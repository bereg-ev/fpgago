/*
 * main.c — Portable entry point for Tic-Tac-Toe.
 *
 * Same source for every arch.  The char HAL takes care of font upload and
 * back-buffer / swap discipline behind hal_init/hal_clear/hal_putc/hal_swap.
 */

#include "hal.h"
#include "game.h"
#include "render.h"

static game_t g_game;

int main(void)
{
    game_t *g = &g_game;

    hal_init();
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
