# BTT CB1 image: original printer configs

What `~/printer_data/config/` held on BTT's CB1 image (`CB1_Debian13_Klipper_kernel7.0_20260430.img.xz`) before
`stock_prep.sh` imported the benchmark printer's config. `printer.cfg` and `KlipperScreen.conf` are kept as captured.
The other files were stock copies of BTT's or upstream projects' files and are not kept here; this list says what
each was and which settings mattered.

| File | What it was | Settings that mattered for the benchmark |
|---|---|---|
| `printer.cfg` | BTT's placeholder (kept) | includes `mainsail.cfg`, a `[mcu CB1]` on the Klipper host MCU, and a generic BTT board include; replaced by the benchmark printer's config |
| `KlipperScreen.conf` | empty auto-generated stub (kept) | none; KlipperScreen itself ran on the stock image with no screen attached (see the CB1 summary in `docs/benchmarks.md`) |
| `moonraker.conf` | BTT's Moonraker config | `[server]` on all interfaces, port 7125, Klippy socket under `/home/biqu/printer_data`; `trusted_clients` = the RFC1918 + loopback + link-local + IPv6 ULA list Moonraker's installer suggests; `cors_domains` for `*.lan`, `*.local`, localhost and the hosted Mainsail/Fluidd apps; `[octoprint_compat]`, `[history]`; `update_manager` on the `dev` channel with entries for Mainsail, mainsail-config, KlipperScreen, Crowsnest, Sonar, moonraker-timelapse and print_area_bed_mesh. `stock_prep.sh` copied the benchmark printer's config directory over it |
| `.moonraker.conf.bkp` | Moonraker's automatic backup of the same file | identical settings, written in `key = value` form |
| `mainsail.cfg` | the upstream [mainsail-config](https://github.com/mainsail-crew/mainsail-config) macros (GPLv3) | none; an upstream file, not specific to BTT |
| `timelapse.cfg` | the upstream [moonraker-timelapse](https://github.com/mainsail-crew/moonraker-timelapse) macros (GPLv3) | none; an upstream file, not specific to BTT |
| `print_area_bed_mesh.cfg` | the [print_area_bed_mesh](https://github.com/Turge08/print_area_bed_mesh) macro | none; an upstream file, not specific to BTT |
| `crowsnest.conf` | Crowsnest's default config | one `ustreamer` camera on `/dev/video0`, 640x480 at 15 fps; the benchmarks use no webcam |
| `sonar.conf` | the default config of [Sonar](https://github.com/mainsail-crew/sonar), a Wi-Fi keepalive (GPLv3) | `enable: false` |
