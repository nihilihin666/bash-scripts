"""Offline update failures and launcher policy, without starting T3 Code."""
import hashlib

from support import ScriptTest


class LauncherTests(ScriptTest):
    def installed_release(self):
        install = self.home / '.local/opt/t3code'
        release = install / 'releases/old'
        release.mkdir(parents=True)
        app = release / 'AppRun'
        app.write_text('#!/usr/bin/env bash\nexit 0\n')
        app.chmod(0o755)
        (install / 'current').symlink_to(release, target_is_directory=True)
        (install / 'T3-Code.AppImage').write_bytes(b'old verified image')
        return install, release

    def test_failed_update_preserves_previous_image_release_and_cleans_temporary(self):
        install, release = self.installed_release()
        for failure in ('download', 'checksum', 'extraction'):
            with self.subTest(failure=failure):
                fixture = self.work / 'fake-image'
                fixture.write_text('#!/usr/bin/env bash\nexit 7\n')
                digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
                result = self.bash('t3code.sh', '''
fixture="$1"; failure="$2"; fixture_digest="$3"
trap cleanup_install_tmp EXIT
fetch_latest_appimage_asset() {
    printf 'T3-Code.AppImage\thttps://github.com/%s/releases/download/test/app\tsha256:%s\n' "$REPO" "$fixture_digest"
}
curl() {
    if [[ "$failure" == download ]]; then return 7; fi
    cp -- "$fixture" "${@: -1}"
}
if [[ "$failure" == checksum ]]; then fixture_digest="$(printf '0%.0s' {1..64})"; fi
install_or_update_app
''', fixture, failure, digest, expected=1 if failure == 'checksum' else 7)
                if failure == 'checksum':
                    self.assertIn('checksum verification failed', result.stderr)
                self.assertEqual((install / 'T3-Code.AppImage').read_bytes(), b'old verified image')
                self.assertEqual((install / 'current').resolve(), release)
                self.assertEqual(list((install / 'releases').iterdir()), [release])
                self.assertEqual(list(install.glob('*.tmp.*')), [])
                self.assertEqual(list(install.glob('.extract.*')), [])

    def test_unexpected_download_origin_is_rejected(self):
        install, release = self.installed_release()
        result = self.bash('t3code.sh', '''
fetch_latest_appimage_asset() { printf 'app\thttps://example.invalid/app\tsha256:abc\n'; }
install_or_update_app
''', expected=1)
        self.assertIn('refusing unexpected download URL', result.stderr)
        self.assertEqual((install / 'current').resolve(), release)

    def test_unrelated_url_handler_is_preserved(self):
        self.bash('t3code.sh', '''
xdg-mime() {
    if [[ "$1" == query ]]; then echo unrelated.desktop
    else echo unexpected-registration >&2; exit 98; fi
}
update-desktop-database() { :; }
update_existing_desktop_entries
''')
        self.assertTrue((self.home / '.local/share/applications/t3code-launcher.desktop').is_file())

    def test_sandbox_retry_requires_opt_in_and_sandbox_error(self):
        for allowed, message, retries in (
            ('false', 'No usable sandbox', 1),
            ('true', 'No usable sandbox', 2),
            ('true', 'unrelated startup error', 1),
        ):
            with self.subTest(allowed=allowed, message=message):
                self.bash('t3code.sh', r'''
ALLOW_NO_SANDBOX="$1"; message="$2"; expected="$3"
APP_ARGS=('t3code://some path' '--literal=$(touch nope)')
mktemp() { command mktemp "$TMPDIR/t3code-run.XXXXXX.log"; }
calls=0
launch_once() {
    calls=$((calls + 1))
    local log="$1"
    shift
    printf '%s\0' "$@" > "$HOME/launch-$calls"
    if (( calls == 1 )); then printf '%s\n' "$message" > "$log"; return 7; fi
}
acquire_launch_lock() { :; }
release_launch_lock() { :; }
restore_previous_release() { :; }
if run_app; then [[ "$expected" == 2 ]]; else [[ "$expected" == 1 ]]; fi
[[ "$calls" == "$expected" ]]
''', allowed, message, retries)
                first = (self.home / 'launch-1').read_bytes().split(b'\0')[:-1]
                self.assertNotIn(b'--no-sandbox', first)
                if retries == 2:
                    second = (self.home / 'launch-2').read_bytes().split(b'\0')[:-1]
                    self.assertIn(b'--no-sandbox', second)
                    self.assertEqual(second[-2:], [b't3code://some path', b'--literal=$(touch nope)'])
                self.assertFalse((self.work / 'nope').exists())

    def test_failed_updated_startup_restores_previous_release(self):
        install, release = self.installed_release()
        new = install / 'releases/new'
        new.mkdir()
        result = self.bash('t3code.sh', '''
PREVIOUS_RELEASE="$1"; UPDATED_THIS_RUN=true
mktemp() { command mktemp "$TMPDIR/t3code-run.XXXXXX.log"; }
ln -sfn "$2" "$CURRENT_LINK"
launch_once() { printf 'startup failed\n' > "$1"; return 7; }
acquire_launch_lock() { :; }
release_launch_lock() { :; }
run_app
''', release, new, expected=1)
        self.assertIn('Restored the previous', result.stderr)
        self.assertEqual((install / 'current').resolve(), release)
