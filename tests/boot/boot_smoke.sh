#!/bin/bash
# Boots a built image's root filesystem with systemd-nspawn and checks the first-boot and security setup under real
# systemd. Usage: sudo tests/boot/boot_smoke.sh out/kos-<board>-YYYYMMDD.img      (exit 0 = every check passed)
#
# Needs: Linux, root, systemd-nspawn (package systemd-container), losetup, overlayfs, python3, ssh-keygen, ssh, curl,
# and a host of the image's architecture (arm64; GitHub's ubuntu-24.04-arm runner). Docker Desktop's linuxkit kernel
# does not work: systemd's credential setup (243/CREDENTIALS) and nspawn's clone() fail there with EINVAL.
# The image file is only read: KOS-ROOT is mounted read-only under a tmpfs overlay; KOS and KOS-DATA are copied.
# The image's own systemd mounts /config and printer_data from its fstab (by-label links stand in for udev).
# The container gets its own network namespace with a veth pair; this host is the SSH and HTTP client.
#
# Not checked here (needs hardware): kernel command line (ipv6.disable=1, isolcpus), U-Boot/firmware boot, growpart of
# the real data partition, udev, CAN (can0, 99-can.network), kos-tune IRQ affinity, kos-mcu-discover with real boards,
# Klipper talking to an MCU, zram swap, Wi-Fi/NetworkManager DHCP, avahi/mDNS on a LAN, display, CM5 carrier edits,
# a timer firing on its own after 1 day (only its next elapse time is checked). unattended-upgrade is only seen to
# start: the container has no route out, so it cannot download anything.
set -u
IMG=$(readlink -f "${1:?usage: boot_smoke.sh IMAGE}")
[ "$(id -u)" = 0 ] || exec sudo "$0" "$IMG"
for c in systemd-nspawn machinectl losetup blkid python3 ssh-keygen ssh curl ip nsenter; do
    command -v "$c" >/dev/null || { echo "boot_smoke: needs $c" >&2; exit 2; }
done
W=$(mktemp -d /tmp/kos-boot.XXXXXX); chmod 755 "$W"
M=kosboot$$ NS=kosb$$ IP=10.209.0.2 HOSTIP=10.209.0.1
LOOPS=() NSPAWN='' ROOT=''
cleanup() {
    [ -n "$NSPAWN" ] && { kill -TERM "$NSPAWN" 2>/dev/null; for _ in $(seq 30); do kill -0 "$NSPAWN" 2>/dev/null || break; sleep 1; done; kill -KILL "$NSPAWN" 2>/dev/null; }
    umount -R "$W/root" "$W/lower" "$W/ovl" 2>/dev/null
    for d in "${LOOPS[@]}"; do losetup -d "$d" 2>/dev/null; done
    ip netns del "$NS" 2>/dev/null
    rm -rf "$W"
}
trap cleanup EXIT

# --- partitions (MBR) -> loop devices ---
mkdir -p "$W/lower" "$W/ovl" "$W/root" "$W/by-label" "$W/cfg" "$W/keys"
while read -r off size; do
    label=$(blkid -p -o value -s LABEL -O "$off" -S "$size" "$IMG" 2>/dev/null)
    case $label in
    KOS-ROOT) d=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$IMG"); ROOT=$d ;;
    KOS|KOS-DATA)
        dd if="$IMG" of="$W/$label.fs" bs=1M iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none
        d=$(losetup -f --show "$W/$label.fs") ;;
    *) continue ;;
    esac
    LOOPS+=("$d"); ln -s "$d" "$W/by-label/$label"
done < <(python3 -I - "$IMG" <<'EOF'
import sys, struct
h = open(sys.argv[1], "rb").read(512)
for i in range(4):
    _, _, typ, _, start, size = struct.unpack("<B3sB3sII", h[446 + i*16:462 + i*16])
    if typ: print(start * 512, size * 512)
EOF
)
for l in KOS-ROOT KOS KOS-DATA; do [ -e "$W/by-label/$l" ] || { echo "boot_smoke: no $l partition in $IMG" >&2; exit 2; }; done

# --- test /config: hostname, keys in both forms, allowed_hosts, bad values; printer_data with a foreign home ---
for k in one two three four; do ssh-keygen -q -t ed25519 -N '' -C "t2-$k" -f "$W/keys/$k"; done
pub() { cat "$W/keys/$1.pub"; }
mount -t vfat "$W/by-label/KOS" "$W/cfg"
cat > "$W/cfg/kos.conf" <<EOF
hostname=kos-boot
allowed_hosts=voron.lan, printer.home.arpa bad_host!
ssh_key=$(pub one)
ssh_key=$(pub two) \\
        $(pub three)
