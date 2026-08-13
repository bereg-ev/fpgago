# Prebuilt bitstreams

The ROM-free (`ROMLESS`) Commodore builds, committed so a fresh clone can
flash a machine **without installing the FPGA toolchain first**.

| file | machine | board | ROM banks it needs |
|---|---|---|---|
| `c64-romless.bit`   | Commodore 64 (+ EasyFlash cart port) | HW=v2 | kernal, basic, chargen |
| `c16-romless.bit`   | Commodore 16 | HW=v2 | kernal, basic |
| `plus4-romless.bit` | Commodore Plus/4 | HW=v2 | kernal, basic |

All three carry the QSPI link, the BIOS overlay and the combined real-1541 +
fastload drive (the `IEC=1` default) — they are the same builds
`make build ARCH=<m> TARGET=fpga` produces, minus the ROMs.

`c64-romless.bit` additionally carries the **EasyFlash cartridge port**
(`cart=easyflash` in its tag — see `retro-arch/c64/README.md`): one bitstream
runs disks and cartridges, deciding at runtime on whether a cart image has
been pushed into it. Upload a `.crt` and the board unpacks it itself.

## Why these are the only `.bit` files in git

They contain **no copyrighted bytes**. The `basic` / `kernal` / `chargen`
arrays ship empty and the ROMs arrive at run time over the QSPI link from
files you supply. Every ROM-*baked* bitstream stays out of the repository —
that line does not move; see the copyright fence at the bottom of
`.gitignore`.

Each bit declares what it needs in its own header, which is how the board
knows which banks to feed and can name a missing one:

```
$ python3 util/bittag.py bitstreams/c64-romless.bit
Part: LFE5U-25F-6CABGA256
gc: hw=v2 arch=c64 ver=2608051258.0 roms=kernal,basic,chargen
```

**The bank id is the declaration order.** `roms=kernal,basic,chargen` means
kernal is bank 0, basic bank 1, chargen bank 2 — exactly what that SoC
decodes.

## Using one

You still need your own ROM dumps. **The desktop app does the whole thing**:
`make start` → **Board tab**. If the machines cannot run you get a red box
naming them; tick the consent checkbox in it and press *Download ROMs and
install to board*. That fetches the ROMs, packs them and uploads them (and
the bitstream, if the board has none).

The Install tab is the same thing with the steps separated, for when you want
to synthesize your own ROM-baked bitstreams instead. Its `<machine> ON THE
BOARD` rows are the ones that answer "will my c64 start" — the rows above them
describe this computer, not the board.

By hand it is two commands:

```sh
make download-rom ARCH=c64          # VICE project, after the consent prompt
python3 util/mkroms.py c64.roms \
    kernal=retro-arch/c64/roms/kernal.hex \
    basic=retro-arch/c64/roms/basic.hex \
    chargen=retro-arch/c64/roms/chargen.hex
```

Feed it the **`.hex` files, not the raw `.bin` dumps**: `make download-rom`
converts the dumps and then runs `retro-arch/common/kernal_fastload_patch.py`
over them, which writes the 4-byte LOAD detour the fastload engine is reached
through. The baked bitstreams are synthesised from those same patched files,
so a container built from anything else gives you a KERNAL that cannot
fastload.

Then upload `c64-romless.bit` and `c64.roms` to the board (desktop Files tab,
or `python3 -m library.cli`). The filenames are what tag them: `c64-` marks
the bit as a c64 bitstream, and a `.roms` container takes its platform from
its own name. On launch the board reads the bit's `roms=` list, verifies every
bank in the container, pushes them, and only then releases the machine.

**A missing or unpushed bank is not a subtle failure**: the fabric holds the
CPU in reset until every declared bank is valid, so the screen stays blank
rather than the machine running against an empty KERNAL. The BIOS still runs
(it is drawn by the fabric, not the machine), and it names the missing bank.

> **Status — not board-tested yet.** The fabric side is verified in simulation
> (a pushed build boots byte-identically to the baked one; no push, or a
> partial push, leaves the machine correctly held). The firmware that does the
> pushing is written and host-tested against the containers this flow
> produces, but is not yet in a released firmware build.

## Regenerating

```sh
make bitstreams
```

builds all three and copies them here. One at a time:

```sh
ROMLESS=1 make build ARCH=c64 TARGET=fpga HW=v2   # -> /tmp/c64_v2_iec_romless.bit
```

`make clean` deliberately leaves this directory alone — these are committed
artifacts, not build output.
