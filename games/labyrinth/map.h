/*
 * map.h — ASCII map definition and interface
 *
 * File format: plain text, '#' = wall, ' ' = open space.
 * Each line is one row. Lines need not all be the same length.
 * Out-of-bounds cells are treated as walls.
 */

#ifndef __MAP_H__
#define __MAP_H__

#ifdef PLATFORM_RISC2
#define MAP_MAX_W   16
#define MAP_MAX_H   16
#else
#define MAP_MAX_W   64
#define MAP_MAX_H   64
#endif

typedef struct
{
    int  tiles[MAP_MAX_H][MAP_MAX_W];  /* int to avoid byte loads on RISC2 */
    int  width;
    int  height;
} map_t;

/*
 * Load a map. On desktop, path is a filename.
 * On RISC2, path is unused (hardcoded map).
 * Returns 0 on success, -1 on error.
 */
int map_load(map_t *m, const void *path);

/*
 * Returns 1 if (x, y) is a wall or out of bounds, 0 otherwise.
 */
int map_is_wall(const map_t *m, int x, int y);

#endif /* __MAP_H__ */
