/* memmap.h — riscv-darkrv SoC memory map for C games.
 *
 * Mirror of arch/riscv-darkrv/soc.v.  Includes the GPU MMIO protocol
 * adopted from arch/risc2/memmap.h so games can share HAL conventions.
 */
#ifndef RISCV_DARKRV_MEMMAP_H
#define RISCV_DARKRV_MEMMAP_H

#include <stdint.h>

/* ── UART ────────────────────────────────────────────────────────────── */
#define UART_STATUS   (*(volatile uint32_t*)0x00200000u)
#define UART_TX       (*(volatile uint32_t*)0x00200004u)
#define UART_RX       (*(volatile uint32_t*)0x00200008u)
#define FRAME_READY   (*(volatile uint32_t*)0x0020000Cu)

#define UART_RXRDY    (1u << 0)

/* ── GPU / framebuffer-cache MMIO ────────────────────────────────────── */
#define GPU_ROW          (*(volatile uint32_t*)0x00200010u)
#define GPU_CLEAR_COLOR  (*(volatile uint32_t*)0x00200014u)
#define GPU_CMD          (*(volatile uint32_t*)0x00200018u)
#define GPU_STATUS       (*(volatile uint32_t*)0x0020001Cu)

#define GPU_CMD_FLUSH         1u   /* copy scanline buffer → FB[GPU_ROW]   */
#define GPU_CMD_CLEAR_FB      2u   /* fill FB with GPU_CLEAR_COLOR         */
#define GPU_CMD_SWAP_BUFFERS  3u   /* single-buffer for now — no-op        */
#define GPU_STATUS_BUSY       (1u << 0)

/* ── Scanline write buffer (480 × u32, only low 16 bits used) ─────────── */
#define MEM_FB_BUF_BASE  0x00300000u
#define FB_BUF(c)        (*(volatile uint32_t*)(MEM_FB_BUF_BASE + (c)*4))

/* ── Direct framebuffer (kept for labyrinth's raycaster) ───────────────── */
#define FB_BASE          0x00100000u
#define FB_PIXEL_PTR     ((volatile uint16_t*)FB_BASE)

/* ── Char-LCD overlay (used by tic-tac-toe / char-gomoku) ──────────────── */
#define MEM_BRAM_BASE          0x00010000u    /* re-uses general RAM       */
#define MEM_LCD_CHAR_TEXT_BASE 0x00400000u    /* 32×16 cells × u32         */
#define MEM_LCD_CHAR_FONT_BASE 0x00500000u    /* 128 glyphs × 16 lines     */

#define LCD_CHAR_X       (*(volatile uint32_t*)0x00200020u)
#define LCD_CHAR_Y       (*(volatile uint32_t*)0x00200024u)
#define LCD_CHAR_NUMX    (*(volatile uint32_t*)0x00200028u)
#define LCD_CHAR_CONFIG  (*(volatile uint32_t*)0x0020002Cu)

/* RGB565 helper — game-side hal.h may already provide this; guard so
 * the legacy include-order (hal.h then memmap.h) doesn't warn. */
#ifndef RGB565
#define RGB565(r,g,b)  ((uint16_t)(((r)<<11)|((g)<<5)|(b)))
#endif

#endif
