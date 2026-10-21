# KOS — FlyOS-Fast H3 v1.3.8 teardown

Reverse-engineering notes for Mellow's **FlyOS-Fast v1.3.8 (Allwinner H3)** image, with the goal of building an equivalent KOS without the Fly-hardware-specific customizations.

Mellow publishes no build docs, no Buildroot tree, and no kernel source for this image. Everything here was recovered from the shipped `.img`.

This is the archived research phase of the project. The design it fed into is [`docs/plan.md`](../plan.md); the image being built is described in the [project README](../../README.md).

**Start here:** [`FlyOS-Fast-1.3.8-inventory.md`](FlyOS-Fast-1.3.8-inventory.md) — the full inventory: partition layout, boot chain, base distro evidence, kernel, package set, per-app patch analysis, network surface, and two rebuild paths.

---

## Source artifact

| | |
|---|---|
| File | `FlyOS-Fast-H3-v1.3.8.img.7z` (1,189,690,236 bytes) |
| SHA-256 (`.7z`) | `12183cd72c71d2411db911ae7589f2d53c74cbab1cc80c0f14063ba976f1ad87` |
| SHA-256 (`.img`) | `d6540759ac2e0fd4a4b3c421d61c99c322c4f6cd5ad0c3185092f445c9a59c70` |
| Image version | `FlyOS-Fast v1.3.8-g991092eae1`, built 2026-05-13 03:49:03 |
| Target | Allwinner H3 (sun8i), armv7hf — Fly Lite2 / Lite2.1 / MiniPad |

The `.7z` is not tracked here (1.1 GB). Get it from Mellow's download page or copy it across; verify the SHA-256 above before trusting any of these notes against it.

## Repository layout

Small, worth keeping / committing (all in `docs/teardown/`):

| Path | What it is |
|---|---|
| `README.md` | this file |
| `FlyOS-Fast-1.3.8-inventory.md` | the main report |
| `flyos-glue.md` | what each of the vendor's own files does, and what the three vendor patches change (see below) |
| `userland-binaries.txt` | 979 binaries from `/usr/bin` + `/usr/sbin` |
| `shared-libs.txt` | 556 versioned shared libraries |
| `python-site-packages.txt` | 154 site-packages entries |
| `rootfs-list.txt` | all 44,555 paths in the root filesystem |

The vendor's files and the three patches (Klipper vs upstream `02cfc65e`, 28 files, 89 hunks; Moonraker vs `9008485`, 4 files; KlipperScreen vs `3fab8d60`, 39 files, locales excluded) are not in this repository. KOS does not ship vendor code; `flyos-glue.md` describes them instead, and both can be regenerated from the image with the steps below.

Large, regenerable, do not commit (≈8.4 GB total):

```
FlyOS-Fast-H3-v1.3.8.img   parts/   rootfs/   boot0/   boot1/   env4/
```

Those six paths are in `.gitignore`; the tracked notes stand on their own without them.

## The vendor's own files

These are the parts of the image that are *not* upstream anything: 21 shell scripts (most in `/usr/lib/flyos/`), 32 systemd units (two shipped disabled), udev rules, CAN and Ethernet network files, nginx and Caddy configs, the shipped `config.txt` and other default configs, the U-Boot script and the list of device-tree overlays, and the files the vendor added to Klipper, Moonraker and KlipperScreen. [`flyos-glue.md`](flyos-glue.md) describes each one: where it lived in the image, what it does, and its licence header if it has one.

## Reproducing the extraction on another machine

Only needs the `.7z` and 7-Zip. No mounting, no loopback, no Linux VM — 7-Zip reads MBR, ext4 and SquashFS directly.

```sh
brew install sevenzip                        # or: apt install p7zip-full  (use 7z instead of 7zz)

7zz x FlyOS-Fast-H3-v1.3.8.img.7z            # → .img  (2.16 GiB, ~6 s)
7zz x FlyOS-Fast-H3-v1.3.8.img -oparts       # → parts/0.img … 4.img
7zz x -orootfs   parts/2.img                 # rootfs   (SquashFS-zstd, 3.1 GB extracted)
7zz x -oboot0    parts/0.img                 # /boot    (zImage, fly-h3.dtb, dtbs/, boot.scr)
7zz x -oboot1    parts/1.fat                 # /config  (config.txt)
7zz l parts/2.img | tail -n +27 > rootfs-list.txt   # 44,555-path index; grep this first
```

Gotcha: 7-Zip does not restore symlinks (363 skipped). Symlinked files land as empty files — e.g. `/etc/os-release` is empty; read `/usr/lib/os-release` instead. Same for `/bin`, `/lib`, `/sbin`.

## Regenerating the vendor patches

