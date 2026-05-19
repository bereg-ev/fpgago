
# Hardware version selector:
#   HW=v1 (default)  -> two SDR SDRAMs (project-risc2-video-hw1.lpf)
#   HW=v2            -> single DDR3 SDRAM   (project-risc2-video-hw2.lpf)
HW="${HW:-v1}"
case "$HW" in
  v1) LPF="project-risc2-video-hw1.lpf"; HW_DEFINE="-DHW_V1" ;;
  v2) LPF="project-risc2-video-hw2.lpf"; HW_DEFINE="-DHW_V2" ;;
  *)  echo "Unknown HW=$HW (expected v1 or v2)"; exit 1 ;;
esac
echo "  Hardware: $HW  (LPF: $LPF)"

# CPU variant selection (CPU=risc2 default | risc2p2 | risc2p3 | risc2p5)
CPU="${CPU:-risc2}"
case "$CPU" in
  risc2)    CPU_DEFINE=""; CPU_VSRC="" ;;
  risc2p2)  CPU_DEFINE="-DUSE_RISC2P2"; CPU_VSRC="./cpu/cpu_risc2p2.v" ;;
  risc2p3)  CPU_DEFINE="-DUSE_RISC2P3"; CPU_VSRC="./cpu/cpu_risc2p3.v" ;;
  risc2p5)  CPU_DEFINE="-DUSE_RISC2P5"; CPU_VSRC="./cpu/cpu_risc2p5.v" ;;
  *) echo "Unknown CPU=$CPU"; exit 1 ;;
esac
echo "  CPU: $CPU"

CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm out.*

# Read every Verilog file with HW_DEFINE so the `ifdef HW_V2 ... `endif blocks
# in soc.v and project-risc2-video.v are visible.  All sources go through one
# read_verilog so they share the same define scope.
yosys -p "read_verilog $HW_DEFINE $CPU_DEFINE -I ./cpu project-risc2-video.v soc.v interface-sdram.v $CPUDIR/cpu_risc2.v $CPU_VSRC $CPUDIR/alu_risc2.v $UTIL/ecp5.v $PERI/uart.v $PERI/sdram.v $PERI/dcache.v $PERI/icache.v $PERI/psram.v $PERI/psram_iface.v $PERI/debugger.v $PERI/lcd_out.v $PERI/audio.v $PERI/lcd_char.v $PERI/timer.v; synth_ecp5 -top fpga_gameconsole -json out.json"
nextpnr-ecp5 --json out.json --textcfg out.config --25k --package CABGA256 --lpf "$LPF" --report out.timing

#ecppack --svf out.svf out.config out.bit
ecppack out.config out.bit
cp out.bit /Users/bereg/f
