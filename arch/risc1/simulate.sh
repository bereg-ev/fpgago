#!/bin/bash

CPU="./cpu"
UTIL="../../util"
PERI="../../peripheral"
FONT="../../util/font2init"

iverilog -o out -DSIMULATION \
    -I $CPU/ -I $FONT/ \
    testbench.v soc.v \
    $CPU/cpu_risc1.v $CPU/alu_risc1.v \
    $UTIL/ecp5_simul.v \
    $PERI/uart.v $PERI/lcd_out.v $PERI/lcd_char.v

vvp out
