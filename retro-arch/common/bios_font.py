#!/usr/bin/env python3
#
# bios_font.py — generate the BIOS-mode 9-wide text font (bios_font_{lo,hi}.hex)
#
# Base font: the classic IBM VGA 8x16 CP437 bitmap (extracted from the
# Linux kernel's lib/fonts/font_8x16.c rendering of the original IBM ROM
# font; bitmap typefaces carry no copyright in the US — same basis as the
# Ultimate Oldschool PC Font Pack), widened to 9 columns the way real VGA
# hardware does for its 720x400 9x16 text mode: column 8 duplicates
# column 7 for the line-graphics/block range (here 0xB0-0xDF), and is
# blank for text glyphs, so letters get a clean spacing column instead of
# the Bresenham stem-doubling the 8->10 stretch produced.
#
# bios_text.v shows 9 font pixels + 1 extension pixel per 10-px cell: the
# 10th column repeats column 8 for every non-ASCII glyph (boxes, blocks
# and the logo stay seamless across cells), and is background for ASCII.
#
# Logo: an "Energy Star"-style emblem is composed into 108 glyph slots
# across every CP437 range the BIOS UI never draws (see logo_glyph); the
# art is designed on the full 18x6-cell = 180x96 px canvas (10 px/cell)
# and column 9 of each cell is folded into stored column 8 (the renderer
# shows col 8 twice), so arcs and rules stay continuous.
#
# Output (one 3-hex-digit 9-bit row per line, glyph-major, bit8 = leftmost):
#   retro-arch/{c16,plus4,c64}/roms/bios_font_lo.hex   chars 0x00-0x7F
#   retro-arch/{c16,plus4,c64}/roms/bios_font_hi.hex   chars 0x80-0xFF
#
# Usage:  python3 bios_font.py                      write the .hex files
#         python3 bios_font.py --png [out.png]      logo preview image ONLY
#         python3 bios_font.py --preview            ASCII dump
#
# Logo workflow: iterate with --png (fast, display-accurate image, no
# synthesis); when the logo is final, run without flags and rebuild the
# three bitstreams (make build ARCH=c64/plus4/c16 TARGET=fpga).
#
import base64
import os
import sys

# ── IBM VGA 8x16, 256 glyphs x 16 rows (4096 bytes), CP437 order ──────────
VGA8X16_B64 = """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AAB4zMzM2MzGxsbMAAAAAAAA/sbGwMDAwMDAwAAAAAAAAAAAAP5sbGxsbGwAAAAAAAD+xmAwGBgwYMb+AAAAAAAAAAAAftjY2NjYcAAAAAAAAAAAAGZmZmZmZnxgYMAAAAAAAHbcGBgYGBgYAAAAAAAAfhg8ZmZmZjwYfgAAAAAAADhsxsb+xsbGbDgAAAAAAAA4bMbGxmxsbGzuAAAAAAAAHjAYDD5mZmZmPAAAAAAAAAAAAH7b29t+AAAAAAAAAAAAAwZ+29vzfmDAAAAAAAAAHDBgYHxgYGAwHAAAAAAAAAB8xsbGxsbGxsYAAAAAAAAAAP4AAP4AAP4AAAAAAAAAAAAYGH4YGAAAfgAAAAAAAAAwGAwGDBgwAH4AAAAAAAAADBgwYDAYDAB+AAAAAAAADhsbGBgYGBgYGBgYGBgYGBgYGBgYGBjY2NhwAAAAAAAAAAAYAH4AGAAAAAAAAAAAAAAAdtwAdtwAAAAAAAAAOGxsOAAAAAAAAAAAAAAAAAAAAAAAABgYAAAAAAAAAAAAAAAAAAAYAAAAAAAAAAAADwwMDAwM7GxsPBwAAAAAAGw2NjY2NgAAAAAAAAAAAAA8ZgwYMn4AAAAAAAAAAAAAAAAAfn5+fn5+fgAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="""

