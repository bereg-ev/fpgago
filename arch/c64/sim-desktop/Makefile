#
# sim-desktop/Makefile — Commodore 64 desktop simulation via Verilator + SDL2
#

REPO = ../../..
CPU  = ../cpu
PET_CPU = ../../pet/cpu
VIC  = ../vic
SID  = ../sid
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# ── ROM download URLs (VICE project) ──────────────────────────────────────
ROM_BASE = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/C64
ROM_BASIC   = basic-901226-01.bin
ROM_KERNAL  = kernal-901227-03.bin
ROM_CHARGEN = chargen-901225-01.bin

# ── Verilator flags ─────────────────────────────────────────────────────────
VFLAGS = \
    --cc \
    --exe \
    --build \
    --top-module soc \
    -DSIMULATION \
    -DSIMULATION_SDL \
    -I$(CPU) \
    -I$(PET_CPU) \
    -I$(VIC) \
    -I$(SID) \
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
    -Wno-MULTIDRIVEN \
    -Wno-LATCH \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),Commodore 64) — c64 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-c64-rom download-cpu list-c64-games download-c64-game run-c64-game

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/c64_keyboard.v \
    $(CPU)/cpu_6510.v \
    $(PET_CPU)/cpu_6502.v \
    $(PET_CPU)/ALU.v \
    $(CPU)/mos6526.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

all:
	@if [ ! -f $(CPU)/mos6526.v ]; then \
	    echo "  C64 chips not found. Run 'make download-cpu ARCH=c64' first."; exit 1; \
	fi
	@if [ ! -f $(ROMS)/basic.hex ]; then \
	    echo "  ROMs not found. Run 'make download-rom ARCH=c64' first."; exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

clean:
	rm -rf obj_dir

download-cpu:
	@bash $(CPU)/download_chips.sh

download-c64-rom:
	@echo ""
	@echo "  ================================================================"
	@echo "  Commodore 64 ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  Downloading C64 ROMs from VICE project..."
	@echo "  These ROMs are Copyright (C) Commodore Business Machines."
	@echo ""
	@printf "  Proceed? [y/N] " && read ans && \
	    case "$$ans" in [yY]*) ;; *) echo "  Aborted."; exit 1;; esac
	@echo ""
	@curl -sf -o $(ROMS)/$(ROM_BASIC)   $(ROM_BASE)/$(ROM_BASIC)   && echo "    $(ROM_BASIC) (8KB BASIC)"
	@curl -sf -o $(ROMS)/$(ROM_KERNAL)  $(ROM_BASE)/$(ROM_KERNAL)  && echo "    $(ROM_KERNAL) (8KB KERNAL)"
	@curl -sf -o $(ROMS)/$(ROM_CHARGEN) $(ROM_BASE)/$(ROM_CHARGEN) && echo "    $(ROM_CHARGEN) (4KB Character ROM)"
	@echo ""
	@echo "  Converting..."
	@python3 $(ROMS)/rom_convert.py $(ROMS)/$(ROM_BASIC) $(ROMS)/basic.hex
	@python3 $(ROMS)/rom_convert.py $(ROMS)/$(ROM_KERNAL) $(ROMS)/kernal.hex
	@python3 $(ROMS)/rom_convert.py $(ROMS)/$(ROM_CHARGEN) $(ROMS)/chargen.hex
	@echo ""
	@echo "  Done!"
	@echo ""

