#!/usr/bin/env bash
set -euo pipefail

# Fedora dev setup (Docker-first)
# Run with: sudo bash ./bash-scripts/os/fedora/setup/fedora-setup-03-dev.sh

DRY_RUN=0
ORIGINAL_USER=""
ORIGINAL_HOME=""
TEMP_DIRS=()
NEW_TEMP_DIR=""
LOCK_FILE="/run/lock/fedora-setup-03-dev.lock"
readonly VSCODE_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
readonly VSCODE_REPO_BASEURL="https://packages.microsoft.com/yumrepos/vscode"

usage() {
  cat <<EOF
Install Fedora development tools and Docker, with optional language and GUI tools.

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
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (provided by util-linux)."
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another developer setup process is already running."
}

cleanup_temp_dirs() {
  local dir
  for dir in "${TEMP_DIRS[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] && rm -rf -- "$dir"
  done
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
      read -r -p "$prompt [Y/n]: " reply || true
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply || true
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

is_pkg_available() {
  dnf -q list --available "$1" >/dev/null 2>&1 || dnf -q info "$1" >/dev/null 2>&1
}

ensure_pkg() {
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

is_flatpak_app_installed() {
  local app_id="$1"
  command -v flatpak >/dev/null 2>&1 || return 1

  flatpak --system info "$app_id" >/dev/null 2>&1 && return 0
  if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != root ]] \
      && command -v runuser >/dev/null 2>&1; then
    runuser -u "$ORIGINAL_USER" -- env HOME="$ORIGINAL_HOME" \
      flatpak --user info "$app_id" >/dev/null 2>&1 && return 0
  fi
  return 1
}

ensure_flatpak_app() {
  local app_id="$1"
  if is_flatpak_app_installed "$app_id"; then
    return 0
  fi

  if command -v flatpak >/dev/null 2>&1; then
    if ! flatpak --system remotes --columns=name 2>/dev/null | grep -Fxq flathub; then
      warn "System Flathub remote not found, skipping $app_id"
    else
      flatpak --system install -y flathub "$app_id" \
        || warn "Failed to install optional Flatpak application $app_id"
    fi
  else
    warn "Flatpak not found, skipping $app_id"
  fi
}

run_as_original_user() {
  runuser -u "$ORIGINAL_USER" -- env HOME="$ORIGINAL_HOME" "$@"
}

ensure_npm_global() {
  local package="$1"
  local binary="$2"

  # The positional parameter is intentionally expanded by the child shell.
  # shellcheck disable=SC2016
  if run_as_original_user sh -c 'command -v "$1" >/dev/null 2>&1' sh "$binary" \
      || [[ -x "$ORIGINAL_HOME/.local/bin/$binary" ]]; then
    log "$binary already installed"
    return
  fi

  if command -v npm >/dev/null 2>&1; then
    log "Installing $package for $ORIGINAL_USER under $ORIGINAL_HOME/.local"
    run_as_original_user npm install -g --prefix "$ORIGINAL_HOME/.local" "$package"
  else
    warn "npm not found, skipping $package"
  fi
}

ensure_docker_repo() {
  local repo_file="/etc/yum.repos.d/docker-ce.repo"

  if [[ -f "$repo_file" ]]; then
    return
  fi

  log "Adding Docker repository"
  dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
}

remove_docker_conflicts_if_approved() {
  local -a known_conflicts=(
    docker docker-client docker-client-latest docker-common docker-latest
    docker-latest-logrotate docker-logrotate docker-selinux
    docker-engine-selinux docker-engine podman-docker
  )
  local -a installed_conflicts=()
  local pkg

  for pkg in "${known_conflicts[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 && installed_conflicts+=("$pkg")
  done
  (( ${#installed_conflicts[@]} > 0 )) || return 0

  warn "Docker CE conflicts with installed package(s): ${installed_conflicts[*]}"
  if ! ask_yes_no "Remove only these conflicting packages before installing Docker CE" "N"; then
    warn "Docker CE installation skipped; no conflicting packages were removed."
    return 1
  fi

  dnf remove -y "${installed_conflicts[@]}"
}

new_temp_dir() {
  NEW_TEMP_DIR="$(mktemp -d)"
  TEMP_DIRS+=("$NEW_TEMP_DIR")
}

download_verified_github_asset() {
  local repo="$1"
  local name_pattern="$2"
  local destination="$3"
  local release_json asset asset_name download_url digest expected

  release_json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest")"
  asset="$(
    printf '%s\n' "$release_json" | jq -r --arg pattern "$name_pattern" '
      [.assets[] | select(.name | test($pattern))]
      | if length == 1 then
          .[0] | [.name, .browser_download_url, (.digest // "")] | @tsv
        else
          empty
        end
    '
  )"

  if [[ -z "$asset" ]]; then
    warn "Could not find exactly one release asset matching ${name_pattern} in ${repo}"
    return 1
  fi

  IFS=$'\t' read -r asset_name download_url digest <<< "$asset"
  case "$download_url" in
    "https://github.com/${repo}/releases/download/"*) ;;
    *)
      warn "Refusing unexpected GitHub asset URL: $download_url"
      return 1
      ;;
  esac
  case "$digest" in
    sha256:*) expected="${digest#sha256:}" ;;
    *)
      warn "GitHub did not provide a SHA-256 digest for $asset_name"
      return 1
      ;;
  esac

  curl -fsSL "$download_url" -o "$destination"
  if ! printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status; then
    warn "Checksum verification failed for $asset_name"
    return 1
  fi
}

