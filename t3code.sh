#!/usr/bin/env bash
#
# t3code.sh
#
# Installs and runs T3 Code AppImage on Linux.
#
# What it does:
# - checks whether T3 Code is installed under ~/.local/opt/t3code
# - downloads the latest AppImage from the GitHub releases API if missing
# - can force-update the installed AppImage
# - extracts the AppImage into a versioned installation and runs without FUSE
# - can retry with --no-sandbox only when explicitly allowed
# - can run the app in background so the current terminal stays usable
#
# Supported wrapper arguments:
#   --bg        Run T3 Code in background
#   --update    Force download of the latest AppImage before running
#   --allow-no-sandbox  Permit the less secure Chromium sandbox fallback
#   --recover   Stop stale T3 Code processes before launching
#   --help      Show this help
#   --          Everything after this is passed to T3 Code unchanged
#
# Examples:
#   ./bash-scripts/t3code.sh
#   ./bash-scripts/t3code.sh --bg
#   ./bash-scripts/t3code.sh --update
#   ./bash-scripts/t3code.sh --bg --update
#   ./bash-scripts/t3code.sh --allow-no-sandbox
#   ./bash-scripts/t3code.sh -- --verbose
#
# Notes:
# - supports Ubuntu and Fedora style systems
# - installs curl, jq, and checksum tools automatically if missing
# - AppImage is stored in ~/.local/opt/t3code
# - extracted releases are stored under ~/.local/opt/t3code/releases
# - a symlink is created at ~/.local/bin/t3code

set -euo pipefail

REPO_OWNER="pingdotgg"
REPO_NAME="t3code"
REPO="${REPO_OWNER}/${REPO_NAME}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}")"

INSTALL_DIR="${HOME}/.local/opt/t3code"
LAUNCHER_PATH="${INSTALL_DIR}/launcher.sh"
BIN_DIR="${HOME}/.local/bin"
APPIMAGE_PATH="${INSTALL_DIR}/T3-Code.AppImage"
LINK_PATH="${BIN_DIR}/t3code"
RELEASES_DIR="${INSTALL_DIR}/releases"
CURRENT_LINK="${INSTALL_DIR}/current"
CURRENT_APP="${CURRENT_LINK}/AppRun"
LOCK_PATH="${INSTALL_DIR}/launcher.lock"
STARTUP_TIMEOUT=45

BG=false
FORCE_UPDATE=false
APP_ARGS=()
ALLOW_NO_SANDBOX=false
RECOVER=false
INSTALL_TMP=""
LAUNCHER_TMP=""
EXTRACT_TMP=""
PREPARED_RELEASE=""
PREVIOUS_RELEASE=""
UPDATED_THIS_RUN=false
LAUNCH_LOCKED=false

cleanup_install_tmp() {
    if [[ -n "$LAUNCHER_TMP" ]]; then
        rm -f -- "$LAUNCHER_TMP"
    fi
    if [ -n "$INSTALL_TMP" ] && [ -e "$INSTALL_TMP" ]; then
        rm -f -- "$INSTALL_TMP"
    fi
    if [[ -n "$EXTRACT_TMP" && "$EXTRACT_TMP" == "$INSTALL_DIR"/.extract.* && -d "$EXTRACT_TMP" ]]; then
        rm -rf -- "$EXTRACT_TMP"
    fi
}

print_help() {
    cat <<HELP
Install and launch the T3 Code AppImage on Linux.

Usage: "$0" [wrapper-options] [-- application-arguments]

Arguments:
  application-arguments  Arguments forwarded unchanged to T3 Code after --.

Wrapper options:
  --bg                Run T3 Code in the background.
  --update            Force download of the latest AppImage before launch.
  --allow-no-sandbox  Permit the reduced-security Chromium fallback.
  --recover           Stop stale T3 Code processes before launch.
  -h, --help          Show this help.
  --                  Forward all following arguments to T3 Code unchanged.

Examples:
  ./bash-scripts/t3code.sh
  ./bash-scripts/t3code.sh --bg
  ./bash-scripts/t3code.sh --update
  ./bash-scripts/t3code.sh --recover
  ./bash-scripts/t3code.sh --allow-no-sandbox
  ./bash-scripts/t3code.sh -- --verbose

T3 Code is run from a persistent extracted release. This avoids AppImage FUSE
mount failures. An explicitly permitted --no-sandbox retry is used only when
the log indicates a Chromium sandbox failure.
HELP
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_pkg_manager() {
    if have_cmd apt-get; then
        echo "apt"
        return
    fi

    if have_cmd dnf; then
        echo "dnf"
        return
    fi

    echo ""
}

install_required_tools() {
    local missing=()

    have_cmd curl || missing+=("curl")
    have_cmd jq || missing+=("jq")
    have_cmd sha256sum || missing+=("coreutils")
    have_cmd flock || missing+=("util-linux")

    if [ "${#missing[@]}" -eq 0 ]; then
        return
    fi

    local pm
    pm="$(detect_pkg_manager)"

    if [ -z "$pm" ]; then
        echo "Error: curl is missing, and no supported package manager was found (apt-get / dnf)." >&2
        exit 1
    fi

    echo "Installing required packages: ${missing[*]}"

    case "$pm" in
        apt)
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
            ;;
        dnf)
            sudo dnf install -y "${missing[@]}"
            ;;
    esac
}

