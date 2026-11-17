#!/usr/bin/env bash
set -euo pipefail

# Fedora base setup (desktop-agnostic)
# Run with: sudo bash ./bash-scripts/os/fedora/setup/fedora-setup-01-base.sh

DRY_RUN=0
ORIGINAL_USER=""
ORIGINAL_HOME=""
FEDORA_VERSION=""
LOCK_FILE="/run/lock/fedora-setup-01-base.lock"
readonly BRAVE_REPO_URL="https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo"
readonly VIVALDI_REPO_URL="https://repo.vivaldi.com/archive/vivaldi-fedora.repo"
readonly HELIUM_COPR_PROJECT="imput/helium"
readonly HELIUM_REPO_ID="copr:copr.fedorainfracloud.org:imput:helium"
readonly LIBREWOLF_REPO_URL="https://repo.librewolf.net/librewolf.repo"
# Published at https://signal.org/download/linux/; key rotation requires review.
readonly SIGNAL_APPIMAGE_KEY_FINGERPRINT="4B16B7232DFAA439AD791002EF9F501F13EED94C"

usage() {
  cat <<EOF
Install and configure Fedora base packages, repositories, and shell tools.

Usage: $0 [--dry-run] [--help]

Options:
  --dry-run   Show the setup plan without applying changes.
  -h, --help  Show this help.

Run through sudo from your normal user account.
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
  if [[ -e /run/ostree-booted ]]; then
    die "this script uses DNF and does not support Fedora Atomic desktops."
  fi
}

resolve_execution_context() {
  if [[ "$DRY_RUN" -ne 1 && ${EUID:-$(id -u)} -ne 0 ]]; then
    die "run as root: sudo bash $0"
  fi

  ORIGINAL_USER="${SUDO_USER:-${USER:-}}"
  [[ -n "$ORIGINAL_USER" ]] || die "could not determine the normal user account."
  if [[ "$DRY_RUN" -ne 1 && -z "${SUDO_USER:-}" ]]; then
    die "run this script using sudo from a normal user account."
  fi

  ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)"
  [[ -n "$ORIGINAL_HOME" ]] || die "could not determine the home directory for $ORIGINAL_USER."
  FEDORA_VERSION="$(rpm -E %fedora)"
  [[ "$FEDORA_VERSION" =~ ^[0-9]+$ ]] || die "could not determine the Fedora release."
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (provided by util-linux)."
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another base setup process is already running."
}

log() {
  echo
  echo "==> $*"
}

