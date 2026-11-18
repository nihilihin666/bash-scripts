"""Run with python3 -m unittest discover -s os/fedora/tests -v.

All update commands and system preconditions are mocked; no real updates run.
"""

import json
import os
from pathlib import Path
import subprocess
import shlex
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "fedora-update-all.sh"

MOCKS = r'''
source "$1"
TRACE="$2"
SUDO_USER=""
require_fedora() { :; }
require_root_unless_dry_run() { :; }
acquire_lock() { printf 'lock\n' >> "$TRACE"; }
has_cmd() {
  case "$1" in
    fwupdmgr) [[ ${HAVE_FWUPD:-1} == 1 ]] ;;
    flatpak) [[ ${HAVE_FLATPAK:-1} == 1 ]] ;;
    snap) [[ ${HAVE_SNAP:-1} == 1 ]] ;;
    python3) [[ ${HAVE_PYTHON:-1} == 1 ]] ;;
    *) return 1 ;;
  esac
}
dnf() {
  printf 'dnf %s\n' "$*" >> "$TRACE"
  case "$*" in
    'upgrade --refresh'*) return "${DNF_RC:-0}" ;;
    'needs-restarting --help') return "${DNF_HELP_RC:-0}" ;;
    'needs-restarting --reboothint') return "${DNF_REBOOT_RC:-0}" ;;
    *) return 99 ;;
  esac
}
fwupdmgr() {
  printf 'fwupdmgr %s\n' "$*" >> "$TRACE"
  case "$1" in
    --help)
      if [[ ${FW_CHECK_SUPPORTED:-1} == 1 ]]; then
        printf '  check-reboot-needed [DEVICE-ID|GUID]\n'
      fi
      if [[ ${FW_JSON_SUPPORTED:-1} == 1 ]]; then
        printf '  --json Output in JSON format\n'
      fi
      return "${FW_HELP_RC:-0}" ;;
    refresh) return "${FW_REFRESH_RC:-0}" ;;
    get-updates)
      printf 'Devices with no available firmware updates:\n  Device A\n'
      printf 'Device B: firmware update available\n'
      return "${FW_QUERY_RC:-0}" ;;
    update)
      [[ "$*" == 'update --no-reboot-check' || "$*" == 'update --no-reboot-check --assume-yes' ]] || return 99
      printf 'Device-specific firmware instructions\n'
      return "${FW_UPDATE_RC:-0}" ;;
    get-devices)
      [[ "$*" == 'get-devices --json' ]] || return 99
      if [[ -n ${FW_DEVICES_JSON+x} ]]; then
        printf '%s\n' "$FW_DEVICES_JSON"
      elif [[ ${FW_REBOOT_RC:-2} == 0 ]]; then
        printf '%s\n' '{"Devices":[{"UpdateState":4,"Flags":["needs-reboot"]}]}'
      else
        printf '%s\n' '{"Devices":[]}'
      fi
      case "${FW_REBOOT_RC:-2}" in
        0|2) return 0 ;;
        *) return "$FW_REBOOT_RC" ;;
      esac ;;
    *) return 99 ;;
  esac
}
flatpak() {
  printf 'flatpak %s\n' "$*" >> "$TRACE"
  case "$2" in
    remotes)
      printf '%s' "${FLATPAK_REMOTES-flathub}"
      return "${FLATPAK_REMOTES_RC:-0}" ;;
    remote-ls)
      if [[ ${HIDDEN_FLATPAK_UPDATE:-0} == 1 && "$*" != *'--all'* ]]; then
        return 0
      fi
      if [[ ${FLATPAK_WARNING:-0} == 1 ]]; then
        printf 'Warning: example diagnostic\n' >&2
      fi
      printf '%s' "${FLATPAK_UPDATES-org.example.App}"
      return "${FLATPAK_QUERY_RC:-0}" ;;
    update) return "${FLATPAK_UPDATE_RC:-0}" ;;
    *) return 99 ;;
  esac
}
snap() {
  printf 'snap %s\n' "$*" >> "$TRACE"
  if [[ "$*" == 'refresh --list' ]]; then
    printf '%s\n' "${SNAP_UPDATES-example-snap}"
    return "${SNAP_QUERY_RC:-0}"
  fi
  [[ "$*" == refresh ]] || return 99
  return "${SNAP_UPDATE_RC:-0}"
}
'''


