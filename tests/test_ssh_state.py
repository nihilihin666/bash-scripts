"""Agent state parsing with private Unix sockets and mocked SSH commands."""
import socket

from support import ScriptTest


class AgentTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.ssh = self.home / '.ssh'
        self.ssh.mkdir(mode=0o700)
        self.state = self.ssh / 'agent.env'
        self.sock_path = self.work / 'agent.sock'
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.sock_path))

    def saved_state(self, mode=0o600):
        self.state.write_text(f'SSH_AUTH_SOCK={self.sock_path}\nSSH_AGENT_PID=123\n')
        self.state.chmod(mode)

    def test_saved_agent_accepts_loaded_or_empty_but_rejects_unreachable(self):
        self.saved_state()
        for status in (0, 1, 2):
            with self.subTest(status=status):
                self.bash('ssh.sh', '''
mock_status="$1"
ssh-add() { return "$mock_status"; }
if load_saved_agent; then
    [[ "$mock_status" != 2 && "$SSH_AUTH_SOCK" == "$2" && "$SSH_AGENT_PID" == 123 ]]
else
    [[ "$mock_status" == 2 ]]
fi
''', status, self.sock_path)

    def test_unsafe_permissions_or_owner_reject_state_before_agent_contact(self):
        for mode, wrong_owner in ((0o644, False), (0o666, False), (0o600, True)):
            with self.subTest(mode=mode, wrong_owner=wrong_owner):
                self.saved_state(mode)
                self.bash('ssh.sh', '''
if [[ "$1" == True ]]; then
    stat() {
        if [[ "$2" == '%u' ]]; then echo "$(( $(id -u) + 1 ))"
        else command stat "$@"; fi
    }
fi
if load_saved_agent; then exit 98; fi
''', wrong_owner)

    def test_state_contents_are_data_and_never_evaluated(self):
        self.state.write_text('SSH_AUTH_SOCK=$(touch "$HOME/executed")\n'
                              'SSH_AGENT_PID=123; touch "$HOME/executed"\n'
                              'UNKNOWN=$(touch "$HOME/executed")\n')
        self.state.chmod(0o600)
        self.bash('ssh.sh', 'if load_saved_agent; then exit 98; fi')
        self.assertFalse((self.home / 'executed').exists())

    def test_stale_saved_socket_starts_mock_agent_and_saves_private_state(self):
        self.state.write_text('SSH_AUTH_SOCK=/nonexistent/stale.sock\nSSH_AGENT_PID=1\n')
        self.state.chmod(0o600)
        self.bash('ssh.sh', '''
mock_socket="$1"
ssh-agent() {
    printf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\nSSH_AGENT_PID=456; export SSH_AGENT_PID;\n' "$mock_socket"
}
ensure_agent
[[ "$SSH_AUTH_SOCK" == "$mock_socket" && "$SSH_AGENT_PID" == 456 ]]
''', self.sock_path)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.read_text(), f'SSH_AUTH_SOCK={self.sock_path}\nSSH_AGENT_PID=456\n')
        self.assertEqual(list(self.ssh.glob('.agent.env.tmp.*')), [])

    def test_failed_state_replacement_preserves_previous_and_cleans_temporary(self):
        self.saved_state()
        before = self.state.read_bytes()
        self.bash('ssh.sh', '''
SSH_AUTH_SOCK="$1"; SSH_AGENT_PID=456
trap cleanup_agent_tmp EXIT
mv() { return 7; }
save_agent
''', self.sock_path, expected=7)
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(list(self.ssh.glob('.agent.env.tmp.*')), [])

    def test_print_env_round_trips_literal_values_without_stdout_diagnostics(self):
        result = self.bash('ssh.sh', r'''
PRINT_ENV=1
SSH_AUTH_SOCK='some path/$(touch nope);socket'
SSH_AGENT_PID=123
log 'diagnostic'
print_agent_environment
''')
        self.assertEqual(result.stderr, 'diagnostic\n')
        restored = self.bash('ssh.sh', '''
eval "$1"
printf '%s' "$SSH_AUTH_SOCK"
''', result.stdout)
        self.assertEqual(restored.stdout, 'some path/$(touch nope);socket')
        self.assertFalse((self.work / 'nope').exists())
