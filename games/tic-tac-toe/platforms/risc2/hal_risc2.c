/*
 * hal_risc2.c — RISC2 implementation of the Tic-Tac-Toe character HAL.
 *
 * Drives the lcd_char overlay (peripheral/lcd_char.v) via MMIO defined in
 * arch/risc2/memmap.h.  hal_putc writes go to a small back-buffer in BRAM
 * scratch; hal_swap copies the buffer to the LCD text RAM in one pass to
 * avoid mid-scanline tearing.
 */

#include "hal.h"
#include "hal_risc2.h"
#include "memmap.h"
#include "font_ibm8x16.h"

/* Convenience accessors over the LCD-char text + font RAM bases. */
#define LCD_TEXT(n)  (*(volatile unsigned int*)(MEM_LCD_CHAR_TEXT_BASE + (n)))
#define CHR_ROM(n)   (*(volatile unsigned int*)(MEM_LCD_CHAR_FONT_BASE + (n)))

/* Back buffer in BRAM scratch.  LCD is 32x16 = 512 cells; placing it at
 * BRAM+0x100 leaves the low 256 bytes free for any peripheral side-effects. */
#define BUF_BASE     ((volatile unsigned int*)(MEM_BRAM_BASE + 0x100u))
static volatile unsigned int *buf = BUF_BASE;

/* ── HAL implementation ─────────────────────────────────────────────────── */
void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        buf[row * LCD_COLS + col] = (unsigned int)ch;
}

void hal_clear(void)
{
    int i;
    int n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        buf[i] = ' ';
}

void hal_swap(void)
{
    int i;
    int n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        LCD_TEXT(i) = buf[i];
}

/* ── Init helpers ──────────────────────────────────────────────────────── */
static void gpu_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

static void gpu_clear_black(void)
{
    /* Clear and swap both buffers so neither shows garbage behind the text. */
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
}

static void lcd_char_init(void)
{
    LCD_CHAR_X      = 0;
    LCD_CHAR_Y      = 0;
    LCD_CHAR_NUMX   = LCD_COLS;
    LCD_CHAR_CONFIG = 0x8000 | LCD_ROWS;  /* enable + row count */
}

/* Upload the full IBM 8x16 font into the lcd_char font ROM.  The hardware
 * file lcd_char.v initialises fontmem from ibm8x16.hex via $readmemh, but on
 * some yosys/ECP5 paths that init does not survive synthesis — particularly
 * on HW=v2.  Re-uploading at startup makes the game robust either way. */
static void upload_font(void)
{
    int i;
    for (i = 0; i < 1024; i++)
        CHR_ROM(i) = font_ibm8x16[i];
}

void hal_risc2_init(void)
{
    gpu_clear_black();
    lcd_char_init();
    upload_font();
}
