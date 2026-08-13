REPO = ../../..
CPU  = ../../common/cpu/6502
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms
C16  = ../../c16

# Floppy 1541 emulator (shared with the RP2350 firmware in the board firmware)
F1541_DIR = $(abspath $(PROJ)/../common/floppy1541)
F1541_CSRCS = $(F1541_DIR)/floppy1541.c $(F1541_DIR)/cpu6502.c $(F1541_DIR)/via6522.c
# Shared sim-side floppy/IEC glue (same code for c16/plus4/c64).  Absolute:
# the C++ compile runs from obj_dir/, so a relative -I would be wrong.
COMMON = $(abspath $(PROJ)/../common)

VFLAGS = \
    --cc --exe --build --top-module soc \
    -DSIMULATION -DSIMULATION_SDL $(if $(ROMLESS),-DROMLESS,) \
    -I$(CPU) -I$(PROJ) -I$(COMMON) --Mdir obj_dir --no-timing \
    -Wno-BLKSEQ -Wno-UNDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-UNSIGNED -Wno-IMPLICIT \
    -Wno-CASEOVERLAP -Wno-CASEX -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
    -CFLAGS  "$(shell sdl2-config --cflags) -I$(F1541_DIR) -I$(COMMON) -DSIMULATION -DSIM_TITLE='\"Commodore Plus/4 — plus4 (ESC=quit)\"'" \
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
GAME_prince     = $(GAMES_PRG_BASE)/p/Prince_Of_Persia_(fix_ACW).prg|prg|Prince of Persia
GAME_wizardwor  = $(GAMES_PRG_BASE)/w/Wizard%20Of%20Wor.prg|prg|Wizard of Wor
GAME_wizardakyrz = $(GAMES_PRG_BASE)/w/Wizard%20Of%20Akyrz.prg|prg|Wizard of Akyrz
GAME_tuttifrutti = $(GAMES_PRG_BASE)/t/Tutti%20Frutti.prg|prg|Tutti Frutti (graphical arcade)
GAME_tetris     = $(GAMES_PRG_BASE)/t/Tetris.prg|prg|Tetris
GAME_trailblazer = $(GAMES_PRG_BASE)/t/Trailblazer.prg|prg|Trailblazer (racing)
GAME_tacman     = $(GAMES_PRG_BASE)/t/Tacman.prg|prg|Tacman (Pac-Man clone)
GAME_manicminer = $(GAMES_PRG_BASE)/m/Manic%20Miner.prg|prg|Manic Miner (platformer)
GAME_thrust     = $(GAMES_PRG_BASE)/t/Thrust.prg|prg|Thrust (gravity shooter)
GAME_terranova  = $(GAMES_PRG_BASE)/t/Terra%20Nova.d64.gz|d64gz|Terra Nova
GAME_guess      = $(GAMES_BAS_BASE)/guess.bas|bas|Number guessing game
GAME_lunar      = $(GAMES_BAS_BASE)/lunar.bas|bas|Lunar lander simulation
GAME_hammurabi  = $(GAMES_BAS_BASE)/hammurabi.bas|bas|Kingdom management

# Shared modules from C16 (same TED, CPU, keyboard, etc.)
VSRCS = \
    $(PROJ)/soc.v \
    $(C16)/c16.v \
    $(C16)/ted.v \
    $(C16)/mos8501.v \
    $(C16)/gen_ram.v \
    $(C16)/colors_to_rgb.v \
    $(C16)/c16_keymatrix.v \
    $(C16)/c16_kbd_map.v \
    $(COMMON)/kbd_typer.v \
    $(COMMON)/kbd_matrix.v \
    $(COMMON)/kbd_buttons.v \
    $(COMMON)/boot_typer.v \
    $(COMMON)/qspi_slave.v \
    $(COMMON)/lcd_backlight.v \
    $(COMMON)/shot_cap.v \
    $(COMMON)/bios_text.v \
    $(C16)/mos6529.v \
    $(C16)/gen_uart.v \
    $(PROJ)/basic_rom.v \
    $(PROJ)/kernal_rom.v \
    $(C16)/sigma_delta_dac.v \
    $(C16)/stubs.v \
    $(CPU)/cpu_6502.v \
    $(CPU)/ALU.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-plus4-rom download-cpu \
        download-plus4-game run-plus4-game list-plus4-games run-plus4-floppy \
        run-plus4-prg

