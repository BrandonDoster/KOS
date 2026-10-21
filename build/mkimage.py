#!/usr/bin/env python3
"""Assemble a bootable MBR disk image without loop devices or root.

Each partition is built as its own filesystem image (mkfs.vfat+mcopy / mkfs.ext4 -d), then dd'd into a sparse
file at its offset; the MBR is written with struct. U-Boot goes at a raw offset before the first partition.

Usage: mkimage.py OUT.img --parts 'LABEL:fs:MiB ...' [--first-mib 16] [--src LABEL=DIR ...]
                  [--uboot FILE --uboot-seek-kib 8] [--bootable LABEL]
Self-test: mkimage.py --test
"""
import os, struct, subprocess, sys, tempfile

SECTOR = 512
MIB = 1 << 20
TYPES = {"vfat": 0x0C, "ext4": 0x83}


def mbr(parts, bootable=None):
    """parts: [(label, fs, start_lba, size_sectors)] -> 512-byte MBR."""
    b = bytearray(SECTOR)
    for i, (label, fs, start, size) in enumerate(parts):
        flag = 0x80 if label == bootable else 0
        # CHS fields are 0xFE 0xFF 0xFF ("use LBA"); every firmware and kernel ignores them.
        b[446 + i * 16:446 + (i + 1) * 16] = struct.pack("<B3sB3sII", flag, b"\xfe\xff\xff", TYPES[fs], b"\xfe\xff\xff", start, size)
    b[510:512] = b"\x55\xaa"
    return bytes(b)


def parse_mbr(data):
    out = []
    for i in range(4):
        flag, _, typ, _, start, size = struct.unpack("<B3sB3sII", data[446 + i * 16:446 + (i + 1) * 16])
        if typ:
            out.append((flag, typ, start, size))
    return out


def layout(spec, first_mib, total_mib=None):
    """'A:vfat:64 B:ext4:0' -> [(label, fs, start_lba, size_sectors)]; size 0 = fill to total_mib."""
    parts, start = [], first_mib * MIB // SECTOR
    items = [p.split(":") for p in spec.split()]
    for label, fs, mib in items:
        mib = int(mib)
        if mib == 0:
            assert total_mib, "fill partition needs total size"
            mib = total_mib - start * SECTOR // MIB
        size = mib * MIB // SECTOR
        parts.append((label, fs, start, size))
        start += size
    return parts


def mkfs(fs, label, src, size_bytes, out):
    if fs == "vfat":
        subprocess.run(["mkfs.vfat", "-F", "32", "-n", label, "-C", out, str(size_bytes // 1024)], check=True)
        if src and os.listdir(src):
            subprocess.run(["mcopy", "-s", "-i", out] + [os.path.join(src, f) for f in os.listdir(src)] + ["::"], check=True)
    else:
        # -T default: KOS-DATA is a 256 MB placeholder grown to the card on first boot; mke2fs would pick its "small"
        # profile (1 KiB blocks, inode every 4 KiB), which growing keeps: 1.7 GB of inode tables zeroed on a 24 GB card.
        cmd = ["mkfs.ext4", "-q", "-F", "-T", "default", "-L", label, "-E", "lazy_itable_init=0,lazy_journal_init=0"]
        if src:
            cmd += ["-d", src]
        subprocess.run(cmd + [out, str(size_bytes // 1024) + "k"], check=True)


def build(out_path, spec, first_mib, srcs, uboot=None, uboot_seek_kib=8, bootable=None, fill_mib=256):
    total_mib = first_mib + sum(int(p.split(":")[2]) for p in spec.split()) + fill_mib
    parts = layout(spec, first_mib, total_mib)
    total = (parts[-1][2] + parts[-1][3]) * SECTOR
    with open(out_path, "wb") as f:
        f.truncate(total)
        f.write(mbr(parts, bootable))
        if uboot:
            f.seek(uboot_seek_kib * 1024)
            f.write(open(uboot, "rb").read())
        for label, fs, start, size in parts:
            with tempfile.NamedTemporaryFile(suffix=".fs", delete=False) as t:
                pass
            os.unlink(t.name)   # mkfs.vfat -C refuses to overwrite an existing file
            try:
                mkfs(fs, label, srcs.get(label), size * SECTOR, t.name)
                f.seek(start * SECTOR)
                with open(t.name, "rb") as p:
                    while chunk := p.read(4 * MIB):
                        f.write(chunk)
            finally:
                if os.path.exists(t.name):
                    os.unlink(t.name)
    return parts


def test():
    parts = layout("KOS:vfat:64 KOS-ROOT:ext4:3072 KOS-DATA:ext4:0", 16, total_mib=16 + 64 + 3072 + 256)
    assert parts[0][2] == 16 * 2048 and parts[1][2] == 80 * 2048 and parts[2][3] == 256 * 2048, parts
    m = mbr(parts, bootable="KOS-ROOT")
    assert m[510:512] == b"\x55\xaa"
    back = parse_mbr(m)
    assert back == [(0, 0x0C, 32768, 131072), (0x80, 0x83, 163840, 6291456), (0, 0x83, 6455296, 524288)], back
    # partitions must be contiguous and not overlap the U-Boot area (8 KiB .. ~1 MiB)
    assert all(back[i][2] + back[i][3] == back[i + 1][2] for i in range(2))
    assert back[0][2] * SECTOR > 8 * 1024 + 1 * MIB
    print("ok")


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--parts", required=True); ap.add_argument("--first-mib", type=int, default=16)
    ap.add_argument("--src", action="append", default=[]); ap.add_argument("--uboot"); ap.add_argument("--uboot-seek-kib", type=int, default=8)
    ap.add_argument("--bootable"); ap.add_argument("--fill-mib", type=int, default=256, help="size given to the ':0' partition; grown on first boot")
    a = ap.parse_args(argv)
    srcs = dict(s.split("=", 1) for s in a.src)
    for label, fs, start, size in build(a.out, a.parts, a.first_mib, srcs, a.uboot, a.uboot_seek_kib, a.bootable, a.fill_mib):
        print(f"{label:10} {fs:5} start={start * SECTOR // MIB:6} MiB size={size * SECTOR // MIB:6} MiB")


if __name__ == "__main__":
    sys.exit(test() if "--test" in sys.argv else main(sys.argv[1:]))
