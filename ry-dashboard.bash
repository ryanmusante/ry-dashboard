#!/usr/bin/env bash
# ry-dashboard v1.0.0 — 2026-02-20
# System monitoring TUI for CachyOS on AMD Strix Halo (GTR9 Pro)
# Pure bash + tput, zero external dependencies beyond coreutils + sysfs
set -euo pipefail

readonly VERSION="1.0.0"
readonly PROG="${0##*/}"

# ── Defaults ──────────────────────────────────────────────────────────────
INTERVAL=2
START_PANEL=0           # 0 = overview grid, 1-6 = expanded panel
LOG_ENABLED=0
LOG_PATH=""
LOG_JSON=0
USE_COLOR=1
DETAIL_LEVEL=0          # 0 = compact, 1 = detailed (within expanded panel)

# ── State ─────────────────────────────────────────────────────────────────
FOCUSED_PANEL=0         # 0 = overview, 1-6 = expanded
COLS=0
ROWS=0
NEED_REDRAW=1
LAST_COLLECT_MS=0
RUNNING=1

# ── CPU state (deltas) ───────────────────────────────────────────────────
declare -a PREV_CPU_IDLE=()
declare -a PREV_CPU_TOTAL=()
declare -a CPU_LOAD=()
CPU_FREQ_AVG=0
CPU_TEMP=0
CPU_GOVERNOR=""
CPU_BOOST=""
CPU_CORES=0
declare -a CPU_FREQS=()
declare -a CPU_TEMPS=()

# ── GPU state ─────────────────────────────────────────────────────────────
GPU_DRM=""
GPU_SCLK=0
GPU_MCLK=0
GPU_TEMP=0
GPU_BUSY=0
GPU_VRAM_USED=0
GPU_VRAM_TOTAL=0
GPU_POWER=0
GPU_DPM=""

# ── Network state ─────────────────────────────────────────────────────────
NET_IFACE=""
NET_IP=""
NET_RX_RATE=0
NET_TX_RATE=0
NET_WIFI_SIGNAL=""
NET_WIFI_BAND=""
NET_WIFI_CHANNEL=""
PREV_NET_RX=0
PREV_NET_TX=0
PREV_NET_TIME=0

# ── Storage state ─────────────────────────────────────────────────────────
STOR_ROOT_USED=""
STOR_ROOT_TOTAL=""
STOR_ROOT_PCT=0
STOR_BTRFS_STATUS=""
STOR_SNAP_COUNT=0
STOR_SNAP_LATEST=""
STOR_IO_READ=0
STOR_IO_WRITE=0
PREV_IO_READ=0
PREV_IO_WRITE=0

# ── Systemd state ─────────────────────────────────────────────────────────
SYS_FAILED_COUNT=0
SYS_FAILED_UNITS=""
SYS_BOOT_TIME=""
SYS_TIMER_COUNT=0
SYS_JOURNAL_ERRORS=""

# ── Thermal state ─────────────────────────────────────────────────────────
THERM_PACKAGE=0
THERM_CORE=0
THERM_GPU=0
THERM_EDGE=0
THERM_FAN=0
THERM_POWER_CORE=0
THERM_POWER_SOC=0
THERM_TDP=0

# ── hwmon discovery cache ─────────────────────────────────────────────────
HWMON_K10TEMP=""
HWMON_AMDGPU=""

# ── Colors ────────────────────────────────────────────────────────────────
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_WHITE=""
C_BG_BLUE=""

init_colors() {
    if [[ $USE_COLOR -eq 1 ]] && [[ -t 1 ]]; then
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'
        C_DIM=$'\e[2m'
        C_RED=$'\e[31m'
        C_GREEN=$'\e[32m'
        C_YELLOW=$'\e[33m'
        C_CYAN=$'\e[36m'
        C_WHITE=$'\e[37m'
        C_BG_BLUE=$'\e[44m'
    fi
}

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $PROG [OPTIONS]

System monitoring TUI for CachyOS / AMD Strix Halo

Options:
  -i, --interval SEC   Refresh interval in seconds (default: 2, range: 1-10)
  -p, --panel NUM      Start on panel 1-6, 0 for overview (default: 0)
  -l, --log [PATH]     Enable CSV logging (default: \$XDG_DATA_HOME/ry-dashboard/)
      --json           Use JSONL format for logging
      --no-color       Disable color output
      --version        Print version and exit
  -h, --help           Show this help

