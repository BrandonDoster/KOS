#!/bin/sh
# Host wrapper: build/build.sh [cb1]. Needs Docker with arm64 emulation (Docker Desktop has it).
# Output: out/kos-<board>-<date>.img. Flash with: dd if=out/*.img of=/dev/rdiskN bs=4m
set -eu
BOARD=${1:-cb1}
cd "$(dirname "$0")/.."
exec docker run --rm --privileged --platform linux/arm64 \
    -v "$PWD:/w" -w /w -e BOARD="$BOARD" debian:trixie bash /w/build/in-container.sh "$BOARD"
