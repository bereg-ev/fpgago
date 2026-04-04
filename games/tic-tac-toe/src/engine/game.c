/*
 * game.c — Tic-Tac-Toe game logic + simple AI
 */

#include "game.h"

void game_init(game_t *g)
{
    volatile int *p = (volatile int *)g->board;
    int i;
    for (i = 0; i < 9; i++)
        p[i] = CELL_EMPTY;
    g->cursor_row = 1;
    g->cursor_col = 1;
    g->state = STATE_PLAYING;
}

/* ── Win / draw detection ─────────────────────────────────────────────── */

static int check_line(const game_t *g, int r0, int c0, int r1, int c1, int r2, int c2)
{
    int v = g->board[r0][c0];
    if (v != CELL_EMPTY && v == g->board[r1][c1] && v == g->board[r2][c2])
        return v;
    return 0;
}

static int check_winner(const game_t *g)
{
    int i, v;
    /* rows */
    for (i = 0; i < 3; i++) {
        v = check_line(g, i,0, i,1, i,2);
        if (v) return v;
    }
    /* cols */
    for (i = 0; i < 3; i++) {
        v = check_line(g, 0,i, 1,i, 2,i);
        if (v) return v;
    }
    /* diagonals */
    v = check_line(g, 0,0, 1,1, 2,2);
    if (v) return v;
    v = check_line(g, 0,2, 1,1, 2,0);
    if (v) return v;
    return 0;
}

static int board_full(const game_t *g)
{
    int r, c;
    for (r = 0; r < 3; r++)
        for (c = 0; c < 3; c++)
            if (g->board[r][c] == CELL_EMPTY) return 0;
    return 1;
}

static void update_state(game_t *g)
{
    int w = check_winner(g);
    if (w == CELL_X)      g->state = STATE_HUMAN_WINS;
    else if (w == CELL_O) g->state = STATE_AI_WINS;
    else if (board_full(g)) g->state = STATE_DRAW;
}

/* ── AI (minimax) ─────────────────────────────────────────────────────── */

static int minimax(game_t *g, int is_maximizing)
{
    int w = check_winner(g);
    if (w == CELL_O) return  10;
    if (w == CELL_X) return -10;
    if (board_full(g)) return 0;

    int best, r, c;
    if (is_maximizing) {
        best = -100;
        for (r = 0; r < 3; r++)
            for (c = 0; c < 3; c++)
                if (g->board[r][c] == CELL_EMPTY) {
                    g->board[r][c] = CELL_O;
                    int val = minimax(g, 0);
                    g->board[r][c] = CELL_EMPTY;
                    if (val > best) best = val;
                }
    } else {
        best = 100;
        for (r = 0; r < 3; r++)
            for (c = 0; c < 3; c++)
                if (g->board[r][c] == CELL_EMPTY) {
                    g->board[r][c] = CELL_X;
                    int val = minimax(g, 1);
                    g->board[r][c] = CELL_EMPTY;
                    if (val < best) best = val;
                }
    }
    return best;
}

static void ai_move(game_t *g)
{
    int best_score = -100;
    int best_r = -1, best_c = -1;
    int r, c;

    for (r = 0; r < 3; r++)
        for (c = 0; c < 3; c++)
            if (g->board[r][c] == CELL_EMPTY) {
                g->board[r][c] = CELL_O;
                int score = minimax(g, 0);
                g->board[r][c] = CELL_EMPTY;
                if (score > best_score) {
                    best_score = score;
                    best_r = r;
                    best_c = c;
                }
            }

    if (best_r >= 0) {
        g->board[best_r][best_c] = CELL_O;
        update_state(g);
    }
}

/* ── Public interface ─────────────────────────────────────────────────── */

void game_tick(game_t *g, int input)
{
    if (g->state != STATE_PLAYING) {
        if (input == ' ' || input == '\r')
            game_init(g);
        return;
    }

    switch (input) {
        case 'w': if (g->cursor_row > 0) g->cursor_row--; break;
        case 's': if (g->cursor_row < 2) g->cursor_row++; break;
        case 'a': if (g->cursor_col > 0) g->cursor_col--; break;
        case 'd': if (g->cursor_col < 2) g->cursor_col++; break;
        case ' ':
        case '\r':
            if (g->board[g->cursor_row][g->cursor_col] == CELL_EMPTY) {
                g->board[g->cursor_row][g->cursor_col] = CELL_X;
                update_state(g);
                if (g->state == STATE_PLAYING)
                    ai_move(g);
            }
            break;
    }
}
