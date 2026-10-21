#!/bin/bash
# Bring a stock install (Raspberry Pi OS Lite / Armbian minimal + KIAUH) to the benchmark baseline in docs/benchmarks.md:
# the same Klipper and Moonraker commits as the KOS image under test, the printer's own config, and CAN plus the
# Klipper host MCU set up the way upstream's docs describe (docs/CANBUS.md, docs/RPi_microcontroller.md).
# Run as the user KIAUH installed under, after KIAUH has installed Klipper, Moonraker, Mainsail (+ mainsail-config):
#   bash stock_prep.sh <config dir>        e.g. bash stock_prep.sh ~/sindri/printer_data/config
# Env: KLIPPER_REF / MOONRAKER_REF (commits the KOS run used), CAN_BITRATE=1M.
set -eu
CFG=${1:?usage: stock_prep.sh <config dir>}
KLIPPER_REF=${KLIPPER_REF:-c63b2951}
MOONRAKER_REF=${MOONRAKER_REF:-9e676eb}
CAN_BITRATE=${CAN_BITRATE:-1M}
PD=$HOME/printer_data
for d in klipper moonraker klippy-env moonraker-env; do
    [ -d "$HOME/$d" ] || { echo "~/$d missing: install Klipper, Moonraker and Mainsail with KIAUH first" >&2; exit 1; }
done

echo "== pin Klipper $KLIPPER_REF, Moonraker $MOONRAKER_REF"
sudo systemctl stop klipper moonraker
for r in "klipper $KLIPPER_REF" "moonraker $MOONRAKER_REF"; do
    set -- $r; git -C "$HOME/$1" fetch -q origin && git -C "$HOME/$1" checkout -q "$2"
done
~/klippy-env/bin/pip install -q -r ~/klipper/scripts/klippy-requirements.txt
~/moonraker-env/bin/pip install -q -r ~/moonraker/scripts/moonraker-requirements.txt

echo "== Klipper host MCU (docs/RPi_microcontroller.md)"
printf 'CONFIG_MACH_LINUX=y\n' > /tmp/linux-mcu.config
make -C ~/klipper -s KCONFIG_CONFIG=/tmp/linux-mcu.config OUT=/tmp/linux-mcu/ olddefconfig >/dev/null
make -C ~/klipper -s -j"$(nproc)" KCONFIG_CONFIG=/tmp/linux-mcu.config OUT=/tmp/linux-mcu/
sudo install -m 0755 /tmp/linux-mcu/klipper.elf /usr/local/bin/klipper_mcu
sudo install -m 0644 ~/klipper/scripts/klipper-mcu.service /etc/systemd/system/klipper-mcu.service
sudo usermod -aG tty "$USER"
sudo systemctl daemon-reload && sudo systemctl enable --now klipper-mcu

# BTT's CB1 image already brings can0 up with ifupdown; a second config in networkd would fight it.
if [ -e /etc/network/interfaces.d/can0 ]; then
    echo "== CAN: left to the image's /etc/network/interfaces.d/can0"
else
    echo "== CAN via systemd-networkd at $CAN_BITRATE (docs/CANBUS.md)"
    printf '[Match]\nName=can*\n\n[CAN]\nBitRate=%s\n' "$CAN_BITRATE" | sudo tee /etc/systemd/network/25-can.network >/dev/null
    printf '[Match]\nType=can\n\n[Link]\nTransmitQueueLength=128\n' | sudo tee /etc/systemd/network/99-can.link >/dev/null
    sudo systemctl enable --now systemd-networkd
    sudo systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
fi

echo "== printer config from $CFG"
cp -r "$CFG"/. "$PD/config/"
find "$PD/config" -name '._*' -type f -delete
find "$PD/config" -type f \( -name '*.cfg' -o -name '*.conf' \) -exec perl -pi -e "s#/home/(?!$USER/)[\\w.-]+/#$HOME/#g" {} +
[ -e "$PD/config/mainsail.cfg" ] || ln -sfn "$HOME/mainsail-config/mainsail.cfg" "$PD/config/mainsail.cfg"

sudo systemctl start klipper moonraker
for _ in $(seq 60); do
    s=$(curl -s 127.0.0.1:7125/printer/info | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null || true)
    [ "$s" = ready ] && break; sleep 2
done
echo "== Klippy: ${s:-unreachable}. Klipper $(git -C ~/klipper describe --always --tags), Moonraker $(git -C ~/moonraker describe --always --tags)"
echo "Reboot (cold: pull power) before benchmarking, so the run starts from a fresh boot."
