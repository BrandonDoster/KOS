#!/bin/sh
# Read-only inspection of a built image without mounting it. Usage: tests/inspect_image.sh out/kos-<board>-*.img
set -eu
IMG=${1:?image}
cd "$(dirname "$0")/.."
python3 - "$IMG" <<'EOF'
import sys, struct
d = open(sys.argv[1], "rb")
head = d.read(512)
print("MBR sig ok:", head[510:512] == b"\x55\xaa")
for i in range(4):
    flag, _, typ, _, start, size = struct.unpack("<B3sB3sII", head[446 + i*16:446 + (i+1)*16])
    if typ: print(f"  p{i+1}: type=0x{typ:02x} boot={'*' if flag else '-'} start={start*512//2**20} MiB size={size*512//2**20} MiB")
d.seek(8192); print("U-Boot eGON header at 8 KiB:", d.read(12)[4:12] == b"eGON.BT0")
EOF
docker run --rm -i --platform linux/amd64 -v "$PWD/$(dirname "$IMG"):/o:ro" -e IMG="/o/$(basename "$IMG")" debian:trixie bash -eu <<'EOF'
apt-get update -qq >/dev/null; apt-get install -y -qq e2fsprogs mtools python3 >/dev/null 2>&1
# partition table -> offsets
eval "$(python3 - "$IMG" <<'PY'
import sys, struct
h = open(sys.argv[1], "rb").read(512)
fats, exts = [], []
for i in range(4):
    _, _, typ, _, start, size = struct.unpack("<B3sB3sII", h[446+i*16:446+(i+1)*16])
    (fats if typ in (0x0b, 0x0c, 0x0e) else exts if typ == 0x83 else []).append((start*512, size*512))
print("FATS='%s'" % " ".join(f"{s}:{z}" for s, z in fats))
print("ROOT_OFF=%d ROOT_LEN=%d" % exts[0])
PY
)"
for f in $FATS; do echo "--- FAT partition at $((${f%%:*} / 1048576)) MiB"; mdir -i "$IMG@@${f%%:*}" :: | grep -v -E '^ *Volume|^Directory|^$' | awk '{print $NF}' | tr '\n' ' '; echo; done
dd if="$IMG" of=/tmp/root.fs bs=1M skip=$((ROOT_OFF / 1048576)) count=$((ROOT_LEN / 1048576)) status=none
r() { debugfs -R "$1" /tmp/root.fs 2>/dev/null; }
echo "--- /boot"; r "ls -l /boot" | awk '{print $NF}' | tr '\n' ' '; echo
[ -n "$(r 'cat /boot/armbianEnv.txt')" ] && { echo "--- armbianEnv.txt"; r "cat /boot/armbianEnv.txt" | grep -v '^#'; }
echo "--- fstab"; r "cat /etc/fstab" | grep -v '^#'
echo "--- enabled units"; r "ls /etc/systemd/system/multi-user.target.wants" | tr -s ' \n' '\n' | grep -E '\.(service|target)$' | tr '\n' ' '; echo
echo "--- masked"; for u in apt-daily.timer man-db.timer systemd-networkd-wait-online.service; do printf '%s: ' "$u"; r "stat /etc/systemd/system/$u" | grep -o '"/dev/null"' || echo not-masked; done
echo "--- kos tools"; r "ls -l /usr/lib/kos" | awk 'NF>1{print $2, $NF}' | grep -v '^40'
echo "--- home"; r "ls /home/klipper" | tr -s ' \n' '\n' | grep -E '^[a-z]' | tr '\n' ' '; echo
echo "--- chelper built?"; r "ls /home/klipper/klipper/klippy/chelper" | grep -o 'c_helper[^ ]*' || echo "no c_helper.so"
echo "--- passwd/shadow"; r "cat /etc/passwd" | grep -E '^(root|klipper):'; r "cat /etc/shadow" | grep -E '^(root|klipper):' | cut -d: -f1,2
echo "--- groups"; r "cat /etc/group" | grep -E '^(klipper|moonraker-admin|dialout):'
echo "--- machine-id bytes"; r "cat /etc/machine-id" | wc -c
echo "--- apt sources"; for f in $(r "ls /etc/apt/sources.list.d" | tr -s ' \n' '\n' | grep '\.list$'); do r "cat /etc/apt/sources.list.d/$f"; done
echo "--- modules"; r "ls /lib/modules" | tr -s ' \n' '\n' | grep -E '^[0-9]' | tr '\n' ' '; echo
echo "--- kernel config bits"; for c in $(r "ls /boot" | tr -s ' \n' '\n' | grep '^config-'); do echo "$c:"; r "cat /boot/$c" | grep -E '^CONFIG_(EXT4_FS|CAN_GS_USB|CAN_MCP251XFD|RTL8189FS|PREEMPT|NO_HZ_FULL|CMA_SIZE_MBYTES|DRM_SUN4I|DRM_VC4|ARM64_16K_PAGES)=' | tr '\n' ' '; echo; done
EOF
