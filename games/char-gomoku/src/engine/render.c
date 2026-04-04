/*
 * render.c -- character-based frame rendering for Gomoku
 *
 * Each board cell is two custom characters (left + right half of a 16x16
 * square).  Grid borders (left edge + bottom edge) are baked into the
 * character bitmaps so the board looks like a proper game field.
 *
 * Screen layout (60 cols x 17 rows):
 *   Row 0:      column headers A-O (custom glyphs with bottom border = top edge)
 *   Rows 1-15:  board rows with row numbers and right-edge column
 *   Row 16:     game-over message
 */

#include "render.h"
#include "../hal/hal.h"

/* ---- layout constants --------------------------------------------------- */
/* Board needs: 3 (label) + 30 (cells) + 1 (edge) = 34 chars.
 * Centre in TEXT_COLS; for narrow displays (e.g. 34) OX = 0. */
#define BOARD_W  34                       /* minimum board width in chars     */
#define OX       ((TEXT_COLS - BOARD_W) / 2)
#define BOARD_X  (OX + 3)                 /* first board cell text column     */
#define BOARD_Y  1                        /* first board row                  */
#define STATUS_Y (BOARD_Y + BOARD_SIZE)   /* row 16                          */

/* ---- helper ------------------------------------------------------------- */
static void put_str(int col, int row, const int *s)
{
    while (*s) {
        hal_putchar(col, row, *s);
        col++;
        s++;
    }
}

/* ---- public ------------------------------------------------------------- */
void render_frame(const game_t *g)
{
    int r, c;

    hal_clear();

    /* Column headers with grid borders (row 0 = top edge of board) */
    for (c = 0; c < BOARD_SIZE; c++) {
        hal_putchar(BOARD_X + c * 2,     0, CH_HDR_L(c));
        hal_putchar(BOARD_X + c * 2 + 1, 0, CH_HDR_R(c));
    }
    hal_putchar(BOARD_X + BOARD_SIZE * 2, 0, CH_EMPTY_L); /* right edge */

    /* Board rows */
    for (r = 0; r < BOARD_SIZE; r++) {
        int num = r + 1;
        int ty  = BOARD_Y + r;
        int cl, cr;

        /* Row number (right-justified in 2 chars).
         * Avoid % operator — RISC2 runtime lacks __umodsi3. */
        {
            int tens = num / 10;
            int ones = num - tens * 10;
            if (tens)
                hal_putchar(OX, ty, '0' + tens);
            hal_putchar(OX + 1, ty, '0' + ones);
        }

        /* Board cells */
        for (c = 0; c < BOARD_SIZE; c++) {
            if (g->result == RESULT_PLAYING &&
                r == g->cursor_row && c == g->cursor_col) {
                cl = CH_CUR_L;  cr = CH_CUR_R;
            } else if (g->board[r][c] == CELL_HUMAN) {
                cl = CH_X_L;    cr = CH_X_R;
            } else if (g->board[r][c] == CELL_AI) {
                cl = CH_O_L;    cr = CH_O_R;
            } else {
                cl = CH_EMPTY_L; cr = CH_EMPTY_R;
            }
            hal_putchar(BOARD_X + c * 2,     ty, cl);
            hal_putchar(BOARD_X + c * 2 + 1, ty, cr);
        }

        /* Right edge column (vertical border) */
        hal_putchar(BOARD_X + BOARD_SIZE * 2, ty, CH_EMPTY_L);
    }

    /* Game-over message on status row */
    {
        static const int s_youwin[] = {
            'Y','O','U',' ','W','I','N','!',
            ' ',' ','S','P','A','C','E','=','N','E','W', 0
        };
        static const int s_aiwins[] = {
            'A','I',' ','W','I','N','S','!',
            ' ',' ','S','P','A','C','E','=','N','E','W', 0
        };
        static const int s_draw[] = {
            'D','R','A','W','!',
            ' ',' ','S','P','A','C','E','=','N','E','W', 0
        };

        if (g->result == RESULT_HUMAN_WINS)
            put_str(BOARD_X, STATUS_Y, s_youwin);
        else if (g->result == RESULT_AI_WINS)
            put_str(BOARD_X, STATUS_Y, s_aiwins);
        else if (g->result == RESULT_DRAW)
            put_str(BOARD_X, STATUS_Y, s_draw);
    }
}
