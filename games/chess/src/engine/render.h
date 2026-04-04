/*
 * render.h — Chess board renderer
 *
 * Draws board, pieces, cursor, and info panel via hal_fill_rect / hal_clear.
 * Does NOT call hal_swap.
 */

#ifndef RENDER_H
#define RENDER_H

#include "game.h"

void render_frame(const game_t *g);

#endif /* RENDER_H */
