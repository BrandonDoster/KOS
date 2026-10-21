# CM5 on BTT Manta M8P (v1.x, v2.0) and M5P

Research date: 2026-10-19. Hardware context: CM5 Lite CM5104000 (4 GB, Wi-Fi/BT, no eMMC, SD boot). Sindri = Manta M5P + CM5 (working today). Brokkr = Manta M8P + CB1 + touchscreen (CM5 moves there later).

Tags: **[verified-source]** = official docs, datasheet, BTT schematic/manual, or kernel source. **[community]** = forum or issue reports. **[unconfirmed]** = my inference or a hypothesis nobody has confirmed yet.

"Schematic" below means BTT's published schematics: M5P V1.0, M8P V1.0 and V1.1, M8P V2.0 (links in §5). On all three boards the CM-connector page is almost identical, so most findings apply to all of them.

---

## 1. Summary (must-do list)

**Both boards (M5P and M8P):**
1. `[cm5] dtoverlay=dwc2,dr_mode=host`. Without it, USB is dead: no hub, no MCU, no USB-to-CAN. KOS already does this.
2. Tell the firmware the carrier is CM4-style. Add `device_tree=bcm2712-rpi-cm5l-cm4io.dtb` (use `bcm2712-rpi-cm5-cm4io.dtb` on an eMMC CM5). The CM5 cannot detect its carrier, and the default DTB assumes CM5IO wiring. That default puts the DSI1/CAM1 I2C bus on the wrong pins for a Manta.
3. Expect these to be lost or different: no USB 3 (the pins are not routed), no RTC battery (VBAT pin 76 is unconnected), no power button (pin 92 is not connected). With the CM5 default `POWER_OFF_ON_HALT=1`, `shutdown -h` stays off until 24 V is cycled. The Pi fan header is plain GPIO26, not the CM5 fan PWM. Serial console on GPIO14/15 needs `dtparam=uart0_console`.
4. The SD card's power is wired straight to 3.3 V. The CM5's `SD_PWR_ON` drives nothing, so a warm reboot never power-cycles the card. This is the most likely cause of the 128 GB warm-reboot hang. Use cards that have been tested on this board, and test `sdhci.debug_quirks2=0x4` (stops the 1.8 V UHS switch).
5. Flashing the MCU: there is no host-controlled BOOT0 or RESET line. Use `make flash FLASH_DEVICE=/dev/serial/by-id/...`, Katapult, or the MCU-Card SD slot. KOS does not ship `dfu-util`.

**M8P only:** DSI display. BTT's `dt-blob.bin` instruction is for CM4 only. On CM5 use a `dtoverlay=vc4-kms-dsi-*` line, the cm4io DTB, and a 15-pin cable. M8P V1.0 has no Pi-FAN header and no CH340 UART. Brokkr's 5 V budget: CM5 draws up to 2.5 A. One CM5+M8P under-voltage report was caused by LED strips on 5 V.

---

## 2. Actionable items

