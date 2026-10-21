#!/bin/sh
# Everything that can be checked without hardware or Docker.
set -eu
cd "$(dirname "$0")/.."
for f in overlay/usr/lib/kos/kos-config overlay/usr/lib/kos/kos-tune overlay/usr/lib/kos/kos-trash-purge overlay/usr/lib/kos/kos-cm5-carrier build/*.sh build/boards/*/*.sh tests/*.sh; do
    bash -n "$f"
done
python3 overlay/usr/lib/kos/kos-mcu-discover --test
python3 overlay/usr/lib/kos/kos-archive --test
python3 tests/print_stats.py --test
python3 build/mkimage.py --test
bash tests/test_lib_sh.sh
if sed --version >/dev/null 2>&1; then bash tests/test_cm5_carrier.sh; else echo "skip test_cm5_carrier.sh (needs GNU sed)"; fi
echo "all ok"
