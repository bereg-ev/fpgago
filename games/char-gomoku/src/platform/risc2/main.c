/*
 * platform/risc2/main.c -- RISC2 platform layer for Gomoku (character-based)
 *
 * Uses the LCD character overlay (lcd_char) for display.  Custom 8x16 glyphs
 * for board cells are uploaded to the font ROM at startup via 0x0D0000.
 *
 * MEMORY MAP (data RAM = 1024 words at data_addr[11:2]):
 *
 *   Words 0-15:   corrupted by GPU / font ROM writes (do not use)
 *   Words 0-144:  corrupted by text RAM writes (34*17/4 ≈ 145 words max)
 *   Word  256+:   game_t at 0x010400 (safe from all corruption)
 *   Word  486+:   glyph canvas (16 words, temporary, at 0x0107A8)
 *   Word  960:    stack top (0x01FF00, grows downward)
 *
 *   Text RAM (0x0E0000) is written DIRECTLY — no back-buffer needed.
 *   This avoids the 1020-word buffer that wouldn't fit in 1024-word RAM.
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ---- GPU3D (background clear only) ------------------------------------- */
#define GPU_BASE         0x0A0000
#define GPU_REG(n)       (*(volatile unsigned int*)(GPU_BASE + (n)*4))
#define GPU_CLR_COLOR    GPU_REG(7)
#define GPU_CMD          GPU_REG(8)
#define GPU_STATUS       GPU_REG(9)
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

/* ---- LCD char overlay --------------------------------------------------- */
#define LCD_CTRL(n)      (*(volatile unsigned int*)(0x0C0000 + (n)))
#define CHR_ROM(n)       (*(volatile unsigned int*)(0x0D0000 + (n)))
#define LCD_TEXT(n)      (*(volatile unsigned int*)(0x0E0000 + (n)))

/* ---- UART --------------------------------------------------------------- */
#define IO_STATUS        (*(volatile unsigned int*)0xF0002)
#define IO_UART_TX       (*(volatile unsigned int*)0xF0003)
#define IO_UART_RX       (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY       (1 << 0)
#define UART_TXBUSY      (1 << 2)

static void uart_putchar(int ch)
{
    while (IO_STATUS & UART_TXBUSY) { /* spin */ }
    IO_UART_TX = (unsigned int)ch;
}

/* ---- Data RAM layout ---------------------------------------------------- */
/* game_t at data RAM word 256 (address 0x010400):
 *   safe from text RAM corruption (words 0-254) and GPU corruption (0-9). */
#define GAME_PTR         ((game_t*)0x010400)

/* Temporary glyph canvas: 16 words at data RAM word 486 (0x0107A8). */
#define CVS              ((unsigned int*)0x0107A8)

/* ==== Custom glyph upload ================================================ */

static void cvs_pixel(int x, int y)
{
    if ((unsigned)x < 16 && (unsigned)y < 16)
        CVS[y] = CVS[y] | (0x8000 >> x);
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
    for (y = 0; y < 16; y++) CVS[y] = 0x8000; /* left border */
    CVS[15] = 0xFFFF;                           /* bottom border */
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

/* ==== HAL implementation (direct text RAM writes, no buffer) ============= */

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
    /* row * TEXT_COLS via add-chain — volatile prevents LLVM from
     * folding it back into a __mulsi3 call (66-instruction loop). */
    volatile int t;
    int r2;
    if ((unsigned)col >= TEXT_COLS || (unsigned)row >= TEXT_ROWS)
        return;
    /* 34 = 32 + 2, so row*34 = row*32 + row*2 */
    t = row;
    t = t + t;       /* x2  */
    r2 = t;           /* save x2 */
    t = t + t;       /* x4  */
    t = t + t;       /* x8  */
    t = t + t;       /* x16 */
    t = t + t;       /* x32 */
    t = t + r2 + col; /* x34 + col */
    LCD_TEXT(t) = (unsigned int)map_char(ch);
}

void hal_swap(void)
{
    /* No-op: writes go directly to text RAM */
}

/* ==== Helpers ============================================================ */

static void gpu_wait(void)
{
    while (GPU_STATUS & 1) { /* spin */ }
}

static void gpu_clear_black(void)
{
    gpu_wait();
    GPU_CLR_COLOR = 0;
    GPU_CMD = CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
    gpu_wait();
    GPU_CLR_COLOR = 0;
    GPU_CMD = CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
}

static void lcd_init(void)
{
    /* Centre the narrow text window on the 480-pixel-wide LCD */
    int x_offset = (480 - TEXT_COLS * 8) / 2;
    LCD_CTRL(0) = x_offset;
    LCD_CTRL(1) = 0;
    LCD_CTRL(2) = TEXT_COLS;
    LCD_CTRL(3) = 0x8000 | TEXT_ROWS;
}

static int uart_getchar(void)
{
    while (!(IO_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(IO_UART_RX & 0xFF);
}

/* ==== Main =============================================================== */

int main(void)
{
    game_t *g = GAME_PTR;
    int ch;

    gpu_clear_black();
    lcd_init();
    init_glyphs();

    game_init(g);
    render_frame(g);

    for (;;) {
        ch = uart_getchar();
        game_tick(g, ch);
        render_frame(g);
    }

    return 0;
}
