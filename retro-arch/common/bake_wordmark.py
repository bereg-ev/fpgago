#!/usr/bin/env python3
#
# bake_wordmark.py — regenerate the BIOS logo's handwritten wordmark bitmap.
#
# The logo wordmark in bios_font.py is a BAKED 1-bit bitmap (WORDMARK_B64),
# not a live font rendering, so `python3 bios_font.py` works on any machine
# with no font dependencies.  This tool is the one-time baking step: it
# renders a string with a TTF/TTC font (PIL required), thresholds it to
# 1 bit, crops to the ink bounding box, and prints a WORDMARK_W/H +
# WORDMARK_B64 block ready to paste into bios_font.py.
#
# The shipped wordmark is "fpgago" in macOS Bradley Hand Bold at 50 px
# (bitmap typefaces carry no copyright in the US).  Chosen over Brush
# Script (cursive f unreadable at 1-bit), Apple Chancery / Savoye /
# Snell (strokes too thin), Marker Felt / Comic Sans (too print-like).
#
# Usage:
#   python3 bake_wordmark.py "fpgago" \
#       "/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf" 50
#
# After pasting: check size fits the logo layout (see docs/bios-logo.md),
# iterate with `python3 bios_font.py --png /tmp/logo.png`, and only build
# bitstreams once the image is approved.
#
import base64
import sys

from PIL import Image, ImageDraw, ImageFont


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    text, font_path, size = sys.argv[1], sys.argv[2], int(sys.argv[3])

    f = ImageFont.truetype(font_path, size)
    img = Image.new("L", (8 * size, 4 * size), 0)
    ImageDraw.Draw(img).text((20, 20), text, font=f, fill=255)
    bw = img.point(lambda v: 1 if v > 110 else 0)
    bw = bw.crop(bw.getbbox())
    w, h = bw.size

    stride = (w + 7) // 8
    data = bytearray()
    for y in range(h):
        for bx in range(stride):
            b = 0
            for i in range(8):
                x = bx * 8 + i
                if x < w and bw.getpixel((x, y)):
                    b |= 0x80 >> i
            data.append(b)
    b64 = base64.b64encode(bytes(data)).decode()

    print(f"# {text!r} @ {size}px from {font_path}")
    print(f"WORDMARK_W, WORDMARK_H = {w}, {h}")
    print(f'WORDMARK_B64 = """{b64}"""')
    print("\n# preview:")
    for y in range(h):
        row = "".join("#" if data[y * stride + x // 8] & (0x80 >> (x % 8))
                      else "." for x in range(w))
        print("#", row)


if __name__ == "__main__":
    main()
