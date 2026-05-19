/*
 * raycast.c — Row-major DDA raycaster.
 *
 * Algorithm shape that matches the hardware:
 *   Pass 1 — per-column DDA (480 columns).  Fills col_info[col] with the
 *            wall span, texture column, and a Q16.16 per-row tex_step.
 *            Each column does ~5 FIXED_MULs; total ~2400 muls/frame.
 *   Pass 2 — per-row composition (272 rows × 480 cols).  Walks col_info
 *            in row-major order, building a 480-pixel scratch buffer for
 *            each scanline, then calling hal_blit_row().  The hot inner
 *            loop is mul-free: tex_pos accumulates with adds, tex index
 *            uses shifts (TEX_W = 16 is a power of two).
 *
 * The two-pass split exists because the FPGA HAL flushes the back buffer
 * one full row at a time (FB_BUF[col] + GPU_ROW + GPU_CMD_FLUSH), whereas
 * a classical column-major raycaster would write to pixels[y*SCREEN_W+x]
 * directly.  Building a row buffer is the cheapest bridge.
 */

#include "raycast.h"
#include "hal.h"
#include "fixed.h"
#include "trig.h"
#include "texture.h"
#include "scratch.h"

#define FOV_ANGLES   341
#define HALF_FOV     (FOV_ANGLES / 2)

/* Per-column FOV offset table.
 *
 * Each entry is `(col * FOV_ANGLES) / SCREEN_W - HALF_FOV`.  Replacing the
 * runtime expression with a LUT removes one __mulsi3 + one __udivsi3 from
 * the per-column setup — together ~550 cycles on risc2 (no hardware
 * multiply or divide).  Stored as int so the load is a plain word access,
 * avoiding any halfword sign-extension helper on risc2's load path. */
static const int col_offset_lut[SCREEN_W] = {
    -170, -170, -169, -168, -168, -167, -166, -166,
    -165, -164, -163, -163, -162, -161, -161, -160,
    -159, -158, -158, -157, -156, -156, -155, -154,
    -153, -153, -152, -151, -151, -150, -149, -148,
    -148, -147, -146, -146, -145, -144, -144, -143,
    -142, -141, -141, -140, -139, -139, -138, -137,
    -136, -136, -135, -134, -134, -133, -132, -131,
    -131, -130, -129, -129, -128, -127, -126, -126,
    -125, -124, -124, -123, -122, -121, -121, -120,
    -119, -119, -118, -117, -117, -116, -115, -114,
    -114, -113, -112, -112, -111, -110, -109, -109,
    -108, -107, -107, -106, -105, -104, -104, -103,
    -102, -102, -101, -100,  -99,  -99,  -98,  -97,
     -97,  -96,  -95,  -94,  -94,  -93,  -92,  -92,
     -91,  -90,  -90,  -89,  -88,  -87,  -87,  -86,
     -85,  -85,  -84,  -83,  -82,  -82,  -81,  -80,
     -80,  -79,  -78,  -77,  -77,  -76,  -75,  -75,
     -74,  -73,  -72,  -72,  -71,  -70,  -70,  -69,
     -68,  -67,  -67,  -66,  -65,  -65,  -64,  -63,
     -63,  -62,  -61,  -60,  -60,  -59,  -58,  -58,
     -57,  -56,  -55,  -55,  -54,  -53,  -53,  -52,
     -51,  -50,  -50,  -49,  -48,  -48,  -47,  -46,
     -45,  -45,  -44,  -43,  -43,  -42,  -41,  -40,
     -40,  -39,  -38,  -38,  -37,  -36,  -36,  -35,
     -34,  -33,  -33,  -32,  -31,  -31,  -30,  -29,
     -28,  -28,  -27,  -26,  -26,  -25,  -24,  -23,
     -23,  -22,  -21,  -21,  -20,  -19,  -18,  -18,
     -17,  -16,  -16,  -15,  -14,  -13,  -13,  -12,
     -11,  -11,  -10,   -9,   -9,   -8,   -7,   -6,
      -6,   -5,   -4,   -4,   -3,   -2,   -1,   -1,
       0,    1,    1,    2,    3,    4,    4,    5,
       6,    6,    7,    8,    9,    9,   10,   11,
      11,   12,   13,   13,   14,   15,   16,   16,
      17,   18,   18,   19,   20,   21,   21,   22,
      23,   23,   24,   25,   26,   26,   27,   28,
      28,   29,   30,   31,   31,   32,   33,   33,
      34,   35,   36,   36,   37,   38,   38,   39,
      40,   40,   41,   42,   43,   43,   44,   45,
      45,   46,   47,   48,   48,   49,   50,   50,
      51,   52,   53,   53,   54,   55,   55,   56,
      57,   58,   58,   59,   60,   60,   61,   62,
      63,   63,   64,   65,   65,   66,   67,   67,
      68,   69,   70,   70,   71,   72,   72,   73,
      74,   75,   75,   76,   77,   77,   78,   79,
      80,   80,   81,   82,   82,   83,   84,   85,
      85,   86,   87,   87,   88,   89,   90,   90,
      91,   92,   92,   93,   94,   94,   95,   96,
      97,   97,   98,   99,   99,  100,  101,  102,
     102,  103,  104,  104,  105,  106,  107,  107,
     108,  109,  109,  110,  111,  112,  112,  113,
     114,  114,  115,  116,  117,  117,  118,  119,
     119,  120,  121,  121,  122,  123,  124,  124,
     125,  126,  126,  127,  128,  129,  129,  130,
     131,  131,  132,  133,  134,  134,  135,  136,
     136,  137,  138,  139,  139,  140,  141,  141,
     142,  143,  144,  144,  145,  146,  146,  147,
     148,  148,  149,  150,  151,  151,  152,  153,
     153,  154,  155,  156,  156,  157,  158,  158,
     159,  160,  161,  161,  162,  163,  163,  164,
     165,  166,  166,  167,  168,  168,  169,  170,
};

