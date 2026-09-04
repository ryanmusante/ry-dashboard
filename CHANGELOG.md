Changes for ry-dashboard
========================

Newest first. Versioning is MAJOR.MINOR.PATCH.

1.5.0
-----

  - profile: track ry-install and ry-verify 7.195.1; no tunable moved, the
    pair's bump was verify-side only
  - fix: read_sysfs redirected stderr after the read, so a sysfs read error
    leaked bash text into the frame; the brace group carries the redirect
  - fix: the raw $(< node) reads bypassed read_sysfs, and an empty read then
    failed the arithmetic and set -e ended the TUI; every read goes through it
  - fix: a left overview panel drew past its half into the right one; put
    now clips every line at the panel edge, escapes carried uncounted
  - fix: the header, status bar, and footer garbled their last column below
    the width they assume; the bar drops whole fields, NET first, others clip
  - thermal: drop the dead readouts: power2_average is no amdgpu node, and
    power1_cap, fan1_input, junction temp2 are hidden on every APU
  - thermal: Tdie read temp2_input, which k10temp exposes on no Strix Halo
    part, and the CCD line named it CCD0; channels now resolve by _label
  - thermal: headroom is the PPT draw against the 85 W BIOS ceiling, yellow
    inside 10% of it and red 5 W over; cap and fan lines need their nodes
  - gpu: label the power readout with amdgpu power1_label, PPT on an APU,
    since the socket draw is not GPU-only power
  - cpu: the nproc count reads CPUs, not Cores, on a 16C/32T part
  - network: rediscover the interface when its carrier drops and reseed the
    rate window, rather than following a dead link
  - preflight: gate stty, df, nproc, date, findmnt, awk, and sed, the tools
    README.md already said were gated; ip stays optional
  - terminal: on a hung-up pty the restore printf failed under set -e ahead
    of the 129 exit; the restore writes tolerate a dead tty
  - logging: run log_init before the alternate screen so a create failure
    stays readable, and drop the bash line-number noise beside it
  - statusbar: drop the T: field, the same k10temp Tctl the CPU field shows
  - readme: ip is optional, the TUI paints stdout, a missing tool exits 3,
    the zero log columns on gfx1151, UTF-8 locale, clipping under 80 columns


1.4.0
-----

  - fix: the panel rule emitted one raw 0xE2 byte per column, tr having
    truncated the box-drawing replacement to its first byte
  - fix: the Wi-Fi power-save readout parsed iw dev info, which never
    prints it; read iw dev get power_save and match its capital P
  - fix: --interval 011 parsed as octal 9 and passed the range test, and
    --interval 08 leaked a bash arithmetic error; match 1-10 literally
  - fix: INT, TERM, and HUP now exit 130, 143, and 129 rather than 0, and
    HUP no longer leaves the alternate screen up
  - fix: an absent systemctl reported 0/5 active and 0/11 masked in red
    rather than blanking the panel
  - fix: the failed-unit list was the one unguarded pipeline under
    pipefail; slice to ten rows inside awk instead
  - cpu: color the boost readout against the 1 ry-verify asserts
  - storage: rate the IO counters off the measured window, as the network
    rates already do, not off the configured interval
  - terminal: save stty -g at setup and restore it verbatim rather than
    forcing echo and icanon back on
  - logging: key the JSONL rows by the CSV column names
  - profile: name the iw power-save state the profile implies as its own
    expectation instead of a literal in the renderer
  - preflight: run the terminal-size gate before the hardware gate, the
    order README.md documents
  - preflight: read the CPU model only when the skip variable is unset
  - thermal: THERM_POWER_CORE holds amdgpu power1_average, so rename it
    THERM_POWER_GPU and label it alike in both panels
  - header: derive the clock padding from the widths actually printed,
    which left it 14 columns short of the right edge
  - help: name EXPECT_CPU_MATCH, the gate this script declares, and print
    the signal line and log path beside the exit codes
  - cleanty: head -1, tail -1, head -10, and tail -5 take -n; drop the
    grep dependency by matching /proc/net/wireless field-wise
  - readme: ip and the util-linux tools, the GPU is discovered and not
    gated, signal exits, and the JSONL keying


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
