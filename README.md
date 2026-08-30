# ry-dashboard

**Version 1.4.0** · [Changelog](CHANGELOG.md)

Read-only terminal monitor for the CachyOS profile [ry-install](https://github.com/ryanmusante/ry-install) deploys on the Beelink GTR9 Pro (Ryzen AI Max+ 395 / gfx1151 / Strix Halo). `ry-dashboard.bash` reads sysfs, `/proc`, and `systemctl` on a timer and paints six panels, coloring each live value against the tunable [ry-install](https://github.com/ryanmusante/ry-install) actually deploys — a glance at profile state between runs, not a substitute for [ry-verify](https://github.com/ryanmusante/ry-verify), which is the audit.

## Quick Start

> [!WARNING]
> Run as your normal user — the dashboard never needs `sudo` and writes nothing outside its own log directory. Meet [Requirements](#requirements) first.

```bash
git clone https://github.com/ryanmusante/ry-dashboard.git
cd ry-dashboard
install -Dm755 ry-dashboard.bash ~/.local/bin/ry-dashboard
ry-dashboard
```

The overview grid opens on launch; `1`-`6` expand a panel and `q` quits — see [Keybinds](#keybinds).

## Requirements

`ry-dashboard.bash` gates each of these at preflight and exits `3` on the first that fails.

| Requirement | Detail |
|---|---|
| OS | Linux with sysfs; CachyOS with the [ry-install](https://github.com/ryanmusante/ry-install) profile deployed |
| Shell | bash 5.0 or newer |
| Terminal | at least 60x20, `TERM` with an alternate screen (`smcup`) |
| Hardware | CPU matching `Ryzen AI Max` — bypass via [Environment Overrides](#environment-overrides) |
| Privileges | normal user; no `sudo`, no writes outside the log directory |
| Tools | GNU coreutils (`stty`, `df`, `nproc`, `date`), `tput` (ncurses), `findmnt` (util-linux), `ip` (iproute2), `awk`, `sed` |

Optional and degraded gracefully when absent: `systemctl` and `systemd-analyze` blank the Systemd panel, `journalctl` drops the recent-errors block, `iw` drops the Wi-Fi band, channel, and power-save readouts, `ip` blanks the IP address, and a missing GPU blanks the GPU panel. The GPU is discovered, not gated — an absent one is not a preflight failure.

## Usage

The bare invocation is the overview grid at a 2-second refresh. `--panel <0-6>` opens straight into an expanded panel and `--interval <1-10>` sets the tick. `--log` starts CSV logging, `--json` switches that to JSONL. Positional arguments and unknown options exit `2`. `--help` (`-h`) and `--version` (`-v`) are the only stdout output — every diagnostic goes to stderr.

| Flag | Effect |
|---|---|
| `-i, --interval SEC` | refresh interval, `1`-`10`, default `2` |
| `-p, --panel NUM` | start panel, `0`-`6`, default `0` (overview) |
| `-l, --log [PATH]` | enable logging; bare form uses the default path |
| `--json` | log JSONL instead of CSV |
| `--no-color` | disable colored output |
| `-v, --version` | print `v1.4.0` and exit |
| `-h, --help` | print help and exit |

## Exit Codes

`ry-dashboard.bash` exits `0 1 2 3` — the same domain `ry-install.fish` and `ry-verify.fish` use for their shared codes.

| Code | Meaning |
|---|---|
| `0` | OK — clean quit |
| `1` | a runtime failure; the terminal could not be taken over |
| `2` | bad arguments, a positional argument, an out-of-range value |
| `3` | preflight — old bash, missing `tput`, no tty, no alternate screen, terminal below 60x20, CPU gate mismatch |

`INT`, `TERM`, and `HUP` exit `128+N` — `130`, `143`, and `129` — the signal convention `ry-install.fish` and `ry-verify.fish` certify.

## Environment Overrides

| Variable | Effect |
|---|---|
| `RY_INSTALL_SKIP_HARDWARE_CHECK=1` | bypass the `EXPECT_CPU_MATCH` hard-fail, the same knob the pair reads |
| `NO_COLOR` | disable colored output when set to a non-empty value ([no-color.org](https://no-color.org)) |
| `TERM=dumb` | disables color independently of `NO_COLOR`, and fails the alternate-screen gate |
| `XDG_DATA_HOME` | log directory root; defaults to `~/.local/share` |

## Panels

Six panels, two per row in the overview grid, each expandable. `d` toggles the detail block inside an expanded panel.

| Panel | Sources | Profile readouts |
|---|---|---|
| CPU | `/proc/stat`, `cpufreq`, `k10temp` | scaling driver, governor, EPP, boost |
| GPU | `/sys/class/drm/card*/device/`, `amdgpu` hwmon | DPM level |
| Network | `/sys/class/net/*/statistics/`, `/proc/net/wireless`, `ip`, `iw` | Wi-Fi power save |
| Storage | `df`, `findmnt`, `/proc/diskstats`, `/sys/block/*/queue/` | fstab options, NVMe scheduler |
| Systemd | `systemctl`, `systemd-analyze`, `journalctl` | enabled and masked unit tallies, refreshed every 5th tick |
| Thermal | `k10temp` and `amdgpu` hwmon | TjMax and PPT ceiling headroom |

Every hwmon path is discovered by name, never by index, so a reshuffle across boots cannot point a readout at the wrong sensor. The GPU is found by AMD vendor ID `0x1002`.

### Keybinds

| Key | Action |
|---|---|
| `1`-`6` | expand a panel; press again or `Esc` to return |
| `0` | return to the overview grid |
| `d` | toggle the detail block in an expanded panel |
| `l` | toggle logging on and off |
| `r` | force an immediate refresh |
| `+` / `-` | adjust the refresh interval |
| `q` / `Ctrl-C` | quit |

## Profile Baseline

> [!CAUTION]
> The values below are carried verbatim from `ry-install.fish` 7.195.0. Bump this repo whenever the deployed tunables change, or the dashboard colors correct state as drift. `PROFILE_VERSION` at the top of the script names the release it tracks.

A green readout means the live value equals what [ry-install](https://github.com/ryanmusante/ry-install) deploys; yellow means it does not. The dashboard only reports — re-run `ry-install.fish` to converge, and [ry-verify](https://github.com/ryanmusante/ry-verify) for the authoritative check.

| Script key | Declared in | Source key | Value |
|---|---|---|---|
| `EXPECT_SCALING_DRIVER` | ry-verify | `EXPECTED_SCALING_DRIVER` | `amd-pstate-epp` |
| `EXPECT_GOVERNOR` | both | `CPUPOWER_GOVERNOR` | `performance` |
| `EXPECT_EPP` | both | `EPP_PREFERENCE` | `performance` |
| `EXPECT_CPU_BOOST` | ry-verify | `cpufreq/boost` | `on` (sysfs `1`) |
| `EXPECT_GPU_DPM` | both | `GPU_DPM_LEVEL` | `high` |
| `EXPECT_IO_SCHED` | both | `99-ry-perf.rules` | `none` |
| `EXPECT_WIFI_POWERSAVE` | both | `NM_WIFI_POWERSAVE` | `2`, which `iw` reports as `off` |
| `EXPECT_FSTAB_OPTS` | both | fstab rewrite | `noatime`, `lazytime`, `commit=10` |
| `EXPECT_SERVICES` | both | `EXPECTED_SERVICES` | 5 units expected active |
| `EXPECT_MASK` | both | `MASK` | 11 units expected masked |
| `EXPECT_CPU_MATCH` | both | `EXPECTED_CPU_MATCH` | `Ryzen AI Max` |
| `BIOS_PPT_CEILING` | — | BIOS | `85` W flat SPL/fPPT/sPPT |
| `BIOS_TJMAX` | — | BIOS | `90` °C |

All five sleep, suspend, and hibernate targets sit in `MASK`, so this host has no resume path — a masked `suspend.target` is expected state, not a fault.

## Logging

Logging is off by default. `--log` writes one row per refresh tick; `l` toggles it live.

| Property | Detail |
|---|---|
| Path | `$XDG_DATA_HOME/ry-dashboard/YYYY-MM-DD-PID.csv` |
| Mode | `0600`, written under `umask 0177`; the directory is `0700` |
| CSV columns | `timestamp,cpu_freq_avg,cpu_temp,cpu_load,gpu_sclk,gpu_temp,gpu_busy,gpu_power,net_rx_rate,net_tx_rate,stor_root_pct,sys_failed,therm_package,therm_fan,therm_tdp` |
| JSONL | one object per line keyed by the CSV column names, via `--json` |

The PID in the filename keeps two concurrent instances from interleaving rows into one file.

## Safety and Reliability

**Read-only** — the dashboard opens sysfs and `/proc` for reading, calls `systemctl` only in query subcommands, and writes nothing but its own log file.

**Terminal restore** — `tput smcup` takes the alternate screen and the `EXIT`, `INT`, `TERM`, and `HUP` traps restore the screen, cursor, line wrap, and the `stty` settings saved at setup. Preflight probes the alternate screen without emitting it, so a failed gate leaves the terminal untouched and needs no restore.

**Exit status** — the `EXIT` trap preserves the status the script is exiting with rather than forcing `0`, and a signal exits `128+N`, so a wrapper script can tell a clean quit from an interrupt.

**Graceful degradation** — a missing GPU, `iw`, `systemctl`, or `journalctl` blanks the affected readout instead of failing the run.

**Resize** — `SIGWINCH` re-reads the terminal size and forces a redraw.

## Troubleshooting

**Exits `3` immediately** — the terminal is below 60x20, `TERM` has no alternate screen, or bash is older than 5.0. The message names which gate failed.

**Everything reads `0` or `?`** — the `k10temp` and `amdgpu` hwmon nodes were not found. Confirm `lm_sensors` is installed and `sensors` reports the sensors by those names.

**Profile counts are yellow after a fresh install** — the units are masked and enabled at deploy but some only settle after a reboot. Reboot, then re-check with [ry-verify](https://github.com/ryanmusante/ry-verify).

**Mount options read `0/3`** — the fstab rewrite has not been applied or was reverted. Re-run `ry-install.fish`; the dashboard never repairs anything itself.

**Wi-Fi band and channel blank** — `iw` is absent or the interface is wired. The signal readout comes from `/proc/net/wireless` and survives without `iw`.

## Contributing

Questions and bug reports: [GitHub issues](https://github.com/ryanmusante/ry-dashboard/issues). Single-host scope — open an issue before a PR.

## License

MIT — see [LICENSE](LICENSE).
