# FlyOS-Fast glue: what the removed vendor files did

The teardown of Mellow's FlyOS-Fast H3 v1.3.8 image ([README.md](README.md), full report in [FlyOS-Fast-1.3.8-inventory.md](FlyOS-Fast-1.3.8-inventory.md)) originally kept 88 files copied verbatim out of the image, plus three image-vs-upstream patches for Klipper, Moonraker and KlipperScreen. They were removed from this repository: KOS does not ship vendor code it does not use. This page describes what each file or group did, so the references in [`../plan.md`](../plan.md) and the teardown notes still make sense.

Paths are the ones the files had inside the image. Line numbers quoted elsewhere in these docs (for example `flyos-init:39-102`) refer to the files as shipped in the image. To read the originals, extract the image as described in [README.md](README.md#reproducing-the-extraction-on-another-machine).

Licence headers are noted per file. Most of the vendor's own shell scripts and units carry none.

---

## Scripts

21 shell scripts. All live in `/usr/lib/flyos/` except `flyos-init` (`/usr/sbin/flyos-init`, reached as `/sbin/flyos-init` through the merged-`/usr` symlink) and `flyos-serial-autologin` (`/usr/sbin/`). None has a licence header. Several read `/config/config.txt` by `source`-ing it as root; that is called out per script.

### flyos-init

The pre-systemd init, passed as `init=` by the U-Boot script. POSIX shell, 214 lines. In order:

- Mounts `/proc` and `/sys`, then reads `root=` and `rootfstype=` from the kernel command line.
- Escape hatch: with `noro=1` it remounts root read-write (ext4 options `noatime`, `nodiratime`, `commit=120`, `errors=remount-ro`) and hands over to `/sbin/init` without any overlay.
- Finds the parent block device of the root partition. If userdata partition 6 is 4 GiB or smaller, it rewrites the partition table with scripted `fdisk` input so partition 6 runs to the end of the card, then formats it ext4. On MBR it also has to delete and recreate the extended partition and slot B's logical partition around it; on GPT it only recreates partition 6. This is the first-boot expansion (lines 39-102 in the original).
- Mounts partition 6 at `/overlay` with the same ext4 options (lines 18 and 120). On mount failure it falls back to the read-write path.
- Bind-mounts `/overlay/var/lib/NetworkManager` and `/overlay/var/lib/systemd` over their originals.
- Mounts overlayfs on `/etc`, `/data` and `/root`, then on `/usr/share/printer_data` when `printer=klipper` or `/opt/dsf` when `printer=rrf`. Upper and work directories sit under `/overlay/`, named after the target path with slashes turned into underscores (lines 153-196).
- With `show_overlay=1` it moves `/overlay` to `/mnt/overlay` for inspection, then `exec`s systemd.

This one script is the whole read-only-root plus writable-overlay design.

### flyos-config

Run on every boot by `flyos-config.service`. In order:

- Creates `.flyos-config/sys-config.conf` in the printer config directory as a symlink to `/config/config.txt`, so the web UI's file editor can edit the provisioning file.
- Makes `fluidd.cfg` and `mainsail.cfg` immutable with `chattr +i` on their copies in the overlay upper directory, first forcing a copy-up if the file only exists in the lower layer (lines 95-118). The point is that UI-managed macro files cannot be edited or overwritten.
- Runs `flyos-init-zram`.
- `source`s `config.txt` as root (line 145) and applies:
  - `localtime`: symlinks `/etc/localtime`, falling back to `Asia/Shanghai` for an unknown zone (lines 60-76);
  - `canbus_bitrate`: rewrites the `BitRate=` line of `/etc/systemd/network/99-can.network` in place and restarts systemd-networkd when it changed (lines 78-93);
  - `board`: runs the vendor's `fly-flash` tool for that board;
  - `WIFI_SSID` / `WIFI_PASS`: turns the Wi-Fi radio on and creates or updates a NetworkManager connection named "FlyOS wireless" on `wlan0`, WPA-PSK when a password is set, with autoconnect on and `autoconnect-priority` set to -999, then brings it up if no Wi-Fi link is active (lines 159-202).
- Runs `flyos-init-hard`.

Status text goes to the boot splash throughout. Generators for a hostapd and udhcpd access-point fallback on `wlan1` are present but their calls are commented out.

### flyos-firstrun

One-shot, gated on the marker `/config/.is_first`, which it deletes first. It `source`s `config.txt` (line 11). If `/config/printer_data/` exists it `rsync`s it into `/usr/share/printer_data/` (Klipper) or `/opt/dsf/sd/` (RRF), skipping the marker and `config.txt`, and then deletes the source directory with `rm -rf` (lines 3-21). If `board=` and a readable `firmware=` path are set, it flashes that firmware with `fly-flash`. Finally it calls `flyos-init-swap`; calls to `flyos-resizefs` and `flyos-init-venv` are commented out.

### flyos-set-hostname

Run by `first-setting.service`, which it disables on its first run. In order:

- Deletes `/etc/machine-id` so systemd generates a fresh one (line 6).
- Builds a default hostname from `flyos-` plus a six-character device ID from the vendor's `dev-id` tool.
- `source`s `config.txt` (line 16) for `hostname`, `printer_name` and `language`.
- Sets the hostname with `hostnamectl`, writes `/etc/hostname`, and inserts a `127.0.0.1` line for it into `/etc/hosts` (lines 40-46).
- On the first boot, or when Moonraker's database does not exist yet, deletes and recreates `moonraker-sql.db` with `sqlite3`. It seeds the Mainsail and Fluidd UI settings with the printer name, the UI language and file-list filters, so the web UI comes up named and in the chosen language.
- If an OEM init script is present and `flyos-ver` reports an OEM name, runs that script.

### flyos-init-zram

Called from `flyos-config`. Loads the `zram` module and creates one swap device per CPU core, capped at one device on non-3.x kernels. Each device is sized to 50 % of RAM divided across the devices, with an equal memory limit (lines 33-38). It uses `lzo-rle` when available, disables zswap, and enables the devices at swap priority 5. It edits `/etc/systemd/journald.conf` to cap the journal at 20 MB (line 47). It then makes one more zram device of 50 MB, formats it ext4 without a journal and mounts it on `/var/log` (lines 71-76), which keeps logs off the SD card. The structure and variable names follow Armbian's zram setup script.

### flyos-init-hard

Called from `flyos-config`. Applies `/etc/default/cpufrequtils` (governor, minimum and maximum frequency) to every cpufreq policy, and sets Armbian's `ondemand` tuning values when that governor is chosen. Then it steers interrupts by writing CPU masks to `/proc/irq/*/smp_affinity`, finding each IRQ number by name in `/proc/interrupts`: `usb1` to CPU 1, `usb2` to CPU 2, and the first `sunxi-mmc` and `eth` IRQs to CPU 3 (lines 27-32). It also sets receive packet steering on `end0` to CPUs 0-2. Like `flyos-init-zram`, it is close to Armbian's equivalent script.

Note that this puts the MMC and Ethernet interrupts on CPU 3, the same core that `isolcpus=3` and Klipper's `CPUAffinity=3` reserve for Klippy. KOS steers peripheral IRQs away from the isolated core instead.

### flyos-init-venv

Creates `/data/klippy-env`, `/data/moonraker-env` and `/data/klipperscreen-env` with `python -m venv` if they are missing, then copies the whole system `site-packages` tree into each. The shipped units ignore these venvs and run `/usr/bin/python` directly. The call from `flyos-firstrun` is commented out in this build.

### flyos-init-swap

Entirely commented out: it would have created a 256 MB swap file and added it to `/etc/fstab`. As shipped it does nothing and exits 0.

### flyos-blk-links

Creates stable names for the SD card and eMMC regardless of `mmcblkN` numbering. For each whole `mmcblk` device it inspects the sysfs path and maps the controller address to `/dev/sdcard` or `/dev/emmc`, plus `-pN` links for each partition. It knows two address pairs: one for the H618 (lines 28-35, the die family of the CB1's H616) and one for the H3/H5. Run before `sysinit.target` by `flyos-blk-links.service`.

### flyos-mounts

Mounts partition 1 at `/boot` (ext4, `noatime`, `commit=360`, `errors=remount-ro`; line 10) and partition 2 at `/config` (FAT, `sync`, `iocharset=utf8`, `umask=000`; line 14). It finds the disk from the root filesystem's parent device first. It then tries `bootdev=` from the kernel command line through the `flyos-blk-links` names, then `mmcblk0` to `mmcblk2` in turn. A lock file in `/run` makes it run once per boot.

### flyos-automount

Instance script for `flyos-automount@.service`, triggered by the udev rules for USB storage partitions. On add it accepts only FAT, exFAT and NTFS. It mounts the partition world-writable under the gcode directory as `U_<vendor>_<model>_P<n>-<size>`, so a USB stick shows up as a folder in the web UI's file list. Mounts are recorded in a list under `/var/run`. If the stick has an empty `printer_data/config`, `logs` or `gcodes` directory, it copies the current printer data into it. On remove it unmounts and deletes the mount point. It logs to `/var/log/flyos-auto-mount.log`.

### flyos-netinit

Run once after NetworkManager starts. It bounces `wlan0`, forces mode 600 on every NetworkManager connection file (and reloads NetworkManager if it had to fix one), and activates any Ethernet connection whose interface exists but is down. A block that would set the Wi-Fi MAC from a device ID is commented out.

### flyos-net-wait-online

Wraps `systemd-networkd-wait-online` with a 3-second timeout and always exits 0.

### flyos-nginx

`ExecStartPre` of `nginx.service`. Creates nginx's cache and temporary directories under `/tmp` and `/var/cache`. It `source`s `config.txt` and installs the port-80 `default` site with its placeholder replaced by the Fluidd or Mainsail port, according to `klipper_webui`. Fluidd is the default when the key is unset, unless an OEM marker is present. Finally it runs `nginx -t` as a configuration test.

### flyos-caddy

The Caddy counterpart of `flyos-nginx`: `source`s `config.txt` and runs or reloads Caddy with `Caddyfile-f` (Fluidd, the default) or `Caddyfile-m` (Mainsail) according to `klipper_webui`. No Caddy unit was among the extracted files; nginx is the path the shipped units use.

### flyos-display-init

When the kernel command line says `screen=hdmi`, it writes an Xorg snippet to `/run/xorg/` for the `fbturbo` driver with G2D acceleration. The snippet sets display rotation and a matching touchscreen transformation matrix from `rotate=`, and is symlinked into `/etc/X11/xorg.conf.d/`.

### flyos-psplash

Starts the vendor's `fly-psplash` boot-splash binary with its default configuration, or with the file named by `psplash_config` in `config.txt`, which it `source`s. The other scripts push status strings to the splash with `fly-psplash ctl`.

### flyos-resizefs

An older resize script for a layout where root is partition 3 and directly writable. It grows partition 3 with scripted `fdisk` and `resize2fs`, then writes `rootfs_partuuid=` and `root_dev=` back into `config.txt`. Every call to it in the other scripts is commented out; it is dead code in this build.

### flyos-klippy-guardian

A loop that every 3 seconds renices `klippy.py` to -20 and limits it with `cpulimit`, and renices KlipperScreen and the X server to 19 with a CPU cap. Its unit ships disabled (`flyos-klippy-guardian.service.disable`), so it does not run.

### flyos-login-welcome

The shell login banner. It prints the OS name (with `toilet` if installed) and system information: version, uptime, load, memory and process counts. It adds disk usage of `/overlay` as a bar, the IPv4 address of each interface, and the state of the relevant services (Klipper set, RRF set, or a base set).

### flyos-serial-autologin

`/usr/sbin/flyos-serial-autologin`, for the serial console. It shows a bilingual prompt and, after Enter is pressed twice, `exec`s `agetty` with automatic login as root. Physical access to the serial console therefore gives a root shell. KOS does the same for its local console, as the `klipper` user.

---

## systemd units

32 units. Vendor units live in `/usr/lib/systemd/system/`, enabled through the `.wants` directories under `/etc/systemd/system/`. The application units (Klipper, Moonraker, KlipperScreen, crowsnest, moon2uart, klipper-mcu) sit directly in `/etc/systemd/system/`. Which services start is decided by `ConditionKernelCommandLine=` on values that the U-Boot script copies from `config.txt` into the kernel command line.

### klipper.service

`/etc/systemd/system/klipper.service`, no licence header. Starts only when the command line has `printer=klipper` (line 7), after and requiring `flyos-mounts.service`. Runs Klippy as root with `/usr/bin/python` from `/data/klipper`, with config, socket and log under `/usr/share/printer_data`. Scheduling: `CPUAffinity=3`, `Nice=-18`, `IOSchedulingPriority=2` (lines 14-16). It loads `/config/config.txt` as an `EnvironmentFile=` (line 21) and, as `ExecStartPre`, runs `fly-flash` for the configured board with a 3-second timeout. `Restart=always`.

### moonraker.service

`/etc/systemd/system/moonraker.service`, no licence header. Gated on `printer=klipper`. Runs Moonraker as root from `/data/moonraker` with data path `/usr/share/printer_data`, at `Nice=-18` and `IOSchedulingPriority=2` (lines 14-15). `Restart=always`.

### klipper-mcu.service

`/etc/systemd/system/klipper-mcu.service`, no licence header. Upstream Klipper's Linux host MCU unit, with two conditions added: the `klipper_mcu` binary must be executable, and the command line must say `printer=klipper` (lines 7-8). Starts before Klipper and serves `/tmp/klipper_host_mcu`.

### ttyd.service

`/usr/lib/systemd/system/ttyd.service`, enabled in `multi-user.target`, no licence header. It runs the `ttyd` web terminal as root in front of the system login. The terminal is reachable from the network and has no authentication of its own, and every unit of the image shares one root credential. In practice the image ships a web terminal that grants a root shell to anyone on the network. KOS ships no web terminal.

### Other units

| Unit | What it does |
|---|---|
| `flyos-blk-links.service` | Runs `flyos-blk-links` before `sysinit.target`. |
| `flyos-mounts.service` | Runs `flyos-mounts` before `sysinit.target`, after the block links. Most other FlyOS units require it. |
| `flyos-config.service` | Runs `flyos-config` as `Type=idle` when `/config/config.txt` exists. |
| `flyos-firstrun.service` | Runs `flyos-firstrun` when `/config/.is_first` exists. Wanted by `basic.target`. |
| `first-setting.service` | Runs `flyos-set-hostname`, which disables this unit after the first boot. |
| `flyos-netinit.service` | Runs `flyos-netinit` after NetworkManager. |
| `flyos-display-init.service` | Runs `flyos-display-init` before `sysinit.target`. |
| `flyos-psplash-start.service`, `flyos-psplash-stop.service` | Start the boot splash early. Stop it 2 seconds after a `post-multi-user.target`. |
| `flyos-automount@.service` | Template that runs `flyos-automount` with the instance name, started by the udev rules. |
| `flyos-bind.target` | An empty "FlyOS overlay targets" target ordered before `sysinit.target`. |
| `flyos-fast-ota.service` | Runs the `flyos-fast-ota` update service (a Go binary with no published source) as root, always restarted. |
| `flyos-klippy-guardian.service.disable` | Unit for `flyos-klippy-guardian`. Shipped with a suffix that keeps it disabled. |
| `flyos-x-start.service.disable` | Starts Xorg early on `tty1`. Shipped disabled. |
| `klipperscreen.service` | KlipperScreen under `xinit` as root. Gated on `printer=klipper`, `klipper_screen=1` and a screen other than `none`. Stops the boot splash first. |
| `crowsnest.service` | Crowsnest webcam daemon as root, gated on `crowsnest=1`. Header: written by Stephan Wendel (KwadFan), copyright 2021-2022, distributed under GPLv3 (it is upstream Crowsnest's unit with paths changed). |
| `moon2uart.service` | Runs Mellow's `m2u` Moonraker-to-UART bridge as root, gated on `moon2uart=1`, with port and baud rate taken from `config.txt` through `EnvironmentFile=`. |
| `nginx.service` | nginx with `flyos-nginx` as `ExecStartPre`, gated on `printer=klipper`. |
| `duetcontrolserver.service`, `duetwebserver.service`, `duetpluginservice.service`, `duetpluginservice-root.service` | The Duet Software Framework stack for the RRF path, gated on `printer=rrf`. The control server gets the same core pinning and priorities as Klipper. |
| `dbus-org.freedesktop.network1.service`, `dbus-org.freedesktop.resolve1.service`, `dbus-org.freedesktop.timesync1.service` | D-Bus alias copies of the stock systemd-networkd, systemd-resolved and systemd-timesyncd units. Header: SPDX `LGPL-2.1-or-later` (systemd). |
| `dbus-org.freedesktop.NetworkManager.service`, `dbus-org.freedesktop.nm-dispatcher.service` | D-Bus alias copies of NetworkManager's units. No licence header. |
| `dbus-fi.w1.wpa_supplicant1.service` | D-Bus alias of wpa_supplicant's unit. No licence header. |

---

## udev rules

Three files in `/etc/udev/rules.d/`, no licence headers.

- `97-flyos-usb.rules`: makes the STM32 HID bootloader (USB `1209:beba`) world-writable for flashing. Starts `flyos-automount@` instances when a USB storage partition is added or removed.
- `98-flyos-flylcd.rules`: gives the Fly LCD's USB serial device (`1d50:6188`) a `serial-flylcd-<serial>` symlink.
- `98-flyos-serial.rules`: links each non-8250 `ttyS*` UART to `/dev/serialN`.

None of them names MCUs by role; there is nothing here for the MCU identity problem in [plan.md §8](../plan.md#8-instantly-print-ready--the-mcu-identity-problem).

## Network files

Four systemd-networkd files in `/etc/systemd/network/`, no licence headers.

- `99-can.network`: matches `can*` interfaces and sets the CAN bitrate to 1 Mbit/s with a 100 ms automatic restart after bus-off. `flyos-config` rewrites the bitrate from `canbus_bitrate`.
- `99-can-link.link`: matches `can*` by original name and raises the transmit queue length to 1024. The kernel default of 10 is too short for Klipper.
- `99-end0.network`, `99-eth0.network`: mark `end*` and `eth*` interfaces as unmanaged by networkd, leaving Ethernet to NetworkManager.

KOS ships its own `99-can.network` and `99-can-link.link` with the same settings, in `overlay/etc/systemd/network/`. The settings are the ones Klipper's CAN documentation describes; only the queue length differs from Klipper's suggested 128.

## Web server

Files from `/etc/nginx/` and `/etc/caddy/`, no licence headers.

- `nginx.conf`: runs workers as root, sets a 200 MB request body limit and large header buffers, keeps the body temp path in `/tmp`, and turns access and error logs and gzip on.
- `conf.d/common_vars.conf`: the usual map for proxying websocket upgrades.
- `conf.d/upstreams.conf`: upstreams for Moonraker and four webcam streams.
- `sites-available/fluidd`, `sites-available/mainsail`: the standard sites from the Fluidd and Mainsail install docs. Each serves the static UI from `/data/<ui>` and proxies `/websocket` and the Moonraker API paths to Moonraker. Uploads have no size limit, and the webcam paths are proxied unbuffered. In the image Fluidd listens on 9080 and Mainsail on 9081.
- `sites-available/default`: a port-80 site that proxies `/f/` and `/fluidd/` to Fluidd, `/m/` and `/mainsail/` to Mainsail, and `/` to whichever UI `flyos-nginx` picked.
- `Caddyfile-f`, `Caddyfile-m`: the same layout for Caddy, with the root site serving Fluidd or Mainsail respectively. Selected by `flyos-caddy`.

KOS's nginx site (`overlay/etc/nginx/sites-available/mainsail`) is the same upstream Mainsail site, with paths and log locations adjusted.

## Config files

### config.txt

`/config/config.txt` on the FAT partition: the user-facing provisioning file, no licence header. Plain `key=value` lines that are read three ways: by U-Boot (`env import`), by the shell scripts (`source`), and by units (`EnvironmentFile=`). Keys shipped:

- Wi-Fi credentials, UI language, printer name, time zone (default `Asia/Shanghai`).
- `console`, `printer` (`klipper` or `rrf`), `board` (default `fly-lite2.1`), `screen` and `rotate`.
- `shutdown_pin` and `shutdown_pin_state`: a GPIO wired as a power key.
- Switches for KlipperScreen, crowsnest and moon2uart (with its port and baud rate), and `klipper_webui` (default `fluidd`).
- `canbus_bitrate` (default 1 Mbit/s), `spidev` (SPI devices to enable) and `overlays` (default `uart1 usbhost2 usbhost3`).

The file carries English comments explaining each key.

### moonraker.conf

`/usr/share/printer_data/config/moonraker.conf`, no licence header. It listens on all addresses with the Klippy Unix socket under `/usr/share/printer_data/comms`, a 2048 MB upload limit and `provider: systemd_cli`. It enables the vendor's `[network]` and `[fly_lcd]` components plus `[octoprint_compat]` and `[history]`, and leaves `[zeroconf]` commented out (lines 9-10). `[authorization]` (lines 18-34) trusts every IPv4 and IPv6 address and allows every CORS origin, so Moonraker's authentication is effectively off. KOS trusts only private and link-local ranges.

### Other config files

All in `/usr/share/printer_data/config/`.

- `printer.cfg`: a placeholder that includes `fluidd.cfg`, uses the Linux host MCU and `kinematics: none`, and reads the host temperature. No licence header.
- `fluidd.cfg`, `mainsail.cfg`: the client macro files from the Fluidd and Mainsail config projects (pause, resume, cancel and park macros, `virtual_sdcard` pointing at the gcode directory). Header: copyright 2022 Alex Zellner, distributed under GPLv3. `flyos-config` makes them immutable.
- `plr.cfg`: the configuration for `power_loss_resume`. It sets up the host MCU, a power-sense GPIO on it, and whether to shut the host down on power loss. It also holds the Z lift for resuming a paused print, the resume start G-code (reheat, lift Z, home X and Y), and the G-code run after a set number of layers to restore fan and speed factors. Messages are in Chinese. No licence header.
- `KlipperScreen.conf`: theme `material-dark`, screen blanking off, Chinese UI language. No licence header.
- `crowsnest.conf`: one ustreamer camera on `/dev/video1` at 640x480, 15 fps, with logs under `printer_data`. Its header calls it Crowsnest's typical default config. No licence header.

## Boot

From the `/boot` partition, no licence headers.

- `boot.scr.txt`: the compiled U-Boot script, recovered as text with `strings`. It finds the card with all partitions present and records the device numbers of the boot, config, rootfs A and B, and userdata partitions. It imports `config.txt` into the U-Boot environment (lines 52-54). It picks root slot A or B from `boot_slot`, mounts root read-only unless `noro=1`, and sets `init=/sbin/flyos-init`. It adds `cpufreq_default_governor=performance` and `nohz=on nohz_full=3 rcu_nocbs=3 isolcpus=3` to the kernel command line (lines 97-98), then forwards board, screen, rotation, `printer`, `klipper_screen`, `crowsnest`, `moon2uart` and `klipper_webui` as kernel arguments (lines 124-125). That is how services are gated on `config.txt` (lines 84-101 build the rest of `bootargs`). It enables or disables HDMI in the device tree, applies screen overlays per board, then the user's `overlays`. It wires `shutdown_pin` into the device tree as a power key and enables the requested `spidev` buses. A 64-bit board name makes it stop with an error message in a loop.
- `dtb-overlays.txt`: a list of the 40 `sun8i-h3-*.dtbo` overlay names in `/boot/dtbs/`: Fly screen variants at four rotations, plus the generic Armbian-style I2C, UART, SPI, USB host, PWM, 1-Wire, CIR and codec overlays.

## Klipper add-ons

Files in the image's Klipper tree (`/data/klipper/`) that are not in upstream Klipper.

- `klippy/extras/power_loss_resume.py`: power-loss recovery. Header: copyright 2024 Xiaok, distributed under GPLv3. It watches a GPIO as a button. On power loss it saves the print state as JSON with an `fsync`: file and byte position, heater targets, G-code move state, fan speed, speed factors, toolhead and dual-carriage state, and the current excluded object. It then runs the shutdown G-code and can ask Moonraker to power the host off. After the next boot it offers to resume through the `START_POWER_LOSS_RESUME` and `CLEAR_POWER_LOSS_RESUME` commands and matching webhooks endpoints. It depends on the vendor's `virtual_sdcard.py` changes (see below).
- `klippy/extras/filament_blockage_detection.py` and `src/filament_blockage_detection.c`: MCU-assisted filament blockage detection. Header on both: copyright 2026 Mellow, distributed under GPLv3. A switch-type sensor's pulses are timed on the MCU and compared with extruder movement on the host. A blockage triggers like a runout sensor. `QUERY_FILAMENT_BLOCKAGE` and `CALIBRATE_FILAMENT_BLOCKAGE` are the G-code commands. The C half has to be compiled into the MCU firmware; the vendor's `src/Makefile` change does that.
- `klippy/extras/led_effect.py`: the widely used third-party LED effects plugin, vendored. Header: copyright 2020 Paul McGowan, co-authored by Julian Schill, distributed under GPLv3.

## Moonraker add-ons

Files in the image's Moonraker tree (`/data/moonraker/moonraker/components/`) that are not in upstream Moonraker.

- `fly_lcd.py`: enabled by `[fly_lcd]`. Adds an endpoint that renders the bed mesh as an image with matplotlib for the Fly LCD screen. Header: copyright 2024 Xiaok, distributed under GPLv3.
- `network.py`: enabled by `[network]`. Adds `/server/network/...` endpoints to list devices and saved connections, scan Wi-Fi, connect and disconnect, delete connections, and switch the radio, by running `nmcli` through `sudo`. Header: copyright 2024 Xiaok, distributed under GPLv3.

## KlipperScreen add-ons

Files in the image's KlipperScreen tree (`/data/KlipperScreen/`) that are not in upstream KlipperScreen. None has a licence header.

- `panels/fly_lcd.py`: a settings panel for the Fly LCD over its USB serial port (brightness, rotation, audio).
- `panels/network_info.py`: a panel that lists network interfaces with their state and addresses.
- `ks_includes/ota_client.py`: a websocket client for the local `flyos-fast-ota` service. It receives USB-upgrade, progress and confirmation events and sends update actions.
- `ks_includes/widgets/ota_overlay.py`: a full-screen overlay that blocks the UI while an OTA update runs and shows confirmation dialogs with release notes.

---

## Vendor patches

Three diffs between the image's application trees and the closest upstream commit, picked by minimising the number of differing files (method in [README.md](README.md#regenerating-the-vendor-patches)). Some hunks are upstream drift rather than vendor work. Summaries per changed file follow.

### Klipper patch

Against upstream `02cfc65e` (2026-05-07). 28 files, 89 hunks.

- **`klippy/extras/virtual_sdcard.py`** (about 550 lines added): state tracking for `power_loss_resume`. Also starting a print from a given height, a background thread that parses the G-code file for layers, and detection of files on removable drives, which are copied to local storage in a thread with progress before printing.
- **`klippy/klippy.py`**: helper methods to ask whether a print is running, paused, complete or cancelled. A new internal-error path that can pause the print and turn heaters off instead of shutting Klipper down. A handler for non-fatal MCU errors. Extras can also load from `.pyc` files.
- **Safety behaviour softened while printing.** These files route errors through that internal-error path during a print, where upstream shuts down or raises:
  - `extras/verify_heater.py`: a heater fault pauses the print and turns heaters off instead of shutting down;
  - `extras/tmc.py` and `extras/tmc_uart.py`: TMC driver errors and UART read or write failures are retried or tolerated;
  - `kinematics/extruder.py`: "extrude below minimum temp" is tolerated up to 20 times; this file also adds `SET_NOZZLE_DIAMETER` and `SET_FILAMENT_DIAMETER`;
  - `extras/heaters.py`: a temperature wait can be abandoned.
- **MCU firmware**:
  - `src/sched.c`: "Timer too close" is counted and rescheduled, and shuts down only after more than 20;
  - `src/adccmds.c`: an ADC out-of-range reading sends a non-fatal error instead of shutting down;
  - `src/generic/armcm_timer.c`, `src/generic/timer_irq.c`: the lateness threshold goes from 1 ms to 5 ms;
  - `src/basecmd.c`: the move queue allocation goes from 1024 to 4096;
  - `src/Makefile`: builds the blockage-detection C file.

  Because the host and firmware sides change together, stock Klipper and Fly-built firmware are not guaranteed to mix.
- **Host-MCU path**:
  - `klippy/clocksync.py`: shares the clock estimate with the C helper through a numpy array and changes 32-bit clock extension;
  - `klippy/mcu.py`: handles the new non-fatal error message and relaxes the clock-frequency mismatch warning, only logging it for the host MCU;
  - `klippy/msgproto.py`, `klippy/console.py`: expose and print an application name;
  - `klippy/reactor.py`, `klippy/serialhdl.py`: commented-out real-time priority calls;
  - `klippy/util.py`: adds a helper to set FIFO, round-robin or nice scheduling;
  - `klippy/chelper/__init__.py`: takes the compiler from the command line and skips compiling when a prebuilt `c_helper.so` is present.
- **`klippy/webhooks.py`**: an optional TCP listener on all addresses beside the Unix socket. Moonraker's TCP fallback talks to it.
- **Other**:
  - `klippy/queuelogger.py`: single-letter, optionally coloured log levels;
  - `extras/probe_eddy_current.py`: reworked calibration and drift-compensation interface;
  - `extras/input_shaper.py`, `extras/shaper_calibrate.py`: small edits;
  - `scripts/buildcommands.py`: takes the version from `flyos-ver` instead of git and names the application "Fly-Klipper";
  - `scripts/stepstats.py`: small edit.

### Moonraker patch

Against upstream `9008485` (2026-05-07). Four source files, plus dependency pins in `pyproject.toml`, `scripts/moonraker-requirements.txt` and `uv.lock` (Pillow capped one minor version lower; the lock file changes are mostly drift).

- `components/machine.py`: SD card information no longer assumes `mmcblk0`. It finds the root device with `findmnt` and `lsblk` and reads that device's CID and CSD. It also extends the SD manufacturer ID table (Panasonic, Toshiba, AData, Phison, Lexar, Silicon Power, Kingston, Patriot, Sony, SiliconGo). This is the SD-device fix discussed in [plan.md §13](../plan.md#13-worth-stealing-from-their-patches).
- `components/klippy_connection.py`: when the Klippy Unix socket does not exist, connects over TCP instead, using `klippy_tcp_address` and `klippy_tcp_port` (default `127.0.0.1`, 7126).
- `components/file_manager/file_manager.py`: a `GET /server/files/bottompic` endpoint and about 390 lines that render a first-layer preview image of a G-code file with PIL.
- `components/application.py`: logs upload temp file names and catches `OSError` while writing upload chunks, so a full disk fails the upload instead of raising.

### KlipperScreen patch

Against upstream `3fab8d60` (2026-05-13). 39 files, locale files excluded.

- `screen.py`: starts the OTA overlay, watches USB devices with `pyudev`, preloads panels in a background thread.
- `panels/main_menu.py`: a resume prompt after power loss (resume, clear, cancel) and a clock.
- `panels/camera.py` (about 630 lines added): an embedded `mpv` player for the camera stream.
- `panels/base_panel.py`: a network-info button and IP display in the title bar, and Spoolman spool display.
- `panels/gcodes.py`: copy or move when renaming, defaulting to copy for files on removable drives.
- `panels/network.py`: loads asynchronously through `sdbus` NetworkManager.
- `panels/system.py`: date and OS version.
- Smaller changes to most other panels (`job_status`, `move`, `extrude`, `temperature`, `zcalibrate`, `spoolman`, `printer_select`, `menu`) and to `ks_includes` (`config.py`, `functions.py`, `printer.py`, `KlippyRest.py`, `KlippyGtk.py`, keypad and other widgets).
- The default menus (`main_menu.conf`, `print_menu.conf`, `splash_menu.conf`, `move_menu.conf`, `defaults.conf`) gain Fly LCD and network entries. Some entries are hidden for one OEM build, read from an `OEM=` field in `os-release`.
- Every theme's `style.css` and `base.css` change, and new `fly-lcd.svg` and `notification_important.svg` icons ship in all themes.
- The install scripts and requirements change: `websocket-client`, `requests`, `sdbus` and `psutil` are added.