all:
	@if [ ! -f $(ROMS)/basic.hex ] || [ ! -f $(ROMS)/kernal.hex ]; then \
	    echo ""; \
	    echo "  ROM hex files not found in $(ROMS)/"; \
	    echo "  Run 'make download-rom ARCH=plus4' to fetch Plus/4 ROMs."; \
	    echo ""; \
	    exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp $(F1541_CSRCS)
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

# ── Run a game from the EMULATED 1541 floppy (full 6502+VIA+GCR drive) ────────
# Hands-free: mounts a .d64, then auto-types LOAD"<file>",8 + RUN (no manual
# typing).  Requires the 1541 ROM at $(ROMS)/1541.bin.
#   make run-floppy ARCH=plus4 D64=path/to/disk.d64 [PROGRAM=NAME]
# With PROGRAM=, auto-types LOAD"NAME",8 + RUN.  Without it, just mounts the
# disk so you can type LOAD"$",8 / LIST / LOAD"NAME",8 yourself.
run-plus4-floppy:
	@test -n "$(D64)" || { echo "Usage: make run-floppy ARCH=plus4 D64=<disk.d64> [FILE=<name>]"; exit 1; }
	@test -f "$(D64)" || { echo "Disk image not found: $(D64)"; exit 1; }
	@test -f $(ROMS)/1541.bin || { echo "Missing $(ROMS)/1541.bin (16KB 1541 ROM)."; exit 1; }
	$(MAKE) all
	@FL=""; test -z "$(FAST)" || FL="--fastload"; \
	if [ -n "$(PROGRAM)" ]; then \
	    printf 'LOAD"%s",8\r\001RUN\r' "$(PROGRAM)" > $(ROMS)/floppy.uart; \
	    echo "Mounting $(D64), auto-loading \"$(PROGRAM)\" via the emulated 1541..."; \
	    ./obj_dir/Vsoc $$FL --autotype $(ROMS)/floppy.uart --d64 "$(D64)" --rom $(ROMS)/1541.bin; \
	else \
	    echo "Mounting $(D64) via the emulated 1541 (type LOAD\"\$$\",8 + LIST for the directory)..."; \
	    ./obj_dir/Vsoc $$FL --d64 "$(D64)" --rom $(ROMS)/1541.bin; \
	fi

# ── Run a local .prg baked into the RAM init image (no catalog needed) ───────
# The PRG is preloaded at FPGA-config/sim-load time and autostarted by the
# hardware boot_typer (restore POKEs + RUN) — works on the board without
# the MCU.  TARGET=fpga synthesizes a bitstream instead of running the sim.
#   make run-prg ARCH=plus4 PRG=path/to/game.prg [TARGET=fpga]
run-plus4-prg:
	@test -n "$(PRG)" || { echo "Usage: make run-prg ARCH=plus4 PRG=<file.prg> [TARGET=fpga]"; exit 1; }
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
	    echo "Synthesizing Plus/4 for FPGA..."; \
	    cd $(PROJ) && bash run.sh; \
	else \
	    $(MAKE) all; \
	    ./obj_dir/Vsoc; \
	fi

clean:
	rm -rf obj_dir $(ROMS)/game.hex $(ROMS)/game.uart $(ROMS)/game_params.vh \
	       $(ROMS)/autorun.hex $(ROMS)/games

# VICE project mirrors of the original Commodore ROM images. The 264-series
# KERNAL/BASIC pair is shared by the C16 and the Plus/4; the combined 16KB
# 1541 DOS ROM drives the MCU's real-1541 engine and the sim's full drive.
ROM_BASE    = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/PLUS4
DRV_BASE    = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/DRIVES
ROM_BASIC   = basic-318006-01.bin
ROM_KERNAL  = kernal-318004-05.bin
ROM_1541    = dos1541-325302-01%2B901229-05.bin

