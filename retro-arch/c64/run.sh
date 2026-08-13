#!/bin/bash
#
# run.sh — Synthesize C64 SoC (Kawari VIC-II) for ECP5 FPGA
#
# The SoC clock is the VIC-II dot4x: the board's 17.734475 MHz PAL crystal
# (ball B11) multiplied by 16/9 in an EHXPLLL = the true 31.527955 MHz.
# The LCD is genlocked to the VIC raster (line buffer in soc.v) — still a
# single clock domain, just crystal-exact now (50.125 Hz refresh).
#

# Hardware version selector (v2 is the current board and the default).
HW="${HW:-v2}"
case "$HW" in
  v2) LPF="project-c64-hw2.lpf"; HW_DEFINE="-DHW_V2" ;;
  *)  echo "Unknown HW=$HW (c64 targets the v2 board only)"; exit 1 ;;
esac

# FDRIVE: the fabric 1541 (common/drive1541) — the whole
# drive in fabric, IEC internal, DOS ROM + pre-encoded GCR tracks in the
# QSPI PSRAM behind psram_fast (PLL CLKOS2 = 113.5 MHz fast domain).
# Built without the external-IEC pins (the drive is inside).  Use
# DRIVE_MODE=1 on the link so the kernal detour serves the transparent
# stub and LOAD goes down the stock serial path to the fabric drive.
#
# Every drive mode is alive in this bitstream: with DRIVE_MODE 0 or 2 the
# fabric drive is held in reset (soc.v fd_rst) and the QSPI fastload /
# DOS-over-link paths work exactly as in the plain bit.
#
# EasyFlash coexists too (2026-08-10): one APS6404L, one psram_fast engine,
# psram_hub.v arbitrating with the drive first.  Measured cost is +1 EBR each
# (52 base -> 54), which is why the earlier "they can never share a bit" note
# was wrong — the wall was the two separate engines, not the silicon.
FDRIVE="${FDRIVE:-0}"
FD_DEFINE=""
FD_SRCS=""
FD_TAG=""
if [ "$FDRIVE" = "1" ]; then
    FD_DEFINE="-DFDRIVE"
    FD_SRCS="../common/drive1541/drive_1541.v ../common/drive1541/drive_psram.v \
             ../common/drive1541/via6522.v ../../peripheral/psram_fast.v \
             ../common/psram_hub.v"
    # fdbank=7: the drive image is ONE 512 KiB loader bank, because banks 3..6
    # belong to the cart.  The MCU reads this tag to know which layout to push,
    # so a board still carrying the old two-bank fd bit keeps working.
    FD_TAG="drive=fd1541 fdbank=7"
    IEC=0
    echo "  Fabric 1541 (internal IEC; PSRAM = drive ROM + GCR tracks)"
fi

# IEC: combined real-1541 + QSPI-link bitstream — the DEFAULT since the
# single-bitstream drive-mode switch (qspi_slave.v DRIVE_MODE 0x0B).  The
# PATCHED KERNAL is fine in 1541 mode: with DRIVE_MODE=1 the detour window
# serves a transparent fallback stub (no watchdog stall), so LOAD goes down
# the stock IEC path; with DRIVE_MODE=0 it fastloads.  The IEC lines ride the
# reclaimed sysCONFIG pins (ATN=N9/CCLK via USRMCLK, CLK=N8, DATA=A9) so the
# QSPI link keeps its own balls — BIOS / volume run alongside the drive.
# IEC=0 opts out (fastload-only bit, for A/B debugging).
IEC="${IEC-1}"
[ "$IEC" = "0" ] && IEC=""
IEC_DEFINE=""
if [ -n "$IEC" ]; then
    IEC_DEFINE="-DIEC1541"
    LPF="project-c64-iec.lpf"
    echo "  Combined IEC+QSPI bitstream (runtime DRIVE_MODE switch; IEC on config pins N9/N8/A9)"
fi
echo "  Hardware: $HW  (LPF: $LPF)"

