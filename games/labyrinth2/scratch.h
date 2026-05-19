/*
 * scratch.h — BRAM scratch addresses for labyrinth2 on risc2.
 *
 * Why: the risc2 LLVM backend silently drops mutable static-array globals.
 * The compiler still emits code that uses bare addresses (#10000 etc.), but
 * no `.bss` directive reserves the memory, so two unrelated files can both
 * get assigned 0x10000 as their "static array base" and corrupt each
 * other.  This was hit when col_info[] (in raycast.c) and g_map (in main.c)
 * both landed at 0x10000 — writes to col_info shredded the map data and
 * the DDA reported random walls, producing random-pixel garbage.
 *
 * Fix: every mutable global gets an explicit address in BRAM scratch from
 * this header.  No two regions overlap, none is given to the LLVM
 * auto-allocator.
 *
 * BRAM size note: with `EXTENDED_MEM` defined in arch/risc2/project.vh,
 * BRAM is 4K × 32-bit words = 16 KB.  Only address bits [13:2] are decoded,
 * so anything above 0x13FFF aliases back to 0x10000.  The layout below
 * keeps every region inside the 16 KB window AND leaves headroom at the
 * top for the stack (sp init = 0x1FF00, which aliases to BRAM word 0xFFC =
 * byte offset 0x3FF0).
 *
 * Layout (byte offsets from MEM_BRAM_BASE):
 *   0x0000..0x06A0   g_map      ( 21×20 ints = 1680 B )
 *   0x0700..0x0710   g_player   ( 16 B    )
 *   0x0800..0x3500   col_info[] ( 480 × 24 B = 11520 B )
 *   0x3500..0x38C0   row_buf[]  ( 480 × 2 B  =   960 B )
 *   0x38C0..0x3FF0   ~1.8 KB headroom before the stack starts growing down.
 *
 * Non-risc2 archs use ordinary static arrays — those compile fine into
 * .bss and don't need any of this.
 */

#ifndef LABYRINTH2_SCRATCH_H
#define LABYRINTH2_SCRATCH_H

#ifdef RISC2_PLATFORM
#include "memmap.h"
#define SCRATCH_MAP       (MEM_BRAM_BASE + 0x0000u)
#define SCRATCH_PLAYER    (MEM_BRAM_BASE + 0x0700u)
#define SCRATCH_COL_INFO  (MEM_BRAM_BASE + 0x0800u)
#define SCRATCH_ROW_BUF   (MEM_BRAM_BASE + 0x3500u)
#endif

#endif /* LABYRINTH2_SCRATCH_H */
