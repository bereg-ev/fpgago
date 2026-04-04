/*
 * hal.h — Hardware Abstraction Layer for Five-in-a-Row
 *
 * Three primitives sufficient for all 2-D rendering:
 *   hal_clear     — fill the back buffer with a solid colour
 *   hal_fill_rect — draw a filled axis-aligned rectangle
 *   hal_swap      — present the back buffer to the display
 *
 * Colour format: RGB565 (u16)
 *   bits 15-11  Red   (0-31)
 *   bits 10-5   Green (0-63)
 *   bits  4-0   Blue  (0-31)
 *
 * Platform implementations:
 *   SDL2  : software u16 framebuffer, SDL_UpdateTexture + SDL_RenderPresent
 *   RISC2 : GPU3D triangle rasterizer (two triangles per rectangle)
 */

#ifndef HAL_H
#define HAL_H

#include <stdint.h>

typedef uint16_t u16;
typedef uint8_t  u8;

#define SCREEN_W 480
#define SCREEN_H 272

/* Pack 5-bit R, 6-bit G, 5-bit B into RGB565 */
#define RGB565(r,g,b)  ((u16)(((r)<<11)|((g)<<5)|(b)))

/* Fill the entire back buffer with colour c */
void hal_clear(u16 c);

/* Fill a rectangle with colour c.
   x, y : top-left corner (0-based screen pixels)
   w, h : width and height in pixels
   Clips silently to screen bounds. */
void hal_fill_rect(int x, int y, int w, int h, u16 c);

/* Present the back buffer (flip/blit to display) */
void hal_swap(void);

#endif /* HAL_H */
