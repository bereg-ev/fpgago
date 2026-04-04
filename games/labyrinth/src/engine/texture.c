/*
 * texture.c — procedural brick wall texture generator (integer-only)
 *
 * Layout (64x64):
 *   Brick rows are 10 pixels tall: 8px brick + 2px mortar.
 *   Even rows: bricks start at x=0, width=20px, gap=2px mortar.
 *   Odd  rows: bricks offset by 11px (half-brick stagger).
 *   Mortar colour: dark grey  0x404040
 *   Brick colour:  red-brown  0x8B3A1E  with a subtle noise via (x^y)
 */

#include "texture.h"

u32 brick_texture[TEX_W * TEX_H];

/* Brick parameters (all in pixels, TEX_W=64, TEX_H=64) */
#define BRICK_H         10   /* total row height including mortar */
#define MORTAR_H         2   /* mortar strip at bottom of each row */
#define BRICK_W         20   /* brick width */
#define MORTAR_W         2   /* mortar between bricks */
#define STAGGER         11   /* horizontal offset on odd rows */

#define MORTAR_COLOR    0x00404040U
#define BRICK_BASE_R    0x8B
#define BRICK_BASE_G    0x3A
#define BRICK_BASE_B    0x1E

void texture_init(void)
{
    int x, y;
    int row, col_pos, stagger;
    int in_mortar_h, in_mortar_v;
    u32 color;
    int variation;

    for (y = 0; y < TEX_H; y++)
    {
        row       = y / BRICK_H;
        in_mortar_h = ((y % BRICK_H) >= (BRICK_H - MORTAR_H)) ? 1 : 0;
        stagger   = (row & 1) ? STAGGER : 0;

        for (x = 0; x < TEX_W; x++)
        {
            if (in_mortar_h)
            {
                color = MORTAR_COLOR;
            }
            else
            {
                col_pos    = (x + stagger) % (BRICK_W + MORTAR_W);
                in_mortar_v = (col_pos >= BRICK_W) ? 1 : 0;

                if (in_mortar_v)
                {
                    color = MORTAR_COLOR;
                }
                else
                {
                    /* Slight variation based on position to break uniformity */
                    variation = ((x ^ y ^ (row * 7)) & 0x0F) - 8;

                    int r = BRICK_BASE_R + variation;
                    int g = BRICK_BASE_G + (variation >> 1);
                    int b = BRICK_BASE_B + (variation >> 2);

                    /* Clamp to [0, 255] */
                    if (r < 0) r = 0; if (r > 255) r = 255;
                    if (g < 0) g = 0; if (g > 255) g = 255;
                    if (b < 0) b = 0; if (b > 255) b = 255;

                    color = ((u32)r << 16) | ((u32)g << 8) | (u32)b;
                }
            }

            brick_texture[y * TEX_W + x] = color;
        }
    }
}
