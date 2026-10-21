#!/bin/sh
# Wait for any running CB1 build to finish, then build CM5. Sequential because arm64 emulation is CPU-bound.
cd "$(dirname "$0")/.."
while pgrep -f 'in-container.sh cb1' >/dev/null; do sleep 30; done
build/build.sh cm5 > out/build-cm5-run1.log 2>&1
echo "EXIT $?" >> out/build-cm5-run1.log