Keybinds:
  1-6        Expand panel (CPU/GPU/Net/Disk/Sys/Therm)
  Esc/0      Return to overview grid
  d          Toggle detail level in expanded panel
  l          Toggle logging on/off
  r          Force immediate refresh
  +/-        Adjust refresh interval
  q/Ctrl-C   Quit
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interval)
                [[ -z "${2:-}" ]] && { echo "Error: --interval requires a value" >&2; exit 2; }
                if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 10 )); then
                    INTERVAL="$2"
                else
                    echo "Error: interval must be 1-10" >&2; exit 2
                fi
                shift 2 ;;
            -p|--panel)
                [[ -z "${2:-}" ]] && { echo "Error: --panel requires a value" >&2; exit 2; }
                if [[ "$2" =~ ^[0-6]$ ]]; then
                    START_PANEL="$2"
                else
                    echo "Error: panel must be 0-6" >&2; exit 2
                fi
                shift 2 ;;
            -l|--log)
                LOG_ENABLED=1
                if [[ -n "${2:-}" ]] && [[ "${2:0:1}" != "-" ]]; then
                    LOG_PATH="$2"; shift 2
                else
                    shift
                fi ;;
            --json)     LOG_JSON=1; shift ;;
            --no-color) USE_COLOR=0; shift ;;
            --version)  echo "$PROG $VERSION"; exit 0 ;;
            -h|--help)  usage ;;
            *)          echo "Error: unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # NO_COLOR convention
    [[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
}

# ── Terminal setup/teardown ───────────────────────────────────────────────
term_setup() {
    [[ -t 0 ]] || { echo "Error: stdin is not a terminal" >&2; exit 1; }
    [[ -t 1 ]] || { echo "Error: stdout is not a terminal" >&2; exit 1; }
    tput smcup          # alternate screen
    tput civis          # hide cursor
    stty -echo -icanon  # raw input
    printf '\e[?7l'     # disable line wrap
}

term_restore() {
    printf '\e[?7h'     # re-enable line wrap
    stty echo icanon 2>/dev/null
    tput cnorm 2>/dev/null   # show cursor
    tput rmcup 2>/dev/null   # restore screen
}

update_term_size() {
    COLS=$(tput cols)
    ROWS=$(tput lines)
    NEED_REDRAW=1
}

# ── Logging ───────────────────────────────────────────────────────────────
log_init() {
    [[ $LOG_ENABLED -eq 0 ]] && return

    if [[ -z "$LOG_PATH" ]]; then
        local dir="${XDG_DATA_HOME:-$HOME/.local/share}/ry-dashboard"
        mkdir -p "$dir"
        local ext="csv"
        [[ $LOG_JSON -eq 1 ]] && ext="jsonl"
        LOG_PATH="$dir/log-$(date +%Y-%m-%d).$ext"
    fi

    # Write CSV header if new file
    if [[ $LOG_JSON -eq 0 ]] && [[ ! -f "$LOG_PATH" ]]; then
        echo "timestamp,cpu_freq_avg,cpu_temp,cpu_load,gpu_sclk,gpu_temp,gpu_busy,gpu_power,net_rx_rate,net_tx_rate,stor_root_pct,sys_failed,therm_package,therm_fan,therm_tdp" > "$LOG_PATH"
    fi
}

log_row() {
    [[ $LOG_ENABLED -eq 0 ]] && return
    local ts
    ts=$(date -Iseconds)

    if [[ $LOG_JSON -eq 1 ]]; then
        printf '{"ts":"%s","cpu_freq":%s,"cpu_temp":%s,"cpu_load":%s,"gpu_sclk":%s,"gpu_temp":%s,"gpu_busy":%s,"gpu_power":%s,"net_rx":%s,"net_tx":%s,"root_pct":%s,"failed":%s,"pkg_temp":%s,"fan":%s,"tdp":%s}\n' \
            "$ts" "$CPU_FREQ_AVG" "$CPU_TEMP" "${CPU_LOAD[0]:-0}" \
            "$GPU_SCLK" "$GPU_TEMP" "$GPU_BUSY" "$GPU_POWER" \
            "$NET_RX_RATE" "$NET_TX_RATE" "$STOR_ROOT_PCT" \
            "$SYS_FAILED_COUNT" "$THERM_PACKAGE" "$THERM_FAN" "$THERM_TDP" \
            >> "$LOG_PATH"
    else
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$ts" "$CPU_FREQ_AVG" "$CPU_TEMP" "${CPU_LOAD[0]:-0}" \
            "$GPU_SCLK" "$GPU_TEMP" "$GPU_BUSY" "$GPU_POWER" \
            "$NET_RX_RATE" "$NET_TX_RATE" "$STOR_ROOT_PCT" \
            "$SYS_FAILED_COUNT" "$THERM_PACKAGE" "$THERM_FAN" "$THERM_TDP" \
            >> "$LOG_PATH"
    fi
}

# ── hwmon discovery ───────────────────────────────────────────────────────
# Finds hwmon path by name, not index — stable across boots
find_hwmon() {
    local target="$1"
    local path
    for path in /sys/class/hwmon/hwmon*; do
        [[ -f "$path/name" ]] || continue
        if [[ "$(< "$path/name")" == "$target" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

discover_hwmon() {
    HWMON_K10TEMP=$(find_hwmon "k10temp" 2>/dev/null) || HWMON_K10TEMP=""
    HWMON_AMDGPU=$(find_hwmon "amdgpu" 2>/dev/null) || HWMON_AMDGPU=""

    # GPU DRM path — find by vendor (AMD = 0x1002)
    local card
    for card in /sys/class/drm/card[0-9]; do
        [[ -f "$card/device/vendor" ]] || continue
        if [[ "$(< "$card/device/vendor")" == "0x1002" ]]; then
            GPU_DRM="$card/device"
            break
        fi
    done

    # Core count
    CPU_CORES=$(nproc 2>/dev/null) || CPU_CORES=0
}

# ── Data collection ───────────────────────────────────────────────────────

read_sysfs() {
    # Safely read a sysfs file, return fallback on failure
    local file="$1" fallback="${2:-0}"
    if [[ -r "$file" ]]; then
        cat "$file" 2>/dev/null || echo "$fallback"
    else
        echo "$fallback"
    fi
}

collect_cpu() {
    local i freq total idle
    local -a fields

    # Per-core frequencies
    CPU_FREQS=()
    local freq_sum=0 freq_count=0
    for ((i = 0; i < CPU_CORES; i++)); do
        freq=$(read_sysfs "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq" 0)
        freq=$((freq / 1000))  # kHz → MHz
        CPU_FREQS+=("$freq")
        freq_sum=$((freq_sum + freq))
        freq_count=$((freq_count + 1))
    done
    [[ $freq_count -gt 0 ]] && CPU_FREQ_AVG=$((freq_sum / freq_count)) || CPU_FREQ_AVG=0

    # CPU temperature from k10temp
    if [[ -n "$HWMON_K10TEMP" ]]; then
        local raw
        raw=$(read_sysfs "$HWMON_K10TEMP/temp1_input" 0)
        CPU_TEMP=$((raw / 1000))

        # Per-CCD temps if available
        CPU_TEMPS=("$CPU_TEMP")
        local t
        for t in "$HWMON_K10TEMP"/temp{2,3,4,5}_input; do
            if [[ -r "$t" ]]; then
                CPU_TEMPS+=("$(( $(< "$t") / 1000 ))")
            else
                break
            fi
        done
    fi

    # Governor & boost
    CPU_GOVERNOR=$(read_sysfs "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" "unknown")
    local boost_file="/sys/devices/system/cpu/cpufreq/boost"
    [[ -r "$boost_file" ]] && CPU_BOOST=$(read_sysfs "$boost_file" "?") || CPU_BOOST="?"
    if [[ "$CPU_BOOST" == "1" ]]; then
        CPU_BOOST="on"
    elif [[ "$CPU_BOOST" == "0" ]]; then
        CPU_BOOST="off"
    fi

    # Per-CPU load from /proc/stat
    local line cpu_id
    while IFS= read -r line; do
        [[ "$line" =~ ^cpu([0-9]+)\  ]] || continue
        cpu_id="${BASH_REMATCH[1]}"
        read -ra fields <<< "$line"
        # fields: cpu# user nice system idle iowait irq softirq steal
        idle=$((fields[4] + fields[5]))  # idle + iowait
        total=0
        for ((i = 1; i < ${#fields[@]}; i++)); do
            total=$((total + fields[i]))
        done

        if [[ -n "${PREV_CPU_TOTAL[$cpu_id]:-}" ]]; then
            local d_total=$((total - PREV_CPU_TOTAL[cpu_id]))
            local d_idle=$((idle - PREV_CPU_IDLE[cpu_id]))
            if [[ $d_total -gt 0 ]]; then
                CPU_LOAD[$cpu_id]=$(( (d_total - d_idle) * 100 / d_total ))
            else
                CPU_LOAD[$cpu_id]=0
            fi
        else
            CPU_LOAD[$cpu_id]=0
        fi

        PREV_CPU_TOTAL[$cpu_id]=$total
        PREV_CPU_IDLE[$cpu_id]=$idle
    done < /proc/stat
}

collect_gpu() {
    [[ -z "$GPU_DRM" ]] && return

    # Clock speeds — parse active (*) line from pp_dpm_sclk
    if [[ -r "$GPU_DRM/pp_dpm_sclk" ]]; then
        local line
        while IFS= read -r line; do
            if [[ "$line" == *"*" ]]; then
                # Format: "N: XXXXMhz *"
                GPU_SCLK="${line##*: }"
                GPU_SCLK="${GPU_SCLK%%Mhz*}"
                GPU_SCLK="${GPU_SCLK%%MHz*}"
                GPU_SCLK="${GPU_SCLK// /}"
                break
            fi
        done < "$GPU_DRM/pp_dpm_sclk"
    fi

    if [[ -r "$GPU_DRM/pp_dpm_mclk" ]]; then
        local line
        while IFS= read -r line; do
            if [[ "$line" == *"*" ]]; then
                GPU_MCLK="${line##*: }"
                GPU_MCLK="${GPU_MCLK%%Mhz*}"
                GPU_MCLK="${GPU_MCLK%%MHz*}"
                GPU_MCLK="${GPU_MCLK// /}"
                break
            fi
        done < "$GPU_DRM/pp_dpm_mclk"
    fi

    GPU_BUSY=$(read_sysfs "$GPU_DRM/gpu_busy_percent" 0)

    # VRAM
    local vram_used vram_total
    vram_used=$(read_sysfs "$GPU_DRM/mem_info_vram_used" 0)
    vram_total=$(read_sysfs "$GPU_DRM/mem_info_vram_total" 0)
    GPU_VRAM_USED=$((vram_used / 1048576))    # bytes → MB
    GPU_VRAM_TOTAL=$((vram_total / 1048576))

    # DPM level
    if [[ -r "$GPU_DRM/power_dpm_force_performance_level" ]]; then
        GPU_DPM=$(< "$GPU_DRM/power_dpm_force_performance_level")
    fi

    # Temperature and power from amdgpu hwmon
    if [[ -n "$HWMON_AMDGPU" ]]; then
        local raw
        raw=$(read_sysfs "$HWMON_AMDGPU/temp1_input" 0)
        GPU_TEMP=$((raw / 1000))

        # Power — prefer power1_average, fallback power1_input
        if [[ -r "$HWMON_AMDGPU/power1_average" ]]; then
            raw=$(read_sysfs "$HWMON_AMDGPU/power1_average" 0)
            GPU_POWER=$((raw / 1000000))  # microwatts → W
        elif [[ -r "$HWMON_AMDGPU/power1_input" ]]; then
            raw=$(read_sysfs "$HWMON_AMDGPU/power1_input" 0)
            GPU_POWER=$((raw / 1000000))
        fi
    fi
}

collect_network() {
    # Find primary interface (first non-lo with carrier)
    if [[ -z "$NET_IFACE" ]]; then
        local iface
        for iface in /sys/class/net/*; do
            local name="${iface##*/}"
            [[ "$name" == "lo" ]] && continue
            [[ "$(read_sysfs "$iface/carrier" 0)" == "1" ]] && { NET_IFACE="$name"; break; }
        done
        # Fallback: first non-lo
        if [[ -z "$NET_IFACE" ]]; then
            for iface in /sys/class/net/*; do
                local name="${iface##*/}"
                [[ "$name" != "lo" ]] && { NET_IFACE="$name"; break; }
            done
        fi
    fi

    [[ -z "$NET_IFACE" ]] && return

    # IP address
    NET_IP=$(ip -4 -br addr show "$NET_IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)

    # RX/TX rates
    local now rx tx
    now=$(date +%s%N)
    now=$((now / 1000000))  # milliseconds
    rx=$(read_sysfs "/sys/class/net/$NET_IFACE/statistics/rx_bytes" 0)
    tx=$(read_sysfs "/sys/class/net/$NET_IFACE/statistics/tx_bytes" 0)

    if [[ $PREV_NET_TIME -gt 0 ]]; then
        local dt=$(( (now - PREV_NET_TIME) ))
        if [[ $dt -gt 0 ]]; then
            # bytes/s → KB/s (multiply by 1000 for ms→s conversion)
            NET_RX_RATE=$(( (rx - PREV_NET_RX) * 1000 / dt / 1024 ))
            NET_TX_RATE=$(( (tx - PREV_NET_TX) * 1000 / dt / 1024 ))
            # Clamp negative (counter reset)
            [[ $NET_RX_RATE -lt 0 ]] && NET_RX_RATE=0
            [[ $NET_TX_RATE -lt 0 ]] && NET_TX_RATE=0
        fi
    fi

    PREV_NET_RX=$rx
    PREV_NET_TX=$tx
    PREV_NET_TIME=$now

    # WiFi info from /proc/net/wireless
    NET_WIFI_SIGNAL=""
    NET_WIFI_BAND=""
    NET_WIFI_CHANNEL=""
    if [[ -f /proc/net/wireless ]]; then
        local wline
        wline=$(grep "^ *${NET_IFACE}" /proc/net/wireless 2>/dev/null) || true
        if [[ -n "$wline" ]]; then
            # Format: iface: status link level noise ...
            read -ra wfields <<< "$wline"
            NET_WIFI_SIGNAL="${wfields[3]%%.*}"  # dBm, strip trailing dot
            NET_WIFI_SIGNAL="${NET_WIFI_SIGNAL%.}"
        fi
    fi

    # Band/channel from iw (if available)
    if command -v iw &>/dev/null && [[ -n "$NET_WIFI_SIGNAL" ]]; then
        local iw_out
        iw_out=$(iw dev "$NET_IFACE" info 2>/dev/null) || true
        if [[ -n "$iw_out" ]]; then
            NET_WIFI_CHANNEL=$(echo "$iw_out" | grep -oP 'channel \K[0-9]+' | head -1)
            local freq
            freq=$(echo "$iw_out" | grep -oP '\(\K[0-9]+(?= MHz)' | head -1)
            if [[ -n "$freq" ]]; then
                if (( freq < 3000 )); then
                    NET_WIFI_BAND="2.4"
                elif (( freq < 6000 )); then
                    NET_WIFI_BAND="5"
                else
                    NET_WIFI_BAND="6"
                fi
            fi
        fi
    fi
}

collect_storage() {
    # Root partition usage
    local df_out
    df_out=$(df -B1 / 2>/dev/null | tail -1) || true
    if [[ -n "$df_out" ]]; then
        read -ra df_fields <<< "$df_out"
        STOR_ROOT_TOTAL=$(( df_fields[1] / 1073741824 ))  # bytes → GB
        STOR_ROOT_USED=$(( df_fields[2] / 1073741824 ))
        STOR_ROOT_PCT="${df_fields[4]%%%}"
    fi

    # Btrfs status
    STOR_BTRFS_STATUS="n/a"
    if command -v btrfs &>/dev/null; then
        if btrfs filesystem show / &>/dev/null; then
            local dev_stats
            dev_stats=$(btrfs device stats / 2>/dev/null) || true
            if [[ -n "$dev_stats" ]]; then
                local err_count
                err_count=$(echo "$dev_stats" | awk -F'[. ]+' '{s+=$NF} END{print s+0}')
                [[ "$err_count" -eq 0 ]] && STOR_BTRFS_STATUS="OK" || STOR_BTRFS_STATUS="${err_count} errors"
            fi
        fi
    fi

    # Snapshot count
    STOR_SNAP_COUNT=0
    STOR_SNAP_LATEST=""
    if command -v btrfs &>/dev/null; then
        local snap_list
        snap_list=$(btrfs subvolume list -s / 2>/dev/null) || true
        if [[ -n "$snap_list" ]]; then
            STOR_SNAP_COUNT=$(echo "$snap_list" | wc -l)
            STOR_SNAP_LATEST=$(echo "$snap_list" | tail -1 | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' | head -1)
        fi
    fi

    # IO rates from /proc/diskstats (root device)
    local root_dev
    root_dev=$(findmnt -no SOURCE / 2>/dev/null | sed 's|/dev/||; s|\[.*||') || true
    # Strip partition number for diskstats lookup
    local disk_name="${root_dev%%[0-9]*}"
    # For nvme: nvme0n1p2 → nvme0n1
    [[ "$root_dev" == nvme* ]] && disk_name="${root_dev%%p[0-9]*}"

    if [[ -n "$disk_name" ]] && [[ -f /proc/diskstats ]]; then
        local ds_line
        ds_line=$(awk -v d="$disk_name" '$3 == d {print}' /proc/diskstats 2>/dev/null) || true
        if [[ -n "$ds_line" ]]; then
            read -ra ds <<< "$ds_line"
            # fields[5] = sectors read, fields[9] = sectors written (512 bytes each)
            local cur_read=$(( ds[5] * 512 ))
            local cur_write=$(( ds[9] * 512 ))

            if [[ $PREV_IO_READ -gt 0 ]]; then
                local d_read=$((cur_read - PREV_IO_READ))
                local d_write=$((cur_write - PREV_IO_WRITE))
                [[ $d_read -lt 0 ]] && d_read=0
                [[ $d_write -lt 0 ]] && d_write=0
                STOR_IO_READ=$((d_read / INTERVAL / 1048576))   # MB/s
                STOR_IO_WRITE=$((d_write / INTERVAL / 1048576))
            fi

            PREV_IO_READ=$cur_read
            PREV_IO_WRITE=$cur_write
        fi
    fi
}

collect_systemd() {
    # Failed units
    SYS_FAILED_UNITS=""
    SYS_FAILED_COUNT=0
    local failed_out
    failed_out=$(systemctl --failed --no-legend --plain 2>/dev/null) || true
    if [[ -n "$failed_out" ]]; then
        SYS_FAILED_COUNT=$(echo "$failed_out" | wc -l)
        SYS_FAILED_UNITS=$(echo "$failed_out" | awk '{print $1}' | head -10)
    fi

    # Boot time
    SYS_BOOT_TIME=$(systemd-analyze 2>/dev/null | head -1 | grep -oP '= .*' | sed 's/= //') || SYS_BOOT_TIME="?"

    # Active timers count
    SYS_TIMER_COUNT=$(systemctl list-timers --no-legend 2>/dev/null | wc -l) || SYS_TIMER_COUNT=0

    # Recent journal errors (last 5 min, priority err+)
    SYS_JOURNAL_ERRORS=""
    local je
    je=$(journalctl -p err --since "5 min ago" --no-pager -q --output=short-monotonic 2>/dev/null | tail -5) || true
    SYS_JOURNAL_ERRORS="$je"
}

collect_thermal() {
    # From k10temp
    if [[ -n "$HWMON_K10TEMP" ]]; then
        local raw
        raw=$(read_sysfs "$HWMON_K10TEMP/temp1_input" 0)
        THERM_PACKAGE=$((raw / 1000))

        # Tctl (often temp1), Tccd (temp3+)
        [[ -r "$HWMON_K10TEMP/temp2_input" ]] && THERM_CORE=$(( $(< "$HWMON_K10TEMP/temp2_input") / 1000 ))
    fi

    # From amdgpu hwmon
    if [[ -n "$HWMON_AMDGPU" ]]; then
        # Edge temp (temp1), junction (temp2), memory (temp3)
        [[ -r "$HWMON_AMDGPU/temp1_input" ]] && THERM_EDGE=$(( $(< "$HWMON_AMDGPU/temp1_input") / 1000 ))
        [[ -r "$HWMON_AMDGPU/temp2_input" ]] && THERM_GPU=$(( $(< "$HWMON_AMDGPU/temp2_input") / 1000 ))

        # Fan RPM
        THERM_FAN=$(read_sysfs "$HWMON_AMDGPU/fan1_input" 0)

        # Power rails
        [[ -r "$HWMON_AMDGPU/power1_average" ]] && THERM_POWER_CORE=$(( $(read_sysfs "$HWMON_AMDGPU/power1_average" 0) / 1000000 ))
        [[ -r "$HWMON_AMDGPU/power2_average" ]] && THERM_POWER_SOC=$(( $(read_sysfs "$HWMON_AMDGPU/power2_average" 0) / 1000000 ))

        # TDP / power cap
        [[ -r "$HWMON_AMDGPU/power1_cap" ]] && THERM_TDP=$(( $(read_sysfs "$HWMON_AMDGPU/power1_cap" 0) / 1000000 ))
    fi
}

collect_all() {
    collect_cpu
    collect_gpu
    collect_network
    collect_storage
    collect_systemd
    collect_thermal
}

# ── Rendering helpers ─────────────────────────────────────────────────────

# Move cursor to row, col (1-indexed)
goto() { printf '\e[%d;%dH' "$1" "$2"; }

# Clear screen without flicker — just reposition
clear_content() { printf '\e[2J\e[H'; }

# Print at position with color
put() {
    local row=$1 col=$2 color=$3
    shift 3
    goto "$row" "$col"
    printf '%s%s%s' "$color" "$*" "$C_RESET"
}

# Draw horizontal line
hline() {
    local row=$1 col=$2 width=$3 char="${4:-─}"
    goto "$row" "$col"
    printf '%*s' "$width" '' | tr ' ' "$char"
}

# Right-align text in a field
rpad() {
    local text="$1" width="$2"
    printf '%*s' "$width" "$text"
}

lpad() {
    local text="$1" width="$2"
    printf '%-*s' "$width" "$text"
}

# Format bytes as human-readable
fmt_rate() {
    local kb=$1
    if (( kb >= 1024 )); then
        printf '%d.%d MB/s' $((kb / 1024)) $(( (kb % 1024) * 10 / 1024 ))
    else
        printf '%d KB/s' "$kb"
    fi
}

# Color a value based on threshold: green < warn < crit = red
color_threshold() {
    local val=$1 warn=$2 crit=$3
    if (( val >= crit )); then
        printf '%s' "$C_RED"
    elif (( val >= warn )); then
        printf '%s' "$C_YELLOW"
    else
        printf '%s' "$C_GREEN"
    fi
}

# CPU load average (across all cores)
cpu_load_avg() {
    local sum=0 count=0 i
    for ((i = 0; i < CPU_CORES; i++)); do
        sum=$((sum + ${CPU_LOAD[$i]:-0}))
        count=$((count + 1))
    done
    [[ $count -gt 0 ]] && echo $((sum / count)) || echo 0
}

# ── Panel renderers (grid mode) ──────────────────────────────────────────

# Each panel gets: start_row, start_col, width, height
# Panels write within their bounds

render_panel_header() {
    local row=$1 col=$2 width=$3 title=$4
    put "$row" "$col" "${C_BOLD}${C_CYAN}" "$title"
    local title_len=${#title}
    local remain=$((width - title_len))
    if (( remain > 1 )); then
        goto "$row" $((col + title_len + 1))
        printf '%s' "$C_DIM"
        printf '%*s' "$((remain - 1))" '' | tr ' ' '─'
        printf '%s' "$C_RESET"
    fi
}

render_cpu_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "CPU"
    local load_avg
    load_avg=$(cpu_load_avg)
    local tc
    tc=$(color_threshold "$CPU_TEMP" 70 85)

    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Avg: %-5s MHz  Load: %s%3d%%%s' "$CPU_FREQ_AVG" "$(color_threshold "$load_avg" 60 90)" "$load_avg" "$C_RESET")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Temp: %s%3d°C%s     Gov: %s' "$tc" "$CPU_TEMP" "$C_RESET" "$CPU_GOVERNOR")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Boost: %-3s     Cores: %d' "$CPU_BOOST" "$CPU_CORES")"

    # Per-core freq summary (first 8, abbreviated)
    if (( h > 4 )); then
        local core_str="" i
        local show=$((CPU_CORES < 8 ? CPU_CORES : 8))
        for ((i = 0; i < show; i++)); do
            core_str+="$(printf 'C%d:%4d ' "$i" "${CPU_FREQS[$i]:-0}")"
        done
        [[ $CPU_CORES -gt 8 ]] && core_str+="..."
        put $((r+4)) "$c" "$C_DIM" "${core_str:0:$w}"
    fi
}

render_gpu_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "GPU"

    if [[ -z "$GPU_DRM" ]]; then
        put $((r+1)) "$c" "$C_DIM" "No AMD GPU detected"
        return
    fi

    local tc
    tc=$(color_threshold "$GPU_TEMP" 70 90)
    local vram_gb=""
    if (( GPU_VRAM_TOTAL > 0 )); then
        vram_gb="$(printf '%d.%d/%d.%d GB' $((GPU_VRAM_USED/1024)) $(( (GPU_VRAM_USED%1024)*10/1024 )) $((GPU_VRAM_TOTAL/1024)) $(( (GPU_VRAM_TOTAL%1024)*10/1024 )))"
    fi

    put $((r+1)) "$c" "$C_WHITE" "$(printf 'SCLK: %-5s MHz  Busy: %s%3d%%%s' "$GPU_SCLK" "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "$C_RESET")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Temp: %s%3d°C%s     VRAM: %s' "$tc" "$GPU_TEMP" "$C_RESET" "$vram_gb")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Power: %3dW      DPM: %s' "$GPU_POWER" "${GPU_DPM:-?}")"
}

render_network_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "NETWORK"

    put $((r+1)) "$c" "$C_WHITE" "$(printf 'IF: %-12s IP: %s' "${NET_IFACE:-none}" "${NET_IP:-?}")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf '↓ %-14s ↑ %s' "$(fmt_rate "$NET_RX_RATE")" "$(fmt_rate "$NET_TX_RATE")")"

    if [[ -n "$NET_WIFI_SIGNAL" ]] && [[ "$NET_WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
        local sig_color sig_abs
        sig_abs=${NET_WIFI_SIGNAL#-}
        sig_color=$(color_threshold "$sig_abs" 60 75)
        put $((r+3)) "$c" "$C_WHITE" "$(printf 'Signal: %s%s dBm%s  Band: %s GHz  Ch: %s' "$sig_color" "$NET_WIFI_SIGNAL" "$C_RESET" "${NET_WIFI_BAND:-?}" "${NET_WIFI_CHANNEL:-?}")"
    else
        put $((r+3)) "$c" "$C_DIM" "Wired connection"
    fi
}

render_storage_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "STORAGE"

    local pct_color
    pct_color=$(color_threshold "$STOR_ROOT_PCT" 75 90)
    put $((r+1)) "$c" "$C_WHITE" "$(printf '/: %s%3d%%%s  %dG/%dG' "$pct_color" "$STOR_ROOT_PCT" "$C_RESET" "${STOR_ROOT_USED:-0}" "${STOR_ROOT_TOTAL:-0}")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Btrfs: %-6s Snaps: %d' "$STOR_BTRFS_STATUS" "$STOR_SNAP_COUNT")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'IO: R %3d MB/s  W %3d MB/s' "$STOR_IO_READ" "$STOR_IO_WRITE")"
    if [[ -n "$STOR_SNAP_LATEST" ]] && (( h > 4 )); then
        put $((r+4)) "$c" "$C_DIM" "$(printf 'Last snap: %s' "$STOR_SNAP_LATEST")"
    fi
}

render_systemd_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "SYSTEMD"

    local fail_color="$C_GREEN"
    [[ $SYS_FAILED_COUNT -gt 0 ]] && fail_color="$C_RED"

    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Failed: %s%d%s       Boot: %s' "$fail_color" "$SYS_FAILED_COUNT" "$C_RESET" "${SYS_BOOT_TIME:-?}")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Timers: %d active' "$SYS_TIMER_COUNT")"

    if [[ $SYS_FAILED_COUNT -gt 0 ]] && (( h > 3 )); then
        local unit
        local row_off=3
        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            (( row_off >= h )) && break
            put $((r + row_off)) "$c" "$C_RED" "  ! ${unit:0:$((w-4))}"
            ((row_off++))
        done <<< "$SYS_FAILED_UNITS"
    fi
}

render_thermal_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "THERMAL"

    local pkg_color
    pkg_color=$(color_threshold "$THERM_PACKAGE" 70 85)
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Package: %s%3d°C%s   Fan: %d RPM' "$pkg_color" "$THERM_PACKAGE" "$C_RESET" "$THERM_FAN")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Core: %3d°C      SoC: %3dW' "$THERM_CORE" "$THERM_POWER_SOC")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Edge: %3d°C      GPU: %3dW  TDP: %dW' "$THERM_EDGE" "$THERM_POWER_CORE" "$THERM_TDP")"
}

