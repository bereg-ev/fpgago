#!/usr/bin/env python3
"""
mk_sid_tables.py — extract the SID wave / filter tables from the upstream
MiSTer sid_tables.sv ('{...} array literals, un-synthesizable by yosys)
into plain $readmemh hex files consumed by the yosys-safe port
(sid_tables.v).

Usage:  python3 mk_sid_tables.py <path/to/upstream/sid_tables.sv> <out_dir>

Run once after a download_chips.sh refresh (which restores the upstream
.sv files); the generated roms/sid_*.hex are checked in, so a normal
build never needs this script.

Extracted (names = upstream array names):
  wave6581_p_t [2048]x8  -> sid_wave6581_pt.hex
  wave6581_ps_ [2048]x8  -> sid_wave6581_ps.hex
  wave8580_p_t [2048]x8  -> sid_wave8580_pt.hex
  wave8580_ps_ [4096]x8  -> sid_wave8580_ps.hex
  f6581_curve  [1024]x16 -> sid_f6581_curve.hex   (first 1024 of 4096 =
                            curve 0 "mixed calc"; the port hardwires the
                            MULTI_FILTERS=0 path)
  f6581_adj    [1024]x15 -> sid_f6581_adj.hex
"""
import re
import sys
import os

TABLES = [
    # (name, count, hex digits per entry)
    ("wave6581_p_t", 2048, 2, "sid_wave6581_pt.hex"),
    ("wave6581_ps_", 2048, 2, "sid_wave6581_ps.hex"),
    ("wave8580_p_t", 2048, 2, "sid_wave8580_pt.hex"),
    ("wave8580_ps_", 4096, 2, "sid_wave8580_ps.hex"),
    ("f6581_curve",  1024, 4, "sid_f6581_curve.hex"),
    ("f6581_adj",    1024, 4, "sid_f6581_adj.hex"),
]


def parse_values(body):
    vals = []
    for tok in body.split(","):
        tok = tok.strip()
        if not tok:
            continue
        m = re.match(r"'h([0-9a-fA-F]+)$", tok)
        if m:
            vals.append(int(m.group(1), 16))
        else:
            vals.append(int(tok, 10))
    return vals


def main():
    src_path, out_dir = sys.argv[1], sys.argv[2]
    src = open(src_path).read()
    # strip // comments (the f6581_curve block has "// N ..." headers)
    src = re.sub(r"//[^\n]*", "", src)

    for name, count, digits, out_name in TABLES:
        m = re.search(re.escape(name) + r"\s*\[[^\]]*\]\s*=\s*'\{(.*?)\};",
                      src, re.S)
        if not m:
            sys.exit(f"table {name} not found in {src_path}")
        vals = parse_values(m.group(1))
        if len(vals) < count:
            sys.exit(f"table {name}: got {len(vals)} entries, need {count}")
        out_path = os.path.join(out_dir, out_name)
        with open(out_path, "w") as f:
            for v in vals[:count]:
                f.write(f"{v:0{digits}x}\n")
        print(f"  {out_name}: {count} entries "
              f"(source had {len(vals)})")


if __name__ == "__main__":
    main()
