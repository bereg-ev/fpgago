#!/usr/bin/env python3
"""Generate rastertest.prg — raster IRQ double-split + 2 sprites.

Expected on screen: border white between raster lines 100 and 180,
black elsewhere; two solid sprites (white @100,100; yellow expanded
@150,120) on black background over the BASIC screen.
"""
import struct

code = bytearray()
ORG = 0x0810

def emit(*bs): code.extend(bs)
def addr(a): return (a & 0xFF, a >> 8)

# Pass 1/2: assemble with known layout; labels computed after a dry run.
def assemble(isr, forever, second, loop):
    global code
    code = bytearray()
    emit(0x78)                          # SEI
    emit(0xA9, 0x7F); emit(0x8D, *addr(0xDC0D))   # CIA1 IRQs off
    emit(0xAD, *addr(0xDC0D))                     # ack pending
    emit(0xA9, 0x01); emit(0x8D, *addr(0xD01A))   # raster IRQ enable
    emit(0xA9, 0x64); emit(0x8D, *addr(0xD012))   # line 100
    emit(0xAD, *addr(0xD011)); emit(0x29, 0x7F); emit(0x8D, *addr(0xD011))
    emit(0xA9, isr & 0xFF); emit(0x8D, *addr(0x0314))
    emit(0xA9, isr >> 8);   emit(0x8D, *addr(0x0315))
    emit(0xA9, 0x00); emit(0x8D, *addr(0xD020)); emit(0x8D, *addr(0xD021))
    emit(0xA2, 0x3E); emit(0xA9, 0xFF)            # X=62, A=$FF
    # loop:
    assert len(code) + ORG == loop or loop == 0
    emit(0x9D, *addr(0x0340))                     # STA $0340,X
    emit(0xCA)                                    # DEX
    emit(0x10, 0xFA)                              # BPL loop
    emit(0xA9, 0x0D); emit(0x8D, *addr(0x07F8)); emit(0x8D, *addr(0x07F9))
    emit(0xA9, 0x03); emit(0x8D, *addr(0xD015))   # enable sprites 0,1
    emit(0xA9, 0x64); emit(0x8D, *addr(0xD000)); emit(0x8D, *addr(0xD001))
    emit(0xA9, 0x96); emit(0x8D, *addr(0xD002))
    emit(0xA9, 0x78); emit(0x8D, *addr(0xD003))
    emit(0xA9, 0x00); emit(0x8D, *addr(0xD010))
    emit(0xA9, 0x01); emit(0x8D, *addr(0xD027))   # s0 white
    emit(0xA9, 0x07); emit(0x8D, *addr(0xD028))   # s1 yellow
    emit(0xA9, 0x02); emit(0x8D, *addr(0xD017))   # s1 y-expand
    emit(0x8D, *addr(0xD01D))                     # s1 x-expand
    emit(0x58)                                    # CLI
    # forever:
    assert len(code) + ORG == forever or forever == 0
    emit(0x4C, *addr(forever))                    # JMP forever
    # isr:
    assert len(code) + ORG == isr or isr == 0
    emit(0xAD, *addr(0xD019)); emit(0x8D, *addr(0xD019))  # ack
    emit(0xAD, *addr(0xD012)); emit(0xC9, 0xB4)           # >= 180?
    emit(0xB0, 0x0D)                                      # BCS second (+13)
    emit(0xA9, 0x01); emit(0x8D, *addr(0xD020))           # border white
    emit(0xA9, 0xB4); emit(0x8D, *addr(0xD012))           # rearm 180
    emit(0x4C, 0x81, 0xEA)                                # JMP $EA81
    # second:
    assert len(code) + ORG == second or second == 0
    emit(0xA9, 0x00); emit(0x8D, *addr(0xD020))           # border black
    emit(0xA9, 0x64); emit(0x8D, *addr(0xD012))           # rearm 100
    emit(0x4C, 0x81, 0xEA)                                # JMP $EA81

# dry run with dummy labels to measure offsets
LOOP = FOREVER = ISR = SECOND = 0
assemble(0, 0, 0, 0)
# find offsets by reproducing the layout: easier — recompute directly
# loop is right after the LDX/LDA pair; scan for it structurally:
b = bytes(code)
loop_off    = b.index(bytes([0xA2, 0x3E, 0xA9, 0xFF])) + 4
forever_off = b.index(bytes([0x58])) + 1
isr_off     = forever_off + 3
second_off  = isr_off + 13 + 2  # ack(6)+lda d012(3)+cmp(2)+bcs(2) = 13, then 10 more
# second = isr + 6(ack) + 3 + 2 + 2 + 5(lda/sta) + 5(lda/sta) + 3(jmp) = isr+26... compute:
second_off  = isr_off + 6 + 3 + 2 + 2 + 5 + 5 + 3

assemble(ORG + isr_off, ORG + forever_off, ORG + second_off, ORG + loop_off)

# BASIC stub: 10 SYS 2064 — 12 bytes, $0801-$080C
stub = bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E]) + b"2064" + bytes([0x00, 0x00, 0x00])
assert len(stub) == 12
prg = struct.pack("<H", 0x0801) + stub          # ends at $080C
prg += bytes(3)                                  # pad $080D-$080F
prg += bytes(code)                               # code at $0810
with open("rastertest.prg", "wb") as f:
    f.write(prg)
print(f"rastertest.prg: {len(prg)} bytes, code at $0810, isr=${ORG+isr_off:04X}, second=${ORG+second_off:04X}")
