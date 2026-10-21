#!/bin/bash
# Self-check for overlay/usr/lib/kos/lib.sh: the kos.conf parser (and its Python twin), validators, SSH key handling.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
KOS_CONF=$T/kos.conf
ssh-keygen -q -t ed25519 -N '' -C 'me@laptop' -f "$T/a" && ssh-keygen -q -t ed25519 -N '' -C 'second key' -f "$T/b"
A=$(cat "$T/a.pub"); B=$(cat "$T/b.pub")
cat > "$KOS_CONF" <<EOF
# comment
hostname = voron
  timezone=America/Chicago
password=correct horse #battery staple
wifi_pass="p4ss w0rd\$"
quoted='x'
lonequote="
empty=
hostname=voron2
crlf=value
long=first part \\
    second part\\
   third
# a comment line ending in a backslash does not continue \\
notswallowed=yes
ssh_key=$A
ssh_key=$B \\
  $A \\
  ssh-ed25519 AAAAnotbase64!! typo@key
EOF
printf 'crlf=dos\r\n' >> "$KOS_CONF"
. overlay/usr/lib/kos/lib.sh
[ "$(cfg hostname)" = voron2 ]
[ "$(cfg timezone)" = America/Chicago ]
[ "$(cfg password)" = 'correct horse #battery staple' ]   # '#' is a comment only at the start of a line
[ "$(cfg wifi_pass)" = 'p4ss w0rd$' ]
[ "$(cfg quoted)" = x ] && [ "$(cfg lonequote)" = '"' ] || exit 1
[ "$(cfg empty default)" = default ]
[ "$(cfg missing fallback)" = fallback ]
[ "$(cfg long)" = 'first part second part third' ]
[ "$(cfg notswallowed)" = yes ]
[ "$(cfg crlf)" = dos ]
[ "$(cfg_lines long | cut -d' ' -f1-2)" = '11 13' ]

# The Python twin (kos-archive, kos-mcu-discover) must read every key the same way.
same_in_python() {
    for k in $(LC_ALL=C awk -F= '/=/ && !/^#/ {gsub(/[[:space:]]/, "", $1); print $1}' "$KOS_CONF" | LC_ALL=C sort -u); do printf '%s=%s\n' "$k" "$(cfg "$k")"; done > "$T/sh.out"
    for tool in kos-archive kos-mcu-discover; do
        python3 -I -B - "overlay/usr/lib/kos/$tool" "$KOS_CONF" "$T/sh.out" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("tool", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("tool", loader)); loader.exec_module(mod)
py = mod.read_conf(sys.argv[2])
for line in open(sys.argv[3], encoding="utf-8", errors="replace", newline="").read().split("\n")[:-1]:
    k, v = line.split("=", 1)
    assert py.get(k, "") == v, (sys.argv[1], k, py.get(k), v)
EOF
    done
}
same_in_python
[ -z "$(cfg_problems)" ]

# Edge cases: a UTF-8 BOM, a commented-out continuation (that key is revoked), a continuation that runs into the next
# key= or off the end of the file, a lone CR mid-line, a NUL byte.
printf '\357\273\277ssh_key=%s \\\n#   %s\nhostname=bom\\\ntimezone=Etc/UTC\nmid=a\rb\nn\000ul=x\000y\nwifi_pass=ends\\\n' "$A" "$B" > "$T/edge.conf"
KOS_CONF=$T/edge.conf
[ "$(ssh_keys)" = "$A" ]   # B's line is commented out, so B is not a key
[ "$(cfg hostname)" = bom ] && [ "$(cfg timezone)" = Etc/UTC ] && [ "$(cfg wifi_pass)" = ends ] || exit 1
[ "$(cfg mid)" = "$(printf 'a\rb')" ] && [ "$(cfg nul)" = xy ] || exit 1
[ "$(cfg_lines ssh_key | cut -d' ' -f1-2)" = '1 1' ]
[ "$(cfg_problems | wc -l)" -eq 2 ]
cfg_problems | grep -q '^line 3 ends in .* but line 4 starts a new setting' && cfg_problems | grep -q '^the last line ends in' || exit 1
same_in_python
KOS_CONF=$T/kos.conf

