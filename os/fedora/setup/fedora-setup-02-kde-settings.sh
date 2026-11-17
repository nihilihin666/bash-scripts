#!/usr/bin/env bash
set -Eeuo pipefail

# fedora-setup-02-kde-settings.sh
# Conservative, user-level Fedora KDE Plasma 6 Wayland setup.
#
# Run as the logged-in desktop user, without sudo:
#   bash ./bash-scripts/os/fedora/setup/fedora-setup-02-kde-settings.sh
#
# Optional window/desktop settings also adjust the panel's Pager widget.
# Optional Yakuake installation uses sudo; no Yakuake settings are configured.
# The script intentionally does not modify SDDM, X11,
# display settings, power profiles, or system services.

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

DRY_RUN=0
LOCK_MINUTES=30
LOCK_MINUTES_SET=0
USER_NAME=""
USER_HOME=""
USER_ID=""
USER_RUNTIME_DIR=""
CONFIG_HOME=""
STATE_HOME=""
DATA_HOME=""
LOCK_FILE=""
KWRITE_NOTIFY=0
QT_PATHS_SHIM_DIR=""

ADD_GB=0
GB_DEFAULT=0
USE_HUNGARIAN_FORMATS=0
USE_EMPTY_SESSION=0
INSTALL_YAKUAKE=0
YAKUAKE_STATUS="skipped by choice"
COLOR_SCHEME="leave"
BROWSER_DESKTOP_ID="leave"
FIREFOX_DESKTOP_ID=""
BRAVE_DESKTOP_ID=""
USE_WINDOW_SETTINGS=0
WINDOW_SNAPSHOT=""
WINDOW_PANEL_ID=-1
WINDOW_REDUCE_DESKTOPS=0
WINDOW_SETTINGS_STATUS="unchanged by choice"
DISABLE_TOP_LEFT=0
HOT_CORNER_STATUS="unchanged by choice"
HOT_CORNER_ARMED=0
HOT_CORNER_GROUPS=()
HOT_CORNER_KEYS=()
HOT_CORNER_OLD=()
HOT_CORNER_EFFECTS=(overview windowview)
HOT_CORNER_PENDING=0
CHANGED_CONFIGS=()

BACKUP_DIR=""
ROLLBACK_ARMED=0
BACKUP_PATHS=()
BACKUP_FILES=()
BACKUP_EXISTED=()
ADVISORIES=()

usage() {
  cat <<USAGE
Configure Fedora KDE Plasma keyboard, locale, session, and optional desktop settings.

Usage: $0 [--dry-run] [--lock-minutes MINUTES]

Options:
  --dry-run               Show the default plan without changing anything.
  --lock-minutes MINUTES  Set the automatic screen-lock delay (1-1440).
  -h, --help              Show this help.

Window/desktop customisation is optional (confirmation defaults to No).
Accepting configures 3 desktops, Windows+arrow shortcuts, and a panel Pager.
Declining leaves those settings unchanged, including on subsequent runs.
Separately asks whether to disable top-left mouse activation (default No).
Dragging windows to the top or sides is never changed by that option.
Yakuake installation is optional (default No) and requires sudo only if missing.
Yakuake is not launched, configured, or added to autostart.
USAGE
}

log() {
  echo
  echo "==> $*"
}

warn() {
  echo "[WARN] $*" >&2
}

cleanup_runtime_temp() {
  if [[ -z "$QT_PATHS_SHIM_DIR" ]]; then
    return 0
  fi

  case "$QT_PATHS_SHIM_DIR" in
    "$USER_RUNTIME_DIR"/fedora-kde-qtpaths.*)
      rm -f -- "$QT_PATHS_SHIM_DIR/qtpaths" \
        || warn "Could not remove the temporary qtpaths compatibility link."
      rmdir -- "$QT_PATHS_SHIM_DIR" \
        || warn "Could not remove the temporary directory $QT_PATHS_SHIM_DIR"
      ;;
    *)
      warn "Refusing to remove unexpected temporary path: $QT_PATHS_SHIM_DIR"
      ;;
  esac
  QT_PATHS_SHIM_DIR=""
}

rollback() {
  local index path backup existed
  local -a restored=()

  [[ "$ROLLBACK_ARMED" -eq 1 ]] || return 0
  ROLLBACK_ARMED=0
  warn "Restoring KDE configuration from $BACKUP_DIR"
  restore_hot_corner

  for index in "${!BACKUP_PATHS[@]}"; do
    path="${BACKUP_PATHS[$index]}"
    backup="${BACKUP_FILES[$index]}"
    existed="${BACKUP_EXISTED[$index]}"
    # These files are archived for manual recovery. The window-settings
    # transaction restores their live owners itself; copying over live config
    # files here would race KWin, KGlobalAccel, and Plasma.
    case "${path##*/}" in
      kwinrc|kglobalshortcutsrc|plasma-org.kde.plasma.desktop-appletsrc) continue ;;
    esac
    if [[ "$existed" -eq 1 ]]; then
      if ! mkdir -p -- "$(dirname "$path")"; then
        warn "Could not recreate the parent directory for $path"
        continue
      fi
      if ! cp -a -- "$backup" "$path"; then
        warn "Could not restore $path from $backup; manual recovery is required."
        continue
      fi
    else
      if ! rm -f -- "$path"; then
        warn "Could not remove newly created configuration file $path; manual recovery is required."
        continue
      fi
    fi
    restored+=("${path##*/}")
  done
  reload_recovered_settings "${restored[@]}"
}

reload_recovered_settings() {
  local file restored found
  # File restoration alone does not update running consumers. Never restart
  # the desktop or screen locker during recovery; use supported notifications.
  for file in "${CHANGED_CONFIGS[@]}"; do
    found=0
    for restored in "$@"; do
      [[ "$restored" == "$file" ]] && found=1
    done
    [[ "$found" == 1 ]] || continue
    case "$file" in
      kscreenlockerrc)
        if ! gdbus call --session --timeout 10 --dest org.kde.screensaver \
            --object-path /ScreenSaver --method org.kde.screensaver.configure >/dev/null 2>&1; then
          warn "Screen-lock recovery needs logout/login; the running lock policy may still differ from the restored file."
        fi ;;
      kdeglobals)
        # PaletteChanged=0, as used by Plasma's platform theme.
        gdbus emit --session --object-path /KGlobalSettings \
          --signal org.kde.KGlobalSettings.notifyChange 0 0 >/dev/null 2>&1 \
          || warn "Could not notify applications of the recovered palette."
        warn "Colour settings were restored on disk; restart applications or log out/in if their colours have not returned." ;;
      kxkbrc|kcminputrc|ksmserverrc|plasma-localerc)
        warn "Recovery of $file requires logout/login to fully restore the running session." ;;
    esac
  done
}

mark_config_changed() {
  local file
  for file in "${CHANGED_CONFIGS[@]}"; do
    [[ "$file" == "$1" ]] && return 0
  done
  CHANGED_CONFIGS+=("$1")
}

die() {
  echo "Error: $*" >&2
  cleanup_runtime_temp
  rollback
  exit 1
}

on_error() {
  local line="$1"
  local status="$2"
  trap - ERR INT TERM
  warn "Unexpected failure at line $line (exit $status)."
  cleanup_runtime_temp
  rollback
  exit "$status"
}

on_signal() {
  local signal="$1"
  local status="$2"
  trap - ERR INT TERM
  warn "Interrupted by $signal."
  cleanup_runtime_temp
  rollback
  exit "$status"
}

trap 'on_error "$LINENO" "$?"' ERR
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