#define COL_CEILING  0x2105u   /* dim grey-blue */
#define COL_FLOOR    0x4A48u   /* darker grey   */

#define FIXED_INF    0x7FFFFFFF

typedef struct {
    int     wall_top;     /* first row of wall (clipped to [0, SCREEN_H]) */
    int     wall_bottom;  /* one past last row of wall                    */
    int     tex_x;        /* 0..TEX_W-1                                   */
    fixed_t tex_step;     /* per-row advance in Q16.16                    */
    fixed_t tex_pos;      /* mutable: current tex_y * FIXED_ONE           */
    int     hit_side;     /* 0 = X face, 1 = Y face (darken when 1)       */
} col_info_t;

/* Mutable scratch.  On risc2, point at known BRAM addresses so the LLVM
 * backend's static-array dropper doesn't put us on top of another file's
 * statics (see scratch.h).  Other archs use plain .bss. */
#ifdef RISC2_PLATFORM
static col_info_t * const col_info = (col_info_t *)SCRATCH_COL_INFO;
static u16        * const row_buf  = (u16 *)SCRATCH_ROW_BUF;
#else
static col_info_t col_info[SCREEN_W];
static u16        row_buf [SCREEN_W];
#endif

static u16 shade_dark(u16 c)
{
    return (u16)((c >> 1) & 0x7BEFu);
}

/* Per-column DDA.  Sets col_info[col].* and resets tex_pos to 0.
 * Called once per column at frame setup. */
