#
# sim-desktop/Makefile — PET desktop simulation via Verilator + SDL2
#

REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# ── ROM download URLs (VICE emulator project, GitHub) ───────────────────────
ROM_BASE = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/PET
ROM_BASIC   = basic-2.901465-01-02.bin
ROM_KERNAL  = kernal-2.901465-03.bin
ROM_EDITOR  = edit-2-n.901447-24.bin
ROM_CHARGEN = characters-2.901447-10.bin

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
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),Commodore PET) — pet (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/pet_video.v \
    $(PROJ)/pet_keyboard.v \
    $(PROJ)/pet_via.v \
    $(CPU)/cpu_6502.v \
    $(CPU)/ALU.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-pet-roms

all:
	@if [ ! -f $(ROMS)/basic.hex ] || [ ! -f $(ROMS)/kernal.hex ] || [ ! -f $(ROMS)/chargen.hex ]; then \
	    echo ""; \
	    echo "  ROM hex files not found in $(ROMS)/"; \
	    echo "  Run 'make download-pet-roms' to fetch Commodore PET ROMs."; \
	    echo ""; \
	    exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir

# ── Download and convert PET ROM files ───────────────────────────────────────
download-pet-roms:
	@echo ""
	@echo "  ================================================================"
	@echo "  Commodore PET ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  This will download Commodore PET 2001 ROM images from the VICE"
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
	@curl -sf -o $(ROMS)/$(ROM_BASIC)   $(ROM_BASE)/$(ROM_BASIC)   && echo "    $(ROM_BASIC) (8KB BASIC 2.0)"
	@curl -sf -o $(ROMS)/$(ROM_KERNAL)  $(ROM_BASE)/$(ROM_KERNAL)  && echo "    $(ROM_KERNAL) (4KB KERNAL)"
	@curl -sf -o $(ROMS)/$(ROM_EDITOR)  $(ROM_BASE)/$(ROM_EDITOR)  && echo "    $(ROM_EDITOR) (2KB screen editor)"
	@curl -sf -o $(ROMS)/$(ROM_CHARGEN) $(ROM_BASE)/$(ROM_CHARGEN) && echo "    $(ROM_CHARGEN) (2KB character generator)"
	@echo ""
	@echo "  Converting to Verilog hex format..."
	@python3 $(ROMS)/rom_convert.py convert        $(ROMS)/$(ROM_BASIC)   $(ROMS)/basic.hex
	@python3 $(ROMS)/rom_convert.py combine-kernal $(ROMS)/$(ROM_EDITOR) $(ROMS)/$(ROM_KERNAL) $(ROMS)/kernal.hex
	@python3 $(ROMS)/rom_convert.py convert        $(ROMS)/$(ROM_CHARGEN) $(ROMS)/chargen.hex
	@echo ""
	@echo "  Done! ROM hex files ready in $(ROMS)/"
	@echo "  Run 'make' to build the simulation."
	@echo ""
