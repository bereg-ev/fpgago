/*
 * hal_sdl2.c — SDL2 implementation of hal.h.
 *
 * Owns the entire SDL render-side state (window, renderer, RGB565
 * streaming texture, software framebuffer). main.c only sees:
 *   - the HAL primitives declared in hal.h
 *   - hal_sdl2_init / hal_sdl2_shutdown declared in hal_sdl2.h
 *   - SDL events (which need no SDL state from this file)
 */

#include <SDL.h>

#include "hal.h"
#include "hal_sdl2.h"

static u16           s_fb[SCREEN_W * SCREEN_H];
static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;

/* ── HAL implementation ──────────────────────────────────────────────────── */
void hal_clear(u16 c)
{
    int i;
    int n = SCREEN_W * SCREEN_H;
    for (i = 0; i < n; i++)
        s_fb[i] = c;
}

void hal_fill_rect(int x, int y, int w, int h, u16 c)
{
    int row, col;
    int x0 = x, y0 = y;
    int x1 = x + w;
    int y1 = y + h;
    /* Clip to screen */
    if (x0 < 0)        x0 = 0;
    if (y0 < 0)        y0 = 0;
    if (x1 > SCREEN_W) x1 = SCREEN_W;
    if (y1 > SCREEN_H) y1 = SCREEN_H;
    if (x1 <= x0 || y1 <= y0) return;
    for (row = y0; row < y1; row++) {
        u16 *p = s_fb + row * SCREEN_W + x0;
        for (col = x0; col < x1; col++)
            *p++ = c;
    }
}

void hal_swap(void)
{
    SDL_UpdateTexture(s_texture, NULL, s_fb, SCREEN_W * (int)sizeof(u16));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

/* ── Lifecycle ───────────────────────────────────────────────────────────── */
int hal_sdl2_init(const char *title)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        return 1;

    s_window = SDL_CreateWindow(
        title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 2, SCREEN_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) {
        SDL_Quit();
        return 1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest-neighbour 2x */

    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (!s_renderer) {
        SDL_DestroyWindow(s_window);
        s_window = NULL;
        SDL_Quit();
        return 1;
    }
    SDL_RenderSetLogicalSize(s_renderer, SCREEN_W, SCREEN_H);

    s_texture = SDL_CreateTexture(
        s_renderer,
        SDL_PIXELFORMAT_RGB565,
        SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H
    );
    if (!s_texture) {
        SDL_DestroyRenderer(s_renderer); s_renderer = NULL;
        SDL_DestroyWindow(s_window);     s_window   = NULL;
        SDL_Quit();
        return 1;
    }

    return 0;
}

void hal_sdl2_shutdown(void)
{
    if (s_texture)  { SDL_DestroyTexture(s_texture);   s_texture  = NULL; }
    if (s_renderer) { SDL_DestroyRenderer(s_renderer); s_renderer = NULL; }
    if (s_window)   { SDL_DestroyWindow(s_window);     s_window   = NULL; }
    SDL_Quit();
}
