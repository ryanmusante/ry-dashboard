# ry-dashboard

![Version](https://img.shields.io/badge/version-1.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Bash](https://img.shields.io/badge/bash-5%2B-orange)

System monitoring TUI for **Beelink GTR9 Pro** (AMD Ryzen AI Max+ 395 / Strix Halo). Pure bash + tput, zero external dependencies beyond coreutils + sysfs.

## Quick Start

```bash
install -Dm755 ry-dashboard.bash /usr/local/bin/ry-dashboard
ry-dashboard              # Launch TUI
ry-dashboard --help       # All options
```

**Prerequisites:** bash 5+, Linux with sysfs, terminal ≥ 60×20. Optional: `btrfs-progs`, `iw`, `systemd`.

## Options

| Flag | Description |
|------|-------------|
| `-i, --interval SEC` | Refresh interval in seconds (default: 2, range: 1-10) |
| `-p, --panel NUM` | Start on panel 0-6 (0 = overview, default: 0) |
| `-l, --log [PATH]` | Enable CSV logging (default: `$XDG_DATA_HOME/ry-dashboard/`) |
| `--json` | Use JSONL format for logging |
| `--no-color` | Disable color output (respects `NO_COLOR` env) |
| `--version` | Print version and exit |
| `-h, --help` | Show this help |

## Keybinds

| Key | Action |
|-----|--------|
| `1-6` | Expand panel (press again or Esc to return) |
| `0` | Return to overview |
| `d` | Toggle detail level in expanded panel |
| `l` | Toggle logging on/off |
| `r` | Force immediate refresh |
| `+/-` | Adjust refresh interval |
| `q` / `Ctrl-C` | Quit |

## Panels (6)

| Panel | Sources |
|-------|---------|
| CPU | `/proc/stat` · `/sys/devices/system/cpu/*/cpufreq/` · k10temp hwmon |
| GPU | `/sys/class/drm/card*/device/` (pp_dpm_sclk, gpu_busy_percent) · amdgpu hwmon |
| Network | `/sys/class/net/*/statistics/` · `/proc/net/wireless` · `iw` |
| Storage | `df` · `btrfs device stats` · `btrfs subvolume list` · `/proc/diskstats` |
| Systemd | `systemctl --failed` · `systemd-analyze` · `journalctl -p err` |
| Thermal | k10temp hwmon · amdgpu hwmon (temps, fan RPM, power rails, TDP cap) |

All sensors discovered by name (not hwmon index) for stability across boots. GPU detected by AMD vendor ID (0x1002).

## Logging

Default log path: `$XDG_DATA_HOME/ry-dashboard/log-YYYY-MM-DD.csv`

| Format | Columns |
|--------|---------|
| CSV | `timestamp,cpu_freq_avg,cpu_temp,cpu_load,gpu_sclk,gpu_temp,gpu_busy,gpu_power,net_rx_rate,net_tx_rate,stor_root_pct,sys_failed,therm_package,therm_fan,therm_tdp` |
| JSONL | Same fields as JSON objects (`--json`) |

## Safety

| Feature | Detail |
|---------|--------|
| Alternate screen | `tput smcup/rmcup` — restores terminal on exit |
| Signal handling | Cleanup on EXIT, INT, TERM |
| Resize | SIGWINCH triggers redraw |
| Graceful degradation | Works without GPU, btrfs, iw, or WiFi |
| Input | Raw mode with proper restore on all exit paths |

## [Changelog](CHANGELOG.txt) · License: MIT
