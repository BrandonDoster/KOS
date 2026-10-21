#!/bin/sh
# What can be checked of a built image without systemd as PID 1 (so also under Docker Desktop, where
# tests/boot/boot_smoke.sh cannot boot it). Usage: tests/boot/static_checks.sh out/kos-<board>-YYYYMMDD.img
# In a privileged arm64 container: KOS-ROOT read-only under a tmpfs overlay, the image's KOS partition copied and mounted
# with the fstab's options, then in a chroot: kos-config on a test kos.conf, sshd -t/-T and real SSH logins against a
# hand-started sshd, kos-ssh-key, nginx -t and Host/Origin requests against the generated map, visudo -c,
# systemd-analyze verify on KOS's units, unattended-upgrade --dry-run, and the configured listen addresses.
# Exit 0 = every check passed.
set -eu
IMG=$(cd "$(dirname "${1:?image}")" && pwd)/$(basename "$1")
cd "$(dirname "$0")/../.."
sh build/bump-pins.sh --check build/pins.env && . build/pins.env   # DEBIAN_IMAGE
docker run --rm -i --privileged --platform linux/arm64 -v "$(dirname "$IMG"):/o:ro" -e IMG="/o/$(basename "$IMG")" \
    "$DEBIAN_IMAGE" bash -u <<'OUTER'
W=/w; mkdir -p $W/lower $W/ovl $W/r $W/keys
apt-get update -qq >/dev/null && apt-get install -y -qq python3 >/dev/null 2>&1
eval "$(python3 -I - "$IMG" <<'PY'
import sys, struct
h = open(sys.argv[1], "rb").read(512)
print("PARTS='%s'" % " ".join(f"{s*512}:{z*512}" for _, _, t, _, s, z in
      (struct.unpack("<B3sB3sII", h[446+i*16:462+i*16]) for i in range(4)) if t))
PY
)"
for p in $PARTS; do
    off=${p%%:*} size=${p##*:}
    case $(blkid -p -o value -s LABEL -O "$off" -S "$size" "$IMG") in
    KOS-ROOT) mount -o ro,loop,offset="$off",sizelimit="$size" "$IMG" $W/lower ;;
    KOS) dd if="$IMG" of=$W/kos.fs bs=1M iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none ;;
    esac
done
mount -t tmpfs -o size=2g tmpfs $W/ovl && mkdir $W/ovl/u $W/ovl/w
mount -t overlay overlay -o lowerdir=$W/lower,upperdir=$W/ovl/u,workdir=$W/ovl/w $W/r
for m in proc sys dev dev/pts; do mount --bind /$m $W/r/$m; done
mount -t tmpfs tmpfs $W/r/run; mount -t tmpfs tmpfs $W/r/tmp; mount -t tmpfs tmpfs $W/r/var/log
cp /etc/resolv.conf $W/r/etc/resolv.conf
# /config: the image's own KOS partition, mounted with the options in the image's fstab
o=$(awk '$2 == "/config" {print $4}' $W/r/etc/fstab | sed 's/,nofail//')
mount -o loop,"$o" $W/kos.fs $W/r/config
mount -t tmpfs tmpfs $W/r/home/klipper/printer_data   # stands in for KOS-DATA (a mount point, as kos-config wants)
c() { chroot $W/r "$@" </dev/null; }   # stdin is this script: ssh would read it
c systemd-tmpfiles --create >/dev/null 2>&1   # as systemd-tmpfiles-setup.service at boot: /var/log and /run start empty
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }
check() { n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
info() { echo "INFO $*"; }

# --- test kos.conf (as boot_smoke.sh) ---
for k in one two three four; do c ssh-keygen -q -t ed25519 -N '' -C "t2-$k" -f /tmp/$k; cp $W/r/tmp/$k* $W/keys/; done
pub() { cat $W/keys/$1.pub; }
cat > $W/r/config/kos.conf <<EOF
hostname=kos-boot
allowed_hosts=voron.lan, printer.home.arpa bad_host!
ssh_key=$(pub one)
ssh_key=$(pub two) \\
        $(pub three)
ssh_key=from="10.0.0.1" $(pub four)
timezone=Mars/Olympus
can_bitrate=fast
EOF
mkdir -p $W/r/config/printer_data/config
printf '[include /home/pi/printer_data/config/macros.cfg]\n[mcu]\nserial: /dev/null\n' > $W/r/config/printer_data/config/printer.cfg
sed 's/^host: 127.0.0.1/host: 0.0.0.0/' $W/r/usr/lib/kos/moonraker.conf > $W/r/config/printer_data/config/moonraker.conf

# --- /config mount ---
opts=$(findmnt -no OPTIONS $W/r/config)
for x in nosuid nodev noexec uid=1000 fmask=0177 dmask=0077 sync; do
    case ",$opts," in *",$x,"*) ok "/config $x" ;; *) bad "/config $x" "$opts" ;; esac