download-plus4-rom:
	@echo ""
	@echo "  ================================================================"
	@echo "  Commodore Plus/4 ROM Download"
	@echo "  ================================================================"
	@echo ""
	@echo "  Downloading Plus/4 ROMs from VICE project..."
	@echo "  These ROMs are Copyright (C) Commodore Business Machines."
	@echo ""
	@printf "  Proceed? [y/N] " && read ans && \
	    case "$$ans" in [yY]*) ;; *) echo "  Aborted."; exit 1;; esac
	@echo ""
	@curl -sf -o $(ROMS)/$(ROM_BASIC)  $(ROM_BASE)/$(ROM_BASIC)  && echo "    $(ROM_BASIC) (16KB BASIC)"
	@curl -sf -o $(ROMS)/$(ROM_KERNAL) $(ROM_BASE)/$(ROM_KERNAL) && echo "    $(ROM_KERNAL) (16KB KERNAL, PAL)"
	@curl -sf -o $(ROMS)/3plus1lo.bin  $(ROM_BASE)/3plus1-317053-01.bin && echo "    3plus1lo.bin (16KB 3-plus-1 low)"
	@curl -sf -o $(ROMS)/3plus1hi.bin  $(ROM_BASE)/3plus1-317054-01.bin && echo "    3plus1hi.bin (16KB 3-plus-1 high)"
	@curl -sf -o $(ROMS)/c2lo-364.bin  $(ROM_BASE)/c2lo-364.bin && echo "    c2lo-364.bin (V364 C2 low)"
	@curl -sf -o "$(ROMS)/1541.bin"    "$(DRV_BASE)/$(ROM_1541)" && echo "    1541.bin (16KB 1541 DOS)"
	@echo ""
	@echo "  Converting..."
	@python3 $(ROMS)/rom_convert.py convert $(ROMS)/$(ROM_BASIC)  $(ROMS)/basic.hex
	@python3 $(ROMS)/rom_convert.py convert $(ROMS)/$(ROM_KERNAL) $(ROMS)/kernal.hex
	@python3 $(ROMS)/rom_convert.py convert $(ROMS)/3plus1lo.bin  $(ROMS)/3plus1lo.hex
	@python3 $(ROMS)/rom_convert.py convert $(ROMS)/3plus1hi.bin  $(ROMS)/3plus1hi.hex
	@dd if=$(ROMS)/1541.bin of=$(ROMS)/1541-c000.bin bs=8192 count=1 2>/dev/null
	@dd if=$(ROMS)/1541.bin of=$(ROMS)/1541-e000.bin bs=8192 skip=1 2>/dev/null
	@# patch the QSPI fastload detour into kernal.hex (idempotent)
	@python3 ../../common/kernal_fastload_patch.py
	@echo ""
	@echo "  Done!"
	@echo ""

download-cpu:
	@echo "  6502 CPU is included in the repository. Nothing to download."

