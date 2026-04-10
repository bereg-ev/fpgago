#!/usr/bin/env python3
"""
rom_convert.py — Convert PET ROM binary dumps to Verilog $readmemh format.

Usage:
    python3 rom_convert.py convert <input.bin> <output.hex>
    python3 rom_convert.py combine-kernal <editor.bin> <kernal.bin> <output.hex>

The 'convert' command reads a raw binary and writes a hex file suitable
for Verilog's $readmemh() system task (one byte per line, 2-digit hex).

The 'combine-kernal' command builds the 8KB kernal image ($E000-$FFFF):
    $E000-$E7FF: editor ROM  (2KB)
    $E800-$EFFF: I/O window  (2KB of $FF — overridden by address decoder)
    $F000-$FFFF: kernal ROM  (4KB)
"""

import sys

def convert(infile, outfile):
    with open(infile, 'rb') as f:
        data = f.read()
    with open(outfile, 'w') as f:
        for byte in data:
            f.write(f'{byte:02x}\n')
    print(f'  {infile} ({len(data)} bytes) -> {outfile}')

def combine_kernal(editor_file, kernal_file, outfile):
    with open(editor_file, 'rb') as f:
        editor = f.read()
    with open(kernal_file, 'rb') as f:
        kernal = f.read()

    if len(editor) != 2048:
        print(f'Warning: editor ROM is {len(editor)} bytes, expected 2048')
    if len(kernal) != 4096:
        print(f'Warning: kernal ROM is {len(kernal)} bytes, expected 4096')

    # Build 8KB image: editor(2K) + FF-fill(2K) + kernal(4K)
    combined = bytearray(editor)
    combined += bytearray(b'\xff' * (4096 - len(editor)))  # pad to 4K
    combined += bytearray(kernal)

    with open(outfile, 'w') as f:
        for byte in combined:
            f.write(f'{byte:02x}\n')
    print(f'  {editor_file} ({len(editor)}B) + {kernal_file} ({len(kernal)}B) -> {outfile} ({len(combined)}B)')

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage:')
        print(f'  {sys.argv[0]} convert <input.bin> <output.hex>')
        print(f'  {sys.argv[0]} combine-kernal <editor.bin> <kernal.bin> <output.hex>')
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == 'convert' and len(sys.argv) == 4:
        convert(sys.argv[2], sys.argv[3])
    elif cmd == 'combine-kernal' and len(sys.argv) == 5:
        combine_kernal(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(f'Unknown command or wrong arguments: {sys.argv[1:]}')
        sys.exit(1)
