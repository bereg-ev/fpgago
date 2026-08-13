REPO = ../../..
CPU  = ../../common/cpu/6502
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# 1541 floppy emulator (shared with plus4/c64 and the RP2350 firmware) +
# the shared sim-side IEC glue.  COMMON is absolute (C++ compiles from obj_dir/).
F1541_DIR = $(abspath $(PROJ)/../common/floppy1541)
F1541_CSRCS = $(F1541_DIR)/floppy1541.c $(F1541_DIR)/cpu6502.c $(F1541_DIR)/via6522.c
COMMON = $(abspath $(PROJ)/../common)
# The C16 shares the 1541 ROM with the Plus/4 (same drive).
ROM1541 = ../../plus4/roms/1541.bin

VFLAGS = \
    --cc --exe --build --top-module soc \
    -DSIMULATION -DSIMULATION_SDL $(if $(ROMLESS),-DROMLESS,) \
    -I$(CPU) -I$(PROJ) -I$(COMMON) --Mdir obj_dir --no-timing \
    -Wno-BLKSEQ -Wno-UNDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-UNSIGNED -Wno-IMPLICIT \
    -Wno-CASEOVERLAP -Wno-CASEX -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
    -CFLAGS  "$(shell sdl2-config --cflags) -I$(F1541_DIR) -I$(COMMON) -DSIMULATION -DFL_RAM_MASK=0x3FFF -DSIM_TITLE='\"Commodore C16 — c16 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Game catalog ─────────────────────────────────────────────────────────────
# C16 and Plus/4 share the same game library (BASIC 3.5 compatible)
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
GAME_tuttifrutti = $(GAMES_PRG_BASE)/t/Tutti%20Frutti.prg|prg|Tutti Frutti (graphical arcade)
GAME_tetris     = $(GAMES_PRG_BASE)/t/Tetris.prg|prg|Tetris
GAME_trailblazer = $(GAMES_PRG_BASE)/t/Trailblazer.prg|prg|Trailblazer (racing)
GAME_tacman     = $(GAMES_PRG_BASE)/t/Tacman.prg|prg|Tacman (Pac-Man clone)
GAME_manicminer = $(GAMES_PRG_BASE)/m/Manic%20Miner.prg|prg|Manic Miner (platformer)
GAME_thrust     = $(GAMES_PRG_BASE)/t/Thrust.prg|prg|Thrust (gravity shooter)
GAME_guess      = $(GAMES_BAS_BASE)/guess.bas|bas|Number guessing game
GAME_lunar      = $(GAMES_BAS_BASE)/lunar.bas|bas|Lunar lander simulation
GAME_hammurabi  = $(GAMES_BAS_BASE)/hammurabi.bas|bas|Kingdom management

VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/c16.v \
    $(PROJ)/ted.v \
    $(PROJ)/mos8501.v \
    $(PROJ)/gen_ram.v \
    $(PROJ)/colors_to_rgb.v \
    $(PROJ)/c16_keymatrix.v \
    $(PROJ)/c16_kbd_map.v \
    $(COMMON)/kbd_typer.v \
    $(COMMON)/kbd_matrix.v \
    $(COMMON)/kbd_buttons.v \
    $(COMMON)/qspi_slave.v \
    $(COMMON)/lcd_backlight.v \
    $(COMMON)/shot_cap.v \
    $(COMMON)/bios_text.v \
    $(COMMON)/boot_typer.v \
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

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-c16-rom download-cpu \
        download-c16-game run-c16-game list-c16-games run-c16-floppy \
        run-c16-prg

all:
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp $(F1541_CSRCS)
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

# ── Run a game from the EMULATED 1541 floppy (full 6502+VIA+GCR drive) ────────
# Hands-free: mounts a .d64, then auto-types LOAD"<file>",8 + RUN.  The C16 fits
# in BRAM (BASIC+KERNAL only) so this is the easy target to validate floppy on
# real hardware.  Shares the drive code + IEC glue with plus4/c64.
#   make run-floppy ARCH=c16 D64=path/to/disk.d64 [PROGRAM=NAME]
# With PROGRAM=, auto-types LOAD"NAME",8 + RUN.  Without it, just mounts.
run-c16-floppy:
	@test -n "$(D64)" || { echo "Usage: make run-floppy ARCH=c16 D64=<disk.d64> [PROGRAM=<name>]"; exit 1; }
	@test -f "$(D64)" || { echo "Disk image not found: $(D64)"; exit 1; }
	@test -f $(ROM1541) || { echo "Missing 1541 ROM at $(ROM1541)."; exit 1; }
	$(MAKE) all
	@FL=""; test -z "$(FAST)" || FL="--fastload"; \
	if [ -n "$(PROGRAM)" ]; then \
	    printf 'LOAD"%s",8\r\001RUN\r' "$(PROGRAM)" > $(ROMS)/floppy.uart; \
	    echo "Mounting $(D64), auto-loading \"$(PROGRAM)\" via the emulated 1541..."; \
	    ./obj_dir/Vsoc $$FL --autotype $(ROMS)/floppy.uart --d64 "$(D64)" --rom $(ROM1541); \
	else \
	    echo "Mounting $(D64) via the emulated 1541 (type LOAD\"\$$\",8 + LIST for the directory)..."; \
	    ./obj_dir/Vsoc $$FL --d64 "$(D64)" --rom $(ROM1541); \
	fi