ssh_key=from="10.0.0.1" $(pub four)
timezone=Mars/Olympus
can_bitrate=fast
EOF
mkdir -p "$W/cfg/printer_data/config"
printf '[include /home/pi/printer_data/config/macros.cfg]\n[mcu]\nserial: /dev/serial/by-id/usb-Klipper_test-if00\n[printer]\nkinematics: none\nmax_velocity: 1\nmax_accel: 1\n' \
    > "$W/cfg/printer_data/config/printer.cfg"
mount -o ro "$ROOT" "$W/lower"
sed 's/^host: 127.0.0.1/host: 0.0.0.0/' "$W/lower/usr/lib/kos/moonraker.conf" > "$W/cfg/printer_data/config/moonraker.conf"
umount "$W/cfg"
mount -t tmpfs -o size=2g tmpfs "$W/ovl" && mkdir "$W/ovl/u" "$W/ovl/w"
mount -t overlay overlay -o "lowerdir=$W/lower,upperdir=$W/ovl/u,workdir=$W/ovl/w" "$W/root"

# --- network: veth pair, container end in its own namespace (static address, no DHCP server) ---
ip netns add "$NS"
ip link add "h$NS" type veth peer name eth0 netns "$NS"
ip addr add "$HOSTIP/24" dev "h$NS"; ip link set "h$NS" up
ip -n "$NS" addr add "$IP/24" dev eth0; ip -n "$NS" link set eth0 up; ip -n "$NS" link set lo up

# --- boot ---
binds=(); for d in "${LOOPS[@]}"; do binds+=("--bind=$d"); done
systemd-nspawn -q -D "$W/root" -b -M "$M" --network-namespace-path="/run/netns/$NS" "${binds[@]}" \
    --bind="$W/by-label:/dev/disk/by-label" --property="DeviceAllow=block-loop rwm" > "$W/console.log" 2>&1 &
NSPAWN=$!
L=
for _ in $(seq 60); do L=$(machinectl show "$M" -p Leader --value 2>/dev/null) && [ -n "$L" ] && break; sleep 1; done
[ -n "$L" ] || { echo "boot_smoke: container did not start"; tail -n 30 "$W/console.log"; exit 1; }
kos() { nsenter -t "$L" -a "$@"; }
state=$(kos timeout 240 systemctl is-system-running --wait 2>/dev/null)

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
info() { echo "INFO $*"; }

# 1. boot state. Units that need hardware may fail in a container; anything else failing is a finding.
HW='^(kos-tune|kos-mcu-discover|zramswap|klipper-mcu|systemd-networkd-wait-online|NetworkManager-wait-online|e2scrub_reap)\.service$|\.(device|automount)$'
failed=$(kos systemctl --failed --no-legend --plain | awk '{print $1}')
info "is-system-running: $state; failed units: $(printf '%s' "$failed" | tr '\n' ' ')"
unexpected=$(printf '%s\n' "$failed" | grep -Ev "$HW" | grep . )
[ -z "$unexpected" ] && ok "no unexpected failed units" || bad "unexpected failed units" "$(printf '%s' "$unexpected" | tr '\n' ' ')"
info "skipped by condition: $(kos systemctl list-units --all --no-legend --plain --state=inactive | awk '{print $1}' | while read -r u; do r=$(kos systemctl show -p ConditionResult --value "$u"); [ "$r" = no ] && printf '%s ' "$u"; done)"
check "kos-config ran" kos systemctl is-active kos-config.service

# 2. /config and first boot
opts=$(kos findmnt -no FSTYPE,OPTIONS /config)
case $opts in vfat*nosuid*nodev*noexec*) ok "/config vfat nosuid,nodev,noexec";; *) bad "/config mount" "$opts";; esac
for o in uid=1000 fmask=0177 dmask=0077 sync; do case $opts in *"$o"*) ok "/config $o";; *) bad "/config $o" "$opts";; esac; done
[ "$(kos stat -c %a /config/kos.conf)" = 600 ] && ok "kos.conf 0600" || bad "kos.conf mode" "$(kos stat -c %a /config/kos.conf)"
check "printer_data mounted" kos mountpoint -q /home/klipper/printer_data
check "hostname kos-boot" test "$(kos cat /etc/hostname)" = kos-boot
check "printer.cfg imported, home rewritten" kos grep -q '/home/klipper/printer_data/config/macros.cfg' /home/klipper/printer_data/config/printer.cfg
check "moonraker.conf host forced to 127.0.0.1" kos grep -qx 'host: 127.0.0.1' /home/klipper/printer_data/config/moonraker.conf
map=$(kos cat /etc/kos/nginx-hosts.map)
for n in kos-boot kos-boot.local voron.lan printer.home.arpa localhost; do
    printf '%s\n' "$map" | grep -qxF "\\$n 1;" && ok "host map has $n" || bad "host map has $n" "$map"
