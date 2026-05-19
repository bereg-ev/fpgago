/*
 * glyphs.h — Char-Gomoku custom font setup.
 *
 * Char-Gomoku displays its 15×15 board as 16×16-pixel cells, each made of a
 * left and right 8×16 character glyph that carry built-in grid borders.  The
 * stock lcd_char font (IBM 8x16) doesn't contain these — game_init_glyphs()
 * builds them procedurally and uploads them via hal_upload_glyph().
 *
 * Must be called once, after hal_init() (which loads the default font) and
 * before the first render_frame().  Called from main().
 */

#ifndef GLYPHS_H
#define GLYPHS_H

void game_init_glyphs(void);

#endif /* GLYPHS_H */
