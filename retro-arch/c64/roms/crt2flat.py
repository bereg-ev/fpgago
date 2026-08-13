#!/usr/bin/env python3
"""
crt2flat.py — unpack an EasyFlash .crt into the 1 MiB flat image the RTL eats.

The cartridge RTL and the MCU loader want a plain byte-addressable image,
not a packet container:

    flat address = chip * 0x80000 + bank * 0x2000 + offset

with chip 0 = ROML ($8000 packets), chip 1 = ROMH ($A000/$E000 packets),
bank 0..63, offset 0..$1FFF.  Everything a CHIP packet did not cover stays
0xFF — erased flash, NEVER zero: EasyFlash menus and EAPI probe for erased
(0xFF) bytes to find free banks, and real flash erases to 0xFF.

Also reports whether the cart carries an EAPI driver blob (ROMH bank 0
offset $1800, signature "eapi"/"EAPI"): games save through EAPI, so a cart
without it cannot save.

Usage: crt2flat.py <input.crt> <output.flat>
"""

import os, struct, sys

BANKS = 64
BANK_SIZE = 0x2000
CHIP_SIZE = BANKS * BANK_SIZE          # 512 KiB per chip
FLAT_SIZE = 2 * CHIP_SIZE              # 1 MiB
EAPI_OFF = CHIP_SIZE + 0x1800          # chip 1 (ROMH), bank 0, offset $1800

# .crt hardware-type field values, for a helpful error message
HW_NAMES = {
    0: 'normal cartridge (8K/16K/ultimax)',
    1: 'Action Replay',
    2: 'KCS Power Cartridge',
    3: 'Final Cartridge III',
    5: 'Ocean type 1',
    19: 'Magic Desk',
    32: 'EasyFlash',
}


class CrtError(Exception):
    pass


def parse_crt(data):
    """Parse .crt file bytes -> (1 MiB flat bytearray, info dict)."""
    if len(data) < 0x40 or data[0:16] != b'C64 CARTRIDGE   ':
        raise CrtError('not a .crt file (bad magic)')
    header_len = struct.unpack_from('>I', data, 0x10)[0]
    if header_len < 0x40:
        header_len = 0x40
    hw_type = struct.unpack_from('>H', data, 0x16)[0]
    if hw_type != 32:
        name = HW_NAMES.get(hw_type, 'unknown type')
        raise CrtError(f'hardware type {hw_type} ({name}) — need 32 (EasyFlash)')
    name = data[0x20:0x40].split(b'\0')[0].decode('latin-1')

    flat = bytearray(b'\xFF' * FLAT_SIZE)
    roml, romh = set(), set()
    pos = header_len
    while pos < len(data):
        if data[pos:pos + 4] != b'CHIP':
            raise CrtError(f'bad CHIP magic at file offset 0x{pos:X}')
        if pos + 16 > len(data):
            raise CrtError(f'truncated CHIP header at file offset 0x{pos:X}')
        # packet length field is unreliable in the wild; advance by 16 + size
        _plen, _ctype, bank, load, size = struct.unpack_from('>IHHHH', data, pos + 4)
        if pos + 16 + size > len(data):
            raise CrtError(f'truncated CHIP data at file offset 0x{pos:X}')
        if bank >= BANKS:
            raise CrtError(f'CHIP bank {bank} out of range (0..63)')
        if size > BANK_SIZE:
            raise CrtError(f'CHIP size 0x{size:X} > 0x2000 (bank {bank})')
        if load == 0x8000:
            chip = 0
            roml.add(bank)
        elif load in (0xA000, 0xE000):
            chip = 1
            romh.add(bank)
        else:
            raise CrtError(f'CHIP load address ${load:04X} (bank {bank}) — '
                           f'expected $8000 (ROML) or $A000/$E000 (ROMH)')
        base = chip * CHIP_SIZE + bank * BANK_SIZE
        flat[base:base + size] = data[pos + 16:pos + 16 + size]
        # rest of the bank stays 0xFF (pre-filled)
        pos += 16 + size

    return flat, {'name': name, 'roml': roml, 'romh': romh}


def main(argv):
    if len(argv) != 3:
        print(f'Usage: {argv[0]} <input.crt> <output.flat>')
        return 1
    with open(argv[1], 'rb') as f:
        data = f.read()
    try:
        flat, info = parse_crt(data)
    except CrtError as e:
        print(f'  Error: {os.path.basename(argv[1])}: {e}')
        return 1

    print(f'  {os.path.basename(argv[1])}: "{info["name"]}" (EasyFlash, type 32)')
    print(f'  ROML banks: {len(info["roml"])}/64, ROMH banks: {len(info["romh"])}/64')

    sig = bytes(flat[EAPI_OFF:EAPI_OFF + 16])
    hexs = ' '.join(f'{b:02X}' for b in sig)
    asc = ''.join(chr(b) if 0x20 <= b < 0x7F else '.' for b in sig)
    print(f'  ROMH bank 0 offset $1800: {hexs}  |{asc}|')
    if sig[0:4].lower() == b'eapi':
        print('  EAPI: present')
    else:
        print('  EAPI: absent (game cannot save)')

    with open(argv[2], 'wb') as f:
        f.write(flat)
    print(f'  -> {argv[2]} ({FLAT_SIZE} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