done
printf '%s\n' "$map" | grep -q bad_host && bad "host map leaves out bad_host!" || ok "host map leaves out bad_host!"

# 3. warnings
for w in "timezone 'Mars/Olympus'" "can_bitrate 'fast'" "allowed_hosts: 'bad_host!'" "ssh_key: not a plain public key" "moonraker.conf: \[server\] host was '0.0.0.0'"; do
    kos grep -q "$w" /config/KOS-WARNINGS.txt && ok "KOS-WARNINGS.txt: $w" || bad "KOS-WARNINGS.txt: $w"
    kos grep -q "$w" /run/motd.d/kos-warnings && ok "motd: $w" || bad "motd: $w"
done

# 4. sshd
for t in ed25519 ecdsa rsa; do check "host key $t generated" kos test -s "/etc/ssh/ssh_host_${t}_key"; done
T=$(kos sshd -T 2>&1)
for want in "authorizedkeysfile /etc/kos/authorized_keys/%u" "permitrootlogin no" "addressfamily inet"; do
    printf '%s\n' "$T" | grep -qx "$want" && ok "sshd -T: $want" || bad "sshd -T: $want"
done
check "klipper password locked (no password= given)" test "$(kos getent shadow klipper | cut -d: -f2)" = '*'
S=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes -o LogLevel=ERROR)
login() { [ "$(ssh "${S[@]}" -i "$W/keys/$1" "$2@$IP" id -un 2>/dev/null)" = "$2" ]; }
for k in one two three; do check "ssh klipper with key $k" login "$k" klipper; done
login four klipper && bad "key four (from= option, not installed) refused" || ok "key four (from= option, not installed) refused"
login one root && bad "root login refused" || ok "root login refused"
ssh "${S[@]}" -o PubkeyAuthentication=no -o PasswordAuthentication=yes "klipper@$IP" true 2>/dev/null && bad "password login refused" || ok "password login refused"

# 5. kos-ssh-key round trip (four is in kos.conf with from=, so add it bare)
if kos /usr/lib/kos/kos-ssh-key add "$(pub four)" >/dev/null 2>&1 && login four klipper; then ok "kos-ssh-key add: key works at once"; else bad "kos-ssh-key add"; fi
kos /usr/lib/kos/kos-ssh-key list | grep -c 'ED25519' | grep -qx 4 && ok "kos-ssh-key list shows 4 keys" || bad "kos-ssh-key list" "$(kos /usr/lib/kos/kos-ssh-key list)"
kos grep -q "$(pub four | cut -d' ' -f2)" /config/kos.conf && ok "kos-ssh-key wrote kos.conf" || bad "kos-ssh-key wrote kos.conf"
if kos /usr/lib/kos/kos-ssh-key remove t2-four >/dev/null 2>&1 && ! login four klipper; then ok "kos-ssh-key remove: key refused at once"; else bad "kos-ssh-key remove"; fi
check "other keys still work after remove" login one klipper

# 6. listeners: IPv4 only; 0.0.0.0 only for sshd and nginx; Moonraker on loopback
ss=$(kos ss -Htlnp)
info "listening: $(printf '%s\n' "$ss" | awk '{print $4}' | sort -u | tr '\n' ' ')"
printf '%s\n' "$ss" | awk '{print $4}' | grep -q '^\[' && bad "no IPv6 listeners" "$(printf '%s\n' "$ss" | grep '\[')" || ok "no IPv6 listeners"
wild=$(printf '%s\n' "$ss" | awk '$4 ~ /^(0\.0\.0\.0|\*):/ {print $4}' | grep -Ev ':(22|80)$')
[ -z "$wild" ] && ok "nothing unexpected on 0.0.0.0" || bad "unexpected on 0.0.0.0" "$(printf '%s' "$wild" | tr '\n' ' ')"
for _ in $(seq 60); do printf '%s\n' "$(kos ss -Htln)" | grep -q '127.0.0.1:7125 ' && break; sleep 2; done
kos ss -Htln | grep -q '127.0.0.1:7125 ' && ok "Moonraker on 127.0.0.1:7125" || bad "Moonraker on 127.0.0.1:7125" "moonraker: $(kos systemctl is-active moonraker)"

