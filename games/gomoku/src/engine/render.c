/*
 * render.c — frame rendering for Five-in-a-Row
 *
 * All drawing is done exclusively via hal_fill_rect() and hal_clear().
 * No platform, SDL2, or GPU3D headers are included here.
 *
 * RISC2 note: all string data uses const int[] (word-wide elements) to avoid
 * 8-bit (byte) memory loads, which the RISC2 LLVM backend cannot select.
 *
 * Screen layout (480×272):
 *   x=4..243   Board area  (15×15 cells, 16 px/cell, 240×240 px total)
 *   x=248..476 Info panel  (status text and key hints)
 */

#include "render.h"
#include "font.h"
#include "../hal/hal.h"

/* ── Layout constants ─────────────────────────────────────────────────────── */
#define BOARD_X      4
#define BOARD_Y      4
#define CELL         16
#define BOARD_PX     (BOARD_SIZE * CELL)   /* 240 */

#define INFO_X       248
#define INFO_W       (SCREEN_W - INFO_X - 4)
#define INFO_Y       4

/* ── Colour palette (RGB565) ─────────────────────────────────────────────── */
#define COL_BG        RGB565( 3,  6,  3)
#define COL_GRID      RGB565( 7, 14,  7)
#define COL_DOT       RGB565(10, 20, 10)
#define COL_HUMAN     RGB565(31, 31, 31)   /* white  — X symbol */
#define COL_AI_PIECE  RGB565(28, 10,  4)   /* orange — O symbol */
#define COL_AI        RGB565( 0,  0,  0)
#define COL_AI_RIM    RGB565( 8, 16,  8)
#define COL_CURSOR    RGB565(31, 40,  0)
#define COL_INFO_BG   RGB565( 2,  4,  2)
#define COL_TEXT      RGB565(18, 36, 18)
#define COL_TITLE     RGB565(24, 50, 24)
#define COL_HUMAN_TXT RGB565(28, 28, 31)
#define COL_AI_TXT    RGB565(20, 40, 20)
#define COL_WIN_TXT   RGB565(31, 63,  0)
#define COL_DRAW_TXT  RGB565(20, 40, 20)

/* ── String constants as int[] to avoid byte loads on RISC2 ─────────────── */
static const int s_GOMOKU[]    = {'G','O','M','O','K','U', 0};
static const int s_5INAROW[]   = {'5',' ','I','N',' ','A',' ','R','O','W', 0};
static const int s_YOUR[]      = {'Y','O','U','R', 0};
static const int s_TURN[]      = {'T','U','R','N', 0};
static const int s_AI[]        = {'A','I', 0};
static const int s_WINS[]      = {'W','I','N','S','!', 0};
static const int s_YOU[]       = {'Y','O','U', 0};
static const int s_WIN[]       = {'W','I','N','!', 0};
static const int s_DRAW[]      = {'D','R','A','W','!', 0};
static const int s_MOVES[]     = {'M','O','V','E','S',':', 0};
static const int s_YOUEQ[]     = {'Y','O','U','=', 0};
static const int s_AIEQ[]      = {'A','I',' ','=', 0};
static const int s_WASD[]      = {'W','A','S','D', 0};
static const int s_MOVE[]      = {' ','M','O','V','E', 0};
static const int s_SPC[]       = {'S','P','C', 0};
static const int s_PLACE[]     = {' ','P','L','A','C','E', 0};
static const int s_SPCNEW[]    = {'S','P','C','=','N','E','W', 0};
static const int s_GAME[]      = {'G','A','M','E', 0};

/* ── Bitmap text rendering ───────────────────────────────────────────────── */
/* ch is passed as int to avoid byte-load patterns */
static void render_char(int px, int py, int ch, int s, u16 c)
{
    int row, col;
    const unsigned int *glyph;
    if (ch < 0x20 || ch > 0x7F) ch = '?';
    glyph = font5x7[ch - 0x20];
    for (row = 0; row < 7; row++) {
        unsigned int bits = glyph[row];
        for (col = 0; col < 5; col++) {
            if (bits & (0x10 >> col))
                hal_fill_rect(px + col * s, py + row * s, s, s, c);
        }
    }
}

/* str is const int* (word elements) to avoid byte loads on RISC2 */
static void render_str(int px, int py, const int *str, int s, u16 c)
{
    while (*str) {
        render_char(px, py, *str, s, c);
        px += 6 * s;
        str++;
    }
}

/* Render a non-negative integer using int digit buffer (no char[] on stack) */
static void render_int(int px, int py, int val, int s, u16 c)
{
    int digs[6];  /* up to 6 decimal digits */
    int n = 0, i;
    if (val <= 0) {
        render_char(px, py, '0', s, c);
        return;
    }
    while (val > 0 && n < 6) {
        digs[n] = '0' + (val % 10);
        n++;
        val /= 10;
    }
    /* Most-significant digit first */
    for (i = n - 1; i >= 0; i--) {
        render_char(px, py, digs[i], s, c);
        px += 6 * s;
    }
}

/* ── Board rendering ─────────────────────────────────────────────────────── */
static void render_grid(void)
{
    int r, c;
    /*
     * Draw the entire board area in grid colour, then fill each cell
     * interior in background colour.  The 1-px gaps between cells show
     * the grid colour as grid lines.
     *
     * This approach avoids 1-pixel-tall or 1-pixel-wide rectangles,
     * which degenerate to a single Y-scanline triangle and are skipped
     * by the GPU rasteriser (s0y == s2y check).
     */
    hal_fill_rect(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX, COL_GRID);
    for (r = 0; r < BOARD_SIZE; r++) {
        for (c = 0; c < BOARD_SIZE; c++) {
            hal_fill_rect(BOARD_X + c * CELL + 1,
                          BOARD_Y + r * CELL + 1,
                          CELL - 1, CELL - 1, COL_BG);
        }
    }
}

