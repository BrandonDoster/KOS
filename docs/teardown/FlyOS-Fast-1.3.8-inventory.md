# FlyOS-Fast H3 v1.3.8 — image inventory and customization analysis

Source artifact: `FlyOS-Fast-H3-v1.3.8.img.7z` (1.11 GiB compressed → 2.16 GiB raw image)
Image build stamp: `v1.3.8-g991092eae1`, `BUILD_TIME=2026-05-13 03:49:03`
Vendor: Mellow (`https://mellow.klipper.cn/`)
Target hardware: Allwinner H3 (sun8i), armv7 hard-float — Fly-Pi class boards (Fly Lite2 / Lite2.1 / MiniPad)

Everything below was read directly out of the image. Nothing is inferred from vendor documentation, because none was published.

---

## 1. How the image was opened

No mounting is required. 7-Zip understands MBR, ext2/3/4 and SquashFS, so the whole image can be unpacked on macOS:

```sh
brew install sevenzip
7zz x FlyOS-Fast-H3-v1.3.8.img.7z         # → FlyOS-Fast-H3-v1.3.8.img
7zz x FlyOS-Fast-H3-v1.3.8.img -oparts    # → parts/0.img … parts/4.img
7zz x -orootfs parts/2.img                # → full root filesystem
7zz x -oboot0 parts/0.img                 # → kernel, dtbs, boot.scr
7zz x -oboot1 parts/1.fat                 # → /config partition (config.txt)
```

Caveat: 7-Zip does not restore symlinks (363 were skipped for the rootfs). Symlinked files such as `/etc/os-release` appear as empty files in the extract; the real content is in the link target (`/usr/lib/os-release`).

## 2. Partition and boot layout

MBR (msdos) label, 512-byte sectors:

| Part | Size | FS | Mount | Purpose |
|------|------|----|-------|---------|
| p1 | 32 MiB | ext4 | `/boot` | `zImage`, `fly-h3.dtb`, `dtbs/*.dtbo`, `boot.scr` |
| p2 | 128 MiB | FAT16 | `/config` | user-editable `config.txt`, `.is_first` marker, optional `printer_data/` seed |
| p3 | 1 GiB | SquashFS (zstd) | `/` | rootfs slot A |
| p5 | 1 GiB | SquashFS (zstd) | — | rootfs slot B (byte-identical to A in a fresh image) |
| p6 | 1 MiB | ext4 | `/overlay` | userdata; grown to fill the card on first boot |

This is an A/B, read-only-root design:

- U-Boot `boot.scr` sets `root_dev=PARTLABEL=rootfs`, `rootfstype=squashfs`, `init=/sbin/flyos-init`, and knows `devnum_rootfs_a=:3`, `devnum_rootfs_b=:5`, `devnum_userdata=:6`.
- `boot.scr` also loads `dtbs/sun8i-h3-*.dtbo` overlays chosen from `config.txt` (`overlays=uart1 usbhost2 usbhost3` by default, plus screen/rotation overlays).
- `/sbin/flyos-init` (POSIX shell, 214 lines) runs before systemd. It:
  1. reads `root=`/`rootfstype=` from `/proc/cmdline`;
  2. finds the userdata partition (`p6`), and if it is ≤ 4 GiB, rewrites the partition table with `fdisk` to consume the rest of the card and `mkfs.ext4`s it — this is the first-boot expansion;
  3. mounts it at `/overlay`;
  4. bind-mounts `/overlay/var/lib/NetworkManager` and `/overlay/var/lib/systemd`;
  5. overlayfs-mounts `/etc`, `/data`, `/root`, and then either `/usr/share/printer_data` (when `printer=klipper`) or `/opt/dsf` (when `printer=rrf`), with upper/work dirs under `/overlay/<path_with_underscores>/`;
  6. `exec /sbin/init` (systemd).
- Escape hatch: kernel arg `noro=1` skips the overlay entirely and remounts root rw; `show_overlay=1` moves `/overlay` to `/mnt/overlay` so it is inspectable.

Consequence for anyone rebuilding: the root filesystem is immutable by design, and every persistent change lives in the ext4 overlay upper dirs. That is the single biggest structural difference from a normal Armbian/Debian Klipper host.

## 3. Base distribution

**Buildroot** (not Armbian, not Debian, not OpenWrt/OpenEmbedded). Evidence:

