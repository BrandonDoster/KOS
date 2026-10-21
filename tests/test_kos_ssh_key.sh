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

[ "$(k list | wc -l)" -eq 2 ] && k list | grep -q '^2  256 SHA256:.* key-b (ED25519)$'
k add "$C" > /dev/null
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$A" "$B" "$C")" ]                      # active at once
! k add "$C" 2>/dev/null                                                           # duplicate
! k add "ssh-ed25519 AAAAbroken" 2>/dev/null && ! k add "$A $B" 2>/dev/null && ! k add 'command="sh" '"$C" 2>/dev/null
k remove key-a > /dev/null                                                         # by comment
[ "$(cat "$KOS_KEYS")" = "$(printf '%s\n' "$B" "$C")" ]
k remove 1 > /dev/null                                                             # by number
[ "$(cat "$KOS_KEYS")" = "$C" ]
! k remove nosuchkey 2>/dev/null
[ "$(grep -c '^ssh_key=' "$KOS_CONF")" -eq 1 ] && grep -qx 'hostname=kos' "$KOS_CONF" && grep -qx 'timezone=Etc/UTC' "$KOS_CONF"
grep -qx '# ssh_key=ssh-ed25519 AAAA... example' "$KOS_CONF" && grep -qx '# my printer' "$KOS_CONF"   # comments stay
k remove key-c 2>&1 >/dev/null | grep -q 'SSH login is off'
[ ! -s "$KOS_KEYS" ] && ! grep -q '^ssh_key=' "$KOS_CONF"
echo ok
