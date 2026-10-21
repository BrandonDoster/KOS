#!/usr/bin/env python3
"""pgp-fpr.py KEYFILE FINGERPRINT: exit 0 only if the ASCII-armored KEYFILE is one public key block holding exactly one
primary key, an OpenPGP v4 key with that fingerprint (RFC 4880 12.2: SHA-1 over 0x99, a 2-byte length and the
public-key packet). Subkeys are allowed: apt only accepts those the primary key has signed. Used by customize.sh and
tests/test_pgp_fpr.sh; no gpg needed.
"""
import base64, hashlib, sys


def packets(data):
    """(tag, body) for each OpenPGP packet."""
    i = 0
    while i < len(data):
        h = data[i]; i += 1
        if not h & 0x80:
            raise ValueError("not an OpenPGP packet")
        if h & 0x40:   # new format
            tag, n = h & 0x3F, data[i]; i += 1
            if 192 <= n < 224:
                n = ((n - 192) << 8) + data[i] + 192; i += 1
            elif n == 255:
                n = int.from_bytes(data[i:i + 4], "big"); i += 4
            elif n >= 224:
                raise ValueError("partial body lengths are not used in keys")
        else:          # old format
            tag, size = (h >> 2) & 0x0F, [1, 2, 4][h & 3]
            n = int.from_bytes(data[i:i + size], "big"); i += size
        yield tag, data[i:i + n]; i += n


def primary_fingerprints(armored):
    """Fingerprints of the primary keys in the one public key block. Anything else sqv could also read as a key
    (secret key packets, a second armor block, packets that do not belong in a public key) is an error."""
    if armored.count("-----BEGIN PGP") != 1 or "-----BEGIN PGP PUBLIC KEY BLOCK-----" not in armored:
        raise ValueError("expected exactly one armor block, a PGP PUBLIC KEY BLOCK")
    block = armored.split("-----BEGIN PGP PUBLIC KEY BLOCK-----")[1]
    lines = block.split("-----END PGP PUBLIC KEY BLOCK-----")[0].strip("\n").split("\n")
    while lines and ":" in lines[0]:   # armor headers (Version: ...), then a blank line
        lines.pop(0)
    data = base64.b64decode("".join(ln.strip() for ln in lines if ln.strip() and not ln.startswith("=")))
    out = []
    for n, (tag, pkt) in enumerate(packets(data)):
        # public key, signature, user id, user attribute, public subkey; a key starts with its primary
        if tag not in (6, 2, 13, 17, 14) or (n == 0) != (tag == 6):
            raise ValueError(f"packet {n} has tag {tag}: not part of a single public key")
        if tag == 6:
            if pkt[0] != 4:
                raise ValueError(f"key version {pkt[0]}, expected 4")
            out.append(hashlib.sha1(b"\x99" + len(pkt).to_bytes(2, "big") + pkt).hexdigest().upper())
    return out


if __name__ == "__main__":
    path, want = sys.argv[1], sys.argv[2].replace(" ", "").upper()
    try:
        got = primary_fingerprints(open(path).read().replace("\r\n", "\n"))
    except ValueError as e:
        sys.exit(f"{path}: {e}")
    if got != [want]:
        sys.exit(f"{path}: primary key fingerprints {got}, expected exactly [{want}]")
    print(f"{path}: {want} ok")
