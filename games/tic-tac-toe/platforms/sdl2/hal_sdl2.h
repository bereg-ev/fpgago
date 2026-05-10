/*
 * hal_sdl2.h — SDL2 platform lifecycle for the Tic-Tac-Toe character HAL.
 *
 * The HAL primitives (hal_clear / hal_putc / hal_swap) declared in hal.h are
 * implemented in hal_sdl2.c.  The implementation simulates a 32x16 LCD with
 * 8x16 pixel cells (256x256 pixels, 2x window scale).
 */

#ifndef HAL_SDL2_H
#define HAL_SDL2_H

int  hal_sdl2_init(const char *title);
void hal_sdl2_shutdown(void);

#endif /* HAL_SDL2_H */