/* Draw X symbol: two diagonals built from 2×2 pixel steps */
static void render_X(int sx, int sy, u16 c)
{
    int i;
    for (i = 0; i < 9; i++) {
        hal_fill_rect(sx + i,     sy + i,     2, 2, c);   /* \ diagonal */
        hal_fill_rect(sx + 8 - i, sy + i,     2, 2, c);   /* / diagonal */
    }
}

/* Draw O symbol: square ring (4 border rects) */
static void render_O(int sx, int sy, u16 c)
{
    hal_fill_rect(sx + 1, sy,     8, 2, c);   /* top    */
    hal_fill_rect(sx + 1, sy + 8, 8, 2, c);   /* bottom */
    hal_fill_rect(sx,     sy + 1, 2, 8, c);   /* left   */
    hal_fill_rect(sx + 8, sy + 1, 2, 8, c);   /* right  */
}

static void render_pieces(const game_t *g)
{
    int r, c, sx, sy;
    for (r = 0; r < BOARD_SIZE; r++) {
        for (c = 0; c < BOARD_SIZE; c++) {
            int cell = g->board[r][c];
            if (cell == CELL_EMPTY) continue;
            /* Centre a 10×10 symbol within the 16×16 cell */
            sx = BOARD_X + c * CELL + 3;
            sy = BOARD_Y + r * CELL + 3;
            if (cell == CELL_HUMAN)
                render_X(sx, sy, COL_HUMAN);
            else
                render_O(sx, sy, COL_AI_PIECE);
        }
    }
}

static void render_cursor(const game_t *g)
{
    int cx, cy;
    if (g->result != RESULT_PLAYING) return;
    cx = BOARD_X + g->cursor_col * CELL;
    cy = BOARD_Y + g->cursor_row * CELL;
    hal_fill_rect(cx,          cy,          CELL, 2,    COL_CURSOR);
    hal_fill_rect(cx,          cy + CELL-2, CELL, 2,    COL_CURSOR);
    hal_fill_rect(cx,          cy,          2,    CELL, COL_CURSOR);
    hal_fill_rect(cx + CELL-2, cy,          2,    CELL, COL_CURSOR);
}

/* ── Info panel rendering ────────────────────────────────────────────────── */
static void render_info(const game_t *g)
{
    int y = INFO_Y;

    hal_fill_rect(INFO_X - 4, 0, INFO_W + 8, SCREEN_H, COL_INFO_BG);
    hal_fill_rect(INFO_X - 5, 0, 1, SCREEN_H, COL_GRID);

    /* Title */
    render_str(INFO_X, y, s_GOMOKU, 2, COL_TITLE);
    y += 20;
    render_str(INFO_X, y, s_5INAROW, 1, COL_TEXT);
    y += 14;
    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_GRID);
    y += 6;

    /* Status (if/else — no switch, avoids jump tables) */
    if (g->result == RESULT_PLAYING) {
        if (g->turn == CELL_HUMAN) {
            render_str(INFO_X, y, s_YOUR, 2, COL_HUMAN_TXT);
            y += 18;
            render_str(INFO_X, y, s_TURN, 2, COL_HUMAN_TXT);
        } else {
            render_str(INFO_X, y, s_AI,   2, COL_AI_TXT);
            y += 18;
            render_str(INFO_X, y, s_TURN, 2, COL_AI_TXT);
        }
        y += 18;
    } else if (g->result == RESULT_HUMAN_WINS) {
        render_str(INFO_X, y, s_YOU, 2, COL_WIN_TXT);
        y += 18;
        render_str(INFO_X, y, s_WIN, 2, COL_WIN_TXT);
        y += 18;
    } else if (g->result == RESULT_AI_WINS) {
        render_str(INFO_X, y, s_AI,  2, COL_WIN_TXT);
        y += 18;
        render_str(INFO_X, y, s_WINS,2, COL_WIN_TXT);
        y += 18;
    } else {
        render_str(INFO_X, y, s_DRAW, 2, COL_DRAW_TXT);
        y += 36;
    }

    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_GRID);
    y += 6;

    /* Counters */
    render_str(INFO_X, y, s_MOVES, 1, COL_TEXT);
    render_int(INFO_X + 42, y, g->stones, 1, COL_TEXT);
    y += 12;

    /* Symbol legend */
    render_str(INFO_X, y, s_YOUEQ, 1, COL_TEXT);
    render_X(INFO_X + 28, y - 1, COL_HUMAN);
    y += 12;
    render_str(INFO_X, y, s_AIEQ, 1, COL_TEXT);
    render_O(INFO_X + 28, y - 1, COL_AI_PIECE);
    y += 16;

    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_GRID);
    y += 6;

    /* Controls */
    render_str(INFO_X, y, s_WASD,  1, COL_TITLE);
    y += 10;
    render_str(INFO_X, y, s_MOVE,  1, COL_TEXT);
    y += 10;
    render_str(INFO_X, y, s_SPC,   1, COL_TITLE);
    y += 10;
    render_str(INFO_X, y, s_PLACE, 1, COL_TEXT);
    y += 10;

    if (g->result != RESULT_PLAYING) {
        y += 4;
        render_str(INFO_X, y, s_SPCNEW, 1, COL_WIN_TXT);
        y += 10;
        render_str(INFO_X, y, s_GAME,   1, COL_WIN_TXT);
    }
}

/* ── Public: render_frame ────────────────────────────────────────────────── */
void render_frame(const game_t *g)
{
    hal_clear(COL_BG);
    render_grid();
    render_pieces(g);
    render_cursor(g);
    render_info(g);
}
