/*
 * hal_pixel.c — Shared risc2 implementation of the pixel HAL.
 *
 * Used by gomoku, chess, and any other game that includes the pixel hal.h.
 * Drives peripheral/dcache.v: the scanline write buffer, GPU_ROW, GPU_CMD
 * (FLUSH / CLEAR_FB / SWAP_BUFFERS), and UART input.
 */

#include "hal.h"
#include "memmap.h"

static void fb_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

void hal_init(void)
{
    /* dcache is brought up by the SoC reset; games still hal_clear()
     * before their first frame to set the background colour. */
}

int hal_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

/* Hardware-accelerated clear of the back buffer.
 *
 * CLEAR_FB kicks dcache's internal row walker, which writes rows 0..271 of
 * SDRAM in a tight FSM (vastly faster than 272 separate CPU FLUSH-per-row
 * loops via hal_fill_rect).
 *
 * Catch: the same lcd_out.v off-by-one documented at hal_blit_row means PPM
 * row 271 is fed from SDRAM row 272, which CLEAR_FB never touches.  Paint
 * that row here via the normal FLUSH path (which is +1-shifted) so callers
 * see a fully cleared back buffer.  Synchronous on exit: returns only after
 * the row-271 FLUSH completes. */
void hal_clear(u16 c)
{
    fb_wait();
    GPU_CLEAR_COLOR = c;
    GPU_CMD         = GPU_CMD_CLEAR_FB;
    fb_wait();                          /* CLEAR_FB done */

    int col;
    for (col = 0; col < SCREEN_W; col++)
        FB_BUF(col) = c;
    GPU_ROW = SCREEN_H;                 /* (SCREEN_H-1) + 1 — PPM row 271 */
    GPU_CMD = GPU_CMD_FLUSH;
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
        GPU_ROW = r + 1;   /* same +1 shift as hal_blit_row; see note there */
        GPU_CMD = GPU_CMD_FLUSH;
        fb_wait();
    }
}

void hal_swap(void)
{
    fb_wait();
    GPU_CMD = GPU_CMD_SWAP_BUFFERS;
}

/* Copy a full scanline of pixels into the back buffer (RGB565).
 * Caller owns `pixels` (must have SCREEN_W u16 entries).
 *
 * NB on GPU_ROW = row + 1: dcache.v's LCD prefetch reads SDRAM row N+1
 * during LCD scan row N (intended as a one-row look-ahead for the
 * ping-pong line buffer), but lcd_out.v's active range is LCD rows
 * 1..272 — net effect, CPU's "FB row N" displays at PPM row N-1.
 *
 *   FB row 0  → never displayed (LCD row 0 is in blanking).
 *   FB row N  → PPM row N-1 (visible).
 *   PPM row 271 always reads SDRAM row 272 (out of FB) → garbage.
 *
 * Shifting the row by +1 here makes user code's row [0..271] land at the
 * matching PPM row [0..271].  Range becomes GPU_ROW=[1..272], which
 * fits in the 9-bit row_reg.  Other dcache MMIO that internally walks
 * rows (CLEAR_FB) doesn't get this fix — games that paint critical
 * content via hal_clear at row 271 will still see garbage; labyrinth2
 * isn't one of them (it overwrites every pixel via hal_blit_row). */
void hal_blit_row(int row, const u16 *pixels)
{
    if (row < 0 || row >= SCREEN_H) return;
    fb_wait();
    int x;
    for (x = 0; x < SCREEN_W; x++)
        FB_BUF(x) = pixels[x];
    GPU_ROW = row + 1;
    GPU_CMD = GPU_CMD_FLUSH;
    fb_wait();
}
