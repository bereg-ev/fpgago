/*
 * platform/sdl2/main.c -- SDL2 platform layer for Gomoku (character-based)
 *
 * Implements the character HAL with custom 8x16 glyph bitmaps for board
 * cells.  Each board cell is a pair of custom glyphs (left + right half)
 * forming a 16x16 square with built-in grid borders.
 *
 * Grid-line pixels are rendered in a muted colour, piece/symbol pixels
 * in distinct bright colours, giving the board a clean field look.
 */

#include <SDL.h>
#include <stdlib.h>

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"
#include "../../engine/font.h"

/* ---- framebuffer and text buffer ---------------------------------------- */
static u16 s_fb[SCREEN_W * SCREEN_H];
static int s_text[TEXT_ROWS][TEXT_COLS];

static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;

/* ---- colour palette ----------------------------------------------------- */
#define COL_BG      RGB565( 0,  2,  0)   /* near-black background  */
#define COL_GRID    RGB565( 2, 14,  2)   /* medium green grid      */
#define COL_X       RGB565(31, 63, 31)   /* white for human (X)    */
#define COL_O       RGB565(31, 20,  0)   /* orange for AI (O)      */
#define COL_CURSOR  RGB565(31, 63,  0)   /* yellow cursor          */
#define COL_HDR     RGB565( 6, 28,  6)   /* muted green headers    */
#define COL_TEXT    RGB565( 0, 48,  0)   /* bright green text      */

/* ---- custom glyph storage ----------------------------------------------- */
static u8 custom_bitmaps[CUST_COUNT][16]; /* [code - CUST_BASE][row] */

/* ---- 16-wide canvas for glyph generation -------------------------------- */
static u8 cvs_l[16], cvs_r[16]; /* left/right halves, 1 byte/row */

static void cvs_clear(void)
{
    int y;
    for (y = 0; y < 16; y++) { cvs_l[y] = 0; cvs_r[y] = 0; }
}

static void cvs_pixel(int x, int y)
{
    if ((unsigned)x >= 16 || (unsigned)y >= 16) return;
    if (x < 8) cvs_l[y] |= (0x80 >> x);
    else       cvs_r[y] |= (0x80 >> (x - 8));
}

static void cvs_borders(void)
{
    int y;
    for (y = 0; y < 16; y++) cvs_l[y] |= 0x80;  /* left border col 0  */
    cvs_l[15] = 0xFF; cvs_r[15] = 0xFF;          /* bottom border row 15 */
}

static void cvs_store(int left_code, int right_code)
{
    int y;
    for (y = 0; y < 16; y++) {
        custom_bitmaps[left_code  - CUST_BASE][y] = cvs_l[y];
        custom_bitmaps[right_code - CUST_BASE][y] = cvs_r[y];
    }
}

/* ---- generate all custom glyphs ----------------------------------------- */
static void init_glyphs(void)
{
    int i, y, gr, gc;

    /* Empty cell: borders only */
    cvs_clear(); cvs_borders();
    cvs_store(CH_EMPTY_L, CH_EMPTY_R);

    /* X piece: two 2-pixel-wide diagonals, rows 2-12 */
    cvs_clear(); cvs_borders();
    for (i = 0; i <= 10; i++) {
        int dy = 2 + i;
        int xbs = 2 + i;    /* backslash  \ */
        int xfs = 13 - i;   /* forward-slash / */
        cvs_pixel(xbs,     dy);
        cvs_pixel(xbs + 1, dy);
        cvs_pixel(xfs,     dy);
        cvs_pixel(xfs - 1, dy);
    }
    cvs_store(CH_X_L, CH_X_R);

    /* O piece: rounded ring, rows 2-12 */
    cvs_clear(); cvs_borders();
    for (i = 5; i <= 10; i++) { cvs_pixel(i, 2); cvs_pixel(i, 12); }
    for (i = 3; i <= 12; i++) { cvs_pixel(i, 3); cvs_pixel(i, 11); }
    for (y = 4; y <= 10; y++) {
        cvs_pixel(3, y); cvs_pixel(4, y);
        cvs_pixel(11, y); cvs_pixel(12, y);
    }
    cvs_store(CH_O_L, CH_O_R);

    /* Cursor: 2-pixel-thick hollow rectangle, rows 2-12, cols 3-12 */
    cvs_clear(); cvs_borders();
    for (i = 3; i <= 12; i++) {
        cvs_pixel(i, 2); cvs_pixel(i, 3);     /* top bar    */
        cvs_pixel(i, 11); cvs_pixel(i, 12);   /* bottom bar */
    }
    for (y = 2; y <= 12; y++) {
        cvs_pixel(3, y); cvs_pixel(4, y);     /* left bar   */
        cvs_pixel(11, y); cvs_pixel(12, y);   /* right bar  */
    }
    cvs_store(CH_CUR_L, CH_CUR_R);

    /* Column headers A-O: font5x7 letter centred + grid borders */
    for (i = 0; i < 15; i++) {
        const unsigned int *fnt = font5x7['A' + i - 0x20];
        cvs_clear(); cvs_borders();
        for (gr = 0; gr < 7; gr++) {
            unsigned int bits = fnt[gr];
            for (gc = 0; gc < 5; gc++) {
                if (bits & (0x10 >> gc)) {
                    cvs_pixel(6 + gc, 1 + gr * 2);      /* doubled vertically */
                    cvs_pixel(6 + gc, 1 + gr * 2 + 1);
                }
            }
        }
        cvs_store(CH_HDR_L(i), CH_HDR_R(i));
    }
}

