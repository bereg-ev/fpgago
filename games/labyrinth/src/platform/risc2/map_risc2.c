/*
 * map_risc2.c — hardcoded map for RISC2 (no stdio/file I/O)
 */

#include "../../engine/map.h"

#define W '#'
#define O ' '

static const int default_tiles[16][16] = {
    { W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W },
    { W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W },
    { W,O,O,O,W,W,O,O,O,O,W,W,O,O,O,W },
    { W,O,O,O,W,O,O,O,O,O,O,W,O,O,O,W },
    { W,O,W,O,W,O,O,W,W,O,O,W,O,W,O,W },
    { W,O,W,O,O,O,O,O,O,O,O,O,O,W,O,W },
    { W,O,W,O,O,W,O,O,O,O,W,O,O,W,O,W },
    { W,O,O,O,O,W,O,O,O,O,W,O,O,O,O,W },
    { W,O,O,O,O,W,O,O,O,O,W,O,O,O,O,W },
    { W,O,W,O,O,W,O,O,O,O,W,O,O,W,O,W },
    { W,O,W,O,O,O,O,O,O,O,O,O,O,W,O,W },
    { W,O,W,O,W,O,O,W,W,O,O,W,O,W,O,W },
    { W,O,O,O,W,O,O,O,O,O,O,W,O,O,O,W },
    { W,O,O,O,W,W,O,O,O,O,W,W,O,O,O,W },
    { W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W },
    { W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W },
};

int map_load(map_t *m, const void *unused)
{
    volatile int *dst = (volatile int *)m->tiles;
    int r, c;
    (void)unused;
    m->width  = 16;
    m->height = 16;
    /* Fill all with walls first */
    for (r = 0; r < MAP_MAX_H * MAP_MAX_W; r++)
        dst[r] = '#';
    /* Copy map data */
    for (r = 0; r < 16; r++)
        for (c = 0; c < 16; c++)
            dst[r * MAP_MAX_W + c] = default_tiles[r][c];
    return 0;
}

int map_is_wall(const map_t *m, int x, int y)
{
    if (x < 0 || x >= m->width || y < 0 || y >= m->height)
        return 1;
    return m->tiles[y][x] == '#';
}