archive_paths_are_safe() {
  local archive="$1"
  ! tar -tzf "$archive" | awk '
    /^\// { bad=1 }
    { n=split($0, parts, "/"); for (i=1; i<=n; i++) if (parts[i] == "..") bad=1 }
    END { exit bad ? 0 : 1 }
  '
}

install_core_tools() {
  local packages=(
    git curl unzip tar make gcc gcc-c++ pkgconf-pkg-config jq
    python3 nodejs npm ca-certificates openssl shellcheck yq
    postgresql redis
  )

  log "Installing core dev tools"
  ensure_pkg "${packages[@]}"

  log "Installing Codex CLI"
  ensure_npm_global @openai/codex codex
}

install_docker() {
  local docker_pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

  if command -v docker >/dev/null 2>&1 && rpm -q "${docker_pkgs[@]}" >/dev/null 2>&1; then
    log "Docker already installed"
  else
    log "Installing Docker"
    if dnf --version 2>/dev/null | head -n1 | grep -q '^dnf5 '; then
      ensure_pkg dnf5-plugins
    else
      ensure_pkg dnf-plugins-core
    fi
    ensure_docker_repo
    if ! remove_docker_conflicts_if_approved; then
      return 0
    fi
    if ! dnf -q repoquery --available docker-ce >/dev/null 2>&1; then
      warn "Docker CE is unavailable for this Fedora release/architecture; skipping Docker installation."
      return 0
    fi
    ensure_pkg "${docker_pkgs[@]}"
  fi

  if ! systemctl is-enabled docker >/dev/null 2>&1; then
    systemctl enable --now docker
  else
    systemctl start docker || true
  fi

  if ! systemctl is-active docker >/dev/null 2>&1; then
    warn "Docker was installed but docker.service is not active. Check: journalctl -u docker"
    return 0
  fi

  if id -nG "$ORIGINAL_USER" | tr ' ' '\n' | grep -qx docker; then
    log "User $ORIGINAL_USER already in docker group"
  elif ask_yes_no "Docker group membership grants root-equivalent access. Add $ORIGINAL_USER to the docker group" "N"; then
    usermod -aG docker "$ORIGINAL_USER"
    log "Added $ORIGINAL_USER to docker group (relogin required)"
  else
    warn "$ORIGINAL_USER was not added to the docker group; this will be asked again next run"
  fi
}

install_go() {
  if is_pkg_installed golang; then
    log "Go already installed"
    return
  fi

  if ask_yes_no "Install Go" "N"; then
    ensure_pkg golang
  fi
}

install_php_stack() {
  if command -v php >/dev/null 2>&1 && command -v composer >/dev/null 2>&1 && command -v symfony >/dev/null 2>&1; then
    log "PHP / Composer / Symfony CLI already installed"
    return
  fi

  if ask_yes_no "Install PHP + Composer + Symfony CLI + extensions" "N"; then
    ensure_pkg php php-cli php-common php-pgsql php-mbstring php-xml php-curl php-zip php-intl php-opcache composer

    if ! command -v symfony >/dev/null 2>&1; then
      local symfony_arch symfony_tmp symfony_rpm
      case "$(uname -m)" in
        x86_64) symfony_arch="x86_64" ;;
        aarch64|arm64) symfony_arch="aarch64" ;;
        *) warn "Unsupported architecture for Symfony CLI: $(uname -m)"; return ;;
      esac
      new_temp_dir
      symfony_tmp="$NEW_TEMP_DIR"
      symfony_rpm="$symfony_tmp/symfony-cli.rpm"
      if download_verified_github_asset symfony-cli/symfony-cli \
          "symfony-cli-.*-1[.]${symfony_arch}[.]rpm$" "$symfony_rpm"; then
        dnf install -y "$symfony_rpm"
      else
        warn "Verified Symfony CLI download failed; Symfony CLI was not installed"
      fi
    fi
  fi
}