/* ---- determine foreground colour for a custom glyph --------------------- */
static u16 glyph_fg(int ch)
{
    if (ch == CH_X_L   || ch == CH_X_R)   return COL_X;
    if (ch == CH_O_L   || ch == CH_O_R)   return COL_O;
    if (ch == CH_CUR_L || ch == CH_CUR_R) return COL_CURSOR;
    if (ch >= CH_HDR_L(0))                return COL_HDR;
    return COL_GRID; /* empty cell: all visible pixels are grid */
}

/* ---- HAL implementation ------------------------------------------------- */
void hal_clear(void)
{
    int r, c;
    for (r = 0; r < TEXT_ROWS; r++)
        for (c = 0; c < TEXT_COLS; c++)
            s_text[r][c] = ' ';
}

void hal_putchar(int col, int row, int ch)
{
    if ((unsigned)col < TEXT_COLS && (unsigned)row < TEXT_ROWS)
        s_text[row][col] = ch;
}

/* Render text buffer to pixel framebuffer */
static void render_text_to_fb(void)
{
    int tr, tc, gr, gc, py, px;

    for (tr = 0; tr < TEXT_ROWS; tr++) {
        py = tr * 16;
        for (tc = 0; tc < TEXT_COLS; tc++) {
            int ch = s_text[tr][tc];
            px = tc * 8;

            if (ch >= CUST_BASE && ch < CUST_BASE + CUST_COUNT) {
                /* Custom board glyph: separate grid-line and content colours */
                u8 *bmp = custom_bitmaps[ch - CUST_BASE];
                int is_left = ((ch - CUST_BASE) & 1) == 0;
                u16 fg = glyph_fg(ch);

                for (gr = 0; gr < 16; gr++) {
                    u8 bits = bmp[gr];
                    /* Border mask: col 0 for left halves, row 15 for all */
                    u8 bmask = (gr == 15) ? 0xFF : (is_left ? 0x80 : 0x00);
                    u16 *row_ptr = s_fb + (py + gr) * SCREEN_W + px;

                    for (gc = 0; gc < 8; gc++) {
                        u8 bit = 0x80 >> gc;
                        if (bits & bit)
                            row_ptr[gc] = (bmask & bit) ? COL_GRID : fg;
                        else
                            row_ptr[gc] = COL_BG;
                    }
                }
            } else {
                /* Standard ASCII: font5x7 doubled vertically, no borders */
                for (gr = 0; gr < 16; gr++)
                    for (gc = 0; gc < 8; gc++)
                        s_fb[(py + gr) * SCREEN_W + px + gc] = COL_BG;

                if (ch >= 0x20 && ch <= 0x7E) {
                    const unsigned int *glyph = font5x7[ch - 0x20];
                    for (gr = 0; gr < 7; gr++) {
                        unsigned int bits = glyph[gr];
                        for (gc = 0; gc < 5; gc++) {
                            if (bits & (0x10 >> gc)) {
                                int fx = px + 1 + gc;
                                int fy = py + 1 + gr * 2;
                                s_fb[fy       * SCREEN_W + fx] = COL_TEXT;
                                s_fb[(fy + 1) * SCREEN_W + fx] = COL_TEXT;
                            }
                        }
                    }
                }
            }
        }
    }
}

void hal_swap(void)
{
    render_text_to_fb();
    SDL_UpdateTexture(s_texture, NULL, s_fb, SCREEN_W * (int)sizeof(u16));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

/* ---- main --------------------------------------------------------------- */
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
        "Gomoku",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 2, SCREEN_H * 2,
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
        SDL_RenderSetLogicalSize(s_renderer, SCREEN_W, SCREEN_H);
    if (!s_renderer) {
        SDL_Log("SDL_CreateRenderer: %s", SDL_GetError());
        SDL_DestroyWindow(s_window);
        SDL_Quit();
        return 1;
    }

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

    init_glyphs();
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
                    case SDLK_s: case SDLK_DOWN:  input = 's'; break;
                    case SDLK_a: case SDLK_LEFT:  input = 'a'; break;
                    case SDLK_d: case SDLK_RIGHT: input = 'd'; break;
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
