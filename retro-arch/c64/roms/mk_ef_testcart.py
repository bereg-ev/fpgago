#!/usr/bin/env python3
"""
mk_ef_testcart.py — build a copyright-free self-testing EasyFlash cartridge.

Why: the EasyFlash RTL (bank register $DE00, mode register $DE02, EF RAM at
$DF00, and the Am29F040 flash command emulation) has to be proven from below
with a deterministic 10-second test — not through a commercial game image.
Every bank carries marker bytes (ROML: offset 0 = bank, offset 1 = bank^$FF;
ROMH: bank^$80, bank^$7F), so a wrong bank decode is immediately visible,
and ROMH bank 0 carries a hand-assembled 6502 driver that walks all 64
banks and exercises EF RAM, cart kill, flash autoselect, byte program and
sector erase.

Result protocol (page 3, readable from a sim capture or a BIOS freeze):
    $03C0/$03C1 = $EF $64   base tests passed   (stages 2-5)
    $03C4/$03C5 = $EF $65   flash tests passed  (stages 6-8)
    $03C0 = $BA             FAILED: $03C1 = stage, $03C2 = aux (bank/index),
                            $03C3 = value read
    $02                     last stage reached (1..8)

Stages: 1 boot reached / 2 16K mode / 3 bank walk / 4 EF RAM / 5 RAM-under-
ROM + cart kill / 6 flash autoselect ($01/$A4) / 7 byte program (bank 1
offset $100 := $42) / 8 sector erase (64 KiB sectors, sector = bank>>3:
banks 8+9 erased, bank 7 must survive).

The driver does not fit in one page (the required checks with the exact
fail protocol come to ~360 bytes), so the boot code copies TWO pages:
$E200-$E2FF -> $0200-$02FF plus $E300-$E3BF -> $0300-$03BF, stopping short
of the result bytes at $03C0.

Usage: mk_ef_testcart.py <output.flat> [<output.crt>]

With the second argument it also writes a type-32 .crt (one 8 KiB CHIP
packet per bank per chip) and round-trips it through crt2flat.parse_crt()
as a self-check.
"""

import os, struct, sys

BANKS = 64
BANK_SIZE = 0x2000
CHIP_SIZE = BANKS * BANK_SIZE
FLAT_SIZE = 2 * CHIP_SIZE

DRIVER_BASE = 0x0200            # driver runs here (copied from $E200/$E300)
DRIVER_MAX = 0x1C0              # $0200-$03BF; results live at $03C0+
BOOT_BASE = 0xFF00              # ultimax: ROMH bank 0 offset $1F00


# ── mini two-pass layout: literal opcode bytes, only branch/jump targets ──
# are symbolic (offsets are computed and range-asserted, never hand-numbered)
def asm(items, base):
    labels = {}
    pc = 0
    for it in items:
        kind = it[0]
        if kind == 'label':
            labels[it[1]] = pc
        elif kind == 'bne':
            pc += 2
        elif kind in ('jmp', 'jsr'):
            pc += 3
        elif kind == 'db':
            pc += len(it[1])
        else:
            raise AssertionError(f'bad item {it!r}')
    out = bytearray()
    nbranch = 0
    for it in items:
        kind = it[0]
        if kind == 'label':
            continue
        if kind == 'bne':
            off = labels[it[1]] - (len(out) + 2)   # relative to PC after BNE
            assert -128 <= off <= 127, \
                f'BNE {it[1]} at ${base + len(out):04X}: offset {off} out of range'
            out += bytes([0xD0, off & 0xFF])
            nbranch += 1
        elif kind in ('jmp', 'jsr'):
            addr = base + labels[it[1]]
            out += bytes([0x4C if kind == 'jmp' else 0x20,
                          addr & 0xFF, (addr >> 8) & 0xFF])
        else:
            out += bytes(it[1])
    return bytes(out), nbranch


