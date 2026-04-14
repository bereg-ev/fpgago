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

# ── Game catalog ────────────────────────────────────────────────────────────
GAMES_PRG_BASE = https://www.zimmers.net/anonftp/pub/cbm/plus4/Games/misc
GAMES_BAS_BASE = https://raw.githubusercontent.com/GReaperEx/bcg/master

GAME_hangman    = $(GAMES_PRG_BASE)/h/Hangman.prg|prg|Hangman word game
GAME_mastermind = $(GAMES_PRG_BASE)/m/Mastermind.prg|prg|Mastermind code-breaking
GAME_nim        = $(GAMES_PRG_BASE)/n/Nim.prg|prg|Nim strategy game
GAME_dice       = $(GAMES_PRG_BASE)/d/Dice.prg|prg|Dice game
GAME_battleship = $(GAMES_PRG_BASE)/b/Battleship.prg|prg|Battleship
GAME_roulette   = $(GAMES_PRG_BASE)/c/C16_Roulette.prg|prg|Casino roulette
GAME_guessnr    = $(GAMES_PRG_BASE)/g/Guess_The_Number.prg|prg|Guess the number
GAME_tictactoe  = $(GAMES_PRG_BASE)/t/Tic-Tac-Toe_Freesoft_Limited.prg|prg|Tic-tac-toe
GAME_slot       = $(GAMES_PRG_BASE)/s/Slot!.prg|prg|Slot machine
GAME_adventure  = $(GAMES_PRG_BASE)/a/Adventure.prg|prg|Text adventure
GAME_prince     = $(GAMES_PRG_BASE)/p/Prince_Of_Persia_(fix_ACW).prg|prg|Prince of Persia
GAME_wizardwor  = $(GAMES_PRG_BASE)/w/Wizard%20Of%20Wor.prg|prg|Wizard of Wor
GAME_wizardakyrz = $(GAMES_PRG_BASE)/w/Wizard%20Of%20Akyrz.prg|prg|Wizard of Akyrz
GAME_guess      = $(GAMES_BAS_BASE)/guess.bas|bas|Number guessing game
GAME_lunar      = $(GAMES_BAS_BASE)/lunar.bas|bas|Lunar lander simulation
GAME_hammurabi  = $(GAMES_BAS_BASE)/hammurabi.bas|bas|Kingdom management

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
    --converge-limit 500 \
    -CFLAGS  "$(shell sdl2-config --cflags) -DSIM_TITLE='\"$(or $(SIM_GAME),Commodore Plus/4) — plus4 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/fpgated.v \
    $(CPU)/cpu_6502.v \
    $(CPU)/ALU.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-plus4-rom download-plus4-game run-plus4-game list-plus4-games download-cpu

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

# ── List available games ─────────────────────────────────────────────────────
list-plus4-games:
	@echo ""
	@echo "  Available Plus/4 games:"
	@echo ""
	@echo "  PRG games (from zimmers.net — BASIC text games, pre-loaded):"
	@echo "    hangman      Hangman word game"
	@echo "    mastermind   Mastermind code-breaking"
	@echo "    nim          Nim strategy game"
	@echo "    dice         Dice game"
	@echo "    battleship   Battleship"
	@echo "    roulette     Casino roulette"
	@echo "    guessnr      Guess the number"
	@echo "    tictactoe    Tic-tac-toe"
	@echo "    slot         Slot machine"
	@echo "    adventure    Text adventure"
	@echo "    prince       Prince of Persia"
	@echo "    wizardwor    Wizard of Wor"
	@echo "    wizardakyrz  Wizard of Akyrz"
	@echo ""
	@echo "  BAS games (from github.com/GReaperEx/bcg — BASIC source, auto-typed):"
	@echo "    guess        Number guessing game"
	@echo "    lunar        Lunar lander simulation"
	@echo "    hammurabi    Kingdom management"
	@echo ""
	@echo "  Usage:"
	@echo "    make download-game ARCH=plus4 GAME=<name>"
	@echo "    make run-game ARCH=plus4 GAME=<name>"
	@echo ""

# ── Download a specific game ─────────────────────────────────────────────────
download-plus4-game:
	@test -n "$(GAME)" || { echo "Usage: make download-game ARCH=plus4 GAME=<name>"; echo "Run 'make list-games ARCH=plus4' to see available games."; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=plus4'."; exit 1; \
	fi; \
	url=$$(echo "$$game_entry" | cut -d'|' -f1); \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	desc=$$(echo "$$game_entry" | cut -d'|' -f3); \
	echo ""; \
	echo "  ================================================================"; \
	echo "  Commodore Plus/4 Game Download: $(GAME)"; \
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
	echo "  Done! Run with: make run-game ARCH=plus4 GAME=$(GAME)"; \
	echo ""

# ── Build and run a game ─────────────────────────────────────────────────────
run-plus4-game:
	@test -n "$(GAME)" || { echo "Usage: make run-game ARCH=plus4 GAME=<name>"; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=plus4'."; exit 1; \
	fi; \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	if [ "$$fmt" = "prg" ]; then \
	    test -f $(ROMS)/game.hex || { echo "Run 'make download-game ARCH=plus4 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building with PRG game loaded into RAM..."; \
	    rm -rf obj_dir; \
	    verilator $(VFLAGS) -DGAME_PRG $(VSRCS) sim_top.cpp; \
	    echo "Running $(GAME)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	elif [ "$$fmt" = "bas" ]; then \
	    test -f $(ROMS)/game.uart || { echo "Run 'make download-game ARCH=plus4 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building Plus/4 simulation..."; \
	    rm -rf obj_dir; \
	    $(MAKE) all; \
	    echo "Running $(GAME) (auto-typing BASIC source)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	fi
