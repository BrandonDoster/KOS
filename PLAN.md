# klipperOS — design plan (V1)

Concepts and decisions, not a build procedure. Where FlyOS-Fast already solved something, the reference points at the extracted file so the mechanism can be read rather than re-derived. Paths are relative to this repo; `analysis/flyos-glue/` survives deleting the 5.4 GB extract.

Last validated 2026-09-03 against the extracted image and upstream sources; see §19 for what was checked and what changed.

## 1. Goal

A very lightweight, Klipper-ready Debian image for **Raspberry Pi CM5** and **BTT CB1**, with CM4 as a bonus target (untestable here — no hardware).

**V1 is done when:** flash SD → boot → copy an existing `printer.cfg` onto the card → the machine is print-ready, with CAN and USB toolhead boards and controllers picked up automatically.

That acceptance test is the whole scope filter. Anything that doesn't serve it is V2.

Implied by the test but easy to forget: the user has no serial console and no known IP. The machine must be findable as `<hostname>.local` (mDNS) and the web UI must be up on port 80 with no further setup. See §11.

## 2. Base OS: Debian

Decided: Debian, because `apt` and `sudo` are required. This is a deliberate divergence from FlyOS, which is Buildroot with no package manager at all — no dpkg/opkg/apk, no package database anywhere (`analysis/FlyOS-Fast-1.3.8-inventory.md` §3). Their image is smaller and immutable; ours is maintainable and debuggable at 3am on a printer that won't home.

Consequences to accept up front:

- Size baseline, corrected: FlyOS's root is a 620 MB SquashFS-zstd (`7zz l parts/2.img` → Physical Size 620,195,840) that unpacks to **3.1 GB** on disk (`du -sh rootfs`). Of that, `/data/klipper` is 222 MB, `/data/katapult` 120 MB (a vendored `lib/`), modules 80 MB, plus Xorg/GTK, DSF and the ARM toolchain. An ext4 image is uncompressed, so the honest comparison is against 3.1 GB, not 620 MB. Target: **≤1.5 GB image, ≤400 MB RAM at idle**, measured every build.
- Debian's Python is fine: FlyOS proves the dependency set is modest — see `analysis/python-site-packages.txt` for exactly what Klipper + Moonraker + Crowsnest actually need at runtime (numpy, scipy, matplotlib, tornado, msgspec/msgpack, jinja2, libnacl, streaming-form-data, zeroconf, pyserial, python-can, distro, psutil, lmdb, preprocess-cancellation, paho-mqtt, dbus-fast, pyudev…). Nothing exotic. Klipper builds `chelper/c_helper.so` on first start, so `gcc`, `libffi-dev` and `python3-dev` stay in the image (FlyOS ships a prebuilt `.so` instead; we can't, because a git update would need the compiler anyway).
- Keep `apt` genuinely usable: don't do read-only root in V1 (see §7).

**Base suite: `trixie` (Debian 13).** The original draft said bookworm-unless-forced; that is stale. Trixie has been stable since August 2025, Raspberry Pi OS ships on trixie with kernel 6.12, and Armbian's CB1 images are trixie-based. Bookworm is now oldstable and buys nothing.

Kernels do not come from Debian on either board (§14): Raspberry Pi's `archive.raspberrypi.com` packages for CM5/CM4, Armbian's `linux-image-current-sunxi64` for CB1. Debian's own 6.12 kernel has partial BCM2712 support but not the RP1 peripheral chip, so it is not a usable fallback on CM5.

**Builder: `mmdebstrap` with hooks, one tree for both boards.** Raspberry Pi's own `rpi-image-gen` (official since 2025, mmdebstrap/bdebstrap underneath, YAML layers, ships a `trixie-minbase` config and CM5 examples) is the reference for the Pi side: copy its kernel/firmware/boot-partition layer rather than re-deriving it. CB1 gets the same rootfs plus Armbian's kernel and U-Boot `.deb`s. Do not adopt pi-gen or the full Armbian framework — each owns only one board and drags in its own desktop-oriented defaults. The only per-board delta is kernel + bootloader + DTB + boot-partition contents.

## 3. One image or two

Mechanically, one card *can* boot both:

- **CM5/CM4** — bootloader lives in SPI EEPROM; it reads firmware, kernel and DTB as *files* from the first FAT partition (`config.txt`, `cmdline.txt`, `kernel_2712.img` / `kernel8.img`).
- **CB1** — Allwinner H616 (sun50iw9 family; same die family as the H618 that FlyOS's own glue already special-cases, see `analysis/flyos-glue/scripts/flyos-blk-links:28-35`). The BROM loads the SPL from a *raw sector offset*: 8 KiB (sector 16) first, then 256 KiB (sector 512) on H616 — the 128 KiB fallback belongs to older sunxi parts. Armbian's CB1 config uses a **FAT** boot partition labelled `BOOT` (`BOOTFS_TYPE="fat"`), `boot.scr` + `armbianEnv.txt`, DTB `sun50i-h616-bigtreetech-cb1-sd.dtb`, overlay prefix `sun50i-h616`.

Those two mechanisms don't collide: raw sectors before the first partition vs. files inside a FAT partition, and both bootloaders are happy reading their files from the same FAT volume. A hybrid card is genuinely possible.

**Recommendation for V1: one build system, two artifacts.** The blocker isn't boot, it's everything downstream — two kernel packages, two module trees, two DTB sets, two `apt` sources for kernel upgrades (Raspberry Pi's vs Armbian's), and a doubled test matrix. A combined card is a fun V2 experiment; it is not on the path to "flash and print."

Design the rootfs so this stays cheap: everything board-specific lives behind a single `BOARD=` value resolved at first boot (from `/proc/device-tree/model`, not from the config file), and nothing else in the image branches on hardware. All three targets are arm64, so it is literally one rootfs. Note the analyzed FlyOS image is 32-bit armv7 (H3): nothing binary in it is reusable, only the shell/unit/config text.

## 4. What "very lightweight" means concretely

FlyOS is the baseline for what a full-featured vendor image costs: 979 binaries, 556 shared libraries, 2,696 kernel modules, an entire Xorg + GTK3 stack, gcc-arm-none-eabi in `/opt`, and the whole Duet/DSF stack alongside Klipper (`analysis/userland-binaries.txt`, `analysis/FlyOS-Fast-1.3.8-inventory.md` §5-6).

Cut list for V1:

- No Xorg/GTK/KlipperScreen (headless; screens are V2)
- No DSF/RRF path — Klipper only
- One web UI, not two. Fluidd unless there's a reason to prefer Mainsail; nginx serving static files is enough. FlyOS's `analysis/flyos-glue/web/sites-available/fluidd` is the standard upstream nginx site verbatim (proxy `/websocket` and `/(printer|api|access|machine|server)/` to Moonraker, `client_max_body_size 0`) — copy it. FlyOS ships both UIs plus both nginx *and* Caddy.
- No vendored toolchain — flashing MCU firmware is a build-host job, or an opt-in package
- Trim locales, docs, man pages, and the module tree to what the board actually has
- Camera stack (Crowsnest/ustreamer) is optional-by-default, not baked in
- Katapult: scripts only (`flashtool.py`), not the 120 MB vendored tree

Anti-pattern worth naming: FlyOS creates `/data/{klippy,moonraker,klipperscreen}-env` and then just copies system site-packages into them (`analysis/flyos-glue/scripts/flyos-init-venv`); the shipped units ignore the venvs and run `/usr/bin/python` directly. Either use real venvs or don't pretend — for a Debian base, real venvs per app (`--system-site-packages` over Debian's numpy/matplotlib to avoid compiling them) are the honest choice and cost little. Moonraker's `update_manager` also expects a venv path per app.

## 5. The provisioning surface

The single best idea in FlyOS: **a FAT partition the user can edit from any OS after flashing**, holding one plain-text config file that drives everything (`analysis/flyos-glue/config/config.txt`). Wi-Fi credentials, timezone, hostname, CAN bitrate, which UI, which screen — all set before first boot, no serial console, no SSH-then-fix dance. FlyOS mounts it `vfat … sync,umask=000` (`flyos-mounts:14`).

Adopt this. Three adjustments:

- **Don't name it `config.txt` on the Pi.** That name (and `cmdline.txt`) is owned by the Raspberry Pi firmware on the first FAT partition. Use a distinct name (`klipperos.conf`) and, ideally, a separate third FAT partition mounted at `/config`, so the firmware's file and ours never share a directory. The Pi firmware only reads the first FAT partition, so a second one is invisible to it. Keeps CM5 and CB1 identical.
- **Don't route settings through the kernel command line.** FlyOS imports `config.txt` into the U-Boot environment and forwards keys into `bootargs` (`analysis/flyos-glue/boot/boot.scr.txt:52-54, 124-125`), then gates services with `ConditionKernelCommandLine=` (`analysis/flyos-glue/systemd/klipper.service:7`). Elegant, but it depends on U-Boot — the Pi has no equivalent. The portable equivalent is a first-boot unit that parses the file and enables/disables units with `systemctl`, plus `EnvironmentFile=` for values services need at runtime (`klipper.service:21` shows the pattern).
- **Don't `source` it.** FlyOS runs `source "$fp_config"` as root (`flyos-config:145`, `flyos-firstrun:11`, `flyos-set-hostname:16`), so the config file is a root shell script. Parse `key=value` lines instead. The threat is low (whoever holds the card owns the machine anyway) but the parser is the same size and doesn't break on a stray `$`.

Also worth copying: seeding user data from the FAT partition on first boot. FlyOS rsyncs `/config/printer_data/` into place once and deletes the marker (`analysis/flyos-glue/scripts/flyos-firstrun:3-21`; note it also `rm -rf`s the source dir at line 21 — rename it to `printer_data.imported/` instead so the user's original survives). That is exactly the "copy an existing cfg file over" half of the V1 acceptance test — the user drops `printer.cfg` on the FAT partition from their laptop and it lands in `printer_data/config` on boot.

## 6. First-boot flow

Conceptually: expand → seed → identify → configure → start.

- **Expand.** FlyOS hand-rolls partition expansion with scripted `fdisk` before systemd starts (`analysis/flyos-glue/scripts/flyos-init:39-102`) because Buildroot gave it nothing better. On Debian: `growpart` (package `cloud-guest-utils`, one line, works on MBR and GPT) in a oneshot unit, then `x-systemd.growfs` in `fstab` for the filesystem. `systemd-repart` is the nicer tool but is **GPT-only**; it becomes an option only if the GPT decision in §15 goes that way.
- **Seed.** Copy user files from `/config`, regenerate SSH host keys and machine-id (FlyOS: `flyos-set-hostname:6`), set hostname (`flyos-set-hostname:40-46`), apply timezone and Wi-Fi from the config file (`flyos-config:60-76` and `:159-202`; Wi-Fi via `nmcli`, creating a connection named "FlyOS wireless" with `autoconnect-priority -999`).
- **Identify.** MCU discovery — the interesting part, §8.
- **Configure/start.** Enable the units the config file asked for; drop the first-boot marker.

Everything here is an ordinary systemd unit ordered before `klipper.service`. No custom `init=` — FlyOS needs one only because the overlay has to exist before systemd does.

## 7. Durability vs. writability

FlyOS's answer to "printers lose power mid-write": read-only SquashFS root, everything mutable in an overlayfs on a separate ext4 partition, plus A/B root slots (`analysis/flyos-glue/scripts/flyos-init:153-196`, inventory §2). It's a good answer, and it is fundamentally incompatible with `apt install` on a running machine.

**V1: writable root, mitigations only.**

- Mount options, as FlyOS does them: root/userdata `noatime,nodiratime,commit=120,errors=remount-ro` (`flyos-init:18,120`), boot `commit=360` (`flyos-mounts:10`), config FAT `sync` (`flyos-mounts:14`)
- Logs off the card: journald `SystemMaxUse=20M` and `/var/log` on a 50 MB zram ext4 (`flyos-init-zram:47,71-76`); zram swap at 50% of RAM (`flyos-init-zram:33-38`). On Debian this is `zram-tools` + a `journald.conf` drop-in, not a script. FlyOS's file-swap script is a no-op (`flyos-init-swap` is fully commented out).
- Keep the partition layout *A/B-shaped anyway* — leave an unused slot-B-sized gap and a separate data partition — so V2 can adopt overlay/A-B without re-imaging users
- Their `chattr +i` trick to protect UI-managed configs from being clobbered (`flyos-config:95-118`) is worth remembering but not V1

State the tradeoff in the README when shipping: a hard power cut mid-`apt` can still corrupt this image. That's the price of `apt`.

## 8. "Instantly print ready" — the MCU identity problem

This is the actual hard requirement, and neither FlyOS nor stock Klipper solves it. A `printer.cfg` copied from another machine contains `[mcu] serial: /dev/serial/by-id/usb-Klipper_stm32f446xx_XXXX-if00` or `canbus_uuid: abc123…`, and those strings are machine-specific. Copying the file to new hardware breaks exactly there.

Facts that shape the design:

- `/dev/serial/by-id/` names are already stable per physical board: Klipper and Katapult firmware report the chip's unique ID as the USB serial number. Stability across reboots is free; the udev symlinks below are for *role* naming, not stability.
- A main board running Klipper's USB-to-CAN bridge mode appears as a `gs_usb` CAN adapter **and** as a CAN node with its own `canbus_uuid`. Its `[mcu]` section then uses `canbus_uuid:`, not `serial:`. Discovery must handle both.
- `scripts/canbus_query.py` (and Katapult's `flashtool.py -q`) only get answers from MCUs that are **not currently connected** to a Klipper instance. Discovery therefore has to run before `klipper.service`, and on-demand re-discovery has to stop Klipper first.

Design concept for V1:

- **Own the `[mcu]` sections.** A first-boot (and on-demand) discovery service enumerates `/dev/serial/by-id/usb-Klipper_*` and `usb-katapult_*`, queries the CAN bus for UUIDs, then *generates* `mcus.cfg` containing the `[mcu]` / `[mcu toolhead]` blocks. The user's `printer.cfg` keeps everything else and gains one `[include mcus.cfg]`. The seeding step comments out existing `[mcu*]` blocks in the imported file and reports what it did. Klipper's `SAVE_CONFIG` block must stay at the bottom of `printer.cfg`; includes elsewhere are fine.
- **Stable role names via udev.** Assign `/dev/klipper-main`, `/dev/klipper-toolhead0` from VID/PID + serial once a role is known, so `mcus.cfg` never has to change again. FlyOS's own rules are thin (`analysis/flyos-glue/udev/98-flyos-serial.rules` just maps non-8250 `ttyS*` to `/dev/serialN`; `97-flyos-usb.rules` handles the STM32 HID bootloader and USB storage automount) — there's little to copy, this is new work.
- **Report, don't guess.** When discovery finds two identical boards and can't tell which is the toolhead, write both into `mcus.cfg` commented with their descriptors and surface a clear message (Moonraker announcement + a file on `/config`). Silent wrong guesses are worse than a one-line manual edit. Heuristics that are usually right and can be offered as defaults: a lone USB Klipper device is the main MCU; a CAN node whose MCU type is a G0/G4/RP2040 class part alongside a larger F4/H7 main is the toolhead.
- Ambiguity resolution belongs in the config file too: let `klipperos.conf` pin `main_mcu_serial=` / `toolhead_uuid=` when the user already knows.

## 9. CAN bus

Neither CM5 nor CB1 has a native CAN controller, so this is USB (`gs_usb`: candleLight, BTT U2C, or a main board in bridge mode) or SPI (`mcp251x` / `mcp251xfd`). Verified: all three are `=m` in Raspberry Pi's `bcm2712_defconfig` and `bcm2711_defconfig` (rpi-6.12.y) and in Armbian's `linux-sunxi64-current.config`. No kernel work needed; just don't prune them.

Bring-up should be declarative, exactly as FlyOS does it:

- `analysis/flyos-glue/network/99-can.network`: `[Match] Name=can*` + `[CAN] BitRate=1000000, RestartSec=100ms`
- `analysis/flyos-glue/network/99-can-link.link`: `TransmitQueueLength=1024` — the queue-length bump that everyone otherwise discovers the hard way after random `Timer too close` errors. Klipper's docs say 128; FlyOS uses 1024; the CB1-on-mainline write-up that ran for months used 128. Either works, the default of 10 does not.
- Bitrate is user-settable and rewritten in place from the config file (`flyos-config:78-93`); it must match the toolhead firmware, so expose it prominently (FlyOS defaults to 1 Mbit)

Discovery (§8) should query CAN UUIDs after the interface is up, and ordering must guarantee that happens before `klipper.service` starts. If NetworkManager owns the box, still let `systemd-networkd` own `can*` (NM ignores CAN links) — that's what FlyOS does, both are enabled.

## 10. Real-time tuning — the highest-value thing to copy, with one correction

FlyOS pins Klippy to an isolated core:

- Kernel args: `nohz=on nohz_full=3 rcu_nocbs=3 isolcpus=3`, `cpufreq_default_governor=performance` (`analysis/flyos-glue/boot/boot.scr.txt:97-98`)
- Unit: `CPUAffinity=3`, `Nice=-18`, `IOSchedulingPriority=2` (`analysis/flyos-glue/systemd/klipper.service:14-16`), Moonraker at `Nice=-18`, `IOSchedulingPriority=2` (`moonraker.service:14-15`)
- IRQ steering away from the isolated core: USB, MMC and ethernet IRQs pinned to CPUs 1–2 by mask (`flyos-init-hard:27-32`)

Correction: **`nohz_full=` and `rcu_nocbs=` are inert on both stock kernels.** Neither Raspberry Pi's 6.12 defconfigs nor Armbian's sunxi64-current config set `CONFIG_NO_HZ_FULL` or `CONFIG_RCU_NOCB_CPU` (checked 2026-09-03; both have `CONFIG_NO_HZ=y` = idle-only, and `CONFIG_PREEMPT=y`). `isolcpus=3` works everywhere. What actually ports:

- `isolcpus=3` in `cmdline.txt` (Pi) / `armbianEnv.txt` `extraargs=` (CB1), plus `CPUAffinity=3` in the unit. That is the measurable part.
- Governor: the mainline parameter is `cpufreq.default_governor=performance`; FlyOS's `cpufreq_default_governor=` spelling is either a BSP patch or a no-op on their kernel, don't copy it. On CB1 Armbian defaults to `ondemand` with a 480 MHz floor — set `performance` or raise the floor, both via `/etc/default/cpufrequtils`.
- IRQ affinity: a small oneshot like `flyos-init-hard`, driven by `/proc/interrupts` names, not hardcoded numbers.
- Building our own kernel to get `NO_HZ_FULL` is V2 at most; it also means owning kernel updates.

Both targets are quad-core (CM5: 4× Cortex-A76; CB1: 4× Cortex-A53 @ 1.5 GHz), so core 3 exists on both.

## 11. Services and network posture

Keep the service set small: klipper, moonraker, nginx, NetworkManager, systemd-networkd (CAN only), sshd, avahi-daemon. Optional by config: crowsnest, klipper-mcu (Klipper's Linux host MCU — useful for host GPIO / SPI accelerometer / host temperature), a screen stack in V2.

Discovery for the headless acceptance test: `avahi-daemon` publishing `<hostname>.local`, and Moonraker's `[zeroconf]` section so Fluidd/Mainsail and slicers find the printer. FlyOS leaves `[zeroconf]` commented out (`config/moonraker.conf:9-10`) and instead prints the IP on a splash screen we don't have.

Do **not** copy FlyOS's network posture. Their image ships root with a fixed password baked into `/etc/shadow`, a writable unauthenticated `ttyd` root shell on :8888, and Moonraker with `trusted_clients: 0.0.0.0/0, ::/0` and `cors_domains: *` (inventory §9, `config/moonraker.conf:18-34`). For us: no default root password, key-based SSH or first-boot-set credentials from `klipperos.conf`, and a `trusted_clients` list generated from the actual LAN prefix at first boot (fall back to RFC1918 + link-local, which is what Moonraker's own installer suggests).

Moonraker needs `sudo` for its `[machine]` component (reboot, service control; `provider: systemd_dbus` is preferable to FlyOS's `systemd_cli`) — another reason Debian.

## 12. Updates

Two lanes, deliberately different from FlyOS:

- **OS:** `apt`. That's the whole point of the Debian decision. Kernel comes through the same channel: Raspberry Pi's apt repo on CM5/CM4, Armbian's on CB1.
- **Klipper/Moonraker/Fluidd:** install as real git checkouts so Moonraker's `update_manager` works. FlyOS strips all `.git` metadata (inventory §6), which is why their only update path is the signed-7z OTA blob in `flyos-fast-ota` — a Go binary with no published source. We can't reproduce that and shouldn't want to.

The cost is disk (shallow clones keep it small; `update_manager` copes with `--depth`) and the fact that users can update themselves into a broken state. Acceptable; that's how every other Klipper distro works.

## 13. Worth stealing from their patches

The patch analysis (inventory §7, `analysis/*.patch`) separates Fly-hardware code from generally-useful fixes:

- `power_loss_resume.py` + the heavy `virtual_sdcard.py` rewrite — power-loss recovery. High value on a printer, but it's a large patch against a moving upstream file; treat as opt-in, not baked in.
- Moonraker `machine.py` SD-device fix — resolves the root device via `findmnt`/`lsblk` instead of hardcoding `mmcblk0` (`analysis/moonraker-vendor.patch:618-661`). Still relevant: upstream `master` hardcodes `/sys/block/mmcblk0/device/cid` as of 2026-09-03. Effect on us is cosmetic (SD info panel in the UI), so: carry it as a small patch, or upstream it, but don't block on it. On CM5 with eMMC the root *is* `mmcblk0`, so the stock code happens to work there.
- `filament_blockage_detection` — self-contained, opt-in, needs its MCU-side `.c` compiled into the toolhead firmware, so it's really a firmware-build option.
- Skip: `fly_lcd` (both sides), the OTA client, KlipperScreen theming, and the host↔MCU communication patches (`mcu.py`/`serialhdl.py`/`src/*.c` are patched together, so they only make sense with Fly-built firmware).

## 14. Board support matrix

| Board | SoC / arch | Kernel source | Boot mechanism | Boot partition | Tested |
|---|---|---|---|---|---|
| RPi CM5 | BCM2712, 4× A76, arm64 | Raspberry Pi `linux-image-rpi-2712` (6.12 on trixie) | SPI EEPROM bootloader → files on first FAT partition | FAT: firmware, `config.txt`, `cmdline.txt`, `kernel_2712.img`, `bcm2712-rpi-cm5-*.dtb` | yes (have hardware) |
| BTT CB1 | Allwinner H616, 4× A53 @ 1.5 GHz, arm64, 1 GB | Armbian `linux-image-current-sunxi64` (mainline 6.18.x; board status "Standard", family `sun50iw9`) | U-Boot SPL at raw 8 KiB (or 256 KiB) → `boot.scr` on FAT | FAT labelled `BOOT`: `Image`, `sun50i-h616-bigtreetech-cb1-sd.dtb`, `boot.scr`, `armbianEnv.txt` | yes (have hardware) |
| RPi CM4 | BCM2711, 4× A72, arm64 | Raspberry Pi `linux-image-rpi-v8`, same repo as CM5 | on-board EEPROM bootloader → first FAT partition | FAT: `kernel8.img`, `bcm2711-rpi-cm4.dtb` | **no hardware — build only, mark untested** |

CB1 notes, resolving the old open question:

- Use Armbian's mainline kernel, not BTT's `CB1-Kernel` fork (a 5.16 BSP tree that is effectively unmaintained). Armbian's CB1 config is maintained upstream, offers `current` and `edge`, and its trixie images are what the "mainline Armbian on CB1" community reports are based on (months of printing, one TTC in ~200 h).
- Wi-Fi is a Realtek RTL8189FS (SDIO) with an **out-of-tree** driver. Armbian builds it in (`CONFIG_RTL8189FS=m`, source pulled from `EvilOlaf/rtl8189ES_linux` at kernel build time). Using Armbian's kernel package gets the driver for free; building our own kernel would mean carrying that driver too. First-boot Wi-Fi flakiness on CB1 is a known forum topic; wired is the safe default for the acceptance test.
- FlyOS has no CB1/H616 code, only the H618 block-device naming in `flyos-blk-links`. Nothing to port.

Be explicit in release notes about which artifacts were actually booted. An untested-but-built CM4 image is fine as long as it says so.

## 15. Open questions

Resolved since the first draft (see §14, §2): CB1 kernel provenance (Armbian mainline), CM5 suite (trixie, Pi kernel 6.12).

Still open:

- **MBR or GPT.** Pi 5 firmware boots GPT fine as long as the partition entry array sits at the standard LBA 2. H616 can boot from 256 KiB, clear of a GPT array, but that needs a U-Boot with the H616 high-offset fix and departs from Armbian's 8 KiB/MBR layout. GPT unlocks `systemd-repart` and clean A/B labels; MBR is what every existing image on both boards uses. Default to MBR + `growpart` unless GPT is proven on CB1 hardware early.
- Boot media matrix: CB1 is SD-only in practice (its DTB name even says `-sd`); CM5 adds eMMC and NVMe. Does V1 support NVMe root, or SD only?
- Whether Klipper's Linux host MCU (`klipper_mcu`) is worth enabling by default — FlyOS ships it gated behind a unit condition (`analysis/flyos-glue/systemd/klipper-mcu.service:7-8`).
- Image build reproducibility: containerized build + checksummed artifacts, and how a boot smoke test gets run on real hardware without a person plugging in cards.
- Kernel module pruning: how far to trim before it becomes a support burden (FlyOS ships all 2,696 — the opposite extreme). With vendor kernel packages, pruning means post-install deletion that the next kernel upgrade undoes; probably not worth it in V1.
- CB1 memory: 1 GB (some variants 512 MB). Klipper + Moonraker + nginx idle comfortably under 400 MB, but the zram sizing and journald caps in §7 matter more here than on CM5.

## 16. Hardware research — performance options, CB1 first

The CB1 is the constrained target: 4× Cortex-A53 @ 1.5 GHz, 1 GB DDR3 (512 MB on some batches), SD-only storage, USB 2.0, Wi-Fi on SDIO. The CM5 has headroom to spare and mostly needs *not* to be pessimised. Everything below is a hypothesis to measure on the bench, not a decision; the point of this section is to fix the measurement protocol first so each option gets a number, and to record that FlyOS already does several of them.

### 16.1 What to measure, and how

Same printer, same G-code (a 2 h multi-feature print), same MCU firmware, run once per configuration. Collect:

| Metric | Where | Why |
|---|---|---|
| `Timer too close` / `MCU shutdown` count | `klippy.log` | the failure mode this whole section exists to prevent |
| Per-MCU `srtt`, `rttvar`, `bytes_retransmit`, `freq` drift | `klippy.log` `Stats` lines, `scripts/graphstats.py` | host-side latency and link health; retransmits on CAN/USB are the early warning |
| `sysload`, `cputime`, `memavail` | same `Stats` lines | host load during print; sysload > ~1.0 on a 4-core A53 is trouble |
| Idle RAM after boot | `free -m` at Moonraker-ready | the ≤400 MB target from §2 |
| Boot to Moonraker-ready | `systemd-analyze` + timestamp of first `/server/info` 200 | the "flash and print" experience |
| SD write volume per hour | `/proc/diskstats` delta | card wear and stall risk |

Baseline to beat: stock Armbian minimal (trixie, `current` kernel) + KIAUH-installed Klipper on the same CB1. If an option doesn't move a metric, it doesn't go in the image.

### 16.2 Display and desktop: off by config

V1 ships no Xorg/Wayland/GTK, so there is nothing to disable in userland yet. The knob still matters now, for two reasons: the *kernel* side (DRM, HDMI, GPU, CMA reservation) is present regardless of userland, and V2 screen support must not make headless users pay for it. So define the option in V1 and make first boot honour it on both boards:

```
# klipperos.conf
display=none        # none | hdmi | <panel-id in V2>
```

`display=none` means, per board:

- **CB1** — `extraargs=video=HDMI-A-1:d` in `armbianEnv.txt`, plus a modprobe blacklist for `sun4i_drm`, `sun8i_mixer`, `sun8i_drm_hdmi`, `lima`/`panfrost`. FlyOS does the equivalent in U-Boot: `fdt set /soc/hdmi@1ee0000 status "disabled"` whenever `screen` is not `hdmi` (`analysis/flyos-glue/boot/boot.scr.txt:126-131`), and shrinks the framebuffer reservation with `sunxi_fb_mem_reserve=32` (`:96`). On mainline the reservation is CMA; check `cat /proc/meminfo | grep Cma` before and after — expect tens of MB back on a 1 GB board.
- **CM5/CM4** — omit `dtoverlay=vc4-kms-v3d` from `config.txt`, same `video=HDMI-A-1:d` in `cmdline.txt`, blacklist `vc4`/`v3d`. Pi 5 firmware no longer honours `gpu_mem`, so the DT overlay is the only lever.
- **Both** — keep `getty@tty1` (it costs nothing and is the debug path when networking fails), `consoleblank=0` so a monitor plugged in later still shows the console, and mask any display unit V2 adds (`klipperscreen`, a display manager) with `systemctl mask` from the same first-boot unit that reads the key.

`display=hdmi` in V1 does nothing beyond leaving the kernel defaults alone; it exists so V2 has a value to grow into without changing the file format.

### 16.3 CPU scheduling

- **Core isolation** — `isolcpus=3` + `CPUAffinity=3` on `klipper.service` (§10). Measure: `srtt` spread and TTC count with and without. This is the single highest-expected-value change on CB1.
- **Governor** — Armbian ships `ondemand` with a 480 MHz floor on `sun50iw9` (`CPUMIN=480000`, `CPUMAX=1512000`). Options: `performance` (simplest, costs a few hundred mW), or `ondemand` with the floor raised to ~800 MHz (the mainline-CB1 community setting). Compare power/thermal on the SoM: the H616 throttles under a heatsink-less Manta enclosure; check `/sys/class/thermal` during the print.
- **IRQ affinity** — keep USB (CAN adapter, main MCU), MMC and ethernet IRQs off core 3; FlyOS pins them to cores 1–2 by mask (`flyos-init-hard:27-32`). On CB1 the names in `/proc/interrupts` are `sunxi-mmc`, `ehci_hcd`/`ohci_hcd`/`musb-hdrc`, `eth0`/`end0`; on CM5 they live behind the RP1 (`rp1_*`). Match by name, never by number.
- **`Nice=-18` / `IOSchedulingPriority=2`** on klipper and moonraker (§10). Cheap; verify it doesn't starve `nginx` during a large upload mid-print.
- **Wi-Fi power save off** — `nmcli connection modify <con> wifi.powersave 2`. RTL8189FS with power save on is the usual cause of Moonraker websocket drops and "lost connection" reports on CB1. Not a print-quality issue, but it is the top user-visible complaint. Disable IPv6 on the link too if the Realtek driver misbehaves with RA traffic (the mainline-CB1 write-up did).

### 16.4 Memory

- **zram swap** at 50% of RAM (FlyOS: `flyos-init-zram:33-38`; Armbian: `armbian-zram-config`). With `zram-tools` on Debian this is one config file. Measure whether it ever gets used during a print; if `memavail` never drops below ~300 MB, it is insurance, not a fix.
- **Logs in RAM** — journald `SystemMaxUse=20M` + `/var/log` on zram (FlyOS `flyos-init-zram:47,71-76`, Armbian `armbian-ramlog`). Klippy's own log goes to `printer_data/logs` on the card; Klipper rotates it per restart so it is bounded.
- **Python** — venvs with `--system-site-packages` so numpy/scipy/matplotlib are Debian's, not compiled or duplicated. Moonraker's `[file_manager]` metadata scanning and Klipper's `shaper_calibrate` pull matplotlib/scipy in only when used.
- **Kernel** — the sunxi64 kernel `.deb` installs every module Armbian enables; not loaded means not resident, so pruning buys disk, not RAM (§15).

### 16.5 Storage I/O (CB1 is SD-only)

- Mount options from §7 (`noatime,nodiratime,commit=120`), `mq-deadline` or `none` scheduler on `mmcblk0`.
- Measure SD write volume during a print with and without the log/journal changes; a 2 h print should produce close to zero writes beyond `klippy.log`.
- `x-systemd.growfs` and `growpart` run once; no other partition work at runtime.
- Option, not default: F2FS for the data partition. Only if diskstats say writes are still significant.

### 16.6 Kernel experiments (V2 unless a measurement forces it)

- `CONFIG_NO_HZ_FULL` + `CONFIG_RCU_NOCB_CPU` — makes FlyOS's `nohz_full=3 rcu_nocbs=3` real (§10). Requires our own kernel build on both boards and therefore owning updates.
- `CONFIG_PREEMPT_RT` — in mainline since 6.12; Armbian does not enable it in `current`. Same cost. Worth one bench run on CB1 to know if it matters at all.
- `CONFIG_HZ` — check what Armbian sets for sunxi64 (`grep CONFIG_HZ= /boot/config-*`); 250 vs 1000 changes timer granularity for Klipper's host-side scheduling.

### 16.7 CM5-specific

Expected to be a non-issue for print quality; the research question is only "does any CB1 setting hurt here?" Verify `isolcpus=3` and `performance` don't raise idle power or SoC temperature enough to matter in an enclosed printer. NVMe root vs SD is a boot-time and wear question, not a latency one (§15).

### 16.8 Boot time

`systemd-analyze blame` on each board. Usual suspects to mask on an appliance: `apt-daily*.timer`, `e2scrub_all.timer`, `man-db.timer`, `systemd-networkd-wait-online` (we wait on our own unit), and anything Armbian's `.deb`s enable that we didn't ask for. Target: Moonraker answering within 30 s of power on CB1, faster on CM5.

## 17. Explicitly not in V1

A/B root slots, OTA, read-only root/overlayfs, KlipperScreen or any GUI, DSF/RRF support, the combined dual-board card, camera stack on by default, MCU firmware flashing from the host, a custom kernel build.

Each of these has a hook left in the design (partition layout, config-file keys, service gating) so V2 doesn't require re-imaging anyone.

## 18. Reference index

| Concept | Where to read it |
|---|---|
| Pre-systemd init, overlay mounts, partition growth | `analysis/flyos-glue/scripts/flyos-init` (`:39-102` grow, `:153-196` overlays, `:18,120` mount options) |
| First-boot seeding from FAT partition | `analysis/flyos-glue/scripts/flyos-firstrun:3-21` |
| Config-file-driven provisioning (Wi-Fi, TZ, CAN, board) | `analysis/flyos-glue/scripts/flyos-config` (`:60-76` timezone, `:78-93` CAN bitrate, `:95-118` chattr, `:159-202` Wi-Fi) |
| Hostname, machine-id reset, UI database seeding | `analysis/flyos-glue/scripts/flyos-set-hostname` |
| zram swap, `/var/log` on zram, journald cap | `analysis/flyos-glue/scripts/flyos-init-zram` |
| Governor and IRQ affinity | `analysis/flyos-glue/scripts/flyos-init-hard` |
| User-facing config surface | `analysis/flyos-glue/config/config.txt` |
| Config → U-Boot env → kernel cmdline | `analysis/flyos-glue/boot/boot.scr.txt:52-54, 84-101, 124-125` |
| Service gating on cmdline flags | `analysis/flyos-glue/systemd/klipper.service:7`, `klipper-mcu.service:7-8` |
| Real-time pinning | `boot.scr.txt:97-98` + `klipper.service:14-16` + `moonraker.service:14-15` |
| CAN bring-up | `analysis/flyos-glue/network/99-can.network`, `99-can-link.link` |
| Stable block-device naming, sunxi H3/H5/H618 handling | `analysis/flyos-glue/scripts/flyos-blk-links` |
| Boot/config partition mounting | `analysis/flyos-glue/scripts/flyos-mounts` |
| Web stack config (nginx site is upstream-standard) | `analysis/flyos-glue/web/` |
| Moonraker config as shipped (open trust, zeroconf off) | `analysis/flyos-glue/config/moonraker.conf` |
| Moonraker SD-device fix | `analysis/moonraker-vendor.patch:618-661` |
| Full teardown, versions, patch analysis | `analysis/FlyOS-Fast-1.3.8-inventory.md` |

## 19. Validation log

2026-09-03 — every file/line reference above was re-read from `analysis/flyos-glue/` and the inventory; external claims were checked against upstream sources. What changed from the first draft:

| Claim | Was | Now | Source |
|---|---|---|---|
| Base suite | bookworm unless forced | trixie | Debian 13 stable since 2025-08; Raspberry Pi OS trixie ships kernel 6.12; Armbian CB1 images are trixie |
| Builder | mmdebstrap / pi-gen / Armbian, pick one | mmdebstrap; copy `rpi-image-gen`'s Pi layer | github.com/raspberrypi/rpi-image-gen |
| FlyOS root size | 620 MB | 620 MB compressed, 3.1 GB on disk | `7zz l parts/2.img`, `du -sh rootfs` |
| CB1 boot offset | "raw sector offset" | 8 KiB, with 256 KiB fallback on H616 (128 KiB is older sunxi) | U-Boot sunxi docs; linux-sunxi BROM page |
| CB1 boot partition | unspecified | FAT, label `BOOT`, `boot.scr` + `armbianEnv.txt` | `armbian/build config/boards/bigtreetech-cb1.conf` |
| CB1 kernel | open question | Armbian mainline 6.18 `current`, board "Standard"; Wi-Fi RTL8189FS out-of-tree, bundled by Armbian | armbian.com/bigtreetech-cb1, `linux-sunxi64-current.config`, `drivers_network.sh` |
| CM5 kernel | "6.6+" | Raspberry Pi 6.12 on trixie, `linux-image-rpi-2712` | raspberrypi.com trixie announcement |
| Partition growth | `systemd-repart` | `growpart` + `x-systemd.growfs`; repart only if GPT | systemd-repart is GPT-only |
| RT kernel args | copy all of FlyOS's | only `isolcpus=3` is live; `nohz_full`/`rcu_nocbs` need `CONFIG_NO_HZ_FULL`, absent from rpi-6.12.y `bcm2712_defconfig`/`bcm2711_defconfig` and Armbian sunxi64-current | raw defconfigs, grepped |
| Governor arg | `cpufreq_default_governor=` | `cpufreq.default_governor=` | kernel-parameters.txt |
| CAN modules | "make sure both exist" | `gs_usb`, `mcp251x`, `mcp251xfd` all `=m` on both kernels | same defconfigs |
| by-id stability | udev symlinks for stability | by-id already stable; symlinks are for role names | Klipper USB serial = chip unique ID |
| Moonraker SD fix | "stock gets it wrong" | still hardcoded upstream as of today; impact cosmetic | `Arksine/moonraker master machine.py:62-63` |
| Line refs | `flyos-init:39-95`, `:153-192`; `boot.scr.txt:96-98`; `flyos-config:97-114` | `:39-102`, `:153-196`; `:97-98`; `:95-118` | re-read with `cat -n` |
| Config file handling | parse | parse, explicitly not `source` (FlyOS sources it as root) | `flyos-config:145`, `flyos-firstrun:11` |
| Discovery | mDNS not mentioned | avahi + Moonraker `[zeroconf]` required by the acceptance test | — |
| Seed dir | rsync then delete (as FlyOS) | rsync then rename | `flyos-firstrun:21` |

Not re-verified and still taken from the inventory: FlyOS component versions, patch file counts, the Pi 5 GPT partition-array constraint (from `rpi-eeprom#585`, closed without a documented fix).
