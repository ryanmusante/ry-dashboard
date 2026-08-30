#!/usr/bin/env bash
# ry-dashboard v1.4.0 — CachyOS profile monitor for the Beelink GTR9 Pro (gfx1151)
set -euo pipefail

# ── HEADER: VERSION + EXIT CODES ──
readonly VERSION="1.4.0"
readonly PROG="${0##*/}"
readonly EXIT_OK=0 EXIT_FAIL=1 EXIT_USAGE=2 EXIT_PREFLIGHT=3

# ── PROFILE EXPECTATIONS (LOCKSTEP WITH THE ry-install PAIR) ──
# Every value below is carried by the pair — edit all three or readouts lie
readonly PROFILE_VERSION="7.195.0"
readonly EXPECT_SCALING_DRIVER="amd-pstate-epp"   # ry-verify EXPECTED_SCALING_DRIVER
readonly EXPECT_GOVERNOR="performance"            # CPUPOWER_GOVERNOR
readonly EXPECT_EPP="performance"                 # EPP_PREFERENCE
readonly EXPECT_CPU_BOOST="on"                    # ry-verify asserts cpufreq/boost 1
readonly EXPECT_GPU_DPM="high"                    # GPU_DPM_LEVEL
readonly EXPECT_IO_SCHED="none"                   # 99-ry-perf.rules
readonly EXPECT_WIFI_POWERSAVE="2"                # NM_WIFI_POWERSAVE
readonly EXPECT_WIFI_PS_STATE="off"               # what iw reports under wifi.powersave=2
readonly EXPECT_CPU_MATCH="Ryzen AI Max"          # EXPECTED_CPU_MATCH
readonly BIOS_PPT_CEILING=85                      # flat SPL/fPPT/sPPT ceiling
readonly BIOS_TJMAX=90                            # TjMax
readonly -a EXPECT_FSTAB_OPTS=(noatime lazytime commit=10)
readonly -a EXPECT_SERVICES=(fstrim.timer NetworkManager.service cpupower.service nftables.service bluetooth.service)
readonly -a EXPECT_MASK=(ananicy-cpp.service power-profiles-daemon.service NetworkManager-wait-online.service avahi-daemon.service avahi-daemon.socket ufw.service sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)

# ── DEFAULTS ──
INTERVAL=2
START_PANEL=0           # 0 = overview grid, 1-6 = expanded
LOG_ENABLED=0
LOG_PATH=""
LOG_JSON=0
USE_COLOR=1
DETAIL_LEVEL=0          # 0 = compact, 1 = detailed within an expanded panel

# ── RUNTIME STATE ──
FOCUSED_PANEL=0
COLS=0
ROWS=0
NEED_REDRAW=1
RENDER_ROW=0
LAST_COLLECT_MS=0
RUNNING=1
TERM_STTY=""
PROFILE_TICK=0
readonly PROFILE_EVERY=5   # unit tally costs 16 systemctl calls, poll it sparsely

# ── CPU STATE ──
declare -a PREV_CPU_IDLE=()
declare -a PREV_CPU_TOTAL=()
declare -a CPU_LOAD=()
declare -a CPU_FREQS=()
declare -a CPU_TEMPS=()
CPU_FREQ_AVG=0
CPU_TEMP=0
CPU_GOVERNOR=""
CPU_DRIVER=""
CPU_EPP=""
CPU_BOOST=""
CPU_CORES=0

# ── GPU STATE ──
GPU_DRM=""
GPU_SCLK=0
GPU_MCLK=0
GPU_TEMP=0
GPU_BUSY=0
GPU_VRAM_USED=0
GPU_VRAM_TOTAL=0
GPU_POWER=0
GPU_DPM=""

# ── NETWORK STATE ──
NET_IFACE=""
NET_IP=""
NET_RX_RATE=0
NET_TX_RATE=0
NET_WIFI_SIGNAL=""
NET_WIFI_BAND=""
NET_WIFI_CHANNEL=""
NET_POWERSAVE=""
PREV_NET_RX=0
PREV_NET_TX=0
PREV_NET_TIME=0

# ── STORAGE STATE ──
STOR_ROOT_USED=0
STOR_ROOT_TOTAL=0
STOR_ROOT_PCT=0
STOR_FSTYPE=""
STOR_DISK=""
STOR_SCHED=""
STOR_OPTS_OK=0
STOR_OPTS_MISSING=""
STOR_IO_READ=0
STOR_IO_WRITE=0
PREV_IO_READ=0
PREV_IO_WRITE=0
PREV_IO_TIME=0

# ── SYSTEMD STATE ──
SYS_PRESENT=0
SYS_FAILED_COUNT=0
SYS_FAILED_UNITS=""
SYS_BOOT_TIME=""
SYS_TIMER_COUNT=0
SYS_JOURNAL_ERRORS=""
SYS_SVC_OK=0
SYS_SVC_BAD=""
SYS_MASK_OK=0
SYS_MASK_BAD=""

# ── THERMAL STATE ──
THERM_PACKAGE=0
THERM_CORE=0
THERM_GPU=0
THERM_EDGE=0
THERM_FAN=0
THERM_POWER_GPU=0
THERM_POWER_SOC=0
THERM_TDP=0

# ── HWMON DISCOVERY CACHE ──
HWMON_K10TEMP=""
HWMON_AMDGPU=""

# ── COLORS ──
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_WHITE=""
C_BG_BLUE=""

init_colors() {
    # NO_COLOR needs a non-empty value; TERM=dumb disables independently
    if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
        USE_COLOR=0
    fi
    if [[ $USE_COLOR -eq 1 && -t 1 ]]; then
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
    return 0
}

# ── DIAGNOSTICS: STDERR ONLY ──
err() { printf '%s\n' "$*" >&2; }

die() {
    local code=$1
    shift
    err "$PROG: $*"
    exit "$code"
}

# ── HELP TEXT ──
usage() {
    cat <<EOF
Usage: $PROG [OPTIONS]

Read-only monitor for the CachyOS profile ry-install deploys on the GTR9 Pro.

Options:
  -i, --interval SEC   Refresh interval in seconds (default: 2, range: 1-10)
  -p, --panel NUM      Start on panel 0-6 (0 = overview, default: 0)
  -l, --log [PATH]     Enable CSV logging (default: \$XDG_DATA_HOME/ry-dashboard/)
      --json           Use JSONL format for logging
      --no-color       Disable colored output
  -v, --version        Print version and exit
  -h, --help           Show this help

Keybinds:
  1-6        Expand panel (CPU/GPU/Net/Disk/Sys/Therm)
  Esc/0      Return to the overview grid
  d          Toggle detail level in an expanded panel
  l          Toggle logging on/off
  r          Force an immediate refresh
  +/-        Adjust the refresh interval
  q/Ctrl-C   Quit

EXIT CODES: 0 ok · 1 runtime failure · 2 usage · 3 preflight
  (signals exit 128+N: INT 130, TERM 143, HUP 129)

ENVIRONMENT (see README.md for detail):
  RY_INSTALL_SKIP_HARDWARE_CHECK=1  Bypass EXPECT_CPU_MATCH hard-fail.
  NO_COLOR              Disable colored output when set non-empty (no-color.org).
  XDG_DATA_HOME         Log directory root. Default ~/.local/share

Log: \$XDG_DATA_HOME/ry-dashboard/YYYY-MM-DD-PID.csv (--json writes .jsonl)
Profile baseline: ry-install $PROFILE_VERSION.
EOF
    exit "$EXIT_OK"
}

