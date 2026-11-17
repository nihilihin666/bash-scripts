#!/usr/bin/env bash
set -Eeuo pipefail

# fedora-setup-02-xfce-settings.sh
# Fedora XFCE settings/profile bootstrap
# - reliability-first dark profile
# - optional bottom panel
# - optional black background (confirmation defaults to No)
# - clean session behavior
# - keyboard: keep gb+hu, switch with both Shift keys, disable Caps Lock
# - desktop/laptop mode tweaks
# - optional hidden files in Thunar
#
# Run as normal user with sudo available:
#   bash ./bash-scripts/os/fedora/setup/fedora-setup-02-xfce-settings.sh
#
# Notes:
# - Some changes need a new login or reboot to fully settle.
# - Panel changes are optional and confirmed before applying.

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
DRY_RUN=0
USER_NAME=""
USER_HOME=""
USER_ID=""
USER_RUNTIME_DIR=""
LOCK_FILE=""

usage() {
  cat <<EOF
Configure Fedora XFCE themes, keyboard, session, and optional panel settings.

Usage: $0 [--dry-run] [--help]

Options:
  --dry-run   Show the setup plan without applying changes.
  -h, --help  Show this help.

Run as the logged-in desktop user, with sudo available for system changes.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $arg" ;;
    esac
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
  [[ "${ID:-}" == "fedora" ]] || {
    echo "This script supports Fedora only. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
  }
  fedora_version="$(rpm -E %fedora 2>/dev/null || true)"
  [[ "$fedora_version" =~ ^[0-9]+$ ]] || { echo "Could not determine the Fedora release." >&2; exit 1; }
}

resolve_execution_context() {
  if [[ "$DRY_RUN" -eq 1 && -n "${SUDO_USER:-}" ]]; then
    USER_NAME="$SUDO_USER"
  else
    USER_NAME="${USER:-}"
  fi
  [[ -n "$USER_NAME" ]] || die "could not determine the current user."

  if [[ "$DRY_RUN" -ne 1 && "$EUID" -eq 0 ]]; then
    die "run this as your normal user, not through sudo. Example: bash ${SCRIPT_NAME}"
  fi
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  [[ -n "$USER_HOME" ]] || die "could not determine the home directory for $USER_NAME."
  USER_ID="$(id -u "$USER_NAME")"
  USER_RUNTIME_DIR="/run/user/${USER_ID}"

  if [[ "$DRY_RUN" -ne 1 ]] && ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required."
  fi
}

detect_session_type() {
  local session_type="${XDG_SESSION_TYPE:-}"

  if [[ -z "$session_type" && -n "${XDG_SESSION_ID:-}" ]]; then
    session_type="$(loginctl show-session "$XDG_SESSION_ID" -p Type --value 2>/dev/null || true)"
  fi
  if [[ -z "$session_type" && -n "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    session_type="x11"
  fi
  printf '%s\n' "${session_type,,}"
}

preflight_xfce_session() {
  local cmd desktop session_type

  desktop="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-}}"
  case "${desktop,,}" in
    *xfce*) ;;
    *) die "the current desktop is ${desktop:-unknown}, not XFCE; no settings were changed." ;;
  esac

  session_type="$(detect_session_type)"
  [[ "$session_type" == x11 ]] \
    || die "the current XFCE session is ${session_type:-unknown}, not X11; no settings were changed."

  for cmd in xfconf-query xfce4-panel; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required; run this after installing Fedora XFCE."
  done

  [[ -S "${USER_RUNTIME_DIR}/bus" ]] \
    || die "the user D-Bus session is unavailable; run this from a logged-in XFCE session."
  sudo -v || die "sudo authorization failed."
  run_as_user xfconf-query -c xsettings -l >/dev/null 2>&1 \
    || die "XFConf is unavailable; run this from a working XFCE session."
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (provided by util-linux)."
  LOCK_FILE="${USER_RUNTIME_DIR}/fedora-setup-02-xfce-settings.lock"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another XFCE setup process is already running for $USER_NAME."
}

log() {
  echo
  echo "==> $*"
}

