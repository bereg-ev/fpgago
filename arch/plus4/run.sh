#!/bin/bash
#
# run.sh — Synthesize Plus/4 SoC for ECP5 FPGA and program the board
#

C16DIR="../../arch/c16"
CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm -f out.*

# Create symlink so $readmemh("../roms/...") works when yosys runs from arch/plus4/
rm -f ../roms 2>/dev/null
ln -sf plus4/roms ../roms

# Shared modules from C16 (same TED, CPU, keyboard, etc.)
# Plus/4-specific: soc.v, basic_rom.v, kernal_rom.v
SRCS="project-plus4.v soc.v \
      $C16DIR/c16.v $C16DIR/ted.v $C16DIR/mos8501.v $C16DIR/gen_ram.v \
      $C16DIR/colors_to_rgb.v $C16DIR/c16_keymatrix.v $C16DIR/mos6529.v \
      $C16DIR/gen_uart.v $C16DIR/sigma_delta_dac.v $C16DIR/stubs.v \
      basic_rom.v kernal_rom.v \
      $CPUDIR/cpu_6502.v $CPUDIR/ALU.v \
      $UTIL/ecp5.v \
      $PERI/uart.v $PERI/lcd_out.v"

echo "  Synthesizing with yosys..."
yosys -q -p "read_verilog -I ./cpu -I . project-plus4.v; synth_ecp5 -top fpga_gameconsole -json out.json" \
    $SRCS

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf project-plus4.lpf \
    --report out.timing

echo "  Packing bitstream..."
ecppack out.config out.bit

echo "  Done: out.bit"
ls -la out.bit
cp out.bit /Users/bereg/f 2>/dev/null && echo "  Copied to /Users/bereg/f" || echo "  Program with:  ecpprog out.bit"