# ── ARGUMENT PARSING ──
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interval)
                [[ -n "${2:-}" ]] || die "$EXIT_USAGE" "--interval requires a value"
                [[ "$2" =~ ^([1-9]|10)$ ]] || die "$EXIT_USAGE" "--interval must be 1-10"
                INTERVAL="$2"
                shift 2 ;;
            -p|--panel)
                [[ -n "${2:-}" ]] || die "$EXIT_USAGE" "--panel requires a value"
                [[ "$2" =~ ^[0-6]$ ]] || die "$EXIT_USAGE" "--panel must be 0-6"
                START_PANEL="$2"
                shift 2 ;;
            -l|--log)
                LOG_ENABLED=1
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    LOG_PATH="$2"
                    shift 2
                else
                    shift
                fi ;;
            --json)     LOG_JSON=1; shift ;;
            --no-color) USE_COLOR=0; shift ;;
            -v|--version) printf 'v%s\n' "$VERSION"; exit "$EXIT_OK" ;;
            -h|--help)  usage ;;
            --)         die "$EXIT_USAGE" "positional arguments are not accepted" ;;
            -*)         die "$EXIT_USAGE" "unknown option: $1" ;;
            *)          die "$EXIT_USAGE" "positional arguments are not accepted: $1" ;;
        esac
    done
    return 0
}

# ── HARDWARE GATE ──
# Fail-closed on an unreadable model, exactly as the pair does
hardware_gate() {
    [[ "${RY_INSTALL_SKIP_HARDWARE_CHECK:-}" == "1" ]] && return 0
    [[ -n "$EXPECT_CPU_MATCH" ]] || return 0
    local model=""
    [[ -r /proc/cpuinfo ]] && model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    local lower_model="${model,,}" lower_match="${EXPECT_CPU_MATCH,,}"
    if [[ -z "$model" ]]; then
        err "$PROG: CPU model unreadable; expected a match for '$EXPECT_CPU_MATCH'"
    elif [[ "$lower_model" != *"$lower_match"* ]]; then
        err "$PROG: CPU '$model' does not match '$EXPECT_CPU_MATCH'"
    else
        return 0
    fi
    err "  Override (at your risk): RY_INSTALL_SKIP_HARDWARE_CHECK=1 $PROG"
    exit "$EXIT_PREFLIGHT"
}

# ── PREFLIGHT GATES ──
preflight() {
    (( BASH_VERSINFO[0] >= 5 )) || die "$EXIT_PREFLIGHT" "bash 5 or newer required, found ${BASH_VERSION}"
    command -v tput >/dev/null 2>&1 || die "$EXIT_PREFLIGHT" "tput not found (install ncurses)"
    [[ -t 0 ]] || die "$EXIT_PREFLIGHT" "stdin is not a terminal"
    [[ -t 1 ]] || die "$EXIT_PREFLIGHT" "stdout is not a terminal"
    # Probe the capability without emitting it — a TERM without it cannot host the TUI
    tput smcup >/dev/null 2>&1 || die "$EXIT_PREFLIGHT" "TERM=${TERM:-unset} has no alternate screen"
    update_term_size
    (( COLS >= 60 && ROWS >= 20 )) \
        || die "$EXIT_PREFLIGHT" "terminal too small (need 60x20, have ${COLS}x${ROWS})"
    hardware_gate
    return 0
}

# ── TERMINAL SETUP + TEARDOWN ──
term_setup() {
    TERM_STTY=$(stty -g 2>/dev/null) || TERM_STTY=""
    tput smcup || die "$EXIT_FAIL" "cannot switch to the alternate screen"
    tput civis || true          # hide cursor
    stty -echo -icanon || die "$EXIT_FAIL" "cannot put the terminal in raw mode"
    printf '\e[?7l'             # disable line wrap
}

term_restore() {
    printf '\e[?7h'     # re-enable line wrap
    if [[ -n "$TERM_STTY" ]]; then
        stty "$TERM_STTY" 2>/dev/null || true
    else
        stty echo icanon 2>/dev/null || true
    fi
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
}

update_term_size() {
    COLS=$(tput cols)
    ROWS=$(tput lines)
    NEED_REDRAW=1
    return 0
}

# ── LOGGING ──
log_init() {
    (( LOG_ENABLED == 1 )) || return 0
    if [[ -z "$LOG_PATH" ]]; then
        local dir="${XDG_DATA_HOME:-$HOME/.local/share}/ry-dashboard"
        mkdir -p "$dir" || { err "$PROG: cannot create $dir"; LOG_ENABLED=0; return 0; }
        chmod 0700 "$dir" || { err "$PROG: cannot secure $dir"; LOG_ENABLED=0; return 0; }
        local ext="csv"
        (( LOG_JSON == 1 )) && ext="jsonl"
        LOG_PATH="$dir/$(date +%Y-%m-%d)-$$.$ext"
    fi
    # Log rows can carry host telemetry; keep the file owner-only
    ( umask 0177 && : >> "$LOG_PATH" ) || { err "$PROG: cannot write $LOG_PATH"; LOG_ENABLED=0; return 0; }
    if (( LOG_JSON == 0 )) && [[ ! -s "$LOG_PATH" ]]; then
        printf '%s\n' \
            "timestamp,cpu_freq_avg,cpu_temp,cpu_load,gpu_sclk,gpu_temp,gpu_busy,gpu_power,net_rx_rate,net_tx_rate,stor_root_pct,sys_failed,therm_package,therm_fan,therm_tdp" \
            >> "$LOG_PATH"
    fi
    return 0
}

log_row() {
    (( LOG_ENABLED == 1 )) || return 0
    local ts
    ts=$(date -Iseconds)
    if (( LOG_JSON == 1 )); then
        printf '{"timestamp":"%s","cpu_freq_avg":%s,"cpu_temp":%s,"cpu_load":%s,"gpu_sclk":%s,"gpu_temp":%s,"gpu_busy":%s,"gpu_power":%s,"net_rx_rate":%s,"net_tx_rate":%s,"stor_root_pct":%s,"sys_failed":%s,"therm_package":%s,"therm_fan":%s,"therm_tdp":%s}\n' \
            "$ts" "$CPU_FREQ_AVG" "$CPU_TEMP" "$(cpu_load_avg)" \
            "$GPU_SCLK" "$GPU_TEMP" "$GPU_BUSY" "$GPU_POWER" \
            "$NET_RX_RATE" "$NET_TX_RATE" "$STOR_ROOT_PCT" \
            "$SYS_FAILED_COUNT" "$THERM_PACKAGE" "$THERM_FAN" "$THERM_TDP" \
            >> "$LOG_PATH"
    else
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$ts" "$CPU_FREQ_AVG" "$CPU_TEMP" "$(cpu_load_avg)" \
            "$GPU_SCLK" "$GPU_TEMP" "$GPU_BUSY" "$GPU_POWER" \
            "$NET_RX_RATE" "$NET_TX_RATE" "$STOR_ROOT_PCT" \
            "$SYS_FAILED_COUNT" "$THERM_PACKAGE" "$THERM_FAN" "$THERM_TDP" \
            >> "$LOG_PATH"
    fi
    return 0
}

# ── SYSFS READS ──
# Read a sysfs file with the builtin, never cat — this runs per core per tick
read_sysfs() {
    local file="$1" fallback="${2:-0}" val
    if [[ -r "$file" ]] && val=$(< "$file") 2>/dev/null && [[ -n "$val" ]]; then
        printf '%s\n' "$val"
    else
        printf '%s\n' "$fallback"
    fi
    return 0
}

