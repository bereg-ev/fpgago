#!/usr/bin/env python3
"""
d64extract.py — Extract the first PRG file from a C64 .d64 disk image.

D64 format: 35 tracks, 683 sectors of 256 bytes = 174848 bytes.
Directory is at track 18, sector 1. Each directory entry is 32 bytes.
File data follows the track/sector chain from the directory entry.

Usage: d64extract.py <input.d64> <output.prg>
"""

import sys, os, struct

# Track layout: tracks 1-17 have 21 sectors, 18-24 have 19, 25-30 have 18, 31-35 have 17
SECTORS_PER_TRACK = (
    [0] +           # track 0 doesn't exist
    [21]*17 +       # tracks 1-17
    [19]*7 +        # tracks 18-24
    [18]*6 +        # tracks 25-30
    [17]*5          # tracks 31-35
)

def track_sector_to_offset(track, sector):
    """Convert track/sector to byte offset in D64 file."""
    offset = 0
    for t in range(1, track):
        offset += SECTORS_PER_TRACK[t] * 256
    offset += sector * 256
    return offset

def extract(d64file, prgfile):
    with open(d64file, 'rb') as f:
        data = f.read()

    if len(data) < 174848:
        print(f'  Warning: {d64file} is {len(data)} bytes (expected 174848)')

    # Read directory at track 18, sector 1
    dir_track, dir_sector = 18, 1
    files_found = []

    while dir_track != 0:
        offset = track_sector_to_offset(dir_track, dir_sector)
        # Next directory sector
        dir_track = data[offset]
        dir_sector = data[offset + 1]

        # 8 directory entries per sector (32 bytes each), starting at byte 2
        for i in range(8):
            entry_offset = offset + (i * 32) if i > 0 else offset
            if i == 0:
                entry_offset = offset  # first entry starts at offset 2 of sector
                # Actually first entry in first dir sector starts at byte 0+2=2
                # but the entry structure starts at the file type byte
                entry_offset = offset + 2  # skip next track/sector link

            e = offset + 2 + i * 32 if i > 0 else offset + 2
            if e + 30 > len(data):
                break

            file_type = data[e] & 0x0F
            if file_type == 0:
                continue  # deleted/empty

            file_track = data[e + 1]
            file_sector = data[e + 2]
            filename = data[e + 3:e + 19].decode('ascii', errors='replace').rstrip('\xa0').rstrip()
            file_size_sectors = data[e + 28] | (data[e + 29] << 8)

            type_names = {1: 'SEQ', 2: 'PRG', 3: 'USR', 4: 'REL'}
            type_name = type_names.get(file_type, f'?{file_type}')

            files_found.append({
                'name': filename,
                'type': file_type,
                'type_name': type_name,
                'track': file_track,
                'sector': file_sector,
                'size_sectors': file_size_sectors,
            })

        if dir_track == 0:
            break

    if not files_found:
        print(f'  No files found in {d64file}')
        sys.exit(1)

    print(f'  {os.path.basename(d64file)}: {len(files_found)} files')
    for f in files_found:
        marker = '  >>>' if f['type'] == 2 else '     '
        print(f'{marker} {f["type_name"]} "{f["name"]}" ({f["size_sectors"]} sectors)')

    # Find first PRG file
    prg = None
    for f in files_found:
        if f['type'] == 2:  # PRG
            prg = f
            break

    if not prg:
        # Fall back to first file of any type
        prg = files_found[0]
        print(f'  No PRG found, using first file: "{prg["name"]}"')

    # Follow track/sector chain to extract file data
    file_data = bytearray()
    t, s = prg['track'], prg['sector']
    while t != 0:
        off = track_sector_to_offset(t, s)
        next_t = data[off]
        next_s = data[off + 1]
        if next_t == 0:
            # Last sector: next_s = number of bytes used in this sector
            file_data.extend(data[off + 2:off + 2 + next_s - 1])
        else:
            file_data.extend(data[off + 2:off + 256])
        t, s = next_t, next_s

    print(f'  Extracted "{prg["name"]}": {len(file_data)} bytes')

    with open(prgfile, 'wb') as f:
        f.write(file_data)

    print(f'  -> {prgfile}')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input.d64> <output.prg>')
        sys.exit(1)
    extract(sys.argv[1], sys.argv[2])
