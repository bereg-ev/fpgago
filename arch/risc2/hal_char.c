/*
 * hal_char.c — Shared risc2 implementation of the char-LCD HAL.
 *
 * Used by tic-tac-toe and char-gomoku.  Drives peripheral/lcd_char.v via
 * MMIO from arch/risc2/memmap.h.
 *
 * Notes specific to risc2:
 *   - The runtime has no __mulsi3, so we cannot write `row * HAL_COLS`
 *     directly when HAL_COLS isn't a power of two.  HAL_LINEAR below
 *     decomposes both supported widths (32 and 34) into shifts/adds the
 *     compiler will emit without an integer-multiply call.
 *   - Cell writes go to a BRAM back buffer; hal_swap copies it to LCD
 *     text RAM in one pass to avoid tearing.
 *   - hal_upload_glyph takes a 0..127 font-slot index, not the symbolic
 *     128+ codes some games used to use — translation now lives game-side.
 */

#include "hal.h"
#include "memmap.h"
#include "font_ibm8x16.h"

#if defined(LCD_COLS)
  #define HAL_COLS  LCD_COLS
  #define HAL_ROWS  LCD_ROWS
#else
  #define HAL_COLS  TEXT_COLS
  #define HAL_ROWS  TEXT_ROWS
#endif

#if   HAL_COLS == 32
  #define HAL_LINEAR(r, c)  (((r) << 5) + (c))
#elif HAL_COLS == 34
  #define HAL_LINEAR(r, c)  (((r) << 5) + ((r) << 1) + (c))
#else
  #error "arch/risc2/hal_char.c: add a HAL_LINEAR variant for this HAL_COLS"
#endif

#define LCD_TEXT(n)  (*(volatile unsigned int*)(MEM_LCD_CHAR_TEXT_BASE + (n)))
#define CHR_ROM(n)   (*(volatile unsigned int*)(MEM_LCD_CHAR_FONT_BASE + (n)))

#define BUF_BASE  ((volatile unsigned int*)(MEM_BRAM_BASE + 0x100u))
static volatile unsigned int *buf = BUF_BASE;

static void gpu_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

static void put_cell(int col, int row, int ch)
{
    if (col >= 0 && col < HAL_COLS && row >= 0 && row < HAL_ROWS)
        buf[HAL_LINEAR(row, col)] = (unsigned int)ch;
}

/* Both spellings exposed; only one is used by any given game. */
void hal_putc   (int col, int row, int ch) { put_cell(col, row, ch); }
void hal_putchar(int col, int row, int ch) { put_cell(col, row, ch); }

void hal_clear(void)
{
    int i, n = HAL_COLS * HAL_ROWS;   /* constant-folded */
    for (i = 0; i < n; i++) buf[i] = ' ';
}

void hal_swap(void)
{
    int i, n = HAL_COLS * HAL_ROWS;
    for (i = 0; i < n; i++) LCD_TEXT(i) = buf[i];
}

/* Overwrite one glyph in font ROM.  `slot` is the 0..127 font index the
 * hardware will look up when a text cell holds that value; `bitmap[i]` is
 * row i (top→bottom), each byte = 8 horizontal pixels (MSB = leftmost). */
void hal_upload_glyph(int slot, const unsigned char *bitmap)
{
    int idx = slot & 0x7F;
    int i;
    for (i = 0; i < 8; i++) {
        unsigned int even = bitmap[i * 2];
        unsigned int odd  = bitmap[i * 2 + 1];
        CHR_ROM(idx * 8 + i) = (odd << 8) | even;
    }
}

int hal_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

void hal_init(void)
{
    /* Centre narrow text windows on the 480-wide LCD (HAL_COLS=34 → 104px
     * margin; HAL_COLS=32 → 112px margin).  HAL_COLS*8 is constant-folded. */
    int x_offset = (480 - HAL_COLS * 8) / 2;
    if (x_offset < 0) x_offset = 0;

    /* Blank both pixel-FB buffers behind the overlay. */
    gpu_wait();
    GPU_CLEAR_COLOR = 0;
    GPU_CMD         = GPU_CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD         = GPU_CMD_SWAP_BUFFERS;
    gpu_wait();
    GPU_CLEAR_COLOR = 0;
    GPU_CMD         = GPU_CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD         = GPU_CMD_SWAP_BUFFERS;

    /* Overlay window. */
    LCD_CHAR_X      = x_offset;
    LCD_CHAR_Y      = 0;
    LCD_CHAR_NUMX   = HAL_COLS;
    LCD_CHAR_CONFIG = 0x8000u | HAL_ROWS;

    /* Re-upload the IBM 8x16 font: lcd_char.v $readmemh init is dropped by
     * some yosys/ECP5 paths on HW=v2.  Games may overwrite individual slots
     * afterward via hal_upload_glyph. */
    {
        int i;
        for (i = 0; i < 1024; i++)
            CHR_ROM(i) = font_ibm8x16[i];
    }
}
