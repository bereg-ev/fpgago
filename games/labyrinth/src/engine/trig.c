/*
 * trig.c — sin/cos table initialisation
 *
 * Uses <math.h> once at startup. All runtime usage is pure integer.
 *
 * FPGA PORTING NOTE:
 *   Run this on the host, print the tables, then embed them as:
 *       static const fixed_t sin_table[ANGLE_COUNT] = { ... };
 *   Then remove trig_init() and the <math.h> include entirely.
 */

#define _DEFAULT_SOURCE   /* M_PI on glibc with strict -std=c11 */
#include <math.h>
#include "trig.h"

fixed_t sin_table[ANGLE_COUNT];
fixed_t cos_table[ANGLE_COUNT];

void trig_init(void)
{
    int i;
    double step = (2.0 * M_PI) / (double)ANGLE_COUNT;

    for (i = 0; i < ANGLE_COUNT; i++)
    {
        double angle = (double)i * step;
        sin_table[i] = (fixed_t)(sin(angle) * (double)FIXED_ONE);
        cos_table[i] = (fixed_t)(cos(angle) * (double)FIXED_ONE);
    }
}
