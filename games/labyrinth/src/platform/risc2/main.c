/*
 * platform/risc2/main.c — RISC2 platform layer for Labyrinth
 *
 * Bare-metal: UART input, dcache scanline rendering.
 */

#include "../../engine/fixed.h"
#include "../../engine/trig.h"
#include "../../engine/player.h"
#include "../../engine/map.h"

/* UART / IO registers */
#define IO_STATUS       (*(volatile unsigned int*)0xF0002)
#define IO_UART_TX      (*(volatile unsigned int*)0xF0003)
#define IO_UART_RX      (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY      (1 << 0)
#define UART_TXBUSY     (1 << 2)

/* dcache framebuffer interface */
#define FB_BUF(c)       (*(volatile unsigned int*)(0x200000 + (c)*4))
#define FB_ROW          (*(volatile unsigned int*)0x0A0000)
#define FB_CLR_COLOR    (*(volatile unsigned int*)0x0A001C)
#define FB_CMD          (*(volatile unsigned int*)0x0A0020)
#define FB_STATUS       (*(volatile unsigned int*)0x0A0024)

#define CMD_FLUSH        1
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

#define SCREEN_W 480
#define SCREEN_H 272

static void fb_wait(void) { while (FB_STATUS & 1) {} }

/* Raycaster (in raycast_risc2.c) */
void raycast_render(const player_t *p, const map_t *m);

/* Game state above dcache corruption zone (words 0-479) */
#define PLAYER_PTR  ((player_t*)0x010780)
#define MAP_PTR     ((map_t*)0x010790)

static int uart_try_getchar(void)
{
    if (IO_STATUS & UART_RXRDY)
        return (int)(IO_UART_RX & 0xFF);
    return 0;
}

int main(void)
{
    player_t *p = PLAYER_PTR;
    map_t *m = MAP_PTR;

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
