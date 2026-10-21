# Changelog

All notable changes to KOS are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

The first version (V1). Not released yet; build it from source.

### Added

- Debian 13 (trixie) arm64 images for the BigTreeTech CB1 and the Raspberry Pi CM5, built with `mmdebstrap` from one
  tree (`build/build.sh <board>`). The CM5 image also contains the CM4 kernel; CM4 is untested.
- Klipper, Moonraker and Mainsail (with `mainsail-config`) behind nginx. Klipper and Moonraker are git checkouts, so
  Moonraker's update manager works. Klipper's Linux host MCU is built in and starts only when a config uses it.
- A FAT partition labelled `KOS` with `kos.conf`, read on every boot: hostname, login (password or SSH key), Wi-Fi,
  timezone, CAN bitrate, display, gcode archiving and the CM5-on-Manta board settings.
- Import of an existing printer config dropped on the `KOS` partition (`printer.cfg`, a `config/` folder or a whole
  `printer_data/` folder), with paths to another user's home rewritten to `/home/klipper/`.
- MCU discovery before Klipper starts: stale `serial:` and `canbus_uuid:` values are rewritten in place to the boards
  actually connected, or reported in `MCU-DISCOVERY.txt` when the match is ambiguous.
- CAN bring-up through `systemd-networkd` (`can*` interfaces, bitrate from `kos.conf`, transmit queue length 1024).
- Realtime tuning: Klippy pinned to an isolated core (`isolcpus=3`), `performance` governor, IRQs steered off that
  core, zram swap, logs in RAM.
- Gcode archiving: successfully printed files move into `Printed/YYYY/MM/` through Moonraker's API.
- Recycle bin for interactive `rm` on the printer (`trash-cli`), purged after 30 days or when space runs low.
- Fixed-size root partition and a separate data partition for `printer_data`.
- A GitHub Actions workflow that builds both boards on arm64 runners and publishes images for `v*` tags, and one
  that runs the no-hardware checks (`tests/run.sh`).
- Benchmarks of KOS against Raspberry Pi OS and BTT's CB1 image, with the scripts and raw results
  ([docs/benchmarks.md](docs/benchmarks.md)).
- Weekly prerelease builds (`weekly-YYYYMMDD`) from the latest upstream, with pins bumped automatically
  (`build/bump-pins.sh`); a `v*` tag republishes a tested weekly's files as the release. Images carry GitHub build
  provenance attestations next to their `.sha256` files.
- `build/pins.env` pins the Klipper, Moonraker, mainsail-config and Mainsail versions (with the Mainsail zip's
  sha256), msgspec/uvloop, and the build container digest. Fresh images start at those revisions, still on their
  branches, so Moonraker's update manager updates them as usual.
- Automatic Debian security updates (`unattended-upgrades`, `trixie-security` only) once a day, only while Moonraker
  reports the printer idle; never a reboot (`kos-security-updates.timer`, `kos-printer-idle`).
- `kos-ssh-key add|list|remove` manages the `ssh_key=` lines in `kos.conf` from a shell on the printer, effective at
  once.
- `kos.conf`: several `ssh_key=` lines, or several keys in one value; lines ending in `\` continue on the next line;
  `allowed_hosts=` for extra names the web UI may be reached under.
- `KOS-WARNINGS.txt` on the KOS partition and the login banner list anything `kos-config` could not apply.

### Changed

- `kos.conf` comments start only at the beginning of a line: `password=a #b` is the password `a #b`.
- Moonraker listens on `127.0.0.1` only and no longer advertises itself over mDNS; apps and slicers use
  `http://<printer>` on port 80.
- IPv4 only: IPv6 is disabled on the kernel command line of both boards, in nginx, sshd, avahi and NetworkManager.
- `kos-config` runs even when the data partition fails to mount; only the printer config steps are skipped, with a
  warning.

### Security

