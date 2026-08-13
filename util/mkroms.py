#!/usr/bin/env python3
"""mkroms.py — build a ".roms" container for a ROM-free machine bitstream.

A ROM-free bit ships with empty ROM arrays and declares what it needs in its
own header (`roms=kernal,basic`, see bittag.py).  The MCU pushes the bytes in
after configuration, reading them from ONE flash file per platform — this
container.  See bitstreams/README.md; the MCU side is
the board firmware, keep the two formats in sync.

    mkroms.py c64.roms kernal=kernal.bin basic=basic.bin chargen=chargen.bin
    mkroms.py --list c64.roms

One file per platform rather than one per bank because the flash directory is
a single 4 KB sector of 63 entries; per-bank files would spend a fifth of it
on ROMs before a single game.  It is also atomic: a machine can never end up
holding a kernal but no chargen.

Layout, little-endian:

    0   "GCRM"
    4   u8 version (1), u8 bank_count, u16 reserved
    8   bank_count x { char name[8]; u32 offset; u32 size; u32 sum }
    ..  the bank blobs, in index order

`sum` is a plain 32-bit byte sum — the same one the flash FS uses for its own
files, so the MCU verifies a bank with code it already has.

ROM images are the user's own; nothing here ships with the project and the
output is never committed.
"""
import os
import struct
import sys

MAGIC = b"GCRM"
VERSION = 1
NAME_MAX = 8
MAX_BANKS = 8            # qspi_slave.v carries a 3-bit bank id
HDR = 8
ENTRY = 20


def sum32(data):
    return sum(data) & 0xFFFFFFFF


def build(out, banks):
    """banks = [(name, bytes)] in push order."""
    if not 1 <= len(banks) <= MAX_BANKS:
        sys.exit(f"error: {len(banks)} banks (want 1..{MAX_BANKS})")
    for name, _ in banks:
        if not name or len(name) > NAME_MAX or not name.isascii():
            sys.exit(f"error: bad bank name {name!r} (1..{NAME_MAX} ASCII)")
    seen = set()
    for name, _ in banks:
        if name.lower() in seen:
            sys.exit(f"error: duplicate bank {name!r}")
        seen.add(name.lower())

    body = HDR + ENTRY * len(banks)
    index, blobs, off = b"", b"", body
    for name, data in banks:
        if not data:
            sys.exit(f"error: bank {name!r} is empty")
        index += struct.pack("<8sIII", name.encode().ljust(NAME_MAX, b"\0"),
                             off, len(data), sum32(data))
        blobs += data
        off += len(data)

    img = (MAGIC + bytes([VERSION, len(banks), 0, 0]) + index + blobs)
    with open(out, "wb") as fh:
        fh.write(img)
    print(f"  {out}: {len(img)} bytes, {len(banks)} bank(s)")
    for name, data in banks:
        print(f"    {name:<8} {len(data):6d} B  sum={sum32(data):08x}")
    return 0


def show(path):
    with open(path, "rb") as fh:
        img = fh.read()
    if len(img) < HDR or img[:4] != MAGIC:
        sys.exit(f"error: {path} is not a .roms container")
    ver, n = img[4], img[5]
    if ver != VERSION:
        sys.exit(f"error: container version {ver}, this tool speaks {VERSION}")
    print(f"{path}: version {ver}, {n} bank(s), {len(img)} bytes")
    for i in range(n):
        name, off, size, chk = struct.unpack_from("<8sIII", img,
                                                  HDR + i * ENTRY)
        name = name.rstrip(b"\0").decode("ascii", "replace")
        blob = img[off:off + size]
        ok = "ok" if len(blob) == size and sum32(blob) == chk else "BAD"
        print(f"    {name:<8} off={off:<8} {size:6d} B  sum={chk:08x}  {ok}")
    return 0


def read_rom(path):
    """Read a ROM image: raw binary, or the one-byte-per-line hex the
    simulator's $readmemh consumes (so the same file feeds both paths)."""
    with open(path, "rb") as fh:
        data = fh.read()
    head = data[:64]
    if head and all(c in b"0123456789abcdefABCDEF \t\r\n" for c in head):
        try:
            return bytes(int(tok, 16) for tok in data.split())
        except ValueError:
            pass
    return data


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    if args[0] == "--list":
        if len(args) != 2:
            sys.exit("usage: mkroms.py --list file.roms")
        return show(args[1])

    out, specs = args[0], args[1:]
    if not specs:
        sys.exit("usage: mkroms.py out.roms name=file [name=file ...]")
    banks = []
    for spec in specs:
        if "=" not in spec:
            sys.exit(f"error: {spec!r} is not name=file")
        name, path = spec.split("=", 1)
        if not os.path.exists(path):
            sys.exit(f"error: no such ROM file: {path}")
        banks.append((name, read_rom(path)))
    return build(out, banks)


if __name__ == "__main__":
    sys.exit(main())
