
//`define SIMULATION        // has effect on: sdram init timing, bootloader, lcd resolution
//`define CPU_DEBUGGER
//`define AUDIO
`define EXTENDED_MEM        // 8KB ROM + 16KB RAM (default: 4KB ROM + 4KB RAM)

`define TIMER_DIVIDER       3


`define MAIN_CLK_DIVIDER      "16" // "3" // "4" // "8" // "16"

`ifdef SIMULATION
`define UART_BIT_TIME		      3
`else
`define UART_BIT_TIME		      165 // 880 // 660 // 330  // 165
`endif

`define SD_WIDTH          16
`define BRAM_ADDR_WIDTH   12

/* GPU3D base address (MMIO, word-addressed, 10 registers) */
`define GPU3D_BASE        24'h0A0000


