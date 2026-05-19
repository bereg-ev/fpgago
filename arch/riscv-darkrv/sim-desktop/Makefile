#
# sim-desktop/Makefile — Verilator + SDL2 simulation of the DarkRISCV SoC.
#
# Game-agnostic.  The current rom.hex must already be installed at ../rom.hex
# by a game's platforms/riscv-darkrv/Makefile (`run-verilator` target).
#
# Usage:
#   make          — verilate the SoC (uses whatever ../rom.hex is current)
#   make run      — build + run (opens an SDL2 window; ESC to quit)
#   make clean    — remove generated files
#
# From the repo root, prefer:
#   make run GAME=labyrinth ARCH=riscv-darkrv TARGET=verilator
#   make run GAME=labyrinth ARCH=riscv-darkrv TARGET=verilator RAM=psram HW=v2
#
# Prerequisite: brew install verilator sdl2
#

PROJ    = ..
PERI    = $(PROJ)/../../peripheral
TOP     = soc

# ── HW + RAM (defaults match build.mk) ───────────────────────────────────
HW  ?= v2
RAM ?= bram

ifneq ($(filter-out v1 v2,$(HW)),)
  $(error HW=$(HW) is not valid; expected HW=v1 or HW=v2)
endif
ifneq ($(filter-out bram sdram psram ddr3,$(RAM)),)
  $(error RAM=$(RAM) is not valid; expected RAM=bram|sdram|psram|ddr3)
endif
ifeq ($(RAM),sdram)
  ifneq ($(HW),v1)
    $(error RAM=sdram requires HW=v1 (currently HW=$(HW)); SDRAM lives on the HW=v1 board)
  endif
endif
ifeq ($(RAM),psram)
  ifneq ($(HW),v2)
    $(error RAM=psram requires HW=v2 (currently HW=$(HW)); QSPI PSRAM lives on the HW=v2 board)
  endif
endif
ifeq ($(RAM),ddr3)
  ifneq ($(HW),v2)
    $(error RAM=ddr3 requires HW=v2 (currently HW=$(HW)); DDR3 lives on the HW=v2 board)
  endif
endif
ifeq ($(RAM),ddr3)
  $(error RAM=ddr3 is not yet implemented for riscv-darkrv (DDR3 not validated on real HW yet). Use RAM=psram, RAM=sdram, or RAM=bram.)
endif

# ── Per-RAM Verilog source list + defines ────────────────────────────────
RAM_VSRCS  =
RAM_DEFINE = -DRAM_BRAM
ifeq ($(RAM),psram)
  RAM_VSRCS  = $(PROJ)/psram_ram.v $(PERI)/psram.v psram_model.v
  RAM_DEFINE = -DRAM_PSRAM
endif
# sdram_model.v defines `module sdram(...)` — it is a drop-in replacement
# for peripheral/sdram.v in sim, so we use it INSTEAD of peripheral/sdram.v.
ifeq ($(RAM),sdram)
  RAM_VSRCS  = $(PROJ)/fb_sdram.v sdram_model.v
  RAM_DEFINE = -DRAM_SDRAM
endif

HW_DEFINE = $(if $(filter v2,$(HW)),-DHW_V2,-DHW_V1)

VFLAGS  = \
    --cc \
    --exe \
    --build \
    --top-module $(TOP) \
    -I$(PROJ) \
    --Mdir obj_dir \
    --no-timing \
    -DSIMULATION \
    $(HW_DEFINE) \
    $(RAM_DEFINE) \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-WIDTHCONCAT \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM \
    -Wno-CASEINCOMPLETE \
    -Wno-CASEX \
    -Wno-INITIALDLY \
    -Wno-UNDRIVEN \
    -Wno-PINMISSING \
    -Wno-UNOPTFLAT \
    -Wno-TIMESCALEMOD \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),test) — $(or $(SIM_ARCH),riscv-darkrv) RAM=$(RAM) (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/cpu_darkrv.v \
    $(PROJ)/darkriscv.v \
    $(RAM_VSRCS)

.PHONY: all run clean
all:
	@test -f $(PROJ)/rom.hex || { \
	    echo ""; \
	    echo "Error: $(PROJ)/rom.hex not found."; \
	    echo "Build a game first, e.g.:"; \
	    echo "    make run GAME=labyrinth ARCH=riscv-darkrv TARGET=verilator"; \
	    echo ""; \
	    exit 1; \
	}
	@echo "[sim-desktop] HW=$(HW)  RAM=$(RAM)"
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: make run"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir
