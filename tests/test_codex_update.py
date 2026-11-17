"""No npm installations: updater control flow uses a local npm function."""
import os

from support import ScriptTest


class CodexUpdaterTests(ScriptTest):
    def test_root_is_refused_before_npm(self):
        if os.geteuid() != 0:
            self.skipTest('actual root refusal requires EUID 0; never invoke sudo for tests')
        result = self.bash('codex-update.sh', 'main', expected=1)
        self.assertIn('normal user', result.stderr)

    def test_prefix_fallback_and_writable_prefix_preserve_spaces(self):
        for writable in (True, False):
            with self.subTest(writable=writable):
                result = self.bash('codex-update.sh', '''
npm() { printf '%s\n' "$HOME/npm prefix"; }
prefix_is_writable() { [[ "$1" == "$HOME/npm prefix" && "$writable" == True ]]; }
writable="$1"
resolve_install_prefix
''', writable)
                self.assertEqual(result.stdout.strip(), str(
                    self.home / ('npm prefix' if writable else '.local')))

    def test_writable_prefix_detection_for_existing_and_new_paths(self):
        prefix = self.home / 'existing prefix'
        prefix.mkdir()
        self.bash('codex-update.sh', '''
prefix_is_writable "$1"
prefix_is_writable "$1/not created/yet"
''', prefix)
        self.assertEqual(list(prefix.iterdir()), [])

    def updater(self):
        return '''
# Bypass only the UID preflight so main can be tested under root or a user.
# npm itself remains mocked; the dedicated root test checks the real guard.
require_normal_user() { :; }
mode="$1"
codex() { echo 'codex-cli fixture'; }
npm() {
    case "$1 $2" in
        '--version ') echo fixture ;;
        'view @openai/codex') echo 2.0 ;;
        'config get') printf '%s\n' "$HOME/npm prefix" ;;
        'install -g')
            printf '%s\\0' "$@" > "$HOME/install-args"
            if [[ "$mode" == install-fails ]]; then return 7; fi
            touch "$HOME/installed"
            ;;
        'list -g')
            if [[ "$mode" == current || ( -f "$HOME/installed" && "$mode" != verification-fails ) ]]; then
                echo '@openai/codex@2.0'
            else echo '@openai/codex@1.0'; fi
            ;;
        *) echo "unexpected npm arguments: $*" >&2; return 98 ;;
    esac
}
main
'''

    def test_already_current_skips_installation(self):
        result = self.bash('codex-update.sh', self.updater(), 'current')
        self.assertIn('already up to date', result.stdout)
        self.assertFalse((self.home / 'install-args').exists())

    def test_install_arguments_keep_user_prefix_literal(self):
        result = self.bash('codex-update.sh', self.updater(), 'success')
        self.assertIn('Codex update completed.', result.stdout)
        self.assertEqual((self.home / 'install-args').read_bytes().split(b'\0')[:-1],
                         [b'install', b'-g', b'--prefix',
                          str(self.home / 'npm prefix').encode(), b'@openai/codex@latest'])

    def test_install_failure_stops_before_verification_and_success(self):
        result = self.bash('codex-update.sh', self.updater(), 'install-fails', expected=7)
        self.assertNotIn('Updated versions', result.stdout)
        self.assertNotIn('update completed', result.stdout)

    def test_wrong_installed_version_is_failure(self):
        result = self.bash('codex-update.sh', self.updater(), 'verification-fails', expected=1)
        self.assertIn('expected 2.0', result.stderr)
        self.assertNotIn('update completed', result.stdout)
