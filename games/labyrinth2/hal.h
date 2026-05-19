/*
 * hal.h — pixel-FB HAL for Labyrinth2.
 *
 * Same surface as gomoku/chess plus hal_blit_row() for streaming a full
 * scanline of pixels into the back buffer.  RGB565 throughout; the
 * framebuffer is exactly 480×272 on every arch (SDL2 scales 2× in its
 * window, so the visual size is identical to the real LCD).
 */

#ifndef HAL_H
#define HAL_H

#include <stdint.h>

typedef uint16_t u16;
typedef uint8_t  u8;
typedef int32_t  i32;
typedef uint32_t u32;

#define SCREEN_W  480
#define SCREEN_H  272

#define RGB565(r,g,b)  ((u16)(((r)<<11)|((g)<<5)|(b)))

void hal_init(void);
int  hal_getchar(void);
void hal_clear(u16 c);
void hal_fill_rect(int x, int y, int w, int h, u16 c);
void hal_blit_row(int row, const u16 *pixels);
void hal_swap(void);

#ifndef GAME_TITLE
#define GAME_TITLE "Labyrinth2"
#endif

#endif /* HAL_H */
