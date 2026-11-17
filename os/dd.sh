#!/usr/bin/env bash

# Create a bootable Linux installer USB from an ISO image.

set -euo pipefail
export LC_ALL=C

DRY_RUN=0
ISO_PATH=""
TARGET=""
TARGET_SIZE=""
TARGET_MODEL=""
TARGET_FINGERPRINT=""
MOUNT_POINTS=()
MOUNT_DEVICES=()
UNMOUNTED_POINTS=()
DD_COMMAND=()

DEFAULT_BS="4M"
DEFAULT_STATUS="progress"
DEFAULT_CONV="fsync"

BS="$DEFAULT_BS"
STATUS="$DEFAULT_STATUS"
CONV="$DEFAULT_CONV"

usage() {
  cat <<EOF
Usage: "$0" [--dry-run] <path-to.iso>

Interactively selects a removable USB disk, unmounts any mounted filesystems
on it, and writes the ISO to the whole disk with dd.

Arguments:
  <path-to.iso>  Non-empty, readable ISO image to write to the selected USB disk.

Options:
  --dry-run   Show the choices and planned commands without changing anything
  -h, --help  Show this help
      --      End options; treat remaining values as positional arguments.

Run a real write as root, for example:
  sudo $(printf '%q' "$0") ~/Downloads/linux.iso
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

quote_command() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$ISO_PATH" ]] || die "only one ISO path may be supplied"
        ISO_PATH="$1"
        shift
        ;;
    esac
  done

  if (( $# > 0 )); then
    [[ -z "$ISO_PATH" && $# -eq 1 ]] || die "only one ISO path may be supplied"
    ISO_PATH="$1"
  fi

  [[ -n "$ISO_PATH" ]] || { usage >&2; exit 2; }
}

validate_iso() {
  [[ -f "$ISO_PATH" ]] || die "ISO is not a regular file: $ISO_PATH"
  [[ -r "$ISO_PATH" ]] || die "ISO is not readable: $ISO_PATH"
  [[ -s "$ISO_PATH" ]] || die "ISO is empty: $ISO_PATH"
  [[ "$ISO_PATH" == *.iso || "$ISO_PATH" == *.ISO ]] \
    || warn "the input filename does not end in .iso"

  ISO_PATH="$(readlink -f -- "$ISO_PATH")"
}

require_interactive_terminal() {
  [[ -t 0 && -t 1 ]] || die "interactive terminal required; redirecting input is intentionally unsupported"
}

discover_candidates() {
  local name type size model transport removable is_readonly
  CANDIDATE_NAMES=()
  CANDIDATE_SIZES=()
  CANDIDATE_MODELS=()

  # lsblk's machine-readable output is safer to parse than localized fdisk text.
  while IFS=$'\t' read -r name type size model transport removable is_readonly; do
    [[ "$type" == "disk" ]] || continue
    [[ "$is_readonly" == "0" ]] || continue
    [[ "$transport" == "usb" || "$removable" == "1" ]] || continue
    [[ -b "$name" ]] || continue

    CANDIDATE_NAMES+=("$name")
    CANDIDATE_SIZES+=("$size")
    CANDIDATE_MODELS+=("${model:-unknown model}")
  done < <(lsblk --bytes --nodeps --paths --noheadings --pairs \
    --output NAME,TYPE,SIZE,MODEL,TRAN,RM,RO \
    | awk '
      {
        delete v
        while (match($0, /[A-Z]+="([^"]|\\")*"/)) {
          item = substr($0, RSTART, RLENGTH)
          key = item
          sub(/=.*/, "", key)
          val = item
          sub(/^[^=]+="/, "", val)
          sub(/"$/, "", val)
          gsub(/\\"/, "\"", val)
          v[key] = val
          $0 = substr($0, RSTART + RLENGTH)
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", v["NAME"], v["TYPE"], v["SIZE"], v["MODEL"], v["TRAN"], v["RM"], v["RO"]
      }')

  (( ${#CANDIDATE_NAMES[@]} > 0 )) \
    || die "no writable removable/USB whole disks were found"
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1"
}

verify_no_active_swap() {
  local node resolved_node swap_device resolved_swap
  local -A target_nodes=()

  while read -r node; do
    [[ -n "$node" ]] || continue
    resolved_node="$(readlink -f -- "$node" 2>/dev/null || true)"
    [[ -n "$resolved_node" ]] && target_nodes[$resolved_node]=1
  done < <(lsblk --list --noheadings --paths --output NAME "$TARGET")

  while read -r swap_device; do
    [[ "$swap_device" == /dev/* ]] || continue
    resolved_swap="$(readlink -f -- "$swap_device" 2>/dev/null || true)"
    if [[ -n "$resolved_swap" && -n "${target_nodes[$resolved_swap]:-}" ]]; then
      die "refusing to write while $swap_device on the target disk is active swap"
    fi
  done < <(swapon --noheadings --raw --show=NAME 2>/dev/null || true)
}

choose_target() {
  local index answer

  printf '\nEligible removable/USB whole disks:\n'
  for index in "${!CANDIDATE_NAMES[@]}"; do
    printf '  %d) %-14s %9s  %s\n' \
      "$((index + 1))" \
      "${CANDIDATE_NAMES[$index]}" \
      "$(human_size "${CANDIDATE_SIZES[$index]}")" \
      "${CANDIDATE_MODELS[$index]}"
  done

  while true; do
    read -r -p "Select the target disk by number (or q to quit): " answer
    [[ "$answer" != "q" && "$answer" != "Q" ]] || exit 0
    if [[ "$answer" =~ ^[0-9]+$ ]] \
        && (( answer >= 1 && answer <= ${#CANDIDATE_NAMES[@]} )); then
      index=$((answer - 1))
      TARGET="${CANDIDATE_NAMES[$index]}"
      TARGET_SIZE="${CANDIDATE_SIZES[$index]}"
      TARGET_MODEL="${CANDIDATE_MODELS[$index]}"
      TARGET_FINGERPRINT="$(lsblk --bytes --nodeps --pairs \
        --output SIZE,MODEL,SERIAL,WWN,TRAN,RM,RO "$TARGET")"
      break
    fi
    printf 'Enter a number from 1 to %d, or q.\n' "${#CANDIDATE_NAMES[@]}"
  done
}

verify_target() {
  local current_type current_size current_transport current_removable current_readonly current_fingerprint

  [[ -b "$TARGET" ]] || die "selected target disappeared: $TARGET"
  current_type="$(lsblk --nodeps --noheadings --output TYPE "$TARGET" | xargs)"
  current_size="$(lsblk --bytes --nodeps --noheadings --output SIZE "$TARGET" | xargs)"
  current_transport="$(lsblk --nodeps --noheadings --output TRAN "$TARGET" | xargs)"
  current_removable="$(lsblk --nodeps --noheadings --output RM "$TARGET" | xargs)"
  current_readonly="$(lsblk --nodeps --noheadings --output RO "$TARGET" | xargs)"
  current_fingerprint="$(lsblk --bytes --nodeps --pairs \
    --output SIZE,MODEL,SERIAL,WWN,TRAN,RM,RO "$TARGET")"

  [[ "$current_type" == "disk" ]] || die "target is no longer a whole disk: $TARGET"
  [[ "$current_readonly" == "0" ]] || die "target became read-only: $TARGET"
  [[ "$current_transport" == "usb" || "$current_removable" == "1" ]] \
    || die "target is no longer identified as removable/USB: $TARGET"
  [[ "$current_size" == "$TARGET_SIZE" ]] || die "target size changed; unplug it and start again"
  [[ "$current_fingerprint" == "$TARGET_FINGERPRINT" ]] \
    || die "target identity changed; unplug it and start again"
  verify_no_active_swap

  # Refuse the disk that contains either / or the ISO, even if firmware reports it removable.
  local source_path source_device resolved_device parent_disk found_parent
  for source_path in / "$ISO_PATH"; do
    source_device="$(findmnt --noheadings --output SOURCE --target "$source_path" 2>/dev/null \
      | head -n 1 || true)"
    # Btrfs sources may be reported as /dev/device[subvolume].
    source_device="${source_device%%\[*}"
    [[ "$source_device" == /dev/* ]] || continue
    resolved_device="$(readlink -f -- "$source_device" 2>/dev/null || true)"
    [[ -n "$resolved_device" ]] && source_device="$resolved_device"

    found_parent=0
    while read -r parent_disk; do
      [[ -n "$parent_disk" ]] || continue
      found_parent=1
      [[ "$parent_disk" != "$TARGET" ]] \
        || die "refusing to overwrite the disk that contains $source_path"
    done < <(lsblk --inverse --list --noheadings --paths --output NAME,TYPE "$source_device" 2>/dev/null \
      | awk '$2 == "disk" { print $1 }')
    (( found_parent == 1 )) \
      || die "could not determine the backing disk for $source_path ($source_device)"
  done

  (( TARGET_SIZE >= $(stat --format=%s "$ISO_PATH") )) \
    || die "the ISO is larger than the selected target"
}

show_fdisk_details() {
  local details
  printf '\nfdisk details for the selected disk:\n'
  if details="$(fdisk -l -- "$TARGET" 2>&1)"; then
    printf '%s\n' "$details"
  elif (( DRY_RUN )); then
    warn "fdisk could not inspect $TARGET without elevated access: $details"
    printf '  (dry-run continues using the lsblk details shown above)\n'
  else
    die "fdisk could not inspect $TARGET: $details"
  fi
}

prompt_choice() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local allowed="$4"
  local answer=""

  while true; do
    read -r -p "$label [$allowed] (default: $default_value): " answer
    answer="${answer:-$default_value}"
    if [[ " $allowed " == *" $answer "* ]]; then
      printf -v "$variable_name" '%s' "$answer"
      return
    fi
    printf 'Choose one of: %s\n' "$allowed"
  done
}

prompt_dd_options() {
  printf '\nChoose dd options. Press Enter to accept each recommended default.\n'
  prompt_choice BS "Block size" "$DEFAULT_BS" "1M 4M 8M 16M"
  prompt_choice STATUS "Status display" "$DEFAULT_STATUS" "progress noxfer none"
  prompt_choice CONV "Write-cache flush" "$DEFAULT_CONV" "fsync fdatasync"
}

collect_mounts() {
  local device mount_point device_is_mounted
  local -A seen_mounts=()

  MOUNT_POINTS=()
  MOUNT_DEVICES=()
  while read -r device; do
    [[ -n "$device" ]] || continue
    device_is_mounted=0
    while IFS= read -r mount_point; do
      [[ -n "$mount_point" ]] || continue
      device_is_mounted=1
      if [[ -z "${seen_mounts[$mount_point]:-}" ]]; then
        MOUNT_POINTS+=("$mount_point")
        seen_mounts[$mount_point]=1
      fi
    done < <(findmnt --raw --noheadings --source "$device" --output TARGET 2>/dev/null || true)
    (( device_is_mounted == 0 )) || MOUNT_DEVICES+=("$device")
  done < <(lsblk --list --noheadings --paths --output NAME "$TARGET" | awk 'NF { print $1 }')
}

build_dd_command() {
  DD_COMMAND=(dd "if=$ISO_PATH" "of=$TARGET" "bs=$BS" "status=$STATUS" "conv=$CONV")
}

print_summary() {
  build_dd_command

  printf '\nFinal plan\n'
  printf '  ISO:       %s (%s)\n' "$ISO_PATH" "$(human_size "$(stat --format=%s "$ISO_PATH")")"
  printf '  Target:    %s (%s, %s)\n' "$TARGET" "$(human_size "$TARGET_SIZE")" "$TARGET_MODEL"
  if (( DRY_RUN && ${#MOUNT_POINTS[@]} > 0 )); then
    printf '  Unmount:   %s\n' "${MOUNT_POINTS[*]}"
  elif (( ! DRY_RUN && ${#UNMOUNTED_POINTS[@]} > 0 )); then
    printf '  Unmounted: %s\n' "${UNMOUNTED_POINTS[*]}"
  else
    printf '  Unmount:   nothing was mounted\n'
  fi
  printf '  Command:\n'
  quote_command "${DD_COMMAND[@]}"
}

unmount_target() {
  local index device
  collect_mounts
  UNMOUNTED_POINTS=("${MOUNT_POINTS[@]}")

  # Work from the deepest lsblk child upward. --all-targets also handles bind
  # mounts of the same filesystem without parsing mount-point path escaping.
  for (( index=${#MOUNT_DEVICES[@]} - 1; index >= 0; index-- )); do
    device="${MOUNT_DEVICES[$index]}"
    printf 'Unmounting all mount points for %s\n' "$device"
    umount --all-targets -- "$device"
  done

  collect_mounts
  (( ${#MOUNT_POINTS[@]} == 0 )) || die "some target filesystems are still mounted"
}

confirm_and_write() {
  local answer expected
  expected="CREATE $TARGET"

  printf '\nTHIS PERMANENTLY OVERWRITES ALL DATA ON %s.\n' "$TARGET"
  read -r -p "Type '$expected' to create the installer: " answer
  [[ "$answer" == "$expected" ]] \
    || { printf 'Cancelled; no data was written (the target remains unmounted).\n'; exit 0; }

  # Check identity once more immediately before making changes.
  verify_target
  collect_mounts
  (( ${#MOUNT_POINTS[@]} == 0 )) \
    || die "the target was mounted again after the summary; start over"

  printf 'Writing installer...\n'
  build_dd_command
  "${DD_COMMAND[@]}" \
    || die "dd failed; $TARGET may contain a partial image"
  printf '\nInstaller created successfully on %s.\n' "$TARGET"
}

main() {
  local command

  parse_args "$@"
  for command in awk dd fdisk findmnt head lsblk numfmt readlink stat swapon umount xargs; do
    require_command "$command"
  done
  require_interactive_terminal
  validate_iso

  if (( ! DRY_RUN && EUID != 0 )); then
    die "a real write requires root; rerun with: sudo $(printf '%q' "$0") $(printf '%q' "$ISO_PATH")"
  fi

  discover_candidates
  choose_target
  verify_target
  show_fdisk_details
  prompt_dd_options

  if (( DRY_RUN )); then
    collect_mounts
    print_summary
    printf '\nDry run: answer is treated as no; no unmount or write was performed.\n'
    exit 0
  fi

  verify_target
  unmount_target
  print_summary
  confirm_and_write
}

main "$@"
