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

# ── Game catalog ────────────────────────────────────────────────────────────
# Games auto-downloaded from spectrumcomputing.co.uk as .tzx/.tap, converted to .sna
SC = https://spectrumcomputing.co.uk/pub/sinclair

GAME_horace     = $(SC)/games/h/HungryHorace.tzx.zip|Hungry Horace - Pac-Man style maze
GAME_chuckie    = $(SC)/games/c/ChuckieEgg.tzx.zip|Chuckie Egg - platform arcade
GAME_boulder    = $(SC)/games/b/BoulderDash.tzx.zip|Boulder Dash - digging puzzle
GAME_frogger    = $(SC)/games/f/Frogger.tzx.zip|Frogger - road crossing arcade
GAME_trashman   = $(SC)/games/t/Trashman.tzx.zip|Trashman - dodge traffic
GAME_penetrator = $(SC)/games/p/Penetrator.tzx.zip|Penetrator - Scramble-style shooter
GAME_skool      = $(SC)/games/s/SkoolDaze.tzx.zip|Skool Daze - school simulation
GAME_dizzy      = $(SC)/games/d/Dizzy.tzx.zip|Dizzy - puzzle platformer

list-spectrum-games:
	@echo ""
	@echo "  Available ZX Spectrum games:"
	@echo ""
	@echo "    horace         Hungry Horace - Pac-Man style maze"
	@echo "    chuckie        Chuckie Egg - platform arcade"
	@echo "    boulder        Boulder Dash - digging puzzle"
	@echo "    frogger        Frogger - road crossing arcade"
	@echo "    trashman       Trashman - dodge traffic"
	@echo "    penetrator     Penetrator - Scramble-style shooter"
	@echo "    skool          Skool Daze - school simulation"
	@echo "    dizzy          Dizzy - puzzle platformer"
	@echo ""
	@echo "  Usage:"
	@echo "    make download-game ARCH=spectrum GAME=<name>"
	@echo "    make run-game ARCH=spectrum GAME=<name>"
	@echo ""

download-spectrum-game:
	@test -n "$(GAME)" || { echo "Usage: make download-game ARCH=spectrum GAME=<name>"; echo "Run 'make list-games ARCH=spectrum'."; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=spectrum'."; exit 1; \
	fi; \
	url=$$(echo "$$game_entry" | cut -d'|' -f1); \
	desc=$$(echo "$$game_entry" | cut -d'|' -f2); \
	echo ""; \
	echo "  Downloading: $$desc"; \
	mkdir -p $(ROMS)/games; \
	zipfile="$(ROMS)/games/$(GAME).tzx.zip"; \
	curl -sfL -o "$$zipfile" "$$url" || { echo "  Error: download failed."; exit 1; }; \
	echo "  Extracting..."; \
	unzip -qo "$$zipfile" -d $(ROMS)/games/; \
	tzxfile=$$(ls $(ROMS)/games/*.tzx $(ROMS)/games/*.tap 2>/dev/null | head -1); \
	if [ -z "$$tzxfile" ]; then echo "  Error: no .tzx/.tap found in archive."; exit 1; fi; \
	echo "  Converting to snapshot..."; \
	python3 $(ROMS)/tzx2sna.py "$$tzxfile" $(ROMS)/games/$(GAME).sna; \
	python3 $(ROMS)/sna2hex.py $(ROMS)/games/$(GAME).sna $(ROMS)/game.hex; \
	echo ""; \
	echo "  Done! Run with: make run-game ARCH=spectrum GAME=$(GAME)"; \
	echo ""

run-spectrum-game:
	@test -f $(ROMS)/game.hex || { echo "No game loaded. Run 'make download-game ARCH=spectrum GAME=<name>' first."; exit 1; }
	@echo "Building with snapshot..."
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