install_watchexec() {
  if command -v watchexec >/dev/null 2>&1; then
    return
  fi

  if is_pkg_available watchexec; then
    ensure_pkg watchexec
    return
  fi

  if command -v cargo >/dev/null 2>&1; then
    log "Installing watchexec via cargo"
    run_as_original_user cargo install watchexec-cli || warn "Failed to install watchexec via cargo"
    return
  fi

  warn "watchexec package is not available in current Fedora repositories and cargo is not installed; skipping watchexec"
}

install_helpers() {
  local need_prompt=0
  command -v mkcert >/dev/null 2>&1 || need_prompt=1
  command -v mailpit >/dev/null 2>&1 || need_prompt=1
  command -v watchexec >/dev/null 2>&1 || need_prompt=1

  if (( need_prompt == 0 )); then
    log "mkcert / Mailpit / watchexec already installed"
    return
  fi

  if ask_yes_no "Install mkcert + Mailpit + watchexec" "N"; then
    if ! command -v mkcert >/dev/null 2>&1; then
      ensure_pkg mkcert
    fi

    if ! command -v mailpit >/dev/null 2>&1; then
      local mailpit_arch mailpit_tmp mailpit_archive
      case "$(uname -m)" in
        x86_64) mailpit_arch="amd64" ;;
        aarch64|arm64) mailpit_arch="arm64" ;;
        *) warn "Unsupported architecture for Mailpit: $(uname -m)"; mailpit_arch="" ;;
      esac
      if [[ -n "$mailpit_arch" ]]; then
        new_temp_dir
        mailpit_tmp="$NEW_TEMP_DIR"
        mailpit_archive="$mailpit_tmp/mailpit.tar.gz"
        if download_verified_github_asset axllent/mailpit \
            "mailpit-linux-${mailpit_arch}[.]tar[.]gz$" "$mailpit_archive" \
            && archive_paths_are_safe "$mailpit_archive" \
            && tar -xzf "$mailpit_archive" -C "$mailpit_tmp" \
            && [[ -f "$mailpit_tmp/mailpit" ]]; then
          install -m 0755 "$mailpit_tmp/mailpit" /usr/local/bin/mailpit
        else
          warn "Verified Mailpit installation failed"
        fi
      fi
    fi

    install_watchexec
  fi
}

vscode_repo_enabled() {
  grep -RqsF "baseurl=${VSCODE_REPO_BASEURL}" /etc/yum.repos.d 2>/dev/null \
    && dnf -q repolist --enabled 2>/dev/null \
      | awk '$1 == "code" { found=1 } END { exit found ? 0 : 1 }'
}

enable_vscode_repo() {
  local repo_file="/etc/yum.repos.d/vscode.repo"
  local repo_tmp

  if vscode_repo_enabled; then
    return 0
  fi

  if grep -RqsE '^\[code\][[:space:]]*$' /etc/yum.repos.d 2>/dev/null \
      || grep -RqsF "$VSCODE_REPO_BASEURL" /etc/yum.repos.d 2>/dev/null; then
    warn "A VS Code repository configuration exists but is not the enabled official repository; leaving it unchanged."
    return 1
  fi
  if [[ -e "$repo_file" ]]; then
    warn "$repo_file already exists; refusing to overwrite it."
    return 1
  fi

  log "Adding Microsoft's official VS Code RPM repository"
  if ! rpm --import "$VSCODE_KEY_URL"; then
    warn "Could not import Microsoft's package-signing key."
    return 1
  fi

  new_temp_dir
  repo_tmp="$NEW_TEMP_DIR/vscode.repo"
  printf '%s\n' \
    '[code]' \
    'name=Visual Studio Code' \
    "baseurl=${VSCODE_REPO_BASEURL}" \
    'enabled=1' \
    'autorefresh=1' \
    'type=rpm-md' \
    'gpgcheck=1' \
    "gpgkey=${VSCODE_KEY_URL}" > "$repo_tmp"

  if ! install -m 0644 "$repo_tmp" "$repo_file"; then
    warn "Could not install the VS Code repository configuration."
    return 1
  fi
  if ! vscode_repo_enabled; then
    rm -f -- "$repo_file"
    warn "The VS Code repository was not enabled after configuration; removed $repo_file."
    return 1
  fi
}

install_vscode() {
  if is_flatpak_app_installed com.visualstudio.code; then
    log "VS Code is already installed as a Flatpak; keeping it and skipping the RPM package"
    return 0
  fi
  if is_pkg_installed code; then
    log "VS Code RPM already installed"
    return 0
  fi
  case "$(uname -m)" in
    x86_64|aarch64|arm64|armv7hl|armv7l) ;;
    *) warn "Microsoft's VS Code RPM is unavailable for $(uname -m); skipping VS Code."; return 0 ;;
  esac

  if ! enable_vscode_repo; then
    warn "VS Code was not installed."
    return 0
  fi
  if ! is_pkg_available code; then
    warn "The code package is unavailable from the configured repository; skipping it."
    return 0
  fi
  if ! dnf install -y code; then
    warn "Failed to install the optional VS Code RPM package."
    return 0
  fi
  is_pkg_installed code \
    || warn "VS Code installation completed without a verifiable code package."
}