is_installed() {
    [ -x "$APPIMAGE_PATH" ]
}

acquire_launch_lock() {
    mkdir -p "$INSTALL_DIR"
    exec 9>"$LOCK_PATH"
    if ! flock -w 30 9; then
        echo "Error: another T3 Code install or launch is still being prepared." >&2
        exit 1
    fi
    LAUNCH_LOCKED=true
}

release_launch_lock() {
    if [ "$LAUNCH_LOCKED" = true ]; then
        flock -u 9
        LAUNCH_LOCKED=false
    fi
}

prepare_extracted_release() {
    local image_path="$1"
    local digest release_dir extracted_root

    digest="$(sha256sum "$image_path" | awk '{print $1}')"
    release_dir="${RELEASES_DIR}/${digest}"

    if [ -x "${release_dir}/AppRun" ]; then
        PREPARED_RELEASE="$release_dir"
        return
    fi

    mkdir -p "$RELEASES_DIR"
    EXTRACT_TMP="$(mktemp -d "${INSTALL_DIR}/.extract.XXXXXX")"
    echo "Extracting T3 Code into a FUSE-free installation..."
    (
        cd "$EXTRACT_TMP"
        "$image_path" --appimage-extract >/dev/null
    )

    extracted_root="${EXTRACT_TMP}/squashfs-root"
    if [ ! -x "${extracted_root}/AppRun" ]; then
        echo "Error: the AppImage did not contain an executable AppRun." >&2
        exit 1
    fi

    if [ -e "$release_dir" ]; then
        echo "Error: incomplete extracted release already exists: $release_dir" >&2
        exit 1
    fi

    mv "$extracted_root" "$release_dir"
    rmdir "$EXTRACT_TMP"
    EXTRACT_TMP=""
    PREPARED_RELEASE="$release_dir"
}

activate_release() {
    local release_dir="$1"
    local new_link="${CURRENT_LINK}.new.$$"

    if [ -L "$CURRENT_LINK" ]; then
        PREVIOUS_RELEASE="$(readlink -f "$CURRENT_LINK" || true)"
    else
        PREVIOUS_RELEASE=""
    fi

    ln -s "$release_dir" "$new_link"
    mv -Tf "$new_link" "$CURRENT_LINK"
    install_launcher
}

install_launcher() {
    # Keep shortcuts independent of the source script's location. Invoking the
    # installed copy must not replace the file Bash is currently reading.
    if [[ "$SCRIPT_PATH" != "$LAUNCHER_PATH" ]]; then
        LAUNCHER_TMP="$(mktemp "${INSTALL_DIR}/.launcher.XXXXXX")"
        cp -- "$SCRIPT_PATH" "$LAUNCHER_TMP"
        chmod 755 "$LAUNCHER_TMP"
        mv -fT -- "$LAUNCHER_TMP" "$LAUNCHER_PATH"
        LAUNCHER_TMP=""
    fi
    ln -sfn "$LAUNCHER_PATH" "$LINK_PATH"
}

restore_previous_release() {
    local new_link="${CURRENT_LINK}.rollback.$$"

    [ "$UPDATED_THIS_RUN" = true ] || return 0
    [ -n "$PREVIOUS_RELEASE" ] || return 0
    [ -x "${PREVIOUS_RELEASE}/AppRun" ] || return 0

    ln -s "$PREVIOUS_RELEASE" "$new_link"
    mv -Tf "$new_link" "$CURRENT_LINK"
    echo "Restored the previous T3 Code release after the updated release failed to start." >&2
}

