#!/usr/bin/env bash

set -euo pipefail

# Start or reuse ssh-agent and ensure a selected key is loaded.

readonly AGENT_ENV_FILE="$HOME/.ssh/agent.env"

SSH_KEY_NAME="id_ed25519"
SSH_KEY_PATH=""
PRINT_ENV=0
AGENT_TMP=""

usage() {
    cat <<EOF
Start or reuse ssh-agent and load a selected SSH key.

Usage: $0 [--key filename] [--print-env]

Options:
  --key filename  Load this key from ~/.ssh (default: id_ed25519).
  --print-env     Print only shell-compatible export commands to stdout.
  -h, --help      Show this help.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

log() {
    if [[ "$PRINT_ENV" -eq 1 ]]; then
        echo "$*" >&2
    else
        echo "$*"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)
                [[ $# -ge 2 && -n "$2" ]] || die "--key requires a value"
                SSH_KEY_NAME="$2"
                shift 2
                ;;
            --print-env)
                PRINT_ENV=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

validate_args() {
    [[ "$SSH_KEY_NAME" != */* && "$SSH_KEY_NAME" != "." && "$SSH_KEY_NAME" != ".." ]] \
        || die "--key must be a key filename inside ~/.ssh"

    SSH_KEY_PATH="$HOME/.ssh/$SSH_KEY_NAME"
    [[ -f "$SSH_KEY_PATH" ]] || die "SSH key not found: $SSH_KEY_PATH"
}

require_commands() {
    local command_name

    for command_name in ssh-add ssh-agent ssh-keygen stat; do
        command -v "$command_name" >/dev/null 2>&1 \
            || die "required command not found: $command_name"
    done
}

cleanup_agent_tmp() {
    if [[ -n "$AGENT_TMP" ]]; then
        rm -f -- "$AGENT_TMP"
    fi
}

agent_responds() {
    local status

    [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]] || return 1
    set +e
    ssh-add -l >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

load_saved_agent() {
    local owner mode key value saved_sock="" saved_pid=""

    [[ -f "$AGENT_ENV_FILE" ]] || return 1
    owner="$(stat -c '%u' "$AGENT_ENV_FILE")"
    mode="$(stat -c '%a' "$AGENT_ENV_FILE")"
    [[ "$owner" -eq "$(id -u)" && "$mode" == "600" ]] || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            SSH_AUTH_SOCK) saved_sock="$value" ;;
            SSH_AGENT_PID) saved_pid="$value" ;;
        esac
    done < "$AGENT_ENV_FILE"

    [[ -n "$saved_sock" ]] || return 1
    export SSH_AUTH_SOCK="$saved_sock"
    if [[ -n "$saved_pid" ]]; then
        export SSH_AGENT_PID="$saved_pid"
    fi
    agent_responds
}

save_agent() {
    mkdir -p "$HOME/.ssh"
    AGENT_TMP="$(mktemp "$HOME/.ssh/.agent.env.tmp.XXXXXX")"
    chmod 600 "$AGENT_TMP"
    {
        printf 'SSH_AUTH_SOCK=%s\n' "$SSH_AUTH_SOCK"
        printf 'SSH_AGENT_PID=%s\n' "${SSH_AGENT_PID:-}"
    } > "$AGENT_TMP"
    mv -f -- "$AGENT_TMP" "$AGENT_ENV_FILE"
    AGENT_TMP=""
}

start_agent() {
    local output sock pid

    output="$(ssh-agent -s)"
    sock="$(printf '%s\n' "$output" | sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*/\1/p')"
    pid="$(printf '%s\n' "$output" | sed -n 's/^SSH_AGENT_PID=\([^;]*\);.*/\1/p')"
    if [[ -z "$sock" || -z "$pid" || ! -S "$sock" ]]; then
        die "ssh-agent started but its environment could not be read"
    fi
    export SSH_AUTH_SOCK="$sock"
    export SSH_AGENT_PID="$pid"
    save_agent
}

ensure_agent() {
    if agent_responds; then
        log "ssh-agent already running."
    elif load_saved_agent; then
        log "Reusing saved ssh-agent."
    else
        log "Starting ssh-agent..."
        start_agent
    fi
}

ensure_key_loaded() {
    local key_fingerprint

    key_fingerprint="$(ssh-keygen -lf "$SSH_KEY_PATH" | awk 'NR == 1 {print $2}')"
    [[ -n "$key_fingerprint" ]] \
        || die "could not determine SSH key fingerprint: $SSH_KEY_PATH"

    if ssh-add -l 2>/dev/null | awk '{print $2}' | grep -Fxq -- "$key_fingerprint"; then
        log "SSH key already added."
    else
        log "Adding SSH key: $SSH_KEY_NAME"
        ssh-add "$SSH_KEY_PATH"
    fi
}

print_agent_environment() {
    if [[ "$PRINT_ENV" -eq 1 ]]; then
        printf 'export SSH_AUTH_SOCK=%q SSH_AGENT_PID=%q\n' "$SSH_AUTH_SOCK" "${SSH_AGENT_PID:-}"
    else
        printf 'To use this agent in the current shell, run:\n'
        printf '  export SSH_AUTH_SOCK=%q SSH_AGENT_PID=%q\n' "$SSH_AUTH_SOCK" "${SSH_AGENT_PID:-}"
    fi
}

main() {
    parse_args "$@"
    validate_args
    require_commands

    trap cleanup_agent_tmp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ensure_agent
    ensure_key_loaded
    print_agent_environment
    trap - EXIT INT TERM
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
