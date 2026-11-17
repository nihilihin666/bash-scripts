"""Exercise optional Yakuake installation without running a package manager."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-02-kde-settings.sh"
MOCKS = r'''
source "$1"
installed=0
install_result=0
verify_install=1
calls=()
rpm() { [[ "$*" == '-q yakuake' && "$installed" == 1 ]]; }
dnf() { echo 'Unexpected direct DNF invocation' >&2; return 99; }
sudo() {
  [[ "$*" == 'dnf install -y yakuake' ]] || return 99
  calls+=("$*")
  [[ "$install_result" == 0 ]] || return "$install_result"
  installed="$verify_install"
}
'''


class YakuakeTests(unittest.TestCase):
    def shell(self, code, answers="", expected_status=0):
        result = subprocess.run(
            ["bash", "-c", MOCKS + code, "test", str(SCRIPT)],
            input=answers, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
        return result

    def test_default_and_explicit_no_skip_installation(self):
        for answer in ("\n", "n\n"):
            with self.subTest(answer=answer):
                self.shell(r'''
collect_yakuake_choice
install_yakuake
[[ "$INSTALL_YAKUAKE" == 0 && "${#calls[@]}" == 0 ]]
[[ "$YAKUAKE_STATUS" == 'skipped by choice' ]]
''', answer)

    def test_yes_records_choice_then_installs_once(self):
        self.shell(r'''
collect_yakuake_choice
[[ "$INSTALL_YAKUAKE" == 1 && "${#calls[@]}" == 0 ]]
install_yakuake
install_yakuake
[[ "$installed" == 1 && "${#calls[@]}" == 1 ]]
[[ "$YAKUAKE_STATUS" == 'already installed' ]]
''', "y\n")

    def test_success_is_reported_in_summary(self):
        result = self.shell(r'''
collect_yakuake_choice
install_yakuake
[[ "$YAKUAKE_STATUS" == installed && "${#ADVISORIES[@]}" == 0 ]]
print_summary
''', "Y\n")
        self.assertRegex(result.stdout, r"Yakuake:\s+installed")

    def test_already_installed_needs_no_input_or_sudo(self):
        self.shell(r'''
installed=1
collect_yakuake_choice
install_yakuake
[[ "$YAKUAKE_STATUS" == 'already installed' && "${#calls[@]}" == 0 ]]
''')

    def test_package_installed_after_choice_skips_sudo(self):
        self.shell(r'''
collect_yakuake_choice
installed=1
install_yakuake
[[ "$YAKUAKE_STATUS" == 'already installed' && "${#calls[@]}" == 0 ]]
''', "y\n")

    def test_install_failure_is_nonfatal_and_reported(self):
        result = self.shell(r'''
INSTALL_YAKUAKE=1
install_result=1
install_yakuake
[[ "$YAKUAKE_STATUS" == 'installation failed' && "${#ADVISORIES[@]}" == 1 ]]
[[ "$ROLLBACK_ARMED" == 0 && "${#calls[@]}" == 1 ]]
print_summary
echo continued
''')
        self.assertIn("continuing KDE setup", result.stderr)
        self.assertIn("installation failed", result.stdout)
        self.assertIn("continued", result.stdout)

    def test_unverified_install_is_reported(self):
        result = self.shell(r'''
INSTALL_YAKUAKE=1
verify_install=0
install_yakuake
[[ "$YAKUAKE_STATUS" == 'installation failed' && "${#ADVISORIES[@]}" == 1 ]]
''')
        self.assertIn("Could not verify", result.stderr)

    def test_missing_tools_only_matter_when_installing(self):
        for missing in ("sudo", "dnf"):
            with self.subTest(missing=missing):
                result = self.shell(f"missing={missing}\n" + r'''
command() {
  [[ "$*" != "-v $missing" ]] || return 1
  builtin command "$@"
}
install_yakuake
[[ "${#ADVISORIES[@]}" == 0 ]]
INSTALL_YAKUAKE=1
install_yakuake
[[ "$YAKUAKE_STATUS" == 'installation failed' && "${#ADVISORIES[@]}" == 1 ]]
[[ "${#calls[@]}" == 0 ]]
''')
                self.assertIn(f"{missing} is required", result.stderr)

    def test_eof_aborts_before_installation(self):
        result = self.shell("collect_yakuake_choice\ninstall_yakuake", expected_status=1)
        self.assertIn("input ended", result.stderr)
        self.assertNotIn("Installing Yakuake", result.stdout)

    def test_dry_run_bypasses_preflight_prompts_and_package_commands(self):
        result = self.shell(r'''
require_fedora() { return 99; }
collect_choices() { return 99; }
rpm() { return 99; }
sudo() { return 99; }
INSTALL_YAKUAKE=1
main --dry-run
install_yakuake
''')
        self.assertIn("installing missing Yakuake", result.stdout)
        self.assertIn("default No", result.stdout)

    def test_installation_precedes_configuration_transaction(self):
        self.shell(r'''
events=()
for fn in require_fedora resolve_execution_context preflight_plasma_session acquire_lock \
    configure_keyboard_layouts configure_numlock configure_screen_locking configure_session \
    configure_regional_formats configure_color_scheme configure_default_browser \
    check_desktop_integrations configure_hot_corner configure_window_settings print_summary; do
  eval "$fn() { :; }"
done
collect_choices() { events+=(choices); collect_yakuake_choice; }
validate_choices() { events+=(validated); }
sudo() {
  [[ "$*" == 'dnf install -y yakuake' && "$ROLLBACK_ARMED" == 0 ]] || return 99
  events+=(installed)
  installed=1
}
prepare_backups() { events+=(backups); ROLLBACK_ARMED=1; }
main
[[ "${events[*]}" == 'choices validated installed backups' ]]
''', "y\n")


if __name__ == "__main__":
    unittest.main()