# ── List available games ─────────────────────────────────────────────────────
list-plus4-games:
	@echo ""
	@echo "  Available Plus/4 games:"
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
	@printf "    %-14s %s\n" "prince"     "Prince of Persia"
	@printf "    %-14s %s\n" "wizardwor"  "Wizard of Wor"
	@printf "    %-14s %s\n" "wizardakyrz" "Wizard of Akyrz"
	@echo ""
	@echo "  Graphical games:"
	@printf "    %-14s %s\n" "tuttifrutti" "Tutti Frutti (arcade)"
	@printf "    %-14s %s\n" "tetris"      "Tetris"
	@printf "    %-14s %s\n" "trailblazer" "Trailblazer (racing)"
	@printf "    %-14s %s\n" "tacman"      "Tacman (Pac-Man clone)"
	@printf "    %-14s %s\n" "manicminer"  "Manic Miner (platformer)"
	@printf "    %-14s %s\n" "thrust"      "Thrust (gravity shooter)"
	@printf "    %-14s %s\n" "terranova"   "Terra Nova"
	@echo ""
	@echo "  BASIC games (auto-typed via keyboard):"
	@printf "    %-14s %s\n" "guess"      "Number guessing game"
	@printf "    %-14s %s\n" "lunar"      "Lunar lander simulation"
	@printf "    %-14s %s\n" "hammurabi"  "Kingdom management"
	@echo ""
	@echo "  Usage: make download-game ARCH=plus4 GAME=<name>"
	@echo "         make run-game ARCH=plus4 GAME=<name>"
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
	echo "  Downloading: $$desc"; \
	echo "  URL: $$url"; \
	echo ""; \
	echo "  NOTE: This game is copyrighted software."; \
	echo "  By downloading you accept responsibility for complying with"; \
	echo "  applicable copyright law in your jurisdiction."; \
	echo ""; \
	mkdir -p $(ROMS)/games; \
	if [ "$$fmt" = "d64gz" ]; then \
	    outfile="$(ROMS)/games/$(GAME).d64.gz"; \
	else \
	    outfile="$(ROMS)/games/$(GAME).$${fmt}"; \
	fi; \
	curl -L --fail -o "$$outfile" "$$url" || { echo "Download failed."; exit 1; }; \
	echo ""; \
	if [ "$$fmt" = "prg" ]; then \
	    echo "  Converting PRG to RAM hex + autorun..."; \
	    python3 $(ROMS)/prg2hex.py "$$outfile" $(ROMS)/game.hex $(ROMS)/game.uart; \
	elif [ "$$fmt" = "d64gz" ]; then \
	    echo "  Decompressing D64 disk image..."; \
	    gunzip -f -k "$$outfile"; \
	    d64file="$(ROMS)/games/$(GAME).d64"; \
	    prgfile="$(ROMS)/games/$(GAME).prg"; \
	    echo "  Extracting PRG from D64..."; \
	    python3 $(ROMS)/d64extract.py "$$d64file" "$$prgfile"; \
	    echo "  Converting PRG to RAM hex + autorun..."; \
	    python3 $(ROMS)/prg2hex.py "$$prgfile" $(ROMS)/game.hex $(ROMS)/game.uart; \
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
	if [ "$(TARGET)" = "fpga" ]; then \
	    if [ "$$fmt" = "prg" ] || [ "$$fmt" = "d64gz" ]; then \
	        test -f $(ROMS)/game.hex -a -f $(ROMS)/autorun.hex || { echo "Run 'make download-game ARCH=plus4 GAME=$(GAME)' first."; exit 1; }; \
	        echo "Synthesizing Plus/4 for FPGA with $(GAME) baked in..."; \
	        cd $(PROJ) && GAME="$(GAME)" bash run.sh; \
	    else \
	        echo "Synthesizing Plus/4 for FPGA..."; \
	        cd $(PROJ) && bash run.sh; \
	    fi; \
	elif [ "$$fmt" = "prg" ] || [ "$$fmt" = "d64gz" ]; then \
	    test -f $(ROMS)/game.hex -a -f $(ROMS)/autorun.hex || { echo "Run 'make download-game ARCH=plus4 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building with PRG game baked into the RAM init image..."; \
	    rm -rf obj_dir; \
	    verilator $(VFLAGS) -DGAME_PRG $(VSRCS) sim_top.cpp $(F1541_CSRCS); \
	    echo "Running $(GAME) (hardware boot_typer autoruns it)..."; \
	    ./obj_dir/Vsoc; \
	elif [ "$$fmt" = "bas" ]; then \
	    test -f $(ROMS)/game.uart || { echo "Run 'make download-game ARCH=plus4 GAME=$(GAME)' first."; exit 1; }; \
	    echo "Building Plus/4 simulation..."; \
	    rm -rf obj_dir; \
	    $(MAKE) all; \
	    echo "Running $(GAME) (auto-typing BASIC source)..."; \
	    ./obj_dir/Vsoc --autotype $(ROMS)/game.uart; \
	fi
