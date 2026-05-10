/*
 * fixed.h — Q16.16 fixed-point arithmetic
 *
 * Format: signed 32-bit, 16 integer bits + 16 fractional bits.
 * FIXED_ONE (65536) represents 1.0.
 *
 * FPGA PORTING NOTE:
 *   FIXED_MUL uses int64_t intermediate to avoid overflow.
 *   If the soft CPU has no 64-bit multiply instruction, replace
 *   FIXED_MUL with a software 32x32->64 multiply routine.
 */

#ifndef __FIXED_H__
#define __FIXED_H__

#ifdef PLATFORM_RISC2
/* RISC2: no stdint.h, define types manually. No u8 (byte loads unsupported). */
typedef int          fixed_t;
typedef unsigned int u32;
typedef unsigned int u16;
#else
#include <stdint.h>
typedef int32_t  fixed_t;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;
#endif

#define FIXED_SHIFT     16
#define FIXED_ONE       (1 << FIXED_SHIFT)      /* 65536  = 1.0  */
#define FIXED_HALF      (FIXED_ONE >> 1)         /* 32768  = 0.5  */
#define INT32_MAX_VAL   0x7FFFFFFF

/* Conversion */
#define INT_TO_FIXED(n)     ((fixed_t)((n) << FIXED_SHIFT))
#define FIXED_TO_INT(f)     ((int)((f) >> FIXED_SHIFT))

/* Arithmetic */
#ifdef PLATFORM_RISC2
/* 32-bit only: shift each operand down 8 bits before multiply.
 * Loses 8 bits of precision but avoids 64-bit intermediate. */
#define FIXED_MUL(a, b) \
    ((fixed_t)(((a) >> 8) * ((b) >> 8)))
#define FIXED_DIV(a, b) \
    ((fixed_t)(((a) / ((b) >> 8)) << 8))
#else
/* 64-bit intermediate prevents overflow */
#define FIXED_MUL(a, b) \
    ((fixed_t)(((int64_t)(a) * (int64_t)(b)) >> FIXED_SHIFT))
#define FIXED_DIV(a, b) \
    ((fixed_t)(((int64_t)(a) << FIXED_SHIFT) / (int64_t)(b)))
#endif

#define FIXED_ABS(x)    ((x) < 0 ? -(x) : (x))

/* Fractional part (lower 16 bits), always positive */
#define FIXED_FRAC(f)   ((f) & 0xFFFF)

#endif /* __FIXED_H__ */
