#
# sim-desktop/Makefile — ZX Spectrum desktop simulation via Verilator + SDL2
#

REPO = ../../..
CPU  = ../cpu
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# ── ROM source: FUSE emulator project (SourceForge) ────────────────────────
FUSE_URL = https://sourceforge.net/projects/fuse-emulator/files/fuse/1.6.0/fuse-1.6.0.tar.gz/download

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
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),ZX Spectrum) — spectrum (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/spectrum_keyboard.v \
    $(CPU)/tv80s.v \
    $(CPU)/tv80_core.v \
    $(CPU)/tv80_alu.v \
    $(CPU)/tv80_mcode.v \
    $(CPU)/tv80_reg.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-spectrum-rom download-tv80 download-cpu \
       list-spectrum-games download-spectrum-game run-spectrum-game

# Also update error messages to use unified syntax


all:
	@if [ ! -f $(CPU)/tv80s.v ]; then \
	    echo ""; \
	    echo "  TV80 Z80 core not found. Run 'make download-tv80' first."; \
	    echo ""; \
	    exit 1; \
	fi
	@if [ ! -f $(ROMS)/rom.hex ]; then \
	    echo ""; \
	    echo "  Spectrum ROM not found. Run 'make download-spectrum-rom' first."; \
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

# ── Game support (.sna snapshots) ───────────────────────────────────────────
# Users provide their own .sna files from Spectrum archives.
# Recommended sources:
#   spectrumcomputing.co.uk — largest archive, search and download
#   worldofspectrum.net     — classic archive

list-spectrum-games:
	@echo ""
	@echo "  ZX Spectrum Game Loader"
	@echo ""
	@echo "  This loads .sna (48K snapshot) files into the Spectrum simulation."
	@echo "  Download .sna files from: spectrumcomputing.co.uk"
	@echo ""
	@echo "  Flagship games to search for (save as <name>.sna):"
	@echo "    dizzy              Dizzy - puzzle platformer"
	@echo "    elite              Elite - space trading"
	@echo "    horace             Hungry Horace - maze game"
	@echo "    loderunner         Lode Runner - platform puzzler"
	@echo "    manicminer         Manic Miner - platform classic"
	@echo "    pacman             Pac-Man - arcade"
	@echo "    saberwulf          Sabre Wulf - action adventure"
	@echo "    tetris             Tetris - puzzle"
	@echo ""
	@echo "  Usage:"
	@echo "    1. Download a .sna file and place it in arch/spectrum/roms/games/"
	@echo "    2. make download-game ARCH=spectrum GAME=<filename>"
	@echo "    3. make run-game ARCH=spectrum"
	@echo ""
	@if [ -d $(ROMS)/games ]; then \
	    snaps=$$(ls $(ROMS)/games/*.sna 2>/dev/null); \
	    if [ -n "$$snaps" ]; then \
	        echo "  Already downloaded:"; \
	        for f in $$snaps; do echo "    $$(basename $$f .sna)"; done; \
	        echo ""; \
	    fi; \
	fi

# Load a .sna file from the games directory
download-spectrum-game:
	@test -n "$(GAME)" || { echo "Usage: make load-sna ARCH=spectrum GAME=<name>"; exit 1; }
	@mkdir -p $(ROMS)/games
	@snafile="$(ROMS)/games/$(GAME).sna"; \
	if [ ! -f "$$snafile" ]; then \
	    echo ""; \
	    echo "  File not found: $$snafile"; \
	    echo ""; \
	    echo "  Steps:"; \
	    echo "    1. Go to: https://spectrumcomputing.co.uk"; \
	    echo "    2. Search for '$(GAME)'"; \
	    echo "    3. Download the .sna snapshot file"; \
	    echo "    4. Save it as: arch/spectrum/roms/games/$(GAME).sna"; \
	    echo "    5. Re-run: make download-game ARCH=spectrum GAME=$(GAME)"; \
	    echo ""; \
	    case "$$(uname -s)" in \
	        Darwin) open "https://spectrumcomputing.co.uk/?search=$(GAME)" 2>/dev/null ;; \
	        Linux)  xdg-open "https://spectrumcomputing.co.uk/?search=$(GAME)" 2>/dev/null ;; \
	    esac; \
	    exit 1; \
	fi; \
	echo ""; \
	echo "  Converting .sna snapshot..."; \
	python3 $(ROMS)/sna2hex.py "$$snafile" $(ROMS)/game.hex; \
	echo ""; \
	echo "  Done! Run with: make run-game ARCH=spectrum"; \
	echo ""

run-spectrum-game:
	@test -f $(ROMS)/game.hex || { echo "No game loaded. Run 'make list-games ARCH=spectrum' for instructions."; exit 1; }
	@echo "Building with .sna snapshot..."
	@rm -rf obj_dir
	verilator $(VFLAGS) -DGAME_SNA $(VSRCS) sim_top.cpp
	@echo "Running game..."
	./obj_dir/Vsoc

# ── Download TV80 Z80 CPU core ──────────────────────────────────────────────
download-tv80 download-cpu:
	@bash $(CPU)/download_tv80.sh

# ── Download and convert Spectrum ROM ───────────────────────────────────────
download-spectrum-rom:
	@echo ""
	@echo "  ================================================================"
	@echo "  ZX Spectrum 48K ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  This will download the ZX Spectrum 48K ROM image."
	@echo "  The ROM is Copyright (C) Amstrad plc."
	@echo "  Amstrad has given permission for Spectrum ROMs to be"
	@echo "  redistributed for emulation purposes."
	@echo ""
	@printf "  Proceed with download? [y/N] " && read ans && \
	    case "$$ans" in \
	        [yY]*) ;; \
	        *) echo "  Aborted."; exit 1;; \
	    esac
	@echo ""
	@echo "  Downloading FUSE emulator (contains Spectrum ROMs)..."
	@tmpfile=$$(mktemp); \
	curl -sfL -o "$$tmpfile" "$(FUSE_URL)" || { echo "  Error: download failed."; rm -f "$$tmpfile"; exit 1; }; \
	echo "  Extracting 48.rom..."; \
	tar xzf "$$tmpfile" --strip-components=2 -C $(ROMS) fuse-1.6.0/roms/48.rom; \
	rm -f "$$tmpfile"; \
	mv $(ROMS)/48.rom $(ROMS)/spectrum48.bin; \
	echo "    spectrum48.bin ($$(wc -c < $(ROMS)/spectrum48.bin | tr -d ' ') bytes)"
	@echo ""
	@echo "  Converting to Verilog hex format..."
	@python3 $(ROMS)/rom_convert.py $(ROMS)/spectrum48.bin $(ROMS)/rom.hex
	@echo ""
	@echo "  Done! Run 'make' to build the simulation."
	@echo ""
