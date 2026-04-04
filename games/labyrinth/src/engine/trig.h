/*
 * trig.h — integer sin/cos lookup tables (Q16.16)
 *
 * ANGLE_COUNT steps cover a full 360 degrees.
 * Index 0 = 0°, index 512 = 90°, index 1024 = 180°, etc.
 *
 * FPGA PORTING NOTE:
 *   Replace trig_init() with a pre-computed static const array.
 *   Remove the <math.h> dependency entirely.
 *   See trig.c for the generator pattern.
 */

#ifndef __TRIG_H__
#define __TRIG_H__

#include "fixed.h"

#define ANGLE_COUNT  2048   /* steps per full rotation */

extern fixed_t sin_table[ANGLE_COUNT];
extern fixed_t cos_table[ANGLE_COUNT];

/* Call once at startup to fill the tables (uses double internally). */
void trig_init(void);

/* Wrap an angle into [0, ANGLE_COUNT) */
static inline int angle_wrap(int a)
{
    a = a % ANGLE_COUNT;
    if (a < 0) a += ANGLE_COUNT;
    return a;
}

#endif /* __TRIG_H__ */
