# Commodore 64

The C64 core: a 6510 (Arlet's 6502 with the undocumented opcodes and the
processor port), the Kawari VIC-II, a MiSTer-derived SID and 6526 CIA, wired
into `soc.v` alongside the shared fabric in `../common/` — the BIOS overlay,
the keyboard mapper, the QSPI host link and the screen-grab engine.

```
project-c64.v   board top level: pins, PLL, LCD, audio, buttons
soc.v           the machine: CPU, PLA, RAM/ROM banking, VIC, SID, CIA,
                the drive paths, the BIOS overlay and the LCD line buffer
c64_easyflash.v the EasyFlash cartridge port
c64_kbd_map.v   PC scancodes -> the C64 keyboard matrix
cpu/            cpu_6510.v, cpu_6502.v + ALU.v (Arlet), mos6526.v (CIA)
vic/            VIC-II (vicii-kawari)
sid/            SID (MiSTer, rewritten in plain Verilog for yosys)
roms/           ROM conversion + game tooling; NO ROM images
sim-desktop/    the Verilator + SDL2 harness
run.sh          synthesis (yosys -> nextpnr-ecp5 -> ecppack)
```

The SoC clock is the VIC-II dot4x: the board's 17.734475 MHz PAL crystal
multiplied by 16/9 in an `EHXPLLL` = the true 31.527955 MHz. The LCD is
genlocked to the VIC raster through a line buffer in `soc.v`, so the whole
machine stays in one crystal-exact clock domain at a 50.125 Hz refresh.

## Loading games

Four drive paths live in the same bitstream; the board picks between them at
runtime (`DRIVE_MODE`, QSPI command `0x0B`), so you never reflash to change
loader:

| mode | what it is | when you want it |
|---|---|---|
| **FASTLOAD** | a KERNAL LOAD detour that pulls the file over the QSPI link straight into RAM | single-load games; by far the quickest |
| **REAL 1541** | the external IEC bus on the reclaimed sysCONFIG pins (ATN=N9, CLK=N8, DATA=A9) | a real drive on the connector |
| **DOS 1541** | the drive emulated on the companion MCU, speaking the IEC protocol | multi-load games that talk to the DOS |
| **FPGA 1541** | a complete 1541 in fabric — 6502 + VIA + GCR, DOS ROM and pre-encoded tracks in the QSPI PSRAM (`../common/drive1541/`) | fastloaders that bit-bang the serial line and time the drive |

The patched KERNAL is safe in every mode: with `DRIVE_MODE` ≠ 0 the detour
window serves a transparent fallback stub, so LOAD goes down the stock serial
path with no watchdog stall.

In the desktop simulation the same choice is a flag:

```sh
make run-floppy ARCH=c64 D64=disk.d64 PROGRAM="GAME"     # emulated 1541
make run-floppy ARCH=c64 D64=disk.d64 PROGRAM="GAME" FAST=1   # fastload
```

## EasyFlash cartridges

The cart port is **always** in the v2 bitstream (`EASYFLASH=1`, the default;
`EASYFLASH=0` builds without it for A/B debugging). One bitstream runs both
disks and cartridges and decides at runtime:

- With no cart pushed, the `/GAME` `/EXROM` terms fold back to the original
  PLA and the fastload windows stay live.
- Once a 1 MiB flat image has been pushed into the QSPI PSRAM, the cart owns
  I/O1 and I/O2 and boots in Ultimax mode off the next reset.

The fabric emulates what EAPI needs from the Am29F040 flash: autoselect, byte
program and sector erase, plus the 256-byte cart RAM, the 64+64 bank window
and the kill state. Upload a `.crt` and the board unpacks it into the port
itself — nothing is converted on the host.

```sh
make run-crt         ARCH=c64 CRT=game.crt   # run one in simulation
make check-easyflash ARCH=c64                # copyright-free self-test cart
make check-efpush    ARCH=c64                # the image push, at two rates
```

`check-easyflash` boots `roms/mk_ef_testcart.py`'s own cartridge in Ultimax,
walks all 64 banks on both chips, and tests the RAM, the kill state and the
flash emulation — about a second of machine time, no ROMs needed.

With the fabric 1541 also enabled, both share the single APS6404L through
`../common/psram_hub.v` (the drive sets the pace); the measured cost is one
extra EBR.

## Synthesis knobs

`run.sh` reads these from the environment:

| variable | default | effect |
|---|---|---|
| `HW` | `v2` | board revision (v2 is the only one the c64 targets) |
| `IEC` | `1` | external IEC pins + the runtime drive-mode switch |
| `FDRIVE` | `0` | build the fabric 1541 in |
| `EASYFLASH` | `1` | build the cartridge port in |
| `ROMLESS` | `0` | ship empty ROM arrays; the board pushes the user's dumps |
| `GAME` | — | bake `roms/game.hex` into the RAM image and autostart it |
| `BIT_VERSION` | — | stamped into the ECP5 USERCODE and the bit's `gc:` tag |

`make build ARCH=c64 TARGET=fpga` passes `HW`, `IEC` and `ROM` through and
sets `BIT_VERSION` for you.

## Chip sources

`cpu/download_chips.sh` refetches the VIC-II (vicii-kawari), the SID and the
CIA (C64_MiSTer) from upstream. They are checked in, so a clone does not need
it — run it only to take an upstream bump, and re-run
`sid/mk_sid_tables.py` afterwards to regenerate `roms/sid_*.hex`.
