/* memmap.h — risc2 SoC memory map for C games.
 *
 * Mirror of arch/risc2/memmap.vh.  Keep the two in sync.
 *
 * All peripheral MMIO sits in 0x000000..0x0FFFFF so accesses compile to a
 * single LOAD/STORE without an IMM prefix.
 */

#ifndef RISC2_MEMMAP_H
#define RISC2_MEMMAP_H

#include <stdint.h>

/* ---- SYS (LEDs, version, debug) -------------------------------------- */
#define SYS_LED_SET     (*(volatile uint32_t*)0x008000u)
#define SYS_LED_CLR     (*(volatile uint32_t*)0x008004u)
#define SYS_VERSION     (*(volatile uint32_t*)0x008008u)
#define SYS_DEBUG       (*(volatile uint32_t*)0x00800Cu)
#define SYS_ICACHE_BUSY (*(volatile uint32_t*)0x008010u)

/* ---- UART ------------------------------------------------------------- */
#define UART_STATUS     (*(volatile uint32_t*)0x008100u)
#define UART_TX         (*(volatile uint32_t*)0x008104u)
#define UART_RX         (*(volatile uint32_t*)0x008108u)

#define UART_RXRDY      (1u << 0)
#define UART_RXOVF      (1u << 1)
#define UART_TXBUSY     (1u << 2)

/* ---- AUDIO (3-channel SID-style synth, 16 byte registers) ------------- */
#define AUDIO_REG_BASE  0x008400u
#define AUDIO_REG(i)    (*(volatile uint8_t*)(AUDIO_REG_BASE + (i)))

/* ---- GPU / framebuffer-cache MMIO ------------------------------------- */
#define GPU_ROW          (*(volatile uint32_t*)0x008500u)  /* reg 0  */
#define GPU_CLEAR_COLOR  (*(volatile uint32_t*)0x00851Cu)  /* reg 7  */
#define GPU_CMD          (*(volatile uint32_t*)0x008520u)  /* reg 8  */
#define GPU_STATUS       (*(volatile uint32_t*)0x008524u)  /* reg 9  */

#define GPU_CMD_FLUSH         1u
#define GPU_CMD_CLEAR_FB      2u
#define GPU_CMD_SWAP_BUFFERS  3u
#define GPU_STATUS_BUSY       (1u << 0)

/* ---- LCD-CHAR display config (X, Y, chnumx, enabled+chnumy) ----------- */
#define LCD_CHAR_X       (*(volatile uint32_t*)0x008600u)
#define LCD_CHAR_Y       (*(volatile uint32_t*)0x008601u)
#define LCD_CHAR_NUMX    (*(volatile uint32_t*)0x008602u)
#define LCD_CHAR_CONFIG  (*(volatile uint32_t*)0x008603u)

/* ---- Memory regions --------------------------------------------------- */
#define MEM_BRAM_BASE          0x010000u
#define MEM_LCD_CHAR_TEXT_BASE 0x020000u
#define MEM_LCD_CHAR_FONT_BASE 0x030000u
#define MEM_EXT_RAM_BASE       0x100000u
#define MEM_FB_BASE            0x200000u

/* Framebuffer scanline write buffer: write column c (0..479) before FLUSH. */
#define FB_BUF(c)        (*(volatile uint32_t*)(MEM_FB_BASE + (c)*4))

#endif /* RISC2_MEMMAP_H */
