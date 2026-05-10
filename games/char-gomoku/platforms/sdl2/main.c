/*
 * platforms/sdl2/main.c — SDL2 entry point for Char-Gomoku.
 *
 * All HAL plumbing (text buffer, glyph rasterizer, SDL framebuffer) lives in
 * hal_sdl2.c — this file only sees the character HAL surface plus SDL events.
 */

#include <SDL.h>

#include "hal.h"
#include "hal_sdl2.h"
#include "game.h"
#include "render.h"

int main(int argc, char *argv[])
{
    game_t g;
    int running = 1;

    (void)argc; (void)argv;

    if (hal_sdl2_init("Gomoku") != 0) {
        SDL_Log("hal_sdl2_init failed: %s", SDL_GetError());
        hal_sdl2_shutdown();
        return 1;
    }

    game_init(&g);
    render_frame(&g);
    hal_swap();

    while (running) {
        SDL_Event ev;
        int input = 0;

        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) {
                running = 0;
            } else if (ev.type == SDL_KEYDOWN) {
                switch (ev.key.keysym.sym) {
                    case SDLK_ESCAPE:                     running = 0; break;
                    case SDLK_w: case SDLK_UP:            input = 'w'; break;
                    case SDLK_s: case SDLK_DOWN:          input = 's'; break;
                    case SDLK_a: case SDLK_LEFT:          input = 'a'; break;
                    case SDLK_d: case SDLK_RIGHT:         input = 'd'; break;
                    case SDLK_SPACE:                      input = ' '; break;
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

    hal_sdl2_shutdown();
    return 0;
}
