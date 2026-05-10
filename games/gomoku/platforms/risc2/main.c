/*
 * platforms/risc2/main.c — RISC2 entry point for Five-in-a-Row.
 *
 * Reads keystrokes from the on-board UART, drives game_tick(), and presents
 * each frame via the HAL. Game state lives in external RAM (PSRAM on HW=v2,
 * X-SDRAM on HW=v1) so cache and external-memory paths get exercised.
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

/* Game state in external RAM. Both HW versions map it at MEM_EXT_RAM_BASE
 * (= 0x100000): v1 → X-bus SDR SDRAM, v2 → APS6404L QSPI PSRAM. */
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
