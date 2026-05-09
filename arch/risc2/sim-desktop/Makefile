#
# sim-desktop/Makefile — Desktop simulation via Verilator + SDL2
#
# Purpose : Compiles the actual Verilog SoC to C++ (Verilator) and links
#           against SDL2 to render LCD output in a window.  Keyboard input
#           is forwarded to the CPU through the UART interface.
#
# Usage   : cd arch/risc2/sim-desktop
#           make          — build (first run takes ~30 s to verilate)
#           make run      — build + run
#           make clean    — remove generated files
#
# Prerequisite: brew install verilator
#

REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..

# ── Hardware version (HW=v1 default | HW=v2 selects PSRAM path) ─────────────
HW ?= v1
ifeq ($(HW),v2)
  HW_DEFINE = -DHW_V2
  HW_VSRCS  = $(PERI)/psram.v $(PERI)/psram_iface.v psram_model.v
else
  HW_DEFINE = -DHW_V1
  HW_VSRCS  =
endif

# ── Verilator flags ─────────────────────────────────────────────────────────
VFLAGS = \
    --cc \
    --exe \
    --build \
    --top-module soc \
    -DSIMULATION \
    -DSIMULATION_SDL \
    $(HW_DEFINE) \
    -I$(CPU) \
    -I$(PROJ) \
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
    -CFLAGS  "$(shell sdl2-config --cflags) $(HW_DEFINE) -DSIM_TITLE='\"$(or $(SIM_GAME),FPGAgo) — $(or $(SIM_ARCH),risc2) (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
# sdram_model.v is listed INSTEAD OF $(PERI)/sdram.v (stub replacement).
# ecp5_simul.v provides simulation stubs for ECP5 primitives (OSCG etc.).
# psram.v + psram_iface.v + psram_model.v are added when HW=v2.
# The order matters: Verilator uses the first definition it sees.
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/interface-sdram.v \
    $(CPU)/cpu_risc2.v \
    $(CPU)/alu_risc2.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/bootloader.v \
    $(PERI)/debugger.v \
    $(PERI)/lcd_out.v \
    $(PERI)/lcd_char.v \
    $(PERI)/audio.v \
    $(PERI)/timer.v \
    $(PERI)/icache.v \
    $(PERI)/dcache.v \
    $(HW_VSRCS) \
    sdram_model.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean

all:
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir
