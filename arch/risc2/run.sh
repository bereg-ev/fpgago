
CPUDIR="./cpu"
UTIL="../../util"
PERI="../../peripheral"

rm out.*

yosys -p "read_verilog -I ./cpu project-risc2-video.v; synth_ecp5 -top fpga_gameconsole -json out.json" *v $CPUDIR/*v $UTIL/ecp5.v $PERI/uart.v $PERI/sdram.v $PERI/dcache.v $PERI/icache.v $PERI/debugger.v $PERI/lcd_out.v $PERI/audio.v $PERI/lcd_char.v $PERI/timer.v
nextpnr-ecp5 --json out.json --textcfg out.config --25k --package CABGA256 --lpf *lpf --report out.timing

#ecppack --svf out.svf out.config out.bit
ecppack out.config out.bit
cp out.bit /Users/bereg/f

