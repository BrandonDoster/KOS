#!/bin/bash
# Runs inside an arm64 debian:trixie container (privileged, for mmdebstrap's chroot mounts). $1 = board.
# Produces out/kos-<board>-<date>.img. Writes only out/ and /tmp/work: build.sh mounts the repo read-only.
set -euxo pipefail
BOARD=${1:?board}
cd "$(dirname "$0")/.."
. build/boards/$BOARD/board.sh
OUT=out; WORK=/tmp/work; mkdir -p $OUT $WORK

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mmdebstrap ca-certificates curl gnupg mtools dosfstools e2fsprogs u-boot-tools python3 rsync

pkgs=$(grep -v '^#' build/packages.txt | tr '\n' ' ' | tr -s ' ' | sed 's/ /,/g;s/,$//;s/^,//')

# rootfs. Hooks: overlay in, board files and pins in, customize, build files out. The sources become the image's
# /etc/apt/sources.list, so devices get Debian security updates. mmdebstrap copies the host's resolv.conf in for
# network access and leaves it; the last hook drops it (NetworkManager writes the device's own).
mmdebstrap --arch=arm64 --variant=minbase --mode=root \
    --include="$pkgs" \
    --aptopt='Acquire::Languages "none"' \
    --dpkgopt='path-exclude=/usr/share/man/*' --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-exclude=/usr/share/locale/*' --dpkgopt='path-include=/usr/share/locale/locale.alias' \
    --customize-hook='sync-in overlay /' \
    --customize-hook='mkdir -p "$1/tmp/board"' \
    --customize-hook="sync-in build/boards/$BOARD /tmp/board" \
    --customize-hook='copy-in build/customize.sh build/pins.env /tmp' \
    --customize-hook="chroot \"\$1\" bash /tmp/customize.sh $BOARD" \
    --customize-hook='download /tmp/uboot-path /tmp/work/uboot-path' \
    --customize-hook='rm -rf "$1/tmp/board" "$1/tmp/customize.sh" "$1/tmp/pins.env" "$1/etc/resolv.conf"' \
    trixie $WORK/rootfs \
    'deb https://deb.debian.org/debian trixie main' \
    'deb https://deb.debian.org/debian trixie-updates main' \
    'deb https://security.debian.org/debian-security trixie-security main'

uboot=$(cat $WORK/uboot-path)
[ -n "$uboot" ] && uboot_args="--uboot $WORK/rootfs$uboot --uboot-seek-kib $BOARD_UBOOT_SEEK_KIB" || uboot_args=""
# data partition seed: empty printer_data owned by klipper
mkdir -p $WORK/data && chown 1000:1000 $WORK/data
# config partition seed
mkdir -p $WORK/config && cp build/config-partition/* $WORK/config/
# boards that boot from files on a FAT partition (Pi): move that directory's contents out of the rootfs
bootfat_args=""
if [ -n "${BOARD_BOOTFAT_DIR:-}" ]; then
    mkdir -p $WORK/bootfat && mv $WORK/rootfs$BOARD_BOOTFAT_DIR/* $WORK/bootfat/ && bootfat_args="--src KOS-BOOT=$WORK/bootfat"
fi

img=$OUT/kos-$BOARD-$(date +%Y%m%d).img
python3 build/mkimage.py "$img" --parts "$BOARD_PARTS" --first-mib "$BOARD_FIRST_PART_MIB" \
    --src KOS-ROOT=$WORK/rootfs --src KOS-DATA=$WORK/data --src KOS=$WORK/config $bootfat_args \
    $uboot_args --bootable KOS-ROOT
du -sh $WORK/rootfs | tee $OUT/kos-$BOARD.size
ls -la "$img"
