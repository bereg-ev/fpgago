#
# sim-desktop/Makefile — Plus/4 desktop simulation via Verilator + SDL2
#

REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# ── ROM download URLs (VICE emulator project, GitHub) ───────────────────────
ROM_BASE = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/PLUS4
ROM_BASIC   = basic-318006-01.bin
ROM_KERNAL  = kernal-318004-05.bin
# Character ROM is extracted from KERNAL at offset $1000 ($D000-$D7FF)

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
    -Wno-CASEOVERLAP \
    -Wno-CASEX \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),Commodore Plus/4) — plus4 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/plus4_ted.v \
    $(CPU)/cpu_6502.v \
    $(CPU)/ALU.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-plus4-rom download-cpu

all:
	@if [ ! -f $(ROMS)/basic.hex ] || [ ! -f $(ROMS)/kernal.hex ] || [ ! -f $(ROMS)/chargen.hex ]; then \
	    echo ""; \
	    echo "  ROM hex files not found in $(ROMS)/"; \
	    echo "  Run 'make download-rom ARCH=plus4' to fetch Plus/4 ROMs."; \
	    echo ""; \
	    exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

download-cpu:
	@echo "  6502 CPU is included in the repository. Nothing to download."

clean:
	rm -rf obj_dir $(ROMS)/game.hex $(ROMS)/game.uart $(ROMS)/games

# ── Download and convert Plus/4 ROM files ────────────────────────────────────
download-plus4-rom:
	@echo ""
	@echo "  ================================================================"
	@echo "  Commodore Plus/4 ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  This will download Commodore Plus/4 ROM images from the VICE"
	@echo "  emulator project (https://github.com/VICE-Team/svn-mirror)."
	@echo ""
	@echo "  These ROM images contain proprietary Commodore firmware."
	@echo "  They are Copyright (C) Commodore Business Machines."
	@echo "  They are widely redistributed for preservation and educational"
	@echo "  purposes, but remain under their original copyright."
	@echo ""
	@echo "  By proceeding, you acknowledge that:"
	@echo "    - These ROMs are copyrighted material"
	@echo "    - You accept responsibility for your use of them"
	@echo "    - They are intended for personal/educational use only"
	@echo ""
	@printf "  Proceed with download? [y/N] " && read ans && \
	    case "$$ans" in \
	        [yY]*) ;; \
	        *) echo "  Aborted."; exit 1;; \
	    esac
	@echo ""
	@echo "  Downloading ROMs..."
	@curl -sf -o $(ROMS)/$(ROM_BASIC)   $(ROM_BASE)/$(ROM_BASIC)   && echo "    $(ROM_BASIC) (16KB BASIC 3.5)"
	@curl -sf -o $(ROMS)/$(ROM_KERNAL)  $(ROM_BASE)/$(ROM_KERNAL)  && echo "    $(ROM_KERNAL) (16KB KERNAL)"
	@echo ""
	@echo "  Converting to Verilog hex format..."
	@python3 $(ROMS)/rom_convert.py convert         $(ROMS)/$(ROM_BASIC)   $(ROMS)/basic.hex
	@python3 $(ROMS)/rom_convert.py convert          $(ROMS)/$(ROM_KERNAL)  $(ROMS)/kernal.hex
	@python3 $(ROMS)/rom_convert.py convert-chargen  $(ROMS)/$(ROM_KERNAL) $(ROMS)/chargen.hex
	@echo ""
	@echo "  Done! ROM hex files ready in $(ROMS)/"
	@echo "  Run 'make' to build the simulation."
	@echo ""
