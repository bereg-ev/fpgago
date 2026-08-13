#!/usr/bin/env python3
"""
d64togcr.py — build the fabric-1541 PSRAM image from a .d64
(c64/README.md; layout = drive_psram.v's map, encoding = the
reference floppy1541.c sector layout the RTL was verified against).

  python3 d64togcr.py <disk.d64> <rom_1541.bin> <out.bin>
      one flat 512 KiB image = loader bank 7 (the current bitstream)
  python3 d64togcr.py <disk.d64> <rom_1541.bin> <out_a.bin> <out_b.bin>
      the legacy split into loader banks 3 + 4 (pre-fdbank=7 bitstreams)

Chunk A (256 KiB, loader bank 3 → PSRAM 0x200000):
  0x00000  16 KiB DOS ROM
  0x04000  pad
  0x10000  GCR tracks 1..24, one 8 KiB slot each (sector-major, 363 B/sector:
           5xFF sync | 10 hdr | 9x55 | 5xFF | 325 data | 9x55; gap fill 0x55)
Chunk B (256 KiB, loader bank 4 → PSRAM 0x240000):
  0x00000  GCR tracks 25..35, then pad

Simulation:  ./obj_dir/Vsoc --qspi --rom-bin 7:out.bin ...
The MCU mount path (phase 5) produces the same image at mount time.
"""

import sys

SPT = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
GCR_TAB = [0x0A, 0x0B, 0x12, 0x13, 0x0E, 0x0F, 0x16, 0x17,
           0x09, 0x19, 0x1A, 0x1B, 0x0D, 0x1D, 0x1E, 0x15]
SLOT = 8192
SECTOR_LEN = 363


def d64_offset(track, sector):
    off = 0
    for t in range(1, track):
        off += SPT[t]
    return (off + sector) * 256


def encode_group(src):
    g = []
    for b in src:
        g.append(GCR_TAB[b >> 4])
        g.append(GCR_TAB[b & 0x0F])
    return bytes([
        ((g[0] << 3) | (g[1] >> 2)) & 0xFF,
        ((g[1] << 6) | (g[2] << 1) | (g[3] >> 4)) & 0xFF,
        ((g[3] << 4) | (g[4] >> 1)) & 0xFF,
        ((g[4] << 7) | (g[5] << 2) | (g[6] >> 3)) & 0xFF,
        ((g[6] << 5) | g[7]) & 0xFF,
    ])


def encode_track(d64, track, id1, id2):
    out = bytearray()
    for s in range(SPT[track]):
        data = d64[d64_offset(track, s):d64_offset(track, s) + 256]
        out += b"\xFF" * 5
        hdr = bytes([0x08, s ^ track ^ id2 ^ id1, s, track, id2, id1,
                     0x0F, 0x0F])
        out += encode_group(hdr[:4]) + encode_group(hdr[4:])
        out += b"\x55" * 9
        out += b"\xFF" * 5
        xs = 0
        for b in data:
            xs ^= b
        dblk = bytes([0x07]) + data + bytes([xs, 0, 0])
        for i in range(65):
            out += encode_group(dblk[i * 4:i * 4 + 4])
        out += b"\x55" * 9
    assert len(out) == SPT[track] * SECTOR_LEN
    return out.ljust(SLOT, b"\x55")


def build(d64, rom):
    """The whole PSRAM image as one flat 512 KiB block (loader bank 7)."""
    bam = d64[d64_offset(18, 0):d64_offset(18, 0) + 256]
    id1, id2 = bam[0xA2], bam[0xA3]
    img = bytearray(rom) + b"\x00" * (0x10000 - 0x4000)
    for t in range(1, 36):
        img += encode_track(d64, t, id1, id2)
    return img.ljust(0x80000, b"\x00"), id1, id2


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    d64 = open(sys.argv[1], "rb").read()
    rom = open(sys.argv[2], "rb").read()
    if len(rom) != 16384:
        sys.exit("ROM must be exactly 16 KiB")
    img, id1, id2 = build(d64, rom)

    if len(sys.argv) == 4:                      # one bank-7 image
        open(sys.argv[3], "wb").write(bytes(img))
        print("wrote %s, 512 KiB (disk ID %c%c)" % (sys.argv[3], id1, id2))
        return
    # legacy split: banks 3 + 4, for a pre-fdbank=7 bitstream
    open(sys.argv[3], "wb").write(bytes(img[:0x40000]))
    open(sys.argv[4], "wb").write(bytes(img[0x40000:0x80000]))
    print("wrote %s + %s (disk ID %c%c)" %
          (sys.argv[3], sys.argv[4], id1, id2))


if __name__ == "__main__":
    main()