install_gui_tools() {
  local need_prompt=0

  is_flatpak_app_installed io.dbeaver.DBeaverCommunity || need_prompt=1
  is_flatpak_app_installed com.redis.RedisInsight || need_prompt=1
  if ! is_pkg_installed code && ! is_flatpak_app_installed com.visualstudio.code; then
    need_prompt=1
  fi

  if (( need_prompt == 0 )); then
    log "GUI dev tools already installed"
    return
  fi

  if ask_yes_no "Install GUI dev tools (DBeaver and RedisInsight Flatpaks, VS Code RPM)" "N"; then
    ensure_flatpak_app io.dbeaver.DBeaverCommunity
    ensure_flatpak_app com.redis.RedisInsight
    install_vscode
  fi
}

install_lazygit() {
  if command -v lazygit >/dev/null 2>&1; then
    return
  fi

  if is_pkg_available lazygit; then
    ensure_pkg lazygit
    return
  fi

  local arch tmp_dir tar_name extracted_dir binary_path
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      warn "Unsupported architecture for lazygit fallback: $(uname -m). Skipping lazygit."
      return
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found, cannot install lazygit fallback"
    return
  fi

  tar_name="lazygit.tar.gz"
  new_temp_dir
  tmp_dir="$NEW_TEMP_DIR"

  log "Installing lazygit via GitHub release"
  if ! download_verified_github_asset jesseduffield/lazygit \
      "lazygit_.*_linux_${arch}[.]tar[.]gz$" "$tmp_dir/$tar_name"; then
    warn "Failed to download and verify lazygit release archive"
    return
  fi

  if ! archive_paths_are_safe "$tmp_dir/$tar_name" \
      || ! tar -xzf "$tmp_dir/$tar_name" -C "$tmp_dir"; then
    warn "Failed to safely extract lazygit archive"
    return
  fi

  binary_path="$tmp_dir/lazygit"
  if [[ ! -f "$binary_path" ]]; then
    extracted_dir="$(find "$tmp_dir" -maxdepth 2 -type f -name lazygit | head -n1 || true)"
    binary_path="$extracted_dir"
  fi

  if [[ -z "$binary_path" || ! -f "$binary_path" ]]; then
    warn "lazygit binary not found after extraction"
    return
  fi

  install -m 0755 "$binary_path" /usr/local/bin/lazygit
}

install_git_helpers() {
  local need_prompt=0

  if ! command -v delta >/dev/null 2>&1 && ! is_pkg_installed git-delta; then
    need_prompt=1
  fi
  if ! command -v lazygit >/dev/null 2>&1; then
    need_prompt=1
  fi

  if (( need_prompt == 0 )); then
    log "Git helpers already installed"
    return
  fi

  if ask_yes_no "Install Git helpers (delta, lazygit)" "N"; then
    if is_pkg_available git-delta || is_pkg_installed git-delta; then
      ensure_pkg git-delta
    else
      warn "git-delta package not available; skipping delta"
    fi

    install_lazygit
  fi
}


install_github_cli() {
  if command -v gh >/dev/null 2>&1 || is_pkg_installed gh; then
    log "GitHub CLI already installed"
    return
  fi

  if ask_yes_no "Install GitHub CLI (gh)" "N"; then
    if is_pkg_available gh; then
      ensure_pkg gh
    else
      warn "GitHub CLI package 'gh' is not available in current repositories; skipping"
    fi
  fi
}

print_summary() {
  echo
  echo "Dev setup completed."
  echo "You may need to relogin for Docker group changes."
}

main() {
  parse_args "$@"
  require_fedora
  resolve_execution_context

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<PLAN
Fedora developer setup dry-run for $ORIGINAL_USER; no commands will be executed.

Would perform:
  - install core development tools, Node.js, npm, PostgreSQL client tools, and Redis
  - install Codex as $ORIGINAL_USER under $ORIGINAL_HOME/.local (never through root npm)
  - install and enable Docker
  - ask whether to add $ORIGINAL_USER to the root-equivalent docker group
  - ask about Go, PHP/Symfony, Mailpit, watchexec, GUI tools, and Git helpers
  - install optional VS Code from Microsoft's official RPM repository unless its Flatpak already exists
  - download verified release assets only for optional tools selected by the user
PLAN
    return
  fi

  acquire_lock

  trap cleanup_temp_dirs EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  install_core_tools
  install_docker
  install_go
  install_php_stack
  install_helpers
  install_gui_tools
  install_git_helpers
  install_github_cli
  print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
