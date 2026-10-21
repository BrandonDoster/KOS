#!/bin/sh
# Self-check for build/bump-pins.sh --check, the gate in front of every ". pins.env": the committed file passes, and a
# value that is not exactly its key's shape (a second line, shell code, a CR, an unknown key) fails.
set -eu
cd "$(dirname "$0")/.."
sh build/bump-pins.sh --check build/pins.env
T=$(mktemp -d)
bad() {
    sed "$1" build/pins.env > "$T/pins.env"
    if sh build/bump-pins.sh --check "$T/pins.env" 2>/dev/null; then echo "FAIL: accepted: $1"; exit 1; fi
}
bad 's/^PIP_UVLOOP_VERSION=.*/PIP_UVLOOP_VERSION=$(id>\/tmp\/pwned)/'
bad 's/^PIP_MSGSPEC_VERSION=.*/PIP_MSGSPEC_VERSION=1.0\
id/'
bad 's/^KLIPPER_COMMIT=\(.*\)/KLIPPER_COMMIT=\1 ;id/'
bad 's/^DEBIAN_IMAGE=\(.*\)/DEBIAN_IMAGE=\1'"$(printf '\r')"'/'
bad 's/^MAINSAIL_VERSION=.*/MAINSAIL_VERSION=v2.19.0`id`/'
bad '$a\
PATH=/tmp'
echo ok
