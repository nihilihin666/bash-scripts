#!/usr/bin/env bash

set -euo pipefail

# Randomise filenames recursively, with a reversible map by default.
#
# Usage:
#   ./bash-scripts/randomise-filenames.sh [--prefix <prefix>] [--no-manifest] <directory>
#   ./bash-scripts/randomise-filenames.sh --reverse <map-file>

usage() {
    cat <<EOF
Randomise filenames recursively, saving an undo map by default.

Usage:
  $0 [--prefix <prefix>] [--no-manifest] <directory>
  $0 --reverse <map-file>

Arguments:
  <directory>  Directory whose files are renamed recursively.

Options:
  --prefix <prefix>  Add a prefix before each random seven-digit number.
  --no-manifest      Do not keep an undo map after a successful rename.
  --reverse <map>    Restore names using a previously created map.
  -h, --help         Show this help.
      --             End options; treat remaining values as positional arguments.

Undo maps are saved under: \$HOME/bash-scripts-output/
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

PREFIX=""
DIR=""
REVERSE_MAP=""
KEEP_MANIFEST=1
MAP_DIR="$HOME/bash-scripts-output"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                [[ $# -ge 2 && -n "$2" ]] || die "--prefix requires a value"
                PREFIX="$2"
                shift 2
                ;;
            --no-manifest)
                KEEP_MANIFEST=0
                shift
                ;;
            --reverse)
                [[ $# -ge 2 && -n "$2" ]] || die "--reverse requires a map file"
                REVERSE_MAP="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    [[ -z "$DIR" ]] || die "expected exactly one directory"
                    DIR="$1"
                    shift
                done
                break
                ;;
            -*)
                usage >&2
                die "unknown argument '$1'"
                ;;
            *)
                [[ -z "$DIR" ]] || die "multiple directory paths were provided"
                DIR="$1"
                shift
                ;;
        esac
    done
}