# ── Run a local .prg baked into the RAM init image (no catalog needed) ───────
#   make run-prg ARCH=c16 PRG=path/to/game.prg [TARGET=fpga]
run-c16-prg:
	@test -n "$(PRG)" || { echo "Usage: make run-prg ARCH=c16 PRG=<file.prg> [TARGET=fpga]"; exit 1; }
	@test -f "$(PRG)" || { echo "PRG not found: $(PRG)"; exit 1; }
	@python3 $(ROMS)/prg2hex.py "$(PRG)" $(ROMS)/game.hex $(ROMS)/game.uart
	@if [ "$(TARGET)" = "fpga" ]; then \
	    cd $(PROJ) && GAME="$$(basename "$(PRG)" .prg)" bash run.sh; \
	else \
	    rm -rf obj_dir; \
	    verilator $(VFLAGS) -DGAME_PRG $(VSRCS) sim_top.cpp $(F1541_CSRCS); \
	    echo "Running $$(basename "$(PRG)") (hardware boot_typer autoruns it)..."; \
	    ./obj_dir/Vsoc; \
	fi

run:
	@if [ "$(TARGET)" = "fpga" ]; then \
	    echo "Synthesizing C16 for FPGA..."; \
	    cd $(PROJ) && bash run.sh; \
	else \
	    $(MAKE) all; \
	    ./obj_dir/Vsoc; \
	fi

clean:
	rm -rf obj_dir $(ROMS)/game.hex $(ROMS)/game.uart $(ROMS)/game_params.vh \
	       $(ROMS)/autorun.hex $(ROMS)/games

# VICE mirrors of the original Commodore ROMs (the C16 shares the 264-series
# KERNAL/BASIC with the Plus/4). rom_convert.py lives in the plus4 tree.
ROM_BASE    = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/PLUS4
ROM_BASIC   = basic-318006-01.bin
ROM_KERNAL  = kernal-318004-05.bin
P4ROMS      = ../../plus4/roms

download-c16-rom:
	@echo ""
	@echo "  ================================================================"
	@echo "  Commodore 16 ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  Downloading C16 (264-series) ROMs from VICE project..."
	@echo "  These ROMs are Copyright (C) Commodore Business Machines."
	@echo ""
	@printf "  Proceed? [y/N] " && read ans && \
	    case "$$ans" in [yY]*) ;; *) echo "  Aborted."; exit 1;; esac
	@echo ""
	@curl -sf -o $(ROMS)/$(ROM_BASIC)  $(ROM_BASE)/$(ROM_BASIC)  && echo "    $(ROM_BASIC) (16KB BASIC)"
	@curl -sf -o $(ROMS)/$(ROM_KERNAL) $(ROM_BASE)/$(ROM_KERNAL) && echo "    $(ROM_KERNAL) (16KB KERNAL, PAL)"
	@echo ""
	@echo "  Converting..."
	@python3 $(P4ROMS)/rom_convert.py convert $(ROMS)/$(ROM_BASIC)  $(ROMS)/basic.hex
	@python3 $(P4ROMS)/rom_convert.py convert $(ROMS)/$(ROM_KERNAL) $(ROMS)/kernal_PAL.hex
	@# patch the QSPI fastload detour into kernal_PAL.hex (idempotent)
	@python3 ../../common/kernal_fastload_patch.py
	@echo ""
	@echo "  Done!"
	@echo ""

download-cpu:
	@echo "  6502 CPU is included in the repository. Nothing to download."

