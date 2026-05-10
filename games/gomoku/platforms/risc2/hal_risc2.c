/*
 * hal_risc2.c — RISC2 implementation of hal.h.
 *
 * Drives the dcache framebuffer (peripheral/dcache.v) via MMIO defined in
 * arch/risc2/memmap.h:
 *   - hal_clear   issues CLEAR_FB with a chosen RGB565 fill colour.
 *   - hal_fill_rect writes pixels into the scanline write buffer one row at
 *                   a time, sets GPU_ROW, and issues FLUSH per row.
 *   - hal_swap    issues SWAP_BUFFERS to flip front/back framebuffer halves.
 */

#include "hal.h"
#include "memmap.h"

static void fb_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

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
