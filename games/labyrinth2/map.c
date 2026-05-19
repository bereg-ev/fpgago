/*
 * map.c — Hardcoded labyrinth2 map.
 *
 * Stored as a 2D `int` table (not strings) because the risc2 LLVM backend
 * emits string literals as .db byte arrays that gcasm can't link.  Ints go
 * straight to .dd dwords, which gcasm handles.  Identical content across
 * archs.
 */

#include "map.h"

#define W 1
#define O 0

static const int MAP_DATA[MAP_ROWS][MAP_COLS] = {
    { W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W },
    { W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W },
    { W,O,W,W,W,O,O,W,W,W,W,W,W,O,O,W,W,W,O,W },
    { W,O,W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W,O,W },
    { W,O,W,O,O,W,W,O,O,O,O,W,W,O,O,O,W,O,O,W },
    { W,O,O,O,O,W,O,O,O,O,O,O,O,O,W,O,O,O,O,W },
    { W,O,W,O,O,W,O,O,O,O,O,O,O,O,W,O,O,O,W,W },
    { W,O,W,O,O,W,W,O,O,O,O,W,W,O,O,W,O,O,O,W },
    { W,O,W,W,W,O,O,W,W,W,W,W,W,O,O,W,O,O,W,W },
    { W,O,O,O,O,O,O,O,O,O,W,O,O,O,O,O,O,O,O,W },
    { W,W,W,W,O,O,O,W,O,O,W,O,O,W,O,O,O,O,O,W },
    { W,O,O,O,O,O,O,W,O,O,O,O,O,W,O,O,O,O,O,W },
    { W,O,O,W,W,W,W,W,O,O,W,W,W,W,O,O,O,O,O,W },
    { W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W },
    { W,W,W,W,O,O,W,W,W,W,W,W,W,W,W,O,O,O,O,W },
    { W,O,O,O,O,O,W,O,O,O,O,O,O,O,W,O,O,O,O,W },
    { W,O,O,W,W,W,W,O,O,W,W,W,O,O,W,W,W,W,W,W },
    { W,O,O,O,O,O,O,O,O,W,O,W,O,O,O,O,O,O,O,W },
    { W,W,W,W,W,W,O,O,O,W,O,W,O,O,O,W,O,O,O,W },
    { W,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,O,W },
    { W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W,W },
};

void map_init(map_t *m)
{
    int r, c;
    for (r = 0; r < MAP_ROWS; r++)
        for (c = 0; c < MAP_COLS; c++)
            m->tiles[r][c] = MAP_DATA[r][c];
}

int map_is_wall(const map_t *m, int x, int y)
{
    if (x < 0 || x >= MAP_COLS || y < 0 || y >= MAP_ROWS)
        return 1;
    return m->tiles[y][x];
}