validate_lock_minutes() {
  normalize_decimal "$1" 1440 >/dev/null
}

normalize_decimal() {
  local value="$1" maximum="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # Strip leading zeroes before arithmetic and bound length before conversion
  # so huge inputs cannot wrap Bash's signed integer representation.
  value="${value#"${value%%[!0]*}"}"
  [[ -n "$value" && ${#value} -le ${#maximum} ]] || return 1
  (( 10#$value <= maximum )) || return 1
  printf '%s\n' "$value"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --lock-minutes)
        (( $# >= 2 )) || die "--lock-minutes requires a value."
        LOCK_MINUTES="$(normalize_decimal "$2" 1440)" \
          || die "lock minutes must be an integer from 1 through 1440."
        LOCK_MINUTES_SET=1
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

print_dry_run() {
  cat <<PLAN
Fedora KDE settings dry-run; no commands will be executed and no files will be created.

Would:
  - require a normal-user Fedora KDE Plasma 6 Wayland session
  - ask whether to add English (UK), keeping Hungarian as the recommended default
  - configure global Plasma keyboard layout switching
  - turn Num Lock on when the Plasma session starts
  - enable automatic screen locking after $LOCK_MINUTES minutes
  - require the password immediately and always lock after resume
  - ask about Hungarian regional formats and empty-session startup
  - optionally apply Breeze Light or Breeze Dark without changing the desktop layout
  - optionally select an installed Firefox or Brave browser as the default
  - ask before installing missing Yakuake with sudo dnf install -y yakuake (default No)
  - leave Yakuake configuration, shortcuts, and autostart unchanged
  - back up and verify every KDE configuration file that would be changed
  - check KDE update, printing, networking, and Bluetooth integration
  - ask before configuring 3 desktops, Windows+arrow shortcuts, and a Pager left of the System Tray
  - preserve this entire section when declined, including settings from previous runs
  - separately ask before disabling the top-left mouse hot corner, preserving window dragging

Would not modify SDDM, X11, displays, power profiles, or services.
System package changes are limited to the confirmed Yakuake installation and its dependencies.
PLAN
}

require_fedora() {
  local fedora_version

  [[ -r /etc/os-release ]] || die "cannot verify Fedora: /etc/os-release is unavailable."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == fedora ]] \
    || die "this script supports Fedora only. Detected: ${PRETTY_NAME:-unknown}"

  fedora_version="$(rpm -E %fedora 2>/dev/null || true)"
  [[ "$fedora_version" =~ ^[0-9]+$ ]] \
    || die "could not determine the Fedora release."
}

resolve_execution_context() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] \
    || die "run this as your logged-in desktop user, not through sudo. Example: bash $SCRIPT_NAME"

  USER_NAME="$(id -un)"
  USER_ID="$(id -u)"
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  [[ -n "$USER_HOME" ]] || die "could not determine the home directory for $USER_NAME."
  [[ "$USER_HOME" == "$HOME" ]] \
    || die "HOME ($HOME) does not match the account home directory ($USER_HOME)."

  USER_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$USER_ID}"
  CONFIG_HOME="${XDG_CONFIG_HOME:-$USER_HOME/.config}"
  STATE_HOME="${XDG_STATE_HOME:-$USER_HOME/.local/state}"
  DATA_HOME="${XDG_DATA_HOME:-$USER_HOME/.local/share}"

  [[ -d "$USER_RUNTIME_DIR" ]] || die "the user runtime directory is unavailable."
  [[ "$(stat -c %u "$USER_RUNTIME_DIR" 2>/dev/null || true)" == "$USER_ID" ]] \
    || die "the user runtime directory is not owned by $USER_NAME."
  [[ -S "$USER_RUNTIME_DIR/bus" ]] \
    || die "the user D-Bus session is unavailable; run this from a logged-in Plasma session."

  if [[ -e "$CONFIG_HOME" ]]; then
    [[ -d "$CONFIG_HOME" && ! -L "$CONFIG_HOME" ]] \
      || die "the KDE configuration directory must be a real directory: $CONFIG_HOME"
    [[ "$(stat -c %u "$CONFIG_HOME" 2>/dev/null || true)" == "$USER_ID" ]] \
      || die "$CONFIG_HOME is not owned by $USER_NAME."
  fi
}

detect_session_type() {
  local session_type="${XDG_SESSION_TYPE:-}"

  if [[ -z "$session_type" && -n "${XDG_SESSION_ID:-}" ]]; then
    session_type="$(loginctl show-session "$XDG_SESSION_ID" -p Type --value 2>/dev/null || true)"
  fi
  printf '%s\n' "${session_type,,}"
}

preflight_plasma_session() {
  local desktop session_type plasma_version plasma_major

  desktop="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-}}"
  case "${desktop,,}" in
    *kde*|*plasma*) ;;
    *) die "the current desktop is ${desktop:-unknown}, not KDE Plasma." ;;
  esac

  session_type="$(detect_session_type)"
  [[ "$session_type" == wayland ]] \
    || die "the current Plasma session is ${session_type:-unknown}, not Wayland; no settings were changed."

  local cmd
  for cmd in plasmashell kwriteconfig6 kreadconfig6 flock; do
    command -v "$cmd" >/dev/null 2>&1 \
      || die "$cmd is required; run this after installing Fedora KDE Plasma 6."
  done

  pgrep -u "$USER_ID" -x plasmashell >/dev/null 2>&1 \
    || die "plasmashell is not running for $USER_NAME."

  plasma_version="$(plasmashell --version 2>/dev/null || true)"
  plasma_major="$(grep -oE '[0-9]+([.][0-9]+)+' <<< "$plasma_version" | head -n1 | cut -d. -f1 || true)"
  [[ "$plasma_major" == 6 ]] \
    || die "this script supports Plasma 6 only. Detected: ${plasma_version:-unknown}"

  if kwriteconfig6 --help 2>&1 | grep -q -- '--notify'; then
    KWRITE_NOTIFY=1
  else
    warn "kwriteconfig6 does not advertise --notify; settings will fully apply after the next login."
  fi
}

acquire_lock() {
  LOCK_FILE="$USER_RUNTIME_DIR/fedora-setup-02-kde-settings.lock"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another KDE setup process is already running for $USER_NAME."
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply

  while true; do
    if [[ "$default" == Y ]]; then
      read -r -p "$prompt [Y/n]: " reply \
        || die "input ended before setup choices were complete; no settings were changed."
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply \
        || die "input ended before setup choices were complete; no settings were changed."
      reply="${reply:-N}"
    fi

    case "$reply" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Enter y or n." ;;
    esac
  done
}

ask_lock_minutes() {
  local reply

  while true; do
    read -r -p "Lock the screen after how many inactive minutes? [30]: " reply \
      || die "input ended before setup choices were complete; no settings were changed."
    reply="${reply:-30}"
    if LOCK_MINUTES="$(normalize_decimal "$reply" 1440)"; then
      return
    fi
    echo "Enter an integer from 1 through 1440."
  done
}

ask_numbered_choice() {
  local prompt="$1"
  local default="$2"
  local maximum="$3"
  local reply

  while true; do
    read -r -p "$prompt [$default]: " reply \
      || die "input ended before setup choices were complete; no settings were changed."
    reply="${reply:-$default}"
    if reply="$(normalize_decimal "$reply" "$maximum")"; then
      printf '%s\n' "$reply"
      return
    fi
    echo "Enter a number from 1 through $maximum." >&2
  done
}