# ── boot code, runs at $FF00 in ultimax mode right after reset ────────────
BOOT = [
    ('db', (0x78,),             'SEI'),
    ('db', (0xA2, 0xFF),        'LDX #$FF'),
    ('db', (0x9A,),             'TXS'),
    ('db', (0xA9, 0x27),        'LDA #$27'),
    ('db', (0x85, 0x01),        'STA $01      ; EF guide: port data first...'),
    ('db', (0xA9, 0x2F),        'LDA #$2F'),
    ('db', (0x85, 0x00),        'STA $00      ; ...then DDR'),
    ('db', (0xA9, 0x01),        'LDA #$01'),
    ('db', (0x85, 0x02),        'STA $02      ; progress marker: stage 1 = boot reached'),
    ('db', (0xA2, 0x00),        'LDX #$00'),
    ('label', 'c1'),
    ('db', (0xBD, 0x00, 0xE2),  'LDA $E200,X  ; driver source, page 1'),
    ('db', (0x9D, 0x00, 0x02),  'STA $0200,X'),
    ('db', (0xE8,),             'INX'),
    ('bne', 'c1',               'BNE c1'),
    ('label', 'c2'),
    ('db', (0xBD, 0x00, 0xE3),  'LDA $E300,X  ; page 2, X wrapped to 0'),
    ('db', (0x9D, 0x00, 0x03),  'STA $0300,X'),
    ('db', (0xE8,),             'INX'),
    ('db', (0xE0, 0xC0),        'CPX #$C0     ; stop short of results at $03C0'),
    ('bne', 'c2',               'BNE c2'),
    ('db', (0x4C, 0x00, 0x02),  'JMP $0200'),
]