warn() {
  echo "[WARN] $*" >&2
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply=""

  while true; do
    if [[ "$default" == "Y" ]]; then
      if ! read -r -p "$prompt [Y/n]: " reply; then
        warn "No answer received; skipping this optional step."
        return 1
      fi
      reply="${reply:-Y}"
    else
      if ! read -r -p "$prompt [y/N]: " reply; then
        warn "No answer received; skipping this optional step."
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

is_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

is_dnf5() {
  # Consume all output to avoid SIGPIPE under pipefail from head/grep -q.
  dnf --version 2>/dev/null \
    | awk 'NR == 1 && /^dnf5 / { found=1 } END { exit found ? 0 : 1 }'
}

pkg_available() {
  dnf -q list --available "$1" >/dev/null 2>&1 || dnf -q list --installed "$1" >/dev/null 2>&1
}

ensure_pkg() {
  local pkg
  local packages=()
  for pkg in "$@"; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
      packages+=("$pkg")
    fi
  done

  if (( ${#packages[@]} > 0 )); then
    dnf install -y "${packages[@]}"
  fi
}

ensure_pkg_if_available() {
  local pkg
  local packages=()
  local missing=()

  for pkg in "$@"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      continue
    fi

    if pkg_available "$pkg"; then
      packages+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  if (( ${#packages[@]} > 0 )); then
    dnf install -y "${packages[@]}"
  fi

  if (( ${#missing[@]} > 0 )); then
    warn "Skipping unavailable package(s): ${missing[*]}"
  fi
}

append_line_if_missing() {
  local file="$1"
  local line="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

is_flatpak_app_installed() {
  local app_id="$1"
  command -v flatpak >/dev/null 2>&1 || return 1

  flatpak --system info "$app_id" >/dev/null 2>&1 && return 0
  if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != root ]] \
      && command -v runuser >/dev/null 2>&1; then
    runuser -u "$ORIGINAL_USER" -- env \
      -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
      -u FLATPAK_USER_DIR -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
      HOME="$ORIGINAL_HOME" \
      flatpak --user info "$app_id" >/dev/null 2>&1 && return 0
  fi
  return 1
}

ensure_flatpak_app() {
  local app_id="$1"

  if is_flatpak_app_installed "$app_id"; then
    return 0
  fi

  if ! command -v flatpak >/dev/null 2>&1 \
      || ! flatpak --system remotes --columns=name 2>/dev/null | grep -Fxq flathub; then
    warn "Cannot install $app_id because the system Flathub remote is unavailable."
    return 0
  fi

  flatpak --system install -y flathub "$app_id" \
    || warn "Failed to install optional Flatpak application $app_id."
}

configure_dnf() {
  log "Installing dnf helpers and tuning dnf"
  if is_dnf5; then
    ensure_pkg dnf5-plugins
  else
    ensure_pkg dnf-plugins-core
  fi

  local dnf_conf="/etc/dnf/dnf.conf"
  grep -Eq '^max_parallel_downloads=' "$dnf_conf" || echo 'max_parallel_downloads=10' >> "$dnf_conf"
}

system_update() {
  log "Refreshing repositories and updating system"
  dnf upgrade --refresh -y
}

enable_rpm_fusion() {
  log "Enabling RPM Fusion"

  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    dnf install -y "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm"
  fi

  if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    dnf install -y "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
  fi
}

enable_brave_repo() {
  log "Ensuring Brave browser repository exists"

  if grep -Rqs 'brave-browser-rpm-release.s3.brave.com' /etc/yum.repos.d 2>/dev/null; then
    return
  fi

  if is_dnf5; then
    dnf config-manager addrepo --from-repofile="$BRAVE_REPO_URL"
  else
    dnf config-manager --add-repo "$BRAVE_REPO_URL"
  fi
}

install_codecs() {
  log "Installing multimedia codecs"

  dnf group install -y multimedia || warn "Multimedia group install had non-fatal issues."
  dnf group install -y sound-and-video || warn "Sound-and-video group install had non-fatal issues."
}

install_base_packages() {
  local packages=(
    git curl wget micro bash-completion tmux mc unzip p7zip p7zip-plugins unrar
    which rsync ripgrep fd-find bat btop jq fzf ncdu tree tealdeer zoxide
    direnv procs du-dust htop file fastfetch util-linux-user
    google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts
    google-noto-emoji-fonts jetbrains-mono-fonts
    glances iotop smartmontools gparted
    mpv vlc flatpak firewalld fwupd chrony fuse-libs
    firefox brave-browser
    file-roller flameshot
    inxi lshw nmap traceroute bind-utils pavucontrol qview kate evince
    gnome-disk-utility brightnessctl playerctl libreoffice
    geany gwenview libjpeg-turbo-utils
  )

  log "Installing base packages"
  # Personal convenience packages occasionally change names between Fedora
  # releases. Do not let one unavailable optional package abort the complete
  # workstation setup.
  ensure_pkg_if_available "${packages[@]}"
}

install_soft_default_packages() {
  log "Installing soft-default packages when available"
  ensure_pkg_if_available systemd-manager
}

setup_flathub() {
  log "Configuring Flathub"

  command -v flatpak >/dev/null 2>&1 || {
    warn "Flatpak is unavailable; Flathub was not configured."
    return 0
  }

  if ! flatpak --system remote-add --if-not-exists \
      flathub https://flathub.org/repo/flathub.flatpakrepo; then
    warn "Could not configure the system Flathub remote. Flatpak applications will be skipped."
    return 0
  fi

  if ! flatpak --system remotes --columns=name | grep -Fxq flathub; then
    warn "Flathub was not visible after configuration. Flatpak applications will be skipped."
  fi
}

ensure_service_running() {
  local service="$1"

  if systemctl is-enabled "$service" >/dev/null 2>&1; then
    log "$service already enabled"
    if ! systemctl is-active "$service" >/dev/null 2>&1; then
      systemctl start "$service"
    fi
  else
    log "Enabling $service"
    systemctl enable --now "$service"
  fi
}

configure_firewall() {
  log "Checking firewalld"
  ensure_service_running firewalld
}

configure_chrony() {
  log "Checking chrony"
  ensure_pkg chrony
  ensure_service_running chronyd
}

install_keepassxc() {
  if is_pkg_installed keepassxc; then
    log "KeePassXC already installed"
    return
  fi

  if ask_yes_no "Install KeePassXC" "N"; then
    ensure_pkg keepassxc
  fi
}

install_tlp() {
  local conflicting_service

  for conflicting_service in power-profiles-daemon.service tuned-ppd.service; do
    if systemctl is-active "$conflicting_service" >/dev/null 2>&1; then
      if is_pkg_installed tlp; then
        warn "$conflicting_service and TLP are both installed. Review the active power-management services to avoid conflicts."
      else
        warn "$conflicting_service is active; TLP installation was skipped to avoid competing power managers."
      fi
      return
    fi
  done

  if is_pkg_installed tlp; then
    log "TLP already installed"
    return
  fi

  if ask_yes_no "Install TLP" "N"; then
    ensure_pkg tlp tlp-rdw
    systemctl enable --now tlp
  fi
}

install_powertop() {
  if is_pkg_installed powertop; then
    log "Powertop already installed"
    return
  fi

  if ask_yes_no "Install Powertop" "N"; then
    ensure_pkg powertop

    if ask_yes_no "Run Powertop autotune now" "N"; then
      powertop --auto-tune || warn "Powertop autotune failed."
    fi
  fi
}

install_restic() {
  if is_pkg_installed restic; then
    log "Restic already installed"
    return
  fi

  if ask_yes_no "Install Restic" "N"; then
    ensure_pkg_if_available restic
  fi
}

install_terminal_choices() {
  if ! is_pkg_installed tilix; then
    if ask_yes_no "Install Tilix" "N"; then
      ensure_pkg tilix
    fi
  fi

  if ! is_pkg_installed alacritty; then
    if ask_yes_no "Install Alacritty" "N"; then
      ensure_pkg alacritty
    fi
  fi
}

vivaldi_repo_enabled() {
  grep -RqsF "baseurl=https://repo.vivaldi.com/archive/rpm/\$basearch" \
    /etc/yum.repos.d 2>/dev/null \
    && dnf -q repolist --enabled 2>/dev/null \
      | awk '$1 == "vivaldi" { found=1 } END { exit found ? 0 : 1 }'
}

enable_vivaldi_repo() {
  if vivaldi_repo_enabled; then
    return 0
  fi

  if grep -RqsF 'repo.vivaldi.com/archive/rpm' /etc/yum.repos.d 2>/dev/null; then
    warn "A Vivaldi repository configuration exists but is not enabled; leaving it unchanged."
    return 1
  fi

  log "Adding Vivaldi's official RPM repository"
  if is_dnf5; then
    if ! dnf config-manager addrepo --from-repofile="$VIVALDI_REPO_URL"; then
      warn "Could not add Vivaldi's official RPM repository."
      return 1
    fi
  else
    if ! dnf config-manager --add-repo "$VIVALDI_REPO_URL"; then
      warn "Could not add Vivaldi's official RPM repository."
      return 1
    fi
  fi
  if ! vivaldi_repo_enabled; then
    warn "The Vivaldi repository was not enabled after configuration."
    return 1
  fi
}

install_vivaldi() {
  if is_flatpak_app_installed com.vivaldi.Vivaldi; then
    log "Vivaldi is already installed as a Flatpak; keeping it and skipping the RPM package"
    return 0
  fi
  if is_pkg_installed vivaldi-stable; then
    log "Vivaldi RPM already installed"
    return 0
  fi
  if [[ "$(uname -m)" != x86_64 ]]; then
    warn "Vivaldi's official Fedora RPM is unavailable for $(uname -m); skipping Vivaldi."
    return 0
  fi

  if ask_yes_no "Install Vivaldi from its official RPM repository" "N"; then
    if ! enable_vivaldi_repo; then
      warn "Vivaldi was not installed."
      return 0
    fi
    if ! pkg_available vivaldi-stable; then
      warn "vivaldi-stable is unavailable from the configured repository; skipping it."
      return 0
    fi
    if ! dnf install -y vivaldi-stable; then
      warn "Failed to install the optional Vivaldi RPM package."
      return 0
    fi
    is_pkg_installed vivaldi-stable \
      || warn "Vivaldi installation completed without a verifiable vivaldi-stable package."
  fi
}

helium_repo_enabled() {
  dnf -q repolist --enabled 2>/dev/null \
    | awk -v repo="$HELIUM_REPO_ID" '$1 == repo { found=1 } END { exit found ? 0 : 1 }'
}

enable_helium_repo() {
  if helium_repo_enabled; then
    return 0
  fi

  if grep -RqsFx "[$HELIUM_REPO_ID]" /etc/yum.repos.d 2>/dev/null; then
    warn "A Helium COPR configuration exists but is not enabled; leaving it unchanged."
    return 1
  fi

  log "Enabling Helium's official COPR repository"
  # Let COPR detect the Fedora release and architecture and configure signing.
  if ! dnf -y copr enable "$HELIUM_COPR_PROJECT"; then
    warn "Could not enable Helium's COPR repository for this Fedora release and architecture."
    return 1
  fi
  if ! helium_repo_enabled; then
    warn "The Helium repository was not enabled after configuration."
    return 1
  fi
}

install_helium() {
  if is_pkg_installed helium-bin; then
    log "Helium RPM already installed"
    return 0
  fi

  if ask_yes_no "Install Helium browser (beta) from its official COPR repository" "N"; then
    if ! enable_helium_repo; then
      warn "Helium was not installed."
      return 0
    fi
    if ! pkg_available helium-bin; then
      warn "helium-bin is unavailable from the configured repository; skipping it."
      return 0
    fi
    if ! dnf install -y helium-bin; then
      warn "Failed to install the optional Helium RPM package."
      return 0
    fi
    is_pkg_installed helium-bin \
      || warn "Helium installation completed without a verifiable helium-bin package."
  fi
}

librewolf_repo_enabled() {
  # Match the URL within the expected section, not an unrelated repository.
  awk '
    FNR == 1 { in_repo=0 }
    /^[[:space:]]*\[/ { in_repo=($0 ~ /^[[:space:]]*\[librewolf\][[:space:]]*$/) }
    in_repo && /^[[:space:]]*baseurl[[:space:]]*=[[:space:]]*https:\/\/repo\.librewolf\.net\/?[[:space:]]*$/ { found=1 }
    END { exit found ? 0 : 1 }
  ' /etc/yum.repos.d/*.repo 2>/dev/null \
    && dnf -q repolist --enabled 2>/dev/null \
      | awk '$1 == "librewolf" { found=1 } END { exit found ? 0 : 1 }'
}

enable_librewolf_repo() {
  if librewolf_repo_enabled; then
    return 0
  fi

  if [[ -e /etc/yum.repos.d/librewolf.repo ]] \
      || grep -RqsE '^[[:space:]]*\[librewolf\]|librewolf\.net' /etc/yum.repos.d 2>/dev/null; then
    warn "A LibreWolf repository configuration exists but is disabled or differs from the official repository; leaving it unchanged."
    return 1
  fi

  log "Adding LibreWolf's official RPM repository"
  if is_dnf5; then
    if ! dnf config-manager addrepo --from-repofile="$LIBREWOLF_REPO_URL"; then
      warn "Could not add LibreWolf's official RPM repository."
      return 1
    fi
  else
    if ! dnf config-manager --add-repo "$LIBREWOLF_REPO_URL"; then
      warn "Could not add LibreWolf's official RPM repository."
      return 1
    fi
  fi
  if ! librewolf_repo_enabled; then
    warn "The official LibreWolf repository was not enabled after configuration."
    return 1
  fi
}

install_librewolf() {
  if is_pkg_installed librewolf; then
    log "LibreWolf RPM already installed"
    return 0
  fi
  if is_flatpak_app_installed io.gitlab.librewolf-community; then
    log "LibreWolf is already installed as a Flatpak; keeping it and skipping the RPM package"
    return 0
  fi

  if ask_yes_no "Install LibreWolf from its official RPM repository" "N"; then
    if ! enable_librewolf_repo; then
      warn "LibreWolf was not installed."
      return 0
    fi
    if ! pkg_available librewolf; then
      warn "librewolf is unavailable from the configured repository; skipping it."
      return 0
    fi
    if ! dnf install -y librewolf; then
      warn "Failed to install the optional LibreWolf RPM package."
      if [[ "$FEDORA_VERSION" =~ ^[0-9]+$ ]] && (( FEDORA_VERSION <= 42 )); then
        warn "For signing-key errors on Fedora 42 or older, see https://librewolf.net/installation/rhel/#updating-the-gpg-signing-key"
      fi
      return 0
    fi
    is_pkg_installed librewolf \
      || warn "LibreWolf installation completed without a verifiable librewolf package."
  fi
}

install_zen() {
  local package

  if is_flatpak_app_installed app.zen_browser.zen; then
    log "Zen Flatpak already installed"
    return 0
  fi
  for package in zen-browser zen-browser-bin zen; do
    if is_pkg_installed "$package"; then
      log "Zen is already installed as an RPM; skipping the Flatpak package"
      return 0
    fi
  done
  if [[ -x "$ORIGINAL_HOME/.tarball-installations/zen/zen" \
      || -x "$ORIGINAL_HOME/.local/bin/zen" \
      || -x "$ORIGINAL_HOME/.local/bin/zen-browser" \
      || -x /opt/zen/zen ]] \
      || runuser -u "$ORIGINAL_USER" -- env HOME="$ORIGINAL_HOME" \
        sh -c 'command -v zen || command -v zen-browser' >/dev/null 2>&1; then
    log "An existing native Zen installation was detected; skipping the Flatpak package"
    return 0
  fi

  if ask_yes_no "Install Zen Browser from Flathub" "N"; then
    ensure_flatpak_app app.zen_browser.zen
    if is_flatpak_app_installed app.zen_browser.zen; then
      log "Zen Flatpak installed; updates are handled by Flatpak"
    else
      warn "Zen Flatpak installation could not be verified; continuing setup."
    fi
  fi
}

install_optional_browsers() {
  install_vivaldi
  install_helium
  install_librewolf
  install_zen

  if is_pkg_installed chromium; then
    log "Chromium already installed"
  elif ask_yes_no "Install Chromium" "N"; then
    ensure_pkg chromium
  fi
}

is_signal_installed() {
  is_pkg_installed signal-desktop && return 0
  is_flatpak_app_installed org.signal.Signal && return 0
  [[ -e "$ORIGINAL_HOME/.local/bin/signal-desktop.AppImage" \
      || -L "$ORIGINAL_HOME/.local/bin/signal-desktop.AppImage" \
      || -e "$ORIGINAL_HOME/.local/share/applications/signal-appimage.desktop" ]] && return 0
  runuser -u "$ORIGINAL_USER" -- env HOME="$ORIGINAL_HOME" \
    sh -c 'command -v signal-desktop || command -v signal-desktop.AppImage' >/dev/null 2>&1
}

install_verified_signal_appimage() (
  # Use a subshell so cleanup does not replace any caller's traps.
  local staging key_fingerprints
  staging="$(mktemp -d /tmp/fedora-signal.XXXXXXXX)" || return 1
  trap 'rm -rf -- "$staging"' EXIT
  mkdir -m 700 "$staging/gnupg" || return 1

  local filename url
  for filename in signal-desktop.AppImage signal-desktop.AppImage.gpg appimage.asc; do
    if [[ "$filename" == appimage.asc ]]; then
      url="https://updates.signal.org/static/desktop/appimage.asc"
    else
      url="https://updates.signal.org/desktop/$filename"
    fi
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 30 --retry 2 --output "$staging/$filename" "$url" || return 1
  done

  key_fingerprints="$(gpg --no-options --batch --homedir "$staging/gnupg" \
    --with-colons --show-keys "$staging/appimage.asc" \
    | awk -F: '$1 == "pub" { primary=1; next } primary && $1 == "fpr" { print $10; primary=0 }')" \
    || return 1
  if [[ "$key_fingerprints" != "$SIGNAL_APPIMAGE_KEY_FINGERPRINT" ]]; then
    warn "Signal signing key did not match the pinned official fingerprint."
    return 1
  fi
  gpg --no-options --batch --homedir "$staging/gnupg" \
    --import "$staging/appimage.asc" || return 1
  gpg --no-options --batch --homedir "$staging/gnupg" \
    --verify "$staging/signal-desktop.AppImage.gpg" "$staging/signal-desktop.AppImage" || return 1

  # Let the desktop user copy the verified file, avoiding root writes through
  # user-controlled paths. The root-owned staging area remains read-only to them.
  chmod 755 "$staging" || return 1
  chmod 644 "$staging/signal-desktop.AppImage" || return 1
  runuser -u "$ORIGINAL_USER" -- env \
    -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    HOME="$ORIGINAL_HOME" bash -e -s -- "$staging/signal-desktop.AppImage" "$ORIGINAL_HOME" <<'SIGNAL_INSTALL'
source_image="$1"
user_home="$2"
bin_dir="$user_home/.local/bin"
applications_dir="$user_home/.local/share/applications"
mkdir -p -- "$bin_dir" "$applications_dir"
image_tmp="$(mktemp "$bin_dir/.signal-appimage.XXXXXXXX")"
desktop_tmp=""
trap 'rm -f -- "$image_tmp" ${desktop_tmp:+"$desktop_tmp"}' EXIT
install -m 755 -- "$source_image" "$image_tmp"
# Escape a quoted Exec argument per the Desktop Entry specification.
exec_path="$bin_dir/signal-desktop.AppImage"
exec_path="${exec_path//\\/\\\\\\\\}"
exec_path="${exec_path//\"/\\\\\"}"
exec_path="${exec_path//\$/\\\\\$}"
exec_path="${exec_path//\`/\\\\\`}"
exec_path="${exec_path//%/%%}"
desktop_tmp="$(mktemp "$applications_dir/.signal-desktop.XXXXXXXX")"
cat > "$desktop_tmp" <<DESKTOP
[Desktop Entry]
Name=Signal
Comment=Private messaging from your desktop
Exec="$exec_path" %U
Terminal=false
Type=Application
Icon=signal-desktop
StartupWMClass=signal
MimeType=x-scheme-handler/sgnl;x-scheme-handler/signalcaptcha;
Categories=Network;InstantMessaging;Chat;
DESKTOP
chmod 644 "$desktop_tmp"
mv -f -- "$image_tmp" "$bin_dir/signal-desktop.AppImage"
mv -f -- "$desktop_tmp" "$applications_dir/signal-appimage.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" || true
fi
SIGNAL_INSTALL
)

install_signal() {
  if is_signal_installed; then
    log "Signal is already installed; skipping installation"
    return 0
  fi
  if [[ "$(uname -m)" != x86_64 ]]; then
    warn "Signal's official AppImage requires x86_64; skipping Signal."
    return 0
  fi
  if ask_yes_no "Install Signal Desktop (official, signature-verified AppImage)" "N"; then
    if ! ensure_pkg curl gnupg2 fuse-libs; then
      warn "Could not install Signal's prerequisites; skipping Signal."
      return 0
    fi
    if ! install_verified_signal_appimage; then
      warn "Signal installation failed; continuing setup."
      return 0
    fi
    log "Signal installed for $ORIGINAL_USER; launch it from the application menu. Automatic updates are managed by Signal."
  fi
}

install_optional_apps() {
  install_signal

  if is_pkg_installed gimp; then
    log "GIMP already installed"
  elif ask_yes_no "Install GIMP" "N"; then
    ensure_pkg gimp
  fi

  if is_pkg_installed krita; then
    log "Krita already installed"
  elif ask_yes_no "Install Krita" "N"; then
    ensure_pkg krita
  fi

  if is_pkg_installed kdenlive; then
    log "Kdenlive already installed"
  elif ask_yes_no "Install Kdenlive" "N"; then
    ensure_pkg kdenlive
  fi

  if is_pkg_installed qbittorrent; then
    log "qBittorrent already installed"
  elif is_flatpak_app_installed org.qbittorrent.qBittorrent; then
    log "qBittorrent Flatpak already installed"
  elif ask_yes_no "Install qBittorrent" "N"; then
    if pkg_available qbittorrent; then
      ensure_pkg qbittorrent
    else
      ensure_flatpak_app org.qbittorrent.qBittorrent
    fi
  fi

  if is_flatpak_app_installed com.spotify.Client; then
    log "Spotify already installed"
  elif ask_yes_no "Install Spotify (Flatpak)" "N"; then
    ensure_flatpak_app com.spotify.Client
  fi
}

configure_shell_tools() {
  log "Configuring shell helpers for $ORIGINAL_USER"

  local bashrc="$ORIGINAL_HOME/.bashrc"

  append_line_if_missing "$bashrc" ''
  append_line_if_missing "$bashrc" '# User-local executables'
  # These expressions must remain literal for the user's future shell.
  # shellcheck disable=SC2016
  append_line_if_missing "$bashrc" 'export PATH="$HOME/.local/bin:$PATH"'

  append_line_if_missing "$bashrc" ''
  append_line_if_missing "$bashrc" '# Ignore consecutive duplicates and commands starting with a space in history'
  # Preserve existing options and avoid duplicates when .bashrc is sourced again.
  # shellcheck disable=SC2016
  append_line_if_missing "$bashrc" 'case ":${HISTCONTROL-}:" in *:ignoredups:*|*:ignoreboth:*) ;; *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}ignoredups" ;; esac'
  # shellcheck disable=SC2016
  append_line_if_missing "$bashrc" 'case ":${HISTCONTROL-}:" in *:ignorespace:*|*:ignoreboth:*) ;; *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}ignorespace" ;; esac'

  if command -v zoxide >/dev/null 2>&1; then
    append_line_if_missing "$bashrc" ''
    append_line_if_missing "$bashrc" '# zoxide'
    # shellcheck disable=SC2016
    append_line_if_missing "$bashrc" 'eval "$(zoxide init bash)"'
  else
    warn "zoxide is unavailable; its shell initialization was not added."
  fi

  if command -v direnv >/dev/null 2>&1; then
    append_line_if_missing "$bashrc" ''
    append_line_if_missing "$bashrc" '# direnv'
    # shellcheck disable=SC2016
    append_line_if_missing "$bashrc" 'eval "$(direnv hook bash)"'
  else
    warn "direnv is unavailable; its shell initialization was not added."
  fi

  chown "$ORIGINAL_USER":"$(id -gn "$ORIGINAL_USER")" "$bashrc"
}

print_summary() {
cat <<SUMMARY

Base setup finished.

SUMMARY
}

main() {
  parse_args "$@"
  require_fedora
  resolve_execution_context

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<PLAN
Fedora base setup dry-run for $ORIGINAL_USER; no commands will be executed.

Would perform:
  - tune DNF and upgrade Fedora packages
  - enable RPM Fusion and the Brave repository
  - install multimedia codecs, base packages, fonts, and desktop utilities
  - configure Flathub, firewalld, and chrony
  - configure $ORIGINAL_HOME/.bashrc, including $ORIGINAL_HOME/.local/bin in PATH
  - configure Bash history to ignore consecutive duplicates and commands starting with a space
  - ask about optional backup/power tools, terminals, browsers, and desktop applications
  - install optional Vivaldi from its official RPM repository unless its Flatpak already exists
  - ask before installing Helium (beta) from its official COPR repository
  - ask before installing LibreWolf from its official RPM repository unless already installed as a Flatpak
  - ask before installing Zen Browser from Flathub unless an existing installation is detected
  - ask before installing Signal's official AppImage for $ORIGINAL_USER, verifying its pinned signing key and signature
PLAN
    return
  fi

  acquire_lock

  configure_dnf
  system_update
  enable_rpm_fusion
  enable_brave_repo
  system_update
  install_codecs
  install_base_packages
  setup_flathub
  install_soft_default_packages
  configure_firewall
  configure_chrony
  install_keepassxc
  install_tlp
  install_powertop
  install_restic
  install_terminal_choices
  install_optional_browsers
  install_optional_apps
  configure_shell_tools
  print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
