"""Private filesystem and command guards for ordinary regression tests."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScriptTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.home = self.work / 'home with spaces'
        self.home.mkdir()
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.calls = self.work / 'forbidden-calls'
        self.env = {
            **os.environ, 'HOME': str(self.home),
            'XDG_CONFIG_HOME': str(self.home / '.config'),
            'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_CACHE_HOME': str(self.home / '.cache'),
            'XDG_RUNTIME_DIR': str(self.work / 'runtime'),
            'TMPDIR': str(self.work), 'LC_ALL': 'C',
            'PATH': str(self.bin) + os.pathsep + os.defpath,
        }
        Path(self.env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
        for key in ('SSH_AUTH_SOCK', 'SSH_AGENT_PID', 'SUDO_USER', 'SUDO_UID',
                    'SUDO_GID', 'DBUS_SESSION_BUS_ADDRESS'):
            self.env.pop(key, None)
        for name in ('sudo', 'npm', 'curl', 'wget', 'dd', 'umount', 'mount',
                     'swapon', 'swapoff', 'apt', 'apt-get', 'dnf', 'ssh-agent',
                     'ssh-add', 'ssh-keygen', 'xdg-mime', 'update-desktop-database'):
            self.command(name, 'printf "%s\\n" "$0 $*" >> "$HOME/../forbidden-calls"\nexit 99\n')
        self.addCleanup(self.assert_no_forbidden_calls)

    def assert_no_forbidden_calls(self):
        self.assertFalse(self.calls.exists(),
                         self.calls.read_text() if self.calls.exists() else '')

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)
        return path

    def bash(self, script, code, *args, expected=0, stdin=None):
        path = ROOT / script
        if script == 'os/dd.sh':
            # This script has an unconditional entry point. Load its unchanged
            # function definitions without invoking discovery or operational main.
            source = path.read_text()
            self.assertTrue(source.endswith('\nmain "$@"\n'))
            path = self.work / 'dd-functions.sh'
            path.write_text(source.removesuffix('main "$@"\n'))
        result = subprocess.run(
            ['bash', '-c', 'set -e\nsource "$1"\nshift\n' + code,
             'regression', str(path), *map(str, args)],
            cwd=self.work, env=self.env, input=stdin,
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def snapshot(self, directory):
        return {str(path.relative_to(directory)): path.read_bytes()
                for path in directory.rglob('*') if path.is_file()}
