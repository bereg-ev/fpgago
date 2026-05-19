/*
 * project.vh — Verilog-side configuration for arch/riscv-darkrv.
 *
 * The shared SDRAM peripheral (peripheral/sdram.v) and a few other files
 * `include` this header for memory geometry parameters.  Keep it minimal
 * and consistent across arches that share the same SDRAM device.
 */
`ifndef PROJECT_VH
`define PROJECT_VH

/* SDRAM device geometry (Elpida EDS2516ADTA, 16-Mbit ×16, 4 banks, 13×9). */
`define SD_WIDTH          16
`define BRAM_ADDR_WIDTH   12   /* 4K word row buffers (only 512 used per row) */

/* ── Clock / UART (real-hardware values).
   OSCG core osc is ~310 MHz; "16" divider → ~19.4 MHz sys clock.
   UART_BIT_TIME = sys_clk / baud.  19.4 MHz / 115200 ≈ 168, round to 165. */
`define MAIN_CLK_DIVIDER  "16"
`ifdef SIMULATION
  `define UART_BIT_TIME    3       /* tiny so sim doesn't sit forever on a TX */
`else
  `define UART_BIT_TIME    165     /* ~115200 baud at 19.4 MHz */
`endif

`endif