# ── the test driver, runs at $0200 from RAM (bank switching under it is ──
# safe there).  X is pre-loaded with the stage number at each stage start
# (TAX after the marker), so a failing check can BNE straight to fail with
# the exact protocol: A = value read, Y = aux, X = stage.  Stage 3 uses X
# as the bank counter, so it goes through stubs f3a/f3b instead; stage 8 is
# out of BNE range of fail and bounces through trampoline f8.
DRIVER = [
    # ---- stage 2: switch to 16K mode ----------------------------------
    ('db', (0xA9, 0x02),        'LDA #$02'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 2'),
    ('db', (0xAA,),             'TAX          ; X = stage for the fail path'),
    ('db', (0xA9, 0x07),        'LDA #$07'),
    ('db', (0x8D, 0x02, 0xDE),  'STA $DE02    ; M=1 X=1 G=1 -> /GAME=0 /EXROM=0'),

    # ---- stage 3: bank walk, ROML+ROMH markers on all 64 banks --------
    ('db', (0xA9, 0x03),        'LDA #$03'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 3'),
    ('db', (0xA2, 0x00),        'LDX #$00'),
    ('label', 'walk'),
    ('db', (0x8E, 0x00, 0xDE),  'STX $DE00    ; select bank X'),
    ('db', (0x8A,),             'TXA'),
    ('db', (0xA8,),             'TAY          ; Y = bank (aux for fail path)'),
    ('db', (0xCD, 0x00, 0x80),  'CMP $8000    ; ROML marker == bank?'),
    ('bne', 'f3a',              'BNE f3a'),
    ('db', (0x8A,),             'TXA'),
    ('db', (0x49, 0x80),        'EOR #$80'),
    ('db', (0xCD, 0x00, 0xA0),  'CMP $A000    ; ROMH marker == bank^$80?'),
    ('bne', 'f3b',              'BNE f3b'),
    ('db', (0xE8,),             'INX'),
    ('db', (0xE0, 0x40),        'CPX #$40'),
    ('bne', 'walk',             'BNE walk'),
    ('db', (0xA2, 0x00),        'LDX #$00'),
    ('db', (0x8E, 0x00, 0xDE),  'STX $DE00    ; back to bank 0'),
    ('jmp', 'stage4',           'JMP stage4'),
    ('label', 'f3a'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000    ; A = value read'),
    ('db', (0xA2, 0x03),        'LDX #$03'),
    ('jmp', 'fail',             'JMP fail'),
    ('label', 'f3b'),
    ('db', (0xAD, 0x00, 0xA0),  'LDA $A000'),
    ('db', (0xA2, 0x03),        'LDX #$03'),
    ('jmp', 'fail',             'JMP fail'),

    # ---- stage 4: EF RAM at $DF00-$DFFF -------------------------------
    ('label', 'stage4'),
    ('db', (0xA9, 0x04),        'LDA #$04'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 4'),
    ('db', (0xAA,),             'TAX'),
    ('db', (0xA9, 0x5A),        'LDA #$5A'),
    ('db', (0x8D, 0x00, 0xDF),  'STA $DF00'),
    ('db', (0xA9, 0xC3),        'LDA #$C3'),
    ('db', (0x8D, 0x80, 0xDF),  'STA $DF80'),
    ('db', (0xA9, 0x3C),        'LDA #$3C'),
    ('db', (0x8D, 0xFF, 0xDF),  'STA $DFFF'),
    ('db', (0xAD, 0x00, 0xDF),  'LDA $DF00'),
    ('db', (0xA0, 0x00),        'LDY #$00     ; aux = low address byte'),
    ('db', (0xC9, 0x5A),        'CMP #$5A'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xAD, 0x80, 0xDF),  'LDA $DF80'),
    ('db', (0xA0, 0x80),        'LDY #$80'),
    ('db', (0xC9, 0xC3),        'CMP #$C3'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xAD, 0xFF, 0xDF),  'LDA $DFFF'),
    ('db', (0xA0, 0xFF),        'LDY #$FF'),
    ('db', (0xC9, 0x3C),        'CMP #$3C'),
    ('bne', 'fail',             'BNE fail'),

    # ---- stage 5: RAM under ROM + cart kill ---------------------------
    ('db', (0xA9, 0x05),        'LDA #$05'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 5'),
    ('db', (0xAA,),             'TAX'),
    ('db', (0xA9, 0x77),        'LDA #$77'),
    ('db', (0x8D, 0x00, 0x80),  'STA $8000    ; write lands in RAM under ROML'),
    ('db', (0xA9, 0x04),        'LDA #$04'),
    ('db', (0x8D, 0x02, 0xDE),  'STA $DE02    ; kill cart: M=1 X=0 G=0'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000    ; must read back the RAM byte'),
    ('db', (0xA0, 0x00),        'LDY #$00'),
    ('db', (0xC9, 0x77),        'CMP #$77'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xAD, 0x80, 0xDF),  'LDA $DF80    ; EF RAM stays visible when killed'),
    ('db', (0xA0, 0x01),        'LDY #$01'),
    ('db', (0xC9, 0xC3),        'CMP #$C3'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xA9, 0xEF),        'LDA #$EF'),
    ('db', (0x8D, 0xC0, 0x03),  'STA $03C0    ; base-PASS token'),
    ('db', (0xA9, 0x64),        'LDA #$64'),
    ('db', (0x8D, 0xC1, 0x03),  'STA $03C1'),
    ('jmp', 'stage6',           'JMP stage6'),

    # ---- fail: A = got, Y = aux, X = stage ----------------------------
    ('label', 'fail'),
    ('db', (0x8D, 0xC3, 0x03),  'STA $03C3    ; value read'),
    ('db', (0x8C, 0xC2, 0x03),  'STY $03C2    ; aux (bank / index)'),
    ('db', (0x8E, 0xC1, 0x03),  'STX $03C1    ; stage'),
    ('db', (0xA9, 0xBA),        'LDA #$BA'),
    ('db', (0x8D, 0xC0, 0x03),  'STA $03C0    ; FAIL token'),
    ('label', 'hang'),
    ('jmp', 'hang',             'JMP hang'),

    # ---- unlock: the AA/55 flash command prologue ---------------------
    ('label', 'unlock'),
    ('db', (0xA9, 0xAA),        'LDA #$AA'),
    ('db', (0x8D, 0x55, 0x85),  'STA $8555'),
    ('db', (0xA9, 0x55),        'LDA #$55'),
    ('db', (0x8D, 0xAA, 0x82),  'STA $82AA'),
    ('db', (0x60,),             'RTS'),

    # ---- stage 6: flash autoselect on the ROML chip -------------------
    ('label', 'stage6'),
    ('db', (0xA9, 0x06),        'LDA #$06'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 6'),
    ('db', (0xAA,),             'TAX'),
    ('db', (0xA9, 0x07),        'LDA #$07'),
    ('db', (0x8D, 0x02, 0xDE),  'STA $DE02    ; re-enable 16K mode'),
    ('jsr', 'unlock',           'JSR unlock'),
    ('db', (0xA9, 0x90),        'LDA #$90'),
    ('db', (0x8D, 0x55, 0x85),  'STA $8555    ; autoselect'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000'),
    ('db', (0xA0, 0x00),        'LDY #$00'),
    ('db', (0xC9, 0x01),        'CMP #$01     ; manufacturer = AMD'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xAD, 0x01, 0x80),  'LDA $8001'),
    ('db', (0xA0, 0x01),        'LDY #$01'),
    ('db', (0xC9, 0xA4),        'CMP #$A4     ; device = Am29F040'),
    ('bne', 'fail',             'BNE fail'),
    ('db', (0xA9, 0xF0),        'LDA #$F0'),
    ('db', (0x8D, 0x00, 0x80),  'STA $8000    ; reset autoselect'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000'),
    ('db', (0xA0, 0x02),        'LDY #$02'),
    ('db', (0xC9, 0x00),        'CMP #$00     ; bank 0 ROML marker is 0'),
    ('bne', 'fail',             'BNE fail'),

    # ---- stage 7: byte program (bank 1 offset $100: $FF -> $42) -------
    ('db', (0xA9, 0x07),        'LDA #$07'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 7'),
    ('db', (0xAA,),             'TAX'),
    ('db', (0xA9, 0x01),        'LDA #$01'),
    ('db', (0x8D, 0x00, 0xDE),  'STA $DE00    ; bank 1'),
    ('jsr', 'unlock',           'JSR unlock'),
    ('db', (0xA9, 0xA0),        'LDA #$A0'),
    ('db', (0x8D, 0x55, 0x85),  'STA $8555    ; program command'),
    ('db', (0xA9, 0x42),        'LDA #$42'),
    ('db', (0x8D, 0x00, 0x81),  'STA $8100    ; chip 0 bank 1 offset $100'),
    ('label', 'p7'),
    ('db', (0xAD, 0x00, 0x81),  'LDA $8100    ; toggle-bit emulation: status'),
    ('db', (0xC9, 0x42),        'CMP #$42     ; ...until the write lands'),
    ('bne', 'p7',               'BNE p7'),
    ('db', (0xAD, 0x00, 0x81),  'LDA $8100'),
    ('db', (0xA0, 0x00),        'LDY #$00'),
    ('db', (0xC9, 0x42),        'CMP #$42'),
    ('bne', 'fail',             'BNE fail'),
    ('jmp', 'stage8',           'JMP stage8'),
    ('label', 'f8'),
    ('jmp', 'fail',             'JMP fail     ; trampoline: stage 8 is out of BNE range'),

    # ---- stage 8: sector erase (sector 1 = banks 8..15 of chip 0) -----
    ('label', 'stage8'),
    ('db', (0xA9, 0x08),        'LDA #$08'),
    ('db', (0x85, 0x02),        'STA $02      ; stage 8'),
    ('db', (0xAA,),             'TAX'),
    ('db', (0xA9, 0x08),        'LDA #$08'),
    ('db', (0x8D, 0x00, 0xDE),  'STA $DE00    ; bank 8 -> sector 1'),
    ('jsr', 'unlock',           'JSR unlock'),
    ('db', (0xA9, 0x80),        'LDA #$80'),
    ('db', (0x8D, 0x55, 0x85),  'STA $8555    ; erase command'),
    ('jsr', 'unlock',           'JSR unlock'),
    ('db', (0xA9, 0x30),        'LDA #$30'),
    ('db', (0x8D, 0x00, 0x80),  'STA $8000    ; sector erase at bank 8'),
    ('label', 'p8'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000    ; status until erased'),
    ('db', (0xC9, 0xFF),        'CMP #$FF'),
    ('bne', 'p8',               'BNE p8'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000'),
    ('db', (0xA0, 0x00),        'LDY #$00'),
    ('db', (0xC9, 0xFF),        'CMP #$FF     ; bank 8 erased'),
    ('bne', 'f8',               'BNE f8'),
    ('db', (0xA9, 0x09),        'LDA #$09'),
    ('db', (0x8D, 0x00, 0xDE),  'STA $DE00'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000'),
    ('db', (0xA0, 0x01),        'LDY #$01'),
    ('db', (0xC9, 0xFF),        'CMP #$FF     ; bank 9 (same sector) erased too'),
    ('bne', 'f8',               'BNE f8'),
    ('db', (0xA9, 0x07),        'LDA #$07'),
    ('db', (0x8D, 0x00, 0xDE),  'STA $DE00'),
    ('db', (0xAD, 0x00, 0x80),  'LDA $8000'),
    ('db', (0xA0, 0x02),        'LDY #$02'),
    ('db', (0xC9, 0x07),        'CMP #$07     ; bank 7 (sector 0) untouched'),
    ('bne', 'f8',               'BNE f8'),
    ('db', (0xA9, 0xEF),        'LDA #$EF'),
    ('db', (0x8D, 0xC4, 0x03),  'STA $03C4    ; flash-PASS token'),
    ('db', (0xA9, 0x65),        'LDA #$65'),
    ('db', (0x8D, 0xC5, 0x03),  'STA $03C5'),
    ('jmp', 'hang',             'JMP hang'),
]


def build_flat(driver, boot):
    flat = bytearray(b'\xFF' * FLAT_SIZE)
    for bank in range(BANKS):
        lo = bank * BANK_SIZE                  # chip 0 (ROML)
        flat[lo + 0] = bank
        flat[lo + 1] = bank ^ 0xFF
        hi = CHIP_SIZE + bank * BANK_SIZE      # chip 1 (ROMH)
        flat[hi + 0] = bank ^ 0x80
        flat[hi + 1] = bank ^ 0x7F
    # ROMH bank 0: boot + driver source + vectors (ultimax: offset X = $E000+X)
    h0 = CHIP_SIZE
    flat[h0 + 0x0200:h0 + 0x0200 + len(driver)] = driver
    flat[h0 + 0x1F00:h0 + 0x1F00 + len(boot)] = boot
    flat[h0 + 0x1F80] = 0x40                   # RTI (NMI/IRQ handler)
    flat[h0 + 0x1FFA:h0 + 0x1FFC] = bytes((0x80, 0xFF))   # NMI   -> $FF80
    flat[h0 + 0x1FFC:h0 + 0x1FFE] = bytes((0x00, 0xFF))   # RESET -> $FF00
    flat[h0 + 0x1FFE:h0 + 0x2000] = bytes((0x80, 0xFF))   # IRQ   -> $FF80
    return flat


def build_crt(flat):
    hdr = bytearray(0x40)
    hdr[0:16] = b'C64 CARTRIDGE   '
    struct.pack_into('>I', hdr, 0x10, 0x40)    # header length
    struct.pack_into('>H', hdr, 0x14, 0x0100)  # version 1.0
    struct.pack_into('>H', hdr, 0x16, 32)      # hardware type: EasyFlash
    hdr[0x18] = 1                              # EXROM (register-controlled)
    hdr[0x19] = 0                              # GAME: ultimax at boot
    name = b'EF SELFTEST'
    hdr[0x20:0x20 + len(name)] = name
    out = bytearray(hdr)
    for chip, load in ((0, 0x8000), (1, 0xA000)):
        for bank in range(BANKS):
            base = chip * CHIP_SIZE + bank * BANK_SIZE
            out += b'CHIP'
            out += struct.pack('>IHHHH', 0x10 + BANK_SIZE, 2, bank, load,
                               BANK_SIZE)      # chip type 2 = Flash
            out += flat[base:base + BANK_SIZE]
    return bytes(out)


def main(argv):
    if len(argv) not in (2, 3):
        print(f'Usage: {argv[0]} <output.flat> [<output.crt>]')
        return 1

    driver, ndrv = asm(DRIVER, DRIVER_BASE)
    boot, nboot = asm(BOOT, BOOT_BASE)
    assert len(driver) <= DRIVER_MAX, \
        f'driver is {len(driver)} bytes, max {DRIVER_MAX} ($0200-$03BF)'
    assert len(boot) <= 0x80, 'boot code overruns the $FF80 RTI handler'
    print(f'  driver: {len(driver)} bytes, '
          f'${DRIVER_BASE:04X}-${DRIVER_BASE + len(driver) - 1:04X} '
          f'(source at $E200, limit $03BF), {ndrv} branches all in range')
    print(f'  boot:   {len(boot)} bytes at ${BOOT_BASE:04X}, '
          f'{nboot} branches all in range; RTI at $FF80, '
          f'vectors NMI/IRQ=$FF80 RESET=$FF00')

    flat = build_flat(driver, boot)
    with open(argv[1], 'wb') as f:
        f.write(flat)
    print(f'  -> {argv[1]} ({FLAT_SIZE} bytes): 64 ROML + 64 ROMH marker '
          f'banks, self-test in ROMH bank 0, 0xFF elsewhere')

    if len(argv) == 3:
        crt = build_crt(flat)
        with open(argv[2], 'wb') as f:
            f.write(crt)
        print(f'  -> {argv[2]} ({len(crt)} bytes, 128 CHIP packets, type 32)')
        # self-check: the .crt must unpack back to the identical flat image
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import crt2flat
        flat2, info = crt2flat.parse_crt(crt)
        if bytes(flat2) != bytes(flat):
            print('  Error: round-trip through crt2flat.parse_crt() differs')
            return 1
        assert len(info['roml']) == 64 and len(info['romh']) == 64
        print('  round-trip OK')

    print('  PASS: assembly self-checks (branch ranges, driver fits copy '
          'window, boot fits below $FF80)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
