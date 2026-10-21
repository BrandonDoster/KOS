#!/bin/sh
# The image's config files and kos-config, in a throwaway debian:trixie container (the pinned build digest) laid out
# like the image: overlay/ copied over /, the klipper user as build/customize.sh makes it. Needs Docker.
#   systemd units (systemd-analyze verify), sudoers (visudo), the sshd drop-in (sshd -t, and that it takes effect),
#   unattended-upgrades (security origin only), fstab, tmpfiles; then kos-config end to end, three boots in a row,
#   with stubs only for what needs a running system or hardware (systemctl, nmcli, networkctl, iw, hostname).
set -eu
cd "$(dirname "$0")/.."
IMG=$(sed -n 's/^DEBIAN_IMAGE=//p' build/pins.env)
docker run --rm -i --platform linux/amd64 --tmpfs /home/klipper/printer_data:exec -v "$PWD:/src:ro" "$IMG" bash -eu <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends systemd sudo openssh-server unattended-upgrades tzdata python3 perl >/dev/null 2>&1
cp -r /src/overlay/. /
useradd -m -u 1000 -U -s /bin/bash klipper 2>/dev/null; usermod -p '*' klipper; chmod 0440 /etc/sudoers.d/klipper
ok() { echo "ok   $*"; }

# --- static config ---
visudo -cf /etc/sudoers.d/klipper >/dev/null && visudo -c >/dev/null && ok "sudoers" || exit 1
mkdir -p /run/sshd /etc/kos/authorized_keys && ssh-keygen -A >/dev/null && sshd -t || exit 1
sshd -T -C user=klipper | grep -qx 'authorizedkeysfile /etc/kos/authorized_keys/%u'   # the drop-in wins over sshd_config
sshd -T | grep -qx 'permitrootlogin no' && sshd -T | grep -qx 'addressfamily inet' && sshd -T | grep -qx 'allowtcpforwarding no' && sshd -T | grep -qx 'x11forwarding no' && ok "sshd drop-in" || exit 1
[ "$(apt-config dump Unattended-Upgrade::Origins-Pattern | grep -c '^Unattended-Upgrade::Origins-Pattern:: ')" -eq 1 ]
apt-config dump Unattended-Upgrade::Origins-Pattern | grep -qF '"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
apt-config dump Unattended-Upgrade::Automatic-Reboot | grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' && ok "unattended-upgrades: security origin only, no reboot" || exit 1
# The labels and mount points only exist on a flashed card: here only parsing and mount options are checked.
v=$(findmnt --verify --tab-file /etc/fstab 2>&1 || true)
printf '%s\n' "$v" | grep -q '^0 parse errors, .* 0 warnings$' && ! printf '%s\n' "$v" | grep '\[E\]' | grep -qv 'unreachable on boot' || { printf '%s\n' "$v"; exit 1; }
ok "fstab parses"
systemd-tmpfiles --create /etc/tmpfiles.d/kos-nginx.conf /etc/tmpfiles.d/kos-unattended-upgrades.conf
[ "$(stat -c %U:%G:%a /var/log/nginx)" = www-data:adm:755 ]
[ "$(stat -c %U:%G:%a /var/log/unattended-upgrades)" = root:root:755 ]   # /var/log is tmpfs; unattended-upgrade crashes without it
ok "tmpfiles"
# The venvs and the units' other targets come from the build; empty executables stand in for them.
for f in /home/klipper/klippy-env/bin/python /home/klipper/moonraker-env/bin/python /usr/bin/unattended-upgrade; do
    [ -e "$f" ] || { mkdir -p "${f%/*}"; printf '#!/bin/sh\n' > "$f"; chmod +x "$f"; }
