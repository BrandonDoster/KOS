#!/bin/sh
# End-to-end check of build/mkimage.py with real mkfs tools, in a throwaway Linux container. Needs Docker.
set -eu
cd "$(dirname "$0")/.."
M=$(mktemp -d)
mkdir -p "$M/root/etc" "$M/data" "$M/cfg"
echo hello > "$M/root/etc/x"; echo c > "$M/cfg/kos.conf"; head -c 700000 /dev/urandom > "$M/uboot.bin"
docker run --rm -i --platform linux/amd64 -v "$PWD/build:/b:ro" -v "$M:/m" debian:trixie bash -eu <<'EOF'
apt-get update -qq >/dev/null; apt-get install -y -qq mtools dosfstools e2fsprogs python3 fdisk >/dev/null 2>&1
python3 /b/mkimage.py /m/test.img --parts "KOS:vfat:64 KOS-ROOT:ext4:200 KOS-DATA:ext4:0" --fill-mib 64 \
    --src KOS-ROOT=/m/root --src KOS-DATA=/m/data --src KOS=/m/cfg --uboot /m/uboot.bin --bootable KOS-ROOT
sfdisk -l /m/test.img
cmp -n 700000 -i 8192:0 /m/test.img /m/uboot.bin && echo "u-boot at 8 KiB: ok"
mdir -i /m/test.img@@16777216 :: | grep -q kos.conf && echo "config partition: ok"
dd if=/m/test.img bs=1M skip=80 count=200 2>/dev/null > /tmp/root.fs
[ "$(debugfs -R 'cat /etc/x' /tmp/root.fs 2>/dev/null)" = hello ] && echo "root partition: ok"
dumpe2fs -h /tmp/root.fs 2>/dev/null | grep -E "volume name"
EOF
echo "mkimage e2e ok"
