#!/bin/sh
# Everything that can be checked without hardware or Docker.
set -eu
cd "$(dirname "$0")/.."
for f in overlay/usr/lib/kos/kos-config overlay/usr/lib/kos/kos-ssh-key overlay/usr/lib/kos/kos-tune overlay/usr/lib/kos/kos-trash-purge overlay/usr/lib/kos/kos-cm5-carrier build/*.sh build/boards/*/*.sh tests/*.sh tests/device/*.sh bench/scripts/*.sh; do
    bash -n "$f"
done
python3 overlay/usr/lib/kos/kos-mcu-discover --test
python3 overlay/usr/lib/kos/kos-archive --test
python3 overlay/usr/lib/kos/kos-printer-idle --test
. build/boards/cb1/board.sh && python3 build/boards/cb1/pgp-fpr.py build/boards/cb1/armbian.asc "$BOARD_APT_KEY_FPR"
python3 bench/scripts/print_stats.py --test
python3 build/mkimage.py --test
bash tests/test_lib_sh.sh
bash tests/test_kos_ssh_key.sh
bash tests/test_trash_purge.sh
if sed --version >/dev/null 2>&1; then bash tests/test_cm5_carrier.sh; else echo "skip test_cm5_carrier.sh (needs GNU sed)"; fi
echo "all ok"
