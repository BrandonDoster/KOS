# BTT CB1 (Allwinner H616). Sourced by in-container.sh and customize.sh.
BOARD=cb1
# Armbian repo supplies kernel, dtb and U-Boot; everything else is Debian.
BOARD_APT_LINE='deb [signed-by=/usr/share/keyrings/armbian.asc] https://apt.armbian.com trixie main trixie-utils'
BOARD_APT_KEY_URL='https://apt.armbian.com/armbian.key'
BOARD_PACKAGES='linux-image-current-sunxi64 linux-dtb-current-sunxi64 linux-u-boot-bigtreetech-cb1-current u-boot-tools'
# Partition layout, in order: label:fs:size (size in MiB, 0 = fill card). First partition starts at 16 MiB
# so U-Boot at 8 KiB..~1 MiB never collides. Root is fixed-size so it can be re-flashed without touching data.
BOARD_PARTS='KOS:vfat:64 KOS-ROOT:ext4:3072 KOS-DATA:ext4:0'
BOARD_FIRST_PART_MIB=16
BOARD_UBOOT_SEEK_KIB=8   # Armbian sunxi64_common.inc: dd bs=1024 seek=8
