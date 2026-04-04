#!/bin/bash
#
# sim-hdl/simulate.sh — HDL simulation (iverilog + vvp → out.vcd)
#
# Purpose : Logic-level debugging. Produces a VCD waveform that can be
#           inspected with GTKWave.  SIMULATION flag enables fast SDRAM
#           init and a tiny 30×2 LCD frame so the simulation terminates
#           quickly.
#
# Usage   : cd arch/risc2/sim-hdl && bash simulate.sh
#           gtkwave out.vcd
#

CPU="../cpu"
UTIL="../../../util"
PERI="../../../peripheral"
PROJ=".."

if iverilog -o out \
    -DSIMULATION \
    -I "$CPU/" \
    -I "$PROJ/" \
    testbench.v \
    "$PROJ/project-risc2-video.v" \
    "$PROJ/soc.v" \
    "$PROJ/interface-sdram.v" \
    "$CPU"/*v \
    "$UTIL/ecp5_simul.v" \
    "$PERI/uart.v" \
    "$PERI/sdram.v" \
    "$PERI/bootloader.v" \
    "$PERI/debugger.v" \
    "$PERI/lcd_out.v" \
    "$PERI/lcd_char.v" \
    "$PERI/i2s.v" \
    "$PERI/timer.v"
then
    vvp out
else
    echo "ERR: iverilog compilation failed"
    exit 1
fi