# 7. nginx Host and Origin checks, from this host
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" "http://$IP/server/info"; }
for h in "$IP" kos-boot kos-boot.local voron.lan printer.home.arpa; do
    c=$(code -H "Host: $h"); case $c in 421|403|000) bad "Host $h allowed" "$c";; *) ok "Host $h allowed ($c)";; esac
done
c=$(code -H 'Host: evil.example.com'); [ "$c" = 421 ] && ok "foreign Host 421" || bad "foreign Host 421" "$c"
c=$(code -H 'Host: kos-boot.local' -H 'Origin: http://evil.example.com'); [ "$c" = 403 ] && ok "foreign Origin 403" || bad "foreign Origin 403" "$c"
c=$(code -H 'Host: kos-boot.local' -H 'Origin: http://kos-boot.local'); case $c in 403|421|000) bad "own Origin allowed" "$c";; *) ok "own Origin allowed ($c)";; esac
c=$(curl -s -o /dev/null -m 20 -w '%{http_code}' -H "Host: $IP" -F "file=@$W/keys/one.pub;filename=t.gcode" "http://$IP/server/files/upload")
case $c in 403|421|000) bad "upload without Origin passes nginx" "$c";; *) ok "upload without Origin passes nginx ($c)";; esac

# 8. security updates: skipped while busy, run when idle, timer re-armed after a skip
run_updates() { kos systemctl start kos-security-updates.service >/dev/null 2>&1; kos systemctl show -p Result --value kos-security-updates.service; }
r=$(run_updates); info "real Moonraker (no MCU): $(kos /usr/lib/kos/kos-printer-idle 2>&1); Result=$r"
[ "$r" = exec-condition ] && ok "updates skipped while Klippy is not ready" || bad "updates skipped while Klippy is not ready" "$r"
kos systemctl stop moonraker.service
kos sh -c 'echo printing > /run/kos-stub-state'
kos systemd-run -q --unit=kos-stub-moonraker python3 -I -c '
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def do_GET(s):
        job = open("/run/kos-stub-state").read().strip()
        res = {"klippy_state": "ready"} if s.path == "/server/info" else \
              {"status": {"print_stats": {"state": job}, "idle_timeout": {"state": "Printing" if job == "printing" else "Idle"}}}
        b = json.dumps({"result": res}).encode(); s.send_response(200); s.send_header("Content-Length", str(len(b))); s.end_headers(); s.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", 7125), H).serve_forever()'
sleep 2
r=$(run_updates); [ "$r" = exec-condition ] && ok "updates skipped while printing" || bad "updates skipped while printing" "$r"
tm=$(kos systemctl show -p ActiveState -p TimersMonotonic -p NextElapseUSecMonotonic kos-security-updates.timer)
inactive=$(kos systemctl show -p InactiveEnterTimestampMonotonic --value kos-security-updates.service)
next=$(printf '%s\n' "$tm" | grep -o 'OnUnitInactiveUSec=[^;]*; next_elapse=[0-9]*' | grep -o '[0-9]*$')
info "timer after skip: $(printf '%s' "$tm" | tr '\n' ' ')"
if printf '%s\n' "$tm" | grep -qx ActiveState=active && [ -n "$next" ] &&
   [ $((next - inactive)) -ge 86400000000 ] && [ $((next - inactive)) -le $((86400000000 + 3600000000)) ]; then
    ok "timer re-armed 1 day after the skipped run"
else bad "timer re-armed 1 day after the skipped run" "inactive=$inactive next=${next:-none}"; fi
kos sh -c 'echo standby > /run/kos-stub-state'
r=$(run_updates)
j=$(kos journalctl -q -u kos-security-updates.service -n 30 --no-pager)
info "idle run: Result=$r (no route out, so apt and unattended-upgrade may fail)"
[ "$r" != exec-condition ] && printf '%s\n' "$j" | grep -q 'printer idle' && ok "updates run when idle" || bad "updates run when idle" "$r"
kos systemctl stop kos-stub-moonraker.service

echo "---"
[ "$fails" = 0 ] && echo "boot smoke: all checks passed ($IMG)" || { echo "boot smoke: $fails check(s) failed ($IMG)"; tail -n 40 "$W/console.log"; }
[ "$fails" = 0 ]
