#!/usr/bin/env python3
"""
tzx2sna.py — Convert ZX Spectrum .tzx/.tap tape file to .sna snapshot format.

Creates a minimal 48K snapshot where:
- The tape's code/data blocks are loaded into RAM at their target addresses
- System variables are set up for a booted Spectrum
- PC is set to the start address of the code block (or BASIC RUN address)

Usage: tzx2sna.py <input.tzx|.tap> <output.sna>
"""

import sys, struct, os

def read_tzx_blocks(data):
    """Extract data blocks from TZX format."""
    blocks = []
    if data[:7] == b'ZXTape!':
        # TZX format
        i = 10  # skip header
        while i < len(data):
            block_id = data[i]
            i += 1
            if block_id == 0x10:  # Standard speed data block
                pause = struct.unpack_from('<H', data, i)[0]
                length = struct.unpack_from('<H', data, i+2)[0]
                block_data = data[i+4:i+4+length]
                blocks.append(block_data)
                i += 4 + length
            elif block_id == 0x11:  # Turbo speed data block
                length = struct.unpack_from('<H', data, i+15)[0] | (data[i+17] << 16)
                block_data = data[i+18:i+18+length]
                blocks.append(block_data)
                i += 18 + length
            elif block_id == 0x12:  # Pure tone
                i += 4
            elif block_id == 0x13:  # Pulse sequence
                n = data[i]
                i += 1 + n*2
            elif block_id == 0x14:  # Pure data block
                length = struct.unpack_from('<H', data, i+7)[0] | (data[i+9] << 16)
                i += 10 + length
            elif block_id == 0x15:  # Direct recording
                length = struct.unpack_from('<H', data, i+5)[0] | (data[i+7] << 16)
                i += 8 + length
            elif block_id == 0x20:  # Pause
                i += 2
            elif block_id == 0x21:  # Group start
                n = data[i]
                i += 1 + n
            elif block_id == 0x22:  # Group end
                pass
            elif block_id == 0x30:  # Text description
                n = data[i]
                i += 1 + n
            elif block_id == 0x32:  # Archive info
                length = struct.unpack_from('<H', data, i)[0]
                i += 2 + length
            elif block_id == 0x33:  # Hardware type
                n = data[i]
                i += 1 + n*3
            elif block_id == 0x35:  # Custom info
                length = struct.unpack_from('<I', data, i+16)[0]
                i += 20 + length
            else:
                print(f'  Warning: unknown TZX block type ${block_id:02X} at offset {i-1}')
                break
    else:
        # TAP format: sequence of length-prefixed blocks
        i = 0
        while i < len(data) - 1:
            length = struct.unpack_from('<H', data, i)[0]
            block_data = data[i+2:i+2+length]
            blocks.append(block_data)
            i += 2 + length
    return blocks

def make_sna(ram, pc=0x0000, sp=0xFF00, border=7, im=1):
    """Create a 48K .sna file from a RAM image."""
    # Push PC onto stack
    sp -= 2
    ram[sp - 0x4000] = pc & 0xFF
    ram[sp - 0x4000 + 1] = (pc >> 8) & 0xFF

    header = bytearray(27)
    # I=63 (standard IM1 vector page)
    header[0] = 0x3F
    # AF = $0044 (zero flag set)
    struct.pack_into('<H', header, 21, 0x0044)
    # SP
    struct.pack_into('<H', header, 23, sp)
    # IM
    header[25] = im
    # Border
    header[26] = border
    # IY = $5C3A (standard)
    struct.pack_into('<H', header, 15, 0x5C3A)

    return bytes(header) + bytes(ram)