# EasyFlash cartridge support (README.md) is ALWAYS in the v2 bit:
# one bitstream, runtime d64-vs-cart decision.  With no cart pushed the
# /GAME //EXROM terms fold to the original PLA and the fastload windows are
# live; once the MCU delivers the four flat-image chunks (loader banks 3-6)
# the cart owns I/O1/I/O2 and boots in Ultimax off the next reset.
# EASYFLASH=0 opts out for A/B debugging.
EASYFLASH="${EASYFLASH:-1}"
EF_DEFINE=""
EF_SRCS=""
EF_TAG=""
if [ "$EASYFLASH" != "0" ]; then
    EF_DEFINE="-DEASYFLASH -DPSRAM_CLKDIV=1"
    EF_SRCS="./c64_easyflash.v ../../peripheral/psram.v"
    EF_TAG="cart=easyflash"
    if [ "$FDRIVE" = "1" ]; then
        # One chip, one engine (psram_fast — the drive sets the pace), shared
        # by psram_hub.v.  PSRAM_CLKDIV is the slow engine's knob and is not
        # used here.
        EF_DEFINE="-DEASYFLASH"
        EF_SRCS="./c64_easyflash.v"
        echo "  EasyFlash cart support (shares the PSRAM with the fabric 1541)"
    else
        echo "  EasyFlash cart support (1 MiB image in QSPI PSRAM, runtime mount)"
    fi
fi

# ROM-free build (bitstreams/README.md): the basic/kernal/chargen arrays
# ship EMPTY and the MCU pushes the user's own ROMs in after configuration, so
# the bitstream carries no copyrighted bytes.  The bit declares what it needs in
# its own gc: tag (roms=...), which is how the MCU knows which banks to feed and
# can name the missing one in its popup.
ROMLESS_DEFINE=""
ROMS_TAG=""
if [ "${ROMLESS:-0}" = "1" ]; then
    ROMLESS_DEFINE="-DROMLESS"
    ROMS_TAG="roms=kernal,basic,chargen"  # bank order = the SoC's bank decode
    echo "  ROM-free bitstream (needs c64.roms on the board)"
fi

# Bake the build version into the fabric so the MCU can READ the real bitstream
# version over the QSPI link (CMD_VERSION_READ 0x09) instead of assuming it.
# BIT_VERSION=YYMMDDHHMM.N (set by build-iec.sh) → -DBIT_VER_DATE / -DBIT_VER_BUILD.
VER_DEFINE=""
if [ -n "${BIT_VERSION:-}" ]; then
    VER_DEFINE="-DBIT_VER_DATE=${BIT_VERSION%.*} -DBIT_VER_BUILD=${BIT_VERSION##*.}"
fi

# GAME mode: GAME=<name> bash run.sh bakes roms/game.hex into the 64KB RAM
# init image and roms/autorun.hex into the boot_typer script ROM
# (-DGAME_PRG) — the board boots straight into the game, no MCU needed.
GAME_DEFINE=""
GAME_SRCS=""
if [ -n "$GAME" ]; then
    if [ ! -f roms/game.hex ] || [ ! -f roms/autorun.hex ]; then
        echo "GAME=$GAME but roms/game.hex / roms/autorun.hex missing."
        echo "Run:  make run-prg ARCH=c64 PRG=<file.prg> TARGET=fpga"
        exit 1
    fi
    GAME_DEFINE="-DGAME_PRG"
    # boot_typer.v only in GAME builds: its $readmemh(autorun.hex) must not
    # make yosys stumble over a missing file when no game is baked.
    GAME_SRCS="../common/boot_typer.v"
    echo "  Game: $GAME (RAM init image + autorun script baked in)"
fi

CPUDIR="./cpu"
CPU6502="../common/cpu/6502"
VIC="./vic"
UTIL="../../util"
PERI="../../peripheral"
COMMON="../common"

rm -f out.*

# Create symlink so $readmemh("../roms/...") works when yosys runs from
# retro-arch/c64/ (rm first: ln -sf into an existing dir-symlink would nest
# instead of replace).  NB shared with c16/plus4 — never synth in parallel.
rm -f ../roms 2>/dev/null
ln -sf c64/roms ../roms 2>/dev/null

