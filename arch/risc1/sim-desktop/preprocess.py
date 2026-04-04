#!/usr/bin/env python3
"""Pre-process Verilog files for Verilator: inline `include inside #(...) parameter blocks."""
import re, os

def inline_include(src_path, out_path, replacements):
    """Replace uncommented `include "file" with file contents (trailing comma stripped).
    Commented-out includes (// prefix) are left as-is."""
    with open(src_path) as f:
        text = f.read()
    for inc_name, inc_path in replacements:
        with open(inc_path) as f:
            data = f.read().rstrip().rstrip(',')
        # Only replace includes that are NOT commented out
        pattern = r'^(\s*)`include\s+"' + re.escape(inc_name) + r'"'
        def replacer(m):
            return m.group(1) + data
        text = re.sub(pattern, replacer, text, flags=re.MULTILINE)
    with open(out_path, 'w') as f:
        f.write(text)

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.join(here, '..', '..', '..')
peri = os.path.join(repo, 'peripheral')
font = os.path.join(repo, 'util', 'font2init')
proj = os.path.join(here, '..')

# lcd_char.v -> lcd_char_sim.v (inline font ROM)
inline_include(
    os.path.join(peri, 'lcd_char.v'),
    os.path.join(here, 'lcd_char_sim.v'),
    [('ibm8x16.vh', os.path.join(font, 'ibm8x16.vh'))])

# soc.v -> soc_sim.v (inline instruction ROM)
inline_include(
    os.path.join(proj, 'soc.v'),
    os.path.join(here, 'soc_sim.v'),
    [('romL.vh', os.path.join(proj, 'romL.vh'))])

print("Pre-processed: soc_sim.v, lcd_char_sim.v")
