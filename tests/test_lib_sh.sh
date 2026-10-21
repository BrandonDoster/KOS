#!/bin/bash
# Self-check for overlay/usr/lib/kos/lib.sh cfg parser.
set -eu
cd "$(dirname "$0")/.."
KOS_CONF=$(mktemp)
cat > "$KOS_CONF" <<'EOF'
# comment
hostname = voron
  timezone=America/Chicago   # inline comment
wifi_pass="p4ss w0rd$"
ssh_key=ssh-ed25519 AAAA== me@laptop
empty=
hostname=voron2
EOF
. overlay/usr/lib/kos/lib.sh
[ "$(cfg hostname)" = voron2 ]
[ "$(cfg timezone)" = America/Chicago ]
[ "$(cfg wifi_pass)" = 'p4ss w0rd$' ]
[ "$(cfg ssh_key)" = 'ssh-ed25519 AAAA== me@laptop' ]
[ "$(cfg empty default)" = default ]
[ "$(cfg missing fallback)" = fallback ]
KOS_CONF=/nonexistent; [ "$(cfg hostname kos)" = kos ]
echo ok
