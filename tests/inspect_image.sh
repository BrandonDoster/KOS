#!/bin/sh
# Read-only inspection of a built image without mounting it. Usage: tests/inspect_image.sh out/kos-<board>-*.img
# Prints what is in the image, and fails if anything outside the klipper home (and a few package-owned paths) is not
# owned by root, or if a path sshd or sudo checks is not root-owned or is writable by others. CI runs it before
# publishing (.github/workflows/build.yml).
set -eu
IMG=$(cd "$(dirname "${1:?image}")" && pwd)/$(basename "$1")
cd "$(dirname "$0")/.."
sh build/bump-pins.sh --check build/pins.env && . build/pins.env   # DEBIAN_IMAGE
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
docker run --rm -i -v "$(dirname "$IMG"):/o:ro" -e IMG="/o/$(basename "$IMG")" "$DEBIAN_IMAGE" bash -eu <<'EOF'
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
# A kernel with CONFIG_RT_GROUP_SCHED needs rt_group_sched=0, or klipper_mcu -r loses realtime once a login delegates
# the cpu controller (Sindri, 2026-10-21: "mcu 'host': Unable to connect").
for c in $(r "ls /boot" | tr -s ' \n' '\n' | grep '^config-' || true); do
    kcfg=$(r "cat /boot/$c")
    case "$kcfg" in *"
CONFIG_RT_GROUP_SCHED=y"*) ;; *) continue ;; esac
    args="$(r 'cat /boot/armbianEnv.txt' | grep '^extraargs=' || true) $(for f in $FATS; do mtype -i "$IMG@@${f%%:*}" ::cmdline.txt 2>/dev/null || true; done)"
    case " $args " in *" rt_group_sched=0 "*) echo "--- $c: RT_GROUP_SCHED=y, rt_group_sched=0 set: ok" ;;
        *) echo "FAIL: $c has CONFIG_RT_GROUP_SCHED=y but the kernel args lack rt_group_sched=0"; exit 1 ;; esac
done
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
# Owners and modes, from a copy of the root filesystem (debugfs rdump keeps owners and permission bits).
mkdir /tmp/rootfs && debugfs -R "rdump / /tmp/rootfs" /tmp/root.fs >/dev/null 2>&1 && cd /tmp/rootfs
bad=0
fail() { echo "FAIL: $1"; printf '%s\n' "$2" | head -n 40 | sed 's/^/    /'; bad=1; }
# Only klipper's home and what packages hand to their own system users may belong to someone other than root.
f=$(find . -xdev \( -path ./home/klipper -o -path ./var/log -o -path ./var/lib/apt/lists/partial \
    -o -path ./var/cache/apt/archives/partial -o -path ./var/lib/systemd/network \) -prune -o ! -uid 0 -printf '%U:%G %p\n')
[ -z "$f" ] || fail "not owned by root" "$f"
f=$(find ./home/klipper -xdev ! -uid 1000 ! -uid 0 -printf '%U:%G %p\n')
[ -z "$f" ] || fail "in /home/klipper but owned by neither klipper nor root" "$f"
f=$(find . -xdev \( -path ./home/klipper -prune \) -o -gid +999 -printf '%U:%G %p\n')
[ -z "$f" ] || fail "group is a user's group (gid 1000 or more)" "$f"
# sshd's StrictModes (AuthorizedKeysFile /etc/kos/authorized_keys/%u and every directory above it), sshd's and sudo's
# own files, and what root runs: root:root and not writable by group or others. sudoers files exactly 0440.
f=$(for p in . etc etc/kos etc/kos/authorized_keys etc/ssh etc/ssh/sshd_config etc/ssh/sshd_config.d \
        etc/ssh/sshd_config.d/* etc/sudoers etc/sudoers.d etc/sudoers.d/* etc/systemd/system \
        etc/systemd/system/*.service usr usr/lib usr/lib/kos usr/lib/kos/*; do
    [ -e "$p" ] && [ ! -L "$p" ] && find "$p" -maxdepth 0 \( ! -uid 0 -o ! -gid 0 -o -perm /022 \) -printf '%U:%G %m %p\n'
done)
[ -z "$f" ] || fail "not root:root, or writable by group or others" "$f"
f=$(find etc/sudoers etc/sudoers.d -type f ! -perm 0440 -printf '%m %p\n')
[ -z "$f" ] || fail "sudoers file not mode 0440" "$f"
[ "$bad" = 0 ] && echo "--- owners and modes: ok"
exit "$bad"
EOF
