#!/bin/bash
# Self-check for overlay/usr/lib/kos/kos-cm5-carrier against sample boot files. Needs GNU sed (Linux).
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
run() {   # $1 = model string, rest = kos.conf lines
    local model=$1; shift
    printf '%s\0' "$model" > "$T/model"
    printf '%s\n' "$@" > "$T/kos.conf"
    KOS_FW=$T KOS_DT_MODEL=$T/model KOS_CONF=$T/kos.conf sh overlay/usr/lib/kos/kos-cm5-carrier >/dev/null
}
fresh() {
    cp build/boards/cm5/config.txt "$T/config.txt"
    printf 'console=serial0,115200 root=LABEL=KOS-ROOT rootwait\n' > "$T/cmdline.txt"
}

fresh; before=$(cat "$T/config.txt" "$T/cmdline.txt")
run "Raspberry Pi Compute Module 5 Lite Rev 1.0"                 # defaults: the shipped files are already right
[ "$before" = "$(cat "$T/config.txt" "$T/cmdline.txt")" ]
grep -A1 -x '\[board-type=0x18\]' "$T/config.txt" | grep -qx 'device_tree=bcm2712-rpi-cm5-cm4io.dtb'
grep -A1 -x '\[board-type=0x1a\]' "$T/config.txt" | grep -qx 'device_tree=bcm2712-rpi-cm5l-cm4io.dtb'
grep -qx 'dtparam=uart0_console' "$T/config.txt"
! grep -q debug_quirks2 "$T/cmdline.txt" || exit 1

run "Raspberry Pi Compute Module 5 Rev 1.0" carrier_dt=off       # both trees commented, back on restores them
[ "$(grep -c '^#device_tree=bcm2712-rpi-cm5l*-cm4io.dtb$' "$T/config.txt")" -eq 2 ]
run "Raspberry Pi Compute Module 5 Rev 1.0"
[ "$(grep -c '^device_tree=bcm2712-rpi-cm5l*-cm4io.dtb$' "$T/config.txt")" -eq 2 ]

run "Raspberry Pi Compute Module 5 Rev 1.0" sd_3v3_only=on
run "Raspberry Pi Compute Module 5 Rev 1.0" sd_3v3_only=on      # idempotent: added once
[ "$(grep -o 'sdhci.debug_quirks2=0x4' "$T/cmdline.txt" | wc -l)" -eq 1 ]
[ "$(wc -l < "$T/cmdline.txt")" -eq 1 ]                           # cmdline.txt stays one line

run "Raspberry Pi Compute Module 5 Rev 1.0" carrier_dt=off serial_console=off sd_3v3_only=off
[ "$(grep -c '^#device_tree=' "$T/config.txt")" -eq 2 ]
grep -qx '#dtparam=uart0_console' "$T/config.txt"
! grep -q debug_quirks2 "$T/cmdline.txt" || exit 1

fresh; before=$(cat "$T/config.txt" "$T/cmdline.txt")
run "Raspberry Pi Compute Module 4 Rev 1.1" sd_3v3_only=on       # not a CM5: untouched
[ "$before" = "$(cat "$T/config.txt" "$T/cmdline.txt")" ]
echo ok