done
units=$(cd /etc/systemd/system && ls ./*.service ./*.timer | sed 's|^\./|/etc/systemd/system/|')
out=$(systemd-analyze verify --man=no $units ssh.service getty@tty1.service 2>&1 || true)
# Units the image gets from packages this container does not have (nginx, NetworkManager, avahi): not our files' fault.
bad=$(printf '%s\n' "$out" | grep -v -e '^$' -e 'nginx.service' -e 'NetworkManager' -e 'avahi-daemon' -e 'klipper-mcu' -e 'config.mount' -e 'home-klipper-printer_data.mount' || true)
[ -z "$bad" ] || { printf '%s\n' "$out"; exit 1; }
ok "systemd-analyze verify: $(echo $units | wc -w) units + ssh/getty drop-ins"

# --- kos-config, three boots ---
S=/tmp/stub; mkdir -p $S; : > /tmp/calls
for c in systemctl nmcli networkctl iw hostname growpart; do printf '#!/bin/sh\necho "%s $*" >> /tmp/calls\n' "$c" > "$S/$c"; done
chmod +x $S/*
boot() { : > /tmp/calls; PATH=$S:$PATH bash /usr/lib/kos/kos-config > /tmp/out 2>&1 || { cat /tmp/out; exit 1; }; }
mkdir -p /config /var/lib/kos && touch /var/lib/kos/firstboot.done   # growpart/resize2fs need a real disk
ssh-keygen -q -t ed25519 -N '' -C me@laptop -f /tmp/a; A=$(cat /tmp/a.pub)
mkdir -p /config/printer_data/config
printf '[server]\nhost: 0.0.0.0\n[authorization]\n' > /config/printer_data/config/moonraker.conf
printf '[include /home/pi/printer_data/config/macros.cfg]\n' > /config/printer_data/config/printer.cfg
printf '#!/bin/sh\n' > /config/printer_data/config/backup.sh; echo junk > /config/printer_data/config/._printer.cfg
mkdir -p /etc/modprobe.d && echo 'blacklist vc4' > /etc/modprobe.d/kos-display.conf
cat > /config/kos.conf <<CONF
hostname=voron
timezone=Europe/Berlin
password=hunter2
ssh_key=$A
allowed_hosts=printer.lan, bad_name!
wifi_ssid=MyNet
wifi_pass=secret pass
can_bitrate=500000
display=hdmi
archive_printed=off
CONF
boot
P=/home/klipper/printer_data/config
[ "$(cat /etc/hostname)" = voron ] && [ "$(grep -c '^127\.0\.1\.1' /etc/hosts)" -eq 1 ] && grep -qx '127.0.1.1 voron' /etc/hosts || exit 1
. /usr/lib/kos/lib.sh
[ "$(cat /etc/kos/nginx-hosts.map)" = "$(hosts_map voron voron.local printer.lan)" ]
grep -qx 'systemctl try-reload-or-restart nginx.service' /tmp/calls
[ "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Europe/Berlin ] && [ "$(cat /etc/timezone)" = Europe/Berlin ] || exit 1
case $(getent shadow klipper | cut -d: -f2) in '$'*) ;; *) echo "FAIL: password not set"; exit 1 ;; esac
[ "$(cat /etc/kos/authorized_keys/klipper)" = "$A" ]
grep -q "nmcli con add con-name kos-wifi type wifi ifname \* ssid MyNet" /tmp/calls && grep -q 'wifi-sec.psk secret pass' /tmp/calls || exit 1
grep -qx 'BitRate=500000' /etc/systemd/network/99-can.network
[ ! -e /etc/modprobe.d/kos-display.conf ]
grep -qx 'systemctl disable --now --no-block kos-archive.service' /tmp/calls && grep -qx 'systemctl disable --now --no-block klipper-mcu.service' /tmp/calls || exit 1
grep -qx '\[include /home/klipper/printer_data/config/macros.cfg\]' $P/printer.cfg   # foreign home paths rewritten
[ "$(moonraker_host $P/moonraker.conf)" = 127.0.0.1 ] && grep -qx '\[authorization\]' $P/moonraker.conf || exit 1
[ -x $P/backup.sh ] && [ ! -e $P/._printer.cfg ] && [ -L $P/mainsail.cfg ] && [ -e /run/kos-imported ] || exit 1
[ "$(stat -c %U $P/printer.cfg)" = klipper ] && ls -d /config/printer_data.imported.* >/dev/null && [ ! -e /config/printer_data ] || exit 1
grep -q "allowed_hosts: 'bad_name!' is not a host name" /config/KOS-WARNINGS.txt
grep -q "moonraker.conf: \[server\] host was '0.0.0.0', set to 127.0.0.1" /config/KOS-WARNINGS.txt
[ "$(grep -c . /config/KOS-WARNINGS.txt)" -eq 3 ] && cmp -s /config/KOS-WARNINGS.txt /run/motd.d/kos-warnings || exit 1
ok "kos-config boot 1: hostname, hosts map, timezone, password, key, wifi, CAN, display, import, warnings"

echo 'printer.cfg from the card' > /config/printer.cfg
printf 'hostname=bad_name\nallowed_hosts=printer.lan\ntimezone=../../../etc/shadow\nwifi_ssid=\ncan_bitrate=fast\n' > /config/kos.conf
echo '[mcu host]' > $P/host.cfg; echo 'serial: /tmp/klipper_host_mcu' >> $P/host.cfg
boot
[ "$(cat /etc/hostname)" = voron ] && [ "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Etc/UTC ] || exit 1
[ "$(getent shadow klipper | cut -d: -f2)" = '*' ] && [ ! -s /etc/kos/authorized_keys/klipper ] || exit 1   # removed lines revoke
[ "$(cat $P/printer.cfg)" = 'printer.cfg from the card' ] && [ -e /config/printer.cfg.imported ] || exit 1
grep -qx 'BitRate=1000000' /etc/systemd/network/99-can.network && ! grep -q nmcli /tmp/calls || exit 1
grep -qx 'systemctl enable --now --no-block kos-archive.service' /tmp/calls && grep -qx 'systemctl enable --now --no-block klipper-mcu.service' /tmp/calls || exit 1
! grep -q try-reload /tmp/calls || exit 1   # same host names: nginx left alone
for w in "hostname 'bad_name' is not valid" "timezone '../../../etc/shadow' is not a known zone" "can_bitrate 'fast' is not a number" "no valid ssh_key= and no password="; do
    grep -qF "$w" /config/KOS-WARNINGS.txt || { echo "FAIL: missing warning: $w"; cat /config/KOS-WARNINGS.txt; exit 1; }
done
! grep -q moonraker.conf /config/KOS-WARNINGS.txt || exit 1
ok "kos-config boot 2: bad values fall back with warnings, credentials revoked, printer.cfg imported"

printf 'hostname=voron\nssh_key=%s\n' "$A" > /config/kos.conf
boot
[ ! -e /config/KOS-WARNINGS.txt ] && [ ! -e /run/motd.d/kos-warnings ] && [ "$(cat /etc/kos/authorized_keys/klipper)" = "$A" ] || exit 1
ok "kos-config boot 3: all well, warnings removed"
EOF
echo "config ok"
