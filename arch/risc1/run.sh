#!/bin/bash
#
# run.sh — Synthesize RISC1 SoC for ECP5 FPGA and program the board
#
# HW=v1 (default) / v2 — selects the hardware version.  RISC1 uses no
# external memories (SDR / DDR / PSRAM), so the same SoC bitstream and the
# same LPF pin assignments work on both PCB revisions; HW is accepted only
# so the top-level Makefile can pass it transparently.
HW="${HW:-v1}"
case "$HW" in
  v1|v2) echo "  Hardware: $HW (RISC1 uses no SDRAM/DDR/PSRAM — same bitstream for both)" ;;
  *)     echo "Unknown HW=$HW (expected v1 or v2)"; exit 1 ;;
esac

CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm -f out.*

echo "  Synthesizing with yosys..."
yosys -q -p "read_verilog -I ./cpu -I . project-risc1.v; synth_ecp5 -top fpga_gameconsole -json out.json" \
    project-risc1.v soc.v \
    $CPUDIR/*.v \
    $UTIL/ecp5.v \
    $PERI/uart.v $PERI/audio.v $PERI/lcd_out.v $PERI/lcd_char.v $PERI/debugger.v

echo "  Place & route with nextpnr..."
nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf project-risc1.lpf \
    --report out.timing

echo "  Packing bitstream..."
ecppack out.config out.bit

echo "  Done: out.bit"
cp out.bit /Users/bereg/f 2>/dev/null && echo "  Copied to /Users/bereg/f" || echo "  Program with:  ecpprog out.bit"
