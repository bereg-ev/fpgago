/*
 * player.h — Player state and movement.
 *
 * Position (x, y) is Q16.16 where FIXED_ONE = one map cell.
 * angle is an index into sin_table/cos_table (0..ANGLE_COUNT-1).
 */

#ifndef PLAYER_H
#define PLAYER_H

#include "fixed.h"
#include "trig.h"
#include "map.h"

#define INPUT_FORWARD       (1u << 0)
#define INPUT_BACK          (1u << 1)
#define INPUT_TURN_LEFT     (1u << 2)
#define INPUT_TURN_RIGHT    (1u << 3)
#define INPUT_STRAFE_LEFT   (1u << 4)
#define INPUT_STRAFE_RIGHT  (1u << 5)

/* Tunables.  Speeds are in Q16.16 cells per tick / table-index ticks. */
#define MOVE_SPEED      2621    /* ≈ 0.04 cells per tick      */
#define TURN_SPEED      10      /* angle indices per tick     */
#define COLLIDE_MARGIN  13107   /* ≈ 0.2 cell wall stand-off  */

typedef struct {
    fixed_t x;
    fixed_t y;
    int     angle;
} player_t;

void player_init(player_t *p, int cell_x, int cell_y, int angle);
void player_update(player_t *p, const map_t *m, u32 input_flags);

#endif /* PLAYER_H */
