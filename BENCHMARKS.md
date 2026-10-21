# Benchmarks

Does KOS beat a stock OS with the printer stack installed on top? Every number here comes from a JSON file in
[`bench/results/`](bench/results/), produced by [`tests/bench_on_device.sh`](tests/bench_on_device.sh) on the hardware
listed below. Method behind it: [PLAN.md §16.1](PLAN.md#161-what-to-measure-and-how).

## What is compared

Three installs on the **same** host board, SD card, carrier, printer and printer config, with Klipper and Moonraker
pinned to the **same** commits:

| Label | What it is | How it is set up |
|---|---|---|
| `kos` | The KOS image | Flash, put the printer config on the `KOS` partition, boot |
| `stock` | What most people run | CM5: Raspberry Pi OS Lite (64-bit, trixie). CB1: BTT's CB1 image (Armbian-built, what CB1 owners normally run; Armbian minimal optional). Then KIAUH: Klipper, Moonraker, Mainsail. Then [`tests/stock_prep.sh`](tests/stock_prep.sh): pin the same commits, import the same config, CAN and host MCU per upstream docs |
| `stock-tuned` | `stock` plus KOS's realtime tuning | [`tests/stock_tune.sh`](tests/stock_tune.sh): KOS's kernel args (`isolcpus=3 cpufreq.default_governor=performance video=HDMI-A-1:d`), Klippy pinned to core 3 at KOS's priority, IRQs steered off core 3 |

How to read the three:

- `stock-tuned` vs `stock` is what the **tuning** buys. Anyone can copy it onto their own install.
- `kos` vs `stock-tuned` is what the **base image** buys: logs in RAM, fewer services, zram, no background timers, display drivers off.

The kernel args alone are not a fair "tuned" run: `isolcpus=3` keeps everything off core 3, Klippy included, unless
Klippy is pinned there. So the tuning is copied as a set.

On Raspberry Pi OS the governor arg is also not enough on its own: `raspberrypi-sys-mods` ships
`/usr/lib/udev/rules.d/60-ondemand-governor.rules`, which sets every core to `ondemand` after boot. `stock_tune.sh`
masks it with a same-named rule in `/etc/udev/rules.d/`. KOS does not install `raspberrypi-sys-mods`.

## The tests, in plain steps

### Phase 1: no printer motion

The script sends nothing to Klipper. It loads the CPUs for about a minute, so heaters stay off and nothing prints.
Run it right after a cold boot (pull power), once `pgrep ext4lazyinit` prints nothing. Do 3 to 5 cold boots per
install and compare the medians.

1. **What it is running on.** Board, RAM, CPU clock, SD card identity, kernel, command line, CPU governor, isolated
   cores, and the Klipper / Moonraker / Mainsail versions. Confirms the three runs differ only where intended.
2. **Boot.** Kernel and userspace time (`systemd-analyze`), and seconds from power-on until Moonraker logs `Klippy ready`.
3. **Idle footprint.** RAM used and available, processes, running services, installed packages, root filesystem
   size. Taken before the script installs its own tools; `footprint_clean: false` marks a rerun where they were
   already there.
4. **SD card writes.** MB per hour since boot, then over a 10-minute idle window. Less writing means less card wear
   and fewer I/O stalls.
5. **Timing jitter where Klippy runs.** `cyclictest` wakes up every 1 ms for 60 s, on the CPU cores Klippy is
   allowed to use and at Klippy's scheduling class, and records how late each wake-up was. Once idle, once with
   `stress-ng` loading every core (CPU, memory, I/O). Reported as p50 / p99 / p99.9 / max in µs. Late wake-ups are what
   eventually become `Timer too close`.
6. **Web UI under a real library.** Writes 1,234 slicer-style gcode files with thumbnails into `gcodes/kos-bench/`,
   lets Moonraker index them, then times the folder listing Mainsail asks for (`get_directory` with file details),
   five times. Counts `EVENT LOOP BLOCKED` in `moonraker.log` meanwhile: a blocked loop is what drops the UI's
   connection. The folder is deleted afterwards.

### Phase 2: one real print

The same gcode file, sliced once, printed on each install with the same filament and settings. Recorded from
`klippy.log`: `Timer too close` / MCU shutdowns, and the per-second `Stats` lines (`sysload`, `cputime`,
`memavail`, per-MCU `srtt` / `rttvar` / `bytes_retransmit`).

**The print, fixed for every run:** [`bench/fixtures/flexible+railway+track+brio+short+long_PLA_1h25m.gcode`](bench/fixtures/)
(model license CC BY-NC-SA, credited in [`bench/fixtures/LICENSE.md`](bench/fixtures/LICENSE.md); sha256 `dd546acdfec2f18aced3b03611a2d436ca8e78c58c254e8fb6e951604214d2d4`, checked by `bench/fixtures/SHA256SUMS`).
Never re-slice it; print these bytes on every install. Verify on the printer with
`sha256sum ~/printer_data/gcodes/flexible+railway+track+brio+short+long_PLA_1h25m.gcode`.

| | |
|---|---|
| Slicer | OrcaSlicer 2.4.2, profile Voron 0.1, 0.4 mm nozzle, 0.2 mm layers, PLA, ~30 g |
| Length | 1h25m estimated, 60 layers |
| Moves | 156,465 XY moves, 144,496 extruding; **69 % of extruding moves are under 1 mm** (median 0.68 mm, p10 0.20 mm) |
| Arcs | none (`enable_arc_fitting = 0`): every segment reaches Klippy pre-split |
| Speeds | outer wall 120, inner wall 200, gyroid sparse infill 200, travel 350 mm/s; accel 5000 (outer wall 3000) |
| Other | pressure advance 0.04, about 2.7K retracts, 4K wipes, 13.4K travels |

At 200 mm/s over 0.2 mm segments Klippy plans on the order of 1,000 moves a second in the dense regions; the
average over the whole print is about 31 a second.

What the print should be, in general (why this one qualifies):

- **About 2 hours.** Long enough for many thousands of `Stats` samples and for thermal throttling to show; short
  enough to run three times.
- **Many short moves.** Curved, high-polygon surfaces (an organic model, embossed text, a Benchy-class hull) at
  normal speed. Many tiny segments are what load the host: Klippy has to plan every one.
- **Fast infill and travel.** Gyroid infill at the printer's usual top speed and acceleration.
- **Many retractions and layer changes**, and pressure advance and input shaper on as normally used.
- **Same conditions** every time: same start macro, same bed and chamber temperature, nothing else running on the
  host (no webcam unless all three have it).

## Hardware

| | CM5 runs | CB1 runs |
|---|---|---|
| Host | Raspberry Pi CM5 Lite, CM5104000: 4 GB RAM, Wi-Fi/BT, no eMMC, BCM2712 (4× A76) | BigTreeTech CB1 (Allwinner H616, 4× A53, 1 GB) |
| Carrier | BTT Manta M5P | same BTT Manta M5P |
| Printer | Sindri | same printer |
| Main MCU | Manta M5P STM32G0B1, Klipper USB-to-CAN bridge, CAN 1 Mbit | same |
| Toolhead | LDO Nitehawk 36 (RP2040), USB | same |
| Host MCU | Klipper Linux process (`[mcu host]`) | same |
| Network | wired Ethernet | wired Ethernet |
| SD card | 32 GB SDHC, kernel name `SD32G` (see each JSON's `hw_sd`) | same card (`SD32G`, manfid 0x27, oemid 0x5048, 08/2020) |

The CB1 runs swap only the compute module: same carrier, same printer, same config. CM5 vs CB1 is therefore 1:1.

Known hardware caveat: a 128 GB SDXC card (`FD4Q9`) hung on every warm reboot with this CM5 + M5P; the 32 GB card
does not. Benchmarks use the 32 GB card.

## Results

### Summary so far: CM5, one cold boot each (2026-10-19)

| | `kos` | `stock` | `stock-tuned` |
|---|---|---|---|
| Klippy ready after kernel start | **10.9 s** | 15.0 s | 14.6 s |
| Jitter on Klippy's core, all cores loaded: p99 / p99.9 / max | **16 / 36 / 92 µs** | 50 / 189 / 895 µs | **15 / 33 / 90 µs** |
| Jitter idle: p99 / max | 3 / 9 µs | 8 / 123 µs | 3 / 9 µs |
| Root filesystem / packages (clean footprint) | **1.17 GB / 319** | 8.78 GB / 688 | (same base as stock) |
| RAM used at ready | 335 MB | 350 MB | 362 MB |
| Mainsail listing, 1,234 files, after metadata | 0.389 s | 0.393 s | 0.394 s |
| Print: Klippy CPU / sysload median | **1.9 % / 0.03** | 3.7 % / 0.12 | **1.95 % / 0.03** |
| Print: timer errors / retransmits | 0 / 0 | 0 / 0 | 0 / 0 |

What it says, with one run per install:

- **Timing jitter is the tuning.** `stock-tuned` matches `kos` to the microsecond, and both beat `stock` by about 10x at
  the worst case. Anyone can copy that onto Raspberry Pi OS with `tests/stock_tune.sh`, including the udev governor mask.
- **The base image buys boot speed and size.** About 4 s faster to Klippy ready than either stock variant, and a
  root filesystem 7.5x smaller: no MCU firmware toolchains, no desktop-adjacent packages.
- **Moonraker and RAM are a tie.** The web side is the same software on the same CPU.
- **Both print the benchmark file without a single timer error or retransmit.** A CM5 has headroom either way; the
  margins matter more on a CB1, which is next.

**Repeatability (2026-10-20):** three warm-reboot repeats of `stock-tuned` and one `stock` run after three warm reboots
landed within run-to-run noise of the first cold runs (Klippy ready within 0.5 s, jitter p99 within 2 µs, listing within
4 ms). From here on: **one Phase 1 run per install**, after a cold boot or three warm reboots. The first `stock` run's
5.6 MB/h idle SD writes were Moonraker's first apt/PackageKit refresh after install; on a settled stock install it is
0.2 MB/h, the same order as KOS.

### Summary: CB1, one run each after 3 warm reboots (2026-10-20)

| | `kos` | `stock` (BTT image) | `stock-tuned` |
|---|---|---|---|
| Boot (kernel + userspace) | **13.8 s** | 25.3 s | 23.4 s |
| Klippy ready after kernel start | **23.0 s** | 34.4 s | 34.4 s |
| Jitter on Klippy's core, all cores loaded: p99 / p99.9 / max | **90 / 142 / 232 µs**\* | 168 / 381 / 1196 µs | 114 / 187 / 448 µs |
| Jitter idle: p99 / max | **37 / 76 µs** | 89 / 277 µs | 70 / 272 µs |
| Root filesystem / packages (clean footprint) | **1.22 GB / 310** | 4.88 GB / 993 | (same base as stock) |
| RAM used at ready (of 969 MB) | **217 MB** | 320 MB | 331 MB |
| Services running | 20 | 27 | 27 |
| Moonraker metadata, 1,234 files / listing | 1166 s / 3.39 s | 1189 s / 3.50 s | 1190 s / 3.63 s |
| SD writes idle | 2.2 MB/h | 4.3 MB/h | 3.4 MB/h |
| Print: Klippy CPU / sysload median | **13.5 % / 0.26** | 17.2 % / 0.59 | 14.8 % / 0.79 |
| Print: timer errors / retransmits | 0 / 0 | 0 / 0 | 0 / 0 |

What it says:

- **On a CB1 the base image matters for jitter too, not only the tuning.** On the CM5, `stock-tuned` matched `kos` to the
  microsecond. On the CB1 it closes about half the gap: load p99 168 -> 114 µs against KOS's 90, idle p99 89 -> 70 against
  37. Same preemption model and HZ on both kernels (`PREEMPT`, 250 Hz), so the difference is what else runs on four A53
  cores: BTT's image keeps KlipperScreen (with no screen attached), rsyslog, NFS/rpcbind, unattended-upgrades, vnstat and
  more running (27 services vs 20), on vendor kernel 7.0.2 against KOS's 6.18 `current`.
- **Boot is 11 s faster to Klippy ready**, and RAM use is a third lower: 100 MB matters on a 1 GB board.
- **Moonraker is the slow part on any CB1 install:** ~19.5 min to index 1,234 files and 3.4-3.6 s per listing, roughly 8x
  the CM5. Same software, slower CPU; KOS does not change it.
- **Tuning BTT's image needs two extra steps** (now in `tests/stock_tune.sh`): `/etc/default/cpufrequtils` carries
  `GOVERNOR=ondemand`, and Armbian's `armbian-hardware-optimize` forks a background job that moves the SD and Ethernet
  IRQs onto core 3 *after* any early tuning service has run, so `kos-tune` runs a second time 30 s after boot.

\*Two of three `kos` bench runs hit one multi-millisecond stall under the combined load (12.8 ms and 8.3 ms; the table
shows the clean run). It affects every CB1 install, not only KOS: see the next section.

### Latency stalls on 1 GB boards (K-83, 2026-10-21)

**Finding:** on a CB1 (1 GB RAM), a realtime thread pinned to its own core can stall for **5-30 ms** when memory runs
tight. This happens on **every OS tested**, KOS and BTT alike, and it is a property of the Linux kernel's memory
management on a small-RAM board, not of any one image. **It does not endanger prints:** Klipper plans motion about
**1 s ahead** (buffer_time median 1.18 s on every print in this file), so a ~10 ms pause on the host is absorbed by
the queue a hundred times over. All six benchmark prints (CM5 and CB1, every install) finished with 0 timer errors,
0 MCU shutdowns and 0 retransmits.

**What happens:**

1. With 1 GB of RAM, a page cache full of freshly written data plus a program asking for memory (here stress-ng's 256 MB;
   in the bench, the apt install of the test tools just before the latency test) pushes the kernel to free and
   defragment memory.
2. The kernel's *compaction* moves memory pages around on another core to make contiguous room. By default
   (`vm.compact_unevictable_allowed=1`) it also moves pages a program has *locked* in RAM with `mlockall`.
3. If the program touches a page while it is being moved, it waits until the copy finishes. The kernel stack at that
   moment, captured with an ftrace stack trigger: `io_schedule <- migration_entry_wait_on_locked` (newer kernels:
   `softleaf_entry_wait_on_locked`) `<- migration_entry_wait <- do_swap_page <- __handle_mm_fault`.
4. On a loaded 1.5 GHz A53 that copy took 5-30 ms. During the wait the thread's core sits idle; nothing else is running
   there. Not Ethernet, not IRQs, not temperature or clock changes (all ruled out by trace and measurement).

**How it was proven:** a reproducer ([`tests/stall_reproducer.sh`](tests/stall_reproducer.sh)) writes 300 MB of fresh data,
then runs the bench's exact load and `cyclictest` with a trace that freezes at the first wakeup later than 3 ms and
records the kernel stack where the thread blocked. Each series stops at the first stall.

| System | Kernel | Stall caught | Stack |
|---|---|---|---|
| KOS | 6.18.44 `current` | 8.2 ms (run 4), 6.2 ms (run 2); 11.7 ms in an earlier untraced series | migration wait |
| KOS, `vm.swappiness=100` (BTT's setting) | 6.18.44 | 4.5 ms (run 5) | migration wait |
| KOS, Armbian `edge` | 7.2.8 | 30.6 ms (run 5) | migration wait |
| **BTT stock image, as shipped** | **7.0.2-vendor** | **9.7 ms (run 2)** | migration wait |
| KOS, `vm.compact_unevictable_allowed=0` | 6.18.44 | **none in 15 runs** (max 344 µs) | n/a |

**What this means:**

- **All CB1 options are affected the same way.** BTT's stock image passed two bench runs without a stall by luck; the
  reproducer stalls it in the second run. A newer kernel does not fix it (7.2.8 stalled hardest). BTT's one memory
  tweak (`vm.swappiness=100` in `/etc/sysctl.conf`) is not even applied: Debian 13's systemd no longer reads that file.
- **The only switch that removes it, `vm.compact_unevictable_allowed=0`, protects locked memory only.** PREEMPT_RT
  kernels default to 0 for this reason. Its cost is slightly worse memory fragmentation, which can make large contiguous
  allocations (huge pages, display/camera CMA buffers) fail or take longer.
- **KOS does not set it.** Nothing in a running printer locks its memory (Klippy: 0 kB locked, 57 MB resident), so it would
  change nothing for printing and would only make the benchmark tool's numbers look better. Klippy's unlocked pages can be
  moved or swapped at any time on every OS, KOS included; protecting them would mean patching Klipper to call `mlockall`,
  which this project will not carry (decision 2026-10-21).
- **The CM5 (4 GB) bench runs never showed it** (load max 68-206 µs). The reproducer was not run there; with four times
  the RAM, the same load should rarely push the kernel into compaction, but that is untested.
- **The 1 s motion buffer is why it does not matter.** Klippy only needs to keep the MCU's queue ahead of the toolhead; a
  pause of tens of milliseconds is invisible to the print. It would matter for software that must react within a few
  milliseconds on the host, which Klipper's design deliberately avoids.

**Measurement note:** `bench_on_device.sh` runs `cyclictest --policy=other -p 0`, but the measuring thread actually runs
`SCHED_FIFO` priority 2 (cyclictest defaults the priority to 2 and switches to FIFO; checked with `chrt`). Every run on every
image used the same flags, so comparisons hold; the numbers are for a low-priority realtime thread, not a normal one.

Each row below links its raw JSON. "Not clean" footprints are excluded from footprint comparisons.

| Date | Label | Host | Boot (s) | Klippy ready (s) | RAM used (MB) | Services | SD idle (MB/h) | Jitter under load p99 / max (µs) | Directory listing, 1,234 files (s) | Loop blocks | JSON |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-21 | kos on Armbian `edge` kernel 7.2.8 (on-device swap from 6.18.44, 3 warm reboots; footprint not clean) | CB1 | 14.23 | 23.5 | 216 | 20 | 2.3 | 81 / 226 | 3.36 (metadata 1081 s) | 1 | [json](bench/results/2026-10-21-cb1-kos-edge72-warm1.json) |
| 2026-10-20 | kos (new build: kos-tune `ethernet` match; 3 warm reboots, footprint clean) | CB1 | 14.46 | 24.0 | 206 | 20 | 2.0 | 83 / 8342** | 3.42 (metadata 1081 s) | 1 | [json](bench/results/2026-10-20-cb1-kos-newbuild-warm1.json) |
| 2026-10-20 | **stock-tuned** (BTT image + stock_prep.sh + stock_tune.sh incl. cpufrequtils governor and 30 s kos-tune timer, 3 warm reboots; footprint not clean) | CB1 | 23.45 | 34.4 | 331 | 27 | 3.4 | 114 / 448 | 3.63 (metadata 1190 s) | 1 | [json](bench/results/2026-10-20-cb1-stock-tuned-warm1.json) |
| 2026-10-20 | **stock** (BTT CB1 image 3.1.0-26.05.0, kernel 7.0.2-vendor, + stock_prep.sh, 3 warm reboots, footprint clean) | CB1 | 25.35 | 34.4 | 320 | 27 | 4.3 | 168 / 1196 | 3.50 (metadata 1189 s) | 1 | [json](bench/results/2026-10-20-cb1-stock-warm1.json) |
| 2026-10-20 | kos (kos-cb1-20261020, Sindri config, 3 warm reboots; repeat run, footprint not clean) | CB1 | 14.46 | 23.6 | 209 | 20 | 1.9 | 88 / 232 | 3.39 (metadata 1164 s) | 1 | [json](bench/results/2026-10-20-cb1-kos-warm2.json) |
| 2026-10-20 | **kos** (kos-cb1-20261020, Sindri config, 3 warm reboots, footprint clean) | CB1 | 13.84 | 23.0 | 217 | 20 | 2.2 | 90 / 12771** | 3.39 (metadata 1166 s) | 1 | [json](bench/results/2026-10-20-cb1-kos-warm1.json) |
| 2026-10-19 | kos (am build, placeholder config, footprint not clean) | CM5 | 9.97 | n/a | 296 | 18 | 0.5 | 13 / 206 | invalid* | invalid* | [json](bench/results/2026-10-19-cm5-kos-am-placeholder.json) |
| 2026-10-20 | stock-tuned, warm repeat 1 | CM5 | 11.196 | 14.6 | 348 | 20 | 0.2 | 14 / 86 | 0.396 (metadata 154 s) | 0 | [json](bench/results/2026-10-20-cm5-stock-tuned-warm1.json) |
| 2026-10-20 | stock-tuned, warm repeat 2 | CM5 | 11.380 | 14.8 | 341 | 20 | 0.3 | 16 / 70 | 0.397 (metadata 157 s) | 0 | [json](bench/results/2026-10-20-cm5-stock-tuned-warm2.json) |
| 2026-10-20 | stock-tuned, warm repeat 3 | CM5 | 11.632 | 15.1 | 346 | 20 | 0.2 | 16 / 108 | 0.394 (metadata 155 s) | 0 | [json](bench/results/2026-10-20-cm5-stock-tuned-warm3.json) |
| 2026-10-20 | stock, after 3 warm reboots 2 min apart | CM5 | 11.216 | 14.6 | 327 | 20 | 0.2 | 51 / 834 | 0.397 (metadata 154 s) | 0 | [json](bench/results/2026-10-20-cm5-stock-warm1.json) |
| 2026-10-19 | **stock-tuned** (stock + stock_tune.sh incl. udev governor mask, cold boot 1; footprint not clean) | CM5 | 11.24 | 14.6 | 362 | 22 | 4.9 | 15 / 90 | 0.394 (metadata 154 s) | 0 | [json](bench/results/2026-10-19-cm5-stock-tuned-coldboot1.json) |
| 2026-10-19 | **stock** (Pi OS Lite trixie + stock_install.sh, Sindri config, cold boot 1, footprint clean) | CM5 | 11.54 | 15.0 | 350 | 21 | 5.6 | 50 / 895 | 0.393 (metadata 153 s) | 0 | [json](bench/results/2026-10-19-cm5-stock-coldboot1.json) |
| 2026-10-19 | kos (pm build, Sindri config, cold boot 2; footprint not clean) | CM5 | 9.93 | 10.9 | 335 | 21 | 4.3 | 16 / 92 | 0.389 (metadata for all 1,234 took 183 s) | 0 | [json](bench/results/2026-10-19-cm5-kos-pm-coldboot2.json) |
| 2026-10-19 | kos (pm build, Sindri config, cold boot 1; footprint not clean, use the first-boot row's) | CM5 | 10.79 | 16.8 | 325 | 20 | 2.9 | 15 / 68 | invalid* | invalid* | [json](bench/results/2026-10-19-cm5-kos-pm-coldboot1.json) |
| 2026-10-19 | kos (pm build, Sindri config, **first boot**: boot/ready not representative) | CM5 | 12.71 | 42.4 | 330 | 19 | 1.3 | 14 / 100 | invalid* | invalid* | [json](bench/results/2026-10-19-cm5-kos-pm-firstboot.json) |

\* Moonraker columns from the 2026-10-19 runs are invalid: the script waited only 30 s after indexing, so metadata
extraction (183 s for 1,234 files on a CM5) was still running when the listing was timed. Fixed in the script; cold
boot 2 is the first valid Moonraker number.

### Phase 2: the print

| Date | Label | Host | Result | Timer too close / shutdowns / stalls | sysload median / max | Klippy CPU | MCU srtt median / max (ms) | Retransmits | klippy.log written | JSON |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-21 | kos | CB1 | completed, 82.0 min printing / 84.9 min total | 0 / 0 / 0 | 0.26 / 1.39 | 13.5 % of one core (688 s) | mcu 1 / 3, nitehawk 0 / 1, host 0 / 1 | 0 B on all three | 7.92 MB (5.3 MB/h); journal 27.6 KB (RAM) | [json](bench/results/2026-10-21-cb1-kos-print.json) |
| 2026-10-20 | stock-tuned | CB1 | completed, 82.0 min printing / 83.8 min total | 0 / 0 / 0 | 0.79 / 2.61 | 14.8 % of one core (745 s) | mcu 1 / 3, nitehawk 0 / 1, host 0 / 1 | 0 B on all three | 7.82 MB (5.3 MB/h); journal 19.6 KB (volatile) | [json](bench/results/2026-10-20-cb1-stock-tuned-print.json) |
| 2026-10-20 | stock | CB1 | completed, 82.0 min printing / 84.5 min total | 0 / 0 / 0 | 0.59 / 1.28 | 17.2 % of one core (874 s) | mcu 1 / 3, nitehawk 0 / 1, host 0 / 1 | 0 B on all three | 7.88 MB (5.3 MB/h); journal 20.3 KB (volatile) | [json](bench/results/2026-10-20-cb1-stock-print.json) |
| 2026-10-19 | kos | CM5 | completed, 82.0 min printing / 85.0 min total | 0 / 0 / 0 | 0.03 / 0.63 | 1.9 % of one core | mcu 2 / 5, nitehawk 1 / 2, host 0 / 1 | 0 B on all three | 7.91 MB (5.6 MB/h); journal 16 KB, `/var/log` 0 | [json](bench/results/2026-10-19-cm5-kos-print.json) |
| 2026-10-19 | stock | CM5 | completed, 82.0 min printing / 84.4 min total | 0 / 0 / 0 | 0.12 / 0.54 | 3.7 % of one core (188 s; ondemand governor) | mcu 2 / 5, nitehawk 1 / 1, host 0 / 0 | 0 B on all three | 7.88 MB (5.6 MB/h); journal 3.7 KB (volatile on Pi OS too), nginx access 0.7 KB | [json](bench/results/2026-10-19-cm5-stock-print.json) |

Stock setup record (install logs, package list, services, boot config, Klipper unit): [`bench/results/2026-10-19-cm5-stock-setup/`](bench/results/2026-10-19-cm5-stock-setup/).

SD card writes over the same sequence (cold boot, Phase 1, print): KOS 139 MB in 1.92 h, stock 634 MB in 2.21 h. Not an
identical window; the script will measure it directly in a later version.
| 2026-10-19 | stock-tuned | CM5 | completed, 82.0 min printing / 84.3 min total | 0 / 0 / 0 | 0.03 / 0.40 | 1.95 % of one core (98.6 s) | mcu 2 / 5, nitehawk 1 / 2, host 0 / 0 | 0 B on all three | 7.86 MB (5.6 MB/h); journal 4.1 KB, nginx access 0.3 KB | [json](bench/results/2026-10-19-cm5-stock-tuned-print.json) |

SD writes over boot + Phase 1 + print: `kos` 139 MB / 1.92 h, `stock` 634 MB / 2.21 h, `stock-tuned` 200 MB / 2.37 h.
The stock figure likely includes a first-boot apt/PackageKit refresh after install, so treat all three as indicative.
