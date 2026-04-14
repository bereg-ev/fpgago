#
# sim-desktop/Makefile — Desktop simulation via Verilator + SDL2
#
# Purpose : Compiles the RISC1 character-LCD SoC to C++ (Verilator) and links
#           against SDL2 to render LCD output in a window.  Keyboard input
#           is forwarded to the CPU through the UART interface (WASD controls).
#
# Usage   : cd arch/risc1/sim-desktop
#           make          — build
#           make run      — build + run
#           make clean    — remove generated files
#
# Prerequisite: brew install verilator sdl2
#

REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
FONT = $(REPO)/util/font2init
PROJ = ..

# ── Verilator flags ─────────────────────────────────────────────────────────
VFLAGS = \
    --cc \
    --exe \
    --build \
    --top-module soc \
    -DSIMULATION \
    -DSIMULATION_SDL \
    -I$(CPU) \
    -I$(PROJ) \
    -I$(FONT) \
    --Mdir obj_dir \
    --no-timing \
    -Wno-BLKSEQ \
    -Wno-UNDRIVEN \
    -Wno-UNOPTFLAT \
    -Wno-PINMISSING \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-WIDTHCONCAT \
    -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE \
    -Wno-INITIALDLY \
    -Wno-UNSIGNED \
    -Wno-IMPLICIT \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),FPGAgo) — $(or $(SIM_ARCH),risc1) (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
# soc_sim.v and lcd_char_sim.v are pre-processed copies with `include
# directives inside parameter lists replaced by inline data (Verilator
# does not support `include inside #(...) parameter overrides).
VSRCS = \
    soc_sim.v \
    $(CPU)/cpu_risc1.v \
    $(CPU)/alu_risc1.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v \
    $(PERI)/debugger.v \
    lcd_char_sim.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean preprocess

preprocess:
	python3 preprocess.py

all: preprocess
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir soc_sim.v lcd_char_sim.v
