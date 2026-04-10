#!/usr/bin/env python3
"""Convert ZX Spectrum ROM binary to Verilog $readmemh hex format."""

import sys

def convert(infile, outfile):
    with open(infile, 'rb') as f:
        data = f.read()
    with open(outfile, 'w') as f:
        for byte in data:
            f.write(f'{byte:02x}\n')
    print(f'  {infile} -> {outfile} ({len(data)} bytes)')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.bin> <output.hex>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
