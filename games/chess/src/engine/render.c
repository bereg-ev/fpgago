/*
 * render.c — Chess board renderer (480×272 pixel display)
 *
 * Layout:
 *   Board: 8×8 squares, 32px each = 256×256, at (8, 8)
 *   Info panel: right side from x=272
 *
 * RISC2 compatible: int-only, no switch, no string literals.
 */

#include "render.h"
#include "font.h"
#include "../hal/hal.h"

/* ── Layout ──────────────────────────────────────────────────────────── */
#define BRD_X   8
#define BRD_Y   8
#define SQ      32
#define INFO_X  272
#define INFO_W  (SCREEN_W - INFO_X - 4)

/* ── Helpers ──────────────────────────────────────────────────────────── */
static int sq_row(int sq) { return sq >> 3; }
static int sq_col(int sq) { return sq & 7; }

/* ── Colors (RGB565) ─────────────────────────────────────────────────── */
#define COL_LIGHT    RGB565(28, 56, 22)   /* light squares */
#define COL_DARK     RGB565(14, 28, 10)   /* dark squares */
#define COL_BG       RGB565( 2,  4,  2)   /* background */
#define COL_CURSOR   RGB565(31, 63,  0)   /* cursor highlight */
#define COL_SELECT   RGB565( 0, 50,  0)   /* selected piece */
#define COL_LEGAL    RGB565(12, 40,  6)   /* legal move dot */
#define COL_LASTMV   RGB565(14, 36, 18)   /* last move tint */
#define COL_CHECK    RGB565(31, 10,  4)   /* king in check */
#define COL_W_FILL   RGB565(31, 63, 31)   /* white piece */
#define COL_W_OUT    RGB565( 3,  6,  3)   /* white piece outline */
#define COL_B_FILL   RGB565( 3,  6,  3)   /* black piece */
#define COL_B_OUT    RGB565(26, 52, 26)   /* black piece outline */
#define COL_INFO_BG  RGB565( 2,  4,  2)
#define COL_TEXT     RGB565(18, 36, 18)
#define COL_TITLE    RGB565(24, 50, 24)
#define COL_WARN     RGB565(31, 50,  0)
#define COL_WIN      RGB565(31, 63,  0)

/* ── String constants (int[] for RISC2) ──────────────────────────────── */
static const int s_CHESS[]     = {'C','H','E','S','S', 0};
static const int s_YOUR[]     = {'Y','O','U','R',' ','T','U','R','N', 0};
static const int s_THINKING[] = {'T','H','I','N','K','I','N','G','.','.','.', 0};
static const int s_CHECK[]    = {'C','H','E','C','K','!', 0};
static const int s_CHECKMATE[]= {'C','H','E','C','K','M','A','T','E','!', 0};
static const int s_STALEMATE[]= {'S','T','A','L','E','M','A','T','E', 0};
static const int s_WHITE_W[]  = {'W','H','I','T','E',' ','W','I','N','S', 0};
static const int s_BLACK_W[]  = {'B','L','A','C','K',' ','W','I','N','S', 0};
static const int s_DRAW[]     = {'D','R','A','W', 0};
static const int s_WASD[]     = {'W','A','S','D',' ','M','O','V','E', 0};
static const int s_SPC[]      = {'S','P','C',' ',' ','S','E','L','E','C','T', 0};
static const int s_NEW[]      = {'S','P','C','=','N','E','W', 0};
static const int s_NODES[]    = {'N','O','D','E','S',':', 0};
static const int s_DEPTH[]    = {'D','E','P','T','H',':', 0};

/* ── Font rendering ──────────────────────────────────────────────────── */
static void render_char(int px, int py, int ch, int s, u16 color)
{
    const unsigned int *glyph;
    int row, col;
    if (ch < 0x20 || ch > 0x7F) ch = '?';
    glyph = font5x7[ch - 0x20];
    for (row = 0; row < 7; row++)
        for (col = 0; col < 5; col++)
            if (glyph[row] & (0x10 >> col))
                hal_fill_rect(px + col * s, py + row * s, s, s, color);
}

static void render_str(int px, int py, const int *str, int s, u16 color)
{
    while (*str) {
        render_char(px, py, *str, s, color);
        px += 6 * s;
        str++;
    }
}

static void render_int(int px, int py, int val, int s, u16 color)
{
    int digs[10], n = 0, i;
    if (val <= 0) { render_char(px, py, '0', s, color); return; }
    while (val > 0 && n < 10) {
        int d = val / 10;
        digs[n++] = '0' + (val - d * 10);
        val = d;
    }
    for (i = n - 1; i >= 0; i--) {
        render_char(px, py, digs[i], s, color);
        px += 6 * s;
    }
}

/* ── Piece bitmaps (16 wide × 20 tall, bit 15 = leftmost column) ───── */
#define PW 16
#define PH 20

