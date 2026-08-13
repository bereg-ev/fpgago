#!/usr/bin/env python3
"""
kernal_fastload_patch.py — QSPI fastload hook for the 264 (c16/plus4) KERNAL.

Two outputs:

1. fastload_rom.vh — the 6502 fastload routine, assembled at $FD60, emitted
   as a Verilog case-table ROM. The 264 I/O hole ($FD00-$FF3F) shadows the
   KERNAL image, so this code is *served by the FPGA* (qspi_slave.v exposes
   it at $FD60-$FDCF); it never lives in the KERNAL ROM itself.

2. A 4-byte detour patched into the KERNAL hex image(s): the LOAD entry
   ($F04A, the default $032E vector target) becomes JMP $FD60 / NOP.
   Original bytes there (STA $93 / LDA #$00) are re-executed by the
   routine's fallback path, which resumes at $F04E — so VERIFY, non-8
   devices, errors, and a dead MCU all fall through to the stock LOAD.

Routine contract (mirrors the sim fastload trap in iec_floppy_sim.h):
  entry A=verify flag, X/Y already stored to $B4/$B5 by $F041.
  ZP: FNLEN $AB, SA $AD, FA $AE, FNADR $AF/B0, STATUS $90.
  Engine regs (qspi_slave.v): $FE20 CMD/STATUS, $FE21 NAME/DATA, $FE22 count.
  SA==0 → relocate to $B4/B5; SA!=0 → file header address (Terra Nova rule).
  Returns end address in X/Y, CLC, STATUS $90=0.

Usage:  kernal_fastload_patch.py            (regenerates .vh + patches hexes)
Idempotent: already-patched images are detected and left alone.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

ORG        = 0xFD60          # main routine origin (FPGA-served window A)
WINDOW_LEN = 0x70            # $FD60-$FDCF
GETB_ORG   = 0xFE30          # GETB fragment (window B, same I/O hole)
GETB_LEN   = 0x10            # $FE30-$FE3F
GETB_IDX   = 112             # window B maps to ROM table index 112..127
HOOK_ADDR  = 0xF04A          # KERNAL LOAD entry (default $032E vector)
RESUME     = 0xF04E          # after the 4 displaced bytes
ORIG_BYTES = bytes([0x85, 0x93, 0xA9, 0x00])   # STA $93 / LDA #$00

REG_CMD  = 0xFE20            # W: 0=reset 1=submit;  R: status
REG_DATA = 0xFE21            # W: name char push;    R: FIFO pop
BANK_ROM = 0xFF3E            # any write: ROM banked in ($8000-$FFFF)
BANK_RAM = 0xFF3F            # any write: RAM banked in
KERNAL_BASE = 0xC000

# ── mini two-pass 6502 assembler ──────────────────────────────────────────

class Asm:
    def __init__(self, org):
        self.org = org
        self.out = bytearray()
        self.labels = {}
        self.fixups = []     # (offset, kind, label)  kind: 'rel' | 'abs'

    def pc(self): return self.org + len(self.out)
    def label(self, name): self.labels[name] = self.pc()
    def db(self, *bs): self.out.extend(bs)

    def _ref(self, label, kind):
        self.fixups.append((len(self.out), kind, label))
        self.out.extend(b'\x00' if kind == 'rel' else b'\x00\x00')

    # addressing helpers
    def lda_imm(self, v): self.db(0xA9, v)
    def lda_zp(self, a):  self.db(0xA5, a)
    def lda_abs(self, a): self.db(0xAD, a & 0xFF, a >> 8)
    def lda_ind_y(self, a): self.db(0xB1, a)
    def sta_zp(self, a):  self.db(0x85, a)
    def sta_abs(self, a): self.db(0x8D, a & 0xFF, a >> 8)
    def sta_ind_y(self, a): self.db(0x91, a)
    def ldy_imm(self, v): self.db(0xA0, v)
    def ldy_zp(self, a):  self.db(0xA4, a)
    def ldx_zp(self, a):  self.db(0xA6, a)
    def stx_zp(self, a):  self.db(0x86, a)
    def cpy_zp(self, a):  self.db(0xC4, a)
    def cmp_imm(self, v): self.db(0xC9, v)
    def and_imm(self, v): self.db(0x29, v)
    def inc_zp(self, a):  self.db(0xE6, a)
    def iny(self):        self.db(0xC8)
    def tax(self):        self.db(0xAA)
    def tay(self):        self.db(0xA8)
    def sty_zp(self, a):  self.db(0x84, a)
    def php(self):        self.db(0x08)
    def plp(self):        self.db(0x28)
    def sei(self):        self.db(0x78)
    def cli(self):        self.db(0x58)
    def bit_abs(self, a): self.db(0x2C, a & 0xFF, a >> 8)
    def clc(self):        self.db(0x18)
    def sec(self):        self.db(0x38)
    def rts(self):        self.db(0x60)
    def jmp_abs(self, a): self.db(0x4C, a & 0xFF, a >> 8)
    def jmp(self, label): self.db(0x4C); self._ref(label, 'abs')
    def jsr(self, label): self.db(0x20); self._ref(label, 'abs')
    def jsr_abs(self, a): self.db(0x20, a & 0xFF, a >> 8)
    def bne(self, label): self.db(0xD0); self._ref(label, 'rel')
    def beq(self, label): self.db(0xF0); self._ref(label, 'rel')
    def bcs(self, label): self.db(0xB0); self._ref(label, 'rel')
    def bmi(self, label): self.db(0x30); self._ref(label, 'rel')
    def bpl(self, label): self.db(0x10); self._ref(label, 'rel')
    def bvs(self, label): self.db(0x70); self._ref(label, 'rel')

    def link(self):
        for off, kind, label in self.fixups:
            target = self.labels[label]
            if kind == 'abs':
                self.out[off]     = target & 0xFF
                self.out[off + 1] = target >> 8
            else:
                rel = target - (self.org + off + 1)
                assert -128 <= rel <= 127, f"branch out of range to {label}"
                self.out[off] = rel & 0xFF
        return bytes(self.out)

def build_getb():
    # GETB fragment at $FE30 → A=byte C=0, or C=1 when done/error
    a = Asm(GETB_ORG)
    a.label('getb')
    a.lda_abs(REG_CMD)
    a.bmi('have')               # bit7 = byte available
    a.and_imm(0x40)             # bit6 = done (EOF & FIFO drained)
    a.beq('getb')
    a.sec()
    a.rts()
    a.label('have')
    a.lda_abs(REG_DATA)
    a.clc()
    a.rts()
    return a.link()

def build_routine():
    a = Asm(ORG)
    # entry: A = verify flag; keep original semantics ($93 = verify).
    # STA doesn't set flags and the caller's flags are stale — TAY (Y is
    # dead here, KERNAL already stored it to $B5) makes Z reflect A.
    a.sta_zp(0x93)
    a.tay()
    a.bne('fb')                 # VERIFY → real path
    a.lda_zp(0xAE)              # FA (device)
    a.cmp_imm(0x08)
    a.bne('fb')
    a.lda_zp(0xAB)              # FNLEN
    a.beq('fb')
    a.lda_imm(0x00)
    a.sta_abs(REG_CMD)          # reset engine
    # BASIC 3.5 parks the filename in RAM UNDER the ROM (e.g. $FCF6), so
    # the name copy must run with RAM banked in. Our window lives in the
    # $FD00-$FF3F I/O hole, which is mapped in both banks; IRQ vectors are
    # not, hence the SEI bracket.
    a.php()
    a.sei()
    a.sta_abs(BANK_RAM)         # any write banks RAM (A=0)
    a.ldy_imm(0x00)
    a.label('nl')
    a.lda_ind_y(0xAF)           # (FNADR),Y — RAM read
    a.sta_abs(REG_DATA)         # push name char (hw caps at 16)
    a.iny()
    a.cpy_zp(0xAB)
    a.bne('nl')
    a.sta_abs(BANK_ROM)         # ROM back (write value irrelevant)
    a.plp()
    a.lda_imm(0x01)
    a.sta_abs(REG_CMD)          # submit request → REQ to MCU
    a.jsr_abs(GETB_ORG)         # header lo
    a.bcs('fb')                 # nothing came → fall back
    a.tax()
    a.jsr_abs(GETB_ORG)         # header hi
    a.bcs('fb')
    a.ldy_zp(0xAD)              # SA
    a.beq('loop')               # SA=0: relocate, $B4/B5 set, Y already 0
    a.stx_zp(0xB4)              # SA≠0: use the file's header address
    a.sta_zp(0xB5)
    a.ldy_imm(0x00)             # Y stays 0 through the loop (STY $90 later)
    a.label('loop')
    a.jsr_abs(GETB_ORG)
    a.bcs('done')
    a.sta_ind_y(0xB4)
    a.inc_zp(0xB4)
    a.bne('loop')
    a.inc_zp(0xB5)
    a.bne('loop')               # $B5 wrap = end of memory: stop
    a.label('done')
    a.lda_abs(REG_CMD)          # status
    a.and_imm(0x20)             # error bit (not found / MCU dead mid-file)
    a.bne('fb')
    a.sty_zp(0x90)              # STATUS = OK (Y is 0 on both paths here)
    a.ldx_zp(0xB4)              # end address
    a.ldy_zp(0xB5)
    a.clc()
    a.rts()
    a.label('fb')               # fallback: $93 already = verify flag
    a.lda_imm(0x00)             # displaced original LDA #$00
    a.jmp_abs(RESUME)           # resume stock LOAD at $F04E
    return a.link()

# ── outputs ────────────────────────────────────────────────────────────────

# ── C64 variant ────────────────────────────────────────────────────────────
# Same idea, different constants: routine served in the I/O1 window at
# $DE00 (always I/O when the KERNAL runs), regs at $DF00-$DF02 (I/O2).
# The C64 keeps the filename in plain RAM ($0200 input buffer), so no
# banking bracket is needed and the whole routine is one block.

C64_ORG        = 0xDE00
C64_WINDOW_LEN = 0x80         # $DE00-$DE7F (LOAD routine half)
C64_HOOK       = 0xF4A5       # KERNAL LOAD entry (default $0330 vector)
C64_RESUME     = 0xF4A9
C64_REG_CMD    = 0xDF00
C64_REG_DATA   = 0xDF01
C64_KERNAL_BASE = 0xE000

# ── DOS-over-link bus detours (C64) ───────────────────────────────────────
# A title that reads blocks through channel I/O (OPEN/PRINT#/GET#, U1/B-P —
# Pirates! and its class) never goes near the LOAD vector, so the fastload
# trap above cannot help it and every byte crawls over the IEC wire at
# ~1.35 ms.  Two more detours move that traffic onto the link:
#
#   $ED40  every byte the KERNAL puts ON the bus funnels through here —
#          LISTEN/TALK/SECOND/UNLSN/UNTLK all fall into it from $ED11 or
#          $ED36, and CIOUT JSRs it directly.  Byte in $95, ATN asserted
#          per $DD00 bit 3.  Success exit is the stock one: CLI, RTS.
#   $EE13  ACPTR, every byte taken OFF the bus.  Returns the byte in A and
#          ORs $40 into STATUS ($90) on EOI, via the stock $FE1C helper.
#
# BOTH must return with the CARRY CLEAR, exactly as the routines they replace
# do ($EE84 = LDA $A4 / CLI / CLC / RTS).  Carry is the KERNAL's error flag and
# BASIC checks it on every call: $E112 is JSR $FFCF / BCS $E0F9, and $E0F9
# does TAX / JMP $A437 — so a stray carry turns the byte just read into a
# BASIC error NUMBER.  Leaving it out cost a long hunt: INPUT# popped one byte
# ('Y' = $59 = 89), returned carry-set, and BASIC printed error 89 by walking
# off the end of its message table — an error with no name, on the INPUT# line.
#
# Both check the engine's "is this transaction mine" bit first and hand the
# byte back to the stock code otherwise, so a non-8 device still works.
C64_BUS_SEND_ORG = 0xDE80
C64_BUS_RECV_ORG = 0xDEC0
C64_REG_BUS      = 0xDF03     # W: byte under ATN;   R: bus status
C64_REG_BUSDATA  = 0xDF04     # W: channel data byte
C64_STATUS_OR    = 0xFE1C     # KERNAL: ORA $90 / STA $90 / RTS

C64_SEND_HOOK   = 0xED40
C64_SEND_RESUME = 0xED44
C64_SEND_ORIG   = bytes([0x78, 0x20, 0x97, 0xEE])   # SEI / JSR $EE97
C64_RECV_HOOK   = 0xEE13
C64_RECV_RESUME = 0xEE18
C64_RECV_ORIG   = bytes([0x78, 0xA9, 0x00, 0x85])   # SEI / LDA #$00 / STA $A5

def build_routine_c64():
    a = Asm(C64_ORG)
    a.sta_zp(0x93)              # keep original semantics ($93 = verify)
    a.tay()                     # flags from A (stale at entry)
    a.bne('fb')                 # VERIFY → real path
    a.lda_zp(0xBA)              # FA (device)
    a.cmp_imm(0x08)
    a.bne('fb')
    a.lda_zp(0xB7)              # FNLEN
    a.beq('fb')
    a.lda_imm(0x00)
    a.sta_abs(C64_REG_CMD)      # reset engine
    a.ldy_imm(0x00)
    a.label('nl')
    a.lda_ind_y(0xBB)           # (FNADR),Y — plain RAM on the C64
    a.sta_abs(C64_REG_DATA)
    a.iny()
    a.cpy_zp(0xB7)
    a.bne('nl')
    a.lda_imm(0x01)
    a.sta_abs(C64_REG_CMD)      # submit request → REQ to MCU
    a.jsr('getb')               # header lo
    a.bcs('fb')
    a.tax()
    a.jsr('getb')               # header hi
    a.bcs('fb')
    a.ldy_zp(0xB9)              # SA
    a.beq('msg')                # SA=0: relocate, $C3/C4 set by $F49E
    a.stx_zp(0xC3)              # SA≠0: file header address
    a.sta_zp(0xC4)
    a.label('msg')
    # The two screen lines a direct-mode LOAD produces — stock prints them at
    # $F4C1 ("SEARCHING FOR <name>") and $F4F0 ("LOADING"/"VERIFYING"), both
    # downstream of the $F4A5 hook, so the trap swallowed them.
    #
    # They are not cosmetic.  The standard chain-loader idiom prints a LOAD
    # line and a RUN line N rows below it, then stuffs HOME/RETURN/RETURN
    # into the keyboard buffer ($0277) and sets NDX — and N counts exactly
    # these rows.  Swallow them and the queued RETURN lands on a blank line,
    # so the loaded program is never started.  Pirates!' PICK does this at
    # line 21905/21920, and it is why the title loads and then sits there.
    #
    # Both routines test MSGFLG themselves ($F5AF: LDA $9D / BPL; $F5D2 ->
    # $F12B: BIT $9D / BPL), so this is self-gating — silent inside a running
    # program, printed in direct mode, exactly like the stock path.
    #
    # Placed here, after the header is in and the file is known to exist,
    # rather than at the stock $F4C1 point: a miss falls through to 'fb' and
    # the stock path prints SEARCHING itself, and printing it here too would
    # duplicate the line.  Both clobber A/X/Y, which is why they follow the
    # $C3/$C4 stores; Y is re-zeroed below on both paths.
    a.jsr_abs(0xF5AF)
    a.jsr_abs(0xF5D2)
    a.ldy_imm(0x00)
    a.label('loop')
    a.jsr('getb')
    a.bcs('done')
    a.sta_ind_y(0xC3)
    a.inc_zp(0xC3)
    a.bne('loop')
    a.inc_zp(0xC4)
    a.bne('loop')
    a.label('done')
    a.lda_abs(C64_REG_CMD)
    a.and_imm(0x20)             # error bit
    a.bne('fb')
    # A stock serial LOAD ends with the EOI byte, so it returns ST = $40 —
    # which is why loaders mask it (Pirates' PICK: IF(ST AND191)<>0).  We
    # were returning 0; anything that waits for the EOI bit as "the transfer
    # finished" would wait forever.  Match the drive.
    a.lda_imm(0x40)
    a.sta_zp(0x90)              # STATUS = EOI, as a real serial LOAD leaves it
    a.ldx_zp(0xC3)              # end address
    a.ldy_zp(0xC4)
    a.clc()
    a.rts()
    a.label('fb')               # $93 already = verify flag
    a.lda_imm(0x00)             # displaced original LDA #$00
    a.jmp_abs(C64_RESUME)
    a.label('getb')
    a.lda_abs(C64_REG_CMD)
    a.bmi('have')
    a.and_imm(0x40)
    a.beq('getb')
    a.sec()
    a.rts()
    a.label('have')
    a.lda_abs(C64_REG_DATA)
    a.clc()
    a.rts()
    return a.link()

def build_bus_send_c64():
    """$ED40 detour — one outgoing bus byte.  In: $95 = byte, $DD00 bit3 =
    ATN asserted.  Out (ours): CLI + RTS, the stock success exit ($EDAB)."""
    a = Asm(C64_BUS_SEND_ORG)
    a.lda_abs(0xDD00)
    a.and_imm(0x08)             # ATN asserted?  (bit set = pulled low)
    a.beq('data')
    a.jsr('rdy')
    a.lda_zp(0x95)
    a.sta_abs(C64_REG_BUS)      # under ATN: also re-decodes addressing
    a.jmp('chk')
    a.label('data')
    a.bit_abs(C64_REG_BUS)      # channel byte: only if the drive is ours
    a.bpl('fb')
    a.jsr('rdy')
    a.lda_zp(0x95)
    a.sta_abs(C64_REG_BUSDATA)
    a.label('chk')
    a.bit_abs(C64_REG_BUS)      # did the engine take this byte?
    a.bpl('fb')
    a.cli()
    a.clc()                     # success: carry CLEAR, like the stock exit
    a.rts()
    # The engine buffers 16 bytes; a byte written while the previous batch is
    # still waiting to be fetched would be dropped, and a batch appended to
    # mid-fetch could report a length that no longer matches its contents.
    # So: never write while a submission is outstanding.  The engine's ~1.2 s
    # watchdog clears `pending` on its own, so a dead MCU ends the wait
    # instead of hanging the machine.
    a.label('rdy')
    a.lda_abs(C64_REG_BUS)
    a.and_imm(0x04)             # bit2 = submitted, not yet fetched
    a.bne('rdy')
    a.rts()
    a.label('fb')               # not ours: the displaced bytes, then resume
    a.sei()
    a.jsr_abs(0xEE97)
    a.jmp_abs(C64_SEND_RESUME)
    return a.link()

def build_bus_recv_c64():
    """$EE13 detour — ACPTR.  Out: byte in A, EOI ORed into STATUS $90.
    Spins on the engine while the MCU streams the channel into the FIFO;
    that wait is the whole transfer, and it is bounded by the engine's own
    ~1.2 s watchdog (which sets `done`), so a dead MCU cannot hang here."""
    a = Asm(C64_BUS_RECV_ORG)
    a.bit_abs(C64_REG_BUS)
    a.bpl('fb')                 # not our device: stock ACPTR
    a.label('wait')
    a.bit_abs(C64_REG_BUS)
    a.bvs('have')               # bit6 = a byte is waiting
    a.lda_abs(C64_REG_BUS)
    a.and_imm(0x18)             # done (EOF drained) or error
    a.beq('wait')
    a.lda_imm(0x42)             # ST = EOI + read timeout: nothing came
    a.jsr_abs(C64_STATUS_OR)
    a.lda_imm(0x00)
    a.cli()
    a.clc()
    a.rts()
    a.label('have')
    a.lda_abs(C64_REG_BUS)
    a.and_imm(0x20)             # bit5 = this byte is the last one
    a.beq('nb')
    a.lda_imm(0x40)             # ST = EOI, set WITH the byte
    a.jsr_abs(C64_STATUS_OR)
    a.label('nb')
    a.lda_abs(C64_REG_DATA)     # pop
    a.cli()
    a.clc()
    a.rts()
    a.label('fb')
    a.sei()
    a.lda_imm(0x00)
    a.sta_zp(0xA5)
    a.jmp_abs(C64_RECV_RESUME)
    return a.link()

# ── outputs ────────────────────────────────────────────────────────────────

def write_vh(main, getb, path):
    with open(path, 'w') as f:
        f.write("// GENERATED by kernal_fastload_patch.py — do not edit.\n")
        f.write(f"// 6502 fastload routine: main {len(main)}B at ${ORG:04X} "
                f"(idx 0+), GETB {len(getb)}B at ${GETB_ORG:04X} "
                f"(idx {GETB_IDX}+).\n")
        f.write("always @* begin\n    case (fl_rom_addr)\n")
        for i, b in enumerate(main):
            f.write(f"        7'd{i}: rom_q = 8'h{b:02X};\n")
        for i, b in enumerate(getb):
            f.write(f"        7'd{GETB_IDX + i}: rom_q = 8'h{b:02X};\n")
        f.write("        default: rom_q = 8'hFF;\n    endcase\nend\n")

def write_vh_c64(blobs, path):
    """blobs: {origin: code} — the served $DExx page.  Origins must not
    overlap; the gaps read as $FF."""
    cells = {}
    for org, code in blobs.items():
        for i, b in enumerate(code):
            idx = org - C64_ORG + i
            assert 0 <= idx < 0x100, f"${org + i:04X} outside the window"
            assert idx not in cells, f"overlap at ${org + i:04X}"
            cells[idx] = b
    with open(path, 'w') as f:
        f.write("// GENERATED by kernal_fastload_patch.py — do not edit.\n")
        for org, code in sorted(blobs.items()):
            f.write(f"// {len(code)}B at ${org:04X}\n")
        f.write("always @* begin\n    case (fl_rom_addr)\n")
        for idx in sorted(cells):
            f.write(f"        8'd{idx}: rom_q = 8'h{cells[idx]:02X};\n")
        f.write("        default: rom_q = 8'hFF;\n    endcase\nend\n")

def patch_hex(path, size, hook, base, target, orig=ORIG_BYTES, what="LOAD entry"):
    lines = open(path).read().split()
    rom = bytearray(int(x, 16) for x in lines)
    assert len(rom) == size, f"{path}: unexpected size {len(rom)}"
    off = hook - base
    detour = bytes([0x4C, target & 0xFF, target >> 8, 0xEA])
    cur = bytes(rom[off:off + 4])
    if cur == detour:
        print(f"  {path}: {what} already patched")
        return
    assert cur == orig, \
        f"{path}: unexpected bytes at ${hook:04X}: {cur.hex(' ')}"
    rom[off:off + 4] = detour
    with open(path, 'w') as f:
        for b in rom:
            f.write(f"{b:02x}\n")
    print(f"  {path}: {what} ${hook:04X} → JMP ${target:04X}")

if __name__ == '__main__':
    getb = build_getb()
    code = build_routine()
    print(f"264 routine: {len(code)} bytes at ${ORG:04X} (window {WINDOW_LEN}), "
          f"GETB {len(getb)} bytes at ${GETB_ORG:04X} (window {GETB_LEN})")
    assert len(code) <= WINDOW_LEN
    assert len(getb) <= GETB_LEN

    c64 = build_routine_c64()
    print(f"c64 routine: {len(c64)} bytes at ${C64_ORG:04X} "
          f"(window {C64_WINDOW_LEN})")
    assert len(c64) <= C64_WINDOW_LEN

    c64_send = build_bus_send_c64()
    c64_recv = build_bus_recv_c64()
    print(f"c64 bus detours: send {len(c64_send)}B at ${C64_BUS_SEND_ORG:04X}, "
          f"recv {len(c64_recv)}B at ${C64_BUS_RECV_ORG:04X}")
    assert C64_BUS_SEND_ORG + len(c64_send) <= C64_BUS_RECV_ORG
    assert C64_BUS_RECV_ORG + len(c64_recv) <= C64_ORG + 0x100

    vh = os.path.join(HERE, 'fastload_rom.vh')
    write_vh(code, getb, vh)
    print(f"  wrote {vh}")
    vh64 = os.path.join(HERE, 'fastload_rom_c64.vh')
    write_vh_c64({C64_ORG: c64,
                  C64_BUS_SEND_ORG: c64_send,
                  C64_BUS_RECV_ORG: c64_recv}, vh64)
    print(f"  wrote {vh64}")

    for hexfile, size, hook, base, target, orig, what in (
            ('../plus4/roms/kernal.hex',   16384, HOOK_ADDR, KERNAL_BASE, ORG,
             ORIG_BYTES, 'LOAD entry'),
            ('../c16/roms/kernal_PAL.hex', 16384, HOOK_ADDR, KERNAL_BASE, ORG,
             ORIG_BYTES, 'LOAD entry'),
            ('../c64/roms/kernal.hex', 8192, C64_HOOK, C64_KERNAL_BASE,
             C64_ORG, ORIG_BYTES, 'LOAD entry'),
            ('../c64/roms/kernal.hex', 8192, C64_SEND_HOOK, C64_KERNAL_BASE,
             C64_BUS_SEND_ORG, C64_SEND_ORIG, 'bus send'),
            ('../c64/roms/kernal.hex', 8192, C64_RECV_HOOK, C64_KERNAL_BASE,
             C64_BUS_RECV_ORG, C64_RECV_ORIG, 'bus recv (ACPTR)')):
        p = os.path.normpath(os.path.join(HERE, hexfile))
        if os.path.exists(p):
            patch_hex(p, size, hook, base, target, orig, what)
        else:
            print(f"  {p}: not found, skipped")
