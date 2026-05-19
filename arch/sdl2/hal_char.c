/*
 * hal_char.c — Shared SDL2 implementation of the char-LCD HAL.
 *
 * Used by tic-tac-toe and char-gomoku.  Matches the lcd_char.v hardware
 * model: 128 font slots of 8×16 1-bit bitmaps, default-loaded with the IBM
 * 8x16 font; games may overwrite individual slots at runtime via
 * hal_upload_glyph (e.g. char-gomoku's piece bitmaps).
 *
 * Window/texture geometry adapts to the game's hal.h:
 *   - If SCREEN_W/SCREEN_H are defined (char-gomoku, 480×272), the texture
 *     is that LCD size and the text window is centred horizontally so the
 *     sim matches FPGA layout.
 *   - Otherwise (tic-tac-toe), the texture is exactly HAL_COLS·8 × HAL_ROWS·16.
 *
 * Colour is fixed green-on-black (classic LCD look), matching what lcd_char.v
 * produces on the FPGA.  Pieces and cursor are distinguished by their glyph
 * shape, not by colour — this keeps the HAL surface minimal.
 */

#include <SDL.h>
#include <string.h>

#include "hal.h"
#include "font_ibm8x16.h"

#if defined(LCD_COLS)
  #define HAL_COLS  LCD_COLS
  #define HAL_ROWS  LCD_ROWS
#else
  #define HAL_COLS  TEXT_COLS
  #define HAL_ROWS  TEXT_ROWS
#endif

/* Texture size: prefer the explicit LCD framebuffer size if the game
 * defines one, else exactly the text grid. */
#if defined(SCREEN_W) && defined(SCREEN_H)
  #define FB_W  SCREEN_W
  #define FB_H  SCREEN_H
#else
  #define FB_W  (HAL_COLS * 8)
  #define FB_H  (HAL_ROWS * 16)
#endif

#define NUM_SLOTS 128

/* Classic green-on-black LCD palette in RGB565. */
#define COL_BG_DEFAULT  ((unsigned short)((  0u << 11) | ( 2u << 5) |  0u))
#define COL_FG_DEFAULT  ((unsigned short)((  0u << 11) | (48u << 5) |  0u))

static unsigned char  s_font [NUM_SLOTS][16];  /* row r = 8 horiz pixels, MSB left */
static unsigned short s_fg   [NUM_SLOTS];      /* per-slot foreground colour */
static unsigned short s_bg = COL_BG_DEFAULT;
static int            s_chars[16 * 64];        /* up to 64 cols × 16 rows */

static unsigned short s_fb [FB_W * FB_H];

static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;

#ifndef GAME_TITLE
#define GAME_TITLE "fpgago"
#endif

/* ── Font store initialisation ─────────────────────────────────────────── */
static void init_default_font(void)
{
    int slot, i;
    for (slot = 0; slot < NUM_SLOTS; slot++) {
        for (i = 0; i < 8; i++) {
            unsigned int entry = font_ibm8x16[slot * 8 + i];
            s_font[slot][i * 2    ] = (unsigned char)(entry & 0xFF);
            s_font[slot][i * 2 + 1] = (unsigned char)((entry >> 8) & 0xFF);
        }
        s_fg[slot] = COL_FG_DEFAULT;
    }
}

/* ── HAL primitives ────────────────────────────────────────────────────── */
static void put_cell(int col, int row, int ch)
{
    if ((unsigned)col < HAL_COLS && (unsigned)row < HAL_ROWS)
        s_chars[row * HAL_COLS + col] = ch;
}
void hal_putc   (int col, int row, int ch) { put_cell(col, row, ch); }
void hal_putchar(int col, int row, int ch) { put_cell(col, row, ch); }

void hal_clear(void)
{
    int i, n = HAL_COLS * HAL_ROWS;
    for (i = 0; i < n; i++) s_chars[i] = ' ';
}

void hal_upload_glyph(int slot, const unsigned char *bitmap)
{
    int idx = slot & 0x7F;
    int i;
    for (i = 0; i < 16; i++) s_font[idx][i] = bitmap[i];
}

/* ── Render text grid into the texture FB ──────────────────────────────── */
static void render_grid(void)
{
    int tr, tc, gr, gc;
    int x_offset = (FB_W - HAL_COLS * 8) / 2;
    if (x_offset < 0) x_offset = 0;

    /* First clear the entire FB — char-gomoku's hal_init centres a narrow
     * grid in a 480-wide texture and the margin needs to stay s_bg. */
    {
        int i, n = FB_W * FB_H;
        for (i = 0; i < n; i++) s_fb[i] = s_bg;
    }

    for (tr = 0; tr < HAL_ROWS; tr++) {
        int py = tr * 16;
        for (tc = 0; tc < HAL_COLS; tc++) {
            int px = x_offset + tc * 8;
            int ch = s_chars[tr * HAL_COLS + tc] & 0x7F;
            unsigned short fg = s_fg[ch];
            for (gr = 0; gr < 16; gr++) {
                unsigned char bits = s_font[ch][gr];
                unsigned short *row_ptr = s_fb + (py + gr) * FB_W + px;
                for (gc = 0; gc < 8; gc++) {
                    if (bits & (0x80 >> gc))
                        row_ptr[gc] = fg;
                    else
                        row_ptr[gc] = s_bg;
                }
            }
        }
    }
}

void hal_swap(void)
{
    render_grid();
    SDL_UpdateTexture(s_texture, NULL, s_fb, FB_W * (int)sizeof(unsigned short));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

int hal_getchar(void)
{
    SDL_Event ev;
    while (SDL_WaitEvent(&ev)) {
        if (ev.type == SDL_QUIT) return 'q';
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

/* ── Lifecycle ─────────────────────────────────────────────────────────── */
void hal_init(void)
{
    if (s_window) return;          /* already up */

    init_default_font();
    s_bg = COL_BG_DEFAULT;
    hal_clear();                    /* fill char grid with spaces */

    if (SDL_Init(SDL_INIT_VIDEO) != 0) return;

    s_window = SDL_CreateWindow(
        GAME_TITLE,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        FB_W * 2, FB_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) { SDL_Quit(); return; }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    s_renderer = SDL_CreateRenderer(s_window, -1,
                    SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer)
        s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (!s_renderer) {
        SDL_DestroyWindow(s_window); s_window = NULL;
        SDL_Quit();
        return;
    }
    SDL_RenderSetLogicalSize(s_renderer, FB_W, FB_H);

    s_texture = SDL_CreateTexture(
        s_renderer,
        SDL_PIXELFORMAT_RGB565,
        SDL_TEXTUREACCESS_STREAMING,
        FB_W, FB_H
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
