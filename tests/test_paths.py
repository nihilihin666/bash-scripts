"""Relocation checks using private homes and mocked downloads; no installations."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PathTests(unittest.TestCase):
    def bash(self, code, script, home, cwd):
        result = subprocess.run(
            ['bash', '-c', code, 'test', str(script)],
            env={**os.environ, 'HOME': str(home)}, cwd=cwd,
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_default_output_paths_are_home_based(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'home with spaces'
            home.mkdir()
            for name, variable, suffix in (
                ('youtube-download.sh', 'OUTDIR', '/youtube-downloaded'),
                ('system-info.sh', 'OUTPUT_DIR', ''),
                ('randomise-filenames.sh', 'MAP_DIR', ''),
                ('image.sh', 'DEFAULT_RUN_ROOT', '/image/'),
            ):
                with self.subTest(script=name):
                    result = self.bash(
                        'source "$1"\nprintf \'%s\\n\' "$' + variable + '"',
                        ROOT / name, home, root)
                    expected = str(home / 'bash-scripts-output') + suffix
                    if name == 'image.sh':
                        self.assertTrue(result.stdout.strip().startswith(expected))
                    else:
                        self.assertEqual(result.stdout.strip(), expected)
            self.assertEqual(list(home.iterdir()), [])

    def test_moved_downloader_writes_under_home_from_different_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'home with spaces'
            home.mkdir()
            script = root / 'moved downloader.sh'
            shutil.copy2(ROOT / 'youtube-download.sh', script)
            for name in ('working one', 'working two'):
                cwd = root / name
                cwd.mkdir()
                self.bash(r'''
source "$1"
ensure_base_requirements() { :; }
ensure_yt_dlp() { YT_DLP=fake_download; }
fake_download() {
    local destination=''
    while (( $# )); do
        if [[ "$1" == -P ]]; then destination="$2"; break; fi
        shift
    done
    [[ "$destination" == "$HOME/bash-scripts-output/youtube-downloaded" ]] || return 99
    printf 'downloaded\n' > "$destination/example.mp4"
}
main https://example.com/video
''', script, home, cwd)
                self.assertFalse((cwd / 'bash-scripts-output').exists())
                self.assertFalse((root / 'bash-scripts-output').exists())
                self.assertEqual(
                    (home / 'bash-scripts-output/youtube-downloaded/example.mp4').read_text(),
                    'downloaded\n')

    def test_t3_shortcuts_survive_source_removal_and_installed_copy_can_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'home with spaces'
            home.mkdir()
            script = root / 'moved launcher.sh'
            shutil.copy2(ROOT / 't3code.sh', script)
            applications = home / '.local/share/applications'
            applications.mkdir(parents=True)
            desktop = applications / 'com.t3tools.T3Code.desktop'
            desktop.write_text('[Desktop Entry]\nExec=/old/location --bg\n')
            original_desktop = desktop.read_text()
            self.bash(r'''
source "$1"
xdg-mime() {
    case "$*" in
        'query default x-scheme-handler/t3code') echo com.t3tools.T3Code.desktop ;;
        'default t3code-launcher.desktop x-scheme-handler/t3code')
            printf '%s\n' "$*" > "$HOME/handler-registration" ;;
        *) return 99 ;;
    esac
}
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
install_launcher
update_existing_desktop_entries
''', script, home, root)
            launcher = home / '.local/opt/t3code/launcher.sh'
            shortcut = home / '.local/bin/t3code'
            self.assertEqual(shortcut.resolve(), launcher)
            managed_desktop = applications / 't3code-launcher.desktop'
            self.assertIn(f'Exec="{launcher}" --bg -- %U', managed_desktop.read_text())
            self.assertNotIn(str(script), managed_desktop.read_text())
            self.assertEqual(desktop.read_text(), original_desktop)
            self.assertEqual((home / 'handler-registration').read_text().strip(),
                             'default t3code-launcher.desktop x-scheme-handler/t3code')
            # Simulate the application regenerating its own desktop entry.
            desktop.write_text('[Desktop Entry]\nExec=/new/release/t3code %U\n')
            self.assertIn(f'Exec="{launcher}" --bg -- %U', managed_desktop.read_text())
            script.unlink()
            self.bash('"$1" --help', shortcut, home, root)
            inode = launcher.stat().st_ino
            self.bash('source "$1"\ninstall_launcher', shortcut, home, root)
            self.assertEqual(launcher.stat().st_ino, inode)

    def test_t3_repairs_handler_after_ready_or_forwarded_startup(self):
        for forwarded in (False, True):
            with self.subTest(forwarded=forwarded), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.bash(r'''
source "$1"
STARTUP_TIMEOUT=3
release_launch_lock() { :; }
update-desktop-database() { :; }
xdg-mime() {
    if [[ "$1" == query ]]; then
        cat "$HOME/handler"
    else
        printf '%s\n' "$2" > "$HOME/handler"
    fi
}
fake_app() {
    # Simulate the app overriding a previously selected launcher handler.
    printf '%s\n' com.t3tools.T3Code.desktop > "$HOME/handler"
''' + ('' if forwarded else "    echo 'main window created'\n") + r'''
}
printf '%s\n' t3code-launcher.desktop > "$HOME/handler"
launch_once "$HOME/startup.log" fake_app
[[ "$(cat "$HOME/handler")" == t3code-launcher.desktop ]]
''', ROOT / 't3code.sh', root, root)

    def test_t3_failed_startup_does_not_register_handler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.bash(r'''
source "$1"
release_launch_lock() { :; }
update_existing_desktop_entries() { echo unexpected-repair >&2; exit 99; }
fake_app() { return 7; }
if launch_once "$HOME/startup.log" fake_app; then
    exit 98
else
    [[ "$?" == 7 ]]
fi
''', ROOT / 't3code.sh', root, root)

    def test_help_tracks_relocated_script_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'home'
            home.mkdir()
            for original in sorted(ROOT.rglob('*.sh')):
                with self.subTest(script=original.relative_to(ROOT)):
                    script = root / original.name
                    shutil.copy2(original, script)
                    result = self.bash('bash "$1" --help', script, home, home)
                    self.assertIn(str(script), result.stdout)
                    self.assertNotIn('./sh/', result.stdout)
            self.assertEqual(list(home.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
