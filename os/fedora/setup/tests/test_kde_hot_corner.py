"""Shell-level hot-corner tests with in-memory KConfig and reload mocks."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-02-kde-settings.sh"
MOCKS = r'''
source "$1"
declare -A config=()
writes=0
reloads=0
BACKUP_DIR=/unused-test-backup
read_kde_value() { printf '%s\n' "${config[$2/$3]-__missing__}"; }
kwriteconfig6() {
  local group='' key='' deleting=0
  while (( $# )); do
    case "$1" in
      --file) shift 2 ;;
      --group) group="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --delete) deleting=1; shift ;;
      --) shift; break ;;
      *) return 99 ;;
    esac
  done
  writes=$((writes+1))
  if [[ "$deleting" == 1 ]]; then
    unset 'config[$group/$key]'
  else
    config[$group/$key]="$1"
  fi
}
reload_hot_corner() { reloads=$((reloads+1)); }
extra_entries=''
discover_hot_corner_entries() { printf '%s\n' "$extra_entries"; }
'''


class HotCornerTests(unittest.TestCase):
    def run_shell(self, code, answers=""):
        result = subprocess.run(["bash", "-c", MOCKS + code, "test", str(SCRIPT)],
                                input=answers, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_declining_does_nothing(self):
        self.run_shell(r'''
config[Effect-overview/BorderActivate]=7
collect_hot_corner_choice
configure_hot_corner
[[ "$writes" == 0 && "$reloads" == 0 && "$DISABLE_TOP_LEFT" == 0 ]]
[[ "${config[Effect-overview/BorderActivate]}" == 7 ]]
''', "\n")

    def test_default_overview_is_explicitly_disabled(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
configure_hot_corner
[[ "${config[Effect-overview/BorderActivate]}" == 9 ]]
[[ "${config[ElectricBorders/TopLeft]}" == None ]]
[[ "${config[Windows/ElectricBorderMaximize]-absent}" == absent ]]
[[ "${config[Windows/ElectricBorderTiling]-absent}" == absent ]]
[[ "$writes" == 2 ]]
''')

    def test_other_edges_dragging_and_touch_are_unchanged(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
config[Effect-overview/BorderActivate]='7,2,4'
config[Effect-overview/TouchBorderActivate]=7
config[Effect-windowview/BorderActivateAll]='0,7'
config[TabBox/BorderAlternativeActivate]=7
config[ElectricBorders/TopRight]=ShowDesktop
config[Windows/ElectricBorderMaximize]=false
config[Windows/ElectricBorderTiling]=true
configure_hot_corner
[[ "${config[Effect-overview/BorderActivate]}" == 2,4 ]]
[[ "${config[Effect-windowview/BorderActivateAll]}" == 0 ]]
[[ "${config[TabBox/BorderAlternativeActivate]}" == 9 ]]
[[ "${config[Effect-overview/TouchBorderActivate]}" == 7 ]]
[[ "${config[ElectricBorders/TopRight]}" == ShowDesktop ]]
[[ "${config[Windows/ElectricBorderMaximize]}" == false ]]
[[ "${config[Windows/ElectricBorderTiling]}" == true ]]
''')

    def test_repeat_does_not_rewrite_and_declining_does_not_reset(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
configure_hot_corner
HOT_CORNER_ARMED=0
HOT_CORNER_GROUPS=(); HOT_CORNER_KEYS=(); HOT_CORNER_OLD=()
configure_hot_corner
[[ "$writes" == 2 ]]
DISABLE_TOP_LEFT=0
collect_hot_corner_choice
configure_hot_corner
[[ "$writes" == 2 && "${config[Effect-overview/BorderActivate]}" == 9 ]]
''', "n\n")

    def test_targeted_recovery_preserves_unrelated_changes(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
config[Effect-overview/BorderActivate]='7,2'
configure_hot_corner
config[Desktops/Number]=3
restore_hot_corner
[[ "${config[Effect-overview/BorderActivate]}" == 7,2 ]]
[[ "${config[ElectricBorders/TopLeft]-absent}" == absent ]]
[[ "${config[Desktops/Number]}" == 3 ]]
[[ "$HOT_CORNER_ARMED" == 0 ]]
''')

    def test_reload_failure_rolls_back(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
ROLLBACK_ARMED=1
reload_hot_corner() { return 1; }
trap '[[ "${config[ElectricBorders/TopLeft]-absent}" == absent && "${config[Effect-overview/BorderActivate]-absent}" == absent ]] || exit 99' EXIT
# A subshell contains the expected die/exit; its EXIT trap verifies recovery.
if (configure_hot_corner); then exit 99; else status=$?; fi
[[ "$status" == 1 ]]
''')

    def test_edge_list_validation(self):
        self.run_shell(r'''
[[ "$(without_top_left '7')" == 9 ]]
[[ "$(without_top_left '0,7,6')" == 0,6 ]]
[[ "$(without_top_left '0, 6')" == '0, 6' ]]
if without_top_left 'unexpected'; then exit 99; fi
''')

    def test_dynamic_effect_and_script_assignments(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
extra_entries=$'Effect-custom BorderActivate\nScript-custom BorderActivate'
config[Effect-custom/BorderActivate]='7,2'
config[Script-custom/BorderActivate]=7
configure_hot_corner
[[ "${config[Effect-custom/BorderActivate]}" == 2 ]]
[[ "${config[Script-custom/BorderActivate]}" == 9 ]]
[[ " ${HOT_CORNER_EFFECTS[*]} " == *' custom '* ]]
[[ "$HOT_CORNER_PENDING" == 1 && "$HOT_CORNER_STATUS" == *'manual review'* ]]
restore_hot_corner
[[ "${config[Effect-custom/BorderActivate]}" == 7,2 ]]
[[ "${config[Script-custom/BorderActivate]}" == 7 ]]
''')

    def test_unsupported_activation_is_reported(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
extra_entries='Unsupported Script-hardcoded is enabled without standard screen-edge metadata'
configure_hot_corner
[[ "$HOT_CORNER_PENDING" == 1 ]]
[[ " ${ADVISORIES[*]} " == *'Script-hardcoded'* ]]
[[ "$HOT_CORNER_STATUS" == *'manual review'* ]]
''')

    def test_discovery_failure_does_not_write(self):
        self.run_shell(r'''
DISABLE_TOP_LEFT=1
discover_hot_corner_entries() { return 1; }
configure_hot_corner
[[ "$writes" == 0 && "$HOT_CORNER_STATUS" == skipped:* ]]
''')


if __name__ == "__main__":
    unittest.main()