# ── Expanded panel renderers ─────────────────────────────────────────────

render_cpu_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "CPU — Detailed"
    local row=$((r+1)) i

    put "$row" 2 "$C_WHITE" "$(printf 'Average: %d MHz   Governor: %s   Boost: %s   Cores: %d' "$CPU_FREQ_AVG" "$CPU_GOVERNOR" "$CPU_BOOST" "$CPU_CORES")"
    ((row++))

    put "$row" 2 "$C_WHITE" "$(printf 'Package Temp: %s%d°C%s' "$(color_threshold "$CPU_TEMP" 70 85)" "$CPU_TEMP" "$C_RESET")"
    ((row++))

    # CCD temps
    if (( ${#CPU_TEMPS[@]} > 1 )); then
        local tstr="CCD Temps:"
        for ((i = 1; i < ${#CPU_TEMPS[@]}; i++)); do
            tstr+="  CCD$((i-1)): ${CPU_TEMPS[$i]}°C"
        done
        put "$row" 2 "$C_WHITE" "$tstr"
        ((row++))
    fi

    ((row++))
    put "$row" 2 "${C_BOLD}" "$(printf '%-6s %8s %6s %6s' 'Core' 'Freq' 'Load' 'Temp')"
    ((row++))

    for ((i = 0; i < CPU_CORES && row < max_h - 2; i++)); do
        local lc
        lc=$(color_threshold "${CPU_LOAD[$i]:-0}" 60 90)
        put "$row" 2 "$C_WHITE" "$(printf 'cpu%-3d %5d MHz %s%4d%%%s' "$i" "${CPU_FREQS[$i]:-0}" "$lc" "${CPU_LOAD[$i]:-0}" "$C_RESET")"
        ((row++))
    done
}

render_gpu_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "GPU — Detailed"
    local row=$((r+1))

    if [[ -z "$GPU_DRM" ]]; then
        put "$row" 2 "$C_DIM" "No AMD GPU detected"
        return
    fi

    put "$row" 2 "$C_WHITE" "$(printf 'Shader Clock:  %s MHz' "$GPU_SCLK")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Memory Clock:  %s MHz' "$GPU_MCLK")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Busy:      %s%d%%%s' "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "$C_RESET")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Temperature:   %s%d°C%s' "$(color_threshold "$GPU_TEMP" 70 90)" "$GPU_TEMP" "$C_RESET")"; ((row++))

    local vram_pct=0
    (( GPU_VRAM_TOTAL > 0 )) && vram_pct=$(( GPU_VRAM_USED * 100 / GPU_VRAM_TOTAL ))
    put "$row" 2 "$C_WHITE" "$(printf 'VRAM:          %d / %d MB (%d%%)' "$GPU_VRAM_USED" "$GPU_VRAM_TOTAL" "$vram_pct")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Power Draw:    %d W' "$GPU_POWER")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'DPM Level:     %s' "${GPU_DPM:-unknown}")"; ((row++))
}

render_network_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "NETWORK — Detailed"
    local row=$((r+1))

    put "$row" 2 "$C_WHITE" "$(printf 'Interface:  %s' "${NET_IFACE:-none}")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'IP Address: %s' "${NET_IP:-?}")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'RX Rate:    %s' "$(fmt_rate "$NET_RX_RATE")")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'TX Rate:    %s' "$(fmt_rate "$NET_TX_RATE")")"; ((row++))

    if [[ -n "$NET_WIFI_SIGNAL" ]]; then
        ((row++))
        put "$row" 2 "${C_BOLD}" "WiFi Details"; ((row++))
        put "$row" 2 "$C_WHITE" "$(printf 'Signal:   %s dBm' "$NET_WIFI_SIGNAL")"; ((row++))
        put "$row" 2 "$C_WHITE" "$(printf 'Band:     %s GHz' "${NET_WIFI_BAND:-?}")"; ((row++))
        put "$row" 2 "$C_WHITE" "$(printf 'Channel:  %s' "${NET_WIFI_CHANNEL:-?}")"; ((row++))
    fi

    # Per-interface summary
    ((row++))
    put "$row" 2 "${C_BOLD}" "$(printf '%-15s %10s %10s %6s' 'Interface' 'RX bytes' 'TX bytes' 'State')"; ((row++))
    local iface
    for iface in /sys/class/net/*; do
        (( row >= max_h - 2 )) && break
        local name="${iface##*/}"
        [[ "$name" == "lo" ]] && continue
        local state
        state=$(read_sysfs "$iface/operstate" "?")
        local rx_b tx_b
        rx_b=$(read_sysfs "$iface/statistics/rx_bytes" 0)
        tx_b=$(read_sysfs "$iface/statistics/tx_bytes" 0)
        put "$row" 2 "$C_WHITE" "$(printf '%-15s %10d %10d %6s' "$name" "$rx_b" "$tx_b" "$state")"
        ((row++))
    done
}

render_storage_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "STORAGE — Detailed"
    local row=$((r+1))

    put "$row" 2 "$C_WHITE" "$(printf 'Root:     %dG / %dG (%s%d%%%s)' "${STOR_ROOT_USED:-0}" "${STOR_ROOT_TOTAL:-0}" "$(color_threshold "$STOR_ROOT_PCT" 75 90)" "$STOR_ROOT_PCT" "$C_RESET")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Btrfs:    %s' "$STOR_BTRFS_STATUS")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'IO Read:  %d MB/s' "$STOR_IO_READ")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'IO Write: %d MB/s' "$STOR_IO_WRITE")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Snapshots: %d' "$STOR_SNAP_COUNT")"; ((row++))
    [[ -n "$STOR_SNAP_LATEST" ]] && { put "$row" 2 "$C_WHITE" "$(printf 'Latest:    %s' "$STOR_SNAP_LATEST")"; ((row++)); }
}

