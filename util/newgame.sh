#!/bin/bash
# newgame.sh — Scaffold a new game for FPGAgo
#
# Usage: newgame.sh <game-name> <arch-name> <base-isa> <repo-root>
#
# Generates a complete, compilable game skeleton based on the base ISA:
#   risc1 → assembly template with char LCD port I/O
#   risc2 → C template with HAL, engine, platform/risc2, platform/sdl2

set -euo pipefail

GAME="${1:?Usage: $0 <game> <arch> <base-isa> <repo-root>}"
ARCH="${2:?}"
BASE="${3:?}"
ROOT="${4:?}"

GDIR="$ROOT/games/$GAME"

# ════════════════════════════════════════════════════════════════════════════
# RISC1: Assembly template
# ════════════════════════════════════════════════════════════════════════════

gen_risc1() {
    mkdir -p "$GDIR/src/platform"

    # ── Makefile ──
    cat > "$GDIR/Makefile" << 'MKEOF'
ASM = ../../util/gcasm/gcasm
PROJECT = ../../arch/ARCHNAME

all: build copy

build:
	$(ASM) -cARCHNAME GAMENAME.asm

copy: build
	cp romL.vh $(PROJECT)/romL.vh

clean:
	rm -f rom.bin romL.vh romH.vh rom.hex

run: copy
	cd $(PROJECT)/sim-desktop && make run

.PHONY: all build copy clean run
MKEOF
    sed -i.bak -e "s/GAMENAME/$GAME/g" -e "s/ARCHNAME/$ARCH/g" "$GDIR/Makefile" && rm -f "$GDIR/Makefile.bak"

    # ── Assembly source ──
    cat > "$GDIR/$GAME.asm" << 'ASMEOF'
; =====================================================
; GAMENAME — Template game for RISC1 + Character LCD
; =====================================================
; Screen: 32 x 16 characters
;
; Port map (write):
;   0x10  text addr low byte
;   0x11  text addr high byte [1:0]
;   0x12  write char + auto-increment addr
;   0x13  write char (no auto-increment)
;
; Port map (read):
;   0x18  timer tick (8-bit)
;   0x1A  random number (LFSR)
;   0x20  UART status (bit 0 = RX ready)
;   0x21  UART RX data
; =====================================================

start:
    ; ---- Clear screen (fill 512 chars with space 0x20) ----
    mov r0, #00
    out (#10), r0           ; addr low = 0
    out (#11), r0           ; addr high = 0
    mov r1, #20             ; space character
    mov r2, #00             ; counter low
    mov r3, #02             ; counter high (512 = 0x200)
_clear:
    out (#12), r1           ; write space + auto-increment
    add r2, #01
    jnz _clear_check
    sub r3, #01
_clear_check:
    add r3, #00             ; test r3 (nop add to set flags)
    jnz _clear
    add r2, #00             ; test r2
    jnz _clear

    ; ---- Write "HELLO WORLD" at row 3, col 3 ----
    ; Text address = row * 32 + col = 3 * 32 + 3 = 99 = 0x63
    mov r0, #63
    out (#10), r0           ; addr low
    mov r0, #00
    out (#11), r0           ; addr high

    mov r0, 'H'
    out (#12), r0
    mov r0, 'E'
    out (#12), r0
    mov r0, 'L'
    out (#12), r0
    mov r0, 'L'
    out (#12), r0
    mov r0, 'O'
    out (#12), r0
    mov r0, ' '
    out (#12), r0
    mov r0, 'W'
    out (#12), r0
    mov r0, 'O'
    out (#12), r0
    mov r0, 'R'
    out (#12), r0
    mov r0, 'L'
    out (#12), r0
    mov r0, 'D'
    out (#12), r0

    ; ---- Main loop: wait for UART input, echo to screen ----
    ; Write received characters starting at row 5, col 3
    mov r5, #03             ; starting column

_loop:
    in r0, (#20)            ; read UART status
    and r0, #01             ; bit 0 = RX ready
    jz _loop                ; spin until byte arrives

    in r1, (#21)            ; read UART data

    ; Calculate text address: row 5 * 32 + col = 160 + r5 = 0xA0 + r5
    mov r0, r5
    add r0, #a0             ; low byte
    out (#10), r0
    mov r0, #00             ; high byte = 0
    out (#11), r0

    out (#13), r1           ; write received char (no auto-increment)

    add r5, #01             ; advance column
    mov r0, #1f             ; col 31
    cmp r5, r0
    jnz _loop               ; continue if not at end of row
    mov r5, #03             ; wrap back to col 3

    jmp _loop
ASMEOF
    sed -i.bak "s/GAMENAME/$GAME/g" "$GDIR/$GAME.asm" && rm -f "$GDIR/$GAME.asm.bak"
}

# ════════════════════════════════════════════════════════════════════════════
# RISC2: C template with char LCD
# ════════════════════════════════════════════════════════════════════════════

gen_risc2() {
    mkdir -p "$GDIR/src/hal"
    mkdir -p "$GDIR/src/engine"
    mkdir -p "$GDIR/src/platform/risc2"
    mkdir -p "$GDIR/src/platform/sdl2"

    # ── HAL ──
    cat > "$GDIR/src/hal/hal.h" << 'EOF'
#ifndef HAL_H
#define HAL_H

#ifdef RISC2_PLATFORM
typedef unsigned int u32;
#else
#include <stdint.h>
typedef uint32_t u32;
#endif

#define LCD_COLS  32
#define LCD_ROWS  16

void hal_putc(int col, int row, int ch);
void hal_clear(void);
void hal_swap(void);

#endif
EOF

    # ── game.h ──
    cat > "$GDIR/src/engine/game.h" << 'EOF'
#ifndef GAME_H
#define GAME_H

#include "../hal/hal.h"

typedef struct {
    int counter;
} game_t;

void game_init(game_t *g);
void game_tick(game_t *g, int input);

#endif
EOF

    # ── game.c ──
    cat > "$GDIR/src/engine/game.c" << 'EOF'
#include "game.h"

void game_init(game_t *g)
{
    g->counter = 0;
}

void game_tick(game_t *g, int input)
{
    (void)input;
    g->counter++;
}
EOF

    # ── render.h ──
    cat > "$GDIR/src/engine/render.h" << 'EOF'
#ifndef RENDER_H
#define RENDER_H

#include "game.h"

void render_frame(const game_t *g);

#endif
EOF

    # ── render.c ──
    cat > "$GDIR/src/engine/render.c" << 'EOF'
#include "render.h"
#include "../hal/hal.h"

static void put_string(int col, int row, const char *s)
{
    while (*s) {
        hal_putc(col++, row, *s++);
    }
}

static void put_int(int col, int row, int val)
{
    char buf[12];
    int i = 0;
    if (val == 0) { hal_putc(col, row, '0'); return; }
    if (val < 0) { hal_putc(col++, row, '-'); val = -val; }
    while (val > 0) { buf[i++] = '0' + (val % 10); val /= 10; }
    while (i > 0) hal_putc(col++, row, buf[--i]);
}

void render_frame(const game_t *g)
{
    hal_clear();
    put_string(3, 3, "HELLO WORLD");
    put_string(3, 5, "Press any key");
    put_string(3, 7, "Count:");
    put_int(10, 7, g->counter);
}
EOF

    # ── font.h (copy from tic-tac-toe) ──
    cp "$ROOT/games/tic-tac-toe/src/engine/font.h" "$GDIR/src/engine/font.h"

    # ── platform/risc2/Makefile ──
    cat > "$GDIR/src/platform/risc2/Makefile" << 'MKEOF'
GAME_SRCS    = game.c render.c main.c
EXTRA_CFLAGS = -fno-builtin -DRISC2_PLATFORM
include ../../../../../arch/ARCHNAME/build.mk
MKEOF
    sed -i.bak "s/ARCHNAME/$ARCH/g" "$GDIR/src/platform/risc2/Makefile" && rm -f "$GDIR/src/platform/risc2/Makefile.bak"

    # ── platform/risc2/main.c ──
    cat > "$GDIR/src/platform/risc2/main.c" << 'EOF'
/*
 * platform/risc2/main.c — RISC2 char LCD platform layer
 */

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"

/* ── GPU3D (background clear) ──────────────────────────────────────────── */
#define GPU_REG(n)      (*(volatile unsigned int*)(0x0A0000 + (n)*4))
#define GPU_CLR_COLOR   GPU_REG(7)
#define GPU_CMD         GPU_REG(8)
#define GPU_STATUS      GPU_REG(9)

/* ── LCD char control ──────────────────────────────────────────────────── */
#define LCD_CTRL(n)     (*(volatile unsigned int*)(0x0C0000 + (n)))
#define LCD_TEXT(n)     (*(volatile unsigned int*)(0x0E0000 + (n)))

/* ── UART ──────────────────────────────────────────────────────────────── */
#define IO_STATUS       (*(volatile unsigned int*)0xF0002)
#define IO_UART_RX      (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY      (1 << 0)

/* ── Back buffer ───────────────────────────────────────────────────────── */
#define BUF_BASE        ((volatile unsigned int*)0x010100)
static volatile unsigned int *buf = BUF_BASE;

/* ── HAL ───────────────────────────────────────────────────────────────── */

void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        buf[row * LCD_COLS + col] = (unsigned int)ch;
}

void hal_clear(void)
{
    int i, n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        buf[i] = ' ';
}

void hal_swap(void)
{
    int i, n = LCD_COLS * LCD_ROWS;
    for (i = 0; i < n; i++)
        LCD_TEXT(i) = buf[i];
}

/* ── Helpers ───────────────────────────────────────────────────────────── */

static void gpu_wait(void)  { while (GPU_STATUS & 1) {} }

static void gpu_clear_black(void)
{
    gpu_wait(); GPU_CLR_COLOR = 0; GPU_CMD = 2; gpu_wait(); GPU_CMD = 3;
    gpu_wait(); GPU_CLR_COLOR = 0; GPU_CMD = 2; gpu_wait(); GPU_CMD = 3;
}

static void lcd_char_init(void)
{
    LCD_CTRL(0) = 0;
    LCD_CTRL(1) = 0;
    LCD_CTRL(2) = LCD_COLS;
    LCD_CTRL(3) = 0x8000 | LCD_ROWS;
}

static int uart_getchar(void)
{
    while (!(IO_STATUS & UART_RXRDY)) {}
    return (int)(IO_UART_RX & 0xFF);
}

/* ── Game state in data RAM ────────────────────────────────────────────── */
#define GAME_PTR  ((game_t*)0x010900)

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(void)
{
    game_t *g = GAME_PTR;

    gpu_clear_black();
    lcd_char_init();

    game_init(g);
    render_frame(g);
    hal_swap();

    for (;;) {
        int ch = uart_getchar();
        game_tick(g, ch);
        render_frame(g);
        hal_swap();
    }

    return 0;
}
EOF

    # ── platform/sdl2/Makefile ──
    local EXEEXT_BLOCK='ifeq ($(OS),Windows_NT)
  EXEEXT = .exe
else
  EXEEXT =
endif'

    cat > "$GDIR/src/platform/sdl2/Makefile" << MKEOF
CC      = gcc
CFLAGS  = -Wall -Wextra -std=c99 -O2 \\
          -I../../hal \\
          -I../../engine \\
          \$(shell sdl2-config --cflags)
LDFLAGS = \$(shell sdl2-config --libs)

ENGINE  = ../../engine/game.c ../../engine/render.c
SRCS    = \$(ENGINE) main.c
OBJS    = \$(patsubst %.c,%.o,\$(notdir \$(SRCS)))
TARGET  = $GAME

$EXEEXT_BLOCK

vpath %.c ../../engine .

.PHONY: all clean

all: \$(TARGET)\$(EXEEXT)

\$(TARGET)\$(EXEEXT): \$(OBJS)
	\$(CC) \$(CFLAGS) -o \$@ \$(OBJS) \$(LDFLAGS)

game.o: ../../engine/game.c
	\$(CC) \$(CFLAGS) -c \$< -o \$@

render.o: ../../engine/render.c
	\$(CC) \$(CFLAGS) -c \$< -o \$@

main.o: main.c
	\$(CC) \$(CFLAGS) -c \$< -o \$@

clean:
	rm -f \$(OBJS) \$(TARGET) \$(TARGET).exe
MKEOF

    # ── platform/sdl2/main.c ──
    cat > "$GDIR/src/platform/sdl2/main.c" << 'EOF'
/*
 * platform/sdl2/main.c — SDL2 char LCD simulator
 */

#include <SDL.h>
#include <string.h>

#include "../../hal/hal.h"
#include "../../engine/game.h"
#include "../../engine/render.h"
#include "../../engine/font.h"

#define CHAR_W   8
#define CHAR_H  16
#define FONT_W   5
#define GLYPH_H  7

#define FB_W    (LCD_COLS * CHAR_W)
#define FB_H    (LCD_ROWS * CHAR_H)

static char s_chars[LCD_ROWS][LCD_COLS];
static SDL_Window   *s_window   = NULL;
static SDL_Renderer *s_renderer = NULL;
static SDL_Texture  *s_texture  = NULL;
static uint32_t      s_fb[FB_W * FB_H];

#define COL_BG  0xFF001800
#define COL_FG  0xFF00CC00

/* ── HAL ───────────────────────────────────────────────────────────────── */

void hal_putc(int col, int row, int ch)
{
    if (col >= 0 && col < LCD_COLS && row >= 0 && row < LCD_ROWS)
        s_chars[row][col] = ch;
}

void hal_clear(void)
{
    memset(s_chars, ' ', sizeof(s_chars));
}

void hal_swap(void)
{
    int r, c, fr, fc;
    for (r = 0; r < LCD_ROWS; r++) {
        for (c = 0; c < LCD_COLS; c++) {
            unsigned char ch = (unsigned char)s_chars[r][c];
            const unsigned int *glyph = NULL;
            if (ch >= 0x20 && ch < 0x80)
                glyph = font5x7[ch - 0x20];

            int px = c * CHAR_W;
            int py = r * CHAR_H;

            for (fr = 0; fr < CHAR_H; fr++)
                for (fc = 0; fc < CHAR_W; fc++)
                    s_fb[(py + fr) * FB_W + (px + fc)] = COL_BG;

            if (glyph) {
                for (fr = 0; fr < GLYPH_H; fr++)
                    for (fc = 0; fc < FONT_W; fc++)
                        if (glyph[fr] & (0x10 >> fc))
                            s_fb[(py + 4 + fr) * FB_W + (px + 1 + fc)] = COL_FG;
            }
        }
    }
    SDL_UpdateTexture(s_texture, NULL, s_fb, FB_W * (int)sizeof(uint32_t));
    SDL_RenderCopy(s_renderer, s_texture, NULL, NULL);
    SDL_RenderPresent(s_renderer);
}

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    game_t g;
    int running = 1;

    (void)argc; (void)argv;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        SDL_Log("SDL_Init: %s", SDL_GetError());
        return 1;
    }

    s_window = SDL_CreateWindow(
        "GAMENAME",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        FB_W * 2, FB_H * 2,
        SDL_WINDOW_SHOWN
    );
    if (!s_window) { SDL_Log("Window: %s", SDL_GetError()); SDL_Quit(); return 1; }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!s_renderer) s_renderer = SDL_CreateRenderer(s_window, -1, SDL_RENDERER_SOFTWARE);
    if (s_renderer) SDL_RenderSetLogicalSize(s_renderer, FB_W, FB_H);
    if (!s_renderer) { SDL_Log("Renderer: %s", SDL_GetError()); SDL_DestroyWindow(s_window); SDL_Quit(); return 1; }

    s_texture = SDL_CreateTexture(s_renderer, SDL_PIXELFORMAT_ARGB8888,
                                  SDL_TEXTUREACCESS_STREAMING, FB_W, FB_H);
    if (!s_texture) { SDL_DestroyRenderer(s_renderer); SDL_DestroyWindow(s_window); SDL_Quit(); return 1; }

    game_init(&g);
    render_frame(&g);
    hal_swap();

    while (running) {
        SDL_Event ev;
        int input = 0;

        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) running = 0;
            else if (ev.type == SDL_KEYDOWN) {
                switch (ev.key.keysym.sym) {
                    case SDLK_ESCAPE: running = 0; break;
                    case SDLK_w: case SDLK_UP:    input = 'w'; break;
                    case SDLK_s: case SDLK_DOWN:   input = 's'; break;
                    case SDLK_a: case SDLK_LEFT:   input = 'a'; break;
                    case SDLK_d: case SDLK_RIGHT:  input = 'd'; break;
                    case SDLK_SPACE:               input = ' '; break;
                    case SDLK_RETURN:              input = '\r'; break;
                    default: break;
                }
            }
        }

        if (input) {
            game_tick(&g, input);
            render_frame(&g);
            hal_swap();
        }

        SDL_Delay(16);
    }

    SDL_DestroyTexture(s_texture);
    SDL_DestroyRenderer(s_renderer);
    SDL_DestroyWindow(s_window);
    SDL_Quit();
    return 0;
}
EOF
    sed -i.bak "s/GAMENAME/$GAME/g" "$GDIR/src/platform/sdl2/main.c" && rm -f "$GDIR/src/platform/sdl2/main.c.bak"
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════

case "$BASE" in
    risc1) gen_risc1 ;;
    risc2) gen_risc2 ;;
    risc3) gen_risc2 ;;  # risc3 uses C template too
    *)     echo "Error: unknown base ISA '$BASE'"; exit 1 ;;
esac

touch "$GDIR/.user-game"
echo "  Game files created in games/$GAME/"
