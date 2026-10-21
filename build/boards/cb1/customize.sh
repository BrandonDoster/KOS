# Runs chrooted, after the common customize. Kernel/U-Boot/boot script for CB1.
set -eu
install -m 0755 /tmp/board/kernel-postinst.sh /etc/kernel/postinst.d/zz-kos
install -D -m 0755 /tmp/board/initramfs-post-update.sh /etc/initramfs/post-update.d/99-uboot
install -m 0644 /tmp/board/modprobe-display.conf /etc/modprobe.d/kos-display.conf
install -m 0644 /tmp/board/armbianEnv.txt /boot/armbianEnv.txt
install -m 0644 /tmp/board/boot.cmd /boot/boot.cmd

# apt >= 2.4 accepts ASCII-armored keys in signed-by, so no gpg in the image
curl -fsSL "$BOARD_APT_KEY_URL" -o /usr/share/keyrings/armbian.asc
echo "$BOARD_APT_LINE" > /etc/apt/sources.list.d/armbian.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $BOARD_PACKAGES

ver=$(ls /boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
/etc/kernel/postinst.d/zz-kos "$ver"
[ -f "/boot/uInitrd-$ver" ] || update-initramfs -c -k "$ver"
mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr >/dev/null
test -f /boot/Image && test -f /boot/uInitrd && test -f /boot/dtb/allwinner/sun50i-h616-bigtreetech-cb1-sd.dtb
# boot files are on partition 2: a load without ":${distro_bootpart}" would read the KOS FAT (partition 1)
grep -qF '${devtype} ${devnum} ' /boot/boot.cmd && exit 1
# U-Boot binary for mkimage.py (dd'd at BOARD_UBOOT_SEEK_KIB); leave it where the deb put it, just record the path.
ls /usr/lib/linux-u-boot-*/u-boot-sunxi-with-spl.bin > /tmp/uboot-path
apt-get clean
