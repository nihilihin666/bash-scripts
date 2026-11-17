"""Decimal validation, recovery notifications, and metadata discovery tests."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-02-kde-settings.sh"


class SafetyTests(unittest.TestCase):
    def shell(self, code, answers="", env=None):
        result = subprocess.run(["bash", "-c", 'source "$1"\n' + code, "test", str(SCRIPT)],
                                input=answers, text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_decimal_limits_and_overflow(self):
        self.shell(r'''
[[ "$(normalize_decimal 08 1440)" == 8 ]]
[[ "$(normalize_decimal 00030 1440)" == 30 ]]
[[ "$(normalize_decimal 01440 1440)" == 1440 ]]
for value in 02000 1441 0 000 -1 1.5 999999999999999999999999999999999999999999; do
  if normalize_decimal "$value" 1440; then exit 99; fi
done
parse_args --lock-minutes 0008
[[ "$LOCK_MINUTES" == 8 ]]
''')

    def test_numbered_menu_normalizes_and_reprompts(self):
        self.shell('[[ "$(ask_numbered_choice Selection 1 3)" == 2 ]]', "999999999999999999999999\n0002\n")

    def test_interactive_minutes_normalized(self):
        self.shell('ask_lock_minutes\n[[ "$LOCK_MINUTES" == 8 ]]', "02000\n08\n")

    def test_recovery_notifies_only_changed_restored_files(self):
        result = self.shell(r'''
calls=()
gdbus() { calls+=("$*"); }
mark_config_changed kscreenlockerrc
mark_config_changed kscreenlockerrc
mark_config_changed kdeglobals
mark_config_changed kxkbrc
[[ "${#CHANGED_CONFIGS[@]}" == 3 ]]
reload_recovered_settings kscreenlockerrc kdeglobals kxkbrc
[[ "${#calls[@]}" == 2 ]]
[[ "${calls[0]}" == *org.kde.screensaver.configure* ]]
[[ "${calls[1]}" == *org.kde.KGlobalSettings.notifyChange* ]]
calls=()
reload_recovered_settings
[[ "${#calls[@]}" == 0 ]]
''')
        self.assertIn("logout/login", result.stderr)

    def test_recovery_reports_reload_failure_and_continues(self):
        result = self.shell(r'''
gdbus() { return 1; }
CHANGED_CONFIGS=(kscreenlockerrc kdeglobals ksmserverrc)
reload_recovered_settings kscreenlockerrc kdeglobals ksmserverrc
echo completed
''')
        self.assertIn("running lock policy", result.stderr)
        self.assertIn("Could not notify", result.stderr)
        self.assertIn("ksmserverrc", result.stderr)
        self.assertIn("completed", result.stdout)

    def test_rollback_restores_file_before_reloading_consumer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "kscreenlockerrc").write_text("new policy")
            (root / "saved").write_text("old policy")
            env = dict(os.environ, TEST_ROOT=str(root))
            self.shell(r'''
BACKUP_DIR="$TEST_ROOT"
BACKUP_PATHS=("$TEST_ROOT/kscreenlockerrc")
BACKUP_FILES=("$TEST_ROOT/saved")
BACKUP_EXISTED=(1)
CHANGED_CONFIGS=(kscreenlockerrc)
ROLLBACK_ARMED=1
notified=0
gdbus() {
  [[ "$(< "$TEST_ROOT/kscreenlockerrc")" == 'old policy' ]] || return 1
  notified=1
}
rollback
[[ "$notified" == 1 && "$ROLLBACK_ARMED" == 0 ]]
''', env=env)

    def test_failed_restore_does_not_reload_wrong_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "kscreenlockerrc").write_text("new policy")
            env = dict(os.environ, TEST_ROOT=str(root))
            result = self.shell(r'''
BACKUP_DIR="$TEST_ROOT"
BACKUP_PATHS=("$TEST_ROOT/kscreenlockerrc")
BACKUP_FILES=("$TEST_ROOT/missing-backup")
BACKUP_EXISTED=(1)
CHANGED_CONFIGS=(kscreenlockerrc)
ROLLBACK_ARMED=1
notified=0
gdbus() { notified=1; }
rollback
[[ "$notified" == 0 ]]
''', env=env)
            self.assertIn("manual recovery is required", result.stderr)

    def test_discovery_reads_metadata_and_config_without_running_plugins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config"
            data = root / "data"
            config.mkdir()
            (config / "kwinrc").write_text("[Effect-stored]\nBorderActivate=7\n[Script-orphan]\nBorderActivate=7\n")
            for kind, ident in (("effects", "dynamic"), ("scripts", "scripted")):
                plugin = data / "kwin" / kind / ident
                plugin.mkdir(parents=True)
                (plugin / "metadata.json").write_text(json.dumps({
                    "KPlugin": {"Id": ident}, "X-KWin-Border-Activate": True}))
            env = dict(os.environ, XDG_CONFIG_DIRS=str(root / "empty-config"),
                       XDG_DATA_DIRS=str(root / "empty-data"), TEST_CONFIG=str(config), TEST_DATA=str(data))
            result = self.shell('CONFIG_HOME="$TEST_CONFIG"\nDATA_HOME="$TEST_DATA"\ndiscover_hot_corner_entries', env=env)
            self.assertIn("Effect-stored BorderActivate", result.stdout)
            self.assertIn("Effect-dynamic BorderActivate", result.stdout)
            self.assertIn("Script-scripted BorderActivate", result.stdout)
            self.assertIn("Unsupported Script-orphan", result.stdout)


if __name__ == "__main__":
    unittest.main()
