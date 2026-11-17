#!/usr/bin/env bash

set -euo pipefail

# Update the Codex CLI through npm without running npm as root.

readonly PACKAGE="@openai/codex"

usage() {
    cat <<EOF
Update the Codex CLI through npm as the current user.

Usage: $0 [--help]

Options:
  -h, --help  Show this help.

Run as your normal user, without sudo. Requires npm.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    case "$#" in
        0) ;;
        1)
            case "$1" in
                -h|--help) usage; exit 0 ;;
                *) die "unknown argument: $1" ;;
            esac
            ;;
        *) die "this script does not accept positional arguments" ;;
    esac
}

require_normal_user() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] \
        || die "run this updater as your normal user, not as root or through sudo."
}

require_npm() {
    command -v npm >/dev/null 2>&1 \
        || die "npm is required to install or update ${PACKAGE}."
}

print_section() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

get_installed_version() {
    local prefix="${1:-}"
    local args=(-g)

    if [[ -n "$prefix" ]]; then
        args+=(--prefix "$prefix")
    fi
    args+=("$PACKAGE" --depth=0)

    npm list "${args[@]}" 2>/dev/null \
        | sed -n 's/.*@openai\/codex@\([^[:space:]]*\).*/\1/p' \
        | head -n 1 || true
}

print_current_versions() {
    local npm_version

    print_section "Current Codex versions"
    if command -v codex >/dev/null 2>&1; then
        echo "codex CLI: $(codex --version || true)"
    else
        echo "codex CLI: not installed"
    fi

    npm_version="$(get_installed_version)"
    if [[ -n "$npm_version" ]]; then
        echo "npm package: ${PACKAGE}@${npm_version}"
    else
        echo "npm package: not installed"
    fi
}

prefix_is_writable() {
    local path="$1"

    while [[ ! -e "$path" && "$path" != "/" ]]; do
        path="$(dirname -- "$path")"
    done
    [[ -w "$path" ]]
}

resolve_install_prefix() {
    local active_prefix

    active_prefix="$(npm config get prefix)"
    if prefix_is_writable "$active_prefix"; then
        printf '%s\n' "$active_prefix"
    else
        printf '%s\n' "$HOME/.local"
    fi
}

install_update() {
    local install_prefix="$1"

    print_section "Updating Codex"
    echo "Installing into user-owned npm prefix: $install_prefix"
    mkdir -p "$install_prefix"
    npm install -g --prefix "$install_prefix" "${PACKAGE}@latest"
}

verify_update() {
    local install_prefix="$1"
    local expected_version="$2"
    local updated_version

    print_section "Updated versions"
    if command -v codex >/dev/null 2>&1; then
        codex --version
    else
        echo "codex command still not found"
    fi

    npm list -g --prefix "$install_prefix" "$PACKAGE" --depth=0 || true
    updated_version="$(get_installed_version "$install_prefix")"
    [[ "$updated_version" == "$expected_version" ]] \
        || die "npm reports ${updated_version:-no installed version}, expected $expected_version."

    if command -v codex >/dev/null 2>&1; then
        echo "Active codex binary: $(command -v codex)"
    fi
}

main() {
    local latest_version install_prefix installed_version
    local path_already_included=0

    parse_args "$@"
    require_normal_user
    require_npm
    print_current_versions

    echo
    print_section "Checking latest available version"
    latest_version="$(npm view "$PACKAGE" version)"
    echo "Latest available: $latest_version"
    echo

    install_prefix="$(resolve_install_prefix)"
    installed_version="$(get_installed_version "$install_prefix")"
    if [[ "$installed_version" == "$latest_version" ]]; then
        echo "Codex is already up to date."
        return 0
    fi

    case ":${PATH}:" in
        *":${install_prefix}/bin:"*) path_already_included=1 ;;
    esac

    install_update "$install_prefix"
    export PATH="$install_prefix/bin:$PATH"
    echo
    verify_update "$install_prefix" "$latest_version"

    if [[ "$path_already_included" -ne 1 ]]; then
        echo "Add ${install_prefix}/bin to your shell PATH to use this installation in new terminals."
    fi

    echo
    echo "Codex update completed."
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
