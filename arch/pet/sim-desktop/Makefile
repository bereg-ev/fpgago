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

# ── Game catalog ────────────────────────────────────────────────────────────
# Each game: NAME = url|format|description
# format: prg (binary, loaded into RAM) or bas (text, auto-typed via UART)
GAMES_PRG_BASE = https://www.zimmers.net/anonftp/pub/cbm/pet/games/english
GAMES_BAS_BASE = https://raw.githubusercontent.com/GReaperEx/bcg/master

GAME_blackjack   = $(GAMES_PRG_BASE)/blackjack.prg|prg|Blackjack card game
GAME_startrek    = $(GAMES_PRG_BASE)/startrek.prg|prg|Star Trek space combat
GAME_supertrek   = $(GAMES_PRG_BASE)/super_trek.prg|prg|Super Trek strategy game
GAME_adventure   = $(GAMES_PRG_BASE)/adventure-2.prg|prg|Text adventure game
GAME_breakout    = $(GAMES_PRG_BASE)/breakout.prg|prg|Breakout arcade game
GAME_canyon      = $(GAMES_PRG_BASE)/canyon.prg|prg|Canyon bomber
GAME_checkers    = $(GAMES_PRG_BASE)/checkers.prg|prg|Checkers board game
GAME_dungeon     = $(GAMES_PRG_BASE)/dungeon.prg|prg|Dungeon crawler
GAME_hangman     = $(GAMES_PRG_BASE)/hangman1.prg|prg|Hangman word game
GAME_guess       = $(GAMES_BAS_BASE)/guess.bas|bas|Number guessing game
GAME_lunar       = $(GAMES_BAS_BASE)/lunar.bas|bas|Lunar lander simulation
GAME_hammurabi   = $(GAMES_BAS_BASE)/hammurabi.bas|bas|Kingdom management
GAME_tictactoe   = $(GAMES_BAS_BASE)/tictactoe1.bas|bas|Tic-tac-toe
GAME_nim         = $(GAMES_BAS_BASE)/nim.bas|bas|Nim mathematical game
GAME_poker       = $(GAMES_BAS_BASE)/poker.bas|bas|Poker card game

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
.PHONY: all run clean download-pet-roms download-pet-game run-pet-game list-pet-games download-cpu

all:
	@if [ ! -f $(ROMS)/basic.hex ] || [ ! -f $(ROMS)/kernal.hex ] || [ ! -f $(ROMS)/chargen.hex ]; then \
	    echo ""; \
	    echo "  ROM hex files not found in $(ROMS)/"; \
	    echo "  Run 'make download-rom ARCH=pet' to fetch Commodore PET ROMs."; \
	    echo ""; \
	    exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

# ── Download CPU (6502 is in-repo, nothing to do) ──────────────────────────
download-cpu:
	@echo "  6502 CPU is included in the repository. Nothing to download."

clean:
	rm -rf obj_dir $(ROMS)/game.hex $(ROMS)/game.uart $(ROMS)/games

# ── List available games ─────────────────────────────────────────────────────
list-pet-games:
	@echo ""
	@echo "  Available PET games:"
	@echo ""
	@echo "  PRG games (from zimmers.net — binary, pre-loaded into RAM):"
	@echo "    blackjack    Blackjack card game"
	@echo "    startrek     Star Trek space combat"
	@echo "    supertrek    Super Trek strategy game"
	@echo "    adventure    Text adventure game"
	@echo "    breakout     Breakout arcade game"
	@echo "    canyon       Canyon bomber"
	@echo "    checkers     Checkers board game"
	@echo "    dungeon      Dungeon crawler"
	@echo "    hangman      Hangman word game"
	@echo ""
	@echo "  BAS games (from github.com/GReaperEx/bcg — BASIC source, auto-typed):"
	@echo "    guess        Number guessing game"
	@echo "    lunar        Lunar lander simulation"
	@echo "    hammurabi    Kingdom management"
	@echo "    tictactoe    Tic-tac-toe"
	@echo "    nim          Nim mathematical game"
	@echo "    poker        Poker card game"
	@echo ""
	@echo "  Usage:"
	@echo "    make download-game ARCH=pet GAME=<name>"
	@echo "    make run-game ARCH=pet GAME=<name>"
	@echo ""

# ── Download a specific game ─────────────────────────────────────────────────
download-pet-game:
	@test -n "$(GAME)" || { echo "Usage: make download-game ARCH=pet GAME=<name>"; echo "Run 'make list-games ARCH=pet' to see available games."; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=pet'."; exit 1; \
	fi; \
	url=$$(echo "$$game_entry" | cut -d'|' -f1); \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	desc=$$(echo "$$game_entry" | cut -d'|' -f3); \
	echo ""; \
	echo "  ================================================================"; \
	echo "  Commodore PET Game Download: $(GAME)"; \
	echo "  ================================================================"; \
	echo ""; \
	echo "  $$desc"; \
	echo "  Source: $$url"; \
	echo "  Format: $$fmt"; \
	echo ""; \
	echo "  These game programs are distributed for preservation and"; \
	echo "  educational purposes. Original copyrights may still apply."; \
	echo ""; \
	printf "  Proceed with download? [y/N] " && read ans && \
	    case "$$ans" in \
	        [yY]*) ;; \
	        *) echo "  Aborted."; exit 1;; \
	    esac; \
	echo ""; \
	mkdir -p $(ROMS)/games; \
	outfile="$(ROMS)/games/$(GAME).$$fmt"; \
	echo "  Downloading..."; \
	curl -sf -o "$$outfile" "$$url" || { echo "  Error: download failed."; exit 1; }; \
	echo "  Saved to $$outfile"; \
	echo ""; \
	if [ "$$fmt" = "prg" ]; then \
	    echo "  Converting PRG to RAM hex + autorun..."; \
	    python3 $(ROMS)/prg2hex.py "$$outfile" $(ROMS)/game.hex $(ROMS)/game.uart; \
	elif [ "$$fmt" = "bas" ]; then \
	    echo "  Converting BAS to UART input..."; \
	    python3 $(ROMS)/bas2uart.py "$$outfile" $(ROMS)/game.uart; \
	fi; \
	echo ""; \
	echo "  Done! Run with: make run-game ARCH=pet GAME=$(GAME)"; \
	echo ""

# ── Build and run a game ─────────────────────────────────────────────────────
run-pet-game:
	@test -n "$(GAME)" || { echo "Usage: make run-game ARCH=pet GAME=<name>"; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=pet'."; exit 1; \
	fi; \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	if [ "$$fmt" = "prg" ]; then \
	    test -f $(ROMS)/game.hex || { echo "Run 'make download-game ARCH=pet GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building with PRG game loaded into RAM..."; \
	    rm -rf obj_dir; \
	    verilator $(VFLAGS) -DGAME_PRG $(VSRCS) sim_top.cpp; \
	    echo "Running $(GAME)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	elif [ "$$fmt" = "bas" ]; then \
	    test -f $(ROMS)/game.uart || { echo "Run 'make download-game ARCH=pet GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building PET simulation..."; \
	    $(MAKE) all; \
	    echo "Running $(GAME) (auto-typing BASIC source)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	fi

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
