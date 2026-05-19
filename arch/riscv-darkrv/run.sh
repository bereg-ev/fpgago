#!/usr/bin/env bash
#
# arch/riscv-darkrv/run.sh — yosys / nextpnr / ecppack bitstream build.
#
# Invoked by:
#   make run GAME=labyrinth ARCH=riscv-darkrv TARGET=fpga HW=v2 RAM=psram
#
# Currently only HW=v2 + RAM=psram is wired up (other combos error out in
# build.mk before reaching this script).
#
# Output:
#   out.bit  — final bitstream
#   out.json — yosys post-synth netlist
#   out.timing — nextpnr timing report
#
set -euo pipefail

HW="${HW:-v2}"
RAM="${RAM:-psram}"

case "$HW" in
  v2) LPF="project-riscv-darkrv-video-hw2.lpf"; HW_DEFINE="-DHW_V2" ;;
  v1) echo "Error: HW=v1 has no FPGA toplevel for riscv-darkrv yet"; exit 1 ;;
  *)  echo "Unknown HW=$HW (expected v1 or v2)"; exit 1 ;;
esac

case "$RAM" in
  psram|bram)
        # FPGA always uses BRAM for RAM and PSRAM for FB (via fb_psram).
        # RAM=psram + DARK_FPGA would otherwise mean two psram.v instances
        # on the same chip — fb_psram already owns the controller.
        RAM_DEFINE=""
        RAM_VSRC="./fb_psram.v ../../peripheral/psram.v" ;;
  *) echo "FPGA build: only RAM=bram or RAM=psram supported right now (got $RAM)"; exit 1 ;;
esac

echo "  Hardware: $HW  (LPF: $LPF)"
echo "  RAM:      $RAM"

PERI="../../peripheral"

rm -f out.* 2>/dev/null || true

# One read_verilog pass so every `ifdef sees the same scope.
yosys -p "
    read_verilog -DDARK_FPGA -DROM_HEX_PATH=\"rom.hex\" $HW_DEFINE $RAM_DEFINE \
        project-riscv-darkrv-video.v \
        soc.v cpu_darkrv.v darkriscv.v \
        $RAM_VSRC \
        $PERI/uart.v $PERI/lcd_out.v;
    hierarchy -top fpga_gameconsole;
    # Strip reg-init attributes that conflict with async-reset values
    # (peripheral/psram.v sets psram_ce_n <= 1'b1 in reset; default init is 0;
    # ECP5 FFs can't legalize that combo).
    proc;
    attrmap -remove init;
    synth_ecp5 -top fpga_gameconsole -json out.json
"

nextpnr-ecp5 --json out.json --textcfg out.config \
    --25k --package CABGA256 \
    --lpf "$LPF" --report out.timing

ecppack out.config out.bit

echo ""
echo "Bitstream written: $(pwd)/out.bit"
