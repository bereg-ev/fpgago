/*
 * map_riscv.c — bare-metal map_load that hard-codes the 20×21 map from
 * games/labyrinth/assets/map.txt so we don't need a file system.
 */

#include "map.h"

static const char *const MAP_DATA[] = {
    "####################",
    "#                  #",
    "# ###  ######  ### #",
    "# #              # #",
    "# #  ##    ##   #  #",
    "#    #        #    #",
    "# #  #        #   ##",
    "# #  ##    ##  #   #",
    "# ###  ######  #  ##",
    "#         #        #",
    "####   #  #  #     #",
    "#      #     #     #",
    "#  #####  ####     #",
    "#                  #",
    "####  #########    #",
    "#     #       #    #",
    "#  ####  ###  ######",
    "#        # #       #",
    "######   # #   #   #",
    "#                  #",
    "####################",
};
#define MAP_ROWS   ((int)(sizeof(MAP_DATA) / sizeof(MAP_DATA[0])))
#define MAP_COLS   20

int map_load(map_t *m, const void *unused)
{
    (void)unused;
    int r, c;

    /* Zero-fill */
    for (r = 0; r < MAP_MAX_H; r++)
        for (c = 0; c < MAP_MAX_W; c++)
            m->tiles[r][c] = 0;

    for (r = 0; r < MAP_ROWS; r++) {
        for (c = 0; c < MAP_COLS; c++)
            m->tiles[r][c] = MAP_DATA[r][c];
        for (c = MAP_COLS; c < MAP_MAX_W; c++)
            m->tiles[r][c] = '#';
    }
    m->width  = MAP_COLS;
    m->height = MAP_ROWS;
    return 0;
}

int map_is_wall(const map_t *m, int x, int y)
{
    if (x < 0 || x >= m->width || y < 0 || y >= m->height)
        return 1;
    return (m->tiles[y][x] == '#') ? 1 : 0;
}