| # | Item | Board(s) | Change (what, where) | Source | Tag | Testable on Sindri's M5P before the swap? | KOS already does it? |
|---|---|---|---|---|---|---|---|
| 1 | Enable the USB 2.0 controller that feeds the onboard FE1.1S hub and MCU | All | `config.txt`: `[cm5]` `dtoverlay=dwc2,dr_mode=host` | CM5 datasheet §2.4.2; M8P#131; M8P V2 wiki | verified-source | Yes (already working) | **Yes** |
| 2 | Select the CM4IO-style device tree | All | `config.txt` `[cm5]`: `device_tree=bcm2712-rpi-cm5l-cm4io.dtb` (Lite) or `bcm2712-rpi-cm5-cm4io.dtb` (eMMC). Do not put the non-Lite DTB on a Lite module: the Lite DTB is the one that switches SD I/O voltage. Also add the chosen DTB to the `test -e` list in `build/boards/cm5/customize.sh` | PhilE (RPi engineer), forum t=383557; `bcm2712-rpi-cm4io.dtsi`; `bcm2712-rpi-cm5l.dtsi` | verified-source | Yes. Boot, then check `cat /proc/device-tree/model`, USB, Ethernet, CAN. Without a display it changes little | **No** (KOS only asserts `bcm2712-rpi-cm5-cm5io.dtb` exists and sets no `device_tree=`) |
| 3 | DSI display: use KMS overlays, not `dt-blob.bin` | M8P (Brokkr), M5P | `config.txt`: `dtoverlay=vc4-kms-v3d` plus the panel overlay, e.g. `dtoverlay=vc4-kms-dsi-7inch` (DSI1 is the default port). Use the panel vendor's overlay for other screens. Remove BTT's `dt-blob.bin` | RPi display docs (CM section); BTT M5P/M8P manuals (CM4 dt-blob method); M5P#43 / Discourse 24690 | verified-source (RPi method); community (dt-blob fails on CM5) | Partially. M5P has the same 15-pin DSI1 connector, but a panel is needed | Partially (`vc4-kms-v3d` behind `display=hdmi`; no DSI option) |
| 4 | DSI touch/bridge I2C on the right bus | All with DSI | Covered by item 2. With the cm4io DTB, `i2c_csi_dsi` (DSI1/CAM1) = i2c-6 on GPIO38/39 = CM pins 80/82 (SCL0/SDA0), which is where the Manta DSI1 and CAM1 connectors take I2C. With the default CM5IO DTB it is GPIO0/1 | overlays README (`i2c_csi_dsi`); `bcm2712-rpi-cm4io.dtsi`; Manta schematics (P3 DSI1 pins 12/13 = SCL0/SDA0) | verified-source | Partially (needs a panel; `i2cdetect -y 6` shows the bus moves) | No |
| 5 | HDMI screen (BTT HDMI5/HDMI7 + USB touch) | All | `display=hdmi` in kos.conf (uncomments `vc4-kms-v3d`, drops `video=HDMI-A-1:d`). Touch is USB through the hub | Manta schematics (HDMI0/1 wired directly); BTT HDMI5 listing | verified-source (wiring); unconfirmed (no CM5+Manta+HDMI5 report found) | Yes (M5P has micro-HDMI) | Yes (mechanism exists) |
| 6 | Warm-reboot SD hang: card not power-cycled | All (CM5 Lite + SD) | Short term: tested-card list. Test option A: `cmdline.txt` add `sdhci.debug_quirks2=0x4` (`SDHCI_QUIRK2_NO_1_8_V`), which keeps the card at 3.3 V High Speed. It applies to every sdhci host (Wi-Fi SDIO, eMMC too) and **replaces** the quirk word, so apply it on CM5 Lite only. Option B: EEPROM `SD_QUIRKS=1` and/or `SD_BOOT_MAX_RETRIES=3` | CM5 datasheet §2.7 ("power switch controlled by SD_PWR_ON; this is the only way to reset the SD card"); Manta schematics (SOC CARD VDD = +3.3 V, SD_PWR_ON pin 75 not connected); kernel `sdhci.c`/`sdhci.h`; uConsole/ClockworkPi EEPROM workaround | verified-source (cause in hardware); unconfirmed (that it fixes the 128 GB card) | **Yes. Best item to test on Sindri now** (128 GB card + reboot loop) | No |
| 7 | MCU firmware flashing from the CM5 | All | Use `make flash FLASH_DEVICE=/dev/serial/by-id/usb-Klipper_...` (Klipper jumps to DFU itself), or Katapult, or `firmware.bin` on the **MCU-Card** slot. Add `dfu-util` to `build/packages.txt` | BTT manuals (DFU + SD update; "get_status error can be ignored"); M8P#145 (`LIBUSB_ERROR_TIMEOUT` before download, CM5, unresolved) | verified-source (methods); community (DFU failure on CM5) | Yes (M5P STM32G0B1 over the same hub) | **No** (`dfu-util` not in packages) |
| 8 | No host control of MCU BOOT0/RESET | All | Nothing to configure. BOOT0 and RESET are push buttons only (M8P V2: K2/K3). No CM GPIO reaches them | Manta schematics (MCU pages) | verified-source | n/a | n/a |
| 9 | Pi fan header | M5P, M8P V1.1, M8P V2.0 (not V1.0) | Header is a MOSFET on **GPIO26**, not CM5 `Fan_PWM` (pin 19 unconnected). Use `dtoverlay=gpio-fan,gpiopin=26,temp=60000` (on/off, kernel) or Klipper `[temperature_fan]`/`[controller_fan]` with `pin: host:gpiochipN/gpio26` (find N with `gpiodetect`). Jumper selects 5/12/24 V | M5P manual + schematic (Q6 gate = GPIO26); M8P V1.1 manual §2.3.2 ("Pi-FAN controlled by GPIO26"); overlays README (`gpio-fan`) | verified-source | Yes | No |
| 10 | Thermal | All | Heatsink on the CM5; watch `/sys/class/thermal/thermal_zone0/temp`. KOS runs `performance` + `arm_boost=1`, so measure in the enclosure. CM5 throttles to stay below 85 °C | CM5 datasheet §4.4; BTT manuals ("CM4/CB1 may overheat") | verified-source | Yes | No (no fan control) |
| 11 | No power button, halt is final | All | Pin 92 (CM4 RUN_PG, CM5 PWR_BUT) is not connected (R5/R6 NC). With `POWER_OFF_ON_HALT=1` (CM5 default) a halted CM5 stays off until 24 V is cycled. Fine for a printer; document it. Reboot is unaffected | RPi EEPROM docs (`POWER_OFF_ON_HALT` default 1 on CM5); Manta schematics | verified-source | Yes (`sudo poweroff`, then see whether it comes back without a power cycle) | n/a (doc only) |
| 12 | No RTC battery | All | VBAT (pin 76) is "Reserved"/unconnected on the Manta. The CM5 RTC runs only while powered. Rely on NTP (already observed). `dtparam=rtc=off` is optional | CM5 datasheet Table 14; Manta schematics | verified-source | Yes (already observed) | n/a |
| 13 | No USB 3 | All | Nothing to do. CM5 USB3 sits on CM4 CAM0/DSI0 pins; Manta has no CAM0/DSI0 connector. The cm4io DTB disables `rp1_usb0/1`. All ports are USB 2.0 through the FE1.1S hub | CM5 datasheet B.1; `bcm2712-rpi-cm4io.dtsi`; Manta schematics | verified-source | n/a | n/a |
| 14 | Serial console on the board's Type-C (CH340E) | M5P, M8P V1.1/V2 | On CM5, `serial0` = `ttyAMA10` (module debug UART, JST/test points), not GPIO14/15. To get the console on the Manta's CH340E (Type-C, slide switch set to UART), add `dtparam=uart0_console` | RPi docs (UARTs: Pi 5 primary = UART10); overlays README (`uart0_console`); Manta schematics (CH340E on Pi-TX/Pi-RX, SW2 selector) | verified-source | **Yes. Useful for debugging the SD hang** | No (`enable_uart=1` only) |
| 15 | Wi-Fi antenna | All | Internal PCB antenna is the default (`dtparam=ant1`). Inside a metal electronics bay, fit a U.FL antenna and add `dtparam=ant2` | CM5 datasheet §2.1, §4.1.2 | verified-source | Yes | No |
| 16 | 5 V power budget | M8P (Brokkr) especially | CM5 needs up to 2.5 A at 5 V. Keep LED strips and other 5 V loads off the board's 5 V, or use a separate buck. Check `vcgencmd get_throttled` or the hwmon under-voltage alarm | CM5 datasheet B.3; M8P#151 (fixed by moving LED sticks to a buck); M8P V2 wiki (bulk caps added for CM4 start-up dips) | verified-source + community | Partially (M5P has the same TPS5450 5 V rail; Brokkr's loads differ) | No (no `raspi-utils`/`vcgencmd` in image) |
| 17 | eMMC CM5 (if ever used) | All | DIP 3 (RPIBOOT) + 4 (USBOTG) ON, Type-C to a Linux PC, `rpiboot -d mass-storage-gadget64` built from current `usbboot`. EEPROM: `rpiboot -d recovery5` with DIP 1 (EEPROM_nWP) OFF. Back to OFF afterwards. eMMC CM5 ignores the SD slot | M8P#142 (Windows rpiboot failed; Linux/WSL + source build worked); RPi CM bootloader docs; BTT manuals | verified-source + community | Partially (the procedure works for a Lite CM5's EEPROM too) | n/a |
| 18 | Leave DIP 2 (nEXTRST) OFF | All | On CM5, pin 100 is CAM_GPIO1, not nEXTRST. DIP 2 pulls it to GND through 220 R | CM5 datasheet Table 14; Manta schematics (SW1) | verified-source (pin); unconfirmed (effect) | Yes | n/a |
| 19 | DIP 4 (USBOTG) OFF in normal use | All | DIP 4 grounds USB_OTG_ID, which flips the RS2227 switch from the hub to the Type-C port. With it ON the MCU disappears even though `dr_mode=host` is set | Manta schematics (RS2227 Sel = USBOTG_ID) | verified-source (wiring); unconfirmed (CM5 behaviour) | Yes | n/a |
| 20 | Camera on CSI | All | CAM1 only (15-pin). CM5 has no hardware H.264 encoder, so raw cameras cost CPU; UVC MJPEG/H.264 webcams are fine | Manta schematics (P4/P5 = CAM1); M8P#131 (dberlin) | verified-source + community | Yes | n/a |
| 21 | CAN | All | No CM5 change. The transceiver (SN65HVD1050) hangs off the MCU's FDCAN1. The CM5 sees CAN only through the MCU's USB-to-CAN bridge (`gs_usb`). No SPI CAN on the boards | Manta schematics; PLAN §21.6 (working on Sindri) | verified-source | Yes (working) | Yes |

---

## 3. Per-topic notes

### 3.1 config.txt / overlays / dtparams

- **USB:** `dtoverlay=dwc2,dr_mode=host` is required. RPi's CM5 datasheet: "To enable USB 2.0 functionality, add the dtoverlay=dwc2,dr_mode=host overlay setting to your config.txt file." [verified-source] BTT documents the same line for CM4 on M8P V2 and M5P [verified-source]. On CM4 some setups worked without it, and CM5 drops that fallback, so people lost all USB when swapping CM4 to CM5 (dberlin, M8P#131) [community]. KOS has it under `[cm5]`. `otg_mode=1` under `[cm4]` is the RPi OS CM4 default and is irrelevant to CM5 [verified-source, RPi config.txt `otg_mode`].
- **Device tree selection:** RPi ships `bcm2712-rpi-cm5{,l}-cm5io.dtb` and `bcm2712-rpi-cm5{,l}-cm4io.dtb`. PhilE (Raspberry Pi engineer): "The CM5 has no way of knowing which carrier it is fitted to - you need to tell it. For a CM4IO, add ... `device_tree=bcm2712-rpi-cm5-cm4io.dtb`" [verified-source, forum t=383557]. The Manta CM page is a CM4IO-style design, the same "200Pin-CM4" symbol on every board. The cm4io include does three things [verified-source, `bcm2712-rpi-cm4io.dtsi`]: maps `i2c_csi_dsi1` (CAM1/DISP1) to i2c6 on GPIO38/39, `i2c_csi_dsi0` to i2c0, and disables `rp1_usb0`/`rp1_usb1` ("not usable on CM4IO"). The Lite DTB matters: `bcm2712-rpi-cm5l.dtsi` turns `sd_io_1v8_reg` into a GPIO-switched 3.3/1.8 V regulator. The non-Lite DTB has a fixed 1.8 V regulator, which breaks SD on a Lite. That is the failure in siderolabs PR #98 [verified-source]. Open question: whether the firmware swaps in the `l` variant itself when `device_tree=` names the non-Lite file (see §4). Safest is for KOS to name the Lite file on Lite modules.
- **PCIe:** not routed to any connector on M5P or M8P (nets end at labels, no M.2 on the block diagrams) [verified-source, schematics]. Nothing to enable.
- **Fan:** CM5's built-in `cooling_fan` (pwm-fan on `Fan_PWM`, pin 19) drives nothing on a Manta. Pin 19 was Ethernet nLED1 on CM4 and is left unconnected; the Ethernet LEDs use nLED2/nLED3 (pins 17/15) [verified-source]. The Pi-FAN header is GPIO26 → MOSFET (see 3.7).
- **RTC:** works only while powered. No VBAT [verified-source].
- **UART:** see item 14. CM5 Bluetooth uses its own internal UART, so GPIO14/15 are free [verified-source, `bcm2712-rpi-cm5.dtsi` `uarta` = BT].
- **SPI/I2C:** the Manta's 9-pin "SPI" FPC (SOC SPI for BTT TFT35-SPI style screens) uses GPIO9/10/11 (SPI0) plus GPIO4/17/22/27 [verified-source, schematic]. These are ordinary 40-pin GPIO functions on CM5 (RP1, same numbering as Pi 5) [verified-source, CM5 datasheet §2.9]. Enable with `dtparam=spi=on` plus the screen's overlay. No CM5+Manta SPI-screen report found. ADXL345 headers on M8P V2 ("345SPI") are on the **MCU**, not the CM5 [verified-source].

