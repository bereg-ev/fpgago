/*
 * platforms/risc2/main.c — RISC2 entry point for Chess.
 *
 * Reads keystrokes from the on-board UART, drives game_tick(), and presents
 * each frame via the HAL.  Game state (game_t ~3.4KB) and zobrist tables
 * (~4KB) live in external RAM at MEM_EXT_RAM_BASE / MEM_EXT_RAM_BASE+0x10000
 * — PSRAM on HW=v2 — so chess does not consume the 16KB BRAM data region.
 *
 * MMIO addresses come from arch/risc2/memmap.h; HAL implementation is in
 * hal_risc2.c.
 */

#include "hal.h"
#include "game.h"
#include "render.h"
#include "memmap.h"

static int uart_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

/* Game state in external RAM. */
#define GAME_PTR  ((game_t*)MEM_EXT_RAM_BASE)

int main(void)
{
    game_t *g = GAME_PTR;
    int ch;

    game_init(g);

    /* Render both buffers so the display starts clean. */
    render_frame(g);
    hal_swap();
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
