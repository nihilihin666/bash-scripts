"""Exercise Signal opt-in and real GPG verification without installing packages."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-01-base.sh"


@unittest.skipUnless(shutil.which("gpg"), "GPG is required")
class SignalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        root = Path(cls.fixture.name)
        keyring = root / "gnupg"
        keyring.mkdir(mode=0o700)
        command = ["gpg", "--batch", "--homedir", str(keyring)]
        subprocess.run(command + ["--pinentry-mode", "loopback", "--passphrase", "",
                                   "--quick-generate-key", "Signal Installer Test",
                                   "ed25519", "sign", "0"], check=True, capture_output=True)
        listing = subprocess.check_output(command + ["--with-colons", "--list-keys"], text=True)
        cls.fingerprint = next(line.split(":")[9] for line in listing.splitlines()
                               if line.startswith("fpr:"))
        (root / "appimage.asc").write_bytes(subprocess.check_output(command + ["--armor", "--export"]))
        image = root / "signal-desktop.AppImage"
        image.write_text('#!/bin/sh\ntouch "$HOME/SHOULD_NOT_RUN"\n')
        subprocess.run(command + ["--detach-sign", "--output", str(image) + ".gpg", str(image)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def shell(self, code="", answers="y\n", pin_test_key=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            downloads = root / "downloads"
            downloads.mkdir()
            for name in ("appimage.asc", "signal-desktop.AppImage", "signal-desktop.AppImage.gpg"):
                shutil.copy(Path(self.fixture.name) / name, downloads / name)
            # Include characters that require escaping in desktop Exec arguments.
            user_home = root / 'desktop user $cash %name'
            user_home.mkdir()
            script = root / "setup.sh"
            source = SCRIPT.read_text()
            if pin_test_key:
                source = source.replace("4B16B7232DFAA439AD791002EF9F501F13EED94C", self.fingerprint)
            script.write_text(source)
            env = dict(os.environ, TEST_ROOT=str(root), DOWNLOADS=str(downloads), TEST_HOME=str(user_home))
            setup = r'''
source "$1"
ORIGINAL_USER="$(id -un)"
ORIGINAL_HOME="$TEST_HOME"
is_signal_installed() { return 1; }
uname() { echo x86_64; }
ensure_pkg() { echo prerequisites >> "$TEST_ROOT/calls"; }
curl() {
  local output="" url="${!#}"
  while (( $# )); do
    if [[ "$1" == --output ]]; then output="$2"; shift; fi
    shift
  done
  [[ "$url" == https://updates.signal.org/* ]] || return 1
  cp "$DOWNLOADS/${url##*/}" "$output"
}
runuser() { shift 3; "$@"; }
'''
            result = subprocess.run(["bash", "-c", setup + code + "\ninstall_signal\n", "test", str(script)],
                                    input=answers, text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            image = user_home / ".local/bin/signal-desktop.AppImage"
            launcher = user_home / ".local/share/applications/signal-appimage.desktop"
            return result, image.read_bytes() if image.exists() else None, \
                launcher.read_text() if launcher.exists() else None, \
                image.stat().st_mode & 0o777 if image.exists() else None, \
                (root / "calls").exists(), (user_home / "SHOULD_NOT_RUN").exists()

    def test_accept_verifies_and_installs_without_running_app(self):
        result, image, launcher, mode, prerequisites, executed = self.shell()
        self.assertEqual(image, (Path(self.fixture.name) / "signal-desktop.AppImage").read_bytes())
        self.assertEqual(mode, 0o755)
        self.assertIn('Exec="', launcher)
        self.assertIn(r'\\$cash %%name/.local/bin/signal-desktop.AppImage" %U', launcher)
        self.assertIn("x-scheme-handler/sgnl", launcher)
        self.assertTrue(prerequisites)
        self.assertFalse(executed)
        self.assertIn("Signal installed", result.stdout)

    def test_no_empty_and_eof_skip_without_prerequisites(self):
        for answer in ("n\n", "\n", ""):
            with self.subTest(answer=answer):
                _, image, launcher, _, prerequisites, _ = self.shell(answers=answer)
                self.assertIsNone(image)
                self.assertIsNone(launcher)
                self.assertFalse(prerequisites)

    def test_wrong_pinned_key_is_rejected(self):
        result, image, launcher, _, _, _ = self.shell(pin_test_key=False)
        self.assertIn("did not match", result.stderr)
        self.assertIsNone(image)
        self.assertIsNone(launcher)

    def test_tampered_image_is_rejected(self):
        result, image, launcher, _, _, _ = self.shell('echo tampered >> "$DOWNLOADS/signal-desktop.AppImage"')
        self.assertIn("BAD signature", result.stderr)
        self.assertIsNone(image)
        self.assertIsNone(launcher)

    def test_download_failure_is_nonfatal(self):
        result, image, launcher, _, _, _ = self.shell("curl() { return 22; }")
        self.assertIn("continuing setup", result.stderr)
        self.assertIsNone(image)
        self.assertIsNone(launcher)

    def test_existing_installation_and_unsupported_architecture_skip(self):
        for code in ('is_signal_installed() { return 0; }', 'uname() { echo aarch64; }'):
            with self.subTest(code=code):
                _, image, _, _, prerequisites, _ = self.shell(code)
                self.assertIsNone(image)
                self.assertFalse(prerequisites)

    def test_existing_flatpak_or_rpm_is_detected(self):
        self.shell(r'''
eval "$(sed -n '/^is_signal_installed() {/,/^}/p' "$1")"
is_pkg_installed() { [[ "$1" == signal-desktop ]]; }
is_flatpak_app_installed() { return 1; }
is_signal_installed
is_pkg_installed() { return 1; }
is_flatpak_app_installed() { [[ "$1" == org.signal.Signal ]]; }
is_signal_installed
''')


if __name__ == "__main__":
    unittest.main()
