/*
 * hal_sdl2.h — SDL2 platform lifecycle for the character HAL.
 *
 * The character HAL primitives (hal_clear / hal_putchar / hal_swap) declared
 * in hal.h are implemented in hal_sdl2.c.  The implementation owns a text
 * back-buffer plus a software RGB565 framebuffer; on hal_swap the text grid
 * is rasterized through a custom 8x16 glyph table to the framebuffer and
 * uploaded to a streaming SDL_Texture.
 */

#ifndef HAL_SDL2_H
#define HAL_SDL2_H

/* Create window + renderer + texture and prepare the custom glyph bitmaps.
   Returns 0 on success, non-zero on failure. */
int  hal_sdl2_init(const char *title);

/* Tear down texture, renderer, window, and SDL itself. */
void hal_sdl2_shutdown(void);

#endif /* HAL_SDL2_H */
