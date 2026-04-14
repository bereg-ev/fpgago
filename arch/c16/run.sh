#!/bin/bash
#
# run.sh — Synthesize C16 SoC for ECP5 FPGA and program the board
#

CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm -f out.*

# Create symlink so $readmemh("../roms/...") works when yosys runs from arch/c16/
ln -sf c16/roms ../roms 2>/dev/null

SRCS="project-c16.v soc.v c16.v ted.v mos8501.v gen_ram.v colors_to_rgb.v \
      c16_keymatrix.v mos6529.v gen_uart.v basic_rom.v kernal_rom.v \
      sigma_delta_dac.v stubs.v \
      $CPUDIR/cpu_6502.v $CPUDIR/ALU.v \
      $UTIL/ecp5.v \
      $PERI/uart.v $PERI/lcd_out.v"

echo "  Synthesizing with yosys..."
yosys -q -p "read_verilog -I ./cpu -I . project-c16.v; synth_ecp5 -top fpga_gameconsole -json out.json" \
    $SRCS

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf project-c16.lpf \
    --report out.timing

echo "  Packing bitstream..."
ecppack out.config out.bit

echo "  Done: out.bit"
cp out.bit /Users/bereg/f 2>/dev/null && echo "  Copied to /Users/bereg/f" || echo "  Program with:  ecpprog out.bit"