# ── HWMON + DRM DISCOVERY ──
# Discovery is by name, never hwmon index — indexes reshuffle across boots
find_hwmon() {
    local target="$1" path
    for path in /sys/class/hwmon/hwmon*; do
        [[ -r "$path/name" ]] || continue
        if [[ "$(< "$path/name")" == "$target" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

discover_hardware() {
    HWMON_K10TEMP=$(find_hwmon k10temp) || HWMON_K10TEMP=""
    HWMON_AMDGPU=$(find_hwmon amdgpu) || HWMON_AMDGPU=""
    local card
    for card in /sys/class/drm/card[0-9]; do
        [[ -r "$card/device/vendor" ]] || continue
        if [[ "$(< "$card/device/vendor")" == "0x1002" ]]; then   # AMD vendor ID
            GPU_DRM="$card/device"
            break
        fi
    done
    CPU_CORES=$(nproc 2>/dev/null) || CPU_CORES=0
    return 0
}

# ── COLLECTORS ──
collect_cpu() {
    local i freq t
    CPU_FREQS=()
    local freq_sum=0 freq_count=0
    for ((i = 0; i < CPU_CORES; i++)); do
        freq=$(read_sysfs "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq" 0)
        freq=$((freq / 1000))   # kHz -> MHz
        CPU_FREQS+=("$freq")
        freq_sum=$((freq_sum + freq))
        freq_count=$((freq_count + 1))
    done
    if (( freq_count > 0 )); then CPU_FREQ_AVG=$((freq_sum / freq_count)); else CPU_FREQ_AVG=0; fi

    if [[ -n "$HWMON_K10TEMP" ]]; then
        CPU_TEMP=$(( $(read_sysfs "$HWMON_K10TEMP/temp1_input" 0) / 1000 ))
        CPU_TEMPS=("$CPU_TEMP")
        for t in "$HWMON_K10TEMP"/temp{2,3,4,5}_input; do
            [[ -r "$t" ]] || break
            CPU_TEMPS+=("$(( $(< "$t") / 1000 ))")
        done
    fi

    CPU_GOVERNOR=$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor unknown)
    CPU_DRIVER=$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver unknown)
    CPU_EPP=$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference unknown)
    CPU_BOOST=$(read_sysfs /sys/devices/system/cpu/cpufreq/boost '?')
    case "$CPU_BOOST" in
        1) CPU_BOOST="on" ;;
        0) CPU_BOOST="off" ;;
    esac

    collect_cpu_load
    return 0
}

collect_cpu_load() {
    local i total idle line cpu_id
    local -a fields
    while IFS= read -r line; do
        [[ "$line" =~ ^cpu([0-9]+)\  ]] || continue
        cpu_id="${BASH_REMATCH[1]}"
        read -ra fields <<< "$line"
        idle=$((fields[4] + fields[5]))   # idle + iowait
        total=0
        for ((i = 1; i < ${#fields[@]}; i++)); do
            total=$((total + fields[i]))
        done
        if [[ -n "${PREV_CPU_TOTAL[$cpu_id]:-}" ]]; then
            local d_total=$((total - PREV_CPU_TOTAL[cpu_id]))
            local d_idle=$((idle - PREV_CPU_IDLE[cpu_id]))
            if (( d_total > 0 )); then
                CPU_LOAD[cpu_id]=$(( (d_total - d_idle) * 100 / d_total ))
            else
                CPU_LOAD[cpu_id]=0
            fi
        else
            CPU_LOAD[cpu_id]=0
        fi
        PREV_CPU_TOTAL[cpu_id]=$total
        PREV_CPU_IDLE[cpu_id]=$idle
    done < /proc/stat
    return 0
}

# Parse the active (starred) row out of a pp_dpm_* table
dpm_active() {
    local file="$1" line val
    [[ -r "$file" ]] || { printf '0\n'; return 0; }
    while IFS= read -r line; do
        [[ "$line" == *"*" ]] || continue
        val="${line##*: }"
        val="${val%%[Mm]hz*}"
        val="${val%%[Mm]Hz*}"
        printf '%s\n' "${val// /}"
        return 0
    done < "$file"
    printf '0\n'
    return 0
}

collect_gpu() {
    [[ -n "$GPU_DRM" ]] || return 0
    GPU_SCLK=$(dpm_active "$GPU_DRM/pp_dpm_sclk")
    GPU_MCLK=$(dpm_active "$GPU_DRM/pp_dpm_mclk")
    GPU_BUSY=$(read_sysfs "$GPU_DRM/gpu_busy_percent" 0)
    GPU_VRAM_USED=$(( $(read_sysfs "$GPU_DRM/mem_info_vram_used" 0) / 1048576 ))
    GPU_VRAM_TOTAL=$(( $(read_sysfs "$GPU_DRM/mem_info_vram_total" 0) / 1048576 ))
    GPU_DPM=$(read_sysfs "$GPU_DRM/power_dpm_force_performance_level" unknown)
    if [[ -n "$HWMON_AMDGPU" ]]; then
        GPU_TEMP=$(( $(read_sysfs "$HWMON_AMDGPU/temp1_input" 0) / 1000 ))
        if [[ -r "$HWMON_AMDGPU/power1_average" ]]; then
            GPU_POWER=$(( $(read_sysfs "$HWMON_AMDGPU/power1_average" 0) / 1000000 ))
        elif [[ -r "$HWMON_AMDGPU/power1_input" ]]; then
            GPU_POWER=$(( $(read_sysfs "$HWMON_AMDGPU/power1_input" 0) / 1000000 ))
        fi
    fi
    return 0
}

collect_network() {
    local iface name
    if [[ -z "$NET_IFACE" ]]; then
        for iface in /sys/class/net/*; do
            name="${iface##*/}"
            [[ "$name" == "lo" ]] && continue
            if [[ "$(read_sysfs "$iface/carrier" 0)" == "1" ]]; then
                NET_IFACE="$name"
                break
            fi
        done
        if [[ -z "$NET_IFACE" ]]; then
            for iface in /sys/class/net/*; do
                name="${iface##*/}"
                if [[ "$name" != "lo" ]]; then
                    NET_IFACE="$name"
                    break
                fi
            done
        fi
    fi
    [[ -n "$NET_IFACE" ]] || return 0

    # The profile ships ipv6.disable=1, so IPv4 is the only address family
    NET_IP=$(ip -4 -br addr show "$NET_IFACE" 2>/dev/null | awk 'NR==1{split($3,a,"/"); print a[1]}') || NET_IP=""

    local now rx tx dt
    now=$(( $(date +%s%N) / 1000000 ))
    rx=$(read_sysfs "/sys/class/net/$NET_IFACE/statistics/rx_bytes" 0)
    tx=$(read_sysfs "/sys/class/net/$NET_IFACE/statistics/tx_bytes" 0)
    if (( PREV_NET_TIME > 0 )); then
        dt=$((now - PREV_NET_TIME))
        if (( dt > 0 )); then
            NET_RX_RATE=$(( (rx - PREV_NET_RX) * 1000 / dt / 1024 ))
            NET_TX_RATE=$(( (tx - PREV_NET_TX) * 1000 / dt / 1024 ))
            (( NET_RX_RATE < 0 )) && NET_RX_RATE=0
            (( NET_TX_RATE < 0 )) && NET_TX_RATE=0
        fi
    fi
    PREV_NET_RX=$rx
    PREV_NET_TX=$tx
    PREV_NET_TIME=$now

    collect_wifi
    return 0
}

collect_wifi() {
    NET_WIFI_SIGNAL=""
    NET_WIFI_BAND=""
    NET_WIFI_CHANNEL=""
    NET_POWERSAVE=""
    [[ -n "$NET_IFACE" ]] || return 0
    local wline iw_out freq
    local -a wfields
    if [[ -r /proc/net/wireless ]]; then
        # Match the interface field-wise; a name with a dot is not a regex
        while IFS= read -r wline; do
            read -ra wfields <<< "$wline"
            [[ "${wfields[0]:-}" == "${NET_IFACE}:" ]] || continue
            NET_WIFI_SIGNAL="${wfields[3]%%.*}"   # dBm, strip the trailing dot
            break
        done < /proc/net/wireless
    fi
    if [[ -z "$NET_WIFI_SIGNAL" ]] || ! command -v iw >/dev/null 2>&1; then
        return 0
    fi
    iw_out=$(iw dev "$NET_IFACE" info 2>/dev/null) || iw_out=""
    if [[ -n "$iw_out" ]]; then
        NET_WIFI_CHANNEL=$(awk '/channel/{for(i=1;i<=NF;i++) if($i=="channel"){print $(i+1); exit}}' <<< "$iw_out")
        freq=$(sed -n 's/.*(\([0-9]\+\) MHz).*/\1/p' <<< "$iw_out" | head -n 1) || freq=""
        if [[ -n "$freq" ]]; then
            if (( freq < 3000 )); then NET_WIFI_BAND="2.4"
            elif (( freq < 5900 )); then NET_WIFI_BAND="5"
            else NET_WIFI_BAND="6"; fi
        fi
    fi
    # iw prints power save only from get power_save, and with a capital P
    NET_POWERSAVE=$(iw dev "$NET_IFACE" get power_save 2>/dev/null \
        | awk -F': ' '/[Pp]ower save:/{print $2; exit}') || NET_POWERSAVE=""
    return 0
}

collect_storage() {
    local df_out
    local -a df_fields
    df_out=$(df -B1 --output=size,used,pcent / 2>/dev/null | tail -n 1) || df_out=""
    if [[ -n "$df_out" ]]; then
        read -ra df_fields <<< "$df_out"
        STOR_ROOT_TOTAL=$(( df_fields[0] / 1073741824 ))   # bytes -> GiB
        STOR_ROOT_USED=$(( df_fields[1] / 1073741824 ))
        STOR_ROOT_PCT="${df_fields[2]%\%}"
    fi

    # The profile rewrites ext4 rows to noatime,lazytime,commit=10 — check live
    STOR_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null) || STOR_FSTYPE="?"
    local opts opt
    opts=$(findmnt -no OPTIONS / 2>/dev/null) || opts=""
    STOR_OPTS_OK=0
    STOR_OPTS_MISSING=""
    for opt in "${EXPECT_FSTAB_OPTS[@]}"; do
        if [[ ",$opts," == *",$opt,"* ]]; then
            STOR_OPTS_OK=$((STOR_OPTS_OK + 1))
        else
            STOR_OPTS_MISSING+="${STOR_OPTS_MISSING:+ }$opt"
        fi
    done

    local root_dev
    root_dev=$(findmnt -no SOURCE / 2>/dev/null | sed 's|/dev/||; s|\[.*||') || root_dev=""
    STOR_DISK="${root_dev%%[0-9]*}"
    [[ "$root_dev" == nvme* ]] && STOR_DISK="${root_dev%%p[0-9]*}"

    # 99-ry-perf.rules pins the NVMe scheduler to none, outranking the vendor kyber
    STOR_SCHED="?"
    if [[ -n "$STOR_DISK" && -r "/sys/block/$STOR_DISK/queue/scheduler" ]]; then
        local sched
        sched=$(< "/sys/block/$STOR_DISK/queue/scheduler")
        if [[ "$sched" =~ \[([a-z-]+)\] ]]; then
            STOR_SCHED="${BASH_REMATCH[1]}"
        else
            STOR_SCHED="${sched%% *}"
        fi
    fi

    collect_storage_io
    return 0
}