SRCS="project-c64.v soc.v c64_kbd_map.v \
      $COMMON/kbd_typer.v $COMMON/kbd_matrix.v $COMMON/kbd_buttons.v \
      $COMMON/qspi_slave.v $COMMON/lcd_backlight.v $COMMON/shot_cap.v $COMMON/bios_text.v \
      $GAME_SRCS $EF_SRCS $FD_SRCS \
      $CPUDIR/cpu_6510.v $CPU6502/cpu_6502.v $CPU6502/ALU.v \
      $CPUDIR/mos6526.v \
      $VIC/vicii.v $VIC/addressgen_spartan.v $VIC/bus_access.v \
      $VIC/border.v $VIC/cycles.v $VIC/divide.v $VIC/lightpen.v \
      $VIC/matrix.v $VIC/pixel_sequencer.v $VIC/raster.v \
      $VIC/registers.v $VIC/sprites.v \
      $VIC/comp_sync.v $VIC/equalization.v $VIC/serration.v \
      ./sid/sid_top.v ./sid/sid_voice.v ./sid/sid_envelope.v \
      ./sid/sid_filter.v ./sid/sid_tables.v ./sid/sid_dac.v \
      $UTIL/ecp5.v \
      $PERI/uart.v $PERI/i2s_pcm.v"

echo "  Synthesizing with yosys..."
# -sv: the MiSTer mos6526 uses SystemVerilog-only constructs
yosys -q -p "read_verilog -sv $HW_DEFINE $GAME_DEFINE $IEC_DEFINE $VER_DEFINE $ROMLESS_DEFINE $EF_DEFINE $FD_DEFINE -I ./cpu -I ./vic -I . -I ../common $SRCS; synth_ecp5 -top fpga_gameconsole -json out.json" \
    || exit 1

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf "$LPF" \
    --report out.timing 2>&1 | tee out.pnr.log
[ "${PIPESTATUS[0]}" = "0" ] || exit 1

echo "  Packing bitstream..."
# BIT_VERSION (YYMMDDHHMM.N, set by build-iec.sh) is recorded in out.version and
# stamped into the ECP5 USERCODE (readable on the bench with a JTAG tool) for
# traceability.  ecppack wants a plain DECIMAL u32 (it rejects a 0x-prefixed hex
# string) — the datestamp YYMMDDHHMM fits in 32 bits through ~2042; the within-day
# build number lives in out.version and the firmware print, not the USERCODE.
USERCODE_ARG=""
if [ -n "${BIT_VERSION:-}" ]; then
    echo "$BIT_VERSION" > out.version
    UC="${BIT_VERSION%.*}"            # YYMMDDHHMM, decimal, fits u32
    USERCODE_ARG="--usercode $UC"
    echo "  Version: $BIT_VERSION  (USERCODE $UC)"
fi
# --compress: the ECP5 config engine decompresses the bitstream itself, so this
# is free flash on the MCU side (~712 KB -> ~335 KB per .bit) with no firmware
# change -- latticeSendBitFile just clocks out fewer bytes.  bittag.py runs
# AFTER packing, so the board/bit interlock comment header is unaffected.
ecppack --compress $USERCODE_ARG out.config out.bit || exit 1

# Board/bit interlock tag: the MCU reads this from the .bit comment header
# before programming and refuses a bitstream built for another board revision.
python3 ../../util/bittag.py out.bit hw=$HW arch=c64 ${BIT_VERSION:+ver=$BIT_VERSION} $ROMS_TAG $EF_TAG $FD_TAG || exit 1

echo "  Done: out.bit"
BITNAME="/tmp/c64_${HW}_${IEC:+iec_}${GAME:-plain}.bit"
[ -n "$IEC" ] && BITNAME="/tmp/c64_${HW}_iec.bit"
[ "$FDRIVE" = "1" ] && BITNAME="/tmp/c64_${HW}_fd.bit"
[ "$FDRIVE" = "1" ] && [ "$EASYFLASH" != "0" ] && BITNAME="/tmp/c64_${HW}_fdef.bit"
# A ROM-free build must never land on the baked build's name: the desktop
# Install tab picks /tmp/<arch>_*.bit by mtime and would flash a bit whose
# ROMs have not been pushed.
[ -n "$ROMLESS_DEFINE" ] && BITNAME="${BITNAME%.bit}_romless.bit"
cp out.bit "$BITNAME" && echo "  Copied to $BITNAME"
echo "  Program with:  ecpprog $BITNAME"

# A stable name is convenient for scripts but every rebuild of the same
# config SILENTLY OVERWRITES the last one -- and the user flashes by hand,
# often comparing "the bit before this change" against "the bit after".
# Keep the stable name AND drop a timestamped twin beside it, so a rebuild
# can never destroy the artifact that was about to be tested.
STAMPED="${BITNAME%.bit}_$(date +%m%d-%H%M).bit"
cp out.bit "$STAMPED" && echo "  Timestamped copy: $STAMPED"
echo "  (the stable name above is overwritten by the next build; this one is not)"
