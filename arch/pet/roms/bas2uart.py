#!/usr/bin/env python3
"""
bas2uart.py — Convert a BASIC text file to a UART input file.

Reads a .bas file (plain text, one BASIC line per line) and writes
a binary file of bytes to be injected into the PET via UART.  Each
source line is terminated with 0x0D (RETURN).  A trailing "RUN\\r"
is appended.

The sim_top.cpp auto-typer reads this file and feeds it to the UART
queue after the PET boots.

Usage:
    python3 bas2uart.py <input.bas> <output.uart>
"""

import sys

def convert(infile, outfile):
    with open(infile, 'r') as f:
        lines = f.readlines()

    out = bytearray()
    for line in lines:
        line = line.rstrip('\n\r')
        if not line:
            continue
        # Convert to LOWERCASE — the PET keyboard mapper treats lowercase
        # ASCII as unshifted keys, which produce uppercase on the PET.
        # Uppercase ASCII adds SHIFT, producing graphics characters.
        for ch in line:
            c = ord(ch)
            if 0x41 <= c <= 0x5A:  # A-Z → a-z
                out.append(c + 0x20)
            elif 0x20 <= c <= 0x7E:
                out.append(c)
        out.append(0x0D)  # RETURN

    # Append RUN command (lowercase!)
    out.extend(b'run\x0D')

    with open(outfile, 'wb') as f:
        f.write(out)

    print(f'  {infile}: {len(lines)} lines -> {outfile} ({len(out)} bytes)')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.bas> <output.uart>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