render_systemd_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "SYSTEMD — Detailed"
    local row=$((r+1))

    local fail_color="$C_GREEN"
    [[ $SYS_FAILED_COUNT -gt 0 ]] && fail_color="$C_RED"

    put "$row" 2 "$C_WHITE" "$(printf 'Failed Units: %s%d%s' "$fail_color" "$SYS_FAILED_COUNT" "$C_RESET")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Boot Time:    %s' "${SYS_BOOT_TIME:-?}")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Active Timers: %d' "$SYS_TIMER_COUNT")"; ((row++))

    if [[ $SYS_FAILED_COUNT -gt 0 ]]; then
        ((row++))
        put "$row" 2 "${C_BOLD}${C_RED}" "Failed:"; ((row++))
        local unit
        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            (( row >= max_h - 5 )) && break
            put "$row" 4 "$C_RED" "$unit"
            ((row++))
        done <<< "$SYS_FAILED_UNITS"
    fi

    if [[ -n "$SYS_JOURNAL_ERRORS" ]]; then
        ((row++))
        put "$row" 2 "${C_BOLD}${C_YELLOW}" "Recent Errors (5 min):"; ((row++))
        local eline
        while IFS= read -r eline; do
            [[ -z "$eline" ]] && continue
            (( row >= max_h - 2 )) && break
            put "$row" 4 "$C_YELLOW" "${eline:0:$((w-6))}"
            ((row++))
        done <<< "$SYS_JOURNAL_ERRORS"
    fi
}

