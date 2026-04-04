/*
 * game.h — Five-in-a-Row (Gomoku) game logic
 *
 * Platform-independent: no SDL2, no GPU3D, no UART headers included here.
 * All I/O goes through the calling platform via game_tick().
 */

#ifndef GAME_H
#define GAME_H

/* Board dimensions */
#define BOARD_SIZE  15
#define WIN_LEN      5

/* Cell values */
#define CELL_EMPTY   0
#define CELL_HUMAN   1
#define CELL_AI      2

typedef enum {
    RESULT_PLAYING = 0,
    RESULT_HUMAN_WINS,
    RESULT_AI_WINS,
    RESULT_DRAW
} game_result_t;

typedef struct {
    int           board[BOARD_SIZE][BOARD_SIZE]; /* 900 bytes — int avoids byte loads (RISC2 backend) */
    int           cursor_row;
    int           cursor_col;
    int           turn;    /* CELL_HUMAN or CELL_AI */
    game_result_t result;
    int           stones;  /* total placed, for draw detection */
} game_t;

/* Initialise (or re-initialise) the game.  Cursor placed at board centre. */
void game_init(game_t *g);

/* Move cursor by (dr, dc), clamped to board edges. */
void game_move_cursor(game_t *g, int dr, int dc);

/* Place a stone for player at (row, col).
   Returns 1 on success, 0 if occupied or game is already over.
   Updates g->result and g->stones. */
int game_place(game_t *g, int row, int col, int player);

/* Check if player has WIN_LEN stones in a row anywhere.
   Returns 1 if so, 0 otherwise. */
int game_check_win(const game_t *g, int player);

/* Select the best move for the AI using a greedy heuristic.
   Writes the chosen cell into *out_row, *out_col.
   Must only be called when g->result == RESULT_PLAYING. */
void ai_move(const game_t *g, int *out_row, int *out_col);

/* Process one input character and advance game state.
   input: 'w','a','s','d' = move cursor; ' ' or '\r' = place stone.
   On game-over, ' ' or '\r' resets the game.
   Render + swap are NOT called here; the platform must do that after. */
void game_tick(game_t *g, int input);

#endif /* GAME_H */
