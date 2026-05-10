/*
 * platforms/risc2/main.c — RISC2 entry point for Labyrinth.
 *
 * Bare-metal: UART input + dcache framebuffer (raycast_risc2.c writes pixels
 * row-by-row).  Player and map state live in BRAM scratch (small structs,
 * accessed every input tick — kept out of high-latency external RAM).
 *
 * MMIO addresses come from arch/risc2/memmap.h.
 */

#include "memmap.h"

#include "../../fixed.h"
#include "../../trig.h"
#include "../../player.h"
#include "../../map.h"

/* Raycaster (in raycast_risc2.c) drives the dcache framebuffer directly. */
void raycast_render(const player_t *p, const map_t *m);

/* Game state in BRAM scratch, just below the COLBUF used by the raycaster. */
#define PLAYER_PTR  ((player_t*)(MEM_BRAM_BASE + 0x780u))   /* word 480 */
#define MAP_PTR     ((map_t*)   (MEM_BRAM_BASE + 0x790u))   /* word 484 */

static int uart_try_getchar(void)
{
    if (UART_STATUS & UART_RXRDY)
        return (int)(UART_RX & 0xFF);
    return 0;
}

int main(void)
{
    player_t *p = PLAYER_PTR;
    map_t    *m = MAP_PTR;

    trig_init();
    map_load(m, 0);
    player_init(p, 1, 1, 0);

    raycast_render(p, m);

    for (;;) {
        int ch = uart_try_getchar();
        if (ch == 0) continue;

        unsigned int input = 0;
        if (ch == 'w' || ch == 'W') input = INPUT_FORWARD;
        if (ch == 's' || ch == 'S') input = INPUT_BACK;
        if (ch == 'a' || ch == 'A') input = INPUT_TURN_LEFT;
        if (ch == 'd' || ch == 'D') input = INPUT_TURN_RIGHT;

        if (input) {
            player_update(p, m, input);
            raycast_render(p, m);
        }
    }

    return 0;
}
