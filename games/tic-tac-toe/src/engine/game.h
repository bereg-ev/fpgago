/*
 * game.h — Tic-Tac-Toe game logic
 *
 * Platform-independent. All rendering goes through hal.h.
 */

#ifndef GAME_H
#define GAME_H

#define CELL_EMPTY  0
#define CELL_X      1   /* human */
#define CELL_O      2   /* AI */

typedef enum {
    STATE_PLAYING,
    STATE_HUMAN_WINS,
    STATE_AI_WINS,
    STATE_DRAW
} game_state_t;

typedef struct {
    int          board[3][3];
    int          cursor_row;
    int          cursor_col;
    game_state_t state;
} game_t;

/* Initialise game. Human (X) moves first. */
void game_init(game_t *g);

/* Process one input character.
   'w','a','s','d' = move cursor; ' ' or '\r' = place mark.
   On game-over, ' ' or '\r' resets. */
void game_tick(game_t *g, int input);

#endif /* GAME_H */
