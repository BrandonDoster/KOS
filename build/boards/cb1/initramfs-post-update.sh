#!/bin/sh -e
# /etc/initramfs/post-update.d/99-uboot: $1 = kernel version, $2 = initrd path. Armbian's 99-uboot minus /etc/armbian-release.
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d "$2" "/boot/uInitrd-$1" >/dev/null
ln -sf "uInitrd-$1" /boot/uInitrd
