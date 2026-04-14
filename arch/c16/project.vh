
`ifdef SIMULATION_SDL
`define UART_BIT_TIME       3
`elsif SIMULATION
`define UART_BIT_TIME       3
`else
`define UART_BIT_TIME       434
`endif
