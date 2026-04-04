/*
 * render.c — Tic-Tac-Toe character LCD renderer
 *
 * RISC2 note: all string data uses const int[] (word-wide elements) to avoid
 * 8-bit (byte) memory loads, which the RISC2 LLVM backend cannot select.
 * No char types used anywhere.
 *
 * Board layout on 32x16 character LCD:
 *   Column offset = 11, row offset = 3
 *   Each cell is 3 chars wide, 1 char tall, separated by '|' and '-'/'+'.
 *   Cursor shown as [ ] around the cell content.
 */

#include "render.h"
#include "../hal/hal.h"

/* ── String constants as int[] to avoid byte loads on RISC2 ─────────────── */
static const int s_TITLE[]    = {'T','I','C','-','T','A','C','-','T','O','E', 0};
static const int s_TURN[]     = {'Y','O','U','R',' ','T','U','R','N',' ','(','X',')', 0};
static const int s_WIN[]      = {'Y','O','U',' ','W','I','N','!',' ','S','P','A','C','E','=','N','E','W', 0};
static const int s_LOSE[]     = {'Y','O','U',' ','L','O','S','E','!',' ','S','P','C','=','N','E','W', 0};
static const int s_DRAW[]     = {'D','R','A','W','!',' ','S','P','A','C','E','=','N','E','W', 0};
static const int s_CTRL[]     = {'W','A','S','D','=','M','O','V','E',' ','S','P','C','=','P','L','A','C','E', 0};

/* Print int-string at (col, row) */
static void put_str(int col, int row, const int *s)
{
    while (*s) {
        if (col < LCD_COLS)
            hal_putc(col, row, *s);
        col++;
        s++;
    }
}

void render_frame(const game_t *g)
{
    int r, c;
    int ox = 11;
    int oy = 3;

    hal_clear();

    /* title */
    put_str(10, 1, s_TITLE);

    /* draw board */
    for (r = 0; r < 3; r++) {
        int y = oy + r * 2;

        for (c = 0; c < 3; c++) {
            int x = ox + c * 4;
            int ch = ' ';
            int is_cursor = (r == g->cursor_row && c == g->cursor_col
                             && g->state == STATE_PLAYING);

            if (g->board[r][c] == CELL_X) ch = 'X';
            if (g->board[r][c] == CELL_O) ch = 'O';

            if (is_cursor) {
                hal_putc(x,     y, '[');
                hal_putc(x + 1, y, ch);
                hal_putc(x + 2, y, ']');
            } else {
                hal_putc(x,     y, ' ');
                hal_putc(x + 1, y, ch);
                hal_putc(x + 2, y, ' ');
            }

            /* vertical separator */
            if (c < 2)
                hal_putc(x + 3, y, '|');
        }

        /* horizontal separator */
        if (r < 2) {
            int y2 = y + 1;
            int hx;
            for (hx = ox; hx < ox + 10; hx++)
                hal_putc(hx, y2, '-');
            hal_putc(ox + 3, y2, '+');
            hal_putc(ox + 7, y2, '+');
        }
    }

    /* status line */
    if (g->state == STATE_PLAYING)
        put_str(9, oy + 6, s_TURN);
    else if (g->state == STATE_HUMAN_WINS)
        put_str(7, oy + 6, s_WIN);
    else if (g->state == STATE_AI_WINS)
        put_str(7, oy + 6, s_LOSE);
    else
        put_str(8, oy + 6, s_DRAW);

    /* controls hint */
    put_str(6, oy + 8, s_CTRL);
}
