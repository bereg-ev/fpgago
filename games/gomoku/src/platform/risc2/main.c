/*
 * platform/risc2/main.c — RISC2 platform layer for Five-in-a-Row
 *
 * All MMIO addresses come from arch/risc2/memmap.h.
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"
#include "memmap.h"

/* ── Helper: wait for dcache idle ─────────────────────────────────────────── */
static void fb_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

/* ── HAL implementation ──────────────────────────────────────────────────── */
void hal_clear(u16 c)
{
    fb_wait();
    GPU_CLEAR_COLOR = c;
    GPU_CMD         = GPU_CMD_CLEAR_FB;
}

void hal_fill_rect(int x, int y, int w, int h, u16 c)
{
    int r, col;
    int x1 = x + w;
    for (r = y; r < y + h; r++) {
        for (col = x; col < x1; col++)
            FB_BUF(col) = c;
        GPU_ROW = r;
        GPU_CMD = GPU_CMD_FLUSH;
        fb_wait();
    }
}

void hal_swap(void)
{
    fb_wait();
    GPU_CMD = GPU_CMD_SWAP_BUFFERS;
}

/* ── UART I/O ────────────────────────────────────────────────────────────── */
static int uart_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

/* ── Game state in external RAM (PSRAM on HW=v2, X-SDRAM on HW=v1) ──────── */
/* Both HW versions map external memory at MEM_EXT_RAM_BASE = 0x100000.  In
 * v1 that's the X-bus SDR SDRAM; in v2 it's the APS6404L QSPI PSRAM behind
 * psram_iface.v.  Putting game state there exercises the cache/controller
 * paths instead of the BRAM scratchpad. */
#define GAME_PTR  ((game_t*)MEM_EXT_RAM_BASE)

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
