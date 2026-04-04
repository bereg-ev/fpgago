/*
 * render.h -- rendering interface for Gomoku (character-based)
 *
 * render_frame() writes one complete frame into the text buffer
 * via hal_putchar().  It does NOT call hal_swap().
 */

#ifndef RENDER_H
#define RENDER_H

#include "game.h"

void render_frame(const game_t *g);

#endif /* RENDER_H */
