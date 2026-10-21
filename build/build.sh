#!/bin/sh
# Host wrapper: build/build.sh [cb1]. Needs Docker with arm64 emulation (Docker Desktop has it).
# Output: out/kos-<board>-<date>.img. Flash with: dd if=out/*.img of=/dev/rdiskN bs=4m
set -eu
BOARD=${1:-cb1}
cd "$(dirname "$0")/.."
. build/pins.env   # DEBIAN_IMAGE: the build container, pinned by digest
mkdir -p out
# --privileged: mmdebstrap --mode=root mounts /proc, /sys and /dev into the chroot. The build also runs upstream code
# (Klipper's make, pip, maintainer scripts) as root, so on a Linux host it is root on that host. The repo is mounted
# read-only; only out/ is writable.
exec docker run --rm --privileged --platform linux/arm64 \
    -v "$PWD:/w:ro" -v "$PWD/out:/w/out" -w /w -e BOARD="$BOARD" "$DEBIAN_IMAGE" bash /w/build/in-container.sh "$BOARD"