class FedoraUpdateTests(unittest.TestCase):
    def run_script(self, setup="", args="--yes", expected=0, answers=""):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace"
            trace.touch()
            env = os.environ.copy()
            env.pop("BASH_ENV", None)
            result = subprocess.run(
                ["bash", "-c", MOCKS + "\n" + setup + "\nmain " + args,
                 "test", str(SCRIPT), str(trace)],
                input=answers, capture_output=True, text=True, env=env, timeout=10,
            )
            calls = trace.read_text().splitlines()
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr, calls

    def test_mixed_firmware_output_still_installs(self):
        output, calls = self.run_script()
        self.assertIn("Devices with no available firmware updates:", output)
        self.assertIn("fwupdmgr update --no-reboot-check --assume-yes", calls)
        self.assertIn("Device-specific firmware instructions", output)
        self.assertIn("without detected failures", output)

    def test_firmware_nothing_to_do(self):
        output, calls = self.run_script("FW_QUERY_RC=2")
        self.assertNotIn("fwupdmgr update --no-reboot-check --assume-yes", calls)
        self.assertIn("No firmware updates available", output)
        self.assertIn("fwupdmgr get-devices --json", calls)

    def test_firmware_query_failure_is_not_hidden_by_output(self):
        for status in (1, 3):
            with self.subTest(status=status):
                output, calls = self.run_script(f"FW_QUERY_RC={status}", expected=1)
                self.assertNotIn("fwupdmgr update --no-reboot-check --assume-yes", calls)
                self.assertIn(f"Firmware update query (exit {status})", output)
                self.assertIn("1 failed operation(s)", output)

    def test_firmware_refresh_failure_still_queries_and_installs(self):
        output, calls = self.run_script("FW_REFRESH_RC=1", expected=1)
        self.assertIn("Firmware metadata refresh (exit 1)", output)
        self.assertIn("fwupdmgr update --no-reboot-check --assume-yes", calls)

    def test_firmware_noop_refresh_and_install_are_not_failures(self):
        output, _ = self.run_script("FW_REFRESH_RC=2\nFW_UPDATE_RC=2")
        self.assertIn("without detected failures", output)

    def test_update_order_and_reboot_prompt_suppression(self):
        _, calls = self.run_script()
        stages = ["dnf upgrade --refresh -y", "flatpak --system update -y",
                  "snap refresh", "fwupdmgr update --no-reboot-check --assume-yes",
                  "dnf needs-restarting --reboothint",
                  "fwupdmgr get-devices --json"]
        indices = [calls.index(stage) for stage in stages]
        self.assertEqual(indices, sorted(indices))

    def test_skip_reboot_check_preserves_updates_and_skips_both_checks(self):
        _, default_calls = self.run_script()
        output, calls = self.run_script(args="--yes --skip-reboot-check")
        self.assertEqual(default_calls[-4:], ["dnf needs-restarting --help",
                                             "dnf needs-restarting --reboothint",
                                             "fwupdmgr --help", "fwupdmgr get-devices --json"])
        self.assertEqual(calls, default_calls[:-4])
        summary = output.split("==> Update summary", 1)[1]
        self.assertIn("Package and firmware restart checks were skipped", summary)
        self.assertNotIn("No reboot or shutdown is currently recommended", summary)

    def test_partial_failures_continue_and_are_counted(self):
        output, calls = self.run_script(
            "FLATPAK_UPDATE_RC=1\nSNAP_UPDATE_RC=1\nFW_UPDATE_RC=1", expected=1)
        self.assertIn("3 failed operation(s)", output)
        for label in ("system Flatpak installation", "Snap installation", "Firmware installation"):
            self.assertIn(label, output)
        self.assertIn("fwupdmgr get-devices --json", calls)

    def test_discovery_failures_are_counted(self):
        for setting, label, skipped in (
            ("FLATPAK_REMOTES_RC=1", "system Flatpak remote query", "flatpak --system update -y"),
            ("FLATPAK_QUERY_RC=1", "system Flatpak update query", "flatpak --system update -y"),
            ("SNAP_QUERY_RC=1", "Snap update query", "snap refresh"),
        ):
            with self.subTest(setting=setting):
                output, calls = self.run_script(setting, expected=1)
                self.assertIn(label, output)
                self.assertIn("1 failed operation(s)", output)
                self.assertNotIn(skipped, calls)
                self.assertIn("fwupdmgr update --no-reboot-check --assume-yes", calls)

    def test_missing_optional_tools_are_not_failures(self):
        output, calls = self.run_script("HAVE_FLATPAK=0\nHAVE_SNAP=0\nHAVE_FWUPD=0")
        self.assertFalse(any(call.startswith(("flatpak ", "snap ", "fwupdmgr ")) for call in calls))
        self.assertIn("without detected failures", output)
        self.assertIn("could not be fully determined", output)

    def test_no_flatpak_remotes_or_updates_and_no_snap_updates(self):
        for setting in ("FLATPAK_REMOTES=''", "FLATPAK_UPDATES=''"):
            with self.subTest(setting=setting):
                output, calls = self.run_script(setting + "\nSNAP_UPDATES='All snaps up to date.'")
                self.assertNotIn("flatpak --system update -y", calls)
                self.assertNotIn("snap refresh", calls)
                self.assertIn("without detected failures", output)

    def test_declined_updates_are_summarized_without_failure(self):
        output, calls = self.run_script("ask_yes_no() { return 1; }", args="")
        for command in ("flatpak --system update -y", "snap refresh", "fwupdmgr update --no-reboot-check --assume-yes"):
            self.assertNotIn(command, calls)
        summary = output.split("==> Update summary", 1)[1]
        self.assertIn("Updates declined by user:", summary)
        for label in ("system Flatpak updates", "Snap updates", "firmware installation"):
            self.assertIn(label, summary)
        self.assertIn("fwupdmgr get-devices --json", calls)

    def test_dnf_failure_stops_remaining_stages_and_summarizes(self):
        output, calls = self.run_script("DNF_RC=1", expected=1)
        self.assertEqual(calls, ["lock", "dnf upgrade --refresh -y",
                                 "dnf needs-restarting --help",
                                 "dnf needs-restarting --reboothint",
                                 "fwupdmgr --help", "fwupdmgr get-devices --json"])
        self.assertIn("1 failed operation(s)", output)
        self.assertIn("later stages were not attempted", output)
        self.assertIn("No reboot or shutdown is currently recommended", output)

    def test_dnf_failure_still_reports_restart_and_check_failures(self):
        output, _ = self.run_script("DNF_RC=7\nDNF_REBOOT_RC=1\nFW_REBOOT_RC=1", expected=1)
        self.assertIn("DNF package update (exit 7)", output)
        self.assertIn("A reboot is recommended for package updates", output)
        self.assertIn("Firmware reboot check (exit 1)", output)
        self.assertIn("2 failed operation(s)", output)
        self.assertEqual(output.count("==> Update summary"), 1)

    def test_skip_reboot_check_preserves_dnf_failure(self):
        output, calls = self.run_script("DNF_RC=7", args="--skip-reboot-check --yes",
                                        expected=1)
        self.assertEqual(calls, ["lock", "dnf upgrade --refresh -y"])
        self.assertIn("DNF package update (exit 7)", output)
        self.assertIn("1 failed operation(s)", output)
        self.assertIn("Package and firmware restart checks were skipped", output)
        self.assertNotIn("restart checks were still attempted", output)

    def test_unexpected_exit_preserves_status_and_prints_one_summary(self):
        for body in ("return 7", "exit 7", "false"):
            with self.subTest(body=body):
                status = 1 if body == "false" else 7
                output, calls = self.run_script(
                    f"update_flatpak_if_installed() {{ {body}; }}", expected=status)
                self.assertEqual(output.count("==> Update summary"), 1)
                self.assertIn("exited unexpectedly", output)
                self.assertIn("Restart requirements were not fully checked", output)
                self.assertEqual(calls, ["lock", "dnf upgrade --refresh -y"])

    def test_valid_omitted_firmware_defaults(self):
        for device in ({}, {"UpdateState": 4}, {"Flags": []}):
            data = shlex.quote(json.dumps({"Devices": [device]}))
            output, _ = self.run_script(f"FW_DEVICES_JSON={data}")
            self.assertIn("without detected failures", output)
            self.assertEqual("A reboot is required" in output, device.get("UpdateState") == 4)

    def test_restart_status_combinations(self):
        for dnf_status, firmware_status in ((0, 2), (1, 2), (0, 0), (1, 0)):
            with self.subTest(dnf=dnf_status, firmware=firmware_status):
                output, _ = self.run_script(
                    f"DNF_REBOOT_RC={dnf_status}\nFW_REBOOT_RC={firmware_status}")
                self.assertEqual("A reboot is recommended for package updates." in output, dnf_status == 1)
                self.assertEqual("A reboot is required to complete pending firmware updates" in output, firmware_status == 0)
                self.assertEqual("No reboot or shutdown is currently recommended" in output,
                                 dnf_status == 0 and firmware_status == 2)

    def test_pending_firmware_restart_without_new_installation(self):
        output, calls = self.run_script("FW_QUERY_RC=2\nFW_REBOOT_RC=0")
        self.assertIn("A reboot is required to complete pending firmware updates", output)
        self.assertNotIn("fwupdmgr update --no-reboot-check --assume-yes", calls)

    def test_unavailable_dnf_check_does_not_skip_firmware_check(self):
        output, calls = self.run_script("DNF_HELP_RC=1\nFW_REBOOT_RC=0")
        self.assertIn("fwupdmgr get-devices --json", calls)
        self.assertIn("A reboot is required to complete pending firmware updates", output)
        self.assertIn("could not be fully determined", output)

    def test_unsupported_firmware_check_is_unknown_not_failure(self):
        for setting in ("HAVE_PYTHON=0", "FW_JSON_SUPPORTED=0"):
            with self.subTest(setting=setting):
                output, calls = self.run_script(setting)
                self.assertNotIn("fwupdmgr get-devices --json", calls)
                self.assertIn("could not be fully determined", output)
                self.assertNotIn("No reboot or shutdown is currently recommended", output)

    def test_reboot_check_failures_are_counted(self):
        for setting, label in (("DNF_REBOOT_RC=2", "DNF reboot check"),
                               ("FW_REBOOT_RC=1", "Firmware reboot check"),
                               ("FW_HELP_RC=1", "Firmware reboot-check capability query")):
            with self.subTest(setting=setting):
                output, _ = self.run_script(setting, expected=1)
                self.assertIn(label, output)
                self.assertIn("1 failed operation(s)", output)
                self.assertIn("could not be fully determined", output)

    def test_user_flatpak_runs_before_firmware_and_failure_is_named(self):
        output, calls = self.run_script(r'''
SUDO_USER=alice
id() { printf '1000\n'; }
getent() { printf 'alice:x:1000:1000::/home/alice:/bin/bash\n'; }
runuser() {
  printf 'runuser %s\n' "$*" >> "$TRACE"
  while [[ "$1" != flatpak ]]; do shift; done
  shift
  if [[ "$2" == update ]]; then return 1; fi
  flatpak "$@"
}
''', expected=1)
        self.assertIn("user (alice) Flatpak installation", output)
        user_install = next(i for i, call in enumerate(calls)
                            if call.startswith("runuser ") and call.endswith("--user update -y"))
        self.assertLess(user_install, calls.index("fwupdmgr update --no-reboot-check --assume-yes"))

    def test_dry_run_executes_no_update_or_lock_commands(self):
        output, calls = self.run_script(args="--dry-run")
        self.assertEqual(calls, [])
        self.assertLess(output.index("query Snap updates"), output.index("query firmware updates last"))
        self.assertIn("without a reboot prompt", output)
        self.assertIn("check package and firmware restart requirements", output)

    def test_dry_run_reports_skipped_reboot_checks(self):
        output, calls = self.run_script(args="--dry-run --skip-reboot-check")
        self.assertEqual(calls, [])
        self.assertIn("skip package and firmware restart checks (--skip-reboot-check)", output)
        self.assertNotIn("check package and firmware restart requirements", output)

    def test_eof_never_accepts_default_yes(self):
        output, calls = self.run_script(args="")
        self.assertNotIn("flatpak --system update -y", calls)
        self.assertNotIn("snap refresh", calls)
        self.assertFalse(any(call.startswith("fwupdmgr update ") for call in calls))
        self.assertIn("No answer received", output)
        self.assertIn("Updates declined by user", output)

    def test_explicit_blank_answers_keep_interactive_defaults(self):
        _, calls = self.run_script(args="", answers="\n\n\n")
        self.assertIn("flatpak --system update -y", calls)
        self.assertIn("snap refresh", calls)
        self.assertFalse(any(call.startswith("fwupdmgr update ") for call in calls))

    def test_yes_is_forwarded_to_firmware_without_allowing_reboot(self):
        _, calls = self.run_script()
        self.assertIn("fwupdmgr refresh --force --assume-yes", calls)
        self.assertIn("fwupdmgr update --no-reboot-check --assume-yes", calls)
        _, calls = self.run_script(args="", answers="n\nn\ny\n")
        self.assertIn("fwupdmgr update --no-reboot-check", calls)
        self.assertNotIn("fwupdmgr update --no-reboot-check --assume-yes", calls)

    def test_hidden_flatpak_update_reaches_installation(self):
        _, calls = self.run_script("HIDDEN_FLATPAK_UPDATE=1")
        self.assertIn("flatpak --system update -y", calls)

    def test_flatpak_warning_is_not_mistaken_for_an_update(self):
        output, calls = self.run_script("FLATPAK_UPDATES=''\nFLATPAK_WARNING=1")
        self.assertIn("Warning: example diagnostic", output)
        self.assertNotIn("flatpak --system update -y", calls)

    def test_interrupted_commands_stop_all_later_stages(self):
        cases = (
            ("DNF_RC", "dnf upgrade --refresh -y"),
            ("FLATPAK_REMOTES_RC", "flatpak --system remotes --columns=name"),
            ("FLATPAK_QUERY_RC", "flatpak --system remote-ls --updates --all --columns=ref"),
            ("FLATPAK_UPDATE_RC", "flatpak --system update -y"),
            ("SNAP_QUERY_RC", "snap refresh --list"),
            ("SNAP_UPDATE_RC", "snap refresh"),
            ("FW_REFRESH_RC", "fwupdmgr refresh --force --assume-yes"),
            ("FW_QUERY_RC", "fwupdmgr get-updates"),
            ("FW_UPDATE_RC", "fwupdmgr update --no-reboot-check --assume-yes"),
            ("DNF_HELP_RC", "dnf needs-restarting --help"),
            ("DNF_REBOOT_RC", "dnf needs-restarting --reboothint"),
            ("FW_REBOOT_RC", "fwupdmgr get-devices --json"),
        )
        for setting, last_command in cases:
            for status in (130, 143):
                with self.subTest(setting=setting, status=status):
                    output, calls = self.run_script(f"{setting}={status}", expected=status)
                    self.assertEqual(calls[-1], last_command)
                    self.assertIn("Update run interrupted", output)
                    self.assertNotIn("without detected failures", output)
                    self.assertEqual(output.count("==> Update summary"), 1)

    def test_interrupted_firmware_parser_preserves_status_and_stops_run(self):
        for status in (130, 143):
            with self.subTest(status=status):
                output, calls = self.run_script(f'''
parse_firmware_restart_state() {{
  printf 'firmware parser\\n' >> "$TRACE"
  return {status}
}}
''', expected=status)
                self.assertEqual(calls[-2:], ["fwupdmgr get-devices --json", "firmware parser"])
                self.assertIn("Update run interrupted", output)
                self.assertNotIn("invalid device data", output)
                self.assertNotIn("without detected failures", output)
                self.assertNotIn("No reboot or shutdown is currently recommended", output)
                self.assertEqual(output.count("==> Update summary"), 1)

    def test_actual_signals_stop_later_stages(self):
        for signal, status in (("INT", 130), ("TERM", 143)):
            with self.subTest(signal=signal):
                output, calls = self.run_script(
                    f'dnf() {{ kill -{signal} "$BASHPID"; }}', expected=status)
                self.assertEqual(calls, ["lock"])
                self.assertIn(f"interrupted by {signal}", output)

    def test_firmware_capability_flags_do_not_imply_pending_restart(self):
        for state in (None, 0, 2):
            with self.subTest(state=state):
                device = {"Flags": ["needs-reboot", "needs-shutdown"]}
                if state is not None:
                    device["UpdateState"] = state
                data = shlex.quote(json.dumps({"Devices": [device]}))
                output, _ = self.run_script(f"FW_DEVICES_JSON={data}")
                self.assertIn("No reboot or shutdown is currently recommended", output)

    def test_firmware_pending_and_shutdown_states(self):
        for state in (1, 4):
            for shutdown in (False, True):
                with self.subTest(state=state, shutdown=shutdown):
                    devices = [{"UpdateState": state, "Flags": [
                        "needs-shutdown" if shutdown else "needs-reboot"]}]
                    # A second reboot requirement must not replace a full shutdown.
                    devices.append({"UpdateState": 4, "Flags": ["needs-reboot"]})
                    data = shlex.quote(json.dumps({"Devices": devices}))
                    output, _ = self.run_script(f"FW_DEVICES_JSON={data}\nDNF_REBOOT_RC=1")
                    if shutdown:
                        self.assertIn("require a full shutdown and power-on", output)
                        self.assertNotIn("A reboot is recommended for package updates", output)
                        self.assertIn("will cover both", output)
                    else:
                        self.assertIn("A reboot is required to complete pending firmware updates", output)

    def test_bad_firmware_json_is_a_failure_not_a_clean_reboot_check(self):
        for data in ("", "not json", "null", "[]", "42", "{}", '{"Devices":null}', '{"Devices":[null]}',
                     '{"Devices":[{"UpdateState":999}]}', '{"Devices":[{"Flags":1}]}'):
            with self.subTest(data=data):
                output, _ = self.run_script(f"FW_DEVICES_JSON={shlex.quote(data)}", expected=1)
                self.assertIn("invalid device data", output)
                self.assertIn("could not be fully determined", output)
                self.assertNotIn("No reboot or shutdown is currently recommended", output)

    def test_old_fwupd_without_check_reboot_command_uses_device_state(self):
        output, calls = self.run_script("FW_CHECK_SUPPORTED=0\nFW_REBOOT_RC=0")
        self.assertIn("fwupdmgr get-devices --json", calls)
        self.assertIn("A reboot is required to complete pending firmware updates", output)

    def test_user_flatpak_does_not_inherit_root_paths_or_session(self):
        output, _ = self.run_script(r'''
SUDO_USER=alice
id() { printf '987654\n'; }
getent() { printf 'alice:x:987654:987654::/home/alice:/bin/bash\n'; }
export XDG_DATA_HOME=/root/data XDG_CONFIG_HOME=/root/config XDG_CACHE_HOME=/root/cache
export FLATPAK_USER_DIR=/root/flatpak XDG_RUNTIME_DIR=/root/runtime DBUS_SESSION_BUS_ADDRESS=root-bus
runuser() {
  shift 3
  local -a command=()
  while [[ "$1" != flatpak ]]; do command+=("$1"); shift; done
  "${command[@]}" bash -c '
    [[ "$HOME" == /home/alice ]] || exit 99
    [[ -z ${XDG_DATA_HOME+x}${XDG_CONFIG_HOME+x}${XDG_CACHE_HOME+x} ]] || exit 99
    [[ -z ${FLATPAK_USER_DIR+x}${XDG_RUNTIME_DIR+x}${DBUS_SESSION_BUS_ADDRESS+x} ]] || exit 99
    printf "User environment verified\n" >&2
  '
}
''')
        self.assertIn("User environment verified", output)
        self.assertIn("without detected failures", output)

    def test_help_documents_custom_flatpak_path_without_running_commands(self):
        output, calls = self.run_script(args="--help")
        self.assertIn("--user-flatpak-dir PATH", output)
        self.assertIn("absolute", output)
        self.assertIn("non-root user invoking sudo", output)
        self.assertEqual(calls, [])

    def test_help_documents_skip_reboot_check_without_running_commands(self):
        for option in ("--help", "-h"):
            with self.subTest(option=option):
                output, calls = self.run_script(args=option)
                self.assertEqual(calls, [])
                self.assertIn("[--skip-reboot-check]", output)
                self.assertIn("Skip package and firmware restart checks.", output)
                self.assertIn("full shutdown", output)

    def test_custom_flatpak_path_rejects_invalid_arguments_before_updates(self):
        for args in ("--user-flatpak-dir", "--user-flatpak-dir ''",
                     "--user-flatpak-dir relative/path",
                     "--user-flatpak-dir --yes"):
            with self.subTest(args=args):
                output, calls = self.run_script(args=args, expected=1)
                self.assertIn("requires an absolute path", output)
                self.assertEqual(calls, [])

    def test_equals_option_values_are_rejected_before_updates(self):
        for args in ("--user-flatpak-dir=", "--user-flatpak-dir=/custom/flatpak"):
            with self.subTest(args=args):
                output, calls = self.run_script(args=args, expected=1)
                self.assertIn("unknown argument", output)
                self.assertEqual(calls, [])

    def test_custom_flatpak_path_requires_valid_sudo_user(self):
        for setup in ("", "SUDO_USER=root", "SUDO_USER=missing\nid() { return 1; }"):
            with self.subTest(setup=setup):
                output, calls = self.run_script(
                    setup, args="--user-flatpak-dir /custom/flatpak", expected=1)
                self.assertIn("requires a valid non-root SUDO_USER", output)
                self.assertEqual(calls, [])

    def test_custom_flatpak_path_is_literal_and_only_used_as_user(self):
        # Include shell syntax and spaces to catch unsafe argument construction.
        path = "/custom data/$(exit 99); 'flatpak'=data"
        setup = r'''
SUDO_USER=alice
id() { printf '987654\n'; }
getent() { printf 'alice:x:987654:987654::/home/alice:/bin/bash\n'; }
export FLATPAK_USER_DIR=/root/flatpak XDG_DATA_HOME=/root/data
runuser() {
  [[ "$1" == -u && "$2" == alice && "$3" == -- ]] || return 99
  shift 3
  local -a command=()
  while [[ "$1" != flatpak ]]; do command+=("$1"); shift; done
  "${command[@]}" bash -c '
    [[ "$FLATPAK_USER_DIR" == "$EXPECTED_PATH" ]] || exit 99
    [[ "$HOME" == /home/alice && -z ${XDG_DATA_HOME+x} ]] || exit 99
  ' || return $?
  printf 'custom user environment verified\n' >> "$TRACE"
  shift
  flatpak "$@"
}
'''
        setup += "\nexport EXPECTED_PATH=" + shlex.quote(path)
        output, calls = self.run_script(
            setup, args="--yes --user-flatpak-dir " + shlex.quote(path))
        self.assertEqual(calls.count("custom user environment verified"), 3)
        self.assertIn("flatpak --user update -y", calls)
        self.assertIn("flatpak --system update -y", calls)
        self.assertIn("without detected failures", output)

        output, calls = self.run_script(setup, args="--dry-run --user-flatpak-dir " + shlex.quote(path))
        self.assertIn("Personal Flatpak installation for alice: " + path, output)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