# ssh_key: several lines or one continued value; each key on its own; the typo is skipped with a warning
[ "$(ssh_keys | wc -l)" -eq 4 ]
[ "$(ssh_keys | sed -n 2p)" = "$B" ] && [ "$(ssh_keys | sed -n 3p)" = "$A" ] || exit 1
KOS_KEYS=$T/keys/klipper KOS_WARNINGS=
apply_ssh_keys 2> "$T/err"
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$A" "$B" "$A")" ]
grep -q 'not a valid SSH public key, skipped: ssh-ed25519 AAAAnotbase64' "$T/err"
case $KOS_WARNINGS in *"skipped: ssh-ed25519 AAAAnotbase64"*) ;; *) exit 1 ;; esac
# Options and certificates fail closed: the whole entry is rejected, never installed without its restriction.
[ "$(printf 'from="10.0.0.5",command="/usr/bin/true" %s\n' "$A" | split_keys)" = "!from=\"10.0.0.5\",command=\"/usr/bin/true\" $A" ]
[ "$(printf 'restrict %s\n' "$A" | split_keys)" = "!restrict $A" ]
[ "$(printf '%s no-pty,pty %s\n' "$A" "$B" | split_keys | cut -c1)" = '!' ]                  # option in front of a continued key
[ "$(printf '%s command="/bin/sh -c id" %s\n' "$A" "$B" | split_keys | cut -c1)" = '!' ]
[ "$(printf 'ssh-ed25519-cert-v01@openssh.com AAAA x\n' | split_keys | cut -c1)" = '!' ]
printf 'ssh_key=command="id" %s\nssh_key=%s\n' "$A" "$B" > "$T/opt.conf"
KOS_CONF=$T/opt.conf KOS_WARNINGS=
apply_ssh_keys 2> "$T/err"
[ "$(cat "$KOS_KEYS")" = "$B" ] && grep -q 'not a plain public key (options such as from= .*skipped: command="id"' "$T/err" || exit 1
KOS_CONF=$T/kos.conf

valid_label kos && valid_label my-voron-2 && ! valid_label -F/etc/passwd && ! valid_label 'kos router' && ! valid_label kos- && ! valid_label '' || exit 1
! valid_label "$(printf 'a%.0s' $(seq 64))" && valid_label "$(printf 'a%.0s' $(seq 63))" || exit 1
valid_dnsname printer.example.com && ! valid_dnsname 'x 1; } server {' && ! valid_dnsname '*.lan' && ! valid_dnsname a..b || exit 1
valid_tz Europe/Berlin && valid_tz Etc/UTC && ! valid_tz localtime && ! valid_tz ./localtime && ! valid_tz ../../../etc/shadow && ! valid_tz /etc/passwd && ! valid_tz Europe && ! valid_tz '' || exit 1

L=$(printf 'a%.0s' $(seq 63)); valid_dnsname "$L.$L.$L.$(printf 'a%.0s' $(seq 61))" && ! valid_dnsname "$L.$L.$L.$(printf 'a%.0s' $(seq 62))" || exit 1   # 253 ok, 254 not

# nginx map: always localhost, lower case, sorted, each name escaped so a keyword is just a name
[ "$(hosts_map Kos kos.local default)" = "$(printf '%s\n' '\default 1;' '\kos 1;' '\kos.local 1;' '\localhost 1;')" ]
[ "$(hosts_map kos kos.local)" = "$(cat overlay/etc/kos/nginx-hosts.map)" ]   # the image ships what kos-config writes

# moonraker.conf: [server] host forced to loopback; nothing else changes
M=$T/moonraker.conf
printf '[server]\nhost: 127.0.0.1\nport: 7125\n' > "$M"; moonraker_host "$M" > /dev/null
printf '# imported\n[server]\r\nport: 7125\r\nHost = 0.0.0.0  # all\r\n  host: 1.2.3.4\r\n[authorization]\r\nhost: x\r\n' > "$M"
[ "$(moonraker_host "$M")" = 0.0.0.0 ] && ! moonraker_host "$M" > /dev/null || exit 1
moonraker_host "$M" 127.0.0.1 > "$M.new"
[ "$(cat "$M.new")" = "$(printf '# imported\n[server]\r\nhost: 127.0.0.1\nport: 7125\r\n  host: 1.2.3.4\r\n[authorization]\r\nhost: x\r')" ]
moonraker_host "$M.new" > /dev/null
printf '[machine]\nprovider: none\n' > "$M"; [ -z "$(moonraker_host "$M")" ] && ! moonraker_host "$M" > /dev/null || exit 1
[ "$(moonraker_host "$M" 127.0.0.1)" = "$(printf '[machine]\nprovider: none\n\n[server]\nhost: 127.0.0.1')" ]

KOS_CONF=/nonexistent; [ "$(cfg hostname kos)" = kos ]
echo ok
