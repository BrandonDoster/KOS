# Runs chrooted, after the common customize. Firmware + kernels for CM5 (and CM4).
set -eu
install -m 0644 /tmp/board/modprobe-display.conf /etc/modprobe.d/kos-display.conf

# Trixie's apt verifies with sqv, which rejects the key published at raspberrypi.gpg.key (SHA1 self-signature).
# The keyring *package* carries a key that passes, so bootstrap from the .deb directly.
curl -fsSL "$BOARD_KEYRING_DEB_URL" -o /tmp/keyring.deb && dpkg -i /tmp/keyring.deb
echo "$BOARD_APT_LINE" > /etc/apt/sources.list.d/raspi.list
apt-get update
# raspi-firmware first: its kernel/initramfs hooks must exist before the kernel packages run them.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends raspi-firmware
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $BOARD_PACKAGES

install -m 0644 /tmp/board/config.txt /boot/firmware/config.txt
install -m 0644 /tmp/board/cmdline.txt /boot/firmware/cmdline.txt
echo 'LABEL=KOS-BOOT  /boot/firmware             vfat   defaults,noatime                                 0 2' >> /etc/fstab
for f in kernel_2712.img initramfs_2712 kernel8.img initramfs8 bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5l-cm4io.dtb bcm2712-rpi-cm5-cm4io.dtb bcm2711-rpi-cm4.dtb start4.elf overlays/README; do
    test -e "/boot/firmware/$f"
done
echo -n > /tmp/uboot-path   # no U-Boot; in-container.sh downloads this file unconditionally
apt-get clean
