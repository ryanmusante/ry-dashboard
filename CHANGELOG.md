Changes for ry-dashboard
========================

Newest first. Versioning is MAJOR.MINOR.PATCH.

1.3.0
-----

  - preflight: add the EXPECTED_CPU_MATCH hardware gate the pair
    carries, bypassed by RY_INSTALL_SKIP_HARDWARE_CHECK=1
  - help: print the ENVIRONMENT block and the exit-code line in the
    same shape the pair prints them
  - systemd: poll the 16-call unit tally every 5th tick rather than
    every tick
  - profile: attribute EXPECTED_SCALING_DRIVER to ry-verify, the only
    script of the pair that declares it
  - cleanty: split collect_cpu, collect_network, and collect_storage,
    each of which broke the 50-line function ceiling
  - cleanty: drop the profile version from its banner, leaving
    PROFILE_VERSION as the only site naming it
  - readme: document the hardware gate and its override, and correct
    the Profile Baseline attribution column


1.2.0
-----

  - profile: carry the ry-install 7.195.0 tunables verbatim and color
    every live readout by whether it matches the deployed value
  - cpu: add the scaling-driver and EPP readouts, expected
    amd-pstate-epp and performance
  - gpu: color the DPM level against the expected high
  - storage: replace the btrfs device-stats and subvolume readouts,
    inert on this ext4 root, with fstype and the 3 fstab options
  - storage: report the NVMe scheduler against the none that
    99-ry-perf.rules pins over the vendor kyber default
  - systemd: add the profile unit tally, 5 expected active and 11
    expected masked, naming drifted units in the expanded panel
  - thermal: derive every temperature and power threshold from the
    BIOS TjMax 90 C and the flat 85 W SPL/fPPT/sPPT ceiling
  - network: add the Wi-Fi power-save readout beside the expected
    NM_WIFI_POWERSAVE of 2
  - fix: parse_args ended on a bare test that returned 1 under set -e,
    so the TUI exited silently before its first frame
  - fix: the EXIT trap forced exit 0 and masked every failure status
  - fix: wire the documented d keybind, which toggled a detail level
    no renderer ever read
  - cli: adopt the shared 0/1/2/3 exit domain, and -v/--version now
    prints v1.2.0 in the same form as the pair
  - preflight: gate bash 5, tput, both tty ends, the alternate screen,
    and the 60x20 floor, each exiting 3 with the failing gate named
  - logging: write log files under umask 0177 with a PID-scoped name
    so concurrent instances cannot interleave rows
  - cleanty: drop the uncalled hline, lpad, and rpad helpers; read
    sysfs with the builtin rather than cat on every core every tick


1.1.0
-----

  - align project conventions with ry-install v3.0.0
  - header comment: single-line format with metadata separators


1.0.0
-----

  - initial release
  - 6-panel overview: CPU, GPU, Network, Storage, Systemd, Thermal
  - drill-down expanded views with detail toggle
  - color-coded thresholds (green/yellow/red)
  - CSV/JSONL logging with --log/--json
  - keyboard navigation: 0-6 panels, d/l/r/+/-/q
  - hwmon discovery by name for boot stability
  - GPU detection by AMD vendor ID 0x1002
  - alternate screen buffer with proper EXIT/INT/TERM/WINCH cleanup
  - graceful degradation without GPU, btrfs, iw, or WiFi
