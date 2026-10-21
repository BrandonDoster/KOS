#!/bin/bash
# Self-check for overlay/usr/lib/kos/kos-ssh-key against a temp kos.conf and key file.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
export KOS_CONF=$T/kos.conf KOS_KEYS=$T/keys/klipper
for n in a b c; do ssh-keygen -q -t ed25519 -N '' -C "key-$n" -f "$T/$n"; done
A=$(cat "$T/a.pub"); B=$(cat "$T/b.pub"); C=$(cat "$T/c.pub")
printf '%s\n' '# my printer' 'hostname=kos' "ssh_key=$A \\" "   $B" '# ssh_key=ssh-ed25519 AAAA... example' 'timezone=Etc/UTC' > "$KOS_CONF"
k() { bash overlay/usr/lib/kos/kos-ssh-key "$@"; }

[ "$(k list | wc -l)" -eq 2 ] && k list | grep -q '^2  256 SHA256:.* key-b (ED25519)$' || exit 1
k add "$C" > /dev/null
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$A" "$B" "$C")" ]                      # active at once
! k add "$C" 2>/dev/null || exit 1                                                # duplicate
! k add "ssh-ed25519 AAAAbroken" 2>/dev/null && ! k add "$A $B" 2>/dev/null && ! k add 'command="sh" '"$C" 2>/dev/null || exit 1
k remove key-a > /dev/null                                                         # by comment
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$B" "$C")" ]
k remove 1 > /dev/null                                                             # by number
[ "$(cat "$KOS_KEYS")" = "$C" ]
! k remove nosuchkey 2>/dev/null || exit 1
[ "$(grep -c '^ssh_key=' "$KOS_CONF")" -eq 1 ] && grep -qx 'hostname=kos' "$KOS_CONF" && grep -qx 'timezone=Etc/UTC' "$KOS_CONF" || exit 1
grep -qx '# ssh_key=ssh-ed25519 AAAA... example' "$KOS_CONF" && grep -qx '# my printer' "$KOS_CONF" || exit 1   # comments stay
k remove key-c 2>&1 >/dev/null | grep -q 'SSH login is off'
[ ! -s "$KOS_KEYS" ] && ! grep -q '^ssh_key=' "$KOS_CONF" || exit 1

# Options and certificates are refused, and an entry with them is kept as written, not split into a bare key.
ssh-keygen -q -s "$T/c" -I id -n klipper "$T/a.pub"
! k add "$(cat "$T/a-cert.pub")" 2>/dev/null && ! k add 'restrict,command="true" '"$(cat "$T/a-cert.pub")" 2>/dev/null || exit 1
printf '%s\n' 'hostname=kos' "ssh_key=from=\"10.0.0.5\" $A" "ssh_key=$B" > "$KOS_CONF"
k list | grep -q "^1  NOT SUPPORTED" && k remove key-b > /dev/null 2>&1 || exit 1
[ ! -s "$KOS_KEYS" ] && grep -qxF "ssh_key=from=\"10.0.0.5\" $A" "$KOS_CONF" || exit 1
# A last line ending in '\' does not swallow the key added after it, and the password stays what it was.
printf '%s\n' 'hostname=kos' "ssh_key=$A" 'password=hunter2\' > "$KOS_CONF"
. overlay/usr/lib/kos/lib.sh
k add "$B" > /dev/null
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$A" "$B")" ] && [ "$(cfg password)" = hunter2 ] || exit 1
echo ok