collect_storage_io() {
    [[ -n "$STOR_DISK" && -r /proc/diskstats ]] || return 0
    local ds_line now dt cur_read cur_write d_read d_write
    local -a ds
    ds_line=$(awk -v d="$STOR_DISK" '$3 == d {print; exit}' /proc/diskstats 2>/dev/null) || ds_line=""
    [[ -n "$ds_line" ]] || return 0
    read -ra ds <<< "$ds_line"
    now=$(( $(date +%s%N) / 1000000 ))
    cur_read=$(( ds[5] * 512 ))    # sectors read
    cur_write=$(( ds[9] * 512 ))   # sectors written
    # Rate off the measured window, not INTERVAL — r and +/- move the cadence
    if (( PREV_IO_TIME > 0 )); then
        dt=$((now - PREV_IO_TIME))
        if (( dt > 0 )); then
            d_read=$((cur_read - PREV_IO_READ))
            d_write=$((cur_write - PREV_IO_WRITE))
            (( d_read < 0 )) && d_read=0
            (( d_write < 0 )) && d_write=0
            STOR_IO_READ=$(( d_read * 1000 / dt / 1048576 ))     # MB/s
            STOR_IO_WRITE=$(( d_write * 1000 / dt / 1048576 ))
        fi
    fi
    PREV_IO_READ=$cur_read
    PREV_IO_WRITE=$cur_write
    PREV_IO_TIME=$now
    return 0
}

collect_systemd() {
    SYS_PRESENT=0
    command -v systemctl >/dev/null 2>&1 || return 0
    SYS_PRESENT=1
    local failed_out
    SYS_FAILED_UNITS=""
    SYS_FAILED_COUNT=0
    failed_out=$(systemctl --failed --no-legend --plain 2>/dev/null) || failed_out=""
    if [[ -n "$failed_out" ]]; then
        SYS_FAILED_COUNT=$(wc -l <<< "$failed_out")
        SYS_FAILED_UNITS=$(awk 'NR<=10{print $1}' <<< "$failed_out")
    fi

    SYS_BOOT_TIME=$(systemd-analyze 2>/dev/null | awk -F'= ' 'NR==1{print $2; exit}') || SYS_BOOT_TIME=""
    [[ -n "$SYS_BOOT_TIME" ]] || SYS_BOOT_TIME="?"
    SYS_TIMER_COUNT=$(systemctl list-timers --no-legend 2>/dev/null | wc -l) || SYS_TIMER_COUNT=0

    if (( PROFILE_TICK % PROFILE_EVERY == 0 )); then
        collect_profile_units
    fi
    PROFILE_TICK=$((PROFILE_TICK + 1))

    SYS_JOURNAL_ERRORS=""
    if command -v journalctl >/dev/null 2>&1; then
        SYS_JOURNAL_ERRORS=$(journalctl -p err --since "5 min ago" --no-pager -q -o short-monotonic 2>/dev/null | tail -n 5) || SYS_JOURNAL_ERRORS=""
    fi
    return 0
}

# EXPECT_SERVICES must read active, EXPECT_MASK must read masked
collect_profile_units() {
    local unit state
    SYS_SVC_OK=0
    SYS_SVC_BAD=""
    for unit in "${EXPECT_SERVICES[@]}"; do
        state=$(systemctl is-active "$unit" 2>/dev/null) || true
        if [[ "$state" == "active" ]]; then
            SYS_SVC_OK=$((SYS_SVC_OK + 1))
        else
            SYS_SVC_BAD+="${SYS_SVC_BAD:+$'\n'}$unit (${state:-unknown})"
        fi
    done
    SYS_MASK_OK=0
    SYS_MASK_BAD=""
    for unit in "${EXPECT_MASK[@]}"; do
        state=$(systemctl is-enabled "$unit" 2>/dev/null) || true
        if [[ "$state" == "masked" ]]; then
            SYS_MASK_OK=$((SYS_MASK_OK + 1))
        else
            SYS_MASK_BAD+="${SYS_MASK_BAD:+$'\n'}$unit (${state:-unknown})"
        fi
    done
    return 0
}

collect_thermal() {
    if [[ -n "$HWMON_K10TEMP" ]]; then
        THERM_PACKAGE=$(( $(read_sysfs "$HWMON_K10TEMP/temp1_input" 0) / 1000 ))
        [[ -r "$HWMON_K10TEMP/temp2_input" ]] && THERM_CORE=$(( $(< "$HWMON_K10TEMP/temp2_input") / 1000 ))
    fi
    if [[ -n "$HWMON_AMDGPU" ]]; then
        [[ -r "$HWMON_AMDGPU/temp1_input" ]] && THERM_EDGE=$(( $(< "$HWMON_AMDGPU/temp1_input") / 1000 ))
        [[ -r "$HWMON_AMDGPU/temp2_input" ]] && THERM_GPU=$(( $(< "$HWMON_AMDGPU/temp2_input") / 1000 ))
        THERM_FAN=$(read_sysfs "$HWMON_AMDGPU/fan1_input" 0)
        [[ -r "$HWMON_AMDGPU/power1_average" ]] && THERM_POWER_GPU=$(( $(read_sysfs "$HWMON_AMDGPU/power1_average" 0) / 1000000 ))
        [[ -r "$HWMON_AMDGPU/power2_average" ]] && THERM_POWER_SOC=$(( $(read_sysfs "$HWMON_AMDGPU/power2_average" 0) / 1000000 ))
        [[ -r "$HWMON_AMDGPU/power1_cap" ]] && THERM_TDP=$(( $(read_sysfs "$HWMON_AMDGPU/power1_cap" 0) / 1000000 ))
    fi
    return 0
}

