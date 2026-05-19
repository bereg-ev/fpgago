/*
 * hal.h — Hardware Abstraction Layer for character LCD games
 *
 * Character LCD: 32 columns x 16 rows
 * Platform implementations provide these primitives.
 *
 * RISC2 note: all parameters are int (no char/byte types)
 * to avoid byte-load instructions unsupported by the RISC2 LLVM backend.
 */

#ifndef HAL_H
#define HAL_H

#define LCD_COLS  32
#define LCD_ROWS  16

/* One-shot platform bring-up. */
void hal_init(void);

/* Blocking input read. */
int  hal_getchar(void);

/* Set character at (col, row). ch is ASCII code as int. */
void hal_putc(int col, int row, int ch);

/* Clear entire screen with spaces */
void hal_clear(void);

/* Present the back buffer to the display */
void hal_swap(void);

/* Overwrite a font-ROM slot (8x16 bitmap, 16 bytes top-to-bottom, MSB-left).
 * Tic-tac-toe doesn't currently use this, but declaring it here lets the
 * shared char-LCD arch HAL files compile against a single hal.h shape. */
void hal_upload_glyph(int slot, const unsigned char *bitmap);

/* Window title used by the SDL2 sim — ignored on FPGA. */
#ifndef GAME_TITLE
#define GAME_TITLE "Tic-Tac-Toe"
#endif

#endif /* HAL_H */
