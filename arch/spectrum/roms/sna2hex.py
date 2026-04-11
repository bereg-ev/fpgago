#!/usr/bin/env python3
"""
sna2hex.py — Convert ZX Spectrum .sna snapshot to Verilog $readmemh format.

SNA 48K format:
  Offset  Size  Description
  0       1     I register
  1-2     2     HL'
  3-4     2     DE'
  5-6     2     BC'
  7-8     2     AF'
  9-10    2     HL
  11-12   2     DE
  13-14   2     BC
  15-16   2     IY
  17-18   2     IX
  19      1     IFF2 (bit 2)
  20      1     R register
  21-22   2     AF
  23-24   2     SP
  25      1     Interrupt mode (0, 1, 2)
  26      1     Border color
  27+     49152 RAM dump ($4000-$FFFF)

PC is NOT stored directly — it's on the stack (pushed before snapshot).
Entry point = RAM[SP] | (RAM[SP+1] << 8), SP then += 2.

Usage: sna2hex.py <input.sna> <output.hex>
"""

import sys, os

def convert(infile, hexfile):
    with open(infile, 'rb') as f:
        data = f.read()

    if len(data) != 49179:  # 27 header + 49152 RAM
        print(f'  Error: {infile} is {len(data)} bytes, expected 49179 (48K .sna)')
        sys.exit(1)

    header = data[:27]
    ram = data[27:]  # 49152 bytes, maps to $4000-$FFFF

    sp = header[23] | (header[24] << 8)
    border = header[26] & 7
    int_mode = header[25]

    # Extract PC from stack
    sp_offset = sp - 0x4000
    if sp_offset < 0 or sp_offset + 1 >= len(ram):
        print(f'  Warning: SP=${sp:04X} outside RAM range')
        pc = 0
    else:
        pc = ram[sp_offset] | (ram[sp_offset + 1] << 8)
        # "Pop" PC from stack in the RAM dump (restore SP)
        ram = bytearray(ram)
        ram[sp_offset] = 0
        ram[sp_offset + 1] = 0

    sp_restored = sp + 2

    print(f'  {os.path.basename(infile)}: 48K snapshot')
    print(f'    PC=${pc:04X}  SP=${sp_restored:04X}  IM={int_mode}  Border={border}')

    # Write RAM hex file (for $readmemh, 49152 bytes at offset 0 = $4000 in CPU space)
    with open(hexfile, 'w') as f:
        for byte in ram:
            f.write(f'{byte:02x}\n')

    # Write parameters file
    paramfile = os.path.splitext(hexfile)[0] + '_params.vh'
    with open(paramfile, 'w') as f:
        f.write(f'localparam [15:0] GAME_PC = 16\'h{pc:04X};\n')
        f.write(f'localparam [15:0] GAME_SP = 16\'h{sp_restored:04X};\n')
        f.write(f'localparam [2:0]  GAME_BORDER = 3\'d{border};\n')
        f.write(f'localparam [1:0]  GAME_IM = 2\'d{int_mode};\n')

    print(f'    -> {hexfile}, {paramfile}')

    # Write autorun: RANDOMIZE USR <pc>
    uartfile = os.path.splitext(hexfile)[0] + '.uart'
    with open(uartfile, 'wb') as f:
        # On Spectrum, 'T' in K-mode = RANDOMIZE, then type " USR <addr>"
        # But USR needs symbol shift... too complex.
        # Instead, use PRINT USR: 'P' = PRINT in K-mode, then type rest
        # Actually simplest: just load RAM and skip ROM init entirely.
        # For now, write a placeholder — the hardware will handle startup.
        pass

    print(f'    Entry: RANDOMIZE USR {pc}')
    return pc, border

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.sna> <output.hex>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
