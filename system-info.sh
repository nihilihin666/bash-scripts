#!/usr/bin/env bash

# Diagnostic collection is intentionally best-effort: individual unavailable
# commands should not abort the whole report.
set -u

# Linux diagnostic info collector
#
# Features:
# - Detect apt (Ubuntu/Debian family) or dnf (Fedora)
# - Install missing tools used by the script
# - Default console output: useful, filtered, human-friendly
# - --min: even more filtered console output
# - --print-all: write a fuller report to ~/bash-scripts-output/system-info.txt
#
# Example:
#   ./bash-scripts/system-info.sh
#   ./bash-scripts/system-info.sh --min
#   ./bash-scripts/system-info.sh --print-all
#   ./bash-scripts/system-info.sh --min --print-all

MODE_MIN=0
PRINT_ALL=0
readonly OUTPUT_DIR="$HOME/bash-scripts-output"
readonly OUTPUT_FILE="$OUTPUT_DIR/system-info.txt"

REPORT_FILE=""
REPORT_TMP=""
LSCPU_CACHE=""
LSPCI_NNK_CACHE=""
GLXINFO_CACHE=""

usage() {
    cat <<EOF
Collect Linux system diagnostics and optionally save a fuller report.

Usage:
  "$0" [--min] [--print-all]

Options:
  --min        Show a more minimal console report
  --print-all  Write a fuller report to ~/bash-scripts-output/system-info.txt
  -h, --help   Show this help
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --min) MODE_MIN=1 ;;
            --print-all) PRINT_ALL=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $arg" ;;
        esac
    done
}

print_header() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_sudo_prefix() {
    if [ "$(id -u)" -eq 0 ]; then
        echo ""
        return
    fi

    if have_cmd sudo; then
        echo "sudo"
        return
    fi

    echo "unavailable"
}

detect_pkg_manager() {
    if have_cmd apt-get; then
        echo "apt"
        return
    fi

    if have_cmd dnf; then
        echo "dnf"
        return
    fi

    echo "unknown"
}

append_file_header() {
    {
        echo "============================================================"
        echo "$1"
        echo "============================================================"
    } >> "$REPORT_FILE"
}

append_file_cmd() {
    local label="$1"
    shift

    {
        echo
        echo "--- $label ---"
        "$@" 2>&1 || echo "Unavailable / failed"
    } >> "$REPORT_FILE"
}

append_file_text() {
    {
        echo
        cat
    } >> "$REPORT_FILE"
}

append_file_block() {
    local label="$1"
    local content="$2"

    {
        echo
        echo "--- $label ---"
        if [ -n "$content" ]; then
            printf '%s\n' "$content"
        else
            echo "Unavailable / failed"
        fi
    } >> "$REPORT_FILE"
}

cleanup_report_tmp() {
    if [ -n "$REPORT_TMP" ]; then
        rm -f -- "$REPORT_TMP"
    fi
}

