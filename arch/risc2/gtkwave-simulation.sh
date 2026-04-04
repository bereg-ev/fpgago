
CPU="./cpu"
UTIL="../../util"
PERI="../../peripheral"

if iverilog -o out -I $CPU/ testbench.v project-risc2-video.v soc.v interface-sdram.v $CPU/*v $UTIL/ecp5_simul.v $PERI/uart.v $PERI/sdram.v $PERI/bootloader.v $PERI/debugger.v $PERI/lcd_out.v $PERI/lcd_char.v $PERI/i2s.v $PERI/timer.v;
then
  vvp out
else
  echo ERR
fi


