#!/usr/bin/env python3
"""
prg2hex.py — Convert a Plus/4 .prg into the files a GAME_PRG build needs.

The PRG is baked into the machine RAM's *init image* (full 64KB game.hex,
$readmemh into the ram array), which costs zero extra BRAM on the FPGA and
survives board resets.  The KERNAL boot only clobbers low memory
($0000-$0FE7), the BASIC NEW marker at $1000-$1002, one RAM-size probe
byte at $7FFF and the KERNAL top pages ($FCF9+/$FFF6+) — measured with the
soc.v +wrlog logger — so the autorun script simply re-POKEs the few PRG
bytes the boot destroyed, then fixes the BASIC pointers and types RUN.
The autorun script itself is baked as autorun.hex and typed by hardware
(common/boot_typer.v) after boot: no host, MCU or UART needed.

Outputs (all next to <output.hex>):
    game.hex      full-RAM init image (65536 lines)
    autorun.hex   boot_typer script ROM (128 bytes, 0-terminated)
    <autorun.uart> same script as raw bytes (reference / manual --autotype)

Usage:
    python3 prg2hex.py <input.prg> <output.hex> <autorun.uart>
"""

import sys, os

RAM_SIZE    = 65536
BASIC_START = 0x1001
AUTORUN_ROM = 128            # boot_typer SIZE parameter
MAX_LINE    = 70             # BASIC direct-mode line budget (88 max on 3.5)

# Addresses the KERNAL writes between reset and READY (+wrlog measurement,
# 2026-07-08), padded conservatively: everything below BASIC start, the
# $7FFF RAM-size probe, and the KERNAL top pages.
BOOT_CLOBBER = set(range(0x0000, 0x1003)) | {0x7FFF} | set(range(0xFCF9, 0x10000))

def build_autorun(load_addr, program):
    """Restore POKEs for boot-clobbered PRG bytes + pointer POKEs + RUN."""
    stmts = []
    clobbered = [i for i in range(len(program))
                 if (load_addr + i) in BOOT_CLOBBER]
    if len(clobbered) > 24:
        print(f'  Error: {len(clobbered)} PRG bytes fall in the boot-clobbered\n'
              f'  region (program loads at ${load_addr:04X}, below BASIC start\n'
              f'  ${BASIC_START:04X}?).  Load it through the floppy instead:\n'
              f'  make run-floppy ARCH=plus4 PRG=<file> [FAST=1]')
        sys.exit(1)
    for i in clobbered:
        stmts.append(f'poke{load_addr + i},{program[i]}')

    # BASIC end-of-program/variables pointer ($2D/$2E), one past the end
    # marker, so CLR+RUN see the preloaded program.
    end_vars = load_addr + len(program) + 1
    stmts.append(f'poke45,{end_vars & 0xFF}')
    stmts.append(f'poke46,{(end_vars >> 8) & 0xFF}')

    # Pack statements into direct-mode lines of at most MAX_LINE chars.
    lines, cur = [], ''
    for s in stmts:
        cand = s if not cur else cur + ':' + s
        if len(cand) > MAX_LINE:
            lines.append(cur)
            cur = s
        else:
            cur = cand
    if cur:
        lines.append(cur)
    return '\r'.join(lines) + '\rclr\rrun\r'

def convert(infile, hexfile, uartfile):
    with open(infile, 'rb') as f:
        data = f.read()
    if len(data) < 3:
        print(f'Error: {infile} is too small ({len(data)} bytes)')
        sys.exit(1)

    load_addr = data[0] | (data[1] << 8)
    program = data[2:]
    end_addr = load_addr + len(program) - 1
    if end_addr >= RAM_SIZE:
        print(f'Error: PRG ${load_addr:04X}-${end_addr:04X} exceeds 64KB RAM')
        sys.exit(1)

    # Full-RAM init image: zeros + PRG at its load address.  A full image
    # (rather than an @offset fragment) keeps the $readmemh trivially
    # synthesizable as BRAM init.
    image = bytearray(RAM_SIZE)
    image[load_addr:load_addr + len(program)] = program
    with open(hexfile, 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in image) + '\n')

    autorun = build_autorun(load_addr, program)
    if len(autorun) + 1 > AUTORUN_ROM:
        print(f'Error: autorun script is {len(autorun)} bytes '
              f'(> {AUTORUN_ROM - 1}); raise boot_typer SIZE')
        sys.exit(1)

    with open(uartfile, 'wb') as f:
        f.write(autorun.encode('ascii'))

    script = autorun.encode('ascii') + b'\x00' * (AUTORUN_ROM - len(autorun))
    autorun_hex = os.path.join(os.path.dirname(os.path.abspath(hexfile)),
                               'autorun.hex')
    with open(autorun_hex, 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in script) + '\n')

    print(f'  {infile}: {len(program)} bytes at ${load_addr:04X}-${end_addr:04X} -> {hexfile}')
    print(f'  autorun ({len(autorun)} bytes): ' +
          autorun.rstrip('\r').replace('\r', ' | '))
    print(f'  -> {uartfile}, {autorun_hex}')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f'Usage: {sys.argv[0]} <input.prg> <output.hex> <autorun.uart>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