install_missing_tools() {
    local pkg_mgr="$1"
    local sudo_prefix="$2"

    local missing_cmds=()
    local missing_pkgs=()

    have_cmd inxi    || missing_cmds+=("inxi")
    have_cmd lspci   || missing_cmds+=("lspci")
    have_cmd lshw    || missing_cmds+=("lshw")
    have_cmd glxinfo || missing_cmds+=("glxinfo")
    have_cmd lsblk   || missing_cmds+=("lsblk")
    have_cmd free    || missing_cmds+=("free")
    have_cmd lsusb   || missing_cmds+=("lsusb")

    if [ "${#missing_cmds[@]}" -eq 0 ]; then
        echo "All extra tools already installed."
        return
    fi

    echo "Missing tools detected: ${missing_cmds[*]}"
    echo

    if [ "$sudo_prefix" = "unavailable" ]; then
        echo "Cannot install missing tools: this user is not root and sudo is unavailable."
        echo "Continuing with the tools currently installed."
        return
    fi

    case "$pkg_mgr" in
        apt)
            for cmd in "${missing_cmds[@]}"; do
                case "$cmd" in
                    inxi)    missing_pkgs+=("inxi") ;;
                    lspci)   missing_pkgs+=("pciutils") ;;
                    lshw)    missing_pkgs+=("lshw") ;;
                    glxinfo) missing_pkgs+=("mesa-utils") ;;
                    lsblk)   missing_pkgs+=("util-linux") ;;
                    free)    missing_pkgs+=("procps") ;;
                    lsusb)   missing_pkgs+=("usbutils") ;;
                esac
            done
            ;;
        dnf)
            for cmd in "${missing_cmds[@]}"; do
                case "$cmd" in
                    inxi)    missing_pkgs+=("inxi") ;;
                    lspci)   missing_pkgs+=("pciutils") ;;
                    lshw)    missing_pkgs+=("lshw") ;;
                    glxinfo) missing_pkgs+=("glx-utils") ;;
                    lsblk)   missing_pkgs+=("util-linux") ;;
                    free)    missing_pkgs+=("procps-ng") ;;
                    lsusb)   missing_pkgs+=("usbutils") ;;
                esac
            done
            ;;
        *)
            echo "Unsupported package manager. Install these manually if needed:"
            echo "  ${missing_cmds[*]}"
            return
            ;;
    esac

    local deduped_pkgs=()
    local seen=""
    local pkg
    for pkg in "${missing_pkgs[@]}"; do
        case " $seen " in
            *" $pkg "*) ;;
            *)
                deduped_pkgs+=("$pkg")
                seen="$seen $pkg"
                ;;
        esac
    done

    case "$pkg_mgr" in
        apt)
            echo "Installing via apt: ${deduped_pkgs[*]}"
            if [ -n "$sudo_prefix" ]; then
                $sudo_prefix apt-get update && $sudo_prefix apt-get install -y "${deduped_pkgs[@]}"
            else
                apt-get update && apt-get install -y "${deduped_pkgs[@]}"
            fi
            ;;
        dnf)
            echo "Installing via dnf: ${deduped_pkgs[*]}"
            if [ -n "$sudo_prefix" ]; then
                $sudo_prefix dnf install -y "${deduped_pkgs[@]}"
            else
                dnf install -y "${deduped_pkgs[@]}"
            fi
            ;;
    esac
}

collect_common_command_output() {
    if have_cmd lscpu; then
        LSCPU_CACHE="$(lscpu 2>/dev/null || true)"
    fi
    if have_cmd lspci; then
        LSPCI_NNK_CACHE="$(lspci -nnk 2>/dev/null || true)"
    fi
    if have_cmd glxinfo; then
        GLXINFO_CACHE="$(glxinfo -B 2>/dev/null || true)"
    fi
}

get_session_id() {
    if ! have_cmd loginctl; then
        return
    fi

    loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$USER" '$3 == user {print $1; exit}'
}

get_os_pretty_name() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${PRETTY_NAME:-unknown}"
    else
        echo "unknown"
    fi
}

get_desktop_name() {
    if [ -n "${XDG_CURRENT_DESKTOP:-}" ]; then
        echo "$XDG_CURRENT_DESKTOP"
        return
    fi
    if [ -n "${XDG_SESSION_DESKTOP:-}" ]; then
        echo "$XDG_SESSION_DESKTOP"
        return
    fi
    if [ -n "${DESKTOP_SESSION:-}" ]; then
        echo "$DESKTOP_SESSION"
        return
    fi
    echo "unknown"
}

get_session_type() {
    if [ -n "${XDG_SESSION_TYPE:-}" ]; then
        echo "$XDG_SESSION_TYPE"
        return
    fi

    local session_id
    session_id="$(get_session_id || true)"
    if [ -n "$session_id" ] && have_cmd loginctl; then
        loginctl show-session "$session_id" -p Type 2>/dev/null | sed 's/^Type=//'
        return
    fi

    echo "unknown"
}

