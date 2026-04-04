/*
 * raycast_risc2.c — Textured DDA raycaster for RISC2 dcache
 *
 * 120 rays × 4px wide, 68 virtual rows × 4px tall = 480×272.
 * 16×16 embedded brick texture in RGB565.
 *
 * Each virtual row: cast all 120 rays, compute texture color,
 * store 120 colors in COLBUF, then fill+flush PIXEL_H physical rows.
 */

#include "../../engine/fixed.h"
#include "../../engine/trig.h"
#include "../../engine/player.h"
#include "../../engine/map.h"

/* dcache framebuffer interface */
#define FB_BUF(c)       (*(volatile unsigned int*)(0x200000 + (c)*4))
#define FB_ROW          (*(volatile unsigned int*)0x0A0000)
#define FB_CLR_COLOR    (*(volatile unsigned int*)0x0A001C)
#define FB_CMD          (*(volatile unsigned int*)0x0A0020)
#define FB_STATUS       (*(volatile unsigned int*)0x0A0024)

#define CMD_FLUSH        1
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

#define SCREEN_W    480
#define SCREEN_H    272

#define RAY_COUNT   120
#define COL_WIDTH   4
#define VIRT_H      68
#define PIXEL_H     4

#define FOV_ANGLES  341
#define HALF_FOV    (FOV_ANGLES / 2)

#define TEX_SIZE    16

#define COL_CEILING   0x2105
#define COL_FLOOR     0x4A48

#define FIXED_INF   0x7FFFFFFF

static void fb_wait(void) { while (FB_STATUS & 1) { } }

/* 16x16 brick texture in RGB565 */
static const int brick_tex[16 * 16] = {
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x81C3, 0x89C3, 0x4208, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89E3, 0x4208, 0x91E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x89C3, 0x81C3, 0x4208, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x91E3, 0x4208, 0x91E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x89C3, 0x89C3, 0x4208, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x91E3, 0x4208, 0x89E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x89C3, 0x89C3, 0x4208, 0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x91E3, 0x4208, 0x91E3, 0x89E3,
    0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208,
    0x81A3, 0x81A3, 0x81A3, 0x4208, 0x89C3, 0x89C3, 0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x4208, 0x89C3, 0x91E3, 0x91E3, 0x89E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x4208, 0x89C3, 0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x4208, 0x89C3, 0x91E3, 0x89E3, 0x91E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x4208, 0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x4208, 0x89C3, 0x89E3, 0x91E3, 0x91E3, 0x91E3,
    0x91E3, 0x91E3, 0x91E3, 0x4208, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x4208, 0x81C3, 0x81A3, 0x81A3, 0x81A3, 0x81A3,
    0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208,
    0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x81A3, 0x81A3, 0x4208, 0x81A3, 0x89E3, 0x91E3, 0x91E3, 0x91E3, 0x89C3, 0x4208, 0x89C3, 0x89C3,
    0x89C3, 0x81C3, 0x89C3, 0x89C3, 0x81A3, 0x81A3, 0x4208, 0x81A3, 0x91E3, 0x89E3, 0x91E3, 0x91E3, 0x89C3, 0x4208, 0x89C3, 0x89C3,
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x89C3, 0x89C3, 0x4208, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x91E3, 0x4208, 0x89E3, 0x91E3,
    0x81A3, 0x81A3, 0x81A3, 0x81A3, 0x89C3, 0x89C3, 0x4208, 0x81C3, 0x89C3, 0x89C3, 0x89C3, 0x89C3, 0x91E3, 0x4208, 0x91E3, 0x89E3,
    0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208, 0x4208,
    0x89C3, 0x89C3, 0x89C3, 0x4208, 0x91E3, 0x91E3, 0x89E3, 0x91E3, 0x81A3, 0x81A3, 0x4208, 0x81A3, 0x89C3, 0x89C3, 0x81C3, 0x89C3,
};

static int shade_dark(int c) { return (c >> 1) & 0x7BEF; }

/* Color buffer: 120 entries above game data.
 * Map ends at word 742. Buffer at word 743 = 0x010B9C. 120 words → ends at 862. */
#define COLBUF  ((volatile int*)0x010B9C)

