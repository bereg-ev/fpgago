/*
 * hal.h -- Character-based Hardware Abstraction Layer for Gomoku
 *
 * The display is a grid of 8x16-pixel character cells (60 cols x 17 rows).
 * Board cells use custom character codes (128+) that represent left/right
 * halves of 16x16 game field squares, each with built-in grid borders.
 */

#ifndef HAL_H
#define HAL_H

#include <stdint.h>

typedef uint16_t u16;
typedef uint8_t  u8;

#define SCREEN_W  480
#define SCREEN_H  272

#ifdef RISC2_PLATFORM
/* Narrower text grid to reduce rendering cost on slow RISC2 CPU.
 * 34 = minimum for 15-col board + labels + edge. LCD window is centred. */
#define TEXT_COLS  34
#define TEXT_ROWS  17
#else
#define TEXT_COLS  (SCREEN_W / 8)    /* 60 */
#define TEXT_ROWS  (SCREEN_H / 16)   /* 17 */
#endif

#define RGB565(r,g,b)  ((u16)(((r)<<11)|((g)<<5)|(b)))

/* ---- Custom character codes for board cells ----------------------------- */
/* Each board cell is a pair: left half (even code) + right half (odd code).  */
/* Left halves carry a 1-pixel left border; all halves carry a bottom border. */

#define CH_EMPTY_L  128
#define CH_EMPTY_R  129
#define CH_X_L      130
#define CH_X_R      131
#define CH_O_L      132
#define CH_O_R      133
#define CH_CUR_L    134
#define CH_CUR_R    135

/* Column header cells (letters A-O with grid borders) */
#define CH_HDR_L(c) (144 + (c) * 2)   /* c = 0..14 → codes 144,146,..,172 */
#define CH_HDR_R(c) (145 + (c) * 2)   /* c = 0..14 → codes 145,147,..,173 */

/* Range check for custom glyphs */
#define CUST_BASE   128
#define CUST_COUNT  48                 /* covers codes 128..175 */

/* ---- HAL interface ------------------------------------------------------ */
void hal_clear(void);
void hal_putchar(int col, int row, int ch);
void hal_swap(void);

#endif /* HAL_H */
