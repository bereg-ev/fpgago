#!/usr/bin/env python3
"""Generate bordersprites.prg — all 8 sprites parked in the LOWER BORDER,
made visible by the classic $D011 24/25-row border-open trick.

Raster IRQ at line 249 switches to 24-row mode (bit3=0) — the 24-row
border-on comparison at line 247 has already passed, and when line 251
arrives the VIC is in 24-row mode so the 25-row comparison never fires:
the vertical border flip-flop stays off and the lower border never
closes.  The ISR busy-waits to line 253 and restores 25-row mode so the
text window is normal on the next frame.

Expected on screen: normal BASIC screen, and a row of 8 solid sprites
(white,red,cyan,purple,green,blue,yellow,orange) BELOW the text window,
in what should be border.  If the border-open trick is broken, the
sprites are hidden under the border.  Sprites 6,7 sit at X>=256 to
exercise the $D010 X-MSB path.
"""
import struct

ORG = 0x0810

def assemble(labels):
    code = bytearray()
    marks = {}
    def emit(*bs): code.extend(bs)
    def addr(a): return (a & 0xFF, a >> 8)
    def mark(name): marks[name] = ORG + len(code)
    def lab(name): return labels.get(name, 0)

    emit(0x78)                                    # SEI
    emit(0xA9, 0x7F); emit(0x8D, *addr(0xDC0D))   # CIA1 IRQs off
    emit(0xAD, *addr(0xDC0D))                     # ack pending
    emit(0xA9, 0x01); emit(0x8D, *addr(0xD01A))   # raster IRQ enable
    emit(0xA9, 0xF9); emit(0x8D, *addr(0xD012))   # line 249
    emit(0xAD, *addr(0xD011)); emit(0x29, 0x7F); emit(0x8D, *addr(0xD011))
    emit(0xA9, lab('isr') & 0xFF); emit(0x8D, *addr(0x0314))
    emit(0xA9, lab('isr') >> 8);   emit(0x8D, *addr(0x0315))
    # solid sprite shape at $0340 (block 13)
    emit(0xA2, 0x3E); emit(0xA9, 0xFF)            # X=62, A=$FF
    mark('fill')
    emit(0x9D, *addr(0x0340))                     # STA $0340,X
    emit(0xCA)                                    # DEX
    emit(0x10, 0xFA)                              # BPL fill
    # all 8 sprite pointers -> block 13
    emit(0xA2, 0x07); emit(0xA9, 0x0D)
    mark('ptrs')
    emit(0x9D, *addr(0x07F8))                     # STA $07F8,X
    emit(0xCA)
    emit(0x10, 0xFA)                              # BPL ptrs
    # positions + colors, unrolled: X = 24+40*i (6,7 have X>=256), Y = 252
    for i in range(8):
        x = 24 + 40 * i
        emit(0xA9, x & 0xFF); emit(0x8D, *addr(0xD000 + 2 * i))
        emit(0xA9, 0xFC);     emit(0x8D, *addr(0xD001 + 2 * i))
        emit(0xA9, 1 + i);    emit(0x8D, *addr(0xD027 + i))
    emit(0xA9, 0xC0); emit(0x8D, *addr(0xD010))   # X MSB for sprites 6,7
    emit(0xA9, 0xFF); emit(0x8D, *addr(0xD015))   # enable all 8
    emit(0x58)                                    # CLI
    mark('forever')
    emit(0x4C, *addr(lab('forever')))             # JMP forever
    mark('isr')
    emit(0xAD, *addr(0xD019)); emit(0x8D, *addr(0xD019))   # ack
    emit(0xAD, *addr(0xD011)); emit(0x29, 0xF7); emit(0x8D, *addr(0xD011))  # 24 rows
    mark('wait')
    emit(0xAD, *addr(0xD012)); emit(0xC9, 0xFD)   # < 253?
    emit(0x90, 0xF9)                              # BCC wait
    emit(0xAD, *addr(0xD011)); emit(0x09, 0x08); emit(0x8D, *addr(0xD011))  # 25 rows
    emit(0x4C, 0x81, 0xEA)                        # JMP $EA81
    return code, marks

# two-pass: first with dummy labels to learn addresses, then for real
_, labels = assemble({})
code, labels2 = assemble(labels)
assert labels == labels2

# BASIC stub: 10 SYS 2064
stub = bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E]) + b"2064" + bytes([0x00, 0x00, 0x00])
assert len(stub) == 12
prg = struct.pack("<H", 0x0801) + stub + bytes(3) + bytes(code)
with open("games/bordersprites.prg", "wb") as f:
    f.write(prg)
print(f"games/bordersprites.prg: {len(prg)} bytes, code at $0810, "
      + ", ".join(f"{k}=${v:04X}" for k, v in labels.items()))