collect_all() {
    collect_cpu
    collect_gpu
    collect_network
    collect_storage
    collect_systemd
    collect_thermal
    return 0
}

# ── RENDERING HELPERS ──
goto() { printf '\e[%d;%dH' "$1" "$2"; }

clear_content() { printf '\e[2J\e[H'; }

put() {
    local row=$1 col=$2 color=$3
    shift 3
    goto "$row" "$col"
    printf '%s%s%s' "$color" "$*" "$C_RESET"
}

fmt_rate() {
    local kb=$1
    if (( kb >= 1024 )); then
        printf '%d.%d MB/s' $((kb / 1024)) $(( (kb % 1024) * 10 / 1024 ))
    else
        printf '%d KB/s' "$kb"
    fi
}

# Green below warn, yellow to crit, red at or above crit
color_threshold() {
    local val=$1 warn=$2 crit=$3
    if (( val >= crit )); then printf '%s' "$C_RED"
    elif (( val >= warn )); then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_GREEN"; fi
}

# Green when the live value equals the value ry-install deploys
color_expect() {
    if [[ "$1" == "$2" ]]; then printf '%s' "$C_GREEN"; else printf '%s' "$C_YELLOW"; fi
}

color_count() {
    if (( $1 == $2 )); then printf '%s' "$C_GREEN"; else printf '%s' "$C_RED"; fi
}

cpu_load_avg() {
    local sum=0 count=0 i
    for ((i = 0; i < CPU_CORES; i++)); do
        sum=$((sum + ${CPU_LOAD[$i]:-0}))
        count=$((count + 1))
    done
    if (( count > 0 )); then printf '%d\n' $((sum / count)); else printf '0\n'; fi
}

render_panel_header() {
    local row=$1 col=$2 width=$3 title=$4
    put "$row" "$col" "${C_BOLD}${C_CYAN}" "$title"
    local title_len=${#title}
    local remain=$((width - title_len))
    if (( remain > 1 )); then
        # tr would truncate the box-drawing byte string to its first byte
        local pad
        printf -v pad '%*s' "$((remain - 1))" ''
        goto "$row" $((col + title_len + 1))
        printf '%s%s%s' "$C_DIM" "${pad// /─}" "$C_RESET"
    fi
    return 0
}

# ── GRID PANELS ──
render_cpu_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "CPU"
    local load_avg tc
    load_avg=$(cpu_load_avg)
    tc=$(color_threshold "$CPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Avg: %-5s MHz  Load: %s%3d%%%s' "$CPU_FREQ_AVG" "$(color_threshold "$load_avg" 60 90)" "$load_avg" "$C_RESET")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Temp: %s%3d°C%s     Gov: %s%s%s' "$tc" "$CPU_TEMP" "$C_RESET" "$(color_expect "$CPU_GOVERNOR" "$EXPECT_GOVERNOR")" "$CPU_GOVERNOR" "$C_RESET")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'EPP: %s%-12s%s Cores: %d' "$(color_expect "$CPU_EPP" "$EXPECT_EPP")" "$CPU_EPP" "$C_RESET" "$CPU_CORES")"
    if (( h > 4 )); then
        local core_str="" i show
        show=$(( CPU_CORES < 8 ? CPU_CORES : 8 ))
        for ((i = 0; i < show; i++)); do
            core_str+="$(printf 'C%d:%4d ' "$i" "${CPU_FREQS[$i]:-0}")"
        done
        (( CPU_CORES > 8 )) && core_str+="..."
        put $((r+4)) "$c" "$C_DIM" "${core_str:0:$w}"
    fi
    return 0
}

render_gpu_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "GPU"
    if [[ -z "$GPU_DRM" ]]; then
        put $((r+1)) "$c" "$C_DIM" "No AMD GPU detected"
        return 0
    fi
    local tc vram_gb=""
    tc=$(color_threshold "$GPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")
    if (( GPU_VRAM_TOTAL > 0 )); then
        vram_gb="$(printf '%d.%d/%d.%d GB' $((GPU_VRAM_USED/1024)) $(( (GPU_VRAM_USED%1024)*10/1024 )) $((GPU_VRAM_TOTAL/1024)) $(( (GPU_VRAM_TOTAL%1024)*10/1024 )))"
    fi
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'SCLK: %-5s MHz  Busy: %s%3d%%%s' "$GPU_SCLK" "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "$C_RESET")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Temp: %s%3d°C%s     VRAM: %s' "$tc" "$GPU_TEMP" "$C_RESET" "$vram_gb")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Power: %3dW      DPM: %s%s%s' "$GPU_POWER" "$(color_expect "$GPU_DPM" "$EXPECT_GPU_DPM")" "${GPU_DPM:-?}" "$C_RESET")"
    return 0
}

render_network_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "NETWORK"
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'IF: %-12s IP: %s' "${NET_IFACE:-none}" "${NET_IP:-?}")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf '↓ %-14s ↑ %s' "$(fmt_rate "$NET_RX_RATE")" "$(fmt_rate "$NET_TX_RATE")")"
    if [[ "$NET_WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
        local sig_abs sig_color
        sig_abs=${NET_WIFI_SIGNAL#-}
        sig_color=$(color_threshold "$sig_abs" 60 75)
        put $((r+3)) "$c" "$C_WHITE" "$(printf 'Signal: %s%s dBm%s  Band: %s GHz  Ch: %s' "$sig_color" "$NET_WIFI_SIGNAL" "$C_RESET" "${NET_WIFI_BAND:-?}" "${NET_WIFI_CHANNEL:-?}")"
    else
        put $((r+3)) "$c" "$C_DIM" "Wired connection"
    fi
    return 0
}

render_storage_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "STORAGE"
    local pct_color opt_color
    pct_color=$(color_threshold "$STOR_ROOT_PCT" 75 90)
    opt_color=$(color_count "$STOR_OPTS_OK" "${#EXPECT_FSTAB_OPTS[@]}")
    put $((r+1)) "$c" "$C_WHITE" "$(printf '/: %s%3d%%%s  %dG/%dG  %s' "$pct_color" "$STOR_ROOT_PCT" "$C_RESET" "$STOR_ROOT_USED" "$STOR_ROOT_TOTAL" "$STOR_FSTYPE")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Mount opts: %s%d/%d%s  Sched: %s%s%s' "$opt_color" "$STOR_OPTS_OK" "${#EXPECT_FSTAB_OPTS[@]}" "$C_RESET" "$(color_expect "$STOR_SCHED" "$EXPECT_IO_SCHED")" "$STOR_SCHED" "$C_RESET")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'IO: R %3d MB/s  W %3d MB/s' "$STOR_IO_READ" "$STOR_IO_WRITE")"
    if [[ -n "$STOR_OPTS_MISSING" ]] && (( h > 4 )); then
        put $((r+4)) "$c" "$C_YELLOW" "$(printf 'Missing: %s' "$STOR_OPTS_MISSING")"
    fi
    return 0
}

render_systemd_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "SYSTEMD"
    if (( SYS_PRESENT == 0 )); then
        put $((r+1)) "$c" "$C_DIM" "systemctl not available"
        return 0
    fi
    local fail_color="$C_GREEN"
    (( SYS_FAILED_COUNT > 0 )) && fail_color="$C_RED"
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Failed: %s%d%s       Boot: %s' "$fail_color" "$SYS_FAILED_COUNT" "$C_RESET" "${SYS_BOOT_TIME:-?}")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Profile: %s%d/%d%s active  %s%d/%d%s masked' \
        "$(color_count "$SYS_SVC_OK" "${#EXPECT_SERVICES[@]}")" "$SYS_SVC_OK" "${#EXPECT_SERVICES[@]}" "$C_RESET" \
        "$(color_count "$SYS_MASK_OK" "${#EXPECT_MASK[@]}")" "$SYS_MASK_OK" "${#EXPECT_MASK[@]}" "$C_RESET")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Timers: %d active' "$SYS_TIMER_COUNT")"
    if (( SYS_FAILED_COUNT > 0 && h > 4 )); then
        local unit row_off=4
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            (( row_off >= h )) && break
            put $((r + row_off)) "$c" "$C_RED" "  ! ${unit:0:$((w-4))}"
            row_off=$((row_off + 1))
        done <<< "$SYS_FAILED_UNITS"
    fi
    return 0
}

render_thermal_panel() {
    local r=$1 c=$2 w=$3 h=$4
    render_panel_header "$r" "$c" "$w" "THERMAL"
    local pkg_color tdp_color
    pkg_color=$(color_threshold "$THERM_PACKAGE" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")
    tdp_color=$(color_threshold "$THERM_TDP" $((BIOS_PPT_CEILING + 1)) $((BIOS_PPT_CEILING + 20)))
    put $((r+1)) "$c" "$C_WHITE" "$(printf 'Package: %s%3d°C%s   Fan: %d RPM' "$pkg_color" "$THERM_PACKAGE" "$C_RESET" "$THERM_FAN")"
    put $((r+2)) "$c" "$C_WHITE" "$(printf 'Core: %3d°C      SoC: %3dW' "$THERM_CORE" "$THERM_POWER_SOC")"
    put $((r+3)) "$c" "$C_WHITE" "$(printf 'Edge: %3d°C      GPU: %3dW  TDP: %s%dW%s/%dW' "$THERM_EDGE" "$THERM_POWER_GPU" "$tdp_color" "$THERM_TDP" "$C_RESET" "$BIOS_PPT_CEILING")"
    return 0
}

# ── EXPANDED PANELS ──
render_cpu_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "CPU — Detailed"
    local row=$((r+1)) i
    put "$row" 2 "$C_WHITE" "$(printf 'Average:  %d MHz   Boost: %s%s%s   Cores: %d' "$CPU_FREQ_AVG" "$(color_expect "$CPU_BOOST" "$EXPECT_CPU_BOOST")" "$CPU_BOOST" "$C_RESET" "$CPU_CORES")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Driver:   %s%-16s%s expected %s' "$(color_expect "$CPU_DRIVER" "$EXPECT_SCALING_DRIVER")" "$CPU_DRIVER" "$C_RESET" "$EXPECT_SCALING_DRIVER")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Governor: %s%-16s%s expected %s' "$(color_expect "$CPU_GOVERNOR" "$EXPECT_GOVERNOR")" "$CPU_GOVERNOR" "$C_RESET" "$EXPECT_GOVERNOR")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'EPP:      %s%-16s%s expected %s' "$(color_expect "$CPU_EPP" "$EXPECT_EPP")" "$CPU_EPP" "$C_RESET" "$EXPECT_EPP")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Package:  %s%d°C%s (TjMax %d)' "$(color_threshold "$CPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$CPU_TEMP" "$C_RESET" "$BIOS_TJMAX")"; row=$((row+1))
    if (( ${#CPU_TEMPS[@]} > 1 )); then
        local tstr="CCD Temps:"
        for ((i = 1; i < ${#CPU_TEMPS[@]}; i++)); do
            tstr+="  CCD$((i-1)): ${CPU_TEMPS[$i]}°C"
        done
        put "$row" 2 "$C_WHITE" "$tstr"; row=$((row+1))
    fi
    if (( DETAIL_LEVEL == 1 )); then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "$(printf '%-6s %8s %6s' 'Core' 'Freq' 'Load')"; row=$((row+1))
        for ((i = 0; i < CPU_CORES && row < max_h - 2; i++)); do
            put "$row" 2 "$C_WHITE" "$(printf 'cpu%-3d %5d MHz %s%4d%%%s' "$i" "${CPU_FREQS[$i]:-0}" "$(color_threshold "${CPU_LOAD[$i]:-0}" 60 90)" "${CPU_LOAD[$i]:-0}" "$C_RESET")"
            row=$((row+1))
        done
    else
        row=$((row+1))
        put "$row" 2 "$C_DIM" "Press d for the per-core table."
    fi
    return 0
}

render_gpu_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "GPU — Detailed"
    local row=$((r+1))
    if [[ -z "$GPU_DRM" ]]; then
        put "$row" 2 "$C_DIM" "No AMD GPU detected"
        return 0
    fi
    put "$row" 2 "$C_WHITE" "$(printf 'Shader Clock:  %s MHz' "$GPU_SCLK")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Memory Clock:  %s MHz' "$GPU_MCLK")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Busy:      %s%d%%%s' "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "$C_RESET")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Temperature:   %s%d°C%s' "$(color_threshold "$GPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$GPU_TEMP" "$C_RESET")"; row=$((row+1))
    local vram_pct=0
    (( GPU_VRAM_TOTAL > 0 )) && vram_pct=$(( GPU_VRAM_USED * 100 / GPU_VRAM_TOTAL ))
    put "$row" 2 "$C_WHITE" "$(printf 'VRAM:          %d / %d MB (%d%%)' "$GPU_VRAM_USED" "$GPU_VRAM_TOTAL" "$vram_pct")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Power Draw:    %d W' "$GPU_POWER")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'DPM Level:     %s%s%s (expected %s)' "$(color_expect "$GPU_DPM" "$EXPECT_GPU_DPM")" "${GPU_DPM:-unknown}" "$C_RESET" "$EXPECT_GPU_DPM")"; row=$((row+1))
    if (( DETAIL_LEVEL == 1 )); then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "DPM Tables"; row=$((row+1))
        local f line
        for f in pp_dpm_sclk pp_dpm_mclk; do
            [[ -r "$GPU_DRM/$f" ]] || continue
            put "$row" 2 "$C_DIM" "$f"; row=$((row+1))
            while IFS= read -r line; do
                (( row >= max_h - 2 )) && break
                put "$row" 4 "$C_WHITE" "${line:0:$((w-6))}"
                row=$((row+1))
            done < "$GPU_DRM/$f"
        done
    fi
    return 0
}

render_network_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "NETWORK — Detailed"
    local row=$((r+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Interface:  %s' "${NET_IFACE:-none}")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'IP Address: %s' "${NET_IP:-?}")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'RX Rate:    %s' "$(fmt_rate "$NET_RX_RATE")")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'TX Rate:    %s' "$(fmt_rate "$NET_TX_RATE")")"; row=$((row+1))
    if [[ -n "$NET_WIFI_SIGNAL" ]]; then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "Wi-Fi"; row=$((row+1))
        put "$row" 2 "$C_WHITE" "$(printf 'Signal:     %s dBm' "$NET_WIFI_SIGNAL")"; row=$((row+1))
        put "$row" 2 "$C_WHITE" "$(printf 'Band:       %s GHz' "${NET_WIFI_BAND:-?}")"; row=$((row+1))
        put "$row" 2 "$C_WHITE" "$(printf 'Channel:    %s' "${NET_WIFI_CHANNEL:-?}")"; row=$((row+1))
        put "$row" 2 "$C_WHITE" "$(printf 'Power save: %s%s%s (NM_WIFI_POWERSAVE %s = %s)' "$(color_expect "${NET_POWERSAVE:-?}" "$EXPECT_WIFI_PS_STATE")" "${NET_POWERSAVE:-?}" "$C_RESET" "$EXPECT_WIFI_POWERSAVE" "$EXPECT_WIFI_PS_STATE")"; row=$((row+1))
    fi
    if (( DETAIL_LEVEL == 1 )); then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "$(printf '%-15s %14s %14s %6s' 'Interface' 'RX bytes' 'TX bytes' 'State')"; row=$((row+1))
        local iface name state rx_b tx_b
        for iface in /sys/class/net/*; do
            (( row >= max_h - 2 )) && break
            name="${iface##*/}"
            [[ "$name" == "lo" ]] && continue
            state=$(read_sysfs "$iface/operstate" '?')
            rx_b=$(read_sysfs "$iface/statistics/rx_bytes" 0)
            tx_b=$(read_sysfs "$iface/statistics/tx_bytes" 0)
            put "$row" 2 "$C_WHITE" "$(printf '%-15s %14d %14d %6s' "$name" "$rx_b" "$tx_b" "$state")"
            row=$((row+1))
        done
    fi
    return 0
}

render_storage_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "STORAGE — Detailed"
    local row=$((r+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Root:       %dG / %dG (%s%d%%%s)' "$STOR_ROOT_USED" "$STOR_ROOT_TOTAL" "$(color_threshold "$STOR_ROOT_PCT" 75 90)" "$STOR_ROOT_PCT" "$C_RESET")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Filesystem: %s' "$STOR_FSTYPE")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Device:     %s' "${STOR_DISK:-?}")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Scheduler:  %s%s%s (expected %s)' "$(color_expect "$STOR_SCHED" "$EXPECT_IO_SCHED")" "$STOR_SCHED" "$C_RESET" "$EXPECT_IO_SCHED")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Mount opts: %s%d/%d%s of %s' "$(color_count "$STOR_OPTS_OK" "${#EXPECT_FSTAB_OPTS[@]}")" "$STOR_OPTS_OK" "${#EXPECT_FSTAB_OPTS[@]}" "$C_RESET" "${EXPECT_FSTAB_OPTS[*]}")"; row=$((row+1))
    if [[ -n "$STOR_OPTS_MISSING" ]]; then
        put "$row" 2 "$C_YELLOW" "$(printf 'Missing:    %s — re-run ry-install to converge the fstab' "$STOR_OPTS_MISSING")"
        row=$((row+1))
    fi
    put "$row" 2 "$C_WHITE" "$(printf 'IO Read:    %d MB/s' "$STOR_IO_READ")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'IO Write:   %d MB/s' "$STOR_IO_WRITE")"; row=$((row+1))
    if (( DETAIL_LEVEL == 1 )); then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "Mounted Filesystems"; row=$((row+1))
        local line
        while IFS= read -r line; do
            (( row >= max_h - 2 )) && break
            put "$row" 4 "$C_WHITE" "${line:0:$((w-6))}"
            row=$((row+1))
        done < <(findmnt -rno TARGET,FSTYPE,OPTIONS -t ext4,vfat 2>/dev/null || true)
    fi
    return 0
}

# Print one unit per row up to limit; the stop row comes back in RENDER_ROW,
# never a command substitution — put writes escapes to stdout
render_unit_list() {
    local row=$1 w=$2 limit=$3 color=$4 units=$5 unit
    if [[ -n "$units" ]]; then
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            (( row >= limit )) && break
            put "$row" 4 "$color" "${unit:0:$((w-6))}"
            row=$((row+1))
        done <<< "$units"
    fi
    RENDER_ROW=$row
    return 0
}

render_systemd_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "SYSTEMD — Detailed"
    local row=$((r+1))
    if (( SYS_PRESENT == 0 )); then
        put "$row" 2 "$C_DIM" "systemctl not available — the profile tally needs it"
        return 0
    fi
    local fail_color="$C_GREEN"
    (( SYS_FAILED_COUNT > 0 )) && fail_color="$C_RED"
    put "$row" 2 "$C_WHITE" "$(printf 'Failed Units:  %s%d%s' "$fail_color" "$SYS_FAILED_COUNT" "$C_RESET")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Boot Time:     %s' "${SYS_BOOT_TIME:-?}")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Active Timers: %d' "$SYS_TIMER_COUNT")"; row=$((row+1))
    row=$((row+1))
    put "$row" 2 "$C_BOLD" "$(printf 'Profile Units (ry-install %s)' "$PROFILE_VERSION")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Enabled: %s%d/%d active%s' "$(color_count "$SYS_SVC_OK" "${#EXPECT_SERVICES[@]}")" "$SYS_SVC_OK" "${#EXPECT_SERVICES[@]}" "$C_RESET")"; row=$((row+1))
    render_unit_list "$row" "$w" $((max_h - 4)) "$C_YELLOW" "$SYS_SVC_BAD"; row=$RENDER_ROW
    put "$row" 2 "$C_WHITE" "$(printf 'Masked:  %s%d/%d masked%s' "$(color_count "$SYS_MASK_OK" "${#EXPECT_MASK[@]}")" "$SYS_MASK_OK" "${#EXPECT_MASK[@]}" "$C_RESET")"; row=$((row+1))
    render_unit_list "$row" "$w" $((max_h - 3)) "$C_YELLOW" "$SYS_MASK_BAD"; row=$RENDER_ROW
    if (( SYS_FAILED_COUNT > 0 )); then
        row=$((row+1))
        put "$row" 2 "${C_BOLD}${C_RED}" "Failed"; row=$((row+1))
        render_unit_list "$row" "$w" $((max_h - 2)) "$C_RED" "$SYS_FAILED_UNITS"; row=$RENDER_ROW
    fi
    if (( DETAIL_LEVEL == 1 )) && [[ -n "$SYS_JOURNAL_ERRORS" ]]; then
        row=$((row+1))
        put "$row" 2 "${C_BOLD}${C_YELLOW}" "Recent Errors (5 min)"; row=$((row+1))
        render_unit_list "$row" "$w" $((max_h - 2)) "$C_YELLOW" "$SYS_JOURNAL_ERRORS"; row=$RENDER_ROW
    fi
    return 0
}

render_thermal_expanded() {
    local r=$1 w=$2 max_h=$3
    render_panel_header "$r" 2 "$((w-2))" "THERMAL — Detailed"
    local row=$((r+1))
    put "$row" 2 "$C_BOLD" "Temperatures"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Package (Tctl): %s%3d°C%s' "$(color_threshold "$THERM_PACKAGE" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$THERM_PACKAGE" "$C_RESET")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Core (Tdie):    %3d°C' "$THERM_CORE")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Edge:       %3d°C' "$THERM_EDGE")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Junction:   %3d°C' "$THERM_GPU")"; row=$((row+1))
    put "$row" 2 "$C_DIM" "$(printf 'BIOS TjMax:     %3d°C' "$BIOS_TJMAX")"; row=$((row+1))
    row=$((row+1))
    put "$row" 2 "$C_BOLD" "Power"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'GPU Power:      %3d W' "$THERM_POWER_GPU")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'SoC Power:      %3d W' "$THERM_POWER_SOC")"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'TDP Cap:        %s%3d W%s' "$(color_threshold "$THERM_TDP" $((BIOS_PPT_CEILING + 1)) $((BIOS_PPT_CEILING + 20)))" "$THERM_TDP" "$C_RESET")"; row=$((row+1))
    put "$row" 2 "$C_DIM" "$(printf 'BIOS ceiling:   %3d W flat SPL/fPPT/sPPT' "$BIOS_PPT_CEILING")"; row=$((row+1))
    row=$((row+1))
    put "$row" 2 "$C_BOLD" "Cooling"; row=$((row+1))
    put "$row" 2 "$C_WHITE" "$(printf 'Fan Speed:      %d RPM' "$THERM_FAN")"; row=$((row+1))
    if (( DETAIL_LEVEL == 1 && ${#CPU_TEMPS[@]} > 1 )); then
        row=$((row+1))
        put "$row" 2 "$C_BOLD" "k10temp Sensors"; row=$((row+1))
        local i
        for ((i = 0; i < ${#CPU_TEMPS[@]} && row < max_h - 2; i++)); do
            put "$row" 4 "$C_WHITE" "$(printf 'temp%d: %3d°C' "$((i+1))" "${CPU_TEMPS[$i]}")"
            row=$((row+1))
        done
    fi
    return 0
}

# ── CHROME ──
render_header() {
    local now i
    now=$(date +%H:%M:%S)
    local log_ind=""
    (( LOG_ENABLED == 1 )) && log_ind=" ${C_RED}●REC${C_RESET}"
    goto 1 1
    printf '%s' "${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    printf ' ry-dashboard v%s' "$VERSION"
    local panels=("OVR" "CPU" "GPU" "NET" "DISK" "SYS" "THERM")
    local used=$(( 15 + ${#VERSION} ))   # width of the title run above
    for ((i = 0; i < ${#panels[@]}; i++)); do
        used=$(( used + ${#panels[$i]} + 3 ))   # both arms print 3 + label
        if (( i == FOCUSED_PANEL )); then
            printf ' %s[%s]%s%s' "$C_BOLD" "${panels[$i]}" "$C_RESET" "${C_BG_BLUE}${C_WHITE}"
        else
            printf '  %s ' "${panels[$i]}"
        fi
    done
    local right_str="$now "
    (( LOG_ENABLED == 1 )) && used=$((used + 5))   # the ●REC indicator
    local pad_width=$((COLS - used - ${#right_str}))
    (( pad_width > 0 )) && printf '%*s' "$pad_width" ""
    printf '%s%s' "$right_str" "$C_RESET"
    printf '%s' "$log_ind"
    printf '%s\e[K%s' "${C_BG_BLUE}" "$C_RESET"
    return 0
}

render_footer() {
    goto "$ROWS" 1
    printf '%s' "$C_DIM"
    printf ' 0-6:panel  d:detail(%d)  l:log  r:refresh  +/-:interval(%ds)  q:quit\e[K' "$DETAIL_LEVEL" "$INTERVAL"
    printf '%s' "$C_RESET"
    return 0
}

render_statusbar() {
    goto $((ROWS - 1)) 1
    printf '%s' "$C_BOLD"
    local load_avg fail_ind
    load_avg=$(cpu_load_avg)
    if (( SYS_PRESENT == 0 )); then
        fail_ind="${C_DIM}?${C_RESET}${C_BOLD}"
    elif (( SYS_FAILED_COUNT > 0 )); then
        fail_ind="${C_RED}${SYS_FAILED_COUNT}!${C_RESET}${C_BOLD}"
    else
        fail_ind="${C_GREEN}0${C_RESET}${C_BOLD}"
    fi
    printf ' CPU:%dMHz %s%d°C%s %s%d%%%s' \
        "$CPU_FREQ_AVG" \
        "$(color_threshold "$CPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$CPU_TEMP" "${C_RESET}${C_BOLD}" \
        "$(color_threshold "$load_avg" 60 90)" "$load_avg" "${C_RESET}${C_BOLD}"
    printf '  GPU:%sMHz %s%d°C%s %s%d%%%s' \
        "$GPU_SCLK" \
        "$(color_threshold "$GPU_TEMP" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$GPU_TEMP" "${C_RESET}${C_BOLD}" \
        "$(color_threshold "$GPU_BUSY" 60 90)" "$GPU_BUSY" "${C_RESET}${C_BOLD}"
    printf '  NET:↓%s ↑%s' "$(fmt_rate "$NET_RX_RATE")" "$(fmt_rate "$NET_TX_RATE")"
    printf '  SYS:%s' "$fail_ind"
    if (( SYS_PRESENT == 1 )); then
        printf '  PRF:%s%d/%d%s' \
            "$(color_count $((SYS_SVC_OK + SYS_MASK_OK)) $(( ${#EXPECT_SERVICES[@]} + ${#EXPECT_MASK[@]} )))" \
            $((SYS_SVC_OK + SYS_MASK_OK)) $(( ${#EXPECT_SERVICES[@]} + ${#EXPECT_MASK[@]} )) "${C_RESET}${C_BOLD}"
    else
        printf '  PRF:%s?%s' "$C_DIM" "${C_RESET}${C_BOLD}"
    fi
    printf '  T:%s%d°C%s' "$(color_threshold "$THERM_PACKAGE" $((BIOS_TJMAX - 20)) "$BIOS_TJMAX")" "$THERM_PACKAGE" "${C_RESET}${C_BOLD}"
    printf '\e[K%s' "$C_RESET"
    return 0
}

render_overview() {
    local content_start=3
    local content_end=$((ROWS - 3))
    local avail_h=$((content_end - content_start))
    local half_w=$(( (COLS - 3) / 2 ))
    local panel_h=$((avail_h / 3))
    (( panel_h < 4 )) && panel_h=4
    local left_col=2
    local right_col=$((half_w + 3))
    render_cpu_panel     "$content_start"                  "$left_col"  "$half_w" "$panel_h"
    render_gpu_panel     "$content_start"                  "$right_col" "$half_w" "$panel_h"
    render_thermal_panel $((content_start + panel_h))      "$left_col"  "$half_w" "$panel_h"
    render_network_panel $((content_start + panel_h))      "$right_col" "$half_w" "$panel_h"
    render_storage_panel $((content_start + panel_h * 2))  "$left_col"  "$half_w" "$panel_h"
    render_systemd_panel $((content_start + panel_h * 2))  "$right_col" "$half_w" "$panel_h"
    return 0
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
    return 0
}

render() {
    clear_content
    render_header
    if (( FOCUSED_PANEL == 0 )); then
        render_overview
    else
        render_expanded
    fi
    render_statusbar
    render_footer
    NEED_REDRAW=0
    return 0
}

# ── INPUT HANDLER ──
handle_input() {
    local key="$1" seq=""
    case "$key" in
        q|Q) RUNNING=0 ;;
        0)   FOCUSED_PANEL=0; NEED_REDRAW=1 ;;
        [1-6])
            if (( FOCUSED_PANEL == key )); then
                FOCUSED_PANEL=0
            else
                FOCUSED_PANEL="$key"
            fi
            NEED_REDRAW=1 ;;
        d|D) DETAIL_LEVEL=$(( (DETAIL_LEVEL + 1) % 2 )); NEED_REDRAW=1 ;;
        l|L)
            if (( LOG_ENABLED == 1 )); then
                LOG_ENABLED=0
            else
                LOG_ENABLED=1
                log_init
            fi
            NEED_REDRAW=1 ;;
        r|R) LAST_COLLECT_MS=0 ;;
        +|=) (( INTERVAL < 10 )) && INTERVAL=$((INTERVAL + 1)); NEED_REDRAW=1 ;;
        -)   (( INTERVAL > 1 )) && INTERVAL=$((INTERVAL - 1)); NEED_REDRAW=1 ;;
        $'\e')
            read -rsn1 -t 0.05 seq || true
            if [[ "$seq" != "[" ]]; then
                FOCUSED_PANEL=0
                NEED_REDRAW=1
            else
                read -rsn1 -t 0.05 seq || true   # swallow the arrow final byte
            fi ;;
    esac
    return 0
}

# ── CLEANUP ──
# EXIT fires on every path, so preserve the status the script is exiting with
cleanup() {
    local status=$?
    RUNNING=0
    term_restore
    exit "$status"
}

# Signals exit 128+N, the domain ry-install and ry-verify certify
on_signal() {
    local signo=$1
    RUNNING=0
    trap - EXIT
    term_restore
    exit $((128 + signo))
}

# ── MAIN ──
main() {
    parse_args "$@"
    init_colors
    preflight
    discover_hardware
    FOCUSED_PANEL=$START_PANEL

    trap cleanup EXIT
    trap 'on_signal 1' HUP
    trap 'on_signal 2' INT
    trap 'on_signal 15' TERM
    trap update_term_size WINCH

    term_setup
    log_init

    collect_all          # two rounds seed the delta counters
    sleep 0.3
    collect_all

    local now_ms key=""
    while (( RUNNING == 1 )); do
        now_ms=$(( $(date +%s%N) / 1000000 ))
        if (( now_ms - LAST_COLLECT_MS >= INTERVAL * 1000 )); then
            collect_all
            log_row
            LAST_COLLECT_MS=$now_ms
            NEED_REDRAW=1
        fi
        (( NEED_REDRAW == 1 )) && render
        key=""
        if read -rsn1 -t 0.2 key 2>/dev/null; then
            handle_input "$key"
        fi
    done
    return 0
}

main "$@"