warn() {
  echo "[warn] $*" >&2
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply

  while true; do
    if [[ "$default" == "Y" ]]; then
      read -r -p "$prompt [Y/n]: " reply || true
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply || true
      reply="${reply:-N}"
    fi

    case "$reply" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

run_as_user() {
  sudo -u "$USER_NAME" env \
    HOME="$USER_HOME" \
    XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME_DIR}/bus" \
    "$@"
}

pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

install_pkg_if_missing() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    echo "[skip] $pkg already installed"
  else
    sudo dnf install -y "$pkg"
  fi
}

pkg_available() {
  local pkg="$1"
  dnf -q list --available "$pkg" >/dev/null 2>&1 \
    || dnf -q list --installed "$pkg" >/dev/null 2>&1
}

install_xfce_support_packages() {
  local -a wanted=(xclip xsel thunar-archive-plugin thunar-media-tags-plugin)
  local -a installable=()
  local -a unavailable=()
  local pkg

  log "Ensuring XFCE and X11 support packages"
  for pkg in "${wanted[@]}"; do
    if pkg_installed "$pkg"; then
      continue
    elif pkg_available "$pkg"; then
      installable+=("$pkg")
    else
      unavailable+=("$pkg")
    fi
  done

  if (( ${#installable[@]} > 0 )); then
    sudo dnf install -y "${installable[@]}"
  fi
  if (( ${#unavailable[@]} > 0 )); then
    warn "Skipping unavailable optional XFCE/X11 package(s): ${unavailable[*]}"
  fi
}

set_xfconf_property() {
  local channel="$1"
  local prop="$2"
  local type="$3"
  local value="$4"

  if [[ ! -S "${USER_RUNTIME_DIR}/bus" ]]; then
    warn "User D-Bus session not available. Skipping live XFCE setting: ${channel} ${prop}"
    return 0
  fi

  if run_as_user xfconf-query -c "$channel" -p "$prop" >/dev/null 2>&1; then
    run_as_user xfconf-query -c "$channel" -p "$prop" -s "$value" >/dev/null
  else
    run_as_user xfconf-query -c "$channel" -p "$prop" -n -t "$type" -s "$value" >/dev/null
  fi

  local actual
  actual="$(run_as_user xfconf-query -c "$channel" -p "$prop" 2>/dev/null || true)"
  [[ "$actual" == "$value" ]] \
    || die "failed to verify XFConf setting: ${channel} ${prop} (expected '$value', got '$actual')"
}

set_xfconf_bool() {
  set_xfconf_property "$1" "$2" bool "$3"
}

set_xfconf_int() {
  set_xfconf_property "$1" "$2" int "$3"
}

set_xfconf_uint() {
  set_xfconf_property "$1" "$2" uint "$3"
}

set_xfconf_string() {
  set_xfconf_property "$1" "$2" string "$3"
}

set_xfconf_rgba_black() {
  local prop="$1"
  local -a cmd=(xfconf-query -c xfce4-desktop -p "$prop")
  local -a values=()

  if run_as_user xfconf-query -c xfce4-desktop -p "$prop" >/dev/null 2>&1; then
    cmd+=(-s 0 -s 0 -s 0 -s 1)
  else
    cmd+=(-n -a -t double -s 0 -t double -s 0 -t double -s 0 -t double -s 1)
  fi
  run_as_user "${cmd[@]}" >/dev/null

  mapfile -t values < <(
    run_as_user xfconf-query -c xfce4-desktop -p "$prop" 2>/dev/null | tail -n +3
  )
  if (( ${#values[@]} != 4 )) \
      || ! awk -v r="${values[0]:-x}" -v g="${values[1]:-x}" \
        -v b="${values[2]:-x}" -v a="${values[3]:-x}" \
        'BEGIN { exit !((r+0)==0 && (g+0)==0 && (b+0)==0 && (a+0)==1) }'; then
    die "failed to verify black RGBA value for xfce4-desktop ${prop}"
  fi
}

apply_xfconf_settings() {
  local channel="$1"
  local type property value
  shift

  while (( $# >= 3 )); do
    type="$1"
    property="$2"
    value="$3"
    shift 3
    set_xfconf_property "$channel" "$property" "$type" "$value"
  done
  (( $# == 0 )) || die "invalid XFConf setting table for $channel"
}

get_xfconf_value() {
  local channel="$1"
  local prop="$2"

  if [[ ! -S "${USER_RUNTIME_DIR}/bus" ]]; then
    return 1
  fi

  run_as_user xfconf-query -c "$channel" -p "$prop" 2>/dev/null || true
}

remove_xfconf_property_if_exists() {
  local channel="$1"
  local prop="$2"

  if [[ ! -S "${USER_RUNTIME_DIR}/bus" ]]; then
    warn "User D-Bus session not available. Skipping XFCE property removal: ${channel} ${prop}"
    return 0
  fi

  if run_as_user xfconf-query -c "$channel" -p "$prop" >/dev/null 2>&1; then
    run_as_user xfconf-query -c "$channel" -p "$prop" -r >/dev/null
  fi
}

set_xfwm_hotkey() {
  local key="$1"
  local action="$2"
  local command_prop="/commands/custom/${key}"
  local xfwm_prop="/xfwm4/custom/${key}"
  local old_command old_xfwm

  old_command="$(get_xfconf_value xfce4-keyboard-shortcuts "$command_prop" || true)"
  old_xfwm="$(get_xfconf_value xfce4-keyboard-shortcuts "$xfwm_prop" || true)"

  if [[ -n "$old_command" ]]; then
    warn "Removing conflicting command shortcut ${command_prop}: ${old_command}"
    remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "$command_prop"
  fi

  if [[ "$old_xfwm" == "$action" ]]; then
    echo "[skip] ${key} already mapped to ${action}"
    return 0
  fi

  if [[ -n "$old_xfwm" ]]; then
    warn "Replacing XFWM shortcut ${xfwm_prop}: ${old_xfwm} -> ${action}"
    remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "$xfwm_prop"
  fi

  set_xfconf_string xfce4-keyboard-shortcuts "$xfwm_prop" "$action"
}

set_command_hotkey() {
  local key="$1"
  local command="$2"

  local command_prop="/commands/custom/${key}"
  local old_command

  old_command="$(get_xfconf_value xfce4-keyboard-shortcuts "$command_prop" || true)"

  if [[ "$old_command" == "$command" ]]; then
    echo "[skip] ${key} already mapped to ${command}"
    return 0
  fi

  if [[ -n "$old_command" ]]; then
    warn "Replacing command shortcut ${command_prop}: ${old_command} -> ${command}"
  fi

  set_xfconf_string xfce4-keyboard-shortcuts "$command_prop" "$command"
}

ensure_lightdm_numlock() {
  local active_display_manager=""

  if ! rpm -q lightdm >/dev/null 2>&1; then
    warn "LightDM is not installed; login-screen NumLock configuration was skipped."
    return 0
  fi

  active_display_manager="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  if [[ -n "$active_display_manager" && "${active_display_manager##*/}" != lightdm.service ]]; then
    warn "The active display manager is ${active_display_manager##*/}, not LightDM; login-screen NumLock configuration was skipped."
    return 0
  fi

  if ! pkg_installed numlockx; then
    sudo dnf install -y numlockx
  fi

  local dropin_dir="/etc/lightdm/lightdm.conf.d"
  local dropin="$dropin_dir/90-numlock.conf"
  local tmp
  tmp="$(mktemp)"
  printf '[Seat:*]\ngreeter-setup-script=/usr/bin/numlockx on\n' > "$tmp"
  sudo mkdir -p "$dropin_dir"
  if ! sudo install -m 0644 "$tmp" "$dropin"; then
    rm -f -- "$tmp"
    die "could not install the LightDM NumLock drop-in."
  fi
  if ! sudo cmp -s "$tmp" "$dropin"; then
    rm -f -- "$tmp"
    die "the LightDM NumLock drop-in failed verification."
  fi
  rm -f -- "$tmp"
}

data_item_exists() {
  local category="$1"
  local name="$2"
  local dir
  local -a roots=("$USER_HOME/.local/share" "$USER_HOME/.icons" /usr/local/share /usr/share)
  local -a xdg_roots=()

  IFS=: read -r -a xdg_roots <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  roots+=("${xdg_roots[@]}")

  for dir in "${roots[@]}"; do
    if [[ "$category" == icons && "$dir" == "$USER_HOME/.icons" ]]; then
      [[ -d "$dir/$name" ]] && return 0
    elif [[ -d "$dir/$category/$name" ]]; then
      return 0
    fi
  done
  return 1
}

configure_theme() {
  log "Applying dark appearance"

  if data_item_exists themes Adwaita-dark; then
    set_xfconf_string xsettings /Net/ThemeName Adwaita-dark
  else
    warn "GTK theme Adwaita-dark is unavailable; keeping the current GTK theme."
  fi

  if data_item_exists icons Papirus-Dark; then
    set_xfconf_string xsettings /Net/IconThemeName Papirus-Dark
  else
    warn "Icon theme Papirus-Dark is unavailable; keeping the current icon theme."
  fi

  if data_item_exists icons Adwaita; then
    set_xfconf_string xsettings /Gtk/CursorThemeName Adwaita
  else
    warn "Cursor theme Adwaita is unavailable; keeping the current cursor theme."
  fi

  set_xfconf_string xsettings /Gtk/FontName "Noto Sans 10"
  set_xfconf_string xsettings /Gtk/MonospaceFontName "JetBrains Mono 10"

  if [[ -d /usr/share/themes/Adwaita/xfwm4 || -d "$USER_HOME/.themes/Adwaita/xfwm4" ]]; then
    set_xfconf_string xfwm4 /general/theme Adwaita
  else
    warn "XFWM theme Adwaita is unavailable; keeping the current window-manager theme."
  fi
}

configure_background() {
  if ! ask_yes_no "Disable wallpaper images (style: None) and use a plain black background?" N; then
    log "Keeping the existing wallpaper and background settings"
    return 0
  fi
  log "Applying plain black background"

  local -a all_prefixes=() workspace_prefixes=() prefixes=()
  local prefix prop
  while IFS= read -r prop; do
    case "$prop" in
      /backdrop/screen*/monitor*/workspace*/image-style|\
      /backdrop/screen*/monitor*/workspace*/last-image|\
      /backdrop/screen*/monitor*/workspace*/image-path|\
      /backdrop/screen*/monitor*/image-style|\
      /backdrop/screen*/monitor*/last-image|\
      /backdrop/screen*/monitor*/image-path)
        prefix="${prop%/*}"
        all_prefixes+=("$prefix")
        [[ "$prefix" == */workspace* ]] && workspace_prefixes+=("$prefix")
        ;;
    esac
  done < <(run_as_user xfconf-query -c xfce4-desktop -l 2>/dev/null | sort -u)

  if (( ${#workspace_prefixes[@]} > 0 )); then
    mapfile -t prefixes < <(printf '%s\n' "${workspace_prefixes[@]}" | sort -u)
  elif (( ${#all_prefixes[@]} > 0 )); then
    mapfile -t prefixes < <(printf '%s\n' "${all_prefixes[@]}" | sort -u)
  else
    warn "No active XFCE backdrop monitor/workspace properties were found; keeping the current background."
    return 0
  fi

  for prefix in "${prefixes[@]}"; do
    set_xfconf_int xfce4-desktop "$prefix/image-style" 0
    set_xfconf_int xfce4-desktop "$prefix/color-style" 0
    set_xfconf_rgba_black "$prefix/rgba1"
    if run_as_user xfconf-query -c xfce4-desktop -p "$prefix/rgba2" >/dev/null 2>&1; then
      set_xfconf_rgba_black "$prefix/rgba2"
    fi
  done
}

restore_x11_keyboard_state() {
  local persistent_layout="$1"
  local persistent_model="$2"
  local persistent_variant="$3"
  local persistent_options="$4"
  local live_layout="$5"
  local live_model="$6"
  local live_variant="$7"
  local live_options="$8"
  local -a live_cmd=(setxkbmap)
  local -a option_items=()
  local option_item

  if [[ -n "$persistent_layout" ]]; then
    sudo localectl --no-convert set-x11-keymap \
      "$persistent_layout" "$persistent_model" "$persistent_variant" "$persistent_options" \
      || warn "Could not restore the previous persistent X11 keyboard configuration."
  else
    sudo localectl --no-convert set-x11-keymap "" "" "" "" \
      || warn "Could not remove the newly created persistent X11 keyboard configuration."
  fi

  if [[ -n "${DISPLAY:-}" && -n "$live_layout" ]] && command -v setxkbmap >/dev/null 2>&1; then
    live_cmd+=(-layout "$live_layout")
    [[ -n "$live_model" ]] && live_cmd+=(-model "$live_model")
    [[ -n "$live_variant" ]] && live_cmd+=(-variant "$live_variant")
    live_cmd+=(-option '')
    if [[ -n "$live_options" ]]; then
      IFS=, read -r -a option_items <<< "$live_options"
      for option_item in "${option_items[@]}"; do
        [[ -n "$option_item" ]] && live_cmd+=(-option "$option_item")
      done
    fi
    run_as_user "${live_cmd[@]}" >/dev/null 2>&1 \
      || warn "Could not restore the previous live X11 keyboard configuration."
  fi
}

configure_keyboard() {
  log "Configuring XFCE X11 keyboard layouts and XKB options"

  local session_type
  local current_layout current_model current_variant current_options
  local final_layout="gb,hu"
  local live_layout live_options
  local previous_live_layout="" previous_live_model="" previous_live_variant="" previous_live_options=""

  session_type="$(detect_session_type)"
  if [[ "$session_type" != x11 ]]; then
    warn "The current XFCE session is ${session_type:-unknown}, not X11; X11 keyboard configuration was skipped."
    return 0
  fi

  current_layout="$(localectl status 2>/dev/null | awk -F': +' '/X11 Layout/ {print $2; exit}')"
  current_model="$(localectl status 2>/dev/null | awk -F': +' '/X11 Model/ {print $2; exit}')"
  current_variant="$(localectl status 2>/dev/null | awk -F': +' '/X11 Variant/ {print $2; exit}')"
  current_options="$(localectl status 2>/dev/null | awk -F': +' '/X11 Options/ {print $2; exit}')"
  current_layout="${current_layout// /}"

  if [[ "$current_layout" == hu* ]]; then
    final_layout="hu,gb"
  fi

  if [[ -n "${DISPLAY:-}" ]] && command -v setxkbmap >/dev/null 2>&1; then
    previous_live_layout="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^layout:/ {print $2}')"
    previous_live_model="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^model:/ {print $2}')"
    previous_live_variant="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^variant:/ {print $2}')"
    previous_live_options="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^options:/ {$1=""; sub(/^ +/, ""); print}')"
  fi

  if ! sudo localectl --no-convert set-x11-keymap \
      "$final_layout" "" "" "grp:shifts_toggle,caps:none"; then
    warn "Could not persist the XFCE X11 keyboard configuration."
    return 1
  fi

  if [[ -n "${DISPLAY:-}" ]] && command -v setxkbmap >/dev/null 2>&1; then
    if ! run_as_user setxkbmap -layout "$final_layout" \
        -option '' -option 'grp:shifts_toggle' -option 'caps:none'; then
      warn "Could not apply the live X11 keyboard configuration; restoring the previous persistent configuration."
      restore_x11_keyboard_state \
        "$current_layout" "$current_model" "$current_variant" "$current_options" \
        "$previous_live_layout" "$previous_live_model" "$previous_live_variant" "$previous_live_options"
      return 1
    fi

    live_layout="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^layout:/ {print $2}')"
    live_options="$(run_as_user setxkbmap -query 2>/dev/null | awk '/^options:/ {$1=""; sub(/^ +/, ""); print}')"
    if [[ "$live_layout" != "$final_layout" \
        || "$live_options" != *grp:shifts_toggle* \
        || "$live_options" != *caps:none* ]]; then
      warn "Live X11 keyboard verification failed; restoring the previous persistent configuration."
      restore_x11_keyboard_state \
        "$current_layout" "$current_model" "$current_variant" "$current_options" \
        "$previous_live_layout" "$previous_live_model" "$previous_live_variant" "$previous_live_options"
      return 1
    fi
  else
    warn "setxkbmap or DISPLAY is unavailable; the persistent X11 keyboard configuration will apply at the next login."
  fi

  if [[ "$(localectl status 2>/dev/null | awk -F': +' '/X11 Layout/ {print $2; exit}' | tr -d '[:space:]')" != "$final_layout" ]]; then
    warn "Persistent X11 keyboard verification failed; restoring the previous configuration."
    restore_x11_keyboard_state \
      "$current_layout" "$current_model" "$current_variant" "$current_options" \
      "$previous_live_layout" "$previous_live_model" "$previous_live_variant" "$previous_live_options"
    return 1
  fi
}


configure_window_hotkeys() {
  log "Configuring XFCE window/workspace hotkeys"

  # Bind normal arrow keys only.
  # Keypad-arrow bindings are intentionally removed because they can conflict
  # with XFCE/XFWM shortcut handling on some setups.

  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/xfwm4/custom/<Super>KP_Up"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/xfwm4/custom/<Super>KP_Down"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/xfwm4/custom/<Super>KP_Left"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/xfwm4/custom/<Super>KP_Right"

  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/commands/custom/<Super>KP_Up"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/commands/custom/<Super>KP_Down"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/commands/custom/<Super>KP_Left"
  remove_xfconf_property_if_exists xfce4-keyboard-shortcuts "/commands/custom/<Super>KP_Right"

  # Super + Up should maximize, not true fullscreen. True fullscreen hides the panel/taskbar.
  set_xfwm_hotkey "<Super>Up" "maximize_window_key"

  # Send current window to taskbar.
  set_xfwm_hotkey "<Super>Down" "hide_window_key"

  # Workspace navigation through workspace order, not spatial grid navigation.
  set_xfwm_hotkey "<Super>Left" "prev_workspace_key"
  set_xfwm_hotkey "<Super>Right" "next_workspace_key"
  set_xfwm_hotkey "<Shift><Super>Left" "move_window_prev_workspace_key"
  set_xfwm_hotkey "<Shift><Super>Right" "move_window_next_workspace_key"
}

configure_thunar() {
  log "Configuring Thunar"

  if ask_yes_no "Show hidden files in Thunar by default?" Y; then
    set_xfconf_bool thunar /last-show-hidden true
  else
    set_xfconf_bool thunar /last-show-hidden false
  fi

  apply_xfconf_settings thunar \
    bool /misc-single-click false \
    bool /misc-open-new-window-as-tab false \
    bool /misc-directory-specific-settings true \
    string /last-view ThunarDetailsView \
    bool /misc-image-size-in-statusbar true \
    bool /misc-file-size-binary true
}

configure_session() {
  log "Configuring session behavior"

  apply_xfconf_settings xfce4-session \
    bool /general/SaveOnExit false \
    bool /general/PromptOnLogout true
}

configure_power_desktop() {
  log "Applying desktop power settings"

  apply_xfconf_settings xfce4-power-manager \
    uint /xfce4-power-manager/dpms-on-ac-sleep 45 \
    uint /xfce4-power-manager/dpms-on-ac-off 60 \
    uint /xfce4-power-manager/blank-on-ac 30 \
    uint /xfce4-power-manager/inactivity-on-ac 0 \
    uint /xfce4-power-manager/inactivity-sleep-mode-on-ac 1 \
    bool /xfce4-power-manager/logind-handle-lid-switch false
}

configure_power_laptop() {
  log "Applying laptop power settings"

  apply_xfconf_settings xfce4-power-manager \
    uint /xfce4-power-manager/dpms-on-ac-sleep 25 \
    uint /xfce4-power-manager/dpms-on-ac-off 35 \
    uint /xfce4-power-manager/blank-on-ac 20 \
    uint /xfce4-power-manager/dpms-on-battery-sleep 10 \
    uint /xfce4-power-manager/dpms-on-battery-off 15 \
    uint /xfce4-power-manager/blank-on-battery 10 \
    uint /xfce4-power-manager/lid-action-on-battery 1 \
    uint /xfce4-power-manager/inactivity-on-battery 20 \
    uint /xfce4-power-manager/inactivity-sleep-mode-on-battery 1
}

panel_create_scalar() {
  local type="$1"
  local prop="$2"
  local value="$3"
  run_as_user xfconf-query -c xfce4-panel -p "$prop" -n -t "$type" -s "$value" >/dev/null
}

panel_create_array() {
  local type="$1"
  local prop="$2"
  shift 2
  local -a cmd=(xfconf-query -c xfce4-panel -p "$prop" -n)
  local value

  (( $# == 1 )) && cmd+=(-a)
  for value in "$@"; do
    # The long --set= form safely handles string values beginning with '-'.
    cmd+=(-t "$type" "--set=$value")
  done
  run_as_user "${cmd[@]}" >/dev/null
}

apply_bottom_panel_xfce_420() {
  run_as_user xfconf-query -c xfce4-panel -p /panels -r -R >/dev/null 2>&1 || true
  run_as_user xfconf-query -c xfce4-panel -p /plugins -r -R >/dev/null 2>&1 || true

  panel_create_array int /panels 1 || return 1
  panel_create_scalar bool /panels/dark-mode true || return 1
  panel_create_scalar uint /panels/panel-1/autohide-behavior 0 || return 1
  panel_create_scalar double /panels/panel-1/length 100 || return 1
  panel_create_scalar bool /panels/panel-1/length-adjust true || return 1
  panel_create_scalar uint /panels/panel-1/mode 0 || return 1
  panel_create_array int /panels/panel-1/plugin-ids 1 2 3 4 5 6 7 8 || return 1
  panel_create_scalar string /panels/panel-1/position 'p=8;x=0;y=0' || return 1
  panel_create_scalar bool /panels/panel-1/position-locked true || return 1
  panel_create_scalar uint /panels/panel-1/size 34 || return 1

  panel_create_scalar string /plugins/plugin-1 whiskermenu || return 1
  panel_create_scalar string /plugins/plugin-2 separator || return 1
  panel_create_scalar uint /plugins/plugin-2/style 0 || return 1
  panel_create_scalar bool /plugins/plugin-2/expand false || return 1
  panel_create_scalar string /plugins/plugin-3 tasklist || return 1
  panel_create_scalar string /plugins/plugin-4 separator || return 1
  panel_create_scalar uint /plugins/plugin-4/style 0 || return 1
  panel_create_scalar bool /plugins/plugin-4/expand true || return 1
  panel_create_scalar string /plugins/plugin-5 systray || return 1
  panel_create_scalar string /plugins/plugin-6 pulseaudio || return 1
  panel_create_scalar string /plugins/plugin-7 clock || return 1
  panel_create_scalar string /plugins/plugin-7/digital-format '%Y-%m-%d %H:%M' || return 1
  panel_create_scalar uint /plugins/plugin-7/mode 2 || return 1
  panel_create_scalar string /plugins/plugin-8 actions || return 1
  panel_create_scalar uint /plugins/plugin-8/appearance 0 || return 1
  panel_create_array string /plugins/plugin-8/items \
    -lock-screen -switch-user -separator +shutdown +restart -logout-dialog || return 1
}

start_panel() {
  nohup sudo -u "$USER_NAME" env \
    HOME="$USER_HOME" \
    XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME_DIR}/bus" \
    xfce4-panel >/dev/null 2>&1 &
}

stop_panel() {
  local attempt
  run_as_user xfce4-panel --quit >/dev/null 2>&1 || true
  for attempt in 1 2 3 4 5; do
    : "$attempt"
    pgrep -u "$USER_ID" -x xfce4-panel >/dev/null 2>&1 || return 0
    sleep 1
  done
  return 1
}

panel_is_healthy() {
  local attempt
  for attempt in 1 2 3 4 5; do
    : "$attempt"
    if pgrep -u "$USER_ID" -x xfce4-panel >/dev/null 2>&1 \
        && [[ "$(get_xfconf_value xfce4-panel /plugins/plugin-1)" == whiskermenu ]] \
        && [[ "$(get_xfconf_value xfce4-panel /plugins/plugin-8)" == actions ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

reset_panel() {
  log "Rebuilding XFCE panel to a simple bottom layout"

  local panel_version backup_root backup_file
  panel_version="$(xfce4-panel --version 2>/dev/null | awk '/^xfce4-panel / {print $2; exit}')"
  case "$panel_version" in
    4.20.*) ;;
    *)
      warn "Panel layout is tested only with XFCE 4.20; detected ${panel_version:-unknown}. Skipping panel changes."
      return 0
      ;;
  esac

  command -v xfce4-panel-profiles >/dev/null 2>&1 || {
    warn "xfce4-panel-profiles is unavailable; skipping panel changes."
    return 0
  }
  command -v pgrep >/dev/null 2>&1 || {
    warn "pgrep is unavailable; skipping panel changes because health checks cannot run."
    return 0
  }
  command -v xfce4-popup-whiskermenu >/dev/null 2>&1 || {
    warn "Whisker Menu is unavailable; skipping panel changes."
    return 0
  }
  rpm -q xfce4-pulseaudio-plugin >/dev/null 2>&1 || {
    warn "The XFCE PulseAudio panel plugin is unavailable; skipping panel changes."
    return 0
  }

  backup_root="$USER_HOME/.config/xfce4/panel-backups"
  mkdir -p "$backup_root"
  backup_file="$(mktemp "$backup_root/panel-$(date +%Y%m%d-%H%M%S).XXXXXX.tar.bz2")"
  if ! run_as_user xfce4-panel-profiles save "$backup_file" >/dev/null 2>&1 \
      || [[ ! -s "$backup_file" ]] \
      || ! tar -tjf "$backup_file" >/dev/null 2>&1; then
    warn "Could not create a verified panel profile backup; panel changes were skipped."
    rm -f -- "$backup_file"
    return 0
  fi

  log "Panel profile backed up to $backup_file"
  if ! stop_panel; then
    warn "The current panel did not stop cleanly; its configuration was not changed."
    return 1
  fi

  if apply_bottom_panel_xfce_420; then
    start_panel
  fi

  if ! panel_is_healthy; then
    warn "The new panel did not pass its health check; restoring $backup_file"
    stop_panel || true
    if ! run_as_user xfce4-panel-profiles load "$backup_file" >/dev/null 2>&1; then
      warn "Automatic panel restore failed. Restore it manually with: xfce4-panel-profiles load '$backup_file'"
      return 1
    fi
    pgrep -u "$USER_ID" -x xfce4-panel >/dev/null 2>&1 || start_panel
    sleep 2
    pgrep -u "$USER_ID" -x xfce4-panel >/dev/null 2>&1 \
      || warn "The restored panel is not running. Log out and back in."
    return 1
  fi
}

main() {
  parse_args "$@"
  require_fedora
  resolve_execution_context

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<PLAN
Fedora XFCE settings dry-run for $USER_NAME; no commands will be executed.

Would perform:
  - install optional XFCE/Thunar and X11 support packages when available
  - install/configure NumLock for LightDM through a dedicated drop-in
  - apply dark theme, X11 keyboard layouts, and window shortcuts
  - ask before disabling wallpaper images and applying a black background (default No)
  - configure Thunar and XFCE session behavior
  - ask whether to apply laptop or desktop power settings
  - ask before backing up and rebuilding the XFCE panel
PLAN
    return
  fi

  preflight_xfce_session
  acquire_lock

  trap 'exit 130' INT
  trap 'exit 143' TERM

  install_xfce_support_packages

  log "Ensuring login-screen NumLock"
  ensure_lightdm_numlock

  configure_theme
  configure_background
  configure_keyboard
  configure_window_hotkeys
  configure_thunar
  configure_session

  if ask_yes_no "Apply laptop mode power settings?" N; then
    configure_power_laptop
  else
    configure_power_desktop
  fi

  if ask_yes_no "Apply the bottom panel layout changes? This may overwrite current XFCE panel customization." N; then
    reset_panel
  else
    log "Skipping panel changes"
  fi

  # Open the Whisker menu.
  if command -v xfce4-popup-whiskermenu >/dev/null 2>&1; then
    set_command_hotkey "<Super>space" "xfce4-popup-whiskermenu"
    # Migrate the old shortcut without removing a user-reassigned command.
    if [[ "$(get_xfconf_value xfce4-keyboard-shortcuts '/commands/custom/<Super>w')" == xfce4-popup-whiskermenu ]]; then
      remove_xfconf_property_if_exists xfce4-keyboard-shortcuts '/commands/custom/<Super>w'
    fi
  else
    warn "Whisker Menu is unavailable; the Super+Space shortcut was not configured."
  fi

  echo
  echo "Done. Logging out and back in should apply anything XFCE did not refresh live."
  echo "Restarting the computer would be a good idea as well."
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
