/*
 * map.h — 20×21 ASCII map (hard-coded).
 *
 * Cells: '#' = wall, ' ' = floor.  Out-of-bounds reads count as walls so the
 * DDA terminates safely.  Tiles are stored as `int` so risc2 — which has no
 * byte-load instructions — sees natural 32-bit accesses.
 */

#ifndef LABYRINTH2_MAP_H
#define LABYRINTH2_MAP_H

#define MAP_COLS   20
#define MAP_ROWS   21

typedef struct {
    int tiles[MAP_ROWS][MAP_COLS];
} map_t;

void map_init(map_t *m);
int  map_is_wall(const map_t *m, int x, int y);

#endif /* MAP_H */
