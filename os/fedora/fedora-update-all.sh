#!/usr/bin/env bash
set -euo pipefail

# Fedora update helper
# - Updates Fedora packages with dnf
# - Updates Flatpak apps/runtimes if Flatpak is installed and remotes exist
# - Updates Snap packages if snap is installed
# - Updates firmware last with fwupdmgr if installed, without prompting to reboot
# - Summarizes failures and package/firmware restart requirements
#
# Run with: sudo bash ./bash-scripts/os/fedora/fedora-update-all.sh

DRY_RUN=0
ASSUME_YES=0
SKIP_REBOOT_CHECK=0
USER_FLATPAK_DIR=""
LOCK_FILE="/run/lock/fedora-update-all.lock"
FAILED_OPERATIONS=()
DECLINED_UPDATES=()
REBOOT_MESSAGE=""
RUN_COMPLETE=0
RUN_INTERRUPTED=0
STOPPED_AFTER_DNF=0
RESTART_CHECKS_COMPLETE=0

usage() {
  cat <<HELP
Update Fedora packages, Flatpak and Snap apps, and firmware; report restart needs.

Usage: $0 [--dry-run] [--yes] [--skip-reboot-check] [--user-flatpak-dir PATH]

Options:
  --dry-run                Show the update plan without running updates.
  -y, --yes                Accept installation prompts.
  --skip-reboot-check      Skip package and firmware restart checks.
                           Some firmware updates require a full shutdown and
                           power-on. Follow the device-specific instructions.
  --user-flatpak-dir PATH  Use an absolute personal Flatpak installation path
                           for the non-root user invoking sudo. Requires sudo;
                           applies only to that user's Flatpak commands.
  -h, --help               Show this help.

Example:
  sudo bash "$0" --user-flatpak-dir /mnt/alice-data/flatpak
HELP
}

die() {
  echo "Error: $*" >&2
  exit 1
}