list-c64-games:
	@echo ""
	@echo "  Commodore 64 Game Loader"
	@echo ""
	@echo "  Download .prg or .d64 files from csdb.dk, c64.com, or gamebase64.com"
	@echo "  and place them in arch/c64/roms/games/"
	@echo ""
	@echo "  Single-load games (work now):"
	@echo "    zaxxon          Zaxxon"
	@echo "    boulder         Boulder Dash"
	@echo "    frogger         Frogger"
	@echo "    pacman          Pac-Man"
	@echo "    gianasisters    Giana Sisters"
	@echo "    bubblebobble    Bubble Bobble"
	@echo "    thrust          Thrust"
	@echo "    jumpman         Jumpman Junior"
	@echo "    wizardofwor     Wizard of Wor"
	@echo "    archon          Archon"
	@echo ""
	@echo "  Multi-load games (need disk emulation — future):"
	@echo "    pirates         Pirates!"
	@echo "    newyorkcity     New York City"
	@echo "    ghostbusters    Ghostbusters"
	@echo "    impossible      Impossible Mission"
	@echo ""
	@echo "  Usage:"
	@echo "    make download-game ARCH=c64 GAME=<name>    (convert .prg)"
	@echo "    make run-game ARCH=c64 GAME=<name>         (build + run)"
	@echo ""
	@if [ -d $(ROMS)/games ]; then \
	    files=$$(ls $(ROMS)/games/*.prg $(ROMS)/games/*.d64 2>/dev/null); \
	    if [ -n "$$files" ]; then \
	        echo "  Ready to play:"; \
	        for f in $$files; do \
	            base=$$(basename "$$f"); \
	            name=$${base%.*}; \
	            ext=$${base##*.}; \
	            echo "    $$name  ($$ext)"; \
	        done; \
	        echo ""; \
	    fi; \
	fi

download-c64-game:
	@test -n "$(GAME)" || { echo "Usage: make download-game ARCH=c64 GAME=<name>"; exit 1; }
	@mkdir -p $(ROMS)/games
	@prgfile="$(ROMS)/games/$(GAME).prg"; \
	d64file="$(ROMS)/games/$(GAME).d64"; \
	if [ -f "$$prgfile" ]; then \
	    echo "  Converting .prg..."; \
	    python3 $(ROMS)/prg2hex.py "$$prgfile" $(ROMS)/game.hex; \
	elif [ -f "$$d64file" ]; then \
	    echo "  Extracting PRG from .d64..."; \
	    python3 $(ROMS)/d64extract.py "$$d64file" "$$prgfile"; \
	    echo "  Converting .prg..."; \
	    python3 $(ROMS)/prg2hex.py "$$prgfile" $(ROMS)/game.hex; \
	else \
	    echo ""; \
	    echo "  Place $(GAME).prg or $(GAME).d64 in arch/c64/roms/games/"; \
	    echo "  Sources: csdb.dk  c64.com  gamebase64.com"; \
	    echo ""; \
	    exit 1; \
	fi; \
	echo "  Ready: make run-game ARCH=c64 GAME=$(GAME)"

run-c64-game:
	@test -n "$(GAME)" || { echo "Usage: make run-game ARCH=c64 GAME=<name>"; exit 1; }
	@mkdir -p $(ROMS)/games
	@prgfile="$(ROMS)/games/$(GAME).prg"; \
	d64file="$(ROMS)/games/$(GAME).d64"; \
	if [ -f "$$prgfile" ]; then \
	    echo "  Converting .prg..."; \
	    python3 $(ROMS)/prg2hex.py "$$prgfile" $(ROMS)/game.hex; \
	elif [ -f "$$d64file" ]; then \
	    echo "  Extracting PRG from .d64..."; \
	    python3 $(ROMS)/d64extract.py "$$d64file" "$$prgfile"; \
	    echo "  Converting .prg..."; \
	    python3 $(ROMS)/prg2hex.py "$$prgfile" $(ROMS)/game.hex; \
	else \
	    echo "  Place $(GAME).prg or $(GAME).d64 in arch/c64/roms/games/"; \
	    echo "  Sources: csdb.dk  c64.com  gamebase64.com"; \
	    exit 1; \
	fi
	@echo "  Building..."
	@rm -rf obj_dir
	@$(MAKE) -s SIM_GAME="$(GAME)" _build-game

_build-game:
	verilator $(VFLAGS) -DGAME_PRG -CFLAGS "-DGAME_PRG" $(VSRCS) sim_top.cpp
	@echo "  Running $(GAME)..."
	@./obj_dir/Vsoc
