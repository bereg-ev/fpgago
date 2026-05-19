/*
 * player.c — Movement + collision.
 *
 * Movement uses sin/cos LUT lookups + FIXED_MUL.  Same code on every arch
 * (~4 FIXED_MULs per update — negligible cost compared to rendering).
 */

#include "player.h"

void player_init(player_t *p, int cell_x, int cell_y, int angle)
{
    p->x     = INT_TO_FIXED(cell_x) + FIXED_HALF;
    p->y     = INT_TO_FIXED(cell_y) + FIXED_HALF;
    p->angle = angle_wrap(angle);
}

void player_update(player_t *p, const map_t *m, u32 input_flags)
{
    int     new_angle = p->angle;
    fixed_t dx = 0, dy = 0;

    if (input_flags & INPUT_TURN_LEFT)  new_angle = angle_wrap(new_angle - TURN_SPEED);
    if (input_flags & INPUT_TURN_RIGHT) new_angle = angle_wrap(new_angle + TURN_SPEED);
    p->angle = new_angle;

    if (input_flags & INPUT_FORWARD) {
        dx += FIXED_MUL(cos_table[p->angle], (fixed_t)MOVE_SPEED);
        dy += FIXED_MUL(sin_table[p->angle], (fixed_t)MOVE_SPEED);
    }
    if (input_flags & INPUT_BACK) {
        dx -= FIXED_MUL(cos_table[p->angle], (fixed_t)MOVE_SPEED);
        dy -= FIXED_MUL(sin_table[p->angle], (fixed_t)MOVE_SPEED);
    }
    if (input_flags & INPUT_STRAFE_LEFT) {
        int sa = angle_wrap(p->angle - QUARTER_TURN);
        dx += FIXED_MUL(cos_table[sa], (fixed_t)MOVE_SPEED);
        dy += FIXED_MUL(sin_table[sa], (fixed_t)MOVE_SPEED);
    }
    if (input_flags & INPUT_STRAFE_RIGHT) {
        int sa = angle_wrap(p->angle + QUARTER_TURN);
        dx += FIXED_MUL(cos_table[sa], (fixed_t)MOVE_SPEED);
        dy += FIXED_MUL(sin_table[sa], (fixed_t)MOVE_SPEED);
    }

    /* Slide along walls: test X- and Y-axis moves independently with margin. */
    {
        fixed_t new_x = p->x + dx;
        int     cx = FIXED_TO_INT(new_x + (dx >= 0 ? COLLIDE_MARGIN : -COLLIDE_MARGIN));
        int     cy = FIXED_TO_INT(p->y);
        if (!map_is_wall(m, cx, cy)) p->x = new_x;
    }
    {
        fixed_t new_y = p->y + dy;
        int     cx = FIXED_TO_INT(p->x);
        int     cy = FIXED_TO_INT(new_y + (dy >= 0 ? COLLIDE_MARGIN : -COLLIDE_MARGIN));
        if (!map_is_wall(m, cx, cy)) p->y = new_y;
    }
}