# ── List available games ─────────────────────────────────────────────────────
list-c16-games:
	@echo ""
	@echo "  Available C16 games:"
	@echo ""
	@echo "  PRG games (from zimmers.net — downloaded and loaded into RAM):"
	@printf "    %-14s %s\n" "hangman"    "Hangman word game"
	@printf "    %-14s %s\n" "mastermind" "Mastermind code-breaking"
	@printf "    %-14s %s\n" "nim"        "Nim strategy game"
	@printf "    %-14s %s\n" "dice"       "Dice game"
	@printf "    %-14s %s\n" "battleship" "Battleship"
	@printf "    %-14s %s\n" "roulette"   "Casino roulette"
	@printf "    %-14s %s\n" "guessnr"    "Guess the number"
	@printf "    %-14s %s\n" "tictactoe"  "Tic-tac-toe"
	@printf "    %-14s %s\n" "slot"       "Slot machine"
	@printf "    %-14s %s\n" "adventure"  "Text adventure"
	@echo ""
	@echo "  Graphical games:"
	@printf "    %-14s %s\n" "tuttifrutti" "Tutti Frutti (arcade)"
	@printf "    %-14s %s\n" "tetris"      "Tetris"
	@printf "    %-14s %s\n" "trailblazer" "Trailblazer (racing)"
	@printf "    %-14s %s\n" "tacman"      "Tacman (Pac-Man clone)"
	@printf "    %-14s %s\n" "manicminer"  "Manic Miner (platformer)"
	@printf "    %-14s %s\n" "thrust"      "Thrust (gravity shooter)"
	@echo ""
	@echo "  BASIC games (auto-typed via keyboard):"
	@printf "    %-14s %s\n" "guess"      "Number guessing game"
	@printf "    %-14s %s\n" "lunar"      "Lunar lander simulation"
	@printf "    %-14s %s\n" "hammurabi"  "Kingdom management"
	@echo ""
	@echo "  Usage: make download-game ARCH=c16 GAME=<name>"
	@echo "         make run-game ARCH=c16 GAME=<name>"
	@echo ""

# ── Download a specific game ─────────────────────────────────────────────────
download-c16-game:
	@test -n "$(GAME)" || { echo "Usage: make download-game ARCH=c16 GAME=<name>"; echo "Run 'make list-games ARCH=c16' to see available games."; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=c16'."; exit 1; \
	fi; \
	url=$$(echo "$$game_entry" | cut -d'|' -f1); \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	desc=$$(echo "$$game_entry" | cut -d'|' -f3); \
	echo ""; \
	echo "  Downloading: $$desc"; \
	echo "  URL: $$url"; \
	echo ""; \
	echo "  NOTE: This game is copyrighted software."; \
	echo "  By downloading you accept responsibility for complying with"; \
	echo "  applicable copyright law in your jurisdiction."; \
	echo ""; \
	mkdir -p $(ROMS)/games; \
	outfile="$(ROMS)/games/$(GAME).$${fmt}"; \
	curl -L --fail -o "$$outfile" "$$url" || { echo "Download failed."; exit 1; }; \
	echo ""; \
	if [ "$$fmt" = "prg" ]; then \
	    echo "  Converting PRG to RAM hex + autorun..."; \
	    python3 $(ROMS)/prg2hex.py "$$outfile" $(ROMS)/game.hex $(ROMS)/game.uart; \
	elif [ "$$fmt" = "bas" ]; then \
	    echo "  Converting BAS to UART input..."; \
	    python3 $(ROMS)/bas2uart.py "$$outfile" $(ROMS)/game.uart; \
	fi; \
	echo ""; \
	echo "  Done! Run with: make run-game ARCH=c16 GAME=$(GAME)"; \
	echo ""

# ── Build and run a game ─────────────────────────────────────────────────────
run-c16-game:
	@test -n "$(GAME)" || { echo "Usage: make run-game ARCH=c16 GAME=<name>"; exit 1; }
	@game_entry="$(GAME_$(GAME))"; \
	if [ -z "$$game_entry" ]; then \
	    echo "Error: unknown game '$(GAME)'. Run 'make list-games ARCH=c16'."; exit 1; \
	fi; \
	fmt=$$(echo "$$game_entry" | cut -d'|' -f2); \
	if [ "$(TARGET)" = "fpga" ]; then \
	    if [ "$$fmt" = "prg" ]; then \
	        test -f $(ROMS)/game.hex -a -f $(ROMS)/autorun.hex || { echo "Run 'make download-game ARCH=c16 GAME=$(GAME)' first."; exit 1; }; \
	        echo "Synthesizing C16 for FPGA with $(GAME) baked in..."; \
	        cd $(PROJ) && GAME="$(GAME)" bash run.sh; \
	    else \
	        echo "Synthesizing C16 for FPGA..."; \
	        cd $(PROJ) && bash run.sh; \
	    fi; \
	elif [ "$$fmt" = "prg" ]; then \
	    test -f $(ROMS)/game.hex -a -f $(ROMS)/autorun.hex || { echo "Run 'make download-game ARCH=c16 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building with PRG game baked into the RAM init image..."; \
	    rm -rf obj_dir; \
	    verilator $(VFLAGS) -DGAME_PRG $(VSRCS) sim_top.cpp $(F1541_CSRCS); \
	    echo "Running $(GAME) (hardware boot_typer autoruns it)..."; \
	    ./obj_dir/Vsoc; \
	elif [ "$$fmt" = "bas" ]; then \
	    test -f $(ROMS)/game.uart || { echo "Run 'make download-game ARCH=c16 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building C16 simulation..."; \
	    rm -rf obj_dir; \
	    $(MAKE) all; \
	    echo "Running $(GAME) (auto-typing BASIC source)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	fi
