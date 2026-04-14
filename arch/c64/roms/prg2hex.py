#!/usr/bin/env python3
"""
prg2hex.py — Convert a C64 .prg file to $readmemh format for RAM pre-loading.

The PRG starts with a 2-byte load address (little-endian), followed by the
program data. This script creates a hex file that can be loaded into the
C64's 64K RAM via $readmemh, and a params file with the load range.

Usage: prg2hex.py <input.prg> <output.hex>
"""

import sys, os, struct

def convert(infile, hexfile):
    with open(infile, 'rb') as f:
        data = f.read()

    if len(data) < 3:
        print(f'  Error: {infile} too small')
        sys.exit(1)

    load_addr = data[0] | (data[1] << 8)
    program = data[2:]
    end_addr = load_addr + len(program) - 1

    print(f'  {os.path.basename(infile)}: {len(program)} bytes at ${load_addr:04X}-${end_addr:04X}')

    # Write hex file with @address directive
    with open(hexfile, 'w') as f:
        f.write(f'@{load_addr:04x}\n')
        for byte in program:
            f.write(f'{byte:02x}\n')

    # Write params
    paramfile = os.path.splitext(hexfile)[0] + '_params.vh'
    with open(paramfile, 'w') as f:
        f.write(f'localparam [15:0] GAME_START = 16\'h{load_addr:04X};\n')
        f.write(f'localparam [15:0] GAME_END   = 16\'h{end_addr:04X};\n')

    # Write autorun command
    # KERNAL init writes $00 $00 at $0801-$0802 (BASIC NEW), destroying the
    # first two bytes of any program loaded at $0801.  We restore them via
    # POKE before issuing the SYS/RUN command.
    #
    # BASIC line format: link_lo link_hi linenum_lo linenum_hi tokens...
    # SYS token = $9E

    # Build POKE prefix to restore $0801-$0802 if program loads there
    poke_prefix = ''
    if load_addr == 0x0801 and len(program) >= 2:
        poke_prefix = f'poke2049,{program[0]}:poke2050,{program[1]}:'

    autorun = None
    if len(program) > 5 and program[4] == 0x9E:
        # SYS token found — extract ASCII digits
        i = 5
        while i < len(program) and program[i] == 0x20: i += 1
        digits = ''
        while i < len(program) and 0x30 <= program[i] <= 0x39:
            digits += chr(program[i]); i += 1
        if digits:
            autorun = f'{poke_prefix}sys{digits}\r'
            print(f'  Autorun: {poke_prefix}SYS {digits}')

    if not autorun:
        # For RUN, also fix VARTAB so BASIC knows program length
        vt = end_addr + 1
        vt_poke = f'poke45,{vt & 0xFF}:poke46,{vt >> 8}:'
        autorun = f'{poke_prefix}{vt_poke}run\r'
        print(f'  Autorun: {poke_prefix}{vt_poke}RUN')

    uartfile = os.path.splitext(hexfile)[0] + '.uart'
    with open(uartfile, 'wb') as f:
        f.write(autorun.encode())

    print(f'  -> {hexfile}')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.prg> <output.hex>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