static const unsigned int piece_bmp[7][PH] = {
{ /* EMPTY */ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 },
{ /* PAWN — ball, neck, skirt, base */
  0x0000, 0x03C0, 0x07E0, 0x0FF0, 0x0FF0, 0x07E0, 0x03C0, 0x0180,
  0x0180, 0x03C0, 0x03C0, 0x07E0, 0x07E0, 0x0FF0, 0x1FF8, 0x3FFC,
  0x7FFE, 0x7FFE, 0x0000, 0x0000 },
{ /* KNIGHT — horse head facing left, eye notch */
  0x0000, 0x0380, 0x07C0, 0x0FE0, 0x1FE0, 0x3FE0, 0x7FF0, 0x7BF0,
  0x39F0, 0x01F0, 0x03F0, 0x07F0, 0x0FF0, 0x1FF8, 0x3FFC, 0x3FFC,
  0x7FFE, 0x7FFE, 0x0000, 0x0000 },
{ /* BISHOP — mitre with sash, stem, base */
  0x0000, 0x0180, 0x03C0, 0x07E0, 0x0660, 0x0FF0, 0x07E0, 0x07E0,
  0x03C0, 0x03C0, 0x03C0, 0x07E0, 0x07E0, 0x0FF0, 0x1FF8, 0x3FFC,
  0x7FFE, 0x7FFE, 0x0000, 0x0000 },
{ /* ROOK — battlements, tower body, base */
  0x0000, 0x33CC, 0x33CC, 0x3FFC, 0x3FFC, 0x1FF8, 0x0FF0, 0x0FF0,
  0x0FF0, 0x0FF0, 0x0FF0, 0x0FF0, 0x0FF0, 0x1FF8, 0x3FFC, 0x3FFC,
  0x7FFE, 0x7FFE, 0x0000, 0x0000 },
{ /* QUEEN — crown prongs, body, base */
  0x0000, 0x0180, 0x4182, 0x6186, 0x73CE, 0x7BDE, 0x7FFE, 0x3FFC,
  0x1FF8, 0x0FF0, 0x0FF0, 0x0FF0, 0x0FF0, 0x1FF8, 0x3FFC, 0x3FFC,
  0x7FFE, 0x7FFE, 0x0000, 0x0000 },
{ /* KING — cross, crown, body, base */
  0x0000, 0x0180, 0x0180, 0x07E0, 0x07E0, 0x0180, 0x03C0, 0x0FF0,
  0x3FFC, 0x3FFC, 0x1FF8, 0x0FF0, 0x0FF0, 0x0FF0, 0x1FF8, 0x3FFC,
  0x3FFC, 0x7FFE, 0x7FFE, 0x0000 }
};

/* Draw one row of a bitmap as horizontal spans (efficient for GPU) */
static void render_spans(int x, int y, unsigned int bits, int w, u16 c)
{
    int col = 0, start;
    while (col < w) {
        while (col < w && !(bits & (1 << (w - 1 - col)))) col++;
        if (col >= w) break;
        start = col;
        while (col < w && (bits & (1 << (w - 1 - col)))) col++;
        hal_fill_rect(x + start, y, col - start, 1, c);
    }
}

static void draw_piece(int px, int py, int piece)
{
    int type = PIECE_TYPE(piece);
    int is_white = !IS_BLACK(piece);
    const unsigned int *bmp = piece_bmp[type];
    int ox = px + (SQ - PW) / 2;
    int oy = py + (SQ - PH) / 2;
    u16 fill = is_white ? COL_W_FILL : COL_B_FILL;
    u16 out  = is_white ? COL_W_OUT  : COL_B_OUT;
    int row;

    /* Pass 1: outline — dilated bitmap (expand 1px in all directions) */
    for (row = -1; row <= PH; row++) {
        unsigned int above = (row >= 1)       ? bmp[row - 1] : 0;
        unsigned int cur   = (row >= 0 && row < PH) ? bmp[row] : 0;
        unsigned int below = (row < PH - 1 && row >= -1) ? bmp[row + 1] : 0;
        unsigned int d = above | cur | below | (cur << 1) | (cur >> 1);
        if (d) render_spans(ox - 1, oy + row, d, PW + 2, out);
    }

    /* Pass 2: fill — original bitmap */
    for (row = 0; row < PH; row++)
        if (bmp[row]) render_spans(ox, oy + row, bmp[row], PW, fill);
}

