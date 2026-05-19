/*
 * trig.h — Integer sin/cos LUT (Q16.16).
 *
 * 2048 steps cover a full 360° turn.  Tables are `const` and shared by every
 * arch — the bit-identical values let SDL2 and FPGA sim render the same
 * frame.  No runtime initialisation, no <math.h> dependency.
 *
 * Index 0 = 0°, 512 = 90°, 1024 = 180°, 1536 = 270°.
 */

#ifndef TRIG_H
#define TRIG_H

#include "fixed.h"

#define ANGLE_COUNT  2048
#define QUARTER_TURN (ANGLE_COUNT / 4)

extern const fixed_t sin_table[ANGLE_COUNT];
extern const fixed_t cos_table[ANGLE_COUNT];

/* Wrap an angle into [0, ANGLE_COUNT). */
static inline int angle_wrap(int a)
{
    a &= (ANGLE_COUNT - 1);    /* ANGLE_COUNT is a power of 2 → bit-mask */
    return a;
}

#endif /* TRIG_H */
