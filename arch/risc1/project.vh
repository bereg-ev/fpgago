
// ECP5 internal oscillator divider: 310 MHz / 16 = ~19.4 MHz
`define MAIN_CLK_DIVIDER    "16"

`define CPU_DEBUGGER

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
// Real hardware (~19.4 MHz OSCG): 19.4M/115200 ≈ 168 bit time
`define UART_BIT_TIME       165
`define TIMER_PRESCALE      24'd100000
`endif

/* ---- lcd_char.v address-decode macros (parameterised so the same module
 *      serves both risc1 and risc2 with different memory maps) ---------- */
`define MEM_LCD_CHAR_TEXT_PFX8   8'h0E   /* text RAM at  0x0E0000.. (legacy) */
`define MEM_LCD_CHAR_FONT_PFX8   8'h0D   /* font RAM at  0x0D0000.. (legacy) */
`define MEM_LCD_CHAR_CFG_PFX16   16'h0C00 /* config at   0x0C0000..0x0C00FF (legacy: was 0x0C0000..0x0CFFFF; tightened to 256 B) */
