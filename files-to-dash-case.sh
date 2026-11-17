#!/usr/bin/env bash

set -euo pipefail

# Rename files in a target directory to dash-case style.

TARGET_DIR=""
RECURSIVE=0
TRIM=0
LOWER=0
CAMEL=0
RENAME_SUCCESS=0
COMPLETED_OLD=()
COMPLETED_NEW=()

usage() {
    cat <<EOF
Rename files in a directory to dash-case, with optional recursive processing.

Usage: $0 [options] <directory>

Arguments:
  <directory>  Directory containing the files to rename.

Options:
  -r, --recursive  Process files recursively.
  -t, --trim       Trim leading and trailing dashes from the basename.
      --lower      Convert uppercase characters to lowercase.
      --camel      Convert camelCase/PascalCase boundaries and lowercase.
  -h, --help       Show this help.
      --           End options; treat remaining values as positional arguments.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--recursive) RECURSIVE=1 ;;
            -t|--trim) TRIM=1 ;;
            --lower) LOWER=1 ;;
            --camel) CAMEL=1 ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    [[ -z "$TARGET_DIR" ]] || die "multiple directory paths were provided."
                    TARGET_DIR="$1"
                    shift
                done
                break
                ;;
            -*)
                usage >&2
                die "unknown parameter: $1"
                ;;
            *)
                [[ -z "$TARGET_DIR" ]] || die "multiple directory paths were provided."
                TARGET_DIR="$1"
                ;;
        esac
        shift
    done
}

validate_args() {
    [[ -n "$TARGET_DIR" ]] || { echo "Error: directory path is required." >&2; usage >&2; exit 1; }
    [[ ! ( "$LOWER" -eq 1 && "$CAMEL" -eq 1 ) ]] \
        || die "--lower and --camel cannot be used together."
    [[ -d "$TARGET_DIR" ]] || die "target is not a directory: $TARGET_DIR"
}

camel_to_dash_lower() {
    local input="$1"
    local output="" char="" previous="" next=""
    local length=${#input}
    local index=0

    while [[ "$index" -lt "$length" ]]; do
        char="${input:$index:1}"
        previous=""
        next=""
        if [[ "$index" -gt 0 ]]; then
            previous="${input:$((index - 1)):1}"
        fi
        if [[ $((index + 1)) -lt "$length" ]]; then
            next="${input:$((index + 1)):1}"
        fi

        if [[ "$char" =~ [[:upper:]] ]]; then
            if [[ -n "$output" ]] \
                && { [[ "$previous" =~ [[:lower:][:digit:]] ]] \
                    || { [[ "$previous" =~ [[:upper:]] ]] && [[ "$next" =~ [[:lower:]] ]]; }; }; then
                output+="-"
            fi
            output+="${char,,}"
        else
            output+="$char"
        fi
        index=$((index + 1))
    done

    printf '%s' "$output"
}

split_filename() {
    local filename="$1"
    local basename_var="$2"
    local extension_var="$3"
    local result_basename result_extension

    if [[ "$filename" == .* && "$filename" != *.*.* ]]; then
        result_basename="$filename"
        result_extension=""
    elif [[ "$filename" == *.* ]]; then
        result_extension="${filename##*.}"
        result_basename="${filename%.*}"
    else
        result_basename="$filename"
        result_extension=""
    fi
    printf -v "$basename_var" '%s' "$result_basename"
    printf -v "$extension_var" '%s' "$result_extension"
}

normalize_component() {
    printf '%s' "$1" | sed -E 's/[^a-zA-Z0-9-]+/-/g; s/-+/-/g'
}

normalize_filename() {
    local filename="$1"
    local basename extension

    split_filename "$filename" basename extension
    if [[ "$CAMEL" -eq 1 ]]; then
        basename="$(camel_to_dash_lower "$basename")"
        extension="${extension,,}"
    elif [[ "$LOWER" -eq 1 ]]; then
        basename="${basename,,}"
        extension="${extension,,}"
    fi

    basename="$(normalize_component "$basename")"
    extension="$(normalize_component "$extension")"
    if [[ "$TRIM" -eq 1 ]]; then
        basename="$(printf '%s' "$basename" | sed -E 's/^-+//; s/-+$//')"
    fi

    if [[ -n "$extension" ]]; then
        printf '%s.%s' "$basename" "$extension"
    else
        printf '%s' "$basename"
    fi
}

rename_file() {
    local file_path="$1"
    local directory old_name new_name new_path

    directory="$(dirname -- "$file_path")"
    old_name="$(basename -- "$file_path")"
    new_name="$(normalize_filename "$old_name")"
    if [[ -z "$new_name" || "$old_name" == "$new_name" ]]; then
        return 0
    fi

    new_path="$directory/$new_name"
    if [[ -e "$new_path" ]]; then
        echo "Skip: target already exists: $new_path" >&2
        return 0
    fi

    if ! mv -- "$file_path" "$new_path"; then
        echo "Error: failed to rename: $file_path -> $new_path" >&2
        return 1
    fi
    COMPLETED_OLD+=("$file_path")
    COMPLETED_NEW+=("$new_path")
    echo "$file_path -> $new_path"
}

find_target_files() {
    if [[ "$RECURSIVE" -eq 1 ]]; then
        find "$TARGET_DIR" -depth -type f -print0
    else
        find "$TARGET_DIR" -maxdepth 1 -type f -print0
    fi
}

rollback_completed_renames() {
    local index rollback_failed=0

    set +e
    for ((index=${#COMPLETED_OLD[@]} - 1; index>=0; index--)); do
        if [[ -e "${COMPLETED_NEW[$index]}" && ! -e "${COMPLETED_OLD[$index]}" ]]; then
            mv -- "${COMPLETED_NEW[$index]}" "${COMPLETED_OLD[$index]}" || rollback_failed=1
        fi
    done
    if [[ "$rollback_failed" -eq 0 ]]; then
        echo "Rename operation failed; completed renames were rolled back." >&2
    else
        echo "Rename operation failed and rollback was incomplete." >&2
    fi
}

on_rename_exit() {
    local status=$?

    if [[ "$RENAME_SUCCESS" -ne 1 ]]; then
        rollback_completed_renames
    fi
    return "$status"
}

perform_renames() {
    local file_path

    trap on_rename_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while IFS= read -r -d '' file_path; do
        rename_file "$file_path"
    done < <(find_target_files)
    RENAME_SUCCESS=1
    trap - EXIT INT TERM
}

main() {
    parse_args "$@"
    validate_args
    perform_renames
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
