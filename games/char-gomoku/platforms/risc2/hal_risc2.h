/*
 * hal_risc2.h — RISC2 platform lifecycle for the character HAL.
 *
 * The character HAL primitives (hal_clear / hal_putchar / hal_swap) declared
 * in hal.h are implemented in hal_risc2.c.  hal_risc2_init() configures the
 * LCD-char overlay, uploads custom 8x16 glyph bitmaps to the font ROM, and
 * blanks the pixel framebuffer to black behind the text layer.
 */

#ifndef HAL_RISC2_H
#define HAL_RISC2_H

void hal_risc2_init(void);

#endif /* HAL_RISC2_H */
