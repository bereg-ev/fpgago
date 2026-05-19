# labyrinth2 perf journey & open bug

State: reverted to last clean baseline. Intent: re-apply the changes below
one at a time so we can pinpoint which one introduces the column-alternation
artifact in the textured render.

## The five changes that were stacked on top of each other

These were applied together; the cumulative result was textured walls
breaking into alternating wall/floor stripes. Re-apply them in this order
and verify rendering after each step.

### 1. CPU=risc2p5 default in sim
- `arch/risc2/sim-desktop/Makefile`: change `CPU ?= risc2` to
  `CPU ?= risc2p5`.
- Effect: sim runs on the 3-stage pipelined core instead of the FSM core.
  ~3× IPC, identical ISA.
- Verified independently: produces byte-identical PPM to `CPU=risc2`. **Not
  a candidate** for the rendering bug.

### 2. Hardware-accelerated `hal_clear` boot
- `arch/risc2/hal_pixel.c`: extend `hal_clear` to drive the dcache
  `CLEAR_FB` FSM, then issue one extra FLUSH at `GPU_ROW = SCREEN_H` to
  cover the off-by-one PPM row 271 (CLEAR_FB walks dcache rows 0..271,
  which display as PPM rows -1..270 after lcd_out's one-row shift).
- `games/labyrinth2/main.c`: replace the two `hal_fill_rect` boot clears
  with two `hal_clear(0)` + `hal_swap` pairs.
- Effect: boot goes from random-pixels → black in ~0.5 s instead of ~2 s.
- Verified: PPM at frame 60 is 100% black on a clean build.

### 3. col_offset LUT in raycast.c
- `games/labyrinth2/raycast.c`: add a 480-entry
  `static const int col_offset_lut[SCREEN_W]` precomputing
  `(col * FOV_ANGLES) / SCREEN_W - HALF_FOV`. Replace the per-column
  multiply+divide with `col_offset_lut[col]`.
- Effect: eliminates one `__mulsi3` + one `__udivsi3` per column per frame
  (~550 cycles × 480 cols).
- Verified once: produced byte-identical PPM to the formula version.
  **Probably not** a candidate, but worth retesting in isolation.

### 4. 32×32 brick texture
- `games/labyrinth2/texture.{c,h}`: bump `TEX_W` / `TEX_H` / `TEX_SHIFT`
  from 16/16/4 → 32/32/5, replace texture data with a cleaner brick layout
  (4 courses × 8 rows, offset bond, 1-px highlight/shadow + 1-px mortar).
- Effect: at close range, mortar lines stay narrow instead of blurring
  into wide blocks. ROM grew from 26 488 → 28 023 bytes (under the 32 KB
  EXTENDED_MEM cap).
- This is when the column-alternation became *visible*, but see (5) — the
  texture change exposed a build-system bug that wasn't really the
  texture's fault.

### 5. Header dependency tracking in build.mk
- `arch/risc2/build.mk`: each `%.asm` rule now generates a `.d` file via
  `clang -MMD -MF -MT` and the file is `-include`'d so that changes to
  `texture.h` / `hal.h` / `raycast.h` etc. trigger rebuilds of the .asm
  translation units that include them.
- Why this was needed: without it, bumping `TEX_W`/`TEX_SHIFT` in
  `texture.h` rebuilt `texture.asm` (because `texture.c` was newer than
  `texture.asm`) but **not** `raycast.asm`. The result was a binary with
  the new 32×32 texture *data* but the old 16-wide shift constants baked
  into the indexing → most samples landed on mortar rows → all-grey walls.
- The fix was mandatory once we changed `texture.h`. Worth keeping
  regardless of which other changes get re-applied.

## The unsolved bug

After applying all five and rebuilding from `make clean` with the new
header deps in place, the first frame renders with a column-by-column
alternation: cols 0, 1, 3, 5, 7, ... come out as solid `COL_FLOOR`
(rgb 74,73,66) from top to bottom, while cols 2, 4, 6, 8, ... render
textured walls. 248 of 480 columns are solid floor. No row has any
ceiling pixels.

Things that have been ruled out by direct testing:

- ROM / `.vh` / Vsoc staleness — confirmed fresh builds via `md5` and
  timestamps.
- The LUT vs the original formula — both produce identical PPMs (md5
  match), so neither is responsible.
- `CPU=risc2p5` vs `CPU=risc2` — user confirmed render is identical.
- The texture *data* — `texture.c` emits the new 32×32 bytes correctly in
  the assembled rom.bin.
- The per-pixel `((u16*)&tex_pos)[0]` halfword trick — replaced with
  portable `FIXED_TO_INT`, no change.
- The per-pixel `tex_pos +=` mutation — replaced with a per-pixel
  `(row - wall_top) * tex_step` recompute (no col_info write in the inner
  loop), no change.
- `col_info` base address — both `cast_column`'s stores and `blit_rows`'s
  reads use `0x10800` (= `SCRATCH_COL_INFO`); no aliasing onto the map
  region.
- `blit_rows` reads from the correct offsets relative to its pivot
  register (`r10 - 0xC` for wall_top, `r10 - 0x8` for wall_bottom, etc.).

Things that DO matter (confirmed via diagnostics):

- With the DDA fully bypassed and `col_info` written from constants
  (`wall_top = 50, wall_bottom = 200 + col&1, hit_side = col&1`,
  `tex_x = col & 31`), the render is **clean**: solid bricks with
  alternating per-col shading from `hit_side`, mortar lines visible,
  CEILING/FLOOR in the right rows. So `col_info` storage and `blit_rows`
  reading both work end-to-end.
- With the **DDA enabled** + **texture sampling enabled**: the alternation
  appears.
- With the **DDA enabled** + **`LABYRINTH2_NOTEX` (solid-color walls)**:
  the alternation **does not** appear; we see clean wall slabs at varying
  depths, geometrically reasonable. So the DDA's computed `wall_top` /
  `wall_bottom` values *can* be read back correctly — it's the
  texture-sampling path that's involved.

The combination "DDA + texture sampling" is what triggers it, but every
candidate I've checked in the texture path reads from the same addresses
that NOTEX also reads from for wall_top/wall_bottom, and those addresses
are correct. I haven't found the mechanism.

## Step (1) result: confirmed culprit

Re-applied step (1) alone (`CPU ?= risc2p5` in
`arch/risc2/sim-desktop/Makefile`), rebuilt Vsoc from a clean `obj_dir`, ran
the unchanged baseline ROM. Result:

- Built with `-DUSE_RISC2P5`: MD5 of frame-400 PPM = `8bc05915…`. Render
  is wrong — close-up brick wall surface, ~52 % grey-tone, no corridor.
- Built with `CPU=risc2` (FSM): MD5 = `08cab9d6…`, **byte-identical to
  baseline**, clean corridor render restored.

Same ROM, same C, same scratch layout, same texture data — only the
Verilog top-level CPU module differs. So the bug is in `cpu_risc2p5.v`.
Likely a pipeline hazard around the runtime helpers (`__mulsi3`,
`__udivsi3`, `__ashrsi3`, `__lshrsi3`, `__ashlsi3`) that the raycaster
calls heavily — those have tight branch-back-edge loops that pipelined
cores often mis-handle.

The earlier "CPU=risc2 vs risc2p5 = same output" claim was wrong; it came
from a stale Vsoc that the original `make run` flow hadn't rebuilt. The
texture and LUT changes were red herrings.

Sim default reverted to `CPU ?= risc2` with a comment explaining why.
Steps (2), (3), (4) below should now be safe to re-apply against the FSM
core — the bug that masqueraded as their problem is no longer in play.

## Step (2) result: clean

Hardware `hal_clear` re-applied on top of step (1) reverted (CPU=risc2 FSM).

- Final-frame PPM byte-identical to baseline (MD5 `08cab9d6…`).
- Boot transitions random → fully black by frame ~60 (≈ 1 s simulated),
  vs ~120+ frames with the previous per-row `hal_fill_rect` loop.
- ROM grew by 64 bytes (24 531 → 24 595).

No correctness regression. Keeping.

## Step (3) result: clean

`col_offset_lut[]` (480-entry `static const int` table replacing
`(col * 341) / 480 - 170`) re-applied on top of steps (2).

- Final-frame PPM byte-identical to baseline (MD5 `08cab9d6…`).
- ROM grew by 1 892 bytes (24 595 → 26 487) — the 1920-byte LUT minus the
  ~30 bytes the formula's `__mulsi3 + __udivsi3 + add` setup saved.
- Per-frame: 480 calls to `__mulsi3` and 480 calls to `__udivsi3`
  eliminated (~250 k cycles saved at risc2's helper costs).

No correctness regression. Keeping.

## Step (4) result: clean

32×32 texture re-applied on top of steps (2) and (3), FSM CPU.

- ROM grew by 1 524 bytes (26 487 → 28 011) — the 2 KB texture vs the
  previous 512 B, minus some code rearrangement.
- raycast.asm correctly picked up the new `TEX_H/W = 32` and `TEX_SHIFT
  = 5`: clamp is `mov r1, #1f`, byte-stride shift is `mov r1, #6`. The
  header-dep fix (5) did its job — this was the failure mode the first
  time around.
- Render: clean 3D corridor with visible 32-px brick courses, horizontal
  mortar grid, 1-px highlight/shadow per brick.  No alternation, no per-
  pixel noise, no all-grey walls.

## Summary

| Step | Description                       | Status      | Notes |
|------|-----------------------------------|-------------|-------|
| (1)  | `CPU ?= risc2p5` sim default      | **Skipped** | `cpu_risc2p5.v` mis-executes the raycaster. Verilog bug. |
| (2)  | Hardware `hal_clear` (CLEAR_FB)   | Applied     | Boot ~2× faster, render byte-identical. |
| (3)  | `col_offset_lut[]`                | Applied     | Saves ~250 k cycles/frame on risc2, render byte-identical. |
| (4)  | 32×32 brick texture               | Applied     | Cleaner visuals at close range, +1.5 KB ROM. |
| (5)  | build.mk header dependencies      | Applied     | Prerequisite for safe iteration of (4). |

Net: three of four perf changes landed cleanly on the FSM core. (1) is
parked as a separate Verilog debugging task; if/when `cpu_risc2p5.v`'s
hazard is found and fixed, flipping `CPU ?= risc2p5` is a one-line
re-apply on top of this end state.

## cpu_risc2p5 / cpu_risc2p3 bisect

Tested labyrinth2 (and separately gomoku) across all CPU variants. Same
ROM, only the Verilog CPU module varies:

| CPU         | labyrinth2 render | gomoku render |
|-------------|-------------------|---------------|
| `risc2` (FSM) | Correct corridor  | Correct board |
| `risc2p2`   | Correct (matches FSM byte-for-byte) | Correct (matches FSM byte-for-byte) |
| `risc2p3`   | Broken            | Random pixels |
| `risc2p5`   | Broken (different output from p3 but also broken) | Random pixels (matches p3 byte-for-byte) |

So:
- **p2** (the 2-stage variant) works — decode + EX + writeback all in one
  stage means no inter-instruction forwarding is needed.
- **p3** and **p5** both broken. p3 is the first variant that splits
  writeback into a separate stage, requiring EXMEM forwarding. p5
  inherits and extends p3's forwarding logic, so the bug it has is
  *the same bug as p3*.

Write-trace diff (FSM vs p3 on gomoku, captured via `[WR …]` lines from
`sim_top.cpp`):

- Writes 1..58 808 byte-identical (same address, same value, same order).
- Write 58 809 diverges: same value (`0x18c3`), same compile-time
  instruction, but the *target address* is 12 bytes higher on p3 than on
  FSM. Subsequent stack-relative stores all stay offset by exactly 12.
- FSM does ≈493 stack writes total in the captured window; p3 only ≈104.
  The pattern `(0x18c3, n, 5)` triplet pushed onto the stack repeats
  ~160 times on FSM but ~30 times on p3 — looks like p3 either skips a
  loop iteration block or returns early from a function.

The 12-byte SP delta and the function-call-shape of the diverging writes
both point at **CALL / RET handling** in p3's forwarding logic — most
likely:

- a CALL link (R15 ← PC+4) not visible to the RET that immediately
  follows, OR
- a `sub r14, #c` / `add r14, #c` prolog/epilog that got squashed/
  forwarded wrong.

This is a Verilog debugging task on `cpu_risc2p3.v` (and the
inherited-from-p3 portion of `cpu_risc2p5.v`), not a labyrinth2 issue.
Recommended next step is to write a minimal Verilog testbench that
exercises a CALL→RET→CALL chain with reg/flag forwarding and compares
register/SP traces between p2/p3/p5.

For now, sim default stays on `CPU ?= risc2` (FSM); use `CPU=risc2p2`
for a faster known-good variant. p3/p5 are quarantined until the
forwarding bug is found.

## Open questions for the retry

1. Apply change (5) on its own first — fix the build deps before anything
   else. Verify a clean rebuild still produces the original labyrinth2
   render.
2. Apply (1) and (2) — sim CPU + hardware clear. Visually confirm.
3. Apply (3) — col_offset LUT. The PPM should still be byte-identical to
   the formula version. If alternation appears here, the LUT bytes vs the
   formula differ on risc2 somehow (maybe an immediate-encoding glitch in
   `gcasm` for the LUT load).
4. Apply (4) — 32×32 texture. If the alternation appears only here, the
   issue is related to `TEX_SHIFT = 5` interacting with risc2's halfword
   addressing, despite my static check that the asm uses `<<6` and clamps
   to `#1f` correctly.

If the alternation appears only after both (3) and (4) are present, the
two interact and need a paired bisect — try (3) without (4), then (4)
without (3).

## Files touched (in case you want to grep / diff after the revert)

- `arch/risc2/sim-desktop/Makefile`
- `arch/risc2/hal_pixel.c`
- `arch/risc2/build.mk`
- `games/labyrinth2/main.c`
- `games/labyrinth2/raycast.c`
- `games/labyrinth2/texture.c`
- `games/labyrinth2/texture.h`
- `arch/risc2/sim-desktop/sim_top.cpp` (added `SIM_PERIODIC_DUMP` env var
  for headless frame-by-frame PPM dumping — keep this, it's just
  instrumentation)