update_existing_desktop_entries() {
    local desktop_file
    local current_handler
    local applications_dir="${HOME}/.local/share/applications"

    # T3 Code regenerates com.t3tools.T3Code.desktop. Own a separate entry so
    # startup and application updates cannot replace our launcher command.
    mkdir -p "$applications_dir"
    cat >"${applications_dir}/t3code-launcher.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=T3 Code (Launcher)
Exec="${LAUNCHER_PATH}" --bg -- %U
Icon=${HOME}/.local/share/icons/com.t3tools.T3Code.desktop.png
Terminal=false
StartupNotify=false
Categories=Development;
MimeType=x-scheme-handler/t3code;
DESKTOP

    desktop_file="${applications_dir}/t3code-url-handler.desktop"
    if [ -f "$desktop_file" ]; then
        sed -i "s|^Exec=.*|Exec=\"${LAUNCHER_PATH}\" --bg -- %U|" "$desktop_file"
    fi

    if have_cmd update-desktop-database; then
        update-desktop-database "$applications_dir" \
            || echo "Warning: could not refresh the desktop application database." >&2
    fi

    if have_cmd xdg-mime; then
        current_handler="$(xdg-mime query default x-scheme-handler/t3code 2>/dev/null || true)"
        case "$current_handler" in
            ''|com.t3tools.T3Code.desktop|t3code-url-handler.desktop)
                xdg-mime default t3code-launcher.desktop x-scheme-handler/t3code \
                    || echo "Warning: could not register the T3 Code launcher URL handler." >&2
                ;;
        esac
    fi
}

fetch_latest_release_json() {
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO}/releases/latest"
}

fetch_latest_appimage_asset() {
    local release_json
    local arch_pattern
    local asset

    release_json="$(fetch_latest_release_json)"
    case "$(uname -m)" in
        x86_64|amd64) arch_pattern='x86_64[.]AppImage$' ;;
        aarch64|arm64) arch_pattern='(arm64|aarch64).*AppImage$' ;;
        *)
            echo "Error: unsupported architecture for T3 Code AppImage: $(uname -m)" >&2
            exit 1
            ;;
    esac

    asset="$(
        printf '%s\n' "$release_json" | jq -r --arg pattern "$arch_pattern" '
            [.assets[] | select(.name | test($pattern; "i"))]
            | if length == 1 then
                .[0] | [.name, .browser_download_url, (.digest // "")] | @tsv
              else
                empty
              end
        '
    )"

    if [ -z "$asset" ]; then
        echo "Error: could not find exactly one AppImage for architecture $(uname -m)." >&2
        exit 1
    fi

    printf '%s\n' "$asset"
}

install_or_update_app() {
    mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$RELEASES_DIR"

    local asset_name download_url digest expected_digest
    IFS=$'\t' read -r asset_name download_url digest < <(fetch_latest_appimage_asset)

    case "$download_url" in
        "https://github.com/${REPO}/releases/download/"*) ;;
        *)
            echo "Error: refusing unexpected download URL: $download_url" >&2
            exit 1
            ;;
    esac

    case "$digest" in
        sha256:*) expected_digest="${digest#sha256:}" ;;
        *)
            echo "Error: GitHub did not provide a SHA-256 digest for $asset_name." >&2
            exit 1
            ;;
    esac

    local tmp_file
    tmp_file="$(mktemp "${INSTALL_DIR}/T3-Code.AppImage.tmp.XXXXXX")"
    INSTALL_TMP="$tmp_file"

    echo "Downloading T3 Code AppImage: $asset_name"
    curl -fL "$download_url" -o "$tmp_file"

    if ! printf '%s  %s\n' "$expected_digest" "$tmp_file" | sha256sum --check --status; then
        echo "Error: T3 Code AppImage checksum verification failed." >&2
        exit 1
    fi

    chmod +x "$tmp_file"
    prepare_extracted_release "$tmp_file"
    mv -f "$tmp_file" "$APPIMAGE_PATH"
    INSTALL_TMP=""
    UPDATED_THIS_RUN=true
    activate_release "$PREPARED_RELEASE"
    update_existing_desktop_entries

    echo "Installed:"
    echo "  $APPIMAGE_PATH"
    echo "Active extracted release:"
    echo "  $PREPARED_RELEASE"
    echo "Symlink:"
    echo "  $LINK_PATH"
}

log_indicates_sandbox_problem() {
    local log_file="$1"
    grep -qiE 'No usable sandbox|SUID sandbox helper binary|Failed to move to new namespace|zygote_host_impl_linux|setuid sandbox' "$log_file"
}

report_launch_failure() {
    local log_file="$1"

    cat "$log_file" >&2
    echo "T3 Code failed to start." >&2
    if [ "$ALLOW_NO_SANDBOX" = true ]; then
        echo "The failure did not look like a Chromium sandbox error, or the permitted fallback also failed." >&2
    else
        echo "Re-run with --allow-no-sandbox only if you accept the reduced security." >&2
    fi
    echo "Log: $log_file" >&2
    return 1
}

wait_for_startup() {
    local pid="$1"
    local log_file="$2"
    local elapsed=0

    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        if grep -qiE 'main window created|backend ready' "$log_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 2
}

