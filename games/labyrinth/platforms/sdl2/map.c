/*
 * map.c — ASCII map loader (desktop/SDL2 version)
 */

#include <stdio.h>
#include <string.h>
#include "map.h"

int map_load(map_t *m, const void *path_arg)
{
    const char *path = (const char *)path_arg;
    FILE *f;
    char  line[MAP_MAX_W + 4];   /* +4 for \r\n\0 headroom */
    int   row = 0;
    int   col;
    int   len;
    int   r, c;

    /* Zero-fill: unset tiles default to wall ('#') */
    for (r = 0; r < MAP_MAX_H; r++)
        for (c = 0; c < MAP_MAX_W; c++)
            m->tiles[r][c] = 0;
    m->width = 0;
    m->height = 0;

    f = fopen(path, "r");
    if (!f)
    {
        fprintf(stderr, "map_load: cannot open '%s'\n", path);
        return -1;
    }

    while (row < MAP_MAX_H && fgets(line, sizeof(line), f))
    {
        /* Strip \r and \n */
        len = (int)strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
        {
            line[--len] = '\0';
        }

        /* Clamp to map width */
        if (len > MAP_MAX_W) len = MAP_MAX_W;

        for (col = 0; col < len; col++)
            m->tiles[row][col] = (int)(unsigned char)line[col];

        /* Pad remainder of short rows with walls */
        for (col = len; col < MAP_MAX_W; col++)
            m->tiles[row][col] = '#';

        if (len > m->width) m->width = len;
        row++;
    }

    fclose(f);

    m->height = row;

    if (m->width == 0 || m->height == 0)
    {
        fprintf(stderr, "map_load: empty map in '%s'\n", path);
        return -1;
    }

    return 0;
}

int map_is_wall(const map_t *m, int x, int y)
{
    if (x < 0 || x >= m->width || y < 0 || y >= m->height)
        return 1;   /* treat out-of-bounds as wall */

    return (m->tiles[y][x] == '#') ? 1 : 0;
}
