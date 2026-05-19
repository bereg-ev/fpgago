/*
 * main.c — Portable Labyrinth2 entry point.
 *
 * One source for every arch.  Arch-specific I/O is behind the HAL.
 * Mutable game state lives in BRAM scratch on risc2 (see scratch.h);
 * other archs use ordinary static storage.
 */

#include "hal.h"
#include "raycast.h"
#include "player.h"
#include "map.h"
#include "scratch.h"

#ifdef RISC2_PLATFORM
static map_t    * const g_map_p    = (map_t    *)SCRATCH_MAP;
static player_t * const g_player_p = (player_t *)SCRATCH_PLAYER;
#else
static map_t    g_map;
static player_t g_player;
static map_t    * const g_map_p    = &g_map;
static player_t * const g_player_p = &g_player;
#endif

int main(void)
{
    map_t    *m = g_map_p;
    player_t *p = g_player_p;

    hal_init();

    /* Clear BOTH FB buffers to black so the user sees a black screen
     * during the multi-second first raycast, rather than the
     * uninitialised-SDRAM random pixels.  hal_clear uses the dcache
     * CLEAR_FB FSM (~ms on risc2) and patches PPM row 271 itself, so
     * one call per buffer is enough. */
    hal_clear(0);
    hal_swap();
    hal_clear(0);
    hal_swap();

    map_init(m);
    player_init(p, 1, 1, 0);

    raycast_render(p, m);
    hal_swap();

    for (;;) {
        int ch = hal_getchar();
        if (ch == 'q' || ch == 'Q') break;

        u32 input = 0;
        switch (ch) {
            case 'w': case 'W': input = INPUT_FORWARD;      break;
            case 's': case 'S': input = INPUT_BACK;         break;
            case 'a': case 'A': input = INPUT_TURN_LEFT;    break;
            case 'd': case 'D': input = INPUT_TURN_RIGHT;   break;
            case 'e': case 'E': input = INPUT_STRAFE_RIGHT; break;
            case 'r': case 'R': input = INPUT_STRAFE_LEFT;  break;
            default: continue;
        }

        player_update(p, m, input);
        raycast_render(p, m);
        hal_swap();
    }
    return 0;
}
