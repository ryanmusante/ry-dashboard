# ry-dashboard

System monitoring TUI for CachyOS on AMD Strix Halo (Beelink GTR9 Pro).

Pure bash + tput. Zero external dependencies beyond coreutils + sysfs.

## Features

- **6-panel overview** — CPU, GPU, Network, Storage, Systemd, Thermal displayed simultaneously
- **Drill-down** — Press 1-6 to expand any panel to full-width detailed view
- **Color-coded thresholds** — Green/yellow/red for temps, load, usage
- **CSV/JSONL logging** — Record metrics over time with `--log`
- **Keyboard navigation** — Tab, vim-style keys, +/- interval adjust
- **Graceful degradation** — Works without GPU, btrfs, iw, or WiFi
- **Terminal-safe** — Alternate screen buffer, proper cleanup on EXIT/INT/TERM, SIGWINCH resize

## Data Sources

| Panel | Sources |
|-------|---------|
| CPU | `/proc/stat`, `/sys/devices/system/cpu/*/cpufreq/`, k10temp hwmon |
| GPU | `/sys/class/drm/card*/device/` (pp_dpm_sclk, gpu_busy_percent), amdgpu hwmon |
| Network | `/sys/class/net/*/statistics/`, `/proc/net/wireless`, `iw` |
| Storage | `df`, `btrfs device stats`, `btrfs subvolume list`, `/proc/diskstats` |
| Systemd | `systemctl --failed`, `systemd-analyze`, `journalctl -p err` |
| Thermal | k10temp hwmon, amdgpu hwmon (temps, fan RPM, power rails, TDP cap) |

All sensors discovered by name (not hwmon index) for stability across boots.
GPU detected by AMD vendor ID (0x1002).

## Install

```bash
install -Dm755 ry-dashboard.bash /usr/local/bin/ry-dashboard
```

## Usage

```
ry-dashboard [OPTIONS]

Options:
  -i, --interval SEC   Refresh interval (default: 2, range: 1-10)
  -p, --panel NUM      Start on panel 0-6 (0 = overview, default: 0)
  -l, --log [PATH]     Enable CSV logging
      --json           Use JSONL format for logging
      --no-color       Disable color output
      --version        Print version and exit
  -h, --help           Show this help
```

## Keybinds

| Key | Action |
|-----|--------|
| `1-6` | Expand panel (press again or Esc to return) |
| `0` | Return to overview |
| `d` | Toggle detail level |
| `l` | Toggle logging on/off |
| `r` | Force immediate refresh |
| `+/-` | Adjust refresh interval |
| `q` | Quit |

## Logging

Default log path: `$XDG_DATA_HOME/ry-dashboard/log-YYYY-MM-DD.csv`

CSV columns: `timestamp,cpu_freq_avg,cpu_temp,cpu_load,gpu_sclk,gpu_temp,gpu_busy,gpu_power,net_rx_rate,net_tx_rate,stor_root_pct,sys_failed,therm_package,therm_fan,therm_tdp`

Use `--json` for JSONL format instead.

## Requirements

- bash 5+
- Linux with sysfs (`/sys/class/hwmon/`, `/sys/class/drm/`, `/proc/stat`)
- Terminal ≥ 60x20
- Optional: `btrfs-progs`, `iw`, `systemd`

## License

MIT
