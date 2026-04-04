/*
 * player_risc2.c — player movement for RISC2
 *
 * Workaround: RISC2 LLVM backend crashes on struct field access in
 * conditional stores. Use pointer arithmetic instead of struct members.
 */

#include "../../engine/fixed.h"
#include "../../engine/trig.h"
#include "../../engine/map.h"
#include "../../engine/player.h"

void player_init(player_t *p, int cell_x, int cell_y, int angle)
{
    int *pp = (int *)p;
    pp[0] = INT_TO_FIXED(cell_x) + FIXED_HALF;  /* x */
    pp[1] = INT_TO_FIXED(cell_y) + FIXED_HALF;  /* y */
    pp[2] = angle_wrap(angle);                    /* angle */
}

/* Return new position if no wall, or old position if wall.
 * Avoids conditional store pattern that crashes RISC2 LLVM backend. */
static fixed_t try_move(fixed_t old_val, fixed_t new_val, const map_t *m, int cx, int cy)
{
    if (map_is_wall(m, cx, cy))
        return old_val;
    return new_val;
}

void player_update(player_t *p, const map_t *m, u32 input_flags)
{
    int *pp = (int *)p;
    int new_angle = pp[2];
    fixed_t dx = 0;
    fixed_t dy = 0;
    int sa;

    /* Turning */
    if (input_flags & INPUT_TURN_LEFT)
        new_angle = angle_wrap(new_angle - TURN_SPEED);
    if (input_flags & INPUT_TURN_RIGHT)
        new_angle = angle_wrap(new_angle + TURN_SPEED);
    pp[2] = new_angle;

    /* Forward/back */
    if (input_flags & INPUT_FORWARD) {
        dx = FIXED_MUL(cos_table[new_angle], (fixed_t)MOVE_SPEED);
        dy = FIXED_MUL(sin_table[new_angle], (fixed_t)MOVE_SPEED);
    }
    if (input_flags & INPUT_BACK) {
        dx = -FIXED_MUL(cos_table[new_angle], (fixed_t)MOVE_SPEED);
        dy = -FIXED_MUL(sin_table[new_angle], (fixed_t)MOVE_SPEED);
    }

    /* Strafe */
    if (input_flags & INPUT_STRAFE_LEFT) {
        sa = angle_wrap(new_angle - QUARTER_TURN);
        dx += FIXED_MUL(cos_table[sa], (fixed_t)MOVE_SPEED);
        dy += FIXED_MUL(sin_table[sa], (fixed_t)MOVE_SPEED);
    }
    if (input_flags & INPUT_STRAFE_RIGHT) {
        sa = angle_wrap(new_angle + QUARTER_TURN);
        dx += FIXED_MUL(cos_table[sa], (fixed_t)MOVE_SPEED);
        dy += FIXED_MUL(sin_table[sa], (fixed_t)MOVE_SPEED);
    }

    /* Collision — return-value pattern avoids conditional store crash */
    {
        fixed_t new_x = pp[0] + dx;
        pp[0] = try_move(pp[0], new_x, m, FIXED_TO_INT(new_x), FIXED_TO_INT(pp[1]));
    }
    {
        fixed_t new_y = pp[1] + dy;
        pp[1] = try_move(pp[1], new_y, m, FIXED_TO_INT(pp[0]), FIXED_TO_INT(new_y));
    }
}
