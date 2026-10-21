# KOS

> Named after Kos, the Greek island, as a nod to Klipper. Settled 2026-10-19 (was the working name "klipperOS").

A lightweight Debian 13 (trixie) image for running Klipper on **Raspberry Pi CM5** and **BigTreeTech CB1**, with CM4 as a build-only bonus target.

The goal, and the acceptance test for V1: flash the card, drop your existing `printer.cfg` on it, boot, and the machine is print-ready — CAN and USB toolhead boards found automatically, web UI on port 80, reachable at `http://<hostname>.local`.

> **Status: unreleased.** The **CM5** image boots and prints on real hardware (CM5 Lite on a BTT Manta M5P, 2026-10-19; see [PLAN.md §21.6](PLAN.md#216-hardware-log-first-boots-2026-10-19) and [BENCHMARKS.md](BENCHMARKS.md)). The **CB1** image builds and passes offline inspection but **has not been booted yet**. See [PLAN.md §21](PLAN.md#21-implementation-status) for exactly what is verified and what is not.

## What's in it

| | |
|---|---|
| Base | Debian 13 (trixie), arm64, writable root, working `apt` |
| Kernel | Raspberry Pi `linux-image-rpi-2712` + `-v8` (CM5/CM4) · Armbian `linux-image-current-sunxi64` (CB1) |
| Printer stack | Klipper, Moonraker, Mainsail, nginx — git checkouts so Moonraker's `update_manager` works |
| Tuning | `isolcpus=3` + `CPUAffinity=3` on Klippy, `performance` governor, IRQs steered off the isolated core, zram swap, logs in RAM |
| Not included | Xorg/GTK/KlipperScreen, DSF/RRF, camera stack by default, MCU toolchain, A/B root, OTA |

Image size: ~3.5 GB written, rootfs ~1.3 GB.

## Quick start

1. Grab `kos-<board>-<date>.img.xz` from [Releases](../../releases) and write it with Raspberry Pi Imager, balenaEtcher, or `xz -dc image.img.xz | sudo dd of=/dev/rdiskN bs=4m`.
2. The card mounts a small FAT partition labelled **KOS** on any OS. Edit `kos.conf` on it — hostname, Wi-Fi, timezone, CAN bitrate, display.
3. Optionally put your config on the same partition, next to `kos.conf`: a single `printer.cfg`, your `config/` folder, or a whole `printer_data/` folder (so the path reads `KOS/printer_data/config/printer.cfg`).
4. Boot. Open `http://<hostname>.local`.

`kos.conf` is re-read on **every** boot, so changing Wi-Fi or hostname later means editing the card, not re-flashing.

### MCU discovery

A config copied from another machine names its boards by serial or CAN UUID, and those strings don't survive the move. On each boot, before Klipper starts, KOS scans `*.cfg` for `serial:`/`canbus_uuid:` values that no longer resolve and rewrites them in place from the boards actually attached. Your section names, pin references and comments are untouched, and the original is kept as `<file>.orig`.

It refuses to guess: if two candidate boards could fit one slot, nothing is written and `MCU-DISCOVERY.txt` lands on the FAT partition listing what it saw. Pin the answer with `main_mcu_serial=` / `toolhead_uuid=` in `kos.conf`.

### Gcode archiving

A large flat gcode root is the single biggest cause of Fluidd/Mainsail "failed to connect, retry" prompts: on a CB1 with 1,234 files, one directory listing burns 4.4 s inside Moonraker's event loop and the websocket keepalive dies behind it. KOS files successfully printed jobs into `Printed/YYYY/MM/` via Moonraker's own move API, keeping every directory small. `archive_printed=off` disables it; `kos-archive --backfill --dry-run` previews the fix for an existing library. Measurements in [PLAN.md §17](PLAN.md#17-gcode-library-management--archive-printed-files).

## Building

Needs Docker with arm64 emulation. About 35 min per board on an x86 Mac, mostly pip under qemu.

```sh
build/build.sh cb1      # or: cm5
# → out/kos-cb1-<date>.img
```

Tagging `v*` builds both boards on GitHub Actions (native arm64 runners) and attaches the compressed images to a release. `.github/workflows/build.yml` also runs on `workflow_dispatch`.

Everything checkable without hardware:

```sh
sh tests/run.sh              # shell syntax, three Python self-tests, config parser
sh tests/mkimage_docker.sh   # real mkfs/sfdisk round-trip, needs Docker
sh tests/inspect_image.sh out/kos-cb1-*.img
```

## Repository layout

| Path | What |
|---|---|
| `PLAN.md` | The design document: every decision, why, what's still open, implementation status |
| `TEARDOWN.md` | Reverse-engineering notes on Mellow's FlyOS-Fast, which this project started from |
| `build/` | `build.sh` (host wrapper) → `in-container.sh` (mmdebstrap) → `customize.sh` (chroot) → `mkimage.py` (partitioning, no loop devices) |
| `build/boards/{cb1,cm5}/` | The only board-specific code: kernel packages, boot files, partition layout |
| `build/config-partition/` | The `kos.conf` template shipped on the FAT partition |
| `overlay/` | Files copied verbatim into the rootfs: systemd units, fstab, nginx, and the `kos-*` tools |
| `analysis/` | FlyOS teardown output — vendor scripts/units/configs extracted, and three patch sets vs upstream |
| `tests/` | The no-hardware gate |
| `research/`, `out/` | Untracked: the source `.img` extract and build artifacts |

## Credits

Built on the work of others, none of it affiliated with this project:

- **[Klipper](https://github.com/Klipper3d/klipper)** (Kevin O'Connor), **[Moonraker](https://github.com/Arksine/moonraker)** (Eric Callahan), **[Mainsail](https://github.com/mainsail-crew/mainsail)** (mainsail-crew) — the printer stack.
- **[Armbian](https://github.com/armbian/build)** — the CB1 kernel, U-Boot, DTBs and boot script. The `boot-sun50i-next.cmd` script and the sunxi U-Boot write offset are taken from their build system.
- **[Raspberry Pi](https://github.com/raspberrypi/rpi-image-gen)** — `raspi-firmware`, the CM5/CM4 kernels, and the boot-partition layout, which follows `rpi-image-gen`'s Pi layer.
- **[Debian](https://www.debian.org/)** and **[mmdebstrap](https://gitlab.mister-muffin.de/josch/mmdebstrap)** — the base system and the builder.
- **Mellow's FlyOS-Fast** — not used as code (it's 32-bit Buildroot), but its design was the starting point. The provisioning-file-on-a-FAT-partition idea, the CAN `.network`/`.link` files, the mount options and the real-time pinning all come from reading their image. See [TEARDOWN.md](TEARDOWN.md).
- The **[mainline-Armbian-on-CB1](https://github.com/armbian/build/pull/9584)** community reports, for the CAN queue-length and Wi-Fi power-save findings.

KOS's own scripts deliberately do **not** copy FlyOS's network posture: no baked-in root password, no unauthenticated root shell on a TCP port, no `trusted_clients: 0.0.0.0/0`.

## Known tradeoffs

- **Writable root.** A power cut mid-`apt` can corrupt the image. That is the price of having `apt` at all; FlyOS's read-only SquashFS + A/B answer is deferred to V2, and the fixed-size root plus separate data partition is there so V2 can adopt it without re-imaging anyone.
- **CM4 is built but untested** — no hardware here.
- **Wi-Fi on CB1** rides an out-of-tree Realtek RTL8189FS driver. Wired ethernet is the safe path for first boot.

## License

Copyright © 2026 Brandon Doster.

**[GNU AGPL-3.0-or-later](LICENSE)** — copyleft with the network clause. Modify it, ship it, run it as a service: the modified source has to be available to whoever uses it, with attribution intact.

Scope: the build system (`build/`), the shipped scripts and units (`overlay/`), and the documentation in this repository. Everything listed under Credits stays under its own license and is fetched at build time, not vendored here — Klipper, Moonraker and Mainsail are GPL-3.0, which AGPL-3.0 combines with cleanly. The material in `analysis/` is reverse-engineering notes on a third-party image, not redistributable code. The benchmark print in `bench/fixtures/` is a third-party model under CC BY-NC-SA, not AGPL; see [`bench/fixtures/LICENSE.md`](bench/fixtures/LICENSE.md).
