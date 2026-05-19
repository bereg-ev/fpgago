/*
 * main.c — Portable entry point for Char-Gomoku.
 *
 * Same source across SDL2 / RISC-V DarkRV / RISC2.  Differs from the simpler
 * games in one place: a game_init_glyphs() call between hal_init() and
 * game_init().  This uploads the board-piece bitmaps (X / O / cursor / empty
 * with grid borders, plus column-header A-O letters) into the font ROM so
 * render.c's hal_putchar calls produce the expected board look on every arch.
 *
 * The glyph upload has to come after hal_init() (which loads the default IBM
 * font and brings up the renderer) and before game_init() (which writes the
 * first cells the renderer will consume).
 */

#include "hal.h"
#include "game.h"
#include "render.h"
#include "glyphs.h"

static game_t g_game;

int main(void)
{
    game_t *g = &g_game;

    hal_init();
    game_init_glyphs();

    game_init(g);
    render_frame(g);
    hal_swap();

    for (;;) {
        int ch = hal_getchar();
        if (ch == 'q') break;
        game_tick(g, ch);
        render_frame(g);
        hal_swap();
    }
    return 0;
}
