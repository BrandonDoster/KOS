#!/bin/sh
# Lint: shellcheck (with .shellcheckrc) on every shell file, and actionlint on the workflows, from pinned images. Needs Docker.
set -eu
cd "$(dirname "$0")/.."
SHELLCHECK=koalaman/shellcheck@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d   # v0.11.0
ACTIONLINT=rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667     # 1.7.12
sc() { docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$SHELLCHECK" -S warning "$@"; }

# Sourced files have no shebang: name the shell that sources them. lib.sh and profile.d run under dash too.
SOURCED_BASH="build/boards/cb1/board.sh build/boards/cb1/customize.sh build/boards/cm5/board.sh build/boards/cm5/customize.sh"
SOURCED_DASH="overlay/usr/lib/kos/lib.sh overlay/etc/profile.d/kos-trash.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git ls-files -co --exclude-standard | while IFS= read -r f; do
    [ -f "$f" ] && head -n 1 "$f" | grep -qE '^#!.*/(env )?(ba|da)?sh( |$)' && echo "$f"
done > "$T/scripts"
# A new *.sh without a shebang must be added to one of the lists above, or it would go unchecked.
git ls-files -co --exclude-standard '*.sh' | grep -vxF -f "$T/scripts" | while IFS= read -r f; do
    case " $SOURCED_BASH $SOURCED_DASH " in *" $f "*) ;; *) echo "lint: $f has no shebang: add it to SOURCED_* in $0" >&2; exit 1 ;; esac
done
# SC2034: board.sh and pins variables are read by the script that sources them.
# SC1090: "L=/usr/lib/kos/lib.sh; [ -f "$L" ] || L=..." is deliberate; .shellcheckrc follows the constant ones.
# shellcheck disable=SC2046
sc -e SC2034,SC1090 $(cat "$T/scripts")
# shellcheck disable=SC2086
sc -e SC2034 -s bash $SOURCED_BASH
# shellcheck disable=SC2086
sc -s dash $SOURCED_DASH
echo "shellcheck ok"
docker run --rm -v "$PWD:/repo:ro" -w /repo "$ACTIONLINT" -no-color -oneline
echo "actionlint ok"