void raycast_render(const player_t *p, const map_t *m)
{
    int ray, y;

    /* Clear both buffers */
    fb_wait();
    FB_CLR_COLOR = 0;
    FB_CMD = CMD_CLEAR_FB;
    fb_wait();
    FB_CMD = CMD_SWAP_BUFFERS;
    fb_wait();
    FB_CMD = CMD_CLEAR_FB;
    fb_wait();

    for (y = 0; y < VIRT_H; y++)
    {
        int phys_y = y * PIXEL_H + PIXEL_H / 2;
        int half   = SCREEN_H / 2;

        /* Cast all rays and compute textured color for this virtual row */
        for (ray = 0; ray < RAY_COUNT; ray++)
        {
            int col_offset = (ray * FOV_ANGLES) / RAY_COUNT - HALF_FOV;
            int ray_angle  = angle_wrap(p->angle + col_offset);

            fixed_t ray_dx = cos_table[ray_angle];
            fixed_t ray_dy = sin_table[ray_angle];

            int map_x = FIXED_TO_INT(p->x);
            int map_y = FIXED_TO_INT(p->y);

            fixed_t delta_x = (ray_dx == 0) ? FIXED_INF : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dx));
            fixed_t delta_y = (ray_dy == 0) ? FIXED_INF : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dy));

            int step_x, step_y;
            fixed_t side_x, side_y;
            fixed_t frac_x = FIXED_FRAC(p->x);
            fixed_t frac_y = FIXED_FRAC(p->y);

            if (ray_dx < 0) { step_x = -1; side_x = FIXED_MUL(frac_x, delta_x); }
            else             { step_x =  1; side_x = FIXED_MUL(FIXED_ONE - frac_x, delta_x); }
            if (ray_dy < 0) { step_y = -1; side_y = FIXED_MUL(frac_y, delta_y); }
            else             { step_y =  1; side_y = FIXED_MUL(FIXED_ONE - frac_y, delta_y); }

            int hit_side = 0, steps = 0;
            for (;;) {
                if (side_x < side_y) { side_x += delta_x; map_x += step_x; hit_side = 0; }
                else                 { side_y += delta_y; map_y += step_y; hit_side = 1; }
                if (map_is_wall(m, map_x, map_y)) break;
                if (++steps > 64) break;
            }

            fixed_t ray_dist = (hit_side == 0) ? side_x - delta_x : side_y - delta_y;
            fixed_t perp_dist = FIXED_MUL(ray_dist, cos_table[angle_wrap(col_offset)]);
            if (perp_dist < 256) perp_dist = 256;

            int wall_h = (SCREEN_H * FIXED_ONE) / perp_dist;
            if (wall_h > SCREEN_H * 2) wall_h = SCREEN_H * 2;

            int wall_top = (SCREEN_H - wall_h) / 2;
            int wall_bot = wall_top + wall_h;
            int draw_top = wall_top < 0        ? 0        : wall_top;
            int draw_bot = wall_bot > SCREEN_H ? SCREEN_H : wall_bot;

            int color;
            if (phys_y >= draw_top && phys_y < draw_bot)
            {
                /* Texture coordinates */
                fixed_t wall_hit;
                if (hit_side == 0)
                    wall_hit = p->y + FIXED_MUL(ray_dist, ray_dy);
                else
                    wall_hit = p->x + FIXED_MUL(ray_dist, ray_dx);

                int tex_x = (FIXED_FRAC(wall_hit) * TEX_SIZE) >> 16;
                if (hit_side == 0 && ray_dx > 0) tex_x = TEX_SIZE - 1 - tex_x;
                if (hit_side == 1 && ray_dy < 0) tex_x = TEX_SIZE - 1 - tex_x;
                if (tex_x < 0) tex_x = 0;
                if (tex_x >= TEX_SIZE) tex_x = TEX_SIZE - 1;

                int tex_y = 0;
                if (wall_h > 0)
                    tex_y = ((phys_y - wall_top) * TEX_SIZE) / wall_h;
                if (tex_y < 0) tex_y = 0;
                if (tex_y >= TEX_SIZE) tex_y = TEX_SIZE - 1;

                color = brick_tex[tex_y * TEX_SIZE + tex_x];
                if (hit_side) color = shade_dark(color);
            }
            else if (phys_y < half)
                color = COL_CEILING;
            else
                color = COL_FLOOR;

            COLBUF[ray] = color;
        }

        /* Fill and flush PIXEL_H physical rows from COLBUF */
        {
            int py_start = y * PIXEL_H;
            int py_end   = py_start + PIXEL_H;
            int py;
            if (py_end > SCREEN_H) py_end = SCREEN_H;

            for (py = py_start; py < py_end; py++)
            {
                for (ray = 0; ray < RAY_COUNT; ray++)
                {
                    int px = ray * COL_WIDTH;
                    int color = COLBUF[ray];
                    int c;
                    for (c = 0; c < COL_WIDTH; c++)
                        FB_BUF(px + c) = color;
                }
                FB_ROW = py;
                FB_CMD = CMD_FLUSH;
                fb_wait();
            }
        }
    }

    fb_wait();
    FB_CMD = CMD_SWAP_BUFFERS;
}
