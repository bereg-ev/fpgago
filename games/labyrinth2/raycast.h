/*
 * raycast.h — DDA raycaster renderer.
 *
 * Two-pass: per-column DDA computes wall metrics into col_info[] scratch,
 * then per-row blit composes pixels and pushes each scanline to the HAL
 * via hal_blit_row().  This shape matches the FPGA's scanline FLUSH
 * protocol exactly, while still letting SDL2 sim render the same data.
 */

#ifndef RAYCAST_H
#define RAYCAST_H

#include "player.h"
#include "map.h"

void raycast_render(const player_t *p, const map_t *m);

#endif /* RAYCAST_H */