- `libc.so.6` banner: `GNU C Library (Buildroot) stable release version 2.38.`
- `/etc/passwd` is verbatim the Buildroot skeleton (`operator:x:37:37:Operator:/var:/bin/false`, `dbus:...:DBus messagebus user`, plus Buildroot package users `dhcpcd`, `ntp`, `polkitd`).
- No package manager or package DB anywhere: no `dpkg`, `opkg`, `apk`, `rpm` database. Software is baked into the SquashFS.
- `/usr/share/gcc-12.3.0`, BusyBox 1.36.1 (built `2025-10-29`), Python 3.11 — the default versions of the Buildroot 2023.11 / 2024.02 LTS series.
- systemd is 257.7 (much newer than that Buildroot series ships), so the vendor is carrying at least a bumped systemd package, i.e. a customized Buildroot tree rather than a stock release.

Release identity files (`/etc/os-release` is a symlink to `/usr/lib/os-release`):

```
PRETTY_NAME="FlyOS-Fast v1.3.8"; NAME="FlyOS-Fast"; VERSION_ID="1.3.8"
VERSION="v1.3.8-g991092eae1"; ID="flyos-fast"; ID_LIKE="flyos"
HOME_URL="https://mellow.klipper.cn/"; BUILD_TIME="2026-05-13 03:49:03"
```
`/etc/lsb-release` repeats this as `DISTRIB_ID="FlyOS-Fast"`; `/etc/base-release` says `FlyOS-Fast Linux release`. `ID_LIKE=flyos` implies an older/parallel "FlyOS" (non-Fast) tree; "Fast" is the SquashFS/A-B variant.

The `-g991092eae1` suffix is a `git describe` of the vendor's own build repo, which is not published.

## 4. Kernel

- `5.10.85-v3.0-flyos`, `vermagic = 5.10.85-v3.0-flyos FLY SMP mod_unload ARMv7 thumb2 p2v8`
- Allwinner H3 BSP-style tree (`sun8i-h3-*` overlays match the Armbian sunxi-DT-overlays naming), local version `-v3.0-flyos`, `CONFIG_LOCALVERSION` includes `FLY`.
- 2,696 modules shipped — essentially "build everything as a module".
- One out-of-tree module: `extra/flyos-info.ko`, `description = FlyOS System Information Module`, author `FlyOS`, GPL.
- Device tree: `fly-h3.dtb` plus 42 overlays covering the Fly TFT V1/V2, MiniPad (resistive and capacitive), Lite2.1 screens at 0/90/180/270°, i2c0-2, uart1-3, usbhost0-3, spidev, pwm, w1-gpio, analog codec, CIR.

Kernel source is not in the image (no `/lib/modules/*/build`, no `configs.ko`, banner not recoverable from the compressed `zImage`).

## 5. Userland inventory

Saved alongside this report:

- `userland-binaries.txt` — 979 entries from `/usr/bin` + `/usr/sbin`
- `shared-libs.txt` — 556 versioned shared libraries
- `python-site-packages.txt` — 154 entries in `/usr/lib/python3.11/site-packages`
- `rootfs-list.txt` — all 44,555 paths in the rootfs

Notable versions:

| Component | Version |
|---|---|
| glibc | 2.38 (Buildroot) |
| BusyBox | 1.36.1 |
| systemd | 257.7 |
| Python | 3.11 |
| nginx | 1.26.3 |
| Caddy | v2 |
| OpenSSH | 10.0 (sshd) |
| NetworkManager | 1.52.1 |
| ttyd | 1.3.0 (web terminal, see §9) |
| Also present | ffmpeg, mpv, ustreamer, mjpg_streamer, v4l-utils, hostapd, wpa_supplicant, udhcpd, ntpd, polkit, Xorg + GTK3 stack, git, gcc-arm-none-eabi (in `/opt`) |

Python packages of note (system site-packages, no wheels/venv baked in): numpy, scipy, matplotlib, Pillow, tornado (both 6.2 and 6.5.2 present), msgspec, msgpack, uvicorn, uvloop, zeroconf, python-can, pyserial, pyserial-asyncio, GitPython, PyGObject, sdbus-networkmanager, dbus-fast, dbus-next, streaming-form-data, preprocess-cancellation, zstandard, lmdb, libnacl, jinja2, distro, psutil, pyudev.

`/usr/lib/flyos/flyos-init-venv` creates `/data/klippy-env`, `/data/moonraker-env`, `/data/klipperscreen-env` on demand and then just copies the system site-packages into them — the venvs are cosmetic, for compatibility with tools that expect them. In the shipped units, Klipper/Moonraker/KlipperScreen all run under `/usr/bin/python` directly, not a venv.

