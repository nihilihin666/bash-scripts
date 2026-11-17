#!/usr/bin/env bash

# Batch resize, optimize, inspect, and convert static images safely.

set -u
set -o pipefail

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_RUN_ROOT="$HOME/bash-scripts-output/image/$RUN_TIMESTAMP"
DEFAULT_OUTPUT_DIR="$DEFAULT_RUN_ROOT/result"
DEFAULT_BACKUP_DIR="$DEFAULT_RUN_ROOT/backup"

MIN_WIDTH=""
MIN_HEIGHT=""
MAX_WIDTH=""
MAX_HEIGHT=""
TARGET_FORMAT=""
QUALITY=90
BACKGROUND="black"
MIN_SAVINGS=5
KEEP_METADATA=0
TO_SRGB=0
SOURCE_PROFILE=""
OUTPUT_DIR=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
OVERWRITE=0
NO_BACKUP=0
AUTO_INSTALL=1
SUFFIX=""
RECURSIVE=0
DRY_RUN=0
INSPECT=0
INPUT_PATH=""
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()

MAGICK_CMD=()
IDENTIFY_CMD=()
SRGB_PROFILE=""
EXIV2_BIN=""
DISTRO_ID=""
CURRENT_TMP=""
INPUT_IS_DIR=0
INPUT_ROOT=""
ABS_INPUT=""
ABS_OUTPUT=""
ABS_BACKUP=""

FILES_DISCOVERED=0
FILES_SUPPORTED=0
FILES_CHANGED=0
FILES_WOULD_CHANGE=0
FILES_SKIPPED=0
FILES_FAILED=0
BACKUPS_CREATED=0
BYTES_CHANGED_BEFORE=0
BYTES_CHANGED_AFTER=0
PACKAGES_INSTALLED=()

declare -A SKIP_COUNTS=()

usage() {
    cat <<EOF
Batch resize, optimize, inspect, and convert static JPEG, PNG, and WebP images.

Usage:
  $0 [options] <file-or-directory>

Arguments:
  <file-or-directory>  Input image or directory to process.

Dimensions (aspect ratio is always preserved):
      --min-width N          Minimum output width
      --min-height N         Minimum output height
      --max-width N          Maximum output width
      --max-height N         Maximum output height

Format and optimization:
      --to-jpg               Convert changed output to JPEG
      --to-png               Convert changed output to PNG
      --to-webp              Convert changed output to WebP
      --quality N            JPEG/WebP quality, 1-100 (default: $QUALITY)
      --background COLOR     Alpha background for JPEG (default: $BACKGROUND)
      --min-savings N        Minimum optional size saving percent (default: $MIN_SAVINGS)

Metadata and color:
      --keep-metadata        Keep all supported embedded metadata
      --to-srgb              Convert from the embedded/source ICC profile to sRGB
      --source-profile FILE  Source ICC profile for untagged or overridden input

Output and safety:
      --output-dir DIR       Output root (default: $DEFAULT_OUTPUT_DIR)
      --overwrite            Replace/remove source files after validated output
      --backup-dir DIR       Backup root (default: $DEFAULT_BACKUP_DIR)
      --no-backup            Do not back up files changed by --overwrite
      --no-install           Never install missing system packages
      --suffix TEXT          Add TEXT before the extension of changed files
      --dry-run              Show planned work without writing files

Selection and information:
  -r, --recursive            Recurse into input directories
      --include PATTERN      Include matching relative path/basename; repeatable
      --exclude PATTERN      Exclude matching relative path/basename; repeatable
      --inspect              Read-only image and operation report
  -h, --help                 Show this help
      --                     End options; treat remaining values as positional arguments.

Notes:
  * Supported inputs are static JPEG, PNG, and WebP images.
  * Missing packages are installed automatically on Ubuntu and Fedora.
  * Required commands: ImageMagick (magick or convert/identify) and exiv2.
  * --dry-run never installs packages; --no-install disables installation.
  * Existing destination files are never overwritten.
  * --overwrite means replace the source; it never permits clobbering another file.
  * Unchanged files are not copied to the result directory.
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

err() {
    printf 'Error: %s\n' "$*" >&2
}

cleanup_tmp() {
    if [[ -n "$CURRENT_TMP" && -e "$CURRENT_TMP" ]]; then
        rm -f -- "$CURRENT_TMP"
    fi
}

trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_percent() {
    [[ "$1" =~ ^([0-9]|[1-9][0-9]|100)(\.[0-9]+)?$ ]]
}

require_value() {
    local option="$1"
    local count="$2"
    if (( count < 2 )); then
        err "$option requires a value."
        usage
        exit 1
    fi
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --min-width)
                require_value "$1" "$#"
                MIN_WIDTH="$2"
                shift 2
                ;;
            --min-height)
                require_value "$1" "$#"
                MIN_HEIGHT="$2"
                shift 2
                ;;
            --max-width)
                require_value "$1" "$#"
                MAX_WIDTH="$2"
                shift 2
                ;;
            --max-height)
                require_value "$1" "$#"
                MAX_HEIGHT="$2"
                shift 2
                ;;
            --to-jpg|--to-png|--to-webp)
                local requested_format
                requested_format="${1#--to-}"
                if [[ -n "$TARGET_FORMAT" && "$TARGET_FORMAT" != "$requested_format" ]]; then
                    err "Only one of --to-jpg, --to-png, and --to-webp may be used."
                    exit 1
                fi
                TARGET_FORMAT="$requested_format"
                shift
                ;;
            --quality)
                require_value "$1" "$#"
                QUALITY="$2"
                shift 2
                ;;
            --background)
                require_value "$1" "$#"
                BACKGROUND="$2"
                shift 2
                ;;
            --min-savings)
                require_value "$1" "$#"
                MIN_SAVINGS="$2"
                shift 2
                ;;
            --keep-metadata)
                KEEP_METADATA=1
                shift
                ;;
            --to-srgb)
                TO_SRGB=1
                shift
                ;;
            --source-profile)
                require_value "$1" "$#"
                SOURCE_PROFILE="$2"
                shift 2
                ;;
            --output-dir)
                require_value "$1" "$#"
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --overwrite)
                OVERWRITE=1
                shift
                ;;
            --backup-dir)
                require_value "$1" "$#"
                BACKUP_DIR="$2"
                shift 2
                ;;
            --no-backup)
                NO_BACKUP=1
                shift
                ;;
            --no-install)
                AUTO_INSTALL=0
                shift
                ;;
            --suffix)
                require_value "$1" "$#"
                SUFFIX="$2"
                shift 2
                ;;
            -r|--recursive)
                RECURSIVE=1
                shift
                ;;
            --include)
                require_value "$1" "$#"
                INCLUDE_PATTERNS+=("$2")
                shift 2
                ;;
            --exclude)
                require_value "$1" "$#"
                EXCLUDE_PATTERNS+=("$2")
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --inspect)
                INSPECT=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    set_input_path "$1"
                    shift
                done
                ;;
            -*)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                set_input_path "$1"
                shift
                ;;
        esac
    done
}

