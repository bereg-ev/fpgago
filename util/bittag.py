#!/usr/bin/env python3
"""bittag.py -- read or set the "gc:" metadata tag in an ECP5 .bit header.

Every ecppack .bit starts with a comment block the config engine ignores:

    FF 00 <NUL-terminated ASCII strings> FF ... BD B3 (preamble)

This tool inserts (or replaces) one extra string, "gc: key=value ...", so the
MCU can check a bitstream against the board it is about to program (interlock:
a wrong-board bit drives the wrong balls the instant DONE rises).  The MCU
side of this lives in the board firmware/bitmeta.c -- keep the formats in sync.

Usage:
    bittag.py file.bit                      print the comment strings
    bittag.py file.bit hw=v2 arch=c64 ...   set/replace the gc: tag

Keys are free-form ASCII (no spaces).  The MCU interlock reads "hw", which
may be a comma list for bits that run on several boards: hw=v2,v3.
"""
import sys


def parse_comment(data):
    """Return (strings, end) where end = offset of the terminating 0xFF."""
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0x00:
        sys.exit(f"error: no ECP5 comment header (FF 00) -- not a .bit?")
    strings = []
    i = 2
    while True:
        if i >= len(data):
            sys.exit("error: malformed comment header (no FF terminator)")
        if data[i] == 0xFF:
            return strings, i
        j = i
        while j < len(data) and data[j] not in (0x00, 0xFF):
            j += 1
        if j >= len(data) or data[j] != 0x00:
            sys.exit("error: malformed comment header (unterminated string)")
        try:
            strings.append(data[i:j].decode("ascii"))
        except UnicodeDecodeError:
            sys.exit("error: non-ASCII bytes in comment header")
        i = j + 1


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path, "rb") as f:
        data = f.read()
    strings, end = parse_comment(data)

    if len(sys.argv) == 2:          # read mode
        for s in strings:
            print(s)
        return

    for kv in sys.argv[2:]:
        if ("=" not in kv or " " in kv or not kv.isascii()
                or not kv.isprintable()):
            sys.exit(f"error: bad key=value argument: {kv!r}")
    tag = "gc: " + " ".join(sys.argv[2:])

    kept = [s for s in strings if not s.startswith("gc:")]
    block = b"".join(s.encode("ascii") + b"\0" for s in kept + [tag])
    with open(path, "wb") as f:
        f.write(bytes([0xFF, 0x00]) + block + data[end:])
    print(f"  Tagged {path}: {tag}")


if __name__ == "__main__":
    main()
