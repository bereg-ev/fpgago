
`ifdef SIMULATION_SDL
// SDL desktop sim: full 480x272 frame = ~159500 clocks.
// prescale 160000 * speed 10 = ~10 frames/move ≈ 3 moves/sec
`define UART_BIT_TIME       3
`define TIMER_PRESCALE      24'd160000
`elsif SIMULATION
// iverilog tiny-frame waveform sim: fast prescale for quick testing
`define UART_BIT_TIME       3
`define TIMER_PRESCALE      24'd100
`else
// Real hardware (50 MHz): 250000 * speed 10 = 2.5M clocks/move ≈ 2 moves/sec
`define UART_BIT_TIME       434
`define TIMER_PRESCALE      24'd250000
`endif