/* ── Board rendering ─────────────────────────────────────────────────── */
static void render_board(const game_t *g)
{
    int r, c, sq, px, py;

    for (r = 0; r < 8; r++) {
        for (c = 0; c < 8; c++) {
            sq = (r << 3) | c;
            px = BRD_X + c * SQ;
            py = BRD_Y + r * SQ;

            /* square color */
            u16 col = ((r + c) & 1) ? COL_DARK : COL_LIGHT;

            /* last move highlight */
            if (sq == g->last_from || sq == g->last_to)
                col = COL_LASTMV;

            /* selected piece highlight */
            if (sq == g->selected)
                col = COL_SELECT;

            /* king in check */
            if (g->in_check && sq == g->king_sq[g->side])
                col = COL_CHECK;

            hal_fill_rect(px, py, SQ, SQ, col);

            /* piece */
            if (g->board[sq])
                draw_piece(px, py, g->board[sq]);

            /* legal move dot */
            if (g->selected >= 0) {
                int i;
                for (i = 0; i < g->num_legal; i++) {
                    if (MV_TO(g->legal_dests[i]) == sq) {
                        if (g->board[sq])
                            /* capture: corner markers */
                            hal_fill_rect(px, py, 4, 4, COL_LEGAL);
                        else
                            /* empty: center dot */
                            hal_fill_rect(px + 13, py + 13, 6, 6, COL_LEGAL);
                        break;
                    }
                }
            }
        }
    }

    /* cursor border */
    {
        int cr = sq_row(g->cursor), cc = sq_col(g->cursor);
        px = BRD_X + cc * SQ;
        py = BRD_Y + cr * SQ;
        hal_fill_rect(px,          py,          SQ, 2,  COL_CURSOR);
        hal_fill_rect(px,          py + SQ - 2, SQ, 2,  COL_CURSOR);
        hal_fill_rect(px,          py,          2,  SQ, COL_CURSOR);
        hal_fill_rect(px + SQ - 2, py,          2,  SQ, COL_CURSOR);
    }

    /* rank/file labels */
    {
        int i;
        for (i = 0; i < 8; i++) {
            render_char(BRD_X + i * SQ + 12, BRD_Y + 8 * SQ + 2, 'a' + i, 1, COL_TEXT);
            render_char(BRD_X - 7, BRD_Y + i * SQ + 12, '8' - i, 1, COL_TEXT);
        }
    }
}

/* ── Info panel ──────────────────────────────────────────────────────── */
static void render_info(const game_t *g)
{
    int y = 8;

    hal_fill_rect(INFO_X - 4, 0, INFO_W + 8, SCREEN_H, COL_INFO_BG);
    hal_fill_rect(INFO_X - 5, 0, 1, SCREEN_H, COL_TEXT);

    /* title */
    render_str(INFO_X, y, s_CHESS, 3, COL_TITLE);
    y += 28;
    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_TEXT);
    y += 8;

    /* status */
    if (g->state == GS_PLAYING) {
        if (g->side == WHITE) {
            render_str(INFO_X, y, s_YOUR, 1, COL_TITLE);
            y += 12;
            if (g->in_check) {
                render_str(INFO_X, y, s_CHECK, 1, COL_WARN);
                y += 12;
            }
        } else {
            render_str(INFO_X, y, s_THINKING, 1, COL_TEXT);
            y += 12;
        }
    } else if (g->state == GS_WHITE_WINS) {
        render_str(INFO_X, y, s_CHECKMATE, 2, COL_WIN);
        y += 20;
        render_str(INFO_X, y, s_WHITE_W, 1, COL_WIN);
        y += 12;
    } else if (g->state == GS_BLACK_WINS) {
        render_str(INFO_X, y, s_CHECKMATE, 2, COL_WIN);
        y += 20;
        render_str(INFO_X, y, s_BLACK_W, 1, COL_WIN);
        y += 12;
    } else {
        render_str(INFO_X, y, s_STALEMATE, 2, COL_WIN);
        y += 20;
        render_str(INFO_X, y, s_DRAW, 1, COL_WIN);
        y += 12;
    }

    y += 4;
    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_TEXT);
    y += 8;

    /* search stats */
    render_str(INFO_X, y, s_DEPTH, 1, COL_TEXT);
    render_int(INFO_X + 42, y, g->ai.max_depth, 1, COL_TITLE);
    y += 12;
    render_str(INFO_X, y, s_NODES, 1, COL_TEXT);
    render_int(INFO_X + 42, y, g->nodes, 1, COL_TITLE);
    y += 16;

    hal_fill_rect(INFO_X, y, INFO_W, 1, COL_TEXT);
    y += 8;

    /* controls */
    render_str(INFO_X, y, s_WASD, 1, COL_TITLE);
    y += 12;
    render_str(INFO_X, y, s_SPC, 1, COL_TITLE);
    y += 12;

    if (g->state != GS_PLAYING) {
        y += 4;
        render_str(INFO_X, y, s_NEW, 1, COL_WIN);
    }
}

/* ── Public ──────────────────────────────────────────────────────────── */
void render_frame(const game_t *g)
{
    hal_clear(COL_BG);
    render_board(g);
    render_info(g);
}
