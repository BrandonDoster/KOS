#!/bin/sh
# Point build/pins.env at the latest upstream: Klipper/Moonraker/mainsail-config master, the latest Mainsail
# release (zip hashed here), msgspec/uvloop from PyPI, and the current debian:trixie digest.
# Prints what moved; leaves the file untouched (exit 0) when nothing did. Needs curl, git, python3.
set -eu
cd "$(dirname "$0")/.."
PINS=build/pins.env
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# every value is checked against its shape before it goes near the file
check() { printf '%s' "$2" | grep -Eqx "$3" || { echo "bump-pins: bad $1: '$2'" >&2; exit 1; }; printf '%s' "$2"; }
head_of() { git ls-remote "https://github.com/$1" refs/heads/master | cut -f1; }
pypi() { curl -fsSL "https://pypi.org/pypi/$1/json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])'; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

SHA='[0-9a-f]{40}'
KLIPPER_COMMIT=$(check klipper "$(head_of Klipper3d/klipper)" "$SHA")
MOONRAKER_COMMIT=$(check moonraker "$(head_of Arksine/moonraker)" "$SHA")
MAINSAIL_CONFIG_COMMIT=$(check mainsail-config "$(head_of mainsail-crew/mainsail-config)" "$SHA")
# releases/latest redirects to .../tag/<tag>
url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/mainsail-crew/mainsail/releases/latest)
MAINSAIL_VERSION=$(check mainsail "${url##*/}" 'v[0-9]+(\.[0-9]+)+')
curl -fsSL -o "$T/mainsail.zip" "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_VERSION/mainsail.zip"
MAINSAIL_ZIP_SHA256=$(check mainsail.zip "$(sha256 "$T/mainsail.zip")" '[0-9a-f]{64}')
PIP_MSGSPEC_VERSION=$(check msgspec "$(pypi msgspec)" '[0-9]+(\.[0-9]+)+')
PIP_UVLOOP_VERSION=$(check uvloop "$(pypi uvloop)" '[0-9]+(\.[0-9]+)+')
# Docker Hub: anonymous pull token, then HEAD the manifest list for its digest
tok=$(curl -fsSL 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull' |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])')
digest=$(curl -fsSI -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    https://registry-1.docker.io/v2/library/debian/manifests/trixie | tr -d '\r' |
    grep -i '^docker-content-digest:' | cut -d' ' -f2)
DEBIAN_IMAGE=debian:trixie@$(check debian:trixie "$digest" 'sha256:[0-9a-f]{64}')

cp "$PINS" "$T/new"
for k in KLIPPER_COMMIT MOONRAKER_COMMIT MAINSAIL_CONFIG_COMMIT MAINSAIL_VERSION MAINSAIL_ZIP_SHA256 \
         PIP_MSGSPEC_VERSION PIP_UVLOOP_VERSION DEBIAN_IMAGE; do
    eval "v=\$$k"
    grep -q "^$k=" "$T/new" || { echo "bump-pins: $k missing from $PINS" >&2; exit 1; }
    old=$(sed -n "s/^$k=//p" "$T/new")
    [ "$old" = "$v" ] && continue
    echo "$k: $old -> $v"
    sed "s|^$k=.*|$k=$v|" "$T/new" > "$T/tmp" && mv "$T/tmp" "$T/new"
done
if cmp -s "$PINS" "$T/new"; then echo "pins unchanged"; else cat "$T/new" > "$PINS"; fi