launch_once() {
    local log_file="$1"
    shift
    local pid startup_status process_status

    if [ "$BG" = true ]; then
        nohup "$@" >"$log_file" 2>&1 &
    else
        "$@" >"$log_file" 2>&1 &
    fi
    pid=$!

    if wait_for_startup "$pid" "$log_file"; then
        startup_status=0
    else
        startup_status=$?
    fi
    if [ "$startup_status" -eq 0 ]; then
        # The application can register its generated entry during startup.
        # Repair only after readiness, while the launch lock is still held.
        update_existing_desktop_entries \
            || echo "Warning: could not refresh launcher integration after startup." >&2
    fi
    release_launch_lock

    if [ "$startup_status" -eq 1 ]; then
        if wait "$pid"; then
            process_status=0
        else
            process_status=$?
        fi
        if [ "$process_status" -eq 0 ]; then
            update_existing_desktop_entries \
                || echo "Warning: could not refresh launcher integration after forwarding the request." >&2
            rm -f -- "$log_file"
            echo "T3 Code request was handled by an existing instance."
            return 0
        fi
        return "$process_status"
    fi

    if [ "$startup_status" -eq 2 ]; then
        echo "Warning: T3 Code is still running but did not report readiness within ${STARTUP_TIMEOUT} seconds." >&2
        echo "Log: $log_file" >&2
    fi

    if [ "$BG" = true ]; then
        disown "$pid" 2>/dev/null || true
        if [ "$startup_status" -eq 0 ]; then
            echo "T3 Code started in the background."
            echo "Log: $log_file"
        fi
        return 0
    fi

    if wait "$pid"; then
        process_status=0
    else
        process_status=$?
    fi
    if [ "$process_status" -eq 0 ]; then
        rm -f -- "$log_file"
    fi
    return "$process_status"
}

recover_t3_processes() {
    local uid pid cmdline
    local pids=()
    uid="$(id -u)"

    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir#/proc/}"
        [ "$pid" -ne "$$" ] || continue
        [ "$(stat -c %u "$pid_dir" 2>/dev/null || echo -1)" = "$uid" ] || continue
        cmdline="$(tr '\0' ' ' <"${pid_dir}/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
            *"${INSTALL_DIR}/T3-Code.AppImage"*|*"${INSTALL_DIR}/releases/"*|*"/tmp/.mount_T3-"*"/t3code"*)
                pids+=("$pid")
                ;;
        esac
    done

    if [ "${#pids[@]}" -eq 0 ]; then
        echo "No T3 Code processes need recovery."
        return
    fi

    echo "Stopping T3 Code processes: ${pids[*]}" >&2
    kill -TERM "${pids[@]}" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        local survivors=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && survivors+=("$pid")
        done
        [ "${#survivors[@]}" -gt 0 ] || return
        pids=("${survivors[@]}")
        sleep 1
    done
    echo "Force-stopping unresponsive T3 Code processes: ${pids[*]}" >&2
    kill -KILL "${pids[@]}" 2>/dev/null || true
}

run_app() {
    local log_file
    local args=(env -u APPDIR -u APPIMAGE "$CURRENT_APP" "${APP_ARGS[@]}")

    log_file="$(mktemp "/tmp/t3code-run.XXXXXX.log")"
    if launch_once "$log_file" "${args[@]}"; then
        return 0
    fi

    if [ "$ALLOW_NO_SANDBOX" = true ] && log_indicates_sandbox_problem "$log_file"; then
        echo "Retrying with explicitly allowed --no-sandbox..." >&2
        : >"$log_file"
        acquire_launch_lock
        if launch_once "$log_file" env -u APPDIR -u APPIMAGE "$CURRENT_APP" --no-sandbox "${APP_ARGS[@]}"; then
            return 0
        fi
    fi

    acquire_launch_lock
    restore_previous_release
    release_launch_lock
    report_launch_failure "$log_file"
}

parse_args() {
    local pass_through=false

    for arg in "$@"; do
        if [ "$pass_through" = true ]; then
            APP_ARGS+=("$arg")
            continue
        fi

        case "$arg" in
            --bg)
                BG=true
                ;;
            --update)
                FORCE_UPDATE=true
                ;;
            --allow-no-sandbox)
                ALLOW_NO_SANDBOX=true
                ;;
            --recover)
                RECOVER=true
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            --)
                pass_through=true
                ;;
            *)
                APP_ARGS+=("$arg")
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    trap cleanup_install_tmp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    install_required_tools
    acquire_launch_lock

    if [ "$RECOVER" = true ]; then
        recover_t3_processes
    fi

    if [ "$FORCE_UPDATE" = true ] || ! is_installed; then
        install_or_update_app
    else
        mkdir -p "$BIN_DIR" "$RELEASES_DIR"
        prepare_extracted_release "$APPIMAGE_PATH"
        activate_release "$PREPARED_RELEASE"
        update_existing_desktop_entries
    fi

    run_app
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
