# Third-party components

Everything under `retro-arch/`, `peripheral/` and `util/` is our own work
unless it appears below. Each imported file keeps its original licence header;
this table is the index, not a replacement for those headers.

| what | where | project | licence |
|---|---|---|---|
| VIC-II video chip | `retro-arch/c64/vic/` | [vicii-kawari](https://github.com/randyrossi/vicii-kawari), Randy Rossi | GPL-3.0 |
| SID sound chip | `retro-arch/c64/sid/` | [C64_MiSTer](https://github.com/MiSTer-devel/C64_MiSTer) `rtl/sid` | GPL |
| MOS 6526 CIA | `retro-arch/c64/cpu/mos6526.v` | [C64_MiSTer](https://github.com/MiSTer-devel/C64_MiSTer), Rayne + slingshot | GPL |
| MOS 8360 TED | `retro-arch/plus4/fpgated.v`, `retro-arch/c16/ted.v` | [FPGATED](https://github.com/istvanv/fpgated), Istvan Hegedus | GPL-3.0 |
| 6502 CPU core | `retro-arch/common/cpu/6502/cpu_6502.v`, `ALU.v` | Arlet Ottens' [verilog-6502](https://github.com/Arlet/verilog-6502) | permissive (keep the notice) |

The SID core in `retro-arch/c64/sid/` is a plain-Verilog rewrite of the MiSTer
SystemVerilog original (yosys cannot synthesize its `'{...}` array literals);
the wave and filter tables in `retro-arch/c64/roms/sid_*.hex` are extracted
from that same upstream source by `retro-arch/c64/sid/mk_sid_tables.py` and
checked in so a fresh clone can build without re-running the download.

`retro-arch/c64/cpu/download_chips.sh` refetches the VIC-II, SID and CIA from
upstream; run it after an upstream bump, then re-run `mk_sid_tables.py`.

## What is *not* here

No Commodore ROM images (KERNAL, BASIC, chargen, the 1541 DOS), no ROM-baked
bitstreams, and no game dumps. Those are copyrighted by their owners and are
never committed — see the copyright fence at the bottom of `.gitignore`.
`make download-rom ARCH=<machine>` fetches the ROMs from the
[VICE](https://vice-emu.sourceforge.io/) project onto your own disk after an
explicit consent prompt.

## Licence of this repository

FPGAgo is **GPL-3.0-or-later** — the full text is in [`LICENSE`](LICENSE).
That is also what the Commodore cores above require: they are GPL, so
anything built against them is distributed under the GPL as well.

Files that carry their own licence header keep it. Arlet Ottens' 6502 is the
one permissive component; its notice must travel with the code, and it
combines into the GPL work without friction.