## 6. 3D-printing stack shipped in `/data`

| App | Version / provenance |
|---|---|
| Klipper | snapshot of upstream master ≈ `02cfc65e` (2026-05-07), patched (see §7) |
| Moonraker | snapshot ≈ `9008485` (2026-05-07), patched |
| KlipperScreen | snapshot ≈ `3fab8d60` (2026-05-13), patched |
| Fluidd | v1.36.4 (`release_info.json`) |
| Mainsail | v2.17.0 (`release_info.json`) |
| Crowsnest | 4.2.0 |
| Katapult | matches upstream, no additions |
| klippain-shaketune | vendored, symlinked into `klipper/klippy/extras/shaketune` |
| moon2uart | Mellow's own Moonraker-to-UART bridge (optional, `m2u_port`/`m2u_baud` in config.txt) |
| DSF (Duet Software Framework) | `/opt/dsf` with `duetcontrolserver`, `duetwebserver`, `duetpluginservice`, board configs for fly-c5, c5-v1.1, c8, c8p — the RRF alternative firmware path |

All git metadata was stripped (no `.git` anywhere), so Moonraker's update manager cannot operate — consistent with the read-only-root/OTA model.

Klipper printer data lives at `/usr/share/printer_data` (not `~/printer_data`), and `moonraker.conf` uses `klippy_uds_address: /usr/share/printer_data/comms/klippy.sock`, `provider: systemd_cli`, a `trusted_clients` list that trusts every address, and `cors_domains` open to every origin.

## 7. Vendor source modifications

