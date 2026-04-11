#!/usr/bin/env python3
"""
rom_convert.py — Convert Plus/4 ROM binary dumps to Verilog $readmemh format.

Usage:
    python3 rom_convert.py convert <input.bin> <output.hex>
    python3 rom_convert.py convert-chargen <input.bin> <output.hex>

The 'convert' command writes a plain hex file (one byte per line).
The 'convert-chargen' command extracts only the first 2KB from the
16KB character ROM file (c2lo-364.bin contains multiple character sets;
we only use the first one).
"""

import sys

def convert(infile, outfile):
    with open(infile, 'rb') as f:
        data = f.read()
    with open(outfile, 'w') as f:
        for byte in data:
            f.write(f'{byte:02x}\n')
    print(f'  {infile} ({len(data)} bytes) -> {outfile}')

def convert_chargen(infile, outfile):
    """Extract 2KB character ROM from KERNAL ROM at offset $1000 ($D000-$D7FF)."""
    with open(infile, 'rb') as f:
        data = f.read()
    chardata = data[0x1000:0x1800]  # $D000-$D7FF within KERNAL ($C000-based)
    with open(outfile, 'w') as f:
        for byte in chardata:
            f.write(f'{byte:02x}\n')
    print(f'  {infile} (chargen at $D000, 2048 bytes) -> {outfile}')

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage:')
        print(f'  {sys.argv[0]} convert <input.bin> <output.hex>')
        print(f'  {sys.argv[0]} convert-chargen <input.bin> <output.hex>')
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == 'convert' and len(sys.argv) == 4:
        convert(sys.argv[2], sys.argv[3])
    elif cmd == 'convert-chargen' and len(sys.argv) == 4:
        convert_chargen(sys.argv[2], sys.argv[3])
    else:
        print(f'Unknown command or wrong arguments: {sys.argv[1:]}')
        sys.exit(1)
