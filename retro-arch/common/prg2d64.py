#!/usr/bin/env python3
"""
prg2d64.py — Wrap one or more .prg files into a minimal 35-track .d64 image
so they can be loaded through the emulated 1541 (SDL sim today, RP MCU on
real hardware later).  Inverse of d64extract.py.

Layout follows the 1541 conventions: BAM at 18/0, one directory sector at
18/1 (up to 8 files), file data allocated on the tracks closest to the
directory first (17, 16, ... 1, 19 ... 35) with interleave 10 inside a
track, so real-timing GCR loads don't spend a full disk revolution per
sector.

Usage: prg2d64.py <output.d64> <input.prg> [<input2.prg> ...]
       (file name on the disk = input basename, uppercased, max 16 chars)
"""

import sys, os

# Track layout: tracks 1-17 have 21 sectors, 18-24 have 19, 25-30 have 18,
# 31-35 have 17 (same table as d64extract.py).
SECTORS_PER_TRACK = [0] + [21]*17 + [19]*7 + [18]*6 + [17]*5
TOTAL_SECTORS = sum(SECTORS_PER_TRACK)          # 683
DIR_TRACK = 18
INTERLEAVE = 10
DATA_PER_SECTOR = 254

def ts_offset(track, sector):
    off = 0
    for t in range(1, track):
        off += SECTORS_PER_TRACK[t] * 256
    return (off + sector * 256)

def petscii_name(path):
    name = os.path.splitext(os.path.basename(path))[0].upper()
    # PETSCII and ASCII agree on A-Z, 0-9 and common punctuation; replace
    # anything else so the directory entry is typeable in LOAD"name",8.
    name = ''.join(c if c.isalnum() or c in ' -+.' else '-' for c in name)
    return name[:16]

class Allocator:
    """Hand out free sectors near the directory track with interleave."""
    def __init__(self):
        self.used = set()                        # (track, sector)
        for s in range(SECTORS_PER_TRACK[DIR_TRACK]):
            pass                                 # dir track reserved lazily
        self.track_order = list(range(17, 0, -1)) + list(range(19, 36))
        self.last_sector = {}                    # per-track interleave state

    def alloc(self):
        for t in self.track_order:
            n = SECTORS_PER_TRACK[t]
            if sum(1 for s in range(n) if (t, s) in self.used) == n:
                continue
            s = (self.last_sector.get(t, -INTERLEAVE) + INTERLEAVE) % n
            for _ in range(n):
                if (t, s) not in self.used:
                    self.used.add((t, s))
                    self.last_sector[t] = s
                    return t, s
                s = (s + 1) % n
        raise SystemExit('error: disk full (664 blocks)')

def build(outfile, prgfiles):
    img = bytearray(TOTAL_SECTORS * 256)
    alloc = Allocator()
    entries = []

    if len(prgfiles) > 8:
        raise SystemExit('error: max 8 files (single directory sector)')

    for path in prgfiles:
        with open(path, 'rb') as f:
            data = f.read()
        if len(data) < 3:
            raise SystemExit(f'error: {path} is too small to be a PRG')

        # Split into 254-byte chunks and chain them.
        chunks = [data[i:i + DATA_PER_SECTOR]
                  for i in range(0, len(data), DATA_PER_SECTOR)]
        sectors = [alloc.alloc() for _ in chunks]
        for i, ((t, s), chunk) in enumerate(zip(sectors, chunks)):
            off = ts_offset(t, s)
            if i + 1 < len(sectors):
                img[off], img[off + 1] = sectors[i + 1]
            else:
                img[off] = 0
                img[off + 1] = len(chunk) + 1    # last valid byte index
            img[off + 2:off + 2 + len(chunk)] = chunk

        load = data[0] | (data[1] << 8)
        name = petscii_name(path)
        entries.append((name, sectors[0], len(sectors)))
        print(f'  {os.path.basename(path)}: {len(data) - 2} bytes at '
              f'${load:04X}, {len(sectors)} sectors -> "{name}"')

    # ── BAM (18/0) ───────────────────────────────────────────────────────
    bam_used = set(alloc.used) | {(DIR_TRACK, 0), (DIR_TRACK, 1)}
    bam = ts_offset(DIR_TRACK, 0)
    img[bam + 0], img[bam + 1] = DIR_TRACK, 1    # first directory sector
    img[bam + 2] = ord('A')                      # DOS version
    for t in range(1, 36):
        n = SECTORS_PER_TRACK[t]
        free_map = 0
        for s in range(n):
            if (t, s) not in bam_used:
                free_map |= 1 << s
        e = bam + 4 + (t - 1) * 4
        img[e] = bin(free_map).count('1')        # free sector count
        img[e + 1] = free_map & 0xFF
        img[e + 2] = (free_map >> 8) & 0xFF
        img[e + 3] = (free_map >> 16) & 0xFF
    diskname = petscii_name(outfile).encode('ascii')
    img[bam + 0x90:bam + 0xAB] = b'\xA0' * 0x1B
    img[bam + 0x90:bam + 0x90 + len(diskname)] = diskname
    img[bam + 0xA2:bam + 0xA4] = b'00'           # disk ID
    img[bam + 0xA5:bam + 0xA8] = b'\xA02A'       # DOS type

    # ── Directory (18/1) ────────────────────────────────────────────────
    d = ts_offset(DIR_TRACK, 1)
    img[d + 0], img[d + 1] = 0, 0xFF             # last directory sector
    for i, (name, (t, s), nsec) in enumerate(entries):
        e = d + 2 + i * 32
        img[e + 0] = 0x82                        # PRG, closed
        img[e + 1], img[e + 2] = t, s
        img[e + 3:e + 19] = b'\xA0' * 16
        img[e + 3:e + 3 + len(name)] = name.encode('ascii')
        img[e + 28] = nsec & 0xFF
        img[e + 29] = nsec >> 8

    with open(outfile, 'wb') as f:
        f.write(img)
    print(f'  -> {outfile} ({len(img)} bytes, '
          f'{664 - len(bam_used) + 2} blocks free)')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <output.d64> <input.prg> [...]')
        sys.exit(1)
    build(sys.argv[1], sys.argv[2:])
