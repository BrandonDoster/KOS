#!/bin/sh
# Self-check for build/boards/cb1/pgp-fpr.py: the committed Armbian key passes; a keyring that sqv would read as more
# than that one key (secret key packets, a second primary, a second armor block) fails.
set -eu
cd "$(dirname "$0")/.."
. build/boards/cb1/board.sh
F=build/boards/cb1/pgp-fpr.py K=build/boards/cb1/armbian.asc
python3 -I "$F" "$K" "$BOARD_APT_KEY_FPR"
T=$(mktemp -d)
python3 -I - "$K" "$T" <<'EOF'
import base64, sys
src, out = sys.argv[1], sys.argv[2]
text = open(src).read()
body = text.split("-----BEGIN PGP PUBLIC KEY BLOCK-----")[1].split("-----END PGP PUBLIC KEY BLOCK-----")[0]
data = base64.b64decode("".join(ln for ln in body.split("\n")[1:] if ln and not ln.startswith("=") and ":" not in ln))
first = data[:3 + int.from_bytes(data[1:3], "big")] if data[0] == 0x99 else None   # old-format tag 6, 2-byte length
assert first, "armbian.asc no longer starts with an old-format public key packet; adjust this test"
def armor(d, kind="PUBLIC KEY"):
    b = base64.b64encode(d).decode()
    return f"-----BEGIN PGP {kind} BLOCK-----\n\n" + "\n".join(b[i:i + 64] for i in range(0, len(b), 64)) + f"\n-----END PGP {kind} BLOCK-----\n"
fake = lambda tag: bytes([0xC0 | tag, 4]) + b"\x04abc"   # new-format packet, 4-byte body
open(f"{out}/secret-key.asc", "w").write(armor(data + fake(5)))
open(f"{out}/secret-subkey.asc", "w").write(armor(data + fake(7)))
open(f"{out}/second-primary.asc", "w").write(armor(data + first))
open(f"{out}/literal-data.asc", "w").write(armor(data + fake(11)))
open(f"{out}/private-block.asc", "w").write(text + armor(fake(5), "PRIVATE KEY"))
open(f"{out}/two-blocks.asc", "w").write(text + text)
EOF
for f in "$T"/*.asc; do
    if python3 -I "$F" "$f" "$BOARD_APT_KEY_FPR" 2>/dev/null; then echo "FAIL: accepted $(basename "$f")"; exit 1; fi
done
echo ok
