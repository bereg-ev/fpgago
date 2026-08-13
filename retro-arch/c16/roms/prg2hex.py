#!/usr/bin/env python3
"""
prg2hex.py — Convert a C16 .prg into the files a GAME_PRG build needs.

Same scheme as plus4/roms/prg2hex.py (see there for the full story), with
the C16's 16KB physical RAM: the image is 16384 bytes and CPU addresses
wrap with & $3FFF (the 64KB map mirrors the 16KB four times).  The KERNAL
boot clobbers low memory ($0000-$0FE7), the BASIC NEW marker at
$1000-$1002 and the KERNAL top-of-RAM block at $3FEF-$3FFD (measured with
the soc.v +wrlog logger); the autorun script re-POKEs the clobbered PRG
bytes, fixes the BASIC pointers and types RUN via common/boot_typer.v.

Outputs (all next to <output.hex>):
    game.hex      full-RAM init image (16384 lines, physical space)
    autorun.hex   boot_typer script ROM (128 bytes, 0-terminated)
    <autorun.uart> same script as raw bytes (reference / manual --autotype)

Usage:
    python3 prg2hex.py <input.prg> <output.hex> <autorun.uart>
"""

import sys, os

RAM_SIZE    = 16384          # physical; CPU space wraps with & $3FFF
RAM_MASK    = RAM_SIZE - 1
BASIC_START = 0x1001
AUTORUN_ROM = 128            # boot_typer SIZE parameter
MAX_LINE    = 70             # BASIC direct-mode line budget (88 max on 3.5)

# Physical addresses the KERNAL writes between reset and READY (+wrlog
# measurement, 2026-07-08), padded conservatively: everything below BASIC
# start plus the KERNAL top-of-RAM block.
BOOT_CLOBBER = set(range(0x0000, 0x1003)) | set(range(0x3FEF, 0x4000))

def build_autorun(load_addr, program):
    """Restore POKEs for boot-clobbered PRG bytes + pointer POKEs + RUN."""
    stmts = []
    clobbered = [i for i in range(len(program))
                 if ((load_addr + i) & RAM_MASK) in BOOT_CLOBBER]
    if len(clobbered) > 24:
        print(f'  Error: {len(clobbered)} PRG bytes fall in the boot-clobbered\n'
              f'  region (program loads at ${load_addr:04X}, below BASIC start\n'
              f'  ${BASIC_START:04X}?).  Load it through the floppy instead:\n'
              f'  make run-floppy ARCH=c16 PRG=<file> [FAST=1]')
        sys.exit(1)
    for i in clobbered:
        stmts.append(f'poke{load_addr + i},{program[i]}')

    end_vars = load_addr + len(program) + 1
    stmts.append(f'poke45,{end_vars & 0xFF}')
    stmts.append(f'poke46,{(end_vars >> 8) & 0xFF}')

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
    if len(program) > RAM_SIZE:
        print(f'Error: PRG is {len(program)} bytes, more than 16KB RAM')
        sys.exit(1)

    image = bytearray(RAM_SIZE)
    for i, b in enumerate(program):
        image[(load_addr + i) & RAM_MASK] = b
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