set_input_path() {
    local path="$1"
    if [[ -n "$INPUT_PATH" ]]; then
        err "Only one input path is supported."
        exit 1
    fi
    INPUT_PATH="$path"
}

validate_args() {
    local label value

    if [[ -z "$INPUT_PATH" ]]; then
        err "An input file or directory is required."
        usage
        exit 1
    fi

    if [[ ! -e "$INPUT_PATH" && ! -L "$INPUT_PATH" ]]; then
        err "Input path does not exist: $INPUT_PATH"
        exit 1
    fi

    for label in MIN_WIDTH MIN_HEIGHT MAX_WIDTH MAX_HEIGHT; do
        value="${!label}"
        if [[ -n "$value" ]] && ! is_positive_integer "$value"; then
            err "${label//_/-} must be a positive integer."
            exit 1
        fi
    done

    if [[ -n "$MIN_WIDTH" && -n "$MAX_WIDTH" ]] && (( MIN_WIDTH > MAX_WIDTH )); then
        err "--min-width cannot exceed --max-width."
        exit 1
    fi
    if [[ -n "$MIN_HEIGHT" && -n "$MAX_HEIGHT" ]] && (( MIN_HEIGHT > MAX_HEIGHT )); then
        err "--min-height cannot exceed --max-height."
        exit 1
    fi

    if ! is_positive_integer "$QUALITY" || (( QUALITY > 100 )); then
        err "--quality must be an integer between 1 and 100."
        exit 1
    fi

    if ! is_percent "$MIN_SAVINGS"; then
        err "--min-savings must be a number between 0 and 100."
        exit 1
    fi

    if [[ "$SUFFIX" == */* ]]; then
        err "--suffix cannot contain a slash."
        exit 1
    fi

    if (( OVERWRITE == 1 )) && [[ -n "$OUTPUT_DIR" ]]; then
        err "--output-dir and --overwrite cannot be combined."
        exit 1
    fi

    if [[ -n "$SOURCE_PROFILE" ]]; then
        if (( TO_SRGB != 1 )); then
            err "--source-profile requires --to-srgb."
            exit 1
        fi
        if [[ ! -f "$SOURCE_PROFILE" ]]; then
            err "Source ICC profile does not exist: $SOURCE_PROFILE"
            exit 1
        fi
    fi

    if (( OVERWRITE == 0 )); then
        OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    fi
}

imagemagick_available() {
    command -v magick >/dev/null 2>&1 || \
        { command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; }
}

exiv2_available() {
    command -v exiv2 >/dev/null 2>&1
}

detect_distribution() {
    DISTRO_ID=""
    if [[ -r /etc/os-release ]]; then
        DISTRO_ID="$(
            # shellcheck disable=SC1091 # This is the standard OS identity file.
            . /etc/os-release
            printf '%s' "${ID:-}"
        )"
    fi

    case "$DISTRO_ID" in
        ubuntu|fedora) return 0 ;;
        *) return 1 ;;
    esac
}

append_unique_package() {
    local package="$1"
    local existing
    for existing in "${MISSING_PACKAGES[@]}"; do
        [[ "$existing" == "$package" ]] && return
    done
    MISSING_PACKAGES+=("$package")
}

collect_missing_packages() {
    MISSING_PACKAGES=()

    if ! imagemagick_available; then
        case "$DISTRO_ID" in
            ubuntu) append_unique_package "imagemagick" ;;
            fedora) append_unique_package "ImageMagick" ;;
        esac
    fi

    if ! exiv2_available; then
        append_unique_package "exiv2"
    fi

    if (( TO_SRGB == 1 )); then
        find_srgb_profile
        if [[ -z "$SRGB_PROFILE" ]]; then
            case "$DISTRO_ID" in
                ubuntu) append_unique_package "icc-profiles-free" ;;
                fedora) append_unique_package "icc-profiles-openicc" ;;
            esac
        fi
    fi
}

manual_install_command() {
    case "$DISTRO_ID" in
        ubuntu)
            printf 'sudo apt-get update && sudo apt-get install -y'
            ;;
        fedora)
            printf 'sudo dnf install -y'
            ;;
    esac
    printf ' %q' "${MISSING_PACKAGES[@]}"
    printf '\n'
}

install_missing_packages() {
    local root_prefix=()

    if (( EUID != 0 )); then
        if ! command -v sudo >/dev/null 2>&1; then
            err "sudo is required to install missing packages."
            err "Install them manually with: $(manual_install_command)"
            return 1
        fi
        root_prefix=(sudo)
    fi

    log "Missing dependencies detected for $DISTRO_ID."
    log "Installing packages: ${MISSING_PACKAGES[*]}"

    case "$DISTRO_ID" in
        ubuntu)
            if ! command -v apt-get >/dev/null 2>&1; then
                err "Ubuntu was detected, but apt-get is unavailable."
                return 1
            fi
            "${root_prefix[@]}" apt-get update || return 1
            "${root_prefix[@]}" env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${MISSING_PACKAGES[@]}" || return 1
            ;;
        fedora)
            if ! command -v dnf >/dev/null 2>&1; then
                err "Fedora was detected, but dnf is unavailable."
                return 1
            fi
            "${root_prefix[@]}" dnf install -y "${MISSING_PACKAGES[@]}" || return 1
            ;;
        *)
            return 1
            ;;
    esac

    PACKAGES_INSTALLED+=("${MISSING_PACKAGES[@]}")
}

verify_dependencies() {
    local missing=()
    imagemagick_available || missing+=("ImageMagick")
    exiv2_available || missing+=("exiv2")

    if (( TO_SRGB == 1 )); then
        find_srgb_profile
        [[ -n "$SRGB_PROFILE" ]] || missing+=("sRGB ICC profile")
    fi

    if (( ${#missing[@]} > 0 )); then
        err "Dependencies are still unavailable after installation: ${missing[*]}"
        return 1
    fi
}

ensure_dependencies() {
    local initial_missing=()

    imagemagick_available || initial_missing+=("ImageMagick")
    exiv2_available || initial_missing+=("exiv2")
    if (( TO_SRGB == 1 )); then
        find_srgb_profile
        [[ -n "$SRGB_PROFILE" ]] || initial_missing+=("sRGB ICC profile")
    fi

    if (( ${#initial_missing[@]} == 0 )); then
        return
    fi

    if ! detect_distribution; then
        err "Missing dependencies: ${initial_missing[*]}"
        err "Automatic installation supports Ubuntu and Fedora only (detected: ${DISTRO_ID:-unknown})."
        exit 1
    fi

    collect_missing_packages
    if (( ${#MISSING_PACKAGES[@]} == 0 )); then
        err "Missing dependencies could not be mapped to packages: ${initial_missing[*]}"
        exit 1
    fi

    if (( DRY_RUN == 1 )); then
        log "[dry-run] Missing dependencies: ${initial_missing[*]}"
        log "[dry-run] Would install packages: ${MISSING_PACKAGES[*]}"
        log "[dry-run] Command: $(manual_install_command)"
        exit 1
    fi

    if (( AUTO_INSTALL == 0 )); then
        err "Missing dependencies: ${initial_missing[*]}"
        err "Automatic installation was disabled by --no-install."
        err "Install them manually with: $(manual_install_command)"
        exit 1
    fi

    if ! install_missing_packages; then
        err "Failed to install required packages."
        err "You can retry manually with: $(manual_install_command)"
        exit 1
    fi

    if ! verify_dependencies; then
        exit 1
    fi
}

resolve_tools() {
    if command -v magick >/dev/null 2>&1; then
        MAGICK_CMD=(magick)
        IDENTIFY_CMD=(magick identify)
    elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
        MAGICK_CMD=(convert)
        IDENTIFY_CMD=(identify)
    else
        err "ImageMagick is required. Install ImageMagick 6 or 7 and retry."
        exit 1
    fi

    if command -v exiv2 >/dev/null 2>&1; then
        EXIV2_BIN="$(command -v exiv2)"
    else
        err "exiv2 is required for selective metadata cleanup. Install exiv2 and retry."
        exit 1
    fi

    if (( TO_SRGB == 1 )); then
        find_srgb_profile
        if [[ -z "$SRGB_PROFILE" ]]; then
            err "--to-srgb was requested, but an sRGB ICC profile could not be found."
            exit 1
        fi
    fi

    if ! "${MAGICK_CMD[@]}" -size 1x1 xc:"$BACKGROUND" null: >/dev/null 2>&1; then
        err "ImageMagick does not recognize the background color: $BACKGROUND"
        exit 1
    fi
}

find_srgb_profile() {
    local candidate
    SRGB_PROFILE=""
    local candidates=(
        "/usr/share/color/icc/colord/sRGB.icc"
        "/usr/share/color/icc/sRGB.icc"
        "/usr/share/color/icc/OpenICC/sRGB.icc"
        "/usr/share/color/icc/openicc/sRGB.icc"
        "/usr/share/color/icc/ghostscript/srgb.icc"
        "/usr/local/share/color/icc/sRGB.icc"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            SRGB_PROFILE="$candidate"
            return
        fi
    done
}

absolute_path() {
    readlink -m -- "$1"
}

initialize_paths() {
    ABS_INPUT="$(readlink -f -- "$INPUT_PATH")"

    if [[ -d "$INPUT_PATH" ]]; then
        INPUT_IS_DIR=1
        INPUT_ROOT="$ABS_INPUT"
    else
        INPUT_IS_DIR=0
        INPUT_ROOT="$(dirname -- "$ABS_INPUT")"
    fi

    if (( OVERWRITE == 0 )); then
        ABS_OUTPUT="$(absolute_path "$OUTPUT_DIR")"
    else
        ABS_OUTPUT=""
    fi
    ABS_BACKUP="$(absolute_path "$BACKUP_DIR")"

    if (( OVERWRITE == 0 )) && [[ "$ABS_OUTPUT" == "$ABS_INPUT" ]]; then
        err "The output directory cannot be the input directory."
        exit 1
    fi

    if [[ "$ABS_INPUT/" == "$ABS_BACKUP/"* ]]; then
        err "The backup directory, or a path inside it, cannot be used as input."
        exit 1
    fi
    if (( OVERWRITE == 0 )) && [[ "$ABS_INPUT/" == "$ABS_OUTPUT/"* ]]; then
        err "The output directory, or a path inside it, cannot be used as input."
        exit 1
    fi
}

path_is_inside() {
    local child="$1"
    local parent="$2"
    [[ "$child" == "$parent" || "$child/" == "$parent/"* ]]
}

relative_path_for() {
    local file="$1"
    local abs_file
    abs_file="$(readlink -f -- "$file")"
    if (( INPUT_IS_DIR == 1 )); then
        REL_PATH="${abs_file#"$INPUT_ROOT"/}"
    else
        REL_PATH="$(basename -- "$abs_file")"
    fi
}

matches_pattern_list() {
    local rel="$1"
    local base="$2"
    shift 2
    local pattern
    for pattern in "$@"; do
        # shellcheck disable=SC2053 # User-provided shell patterns are intentional here.
        if [[ "$rel" == $pattern || "$base" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

selected_by_patterns() {
    local rel="$1"
    local base
    base="$(basename -- "$rel")"

    if (( ${#INCLUDE_PATTERNS[@]} > 0 )) && ! matches_pattern_list "$rel" "$base" "${INCLUDE_PATTERNS[@]}"; then
        return 1
    fi
    if (( ${#EXCLUDE_PATTERNS[@]} > 0 )) && matches_pattern_list "$rel" "$base" "${EXCLUDE_PATTERNS[@]}"; then
        return 1
    fi
    return 0
}

increment_skip() {
    local reason="$1"
    FILES_SKIPPED=$((FILES_SKIPPED + 1))
    SKIP_COUNTS["$reason"]=$(( ${SKIP_COUNTS["$reason"]:-0} + 1 ))
}

get_file_size() {
    stat -c%s -- "$1" 2>/dev/null || printf '0\n'
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        printf '%s B\n' "$bytes"
    fi
}

inspect_file() {
    local file="$1"
    local raw frame_lines first_info oriented_info

    if ! raw="$("${IDENTIFY_CMD[@]}" -quiet -format '1\n' "$file" 2>/dev/null)"; then
        return 1
    fi
    frame_lines="$(printf '%s\n' "$raw" | awk 'NF {count++} END {print count + 0}')"
    FRAME_COUNT="$frame_lines"

    if ! first_info="$("${IDENTIFY_CMD[@]}" -quiet -format '%m|%w|%h|%[orientation]|%[opaque]|%[colorspace]|%[profiles]|%[compression]' "${file}[0]" 2>/dev/null)"; then
        return 1
    fi

    IFS='|' read -r SOURCE_FORMAT STORED_WIDTH STORED_HEIGHT ORIENTATION OPAQUE COLORSPACE PROFILES COMPRESSION <<< "$first_info"
    SOURCE_FORMAT="${SOURCE_FORMAT^^}"
    [[ "$SOURCE_FORMAT" == "JPEG" || "$SOURCE_FORMAT" == "JPG" || "$SOURCE_FORMAT" == "PNG" || "$SOURCE_FORMAT" == "WEBP" ]] || return 2
    [[ "$SOURCE_FORMAT" == "JPG" ]] && SOURCE_FORMAT="JPEG"

    if ! oriented_info="$("${MAGICK_CMD[@]}" "${file}[0]" -auto-orient -format '%w %h' info: 2>/dev/null)"; then
        return 1
    fi
    read -r SOURCE_WIDTH SOURCE_HEIGHT <<< "$oriented_info"

    HAS_ALPHA=0
    if [[ "${OPAQUE,,}" != "true" ]]; then
        HAS_ALPHA=1
    fi

    HAS_ICC=0
    if [[ "${PROFILES,,}" == *icc* || "${PROFILES,,}" == *icm* ]]; then
        HAS_ICC=1
    fi

    SOURCE_WEBP_LOSSLESS=0
    if [[ "$SOURCE_FORMAT" == "WEBP" ]] && LC_ALL=C grep -aq 'VP8L' "$file"; then
        SOURCE_WEBP_LOSSLESS=1
    fi

    NEEDS_ORIENTATION=0
    case "${ORIENTATION,,}" in
        undefined|topleft|top-left|"") ;;
        *) NEEDS_ORIENTATION=1 ;;
    esac

    return 0
}

solve_dimensions() {
    local width="$1"
    local height="$2"
    local min_w="${MIN_WIDTH:-0}"
    local min_h="${MIN_HEIGHT:-0}"
    local max_w="${MAX_WIDTH:-0}"
    local max_h="${MAX_HEIGHT:-0}"
    local result

    if ! result="$(awk -v w="$width" -v h="$height" -v minw="$min_w" -v minh="$min_h" -v maxw="$max_w" -v maxh="$max_h" '
        function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
        function abs(x) { return x < 0 ? -x : x }
        function valid(cw, ch) {
            return cw >= 1 && ch >= 1 &&
                (!minw || cw >= minw) && (!minh || ch >= minh) &&
                (!maxw || cw <= maxw) && (!maxh || ch <= maxh)
        }
        function consider(cw, ch, scale, score) {
            if (!valid(cw, ch)) return
            scale = (cw / w + ch / h) / 2
            # Preserve the source ratio first; among equally faithful integer
            # sizes, select the smallest change from the original dimensions.
            score = abs(cw * h - ch * w) / (w * h) * 1000000000000 + abs(scale - 1)
            if (!found || score < best) {
                found = 1; best = score; bw = cw; bh = ch
            }
        }
        BEGIN {
            low = 0
            if (minw) low = minw / w
            if (minh && minh / h > low) low = minh / h
            high = 1e30
            if (maxw) high = maxw / w
            if (maxh && maxh / h < high) high = maxh / h
            if (low > high + 1e-12) exit 2

            scale = 1
            if (scale < low) scale = low
            if (scale > high) scale = high
            basew = int(w * scale + 0.5)
            baseh = int(h * scale + 0.5)

            # The normally rounded dimensions are the closest proportional
            # pixel-grid representation of the chosen scale. Only search
            # nearby when rounding itself violates a strict boundary.
            if (valid(basew, baseh)) {
                printf "%d %d\n", basew, baseh
                exit
            }

            for (d = -6; d <= 6; d++) {
                cw = basew + d
                if (cw > 0) consider(cw, int(cw * h / w + 0.5))
                ch = baseh + d
                if (ch > 0) consider(int(ch * w / h + 0.5), ch)
            }
            if (!found) exit 2
            printf "%d %d\n", bw, bh
        }
    ')"; then
        return 1
    fi

    read -r TARGET_WIDTH TARGET_HEIGHT <<< "$result"
    NEEDS_RESIZE=0
    if (( TARGET_WIDTH != width || TARGET_HEIGHT != height )); then
        NEEDS_RESIZE=1
    fi
    return 0
}

format_extension() {
    case "$1" in
        JPEG) printf 'jpg\n' ;;
        PNG) printf 'png\n' ;;
        WEBP) printf 'webp\n' ;;
    esac
}

requested_output_format() {
    if [[ -z "$TARGET_FORMAT" ]]; then
        OUTPUT_FORMAT="$SOURCE_FORMAT"
        return
    fi
    case "$TARGET_FORMAT" in
        jpg) OUTPUT_FORMAT="JPEG" ;;
        png) OUTPUT_FORMAT="PNG" ;;
        webp) OUTPUT_FORMAT="WEBP" ;;
    esac
}

build_destination() {
    local file="$1"
    local rel="$2"
    local rel_dir base stem extension output_base
    rel_dir="$(dirname -- "$rel")"
    base="$(basename -- "$rel")"
    if [[ "$base" == *.* && "$base" != .* ]]; then
        stem="${base%.*}"
    else
        stem="$base"
    fi
    extension="$(format_extension "$OUTPUT_FORMAT")"
    if [[ -z "$TARGET_FORMAT" && "$base" == *.* && "$base" != .* ]]; then
        local source_extension
        source_extension="${base##*.}"
        case "$SOURCE_FORMAT:${source_extension,,}" in
            JPEG:jpg|JPEG:jpeg|PNG:png|WEBP:webp)
                extension="$source_extension"
                ;;
        esac
    fi
    output_base="${stem}${SUFFIX}.${extension}"

    if (( OVERWRITE == 1 )); then
        DESTINATION="$(dirname -- "$file")/$output_base"
    elif [[ "$rel_dir" == "." ]]; then
        DESTINATION="$OUTPUT_DIR/$output_base"
    else
        DESTINATION="$OUTPUT_DIR/$rel_dir/$output_base"
    fi
}

same_path() {
    [[ "$(absolute_path "$1")" == "$(absolute_path "$2")" ]]
}

destination_collides() {
    local source="$1"
    local destination="$2"
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        return 1
    fi
    if (( OVERWRITE == 1 )) && same_path "$source" "$destination"; then
        return 1
    fi
    return 0
}

color_action_for_file() {
    COLOR_ACTION="none"
    COLOR_WARNING=""
    if (( TO_SRGB != 1 )); then
        return
    fi
    if [[ -n "$SOURCE_PROFILE" ]]; then
        COLOR_ACTION="assigned-to-srgb"
    elif (( HAS_ICC == 1 )); then
        COLOR_ACTION="embedded-to-srgb"
    else
        COLOR_WARNING="cannot convert untagged image to sRGB without --source-profile"
    fi
}

has_explicit_required_change() {
    REQUIRED_CHANGE=0
    if (( NEEDS_RESIZE == 1 || NEEDS_ORIENTATION == 1 )); then
        REQUIRED_CHANGE=1
    fi
    if [[ "$OUTPUT_FORMAT" != "$SOURCE_FORMAT" || "$COLOR_ACTION" != "none" ]]; then
        REQUIRED_CHANGE=1
    fi
}

print_inspection() {
    local file="$1"
    local size="$2"
    log "$file"
    log "  Format:        $SOURCE_FORMAT"
    log "  Dimensions:    ${SOURCE_WIDTH}x${SOURCE_HEIGHT} (oriented)"
    if (( NEEDS_ORIENTATION == 1 )); then
        log "  Stored size:   ${STORED_WIDTH}x${STORED_HEIGHT}; orientation: $ORIENTATION"
    else
        log "  Orientation:   ${ORIENTATION:-Undefined}"
    fi
    log "  Frames:        $FRAME_COUNT"
    log "  Transparency:  $([ "$HAS_ALPHA" -eq 1 ] && printf 'yes' || printf 'no')"
    log "  Color space:   ${COLORSPACE:-unknown}"
    log "  ICC profile:   $([ "$HAS_ICC" -eq 1 ] && printf 'embedded' || printf 'none')"
    log "  Profiles:      ${PROFILES:-none}"
    log "  Compression:   ${COMPRESSION:-unknown}"
    log "  File size:     $(human_size "$size")"
    if solve_dimensions "$SOURCE_WIDTH" "$SOURCE_HEIGHT"; then
        log "  Planned size:  ${TARGET_WIDTH}x${TARGET_HEIGHT}"
    else
        log "  Planned size:  impossible with supplied constraints"
    fi
    requested_output_format
    log "  Output format: $OUTPUT_FORMAT"
    color_action_for_file
    if [[ -n "$COLOR_WARNING" ]]; then
        log "  Color action:  skipped ($COLOR_WARNING)"
    else
        log "  Color action:  $COLOR_ACTION"
    fi
    log "  Metadata:      $([ "$KEEP_METADATA" -eq 1 ] && printf 'keep' || printf 'remove privacy/bloat profiles; retain rendering data')"
    log ""
}

make_temp_for_destination() {
    local destination="$1"
    local dir base extension
    dir="$(dirname -- "$destination")"
    base="$(basename -- "$destination")"
    extension="${base##*.}"
    mkdir -p -- "$dir" || return 1
    mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX.${extension}"
}

build_magick_args() {
    local file="$1"
    MAGICK_ARGS=("${file}[0]" -auto-orient)

    if [[ "$COLOR_ACTION" == "assigned-to-srgb" ]]; then
        MAGICK_ARGS+=(+profile icc +profile icm -profile "$SOURCE_PROFILE" -profile "$SRGB_PROFILE")
    elif [[ "$COLOR_ACTION" == "embedded-to-srgb" ]]; then
        MAGICK_ARGS+=(-profile "$SRGB_PROFILE")
    fi

    if (( NEEDS_RESIZE == 1 )); then
        MAGICK_ARGS+=(-resize "${TARGET_WIDTH}x${TARGET_HEIGHT}")
    fi

    if [[ "$OUTPUT_FORMAT" == "JPEG" ]] && (( HAS_ALPHA == 1 )); then
        MAGICK_ARGS+=(-background "$BACKGROUND" -alpha remove -alpha off)
    fi

    case "$OUTPUT_FORMAT" in
        JPEG)
            MAGICK_ARGS+=(-sampling-factor 4:4:4 -quality "$QUALITY" -interlace Plane -define jpeg:optimize-coding=true)
            ;;
        PNG)
            MAGICK_ARGS+=(-define png:compression-level=9 -define png:compression-strategy=1)
            ;;
        WEBP)
            MAGICK_ARGS+=(-quality "$QUALITY" -define webp:method=6 -define webp:use-sharp-yuv=true)
            if [[ "$SOURCE_FORMAT" == "PNG" || ( "$SOURCE_FORMAT" == "WEBP" && "$SOURCE_WEBP_LOSSLESS" -eq 1 ) ]]; then
                MAGICK_ARGS+=(-define webp:lossless=true)
            fi
            ;;
    esac
}

clean_candidate_metadata() {
    local candidate="$1"
    local key
    local commands=()

    if (( KEEP_METADATA == 1 )); then
        return 0
    fi

    # Keep rendering data, attribution, captions, dates, and rights. Remove
    # location/private device identifiers, embedded previews, application
    # history, and other processing baggage. Orientation is redundant after
    # -auto-orient has normalized the pixels.
    while IFS= read -r key; do
        key="${key%%[[:space:]]*}"
        [[ -n "$key" ]] || continue
        case "$key" in
            Exif.GPSInfo.*|Exif.Image.GPSTag|Exif.Thumbnail.*|\
            Exif.Photo.MakerNote|Exif.Image.Make|Exif.Image.Model|\
            Exif.Image.Software|Exif.Image.HostComputer|Exif.Image.Orientation|\
            Exif.Photo.BodySerialNumber|Exif.Photo.LensSerialNumber|\
            Exif.Photo.CameraOwnerName|Exif.Photo.UserComment|\
            Xmp.exif.GPS*|Xmp.xmp.CreatorTool|Xmp.xmpMM.History*|\
            Xmp.photoshop.History*|Xmp.xmpMM.DocumentID|\
            Xmp.xmpMM.InstanceID|Xmp.xmpMM.OriginalDocumentID)
                commands+=("-Mdel $key")
                ;;
        esac
    done < <("$EXIV2_BIN" -q -Pk "$candidate" 2>/dev/null || true)

    if (( ${#commands[@]} > 0 )); then
        "$EXIV2_BIN" -q -k "${commands[@]}" mo "$candidate" || return 1
    fi

    # A JPEG comment is unstructured and commonly duplicates a tool name or
    # edit note. Structured descriptions, creator, and copyright tags remain.
    if [[ "$OUTPUT_FORMAT" == "JPEG" ]]; then
        "$EXIV2_BIN" -q -k -d c rm "$candidate" || return 1
    fi
    return 0
}

validate_candidate() {
    local candidate="$1"
    local info actual_format actual_width actual_height actual_frames actual_opaque actual_profiles

    [[ -s "$candidate" ]] || return 1
    if ! actual_frames="$("${IDENTIFY_CMD[@]}" -quiet -format '1\n' "$candidate" 2>/dev/null | awk 'NF {count++} END {print count + 0}')"; then
        return 1
    fi
    [[ "$actual_frames" == "1" ]] || return 1

    if ! info="$("${IDENTIFY_CMD[@]}" -quiet -format '%m|%w|%h|%[opaque]|%[profiles]' "${candidate}[0]" 2>/dev/null)"; then
        return 1
    fi
    IFS='|' read -r actual_format actual_width actual_height actual_opaque actual_profiles <<< "$info"
    actual_format="${actual_format^^}"
    [[ "$actual_format" == "JPG" ]] && actual_format="JPEG"
    [[ "$actual_format" == "$OUTPUT_FORMAT" ]] || return 1
    [[ "$actual_width" == "$TARGET_WIDTH" && "$actual_height" == "$TARGET_HEIGHT" ]] || return 1

    if [[ -n "$MIN_WIDTH" ]] && (( actual_width < MIN_WIDTH )); then return 1; fi
    if [[ -n "$MIN_HEIGHT" ]] && (( actual_height < MIN_HEIGHT )); then return 1; fi
    if [[ -n "$MAX_WIDTH" ]] && (( actual_width > MAX_WIDTH )); then return 1; fi
    if [[ -n "$MAX_HEIGHT" ]] && (( actual_height > MAX_HEIGHT )); then return 1; fi

    if ! awk -v sw="$SOURCE_WIDTH" -v sh="$SOURCE_HEIGHT" -v aw="$actual_width" -v ah="$actual_height" 'BEGIN {
        difference = aw * sh - ah * sw
        if (difference < 0) difference = -difference
        # Allow only the unavoidable half-pixel rounding error from a
        # proportional resize in either dimension.
        allowed = sw > sh ? sw / 2 : sh / 2
        exit !(difference <= allowed + 1e-9)
    }'; then
        return 1
    fi

    if [[ "$OUTPUT_FORMAT" != "JPEG" && "$HAS_ALPHA" -eq 1 && "${actual_opaque,,}" == "true" ]]; then
        return 1
    fi

    if [[ "$COLOR_ACTION" != "none" && "${actual_profiles,,}" != *icc* && "${actual_profiles,,}" != *icm* ]]; then
        return 1
    fi
    return 0
}

savings_meets_threshold() {
    local before="$1"
    local after="$2"
    awk -v before="$before" -v after="$after" -v minimum="$MIN_SAVINGS" 'BEGIN {
        if (before <= 0 || after >= before) exit 1
        saving = (before - after) * 100 / before
        exit !(saving + 1e-9 >= minimum)
    }'
}

savings_percent() {
    local before="$1"
    local after="$2"
    awk -v before="$before" -v after="$after" 'BEGIN {
        if (before <= 0) { print "0.0"; exit }
        printf "%.1f", (before - after) * 100 / before
    }'
}

preserve_file_attributes() {
    local reference="$1"
    local destination="$2"
    if ! cp --attributes-only --preserve=mode,timestamps,xattr -- "$reference" "$destination" 2>/dev/null; then
        chmod --reference="$reference" "$destination" 2>/dev/null || return 1
        touch --reference="$reference" "$destination" 2>/dev/null || return 1
    fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown --reference="$reference" "$destination" 2>/dev/null || return 1
    fi
}

unique_backup_path() {
    local path="$1"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        UNIQUE_PATH="$path"
        return
    fi
    local dir base stem extension n candidate
    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    if [[ "$base" == *.* && "$base" != .* ]]; then
        stem="${base%.*}"
        extension=".${base##*.}"
    else
        stem="$base"
        extension=""
    fi
    n=1
    while :; do
        candidate="$dir/${stem}-${n}${extension}"
        if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
            UNIQUE_PATH="$candidate"
            return
        fi
        n=$((n + 1))
    done
}

backup_source() {
    local source="$1"
    local rel="$2"
    local desired backup_parent
    desired="$BACKUP_DIR/$rel"
    unique_backup_path "$desired"
    backup_parent="$(dirname -- "$UNIQUE_PATH")"

    if ! mkdir -p -- "$backup_parent"; then
        return 1
    fi
    if ! cp -a -- "$source" "$UNIQUE_PATH"; then
        return 1
    fi
    BACKUPS_CREATED=$((BACKUPS_CREATED + 1))
    log "  Backup: $UNIQUE_PATH"
}

commit_candidate() {
    local source="$1"
    local rel="$2"
    local candidate="$3"
    local destination="$4"
    local destination_is_source=0

    if same_path "$source" "$destination"; then
        destination_is_source=1
    fi

    if ! preserve_file_attributes "$source" "$candidate"; then
        err "Failed to preserve filesystem attributes for: $source"
        return 1
    fi

    if (( OVERWRITE == 1 && NO_BACKUP == 0 )); then
        if ! backup_source "$source" "$rel"; then
            err "Failed to back up: $source"
            return 1
        fi
    fi

    if (( destination_is_source == 1 )); then
        if ! mv -f -- "$candidate" "$destination"; then
            return 1
        fi
        CURRENT_TMP=""
        return 0
    fi

    if [[ -e "$destination" || -L "$destination" ]]; then
        err "Destination appeared during processing; refusing to overwrite: $destination"
        return 1
    fi
    if ! mv -n -- "$candidate" "$destination" || [[ -e "$candidate" ]]; then
        return 1
    fi
    CURRENT_TMP=""

    if (( OVERWRITE == 1 )); then
        if ! rm -- "$source"; then
            err "Converted output is valid, but the source could not be removed: $source"
            return 1
        fi
    fi
    return 0
}

process_supported_file() {
    local file="$1"
    local rel="$2"
    local before_size after_size saving tmp_file

    before_size="$(get_file_size "$file")"
    FILES_SUPPORTED=$((FILES_SUPPORTED + 1))

    if (( FRAME_COUNT != 1 )); then
        if (( INSPECT == 1 )); then
            print_inspection "$file" "$before_size"
        fi
        warn "Skipping multi-frame image ($FRAME_COUNT frames): $file"
        increment_skip "multi-frame"
        return
    fi

    if ! solve_dimensions "$SOURCE_WIDTH" "$SOURCE_HEIGHT"; then
        if (( INSPECT == 1 )); then
            print_inspection "$file" "$before_size"
        fi
        warn "No proportional size can satisfy the supplied constraints: $file (${SOURCE_WIDTH}x${SOURCE_HEIGHT})"
        increment_skip "constraint-conflict"
        return
    fi

    requested_output_format
    color_action_for_file
    if [[ -n "$COLOR_WARNING" ]]; then
        warn "$COLOR_WARNING: $file"
    fi
    has_explicit_required_change
    build_destination "$file" "$rel"

    if (( INSPECT == 0 )) && destination_collides "$file" "$DESTINATION"; then
        warn "Destination already exists; skipping: $DESTINATION"
        increment_skip "collision"
        return
    fi

    if (( INSPECT == 1 )); then
        print_inspection "$file" "$before_size"
        return
    fi

    if (( DRY_RUN == 1 )); then
        log "[dry-run] $file"
        log "  Size: ${SOURCE_WIDTH}x${SOURCE_HEIGHT} -> ${TARGET_WIDTH}x${TARGET_HEIGHT}"
        log "  Format: $SOURCE_FORMAT -> $OUTPUT_FORMAT"
        log "  Destination: $DESTINATION"
        if (( OVERWRITE == 1 && NO_BACKUP == 0 )); then
            log "  Backup root: $BACKUP_DIR"
        fi
        if [[ "$OUTPUT_FORMAT" == "JPEG" && "$HAS_ALPHA" -eq 1 ]]; then
            log "  Alpha background: $BACKGROUND"
        fi
        if (( REQUIRED_CHANGE == 0 )); then
            log "  Action: evaluate optimization; output only if savings >= ${MIN_SAVINGS}%"
        else
            log "  Action: required transformation"
        fi
        FILES_WOULD_CHANGE=$((FILES_WOULD_CHANGE + 1))
        log ""
        return
    fi

    if ! tmp_file="$(make_temp_for_destination "$DESTINATION")"; then
        err "Failed to create a temporary output for: $file"
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi
    CURRENT_TMP="$tmp_file"

    build_magick_args "$file"
    if ! "${MAGICK_CMD[@]}" "${MAGICK_ARGS[@]}" "$tmp_file"; then
        err "Failed to process: $file"
        rm -f -- "$tmp_file"
        CURRENT_TMP=""
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi

    if ! clean_candidate_metadata "$tmp_file"; then
        err "Failed to clean metadata safely: $file"
        rm -f -- "$tmp_file"
        CURRENT_TMP=""
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi

    if ! validate_candidate "$tmp_file"; then
        err "Generated output failed validation: $file"
        rm -f -- "$tmp_file"
        CURRENT_TMP=""
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi

    after_size="$(get_file_size "$tmp_file")"
    if (( REQUIRED_CHANGE == 0 )) && ! savings_meets_threshold "$before_size" "$after_size"; then
        log "Skipping below ${MIN_SAVINGS}% minimum savings: $file ($(human_size "$before_size") -> $(human_size "$after_size"))"
        rm -f -- "$tmp_file"
        CURRENT_TMP=""
        increment_skip "below-savings"
        return
    fi

    if ! commit_candidate "$file" "$rel" "$tmp_file" "$DESTINATION"; then
        err "Failed to commit output for: $file"
        if [[ -e "$tmp_file" ]]; then
            rm -f -- "$tmp_file"
        fi
        CURRENT_TMP=""
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi

    saving="$(savings_percent "$before_size" "$after_size")"
    BYTES_CHANGED_BEFORE=$((BYTES_CHANGED_BEFORE + before_size))
    BYTES_CHANGED_AFTER=$((BYTES_CHANGED_AFTER + after_size))
    FILES_CHANGED=$((FILES_CHANGED + 1))
    log "Changed: $file"
    log "  Size: ${SOURCE_WIDTH}x${SOURCE_HEIGHT} -> ${TARGET_WIDTH}x${TARGET_HEIGHT}"
    log "  Format: $SOURCE_FORMAT -> $OUTPUT_FORMAT"
    log "  Output: $DESTINATION"
    if (( after_size <= before_size )); then
        log "  Bytes: $(human_size "$before_size") -> $(human_size "$after_size") (${saving}% saved)"
    else
        log "  Bytes: $(human_size "$before_size") -> $(human_size "$after_size") (${saving#-}% larger)"
    fi
    log ""
}

process_file() {
    local file="$1"
    local inspect_status abs_file
    FILES_DISCOVERED=$((FILES_DISCOVERED + 1))

    if [[ -L "$file" ]]; then
        warn "Skipping symbolic link: $file"
        increment_skip "symlink"
        return
    fi
    if [[ ! -f "$file" ]]; then
        increment_skip "not-a-file"
        return
    fi

    case "${file,,}" in
        *.jpg|*.jpeg|*.png|*.webp) ;;
        *)
            increment_skip "unsupported"
            return
            ;;
    esac

    abs_file="$(readlink -f -- "$file")"
    if (( OVERWRITE == 0 )) && [[ -n "$ABS_OUTPUT" ]] && path_is_inside "$abs_file" "$ABS_OUTPUT"; then
        return
    fi
    if path_is_inside "$abs_file" "$ABS_BACKUP"; then
        return
    fi

    relative_path_for "$file"
    if ! selected_by_patterns "$REL_PATH"; then
        increment_skip "filtered"
        return
    fi

    inspect_file "$file"
    inspect_status=$?
    if (( inspect_status == 2 )); then
        increment_skip "unsupported"
        return
    elif (( inspect_status != 0 )); then
        warn "Could not read image; skipping: $file"
        FILES_FAILED=$((FILES_FAILED + 1))
        return
    fi

    process_supported_file "$file" "$REL_PATH"
}

process_input() {
    local file
    if [[ -L "$INPUT_PATH" ]]; then
        process_file "$INPUT_PATH"
    elif [[ -f "$INPUT_PATH" ]]; then
        process_file "$INPUT_PATH"
    elif [[ -d "$INPUT_PATH" ]]; then
        if (( RECURSIVE == 1 )); then
            while IFS= read -r -d '' file; do
                process_file "$file"
            done < <(find "$INPUT_PATH" -type f -print0)
        else
            while IFS= read -r -d '' file; do
                process_file "$file"
            done < <(find "$INPUT_PATH" -maxdepth 1 -type f -print0)
        fi
    else
        err "Input is neither a regular file nor a directory: $INPUT_PATH"
        exit 1
    fi
}

print_summary() {
    local net_bytes reason
    net_bytes=$((BYTES_CHANGED_BEFORE - BYTES_CHANGED_AFTER))
    log "============================================================"
    log "Summary"
    log "============================================================"
    log "Run timestamp:       $RUN_TIMESTAMP"
    log "Input:               $INPUT_PATH"
    if (( INSPECT == 1 )); then
        log "Mode:                inspect"
    elif (( DRY_RUN == 1 )); then
        log "Mode:                dry-run"
    elif (( OVERWRITE == 1 )); then
        log "Mode:                overwrite"
    else
        log "Mode:                result directory"
    fi
    if (( OVERWRITE == 0 && INSPECT == 0 )); then
        log "Result directory:    $OUTPUT_DIR"
    fi
    if (( OVERWRITE == 1 && NO_BACKUP == 0 )); then
        log "Backup directory:    $BACKUP_DIR"
    fi
    log "Files discovered:    $FILES_DISCOVERED"
    log "Supported images:    $FILES_SUPPORTED"
    log "Files changed:       $FILES_CHANGED"
    if (( DRY_RUN == 1 )); then
        log "Files considered:    $FILES_WOULD_CHANGE"
    fi
    log "Files skipped:       $FILES_SKIPPED"
    for reason in "${!SKIP_COUNTS[@]}"; do
        log "  $reason: ${SKIP_COUNTS[$reason]}"
    done
    log "Files failed:        $FILES_FAILED"
    log "Backups created:     $BACKUPS_CREATED"
    if (( ${#PACKAGES_INSTALLED[@]} > 0 )); then
        log "Packages installed:  ${PACKAGES_INSTALLED[*]}"
    fi
    if (( FILES_CHANGED > 0 )); then
        log "Changed bytes:       $(human_size "$BYTES_CHANGED_BEFORE") -> $(human_size "$BYTES_CHANGED_AFTER")"
        if (( net_bytes >= 0 )); then
            log "Net bytes saved:     $(human_size "$net_bytes")"
        else
            log "Net bytes increased: $(human_size "$((-net_bytes))")"
        fi
    fi
}

main() {
    parse_args "$@"
    validate_args
    ensure_dependencies
    resolve_tools
    initialize_paths
    process_input
    print_summary

    if (( FILES_FAILED > 0 )); then
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
