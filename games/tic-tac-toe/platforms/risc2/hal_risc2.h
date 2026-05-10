/*
 * hal_risc2.h — RISC2 platform lifecycle for the Tic-Tac-Toe character HAL.
 *
 * The character HAL primitives (hal_clear / hal_putc / hal_swap) declared in
 * hal.h are implemented in hal_risc2.c.  hal_risc2_init() configures the
 * lcd_char overlay and blanks the pixel framebuffer behind it.
 */

#ifndef HAL_RISC2_H
#define HAL_RISC2_H

void hal_risc2_init(void);

#endif /* HAL_RISC2_H */
