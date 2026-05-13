#!/usr/bin/env bash
# run.sh — synthesise the ddr3-test bitstream for the ECP5 LFE5U-25F.
#
# Inputs (must already exist in this directory):
#   rom.hex, romL*.vh, romH*.vh   — built by `make` in this folder
#
# Outputs:
#   out.json, out.config, out.bit, out.timing
#
# The script always reads the controller with HW v2 board-style defines.
# `-DSIMULATION` is *not* set, so soc.v wires up the real ddr3_axi + PHY.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPU="$REPO/arch/risc2/cpu"
PER="$REPO/peripheral"
DDR="$REPO/peripheral/ddr3"
UTIL="$REPO/util"

rm -f out.*

# All sources go through one read_verilog so they share `define scope.
yosys -p "
read_verilog -I . -I $CPU \
    ddr3_test_top.v ddr3_test_soc.v \
    $CPU/cpu_risc2.v $CPU/alu_risc2.v \
    $UTIL/ecp5.v \
    $PER/uart.v \
    $PER/ddr3_iface.v \
    $DDR/ddr3_axi.v \
    $DDR/ddr3_axi_pmem.v \
    $DDR/ddr3_axi_retime.v \
    $DDR/ddr3_core.v \
    $DDR/ddr3_dfi_seq.v \
    $DDR/ddr3_dfi_phy_ecp5.v;
synth_ecp5 -top ddr3_test_top -json out.json
"

nextpnr-ecp5 \
    --json   out.json \
    --textcfg out.config \
    --25k --package CABGA256 \
    --lpf    ddr3_test.lpf \
    --report out.timing

ecppack out.config out.bit
echo "Bitstream: $(pwd)/out.bit"
