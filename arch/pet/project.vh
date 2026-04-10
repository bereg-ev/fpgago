
`ifdef SIMULATION_SDL
`define UART_BIT_TIME       3
`define CPU_CLOCK_DIV       2       // fast sim: 50MHz/2 = 25MHz effective
`elsif SIMULATION
`define UART_BIT_TIME       3
`define CPU_CLOCK_DIV       1       // iverilog: full speed
`else
`define UART_BIT_TIME       434     // 50MHz / 115200 baud
`define CPU_CLOCK_DIV       50      // 50MHz / 50 = 1MHz (real PET speed)
`endif
