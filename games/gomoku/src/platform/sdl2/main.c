/*
 * platform/sdl2/main.c — SDL2 platform layer for Five-in-a-Row
 *
 * Responsibilities:
 *   - Provide hal_clear / hal_fill_rect / hal_swap via a u16 software
 *     framebuffer uploaded to an SDL2 streaming texture (RGB565).
 *   - Map keyboard events to game_tick() input characters.
 *   - Run the main loop at ~60 fps.
 *
 * This is the ONLY file that includes SDL2 headers.
 */

#include <SDL.h>
#include <stdlib.h>

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ── Software framebuffer ────────────────────────────────────────────────── */
static u16 s_fb[SCREEN_W * SCREEN_H];

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
    if (x0 < 0)       x0 = 0;
    if (y0 < 0)       y0 = 0;
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

/* ── Main ────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    game_t g;
    int running = 1;

    (void)argc; (void)argv;

    /* SDL2 init */
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        SDL_Log("SDL_Init: %s", SDL_GetError());
        return 1;
    }

    s_window = SDL_CreateWindow(
        "Five-in-a-Row (Gomoku)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 2, SCREEN_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) {
        SDL_Log("SDL_CreateWindow: %s", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest-neighbour for crisp 2x */
    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (s_renderer)
        SDL_RenderSetLogicalSize(s_renderer, SCREEN_W, SCREEN_H);
    if (!s_renderer) {
        SDL_Log("SDL_CreateRenderer: %s", SDL_GetError());
        SDL_DestroyWindow(s_window);
        SDL_Quit();
        return 1;
    }

    /* RGB565 streaming texture — no colour conversion needed */
    s_texture = SDL_CreateTexture(
        s_renderer,
        SDL_PIXELFORMAT_RGB565,
        SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H
    );
    if (!s_texture) {
        SDL_Log("SDL_CreateTexture: %s", SDL_GetError());
        SDL_DestroyRenderer(s_renderer);
        SDL_DestroyWindow(s_window);
        SDL_Quit();
        return 1;
    }

    /* Game init + first frame */
    game_init(&g);
    render_frame(&g);
    hal_swap();

    /* Main loop */
    while (running) {
        SDL_Event ev;
        int input = 0;

        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) {
                running = 0;
            } else if (ev.type == SDL_KEYDOWN) {
                switch (ev.key.keysym.sym) {
                    case SDLK_ESCAPE:  running = 0;  break;
                    case SDLK_w: case SDLK_UP:    input = 'w'; break;
                    case SDLK_s: case SDLK_DOWN:   input = 's'; break;
                    case SDLK_a: case SDLK_LEFT:   input = 'a'; break;
                    case SDLK_d: case SDLK_RIGHT:  input = 'd'; break;
                    case SDLK_SPACE:               input = ' '; break;
                    case SDLK_RETURN: case SDLK_KP_ENTER: input = '\r'; break;
                    default: break;
                }
            }
        }

        if (input) {
            game_tick(&g, input);
            render_frame(&g);
            hal_swap();
        }

        SDL_Delay(16);
    }

    /* Cleanup */
    SDL_DestroyTexture(s_texture);
    SDL_DestroyRenderer(s_renderer);
    SDL_DestroyWindow(s_window);
    SDL_Quit();
    return 0;
}
