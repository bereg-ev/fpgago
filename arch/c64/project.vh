// project.vh — Commodore 64 build configuration

`ifdef SIMULATION
  `define UART_BIT_TIME 3
`else
  `define UART_BIT_TIME 434
`endif
