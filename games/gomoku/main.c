/*
 * main.c — Portable entry point for Five-in-a-Row.
 *
 * Same source for every arch (SDL2, RISC-V DarkRV, RISC2, future targets).
 * Arch-specific I/O lives behind the HAL interface declared in hal.h.
 *
 * State is a static global so the whole game_t lives in .bss — important on
 * the RISC targets where stack space comes out of a tiny BRAM and large
 * automatic structs would silently corrupt other variables.
 *
 * Input convention: hal_getchar() blocks until the next keystroke.  On sim
 * it returns 'q' when the window is closed, which we treat as quit.  FPGA
 * targets never produce 'q' from the UART unless the user types it, in
 * which case quitting is the right thing anyway.
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
