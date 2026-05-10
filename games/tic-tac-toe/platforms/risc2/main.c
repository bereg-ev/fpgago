/*
 * platforms/risc2/main.c — RISC2 entry point for Tic-Tac-Toe.
 *
 * Reads keystrokes from the on-board UART, drives game_tick(), and presents
 * each frame via the character HAL.  Game state (game_t, ~15 words) lives
 * in external RAM at MEM_EXT_RAM_BASE (PSRAM on HW=v2).
 *
 * MMIO addresses come from arch/risc2/memmap.h; HAL implementation is in
 * hal_risc2.c.
 */

#include "hal.h"
#include "hal_risc2.h"
#include "game.h"
#include "render.h"
#include "memmap.h"

static int uart_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

#define GAME_PTR  ((game_t*)MEM_EXT_RAM_BASE)

int main(void)
{
    game_t *g = GAME_PTR;
    int ch;

    hal_risc2_init();

    game_init(g);
    render_frame(g);
    hal_swap();

    for (;;) {
        ch = uart_getchar();
        game_tick(g, ch);
        render_frame(g);
        hal_swap();
    }

    return 0;
}
