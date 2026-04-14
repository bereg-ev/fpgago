REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

VFLAGS = \
    --cc --exe --build --top-module soc \
    -DSIMULATION -DSIMULATION_SDL \
    -I$(CPU) -I$(PROJ) --Mdir obj_dir --no-timing \
    -Wno-BLKSEQ -Wno-UNDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-UNSIGNED -Wno-IMPLICIT \
    -Wno-CASEOVERLAP -Wno-CASEX -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"Commodore C16 — c16 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/c16.v \
    $(PROJ)/ted.v \
    $(PROJ)/mos8501.v \
    $(PROJ)/gen_ram.v \
    $(PROJ)/colors_to_rgb.v \
    $(PROJ)/c16_keymatrix.v \
    $(PROJ)/mos6529.v \
    $(PROJ)/gen_uart.v \
    $(PROJ)/basic_rom.v \
    $(PROJ)/kernal_rom.v \
    $(PROJ)/sigma_delta_dac.v \
    $(PROJ)/stubs.v \
    $(CPU)/cpu_6502.v \
    $(CPU)/ALU.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

.PHONY: all run clean download-c16-rom download-cpu

all:
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir

download-c16-rom:
	@echo "  ROMs are included in the repository. Nothing to download."

download-cpu:
	@echo "  6502 CPU is included in the repository. Nothing to download."
