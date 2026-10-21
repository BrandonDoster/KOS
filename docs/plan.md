# KOS — design plan (V1)

User-facing overview is [`README.md`](../README.md); the FlyOS-Fast teardown this project grew out of is [`teardown/README.md`](teardown/README.md).

Concepts and decisions, not a build procedure. Where FlyOS-Fast already solved something, the reference names the vendor file (with line numbers as shipped in the image) so the mechanism can be traced rather than re-derived. The vendor files are not in this repo; [`teardown/flyos-glue.md`](teardown/flyos-glue.md) describes each one. Other paths are relative to this repo.

Last validated 2026-09-03 against the extracted image and upstream sources; see §20 for what was checked and what changed. **Implementation started 2026-09-03; §21 tracks what exists, what is tested, and what still needs hardware.** Where the code diverged from the design below, the section says so inline with a "Built:" note.

## 1. Goal

A very lightweight, Klipper-ready Debian image for **Raspberry Pi CM5** and **BTT CB1**, with CM4 as a bonus target (untestable here — no hardware).

**V1 is done when:** flash SD → boot → copy an existing `printer.cfg` onto the card → the machine is print-ready, with CAN and USB toolhead boards and controllers picked up automatically.

That acceptance test is the whole scope filter. Anything that doesn't serve it is V2.

Implied by the test but easy to forget: the user has no serial console and no known IP. The machine must be findable as `<hostname>.local` (mDNS) and the web UI must be up on port 80 with no further setup. See §11.

## 2. Base OS: Debian

Decided: Debian, because `apt` and `sudo` are required. This is a deliberate divergence from FlyOS, which is Buildroot with no package manager at all — no dpkg/opkg/apk, no package database anywhere (`docs/teardown/FlyOS-Fast-1.3.8-inventory.md` §3). Their image is smaller and immutable; ours is maintainable and debuggable at 3am on a printer that won't home.

Consequences to accept up front:

- Size baseline, corrected: FlyOS's root is a 620 MB SquashFS-zstd (`7zz l parts/2.img` → Physical Size 620,195,840) that unpacks to **3.1 GB** on disk (`du -sh rootfs`). Of that, `/data/klipper` is 222 MB, `/data/katapult` 120 MB (a vendored `lib/`), modules 80 MB, plus Xorg/GTK, DSF and the ARM toolchain. An ext4 image is uncompressed, so the honest comparison is against 3.1 GB, not 620 MB. Target: **≤1.5 GB image, ≤400 MB RAM at idle**, measured every build.
- Debian's Python is fine: FlyOS proves the dependency set is modest — see `docs/teardown/python-site-packages.txt` for exactly what Klipper + Moonraker + Crowsnest actually need at runtime (numpy, scipy, matplotlib, tornado, msgspec/msgpack, jinja2, libnacl, streaming-form-data, zeroconf, pyserial, python-can, distro, psutil, lmdb, preprocess-cancellation, paho-mqtt, dbus-fast, pyudev…). Nothing exotic. Klipper builds `chelper/c_helper.so` on first start, so `gcc`, `libffi-dev` and `python3-dev` stay in the image (FlyOS ships a prebuilt `.so` instead; we can't, because a git update would need the compiler anyway).
- Keep `apt` genuinely usable: don't do read-only root in V1 (see §7).

**Base suite: `trixie` (Debian 13).** The original draft said bookworm-unless-forced; that is stale. Trixie has been stable since August 2025, Raspberry Pi OS ships on trixie, and Armbian's CB1 images are trixie-based. Bookworm is now oldstable and buys nothing.

Kernels do not come from Debian on either board (§14): Raspberry Pi's `archive.raspberrypi.com` packages for CM5/CM4 (6.18 as of September 2026), Armbian's `linux-image-current-sunxi64` for CB1 (also 6.18). Debian's own 6.12 kernel has partial BCM2712 support but not the RP1 peripheral chip, so it is not a usable fallback on CM5.

**Builder: `mmdebstrap` with hooks, one tree for both boards.** Raspberry Pi's own `rpi-image-gen` (official since 2025, mmdebstrap/bdebstrap underneath, YAML layers, ships a `trixie-minbase` config and CM5 examples) is the reference for the Pi side: copy its kernel/firmware/boot-partition layer rather than re-deriving it. CB1 gets the same rootfs plus Armbian's kernel and U-Boot `.deb`s. Do not adopt pi-gen or the full Armbian framework — each owns only one board and drags in its own desktop-oriented defaults. The only per-board delta is kernel + bootloader + DTB + boot-partition contents.

## 3. One image or two

Mechanically, one card *can* boot both:

- **CM5/CM4** — bootloader lives in SPI EEPROM; it reads firmware, kernel and DTB as *files* from the first FAT partition (`config.txt`, `cmdline.txt`, `kernel_2712.img` / `kernel8.img`).
- **CB1** — Allwinner H616 (sun50iw9 family; same die family as the H618 that FlyOS's own glue already special-cases, see [`flyos-blk-links:28-35`](teardown/flyos-glue.md#flyos-blk-links)). The BROM loads the SPL from a *raw sector offset*: 8 KiB (sector 16) first, then 256 KiB (sector 512) on H616 — the 128 KiB fallback belongs to older sunxi parts. Armbian's CB1 config uses a **FAT** boot partition labelled `BOOT` (`BOOTFS_TYPE="fat"`), `boot.scr` + `armbianEnv.txt`, DTB `sun50i-h616-bigtreetech-cb1-sd.dtb`, overlay prefix `sun50i-h616`.

Those two mechanisms don't collide: raw sectors before the first partition vs. files inside a FAT partition, and both bootloaders are happy reading their files from the same FAT volume. A hybrid card is genuinely possible.

**Recommendation for V1: one build system, two artifacts.** The blocker isn't boot, it's everything downstream — two kernel packages, two module trees, two DTB sets, two `apt` sources for kernel upgrades (Raspberry Pi's vs Armbian's), and a doubled test matrix. A combined card is a fun V2 experiment; it is not on the path to "flash and print."

Design the rootfs so this stays cheap: everything board-specific lives behind a single `BOARD=` value resolved at first boot (from `/proc/device-tree/model`, not from the config file), and nothing else in the image branches on hardware. All three targets are arm64, so it is literally one rootfs. Note the analyzed FlyOS image is 32-bit armv7 (H3): nothing binary in it is reusable, only the shell/unit/config text.

## 4. What "very lightweight" means concretely

FlyOS is the baseline for what a full-featured vendor image costs: 979 binaries, 556 shared libraries, 2,696 kernel modules, an entire Xorg + GTK3 stack, gcc-arm-none-eabi in `/opt`, and the whole Duet/DSF stack alongside Klipper (`docs/teardown/userland-binaries.txt`, `docs/teardown/FlyOS-Fast-1.3.8-inventory.md` §5-6).

Cut list for V1:

- No Xorg/GTK/KlipperScreen (headless; screens are V2)
- No DSF/RRF path — Klipper only
- One web UI, not two. **Mainsail** (decided 2026-10-19: the owner's configs are Mainsail-based and `[include mainsail.cfg]`; no performance reason was ever recorded for Fluidd, and both are static files behind nginx). `mainsail-config` is cloned and `mainsail.cfg` symlinked into the config dir, as Mainsail's installer does; nginx serving static files is enough. FlyOS's [`sites-available/fluidd`](teardown/flyos-glue.md#web-server) is the standard upstream nginx site verbatim (proxy `/websocket` and `/(printer|api|access|machine|server)/` to Moonraker, `client_max_body_size 0`) — copy it. FlyOS ships both UIs plus both nginx *and* Caddy.
- No vendored toolchain — flashing MCU firmware is a build-host job, or an opt-in package
- Trim locales, docs, man pages, and the module tree to what the board actually has
- Camera stack (Crowsnest/ustreamer) is optional-by-default, not baked in
- Katapult: scripts only (`flashtool.py`), not the 120 MB vendored tree

Anti-pattern worth naming: FlyOS creates `/data/{klippy,moonraker,klipperscreen}-env` and then just copies system site-packages into them ([`flyos-init-venv`](teardown/flyos-glue.md#flyos-init-venv)); the shipped units ignore the venvs and run `/usr/bin/python` directly. Either use real venvs or don't pretend — for a Debian base, real venvs per app (`--system-site-packages` over Debian's numpy/matplotlib to avoid compiling them) are the honest choice and cost little. Moonraker's `update_manager` also expects a venv path per app.

## 5. The provisioning surface

The single best idea in FlyOS: **a FAT partition the user can edit from any OS after flashing**, holding one plain-text config file that drives everything ([`config.txt`](teardown/flyos-glue.md#configtxt)). Wi-Fi credentials, timezone, hostname, CAN bitrate, which UI, which screen — all set before first boot, no serial console, no SSH-then-fix dance. FlyOS mounts it `vfat … sync,umask=000` (`flyos-mounts:14`).

Adopt this. Three adjustments:

- **Don't name it `config.txt` on the Pi.** That name (and `cmdline.txt`) is owned by the Raspberry Pi firmware on the first FAT partition. Use a distinct name (`kos.conf`) and, ideally, a separate third FAT partition mounted at `/config`, so the firmware's file and ours never share a directory. The Pi firmware only reads the first FAT partition, so a second one is invisible to it. Keeps CM5 and CB1 identical.
- **Don't route settings through the kernel command line.** FlyOS imports `config.txt` into the U-Boot environment and forwards keys into `bootargs` ([`boot.scr.txt:52-54, 124-125`](teardown/flyos-glue.md#boot)), then gates services with `ConditionKernelCommandLine=` ([`klipper.service:7`](teardown/flyos-glue.md#klipperservice)). Elegant, but it depends on U-Boot — the Pi has no equivalent. The portable equivalent is a first-boot unit that parses the file and enables/disables units with `systemctl`, plus `EnvironmentFile=` for values services need at runtime (`klipper.service:21` shows the pattern).
- **Don't `source` it.** FlyOS runs `source "$fp_config"` as root (`flyos-config:145`, `flyos-firstrun:11`, `flyos-set-hostname:16`), so the config file is a root shell script. Parse `key=value` lines instead. The threat is low (whoever holds the card owns the machine anyway) but the parser is the same size and doesn't break on a stray `$`.

**Built:** the partition is labelled `KOS` (FAT32, 64 MB), mounted at `/config` with FlyOS's `sync,umask=000` plus `nofail`, and holds `kos.conf` (`build/config-partition/kos.conf` is the shipped template with every key documented). Parser is `cfg KEY DEFAULT` in `overlay/usr/lib/kos/lib.sh` (awk, last key wins, strips one layer of quotes) and a matching 10-line `read_conf()` in the two Python tools. On CB1 it is partition 1; on CM5/CM4 it will be partition 2 because the Pi firmware's FAT must come first.

Also worth copying: seeding user data from the FAT partition on first boot. FlyOS rsyncs `/config/printer_data/` into place once and deletes the marker ([`flyos-firstrun:3-21`](teardown/flyos-glue.md#flyos-firstrun); note it also `rm -rf`s the source dir at line 21 — rename it to `printer_data.imported/` instead so the user's original survives). That is exactly the "copy an existing cfg file over" half of the V1 acceptance test — the user drops `printer.cfg` on the FAT partition from their laptop and it lands in `printer_data/config` on boot.

## 6. First-boot flow

Conceptually: expand → seed → identify → configure → start.

- **Expand.** FlyOS hand-rolls partition expansion with scripted `fdisk` before systemd starts ([`flyos-init:39-102`](teardown/flyos-glue.md#flyos-init)) because Buildroot gave it nothing better. On Debian: `growpart` (package `cloud-guest-utils`, one line, works on MBR and GPT) in a oneshot unit, then `x-systemd.growfs` in `fstab` for the filesystem. `systemd-repart` is the nicer tool but is **GPT-only**; it becomes an option only if the GPT decision in §15 goes that way.
- **Seed.** Copy user files from `/config`, regenerate SSH host keys and machine-id (FlyOS: `flyos-set-hostname:6`), set hostname (`flyos-set-hostname:40-46`), apply timezone and Wi-Fi from the config file (`flyos-config:60-76` and `:159-202`; Wi-Fi via `nmcli`, creating a connection named "FlyOS wireless" with `autoconnect-priority -999`).
- **Identify.** MCU discovery — the interesting part, §8.
- **Configure/start.** Enable the units the config file asked for; drop the first-boot marker.

Everything here is an ordinary systemd unit ordered before `klipper.service`. No custom `init=` — FlyOS needs one only because the overlay has to exist before systemd does.

**Built:** one script, `overlay/usr/lib/kos/kos-config`, run by `kos-config.service` on *every* boot rather than only the first. Each step is idempotent, so a user who edits `kos.conf` later (new Wi-Fi, new hostname, drops a new `printer.cfg`) gets it applied on the next boot without a re-flash. Only partition growth is gated on `/var/lib/kos/firstboot.done` (SSH host keys: see §11). Growth is `growpart` + online `resize2fs` from the script; `x-systemd.growfs` was dropped because it runs at mount time, before `growpart` could have run. Seeding accepts either `/config/printer.cfg` alone or a whole `/config/printer_data/` tree; the source is renamed `*.imported*`, never deleted. Ordering: after NetworkManager (for `nmcli`), before avahi, ssh, nginx, MCU discovery, klipper and moonraker.

**Security review, 2026-10-21:** `kos-config` no longer `Requires=` the data partition: when `KOS-DATA` fails to mount (`nofail`), only seeding is skipped and everything else (credentials, Wi-Fi, hostname) still applies. Every value from `kos.conf` is validated before use (hostname as an RFC 1123 label, timezone as a zone file under `/usr/share/zoneinfo`, `can_bitrate` digits only, `allowed_hosts` as DNS names, `archive_path` in `kos-archive`); a bad one falls back to the current or default value with a warning. Warnings go to the journal, to `/config/KOS-WARNINGS.txt` (readable from a PC) and to `/run/motd.d/kos-warnings` (the SSH and console login banner); both files are removed on a clean boot. The parser (`lib.sh` `cfg_lines`, mirrored by `read_conf` in the Python tools and compared in `tests/test_lib_sh.sh`) takes `#` as a comment only at the start of a line, so a secret containing ` #` is no longer cut short, and joins a line ending in `\` with the next one. A printer_data import is copied without FAT's 0777 modes (`cp -r --preserve=timestamps`, then 644/755), and `/config` is mounted `uid=1000,fmask=0177,dmask=0077,nosuid,nodev,noexec`.

## 7. Durability vs. writability

FlyOS's answer to "printers lose power mid-write": read-only SquashFS root, everything mutable in an overlayfs on a separate ext4 partition, plus A/B root slots ([`flyos-init:153-196`](teardown/flyos-glue.md#flyos-init), inventory §2). It's a good answer, and it is fundamentally incompatible with `apt install` on a running machine.

**V1: writable root, mitigations only.**

- Mount options, as FlyOS does them: root/userdata `noatime,nodiratime,commit=120,errors=remount-ro` (`flyos-init:18,120`), boot `commit=360` (`flyos-mounts:10`), config FAT `sync` (`flyos-mounts:14`)
- Logs off the card: journald `SystemMaxUse=20M` and `/var/log` on a 50 MB zram ext4 (`flyos-init-zram:47,71-76`); zram swap at 50% of RAM (`flyos-init-zram:33-38`). On Debian this is `zram-tools` + a `journald.conf` drop-in, not a script. FlyOS's file-swap script is a no-op (`flyos-init-swap` is fully commented out).
- Keep the partition layout *A/B-shaped anyway* — leave an unused slot-B-sized gap and a separate data partition — so V2 can adopt overlay/A-B without re-imaging users
- Their `chattr +i` trick to protect UI-managed configs from being clobbered (`flyos-config:95-118`) is worth remembering but not V1

State the tradeoff in the README when shipping: a hard power cut mid-`apt` can still corrupt this image. That's the price of `apt`.

**Built (`overlay/etc/fstab`, `build/boards/cb1/board.sh`):**

- Layout on CB1, MBR: p1 `KOS` FAT32 64 MB → p2 `KOS-ROOT` ext4 **fixed 3 GiB** → p3 `KOS-DATA` ext4, fills the card on first boot and is mounted at `/home/klipper/printer_data`. First partition starts at 16 MiB (U-Boot sits at 8 KiB). A fixed-size root means the OS can be re-flashed by writing only p2 while configs, gcodes and the Moonraker database survive on p3. That is the "separate data partition" half of the A/B shape.
- The slot-B gap was **dropped**: MBR allows four primaries, and p1–p3 plus a gap partition leaves no room for anything else. A/B in V2 therefore does mean re-partitioning; the data partition is what makes that survivable. GPT would fix this (§15).
- Logs: `/var/log` is a 50 MB tmpfs and journald is `Storage=volatile`, `RuntimeMaxUse=20M`. Simpler than FlyOS's ext4-on-zram and equivalent in effect, because tmpfs pages swap into the zram device under pressure anyway. Cost: nginx/journal logs vanish on reboot; `klippy.log` and `moonraker.log` live in `printer_data/logs` on the card as before.
- Swap: `zram-tools`, `PERCENT=50`, zstd.
- Mount options exactly as FlyOS: `noatime,nodiratime,commit=120,errors=remount-ro`.

## 8. "Instantly print ready" — the MCU identity problem

This is the actual hard requirement, and neither FlyOS nor stock Klipper solves it. A `printer.cfg` copied from another machine contains `[mcu] serial: /dev/serial/by-id/usb-Klipper_stm32f446xx_XXXX-if00` or `canbus_uuid: abc123…`, and those strings are machine-specific. Copying the file to new hardware breaks exactly there.

Facts that shape the design:

- `/dev/serial/by-id/` names are already stable per physical board: Klipper and Katapult firmware report the chip's unique ID as the USB serial number. Stability across reboots is free; the udev symlinks below are for *role* naming, not stability.
- A main board running Klipper's USB-to-CAN bridge mode appears as a `gs_usb` CAN adapter **and** as a CAN node with its own `canbus_uuid`. Its `[mcu]` section then uses `canbus_uuid:`, not `serial:`. Discovery must handle both.
- `scripts/canbus_query.py` (and Katapult's `flashtool.py -q`) only get answers from MCUs that are **not currently connected** to a Klipper instance. Discovery therefore has to run before `klipper.service`, and on-demand re-discovery has to stop Klipper first.

Design concept for V1:

- **Own the `[mcu]` sections.** A first-boot (and on-demand) discovery service enumerates `/dev/serial/by-id/usb-Klipper_*` and `usb-katapult_*`, queries the CAN bus for UUIDs, then *generates* `mcus.cfg` containing the `[mcu]` / `[mcu toolhead]` blocks. The user's `printer.cfg` keeps everything else and gains one `[include mcus.cfg]`. The seeding step comments out existing `[mcu*]` blocks in the imported file and reports what it did. Klipper's `SAVE_CONFIG` block must stay at the bottom of `printer.cfg`; includes elsewhere are fine.
- **Stable role names via udev.** Assign `/dev/klipper-main`, `/dev/klipper-toolhead0` from VID/PID + serial once a role is known, so `mcus.cfg` never has to change again. FlyOS's own rules are thin ([`98-flyos-serial.rules`](teardown/flyos-glue.md#udev-rules) just maps non-8250 `ttyS*` to `/dev/serialN`; `97-flyos-usb.rules` handles the STM32 HID bootloader and USB storage automount) — there's little to copy, this is new work.
- **Report, don't guess.** When discovery finds two identical boards and can't tell which is the toolhead, write both into `mcus.cfg` commented with their descriptors and surface a clear message (Moonraker announcement + a file on `/config`). Silent wrong guesses are worse than a one-line manual edit. Heuristics that are usually right and can be offered as defaults: a lone USB Klipper device is the main MCU; a CAN node whose MCU type is a G0/G4/RP2040 class part alongside a larger F4/H7 main is the toolhead.
- Ambiguity resolution belongs in the config file too: let `kos.conf` pin `main_mcu_serial=` / `toolhead_uuid=` when the user already knows.

**Built, with a design change (`overlay/usr/lib/kos/kos-mcu-discover`):** the generated-`mcus.cfg` approach above was replaced by **rewriting stale values in place**. Reason: a user's config names its MCUs (`[mcu EBBCan]`) and every pin in the file references that name (`EBBCan:PB5`); moving the section into a generated file would either break those references or force a rename. In-place editing keeps the user's names, `restart_method` lines and comments, and needs no `[include]`. The rules:

- Runs on every boot before `klipper.service`, as the `klipper` user, over every `*.cfg` under `printer_data/config`. Waits up to 15 s for USB enumeration / `can0`.
- A value is *stale* only if it is a `/dev/serial/by-id/...` path that does not exist or a `canbus_uuid` that did not answer `canbus_query.py`. Non-by-id serials (`/tmp/klipper_host_mcu`, `/dev/ttyAMA0`) are never touched, nor is anything outside an `[mcu ...]` section.
- A stale value is replaced only when exactly one *unused* candidate of the same kind exists, or `kos.conf` pins one (`main_mcu_serial=`, `toolhead_uuid=`). Two candidates → nothing is written and `MCU-DISCOVERY.txt` (written to both `printer_data/config/` and `/config/`) lists them.
- Before rewriting, the original is saved as `<file>.orig`.
- Consequence: a config imported from another machine is fixed on the first boot with no user action, which is the §1 acceptance test. A config that is already correct is a no-op every boot. A temporarily unplugged toolhead is not "fixed" because there is no candidate.
- Self-test: `kos-mcu-discover --test` covers rewrite, no-op, ambiguity, pin, and missing-device cases.

Skipped, deliberately: the `/dev/klipper-main` udev role symlinks. by-id paths are already stable per board, and in-place rewriting means the config never has to change again anyway. Add them only if a real config needs a device path that is not a by-id path.

## 9. CAN bus

Neither CM5 nor CB1 has a native CAN controller, so this is USB (`gs_usb`: candleLight, BTT U2C, or a main board in bridge mode) or SPI (`mcp251x` / `mcp251xfd`). Verified: all three are `=m` in Raspberry Pi's `bcm2712_defconfig` and `bcm2711_defconfig` (rpi-6.12.y) and in Armbian's `linux-sunxi64-current.config`. No kernel work needed; just don't prune them.

Bring-up should be declarative, exactly as FlyOS does it:

- [`99-can.network`](teardown/flyos-glue.md#network-files): `[Match] Name=can*` + `[CAN] BitRate=1000000, RestartSec=100ms`
- [`99-can-link.link`](teardown/flyos-glue.md#network-files): `TransmitQueueLength=1024` — the queue-length bump that everyone otherwise discovers the hard way after random `Timer too close` errors. Klipper's docs say 128; FlyOS uses 1024; the CB1-on-mainline write-up that ran for months used 128. Either works, the default of 10 does not.
- Bitrate is user-settable and rewritten in place from the config file (`flyos-config:78-93`); it must match the toolhead firmware, so expose it prominently (FlyOS defaults to 1 Mbit)

Discovery (§8) should query CAN UUIDs after the interface is up, and ordering must guarantee that happens before `klipper.service` starts. If NetworkManager owns the box, still let `systemd-networkd` own `can*` (NM ignores CAN links) — that's what FlyOS does, both are enabled.

## 10. Real-time tuning — the highest-value thing to copy, with one correction

FlyOS pins Klippy to an isolated core:

- Kernel args: `nohz=on nohz_full=3 rcu_nocbs=3 isolcpus=3`, `cpufreq_default_governor=performance` ([`boot.scr.txt:97-98`](teardown/flyos-glue.md#boot))
- Unit: `CPUAffinity=3`, `Nice=-18`, `IOSchedulingPriority=2` ([`klipper.service:14-16`](teardown/flyos-glue.md#klipperservice)), Moonraker at `Nice=-18`, `IOSchedulingPriority=2` (`moonraker.service:14-15`)
- IRQ steering by mask (`flyos-init-hard:27-31`, the same lines as Armbian's `armbian-hardware-optimization`): USB to CPUs 1 and 2, but MMC and ethernet to CPU 3 (mask 8), the core it reserves for Klippy

Correction: **`nohz_full=` and `rcu_nocbs=` are inert on both stock kernels.** Neither Raspberry Pi's 6.12 defconfigs nor Armbian's sunxi64-current config set `CONFIG_NO_HZ_FULL` or `CONFIG_RCU_NOCB_CPU` (checked 2026-09-03; both have `CONFIG_NO_HZ=y` = idle-only, and `CONFIG_PREEMPT=y`). `isolcpus=3` works everywhere. What actually ports:

- `isolcpus=3` in `cmdline.txt` (Pi) / `armbianEnv.txt` `extraargs=` (CB1), plus `CPUAffinity=3` in the unit. That is the measurable part.
- Governor: the mainline parameter is `cpufreq.default_governor=performance`; FlyOS's `cpufreq_default_governor=` spelling is either a BSP patch or a no-op on their kernel, don't copy it. On CB1 Armbian defaults to `ondemand` with a 480 MHz floor — set `performance` or raise the floor, both via `/etc/default/cpufrequtils`.
- IRQ affinity: a small oneshot like `flyos-init-hard`, driven by `/proc/interrupts` names, not hardcoded numbers.
- Building our own kernel to get `NO_HZ_FULL` is V2 at most; it also means owning kernel updates.

Both targets are quad-core (CM5: 4× Cortex-A76; CB1: 4× Cortex-A53 @ 1.5 GHz), so core 3 exists on both.

## 11. Services and network posture

Keep the service set small: klipper, moonraker, nginx, NetworkManager, systemd-networkd (CAN only), sshd, avahi-daemon. Optional by config: crowsnest, klipper-mcu (Klipper's Linux host MCU — useful for host GPIO / SPI accelerometer / host temperature), a screen stack in V2.

Discovery for the headless acceptance test: `avahi-daemon` publishing `<hostname>.local`. FlyOS leaves `[zeroconf]` commented out (`config/moonraker.conf:9-10`) and instead prints the IP on a splash screen we don't have. KOS dropped Moonraker's `[zeroconf]` too (2026-10-21): with Moonraker on loopback it would advertise `127.0.0.1:7125`.

Do **not** copy FlyOS's network posture. Their image ships the same root password on every unit, a web terminal with no authentication of its own in front of that root login (in effect a root shell for anyone on the network), and a Moonraker that trusts every address and every origin (inventory §9, [`moonraker.conf`](teardown/flyos-glue.md#moonrakerconf)). KOS ships no web terminal. For us: no default root password, key-based SSH or first-boot-set credentials from `kos.conf`, and a `trusted_clients` list generated from the actual LAN prefix at first boot (fall back to RFC1918 + link-local, which is what Moonraker's own installer suggests).

Moonraker needs `sudo` for its `[machine]` component (reboot, service control; `provider: systemd_dbus` is preferable to FlyOS's `systemd_cli`) — another reason Debian.

**Built:** user `klipper` (uid 1000, groups `sudo dialout tty video plugdev moonraker-admin`, `NOPASSWD` sudo as every Klipper distro does), root locked. Password locked (`usermod -p '*'`, not `passwd -d`: an empty password let any local account `su klipper`) until `kos.conf` sets `password=`. Physical access is treated as ownership: `getty@tty1` autologs in as `klipper` so a monitor and keyboard always work when the network does not. Moonraker runs with `provider: systemd_dbus`; the polkit rule (`overlay/etc/polkit-1/rules.d/moonraker.rules`) is Moonraker's own action list simplified to `subject.user == "klipper"`, because the upstream `moonraker-admin` group check only matters on a shared workstation. `trusted_clients` is the static RFC1918 + link-local list from Moonraker's installer rather than a prefix derived at first boot — deriving it needs the network up first and would wrongly lock out a laptop on a second subnet; the static list is the same trust level every other Klipper image ships. `[zeroconf]` on, avahi on, nginx on :80 serving Mainsail (`overlay/etc/nginx/sites-available/mainsail`, upstream's site with `access_log off`). Wi-Fi power save is disabled globally via a NetworkManager drop-in, not per connection.

**Network hardening after the security review (2026-10-21).** A LAN client that Moonraker trusts is root-equivalent (config uploads can add `[update_manager]` entries, and `klipper` has `NOPASSWD` sudo); SECURITY.md says so, and an opt-in login is the planned fix. Until then the job is to keep *non*-LAN parties from borrowing a LAN browser:
- Moonraker binds `127.0.0.1`; nginx on :80 is the only entry. nginx answers only when `Host` is an IPv4 literal, the hostname, `<hostname>.local`, `localhost` or a name in `kos.conf`'s `allowed_hosts=` (421 otherwise: DNS rebinding), and the API and websocket locations reject an `Origin` that is neither the request's own host nor a listed name (403: cross-site POSTs, which Moonraker itself only uses to decide on CORS headers). Requests with no `Origin` (slicers, curl) pass. `overlay/etc/nginx/conf.d/kos-hosts.conf` holds the maps; `kos-config` writes the names to `/etc/kos/nginx-hosts.map` each boot. `my.mainsail.xyz`/`app.fluidd.xyz` are gone from `cors_domains`. Checked by `tests/nginx_docker.sh`.
- IPv4 only: `ipv6.disable=1` on both kernel command lines, nginx `listen 80` only, sshd `AddressFamily inet`, avahi `use-ipv6=no`, NetworkManager profiles with `ipv6.method=disabled` (`kos-ethernet` keyfile, `no-auto-default=*`; `kos-wifi` set by `kos-config`). This also settles the RTL8189FS-and-RA concern in §16.3.
- SSH: `kos.conf` is the only key source. `sshd_config.d/kos.conf` sets `AuthorizedKeysFile /etc/kos/authorized_keys/%u` (root-owned, rewritten from every `ssh_key=` entry at boot, so removing a line revokes the key) and `PermitRootLogin no`. One entry may hold several keys (continued with `\`); each is checked with `ssh-keygen -l` and an invalid one is skipped with a warning. `kos-ssh-key add|list|remove` edits `kos.conf` and rewrites the file at once. The image carries no host keys (`customize.sh` removes them); an `ssh.service` drop-in runs `ssh-keygen -A` before `sshd -t`, independent of `kos-config`.

## 12. Updates

Two lanes, deliberately different from FlyOS:

- **OS:** `apt`. That's the whole point of the Debian decision. Kernel comes through the same channel: Raspberry Pi's apt repo on CM5/CM4, Armbian's on CB1. Armbian's repo is pinned (`/etc/apt/preferences.d/kos-armbian`) to supply only `linux-image-*`, `linux-dtb-*` and `linux-u-boot-*`: it also carries `base-files`, `bluez` and firmware that would otherwise replace Debian's. Its key is committed (`build/boards/cb1/armbian.asc`) and its fingerprint checked at build time and in `tests/run.sh` (`pgp-fpr.py`); the Raspberry Pi keyring `.deb` is fetched over https, checked against a pinned sha256, and its `trusted.gpg.d` copy is excluded so the key only signs the Raspberry Pi source.
- **Security updates, automatic (2026-10-21):** `unattended-upgrades` restricted to `trixie-security`, `Automatic-Reboot "false"`, run by `kos-security-updates.timer` (1 h after boot, then a day after the last run, randomized by up to 1 h) instead of the masked `apt-daily*` timers. The service's `ExecCondition` is `kos-printer-idle`, which asks Moonraker on localhost and lets the run proceed only when Klippy is shut down, or ready with `print_stats` not printing/paused and `idle_timeout` not busy; unreachable Moonraker, startup or error means skip. It refreshes the apt lists, then runs `unattended-upgrade` at `Nice=19`, idle I/O. Debian maintainer scripts still restart an upgraded daemon (nginx, sshd); nothing reboots, and Klipper/Moonraker are not touched.
- **Klipper/Moonraker/Fluidd:** install as real git checkouts so Moonraker's `update_manager` works. FlyOS strips all `.git` metadata (inventory §6), which is why their only update path is the signed-7z OTA blob in `flyos-fast-ota` — a Go binary with no published source. We can't reproduce that and shouldn't want to.

The cost is disk (shallow clones keep it small; `update_manager` copes with `--depth`) and the fact that users can update themselves into a broken state. Acceptable; that's how every other Klipper distro works.

## 13. Worth stealing from their patches

The patch analysis (inventory §7, [vendor patches](teardown/flyos-glue.md#vendor-patches)) separates Fly-hardware code from generally-useful fixes:

- `power_loss_resume.py` + the heavy `virtual_sdcard.py` rewrite — power-loss recovery. High value on a printer, but it's a large patch against a moving upstream file; treat as opt-in, not baked in.
- Moonraker `machine.py` SD-device fix — resolves the root device via `findmnt`/`lsblk` instead of hardcoding `mmcblk0` ([Moonraker patch](teardown/flyos-glue.md#moonraker-patch)). Still relevant: upstream `master` hardcodes `/sys/block/mmcblk0/device/cid` as of 2026-09-03. Effect on us is cosmetic (SD info panel in the UI), so: carry it as a small patch, or upstream it, but don't block on it. On CM5 with eMMC the root *is* `mmcblk0`, so the stock code happens to work there.
- `filament_blockage_detection` — self-contained, opt-in, needs its MCU-side `.c` compiled into the toolhead firmware, so it's really a firmware-build option.
- Skip: `fly_lcd` (both sides), the OTA client, KlipperScreen theming, and the host↔MCU communication patches (`mcu.py`/`serialhdl.py`/`src/*.c` are patched together, so they only make sense with Fly-built firmware).

## 14. Board support matrix

| Board | SoC / arch | Kernel source | Boot mechanism | Boot partition | Tested |
|---|---|---|---|---|---|
| RPi CM5 | BCM2712, 4× A76, arm64 | Raspberry Pi `linux-image-rpi-2712` (**6.18.39** in `archive.raspberrypi.com` trixie as of 2026-09-03; 6.12 is what the trixie launch shipped) | SPI EEPROM bootloader → files on first FAT partition | FAT: firmware, `config.txt`, `cmdline.txt`, `kernel_2712.img`, `initramfs_2712`, `bcm2712-rpi-cm5-*.dtb` | yes (have hardware) |
| BTT CB1 | Allwinner H616, 4× A53 @ 1.5 GHz, arm64, 1 GB | Armbian `linux-image-current-sunxi64` (mainline 6.18.x; board status "Standard", family `sun50iw9`) | U-Boot SPL at raw 8 KiB (or 256 KiB) → `boot.scr` on FAT | FAT labelled `BOOT`: `Image`, `sun50i-h616-bigtreetech-cb1-sd.dtb`, `boot.scr`, `armbianEnv.txt` | yes (have hardware) |
| RPi CM4 | BCM2711, 4× A72, arm64 | Raspberry Pi `linux-image-rpi-v8`, same repo as CM5 | on-board EEPROM bootloader → first FAT partition | FAT: `kernel8.img`, `bcm2711-rpi-cm4.dtb` | **no hardware — build only, mark untested** |

CB1 notes, resolving the old open question:

- **Built: `/boot` lives on the ext4 root, not on the FAT partition.** This diverges from Armbian's CB1 board config (`BOOTFS_TYPE="fat"`) on purpose. U-Boot's distro boot scans partitions in order for `boot.scr`, skips the `KOS` FAT partition (no boot script there) and finds `/boot/boot.scr` on p2; the only difference from a stock Armbian sunxi image is the partition number. Reasons: kernel `.deb` postinst hooks and `update-initramfs` create symlinks (`Image`, `uInitrd`, `dtb`) that FAT cannot hold, so `apt upgrade` of the kernel would need FAT-specific copy hooks; and the user-editable FAT partition already exists for `kos.conf`. Two hooks are shipped to keep the symlinks right regardless of what Armbian's own postinst does: `/etc/kernel/postinst.d/zz-kos` and `/etc/initramfs/post-update.d/99-uboot` (Armbian's, minus its `/etc/armbian-release` dependency). Boot script is Armbian's `boot-sun50i-next.cmd` verbatim (`build/boards/cb1/boot.cmd`), compiled at build time. `armbianEnv.txt` sets `rootdev=LABEL=KOS-ROOT`, the CB1 DTB, and `extraargs=isolcpus=3 cpufreq.default_governor=performance video=HDMI-A-1:d`. Packages come from Armbian's trixie apt repo: `linux-image-current-sunxi64` 26.8.3 (kernel 6.18.44), `linux-dtb-current-sunxi64`, `linux-u-boot-bigtreetech-cb1-current` (U-Boot 2026.07), written at 8 KiB per `sunxi64_common.inc`. Armbian's BSP package (`armbian-bsp-cli-bigtreetech-cb1`) is *not* installed; it would pull in armbian-config, ramlog, zram-config, motd scripts and its own governor defaults.
- Use Armbian's mainline kernel, not BTT's `CB1-Kernel` fork (a 5.16 BSP tree that is effectively unmaintained). Armbian's CB1 config is maintained upstream, offers `current` and `edge`, and its trixie images are what the "mainline Armbian on CB1" community reports are based on (months of printing, one TTC in ~200 h).
- Wi-Fi is a Realtek RTL8189FS (SDIO) with an **out-of-tree** driver. Armbian builds it in (`CONFIG_RTL8189FS=m`, source pulled from `EvilOlaf/rtl8189ES_linux` at kernel build time). Using Armbian's kernel package gets the driver for free; building our own kernel would mean carrying that driver too. First-boot Wi-Fi flakiness on CB1 is a known forum topic; wired is the safe default for the acceptance test.
- FlyOS has no CB1/H616 code, only the H618 block-device naming in `flyos-blk-links`. Nothing to port.

**Built (`build/boards/cm5/`):** one Pi image carries both `linux-image-rpi-2712` and `linux-image-rpi-v8`, so the same card boots a CM5 (`kernel_2712.img`) or a CM4 (`kernel8.img`); the firmware picks. That is how Raspberry Pi OS does it and it costs one extra module tree. Mechanism is Raspberry Pi's own `raspi-firmware` 1.20260521-3: its `/etc/kernel/postinst.d/z50-raspi-firmware` copies `vmlinuz-*-rpi-2712` to `/boot/firmware/kernel_2712.img` plus `bcm27*.dtb` and overlays, and `/etc/initramfs/post-update.d/z50-raspi-firmware` copies the initrd to `initramfs_2712`; `config.txt` has `auto_initramfs=1`. Order matters in the chroot: `raspi-firmware` is installed *before* the kernels so those hooks exist when the kernel postinst fires (the firmware package re-triggers the kernel hook for already-installed kernels, but not the initrd one). `config.txt` and `cmdline.txt` are ours (`rpi-image-gen`'s templates, trimmed; `root=LABEL=KOS-ROOT`, same `isolcpus`/governor/`video=` args as CB1, `dtoverlay=vc4-kms-v3d` commented out for `display=none`). Layout: p1 `KOS-BOOT` FAT32 256 MB at `/boot/firmware`, p2 `KOS`, p3 `KOS-ROOT` 3 GiB, p4 `KOS-DATA` — all four MBR primaries used. The rootfs is identical to CB1's; `in-container.sh` moves `/boot/firmware/*` out of the rootfs onto p1 at assembly (`BOARD_BOOTFAT_DIR`). `firmware-brcm80211` included for the wireless CM5/CM4 variants. Not included: `rpi-eeprom` (bootloader updates are V2), `raspberrypi-sys-mods`.

Be explicit in release notes about which artifacts were actually booted. An untested-but-built CM4 image is fine as long as it says so.

## 15. Open questions

Resolved since the first draft (see §14, §2): CB1 kernel provenance (Armbian mainline), CM5 suite (trixie, Pi kernel 6.18).

Still open:

- **MBR or GPT.** Pi 5 firmware boots GPT fine as long as the partition entry array sits at the standard LBA 2. H616 can boot from 256 KiB, clear of a GPT array, but that needs a U-Boot with the H616 high-offset fix and departs from Armbian's 8 KiB/MBR layout. GPT unlocks `systemd-repart` and clean A/B labels; MBR is what every existing image on both boards uses. **Decided for V1: MBR + `growpart`** (`build/mkimage.py` writes the MBR itself; three partitions, see §7). Revisit only if A/B becomes a V2 priority.
- **Project name: settled 2026-10-19 as KOS** (Kos, the Greek island; a nod to Klipper). Renamed from the working name "klipperOS" across `build/`, `overlay/`, `tests/` and docs: labels `KOS-BOOT`/`KOS`/`KOS-ROOT`/`KOS-DATA`, `kos.conf`, `/usr/lib/kos/`, `kos-*` tools and units, default hostname `kos`. The `out/` images from 2026-09-03 predate the rename. Licensing is settled: AGPL-3.0-or-later (`LICENSE`).
- **Decided 2026-10-20: boot media.** V1 is tested on SD only. eMMC (CM5 non-Lite, flashed with `rpiboot`) and NVMe may be documented, but every such instruction carries an "untested" warning: the owner has no eMMC CM5 and the Mantas have no NVMe slot. (- Boot media matrix: CB1 is SD-only in practice (its DTB name even says `-sd`); CM5 adds eMMC and NVMe. Does V1 support NVMe root, or SD only?)
- **Resolved 2026-10-19: Klipper host MCU.** Built into the image (`/usr/local/bin/klipper_mcu`, Klipper's own `klipper-mcu.service`); `kos-config` enables it each boot only when a `*.cfg` references `klipper_host_mcu`. First real config tested (Sindri) uses `[mcu host]`.
- **Decided 2026-10-20: boot smoke testing** stays manual, on the owner's own hardware (CM5 Lite + Manta M5P, CB1 + the same M5P, CM5 + Manta M8P), with the serial console on the Manta Type-C for boots that fail before the network. No other test hardware exists. (- Boot smoke testing: how an image gets verified on real hardware without a person plugging in cards.) The build half is settled — `.github/workflows/weekly.yml` builds both boards on native arm64 runners every week as a `weekly-YYYYMMDD` prerelease, and `release.yml` republishes a weekly that passed the hardware smoke test under a `v*` tag (§21.5).
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
| Moonraker `EVENT LOOP BLOCKED` count and duration | `moonraker.log` | the UI failure mode, see §17 — a blocked loop drops websockets |
| `files.get_directory` and `files.list` latency on the gcodes root | `curl -w %{time_total}` | dominates perceived UI speed once a library exists |
| Websocket survival over 10 min, two concurrent clients | ping/pong client | reproduces "second tab kills the first" |
| Gcode upload throughput, 50 MB file | `curl -T` wall time | 100 Mbit link on CB1, plus upload-time metadata cost |

Baseline to beat: stock Armbian minimal (trixie, `current` kernel) + KIAUH-installed Klipper on the same CB1. If an option doesn't move a metric, it doesn't go in the image.

**The benchmark fixture must include a realistic gcode library.** Measured on a live CB1 (Armbian 26.5.1, kernel 6.6.66-vendor-sunxi64) on 2026-09-03: with 1,234 gcode files flat in the gcodes root plus 3,693 thumbnails (8.2 GB), a single `files.get_directory?extended=true` on that root takes **4.4 s of CPU** and blocks Moonraker's event loop for that whole time. The same call on a 3-file subfolder takes **0.027 s**. An empty-library benchmark would have shown none of this and would have validated an image that falls over in real use. Populate the fixture before trusting any number in this section.

### 16.2 Display and desktop: off by config

V1 ships no Xorg/Wayland/GTK, so there is nothing to disable in userland yet. The knob still matters now, for two reasons: the *kernel* side (DRM, HDMI, GPU, CMA reservation) is present regardless of userland, and V2 screen support must not make headless users pay for it. So define the option in V1 and make first boot honour it on both boards:

```
# kos.conf
display=none        # none | hdmi | <panel-id in V2>
```

`display=none` means, per board:

- **CB1** — `extraargs=video=HDMI-A-1:d` in `armbianEnv.txt`, plus a modprobe blacklist for `sun4i_drm`, `sun8i_mixer`, `sun8i_drm_hdmi`, `lima`/`panfrost`. **Checked in the built image: Armbian's 6.18.44 config has `CONFIG_DRM_SUN4I=y` (built in), so the blacklist is inert for the display engine itself and only `video=HDMI-A-1:d` acts; `CONFIG_CMA_SIZE_MBYTES=64`.** Candidate to measure on hardware: `initcall_blacklist=sun4i_drv_platform_driver_init` on the command line, which stops a built-in driver from binding at all. Not baked in until `Cma` in `/proc/meminfo` shows it is worth it. FlyOS does the equivalent in U-Boot: `fdt set /soc/hdmi@1ee0000 status "disabled"` whenever `screen` is not `hdmi` ([`boot.scr.txt:126-131`](teardown/flyos-glue.md#boot)), and shrinks the framebuffer reservation with `sunxi_fb_mem_reserve=32` (`:96`). On mainline the reservation is CMA; check `cat /proc/meminfo | grep Cma` before and after — expect tens of MB back on a 1 GB board.
- **CM5/CM4** — omit `dtoverlay=vc4-kms-v3d` from `config.txt`, same `video=HDMI-A-1:d` in `cmdline.txt`, blacklist `vc4`/`v3d`. Pi 5 firmware no longer honours `gpu_mem`, so the DT overlay is the only lever.
- **Both** — keep `getty@tty1` (it costs nothing and is the debug path when networking fails), `consoleblank=0` so a monitor plugged in later still shows the console, and mask any display unit V2 adds (`klipperscreen`, a display manager) with `systemctl mask` from the same first-boot unit that reads the key.

`display=hdmi` in V1 does nothing beyond leaving the kernel defaults alone; it exists so V2 has a value to grow into without changing the file format.

### 16.3 CPU scheduling

- **Core isolation** — `isolcpus=3` + `CPUAffinity=3` on `klipper.service` (§10). Measure: `srtt` spread and TTC count with and without. This is the single highest-expected-value change on CB1.
- **Governor** — Armbian ships `ondemand` with a 480 MHz floor on `sun50iw9` (`CPUMIN=480000`, `CPUMAX=1512000`). Options: `performance` (simplest, costs a few hundred mW), or `ondemand` with the floor raised to ~800 MHz (the mainline-CB1 community setting). Compare power/thermal on the SoM: the H616 throttles under a heatsink-less Manta enclosure; check `/sys/class/thermal` during the print.
- **IRQ affinity** — keep USB (CAN adapter, main MCU), MMC and ethernet IRQs off core 3; FlyOS gets this wrong: it puts USB on cores 1–2 but MMC and ethernet on core 3 (mask 8, `flyos-init-hard:27-31`), the Armbian default. On CB1 the names in `/proc/interrupts` are `sunxi-mmc`, `ehci_hcd`/`ohci_hcd`/`musb-hdrc`, `eth0`/`end0`; on CM5 they live behind the RP1 (`rp1_*`). Match by name, never by number.
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

## 17. Gcode library management — archive printed files

The single largest UI performance problem on a real printer is not the kernel, the governor, or the network. It is the size of the gcode root directory. Diagnosed end-to-end on a live CB1 on 2026-09-03:

```
1,234 gcode files flat in gcodes/ + 3,693 thumbnails, 8.2 GB
  → files.get_directory(gcodes, extended) = 4.4 s, CPU-bound, warm cache
  → Moonraker is single-threaded asyncio, so that runs inside the event loop
  → "EVENT LOOP BLOCKED: 12.58 seconds"
  → the pending websocket pong goes unread
  → "Websocket Closed: Pong Time Elapsed: 16.99"
  → the UI shows a connection failure and the user hits retry
```

Causation was confirmed by hitting that one endpoint three times and observing the blocked counter advance by exactly three, with durations (4.37/4.39 s) matching the request times. Repeat calls were identical warm, so the cost is CPU, not SD I/O. Every other Mainsail startup endpoint answered in 12–45 ms. This also explains "opening a second tab disconnects the first": both clients share one event loop, so the second tab's file listing starves the first tab's keepalive.

**Design goal: the gcode root stays small forever, without the user curating it.** Files that have been printed successfully get filed into `Printed/YYYY/MM/`, leaving the root as a handful of folders plus not-yet-printed files.

### 17.1 Where the trigger lives

Not a Klipper macro, despite being the obvious place to put it. Two hard reasons:

- Klipper has no file-management G-code. Moving a file requires either a third-party `[gcode_shell_command]` extension or an HTTP call, and Klipper can do neither natively.
- `PRINT_END` runs while the job is still open from Moonraker's perspective — `virtual_sdcard` still holds the file and history has not been finalised. Moving there is a race.

The correct trigger is Moonraker's own job history. A small service subscribes to the local Moonraker websocket, watches `notify_history_changed` for `action: finished`, and acts only when `status == "completed"`. This needs no macro in `printer.cfg` at all, which also means nothing to break when a user imports their own config — the §1 acceptance test stays intact.

If a macro-driven variant is wanted later, `PRINT_END` can call a `FILE_ARCHIVE` remote-method that just enqueues the request for the same service, keeping the race out of the critical path.

### 17.2 Mechanism

- **Move via `POST /server/files/move`, never `mv`.** The API is what keeps Moonraker's metadata database and file index consistent with the filesystem. A raw `mv` relies on the inotify watcher to reconcile and is the wrong contract.
- **Date comes from the job's end time in history, not `now()`.** Makes the operation deterministic and lets a backfill reproduce exactly the same tree.
- **Only successful jobs move.** `cancelled`, `error`, `klippy_shutdown`, `interrupted` stay in the root — a failed print is usually about to be re-run.
- **Skip anything still referenced by `[job_queue]`.** Check before moving.
- **Path template is a config value, not a constant, and the date sharding is mandatory.** A flat `Printed/` folder does not solve the problem — it moves the 4.4 s stall to whenever the user opens that folder (§17.3, measured). `Printed/YYYY/MM/` is the default; the key belongs in `kos.conf` alongside the rest of the provisioning surface (§5):

```
# kos.conf
archive_printed=on                       # on | off
archive_path=Printed/{year}/{month}/     # tokens: year, month, day
```

- **Ship a backfill.** New users are the easy case; the hard case is the machine that already has 1,234 files. A one-shot `kos-archive --backfill` walks Moonraker history and files everything retroactively, dry-run by default.

Size estimate: this is roughly 60 lines of Python plus a systemd unit. It is not a Moonraker component — keeping it a separate process means a crash in the archiver cannot block Moonraker's event loop, which is the exact failure this feature exists to prevent.

**Built (`overlay/usr/lib/kos/kos-archive`, ~110 lines, stdlib only):** it **polls** `GET /server/history/list` every 60 s instead of subscribing to `notify_history_changed` over the websocket. The websocket needs a client library the archiver would otherwise not need, and a one-minute delay before a finished file is filed is invisible to the user. State is the last-seen `job_id` in `printer_data/.kos-archive.last`, so a restart never re-walks history. `--backfill` ignores the state and walks everything (`--dry-run` to preview); `--once` for cron-style use. Collision policy decided: numeric suffix (`part-2.gcode`, `part-3.gcode`), never overwrite, checked against a `files/directory` listing of the small destination folder. Files already under the archive folder, non-`completed` jobs, jobs whose file no longer exists, and anything in the job queue are skipped. Enabled/disabled each boot from `archive_printed=` in `kos.conf`; `archive_path=` is the template. Self-test runs against an in-process fake Moonraker.

### 17.3 What this does and does not fix — measured, not assumed

Validated on the live CB1 on 2026-09-03 by actually moving all 1,234 files into a subfolder and re-measuring:

| Call | Flat root | After foldering |
|---|---|---|
| `files.get_directory` on the gcodes root (UI browse) | 4.47 s / 1.5 MB | **0.023 s / 323 B** |
| `files.list?root=gcodes` (recursive) | 3.56 s | **4.21 s — unchanged** |
| `files.get_directory` on the now-flat `printed/` | — | **4.47 s / 198 KB** |

Three conclusions, each load-bearing for the design:

- **The retry prompt is genuinely fixed.** Before, the two slow calls stacked into a single 12.58 s block, which exceeded Moonraker's pong deadline and the server killed the socket (`Close Code: None`). After, the worst block is 4.4–6.4 s, under the deadline, and every observed close is now `Close Code: 1001` — the browser closing normally. The failure mode is gone, not merely rarer.
- **The recursive listing is confirmed on the startup path.** Emptying the gcodes root entirely made the UI load fast; moving the same files into a subfolder left a ~4.2 s stall. That difference is only explicable if a startup call walks the whole tree. This settles the question that could not be answered from the nginx access log, since the web clients issue file RPC over the websocket.
- **Sharding by date is required, not cosmetic.** Browsing into a flat `printed/` reproduces the original 4.47 s stall exactly. A single `Printed/` folder relocates the problem to the moment the user clicks it. `Printed/YYYY/MM/` keeps every directory small enough to stay in the tens-of-milliseconds range.

Residual after this feature ships: a ~4 s one-off stall at UI connect, scaling with total file count regardless of layout. Removing that needs files off the card, so V2 owes a retention policy — age out to USB/NAS, or prune. Track it as the next item once the archiver lands.

### 17.4 Must verify on hardware before shipping

Three unknowns, each of which could turn this from a win into a support burden:

- **Thumbnails follow the file.** 3,693 of the 4,935 files in that library are `.thumbs/*.png`, stored per-directory. If `files/move` does not relocate the associated thumbs, the root file count barely drops and orphaned thumbnails accumulate. This is the highest-risk item.
- **History "reprint" still works after a move.** If Moonraker's history entries keep the pre-move path, the reprint button breaks for every archived job. That would be a worse user experience than the stall being fixed.
- **Collision policy.** The same file printed twice lands on an existing destination. Decide between skip-if-identical and a numeric suffix; do not let the move fail silently.

## 18. Explicitly not in V1

A/B root slots, OTA, read-only root/overlayfs, KlipperScreen or any GUI, DSF/RRF support, the combined dual-board card, camera stack on by default, MCU firmware flashing from the host, a custom kernel build.

Each of these has a hook left in the design (partition layout, config-file keys, service gating) so V2 doesn't require re-imaging anyone.

## 19. Reference index

| Concept | Where to read it |
|---|---|
| Pre-systemd init, overlay mounts, partition growth | [`flyos-init`](teardown/flyos-glue.md#flyos-init) (`:39-102` grow, `:153-196` overlays, `:18,120` mount options) |
| First-boot seeding from FAT partition | [`flyos-firstrun:3-21`](teardown/flyos-glue.md#flyos-firstrun) |
| Config-file-driven provisioning (Wi-Fi, TZ, CAN, board) | [`flyos-config`](teardown/flyos-glue.md#flyos-config) (`:60-76` timezone, `:78-93` CAN bitrate, `:95-118` chattr, `:159-202` Wi-Fi) |
| Hostname, machine-id reset, UI database seeding | [`flyos-set-hostname`](teardown/flyos-glue.md#flyos-set-hostname) |
| zram swap, `/var/log` on zram, journald cap | [`flyos-init-zram`](teardown/flyos-glue.md#flyos-init-zram) |
| Governor and IRQ affinity | [`flyos-init-hard`](teardown/flyos-glue.md#flyos-init-hard) |
| User-facing config surface | [`config.txt`](teardown/flyos-glue.md#configtxt) |
| Config → U-Boot env → kernel cmdline | [`boot.scr.txt:52-54, 84-101, 124-125`](teardown/flyos-glue.md#boot) |
| Service gating on cmdline flags | [`klipper.service:7`](teardown/flyos-glue.md#klipperservice), `klipper-mcu.service:7-8` |
| Real-time pinning | `boot.scr.txt:97-98` + `klipper.service:14-16` + `moonraker.service:14-15` |
| CAN bring-up | [`99-can.network`](teardown/flyos-glue.md#network-files), `99-can-link.link` |
| Stable block-device naming, sunxi H3/H5/H618 handling | [`flyos-blk-links`](teardown/flyos-glue.md#flyos-blk-links) |
| Boot/config partition mounting | [`flyos-mounts`](teardown/flyos-glue.md#flyos-mounts) |
| Web stack config (nginx site is upstream-standard) | [the web server files](teardown/flyos-glue.md#web-server) |
| Moonraker config as shipped (open trust, zeroconf off) | [`moonraker.conf`](teardown/flyos-glue.md#moonrakerconf) |
| Moonraker SD-device fix | [Moonraker patch](teardown/flyos-glue.md#moonraker-patch) |
| Full teardown, versions, patch analysis | `docs/teardown/FlyOS-Fast-1.3.8-inventory.md` |

## 20. Validation log

2026-09-03 — every file/line reference above was re-read from the extracted vendor files (described in [`teardown/flyos-glue.md`](teardown/flyos-glue.md)) and the inventory; external claims were checked against upstream sources. What changed from the first draft:

| Claim | Was | Now | Source |
|---|---|---|---|
| Base suite | bookworm unless forced | trixie | Debian 13 stable since 2025-08; Raspberry Pi OS is on trixie; Armbian CB1 images are trixie |
| Builder | mmdebstrap / pi-gen / Armbian, pick one | mmdebstrap; copy `rpi-image-gen`'s Pi layer | github.com/raspberrypi/rpi-image-gen |
| FlyOS root size | 620 MB | 620 MB compressed, 3.1 GB on disk | `7zz l parts/2.img`, `du -sh rootfs` |
| CB1 boot offset | "raw sector offset" | 8 KiB, with 256 KiB fallback on H616 (128 KiB is older sunxi) | U-Boot sunxi docs; linux-sunxi BROM page |
| CB1 boot partition | unspecified | FAT, label `BOOT`, `boot.scr` + `armbianEnv.txt` | `armbian/build config/boards/bigtreetech-cb1.conf` |
| CB1 kernel | open question | Armbian mainline 6.18 `current`, board "Standard"; Wi-Fi RTL8189FS out-of-tree, bundled by Armbian | armbian.com/bigtreetech-cb1, `linux-sunxi64-current.config`, `drivers_network.sh` |
| CM5 kernel | "6.6+" | Raspberry Pi `linux-image-rpi-2712` on trixie; 6.12 at the trixie launch, **6.18.39** as of 2026-09-03 | `archive.raspberrypi.com` trixie `Packages` |
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

2026-09-03, later, while implementing:

| Claim | Checked | Source |
|---|---|---|
| Armbian trixie repo carries CB1 packages | yes: `linux-image-current-sunxi64` 26.8.3 = 6.18.44, `linux-dtb-current-sunxi64` 26.8.3, `linux-u-boot-bigtreetech-cb1-current` 26.8.3 = U-Boot 2026.07 | `apt.armbian.com/dists/trixie/main/binary-arm64/Packages` |
| U-Boot write offset | `dd bs=1024 seek=8` | `config/sources/families/include/sunxi64_common.inc` `write_uboot_platform` |
| Boot script for sun50i | `boot-sun50i-next.cmd` (`booti`, `Image`, `uInitrd`, `${prefix}dtb/allwinner/`), copied verbatim | `armbian/build config/bootscripts/` |
| CB1 board config | `BOOTFS_TYPE="fat"`, `BOOT_FDT_FILE="sun50i-h616-bigtreetech-cb1-sd.dtb"`, `OVERLAY_PREFIX="sun50i-h616"` | `config/boards/bigtreetech-cb1.conf` |
| uInitrd hook | Armbian's `99-uboot` calls `mkimage -A $INITRD_ARCH -O linux -T ramdisk -C gzip` | `packages/bsp/common/etc/initramfs/post-update.d/99-uboot` |
| Klipper venv deps | greenlet 3.3.2, cffi 2.1.1, Jinja2 2.11.3, markupsafe 1.1.1, pyserial 3.4, python-can 3.3.4, msgspec 0.19.0 on py ≥3.12 | `scripts/klippy-requirements.txt` |
| Moonraker venv deps | tornado, pyserial, pillow, streaming-form-data, distro, inotify-simple, libnacl, paho-mqtt, zeroconf, preprocess-cancellation, jinja2, dbus-fast, apprise, ldap3, python-periphery, importlib_metadata; system: `python3-dev libopenjp2-7 libsodium-dev zlib1g-dev libjpeg-dev packagekit wireless-tools curl build-essential` | `scripts/moonraker-requirements.txt`, `scripts/system-dependencies.json` |
| Moonraker polkit actions | `systemd1.manage-units`, `login1.{power-off,reboot,halt}[-multiple-sessions]`, `packagekit.*` | `scripts/set-policykit-rules.sh` |
| `canbus_query.py` output format | `Found canbus_uuid=%012x, Application: %s` | `scripts/canbus_query.py` |
| RPi trixie repo | `linux-image-rpi-2712` / `-v8` 1:6.18.39-1+rpt1 (6.12.x kept as versioned packages), `raspi-firmware` 1:1.20260521-3 (Depends `dosfstools, rsync`), `raspberrypi-archive-keyring` 2025.1+rpt1, `firmware-brcm80211` 20260519 | `archive.raspberrypi.com/debian/dists/trixie/main/binary-arm64/Packages` |
| RPi archive key under trixie apt | `raspberrypi.gpg.key` from the website is **rejected** by `sqv` (`Policy rejected … SHA1 is not considered secure since 2026-02-01`); the key inside `raspberrypi-archive-keyring_2025.1+rpt1` passes. `allow-weak=yes` and switching to `gpgv` do not help. Bootstrap therefore `dpkg -i`s the keyring .deb (CM5 build run 1 failed on this) | tested in a trixie container, 2026-09-03 |
| raspi-firmware hooks | `z50-raspi-firmware` kernel hook: `KERNEL=auto` copies `vmlinuz-*-rpi-2712` → `kernel_2712.img`, `bcm27*.dtb`, overlays; initramfs hook copies → `initramfs_2712`; skips mountpoint check under `ischroot` | extracted `raspi-firmware_1.20260521-3_all.deb` |
| rpi-image-gen Pi layer | `raspi-firmware` + `linux-image-rpi-2712`, templates `boot-firmware/{config,cmdline}.txt`, `INITRD: "No"` for their images, apt source `archive.raspberrypi.com trixie main` signed by `raspberrypi-archive-keyring.gpg` | `layer/rpi/device/*.yaml`, `templates/rpi/boot-firmware/` |

## 21. Implementation status

Everything below was written 2026-09-03 and runs without hardware. `sh tests/run.sh` is the gate: `bash -n` on every shell script, three Python self-tests, one shell parser test.

### 21.1 File map

| Path | What | Verified |
|---|---|---|
| `build/build.sh` | host wrapper: `docker run --privileged --platform linux/arm64 debian:trixie` | syntax |
| `.github/workflows/{weekly,release,build}.yml` | weekly prerelease from the newest upstream pins; a `v*` tag republishes a tested weekly; `build.yml` is the shared build (§21.5) | **never run — no git remote yet** |
| `build/in-container.sh` | installs tools, runs `mmdebstrap`, assembles the image | syntax; first real run in progress, see 21.3 |
| `build/packages.txt` | the whole Debian package list, one place | — |
| `build/customize.sh` | chrooted: user, git checkouts, venvs, Mainsail + mainsail-config, enable/mask units, trim docs | syntax |
| `build/mkimage.py` | MBR + partition images without loop devices or root; `--test` round-trips the MBR | self-test + `tests/mkimage_docker.sh` (real mkfs in a container) |
| `build/boards/cb1/` | `board.sh` (apt line, packages, partition spec, U-Boot offset), `armbianEnv.txt`, `boot.cmd`, kernel/initramfs hooks, DRM blacklist, `customize.sh` | built, image inspected |
| `build/boards/cm5/` | `board.sh`, `config.txt`, `cmdline.txt`, vc4/v3d blacklist, `customize.sh` (keyring .deb, raspi-firmware first, then both kernels, asserts the boot files exist) | built (run 2), image inspected |
| `build/config-partition/kos.conf` | the shipped user-facing file, every key documented | — |
| `overlay/` | copied verbatim into the rootfs (`mmdebstrap sync-in`) | — |
| `overlay/usr/lib/kos/lib.sh` | `cfg` parser, validators, SSH key handling | `tests/test_lib_sh.sh` (also checks the Python twin) |
| `overlay/usr/lib/kos/kos-ssh-key` | add/list/remove `ssh_key=` lines, applied at once | `tests/test_kos_ssh_key.sh` |
| `overlay/usr/lib/kos/kos-printer-idle` | gate for `kos-security-updates.service` (§12) | self-test against a fake Moonraker |
| `overlay/usr/lib/kos/kos-config` | §6 provisioning, every boot | syntax only — needs a booted system |
| `overlay/usr/lib/kos/kos-mcu-discover` | §8 | self-test of the rewrite logic; device enumeration untested |
| `overlay/usr/lib/kos/kos-archive` | §17 | self-test against a fake Moonraker |
| `overlay/usr/lib/kos/kos-tune` | §10 IRQ affinity by name | syntax |
| `overlay/usr/lib/kos/{moonraker.conf,printer.cfg}` | seeded into `printer_data/config` when absent | — |
| `overlay/etc/systemd/system/*.service` | klipper, moonraker, kos-{config,tune,mcu-discover,archive}, tty1 autologin | not loaded yet |
| `overlay/etc/systemd/network/99-can*` | FlyOS's CAN files verbatim | — |
| `overlay/etc/{fstab,polkit-1,sudoers.d,nginx,default/zramswap,NetworkManager}` | §7, §11 | — |
| `tests/run.sh` | the no-hardware gate: `bash -n`, the Python self-tests, the `cfg` parser (shell and Python agree), `kos-ssh-key`, trash purge, Armbian key fingerprint | passes |
| `tests/nginx_docker.sh` | nginx Host/Origin checks against a stub Moonraker (Docker) | passes |
| `tests/mkimage_docker.sh`, `tests/inspect_image.sh` | filesystem round-trip in a container; offline inspection of a built `.img` | both used |

### 21.2 Decisions made while building (not previously in the plan)

- Every-boot idempotent provisioning instead of a one-shot first boot (§6).
- MCU discovery rewrites values in place instead of generating `mcus.cfg` (§8).
- `/boot` on ext4 root for CB1, not on the FAT partition (§14).
- Fixed 3 GiB root + growing data partition; no A/B gap (§7).
- `/var/log` tmpfs, journald volatile (§7).
- Archiver polls over HTTP instead of a websocket subscription (§17).
- Static RFC1918 `trusted_clients` (§11).
- `python3-matplotlib` is **not** in the image: it is only needed by `scripts/calibrate_shaper.py` for graphs; `SHAPER_CALIBRATE` itself needs only numpy, which is. Add it if users ask.
- Klipper and Moonraker are full single-branch clones, not shallow, to keep `update_manager` on its happy path. Cost measured at build time.
- Governor comes from `cpufreq.default_governor=performance` on the command line; no cpufrequtils, no script.
- Kernel module pruning: none (§15 said probably not worth it; confirmed, the `.deb` owns `/lib/modules`).

### 21.3 Needs a build host or hardware — not done

- **First image build.** Runs in Docker on this Mac (x86, arm64 via qemu-user, ~35 min per attempt, dominated by pip under emulation). Findings from runs 1–3, all fixed:
  - mmdebstrap's `sync-in` needs the destination directory to exist (`mkdir -p` hook added).
  - No `gpg` in a minbase chroot; apt ≥ 2.4 accepts an ASCII-armored key in `signed-by`, so the Armbian key is saved as `armbian.asc` and nothing was added to the image.
  - `set -o pipefail` + `du -sh / | tail` killed an otherwise complete run at the very last line. Board step now runs *before* the clone/venv step so board mistakes fail in minutes.
  - Everything feared did not happen: Armbian's kernel postinst runs clean without the BSP package and creates `/boot/Image` itself (our hook is now belt-and-braces), `markupsafe==1.1.1` builds on Python 3.13, U-Boot lands at `/usr/lib/linux-u-boot-current-bigtreetech-cb1/u-boot-sunxi-with-spl.bin`.
  - Warning to remember: `W: Couldn't identify type of root file system 'LABEL=KOS-ROOT' for fsck hook` during `update-initramfs` in the chroot. The initrd therefore carries no `fsck.ext4`; root is mounted read-only by the initramfs and `systemd-fsck-root` checks it from the real root, so nothing is lost. Harmless, but verify on hardware that boot does not stall on it.
  - Rootfs measured **1.3 GB** before the doc/man/apt-list trim. Within the ≤1.5 GB target but not by much; the two git checkouts plus two venvs are the obvious fat if it grows.
  - `build/mkimage.py` was exercised for real in a container (`tests/mkimage_docker.sh`, needs Docker): MBR parses with `sfdisk`, U-Boot bytes at 8 KiB, `kos.conf` readable from the FAT partition, files and label present on the ext4 root.
  - **Run 4 succeeded: `out/kos-cb1-20260903.img`, 3.4 GB (3 GiB fixed root + 64 MB config + 256 MB data placeholder), rootfs 1.3 GB.** Inspected without mounting (`tests/inspect_image.sh`): MBR p1 FAT32 16 MiB/64 MiB, p2 ext4 bootable 80 MiB/3072 MiB, p3 ext4; `eGON.BT0` SPL header at 8 KiB; `/boot` has `Image`, `uInitrd`, `dtb/`, `boot.scr`, `armbianEnv.txt`; fstab, units (`klipper moonraker nginx avahi ssh NetworkManager systemd-networkd zramswap kos-*` enabled, `apt-daily*`/`e2scrub_all`/`man-db`/`fstrim` timers and `networkd-wait-online` masked); both venvs on Python 3.13; `chelper/c_helper.so` prebuilt; Fluidd unpacked; root locked, `klipper` passwordless; `machine-id` empty; Armbian apt source present; one module tree. Kernel config confirms `EXT4_FS=y`, `MMC_SUNXI=y` (root mounts even if the initrd is thin), `CAN_GS_USB/MCP251X/MCP251XFD=m`, `RTL8189FS=m`, `PREEMPT=y`, `ZRAM=m`, `DRM_SUN4I=y` (see §16.2).
  - Cosmetic defect in that image, fixed in source for the next build: `moonraker-admin` was created before the user, so group `klipper` got gid 1001 and gid 1000 is `moonraker-admin`. `kos-config` chowns `printer_data` by name, so nothing breaks. **Run 5 rebuilt the CB1 image with the fix; inspected, `klipper` is 1000:1000.**
- **CM5 build.** Run 1 failed at `apt-get update`: trixie's `sqv` rejects the key at `raspberrypi.gpg.key` (SHA1 self-signature, see §20). Run 2 with the keyring `.deb` bootstrapped via `dpkg -i` succeeded: **`out/kos-cm5-20260903.img`, 3.6 GB, rootfs 1.2 GB.** Inspected: p1 `KOS-BOOT` FAT32 at 4 MiB with `kernel_2712.img`, `initramfs_2712`, `kernel8.img`, `initramfs8`, `config.txt`, `cmdline.txt`, `overlays/`, all `bcm2710/2711/2712*.dtb`, `start4*.elf`/`fixup4*.dat`; p2 `KOS`; p3 `KOS-ROOT` (bootable flag, harmless); p4 `KOS-DATA`. fstab has the `/boot/firmware` line. Two module trees (`6.18.39+rpt-rpi-2712`, `-v8`). Kernel config: `CONFIG_ARM64_16K_PAGES=y` on 2712 (matters for any binary that assumes 4 K pages — Klipper's chelper does not), `DRM_VC4=m` (so the vc4/v3d blacklist *is* effective on the Pi, unlike sun4i on CB1), `CAN_GS_USB=m`, `CAN_MCP251XFD=m`, `EXT4_FS=y`, `PREEMPT=y`. Same `LABEL=KOS-ROOT` fsck-hook warning during `update-initramfs`, twice (one per kernel).
- (Superseded 2026-10-19: the CM5 image is now tested on hardware, see §21.6; the CB1 image is not yet.) Flash: `dd if=out/kos-<board>-20260903.img of=/dev/rdiskN bs=4m` (CM5 with eMMC: through `rpiboot`). Then §21.4.
- Boot on CB1: U-Boot finds `boot.scr` on p2; initramfs resolves `LABEL=KOS-ROOT`; `isolcpus=3` visible in `/sys/devices/system/cpu/isolated`; `cat /proc/cmdline` shows the governor arg took; `Cma` in `/proc/meminfo` with the DRM blacklist in place (§16.2 expects tens of MB back).
- `kos-config` end to end: growpart on a real card, `nmcli` on RTL8189FS, `networkctl reconfigure can0` after a bitrate change.
- `kos-mcu-discover` against real boards: by-id enumeration timing, `canbus_query.py` from the venv as the `klipper` user, USB-to-CAN bridge boards.
- §17.4 unknowns (thumbnails follow `files/move`, history reprint after a move) — needs a live Moonraker.
- Measurement protocol §16.1, all of it.
- CM5/CM4 on hardware. `kos-config` handles `display=hdmi` on the Pi by stripping `video=` from `cmdline.txt` and uncommenting `dtoverlay=vc4-kms-v3d` in `config.txt`. Verify on hardware: EEPROM finds the FAT at 4 MiB, `auto_initramfs` picks `initramfs_2712`, `root=LABEL=` resolves in the initrd, `/boot/firmware` mounts by label, `rp1` IRQ names match `kos-tune`. On a CM5 with eMMC the image is written through `rpiboot` mass-storage mode; SD only on CM5 Lite.

### 21.4 First flash checklist (both boards)

Same order on both, stop at the first failure and fix that layer:

1. **Serial console** (CB1: `ttyS0` on the debug header; CM5: `serial0` on the CM5IO). U-Boot/EEPROM must find the boot files. Expected: CB1 prints `Boot script loaded from mmc` and `Load fdt: /boot/dtb/allwinner/sun50i-h616-bigtreetech-cb1-sd.dtb`; CM5 shows the firmware loading `kernel_2712.img` then `initramfs_2712`.
2. **Root mounts.** If it drops to `(initramfs)`: `blkid` there — is `KOS-ROOT` visible? If not, the MMC driver is missing from the initrd (CB1: built-in, cannot be) or the label was not written.
3. **`systemctl status kos-config`** on tty1 (autologin). Expected: `firstboot.done` created, `/home/klipper/printer_data` grown (`df -h`), hostname from `kos.conf`, `/config` mounted.
4. **`journalctl -u kos-mcu-discover`** and `cat /config/MCU-DISCOVERY.txt`.
5. **`http://<hostname>.local`** from a laptop: Mainsail up, Moonraker connected, `printer.cfg` present.
6. Then the §16.1 numbers.

### 21.5 Release pipeline

`.github/workflows/build.yml` runs `build/in-container.sh` for `cb1` and `cm5` in parallel on `ubuntu-24.04-arm` (native arm64, so no qemu tax) inside a privileged `debian:trixie` container pinned by digest (`build/pins.env`), with a read-only token. `.github/workflows/weekly.yml` bumps `build/pins.env` to the newest Klipper, Moonraker, mainsail-config and Mainsail (`build/bump-pins.sh`), commits that, then starts a second run on `main` (so the build and its attestation name the bumped commit) that calls it, checks each image with `tests/inspect_image.sh` (owners, sshd/sudo modes) before upload, and publishes `kos-<board>-<date>.img.xz`, a `.sha256` and a GitHub build provenance attestation as the `weekly-YYYYMMDD` prerelease. `.github/workflows/release.yml` runs on a `v*` tag: it republishes the files of the weekly built from that commit, unchanged, after checking that their attestation comes from `build.yml` on `main` at that commit, so the bytes tested on hardware are the bytes released. Publishing happens in separate jobs that run no repository code.

`.xz` is the ship format because Raspberry Pi Imager and balenaEtcher both decompress it natively. A ~3.5 GB image lands around 400–600 MB, well under the 2 GB per-file release-asset limit. Raw `.img` files are never committed — git's hard limit is 100 MB.

The runner has ~14 GB of disk, which is why the compress step clears `/tmp/work` first; the rootfs is dead weight once the image is assembled.

Provenance: each image has an attestation (`gh attestation verify kos-cb1-<date>.img.xz -R <owner>/klipperOS --signer-workflow <owner>/klipperOS/.github/workflows/build.yml`). Not done, deliberately: GPG-signed images, apt caching between runs, a `latest` tag.

Untested: no git remote is configured yet, so the workflow has never executed.

### 21.6 Hardware log: first boots, 2026-10-19

**CM5 booted.** Raspberry Pi CM5 Lite CM5104000 (4 GB, no eMMC) on a BTT Manta M5P (Sindri), SD boot, wired. Image
`kos-cm5-20261019` (pm build). §21.4 steps 2–5 pass without a serial console: root mounts by label, `kos-config`
grows `KOS-DATA`, sets hostname and `/etc/hosts`, installs `ssh_key`, imports a real `printer_data`; discovery
matches the Nitehawk 36 (USB) by serial and the M5P's STM32G0B1 USB-to-CAN bridge by `canbus_uuid`; Mainsail on :80;
`Printer is ready` with `mcu` (CAN bridge), `host` (Linux MCU) and `nitehawk`. Boot 9.9 s, Klippy ready 10.9 s after
kernel start. A full 85-minute print ran with 0 timer errors and 0 retransmits. Benchmarks: [benchmarks.md](benchmarks.md).

**CB1 image built and inspected** (`kos-cb1-20261019`); not booted yet. Test target: the same M5P in Sindri.

Bugs found on hardware and fixed in source (all in the pm builds):

| Bug | Symptom | Fix |
|---|---|---|
| Debian's nginx `default` site left enabled | nginx fails: duplicate `default_server` on :80 | `customize.sh` removes it |
| `/var/log` is tmpfs | nginx fails: `/var/log/nginx` missing at boot | `overlay/etc/tmpfiles.d/kos-nginx.conf` |
| `/var/log` is tmpfs | `kos-security-updates.service` fails: unattended-upgrade traceback, `/var/log/unattended-upgrades` missing | `overlay/etc/tmpfiles.d/kos-unattended-upgrades.conf` |
| trixie `HOME_MODE` 0700 | web UI 403 | `chmod 0711 /home/klipper` |
| `RestartSec=100ms` in `99-can.network` (from FlyOS) | `can0` fails on gs_usb: "Device doesn't support restart from Bus Off" | line removed |
| Build container id in `/etc/hostname` | wrong hostname until `kos-config` ran | `customize.sh` writes `kos` |
| `/etc/hosts` only written when the hostname changed | `sudo: unable to resolve host kos` on a default-named box | checked every boot |
| `KOS-DATA` made as a 256 MB placeholder | ext4 "small" profile (1 KiB blocks) kept after growth: 1.7 GB of inode tables zeroed after first boot on a 32 GB card | `mkimage.py` passes `-T default` (4 KiB blocks) |
| Discovery tracked used devices per file | two files could claim one board | one claimed set across files |
| Discovery scanned every `*.cfg` | rewrote commented-out includes and Klipper's `printer-*.cfg` SAVE_CONFIG backups | only `printer.cfg` and its `[include]`s |
| Discovery treated silent CAN nodes as stale | after a warm reboot assigned nodes do not answer `canbus_query`; a fresh node would have taken `[mcu]`'s id | CAN checked only on the boot that imported a config (`/run/kos-imported`) |
| Imported configs name another home | `klippy_uds_address = /home/<you>/...`, Moonraker cannot reach Klippy | `/home/<other>/` rewritten to `/home/klipper/` on import |
| Users copy `config/` without `printer_data/`, and macOS adds `._*` files | config not imported; junk files | both handled on import |

Decisions made on hardware:

- **Mainsail replaces Fluidd** (§4): the owner's configs `[include mainsail.cfg]`; no performance reason was recorded for Fluidd. `mainsail-config` is cloned and linked.
- **Klipper host MCU is built in** (§15 resolved): `/usr/local/bin/klipper_mcu`, enabled by `kos-config` only when a config uses `klipper_host_mcu`.
- **Recycle bin:** `trash-cli`, interactive `rm` aliased to `trash-put`, hourly purge of items over 30 days old and oldest-first while `/` or `printer_data` has under 10 % free. Web UI deletes go through Moonraker and skip it, by design. On-device test (`tests/device/trash_on_device.sh`) not yet run.

Hardware findings, not KOS bugs:

- A 128 GB SDXC card (`FD4Q9`) hangs on every warm reboot with this CM5 + M5P (ACT LED solid; power cycle recovers); a 32 GB SDHC card (`SD32G`) and the owner's old 64 GB card do not. Same image, both SDR104. Release notes need a tested-cards list.
- With the CAN EBB replaced by a USB Nitehawk, the M5P's CAN bus has no other node: `bus_state=passive` with `tx_error` climbing about 13,700/s. Harmless to printing.
- No RTC battery: the wall clock is stale (2026-04-13) until NTP; early log timestamps are wrong.
- Stock Raspberry Pi OS also keeps the journal in RAM (trixie default `Storage=volatile`), and `raspberrypi-sys-mods` forces the `ondemand` governor with a udev rule, overriding `cpufreq.default_governor`.
- Log volume while printing: `klippy.log` 5.6 MB/h (one ~1.2 KB `Stats` line a second); journal and `/var/log` together about 1/500 of that.