static void cast_column(int col, const player_t *p, const map_t *m)
{
    col_info_t *ci = &col_info[col];

    /* Angle offset across the FOV.  LUT lookup avoids a per-column
     * __mulsi3 + __udivsi3 pair (~550 cycles on risc2). */
    int col_offset = col_offset_lut[col];
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
    int steps    = 0;
    for (;;) {
        if (side_x < side_y) { side_x += delta_x; map_x += step_x; hit_side = 0; }
        else                 { side_y += delta_y; map_y += step_y; hit_side = 1; }
        if (map_is_wall(m, map_x, map_y)) break;
        if (++steps > 96) break;   /* DDA safety net for degenerate maps */
    }

    fixed_t ray_dist  = (hit_side == 0) ? (side_x - delta_x) : (side_y - delta_y);
    fixed_t perp_dist = FIXED_MUL(ray_dist, cos_table[angle_wrap(col_offset)]);
    if (perp_dist < 256) perp_dist = 256;

    /* wall_h = SCREEN_H * FIXED_ONE / perp_dist.  perp_dist is Q16.16, so the
     * result lands in pixels.  Cap to 2× screen height to keep tex_step
     * finite; texture sampling clips beyond [0, TEX_H). */
    int wall_h = (SCREEN_H * FIXED_ONE) / perp_dist;
    if (wall_h < 1)              wall_h = 1;
    if (wall_h > SCREEN_H * 4)   wall_h = SCREEN_H * 4;

    int wall_top    = (SCREEN_H - wall_h) / 2;
    int wall_bottom = wall_top + wall_h;
    int draw_top    = wall_top    < 0        ? 0        : wall_top;
    int draw_bottom = wall_bottom > SCREEN_H ? SCREEN_H : wall_bottom;

    /* Texture X: hit position's fractional part, shifted to [0, TEX_W). */
    fixed_t wall_hit = (hit_side == 0)
        ? p->y + FIXED_MUL(ray_dist, ray_dy)
        : p->x + FIXED_MUL(ray_dist, ray_dx);
    int tex_x = (int)(FIXED_FRAC(wall_hit) >> (FIXED_SHIFT - TEX_SHIFT));
    if (hit_side == 0 && ray_dx > 0) tex_x = TEX_W - 1 - tex_x;
    if (hit_side == 1 && ray_dy < 0) tex_x = TEX_W - 1 - tex_x;
    if (tex_x < 0)       tex_x = 0;
    if (tex_x >= TEX_W)  tex_x = TEX_W - 1;

    /* Step the texture down the wall: tex_step = TEX_H * FIXED_ONE / wall_h.
     * Initial tex_pos starts at 0 *unless* the wall extends above the screen,
     * in which case we skip that many rows worth of texture. */
    fixed_t tex_step = (TEX_H * FIXED_ONE) / wall_h;
    fixed_t tex_pos  = 0;
    if (wall_top < 0) {
        int skipped = draw_top - wall_top;   /* always >= 0 */
        /* skipped * tex_step in Q16.16: skipped is a small int (≤ SCREEN_H),
         * tex_step ≤ TEX_H * FIXED_ONE — fits in 32-bit when multiplied. */
        tex_pos = (fixed_t)skipped * tex_step;
    }

    ci->wall_top    = draw_top;
    ci->wall_bottom = draw_bottom;
    ci->tex_x       = tex_x;
    ci->tex_step    = tex_step;
    ci->tex_pos     = tex_pos;
    ci->hit_side    = hit_side;
}

/* Walk col_info[] in row-major order, emitting one full scanline at a time.
 * The inner loop touches no multiplies — texture index uses shifts (TEX_W
 * is a power of two), and tex_pos accumulates via add. */
static void blit_rows(void)
{
    int row, col;
    /* Solid-wall colour used when LABYRINTH2_NOTEX is defined (diagnostic
     * mode that bypasses brick_tex sampling).  Bright orange so it's
     * obvious if the DDA actually produced something 3D-shaped. */
    for (row = 0; row < SCREEN_H; row++) {
        for (col = 0; col < SCREEN_W; col++) {
            col_info_t *ci = &col_info[col];
            u16 c;
            if (row < ci->wall_top) {
                c = COL_CEILING;
            } else if (row >= ci->wall_bottom) {
                c = COL_FLOOR;
            } else {
#ifdef LABYRINTH2_NOTEX
                /* Diagnostic mode: solid wall colour, no texture sampling.
                 * Use this to validate the DDA geometry independently of the
                 * brick texture's per-texel pattern. */
                c = 0x8204;              /* mid-brown brick */
                if (ci->hit_side) c = shade_dark(c);
#else
                /* tex_y = upper halfword of Q16.16 tex_pos.  On risc2 we
                 * dodge the per-pixel `__ashrsi3 #16` (16 single-bit shift
                 * iterations) by reading the upper halfword directly via
                 * `load.w` — risc2's halfword endianness puts the upper
                 * 16 bits at offset 0 of the word, and the hardware's
                 * zero-extending load matches `u16 → int` integer
                 * promotion exactly (no manual sign-extension needed).
                 * tex_pos is always non-negative in this raycaster so
                 * zero-extension gives the right value.  Saves ~70 cycles
                 * per wall pixel.  Other archs use the portable shift. */
#ifdef RISC2_PLATFORM
                int tex_y = ((u16 *)&ci->tex_pos)[0];
#else
                int tex_y = FIXED_TO_INT(ci->tex_pos);
#endif
                if (tex_y < 0)       tex_y = 0;
                if (tex_y >= TEX_H)  tex_y = TEX_H - 1;
                /* TEX_W is a power of two → no multiply for the row stride. */
                c = brick_tex[(tex_y << TEX_SHIFT) | ci->tex_x];
                if (ci->hit_side) c = shade_dark(c);
                ci->tex_pos += ci->tex_step;
#endif
            }
            row_buf[col] = c;
        }
        hal_blit_row(row, row_buf);
    }
}

void raycast_render(const player_t *p, const map_t *m)
{
    int col;
    for (col = 0; col < SCREEN_W; col++)
        cast_column(col, p, m);
    blit_rows();
}
