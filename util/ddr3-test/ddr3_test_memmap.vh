/* ddr3_test_memmap.vh — RISC2 24-bit memory map for the ddr3-test SoC.
 *
 *   0x000000..0x007FFF   Boot ROM             (32 KB)
 *   0x008000..0x00800F   SYS  (LEDs, version)
 *   0x008100..0x00810F   UART
 *   0x008300..0x0083FF   DDR3 test peripheral
 *   0x010000..0x013FFF   Data BRAM scratch    (16 KB)
 *
 * Anything else returns zero on read and is ignored on write.
 */

`define MEM_SYS_PFX16            16'h0080
`define MEM_UART_PFX16           16'h0081
`define MEM_DDR3_PFX16           16'h0083
`define MEM_BRAM_PFX8            8'h01

`define ADDR_SYS_LED_SET         24'h008000
`define ADDR_SYS_LED_CLR         24'h008004
`define ADDR_SYS_VERSION         24'h008008
`define ADDR_UART_STATUS         24'h008100
`define ADDR_UART_TX             24'h008104
`define ADDR_UART_RX             24'h008108
