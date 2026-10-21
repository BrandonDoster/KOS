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
