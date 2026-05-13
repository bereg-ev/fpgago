/* project.vh — ddr3-test config knobs.
 *
 * This is a deliberately stripped-down SoC: RISC2 CPU, 32 KB boot ROM,
 * 16 KB data BRAM, UART, and the DDR3 test peripheral.  No LCD, no audio,
 * no PSRAM, no SDRAM, no icache/dcache — the whole point is to isolate
 * the DDR3 controller for bring-up and validation.
 */

`ifdef SIMULATION
`define UART_BIT_TIME      3     /* fast sim: 1 byte ≈ 30 clocks */
`else
/* 115200 baud at clk_sys = 51.67 MHz (OSCG/2 → PLL CLKFB_DIV=4 / CLKOP_DIV=12).
 * uart.v's bit period is (UART_BIT_TIME + 1) clocks, so 51.67e6/(448+1) ≈
 * 115k → ~0.1% off, well inside any USB-UART bridge tolerance. */
`define UART_BIT_TIME      448
`endif

`define MAIN_CLK_DIVIDER   "2"   /* OSCG /2 → ~155 MHz; PLL fans out to clk_sys/clk_ddr */

`define EXTENDED_MEM             /* 32 KB ROM + 16 KB RAM */

`include "ddr3_test_memmap.vh"
