/*
 * raycast.c — riscv-darkrv platform: 16bpp RGB565 raycaster.
 *
 * Same DDA algorithm as games/labyrinth/platforms/sdl2/raycast.c, retyped
 * to write u16 (RGB565) pixels directly into a flat framebuffer.  Project
 * convention is 16bpp; the 32bpp SDL2 path was an outlier.
 *
 * Pixel layout: pixels[y * SCREEN_W + x] = RGB565
 *               (R[4:0]=bits 15..11, G[5:0]=bits 10..5, B[4:0]=bits 4..0)
 */

#include "fixed.h"
#include "player.h"
#include "map.h"
#include "trig.h"

#define SCREEN_W    480
#define SCREEN_H    272
#define FOV_ANGLES  341
#define HALF_FOV    (FOV_ANGLES / 2)
#define TEX_W       64
#define TEX_H       64

/* RGB565 versions of the ceiling/floor colours from raycast.h (32bpp 0x202028
 * and 0x484840 packed into 5-6-5). */
#define COLOR_CEILING_565   0x2105
#define COLOR_FLOOR_565     0x4A48

/* Sentinel: infinity for DDA when ray component is zero */
#define FIXED_INF   0x7FFFFFFF

extern u16 brick_texture16[TEX_W * TEX_H];

/* Y-face (north/south) walls at 50% brightness — halve each RGB565 channel.
 * Mask 0x7BEF = drop the LSB of each of R[4:0], G[5:0], B[4:0]. */
static u16 shade_dark(u16 color)
{
    return (color >> 1) & 0x7BEFU;
}

void raycast_render16(u16 *pixels, const player_t *p, const map_t *m)
{
    int col;

    for (col = 0; col < SCREEN_W; col++)
    {
        int col_offset = (col * FOV_ANGLES) / SCREEN_W - HALF_FOV;
        int ray_angle  = angle_wrap(p->angle + col_offset);

        fixed_t ray_dx = cos_table[ray_angle];
        fixed_t ray_dy = sin_table[ray_angle];

        int map_x = FIXED_TO_INT(p->x);
        int map_y = FIXED_TO_INT(p->y);

        fixed_t delta_x = (ray_dx == 0) ? FIXED_INF
                                        : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dx));
        fixed_t delta_y = (ray_dy == 0) ? FIXED_INF
                                        : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dy));

        int     step_x, step_y;
        fixed_t side_x, side_y;
        fixed_t frac_x = FIXED_FRAC(p->x);
        fixed_t frac_y = FIXED_FRAC(p->y);

        if (ray_dx < 0) { step_x = -1; side_x = FIXED_MUL(frac_x,             delta_x); }
        else            { step_x =  1; side_x = FIXED_MUL(FIXED_ONE - frac_x, delta_x); }

        if (ray_dy < 0) { step_y = -1; side_y = FIXED_MUL(frac_y,             delta_y); }
        else            { step_y =  1; side_y = FIXED_MUL(FIXED_ONE - frac_y, delta_y); }

        int hit_side = 0;
        for (;;)
        {
            if (side_x < side_y) { side_x += delta_x; map_x += step_x; hit_side = 0; }
            else                 { side_y += delta_y; map_y += step_y; hit_side = 1; }
            if (map_is_wall(m, map_x, map_y)) break;
        }

        fixed_t ray_dist  = (hit_side == 0) ? (side_x - delta_x) : (side_y - delta_y);
        fixed_t perp_dist = FIXED_MUL(ray_dist, cos_table[angle_wrap(col_offset)]);
        if (perp_dist < 256) perp_dist = 256;

        int wall_h = (int)(((int64_t)SCREEN_H << FIXED_SHIFT) / (int64_t)perp_dist);
        if (wall_h < 1) wall_h = 1;

        int wall_top    = (SCREEN_H - wall_h) / 2;
        int wall_bottom = wall_top + wall_h;
        int draw_top    = wall_top    < 0        ? 0        : wall_top;
        int draw_bottom = wall_bottom > SCREEN_H ? SCREEN_H : wall_bottom;

        fixed_t wall_hit = (hit_side == 0)
            ? p->y + FIXED_MUL(ray_dist, ray_dy)
            : p->x + FIXED_MUL(ray_dist, ray_dx);

        int tex_x = (int)(((u32)FIXED_FRAC(wall_hit) * (u32)TEX_W) >> 16);
        if (hit_side == 0 && ray_dx > 0) tex_x = TEX_W - 1 - tex_x;
        if (hit_side == 1 && ray_dy < 0) tex_x = TEX_W - 1 - tex_x;
        if (tex_x < 0)       tex_x = 0;
        if (tex_x >= TEX_W)  tex_x = TEX_W - 1;

        u16 *dst = pixels + col;     /* column pointer, stride = SCREEN_W */

        /* Ceiling */
        int y;
        for (y = 0; y < draw_top; y++)
            dst[y * SCREEN_W] = COLOR_CEILING_565;

        /* Textured wall strip */
        {
            fixed_t tex_step = (fixed_t)(((int64_t)TEX_H << FIXED_SHIFT)
                                         / (int64_t)wall_h);
            fixed_t tex_pos  = (fixed_t)((int64_t)(draw_top - wall_top)
                                         * (int64_t)tex_step);

            for (y = draw_top; y < draw_bottom; y++)
            {
                int tex_y = FIXED_TO_INT(tex_pos);
                if (tex_y < 0)      tex_y = 0;
                if (tex_y >= TEX_H) tex_y = TEX_H - 1;

                u16 color = brick_texture16[tex_y * TEX_W + tex_x];
                if (hit_side == 1) color = shade_dark(color);

                dst[y * SCREEN_W] = color;
                tex_pos += tex_step;
            }
        }

        /* Floor */
        for (y = draw_bottom; y < SCREEN_H; y++)
            dst[y * SCREEN_W] = COLOR_FLOOR_565;
    }
}
