/*
 * hal_pixel.c — Shared riscv-darkrv implementation of the pixel HAL.
 *
 * Used by all games that include the pixel hal.h (hal_clear / hal_fill_rect /
 * hal_swap on an RGB565 framebuffer): gomoku, chess, and anything that
 * follows the same pattern.  Each game's platforms/riscv-darkrv/Makefile
 * just adds $(ARCH_DIR)/hal_pixel.c to GAME_SRCS.
 *
 * Backend: the GPU MMIO protocol in soc.v (sim) and fb_psram.v (FPGA) —
 * scanline write-buffer (FB_BUF[col]), GPU_ROW target, GPU_CMD FLUSH /
 * CLEAR_FB / SWAP_BUFFERS, GPU_STATUS busy bit.
 */

#include "hal.h"
#include "memmap.h"

static void fb_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

void hal_init(void)
{
    /* Nothing arch-specific to bring up here — the GPU FSM is reset by
     * the SoC.  Games still call hal_clear() right after to set their bg. */
}

int hal_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

void hal_clear(u16 c)
{
    fb_wait();
    GPU_CLEAR_COLOR = c;
    GPU_CMD         = GPU_CMD_CLEAR_FB;
    fb_wait();
}

void hal_fill_rect(int x, int y, int w, int h, u16 c)
{
    int r, col;
    int x1 = x + w;
    if (x  < 0)        x = 0;
    if (y  < 0)        y = 0;
    if (x1 > SCREEN_W) x1 = SCREEN_W;
    if (y + h > SCREEN_H) h = SCREEN_H - y;

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
    fb_wait();
    /* Signal sim harness to refresh the SDL window. */
    FRAME_READY = 1;
}

/* Copy a full scanline of pixels into the back buffer.
 * Caller owns `pixels` (must have SCREEN_W u16 entries). */
void hal_blit_row(int row, const u16 *pixels)
{
    if ((unsigned)row >= (unsigned)SCREEN_H) return;
    fb_wait();
    int x;
    for (x = 0; x < SCREEN_W; x++)
        FB_BUF(x) = pixels[x];
    GPU_ROW = row;
    GPU_CMD = GPU_CMD_FLUSH;
    fb_wait();
}
