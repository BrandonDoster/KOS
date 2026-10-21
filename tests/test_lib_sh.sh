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
[ "$(cfg quoted)" = x ] && [ "$(cfg lonequote)" = '"' ]
[ "$(cfg empty default)" = default ]
[ "$(cfg missing fallback)" = fallback ]
[ "$(cfg long)" = 'first part second part third' ]
[ "$(cfg notswallowed)" = yes ]
[ "$(cfg crlf)" = dos ]
[ "$(cfg_lines long | cut -d' ' -f1-2)" = '11 13' ]

# The Python twin (kos-archive, kos-mcu-discover) must read every key the same way.
for k in $(awk -F= '/=/ && !/^#/ {gsub(/[[:space:]]/, "", $1); print $1}' "$KOS_CONF" | sort -u); do printf '%s=%s\n' "$k" "$(cfg "$k")"; done > "$T/sh.out"
for tool in kos-archive kos-mcu-discover; do
    python3 -I -B - "overlay/usr/lib/kos/$tool" "$KOS_CONF" "$T/sh.out" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("tool", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("tool", loader)); loader.exec_module(mod)
py = mod.read_conf(sys.argv[2])
for line in open(sys.argv[3]).read().splitlines():
    k, v = line.split("=", 1)
    assert py.get(k, "") == v, (sys.argv[1], k, py.get(k), v)
EOF
done

# ssh_key: several lines or one continued value; each key on its own; the typo is skipped with a warning
[ "$(ssh_keys | wc -l)" -eq 4 ]
[ "$(ssh_keys | sed -n 2p)" = "$B" ] && [ "$(ssh_keys | sed -n 3p)" = "$A" ]
KOS_KEYS=$T/keys/klipper KOS_WARNINGS=
apply_ssh_keys 2> "$T/err"
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$A" "$B" "$A")" ]
grep -q 'not a valid SSH public key, skipped: ssh-ed25519 AAAAnotbase64' "$T/err"
case $KOS_WARNINGS in *"skipped: ssh-ed25519 AAAAnotbase64"*) ;; *) exit 1 ;; esac
[ "$(printf 'command="x" %s\n' "$A" | split_keys | wc -l)" -eq 2 ]   # options are cut off into an invalid fragment

valid_label kos && valid_label my-voron-2 && ! valid_label -F/etc/passwd && ! valid_label 'kos router' && ! valid_label kos- && ! valid_label ''
! valid_label "$(printf 'a%.0s' $(seq 64))" && valid_label "$(printf 'a%.0s' $(seq 63))"
valid_dnsname printer.example.com && ! valid_dnsname 'x 1; } server {' && ! valid_dnsname '*.lan' && ! valid_dnsname a..b
valid_tz Europe/Berlin && valid_tz Etc/UTC && ! valid_tz ../../../etc/shadow && ! valid_tz /etc/passwd && ! valid_tz Europe && ! valid_tz ''

KOS_CONF=/nonexistent; [ "$(cfg hostname kos)" = kos ]
echo ok