- sshd allows no TCP, X11, agent or socket forwarding and no tunnels, so an SSH key cannot be used to reach Moonraker on
  127.0.0.1:7125 around nginx's Host/Origin checks. Login, scp and sftp are unaffected.
- Images now include Debian's `trixie-security` and `trixie-updates` sources (https), so `apt` and Mainsail's system
  update install security fixes.
- The build container is pinned by digest and mounts the repository read-only; CI builds with a read-only token, and
  only a separate job that runs no repository code can publish.
- The build host's `/etc/resolv.conf` is no longer left in the image, nor the pip cache.
- nginx rejects requests whose `Host` is not an IP address, the hostname, `<hostname>.local` or an `allowed_hosts=`
  name (DNS rebinding), and API/websocket requests with a foreign `Origin` (cross-site requests from web pages).
  The hosted UIs `my.mainsail.xyz` and `app.fluidd.xyz` are no longer in Moonraker's `cors_domains`.
- `kos.conf` is the only source of SSH keys and of the password, applied every boot: removing a line revokes it.
  sshd reads only `/etc/kos/authorized_keys/%u` (root-owned), so `ssh-copy-id` no longer works; root login is off.
- `klipper`'s password is locked (`*`) instead of empty when `password=` is unset, so other local accounts cannot
  `su klipper`. Serial-console login now needs `password=`.
- `/config` is mounted readable only by `klipper` (`fmask=0177,dmask=0077,nosuid,nodev,noexec`), and an imported
  `printer_data` no longer keeps FAT's world-writable modes.
- Images ship without SSH host keys; each printer generates its own before sshd starts, independent of `kos-config`.
- `kos.conf` values are validated: `can_bitrate` (was injected into a `sed` script run as root), `hostname`,
  `timezone` (path traversal), `allowed_hosts`, SSH keys, and `archive_path` in `kos-archive`.
- The recycle-bin purge only empties KOS's own trash folders and skips symlinked ones (it scanned every volume as
  root and followed planted symlinks), and no longer empties everything when `df` fails.
- The Raspberry Pi keyring `.deb` is downloaded over https and checked against a pinned sha256, and its key is not
  installed into `trusted.gpg.d` (where it would be trusted for Debian's sources too). The Armbian key is committed
  with a pinned fingerprint, and Armbian's repository may only supply kernel, device tree and U-Boot packages.
- Everything the build copies from the checkout into the image is root-owned, whoever owns the checkout (CI images
  had the runner's uid on `/`, `/etc`, the sudoers file and `/etc/kos`, so no SSH key and no `sudo` worked). CI checks
  owners and the modes sshd and sudo require in every image before uploading it.
- `kos-config` keeps Moonraker on `127.0.0.1` on every boot, also when an imported `moonraker.conf` said `0.0.0.0`.
- Commenting out a continued `ssh_key=` line now revokes that key (a comment line ends a continuation). A UTF-8 BOM
  no longer hides the first setting, and a continuation running into the next `key=` is warned about instead of
  swallowing it. The shell and Python parsers agree on CR and NUL bytes.
- SSH keys with options (`from=`, `command=`, ...) or certificates are refused, instead of being installed without
  their restriction. A password `chpasswd` rejects locks the account instead of keeping the old password.
- Any name `allowed_hosts=` accepts works in nginx (253-character names, `default`, `include`, `localhost`).
- `timezone=localtime` is rejected (it made `/etc/localtime` a symlink loop).
- CM5: the Raspberry Pi repository may only supply firmware, kernels and its keyring, so its `+rpt` builds of glibc,
  NetworkManager and wpasupplicant cannot block Debian security updates.
- The Armbian key check rejects a keyring with anything besides the one public key (secret key packets, a second
  armor block). `pins.env` is checked line by line before anything sources it or the weekly job commits it.
- Weekly builds run on the commit with the new pins, and a release only republishes files whose attestation comes
  from this repository's `build.yml` on `main` at the release commit.
