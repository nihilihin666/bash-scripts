#!/usr/bin/env bash

# Update this directory without requiring GitHub credentials or Git knowledge.

UPDATE_URL='https://github.com/nihilihin666/bash-scripts.git'
UPDATE_ROOT=''
UPDATE_STAGE=''
UPDATE_LOCK=''
UPDATE_LOCK_HELD=0
UPDATE_BACKUP=''

usage() {
    printf '%s\n' "Usage: $0 [--help]

Update this bash-scripts directory from the public GitHub repository:
  https://github.com/nihilihin666/bash-scripts

Options:
  -h, --help  Show this help.

Run as your normal user. Requires git, network access, and standard Linux tools.
No GitHub account, SSH key, or login is required. Installs no packages.
Works from any working directory; updates the directory containing this script.

Git checkouts: update the remote default branch by fast-forward only. Local
changes, untracked files, local commits, detached HEAD, other branches, and
unfinished Git operations cause refusal. The configured origin is unchanged.

Folders without .git: download a fresh checkout, back up the entire old folder
under \$HOME/bash-scripts-output/repository-backups/, then replace the folder.
The backup includes your local files. Future updates use the new Git checkout.
The parent directory must be writable for locking and folder replacement.
Concurrent updates are refused. An interrupted replacement restores the old
folder when possible. Results and recovery paths are printed to the terminal."
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

git_update() {
    # Never prompt for credentials or run merge/checkout hooks. Use the explicit
    # HTTPS URL instead of origin, which may be configured for an SSH account.
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
        git -c credential.helper= -c core.askPass=/bin/false \
            -c core.hooksPath=/dev/null -c submodule.recurse=false "$@"
}

cleanup_update() {
    local status=$? keep_stage=0
    if [[ -n "$UPDATE_STAGE" && -d "$UPDATE_STAGE" ]]; then
        if [[ -d "$UPDATE_STAGE/previous" && -e "$UPDATE_STAGE/repository" ]]; then
            if [[ ! -e "$UPDATE_ROOT" && ! -L "$UPDATE_ROOT" ]]; then
                if mv -T -- "$UPDATE_STAGE/previous" "$UPDATE_ROOT"; then
                    printf 'Restored the original folder after replacement failed.\n' >&2
                else
                    keep_stage=1
                fi
            else
                keep_stage=1
            fi
            if (( keep_stage )); then
                printf 'Original folder retained for recovery: %s/previous\n' "$UPDATE_STAGE" >&2
            fi
        fi
        if (( ! keep_stage )); then
            rm -rf -- "$UPDATE_STAGE"
        fi
    fi
    if (( UPDATE_LOCK_HELD )); then
        rmdir -- "$UPDATE_LOCK" || printf 'Warning: could not remove update lock: %s\n' "$UPDATE_LOCK" >&2
    fi
    return "$status"
}

remote_default_branch() {
    local listing kind ref target branch=''
    listing="$(git_update ls-remote --symref -- "$UPDATE_URL" HEAD)" \
        || die 'Could not contact GitHub. Check your network connection and try again.'
    while read -r kind ref target; do
        if [[ "$kind" == 'ref:' && "$target" == HEAD && "$ref" == refs/heads/* ]]; then
            [[ -z "$branch" ]] || die 'GitHub reported more than one default branch.'
            branch="${ref#refs/heads/}"
        fi
    done <<< "$listing"
    [[ -n "$branch" ]] || die 'Could not determine the repository default branch.'
    git_update check-ref-format "refs/heads/$branch" >/dev/null \
        || die 'GitHub reported an invalid default branch.'
    printf '%s\n' "$branch"
}

require_clean_checkout() {
    local changes operation path
    changes="$(git_update -C "$UPDATE_ROOT" status --porcelain=v1 --untracked-files=all)" \
        || die 'Could not inspect local changes.'
    if [[ -n "$changes" ]]; then
        printf '%s\n' "$changes" >&2
        die 'Local changes or extra files were found. Keep this folder as your working copy and download a separate fresh copy to update safely.'
    fi
    for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply BISECT_LOG; do
        path="$(git_update -C "$UPDATE_ROOT" rev-parse --git-path "$operation")" \
            || die 'Could not inspect Git operation state.'
        [[ "$path" == /* ]] || path="$UPDATE_ROOT/$path"
        [[ ! -e "$path" ]] || die 'An unfinished Git operation was found. Finish or recover that operation before updating.'
    done
}

update_checkout() {
    local root branch default_branch before after
    root="$(git_update -C "$UPDATE_ROOT" rev-parse --show-toplevel)" \
        || die 'The .git metadata is invalid. The folder was left unchanged.'
    [[ "$(readlink -f -- "$root")" == "$UPDATE_ROOT" ]] \
        || die 'This script is not at the root of its Git checkout.'
    branch="$(git_update -C "$UPDATE_ROOT" symbolic-ref --quiet --short HEAD)" \
        || die 'This checkout is in detached HEAD state. Download a separate fresh copy instead.'
    require_clean_checkout
    default_branch="$(remote_default_branch)" || return 1
    [[ "$branch" == "$default_branch" ]] \
        || die "This checkout uses branch '$branch', but the published default is '$default_branch'. Download a separate fresh copy instead."
    before="$(git_update -C "$UPDATE_ROOT" rev-parse HEAD)" || die 'Could not read the current version.'
    git_update -C "$UPDATE_ROOT" fetch --no-tags --no-recurse-submodules \
        "$UPDATE_URL" "refs/heads/$default_branch" \
        || die 'Download failed. Your working files were left unchanged; check the network and retry.'
    after="$(git_update -C "$UPDATE_ROOT" rev-parse FETCH_HEAD)" || die 'Could not read the downloaded version.'
    git_update -C "$UPDATE_ROOT" merge-base --is-ancestor "$before" "$after" \
        || die 'Local commits or rewritten remote history prevent a safe fast-forward. Keep this folder and download a separate fresh copy.'
    # Repeat after the network operation. Git also checks for files that would
    # be overwritten, including ignored files, immediately before replacement.
    require_clean_checkout
    [[ "$(git_update -C "$UPDATE_ROOT" symbolic-ref --quiet --short HEAD)" == "$branch" \
        && "$(git_update -C "$UPDATE_ROOT" rev-parse HEAD)" == "$before" ]] \
        || die 'The local branch or version changed during download. Stop other Git operations and try again.'
    if [[ "$before" == "$after" ]]; then
        printf 'Already up to date.\n'
        return
    fi
    git_update -C "$UPDATE_ROOT" -c merge.autostash=false merge \
        --ff-only --no-edit --no-overwrite-ignore "$after" \
        || die 'Update could not be applied safely. No reset or automatic conflict resolution was attempted.'
    printf 'Updated bash-scripts to %s.\n' "$after"
}

update_plain_folder() {
    local parent backup_root
    parent="$(dirname -- "$UPDATE_ROOT")"
    backup_root="$(readlink -m -- "$HOME/bash-scripts-output/repository-backups")"
    case "$backup_root/" in
        "$UPDATE_ROOT/"*) die 'The backup destination is inside this folder. Move bash-scripts into its own directory before updating.' ;;
    esac
    UPDATE_STAGE="$(mktemp -d "$parent/.bash-scripts-update.XXXXXX")" \
        || die 'Could not create a staging directory next to bash-scripts.'
    printf 'Downloading a fresh checkout...\n'
    git_update clone --origin origin -- "$UPDATE_URL" "$UPDATE_STAGE/repository" \
        || die 'Download failed. The original folder was left unchanged.'
    mkdir -p -- "$backup_root" || die 'Could not create the backup directory; original folder unchanged.'
    UPDATE_BACKUP="$(mktemp -d "$backup_root/backup-$(date +%Y%m%d-%H%M%S).XXXXXX")" \
        || die 'Could not reserve a backup directory; original folder unchanged.'
    cp -a -- "$UPDATE_ROOT" "$UPDATE_BACKUP/repository" \
        || die "Backup failed; original folder unchanged. An incomplete backup may remain at: $UPDATE_BACKUP"
    printf 'Original folder backed up to: %s/repository\n' "$UPDATE_BACKUP"
    mv -T -- "$UPDATE_ROOT" "$UPDATE_STAGE/previous" \
        || die 'Could not move the original folder; replacement stopped.'
    if ! mv -T --no-clobber -- "$UPDATE_STAGE/repository" "$UPDATE_ROOT" \
        || [[ -e "$UPDATE_STAGE/repository" ]]; then
        die 'Could not install the downloaded folder; attempting to restore the original.'
    fi
    printf 'Updated bash-scripts. Future updates will use this Git checkout.\n'
    printf 'If your terminal was inside the old folder, re-enter it with: cd -- %q\n' "$UPDATE_ROOT"
}

main() {
    case "$#" in
        0) ;;
        1)
            case "$1" in
                -h|--help) usage; return 0 ;;
                *) printf 'Error: unknown argument: %s\n' "$1" >&2; return 2 ;;
            esac
            ;;
        *) printf 'Error: expected no arguments; use --help.\n' >&2; return 2 ;;
    esac
    local tool source_path parent name
    for tool in git readlink dirname basename mkdir rmdir mktemp date cp mv rm; do
        command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool. Install it and try again."
    done
    [[ -n "${HOME:-}" ]] || die 'HOME is not set; cannot choose a safe backup location.'
    # A Git environment inherited from another command must not redirect writes
    # to a different repository or index.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
    source_path="$(readlink -f -- "${BASH_SOURCE[0]}")" || die 'Could not locate this script.'
    UPDATE_ROOT="$(dirname -- "$source_path")"
    [[ "$UPDATE_ROOT" != / ]] || die 'Place bash-scripts in its own directory before updating.'
    parent="$(dirname -- "$UPDATE_ROOT")"
    name="$(basename -- "$UPDATE_ROOT")"
    UPDATE_LOCK="$parent/.$name.update-lock"
    if ! mkdir -- "$UPDATE_LOCK" 2>/dev/null; then
        die "Another update may be running, or the parent directory is not writable. Lock: $UPDATE_LOCK. If an earlier updater was killed, remove this empty lock directory only after confirming no updater is running."
    fi
    UPDATE_LOCK_HELD=1
    trap cleanup_update EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'Updating: %s\n' "$UPDATE_ROOT"
    if [[ -e "$UPDATE_ROOT/.git" || -L "$UPDATE_ROOT/.git" ]]; then
        update_checkout
    else
        update_plain_folder
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