data_file_exists() {
  local relative="$1"
  local root
  local -a roots=("$DATA_HOME")
  local -a system_roots=()

  IFS=: read -r -a system_roots <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  roots+=("${system_roots[@]}")
  for root in "${roots[@]}"; do
    [[ -f "$root/$relative" ]] && return 0
  done
  return 1
}

find_browser_desktop_id() {
  local desktop_id
  for desktop_id in "$@"; do
    if data_file_exists "applications/$desktop_id"; then
      printf '%s\n' "$desktop_id"
      return 0
    fi
  done
  return 1
}

collect_color_choice() {
  local choice

  COLOR_SCHEME=leave
  command -v plasma-apply-colorscheme >/dev/null 2>&1 || return 0
  data_file_exists color-schemes/BreezeLight.colors || return 0
  data_file_exists color-schemes/BreezeDark.colors || return 0

  cat <<'CHOICES'

Color scheme:
  1. Leave unchanged
  2. Breeze Light
  3. Breeze Dark
CHOICES
  choice="$(ask_numbered_choice "Selection" 1 3)"
  case "$choice" in
    1) COLOR_SCHEME=leave ;;
    2) COLOR_SCHEME=BreezeLight ;;
    3) COLOR_SCHEME=BreezeDark ;;
  esac
}

current_default_browser() {
  command -v xdg-mime >/dev/null 2>&1 || return 0
  xdg-mime query default x-scheme-handler/https 2>/dev/null || true
}

collect_browser_choice() {
  local choice current

  FIREFOX_DESKTOP_ID="$(find_browser_desktop_id firefox.desktop org.mozilla.firefox.desktop || true)"
  BRAVE_DESKTOP_ID="$(find_browser_desktop_id brave-browser.desktop com.brave.Browser.desktop || true)"
  BROWSER_DESKTOP_ID=leave

  if [[ -z "$FIREFOX_DESKTOP_ID" && -z "$BRAVE_DESKTOP_ID" ]]; then
    return 0
  fi

  current="$(current_default_browser)"
  echo
  echo "Current default web browser: ${current:-not detected}"

  if [[ -n "$FIREFOX_DESKTOP_ID" && -n "$BRAVE_DESKTOP_ID" ]]; then
    cat <<CHOICES
Default browser:
  1. Leave unchanged
  2. Firefox
  3. Brave
CHOICES
    choice="$(ask_numbered_choice "Selection" 1 3)"
    case "$choice" in
      1) BROWSER_DESKTOP_ID=leave ;;
      2) BROWSER_DESKTOP_ID="$FIREFOX_DESKTOP_ID" ;;
      3) BROWSER_DESKTOP_ID="$BRAVE_DESKTOP_ID" ;;
    esac
  elif [[ -n "$FIREFOX_DESKTOP_ID" ]]; then
    if ask_yes_no "Make Firefox the default web browser?" N; then
      BROWSER_DESKTOP_ID="$FIREFOX_DESKTOP_ID"
    fi
  elif ask_yes_no "Make Brave the default web browser?" N; then
    BROWSER_DESKTOP_ID="$BRAVE_DESKTOP_ID"
  fi
}

collect_choices() {
  log "Collecting KDE preferences"

  if ask_yes_no "Add the English (UK) keyboard layout?" N; then
    ADD_GB=1
    if ask_yes_no "Make English (UK) the default keyboard layout?" N; then
      GB_DEFAULT=1
    fi
  fi

  if [[ "$LOCK_MINUTES_SET" -eq 0 ]]; then
    ask_lock_minutes
  else
    echo "Automatic screen-lock delay: $LOCK_MINUTES minutes (from --lock-minutes)"
  fi

  if ask_yes_no "Use Hungarian regional formats for dates, time, numbers, and currency?" Y; then
    USE_HUNGARIAN_FORMATS=1
  fi

  if ask_yes_no "Start Plasma with an empty session instead of reopening applications?" Y; then
    USE_EMPTY_SESSION=1
  fi

  collect_color_choice
  collect_browser_choice
  collect_window_settings_choice
  collect_hot_corner_choice
  collect_yakuake_choice
}

collect_yakuake_choice() {
  if rpm_installed yakuake; then
    YAKUAKE_STATUS="already installed"
    echo "[skip] Yakuake already installed"
  elif ask_yes_no "Install Yakuake drop-down terminal? (installation only; requires sudo)" N; then
    INSTALL_YAKUAKE=1
  fi
}

install_yakuake() {
  local cmd

  [[ "$DRY_RUN" -eq 0 && "$INSTALL_YAKUAKE" -eq 1 ]] || return 0
  if rpm_installed yakuake; then
    YAKUAKE_STATUS="already installed"
    echo "[skip] Yakuake already installed"
    return 0
  fi

  YAKUAKE_STATUS="installation failed"
  for cmd in sudo dnf; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "$cmd is required for optional Yakuake installation; continuing KDE setup."
      ADVISORIES+=("Yakuake was not installed: $cmd is unavailable.")
      return 0
    fi
  done

  log "Installing Yakuake (installation only)"
  if ! sudo dnf install -y yakuake; then
    warn "Optional Yakuake installation failed; continuing KDE setup."
    ADVISORIES+=("Yakuake installation failed; retry with sudo dnf install -y yakuake.")
  elif ! rpm_installed yakuake; then
    warn "Could not verify Yakuake installation; continuing KDE setup."
    ADVISORIES+=("DNF completed, but the yakuake RPM was not found.")
  else
    YAKUAKE_STATUS="installed"
  fi
}

collect_hot_corner_choice() {
  echo
  echo "This leaves Overview keyboard shortcuts and dragging windows to the top/sides unchanged."
  if ask_yes_no "Disable the top-left hot corner (mouse activation)?" N; then
    if command -v gdbus >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      DISABLE_TOP_LEFT=1
    else
      HOT_CORNER_STATUS="skipped: gdbus or python3 unavailable"
      ADVISORIES+=("$HOT_CORNER_STATUS; no hot-corner settings will be changed.")
    fi
  fi
}