render_thermal_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "THERMAL — Detailed"
    local row=$((r+1))

    put "$row" 2 "${C_BOLD}" "Temperatures"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Package (Tctl): %s%3d°C%s' "$(color_threshold "$THERM_PACKAGE" 70 85)" "$THERM_PACKAGE" "$C_RESET")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Core (Tdie):    %3d°C' "$THERM_CORE")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Edge:       %3d°C' "$THERM_EDGE")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Junction:   %3d°C' "$THERM_GPU")"; ((row++))

    ((row++))
    put "$row" 2 "${C_BOLD}" "Power"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Core Power:     %3d W' "$THERM_POWER_CORE")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'SoC Power:      %3d W' "$THERM_POWER_SOC")"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'TDP Cap:        %3d W' "$THERM_TDP")"; ((row++))

    ((row++))
    put "$row" 2 "${C_BOLD}" "Cooling"; ((row++))
    put "$row" 2 "$C_WHITE" "$(printf 'Fan Speed:      %d RPM' "$THERM_FAN")"; ((row++))
}

# ── Main renderers ────────────────────────────────────────────────────────

render_header() {
    local now
    now=$(date +%H:%M:%S)
    local log_ind=""
    [[ $LOG_ENABLED -eq 1 ]] && log_ind=" ${C_RED}●REC${C_RESET}"

    # Title bar
    goto 1 1
    printf '%s' "${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    printf ' ry-dashboard v%s' "$VERSION"

    # Panel tabs
    local panels=("OVR" "CPU" "GPU" "NET" "DISK" "SYS" "THERM")
    local i
    for ((i = 0; i < ${#panels[@]}; i++)); do
        if [[ $i -eq $FOCUSED_PANEL ]]; then
            printf ' %s[%s]%s%s' "$C_BOLD" "${panels[$i]}" "$C_RESET" "${C_BG_BLUE}${C_WHITE}"
        else
            printf '  %s ' "${panels[$i]}"
        fi
    done

    # Right-align time + log indicator
    local right_str="$now "
    local pad_width=$((COLS - ${#right_str} - 5 - ${#panels[@]} * 7 - 25))
    (( pad_width > 0 )) && printf '%*s' "$pad_width" ""
    printf '%s%s' "$right_str" "$C_RESET"
    printf '%s' "$log_ind"
    printf '%s\e[K%s' "${C_BG_BLUE}" "$C_RESET"
}

render_footer() {
    local row=$ROWS
    goto "$row" 1
    printf '%s' "${C_DIM}"
    printf ' 0-6:panel  d:detail  l:log  r:refresh  +/-:interval(%ds)  q:quit\e[K' "$INTERVAL"
    printf '%s' "$C_RESET"
}

render_statusbar() {
    local row=$((ROWS - 1))
    goto "$row" 1
    printf '%s' "${C_BOLD}"

    local load_avg
    load_avg=$(cpu_load_avg)

    local fail_ind=""
    [[ $SYS_FAILED_COUNT -gt 0 ]] && fail_ind="${C_RED}${SYS_FAILED_COUNT}!${C_RESET}${C_BOLD}" || fail_ind="${C_GREEN}0${C_RESET}${C_BOLD}"

    printf ' CPU:%dMHz %s%d°C%s %s%d%%%s' \
        "$CPU_FREQ_AVG" \
        "$(color_threshold "$CPU_TEMP" 70 85)" "$CPU_TEMP" "${C_RESET}${C_BOLD}" \
        "$(color_threshold "$load_avg" 60 90)" "$load_avg" "${C_RESET}${C_BOLD}"

    printf '  GPU:%sMHz %s%d°C%s %s%d%%%s' \
        "$GPU_SCLK" \
        "$(color_threshold "$GPU_TEMP" 70 90)" "$GPU_TEMP" "${C_RESET}${C_BOLD}" \
        "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "${C_RESET}${C_BOLD}"

    printf '  NET:↓%s ↑%s' "$(fmt_rate "$NET_RX_RATE")" "$(fmt_rate "$NET_TX_RATE")"

    printf '  SYS:%s' "$fail_ind"

    printf '  T:%s%d°C%s' "$(color_threshold "$THERM_PACKAGE" 70 85)" "$THERM_PACKAGE" "${C_RESET}${C_BOLD}"

    printf '\e[K%s' "$C_RESET"
}

render_overview() {
    local content_start=3
    local content_end=$((ROWS - 3))
    local avail_h=$((content_end - content_start))
    local half_w=$(( (COLS - 3) / 2 ))

    # Panel heights: distribute evenly, 3 rows of 2 panels
    local panel_h=$((avail_h / 3))
    (( panel_h < 4 )) && panel_h=4

    local left_col=2
    local right_col=$((half_w + 3))

    # Row 1: CPU | GPU
    render_cpu_panel    "$content_start"                      "$left_col"  "$half_w" "$panel_h"
    render_gpu_panel    "$content_start"                      "$right_col" "$half_w" "$panel_h"

    # Row 2: THERMAL | NETWORK
    render_thermal_panel $((content_start + panel_h))         "$left_col"  "$half_w" "$panel_h"
    render_network_panel $((content_start + panel_h))         "$right_col" "$half_w" "$panel_h"

    # Row 3: STORAGE | SYSTEMD
    render_storage_panel $((content_start + panel_h * 2))     "$left_col"  "$half_w" "$panel_h"
    render_systemd_panel $((content_start + panel_h * 2))     "$right_col" "$half_w" "$panel_h"
}

render_expanded() {
    local content_start=3
    local max_h=$((ROWS - 3))

    case "$FOCUSED_PANEL" in
        1) render_cpu_expanded     "$content_start" "$COLS" "$max_h" ;;
        2) render_gpu_expanded     "$content_start" "$COLS" "$max_h" ;;
        3) render_network_expanded "$content_start" "$COLS" "$max_h" ;;
        4) render_storage_expanded "$content_start" "$COLS" "$max_h" ;;
        5) render_systemd_expanded "$content_start" "$COLS" "$max_h" ;;
        6) render_thermal_expanded "$content_start" "$COLS" "$max_h" ;;
    esac
}

