/*
 * glyphs.c — Build & upload the custom Char-Gomoku board glyphs.
 *
 * The board cells consist of pairs of 8x16 character glyphs that together
 * form a 16x16 "square" with built-in grid borders (left edge column +
 * bottom edge row).  The bitmaps are built on a temporary 16-pixel-wide
 * canvas, then split into two 8-pixel halves and pushed into the font ROM
 * via hal_upload_glyph().
 *
 * Slot layout (after the 0x7F mask the HAL applies):
 *   CH_EMPTY_L=128 → slot 0    empty cell, left half (border only)
 *   CH_EMPTY_R=129 → slot 1    empty cell, right half
 *   CH_X_L    =130 → slot 2    'X' piece, left half
 *   CH_X_R    =131 → slot 3    'X' piece, right half
 *   CH_O_L    =132 → slot 4    'O' piece, left half
 *   CH_O_R    =133 → slot 5    'O' piece, right half
 *   CH_CUR_L  =134 → slot 6    cursor, left half
 *   CH_CUR_R  =135 → slot 7    cursor, right half
 *   CH_HDR_L(c)=144+c*2 → slot 16+c*2   column header c, left half (A..O w/ border)
 *   CH_HDR_R(c)=145+c*2 → slot 17+c*2   column header c, right half
 *
 * The slot indices for headers happen to land in the ASCII control-char
 * range (16..45) — overwriting those slots is safe because the game never
 * displays those control characters anywhere.
 */

#include "hal.h"
#include "glyphs.h"
#include "font5x7.h"

/* 16-pixel-wide canvas: row r, columns 0..7 = left half, 8..15 = right half. */
static unsigned char cvs[16];   /* high 8 bits → left, low 8 bits would need
                                 * a wider type; instead we keep two 8-bit
                                 * rows in separate L/R arrays below. */
static unsigned char cvs_l[16];
static unsigned char cvs_r[16];

static void cvs_clear(void)
{
    int y;
    for (y = 0; y < 16; y++) { cvs_l[y] = 0; cvs_r[y] = 0; }
    (void)cvs;  /* silence unused warning in case host compiler is picky */
}

static void cvs_pixel(int x, int y)
{
    if ((unsigned)x >= 16 || (unsigned)y >= 16) return;
    if (x < 8) cvs_l[y] |= (unsigned char)(0x80 >> x);
    else       cvs_r[y] |= (unsigned char)(0x80 >> (x - 8));
}

/* Bake the standard grid: left border on every row of the left half, plus a
 * bottom border on the bottom row of both halves. */
static void cvs_borders(void)
{
    int y;
    for (y = 0; y < 16; y++) cvs_l[y] |= 0x80;
    cvs_l[15] = 0xFF;
    cvs_r[15] = 0xFF;
}

static void cvs_upload_pair(int left_slot, int right_slot)
{
    hal_upload_glyph(left_slot,  cvs_l);
    hal_upload_glyph(right_slot, cvs_r);
}

/* Plot a 5x7 ASCII letter at offset (gx, gy) on the canvas. */
static void cvs_letter(int gx, int gy, int ch)
{
    if (ch < 0x20 || ch > 0x7E) return;
    const unsigned int *fnt = font5x7[ch - 0x20];
    int row, col;
    for (row = 0; row < 7; row++) {
        unsigned int bits = fnt[row];
        for (col = 0; col < 5; col++) {
            if (bits & (0x10u >> col))
                cvs_pixel(gx + col, gy + row);
        }
    }
}

void game_init_glyphs(void)
{
    int i, y;

    /* Empty cell: just the grid borders. */
    cvs_clear(); cvs_borders();
    cvs_upload_pair(CH_EMPTY_L, CH_EMPTY_R);

    /* X piece: two 2-px-wide diagonals. */
    cvs_clear(); cvs_borders();
    for (i = 0; i <= 10; i++) {
        int dy = 2 + i;
        cvs_pixel(2 + i,  dy);
        cvs_pixel(3 + i,  dy);
        cvs_pixel(13 - i, dy);
        cvs_pixel(12 - i, dy);
    }
    cvs_upload_pair(CH_X_L, CH_X_R);

    /* O piece: thick rounded ring. */
    cvs_clear(); cvs_borders();
    for (i = 5; i <= 10; i++) { cvs_pixel(i, 2);  cvs_pixel(i, 12); }
    for (i = 3; i <= 12; i++) { cvs_pixel(i, 3);  cvs_pixel(i, 11); }
    for (y = 4; y <= 10; y++) {
        cvs_pixel(3,  y); cvs_pixel(4,  y);
        cvs_pixel(11, y); cvs_pixel(12, y);
    }
    cvs_upload_pair(CH_O_L, CH_O_R);

    /* Cursor: hollow 2-px-thick rectangle. */
    cvs_clear(); cvs_borders();
    for (i = 3; i <= 12; i++) {
        cvs_pixel(i, 2);  cvs_pixel(i, 3);
        cvs_pixel(i, 11); cvs_pixel(i, 12);
    }
    for (y = 2; y <= 12; y++) {
        cvs_pixel(3,  y); cvs_pixel(4,  y);
        cvs_pixel(11, y); cvs_pixel(12, y);
    }
    cvs_upload_pair(CH_CUR_L, CH_CUR_R);

    /* Column headers A..O with bottom border (acts as the board's top edge). */
    for (i = 0; i < 15; i++) {
        cvs_clear(); cvs_borders();
        cvs_letter(6, 4, 'A' + i);   /* nudged a little right + down */
        cvs_upload_pair(CH_HDR_L(i), CH_HDR_R(i));
    }
}
