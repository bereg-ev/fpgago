/*
 * raycast.h — DDA raycasting renderer interface
 *
 * raycast_render() fills a packed pixel buffer (0x00RRGGBB per pixel)
 * at 800x600 resolution. No platform dependencies — pass the buffer
 * to SDL2 (or any other display layer) after calling this.
 */

#ifndef __RAYCAST_H__
#define __RAYCAST_H__

#include "fixed.h"
#include "player.h"
#include "map.h"

#define SCREEN_W    480
#define SCREEN_H    272

/* FOV = 60 degrees = 341 angle units out of 2048 */
#define FOV_ANGLES  341
#define HALF_FOV    (FOV_ANGLES / 2)

/*
 * Projection plane distance so a unit wall fills the screen at distance 1.
 * PROJ_DIST = (SCREEN_W/2) / tan(FOV/2) = 240 / tan(30°) ≈ 416
 */
#define PROJ_DIST   416

#define COLOR_CEILING   0x00202028U   /* dark blue-grey ceiling */
#define COLOR_FLOOR     0x00484840U   /* warm grey floor        */

/*
 * Render one frame into pixels[SCREEN_W * SCREEN_H].
 * pixels[y * SCREEN_W + x] = 0x00RRGGBB colour.
 */
void raycast_render(u32 *pixels, const player_t *p, const map_t *m);

#endif /* __RAYCAST_H__ */
