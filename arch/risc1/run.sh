#!/bin/bash
#
# run.sh — Synthesize RISC1 SoC for ECP5 FPGA and program the board
#

CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm -f out.*

echo "  Synthesizing with yosys..."
yosys -q -p "read_verilog -I ./cpu -I . project-risc1.v; synth_ecp5 -top fpga_gameconsole -json out.json" \
    project-risc1.v soc.v \
    $CPUDIR/*.v \
    $UTIL/ecp5.v \
    $PERI/uart.v $PERI/lcd_out.v $PERI/lcd_char.v $PERI/debugger.v

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf project-risc1.lpf \
    --report out.timing

echo "  Packing bitstream..."
ecppack out.config out.bit

echo "  Done: out.bit"
cp out.bit /Users/bereg/f 2>/dev/null && echo "  Copied to /Users/bereg/f" || echo "  Program with:  ecpprog out.bit"
