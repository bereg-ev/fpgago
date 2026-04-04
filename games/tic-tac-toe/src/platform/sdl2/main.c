/*
 * platform/sdl2/main.c — SDL2 platform for Tic-Tac-Toe (character LCD)
 *
 * Simulates a 32x16 character LCD using 8x16 pixel font cells.
 * Display: 256x256 pixels (32*8 x 16*16), scaled 2x.
 */

#include <SDL.h>
#include <string.h>

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"
#include "../../engine/font.h"

/* Character cell: 8 pixels wide (font is 5 wide, 3 padding), 16 tall (font 7, 9 padding) */
#define CHAR_W   8
#define CHAR_H  16
#define FONT_W   5
#define GLYPH_H  7

#define FB_W    (LCD_COLS * CHAR_W)   /* 256 */
#define FB_H    (LCD_ROWS * CHAR_H)   /* 256 */

/* ── Back buffer ────────────────────────────────────────────────────── */
static char s_chars[LCD_ROWS][LCD_COLS];

static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;
static uint32_t      s_fb[FB_W * FB_H];

/* Colours — green on black, classic LCD style */
#define COL_BG  0xFF001800
#define COL_FG  0xFF00CC00

/* ── HAL implementation ─────────────────────────────────────────────── */

void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        s_chars[row][col] = ch;
}

void hal_clear(void)
{
    memset(s_chars, ' ', sizeof(s_chars));
}

void hal_swap(void)
{
    int r, c, fr, fc;

    /* Render chars into pixel framebuffer */
    for (r = 0; r < LCD_ROWS; r++) {
        for (c = 0; c < LCD_COLS; c++) {
            unsigned char ch = (unsigned char)s_chars[r][c];
            const unsigned int *glyph = NULL;
            if (ch >= 0x20 && ch < 0x80)
                glyph = font5x7[ch - 0x20];

            int px = c * CHAR_W;
            int py = r * CHAR_H;

            /* Clear cell */
            for (fr = 0; fr < CHAR_H; fr++)
                for (fc = 0; fc < CHAR_W; fc++)
                    s_fb[(py + fr) * FB_W + (px + fc)] = COL_BG;

            /* Draw glyph (centered: offset x+1, y+4) */
            if (glyph) {
                for (fr = 0; fr < GLYPH_H; fr++)
                    for (fc = 0; fc < FONT_W; fc++)
                        if (glyph[fr] & (0x10 >> fc))
                            s_fb[(py + 4 + fr) * FB_W + (px + 1 + fc)] = COL_FG;
            }
        }
    }

    SDL_UpdateTexture(s_texture, NULL, s_fb, FB_W * (int)sizeof(uint32_t));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

/* ── Main ───────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    game_t g;
    int running = 1;

    (void)argc; (void)argv;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        SDL_Log("SDL_Init: %s", SDL_GetError());
        return 1;
    }

    s_window = SDL_CreateWindow(
        "Tic-Tac-Toe",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        FB_W * 2, FB_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) {
        SDL_Log("SDL_CreateWindow: %s", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (s_renderer)
        SDL_RenderSetLogicalSize(s_renderer, FB_W, FB_H);
    if (!s_renderer) {
        SDL_Log("SDL_CreateRenderer: %s", SDL_GetError());
        SDL_DestroyWindow(s_window);
        SDL_Quit();
        return 1;
    }

    s_texture = SDL_CreateTexture(
        s_renderer,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        FB_W, FB_H
    );
    if (!s_texture) {
        SDL_Log("SDL_CreateTexture: %s", SDL_GetError());
        SDL_DestroyRenderer(s_renderer);
        SDL_DestroyWindow(s_window);
        SDL_Quit();
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

    SDL_DestroyTexture(s_texture);
    SDL_DestroyRenderer(s_renderer);
    SDL_DestroyWindow(s_window);
    SDL_Quit();
    return 0;
}