validate_args() {
    if [[ -n "$REVERSE_MAP" ]]; then
        [[ -z "$DIR" && -z "$PREFIX" && "$KEEP_MANIFEST" -eq 1 ]] \
            || die "--reverse cannot be combined with a directory, --prefix, or --no-manifest"
    else
        [[ -n "$DIR" ]] || { usage >&2; exit 1; }
    fi
    [[ "$PREFIX" != */* ]] \
        || die "--prefix must be a filename prefix and cannot contain '/'"
}

encode_path() {
    printf '%s' "$1" | base64 -w 0
}

decode_into() {
    local variable_name="$1"
    local encoded="$2"
    local decoded
    if ! decoded="$(
        printf '%s' "$encoded" | base64 --decode 2>/dev/null
        decode_status=$?
        printf '.'
        exit "$decode_status"
    )"; then
        return 1
    fi
    printf -v "$variable_name" '%s' "${decoded%.}"
}

is_safe_relative_path() {
    local path="$1"
    local component
    [[ -n "$path" && "$path" != /* ]] || return 1
    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        [[ "$component" != ".." ]] || return 1
    done
}

relative_to_root() {
    local root="$1"
    local path="$2"
    if [[ "$root" == "/" ]]; then
        printf '%s' "${path#/}"
    else
        printf '%s' "${path#"$root"/}"
    fi
}

path_is_within_root() {
    local root="$1"
    local path="$2"
    if [[ "$root" == "/" ]]; then
        [[ "$path" == /* ]]
    else
        [[ "$path" == "$root"/* ]]
    fi
}

random_7_digit_number() {
    local value
    value="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    echo $((value % 9000000 + 1000000))
}

extension_of() {
    local basename="$1"
    if [[ "$basename" != *.* || "$basename" == *. || "$basename" == .* && "$basename" != *.*.* ]]; then
        echo ""
    else
        echo ".${basename##*.}"
    fi
}

declare -a source_paths=()
declare -a destination_paths=()
declare -a temporary_paths=()
declare -a staging_dirs=()
declare -A original_paths=()
TRANSACTION_SUCCESS=0
TRANSACTION_STARTED=0
MAP_FILE=""
REMOVE_MAP_ON_SUCCESS=0

cleanup_empty_staging() {
    local staging_dir
    for staging_dir in "${staging_dirs[@]}"; do
        rmdir -- "$staging_dir" 2>/dev/null || true
    done
}

rollback_transaction() {
    local i rollback_failed=0
    set +e

    for ((i=${#source_paths[@]} - 1; i>=0; i--)); do
        if [[ -e "${destination_paths[$i]}" && ! -e "${temporary_paths[$i]}" ]]; then
            mv -- "${destination_paths[$i]}" "${temporary_paths[$i]}" || rollback_failed=1
        fi
    done
    for ((i=${#source_paths[@]} - 1; i>=0; i--)); do
        if [[ -e "${temporary_paths[$i]}" && ! -e "${source_paths[$i]}" ]]; then
            mv -- "${temporary_paths[$i]}" "${source_paths[$i]}" || rollback_failed=1
        fi
    done
    cleanup_empty_staging

    if [[ "$rollback_failed" -eq 0 ]]; then
        if [[ "$REMOVE_MAP_ON_SUCCESS" -eq 1 && -n "$MAP_FILE" ]]; then
            rm -f -- "$MAP_FILE"
        fi
        echo "Rename failed; all original filenames were restored." >&2
    else
        echo "Rename failed and automatic recovery was incomplete." >&2
        [[ -n "$MAP_FILE" ]] && echo "Recovery map: $MAP_FILE" >&2
    fi
}

on_transaction_exit() {
    local status=$?
    if [[ "$TRANSACTION_STARTED" -eq 1 && "$TRANSACTION_SUCCESS" -ne 1 ]]; then
        rollback_transaction
    else
        cleanup_empty_staging
    fi
    return "$status"
}

cleanup_before_transaction() {
    cleanup_empty_staging
    if [[ "$TRANSACTION_STARTED" -eq 0 && "$REMOVE_MAP_ON_SUCCESS" -eq 1 && -n "$MAP_FILE" ]]; then
        rm -f -- "$MAP_FILE"
    fi
}

run_transaction() {
    local i
    TRANSACTION_STARTED=1
    trap on_transaction_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for i in "${!source_paths[@]}"; do
        mv -- "${source_paths[$i]}" "${temporary_paths[$i]}"
    done
    for i in "${!temporary_paths[@]}"; do
        mv -- "${temporary_paths[$i]}" "${destination_paths[$i]}"
    done

    TRANSACTION_SUCCESS=1
    trap - EXIT INT TERM
    cleanup_empty_staging
}

reverse_from_map() {
    local map="$1"
    local owner kind first second extra decoded_root="" old_rel new_rel
    local root=""
    local line_number=0 i staging_dir
    local header_seen=0
    declare -A current_sources=()
    declare -A mapped_sources=()
    declare -A mapped_destinations=()

    [[ -f "$map" ]] || { echo "Error: map file not found: $map" >&2; exit 1; }
    owner="$(stat -c '%u' "$map")"
    [[ "$owner" -eq "$(id -u)" ]] || { echo "Error: refusing a map owned by another user" >&2; exit 1; }

    source_paths=()
    destination_paths=()
    while IFS=$'\t' read -r kind first second extra || [[ -n "$kind" ]]; do
        line_number=$((line_number + 1))
        case "$kind" in
            randomise-filenames-map-v1)
                [[ "$line_number" -eq 1 && "$header_seen" -eq 0 && -z "${first:-}" && -z "${second:-}" && -z "${extra:-}" ]] || {
                    echo "Error: invalid or duplicate map header at line $line_number" >&2; exit 1;
                }
                header_seen=1
                ;;
            '#'* ) ;;
            root)
                [[ -z "$root" && -n "$first" && -z "${second:-}" && -z "${extra:-}" ]] || {
                    echo "Error: invalid root record at line $line_number" >&2; exit 1;
                }
                decode_into decoded_root "$first" || { echo "Error: invalid root encoding" >&2; exit 1; }
                root="$decoded_root"
                ;;
            file)
                [[ -n "$first" && -n "$second" && -z "${extra:-}" ]] || { echo "Error: invalid file record at line $line_number" >&2; exit 1; }
                decode_into old_rel "$first" || { echo "Error: invalid original path encoding" >&2; exit 1; }
                decode_into new_rel "$second" || { echo "Error: invalid randomized path encoding" >&2; exit 1; }
                if ! is_safe_relative_path "$old_rel" || ! is_safe_relative_path "$new_rel"; then
                    echo "Error: unsafe path in map at line $line_number" >&2; exit 1;
                fi
                if [[ -n "${mapped_sources[$new_rel]+x}" || -n "${mapped_destinations[$old_rel]+x}" ]]; then
                    echo "Error: duplicate path in map at line $line_number" >&2; exit 1
                fi
                mapped_sources["$new_rel"]=1
                mapped_destinations["$old_rel"]=1
                destination_paths+=("$old_rel")
                source_paths+=("$new_rel")
                ;;
            '') ;;
            *) echo "Error: unknown map record at line $line_number" >&2; exit 1 ;;
        esac
    done < "$map"

    [[ "$header_seen" -eq 1 ]] || { echo "Error: map header is missing" >&2; exit 1; }
    [[ -n "$root" && -d "$root" ]] || { echo "Error: map root is unavailable: ${root:-<missing>}" >&2; exit 1; }
    root="$(readlink -f -- "$root")"
    [[ ${#source_paths[@]} -gt 0 ]] || { echo "Error: map contains no file records" >&2; exit 1; }

    for i in "${!source_paths[@]}"; do
        source_paths[i]="$(readlink -m -- "$root/${source_paths[i]}")"
        destination_paths[i]="$(readlink -m -- "$root/${destination_paths[i]}")"
        path_is_within_root "$root" "${source_paths[$i]}" || { echo "Error: randomized path escapes the map root" >&2; exit 1; }
        path_is_within_root "$root" "${destination_paths[$i]}" || { echo "Error: original path escapes the map root" >&2; exit 1; }
        current_sources["${source_paths[$i]}"]=1
    done
    for i in "${!source_paths[@]}"; do
        [[ -f "${source_paths[$i]}" ]] || { echo "Error: randomized file is missing: ${source_paths[$i]}" >&2; exit 1; }
        if [[ -e "${destination_paths[$i]}" && -z "${current_sources[${destination_paths[$i]}]+x}" ]]; then
            echo "Error: original destination already exists: ${destination_paths[$i]}" >&2
            exit 1
        fi
    done

    temporary_paths=()
    staging_dirs=()
    original_paths=()
    for i in "${!source_paths[@]}"; do
        staging_dir="$(mktemp -d "$(dirname -- "${source_paths[$i]}")/.randomise-filenames-reverse.XXXXXX")"
        staging_dirs+=("$staging_dir")
        temporary_paths+=("$staging_dir/file")
    done

    MAP_FILE="$map"
    REMOVE_MAP_ON_SUCCESS=0
    run_transaction
    printf 'Restored %d file(s) using %s\n' "${#source_paths[@]}" "$map"
}

reset_transaction_state() {
    source_paths=()
    destination_paths=()
    temporary_paths=()
    staging_dirs=()
    TRANSACTION_SUCCESS=0
    TRANSACTION_STARTED=0
    MAP_FILE=""
    REMOVE_MAP_ON_SUCCESS=0
}

collect_source_paths() {
    local root_dir="$1"
    local map_dir_abs="$2"
    local filepath abs_file

    while IFS= read -r -d '' filepath; do
        abs_file="$(readlink -f -- "$filepath")"
        case "$abs_file/" in
            "$map_dir_abs/"*) continue ;;
        esac
        source_paths+=("$abs_file")
        original_paths["$abs_file"]=1
    done < <(find "$root_dir" -type f -print0)
}

plan_random_destinations() {
    local index source source_dir source_name extension final_path staging_dir
    declare -A reserved_final_paths=()

    for index in "${!source_paths[@]}"; do
        source="${source_paths[$index]}"
        source_dir="$(dirname -- "$source")"
        source_name="$(basename -- "$source")"
        extension="$(extension_of "$source_name")"
        while :; do
            final_path="$source_dir/${PREFIX}$(random_7_digit_number)${extension}"
            if [[ -z "${reserved_final_paths[$final_path]+x}" ]] \
                && { [[ ! -e "$final_path" ]] || [[ -n "${original_paths[$final_path]+x}" ]]; }; then
                reserved_final_paths["$final_path"]=1
                break
            fi
        done
        destination_paths+=("$final_path")
        staging_dir="$(mktemp -d "$source_dir/.randomise-filenames.XXXXXX")"
        staging_dirs+=("$staging_dir")
        temporary_paths+=("$staging_dir/file")
    done
}

create_undo_map() {
    local root_dir="$1"
    local index old_rel new_rel

    mkdir -p "$MAP_DIR"
    REMOVE_MAP_ON_SUCCESS=1
    MAP_FILE="$(mktemp "$MAP_DIR/randomise-filenames-$(date +%Y%m%d-%H%M%S).XXXXXX.map")"
    chmod 600 "$MAP_FILE"
    {
        echo 'randomise-filenames-map-v1'
        printf 'root\t%s\n' "$(encode_path "$root_dir")"
        for index in "${!source_paths[@]}"; do
            old_rel="$(relative_to_root "$root_dir" "${source_paths[$index]}")"
            new_rel="$(relative_to_root "$root_dir" "${destination_paths[$index]}")"
            printf 'file\t%s\t%s\n' "$(encode_path "$old_rel")" "$(encode_path "$new_rel")"
            printf '# %q -> %q\n' "$old_rel" "$new_rel"
        done
    } > "$MAP_FILE"
}

report_forward_result() {
    local root_dir="$1"

    if [[ "$KEEP_MANIFEST" -eq 1 ]]; then
        REMOVE_MAP_ON_SUCCESS=0
        printf 'Randomised %d file(s) in %s\n' "${#source_paths[@]}" "$root_dir"
        echo "Undo map: $MAP_FILE"
    else
        rm -f -- "$MAP_FILE"
        MAP_FILE=""
        printf 'Randomised %d file(s) in %s (undo map disabled)\n' "${#source_paths[@]}" "$root_dir"
    fi
}

randomise_forward() {
    local root_dir map_dir_abs

    [[ -d "$DIR" ]] || { echo "Error: '$DIR' is not a directory" >&2; exit 2; }
    root_dir="$(readlink -f -- "$DIR")"
    map_dir_abs="$(readlink -m -- "$MAP_DIR")"
    collect_source_paths "$root_dir" "$map_dir_abs"
    if [[ ${#source_paths[@]} -eq 0 ]]; then
        echo "No files found in '$DIR'."
        return 0
    fi

    plan_random_destinations
    create_undo_map "$root_dir"
    run_transaction
    report_forward_result "$root_dir"
}

main() {
    parse_args "$@"
    validate_args
    reset_transaction_state
    trap cleanup_before_transaction EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ -n "$REVERSE_MAP" ]]; then
        reverse_from_map "$REVERSE_MAP"
    else
        randomise_forward
    fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
