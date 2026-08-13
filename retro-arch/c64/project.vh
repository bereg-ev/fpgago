// project.vh — Commodore 64 build configuration

// ECP5 OSCG: 310 MHz / 10 = 31 MHz ≈ dot4x (PAL 31.527955 MHz, ~1.7% slow —
// same approximation class as the c16's OSCG/11; the LCD is genlocked to the
// VIC raster, so the only effect is a slightly slow machine).
`define MAIN_CLK_DIVIDER    "10"

`ifdef SIMULATION
  `define UART_BIT_TIME 3
`else
  // Real hardware (~31 MHz OSCG): 31000000/115200 ≈ 269
  `define UART_BIT_TIME 269
`endif
