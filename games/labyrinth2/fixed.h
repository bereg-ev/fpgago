/*
 * fixed.h — Q16.16 fixed-point arithmetic for the labyrinth2 raycaster.
 *
 * Identical formula across SDL2, riscv-darkrv, risc2.  The multiply uses the
 * platform's signed 32×32→32 multiply (FIXED_MUL = `(a * b) >> 16` would
 * overflow; we shift both operands down 8 first to keep the intermediate
 * in 32 bits — costs 8 fractional bits of precision but works without an
 * int64 mul, which risc2 doesn't have).
 *
 * The hot per-pixel inner loop never calls FIXED_MUL — it's used only in
 * the per-column DDA setup, run 480 times per frame.
 */

#ifndef FIXED_H
#define FIXED_H

#include "hal.h"   /* for u32, i32, u16 */

typedef i32 fixed_t;

#define FIXED_SHIFT       16
#define FIXED_ONE         (1 << FIXED_SHIFT)
#define FIXED_HALF        (FIXED_ONE >> 1)
#define FIXED_INT_MAX     0x7FFFFFFF

/* Conversions */
#define INT_TO_FIXED(n)   ((fixed_t)((n) << FIXED_SHIFT))
#define FIXED_TO_INT(f)   ((int)((f) >> FIXED_SHIFT))

/* Fractional part (lower 16 bits, always positive). */
#define FIXED_FRAC(f)     ((f) & 0xFFFF)

#define FIXED_ABS(x)      ((x) < 0 ? -(x) : (x))

/* 32-bit-only multiply: drop 8 bits of each operand to keep the intermediate
 * in 32 bits.  Same definition on every arch — keeps frame output identical
 * between desktop sim and FPGA. */
#define FIXED_MUL(a, b) \
    ((fixed_t)(((a) >> 8) * ((b) >> 8)))

/* 32-bit-only divide.  Same trick: divide the numerator's high half by the
 * shifted denominator, then shift the result back up. */
#define FIXED_DIV(a, b) \
    ((fixed_t)(((a) / ((b) >> 8)) << 8))

#endif /* FIXED_H */