# ElectricTopLeft=7; ELECTRIC_COUNT=8; ElectricNone=9. Remove only the requested corner,
# retaining the original representation when no change is necessary.
# KDE definitions: src/effect/globals.h and
# src/kcms/screenedges/kwinscreenedgesettings.kcfg (Plasma 6).
without_top_left() {
  local value="$1" edge result="" removed=0
  local -a edges=()
  [[ "$value" =~ ^[[:space:]0-9,]*$ ]] || return 1
  IFS=, read -r -a edges <<< "$value"
  for edge in "${edges[@]}"; do
    edge="${edge//[[:space:]]/}"
    [[ -n "$edge" ]] || continue
    [[ "$edge" =~ ^[0-7]$ || "$edge" == 9 ]] || return 1
    if [[ "$edge" == 7 ]]; then
      removed=1
    else
      result+="${result:+,}$edge"
    fi
  done
  if [[ "$removed" == 0 ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "${result:-9}"
  fi
}

# Discover standard configurable BorderActivate entries, including installed
# effects/scripts whose default has not yet produced a local kwinrc group.
# Only metadata is read: third-party JavaScript is never executed by setup.
discover_hot_corner_entries() {
  python3 - "$CONFIG_HOME" "$DATA_HOME" <<'EDGES_PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys

groups = set()
metadata = {}
safe_id = re.compile(r"[A-Za-z0-9_.-]+\Z")
config_roots = [Path(p) for p in os.environ.get("XDG_CONFIG_DIRS", "/etc/xdg").split(":") if p]
config_roots.append(Path(sys.argv[1]))
for root in config_roots:
    path = root / "kwinrc"
    if not path.exists():
        continue
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"\[(Effect|Script)-([A-Za-z0-9_.-]+)\](?:\[\$i\])?", line.strip())
        if match:
            groups.add(match[1] + "-" + match[2])

# First data root wins, matching XDG lookup precedence.
roots = [Path(sys.argv[2])] + [Path(p) for p in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":") if p]
for root in roots:
    for prefix in ("kwin-wayland", "kwin"):
        for category, kind in (("builtin-effects", "Effect"), ("effects", "Effect"), ("scripts", "Script")):
            directory = root / prefix / category
            pattern = "*.json" if category == "builtin-effects" else "*/metadata.json"
            for path in sorted(directory.glob(pattern)):
                try:
                    data = json.loads(path.read_text())
                    plugin = data.get("KPlugin", {})
                    ident = plugin.get("Id", path.stem if category == "builtin-effects" else path.parent.name)
                    if not isinstance(ident, str) or not safe_id.fullmatch(ident):
                        raise ValueError("unsupported plugin identifier")
                    metadata.setdefault(kind + "-" + ident, data)
                except (ValueError, OSError) as exc:
                    print("Unsupported " + str(path).replace("\n", " ") + ": " + str(exc).replace("\n", " "))

for group, data in metadata.items():
    if data.get("X-KWin-Border-Activate") is True:
        groups.add(group)
    elif group.startswith("Script-"):
        ident = group[len("Script-"):]
        default = "true" if data.get("KPlugin", {}).get("EnabledByDefault", False) else "false"
        enabled = subprocess.check_output(["kreadconfig6", "--file", "kwinrc", "--group", "Plugins",
                                           "--key", ident + "Enabled", "--default", default], text=True).strip()
        if enabled.lower() == "true":
            print("Unsupported " + group + " is enabled without standard screen-edge metadata")
for group in sorted(groups - {"Effect-overview", "Effect-windowview"}):
    if group.startswith("Script-") and group not in metadata:
        print("Unsupported " + group + " has no discoverable metadata; its running behaviour cannot be verified")
    print(group + " BorderActivate")
EDGES_PY
}

reload_hot_corner() {
  local effect
  gdbus call --session --timeout 10 --dest org.kde.KWin --object-path /KWin \
    --method org.kde.KWin.reconfigure >/dev/null || return 1
  for effect in "${HOT_CORNER_EFFECTS[@]}"; do
    gdbus call --session --timeout 10 --dest org.kde.KWin --object-path /Effects \
      --method org.kde.kwin.Effects.reconfigureEffect "$effect" >/dev/null || return 1
  done
}

restore_hot_corner() {
  [[ "$HOT_CORNER_ARMED" == 1 ]] || return 0
  HOT_CORNER_ARMED=0
  local i value
  for i in "${!HOT_CORNER_KEYS[@]}"; do
    value="${HOT_CORNER_OLD[$i]}"
    if [[ "$value" == __missing__ ]]; then
      kwriteconfig6 --file kwinrc --group "${HOT_CORNER_GROUPS[$i]}" \
        --key "${HOT_CORNER_KEYS[$i]}" --delete \
        || warn "Could not remove newly added hot-corner entry."
    else
      kwriteconfig6 --file kwinrc --group "${HOT_CORNER_GROUPS[$i]}" \
        --key "${HOT_CORNER_KEYS[$i]}" -- "$value" \
        || warn "Could not restore hot-corner entry."
    fi
    if [[ "$(read_kde_value kwinrc "${HOT_CORNER_GROUPS[$i]}" "${HOT_CORNER_KEYS[$i]}")" != "$value" ]]; then
      warn "Hot-corner recovery verification failed; consult $BACKUP_DIR."
    fi
  done
  reload_hot_corner || warn "Could not reload recovered hot-corner settings; log out and back in."
  if [[ "$HOT_CORNER_PENDING" == 1 ]]; then
    warn "Custom screen-edge recovery may require logout/login; running scripts were not restarted."
  fi
}

configure_hot_corner() {
  [[ "$DISABLE_TOP_LEFT" == 1 ]] || return 0
  local group key old desired i extras
  local -a desired_values=()
  if ! extras="$(discover_hot_corner_entries)"; then
    HOT_CORNER_STATUS="skipped: screen-edge discovery failed"
    ADVISORIES+=("$HOT_CORNER_STATUS; no hot-corner settings were changed.")
    return 0
  fi
  # Build the complete change list before writing. Missing Overview entries
  # mean the built-in top-left default, so write an explicit ElectricNone.
  while read -r group key; do
    [[ -n "$group" ]] || continue
    if [[ "$group" == Unsupported ]]; then
      HOT_CORNER_PENDING=1
      ADVISORIES+=("Unverified screen-edge activation: $key. Check this in KDE settings; setup will not execute or restart unknown scripts.")
      continue
    fi
    old="$(read_kde_value kwinrc "$group" "$key")"
    if [[ "$group" == Script-* && "$old" != __missing__ ]]; then
      HOT_CORNER_PENDING=1
      ADVISORIES+=("[$group] uses a script-owned corner: log out/in if it is still active; setup does not restart scripts.")
    fi
    if [[ "$group" == ElectricBorders ]]; then
      desired=None
    elif [[ "$old" == __missing__ ]]; then
      [[ "$group/$key" == Effect-overview/BorderActivate ]] || continue
      desired=9
    else
      if ! desired="$(without_top_left "$old")"; then
        die "unrecognised hot-corner value in [$group] $key; no hot-corner settings were changed."
      fi
    fi
    [[ "$old" != "$desired" ]] || continue
    HOT_CORNER_GROUPS+=("$group")
    HOT_CORNER_KEYS+=("$key")
    HOT_CORNER_OLD+=("$old")
    desired_values+=("$desired")
    case "$group" in
      Effect-overview|Effect-windowview) ;;
      Effect-*) HOT_CORNER_EFFECTS+=("${group#Effect-}") ;;
      Script-*)
        HOT_CORNER_PENDING=1
        ADVISORIES+=("Removed top-left from [$group] on disk; log out/in to reload this script safely.") ;;
    esac
  done <<ENTRIES
