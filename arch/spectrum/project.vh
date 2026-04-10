// project.vh — ZX Spectrum 48K build configuration

// CPU clock divider: system_clk / CPU_CLOCK_DIV = CPU clock
// 50 MHz / 14 ≈ 3.5 MHz (original Spectrum clock)
`define CPU_CLOCK_DIV 14

// UART bit timing for simulation
`ifdef SIMULATION
  `define UART_BIT_TIME 3
`else
  `define UART_BIT_TIME 434    // 115200 baud at 50 MHz
`endif