The three patches are image-vs-upstream diffs. The upstream commit for each was picked by minimizing the count of differing files across the April–May 2026 window, so the residual is mostly vendor work rather than version drift — but a few hunks will still be drift. Treat them as a starting point, not a certified patch series.

```sh
mkdir -p /tmp/upstream && cd /tmp/upstream
git clone https://github.com/Klipper3d/klipper
git clone https://github.com/Arksine/moonraker
git clone https://github.com/KlipperScreen/KlipperScreen

git -C klipper       checkout 02cfc65e   # 2026-05-07
git -C moonraker     checkout 9008485    # 2026-05-07
git -C KlipperScreen checkout 3fab8d60   # 2026-05-13
```

Then diff each upstream tree against `rootfs/data/<app>/`. The scripted form used to produce the three patches:

```sh
IMG=/path/to/KOS/rootfs/data
cd /tmp/upstream/klipper
for f in $(git ls-files | grep -vE '^(docs|test)/'); do
  [ -f "$IMG/klipper/$f" ] || continue
  cmp -s "$f" "$IMG/klipper/$f" || diff -u "$f" "$IMG/klipper/$f" \
    --label "upstream/$f" --label "flyos/$f"
done
```

(`comm -13` between `git ls-files` and a `find` of the image tree gives the *added* files instead.)

## What the image actually is — one screen

- **Base: Buildroot**, not Armbian/Debian. `libc.so.6` reports `GNU C Library (Buildroot) stable release version 2.38`; `/etc/passwd` is the Buildroot skeleton verbatim; there is no package manager or package database anywhere. BusyBox 1.36.1 + gcc 12.3.0 + Python 3.11 point at the Buildroot 2023.11 / 2024.02 series, but systemd is 257.7 — so it's a customized tree with bumped packages, not a stock release.
- **Kernel:** `5.10.85-v3.0-flyos`, Allwinner H3 BSP-style, 2,696 modules, one out-of-tree module (`flyos-info.ko`). No source, no `/lib/modules/*/build`.
- **Root is read-only SquashFS with A/B slots.** p3 and p5 are 1 GB SquashFS-zstd (identical in a fresh image); p6 is ext4 userdata that `flyos-init` grows to fill the card on first boot, then overlayfs-mounts under `/etc`, `/data`, `/root`, and `/usr/share/printer_data` (or `/opt/dsf` for RRF). Kernel arg `noro=1` bypasses the whole thing.
- **`/config/config.txt` is the entire provisioning surface.** U-Boot turns its keys into kernel command-line args; systemd units gate on `ConditionKernelCommandLine=` (`printer=klipper`, `klipper_screen=1`, `screen!=none`, …). One image serves Klipper and RRF and every screen variant.
- **OTA:** `/usr/bin/flyos-fast-ota`, Go 1.25.3 static ARM binary, embeds a Vue/Element-Plus UI, unpacks signed 7z payloads verified against `/data/public.pem`. Stripped, no source — not reproducible.

### Installed software, versions

| Component | Version |
|---|---|
| glibc | 2.38 (Buildroot) |
| BusyBox | 1.36.1 |
| systemd | 257.7 |
| Python | 3.11 |
| nginx | 1.26.3 |
| Caddy | v2 |
| OpenSSH (sshd) | 10.0 |
| NetworkManager | 1.52.1 |
| ttyd | 1.3.0 |
| Klipper | upstream master ≈ `02cfc65e` (2026-05-07) + patches |
| Moonraker | ≈ `9008485` (2026-05-07) + patches |
| KlipperScreen | ≈ `3fab8d60` (2026-05-13) + patches |
| Fluidd | v1.36.4 |
| Mainsail | v2.17.0 |
| Crowsnest | 4.2.0 |
| Katapult | matches upstream, unmodified |
| klippain-shaketune | vendored into `klippy/extras/shaketune` |
| DSF / Duet | `/opt/dsf` — duetcontrolserver, duetwebserver, duetpluginservice; board configs for fly-c5, c5-v1.1, c8, c8p |
| Also | ffmpeg, mpv, ustreamer, mjpg_streamer, v4l-utils, hostapd, wpa_supplicant, udhcpd, ntpd, polkit, Xorg + GTK3, git, gcc-arm-none-eabi in `/opt` |

Python site-packages of note: numpy, scipy, matplotlib, Pillow, tornado (6.2 *and* 6.5.2), msgspec, msgpack, uvicorn, uvloop, zeroconf, python-can, pyserial(-asyncio), GitPython, PyGObject, sdbus-networkmanager, dbus-fast, dbus-next, streaming-form-data, preprocess-cancellation, zstandard, lmdb, libnacl, jinja2, distro, psutil, pyudev. Full list in [`python-site-packages.txt`](python-site-packages.txt).

Note: `flyos-init-venv` creates `/data/{klippy,moonraker,klipperscreen}-env` and just copies system site-packages into them. The venvs are cosmetic — the shipped units run `/usr/bin/python` directly.

