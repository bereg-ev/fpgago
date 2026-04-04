/*
 * raycast.c — integer DDA raycasting engine
 *
 * Algorithm overview per screen column:
 *   1. Compute ray direction from player angle + FOV offset.
 *   2. DDA: advance through map cells until a wall is hit.
 *   3. Perpendicular distance = accumulated side distance before last step
 *      (avoids fisheye without trigonometric correction).
 *   4. Wall strip height = PROJ_DIST * SCREEN_H / perp_dist.
 *   5. Texture column selected from the hit position's fractional part.
 *   6. Texture row advanced with fixed-point step (no per-pixel division).
 *
 * All arithmetic is 32-bit integer (+ 64-bit intermediate in FIXED_MUL).
 *
 * FPGA PORTING NOTE:
 *   The main hot-path bottleneck for a minimal soft CPU is likely
 *   FIXED_MUL (64-bit intermediate). If unsupported in hardware,
 *   replace with a software routine or reduce to Q8.8 where range allows.
 *   Consider replacing the wall_h division with a 128-entry lookup table
 *   indexed by FIXED_TO_INT(perp_dist).
 */

#include "raycast.h"
#include "texture.h"
#include "trig.h"

/* Sentinel: infinity for DDA when ray component is zero */
#define FIXED_INF   0x7FFFFFFF

static u32 shade_dark(u32 color)
{
    /* Y-face (north/south) walls at 50% brightness */
    return ((color >> 1) & 0x007F7F7FU);
}

void raycast_render(u32 *pixels, const player_t *p, const map_t *m)
{
    int col;

    for (col = 0; col < SCREEN_W; col++)
    {
        /* ------------------------------------------------------------------ */
        /* 1. Ray angle                                                        */
        /* ------------------------------------------------------------------ */
        int col_offset = (col * FOV_ANGLES) / SCREEN_W - HALF_FOV;
        int ray_angle  = angle_wrap(p->angle + col_offset);

        fixed_t ray_dx = cos_table[ray_angle];
        fixed_t ray_dy = sin_table[ray_angle];

        /* ------------------------------------------------------------------ */
        /* 2. DDA initialisation                                               */
        /* ------------------------------------------------------------------ */

        /* Map cell the player is currently in */
        int map_x = FIXED_TO_INT(p->x);
        int map_y = FIXED_TO_INT(p->y);

        /* Distance along the ray between consecutive x / y cell boundaries */
        fixed_t delta_x = (ray_dx == 0) ? FIXED_INF
                                         : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dx));
        fixed_t delta_y = (ray_dy == 0) ? FIXED_INF
                                         : FIXED_ABS(FIXED_DIV(FIXED_ONE, ray_dy));

        /* Step direction and initial side distances */
        int     step_x, step_y;
        fixed_t side_x, side_y;

        fixed_t frac_x = FIXED_FRAC(p->x);   /* fractional part of player x */
        fixed_t frac_y = FIXED_FRAC(p->y);

        if (ray_dx < 0)
        {
            step_x = -1;
            side_x = FIXED_MUL(frac_x, delta_x);
        }
        else
        {
            step_x = 1;
            side_x = FIXED_MUL(FIXED_ONE - frac_x, delta_x);
        }

        if (ray_dy < 0)
        {
            step_y = -1;
            side_y = FIXED_MUL(frac_y, delta_y);
        }
        else
        {
            step_y = 1;
            side_y = FIXED_MUL(FIXED_ONE - frac_y, delta_y);
        }

        /* ------------------------------------------------------------------ */
        /* 3. DDA walk until wall hit                                          */
        /* ------------------------------------------------------------------ */
        int hit_side = 0;   /* 0 = X-face, 1 = Y-face */

        for (;;)
        {
            if (side_x < side_y)
            {
                side_x += delta_x;
                map_x  += step_x;
                hit_side = 0;
            }
            else
            {
                side_y += delta_y;
                map_y  += step_y;
                hit_side = 1;
            }

            if (map_is_wall(m, map_x, map_y))
                break;
        }

        /* ------------------------------------------------------------------ */
        /* 4. Perpendicular distance (fisheye correction)                     */
        /* ------------------------------------------------------------------ */
        fixed_t ray_dist;
        if (hit_side == 0)
            ray_dist = side_x - delta_x;
        else
            ray_dist = side_y - delta_y;

        fixed_t perp_dist = FIXED_MUL(ray_dist, cos_table[angle_wrap(col_offset)]);

        /* Guard against zero / very small distance */
        if (perp_dist < 256) perp_dist = 256;

        /* ------------------------------------------------------------------ */
        /* 5. Wall strip height                                                */
        /* ------------------------------------------------------------------ */
        int wall_h = (int)(((int64_t)SCREEN_H << FIXED_SHIFT) / (int64_t)perp_dist);
        if (wall_h < 1) wall_h = 1;

        int wall_top    = (SCREEN_H - wall_h) / 2;
        int wall_bottom = wall_top + wall_h;

        /* Clamp draw range to screen; keep true wall_h for texture mapping */
        int draw_top    = wall_top    < 0        ? 0        : wall_top;
        int draw_bottom = wall_bottom > SCREEN_H ? SCREEN_H : wall_bottom;

        /* ------------------------------------------------------------------ */
        /* 6. Texture X coordinate                                             */
        /* ------------------------------------------------------------------ */
        fixed_t wall_hit;

        if (hit_side == 0)
            wall_hit = p->y + FIXED_MUL(ray_dist, ray_dy);
        else
            wall_hit = p->x + FIXED_MUL(ray_dist, ray_dx);

        /* Fractional part → texture column 0..TEX_W-1 */
        int tex_x = (int)(((u32)FIXED_FRAC(wall_hit) * (u32)TEX_W) >> 16);

        /* Mirror to keep texture orientation correct for all ray directions */
        if (hit_side == 0 && ray_dx > 0) tex_x = TEX_W - 1 - tex_x;
        if (hit_side == 1 && ray_dy < 0) tex_x = TEX_W - 1 - tex_x;

        if (tex_x < 0)       tex_x = 0;
        if (tex_x >= TEX_W)  tex_x = TEX_W - 1;

        /* ------------------------------------------------------------------ */
        /* 7. Draw column                                                      */
        /* ------------------------------------------------------------------ */
        int y;
        u32 *dst = pixels + col;   /* column pointer, stride = SCREEN_W */

        /* Ceiling */
        for (y = 0; y < draw_top; y++)
            dst[y * SCREEN_W] = COLOR_CEILING;

        /* Textured wall strip — use true wall_h for correct texture scale   */
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

                u32 color = brick_texture[tex_y * TEX_W + tex_x];

                /* Y-face hits (north/south walls) are darker */
                if (hit_side == 1)
                    color = shade_dark(color);

                dst[y * SCREEN_W] = color;
                tex_pos += tex_step;
            }
        }

        /* Floor */
        for (y = draw_bottom; y < SCREEN_H; y++)
            dst[y * SCREEN_W] = COLOR_FLOOR;
    }
}
