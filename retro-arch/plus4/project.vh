
// ECP5 OSCG: 310 MHz / 11 ≈ 28.18 MHz (close to Plus/4 PAL 28.375 MHz)
// Same TED clock as C16 — both use the MOS 8360 at 4x dot clock.
`define MAIN_CLK_DIVIDER    "11"

`ifdef SIMULATION_SDL
`define UART_BIT_TIME       3
`elsif SIMULATION
`define UART_BIT_TIME       3
`else
// Real hardware (~28.18 MHz OSCG): 28180000/115200 ≈ 245
`define UART_BIT_TIME       245
`endif