render() {
    clear_content
    render_header

    if [[ $FOCUSED_PANEL -eq 0 ]]; then
        render_overview
    else
        render_expanded
    fi

    render_statusbar
    render_footer
    NEED_REDRAW=0
}

# ── Input handler ─────────────────────────────────────────────────────────
handle_input() {
    local key="$1"

    case "$key" in
        q|Q)
            RUNNING=0 ;;
        0)
            FOCUSED_PANEL=0; NEED_REDRAW=1 ;;
        [1-6])
            if [[ $FOCUSED_PANEL -eq "$key" ]]; then
                FOCUSED_PANEL=0  # Toggle back to overview
            else
                FOCUSED_PANEL="$key"
            fi
            NEED_REDRAW=1 ;;
        d|D)
            DETAIL_LEVEL=$(( (DETAIL_LEVEL + 1) % 2 ))
            NEED_REDRAW=1 ;;
        l|L)
            if [[ $LOG_ENABLED -eq 1 ]]; then
                LOG_ENABLED=0
            else
                LOG_ENABLED=1
                log_init
            fi
            NEED_REDRAW=1 ;;
        r|R)
            LAST_COLLECT_MS=0  # Force refresh on next loop iteration
            ;;
        +|=)
            (( INTERVAL < 10 )) && ((INTERVAL++))
            NEED_REDRAW=1 ;;
        -)
            (( INTERVAL > 1 )) && ((INTERVAL--))
            NEED_REDRAW=1 ;;
        $'\e')
            # Escape key — could be escape sequence (arrows)
            local seq=""
            read -rsn1 -t 0.05 seq || true
            if [[ "$seq" == "[" ]]; then
                read -rsn1 -t 0.05 seq || true
                case "$seq" in
                    A) ;; # Up — reserved for scroll
                    B) ;; # Down — reserved for scroll
                    C) ;; # Right
                    D) ;; # Left
                esac
            else
                # Plain Escape — return to overview
                FOCUSED_PANEL=0
                NEED_REDRAW=1
            fi
            ;;
    esac
}

