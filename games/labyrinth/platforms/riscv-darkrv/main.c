/*
 * main.c — DarkRISCV labyrinth entry point.
 *
 * The engine (raycast.c / trig.c / player.c) writes pixels directly into
 * a flat framebuffer at FB_BASE.  After each frame, FRAME_READY is poked so
 * the Verilator sim refreshes its SDL2 window.
 *
 * Controls (read from UART_RX):
 *   w / W  forward     a / A  turn left
 *   s / S  back        d / D  turn right
 *   q / Q  strafe L    e / E  strafe R
 */

#include "memmap.h"
#include "fixed.h"
#include "trig.h"
#include "map.h"
#include "player.h"

/* Local 16bpp engine — overrides the shared 32bpp raycast.h / texture.h. */
extern void texture_init(void);
extern void raycast_render16(u16 *pixels, const player_t *p, const map_t *m);

/* Map_load implementation lives here (bare-metal, hardcoded map). */
int map_load(map_t *m, const void *unused);

static int uart_try_getchar(void)
{
    if (UART_STATUS & UART_RXRDY)
        return (int)(UART_RX & 0xFF);
    return -1;
}

static void uart_putc(char c) { UART_TX = (uint8_t)c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

int main(void)
{
    static map_t    g_map;
    static player_t g_player;

    uart_puts("boot\n");
    trig_init();        uart_puts("trig\n");
    texture_init();     uart_puts("tex\n");
    map_load(&g_map, 0); uart_puts("map\n");
    player_init(&g_player, 1, 1, 0); uart_puts("player\n");

    /* First render */
    uart_puts("render\n");
    raycast_render16((u16 *)FB_BASE, &g_player, &g_map);
    uart_puts("frame\n");
    FRAME_READY = 1;

    for (;;) {
        int ch = uart_try_getchar();
        if (ch < 0) continue;

        u32 input = 0;
        if (ch == 'w' || ch == 'W') input |= INPUT_FORWARD;
        if (ch == 's' || ch == 'S') input |= INPUT_BACK;
        if (ch == 'a' || ch == 'A') input |= INPUT_TURN_LEFT;
        if (ch == 'd' || ch == 'D') input |= INPUT_TURN_RIGHT;
        if (ch == 'q' || ch == 'Q') input |= INPUT_STRAFE_LEFT;
        if (ch == 'e' || ch == 'E') input |= INPUT_STRAFE_RIGHT;

        if (input) {
            player_update(&g_player, &g_map, input);
            raycast_render16((u16 *)FB_BASE, &g_player, &g_map);
            FRAME_READY = 1;
        }
    }

    return 0;
}
