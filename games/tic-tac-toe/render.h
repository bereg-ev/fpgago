/*
 * render.h — rendering for Tic-Tac-Toe on character LCD
 *
 * Draws the board using hal_putc / hal_clear.
 * Does NOT call hal_swap.
 */

#ifndef RENDER_H
#define RENDER_H

#include "game.h"

void render_frame(const game_t *g);

#endif /* RENDER_H */
