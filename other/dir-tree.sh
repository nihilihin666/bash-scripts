#!/usr/bin/env bash

set -euo pipefail

# Print directories and files recursively from a target directory.
#
# Examples:
#   ./bash-scripts/other/dir-tree.sh ~/Dev/DockerProjects
#   ./bash-scripts/other/dir-tree.sh --tree ~/Dev/DockerProjects
#   ./bash-scripts/other/dir-tree.sh -t ~/Dev/DockerProjects

USE_TREE=0
TARGET=""

usage() {
    cat <<EOF
List files and directories recursively under a target directory.

Usage:
  $0 [--tree|-t] /path/to/target

Arguments:
  /path/to/target  Directory whose files and subdirectories are listed.

Options:
  -t, --tree  Use tree(1) instead of the default find-based listing.
  -h, --help  Show this help.
      --      End options; treat remaining values as positional arguments.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tree)
                USE_TREE=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    [[ -z "$TARGET" ]] || die "multiple directory paths were provided"
                    TARGET="$1"
                    shift
                done
                break
                ;;
            -*)
                die "unknown argument: $1"
                ;;
            *)
                [[ -z "$TARGET" ]] || die "multiple directory paths were provided"
                TARGET="$1"
                ;;
        esac
        shift
    done
}

validate_args() {
    [[ -n "$TARGET" ]] || { usage >&2; exit 1; }
    [[ -d "$TARGET" ]] || { echo "Error: '$TARGET' is not a directory." >&2; exit 3; }
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

ensure_tree() {
    local os_id

    command -v tree >/dev/null 2>&1 && return 0
    os_id="$(detect_os)"
    echo "tree not found. Installing..."

    case "$os_id" in
        ubuntu|debian)
            sudo apt update
            sudo apt install -y tree
            ;;
        fedora)
            sudo dnf install -y tree
            ;;
        *)
            echo "Unsupported OS: $os_id" >&2
            echo "Please install 'tree' manually." >&2
            exit 2
            ;;
    esac
}

print_find_listing() {
    LC_ALL=C find "$TARGET" -mindepth 1 -printf '%y %P\n' | sort
}

print_tree_listing() {
    ensure_tree
    tree -a -F --dirsfirst --noreport "$TARGET"
}

main() {
    parse_args "$@"
    validate_args

    if [[ "$USE_TREE" -eq 1 ]]; then
        print_tree_listing
    else
        print_find_listing
    fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
