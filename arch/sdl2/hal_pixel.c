/*
 * hal_pixel.c — Shared SDL2 implementation of the pixel HAL.
 *
 * Used by gomoku, chess, and any other pixel-FB game.  Owns the SDL window,
 * renderer, RGB565 streaming texture, and software framebuffer; main.c only
 * sees hal.h plus SDL_PollEvent for input.
 *
 * Mapping from the FPGA HAL:
 *   - The s_fb[] array stands in for the per-scanline FB_BUF + GPU_ROW
 *     FLUSH protocol.  hal_clear / hal_fill_rect write the whole array
 *     directly (no scanline staging), and hal_swap pushes it to the texture.
 *   - hal_getchar drains key events into the WASD/space mapping expected
 *     by the game-side input layer; arrow keys and Return are aliased so
 *     either keyboard convention works.
 */

#include <SDL.h>

#include "hal.h"

static u16           s_fb[SCREEN_W * SCREEN_H];
static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;

/* Window title — define GAME_TITLE in the game's hal.h (or CFLAGS) to
 * override; otherwise we fall back to a generic name. */
#ifndef GAME_TITLE
#define GAME_TITLE "fpgago"
#endif

/* ── HAL implementation ──────────────────────────────────────────────────── */
void hal_clear(u16 c)
{
    int i, n = SCREEN_W * SCREEN_H;
    for (i = 0; i < n; i++) s_fb[i] = c;
}

void hal_fill_rect(int x, int y, int w, int h, u16 c)
{
    int row, col;
    int x0 = x,     y0 = y;
    int x1 = x + w, y1 = y + h;
    if (x0 < 0)        x0 = 0;
    if (y0 < 0)        y0 = 0;
    if (x1 > SCREEN_W) x1 = SCREEN_W;
    if (y1 > SCREEN_H) y1 = SCREEN_H;
    if (x1 <= x0 || y1 <= y0) return;

    for (row = y0; row < y1; row++) {
        u16 *p = s_fb + row * SCREEN_W + x0;
        for (col = x0; col < x1; col++) *p++ = c;
    }
}

void hal_swap(void)
{
    SDL_UpdateTexture(s_texture, NULL, s_fb, SCREEN_W * (int)sizeof(u16));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

/* Copy a full scanline of pixels into the back buffer.
 * Caller owns `pixels` (must have SCREEN_W u16 entries). */
void hal_blit_row(int row, const u16 *pixels)
{
    if ((unsigned)row >= (unsigned)SCREEN_H) return;
    u16 *dst = s_fb + row * SCREEN_W;
    int x;
    for (x = 0; x < SCREEN_W; x++) dst[x] = pixels[x];
}

int hal_getchar(void)
{
    SDL_Event ev;
    while (SDL_WaitEvent(&ev)) {
        if (ev.type == SDL_QUIT) {
            /* Cooperate with the game's exit handling by feeding a 'q'. */
            return 'q';
        }
        if (ev.type == SDL_KEYDOWN) {
            SDL_Keycode k = ev.key.keysym.sym;
            switch (k) {
                case SDLK_UP:    return 'w';
                case SDLK_DOWN:  return 's';
                case SDLK_LEFT:  return 'a';
                case SDLK_RIGHT: return 'd';
                case SDLK_RETURN:
                case SDLK_KP_ENTER:
                case SDLK_SPACE: return ' ';
                case SDLK_ESCAPE: return 'q';
                default:
                    if (k >= 0x20 && k < 0x7F) return (int)k;
                    break;
            }
        }
    }
    return -1;
}

/* ── Lifecycle ───────────────────────────────────────────────────────────── */
void hal_init(void)
{
    /* SDL is single-shot: if a prior game in the same process already
     * called hal_init we leave the existing window in place. */
    if (s_window) return;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) return;

    s_window = SDL_CreateWindow(
        GAME_TITLE,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 2, SCREEN_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) { SDL_Quit(); return; }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest-neighbour 2× */

    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (!s_renderer) {
        SDL_DestroyWindow(s_window); s_window = NULL;
        SDL_Quit();
        return;
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
    }
}

void hal_shutdown(void)
{
    if (s_texture)  { SDL_DestroyTexture(s_texture);   s_texture  = NULL; }
    if (s_renderer) { SDL_DestroyRenderer(s_renderer); s_renderer = NULL; }
    if (s_window)   { SDL_DestroyWindow(s_window);     s_window   = NULL; }
    SDL_Quit();
}