# Logo block: 20x7 characters at 10 px/cell = 200x112 px.  Styled after
# the real EPA Energy Star logo on 90s POST screens: a TRUE half circle
# whose flat side is the thick green baseline (the diameter), a handwritten
# script "fpgago" inside (the f ascender almost touching the dome), a big
# OUTLINED five-point star sitting ON the arc upper-right (the arc is
# cleared around it so their pixels never cross), and green mini-caps text
# under the baseline.  Rows 0-5 are shown yellow, row 6 green (per-cell
# attribute, the same trick the original used for "POLLUTION PREVENTER").
#
# Glyph slots: 140 glyphs (= 20x7) across EVERY CP437 range the BIOS UI
# never draws — 0x80-0xAF (48, accents), 0xE0-0xFF (32, Greek+math),
# 0x01-0x0F (15, icons), 0x11-0x17 (7), 0x1C-0x1F (4), 0xB1-0xB2 (2,
# shades), plus the unused box-drawing pieces 0xB4-0xB9 (6), 0xBD-0xBE (2),
# 0xC1-0xC3 (3), 0xC5-0xC7 (3), 0xCA-0xCC (3), 0xCE-0xCF (2), 0xD0-0xD8
# (9) and the half-blocks 0xDC-0xDF (4).  Reserved and NOT used: 0x10
# (mark), 0x18/0x19 (arrows), 0x1A/0x1B (adjust hints), 0xB0/0xDB (volume
# bar), 0xB3/0xBA/0xBF/0xC0/0xC4/0xC8/0xC9/0xCD/0xD9/0xDA (the box glyphs
# the UI draws).  logo_glyph(idx) maps a block index to its slot;
# bios_ui.c and qspi_mcu_sim.h mirror it.
LOGO_COLS = 20
LOGO_ROWS = 7
CELL_W = 10                 # canvas px per cell (col 9 folds into col 8)
LOGO_W = LOGO_COLS * CELL_W  # 200
LOGO_H = LOGO_ROWS * 16      # 112

# graphics range that gets the VGA-style column-8-duplicates-column-7
# widening (blocks, shades and box drawing; logo slots are overwritten)
GFX_LO, GFX_HI = 0xB0, 0xDF

# (base, first block index, count) — keep in sync with bios_ui.c
LOGO_SLOTS = (
    (0x80, 0, 48), (0xE0, 48, 32), (0x01, 80, 15), (0x11, 95, 7),
    (0x1C, 102, 4), (0xB1, 106, 2), (0xB4, 108, 6), (0xBD, 114, 2),
    (0xC1, 116, 3), (0xC5, 119, 3), (0xCA, 122, 3), (0xCE, 125, 2),
    (0xD0, 127, 9), (0xDC, 136, 4),
)


def logo_glyph(idx):
    for base, start, count in LOGO_SLOTS:
        if idx < start + count:
            return base + (idx - start)
    raise IndexError(idx)


