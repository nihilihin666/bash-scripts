#!/usr/bin/env bash

set -euo pipefail

# Download a YouTube video, or extract MP3 audio with --audio-only. Missing Python,
# pipx, ffmpeg, and yt-dlp dependencies are installed automatically.

readonly OUTDIR="$HOME/bash-scripts-output/youtube-downloaded"

AUDIO_ONLY=0
COOKIES_BROWSER=""
YT_DLP=""
URL=""
COMMON_ARGS=()

show_help() {
    cat <<HELP
Download a YouTube video or extract its audio as MP3.

Usage:
  "$0" [--audio-only] [--cookies-from-browser BROWSER] <youtube-url>

Arguments:
  <youtube-url>  URL of the YouTube video to download.

Options:
  -a, --audio-only                    Download audio only as MP3.
  -c, --cookies-from-browser BROWSER  Use browser cookies for authentication.
                                     Examples: firefox, chrome, chromium, brave.
  -h, --help                          Show this help.
      --                              End options; treat remaining values as positional arguments.

Output:
  $HOME/bash-scripts-output/youtube-downloaded/

Examples:
  ./bash-scripts/youtube-download.sh 'https://www.youtube.com/watch?v=VancAKcmO6s'
  ./bash-scripts/youtube-download.sh --audio-only 'https://www.youtube.com/watch?v=VancAKcmO6s'
  ./bash-scripts/youtube-download.sh --cookies-from-browser firefox 'https://www.youtube.com/watch?v=VancAKcmO6s'
HELP
}

die() {
    echo "Error: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--audio-only)
                AUDIO_ONLY=1
                shift
                ;;
            -c|--cookies-from-browser)
                [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a browser value."
                COOKIES_BROWSER="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    [[ -z "$URL" ]] || die "exactly one YouTube URL is required."
                    URL="$1"
                    shift
                done
                break
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                [[ -z "$URL" ]] || die "exactly one YouTube URL is required."
                URL="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$URL" ]]; then
        echo "Error: exactly one YouTube URL is required." >&2
        show_help >&2
        exit 1
    fi
}

run_as_root() {
    if [[ $(id -u) -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        echo "Error: missing requirements and neither root nor sudo is available." >&2
        echo "Install python3, pipx and ffmpeg manually, then run this script again." >&2
        exit 1
    fi
}

detect_package_manager() {
    local manager

    for manager in dnf apt-get pacman zypper; do
        if command_exists "$manager"; then
            printf '%s\n' "$manager"
            return 0
        fi
    done
    return 1
}

install_os_packages() {
    local packages=("$@")
    local package_manager

    package_manager="$(detect_package_manager)" \
        || die "unsupported package manager. Install manually: ${packages[*]}"
    case "$package_manager" in
        dnf)
            run_as_root dnf install -y "${packages[@]}"
            ;;
        apt-get)
            run_as_root apt-get update
            run_as_root apt-get install -y "${packages[@]}"
            ;;
        pacman)
            if ! run_as_root pacman -S --needed --noconfirm "${packages[@]}"; then
                echo "Error: pacman could not install the requirements safely." >&2
                echo "Run a full system upgrade with 'sudo pacman -Syu', then retry." >&2
                exit 1
            fi
            ;;
        zypper)
            run_as_root zypper --non-interactive install "${packages[@]}"
            ;;
    esac
}

ensure_base_requirements() {
    local missing_packages=()

    command_exists python3 || missing_packages+=(python3)
    command_exists pipx || missing_packages+=(pipx)
    command_exists ffmpeg || missing_packages+=(ffmpeg)

    if (( ${#missing_packages[@]} > 0 )); then
        echo "Installing missing requirements: ${missing_packages[*]}"
        install_os_packages "${missing_packages[@]}"
    fi
}

resolve_yt_dlp() {
    if command_exists yt-dlp; then
        YT_DLP="yt-dlp"
    elif [[ -x "$HOME/.local/bin/yt-dlp" ]]; then
        YT_DLP="$HOME/.local/bin/yt-dlp"
    else
        return 1
    fi
}

ensure_yt_dlp() {
    resolve_yt_dlp && return 0

    echo "Installing missing requirement: yt-dlp"
    pipx install yt-dlp
    if ! resolve_yt_dlp; then
        echo "Error: yt-dlp was installed, but it is not available on PATH." >&2
        echo "Try running: pipx ensurepath" >&2
        echo "Then reopen the terminal and run this script again." >&2
        exit 1
    fi
}

upgrade_yt_dlp() {
    echo "Trying to upgrade yt-dlp, because YouTube may have changed something..."

    if command_exists pipx && pipx list 2>/dev/null | grep -q 'package yt-dlp '; then
        pipx upgrade yt-dlp || true
    else
        "$YT_DLP" -U || true
    fi
    resolve_yt_dlp || true
}

build_common_args() {
    COMMON_ARGS=(
        --no-playlist
        --windows-filenames
        --extractor-args "youtube:player_client=default,web"
        -P "$OUTDIR"
    )
    if [[ -n "$COOKIES_BROWSER" ]]; then
        COMMON_ARGS+=(--cookies-from-browser "$COOKIES_BROWSER")
    fi
}

run_download() {
    build_common_args
    if [[ "$AUDIO_ONLY" -eq 1 ]]; then
        echo "Downloading AUDIO..."
        "$YT_DLP" "${COMMON_ARGS[@]}" -x --audio-format mp3 "$URL"
    else
        echo "Downloading VIDEO..."
        "$YT_DLP" "${COMMON_ARGS[@]}" "$URL"
    fi
}

print_auth_hint() {
    cat >&2 <<HINT

Download failed.

If the video opens in your browser but yt-dlp says it is not available in this app,
try browser cookies:

  ./bash-scripts/youtube-download.sh --cookies-from-browser firefox 'URL'

or:

  ./bash-scripts/youtube-download.sh -c chrome 'URL'

This only works if that browser is logged into an account that can watch the video.
HINT
}

main() {
    parse_args "$@"
    ensure_base_requirements
    ensure_yt_dlp
    mkdir -p "$OUTDIR"

    run_download && return 0
    upgrade_yt_dlp
    run_download && return 0
    print_auth_hint
    return 1
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
