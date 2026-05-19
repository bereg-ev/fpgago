/*
 * texture.h — 32×32 RGB565 brick texture, sampled by the raycaster.
 *
 * Stored as `const` so it lives in .rodata (ECP5 BRAM stays free).  32×32
 * keeps texture indexing mul-free: `tex_x = FIXED_FRAC(hit) >> 11`,
 * `tex[(tex_y << 5) | tex_x]`.  Quadrupled from the original 16×16 so the
 * mortar bands and brick faces don't blur into wide blocks at close range.
 */

#ifndef TEXTURE_H
#define TEXTURE_H

#include "hal.h"   /* u16, u32 */

#define TEX_W      32
#define TEX_H      32
#define TEX_SHIFT  5    /* log2(TEX_W) */

extern const u16 brick_tex[TEX_W * TEX_H];

#endif /* TEXTURE_H */
