/*
 * game.c — Five-in-a-Row game logic and AI
 *
 * No platform dependencies.  All arithmetic uses plain int.
 */

#include "game.h"

/* ─── Directions: 4 axis-aligned + diagonal pairs ────────────────────────── */
static const int DIR_DR[4] = { 0,  1,  1,  1 };
static const int DIR_DC[4] = { 1,  0,  1, -1 };

/* ── Public: initialise ───────────────────────────────────────────────────── */
void game_init(game_t *g)
{
    int r, c;
    for (r = 0; r < BOARD_SIZE; r++)
        for (c = 0; c < BOARD_SIZE; c++)
            g->board[r][c] = CELL_EMPTY;
    g->cursor_row = BOARD_SIZE / 2;
    g->cursor_col = BOARD_SIZE / 2;
    g->turn       = CELL_HUMAN;
    g->result     = RESULT_PLAYING;
    g->stones     = 0;
}

/* ── Public: cursor movement ─────────────────────────────────────────────── */
void game_move_cursor(game_t *g, int dr, int dc)
{
    int r = g->cursor_row + dr;
    int c = g->cursor_col + dc;
    if (r < 0) r = 0;
    if (r >= BOARD_SIZE) r = BOARD_SIZE - 1;
    if (c < 0) c = 0;
    if (c >= BOARD_SIZE) c = BOARD_SIZE - 1;
    g->cursor_row = r;
    g->cursor_col = c;
}

/* ── Public: win check ────────────────────────────────────────────────────── */
int game_check_win(const game_t *g, int player)
{
    int r, c, d, nr, nc, cnt;
    for (r = 0; r < BOARD_SIZE; r++) {
        for (c = 0; c < BOARD_SIZE; c++) {
            if (g->board[r][c] != player) continue;
            for (d = 0; d < 4; d++) {
                cnt = 1;
                nr = r + DIR_DR[d];
                nc = c + DIR_DC[d];
                while (cnt < WIN_LEN &&
                       (unsigned)nr < BOARD_SIZE &&
                       (unsigned)nc < BOARD_SIZE &&
                       g->board[nr][nc] == player) {
                    cnt++;
                    nr += DIR_DR[d];
                    nc += DIR_DC[d];
                }
                if (cnt >= WIN_LEN) return 1;
            }
        }
    }
    return 0;
}

/* ── Public: place stone ─────────────────────────────────────────────────── */
int game_place(game_t *g, int row, int col, int player)
{
    if (g->result != RESULT_PLAYING) return 0;
    if (g->board[row][col] != CELL_EMPTY) return 0;

    g->board[row][col] = player;
    g->stones++;

    if (game_check_win(g, player)) {
        g->result = (player == CELL_HUMAN) ? RESULT_HUMAN_WINS : RESULT_AI_WINS;
    } else if (g->stones >= BOARD_SIZE * BOARD_SIZE) {
        g->result = RESULT_DRAW;
    }
    return 1;
}

/* ── AI heuristic ─────────────────────────────────────────────────────────── */

/*
 * Count consecutive same-player stones stepping from (r,c) in direction
 * (dr,dc), NOT including (r,c) itself.  Also checks whether the far end
 * is blocked (board edge or opponent stone) via *blocked_out.
 */
static int count_run(const game_t *g,
                     int r, int c, int dr, int dc,
                     int player, int *blocked_out)
{
    int count = 0;
    r += dr; c += dc;
    /* Use unsigned casts for bounds checks — the RISC2 LLVM backend
       mis-compiles signed range tests (r >= 0 && r < N).  Casting to
       unsigned makes negative values wrap to large positive, which a
       single unsigned < N check catches correctly. */
    while (count < WIN_LEN - 1 &&
           (unsigned)r < BOARD_SIZE &&
           (unsigned)c < BOARD_SIZE) {
        if (g->board[r][c] == player) {
            count++;
        } else {
            if (g->board[r][c] != CELL_EMPTY)
                *blocked_out = 1;
            return count;
        }
        r += dr; c += dc;
    }
    /* Reached edge or run limit */
    if ((unsigned)r >= BOARD_SIZE || (unsigned)c >= BOARD_SIZE)
        *blocked_out = 1;
    return count;
}

/* Score for placing player's stone at (r,c) in one direction d */
static int score_direction(const game_t *g,
                           int r, int c, int d, int player)
{
    int dr = DIR_DR[d], dc = DIR_DC[d];
    int b_fwd = 0, b_bwd = 0;
    int fwd = count_run(g, r, c,  dr,  dc, player, &b_fwd);
    int bwd = count_run(g, r, c, -dr, -dc, player, &b_bwd);
    int total = fwd + bwd; /* consecutive stones through candidate */
    int blocked = b_fwd + b_bwd;

    if (total >= WIN_LEN - 1) return 100000; /* winning move */
    if (blocked >= 2)          return 0;     /* fully blocked */

    /* Threat table: [consecutive][open_ends] */
    static const int threat[4][3] = {
        /*          both  one */
        /* 0 */  {  0,  0,  0 },
        /* 1 */  { 10,  4,  1 },
        /* 2 */  {100, 40, 10 },
        /* 3 */  {1000,500,100},
    };
    int open = 2 - blocked;
    if (total > 3) total = 3;
    return threat[total][2 - open];
}

/* ── Public: AI move ─────────────────────────────────────────────────────── */
void ai_move(const game_t *g, int *out_row, int *out_col)
{
    int r, c, d;
    int best = -1;
    int br = BOARD_SIZE / 2;
    int bc = BOARD_SIZE / 2;

    /* If board is empty play centre */
    if (g->stones == 0) {
        *out_row = br;
        *out_col = bc;
        return;
    }

    for (r = 0; r < BOARD_SIZE; r++) {
        for (c = 0; c < BOARD_SIZE; c++) {
            if (g->board[r][c] != CELL_EMPTY) continue;

            int s = 0;
            for (d = 0; d < 4; d++) {
                /* Offensive: AI places here */
                s += score_direction(g, r, c, d, CELL_AI)    * 2;
                /* Defensive: block human */
                s += score_direction(g, r, c, d, CELL_HUMAN)  * 3;
            }

            if (s > best) {
                best = s;
                br = r;
                bc = c;
            }
        }
    }

    *out_row = br;
    *out_col = bc;
}

/* ── Public: game_tick ───────────────────────────────────────────────────── */
void game_tick(game_t *g, int input)
{
    /* On game-over: space/enter restarts */
    if (g->result != RESULT_PLAYING) {
        if (input == ' ' || input == '\r' || input == '\n')
            game_init(g);
        return;
    }

    /* Only accept human input on human's turn */
    if (g->turn != CELL_HUMAN) return;

    /* Use if/else chain — RISC2 backend does not support jump tables */
    if (input == 'w' || input == 'W') {
        game_move_cursor(g, -1,  0);
    } else if (input == 's' || input == 'S') {
        game_move_cursor(g,  1,  0);
    } else if (input == 'a' || input == 'A') {
        game_move_cursor(g,  0, -1);
    } else if (input == 'd' || input == 'D') {
        game_move_cursor(g,  0,  1);
    } else if (input == ' ' || input == '\r' || input == '\n') {
        if (game_place(g, g->cursor_row, g->cursor_col, CELL_HUMAN)) {
            if (g->result == RESULT_PLAYING) {
                int ar, ac;
                ai_move(g, &ar, &ac);
                game_place(g, ar, ac, CELL_AI);
            }
        }
    }
}