def convert(infile, outfile):
    with open(infile, 'rb') as f:
        data = f.read()

    blocks = read_tzx_blocks(data)
    print(f'  {os.path.basename(infile)}: {len(blocks)} tape blocks')

    # Initialize RAM with a clean booted Spectrum state
    ram = bytearray(49152)  # 48K, maps to $4000-$FFFF

    # Set up attributes to white paper / black ink
    for i in range(768):
        ram[0x1800 + i] = 0x38

    # Set up essential system variables (IY+offset from $5C3A)
    sysvars_base = 0x5C00 - 0x4000  # RAM offset for $5C00
    # KSTATE
    ram[sysvars_base + 0x00] = 0xFF
    ram[sysvars_base + 0x04] = 0xFF
    # FLAGS ($5C3B) = $4C (L mode, no key)
    ram[sysvars_base + 0x3B - 0x5C00 + 0x1C00] = 0x4C
    # TV_FLAG ($5C3C) = $01
    ram[sysvars_base + 0x3C - 0x5C00 + 0x1C00] = 0x01
    # CHARS ($5C36) = $3C00 (character set - 256)
    struct.pack_into('<H', ram, 0x1C36, 0x3C00)
    # RAMTOP ($5CB2) = $FF57
    struct.pack_into('<H', ram, 0x1CB2, 0xFF57)
    # UDG ($5C7B) = $FF58
    struct.pack_into('<H', ram, 0x1C7B, 0xFF58)

    # Process tape blocks
    code_start = None
    for block in blocks:
        if len(block) < 2:
            continue
        flag = block[0]
        if flag == 0x00 and len(block) == 19:
            # Header block
            htype = block[1]
            name = block[2:12].decode('ascii', errors='replace').strip()
            data_len = struct.unpack_from('<H', block, 12)[0]
            param1 = struct.unpack_from('<H', block, 14)[0]
            param2 = struct.unpack_from('<H', block, 16)[0]
            type_names = {0: 'Program', 1: 'Number array', 2: 'Char array', 3: 'Code'}
            print(f'    Header: {type_names.get(htype, "?")} "{name}" len={data_len} param1=${param1:04X} param2=${param2:04X}')
            if htype == 3:  # Code block
                code_start = param1  # load address
            elif htype == 0:  # BASIC program
                code_start = 0x5CCB  # BASIC program area
        elif flag == 0xFF and len(block) > 2:
            # Data block
            payload = block[1:-1]  # strip flag byte and checksum
            if code_start is not None:
                addr = code_start
                ram_offset = addr - 0x4000
                if ram_offset >= 0 and ram_offset + len(payload) <= len(ram):
                    ram[ram_offset:ram_offset+len(payload)] = payload
                    print(f'    Data: {len(payload)} bytes loaded at ${addr:04X}-${addr+len(payload)-1:04X}')
                else:
                    print(f'    Data: {len(payload)} bytes at ${addr:04X} (outside RAM range)')
                code_start = None

    # Determine entry point by scanning BASIC data blocks for USR token ($C0)
    entry = 0x0000
    for block in blocks:
        if len(block) > 2 and block[0] == 0xFF:
            payload = block[1:-1]
            for i in range(len(payload) - 1):
                if payload[i] == 0xC0:  # USR token
                    # Read ASCII number after USR
                    j = i + 1
                    # Skip spaces
                    while j < len(payload) and payload[j] == 0x20:
                        j += 1
                    num_str = ""
                    while j < len(payload) and 0x30 <= payload[j] <= 0x39:
                        num_str += chr(payload[j])
                        j += 1
                    if num_str:
                        entry = int(num_str)
                        break
        if entry:
            break

    # Fallback: use the last code block's load address
    if entry == 0:
        for block in blocks:
            if len(block) == 19 and block[0] == 0x00 and block[1] == 3:
                entry = struct.unpack_from('<H', block, 14)[0]

    if entry == 0:
        entry = 0x12AC  # fallback: ROM main loop

    # Set up PROG ($5C53) for BASIC programs
    struct.pack_into('<H', ram, 0x1C53, 0x5CCB)

    print(f'    Entry point: ${entry:04X}')

    sna_data = make_sna(ram, pc=entry, border=7)
    with open(outfile, 'wb') as f:
        f.write(sna_data)

    print(f'    -> {outfile} ({len(sna_data)} bytes)')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.tzx|.tap> <output.sna>')
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
