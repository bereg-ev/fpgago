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
        f.write(f'localparam [15:0] GAME_START = 16\'h{load_addr:04x};\n')
        f.write(f'localparam [15:0] GAME_END   = 16\'h{end_addr:04x};\n')

    print(f'  {infile}: {len(program)} bytes at ${load_addr:04X}-${end_addr:04X} -> {hexfile}')

    # Generate autorun:
    #   poke64829,1  — writes to $FD3D, triggers hardware game copy
    #   poke45,lo:poke46,hi  — set BASIC end-of-variables pointer ($2D/$2E)
    #                          so RUN knows the program exists
    #   run          — starts the game
    end_vars = load_addr + len(program) + 1  # one past the end marker
    lo = end_vars & 0xFF
    hi = (end_vars >> 8) & 0xFF
    autorun = f'poke64829,1:poke45,{lo}:poke46,{hi}\rclr\rrun\r'
    with open(uartfile, 'wb') as f:
        f.write(autorun.encode('ascii'))

    print(f'  autorun: {uartfile}')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f'Usage: {sys.argv[0]} <input.prg> <output.hex> <autorun.uart>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