parse_args() {
  local arg
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --skip-reboot-check) SKIP_REBOOT_CHECK=1 ;;
      --user-flatpak-dir)
        [[ "$#" -ge 2 ]] || die "--user-flatpak-dir requires an absolute path."
        USER_FLATPAK_DIR="$2"
        [[ "$USER_FLATPAK_DIR" == /* ]] || die "--user-flatpak-dir requires an absolute path."
        shift
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $arg" ;;
    esac
    shift
  done
}

require_fedora() {
  local fedora_version
  if [[ ! -r /etc/os-release ]]; then
    echo "Cannot verify Fedora: /etc/os-release is unavailable." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "fedora" ]]; then
    echo "This script supports Fedora only. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
  fi
  if [[ -e /run/ostree-booted ]]; then
    die "this script uses DNF and does not support Fedora Atomic desktops; use the system's atomic update mechanism."
  fi
  fedora_version="$(rpm -E %fedora 2>/dev/null || true)"
  [[ "$fedora_version" =~ ^[0-9]+$ ]] || { echo "Could not determine the Fedora release." >&2; exit 1; }
}

require_root_unless_dry_run() {
  if [[ "$DRY_RUN" -ne 1 && ${EUID:-$(id -u)} -ne 0 ]]; then
    die "run as root: sudo bash $0"
  fi
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (provided by util-linux)."
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another Fedora update process is already running."
}

log() {
  echo
  echo "==> $*"
}

warn() {
  echo "[WARN] $*" >&2
}

record_failure() {
  case "${2:-0}" in
    130) abort_run INT 130 ;;
    143) abort_run TERM 143 ;;
  esac
  FAILED_OPERATIONS+=("$1")
  warn "$1"
}

abort_run() {
  trap - INT TERM
  RUN_INTERRUPTED=1
  FAILED_OPERATIONS+=("Update run interrupted by $1; remaining stages were not attempted.")
  REBOOT_MESSAGE="Restart requirements were not checked after interruption; review the last operation before restarting."
  exit "$2"
}

# EXIT is the single summary path, including errexit and signal termination.
finalize_run() {
  local status="$1"
  trap - EXIT INT TERM
  set +e
  if [[ "$RUN_COMPLETE" -ne 1 && "$RUN_INTERRUPTED" -ne 1 ]]; then
    FAILED_OPERATIONS+=("Update run exited unexpectedly (exit $status); remaining stages were not attempted.")
    [[ "$status" -ne 0 ]] || status=1
  fi
  if [[ "$RESTART_CHECKS_COMPLETE" -ne 1 && -z "$REBOOT_MESSAGE" ]]; then
    REBOOT_MESSAGE="Restart requirements were not fully checked because the update run ended early."
  fi
  print_summary "$STOPPED_AFTER_DNF"
  exit "$status"
}

record_declined_update() {
  DECLINED_UPDATES+=("$1")
  log "Skipped $1 by user choice"
}

print_summary() {
  local stopped="${1:-0}"
  log "Update summary"
  if [[ "$stopped" -eq 1 ]]; then
    if [[ "$SKIP_REBOOT_CHECK" -eq 1 ]]; then
      echo "Update run stopped after DNF failed; later update stages were not attempted."
    else
      echo "Update run stopped after DNF failed; later stages were not attempted (restart checks were still attempted)."
    fi
  fi
  if [[ "${#FAILED_OPERATIONS[@]}" -gt 0 ]]; then
    printf 'Update run had %s failed operation(s):\n' "${#FAILED_OPERATIONS[@]}"
    printf '  - %s\n' "${FAILED_OPERATIONS[@]}"
  else
    echo "Update run completed without detected failures."
  fi
  if [[ "${#DECLINED_UPDATES[@]}" -gt 0 ]]; then
    echo "Updates declined by user:"
    printf '  - %s\n' "${DECLINED_UPDATES[@]}"
  fi
  if [[ -n "$REBOOT_MESSAGE" ]]; then
    printf '%s\n' "$REBOOT_MESSAGE"
  fi
}

# fwupd status 2 means a successful command with nothing to do, not a failure.
run_fwupd_step() {
  local label="$1" rc=0
  shift
  fwupdmgr "$@" || rc=$?
  case "$rc" in
    0) ;;
    2) log "$label: nothing to do" ;;
    *) record_failure "$label (exit $rc)" "$rc" ;;
  esac
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply=""

  while true; do
    if [[ "$default" == "Y" ]]; then
      if ! read -r -p "$prompt [Y/n]: " reply; then
        warn "No answer received; skipping this update. Use --yes to accept updates without input."
        return 1
      fi
      reply="${reply:-Y}"
    else
      if ! read -r -p "$prompt [y/N]: " reply; then
        warn "No answer received; skipping this update. Use --yes to accept updates without input."
        return 1
      fi
      reply="${reply:-N}"
    fi

    case "$reply" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Enter y or n." ;;
    esac
  done
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

update_dnf() {
  log "Updating Fedora packages with dnf"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    dnf upgrade --refresh -y
  else
    dnf upgrade --refresh
  fi
}

update_fwupd_if_installed() {
  if ! has_cmd fwupdmgr; then
    log "fwupdmgr not installed; skipping firmware update check"
    return
  fi

  log "Refreshing firmware metadata"
  local -a firmware_options=()
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    firmware_options+=(--assume-yes)
  fi
  run_fwupd_step "Firmware metadata refresh" refresh --force "${firmware_options[@]}"

  log "Checking for firmware updates"
  local fwupd_output fwupd_rc=0
  fwupd_output="$(LC_ALL=C fwupdmgr get-updates 2>&1)" || fwupd_rc=$?
  echo "$fwupd_output"

  # fwupdmgr uses exit status 2 for a successful query with nothing to do.
  if [[ "$fwupd_rc" -eq 2 ]]; then
    log "No firmware updates available"
    return
  fi

  if [[ "$fwupd_rc" -ne 0 ]]; then
    record_failure "Firmware update query (exit $fwupd_rc); skipping firmware installation." "$fwupd_rc"
    return
  fi

  if [[ "$ASSUME_YES" -eq 1 ]] || ask_yes_no "Apply available firmware updates now" "N"; then
    log "Applying firmware updates"
    run_fwupd_step "Firmware installation" update --no-reboot-check "${firmware_options[@]}"
  else
    record_declined_update "firmware installation"
  fi
}

update_flatpak_scope() {
  local label="$1"
  shift
  local flatpak_cmd=("$@")
  local remotes rc=0
  remotes="$("${flatpak_cmd[@]}" remotes --columns=name)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "$remotes"
    record_failure "${label} Flatpak remote query (exit $rc); skipping this scope." "$rc"
    return
  fi
  if [[ -z "${remotes//[[:space:]]/}" ]]; then
    log "No ${label} Flatpak remotes configured; skipping"
    return
  fi

  log "Checking ${label} Flatpak updates"
  local flatpak_updates
  # Include extensions, other architectures and end-of-life refs/rebases. Keep
  # diagnostics on stderr so a warning cannot masquerade as an available update.
  flatpak_updates="$("${flatpak_cmd[@]}" remote-ls --updates --all --columns=ref)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "$flatpak_updates"
    record_failure "${label} Flatpak update query (exit $rc); skipping this scope." "$rc"
    return
  fi

  if [[ -z "${flatpak_updates//[[:space:]]/}" ]]; then
    log "No ${label} Flatpak updates available"
    return
  fi

  echo "$flatpak_updates"

  if [[ "$ASSUME_YES" -eq 1 ]] || ask_yes_no "Install ${label} Flatpak updates now" "Y"; then
    log "Installing ${label} Flatpak updates"
    "${flatpak_cmd[@]}" update -y || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      record_failure "${label} Flatpak installation (exit $rc)" "$rc"
    fi
  else
    record_declined_update "${label} Flatpak updates"
  fi
}

update_flatpak_if_installed() {
  if ! has_cmd flatpak; then
    log "Flatpak not installed; skipping Flatpak updates"
    return
  fi

  update_flatpak_scope "system" flatpak --system

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    local user_home user_id runtime_dir
    local -a user_env
    if ! user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" \
        || [[ -z "$user_home" ]] || ! user_id="$(id -u "$SUDO_USER")"; then
      record_failure "User ($SUDO_USER) Flatpak environment lookup; skipping this scope."
      return
    fi
    runtime_dir="/run/user/$user_id"
    # Do not reuse root's Flatpak paths or session bus when changing user.
    user_env=(-u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME
      -u FLATPAK_USER_DIR -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS
      HOME="$user_home")
    if [[ -n "$USER_FLATPAK_DIR" ]]; then
      user_env+=(FLATPAK_USER_DIR="$USER_FLATPAK_DIR")
    fi
    if [[ -d "$runtime_dir" && "$(stat -c %u "$runtime_dir" 2>/dev/null || true)" == "$user_id" ]]; then
      user_env+=(XDG_RUNTIME_DIR="$runtime_dir")
    fi
    update_flatpak_scope "user ($SUDO_USER)" \
      runuser -u "$SUDO_USER" -- env "${user_env[@]}" flatpak --user
  fi
}

update_snap_if_installed() {
  if ! has_cmd snap; then
    log "snap not installed; skipping Snap updates"
    return
  fi

  log "Checking Snap updates"
  local snap_updates rc=0
  snap_updates="$(LC_ALL=C snap refresh --list 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "$snap_updates"
    record_failure "Snap update query (exit $rc); skipping Snap refresh." "$rc"
    return
  fi
  echo "$snap_updates"

  if grep -qiE 'All snaps up to date|No updates available' <<< "$snap_updates"; then
    log "No Snap updates available"
    return
  fi

  if [[ "$ASSUME_YES" -eq 1 ]] || ask_yes_no "Install Snap updates now" "Y"; then
    log "Installing Snap updates"
    snap refresh || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      record_failure "Snap installation (exit $rc)" "$rc"
    fi
  else
    record_declined_update "Snap updates"
  fi
}

# Older fwupd check-reboot-needed implementations confuse a device capability
# with a pending update (https://github.com/fwupd/fwupd/issues/9720).
# Read the actual update state, and preserve the distinction between shutdown
# and reboot. Python is optional: without a JSON parser the check stays unknown.
parse_firmware_restart_state() {
  python3 -c '
import json
import sys

try:
    document = json.load(sys.stdin)
    if not isinstance(document, dict):
        raise ValueError("firmware response is not an object")
    devices = document["Devices"]
    if not isinstance(devices, list):
        raise ValueError("Devices is not an array")
    result = "not-needed"
    for device in devices:
        if not isinstance(device, dict):
            raise ValueError("invalid device entry")
        # fwupd omits UNKNOWN update states and empty flags in JSON.
        state = device.get("UpdateState", 0)
        flags = device.get("Flags", [])
        if type(state) is not int or state not in range(6):
            raise ValueError("unknown firmware update state")
        if not isinstance(flags, list) or not all(isinstance(f, str) for f in flags):
            raise ValueError("invalid device flags")
        # FwupdUpdateState: 1 = pending (offline), 4 = needs-reboot.
        # needs-reboot/needs-shutdown flags alone only describe capabilities.
        if state in (1, 4):
            if "needs-shutdown" in flags:
                result = "shutdown"
            elif result != "shutdown":
                result = "needed"
    print(result)
except (ValueError, KeyError, TypeError) as error:
    print("Could not parse firmware restart state: " + str(error), file=sys.stderr)
    sys.exit(1)
'
}

check_restart_requirements() {
  if [[ "$SKIP_REBOOT_CHECK" -eq 1 ]]; then
    REBOOT_MESSAGE="Package and firmware restart checks were skipped (--skip-reboot-check)."
    return
  fi

  log "Checking package and firmware restart requirements"
  local dnf_state=unknown firmware_state=unknown rc=0 output help_output
  if dnf needs-restarting --help >/dev/null 2>&1; then
    output="$(dnf needs-restarting --reboothint 2>&1)" || rc=$?
    case "$rc" in
      0) dnf_state=not-needed ;;
      1) dnf_state=needed ;;
      *)
        printf '%s\n' "$output"
        record_failure "DNF reboot check (exit $rc)" "$rc"
        ;;
    esac
  else
    rc=$?
    case "$rc" in
      130) abort_run INT 130 ;;
      143) abort_run TERM 143 ;;
    esac
    log "DNF needs-restarting unavailable; package restart requirements are unknown"
  fi

  # Check capabilities using help, without contacting devices or offering a reboot.
  if ! has_cmd fwupdmgr; then
    log "fwupdmgr not installed; firmware restart requirements are unknown"
  elif ! has_cmd python3; then
    log "python3 not installed; firmware restart requirements are unknown"
  elif help_output="$(LC_ALL=C fwupdmgr --help 2>&1)"; then
    if grep -q -- '--json' <<< "$help_output"; then
      rc=0
      output="$(fwupdmgr get-devices --json)" || rc=$?
      case "$rc" in
        0)
          if firmware_state="$(parse_firmware_restart_state <<< "$output")"; then
            :
          else
            rc=$?
            firmware_state=unknown
            record_failure "Firmware reboot check returned invalid device data" "$rc"
          fi
          ;;
        2) firmware_state=not-needed ;;
        *)
          printf '%s\n' "$output"
          record_failure "Firmware reboot check (exit $rc)" "$rc"
          ;;
      esac
    else
      log "fwupdmgr lacks a noninteractive reboot check; firmware restart requirements are unknown"
    fi
  else
    rc=$?
    printf '%s\n' "$help_output"
    record_failure "Firmware reboot-check capability query (exit $rc)" "$rc"
  fi

  REBOOT_MESSAGE=""
  if [[ "$firmware_state" == shutdown ]]; then
    REBOOT_MESSAGE="Firmware updates require a full shutdown and power-on; follow the device-specific firmware instructions."
    if [[ "$dnf_state" == needed ]]; then
      REBOOT_MESSAGE+=$'\nPackage updates also require a restart; a full shutdown and power-on will cover both.'
    fi
  elif [[ "$dnf_state" == needed ]]; then
    REBOOT_MESSAGE="A reboot is recommended for package updates."
  fi
  if [[ "$firmware_state" == needed ]]; then
    REBOOT_MESSAGE+="${REBOOT_MESSAGE:+$'\n'}A reboot is required to complete pending firmware updates; follow the device-specific firmware instructions."
  fi
  if [[ "$dnf_state" == unknown || "$firmware_state" == unknown ]]; then
    REBOOT_MESSAGE+="${REBOOT_MESSAGE:+$'\n'}Restart requirements could not be fully determined; review any unavailable or failed checks above."
  elif [[ -z "$REBOOT_MESSAGE" ]]; then
    REBOOT_MESSAGE="No reboot or shutdown is currently recommended by the package and firmware checks."
  fi
}

main() {
  parse_args "$@"
  if [[ -n "$USER_FLATPAK_DIR" ]]; then
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]] || ! id "$SUDO_USER" >/dev/null 2>&1; then
      die "--user-flatpak-dir requires a valid non-root SUDO_USER; run through sudo from that account."
    fi
  fi
  require_fedora
  require_root_unless_dry_run

  if [[ "$DRY_RUN" -eq 1 ]]; then
    local restart_plan="check package and firmware restart requirements without restarting"
    if [[ "$SKIP_REBOOT_CHECK" -eq 1 ]]; then
      restart_plan="skip package and firmware restart checks (--skip-reboot-check)"
    fi
    cat <<PLAN
Fedora update dry-run; no update commands will be executed.

Would perform:
  - dnf upgrade --refresh (interactive unless --yes is supplied)
  - query system Flatpak updates and ask before applying them
  - when run through sudo, query that user's Flatpak updates separately
  - query Snap updates and ask before applying them
  - query firmware updates last and ask before applying them, without a reboot prompt
  - $restart_plan
  - summarize failures and declined updates; return nonzero if any operation failed
The script's installation prompts are accepted when --yes is supplied.
PLAN
    if [[ -n "$USER_FLATPAK_DIR" ]]; then
      printf 'Personal Flatpak installation for %s: %s\n' "$SUDO_USER" "$USER_FLATPAK_DIR"
    fi
    return
  fi

  acquire_lock
  trap 'finalize_run "$?"' EXIT
  trap 'abort_run INT 130' INT
  trap 'abort_run TERM 143' TERM

  local dnf_rc=0
  update_dnf || dnf_rc=$?
  if [[ "$dnf_rc" -ne 0 ]]; then
    record_failure "DNF package update (exit $dnf_rc)" "$dnf_rc"
    STOPPED_AFTER_DNF=1
    check_restart_requirements
    RESTART_CHECKS_COMPLETE=1
    RUN_COMPLETE=1
    return 1
  fi
  update_flatpak_if_installed
  update_snap_if_installed
  update_fwupd_if_installed
  check_restart_requirements
  RESTART_CHECKS_COMPLETE=1
  RUN_COMPLETE=1
  [[ "${#FAILED_OPERATIONS[@]}" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
