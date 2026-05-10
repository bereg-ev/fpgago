/*
 * hal_sdl2.h — SDL2 platform lifecycle for the HAL.
 *
 * The HAL primitives (hal_clear / hal_fill_rect / hal_swap) declared in
 * hal.h are implemented in hal_sdl2.c against an internal RGB565
 * software framebuffer that is uploaded to a streaming SDL_Texture.
 *
 * main.c calls hal_sdl2_init() once at startup and hal_sdl2_shutdown()
 * before exit.
 */

#ifndef HAL_SDL2_H
#define HAL_SDL2_H

/* Create window + renderer + RGB565 streaming texture.
   Returns 0 on success, non-zero on failure (SDL_GetError() has details). */
int  hal_sdl2_init(const char *title);

/* Tear down texture, renderer, window, and SDL itself. Safe to call after
   a partial-init failure. */
void hal_sdl2_shutdown(void);

#endif /* HAL_SDL2_H */
