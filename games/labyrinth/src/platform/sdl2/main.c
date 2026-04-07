/*
 * platform/sdl2/main.c — SDL2 platform layer
 *
 * Responsibilities:
 *   - Open an 800x600 window.
 *   - Read keyboard input and translate to engine INPUT_* flags.
 *   - Call player_update() + raycast_render() each frame.
 *   - Blit the engine framebuffer to the window via SDL_UpdateTexture.
 *
 * This file is the ONLY source that depends on SDL2.
 * The engine (src/engine/) has zero platform dependencies.
 *
 * Controls:
 *   Arrow Up / W    — move forward
 *   Arrow Down / S  — move backward
 *   Arrow Left / A  — turn left
 *   Arrow Right / D — turn right
 *   Q               — strafe left
 *   E               — strafe right
 *   ESC             — quit
 */

#include <stdio.h>
#include <stdlib.h>
#include <SDL.h>

/* Pull in the portable engine */
#include "../../engine/fixed.h"
#include "../../engine/trig.h"
#include "../../engine/map.h"
#include "../../engine/texture.h"
#include "../../engine/player.h"
#include "../../engine/raycast.h"

/* Static framebuffer — no dynamic allocation required */
static u32 framebuffer[SCREEN_W * SCREEN_H];

int main(int argc, char *argv[])
{
    const char *map_path;
    map_t       map;
    player_t    player;
    SDL_Window   *window  = NULL;
    SDL_Renderer *renderer = NULL;
    SDL_Texture  *texture  = NULL;
    int running = 1;

    /* ------------------------------------------------------------------ */
    /* Command-line argument: map file path                                 */
    /* ------------------------------------------------------------------ */
    if (argc < 2)
    {
        fprintf(stderr, "Usage: %s <map.txt>\n", argv[0]);
        return 1;
    }
    map_path = argv[1];

    /* ------------------------------------------------------------------ */
    /* Engine initialisation                                                */
    /* ------------------------------------------------------------------ */
    trig_init();
    texture_init();

    if (map_load(&map, map_path) != 0)
        return 1;

    /* Start at cell (1,1) facing east (angle 0 = east, cos=1, sin=0) */
    player_init(&player, 1, 1, 0);

    /* ------------------------------------------------------------------ */
    /* SDL2 setup                                                           */
    /* ------------------------------------------------------------------ */
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    window = SDL_CreateWindow(
        "Labyrinth (480x272)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 2, SCREEN_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!window)
    {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest-neighbor */
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (!renderer)
    {
        /* Fall back to software renderer */
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
        if (!renderer)
        {
            fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
            SDL_DestroyWindow(window);
            SDL_Quit();
            return 1;
        }
    }

    /*
     * SDL_PIXELFORMAT_ARGB8888: each pixel is 0xAARRGGBB (32-bit).
     * The engine writes 0x00RRGGBB which maps cleanly to this format.
     */
    texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H
    );
    if (!texture)
    {
        fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    /* ------------------------------------------------------------------ */
    /* Main loop                                                            */
    /* ------------------------------------------------------------------ */
    while (running)
    {
        SDL_Event event;
        u32 input_flags = 0;

        /* Event handling */
        while (SDL_PollEvent(&event))
        {
            if (event.type == SDL_QUIT)
                running = 0;

            if (event.type == SDL_KEYDOWN)
            {
                switch (event.key.keysym.sym)
                {
                    case SDLK_ESCAPE:
                        running = 0;
                        break;
                    default:
                        break;
                }
            }
        }

        /* Keyboard state (held keys) */
        const Uint8 *keys = SDL_GetKeyboardState(NULL);

        if (keys[SDL_SCANCODE_UP]    || keys[SDL_SCANCODE_W]) input_flags |= INPUT_FORWARD;
        if (keys[SDL_SCANCODE_DOWN]  || keys[SDL_SCANCODE_S]) input_flags |= INPUT_BACK;
        if (keys[SDL_SCANCODE_LEFT]  || keys[SDL_SCANCODE_A]) input_flags |= INPUT_TURN_LEFT;
        if (keys[SDL_SCANCODE_RIGHT] || keys[SDL_SCANCODE_D]) input_flags |= INPUT_TURN_RIGHT;
        if (keys[SDL_SCANCODE_Q])                             input_flags |= INPUT_STRAFE_LEFT;
        if (keys[SDL_SCANCODE_E])                             input_flags |= INPUT_STRAFE_RIGHT;

        /* Update and render */
        player_update(&player, &map, input_flags);
        raycast_render(framebuffer, &player, &map);

        /* Blit framebuffer to SDL texture and present */
        SDL_UpdateTexture(texture, NULL, framebuffer, SCREEN_W * (int)sizeof(u32));
        SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);

        /* ~60 fps cap */
        SDL_Delay(16);
    }

    /* ------------------------------------------------------------------ */
    /* Cleanup                                                              */
    /* ------------------------------------------------------------------ */
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
