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
.PHONY: all run clean download-spectrum-rom download-tv80

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

# ── Download TV80 Z80 CPU core ──────────────────────────────────────────────
download-tv80:
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
