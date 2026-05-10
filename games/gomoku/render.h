/*
 * render.h — rendering interface for Five-in-a-Row
 *
 * render_frame() draws a complete frame into the back buffer using only
 * hal_fill_rect() calls.  It does NOT call hal_swap(); the platform
 * is responsible for that after render_frame() returns.
 *
 * No platform headers needed here.
 */

#ifndef RENDER_H
#define RENDER_H

#include "game.h"

/* Draw a complete frame reflecting the current game state.
   Calls hal_clear + hal_fill_rect internally.
   Does NOT call hal_swap. */
void render_frame(const game_t *g);

#endif /* RENDER_H */