### Their changes, indexed

**Klipper** — added `power_loss_resume.py`, `filament_blockage_detection.py` + `src/filament_blockage_detection.c`, vendored `led_effect.py` and shaketune, prebuilt `chelper/c_helper.so`. Modified: `virtual_sdcard.py` (heavily rewritten for PLR), `probe_eddy_current.py`, plus the host↔MCU path (`mcu.py`, `serialhdl.py`, `clocksync.py`, `msgproto.py`, `chelper/__init__.py`, `reactor.py`, `webhooks.py`) and MCU firmware (`src/sched.c`, `src/adccmds.c`, `src/basecmd.c`, `src/generic/armcm_timer.c`, `src/generic/timer_irq.c`, `src/Makefile`). Because host and firmware are patched together, mixing stock Klipper with Fly-built MCU firmware is not a guaranteed clean swap.

**Moonraker** — new components `fly_lcd.py` and `network.py` (enabled by `[fly_lcd]` / `[network]` in `moonraker.conf`). `klippy_connection.py` gains a TCP fallback (`klippy_tcp_address`, default `127.0.0.1:7126`). `machine.py` resolves the SD device via `findmnt`/`lsblk` instead of hardcoding `mmcblk0`, and extends the SD manufacturer table. `file_manager.py` adds `GET /server/files/bottompic` plus ~390 lines of PIL G-code first-layer preview rendering. `application.py` adds upload logging and an `OSError` handler.

**KlipperScreen** — new `ks_includes/ota_client.py`, `ks_includes/widgets/ota_overlay.py`, `panels/fly_lcd.py`, `panels/network_info.py`, plus `fly-lcd.svg` / `notification_important.svg` in all five themes. Modified `screen.py`, most panels, the default menu configs and every theme's `style.css`.

**Worth stealing for your own build:** `power_loss_resume` + the `virtual_sdcard` changes, `filament_blockage_detection`, and the Moonraker `machine.py` SD-device fix. **Safe to drop:** `fly_lcd` (both sides), the OTA client, the KlipperScreen theming — all Fly-hardware-specific.

## Security notes (before deriving anything from this image)

- Every shipped unit has the same root password.
- The image ships a web terminal with no authentication of its own in front of the root login. With the shared password, that is a root shell for anyone on the network.
- Moonraker listens on all interfaces and trusts every address and every origin, so its authentication is effectively off.
- Open services as shipped: SSH, nginx (Fluidd and Mainsail), Moonraker, Crowsnest webcam streams, and the web terminal.

Any derivative needs its own credentials, no web shell open to the network, and a real `trusted_clients` list before it goes on a network you don't control. KOS ships no web terminal and no root password.

## Where this went

The teardown answered its questions: the base distro is a customized Buildroot tree with no published source, the provisioning and real-time design is fully readable from the vendor's own scripts and units (described in [`flyos-glue.md`](flyos-glue.md)), and the vendor's application changes were extracted as patches.

Two paths were on the table at the end of the teardown — follow FlyOS's Buildroot + A/B SquashFS design, or drop the appliance model for a package-managed distro. **The project took the second, on different hardware:** Debian trixie on arm64 (CM5 / CB1), keeping the ideas worth keeping (FAT provisioning partition, CAN bring-up files, core isolation, mount options) and none of the binaries — the analyzed image is 32-bit armv7 H3, so only its shell, unit and config text was ever reusable. Reasoning in [`docs/plan.md`](../plan.md) §2, §5, §7, §10.

Adopted from this teardown: the `/config` FAT provisioning file, first-boot seeding of user data, the `99-can.network` / `99-can-link.link` settings ([network files](flyos-glue.md#network-files)), `noatime,nodiratime,commit=120,errors=remount-ro`, `isolcpus` + `CPUAffinity` + IRQ steering, logs off the card.

Dropped: `source`-ing the config file as root, the kernel-command-line provisioning route (no U-Boot on the Pi), the venvs that copy system site-packages, and the entire network posture (see the security notes above).

Loose ends, if anyone picks the reverse-engineering back up:

- Kernel provenance is unconfirmed. `5.10.85-v3.0-flyos` looks like an Allwinner/OrangePi 5.10 BSP tree, but the banner isn't recoverable from the compressed `zImage` and no config was shipped. GPL means Mellow owes source on request — worth asking them directly.
- The patch sets still contain some upstream drift. If a patch is going to be applied rather than read, pin the upstream commit more precisely first (bisect on file-hash equality rather than the date-window heuristic used here).
- `flyos-fast-ota` and `fly-flash` are the only vendor pieces with no readable source; `fly-flash.py` is present and readable, the Go OTA binary is not.
- `parts/3.img` (rootfs slot B) is byte-identical to slot A in this image and was not analyzed separately.
