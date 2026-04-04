/*
 * platform/risc2/main.c — RISC2 platform layer for Chess
 *
 * Uses the dcache memory-mapped framebuffer for pixel rendering.
 * Requires EXTENDED_MEM (16KB data RAM) for game state + zobrist tables.
 *
 * Memory layout (data RAM 0x010000–0x013FFF):
 *   0x010000  game_t       (~3.4KB with MAX_UNDO=128)
 *   0x011000  zobrist tables (~4KB)
 *   0x01FF00  stack (grows down)
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ── dcache framebuffer interface ──────────────────────────────────── */
#define FB_BUF(c)       (*(volatile unsigned int*)(0x200000 + (c)*4))
#define FB_ROW          (*(volatile unsigned int*)0x0A0000)
#define FB_CLR_COLOR    (*(volatile unsigned int*)0x0A001C)
#define FB_CMD          (*(volatile unsigned int*)0x0A0020)
#define FB_STATUS       (*(volatile unsigned int*)0x0A0024)

#define CMD_FLUSH        1
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

/* ── UART / IO registers ──────────────────────────────────────────── */
#define IO_STATUS   (*(volatile unsigned int*)0xF0002)
#define IO_UART_RX  (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY  (1 << 0)

/* ── Helper: wait for dcache idle ─────────────────────────────────── */
static void fb_wait(void)
{
    while (FB_STATUS & 1) { /* spin */ }
}

/* ── HAL implementation ───────────────────────────────────────────── */
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

/* ── UART I/O ─────────────────────────────────────────────────────── */
static int uart_getchar(void)
{
    while (!(IO_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(IO_UART_RX & 0xFF);
}

/* ── Game state at fixed data RAM address ─────────────────────────── */
#define GAME_PTR  ((game_t*)0x010000)

/* ── Main ─────────────────────────────────────────────────────────── */
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
