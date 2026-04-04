/*
 * player.h — player state and movement
 *
 * Position (x, y) is in Q16.16 fixed-point where FIXED_ONE == one map cell.
 * angle is an index into sin_table/cos_table (0 .. ANGLE_COUNT-1).
 */

#ifndef __PLAYER_H__
#define __PLAYER_H__

#include "fixed.h"
#include "trig.h"
#include "map.h"

/* Input bitmask flags passed to player_update() */
#define INPUT_FORWARD       (1u << 0)
#define INPUT_BACK          (1u << 1)
#define INPUT_TURN_LEFT     (1u << 2)
#define INPUT_TURN_RIGHT    (1u << 3)
#define INPUT_STRAFE_LEFT   (1u << 4)
#define INPUT_STRAFE_RIGHT  (1u << 5)

/* Quarter-turn offset in the trig table (90 degrees = ANGLE_COUNT/4) */
#define QUARTER_TURN    (ANGLE_COUNT / 4)

/* Movement speed: cells per update */
#define MOVE_SPEED      2621    /* 0.04 * FIXED_ONE  */
#define TURN_SPEED      10      /* angle indices per update */

/* Collision margin: keep player this far from walls (in fixed-point) */
#define COLLIDE_MARGIN  13107   /* 0.2 * FIXED_ONE */

typedef struct
{
    fixed_t x;      /* position in the map, Q16.16 */
    fixed_t y;
    int     angle;  /* index into trig table */
} player_t;

/*
 * Initialize player at given map cell centre, facing given angle index.
 */
void player_init(player_t *p, int cell_x, int cell_y, int angle);

/*
 * Update player position and angle based on input_flags.
 * Handles collision against the map.
 */
void player_update(player_t *p, const map_t *m, u32 input_flags);

#endif /* __PLAYER_H__ */
