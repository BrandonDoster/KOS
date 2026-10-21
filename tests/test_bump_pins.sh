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
# The bump itself, against stub git/curl in a copy of build/: every pin moves, a second run changes nothing, and an
# upstream answer of the wrong shape stops the run with pins.env untouched.
mkdir -p "$T/repo/build" "$T/bin"
cp build/bump-pins.sh build/pins.env "$T/repo/build/"
cat > "$T/bin/git" <<EOF
#!/bin/sh
cat "$T/head"; printf '\trefs/heads/master\n'
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
out=; prev=; for a; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
case $url in
*/releases/latest) printf 'https://github.com/mainsail-crew/mainsail/releases/tag/v9.8.7' ;;
*/mainsail.zip) printf 'zip' > "$out" ;;
*pypi.org/pypi/*) printf '{"info": {"version": "3.2.1"}}\n' ;;
*auth.docker.io*) printf '{"token": "t"}\n' ;;
*registry-1.docker.io*) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%064d\r\n\r\n' 7 ;;
*) echo "unexpected curl $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/git" "$T/bin/curl"
bump() { PATH=$T/bin:$PATH sh "$T/repo/build/bump-pins.sh"; }
printf '%040d' 1 > "$T/head"
bump > "$T/out"
[ "$(grep -c ' -> ' "$T/out")" -eq 8 ]
P=$T/repo/build/pins.env Z=$(printf zip | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
grep -qx "KLIPPER_COMMIT=$(printf '%040d' 1)" "$P" && grep -qx 'MAINSAIL_VERSION=v9.8.7' "$P" && grep -qx "MAINSAIL_ZIP_SHA256=$Z" "$P" || exit 1
grep -qx 'PIP_UVLOOP_VERSION=3.2.1' "$P" && grep -qx "DEBIAN_IMAGE=debian:trixie@sha256:$(printf '%064d' 7)" "$P" || exit 1
[ "$(grep -c '^#' "$P")" -eq "$(grep -c '^#' build/pins.env)" ] || exit 1   # comments kept
cp "$P" "$T/before"
[ "$(bump)" = "pins unchanged" ] && cmp -s "$P" "$T/before" || exit 1
printf '%s' 'abc;id' > "$T/head"
if bump > /dev/null 2>&1; then echo "FAIL: accepted a bad upstream commit"; exit 1; fi
cmp -s "$P" "$T/before"
echo ok