get_cpu_model() {
    if [ -n "$LSCPU_CACHE" ]; then
        printf '%s\n' "$LSCPU_CACHE" | awk -F: '/Model name:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
        return
    fi
    awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null
}

get_cpu_topology() {
    local sockets cores threads total
    sockets="$(printf '%s\n' "$LSCPU_CACHE" | awk -F: '/Socket\(s\):/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    cores="$(printf '%s\n' "$LSCPU_CACHE" | awk -F: '/Core\(s\) per socket:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    threads="$(printf '%s\n' "$LSCPU_CACHE" | awk -F: '/Thread\(s\) per core:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    total="$(printf '%s\n' "$LSCPU_CACHE" | awk -F: '/^CPU\(s\):/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"

    if [ -n "$sockets" ] || [ -n "$cores" ] || [ -n "$threads" ] || [ -n "$total" ]; then
        echo "Sockets: ${sockets:-?}, Cores/socket: ${cores:-?}, Threads/core: ${threads:-?}, Logical CPUs: ${total:-?}"
    fi
}

get_memory_summary() {
    free -h 2>/dev/null | awk '/^Mem:/ {print "RAM: " $2 " total, " $3 " used, " $7 " available"}'
    free -h 2>/dev/null | awk '/^Swap:/ {print "Swap: " $2 " total, " $3 " used, " $4 " free"}'
}


get_current_renderer_value() {
    if [ -n "$GLXINFO_CACHE" ]; then
        printf '%s\n' "$GLXINFO_CACHE" | awk -F: '/OpenGL renderer string:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    fi
}

get_current_vendor_value() {
    if [ -n "$GLXINFO_CACHE" ]; then
        printf '%s\n' "$GLXINFO_CACHE" | awk -F: '/OpenGL vendor string:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    fi
}

get_current_gl_version_value() {
    if [ -n "$GLXINFO_CACHE" ]; then
        printf '%s\n' "$GLXINFO_CACHE" | awk -F: '/OpenGL core profile version string:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    fi
}

get_current_gl_video_memory_value() {
    if [ -n "$GLXINFO_CACHE" ]; then
        printf '%s\n' "$GLXINFO_CACHE" | awk -F: '/Video memory:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    fi
}

get_current_gl_unified_memory_value() {
    if [ -n "$GLXINFO_CACHE" ]; then
        printf '%s\n' "$GLXINFO_CACHE" | awk -F: '/Unified memory:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    fi
}

bytes_to_mib() {
    local bytes="$1"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
        awk -v b="$bytes" 'BEGIN {printf "%.0f MiB", b / 1024 / 1024}'
    fi
}

bytes_to_gib() {
    local bytes="$1"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GiB", b / 1024 / 1024 / 1024}'
    fi
}

get_sysfs_drm_gpu_memory() {
    local any=0
    local card dev vram visible gtt used_vram

    for card in /sys/class/drm/card[0-9]*; do
        [ -d "$card/device" ] || continue
        dev="$card/device"

        vram=""
        visible=""
        gtt=""
        used_vram=""

        [ -r "$dev/mem_info_vram_total" ] && vram="$(cat "$dev/mem_info_vram_total" 2>/dev/null)"
        [ -r "$dev/mem_info_vis_vram_total" ] && visible="$(cat "$dev/mem_info_vis_vram_total" 2>/dev/null)"
        [ -r "$dev/mem_info_gtt_total" ] && gtt="$(cat "$dev/mem_info_gtt_total" 2>/dev/null)"
        [ -r "$dev/mem_info_vram_used" ] && used_vram="$(cat "$dev/mem_info_vram_used" 2>/dev/null)"

        if [ -n "$vram" ] || [ -n "$visible" ] || [ -n "$gtt" ] || [ -n "$used_vram" ]; then
            any=1
            echo "$(basename "$card") memory:"
            [ -n "$vram" ] && echo "  VRAM total: $(bytes_to_mib "$vram") ($(bytes_to_gib "$vram"))"
            [ -n "$used_vram" ] && echo "  VRAM used: $(bytes_to_mib "$used_vram") ($(bytes_to_gib "$used_vram"))"
            [ -n "$visible" ] && echo "  Visible VRAM: $(bytes_to_mib "$visible") ($(bytes_to_gib "$visible"))"
            [ -n "$gtt" ] && echo "  GTT/shared aperture: $(bytes_to_mib "$gtt") ($(bytes_to_gib "$gtt"))"
        fi
    done

    [ "$any" -eq 1 ]
}

get_nvidia_smi_summary() {
    if ! have_cmd nvidia-smi; then
        return
    fi

    nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,memory.free,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | awk -F, '
        {
            for (i=1; i<=NF; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", $i)
            }
            print "NVIDIA GPU " $1 ": " $2
            print "  Driver: " $3
            print "  Dedicated VRAM: " $4 " MiB total, " $5 " MiB used, " $6 " MiB free"
            if ($7 != "[N/A]" && $7 != "") print "  Temperature: " $7 " C"
            if ($8 != "[N/A]" && $8 != "") print "  Power: " $8 " W"
        }'
}

get_gpu_detailed() {
    local renderer vendor video_mem unified

    renderer="$(get_current_renderer_value || true)"
    vendor="$(get_current_vendor_value || true)"
    video_mem="$(get_current_gl_video_memory_value || true)"
    unified="$(get_current_gl_unified_memory_value || true)"

    if ! have_cmd lspci; then
        echo "GPU PCI info unavailable: lspci missing"
        return
    fi

    printf '%s\n' "$LSPCI_NNK_CACHE" | awk -v renderer="$renderer" -v gl_vendor="$vendor" -v has_nvidia_smi="$(have_cmd nvidia-smi && echo yes || echo no)" '
        BEGIN {
            IGNORECASE=1
            idx=0
        }

        function lower(s) {
            return tolower(s)
        }

        function trim(s) {
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            return s
        }

        function flush_device() {
            if (device == "") return

            idx++
            device_lc=lower(device)
            renderer_lc=lower(renderer " " gl_vendor)

            vendor_name="Unknown"
            gpu_type="Unknown"
            vram="unknown"
            used="No"

            if (device_lc ~ /nvidia/) {
                vendor_name="NVIDIA"
                gpu_type="Dedicated or hybrid dGPU"
                if (has_nvidia_smi == "yes") {
                    vram="see NVIDIA-SMI section below"
                } else {
                    vram="unknown / not exposed by current driver"
                }
                if (renderer_lc ~ /nvidia/) used="Likely yes - current OpenGL renderer"
            } else if (device_lc ~ /amd|advanced micro devices|ati|radeon/) {
                vendor_name="AMD/Radeon"
                if (device_lc ~ /apu|radeon graphics|vega [0-9]+ graphics|renoir|cezanne|rembrandt|phoenix|strix|mendocino/) {
                    gpu_type="Integrated AMD APU / shared memory"
                    vram="shared system memory"
                } else {
                    gpu_type="Dedicated or hybrid GPU"
                    vram="see DRM/sysfs memory section below if exposed"
                }
                if (renderer_lc ~ /amd|radeon/) used="Likely yes - current OpenGL renderer"
            } else if (device_lc ~ /intel/) {
                vendor_name="Intel"
                gpu_type="Integrated / shared memory"
                vram="shared system memory"
                if (renderer_lc ~ /intel/) used="Likely yes - current OpenGL renderer"
            }

            print "GPU #" idx
            print "  PCI: " device
            print "  Vendor: " vendor_name
            print "  Type: " gpu_type
            print "  Kernel driver: " (driver != "" ? driver : "unknown")
            print "  Kernel modules: " (modules != "" ? modules : "unknown")
            print "  Used for current OpenGL session: " used
            print "  VRAM: " vram
            if (vendor_name == "NVIDIA" && has_nvidia_smi != "yes") {
                print "  Note: NVIDIA VRAM is reliably shown with the proprietary NVIDIA driver + nvidia-smi; nouveau often does not expose it."
            }
            print ""

            device=""
            driver=""
            modules=""
        }

        /vga compatible controller|3d controller|display controller/ {
            flush_device()
            device=$0
            next
        }

        device != "" && /Kernel driver in use:/ {
            sub(/^[ \t]*Kernel driver in use:[ \t]*/, "")
            driver=$0
            next
        }

        device != "" && /Kernel modules:/ {
            sub(/^[ \t]*Kernel modules:[ \t]*/, "")
            modules=$0
            next
        }

        END {
            flush_device()
        }
    '

    if [ -n "$video_mem" ]; then
        echo "--- Current renderer memory ---"
        if [ "$unified" = "yes" ]; then
            echo "Renderer memory reported by Mesa: $video_mem shared/unified memory, not dedicated VRAM"
        else
            echo "Renderer memory reported by Mesa: $video_mem"
        fi
        [ -n "$unified" ] && echo "Unified memory: $unified"
        echo
    fi

    local drm_memory
    if drm_memory="$(get_sysfs_drm_gpu_memory 2>/dev/null)"; then
        echo "--- DRM/sysfs GPU memory ---"
        printf '%s\n' "$drm_memory"
        echo
    fi

    if have_cmd nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        echo "--- NVIDIA-SMI ---"
        get_nvidia_smi_summary
        echo
    fi
}

get_gpu_current_renderer_summary() {
    local renderer vendor version video_mem unified

    renderer="$(get_current_renderer_value || true)"
    vendor="$(get_current_vendor_value || true)"
    version="$(get_current_gl_version_value || true)"
    video_mem="$(get_current_gl_video_memory_value || true)"
    unified="$(get_current_gl_unified_memory_value || true)"

    echo "Renderer: ${renderer:-unavailable}"
    echo "Vendor: ${vendor:-unavailable}"
    echo "OpenGL: ${version:-unavailable}"

    if [ -n "$video_mem" ]; then
        if [ "$unified" = "yes" ]; then
            echo "Renderer memory: $video_mem shared/unified memory, not dedicated VRAM"
        else
            echo "Renderer memory: $video_mem"
        fi
    fi

    [ -n "$unified" ] && echo "Unified memory: $unified"
}

get_gpu_lines() {
    local output

    output="$(printf '%s\n' "$LSPCI_NNK_CACHE" | awk '
        BEGIN {IGNORECASE=1}
        /vga compatible controller|3d controller|display controller/ {
            print $0
            show=1
            next
        }
        show && /^[[:space:]]+Kernel driver in use:/ {
            print $0
            show=0
        }
    ' | sed 's/^[[:space:]]*//')"

    if [ -n "$output" ]; then
        printf '%s\n' "$output"
        return
    fi

    if have_cmd inxi; then
        inxi -Gxx 2>/dev/null | awk '
            /^[[:space:]]*Graphics:/ {next}
            /^[[:space:]]*Device-[0-9]+:/ {print; next}
        '
        return
    fi

    echo "GPU device info unavailable"
}

get_glx_brief() {
    printf '%s\n' "$GLXINFO_CACHE" | awk '
        /OpenGL vendor string:/ ||
        /OpenGL renderer string:/ ||
        /OpenGL core profile version string:/ ||
        /OpenGL version string:/ ||
        /Video memory:/ ||
        /Unified memory:/ ||
        /direct rendering:/ {
            print
        }
    '
}

get_display_summary_from_inxi() {
    inxi -Gxx 2>/dev/null | awk '
        /^Graphics:/ {print; next}
        /^[[:space:]]+Device-[0-9]+:/ {print; next}
        /^[[:space:]]+Display:/ {print; next}
        /^[[:space:]]+Monitor-[0-9]+:/ {print; next}
        /^[[:space:]]+API: OpenGL/ {print; next}
        /^[[:space:]]+API: Vulkan/ {print; next}
    '
}

get_display_summary_min() {
    if have_cmd inxi; then
        inxi -Gxx 2>/dev/null | awk '
            /^[[:space:]]*Device-[0-9]+:/ {print; next}
            /^[[:space:]]*Display:/ {print; next}
            /^[[:space:]]*Monitor-[0-9]+:/ {print; next}
            /^[[:space:]]*API: OpenGL/ {print; next}
            /^[[:space:]]*API: Vulkan/ {print; next}
        '
        return
    fi

    echo "Display summary unavailable"
}

get_lsblk_filtered_default() {
    lsblk -e 7 -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINTS,MODEL 2>/dev/null | awk '
        NR==1 {print; next}
        $4 == "loop" {next}
        {print}
    '
}

get_lsblk_filtered_min() {
    lsblk -e 7 -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINTS,MODEL 2>/dev/null | awk '
        NR==1 {print; next}
        $4 == "loop" {next}
        $4 != "disk" && $4 != "part" && $4 != "lvm" && $4 != "raid" && $4 != "crypt" {next}
        {print}
    '
}

get_df_filtered_default() {
    df -hT 2>/dev/null | awk '
        NR==1 {print; next}
        $2 == "tmpfs" || $2 == "devtmpfs" || $2 == "squashfs" || $2 == "overlay" {next}
        $1 ~ /^tmpfs$/ {next}
        {print}
    '
}

get_df_filtered_min() {
    df -hT 2>/dev/null | awk '
        NR==1 {print; next}
        $2 == "tmpfs" || $2 == "devtmpfs" || $2 == "squashfs" || $2 == "overlay" || $2 == "efivarfs" {next}
        $1 ~ /^tmpfs$/ {next}
        $7 != "/" && $7 != "/boot/efi" && $7 !~ /^\/mnt\// {next}
        {print}
    '
}

get_network_summary() {
    if have_cmd inxi; then
        inxi -Nxx 2>/dev/null
    else
        ip -brief link 2>/dev/null
    fi
}

get_battery_summary() {
    if have_cmd inxi; then
        inxi -B 2>/dev/null
        return
    fi

    local bat_dir
    bat_dir="$(find /sys/class/power_supply -maxdepth 1 -type d -name 'BAT*' 2>/dev/null | head -n1)"
    if [ -n "$bat_dir" ]; then
        echo "Battery:"
        [ -r "$bat_dir/status" ] && echo "  Status: $(cat "$bat_dir/status")"
        [ -r "$bat_dir/capacity" ] && echo "  Capacity: $(cat "$bat_dir/capacity")%"
    else
        echo "Battery info unavailable"
    fi
}

get_audio_summary() {
    if have_cmd inxi; then
        inxi -Axx 2>/dev/null
    else
        echo "Audio info unavailable"
    fi
}

get_brief_system_summary() {
    echo "Timestamp: $(date)"
    echo "User: $USER"
    echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
    echo "OS: $(get_os_pretty_name)"
    echo "Kernel: $(uname -r 2>/dev/null || echo unknown)"
    echo "Architecture: $(uname -m 2>/dev/null || echo unknown)"
    echo "Desktop: $(get_desktop_name)"
    echo "Session: $(get_session_type)"
    echo "Shell: ${SHELL:-unknown}"
}

print_cpu_memory_section() {
    local include_topology="$1"

    print_header "CPU / MEMORY"
    echo "CPU: $(get_cpu_model)"
    if [ "$include_topology" -eq 1 ]; then
        get_cpu_topology
    fi
    get_memory_summary
}

print_gpu_display_section() {
    local minimal="$1"

    print_header "GPU / DISPLAY"
    echo "--- VGA / GPU devices ---"
    get_gpu_detailed
    echo "--- Current renderer ---"
    get_gpu_current_renderer_summary
    echo
    if [ "$minimal" -eq 1 ]; then
        echo "--- Display summary ---"
        get_display_summary_min
    elif have_cmd inxi; then
        echo "--- Display summary ---"
        get_display_summary_from_inxi
    fi
}

print_storage_section() {
    local minimal="$1"

    print_header "STORAGE"
    echo "--- Block devices ---"
    if [ "$minimal" -eq 1 ]; then
        get_lsblk_filtered_min
    else
        get_lsblk_filtered_default
    fi
    echo
    echo "--- Filesystems ---"
    if [ "$minimal" -eq 1 ]; then
        get_df_filtered_min
    else
        get_df_filtered_default
    fi
}

print_console_default() {
    print_header "SYSTEM"
    get_brief_system_summary
    echo
    echo "Uptime: $(uptime -p 2>/dev/null || echo unavailable)"

    print_cpu_memory_section 1
    print_gpu_display_section 0
    print_storage_section 0

    print_header "EXTRA"
    echo "--- Battery ---"
    get_battery_summary
    echo
    echo "--- Network ---"
    get_network_summary
    echo
    echo "--- Audio ---"
    get_audio_summary
}

print_console_min() {
    print_header "SYSTEM"
    get_brief_system_summary

    print_cpu_memory_section 0
    print_gpu_display_section 1
    print_storage_section 1
}

get_pci_graphics_context() {
    printf '%s\n' "$LSPCI_NNK_CACHE" | grep -A 3 -Ei 'vga|3d|display'
}

get_pci_graphics_verbose() {
    lspci -vv 2>/dev/null | awk '
        BEGIN {IGNORECASE=1}
        /VGA compatible controller|3D controller|Display controller/ {
            show=1
            print
            next
        }
        show && /^[^ \t]/ {show=0}
        show {print}
    '
}

get_drm_sysfs_cards_raw() {
    local card field

    for card in /sys/class/drm/card[0-9]*; do
        [ -d "$card/device" ] || continue
        echo "$card"
        readlink -f "$card/device/driver" 2>/dev/null || true
        for field in vendor device mem_info_vram_total mem_info_vram_used mem_info_vis_vram_total mem_info_gtt_total; do
            if [ -r "$card/device/$field" ]; then
                echo "  $field=$(cat "$card/device/$field")"
            fi
        done
    done
}

get_lshw_display() {
    lshw -C display
}

get_loaded_modules() {
    lsmod | head -n 200
}

write_full_report_file() {
    mkdir -p "$OUTPUT_DIR"
    REPORT_TMP="$(mktemp "$OUTPUT_DIR/.system-info.txt.tmp.XXXXXX")"
    REPORT_FILE="$REPORT_TMP"
    : > "$REPORT_FILE"

    append_file_header "PACKAGE MANAGER DETECTION"
    {
        echo "Detected package manager: $(detect_pkg_manager)"
        echo
    } >> "$REPORT_FILE"

    append_file_header "BASIC SYSTEM"
    append_file_text <<EOF
--- Timestamp ---
$(date)

--- User ---
$USER

--- Hostname ---
$(hostname 2>/dev/null || echo unavailable)

--- OS Release ---
EOF
    if [ -f /etc/os-release ]; then
        cat /etc/os-release >> "$REPORT_FILE"
        echo >> "$REPORT_FILE"
    else
        echo "/etc/os-release not found" >> "$REPORT_FILE"
        echo >> "$REPORT_FILE"
    fi

    append_file_cmd "Kernel" uname -a
    append_file_cmd "Uptime" uptime -p
    append_file_cmd "Architecture" uname -m
    append_file_cmd "Hostnamectl" hostnamectl

    append_file_header "SESSION / DESKTOP / DISPLAY"
    append_file_text <<EOF
--- Environment ---
XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}
XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}
XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-<unset>}
DESKTOP_SESSION=${DESKTOP_SESSION:-<unset>}
WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}
DISPLAY=${DISPLAY:-<unset>}
SHELL=${SHELL:-<unset>}
EOF

    if have_cmd loginctl; then
        local_session_id="$(get_session_id || true)"
        {
            echo
            echo "--- loginctl session ---"
            if [ -n "${local_session_id:-}" ]; then
                echo "Session ID: $local_session_id"
                loginctl show-session "$local_session_id" \
                    -p Name \
                    -p User \
                    -p Type \
                    -p Class \
                    -p State \
                    -p Remote \
                    -p Display \
                    -p Desktop \
                    -p Service \
                    -p Leader 2>/dev/null || echo "Failed to query session"
            else
                echo "Could not determine current session ID"
            fi
            echo
        } >> "$REPORT_FILE"
    fi

    append_file_header "CPU / MEMORY"
    append_file_block "CPU (lscpu)" "$LSCPU_CACHE"
    append_file_cmd "Memory (free -h)" free -h
    append_file_cmd "/proc/meminfo (first 50 lines)" head -n 50 /proc/meminfo

    append_file_header "GPU / GRAPHICS"
    {
        echo
        echo "--- Detailed VGA / GPU summary ---"
        get_gpu_detailed
        echo
        echo "--- Current renderer summary ---"
        get_gpu_current_renderer_summary
    } >> "$REPORT_FILE"
    append_file_cmd "PCI graphics devices" get_pci_graphics_context
    append_file_cmd "PCI graphics devices verbose" get_pci_graphics_verbose
    append_file_block "OpenGL / renderer (glxinfo -B)" "$GLXINFO_CACHE"
    if have_cmd nvidia-smi; then
        append_file_cmd "nvidia-smi" nvidia-smi
    fi
    append_file_cmd "DRM sysfs cards" get_drm_sysfs_cards_raw
    if have_cmd inxi; then
        append_file_cmd "inxi graphics summary" inxi -Gxx
    fi

    append_file_header "STORAGE"
    append_file_cmd "Block devices (lsblk)" lsblk -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINTS,MODEL
    append_file_cmd "Filesystem usage (df -hT)" df -hT

    append_file_header "HARDWARE SUMMARY"
    if have_cmd inxi; then
        append_file_cmd "inxi full summary" inxi -Fxxxrz
    fi
    if have_cmd lshw; then
        append_file_cmd "lshw -short" lshw -short
        append_file_cmd "lshw display" get_lshw_display
    fi

    append_file_header "RAW / EXTRA"
    append_file_cmd "PCI devices (lspci -nn)" lspci -nn
    append_file_cmd "USB devices (lsusb)" lsusb
    append_file_cmd "Loaded kernel modules (first 200)" get_loaded_modules
    append_file_cmd "IP addresses" ip addr
    append_file_cmd "Routes" ip route

    if [ -e "$OUTPUT_FILE" ]; then
        chmod --reference="$OUTPUT_FILE" "$REPORT_TMP"
    else
        local current_umask output_mode
        current_umask="$(umask)"
        printf -v output_mode '%03o' "$((0666 & ~(8#$current_umask)))"
        chmod "$output_mode" "$REPORT_TMP"
    fi
    mv -f -- "$REPORT_TMP" "$OUTPUT_FILE"
    REPORT_TMP=""
    REPORT_FILE=""
}

main() {
    local pkg_mgr
    local sudo_prefix

    parse_args "$@"
    trap cleanup_report_tmp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    print_header "PACKAGE MANAGER DETECTION"
    pkg_mgr="$(detect_pkg_manager)"
    sudo_prefix="$(need_sudo_prefix)"

    case "$pkg_mgr" in
        apt)
            echo "Detected package manager: apt"
            ;;
        dnf)
            echo "Detected package manager: dnf"
            ;;
        *)
            echo "Could not detect apt or dnf."
            echo "The script will still print what it can, but cannot auto-install missing tools."
            ;;
    esac
    echo

    print_header "INSTALLING MISSING TOOLS"
    install_missing_tools "$pkg_mgr" "$sudo_prefix"
    collect_common_command_output

    if [ "$MODE_MIN" -eq 1 ]; then
        print_console_min
    else
        print_console_default
    fi

    if [ "$PRINT_ALL" -eq 1 ]; then
        write_full_report_file
        echo
        print_header "FULL REPORT FILE"
        echo "Written: $OUTPUT_FILE"
    fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
