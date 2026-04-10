#!/usr/bin/env python3
"""
prg2hex.py — Convert a PET .prg file to $readmemh format for RAM loading,
             and generate an autorun.uart that types RUN after boot.

Usage:
    python3 prg2hex.py <input.prg> <output.hex> <autorun.uart>
"""

import sys

def convert(infile, hexfile, uartfile):
    with open(infile, 'rb') as f:
        data = f.read()

    if len(data) < 3:
        print(f'Error: {infile} is too small ({len(data)} bytes)')
        sys.exit(1)

    load_addr = data[0] | (data[1] << 8)
    program = data[2:]

    # Write hex file for $readmemh (loaded into game_rom shadow array)
    with open(hexfile, 'w') as f:
        f.write(f'@{load_addr:04x}\n')
        for byte in program:
            f.write(f'{byte:02x}\n')

    # Write a Verilog include with the game address range
    paramfile = hexfile.replace('.hex', '_params.vh')
    end_addr = load_addr + len(program) - 1
    with open(paramfile, 'w') as f:
        f.write(f'localparam [14:0] GAME_START = 15\'h{load_addr:04x};\n')
        f.write(f'localparam [14:0] GAME_END   = 15\'h{end_addr:04x};\n')

    print(f'  {infile}: {len(program)} bytes at ${load_addr:04X}-${end_addr:04X} -> {hexfile}')

    # Generate autorun:
    #   poke59632,1  — writes to $E8F0, triggers hardware game copy
    #   run          — starts the game after copy completes
    # (59632 = 0xE8F0, the game-load trigger I/O address)
    with open(uartfile, 'wb') as f:
        f.write(b'poke59632,1\rrun\r')

    print(f'  autorun: {uartfile}')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f'Usage: {sys.argv[0]} <input.prg> <output.hex> <autorun.uart>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
