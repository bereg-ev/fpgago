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

/* Set character at (col, row). ch is ASCII code as int. */
void hal_putc(int col, int row, int ch);

/* Clear entire screen with spaces */
void hal_clear(void);

/* Present the back buffer to the display */
void hal_swap(void);

#endif /* HAL_H */
