/*
 * platform/risc2/main.c — RISC2 platform layer for Tic-Tac-Toe
 *
 * Uses the character LCD overlay (lcd_char) for all display.
 * GPU3D is only used to clear the background to black.
 *
 * LCD char control registers (write):
 *   0x0C0000  window X position (11 bits)
 *   0x0C0001  window Y position (11 bits)
 *   0x0C0002  chars per row (8 bits)
 *   0x0C0003  enable (bit 15) + number of char rows (7 bits)
 *
 * LCD char text RAM (write):
 *   0x0E0000 + offset  character code (7 bits, IBM 8x16 font)
 *
 * UART: 0xF0002 status, 0xF0004 RX data
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ── GPU3D (just for clearing background) ───────────────────────────────── */
#define GPU_BASE        0x0A0000
#define GPU_REG(n)      (*(volatile unsigned int*)(GPU_BASE + (n)*4))
#define GPU_CLR_COLOR   GPU_REG(7)
#define GPU_CMD         GPU_REG(8)
#define GPU_STATUS      GPU_REG(9)

#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

/* ── LCD char control ───────────────────────────────────────────────────── */
#define LCD_CTRL(n)     (*(volatile unsigned int*)(0x0C0000 + (n)))
#define LCD_TEXT(n)     (*(volatile unsigned int*)(0x0E0000 + (n)))

/* ── UART ───────────────────────────────────────────────────────────────── */
#define IO_STATUS       (*(volatile unsigned int*)0xF0002)
#define IO_UART_RX      (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY      (1 << 0)

/* ── Back buffer (in data RAM) ──────────────────────────────────────────── */
/* We buffer writes and flush to text RAM in hal_swap() to avoid flicker.
 * Data RAM offset 0x100 to skip corrupted region (words 0-63). */
#define BUF_BASE        ((volatile unsigned int*)0x010100)
static volatile unsigned int *buf = BUF_BASE;

/* ── HAL implementation ─────────────────────────────────────────────────── */

void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        buf[row * LCD_COLS + col] = (unsigned int)ch;
}

void hal_clear(void)
{
    int i;
    int n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        buf[i] = ' ';
}

void hal_swap(void)
{
    int i;
    int n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        LCD_TEXT(i) = buf[i];
}

/* ── GPU helpers ────────────────────────────────────────────────────────── */

static void gpu_wait(void)
{
    while (GPU_STATUS & 1) { /* spin */ }
}

static void gpu_clear_black(void)
{
    gpu_wait();
    GPU_CLR_COLOR = 0;
    GPU_CMD = CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
    gpu_wait();
    GPU_CLR_COLOR = 0;
    GPU_CMD = CMD_CLEAR_FB;
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
}

/* ── LCD char setup ─────────────────────────────────────────────────────── */

static void lcd_char_init(void)
{
    LCD_CTRL(0) = 0;              /* x = 0 */
    LCD_CTRL(1) = 0;              /* y = 0 */
    LCD_CTRL(2) = LCD_COLS;       /* 32 chars per row */
    LCD_CTRL(3) = 0x8000 | LCD_ROWS; /* enable + 16 rows */
}

/* ── UART ───────────────────────────────────────────────────────────────── */

static int uart_getchar(void)
{
    while (!(IO_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(IO_UART_RX & 0xFF);
}

/* ── Game state ─────────────────────────────────────────────────────────── */
/* Place game_t after the text buffer in data RAM.
 * Buffer: 32*16 = 512 words at 0x010100..0x0108FF
 * Game state at 0x010900 */
#define GAME_PTR  ((game_t*)0x010900)

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(void)
{
    game_t *g = GAME_PTR;
    int ch;

    gpu_clear_black();
    lcd_char_init();

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