Patches were generated as image vs. the closest-matching upstream commit. They are not in this repository; [`flyos-glue.md`](flyos-glue.md#vendor-patches) describes what each one changes:

- Klipper — 28 files, 89 hunks, vs `02cfc65e`
- Moonraker — 4 files, vs `9008485`
- KlipperScreen — 39 files (excluding locales), vs `3fab8d60`

The upstream commit for each was chosen by minimizing the number of differing files across the April–May 2026 window, so the residual diff is mostly vendor work rather than version drift. A handful of hunks will still be drift; treat the patches as a starting point, not a certified patch series.

### Klipper

Added files (not upstream at all):

- `klippy/extras/power_loss_resume.py` — power-loss recovery, with its macros in `/usr/share/printer_data/config/plr.cfg`
- `klippy/extras/filament_blockage_detection.py` + `src/filament_blockage_detection.c` — MCU-side blockage detection, Mellow-branded
- `klippy/extras/led_effect.py` — the julianschill LED-effect plugin, vendored
- `klippy/extras/shaketune` — klippain Shake&Tune, vendored
- `klippy/chelper/c_helper.so` — prebuilt, so the host does not compile chelper at boot

Modified files, in rough order of significance:

- `klippy/extras/virtual_sdcard.py` — heavily rewritten (hundreds of added lines) to support power-loss resume state tracking
- `klippy/extras/probe_eddy_current.py` — substantially reworked
- `klippy/clocksync.py`, `klippy/mcu.py`, `klippy/serialhdl.py`, `klippy/msgproto.py`, `klippy/chelper/__init__.py`, `klippy/reactor.py`, `klippy/webhooks.py`, `klippy/util.py`, `klippy/queuelogger.py`, `klippy/klippy.py` — host/MCU communication and startup changes
- `klippy/extras/heaters.py`, `verify_heater.py`, `input_shaper.py`, `shaper_calibrate.py`, `tmc.py`, `tmc_uart.py`, `kinematics/extruder.py`
- MCU firmware side: `src/Makefile`, `src/adccmds.c`, `src/basecmd.c`, `src/sched.c`, `src/generic/armcm_timer.c`, `src/generic/timer_irq.c`
- `scripts/buildcommands.py`, `scripts/stepstats.py`

Because `mcu.py`/`serialhdl.py`/`src/*.c` are all touched together, the host and the Fly board firmware are somewhat co-dependent — stock Klipper on a Fly MCU built from this tree (or vice versa) may not be a clean swap.

### Moonraker

- New component `components/fly_lcd.py` (enabled via `[fly_lcd]` in `moonraker.conf`) — talks to the Fly LCD.
- New component `components/network.py` (enabled via `[network]`) — network management endpoints, replacing what upstream keeps inside `machine.py`.
- `components/klippy_connection.py` — adds a TCP fallback (`klippy_tcp_address`, default `127.0.0.1:7126`) when the Klippy UDS does not exist.
- `components/machine.py` — SD card info no longer hardcodes `mmcblk0`; it resolves the root device via `findmnt`/`lsblk`, and the SD manufacturer ID table is extended (Panasonic, Toshiba, AData, Phison, Lexar, Silicon Power, Kingston, Patriot, Sony, SiliconGo).
- `components/file_manager/file_manager.py` — adds a `GET /server/files/bottompic` endpoint plus ~390 lines that render a G-code first-layer preview image with PIL.
- `components/application.py` — extra upload logging and an `OSError` handler on chunk writes (SD-full robustness).

### KlipperScreen

- New: `ks_includes/ota_client.py`, `ks_includes/widgets/ota_overlay.py` — in-UI OTA update flow tied to `flyos-fast-ota`.
- New: `panels/fly_lcd.py`, `panels/network_info.py`, plus `fly-lcd.svg` / `notification_important.svg` icons across all five themes.
- Modified: `screen.py`, `panels/base_panel.py`, `main_menu.py`, `menu.py`, `job_status.py`, `network.py`, `system.py`, `camera.py`, `move.py`, `extrude.py`, `temperature.py`, `zcalibrate.py`, `spoolman.py`, `gcodes.py`, `printer_select.py`, `ks_includes/config.py`, `functions.py`, `printer.py`, `KlippyRest.py`, `KlippyGtk.py`, widgets, the default menus (`main_menu.conf`, `print_menu.conf`, `splash_menu.conf`, `move_menu.conf`, `defaults.conf`) and every theme's `style.css`.

## 8. FlyOS-specific system glue

Custom binaries:

- `/usr/bin/flyos-fast-ota` — Go 1.25.3, statically linked, stripped. Runs as a permanent service. Embeds a full Vue/Element-Plus web UI and vendors `github.com/bodgit/sevenzip` and `github.com/gorilla/websocket`, i.e. it downloads and unpacks 7z OTA payloads and serves an update UI over websocket. `/data/public.pem` is the signature-verification key for those payloads.
- `/usr/bin/flyos-ver`, `/usr/bin/fly-flash` (+ `fly-flash.py`) — board firmware flasher, driven by `board=` in `config.txt`
- `/usr/bin/fly-psplash` — boot splash with a status label; scripts push progress strings into it
- `/usr/sbin/flyos-serial-autologin`

Shell glue in `/usr/lib/flyos/` (all readable, all bash/sh; each one is described in [`flyos-glue.md`](flyos-glue.md#scripts)):

`flyos-init` (pre-systemd, §2), `flyos-config`, `flyos-firstrun`, `flyos-mounts`, `flyos-automount`, `flyos-blk-links`, `flyos-netinit`, `flyos-net-wait-online`, `flyos-nginx`, `flyos-caddy`, `flyos-display-init`, `flyos-psplash`, `flyos-resizefs`, `flyos-init-zram`, `flyos-init-swap`, `flyos-init-hard`, `flyos-init-venv`, `flyos-klippy-guardian`, `flyos-set-hostname`, `flyos-login-welcome`.

What `flyos-config` does at every boot: symlinks `/config/config.txt` into `/usr/share/printer_data/config/.flyos-config/sys-config.conf` so the web UI can edit it; `chattr +i`s `fluidd.cfg`/`mainsail.cfg` in the overlay so they cannot be modified; starts zram; sources `config.txt` and applies timezone, CAN bitrate (`sed` into `/etc/systemd/network/99-can.network`), board selection (`fly-flash -d $board -s`), and Wi-Fi via `nmcli` (creating a connection named "FlyOS wireless"). A hostapd/udhcpd AP fallback exists but is commented out in this build.

`flyos-firstrun` runs once (gated on `/config/.is_first`): rsyncs a user-supplied `/config/printer_data/` into `/usr/share/printer_data` (or `/opt/dsf/sd` for RRF), optionally flashes MCU firmware from the `firmware=` path, and initializes swap.

Services enabled (`/etc/systemd/system/*.wants`): klipper, klipper-mcu, moonraker, klipperscreen, crowsnest, moon2uart, nginx, ttyd, sshd, ntpd, acpid, dhcpd, NetworkManager (+ wpa_supplicant), xorg, polkit, the four DSF services, and flyos-{firstrun,config,netinit,bind,fast-ota,psplash,blk-links,mounts,display-init}, `first-setting`.

Config-driven gating is done with `ConditionKernelCommandLine=`: `klipper.service` and `moonraker.service` only start when `printer=klipper`, KlipperScreen only when `klipper_screen=1` and `screen!=none`, etc. `boot.scr` turns `config.txt` keys into kernel command-line arguments — that is the mechanism that makes a single image serve both Klipper and RRF and every screen variant.

Performance tuning worth noting: `klipper.service` runs with `CPUAffinity=3`, `Nice=-18`, `IOSchedulingPriority=2`; moonraker with `Nice=-18`. Klipper is started with `EnvironmentFile=/config/config.txt` and an `ExecStartPre` that pokes `fly-flash`.

## 9. Network surface as shipped

| Port | Service |
|---|---|
| 80 | nginx `default` site |
| 9080 | nginx → Fluidd (`root /data/fluidd`), proxying `/websocket` and `/(printer\|api\|access\|machine\|server)/` to moonraker |
| 9081 | nginx → Mainsail |
| 7125 | Moonraker, on all interfaces, trusting every address (authentication effectively off) |
| 8080-8083 | Crowsnest webcam streams |
| — | ttyd web terminal: a root login in the browser, no authentication of its own |
| 22 | OpenSSH 10.0 |

Caddy is present with `Caddyfile-f` / `Caddyfile-m` (fluidd/mainsail) selected by `flyos-caddy` from `klipper_webui=`, as an alternative to the nginx path.

Security posture, for the record: `ttyd`, `sshd`, `nginx`, `moonraker` and `flyos-fast-ota` are all enabled in `multi-user.target.wants`. Every shipped unit shares one root password, the web terminal puts that root login on the network with no authentication of its own, and Moonraker trusts every address. Any derivative of this image should get its own credentials, no web shell open to the network, and a real `trusted_clients` list before it touches a network you do not control. KOS ships no web terminal.

## 10. Reproducing this without the Mellow specifics

What is genuinely Mellow-proprietary and unavailable: the Buildroot external tree, the kernel tree (`5.10.85-v3.0-flyos`), `flyos-fast-ota` (Go source), `flyos-info.ko` source, `fly-psplash`, `fly-flash`, and the OTA signing key. GPL components (kernel, BusyBox, glibc-linked userland) are source-available on request in principle; nothing is published today.

What is fully readable from this image: every `/usr/lib/flyos/*` shell script, all systemd units, the nginx/Caddy configs, `boot.scr` (readable with `strings`), the device-tree overlays, and the three application patch sets ([`flyos-glue.md`](flyos-glue.md) describes them; they are not in this repository).

Two practical rebuild paths:

1. **Follow the same design.** A Buildroot external tree targeting sun8i-h3, plus the A/B SquashFS + overlayfs scheme, is reproducible from `flyos-init` alone — that script is the entire trick. Cost: you own a kernel and a toolchain forever.
2. **Drop the appliance model.** Armbian already supports sunxi H3 (and upstream Armbian has Mellow Fly C5 support merged), so a stock Armbian + KIAUH install gets Klipper/Moonraker/Fluidd running with a writable rootfs, real `apt`, and working Moonraker update manager — losing OTA, A/B rollback, the read-only root, the psplash flow, and `config.txt`-driven provisioning.

For your case (no Pi-clone-specific vendor customizations, plus your own additions), path 2 plus selectively cherry-picking from the patches above is the lower-maintenance option. The pieces most worth carrying over are `power_loss_resume.py` + the `virtual_sdcard.py` changes, `filament_blockage_detection`, and the Moonraker `machine.py` SD-device fix; `fly_lcd`, the OTA client, and the KlipperScreen theming are Fly-hardware-specific and can be dropped.

---

### Artifacts produced

| Path | Contents |
|---|---|
| `userland-binaries.txt` | 979 binaries in `/usr/bin` + `/usr/sbin` |
| `shared-libs.txt` | 556 versioned `.so` files |
| `python-site-packages.txt` | 154 site-packages entries |
| `rootfs-list.txt` | 44,555-path listing of the rootfs |
| `flyos-glue.md` | descriptions of the vendor's own files and the three patches (Klipper vs `02cfc65e`, Moonraker vs `9008485`, KlipperScreen vs `3fab8d60`); the files themselves are not kept |
| `rootfs/`, `boot0/`, `boot1/`, `env4/`, `parts/` | extracted filesystems (~5.4 GB total) |