done
[ "$(stat -c %a $W/r/config/kos.conf)" = 600 ] && ok "kos.conf 0600 on the FAT" || bad "kos.conf mode" "$(stat -c %a $W/r/config/kos.conf)"

# --- kos-config (systemctl, nmcli, networkctl act as in a chroot: no-ops) ---
c /usr/lib/kos/kos-config > $W/kos-config.log 2>&1; rc=$?
[ $rc = 0 ] && ok "kos-config exit 0" || bad "kos-config exit $rc" "$(tail -n 5 $W/kos-config.log)"
info "kos-config output: $(grep -c . $W/kos-config.log) lines; $(grep -v 'kos: \(WARNING\|importing\|home paths\|hostname\)' $W/kos-config.log | head -n 8 | tr '\n' '|')"
check "hostname kos-boot" test "$(cat $W/r/etc/hostname)" = kos-boot
check "printer.cfg imported, home rewritten" grep -q /home/klipper/printer_data/config/macros.cfg $W/r/home/klipper/printer_data/config/printer.cfg
check "moonraker.conf host forced to 127.0.0.1" grep -qx 'host: 127.0.0.1' $W/r/home/klipper/printer_data/config/moonraker.conf
check "authorized_keys: 3 keys" test "$(grep -c . $W/r/etc/kos/authorized_keys/klipper)" = 3
check "authorized_keys root-owned 0644" test "$(stat -c '%U %a' $W/r/etc/kos/authorized_keys/klipper)" = "root 644"
check "klipper password locked" test "$(c getent shadow klipper | cut -d: -f2)" = '*'
for n in kos-boot kos-boot.local voron.lan printer.home.arpa localhost; do check "host map has $n" grep -qxF "\\$n 1;" $W/r/etc/kos/nginx-hosts.map; done
grep -q bad_host $W/r/etc/kos/nginx-hosts.map && bad "host map leaves out bad_host!" || ok "host map leaves out bad_host!"
for w in "timezone 'Mars/Olympus'" "can_bitrate 'fast'" "allowed_hosts: 'bad_host!'" "ssh_key: not a plain public key" "moonraker.conf: \[server\] host was '0.0.0.0'"; do
    check "KOS-WARNINGS.txt: $w" grep -q "$w" $W/r/config/KOS-WARNINGS.txt
    check "motd: $w" grep -q "$w" $W/r/run/motd.d/kos-warnings
done
c /usr/lib/kos/kos-config > $W/kos-config2.log 2>&1 && check "kos-config second run: same keys" test "$(grep -c . $W/r/etc/kos/authorized_keys/klipper)" = 3

# --- sshd: config, then a real daemon (what ssh.service's ExecStartPre does first) ---
check "image ships no host keys" test -z "$(ls $W/lower/etc/ssh/ | grep '^ssh_host_')"
c ssh-keygen -A >/dev/null && check "ssh-keygen -A makes ed25519/ecdsa/rsa" test -s $W/r/etc/ssh/ssh_host_ed25519_key -a -s $W/r/etc/ssh/ssh_host_ecdsa_key -a -s $W/r/etc/ssh/ssh_host_rsa_key
mkdir -p $W/r/run/sshd   # ssh.service's RuntimeDirectory
check "sshd -t" c /usr/sbin/sshd -t
T=$(c /usr/sbin/sshd -T 2>&1)
for want in "authorizedkeysfile /etc/kos/authorized_keys/%u" "permitrootlogin no" "addressfamily inet" "pubkeyauthentication yes" "allowtcpforwarding no" "x11forwarding no" "allowagentforwarding no"; do
    printf '%s\n' "$T" | grep -qx "$want" && ok "sshd -T: $want" || bad "sshd -T: $want"
done
info "sshd -T: $(printf '%s\n' "$T" | grep -E '^(passwordauthentication|kbdinteractiveauthentication|listenaddress|x11forwarding|allowtcpforwarding) ' | tr '\n' ';')"
c /usr/sbin/sshd -o ListenAddress=127.0.0.1:2222 -E /tmp/sshd.log
for k in one two three four; do cp $W/keys/$k $W/r/root/k_$k; chmod 600 $W/r/root/k_$k; done
login() { [ "$(c ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR -i /root/k_$1 "$2@127.0.0.1" id -un 2>/dev/null)" = "$2" ]; }
for k in one two three; do check "ssh klipper with key $k" login $k klipper; done
login four klipper && bad "key four (from=, not installed) refused" || ok "key four (from=, not installed) refused"
login one root && bad "root login refused" || ok "root login refused"
# --- kos-ssh-key round trip ---
c /usr/lib/kos/kos-ssh-key add "$(pub four)" >/dev/null 2>&1 && login four klipper && ok "kos-ssh-key add: works at once" || bad "kos-ssh-key add"
[ "$(c /usr/lib/kos/kos-ssh-key list | grep -c ED25519)" = 4 ] && ok "kos-ssh-key list: 4 keys" || bad "kos-ssh-key list" "$(c /usr/lib/kos/kos-ssh-key list)"
check "kos-ssh-key wrote kos.conf on the FAT" grep -q "$(pub four | cut -d' ' -f2)" $W/r/config/kos.conf
c /usr/lib/kos/kos-ssh-key remove t2-four >/dev/null 2>&1 && ! login four klipper && ok "kos-ssh-key remove: refused at once" || bad "kos-ssh-key remove"
check "key one still works" login one klipper
check "from= line kept in kos.conf" grep -q '^ssh_key=from=' $W/r/config/kos.conf

