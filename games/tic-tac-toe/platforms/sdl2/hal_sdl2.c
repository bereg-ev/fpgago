/*
 * hal_sdl2.c — SDL2 implementation of the Tic-Tac-Toe character HAL.
 *
 * Owns the text back-buffer, the ARGB pixel framebuffer, and SDL window /
 * renderer / texture state.  hal_swap rasterizes the text grid through
 * font5x7 to the framebuffer and pushes it to the streaming texture.
 */

#include <SDL.h>
#include <string.h>

#include "hal.h"
#include "hal_sdl2.h"
#include "font.h"

#define CHAR_W   8
#define CHAR_H  16
#define FONT_W   5
#define GLYPH_H  7

#define FB_W    (LCD_COLS * CHAR_W)   /* 256 */
#define FB_H    (LCD_ROWS * CHAR_H)   /* 256 */

/* ── Backing state ─────────────────────────────────────────────────────── */
static char          s_chars[LCD_ROWS][LCD_COLS];
static uint32_t      s_fb[FB_W * FB_H];
static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;

/* Classic green-on-black LCD palette */
#define COL_BG  0xFF001800u
#define COL_FG  0xFF00CC00u

/* ── HAL implementation ─────────────────────────────────────────────────── */
void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        s_chars[row][col] = (char)ch;
}

void hal_clear(void)
{
    memset(s_chars, ' ', sizeof(s_chars));
}

void hal_swap(void)
{
    int r, c, fr, fc;

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

/* ── Lifecycle ──────────────────────────────────────────────────────────── */
int hal_sdl2_init(const char *title)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        return 1;

    s_window = SDL_CreateWindow(
        title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        FB_W * 2, FB_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) {
        SDL_Quit();
        return 1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (!s_renderer) {
        SDL_DestroyWindow(s_window); s_window = NULL;
        SDL_Quit();
        return 1;
    }
    SDL_RenderSetLogicalSize(s_renderer, FB_W, FB_H);

    s_texture = SDL_CreateTexture(
        s_renderer,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        FB_W, FB_H
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
