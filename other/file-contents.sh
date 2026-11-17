#!/usr/bin/env bash

set -euo pipefail

# Print the text files below a directory, or write the result atomically to a
# filename inside that directory.

readonly FILE_TITLE_PREFIX='##### File: '
readonly FILE_TITLE_SUFFIX=' #####'

TARGET_DIR=""
OUT_PATH=""
STDOUT_PATH=""
OUTPUT_TMP=""

usage() {
    cat <<EOF
Combine text file contents below a directory into one listing.

Usage:
  $0 /target/dir [output_filename]

Arguments:
  /target/dir        Root directory to scan recursively for text files.
  [output_filename]  Optional filename inside that directory; otherwise use stdout.

Options:
  -h, --help  Show this help.

Examples:
  $0 ./src dump.txt   # writes to ./src/dump.txt
  $0 ./src            # prints to stdout
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        usage
        exit 0
    fi
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }

    TARGET_DIR="$1"
    if [[ $# -eq 2 ]]; then
        [[ "$2" != */* && "$2" != "." && "$2" != ".." ]] \
            || die "output_filename must be a filename, not a path: $2"
        OUT_PATH="$(readlink -m -- "${TARGET_DIR%/}/$2")"
    fi
}

validate_args() {
    [[ -d "$TARGET_DIR" ]] || die "not a directory: $TARGET_DIR"
}

is_excluded_extension() {
    case "$1" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.gz|*.7z|*.tar|*.tgz|*.woff|*.woff2|*.ttf|*.eot|*.mp4|*.mp3|*.exe|*.dll)
            return 0
            ;;
        *) return 1 ;;
    esac
}

find_candidate_files() {
    find . -type f \
        \( \
            -path './.git/*' -o \
            -path './node_modules/*' -o \
            -path './vendor/*' -o \
            -path './dist/*' -o \
            -path './build/*' -o \
            -path './var/cache/*' \
        \) -prune -o \
        -type f -print0
}

emit_contents() {
    local excluded_output="${1:-}"
    local excluded_final="${2:-}"
    local file abs_file

    cd "$TARGET_DIR"
    while IFS= read -r -d '' file; do
        abs_file="$(readlink -f -- "$file" 2>/dev/null || true)"
        if [[ -n "$excluded_output" && "$abs_file" == "$excluded_output" ]]; then
            continue
        fi
        if [[ -n "$excluded_final" && "$abs_file" == "$excluded_final" ]]; then
            continue
        fi
        if [[ -n "$STDOUT_PATH" && "$abs_file" == "$STDOUT_PATH" ]]; then
            continue
        fi
        is_excluded_extension "$file" && continue

        # Include empty files and skip non-empty files that look binary.
        if [[ -s "$file" ]] && ! LC_ALL=C grep -Iq . "$file"; then
            continue
        fi

        printf '%s%s%s\n\n' "$FILE_TITLE_PREFIX" "${file#./}" "$FILE_TITLE_SUFFIX"
        cat -- "$file"
        printf '\n\n'
    done < <(find_candidate_files)
}

cleanup_output_tmp() {
    if [[ -n "$OUTPUT_TMP" ]]; then
        rm -f -- "$OUTPUT_TMP"
    fi
}

apply_output_metadata() {
    local current_umask output_mode

    if [[ -e "$OUT_PATH" ]]; then
        chmod --reference="$OUT_PATH" "$OUTPUT_TMP"
        touch --reference="$OUT_PATH" "$OUTPUT_TMP"
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            chown --reference="$OUT_PATH" "$OUTPUT_TMP"
        elif [[ "$(stat -c '%u' "$OUT_PATH")" -ne "$(id -u)" ]]; then
            cp -- "$OUTPUT_TMP" "$OUT_PATH"
            rm -f -- "$OUTPUT_TMP"
            OUTPUT_TMP=""
            return 1
        fi
    else
        current_umask="$(umask)"
        printf -v output_mode '%03o' "$((0666 & ~(8#$current_umask)))"
        chmod "$output_mode" "$OUTPUT_TMP"
    fi
    return 0
}

write_output_file() {
    local output_fd

    OUTPUT_TMP="$(mktemp --tmpdir="$(dirname -- "$OUT_PATH")" ".$(basename -- "$OUT_PATH").tmp.XXXXXX")"
    trap cleanup_output_tmp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    exec {output_fd}>"$OUTPUT_TMP"
    emit_contents "$OUTPUT_TMP" "$OUT_PATH" >&"$output_fd"
    exec {output_fd}>&-

    if apply_output_metadata; then
        mv -f -- "$OUTPUT_TMP" "$OUT_PATH"
        OUTPUT_TMP=""
    fi
    trap - EXIT INT TERM
}

main() {
    parse_args "$@"
    validate_args
    STDOUT_PATH="$(readlink -f -- "/proc/$$/fd/1" 2>/dev/null || true)"

    if [[ -n "$OUT_PATH" ]]; then
        write_output_file
    else
        emit_contents
    fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
