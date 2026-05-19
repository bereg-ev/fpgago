/*
 * hal_char.c — Shared riscv-darkrv implementation of the character HAL.
 *
 * Used by all games that include the char-LCD hal.h (hal_clear / hal_putc /
 * hal_swap on a 32×16 text grid): tic-tac-toe, char-gomoku, and anything
 * that follows the same pattern.  Each game's platforms/riscv-darkrv/
 * Makefile just adds $(ARCH_DIR)/hal_char.c to GAME_SRCS.
 *
 * Backend: in sim, soc.v exposes a 32×16 u32 text RAM at
 * MEM_LCD_CHAR_TEXT_BASE and a 1024-entry font RAM at
 * MEM_LCD_CHAR_FONT_BASE.  sim_top.cpp peeks both every frame and
 * rasterises the chars onto the SDL window.  Config registers
 * (LCD_CHAR_X/Y/NUMX/CONFIG) position the overlay.
 */

#include "hal.h"
#include "memmap.h"

/* Bridge across the two char-LCD games' hal.h flavours:
 *   tic-tac-toe : LCD_COLS / LCD_ROWS  + hal_putc
 *   char-gomoku : TEXT_COLS / TEXT_ROWS + hal_putchar  (uses centred window)
 */
#if defined(LCD_COLS)
  #define HAL_COLS  LCD_COLS
  #define HAL_ROWS  LCD_ROWS
#else
  #define HAL_COLS  TEXT_COLS
  #define HAL_ROWS  TEXT_ROWS
#endif

/* Byte-addressed: LCD_TEXT(n) writes one cell at byte offset n
 * (matches risc2's HAL macro, which deliberately omits the *4). */
#define LCD_TEXT(n)  (*(volatile uint32_t*)(MEM_LCD_CHAR_TEXT_BASE + (n)))
#define CHR_ROM(n)   (*(volatile uint32_t*)(MEM_LCD_CHAR_FONT_BASE + (n)))

static void gpu_wait(void)
{
    while (GPU_STATUS & GPU_STATUS_BUSY) { /* spin */ }
}

/* Back-buffer in BRAM scratch, same as risc2 (LCD is 32×16 = 512 cells). */
#define BUF_BASE  ((volatile uint32_t*)(MEM_BRAM_BASE + 0x100u))
static volatile uint32_t *buf = BUF_BASE;

static void put_cell(int col, int row, int ch)
{
    if (col >= 0 && col < HAL_COLS && row >= 0 && row < HAL_ROWS)
        buf[row * HAL_COLS + col] = (uint32_t)ch;
}

/* Both spellings exposed; only one is used by any given game. */
void hal_putc   (int col, int row, int ch) { put_cell(col, row, ch); }
void hal_putchar(int col, int row, int ch) { put_cell(col, row, ch); }

void hal_clear(void)
{
    int i;
    int n = HAL_COLS * HAL_ROWS;
    for (i = 0; i < n; i++)
        buf[i] = ' ';
}

void hal_swap(void)
{
    int i;
    int n = HAL_COLS * HAL_ROWS;
    for (i = 0; i < n; i++)
        LCD_TEXT(i) = buf[i];
    /* Tell the sim harness to refresh the SDL window. */
    FRAME_READY = 1;
}

/* One-shot lifecycle: clear the pixel FB behind the text and enable the
 * overlay.  For char-gomoku's narrower window (34 cols), centre it on
 * the 480-wide LCD.  Called once from main(). */
void hal_init(void)
{
    int x_offset = (480 - HAL_COLS * 8) / 2;
    if (x_offset < 0) x_offset = 0;

    gpu_wait();
    GPU_CLEAR_COLOR = 0;        /* black background behind chars */
    GPU_CMD         = GPU_CMD_CLEAR_FB;
    gpu_wait();

    LCD_CHAR_X      = x_offset;
    LCD_CHAR_Y      = 0;
    LCD_CHAR_NUMX   = HAL_COLS;
    LCD_CHAR_CONFIG = 0x8000u | HAL_ROWS;  /* enable + row count */
}

int hal_getchar(void)
{
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}

/* Overwrite one glyph in font ROM.  `slot` is the 0..127 font index the
 * hardware looks up when a text cell holds that value; `bitmap[i]` is row i
 * (top→bottom), each byte = 8 horizontal pixels (MSB = leftmost).  Two
 * adjacent rows pack into one 16-bit word: low byte = even row, high byte =
 * odd row.  Each glyph occupies 8 packed entries. */
void hal_upload_glyph(int slot, const unsigned char *bitmap)
{
    int idx = slot & 0x7F;
    int i;
    for (i = 0; i < 8; i++) {
        uint32_t even = bitmap[i * 2];
        uint32_t odd  = bitmap[i * 2 + 1];
        CHR_ROM(idx * 8 + i) = (odd << 8) | even;
    }
}
