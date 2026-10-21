# MCU firmware builds

Every build that has been flashed to real hardware, with the exact `make menuconfig` values, so they can be checked
against the board vendor's documentation and rebuilt identically.

## BTT Manta M5P main MCU, Klipper USB-to-CAN bridge

Flashed 2026-10-19 on Sindri (Manta M5P V1.0 with a Raspberry Pi CM5 Lite), from the CM5, through Katapult.

| `make menuconfig` | Value | Kconfig symbol | BTT's doc | Previous firmware reported |
|---|---|---|---|---|
| Enable extra low-level configuration options | yes | `CONFIG_LOW_LEVEL_OPTIONS=y` | yes | |
| Micro-controller Architecture | STMicroelectronics STM32 | `CONFIG_MACH_STM32=y` | STM32 | |
| Processor model | STM32G0B1 | `CONFIG_MACH_STM32G0B1=y` | STM32G0B1 | `MCU=stm32g0b1xx` |
| Bootloader offset | 8KiB bootloader (app at `0x8002000`) | `CONFIG_STM32_FLASH_START_2000=y` | 8KiB bootloader | not reported |
| Clock Reference | 8 MHz crystal (core 64 MHz) | `CONFIG_STM32_CLOCK_REF_8M=y` | 8 MHz crystal | `CLOCK_FREQ=64000000`, `RESERVE_PINS_crystal=PF0,PF1` |
| Communication interface | USB to CAN bus bridge (USB on PA11/PA12) | `CONFIG_STM32_USBCANBUS_PA11_PA12=y` | USB (on PA11/PA12) | `CANBUS_BRIDGE=1`, `RESERVE_PINS_USB=PA11,PA12` |
| CAN bus interface | CAN bus (on PD0/PD1) | `CONFIG_STM32_CMENU_CANBUS_PD0_PD1=y` | FDCAN1 RX PD0 / TX PD1 (pinout) | `RESERVE_PINS_CAN=PD0,PD1` |
| CAN bus speed | 1000000 | `CONFIG_CANBUS_FREQUENCY=1000000` | not stated | 1 Mbit on `can0` |
| USB ids, startup pins | defaults (`0x1d50:0x614e`, none) | | | |

- Full resolved config: [`manta-m5p-usb-can-bridge.config`](manta-m5p-usb-can-bridge.config). Rebuild with
  `make KCONFIG_CONFIG=docs/firmware/manta-m5p-usb-can-bridge.config` from the same Klipper commit.
- Klipper commit: `v0.13.0-809-gc63b29510` (the commit KOS pins). Output `klipper.bin` 50,224 bytes, sha256
  `86c9d4fa4c25337af4d1e5ae29d883b7b5fb7bcbe5a0681ffd5695b74fcd63ec`.
- BTT source: [`Manta-M5P/Firmware/Klipper/README.md`](https://github.com/bigtreetech/Manta-M5P/tree/master/Firmware/Klipper)
  (written for USB, not the CAN bridge) and the repo README pinout for FDCAN1.
- Katapult was already on the board: `flashtool.py -i can0 -u <canbus_uuid> -r` brought it up as
  `usb-katapult_stm32g0b1xx_<serial>` (USB `1d50:6177`). Flashed with
  `flashtool.py -d /dev/serial/by-id/usb-katapult_... -f klipper.bin`. The canbus_uuid did not change.
- Result: `Loaded MCU 'mcu' 148 commands (v0.13.0-809-gc63b29510)`, was `v0.13.0-706`; `Printer is ready`.

**Pitfall, caught before flashing:** in Klipper's Kconfig the CAN pins for a USB-to-CAN bridge are set by the
`STM32_CMENU_CANBUS_*` choice ("CAN bus interface"). Writing `CONFIG_STM32_CANBUS_PD0_PD1=y` directly is ignored and
the build silently falls back to **PB8/PB9**, which on this board would bring the bridge up on the wrong pins. Always
check the resolved `.config` (`CONFIG_STM32_CANBUS_PD0_PD1=y`) before flashing.

## Not yet rebuilt

- LDO Nitehawk 36 (RP2040, USB): still `v0.13.0-745`, one commit range behind the host. Not flashed.
