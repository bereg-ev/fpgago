#!/bin/bash
#
# run.sh — Synthesize C16 SoC for ECP5 FPGA and program the board
#

# Hardware version selector (v2 is the current board and the default).
# The c16 v1/v2 delta is only the MCU<->FPGA UART balls (R4/T4 vs A11/A12);
# LCD/LED pins and the C16 RTL are HW-independent.
HW="${HW:-v2}"
case "$HW" in
  v1) LPF="project-c16-hw1.lpf"; HW_DEFINE="-DHW_V1" ;;
  v2) LPF="project-c16-hw2.lpf"; HW_DEFINE="-DHW_V2" ;;
  *)  echo "Unknown HW=$HW (expected v1 or v2)"; exit 1 ;;
esac

# IEC: combined real-1541 + QSPI-link bitstream — the DEFAULT on HW=v2 since
# the single-bitstream drive-mode switch (qspi_slave.v DRIVE_MODE 0x0B): with
# DRIVE_MODE=1 the fastload detour window serves a transparent fallback stub
# and LOAD goes down the stock IEC path; with DRIVE_MODE=0 it fastloads.  The
# IEC lines ride the reclaimed sysCONFIG pins (ATN=N9/CCLK via USRMCLK,
# CLK=N8, DATA=A9) so the QSPI link keeps its own balls — BIOS / volume run
# alongside the drive.  IEC=0 opts out (fastload-only bit).
[ "$HW" = "v2" ] && IEC="${IEC-1}"
[ "$IEC" = "0" ] && IEC=""
IEC_DEFINE=""
if [ -n "$IEC" ]; then
    if [ "$HW" != "v2" ]; then
        echo "IEC=1 needs HW=v2 (config-pin reclaim is a v2 feature)"; exit 1
    fi
    IEC_DEFINE="-DIEC1541"
    LPF="project-c16-iec.lpf"
    echo "  Combined IEC+QSPI bitstream (IEC on config pins N9/N8/A9)"
fi
echo "  Hardware: $HW  (LPF: $LPF)"

# Bake the build version into the fabric so the MCU can READ the real bitstream
# version over the QSPI link (CMD_VERSION_READ 0x09 in common/qspi_slave.v).
# BIT_VERSION=YYMMDDHHMM.N (set by build-iec.sh) → -DBIT_VER_DATE / -DBIT_VER_BUILD.
# ROM-free build (bitstreams/README.md): the kernal/basic arrays ship
# EMPTY and the MCU pushes the user's own ROMs in after configuration, so the
# bitstream carries no copyrighted bytes.  The bit declares what it needs in
# its own gc: tag (roms=...), which is how the MCU knows which banks to feed
# and can name the missing one in its popup.
ROMLESS_DEFINE=""
ROMS_TAG=""
if [ "${ROMLESS:-0}" = "1" ]; then
    ROMLESS_DEFINE="-DROMLESS"
    ROMS_TAG="roms=kernal,basic"     # bank order = the SoC's bank decode
    echo "  ROM-free bitstream (needs PLATFORM.roms on the board)"
fi

VER_DEFINE=""
if [ -n "${BIT_VERSION:-}" ]; then
    VER_DEFINE="-DBIT_VER_DATE=${BIT_VERSION%.*} -DBIT_VER_BUILD=${BIT_VERSION##*.}"
fi

# GAME mode: GAME=<name> bash run.sh bakes roms/game.hex into the 16KB RAM
# init image and roms/autorun.hex into the boot_typer script ROM
# (-DGAME_PRG) — the board boots straight into the game, no MCU needed.
GAME_DEFINE=""
GAME_SRCS=""
if [ -n "$GAME" ]; then
    if [ ! -f roms/game.hex ] || [ ! -f roms/autorun.hex ]; then
        echo "GAME=$GAME but roms/game.hex / roms/autorun.hex missing."
        echo "Run:  make download-game ARCH=c16 GAME=$GAME"
        exit 1
    fi
    GAME_DEFINE="-DGAME_PRG"
    # boot_typer.v only in GAME builds: its $readmemh(autorun.hex) must not
    # make yosys stumble over a missing file when no game is baked.
    GAME_SRCS="../common/boot_typer.v"
    echo "  Game: $GAME (RAM init image + autorun script baked in)"
fi

CPUDIR="../common/cpu/6502"
UTIL="../../util"
PERI="../../peripheral"

rm -f out.*

# Create symlink so $readmemh("../roms/...") works when yosys runs from retro-arch/c16/
# (rm first: ln -sf into an existing dir-symlink would nest instead of replace)
rm -f ../roms 2>/dev/null
ln -sf c16/roms ../roms 2>/dev/null

COMMON="../common"
SRCS="project-c16.v soc.v c16.v ted.v mos8501.v gen_ram.v colors_to_rgb.v \
      c16_keymatrix.v c16_kbd_map.v mos6529.v gen_uart.v basic_rom.v kernal_rom.v \
      $COMMON/kbd_typer.v $COMMON/kbd_matrix.v $COMMON/kbd_buttons.v \
      $COMMON/qspi_slave.v $COMMON/lcd_backlight.v $COMMON/shot_cap.v $COMMON/bios_text.v \
      $GAME_SRCS \
      sigma_delta_dac.v stubs.v \
      $CPUDIR/cpu_6502.v $CPUDIR/ALU.v \
      $UTIL/ecp5.v \
      $PERI/uart.v $PERI/lcd_out.v $PERI/i2s_pcm.v"

echo "  Synthesizing with yosys..."
# All sources + all defines in one read_verilog (so IEC1541 / BIT_VER_DATE reach
# soc.v and qspi_slave.v, not just project-c16.v).
yosys -q -p "read_verilog $HW_DEFINE $GAME_DEFINE $IEC_DEFINE $VER_DEFINE $ROMLESS_DEFINE -I ./cpu -I . -I ../common $SRCS; synth_ecp5 -top fpga_gameconsole -json out.json" \
    || exit 1

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf "$LPF" \
    --report out.timing || exit 1

echo "  Packing bitstream..."
# BIT_VERSION (set by build-iec.sh) → out.version + ECP5 USERCODE (decimal u32).
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
python3 ../../util/bittag.py out.bit hw=$HW arch=c16 ${BIT_VERSION:+ver=$BIT_VERSION} $ROMS_TAG || exit 1

echo "  Done: out.bit"
BITNAME="/tmp/c16_${HW}_${IEC:+iec_}${GAME:-plain}.bit"
[ -n "$IEC" ] && BITNAME="/tmp/c16_${HW}_iec.bit"
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
