/*
 * main.c — Portable entry point for Chess.
 *
 * Same source for every arch (SDL2, RISC-V DarkRV, RISC2, …).  Arch-specific
 * I/O lives behind the HAL interface declared in hal.h.
 *
 * Note: AI moves can take several seconds on slower targets; during that
 * time the sim window is briefly unresponsive (we're inside game_tick,
 * not pumping SDL events).  Acceptable for a turn-based game.
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
