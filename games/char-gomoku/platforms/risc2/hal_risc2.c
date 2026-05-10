/*
 * hal_risc2.c — RISC2 implementation of the character HAL for Char-Gomoku.
 *
 * Drives the lcd_char overlay (peripheral/lcd_char.v) via MMIO defined in
 * arch/risc2/memmap.h:
 *   - LCD_CHAR_X/Y/NUMX/CONFIG    overlay window position + size + enable
 *   - MEM_LCD_CHAR_TEXT_BASE      text RAM (one byte per cell)
 *   - MEM_LCD_CHAR_FONT_BASE      font ROM (8x16 glyph bitmaps)
 *   - GPU_CLEAR_COLOR / GPU_CMD   pixel framebuffer (background only)
 *
 * Writes go straight to text RAM, so hal_swap is a no-op.
 *
 * Custom glyphs (codes 128-175) for board cells are uploaded once at startup
 * using a temporary 16-word canvas in BRAM scratch.
 */

#include "hal.h"
#include "hal_risc2.h"
#include "memmap.h"

/* ── Convenience accessors over memmap.h base addresses ────────────────── */
#define LCD_TEXT(n)  (*(volatile unsigned int*)(MEM_LCD_CHAR_TEXT_BASE + (n)))
#define CHR_ROM(n)   (*(volatile unsigned int*)(MEM_LCD_CHAR_FONT_BASE + (n)))

/* Temporary 16-word glyph canvas in BRAM scratch (used only during init). */
#define CVS          ((volatile unsigned int*)0x0107A8u)

/* ── Glyph canvas helpers (build one 16x16 cell, then upload as left+right) ── */
static void cvs_pixel(int x, int y)
{
    if ((unsigned)x < 16 && (unsigned)y < 16)
        CVS[y] = CVS[y] | (0x8000u >> x);
}

static void cvs_upload(int left_pos, int right_pos)
{
    int p;
    for (p = 0; p < 8; p++) {
        unsigned int even_row = CVS[p * 2];
        unsigned int odd_row  = CVS[p * 2 + 1];
        unsigned int le = (even_row >> 8) & 0xFF;
        unsigned int lo = (odd_row  >> 8) & 0xFF;
        CHR_ROM(left_pos * 8 + p) = (lo << 8) | le;
        unsigned int re = even_row & 0xFF;
        unsigned int ro = odd_row  & 0xFF;
        CHR_ROM(right_pos * 8 + p) = (ro << 8) | re;
    }
}

static void cvs_clear_and_border(void)
{
    int y;
    for (y = 0; y < 16; y++) CVS[y] = 0x8000u; /* left border */
    CVS[15] = 0xFFFFu;                          /* bottom border */
}

static void init_glyphs(void)
{
    int i, y;

    /* Empty cell → font positions 0, 1 */
    cvs_clear_and_border();
    cvs_upload(0, 1);

    /* X piece → font positions 2, 3 */
    cvs_clear_and_border();
    for (i = 0; i <= 10; i++) {
        int dy = 2 + i;
        cvs_pixel(2 + i,  dy);
        cvs_pixel(3 + i,  dy);
        cvs_pixel(13 - i, dy);
        cvs_pixel(12 - i, dy);
    }
    cvs_upload(2, 3);

    /* O piece → font positions 4, 5 */
    cvs_clear_and_border();
    for (i = 5; i <= 10; i++) { cvs_pixel(i, 2); cvs_pixel(i, 12); }
    for (i = 3; i <= 12; i++) { cvs_pixel(i, 3); cvs_pixel(i, 11); }
    for (y = 4; y <= 10; y++) {
        cvs_pixel(3,  y); cvs_pixel(4,  y);
        cvs_pixel(11, y); cvs_pixel(12, y);
    }
    cvs_upload(4, 5);

    /* Cursor → font positions 6, 7 */
    cvs_clear_and_border();
    for (i = 3; i <= 12; i++) {
        cvs_pixel(i, 2);  cvs_pixel(i, 3);
        cvs_pixel(i, 11); cvs_pixel(i, 12);
    }
    for (y = 2; y <= 12; y++) {
        cvs_pixel(3,  y); cvs_pixel(4,  y);
        cvs_pixel(11, y); cvs_pixel(12, y);
    }
    cvs_upload(6, 7);
}

/* ── HAL implementation (direct text RAM writes) ───────────────────────── */
static int map_char(int ch)
{
    if (ch >= 128 && ch <= 135)
        return ch & 0x7F;
    if (ch >= 144 && ch <= 173) {
        /* idx / 2 via bit shift — avoids __lshrsi3 call */
        int idx = ch - 144;
        if (idx & 1) return ' ';
        return 'A' + ((unsigned)idx >> 1);
    }
    return ch;
}

void hal_clear(void)
{
    int i;
    int n = TEXT_COLS * TEXT_ROWS;
    for (i = 0; i < n; i++)
        LCD_TEXT(i) = ' ';
}

void hal_putchar(int col, int row, int ch)
{
    /* row * TEXT_COLS via add-chain: volatile prevents LLVM from folding it
     * back into a __mulsi3 call (which the RISC2 backend lacks). */
    volatile int t;
    int r2;
    if ((unsigned)col >= TEXT_COLS || (unsigned)row >= TEXT_ROWS)
        return;
    /* TEXT_COLS = 34 = 32 + 2, so row*34 = row*32 + row*2 */
    t = row;
    t = t + t;        /* x2  */
    r2 = t;            /* save x2 */
    t = t + t;        /* x4  */
    t = t + t;        /* x8  */
    t = t + t;        /* x16 */
    t = t + t;        /* x32 */
    t = t + r2 + col; /* x34 + col */
    LCD_TEXT(t) = (unsigned int)map_char(ch);
}

void hal_swap(void)
{
    /* No-op: writes go directly to text RAM */
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
    /* Centre the narrow text window on the 480-pixel-wide LCD */
    int x_offset = (480 - TEXT_COLS * 8) / 2;
    LCD_CHAR_X      = x_offset;
    LCD_CHAR_Y      = 0;
    LCD_CHAR_NUMX   = TEXT_COLS;
    LCD_CHAR_CONFIG = 0x8000 | TEXT_ROWS;  /* enable + row count */
}

void hal_risc2_init(void)
{
    gpu_clear_black();
    lcd_char_init();
    init_glyphs();
}