# "fpgago" wordmark, 151x52 px 1-bit bitmap (rows of 19 bytes, MSB
# first).  Rendered once from Bradley Hand Bold at 50 px and baked here
# so font builds don't depend on any system font (bitmap typefaces
# carry no copyright in the US — same basis as the VGA base font).
WORDMARK_W, WORDMARK_H = 151, 52
WORDMARK_B64 = """AAB+AAAAAAAAAAAAAAAAAAAAAAAB/wAAAAAAAAAAAAAAAAAAAAAAA/+AAAAAAAAAAAAAAAAAAAAAAAP/gAAAAAAAAAAAAAAAAAAAAAAHw8AAAAAAAAAAAAAAAAAAAAAAB4PAAAAAAAAAAAAAAAAAAAAAAA8BgAAAAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAB4AAAAAAAAAAAAAAAAAAAAAAAAeAAAAAAAAAAAAAAAAAAAAAAAAHgAAAAAAAAAADgAAAAAAAAAAADwAAAAAAAAAAB/gAAAAAAAAAAA8ABgAAAD8cAA//wAA/HAAAQAAPAA+AAAB/3AAf/+AAf9wAB/AADgB/4AAB/94AP//gAf/eAAf4AA4B//wAA/neAD8H4AP53gAf/AAeA//+AAfg3gA8A8AH4N4AH3wf/////4AHwA4AOAPAB8AOAD4eP///xw/AD4AfAHgHwA+AHwB+Hz///4cH4B4AHwB4B8AeAB8AfA8f//AHgeAeAB8AeA/AHgAfAPgHABwAB4DwPAA/gPAfwDwAP4DwB4AcAAeA8DwAPwDwH4A8AD8A8AeAHAAHAHg4AH+A4D+AOAB/gOAHgDwAB4B4eAD3geB/gHgA94DgB4A8AAeAOHgB54Hg+4B4AeeB4AcAPAAHgDhwB+eB4feAcAfngcAPADwAB4A4cA/HgePngHAPx4HADwA4AAeAeHAfg4Hnx4BwH4OBwB4AOAAH4HhwfwOBz8eAcH8DgcA8ADgAB//4cPwDgf+DwHD8A4PAfAA4AAf/8H/4A4H/A8B/+AOBwfgAOAAH/+B/8AOB/APgf/ADgf/wADgAB4EAP8ADgPwDwD/AA4H/wAA4AAeAAB8AA4AwAYAfAAOA/4AAOAAHAAAAAAOAAAAAAAADgHwAADgABwAAAAAHgAAAAAAAB4AAAAA8AA8AAAAAB4AAAAAAAAeAAAAAPAAHAAAAAAcAAAAAAAAHAAAAADwABwAAAAAPAAAAAAAADwAAAAA8AAcAAAAADwAAAAAAAA8AAAAAPAAHAAAfAB4AAAAAHwAeAAAAAB4ABwAAHwA+AAAAAB8APgAAAAAcAAcAAB+A/AAAAAAfgPwAAAAAHgAHAAAP//gAAAAAD//4AAAAAB4ABwAAA//wAAAAAAP/8AAAAAAOAA8AAAD/wAAAAAAA/8AAAAAADAAPAAAAAAAAAAAAAAAAAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAA4AAAAAAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAAAAAAAAAAAA=="""

# 3x5 mini caps for the green line, shown 2x (only the letters it needs)
MINI35 = {
    'A': ["010", "101", "111", "101", "101"],
    'C': ["011", "100", "100", "100", "011"],
    'D': ["110", "101", "101", "101", "110"],
    'E': ["111", "100", "110", "100", "111"],
    'F': ["111", "100", "110", "100", "100"],
    'I': ["111", "010", "010", "010", "111"],
    'L': ["100", "100", "100", "100", "111"],
    'M': ["101", "111", "111", "101", "101"],
    'N': ["110", "101", "101", "101", "101"],
    'O': ["010", "101", "101", "101", "010"],
    'P': ["110", "101", "110", "100", "100"],
    'R': ["110", "101", "110", "101", "101"],
    'T': ["111", "010", "010", "010", "010"],
    'U': ["101", "101", "101", "101", "111"],
    ' ': ["000", "000", "000", "000", "000"],
}


