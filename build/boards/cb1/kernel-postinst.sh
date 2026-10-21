#!/bin/sh
# /etc/kernel/postinst.d/zz-kos: $1 = kernel version. Armbian's boot.scr loads /boot/Image and /boot/dtb/.
set -e
ver="$1"
[ -n "$ver" ] || exit 0
ln -sf "vmlinuz-$ver" /boot/Image
[ -d "/boot/dtb-$ver" ] && ln -sfn "dtb-$ver" /boot/dtb
exit 0
