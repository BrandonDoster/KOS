# Raspberry Pi CM5 (BCM2712), with the CM4 (BCM2711) kernel on the same card as an untested bonus (PLAN §14).
BOARD=cm5
# Raspberry Pi's trixie repo: firmware, both kernels, Wi-Fi firmware. Everything else is Debian.
BOARD_APT_LINE='deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian trixie main'
# Bootstrap key: the .deb, not raspberrypi.gpg.key (see customize.sh). Bump when the Packages index shows a newer one.
BOARD_KEYRING_DEB_URL='http://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-archive-keyring/raspberrypi-archive-keyring_2025.1+rpt1_all.deb'
BOARD_PACKAGES='raspi-firmware linux-image-rpi-2712 linux-image-rpi-v8 firmware-brcm80211'
# Firmware FAT must be the first partition (the EEPROM bootloader only reads that one). Four primaries = MBR limit.
BOARD_PARTS='KOS-BOOT:vfat:256 KOS:vfat:64 KOS-ROOT:ext4:3072 KOS-DATA:ext4:0'
BOARD_FIRST_PART_MIB=4
# Contents of this rootfs dir are moved onto the first FAT partition at image assembly.
BOARD_BOOTFAT_DIR=/boot/firmware
BOARD_UBOOT_SEEK_KIB=8   # unused: no U-Boot on Pi
