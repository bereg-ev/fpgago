
`ifdef SIMULATION_SDL
`define UART_BIT_TIME       3
`define CPU_CLOCK_DIV       2       // fast sim
`elsif SIMULATION
`define UART_BIT_TIME       3
`define CPU_CLOCK_DIV       1       // iverilog: full speed
`else
`define UART_BIT_TIME       434     // 50MHz / 115200 baud
`define CPU_CLOCK_DIV       28      // 50MHz / 28 ≈ 1.76MHz (Plus/4 PAL speed)
`endif
