/*
 * platform/risc2/main.c — RISC2 platform layer for Five-in-a-Row
 *
 * Uses the dcache memory-mapped framebuffer for pixel rendering.
 * CPU writes pixels to a scanline write buffer, sets the target row,
 * and issues a FLUSH command to burst-write the buffer to Y SDRAM.
 *
 * dcache registers (same base as old GPU3D):
 *   0x200000 + col*4   Write pixel (RGB565) to buffer at column col
 *   0x0A0000  (reg 0)  ROW — target back-buffer row for FLUSH
 *   0x0A001C  (reg 7)  CLEAR_COLOR — RGB565 for CLEAR_FB
 *   0x0A0020  (reg 8)  CMD — 1=FLUSH, 2=CLEAR_FB, 3=SWAP_BUFFERS
 *   0x0A0024  (reg 9)  STATUS — bit 0 = busy
 *
 * UART / IO registers: 0xF0002 (status), 0xF0003 (TX), 0xF0004 (RX)
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ── dcache framebuffer interface ───────────────────────────────────────────── */
#define FB_BUF(c)       (*(volatile unsigned int*)(0x200000 + (c)*4))
#define FB_ROW          (*(volatile unsigned int*)0x0A0000)
#define FB_CLR_COLOR    (*(volatile unsigned int*)0x0A001C)
#define FB_CMD          (*(volatile unsigned int*)0x0A0020)
#define FB_STATUS       (*(volatile unsigned int*)0x0A0024)

#define CMD_FLUSH        1
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

/* ── UART / IO registers ─────────────────────────────────────────────────── */
#define IO_STATUS   (*(volatile unsigned int*)0xF0002)
#define IO_UART_RX  (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY  (1 << 0)

/* ── Helper: wait for dcache idle ─────────────────────────────────────────── */
static void fb_wait(void)
{
    while (FB_STATUS & 1) { /* spin */ }
}

/* ── HAL implementation ──────────────────────────────────────────────────── */
void hal_clear(u16 c)
{
    fb_wait();
    FB_CLR_COLOR = c;
    FB_CMD       = CMD_CLEAR_FB;
}

void hal_fill_rect(int x, int y, int w, int h, u16 c)
{
    int r, col;
    int x1 = x + w;
    for (r = y; r < y + h; r++) {
        for (col = x; col < x1; col++)
            FB_BUF(col) = c;
        FB_ROW = r;
        FB_CMD = CMD_FLUSH;
        fb_wait();
    }
}

void hal_swap(void)
{
    fb_wait();
    FB_CMD = CMD_SWAP_BUFFERS;
}

/* ── UART I/O ────────────────────────────────────────────────────────────── */
static int uart_getchar(void)
{
    while (!(IO_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(IO_UART_RX & 0xFF);
}

/* ── Game state in data RAM ──────────────────────────────────────────────── */
/* Data RAM words 0-479 are corrupted by framebuffer buffer writes
 * (FB_BUF(col) at 0x200000+col*4 aliases to data_addr[11:2]=col).
 * Place game state above the corruption zone: word 480+ = 0x010780. */
#define GAME_PTR  ((game_t*)0x010780)

/* ── Main ────────────────────────────────────────────────────────────────── */
int main(void)
{
    game_t *g = GAME_PTR;
    int ch;

    game_init(g);

    /* Clear + render both buffers so the display starts clean */
    render_frame(g);
    hal_swap();
    render_frame(g);
    hal_swap();

    for (;;) {
        ch = uart_getchar();
        game_tick(g, ch);
        render_frame(g);
        hal_swap();
    }

    return 0;
}