def build_logo(font):
    """Return a LOGO_H x LOGO_W bitmap (list of lists of 0/1)."""
    import math
    px = [[0] * LOGO_W for _ in range(LOGO_H)]

    def dot(x, y, v=1):
        if 0 <= x < LOGO_W and 0 <= y < LOGO_H:
            px[y][x] = v

    # dome: a TRUE half circle whose diameter is the green baseline
    cx, cy, R = 100, 96, 94

    # star centred ON the arc at 45°, like the original Energy Star
    ang = math.radians(45.0)
    scx = cx + R * math.cos(ang)
    scy = cy - R * math.sin(ang)
    r1, r2 = 24.0, 24.0 * 0.42
    pts = []
    for i in range(10):
        a = math.radians(-90 + i * 36)
        r = r1 if i % 2 == 0 else r2
        pts.append((scx + r * math.cos(a), scy + r * math.sin(a)))

    def inside(x, y, grow=0.0):         # ray casting, star polygon;
        gx = scx + (x - scx) * (1 - grow / r1) if grow else x   # grow>0
        gy = scy + (y - scy) * (1 - grow / r1) if grow else y   # = halo
        c = False
        for i in range(10):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % 10]
            if (y1 > gy) != (y2 > gy) and \
               gx < (x2 - x1) * (gy - y1) / (y2 - y1) + x1:
                c = not c
        return c

    # ── the arc, 3 px thick, skipping a halo around the star so their
    #    pixels never cross (the star replaces that stretch of the arc).
    #    The left side STOPS at ARC_STOP°: from there the same pen stroke
    #    curls into the f (drawn below, after the wordmark is placed) ──
    ARC_STOP = 1600                     # tenths of a degree
    for deg in range(0, ARC_STOP + 1):
        a = math.radians(deg / 10.0)
        for r in (R, R - 1, R - 2):
            x = cx + r * math.cos(a)
            y = cy - r * math.sin(a)
            if y < cy and not inside(x, y, grow=3.0):
                dot(int(round(x)), int(round(y)))

    # ── star outline, ~2 px thick ──
    for i in range(10):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % 10]
        steps = int(max(abs(x2 - x1), abs(y2 - y1)) * 3) + 1
        for s in range(steps + 1):
            x = x1 + (x2 - x1) * s / steps
            y = y1 + (y2 - y1) * s / steps
            dot(int(round(x)), int(round(y)))
            dot(int(round(x + 0.6)), int(round(y + 0.6)))

    # ── handwritten "fpgago" (baked Bradley Hand bitmap) ──
    wm = base64.b64decode(WORDMARK_B64)
    stride = (WORDMARK_W + 7) // 8

    def wmbit(x, y):
        return wm[y * stride + x // 8] & (0x80 >> (x % 8))

    wx, wy = 25, 38
    for y in range(WORDMARK_H):
        for x in range(WORDMARK_W):
            if wmbit(x, y):
                dot(wx + x, wy + y)

    # ── handwriting stroke: the dome's left side continues past ARC_STOP,
    #    curls before the baseline and draws the f from the bottom up (one
    #    continuous pen movement, like the original logo).  Cubic Bezier:
    #    leaves the arc end tangentially, bottoms out, arrives at the f's
    #    stem bottom (= bottommost pixel of the wordmark's first columns)
    #    heading up into the stem. ──
    fbot = None
    for y in range(WORDMARK_H - 1, -1, -1):
        for x in range(20):
            if wmbit(x, y):
                fbot = (wx + x, wy + y)
                break
        if fbot:
            break
    a0 = math.radians(ARC_STOP / 10.0)
    p0 = (cx + (R - 1) * math.cos(a0), cy - (R - 1) * math.sin(a0))
    tan = (-math.sin(a0), -math.cos(a0))          # arc tangent, downward
    c1 = (p0[0] + 17 * tan[0], p0[1] + 17 * tan[1])
    c2 = (fbot[0] - 8, fbot[1] + 11)              # arrive climbing right
    for s in range(81):
        t = s / 80.0
        u = 1 - t
        x = (u ** 3 * p0[0] + 3 * u * u * t * c1[0]
             + 3 * u * t * t * c2[0] + t ** 3 * fbot[0])
        y = (u ** 3 * p0[1] + 3 * u * u * t * c1[1]
             + 3 * u * t * t * c2[1] + t ** 3 * fbot[1])
        dot(int(round(x)), int(round(y)))
        dot(int(round(x + 1)), int(round(y)))
        dot(int(round(x)), int(round(y + 1)))

    # ── green row (char row 6, y 96..111): the diameter rule + caption ──
    for y in range(96, 101):
        for x in range(cx - R, cx + R + 1):
            dot(x, y)
    label = "EDUCATIONAL PLATFORM"
    lw = len(label) * 8 - 2             # 2x glyphs, 8-px pitch
    lx, ly = (LOGO_W - lw) // 2, 102
    for i, ch in enumerate(label):
        rows = MINI35.get(ch, MINI35[' '])
        for r in range(5):
            for c in range(3):
                if rows[r][c] == '1':
                    for dy in (0, 1):
                        for dx in (0, 1):
                            dot(lx + i * 8 + 2 * c + dx, ly + 2 * r + dy)

    return px


def render_png(font9, path):
    """Display-accurate logo image: 10-px cells with the col-8 extension,
    16->19 line stretch, yellow/green rows on the BIOS blue, 3x upscaled.
    This is the fast iteration loop — tweak build_logo(), re-run with
    --png, look at the image; only synthesize bitstreams when it's final."""
    lut = (0, 1, 2, 2, 3, 4, 5, 6, 7, 7, 8, 9, 10, 11, 12, 12, 13, 14, 15)
    yel, grn, blu = (255, 255, 84), (84, 255, 84), (0, 0, 168)
    w, h = LOGO_COLS * 10, LOGO_ROWS * 19
    pix = [[blu] * w for _ in range(h)]
    for gy in range(LOGO_ROWS):
        col = grn if gy == LOGO_ROWS - 1 else yel
        for gx in range(LOGO_COLS):
            g = logo_glyph(gy * LOGO_COLS + gx)
            for l in range(19):
                row = font9[g * 16 + lut[l]]
                for p in range(10):
                    bit = (row >> (8 - p)) & 1 if p <= 8 else row & 1
                    if bit:
                        pix[gy * 19 + l][gx * 10 + p] = col
    try:
        from PIL import Image
        img = Image.new("RGB", (w, h))
        for y in range(h):
            for x in range(w):
                img.putpixel((x, y), pix[y][x])
        img.resize((w * 3, h * 3), Image.NEAREST).save(path)
    except ImportError:                  # no PIL: plain PPM, 3x
        if not path.endswith(".ppm"):
            path += ".ppm"
        with open(path, "w") as f:
            f.write(f"P3\n{w * 3} {h * 3}\n255\n")
            for y in range(h * 3):
                for x in range(w * 3):
                    f.write("%d %d %d\n" % pix[y // 3][x // 3])
    print(f"wrote {path}")


def widen(font):
    """8-bit rows -> 9-bit rows (VGA line-graphics widening)."""
    out = [0] * 4096
    for g in range(256):
        for r in range(16):
            row = font[g * 16 + r]
            row9 = row << 1
            if GFX_LO <= g <= GFX_HI:
                row9 |= row & 1          # col 8 = col 7
            out[g * 16 + r] = row9
    return out


def patch_logo(font8, font9):
    px = build_logo(font8)
    for gy in range(LOGO_ROWS):
        for gx in range(LOGO_COLS):
            g = logo_glyph(gy * LOGO_COLS + gx)
            for r in range(16):
                b = 0
                for c in range(9):
                    v = px[gy * 16 + r][gx * CELL_W + c]
                    if c == 8:           # col 9 folds into col 8 (the
                        v |= px[gy * 16 + r][gx * CELL_W + 9]  # renderer
                    if v:                # shows col 8 twice for the logo)
                        b |= 0x100 >> c
                font9[g * 16 + r] = b


def preview(font8, font9):
    px = build_logo(font8)
    print(f"logo ({LOGO_COLS}x{LOGO_ROWS} chars = {LOGO_W}x{LOGO_H} px; "
          "row 5 = green):")
    for row in px:
        print(''.join('#' if v else '.' for v in row))
    print("\nsample glyphs (9 wide):")
    for g, label in ((0x41, "A"), (0xC9, "double-corner"), (0xB1, "shade")):
        print(f"  0x{g:02X} '{label}':")
        for r in range(16):
            row = font9[g * 16 + r]
            print("    " + ''.join('#' if row & (0x100 >> i) else '.'
                                   for i in range(9)))


def main():
    font8 = bytearray(base64.b64decode(VGA8X16_B64))
    assert len(font8) == 4096
    font9 = widen(font8)
    patch_logo(font8, font9)

    if "--preview" in sys.argv:
        preview(font8, font9)
        return
    if "--png" in sys.argv:              # logo-iteration mode: image only
        i = sys.argv.index("--png")
        out = sys.argv[i + 1] if i + 1 < len(sys.argv) else "/tmp/fpgago-logo.png"
        render_png(font9, out)
        return

    here = os.path.dirname(os.path.abspath(__file__))
    dirs = [os.path.join(here, "..", arch, "roms")
            for arch in ("c16", "plus4", "c64")]
    for d in dirs:
        for name, lo, hi in (("bios_font_lo.hex", 0, 2048),
                             ("bios_font_hi.hex", 2048, 4096)):
            path = os.path.join(d, name)
            with open(path, "w") as f:
                for v in font9[lo:hi]:
                    f.write(f"{v:03x}\n")
            print(f"wrote {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