ElectricBorders TopLeft
Effect-overview BorderActivate
Effect-overview GridBorderActivate
Effect-windowview BorderActivate
Effect-windowview BorderActivateAll
Effect-windowview BorderActivateClass
TabBox BorderActivate
TabBox BorderAlternativeActivate
$extras
ENTRIES

  if (( ${#desired_values[@]} > 0 )); then
    HOT_CORNER_ARMED=1
    for i in "${!desired_values[@]}"; do
      set_kde_value kwinrc "${HOT_CORNER_GROUPS[$i]}" "${HOT_CORNER_KEYS[$i]}" string "${desired_values[$i]}"
    done
  fi
  reload_hot_corner || die "could not reload hot-corner settings; attempting targeted recovery."
  HOT_CORNER_STATUS="standard mouse actions disabled; window dragging unchanged"
  if [[ "$HOT_CORNER_PENDING" == 1 ]]; then
    HOT_CORNER_STATUS="supported assignments saved; custom activation needs logout/login or manual review"
  fi
}

collect_window_settings_choice() {
  local count panel_count selection index
  local -a panels=()

  echo
  echo "Overwrite some window and virtual desktop settings?"
  echo "Configure 3 desktops in one row and place their Pager left of the System Tray."
  echo "Windows+Left/Right: previous/next desktop."
  echo "Windows+Shift+Left/Right: move the active window to the previous/next desktop."
  echo "Windows+Up/Down: maximise/minimise. Conflicting shortcuts will be replaced."
  if ! ask_yes_no "Apply these window and virtual desktop settings?" N; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1 \
      || ! python3 -c 'import dbus' >/dev/null 2>&1; then
    WINDOW_SETTINGS_STATUS="skipped: python3 and python3-dbus are required"
    ADVISORIES+=("$WINDOW_SETTINGS_STATUS for the optional window/desktop section.")
    return 0
  fi
  if ! WINDOW_SNAPSHOT="$(window_settings_helper inspect)"; then
    WINDOW_SETTINGS_STATUS="skipped: required KDE session interfaces unavailable"
    ADVISORIES+=("$WINDOW_SETTINGS_STATUS; no window/desktop settings changed.")
    return 0
  fi

  count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["desktops"]))' "$WINDOW_SNAPSHOT")"
  if (( count > 3 )); then
    echo "There are $count desktops. Reducing to 3 reassigns windows from removed desktops."
    echo "Backups cannot fully undo those window assignments or restore removed desktop identities."
    if ask_yes_no "Reduce the existing desktop count to 3?" N; then
      WINDOW_REDUCE_DESKTOPS=1
    fi
  fi

  mapfile -t panels < <(python3 -c '
import json,sys
for p in json.loads(sys.argv[1])["panels"]:
    print(str(p["id"]) + ": screen " + str(p["screen"]) + ", " + p["location"] + " panel")
' "$WINDOW_SNAPSHOT")
  panel_count="${#panels[@]}"
  if (( panel_count == 1 )); then
    WINDOW_PANEL_ID="${panels[0]%%:*}"
  elif (( panel_count > 1 )); then
    echo "Choose the panel for the desktop switcher:"
    for index in "${!panels[@]}"; do
      echo "  $((index + 1)). Panel ${panels[$index]}"
    done
    echo "  $((panel_count + 1)). Leave panels unchanged"
    selection="$(ask_numbered_choice "Panel" "$((panel_count + 1))" "$((panel_count + 1))")"
    if (( selection <= panel_count )); then
      WINDOW_PANEL_ID="${panels[$((selection - 1))]%%:*}"
    fi
  fi
  if [[ "$WINDOW_PANEL_ID" == -1 ]]; then
    ADVISORIES+=("Pager placement skipped: no unambiguous, unlocked horizontal panel selected (one tray and at most one Pager required).")
  fi
  USE_WINDOW_SETTINGS=1
}

configure_window_settings() {
  [[ "$USE_WINDOW_SETTINGS" -eq 1 ]] || return 0
  log "Configuring windows, virtual desktops, and the panel Pager"
  if ! WINDOW_SETTINGS_STATUS="$(window_settings_helper apply "$WINDOW_SNAPSHOT" \
      "$WINDOW_PANEL_ID" "$WINDOW_REDUCE_DESKTOPS" "$BACKUP_DIR")"; then
    die "window/desktop configuration failed; see the recovery messages above and backups in $BACKUP_DIR."
  fi
  echo "$WINDOW_SETTINGS_STATUS"
}

# Embedded so this SH script can still be copied and run on its own.
# Uses the session D-Bus API, including multi-chord shortcut serialization.
# References:
# https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml
# https://github.com/KDE/kwin/blob/master/src/dbusinterface.h
# https://develop.kde.org/docs/plasma/scripting/api/
window_settings_helper() {
  python3 - "$@" <<'PY'
import json
import os
import signal
import sys
import time

import dbus

META, SHIFT = 0x10000000, 0x02000000
LEFT, UP, RIGHT, DOWN = 0x01000012, 0x01000013, 0x01000014, 0x01000015
TARGETS = {
    "Switch to Previous Desktop": META | LEFT,
    "Switch to Next Desktop": META | RIGHT,
    "Window to Previous Desktop": META | SHIFT | LEFT,
    "Window to Next Desktop": META | SHIFT | RIGHT,
    "Window Maximize": META | UP,
    "Window Minimize": META | DOWN,
}
KEYS = set(TARGETS.values())
VD = "org.kde.KWin.VirtualDesktopManager"
PROPS = "org.freedesktop.DBus.Properties"
PAGER = "org.kde.plasma.pager"
TRAY = "org.kde.plasma.systemtray"
PANEL_QUERY = """
function panelData(p) {
    var ws = p.widgets().map(function(w) {
        return {id:w.id, type:w.type, index:w.index};
    });
    ws.sort(function(a,b) { return a.index-b.index; });
    return {id:p.id, screen:p.screen, location:p.location,
            formFactor:p.formFactor, locked:p.locked, widgets:ws};
}
"""


def sequences(value):
    return sorted({tuple(int(k) for k in seq[0] if int(k)) for seq in value} - {()})


def eligible(p):
    ws = p["widgets"]
    return (not p["locked"] and p["screen"] >= 0 and p["formFactor"] == "horizontal"
            and sum(w["type"] == TRAY for w in ws) == 1
            and sum(w["type"] == PAGER for w in ws) <= 1
            and [w["index"] for w in ws] == list(range(len(ws))))


class KDE:
    def __init__(self):
        bus = dbus.SessionBus()
        for name in ("org.kde.KWin", "org.kde.kglobalaccel"):
            if not bus.name_has_owner(name):
                raise RuntimeError(name + " is not running")
        obj = bus.get_object("org.kde.KWin", "/VirtualDesktopManager")
        self.props = dbus.Interface(obj, PROPS)
        self.vd = dbus.Interface(obj, VD)
        accel_obj = bus.get_object("org.kde.kglobalaccel", "/kglobalaccel")
        self.accel = dbus.Interface(accel_obj, "org.kde.KGlobalAccel")
        xml = str(dbus.Interface(accel_obj, "org.freedesktop.DBus.Introspectable").Introspect())
        if "setForeignShortcutKeys" not in xml:
            raise RuntimeError("KGlobalAccel does not support the required shortcut API")
        self.plasma = None
        if bus.name_has_owner("org.kde.plasmashell"):
            self.plasma = dbus.Interface(bus.get_object("org.kde.plasmashell", "/PlasmaShell"),
                                         "org.kde.PlasmaShell")

    def desktop_state(self):
        state = self.props.GetAll(VD)
        return {"desktops": [[int(d[0]), str(d[1]), str(d[2])] for d in state["desktops"]],
                "rows": int(state["rows"]), "current": str(state["current"])}

    def script(self, code):
        if self.plasma is None:
            raise RuntimeError("Plasma scripting is unavailable")
        result = str(self.plasma.evaluateScript(PANEL_QUERY + code, timeout=20))
        # D-Bus success alone does not exclude an embedded JavaScript error.
        lines = [line[6:] for line in result.splitlines() if line.startswith("SETUP:")]
        if len(lines) != 1:
            raise RuntimeError("Plasma script did not return a verified result: " + result)
        return json.loads(lines[0])

    def panels(self):
        return self.script('print("SETUP:" + JSON.stringify(panels().map(panelData)));')

    def shortcut(self, action):
        return sequences(self.accel.shortcutKeys(dbus.Array(action, signature="s")))

    def set_shortcut(self, action, keys):
        if self.shortcut(action) == sorted(keys):
            return
        wire = dbus.Array([dbus.Struct((dbus.Array(k, signature="i"),), signature="ai")
                           for k in keys], signature="(ai)")
        self.accel.setForeignShortcutKeys(dbus.Array(action, signature="s"), wire)
        if self.shortcut(action) != sorted(keys):
            raise RuntimeError("Shortcut verification failed: " + action[1])

    def inspect(self):
        state = self.desktop_state()
        state["shortcuts"] = []
        found = set()
        for component in self.accel.allMainComponents():
            for raw in self.accel.allActionsForComponent(component):
                action = [str(s) for s in raw]
                keys = self.shortcut(action)
                target = action[0] == "kwin" and action[1] in TARGETS
                if target:
                    found.add(action[1])
                if target or any(k[0] in KEYS for k in keys):
                    state["shortcuts"].append({"action": action, "keys": [list(k) for k in keys]})
        state["shortcuts"].sort(key=lambda item: item["action"][:2])
        if found != set(TARGETS):
            raise RuntimeError("Required KWin actions missing: " + str(set(TARGETS) - found))
        try:
            state["panels"] = sorted((p for p in self.panels() if eligible(p)), key=lambda p: p["id"])
            if not self.script('print("SETUP:"+JSON.stringify(knownWidgetTypes.indexOf("org.kde.plasma.pager") >= 0));'):
                print("Pager placement unavailable: the Pager widget is not installed.", file=sys.stderr)
                state["panels"] = []
        except Exception as exc:
            print("Pager placement unavailable: " + str(exc), file=sys.stderr)
            state["panels"] = []
        return state

    def change_shortcuts(self, saved):
        changes = []
        for item in saved:
            action = item["action"]
            kept = [tuple(k) for k in item["keys"] if k[0] not in KEYS]
            desired = list(kept)
            if action[0] == "kwin" and action[1] in TARGETS:
                desired.append((TARGETS[action[1]],))
            if self.shortcut(action) != sorted(desired):
                changes.append((action, kept, desired))
        # Release conflicts before assigning their new owners.
        for action, kept, desired in changes:
            self.set_shortcut(action, kept)
        for action, kept, desired in changes:
            self.set_shortcut(action, desired)

    def change_panel(self, original):
        pid = original["id"]
        existing = [w for w in original["widgets"] if w["type"] == PAGER]
        if not existing:
            self.script('var p=panelById(' + str(pid) + ');'
                        'var w=p.addWidget("org.kde.plasma.pager");'
                        'print("SETUP:"+JSON.stringify(w.id));')
        # Wait for the panel to assign the new widget's layout index.
        for _ in range(20):
            panel = next(p for p in self.panels() if p["id"] == pid)
            pager = [w for w in panel["widgets"] if w["type"] == PAGER]
            if len(pager) == 1 and pager[0]["index"] >= 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Plasma did not place the new Pager")
        tray = next(w for w in panel["widgets"] if w["type"] == TRAY)
        dest = tray["index"] - (1 if pager[0]["index"] < tray["index"] else 0)
        if pager[0]["index"] != dest:
            self.script('var p=panelById(' + str(pid) + ');'
                        'p.widgetById(' + str(pager[0]["id"]) + ').index=' + str(dest) + ';'
                        'print("SETUP:true");')
        expected = [w["id"] for w in original["widgets"] if w["type"] != PAGER]
        expected.insert(expected.index(tray["id"]), pager[0]["id"])
        for _ in range(20):
            result = next(p for p in self.panels() if p["id"] == pid)
            if [w["id"] for w in result["widgets"]] == expected:
                return
            time.sleep(0.1)
        raise RuntimeError("Pager order verification failed")

    def change_desktops(self, count):
        current = self.desktop_state()["desktops"]
        while len(current) < count:
            self.vd.createDesktop(dbus.UInt32(len(current)), "")
            updated = self.desktop_state()["desktops"]
            if len(updated) != len(current) + 1:
                raise RuntimeError("Could not create a virtual desktop")
            current = updated
        while len(current) > count:
            self.vd.removeDesktop(current[-1][1])
            updated = self.desktop_state()["desktops"]
            if len(updated) != len(current) - 1:
                raise RuntimeError("Could not remove a virtual desktop")
            current = updated
        if self.desktop_state()["rows"] != 1:
            self.props.Set(VD, "rows", dbus.UInt32(1))
        result = self.desktop_state()
        if len(result["desktops"]) != count or result["rows"] != 1:
            raise RuntimeError("Virtual-desktop verification failed")

    def restore(self, saved, panel, touched):
        errors = []
        if touched["desktops"]:
            try:
                before_ids = {d[1] for d in saved["desktops"]}
                self.change_desktops(len(saved["desktops"]))
                restored = self.desktop_state()["desktops"]
                for old, new in zip(saved["desktops"], restored):
                    self.vd.setDesktopName(new[1], old[2])
                self.props.Set(VD, "rows", dbus.UInt32(saved["rows"]))
                if saved["current"] in {d[1] for d in restored}:
                    self.props.Set(VD, "current", saved["current"])
                if before_ids != {d[1] for d in restored}:
                    errors.append("Removed desktops were recreated with new identities; review window assignments.")
            except Exception as exc:
                errors.append("Desktop recovery: " + str(exc))
        if touched["shortcuts"]:
            # Recover other actions even if one component has disappeared.
            for clearing in (True, False):
                for item in saved["shortcuts"]:
                    try:
                        keys = [] if clearing else [tuple(k) for k in item["keys"]]
                        self.set_shortcut(item["action"], keys)
                    except Exception as exc:
                        errors.append("Shortcut recovery: " + str(exc))
        if touched["panel"]:
            try:
                self.script("""
var saved = """ + json.dumps(panel) + """;
var p = panelById(saved.id);
var ids = saved.widgets.map(function(w) { return w.id; });
p.widgets().forEach(function(w) {
    if (w.type === "org.kde.plasma.pager" && ids.indexOf(w.id) < 0) w.remove();
});
for (var i=0; i<ids.length-1; ++i) p.widgetById(ids[i]).index=i;
print("SETUP:true");
""")
                for _ in range(20):
                    restored = next(p for p in self.panels() if p["id"] == panel["id"])
                    if [w["id"] for w in restored["widgets"]] == [w["id"] for w in panel["widgets"]]:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("Original widget order did not return")
            except Exception as exc:
                errors.append("Panel recovery: " + str(exc))
        for error in errors:
            print("WARNING: " + error, file=sys.stderr)
        if not errors:
            print("Restored the previous live window/desktop settings.", file=sys.stderr)


def apply(kde, saved, panel_id, reduce, backup_dir):
    # Refuse changes based on a stale snapshot from the preference questions.
    now = kde.inspect()
    if now != saved:
        raise RuntimeError("KDE settings changed during setup; rerun to review the current state.")
    panel = next((p for p in saved["panels"] if p["id"] == panel_id), None)
    if panel_id != -1 and panel is None:
        raise RuntimeError("The selected panel is no longer available")
    recovery_path = os.path.join(backup_dir, "window-settings-live.json")
    with open(recovery_path, "x", encoding="utf-8") as stream:
        os.chmod(recovery_path, 0o600)
        json.dump(saved, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    touched = {"desktops": False, "shortcuts": False, "panel": False}

    def interrupted(signum, frame):
        raise RuntimeError("Window/desktop setup interrupted by signal " + str(signum))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        touched["shortcuts"] = True
        kde.change_shortcuts(saved["shortcuts"])
        if panel is not None:
            touched["panel"] = True
            kde.change_panel(panel)
        count = len(saved["desktops"])
        target_count = 3 if count <= 3 or reduce else count
        touched["desktops"] = True
        # Desktop removal happens last; it can reassign windows and identities.
        kde.change_desktops(target_count)
    except BaseException:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        kde.restore(saved, panel, touched)
        raise
    desktop_result = "3 desktops in one row" if target_count == 3 else str(target_count) + " desktops retained in one row"
    print("Applied: " + desktop_result + "; Windows+arrow shortcuts; "
          + ("Pager left of System Tray." if panel else "panel unchanged."))


def main():
    kde = KDE()
    if sys.argv[1] == "inspect":
        print(json.dumps(kde.inspect()))
    elif sys.argv[1] == "apply":
        apply(kde, json.loads(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1", sys.argv[5])
    else:
        raise RuntimeError("Unknown window-settings operation")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Window/desktop settings: " + str(exc), file=sys.stderr)
        sys.exit(1)
PY
}

xkb_layout_exists() {
  local layout="$1"
  local rules_file

  for rules_file in /usr/share/X11/xkb/rules/evdev.lst /usr/share/X11/xkb/rules/base.lst; do
    [[ -r "$rules_file" ]] || continue
    awk -v wanted="$layout" '
      /^! layout/ { in_layouts=1; next }
      /^!/ && in_layouts { exit }
      in_layouts && $1 == wanted { found=1; exit }
      END { exit found ? 0 : 1 }
    ' "$rules_file" && return 0
  done
  return 1
}

hungarian_locale_available() {
  local locale_name normalized

  while IFS= read -r locale_name; do
    normalized="${locale_name,,}"
    normalized="${normalized//./}"
    normalized="${normalized//-/}"
    [[ "$normalized" == hu_huutf8 ]] && return 0
  done < <(locale -a 2>/dev/null)
  return 1
}

validate_choices() {
  xkb_layout_exists hu \
    || die "the installed XKB rules do not contain the Hungarian layout; no settings were changed."
  if [[ "$ADD_GB" -eq 1 ]]; then
    xkb_layout_exists gb \
      || die "the installed XKB rules do not contain the English (UK) layout; no settings were changed."
  fi

  if [[ "$USE_HUNGARIAN_FORMATS" -eq 1 ]] && ! hungarian_locale_available; then
    warn "hu_HU.UTF-8 is unavailable; Hungarian regional formats will be skipped."
    ADVISORIES+=("Hungarian regional formats were skipped because hu_HU.UTF-8 is unavailable.")
    USE_HUNGARIAN_FORMATS=0
  fi

  if [[ "$BROWSER_DESKTOP_ID" != leave ]]; then
    command -v xdg-mime >/dev/null 2>&1 \
      || die "xdg-mime is required to configure the selected default browser."
  fi
}

add_backup_target() {
  local path="$1"
  local index backup_name backup_path

  [[ "$path" == "$CONFIG_HOME/"* || "$path" == "$DATA_HOME/applications/"* ]] \
    || die "refusing unexpected backup target: $path"
  [[ ! -L "$path" ]] \
    || die "refusing to modify symlinked KDE configuration: $path"
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || die "configuration target is not a regular file: $path"
    [[ "$(stat -c %u "$path" 2>/dev/null || true)" == "$USER_ID" ]] \
      || die "configuration file is not owned by $USER_NAME: $path"
  fi

  index="${#BACKUP_PATHS[@]}"
  backup_name="$(printf '%02d-%s' "$index" "$(basename "$path")")"
  backup_path="$BACKUP_DIR/$backup_name"
  BACKUP_PATHS+=("$path")
  BACKUP_FILES+=("$backup_path")

  if [[ -e "$path" ]]; then
    cp -a -- "$path" "$backup_path"
    BACKUP_EXISTED+=(1)
    printf '%s\t%s\n' "$path" "$backup_name" >> "$BACKUP_DIR/manifest.tsv"
  else
    BACKUP_EXISTED+=(0)
    printf '%s\t%s\n' "$path" '<did-not-exist>' >> "$BACKUP_DIR/manifest.tsv"
  fi
}

prepare_backups() {
  local stamp

  log "Backing up KDE configuration"
  stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="$STATE_HOME/fedora-setup/kde-backups/${stamp}-$$"
  mkdir -p -- "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  : > "$BACKUP_DIR/manifest.tsv"
  chmod 0600 "$BACKUP_DIR/manifest.tsv"

  add_backup_target "$CONFIG_HOME/kxkbrc"
  add_backup_target "$CONFIG_HOME/kcminputrc"
  add_backup_target "$CONFIG_HOME/kscreenlockerrc"
  add_backup_target "$CONFIG_HOME/ksmserverrc"

  if [[ "$USE_WINDOW_SETTINGS" -eq 1 || "$DISABLE_TOP_LEFT" -eq 1 ]]; then
    add_backup_target "$CONFIG_HOME/kwinrc"
  fi
  if [[ "$USE_WINDOW_SETTINGS" -eq 1 ]]; then
    add_backup_target "$CONFIG_HOME/kglobalshortcutsrc"
    if [[ "$WINDOW_PANEL_ID" != -1 ]]; then
      add_backup_target "$CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"
    fi
  fi

  if [[ "$USE_HUNGARIAN_FORMATS" -eq 1 ]]; then
    add_backup_target "$CONFIG_HOME/plasma-localerc"
  fi
  if [[ "$COLOR_SCHEME" != leave ]]; then
    add_backup_target "$CONFIG_HOME/kdeglobals"
  fi
  if [[ "$BROWSER_DESKTOP_ID" != leave ]]; then
    add_backup_target "$CONFIG_HOME/mimeapps.list"
    add_backup_target "$DATA_HOME/applications/mimeapps.list"
  fi

  ROLLBACK_ARMED=1
  echo "Backup: $BACKUP_DIR"
}

read_kde_value() {
  local file="$1"
  local group="$2"
  local key="$3"
  kreadconfig6 --file "$file" --group "$group" --key "$key" --default '__missing__'
}

set_kde_value() {
  local file="$1"
  local group="$2"
  local key="$3"
  local type="$4"
  local value="$5"
  local actual
  local -a command=(kwriteconfig6 --file "$file" --group "$group" --key "$key")

  if [[ "$type" == bool ]]; then
    command+=(--type bool)
  fi
  if [[ "$KWRITE_NOTIFY" -eq 1 ]]; then
    command+=(--notify)
  fi

  actual="$(read_kde_value "$file" "$group" "$key")"
  if [[ "$actual" == "$value" ]]; then
    echo "[skip] $file [$group] $key already equals $value"
    return 0
  fi

  command+=(-- "$value")
  mark_config_changed "$file"
  "${command[@]}"

  actual="$(read_kde_value "$file" "$group" "$key")"
  [[ "$actual" == "$value" ]] \
    || die "failed to verify $file [$group] $key (expected '$value', got '$actual')."
}

configure_keyboard_layouts() {
  local layouts variants display_names default_layout

  log "Configuring Plasma Wayland keyboard layouts"
  if [[ "$ADD_GB" -eq 0 ]]; then
    layouts=hu
    variants=""
    display_names=""
    default_layout="Hungarian"
  elif [[ "$GB_DEFAULT" -eq 1 ]]; then
    layouts=gb,hu
    variants=,
    display_names=,
    default_layout="English (UK)"
  else
    layouts=hu,gb
    variants=,
    display_names=,
    default_layout="Hungarian"
  fi

  set_kde_value kxkbrc Layout Use bool true
  set_kde_value kxkbrc Layout SwitchMode string Global
  set_kde_value kxkbrc Layout LayoutList string "$layouts"
  set_kde_value kxkbrc Layout VariantList string "$variants"
  set_kde_value kxkbrc Layout DisplayNames string "$display_names"

  echo "Keyboard layouts: $layouts (default: $default_layout)"
}

configure_numlock() {
  log "Turning Num Lock on at Plasma startup"
  # Plasma NumLockState: 0=on, 1=off, 2=leave unchanged.
  set_kde_value kcminputrc Keyboard NumLock string 0
}

configure_screen_locking() {
  log "Configuring screen locking"
  set_kde_value kscreenlockerrc Daemon Autolock bool true
  set_kde_value kscreenlockerrc Daemon Timeout string "$LOCK_MINUTES"
  set_kde_value kscreenlockerrc Daemon RequirePassword bool true
  set_kde_value kscreenlockerrc Daemon LockGrace string 0
  set_kde_value kscreenlockerrc Daemon LockOnResume bool true
}

configure_session() {
  log "Configuring Plasma session behavior"
  set_kde_value ksmserverrc General confirmLogout bool true
  if [[ "$USE_EMPTY_SESSION" -eq 1 ]]; then
    set_kde_value ksmserverrc General loginMode string emptySession
  else
    echo "[skip] Keeping the existing Plasma session restoration mode"
  fi
}

configure_regional_formats() {
  [[ "$USE_HUNGARIAN_FORMATS" -eq 1 ]] || return 0
  log "Configuring Hungarian regional formats"
  set_kde_value plasma-localerc Formats LANG string hu_HU.UTF-8
}

configure_color_scheme() {
  local actual

  [[ "$COLOR_SCHEME" != leave ]] || return 0
  log "Applying Plasma color scheme: $COLOR_SCHEME"
  command -v plasma-apply-colorscheme >/dev/null 2>&1 \
    || die "plasma-apply-colorscheme disappeared after preflight."
  mark_config_changed kdeglobals
  plasma-apply-colorscheme "$COLOR_SCHEME"
  actual="$(read_kde_value kdeglobals General ColorScheme)"
  [[ "$actual" == "$COLOR_SCHEME" ]] \
    || die "failed to verify the Plasma color scheme (expected '$COLOR_SCHEME', got '$actual')."
}

prepare_xdg_mime_environment() {
  local qtpaths_command=""

  if command -v qtpaths >/dev/null 2>&1; then
    return 0
  elif command -v qtpaths6 >/dev/null 2>&1; then
    qtpaths_command="$(command -v qtpaths6)"
  elif command -v qtpaths-qt6 >/dev/null 2>&1; then
    qtpaths_command="$(command -v qtpaths-qt6)"
  else
    warn "Qt's qtpaths command was not found; xdg-mime will use its generic fallback."
    return 0
  fi

  QT_PATHS_SHIM_DIR="$(mktemp -d "$USER_RUNTIME_DIR/fedora-kde-qtpaths.XXXXXX")"
  ln -s -- "$qtpaths_command" "$QT_PATHS_SHIM_DIR/qtpaths"
}

run_xdg_mime() {
  if [[ -n "$QT_PATHS_SHIM_DIR" ]]; then
    PATH="$QT_PATHS_SHIM_DIR:$PATH" xdg-mime "$@"
  else
    xdg-mime "$@"
  fi
}

configure_default_browser() {
  local mime actual
  local -a browser_mimes=(
    x-scheme-handler/http
    x-scheme-handler/https
    text/html
    application/xhtml+xml
  )

  [[ "$BROWSER_DESKTOP_ID" != leave ]] || return 0
  log "Configuring default browser: $BROWSER_DESKTOP_ID"

  prepare_xdg_mime_environment

  for mime in "${browser_mimes[@]}"; do
    actual="$(run_xdg_mime query default "$mime" 2>/dev/null || true)"
    if [[ "$actual" == "$BROWSER_DESKTOP_ID" ]]; then
      echo "[skip] $mime already uses $BROWSER_DESKTOP_ID"
      continue
    fi

    run_xdg_mime default "$BROWSER_DESKTOP_ID" "$mime"
    actual="$(run_xdg_mime query default "$mime" 2>/dev/null || true)"
    [[ "$actual" == "$BROWSER_DESKTOP_ID" ]] \
      || die "failed to verify the default application for $mime (got '${actual:-none}')."
  done

  cleanup_runtime_temp
}

rpm_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

check_desktop_integrations() {
  log "Checking KDE desktop integrations"

  if ! command -v plasma-discover >/dev/null 2>&1; then
    ADVISORIES+=("Plasma Discover was not found.")
  else
    rpm_installed plasma-discover-packagekit \
      || ADVISORIES+=("Discover's PackageKit backend package was not found.")
    rpm_installed plasma-discover-notifier \
      || ADVISORIES+=("Discover's update notifier package was not found.")
    if command -v flatpak >/dev/null 2>&1; then
      rpm_installed plasma-discover-flatpak \
        || ADVISORIES+=("Flatpak is installed, but Discover's Flatpak backend package was not found.")
    fi
  fi

  rpm_installed plasma-print-manager \
    || ADVISORIES+=("KDE printer management was not found.")
  rpm_installed plasma-nm \
    || ADVISORIES+=("Plasma NetworkManager integration was not found.")

  if compgen -G '/sys/class/bluetooth/hci*' >/dev/null && ! rpm_installed bluedevil; then
    ADVISORIES+=("Bluetooth hardware was detected, but KDE Bluetooth integration was not found.")
  fi
}

print_summary() {
  local layouts default_layout item

  if [[ "$ADD_GB" -eq 0 ]]; then
    layouts="Hungarian"
    default_layout="Hungarian"
  elif [[ "$GB_DEFAULT" -eq 1 ]]; then
    layouts="English (UK), Hungarian"
    default_layout="English (UK)"
  else
    layouts="Hungarian, English (UK)"
    default_layout="Hungarian"
  fi

  cat <<SUMMARY

KDE settings setup finished.

  Keyboard layouts:       $layouts
  Default layout:         $default_layout
  Num Lock on startup:    enabled
  Automatic screen lock:  after $LOCK_MINUTES minutes
  Password after locking: required immediately
  Lock after resume:      enabled
  Empty session startup:  $([[ "$USE_EMPTY_SESSION" -eq 1 ]] && echo enabled || echo unchanged)
  Hungarian formats:      $([[ "$USE_HUNGARIAN_FORMATS" -eq 1 ]] && echo enabled || echo unchanged)
  Color scheme:           $COLOR_SCHEME
  Default browser:        $BROWSER_DESKTOP_ID
  Window/desktop profile: $WINDOW_SETTINGS_STATUS
  Top-left hot corner:    $HOT_CORNER_STATUS
  Yakuake:                $YAKUAKE_STATUS
  Backup:                 $BACKUP_DIR
SUMMARY

  if (( ${#ADVISORIES[@]} > 0 )); then
    echo
    echo "Advisories:"
    for item in "${ADVISORIES[@]}"; do
      echo "  - $item"
    done
  fi

  cat <<'SUMMARY'

Log out and back in once so the keyboard, Num Lock, locale, and session
settings all begin from a clean Plasma session. SDDM and X11 were not changed.
SUMMARY
}

main() {
  parse_args "$@"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_dry_run
    return 0
  fi

  require_fedora
  resolve_execution_context
  preflight_plasma_session
  acquire_lock
  collect_choices
  validate_choices
  # Package installation is independent of KDE configuration recovery.
  install_yakuake
  prepare_backups

  configure_keyboard_layouts
  configure_numlock
  configure_screen_locking
  configure_session
  configure_regional_formats
  configure_color_scheme
  configure_default_browser
  check_desktop_integrations
  configure_hot_corner
  # Last mutation: this transaction owns recovery of live desktop settings.
  configure_window_settings

  ROLLBACK_ARMED=0
  HOT_CORNER_ARMED=0
  print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