# --- nginx with the generated map, stub Moonraker on 127.0.0.1:7125 ---
mkdir -p $W/r/var/log/nginx
check "nginx -t" c nginx -t
c nginx
c python3 -I -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def go(s): s.send_response(200); s.end_headers(); s.wfile.write(b"stub\n")
    do_GET = do_POST = go
http.server.HTTPServer(("127.0.0.1", 7125), H).serve_forever()' &
sleep 1
IP=$(hostname -I | awk '{print $1}')
code() { c curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
for h in "$IP" kos-boot kos-boot.local voron.lan printer.home.arpa; do
    r=$(code -H "Host: $h" "http://$IP/server/info"); [ "$r" = 200 ] && ok "Host $h allowed" || bad "Host $h allowed" "$r"
done
r=$(code -H 'Host: evil.example.com' "http://$IP/"); [ "$r" = 421 ] && ok "foreign Host 421" || bad "foreign Host 421" "$r"
r=$(code -H 'Host: kos-boot.local' -H 'Origin: http://evil.example.com' -X POST "http://$IP/printer/gcode/script?script=M112"); [ "$r" = 403 ] && ok "foreign Origin 403" || bad "foreign Origin 403" "$r"
r=$(code -H 'Host: kos-boot.local' -H 'Origin: http://voron.lan' "http://$IP/websocket"); [ "$r" = 200 ] && ok "allowed_hosts Origin passes" || bad "allowed_hosts Origin passes" "$r"
r=$(code -H "Host: $IP" -X POST -F file=@/etc/hostname "http://$IP/server/files/upload"); [ "$r" = 200 ] && ok "upload without Origin passes" || bad "upload without Origin passes" "$r"

# --- listen addresses: what is up now in this chroot, then the configured ones ---
ss=$(c ss -Htln)
info "listening now: $(printf '%s\n' "$ss" | awk '{print $4}' | sort -u | tr '\n' ' ')"
printf '%s\n' "$ss" | awk '{print $4}' | grep -q '^\[' && bad "nginx/sshd: no IPv6 listeners" || ok "nginx/sshd: no IPv6 listeners"
l=$(c sh -c "grep -RhE '^[[:space:]]*listen' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ /etc/nginx/nginx.conf" | tr -s ' \t' ' ' | sort -u)
[ "$l" = " listen 80 default_server;" ] && ok "nginx: only 'listen 80', no [::]" || bad "nginx listen lines" "$l"
info "avahi: $(grep -E '^(use-ipv4|use-ipv6|allow-interfaces|publish)' $W/r/etc/avahi/avahi-daemon.conf | tr '\n' ' ')"

# --- sudoers, units, updates ---
check "visudo -c" c visudo -c
units=$(cd $W/r/etc/systemd/system && ls kos-*.service kos-*.timer klipper.service moonraker.service | sed 's|^|/etc/systemd/system/|')
# shellcheck disable=SC2086
v=$(c systemd-analyze verify --man=no $units ssh.service 2>&1 | grep -v 'Failed to .*bus\|Cannot add dependency job\|without --root\|not a container')
[ -z "$v" ] && ok "systemd-analyze verify (KOS units, ssh.service)" || bad "systemd-analyze verify" "$(printf '%s\n' "$v" | head -n 12 | tr '\n' '|')"
c systemd-analyze calendar --iterations=1 now >/dev/null 2>&1 || true
check "kos-printer-idle --test" c python3 -I /usr/lib/kos/kos-printer-idle --test
c apt-get -q update > $W/apt.log 2>&1 || info "apt-get update failed: $(tail -n 2 $W/apt.log | tr '\n' ' ')"
u=$(c unattended-upgrade --dry-run -d 2>&1)
info "unattended-upgrade: $(printf '%s\n' "$u" | grep -iE 'allowed origins|pkgs that look like they should be upgraded|No packages found' | head -n 3 | tr '\n' '|')"
printf '%s\n' "$u" | grep -i 'allowed origins' | grep -q 'security' && ok "unattended-upgrade allows the security origin" || bad "unattended-upgrade origins" "$(printf '%s\n' "$u" | head -n 6 | tr '\n' '|')"
printf '%s\n' "$u" | grep -i 'allowed origins' | grep -qiE 'armbian|raspberrypi' && info "non-Debian origin allowed (check if intended)"

c pkill nginx; c pkill -f 'sshd -o ListenAddress'; kill %1 2>/dev/null
echo "---"; [ $fails = 0 ] && echo "static checks: all passed" || echo "static checks: $fails failed"
exit $fails
OUTER