# ── Cleanup ───────────────────────────────────────────────────────────────
cleanup() {
    RUNNING=0
    term_restore
    exit 0
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    init_colors

    # Minimum terminal size check
    update_term_size
    if (( COLS < 60 || ROWS < 20 )); then
        echo "Error: terminal too small (need 60x20, have ${COLS}x${ROWS})" >&2
        exit 1
    fi

    discover_hwmon
    FOCUSED_PANEL=$START_PANEL

    # Traps
    trap cleanup EXIT INT TERM
    trap 'update_term_size' WINCH

    term_setup
    log_init

    # Initial data collection (two rounds for deltas)
    collect_all
    sleep 0.3
    collect_all

    # Main loop
    local now_ms key=""
    while [[ $RUNNING -eq 1 ]]; do
        now_ms=$(( $(date +%s%N) / 1000000 ))

        # Collect data on interval
        if (( now_ms - LAST_COLLECT_MS >= INTERVAL * 1000 )); then
            collect_all
            log_row
            LAST_COLLECT_MS=$now_ms
            NEED_REDRAW=1
        fi

        # Render if needed
        if [[ $NEED_REDRAW -eq 1 ]]; then
            render
        fi

        # Poll for input (0.2s timeout)
        key=""
        if read -rsn1 -t 0.2 key 2>/dev/null; then
            handle_input "$key"
        fi
    done
}

main "$@"
