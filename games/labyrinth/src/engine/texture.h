/*
 * texture.h — wall texture (64x64, packed 0x00RRGGBB)
 *
 * A single procedural brick texture is generated at startup.
 * No file I/O, no BMP parser — suitable for FPGA ROM embedding.
 *
 * FPGA PORTING NOTE:
 *   After calling texture_init() once on the host, dump brick_texture[]
 *   as a const array and remove texture_init() entirely.
 */

#ifndef __TEXTURE_H__
#define __TEXTURE_H__

#include "fixed.h"

#define TEX_W   64
#define TEX_H   64

/* Wall texture pixels in 0x00RRGGBB format */
extern u32 brick_texture[TEX_W * TEX_H];

/* Generate the brick pattern — call once before rendering */
void texture_init(void);

#endif /* __TEXTURE_H__ */