### 3.2 USB

- Path on all three boards: CM `USB2_P/N` (pins 103/105) → RS2227 2:1 switch (Sel = `USBOTG_ID`, DIP 4) → FE1.1S 4-port USB 2.0 hub → MCU (STM32 PA11/PA12) plus external ports. On M5P, USB-A ports. On M8P V2, 2× USB-A plus a 4-pin 2.54 mm USB header [verified-source, schematics].
- CM5 USB 3.0 pairs land on the old CAM0 (128–142) and DSI0 (157–171) pins [verified-source, datasheet B.1]. Manta has no CAM0/DSI0 connector, so no USB 3 [verified-source]. Pin 111 (CM4 VDAC_COMP, CM5 VBUS_EN) is not used.
- **Dead hub after a crash:** M8P#68. One user moved the same CM5 to a known-good M5P and it found all devices. That points at the M8P hub hardware, not the CM5 [community]. Another M5P report: the MCU was missing until the module was reseated [community, Discourse 24488].
- M5P#15 (CM4): `dwc2` enabled but only the root hub shows. Reseating fixed it for one user [community].

### 3.3 CAN

- Onboard SN65HVD1050 sits on MCU FDCAN1 (M5P G0B1, M8P V1 G0B1, M8P V2 H723). The CM5 has no CAN controller of its own. CAN reaches the host only through Klipper's USB-to-CAN bridge on the MCU (`gs_usb`) [verified-source, schematics; KOS PLAN §12]. Working on Sindri today.
- Community: CM5 + M8P v2 + CAN (EBB2209, ERCF) "reliable" (igiannakas, M8P#131) [community].
- No CM5-specific CAN issue found. KOS already removed `RestartSec` from `99-can.network` for gs_usb (PLAN §21.6).

### 3.4 Display (M8P: Brokkr's touchscreen)

- Manta DSI connector = **DSI1**, 15-pin 1 mm FPC, 2 data lanes (D0, D1, CLK) plus SCL0/SDA0 and 3.3 V [verified-source, schematics P3 "DSI1"]. CSI = **CAM1**, 15-pin [verified-source].
- **BTT's instruction is CM4-only:** `wget .../dt-blob-disp1-cam1.bin -O /boot/firmware/dt-blob.bin` [verified-source, M5P/M8P manuals]. `dt-blob.bin` is read by `start.elf` [verified-source, RPi CM peripheral guide]. On Pi 5-class firmware, "Instead of loading start.elf, the firmware loads the Linux kernel" [verified-source, RPi boot flow docs], and DSI is driven by Linux KMS on RP1. The documented CM method is a config.txt overlay, the same procedure for all Compute Modules including CM5: "To connect the display to DISP1/DSI1, add `dtoverlay=vc4-kms-dsi-7inch`; for DISP0/DSI0 add `...,dsi0`" [verified-source, RPi display docs]. M5P#43 / Discourse 24690: CM5 + M5P + Freenove 5" DSI using the dt-blob method failed (backlight flash, then nothing). Unresolved. The thread never tried KMS overlays or the cm4io DTB [community].
- **I2C jumper hint from RPi docs:** On CM5IO, DISP1 needs jumpers on J6 and DISP0 needs none. On CM4IO it is the other way round [verified-source, display docs]. So the CM5's default I2C-for-DSI1 is not where a CM4 carrier wires it. The cm4io DTB fixes this for the Manta (item 2/4).
- **Known working:** mykepredko runs **BTT TFT5 (DSI, 15-pin)** on Manta M8P, M5P and his own board, on CM4, **CM5**, CB2 and Orange Pi CM4 [community, Discourse 24690]. He did not post his CM5 config.
- Cables: Pi 5-style 22-pin 0.5 mm cables do not fit. Use the 15-pin 1 mm cable that came with a Pi 4-class DSI screen [community, Discourse 24690].
- KlipperScreen / HelixScreen on CM5: no CM5+Manta report found either way. Both need a KMS display, so `vc4-kms-v3d` plus the panel overlay (or HDMI). Mini12864 on the MCU's EXP headers works on CM5 + M8P V2 [community, M8P#131]. That screen is MCU-driven and independent of the CM5.
- BTT HDMI5/HDMI7: HDMI plus USB touch, so nothing CM5-specific beyond KMS. BTT's compatibility list names CB1 on Manta, not CM5 [unconfirmed for CM5].

### 3.5 GPIO and pins that change meaning (CM4 → CM5), Manta impact

From CM5 datasheet Table 14, cross-checked against the Manta CM pages [verified-source]:

| CM pin | CM4 | CM5 | On the Manta | Impact |
|---|---|---|---|---|
| 16 | SYNC_IN | Fan_tacho | net label only | none |
| 19 | Ethernet nLED1 | Fan_PWM | unconnected (LEDs on nLED2/3) | CM5 fan PWM unusable; Ethernet LEDs fine |
| 76 | Reserved | VBAT (RTC) | unconnected | no RTC backup |
| 92 | RUN_PG | PWR_Button | via R5/R6 = NC (not fitted) | no power button / wake |
| 94, 96 | AnalogIP1/0 | CC1/CC2 | AIN labels, unused | none |
| 99 | Global_EN | PMIC_ENABLE | via NC resistor | none |
| 100 | nEXTRST | CAM_GPIO1 | DIP SW1-2 to GND via 220 R | keep DIP 2 OFF |
| 104/106 | Reserved | PCIE_DET_nWAKE / PCIE_PWR_EN | unconnected | none |
| 111 | VDAC_COMP | VBUS_EN | "TV_OUT" label, no connector | none (no composite on Manta) |
| 128–142 | CAM0 | USB3-0 | no CAM0 connector | no USB 3 |
| 157–171 | DSI0 | USB3-1 | no DSI0 connector | no USB 3 |

- 40-pin header, GPIO0–27: same numbering on CM5; GPIO_VREF tied to 3.3 V on the Manta [verified-source]. GPIO2/3 have 1.8 kΩ pull-ups on CM5 [verified-source].
- **M8P V2 oddity:** CM GPIO4 is also wired to MCU PD9 (USART3_RX), as well as to the SPI FPC "LCD-CS" [verified-source, M8P V2 schematic p6]. If GPIO4 is used on the host, check it does not fight the MCU [unconfirmed].
- Onboard RGB (RGB1/RGB2 via 74LVC1G17), all fan headers except Pi-FAN, thermistors, endstops, steppers, probe, ADXL: all on the **MCU**, so unaffected by CM5 [verified-source, block diagrams].
- Klipper host MCU pins: name GPIO as `host:gpiochipN/gpioM`. The RP1 chip number moved between kernels (gpiochip4 → gpiochip0 in 2024, reports of other numbers since), so check with `gpiodetect` on the 6.18 kernel [community, raspberrypi/linux #6144]. The Klipper docs do not cover Pi 5/CM5 [verified-source, Klipper RPi_microcontroller.md].
- Hardware PWM on CM5: the `pwm` overlay's pin table is BCM283x-style. For any pin 0–27 use `dtoverlay=pwm-pio,gpio=N` ("Pi 5 only", which presumably includes CM5) [verified-source README; CM5 applicability unconfirmed]. GPIO26 is not a hardware-PWM pin on the classic table.

### 3.6 Ethernet, Wi-Fi, Bluetooth

- Ethernet: CM5 PHY pairs → TPD4EUSB30 ESD → RJ45 with LEDs on nLED2/nLED3, unchanged from CM4 [verified-source]. Working on Sindri.
- Wi-Fi: CM5 internal antenna by default. U.FL plus `dtparam=ant2` for an external antenna, chosen at boot only [verified-source, datasheet §2.1]. Placement guidance: 10 mm clearance, no metal under the antenna [verified-source §4.1.2]. WL_nDisable/BT_nDisable go to labels only on the Manta (not tied low) [verified-source].
- Bluetooth: internal UART on CM5. No Manta interaction.

### 3.7 Power, cooling, fan

- CM5: "Power supply designs should accommodate 5 V at up to 2.5 A". Idle about 400 mA, typical about 900 mA [verified-source, datasheet B.3, §3.3]. Manta 5 V comes from a TPS5450 (5 A, 6 A peak) shared with the USB ports, the 5 V fan option and the CM [verified-source, BTT]. M8P V2 added bulk capacitance at the core-board 5 V input because CM4 start-up caused dips [verified-source, M8P V2 wiki].
- M8P#151: CM5 + M8P random under-voltage on reboot or power-up. Fixed by moving LED sticks off the board 5 V to a buck converter [community].
- Thermal: BCM2712 throttles to stay below 85 °C [verified-source, §4.4]. BTT warns that CM4/CB1 can overheat [verified-source]. CM5 "runs hotter" is consistent but has no Manta-specific numbers [unconfirmed].
- Pi-FAN: M5P manual lists "3 × 2-pin CNC (FAN0, FAN1, Pi-FAN) (5/12/24 V selectable)". The schematic shows `J23 Pi-FAN`, Q6 MOSFET, gate from **GPIO26** [verified-source]. M8P V1.1 added "Pi-FAN (controlled by GPIO26)". **M8P V1.0 has none** [verified-source, M8P V1.x manual §2.3; V1.0 schematic has no Pi-FAN net]. M8P V2.0 manual lists "1x 2-pin Pi FAN" and the schematic has GPIO26 → Pi-FAN [verified-source].

### 3.8 Boot: SD, eMMC, EEPROM, warm reboot

- **SD power wiring (key finding):** on the M5P V1.0, M8P V1.1 and M8P V2.0 schematics, the "SOC CARD" socket's VDD (pin 4) goes straight to **+3.3V**, and the CM's `SD_PWR_ON` (pin 75) has only a net label, with no load switch [verified-source]. RPi CM5 datasheet §2.7: "SD card. Use the SD_PWR_ON signal to control an external power switch for an SD card ... SD cards require a power switch controlled by SD_PWR_ON; this is the only way to reset the SD card." [verified-source]. The CM5 Lite DT models SD_PWR_ON as the card's `vmmc` regulator (`sd_vcc_reg`, AON GPIO 4) and switches I/O voltage on-module (`sd_io_1v8_reg`, AON GPIO 3) [verified-source]. Linux runs the card at SDR104, i.e. 1.8 V signalling (KOS log: both cards SDR104). On a warm reboot, the kernel's power-off of the card is a no-op on the Manta. The card is left in 1.8 V mode, and the bootloader has to re-initialise a card that never lost power.
- Why only some cards hang: unconfirmed. Plausibly, cards differ in how they answer a 3.3 V re-init while stuck in 1.8 V signalling. This matches "ACT LED solid; power cycle recovers" [unconfirmed].
- **Workarounds, in order of what to test on Sindri:**
  1. `sdhci.debug_quirks2=0x4` on the kernel command line. `SDHCI_QUIRK2_NO_1_8_V` = `1<<2` (`sdhci.h`); with it set, `sdhci_setup_host()` clears SDR104/SDR50/DDR50 and `MMC_CAP_UHS` [verified-source, kernel code]. `MMC_SDHCI=y` in `bcm2712_defconfig`, so it goes on the cmdline [verified-source]. Caveats [verified-source from code]: `debug_quirks2` *replaces* `host->quirks2` (brcmstb ORs `PRESET_VALUE_BROKEN` back in afterwards). It hits all SDHCI hosts, so Wi-Fi SDIO drops to high-speed and an eMMC CM5 loses HS200/HS400. The card runs at High Speed, 50 MHz, about 20–25 MB/s. Whether it cures the hang: **[unconfirmed]**. Verify with `cat /sys/kernel/debug/mmc0/ios` (expect `signal voltage: 3.30 V`, timing `sd high-speed`). The DT property `no-1-8-v` would be cleaner, but `sdhci-brcmstb` never calls `sdhci_get_property()`, so it is ignored [verified-source]. Overlays cannot delete the `sd-uhs-*` properties, so a DT route means shipping a modified DTB [unconfirmed].
  2. EEPROM `SD_QUIRKS=1` ("Disable SD High Speed modes. The card clock is limited to 12.5 MHz", bootloader only) [verified-source, EEPROM docs]. Also `SD_BOOT_MAX_RETRIES=N` (default 0, `-1` = infinite) [verified-source]. ClockworkPi uConsole (another CM4-designed carrier) users run `SD_QUIRKS=1`, `SD_BOOT_MAX_RETRIES=2..5`, `BOOT_ORDER=0xf461` on CM5 Lite for SD detection problems [community]. KOS ships no `rpi-eeprom`, so change it with `rpiboot -d recovery5` or a temporary `rpi-eeprom` install. Whether `rpi-eeprom-update` works in-OS on CM5 is unclear: the RPi docs say CM self-update is disabled by default [verified-source].
  3. Hardware: a load switch on SD VDD driven by SD_PWR_ON. Not practical on a Manta.
- Other CM5 SD/reboot issues that do **not** match this setup: raspberrypi/linux #7014 (80 s shutdown delay with *no* SD card, NVMe boot; workaround `dtparam=sd=off`) and #6647 (no-Wi-Fi CM5 hangs on reboot through unused mmc1). Sindri's CM5 has Wi-Fi and boots SD [community].
- **Halt behaviour:** `POWER_OFF_ON_HALT` default `1` on CM5. Halt puts the PMIC in standby and only the power button wakes it [verified-source]. The Manta has no power button, so after `poweroff` cycle the 24 V.
- **eMMC CM5:** an eMMC CM5 ignores the SD slot [verified-source, BTT + RPi]. Flashing: DIP 3 + 4 ON, Type-C to the PC, `rpiboot -d mass-storage-gadget64` [verified-source, RPi eMMC docs]. Community: Windows rpiboot failed on CM5 + M8P V2. Linux/WSL with usbboot built from source worked. A broken EEPROM boot was fixed with `rpiboot -d recovery5` + `BOOT_ORDER=0xf256341` (DIP 1, 3, 4 ON per the reporter) [community, M8P#142]. Note that DIP 1 is EEPROM_nWP and RPi says it must **not** be pulled low while writing the EEPROM [verified-source]. Check the switch polarity on the board before trusting either. M8P V1.1 user could not get rpiboot to see an eMMC CM5. BTT says the boards "work fine with the CM5" and to follow the CM5 procedure [community, M8P#131]. RPi: CM5 needs kernel 6.12+ and firmware from 2025-03-10 or later [verified-source]. KOS is on 6.18.

### 3.9 Flashing the Manta MCU from the CM5

- BOOT0 and RESET are buttons only. No CM GPIO is wired to them on M5P, M8P V1.1 or M8P V2 [verified-source, MCU schematic pages]. So there is no host-driven DFU entry. Rely on Klipper's software bootloader request: `make flash FLASH_DEVICE=/dev/serial/by-id/...` "would automatically put MCU into DFU, flash, restart" [community, M8P#145; BTT manuals].
- BTT: "dfu-util: Error during download get_status ... can be ignored" (after the `:leave` reset) [verified-source]. M8P#145 differs: on CM5 + M8P V2, `dfu-util` fails with `LIBUSB_ERROR_TIMEOUT` at "Determining device status", *before* download, on two boards. A third user hit the same on one M8P but not on another. Unresolved [community]. Workarounds: Katapult (over USB or CAN) [community, M8P#145], or the **MCU-Card** microSD slot with `firmware.bin` (renamed `FIRMWARE.CUR` on success; needs the factory bootloader) [verified-source].
- On a USB-to-CAN bridge setup like Sindri, Katapult in the MCU gives `flash_can.py`/`flashtool.py` access without DFU [community].
- KOS gap: `dfu-util` is not in `build/packages.txt`.

### 3.10 Board differences

- **M5P V1.0:** STM32G0B1. CM page as above. Pi-FAN on GPIO26. CH340E UART-to-USB on the Type-C via a slide switch. 1 CAN header.
- **M8P V1.0:** STM32G0B1. **No Pi-FAN, no CH340E UART-to-USB** (added in V1.1). Has the RS2227 switch and the CAN transceiver [verified-source, V1.0 schematic text; V1.x manual §2.3].
- **M8P V1.1:** adds CAN headers, the USB-port function switch (UART-to-USB / USB OTG), Pi-FAN (GPIO26) and an e-fuse on 5 V/12 V [verified-source].
- **M8P V2.0:** STM32H723. More 5 V bulk capacitance, higher USB current. CM page the same as V1.1 apart from the power LED drive [verified-source].
- BTT does not officially claim CM5 support in any Manta manual or wiki page (no CM5 text found). BTT in M8P#131: "The boards work fine with the CM5" [community, BTT account].

---

## 4. Open questions / not found

- **Which DTB the firmware loads by default on a CM5 Lite, and whether it swaps in the Lite variant when `device_tree=bcm2712-rpi-cm5-cm4io.dtb` is given.** Not documented. Check on Sindri: `cat /proc/device-tree/model` and `tr '\0' '\n' < /proc/device-tree/compatible`, before and after.
- Whether `sdhci.debug_quirks2=0x4` or EEPROM `SD_QUIRKS=1` cures the 128 GB warm-reboot hang. No report found of the exact combination "CM5 + carrier without SD power switch + warm-reboot hang". The datasheet requirement and the Manta schematic make the mechanism likely, but it is still unproven.
- The exact DSI overlay for Brokkr's touchscreen. The model is not stated. No CM5 + Manta DSI config has been published. BTT TFT5 is reported working on CM5 + Manta without config details.
- KlipperScreen / HelixScreen on CM5 specifically: no reports found either way.
- Root cause of M8P#145 (DFU `LIBUSB_ERROR_TIMEOUT` on CM5): unresolved upstream.
- Whether M8P V1.0/V1.1 with CM5 has extra issues beyond the eMMC-flashing reports in M8P#131. Nothing specific found.
- Whether `rpi-eeprom-update`/`rpi-eeprom-config --apply` works in-OS on CM5 Lite (RPi docs say CM self-update is disabled by default). Not verified.
- Whether CM5's `pwm-pio` overlay applies to CM5 (README says "Pi 5 only").
- Manta CM-socket placement versus Wi-Fi antenna performance: no measurements found.

---

## 5. Sources

Raspberry Pi (primary)
- CM5 datasheet (Appendix B CM4/CM5 differences, §2.4.2 USB, §2.7 SDIO/SD_PWR_ON, §2.11 fan, §2.12.2 control pins, §3.3 power, §4.4 thermal): https://datasheets.raspberrypi.com/cm5/cm5-datasheet.pdf (redirects to https://pip.raspberrypi.com/documents/RP-008180-DS-cm5-datasheet.pdf)
- Overlay/dtparam README (`i2c_csi_dsi*`, `ant2`, `uart0_console`, `rtc`, `sd*`, `gpio-fan`, `pwm-pio`): https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm/boot/dts/overlays/README
- CM4IO include for CM5: https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi-cm4io.dtsi
- CM5 / CM5 Lite device trees: https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi-cm5.dtsi , https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi-cm5l.dtsi
- SDHCI quirk source: https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/mmc/host/sdhci.h , https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/mmc/host/sdhci.c , https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/mmc/host/sdhci-brcmstb.c , https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/mmc/host/sdhci-pltfm.c , https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/configs/bcm2712_defconfig
- PhilE on CM5 + CM4IO DTB: https://forums.raspberrypi.com/viewtopic.php?t=383557
- Touch Display on Compute Modules (overlay, DSI0/1, J6 jumpers): https://www.raspberrypi.com/documentation/accessories/display.html
- EEPROM settings (`POWER_OFF_ON_HALT`, `SD_QUIRKS`, `SD_BOOT_MAX_RETRIES`, `BOOT_ORDER`): https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration
- Boot flow, Pi 5 differences (no `start.elf`): https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#eeprom-boot-flow
- CM bootloader / eMMC flashing / peripheral guide (CM5 kernel 6.12+, firmware ≥ 2025-03-10; `dt-blob.bin` read by `start.elf`): https://www.raspberrypi.com/documentation/computers/compute-module.html
- UARTs (Pi 5 primary = UART10 / ttyAMA10): https://www.raspberrypi.com/documentation/computers/configuration.html#configure-uarts
- `otg_mode`: https://www.raspberrypi.com/documentation/computers/config_txt.html#otg_mode-raspberry-pi-4-only
- usbboot (recovery5, mass-storage-gadget64): https://github.com/raspberrypi/usbboot

BigTreeTech (primary)
- M8P V2.0 wiki: https://global.bttwiki.com/M8P-V2_0.html
- M5P wiki: https://global.bttwiki.com/M5P.html
- M5P manual: https://github.com/bigtreetech/Manta-M5P/blob/master/BIGTREETECH%20MANTA%20M5P%20V1.0%20User%20Manual.pdf
- M5P schematic: https://github.com/bigtreetech/Manta-M5P/blob/master/Hardware/BIGTREETECH%20MANTA%20M5P%20V1.0-SCH.pdf
- M8P V1.0/V1.1 manual: https://github.com/bigtreetech/Manta-M8P/blob/master/V1.0_V1.1/BIGTREETECH%20MANTA%20M8P%20V1.0%26V1.1%20User%20Manual.pdf
- M8P V1.0 / V1.1 schematics: https://github.com/bigtreetech/Manta-M8P/blob/master/V1.0_V1.1/Hardware/BIGTREETECH%20MANTA%20M8P%20V1.0-SCH.pdf , https://github.com/bigtreetech/Manta-M8P/blob/master/V1.0_V1.1/Hardware/BIGTREETECH%20MANTA%20M8P%20V1.1-SCH.pdf
- M8P V2.0 manual / schematic: https://github.com/bigtreetech/Manta-M8P/blob/master/V2.0/BIGTREETECH%20MANTA%20M8P%20V2.0%20User%20Manual.pdf , https://github.com/bigtreetech/Manta-M8P/blob/master/V2.0/Hardware/BIGTREETECH%20MANTA%20M8P%20V2.0-SCH.pdf

Community
- M8P#131 Support for CM5 (dwc2 requirement, CAN works, eMMC flashing, no HW encode): https://github.com/bigtreetech/Manta-M8P/issues/131
- M8P#142 CM5 won't boot / rpiboot + recovery5 fix: https://github.com/bigtreetech/Manta-M8P/issues/142
- M8P#145 DFU from CM5 fails (`LIBUSB_ERROR_TIMEOUT`): https://github.com/bigtreetech/Manta-M8P/issues/145
- M8P#151 CM5 + M8P under-voltage (LED sticks on 5 V): https://github.com/bigtreetech/Manta-M8P/issues/151
- M8P#68 Dead USB hub (CM5 works in another M5P): https://github.com/bigtreetech/Manta-M8P/issues/68
- M5P#43 DSI + CM5 not working (dt-blob): https://github.com/bigtreetech/Manta-M5P/issues/43
- M5P#15 USB ports not working with CM4 (reseat): https://github.com/bigtreetech/Manta-M5P/issues/15
- Klipper Discourse, DSI on M5P + CM5 (BTT TFT5 works on CM5): https://klipper.discourse.group/t/cannot-get-5-inch-touch-screen-to-work-with-manta-m5p-dsi-cm5-43/24690
- Klipper Discourse, M5P + CM5 USB/dwc2: https://klipper.discourse.group/t/manta-m5p-flashing-and-running-custom-firmware/24269
- Klipper Discourse, M5P MCU missing until reseat: https://klipper.discourse.group/t/manta-m5p-not-picking-up-usb-devices-i-e-the-mcu/24488
- siderolabs CM5 Lite SD UHS PR (non-Lite DTB on Lite breaks SD): https://github.com/siderolabs/sbc-raspberrypi/pull/98
- raspberrypi/linux #7014 (CM5 Lite no-SD shutdown delay): https://github.com/raspberrypi/linux/issues/7014
- raspberrypi/linux #6647 (no-Wi-Fi CM5 reboot hang): https://github.com/raspberrypi/linux/issues/6647
- uConsole CM5 Lite EEPROM workaround: https://github.com/yazzang-homelab/uconsole-cm5-lite-headless-recovery , https://forum.clockworkpi.com/t/eeprom-config-and-the-cm5-lite/19649
- RP1 gpiochip renumbering: https://github.com/raspberrypi/linux/pull/6144
- Klipper host MCU doc: https://www.klipper3d.org/RPi_microcontroller.html

## Addendum 2026-10-19: Type-C slide switch on the M5P (from testing on Sindri)

- The M5P V1.0's Type-C function switch has no silkscreen. A Reddit post found by the owner says **toward the centre
  of the board = USB OTG** (for CM4); toward the edge is therefore UART-to-USB (CH340E) [community, unverified].
- On Sindri, with all DIP switches OFF, the Mac saw **no USB device at all** in either position, with a USB-C to C
  cable and with a USB-A to C path through an adapter. The printer was unaffected throughout. So the failure is the
  cable/adapter path (or missing CC pull-downs on the board's Type-C), not the switch position. `uart0_console` was not
  applied. Next try: switch toward the edge, a plain USB-A to USB-C data cable into a USB-A port or hub.

## Schematic review: M5P Type-C, slide switch and CH340E (2026-10-19)

Sources, all from `bigtreetech/Manta-M5P` (master):
- **SCH** = `Hardware/BIGTREETECH MANTA M5P V1.0-SCH.pdf`. PDF p1 is the index, p2 the block diagram, p3 the CM4
  sheet (all USB/UART parts below), p6 the MCU sheet. Grid zones (column letter/number) refer to the frame on that page.
  Net names were read from the drawing and checked against the Altium net/pin text embedded in the PDF.
- **PIN** = `Hardware/BIGTREETECH MANTA M5P V1.0-Pin.png` (BTT pin-out diagram, single image).
- **TOP** = `Hardware/BIGTREETECH MANTA M5P V1.0-SIZE-top.pdf` (top-side layout with pad names, 1 page).
- **MAN** = `BIGTREETECH MANTA M5P V1.0 User Manual.pdf` (35 pages).

Tags: [schematic], [manual] (MAN or PIN or TOP, i.e. BTT documents other than the schematic), [community], [inference].

### Summary of the wiring

```
Type-C "USB" (D+/D- = OUT_P/OUT_N, U6 TPD4EUSB30 ESD)
   -> SW2 (SS-3390S-L2, DPDT slide switch)
        pos. 2-1 / 5-4 (toward board centre, "USB-OTG"):  USBD_N/USBD_P -> U3 RS2227 HSD2-/HSD2+
        pos. 2-3 / 5-6 (toward board edge, "UART To USB"): D-/D+ -> U4 CH340E VD-/VD+ -> CM4 GPIO14/15 (UART0)
U3 RS2227: D+/D- = USB2_P/USB2_N (CM pins 105/103); Sel = USBOTG_ID (CM pin 101); HSD1 = USBH -> U5 FE1.1S upstream
U5 FE1.1S hub: port1 = STM32 USB (PA11/PA12), port2/3 = the two USB-A ports, port4 = "USB Host" 4-pin header
SW1 DIP 4 (USBOTG): ties USBOTG_ID to Type-C VBUS via R3 2.2k; R7 2.2k pulls USBOTG_ID to GND
```

### 1. Type-C connector ("USB", TYPE-C-16P) - SCH p3, zone C3

- D+/D-: A6 and B6 (DP1/DP2) are net **OUT_P**, A7 and B7 (DN1/DN2) are net **OUT_N** [schematic]. OUT_P/OUT_N go to
  U6 (TPD4EUSB30DQAR ESD array, SCH p3 zone D3) and to the common pins of the slide switch, SW2 pin 5 (OUT_P) and pin 2
  (OUT_N) [schematic]. They do **not** go to the RS2227 directly; they reach it only through SW2 [schematic].
- CC: CC1 (A5) and CC2 (B5) are **tied together** on one net **CC** with a single **R13 = 10 kΩ** to GND [schematic].
  There are **no separate 5.1 kΩ pull-downs**, one per CC pin.
- VBUS: A4/A9/B4/B9 are net **VBUS**. It goes to C8 0.1 µF and C9 10 µF to GND, to R3 (2.2 kΩ, to DIP switch 4) and to
  pin 2 of the **VUSB** 2-pin jumper (SCH p3 zone D2) [schematic]. VUSB pin 1 is the board **5V** rail (the input of
  U8 LPW5209 and C16) [schematic]. There is **no diode**. VBUS is not connected to the CH340E [schematic]. MAN p10: fit the
  jumper cap on VUSB "when using only the USB to power the board or provide power through the USB" [manual]. So with the
  jumper fitted, Type-C VBUS and the board 5 V rail are directly connected in both directions [inference].
- Naming trap: the jumper is labelled VUSB, but the **net** VUSB is something else: the output of U8 LPW5209
  (current-limited switch, EN tied to 5V) that powers the two USB-A ports (USB2.0*2 pins 1/5) [schematic].

### 2. Slide switch - SW2, SS-3390S-L2 - SCH p3, zone C6-C7

- It is a DPDT switch. Pins **2 and 5 are the commons** (OUT_N and OUT_P from the Type-C) [schematic].
  - **2-1 / 5-4**: OUT_N -> **USBD_N** (SW2-1), OUT_P -> **USBD_P** (SW2-4). USBD_N/USBD_P go to RS2227 U3 pin 8
    (HSD2-) and pin 9 (HSD2+) [schematic].
  - **2-3 / 5-6**: OUT_N -> **D-** (SW2-3), OUT_P -> **D+** (SW2-6). D-/D+ go to CH340E U4 pin 2 (VD-) and pin 1
    (VD+) [schematic].
- Physical direction:
  - TOP pad names: SW2-3/6 (CH340E side) are the row nearest the top board edge (the Type-C edge). SW2-1/4 (USBD side)
    are the row nearest the board centre. The switch slides at right angles to that edge [manual, TOP].
  - The BTT pin-out diagram (PIN, top right, the "UART To USB / USB-OTG" legend, with a box drawn around the switch
    next to the Type-C) shows the actuator **toward the board edge = "UART To USB"** and **toward the centre =
    "USB-OTG"** [manual, PIN].
  - Both agree, provided the usual slide-switch convention holds: the actuator end bridges the common to the outer pin
    on that side [inference; the SS-3390S-L2 datasheet was not checked].
- The Reddit claim "toward the centre = OTG mode for CM4" is **confirmed** by BTT's own pin-out diagram [manual, PIN].
  But "OTG" here only means the Type-C is routed to the RS2227's HSD2 port. It reaches the CM only when DIP 4 is ON
  (see 5) [schematic].

### 3. CH340E - U4 - SCH p3, zone C7

- VD+ (pin 1) = D+ and VD- (pin 2) = D-, both from SW2. These nets reach the Type-C only in the edge ("UART To USB")
  position [schematic].
- RXD (pin 9) = net **Pi_TX**. That net also has the labels **GPIO14** (the same net) and goes to CM4 connector pin 55
  (U1A "GPIO14") and to 40-pin header H1 pin 8 [schematic].
- TXD (pin 8) goes through **D26 1N4148** to net **Pi_RX** (= GPIO15, CM4 pin 51, H1 pin 10) [schematic]. The diode's
  cathode is on the CH340E side, so the 5 V CH340E can only pull Pi_RX low. The high level comes from the CM side
  [inference from the symbol orientation].
- Power: VCC (pin 7) = board **5V**, V3 (pin 10) = only C7 0.1 µF to GND (the CH340's 5 V supply mode), GND (pin 3) = GND,
  RTS#/CTS#/TNOW not connected [schematic]. It is powered whenever the board 5 V rail is up, whatever the switch
  position and whether or not the host supplies VBUS. Its USB lines reach the Type-C only in the edge position [schematic].
- Pi_TX/Pi_RX (GPIO14/15) appear only on SCH p3. The MCU sheet (p6) has no net connected to them [schematic].
  So the CH340E does not touch the STM32.
- CB1: the nets use CM4 names. Which CB1 UART lands on those CM pins cannot be read from this schematic.

### 4. The "CH340E bridges the core board and the STM32G0B1" claim: inaccurate

- What the CH340E bridges: the **Type-C port (USB)** and the **core board's UART0 on GPIO14/15** [schematic, p2 block
  diagram "Type-C -> Pi-USB -> CH340E -> UART -> CM4", and p3]. It is a USB serial console for the CM4/CB1 into a PC.
  It has nothing to do with the MCU.
- What links the core board and the MCU:
  - **USB through the FE1.1S hub**. STM32 U13 pin 43 PA11 = net **USB_N** and pin 44 PA12 = **USB_P** (SCH p6)
    connect to FE1.1S U5 pins 11/12 (**DM1/DP1**, downstream port 1, SCH p3 zone C1-C2) [schematic].
  - The hub's upstream port is DMU/DPU (pins 14/15) = **USBH_N/USBH_P**. That goes to RS2227 HSD1-/HSD1+ (U3 pins 6/7)
    [schematic].
  - RS2227 common D+/D- (pins 3/4) = **USB2_P/USB2_N** = CM connector pins 105/103 [schematic].
  - Klipper is configured for "USB (on PA11/PA12)" (MAN p32) [manual]. The CM4 USB must be enabled with
    `dtoverlay=dwc2,dr_mode=host` (MAN p25) [manual].
- There is no UART between the CM and the STM32 on the schematic [schematic].
- Minor inconsistency: the p2 block diagram draws ST-USB into hub "USB4". The detailed sheet (p3) puts USB_N/USB_P on
  DM1/DP1 and USB4_N/P on the "USB Host" 4-pin header [schematic]. The detailed sheet is the one to trust.
- The STM32's FDCAN goes to the SN65HVD1050 CAN transceiver and connectors, not to the CM (p2) [schematic].

### 5. DIP switch SW1 (DSHP04) - SCH p3, zone B7-B8. Silkscreen per TOP: eeprom-WP / NEXTRST / RPIBOOT / USBOTG

- **DIP 1**: pin 1 **EEPROM_nWP** (CM pin 20) to pin 8 = GND. ON = EEPROM write-protect asserted [schematic].
- **DIP 2**: pin 2 **nEXTRST** (CM pin 100) to pin 7, then R2 220 Ω to GND [schematic]. What ON does depends on how the CM
  uses that pin [inference].
- **DIP 3**: pin 3 **nRPIBOOT** (CM pin 93) to pin 6 = GND. ON = forces USB boot (rpiboot) [schematic]. MAN p24: DIP 3 +
  DIP 4 ON to flash eMMC over the Type-C [manual].
- **DIP 4** (USBOTG):
  - Wiring: pin 4 = net **USBOTG**, which connects through R3 2.2 kΩ to Type-C **VBUS**. Pin 5 = **USBOTG_ID**, which
    goes to CM pin 101 (USB_OTG_ID), to RS2227 **Sel** (U3 pin 2), and through R7 2.2 kΩ to GND. RS2227 OE# (pin 10) is
    tied to GND, so the switch is always enabled [schematic].
  - DIP 4 OFF: Sel/ID = low (R7). DIP 4 ON with VBUS present: Sel/ID ≈ VBUS × 2.2/(2.2+2.2) ≈ 2.5 V = high.
    DIP 4 ON without VBUS: still low [schematic + inference].
  - VBUS is present if a host supplies it on the Type-C **or** the VUSB jumper is fitted (then it is board 5 V)
    [schematic].
  - Which RS2227 port each Sel level selects is not printed on the schematic. Everything BTT documents fits Sel low =
    HSD1 (the hub) and Sel high = HSD2 (USBD -> SW2 -> Type-C):
    - MAN p24 needs DIP 4 ON for rpiboot over the Type-C [manual].
    - MAN p25 runs the hub with the CM USB in host mode, with DIP 4 OFF by default [manual].
    - The same pin is the CM's OTG ID: low = host [inference; RS2227 datasheet not checked].
- How DIP 4 interacts with the slide switch:
  - The CM's USB2 reaches the Type-C only when **DIP 4 ON** (RS2227 -> HSD2) **and** SW2 is toward the centre (USBD).
  - With DIP 4 ON, the CM's USB leaves the hub, so the STM32 and the USB-A ports disappear from the CM [inference from
    the wiring].
  - The CH340E path (SW2 toward the edge) does not depend on any DIP switch [schematic].

### 6. All DIPs OFF: what a computer on the Type-C should see, and why Sindri showed nothing

Expected:
- **Toward the centre (USB-OTG):** nothing. OUT_P/OUT_N go to RS2227 HSD2, but Sel is held low by R7, so the RS2227
  connects the CM to the hub (HSD1). HSD2 is left open [schematic + inference on the Sel polarity, see 5].
  Seeing no device in this position is **expected**.
- **Toward the edge (UART To USB):** a CH340 USB-serial device should enumerate whenever the board's 5 V rail is up.
  It does not need host VBUS, because the CH340E runs from board 5V [schematic]. The CM's UART0 console appears only if
  it is enabled on GPIO14/15 [inference]. Seeing nothing in this position is **not** explained by the design alone.

Explanations the documents support, most likely first:
1. **OTG position: DIP 4 OFF means the D+/D- lines are not connected to anything live.** This fully explains the
   centre-position result [schematic].
2. **C-to-C cable: non-standard CC termination.** CC1 and CC2 are tied together with one 10 kΩ to GND (R13), instead of
   5.1 kΩ on each [schematic]. Two effects [inference]:
   - If the Mac advertises 1.5 A or 3 A Rp (180/330 µA), 10 kΩ gives about 1.8 V / 3.3 V on CC. That is above the
     ~1.6 V Rd window, so the Mac may treat the port as "nothing attached" and never source VBUS or enable data.
   - With an **e-marked** C-to-C cable, the cable's Ra in the far plug's VCONN pin lands on the tied CC2 and appears in
     parallel with R13. The Mac then sees only Ra and does not attach.
   - This covers the C-to-C tests in both positions. It cannot explain the A-to-C test: legacy A-to-C cables carry
     their own 56 kΩ Rp, and the board's CC is ignored.
3. **VUSB jumper fitted (check Sindri):** board 5 V is then wired straight onto Type-C VBUS with no diode [schematic].
   A Type-C source expects vSafe0V before attaching. A port that already sees 5 V on VBUS, or a C-to-A adapter port
   that is back-fed, may refuse to attach or shut the port down [inference]. This would affect both cable paths and both
   positions. If the jumper is on, remove it before testing (the board is powered from 24 V anyway).
4. **Cable/adapter path** (charge-only C cable, or an adapter or hub that does not pass data): not visible in any
   document. It is still the simplest explanation for the A-to-C failure in the edge position [inference].
5. **Switch not fully seated in the edge position, or a fault in U6/U4:** cannot be determined from the documents.
6. **"CH340E only powered from the board" is not a cause.** It runs from board 5V, which was up (the printer was
   running). In the edge position it should have enumerated even with no host VBUS [schematic + inference].

Next test, as the schematic suggests:
- All DIPs OFF, VUSB jumper **off**, SW2 **toward the edge**.
- Use a known-good USB-A to USB-C **data** cable (not e-marked, no adapter) into a USB-A port or a USB-A hub on the Mac.
- Check `system_profiler SPUSBDataType` or `ioreg -p IOUSB` for a QinHeng/CH340 device. Its USB ID is expected to be
  1a86:7523 [inference].
- To reach the CM's own USB over the Type-C (gadget mode or rpiboot), set DIP 4 ON and SW2 toward the centre, and expect
  the hub (STM32, USB-A ports) to drop off while it is ON [schematic + manual p24].

## Addendum 2026-10-19: serial console on the M5P Type-C, tested

Working on Sindri (CM5 Lite + Manta M5P V1.0):

- Slide switch SW2 **toward the board edge** (UART-to-USB), all DIP switches OFF, `VUSB` jumper not fitted.
- Mac side: a USB-A to USB-C data cable through a USB-C adapter. It shows up as `/dev/cu.usbserial-<n>`, vendor
  `0x1a86` "USB Serial" (CH340E); the macOS built-in driver is enough. The earlier failures were the cable/adapter
  path, not the board.
- Pi side: add `dtparam=uart0_console` to `config.txt`. `/dev/serial0` then points at `ttyAMA0` (GPIO14/15), the
  kernel command line's `console=serial0,115200` resolves to `console=ttyAMA0,115200`, and a login prompt runs on it.
- Result: the full kernel boot log (`Booting Linux on physical CPU 0` onward) is readable on the Mac at 115200 8N1.
  This is the console for debugging a boot that fails before the network comes up. The firmware's own boot messages
  (`BOOT_UART=1`) still go to the CM5's separate debug UART, not this port.

## Addendum 2026-10-19: SD warm-reboot fix, tested

On Sindri (CM5 Lite + Manta M5P V1.0) with the 128 GB SDXC card that hung on every warm reboot (`FD4Q9`):

| Step | SD mode (`/sys/kernel/debug/mmc0/ios`) | Warm reboot |
|---|---|---|
| Before (stock cmdline) | UHS-I **SDR104**, 200 MHz, **1.80 V** | hung 2/2 earlier today; control run tonight hung too. Serial console: clean shutdown to `reboot: Restarting system`, then nothing (no `Booting Linux`) |
| `sdhci.debug_quirks2=0x4` added to `cmdline.txt` (after one power cycle) | **sd high-speed**, 50 MHz, **3.30 V** | **3/3 came back**, 25–26 s each; serial shows 3 × `reboot: Restarting system` followed by `Booting Linux` |

- Confirms the mechanism from the schematics: the Manta never power-cycles the SD card, so a card left at 1.8 V
  signalling cannot be re-initialised by the firmware after a warm reset. Keeping the card at 3.3 V avoids it.
- Cost: card bus at 50 MHz. Sequential read measured 22.4 MB/s (`dd ... iflag=direct`, 400 MiB), near that mode's
  ~25 MB/s ceiling; SDR104 is several times faster. For Klipper (small writes, gcode reads) this is not limiting.
- Side effects checked: no MMC errors, `brcmfmac` Wi-Fi driver loads (shares the SDHCI core). Wi-Fi throughput and
  association were **not** tested. `debug_quirks2` replaces the quirk flags of every SDHCI host rather than adding to
  them; nothing visibly broke here, but it is a blunt switch.
- Applies only to carriers without SD power switching (the Mantas). Raspberry Pi's own CM5IO board switches SD power
  and does not need it.

## Pi-FAN on the Manta: Klipper example (2026-10-19)

The Pi-FAN header is VBB (the fan-voltage jumper's selection: 5, 12 or 24 V, always on) and a low-side MOSFET driven by
**GPIO26**. Tested on Sindri's M5P with a 24 V fan: `pinctrl set 26 op dh` runs it, `dl` stops it. GPIO26 is not a
hardware PWM pin, so treat the fan as on/off. On a CM5 the pin is on `gpiochip0` (`pinctrl-rp1`); Klipper reaches it
through the host MCU, so `printer.cfg` needs `[mcu host]` (`serial: /tmp/klipper_host_mcu`; KOS starts `klipper-mcu`
by itself when a config references it).

Cool the CM5 on its own temperature (recommended):

```ini
[temperature_sensor CM5]
sensor_type: temperature_host

[temperature_fan pi_fan]
pin: host:gpiochip0/gpio26
sensor_type: temperature_host
control: watermark      # on/off around target_temp; no PWM needed
target_temp: 60
max_delta: 5            # on above 65 °C, off below 55 °C
max_power: 1.0
shutdown_speed: 1.0     # run the fan if Klipper shuts down
min_temp: 0
max_temp: 90
```

Or run it whenever the printer is active (steppers or heaters on):

```ini
[controller_fan pi_fan]
pin: host:gpiochip0/gpio26
idle_timeout: 300
```

Check the chip number on a new kernel with `sudo grep -B1 GPIO26 /sys/kernel/debug/gpio`: it must sit under the
`pinctrl-rp1` chip. Klipper itself has not been tested with these sections yet; the GPIO26 on/off path has.

Raw serial captures (115200 8N1, Manta Type-C CH340E): control hang `docs/logs/2026-10-19-cm5-m5p-128gb-control-hang.serial.log`, three warm reboots with the fix `docs/logs/2026-10-19-cm5-m5p-128gb-sd3v3-3-warm-reboots.serial.log`.

## Addendum 2026-10-20: CM4-carrier device tree from the first boot

Raspberry Pi's `config.txt` filter `[board-type=…]` matches the type field of the revision code, so the firmware itself
can pick the right carrier tree, from the first boot, with no detection script:

```ini
[board-type=0x18]
device_tree=bcm2712-rpi-cm5-cm4io.dtb
[board-type=0x1a]
device_tree=bcm2712-rpi-cm5l-cm4io.dtb
```

Sindri's CM5 Lite reports revision `c041a0`, board type `0x1a`. Tested with these lines appended to `config.txt`:
after a warm reboot the two unusable USB 3 root hubs were gone (cm4io tree loaded), the SD card still booted (so the
Lite tree, not the eMMC one, was chosen), and the CAN bridge, Nitehawk and `can0` came up. `0x18` (CM5 with eMMC) is
from the revision-code table and has not been tested on hardware. KOS's CM5 `config.txt` ships these lines active;
`carrier_dt=off` in `kos.conf` comments them out on the next boot.
