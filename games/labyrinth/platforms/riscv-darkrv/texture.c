/*
 * texture.c — riscv-darkrv platform: 16bpp RGB565 brick texture.
 *
 * Identical procedural algorithm to platforms/sdl2/texture.c, just packed
 * to RGB565 instead of 0x00RRGGBB.
 */

#include "fixed.h"

#define TEX_W   64
#define TEX_H   64

u16 brick_texture16[TEX_W * TEX_H];

/* Brick parameters (all in pixels, TEX_W=64, TEX_H=64) */
#define BRICK_H         10
#define MORTAR_H         2
#define BRICK_W         20
#define MORTAR_W         2
#define STAGGER         11

#define MORTAR_R  0x40
#define MORTAR_G  0x40
#define MORTAR_B  0x40

#define BRICK_BASE_R  0x8B
#define BRICK_BASE_G  0x3A
#define BRICK_BASE_B  0x1E

static u16 rgb565(int r, int g, int b)
{
    if (r < 0) r = 0; if (r > 255) r = 255;
    if (g < 0) g = 0; if (g > 255) g = 255;
    if (b < 0) b = 0; if (b > 255) b = 255;
    return (u16)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

void texture_init(void)
{
    int x, y;
    int row, col_pos, stagger;
    int in_mortar_h, in_mortar_v;
    int variation;
    u16 color;

    const u16 mortar565 = rgb565(MORTAR_R, MORTAR_G, MORTAR_B);

    for (y = 0; y < TEX_H; y++)
    {
        row         = y / BRICK_H;
        in_mortar_h = ((y % BRICK_H) >= (BRICK_H - MORTAR_H)) ? 1 : 0;
        stagger     = (row & 1) ? STAGGER : 0;

        for (x = 0; x < TEX_W; x++)
        {
            if (in_mortar_h)
            {
                color = mortar565;
            }
            else
            {
                col_pos     = (x + stagger) % (BRICK_W + MORTAR_W);
                in_mortar_v = (col_pos >= BRICK_W) ? 1 : 0;

                if (in_mortar_v)
                {
                    color = mortar565;
                }
                else
                {
                    variation = ((x ^ y ^ (row * 7)) & 0x0F) - 8;
                    int r = BRICK_BASE_R + variation;
                    int g = BRICK_BASE_G + (variation >> 1);
                    int b = BRICK_BASE_B + (variation >> 2);
                    color = rgb565(r, g, b);
                }
            }

            brick_texture16[y * TEX_W + x] = color;
        }
    }
}
