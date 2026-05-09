/* memmap.vh — risc2 SoC memory map (24-bit address space).
 *
 * All peripheral MMIO is in the bottom 1 MB (0x000000..0x0FFFFF), so a
 * single LOAD/STORE with a 20-bit immediate (no IMM prefix) reaches every
 * peripheral.  External RAM and the framebuffer live above 1 MB and are
 * accessed through icache/dcache (paying the IMM cost there is fine).
 *
 * Layout
 * ------
 *   0x000000..0x007FFF   Boot ROM                         (32 KB)
 *   0x008000..0x008FFF   Peripheral page (256-byte slots) (4 KB)
 *      0x008000  SYS    LEDs, version, debug, icache busy
 *      0x008100  UART   status, tx, rx
 *      0x008200  TIMER  (reserved for future MMIO)
 *      0x008300  JOYSTICK / keyboard
 *      0x008400  AUDIO  16 byte registers
 *      0x008500  GPU    ROW, CLEAR_COLOR, CMD, STATUS (dcache MMIO)
 *      0x008600  LCD-CHAR-CFG  X, Y, chnumx, enabled+chnumy
 *   0x010000..0x01FFFF   BRAM scratch RAM
 *   0x020000..0x02FFFF   LCD-char text RAM
 *   0x030000..0x03FFFF   LCD-char font RAM
 *   0x100000..0x1FFFFF   External RAM (HW v1 SDR x-bus, HW v2 QSPI)
 *   0x200000..0x2FFFFF   Framebuffer  (HW v1 SDR y-bus, HW v2 QSPI shared)
 */

/* ---- Peripheral page (high 16 bits identify the peripheral) ----------- */
`define MEM_SYS_PFX16            16'h0080
`define MEM_UART_PFX16           16'h0081
`define MEM_TIMER_PFX16          16'h0082
`define MEM_JOYSTICK_PFX16       16'h0083
`define MEM_AUDIO_PFX16          16'h0084
`define MEM_GPU_PFX16            16'h0085
`define MEM_LCD_CHAR_CFG_PFX16   16'h0086

/* ---- Full byte addresses for one-shot equality compares --------------- */
`define ADDR_SYS_LED_SET         24'h008000
`define ADDR_SYS_LED_CLR         24'h008004
`define ADDR_SYS_VERSION         24'h008008
`define ADDR_SYS_DEBUG           24'h00800C
`define ADDR_SYS_ICACHE_BUSY     24'h008010
`define ADDR_UART_STATUS         24'h008100
`define ADDR_UART_TX             24'h008104
`define ADDR_UART_RX             24'h008108
`define ADDR_GPU_ROW             24'h008500
`define ADDR_GPU_CLEAR_COLOR     24'h00851C
`define ADDR_GPU_CMD             24'h008520
`define ADDR_GPU_STATUS          24'h008524

/* ---- Larger regions identified by 8-bit prefix ------------------------ */
`define MEM_BRAM_PFX8            8'h01
`define MEM_LCD_CHAR_TEXT_PFX8   8'h02
`define MEM_LCD_CHAR_FONT_PFX8   8'h03

/* ---- External RAM and framebuffer (4-bit prefix) ---------------------- */
`define MEM_EXT_RAM_PFX4         4'h1     /* 0x100000..0x1FFFFF */
`define MEM_FB_PFX4              4'h2     /* 0x200000..0x2FFFFF */

/* ---- Boot ROM range used by data_in_valid and read-back logic --------- */
`define MEM_ROM_PFX9             9'b0     /* 0x000000..0x007FFF, 32 KB */
