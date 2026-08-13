#
# sim-desktop/Makefile — Commodore 64 desktop simulation via Verilator + SDL2
#

REPO = ../../..
CPU  = ../cpu
CPU6502 = ../../common/cpu/6502
VIC  = ../vic
SID  = ../sid
UTIL = $(REPO)/util
PERI = $(REPO)/peripheral
PROJ = ..
ROMS = ../roms

# 1541 floppy emulator (shared with c16/plus4 and the RP2350 firmware) + the
# shared sim-side IEC glue.  COMMON absolute (C++ compiles from obj_dir/).
F1541_DIR = $(abspath $(PROJ)/../common/floppy1541)
F1541_CSRCS = $(F1541_DIR)/floppy1541.c $(F1541_DIR)/cpu6502.c $(F1541_DIR)/via6522.c
COMMON = $(abspath $(PROJ)/../common)
ROM1541 = ../../plus4/roms/1541.bin

# ── ROM download URLs (VICE project) ──────────────────────────────────────
ROM_BASE = https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/C64
ROM_BASIC   = basic-901226-01.bin
ROM_KERNAL  = kernal-901227-03.bin
ROM_CHARGEN = chargen-901225-01.bin

# ── Verilator flags ─────────────────────────────────────────────────────────
# EasyFlash cartridge support is ON by default (one bitstream, runtime
# d64-vs-cart decision — retro-arch/c64/README.md).  EASYFLASH=0
# builds the pre-cart SoC for A/B debugging.
EASYFLASH ?= 1

VFLAGS = \
    --cc \
    --exe \
    --build \
    --top-module soc \
    -DSIMULATION \
    -DSIMULATION_SDL \
    $(if $(ROMLESS),-DROMLESS,) \
    $(if $(filter-out 0,$(EASYFLASH)),-DEASYFLASH,) \
    $(if $(filter 1,$(FDRIVE)),-DFDRIVE,-DPSRAM_CLKDIV=1) \
    -I$(CPU) \
    -I$(CPU6502) \
    -I$(VIC) \
    -I$(SID) \
    -I$(PROJ) \
    -I$(COMMON) \
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
    -Wno-TIMESCALEMOD \
    -CFLAGS  "$(shell sdl2-config --cflags) -I$(F1541_DIR) -I$(COMMON) -DSIMULATION $(if $(filter-out 0,$(EASYFLASH)),-DEASYFLASH,) $(if $(filter 1,$(FDRIVE)),-DFDRIVE,) -DSIM_TITLE='\"$(or $(SIM_GAME),Commodore 64) — c64 (ESC=quit)\"'" \
    -LDFLAGS "$(shell sdl2-config --libs)"

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all run clean download-c64-rom download-cpu list-c64-games download-c64-game run-c64-game run-c64-floppy run-c64-prg check-easyflash check-efpush run-c64-crt check-cpu

# ── Verilog source list ──────────────────────────────────────────────────────
VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/c64_kbd_map.v \
    $(COMMON)/kbd_typer.v \
    $(COMMON)/kbd_matrix.v \
    $(COMMON)/kbd_buttons.v \
    $(COMMON)/qspi_slave.v \
    $(COMMON)/lcd_backlight.v \
    $(COMMON)/shot_cap.v \
    $(COMMON)/bios_text.v \
    $(COMMON)/boot_typer.v \
    $(CPU)/cpu_6510.v \
    $(CPU6502)/cpu_6502.v \
    $(CPU6502)/ALU.v \
    $(CPU)/mos6526.v \
    $(VIC)/vicii.v \
    $(VIC)/addressgen_spartan.v \
    $(VIC)/bus_access.v \
    $(VIC)/border.v \
    $(VIC)/cycles.v \
    $(VIC)/divide.v \
    $(VIC)/lightpen.v \
    $(VIC)/matrix.v \
    $(VIC)/pixel_sequencer.v \
    $(VIC)/raster.v \
    $(VIC)/registers.v \
    $(VIC)/sprites.v \
    $(VIC)/comp_sync.v \
    $(VIC)/equalization.v \
    $(VIC)/serration.v \
    $(VIC)/sinewave.v \
    $(SID)/sid_top.v \
    $(SID)/sid_voice.v \
    $(SID)/sid_envelope.v \
    $(SID)/sid_filter.v \
    $(SID)/sid_tables.v \
    $(SID)/sid_dac.v \
    $(UTIL)/ecp5_simul.v \
    $(PERI)/uart.v \
    $(PERI)/lcd_out.v

# EasyFlash needs the pin-level engine + chip model ONLY when it owns the
# PSRAM.  With FDRIVE=1 the two share one behavioural engine through
# psram_hub.v (the drive sets the pace; a pin-level model at the drive's
# latencies would cost 4 evals per clk for nothing).
ifneq ($(EASYFLASH),0)
VSRCS += $(PROJ)/c64_easyflash.v
ifneq ($(FDRIVE),1)
VSRCS += \
    $(PERI)/psram.v \
    $(PERI)/psram_model.v
endif
endif

# FDRIVE=1 adds the fabric 1541 (common/drive1541):
# internal-IEC drive + PSRAM ROM/GCR backend.  Push shares loader banks
# 3..4 with the EasyFlash flat image — a run uses the cart OR the drive.
ifeq ($(FDRIVE),1)
VSRCS += \
    $(COMMON)/drive1541/drive_1541.v \
    $(COMMON)/drive1541/drive_psram.v \
    $(COMMON)/drive1541/psram_cmd_behav.v \
    $(COMMON)/drive1541/via6522.v \
    $(COMMON)/psram_hub.v
endif

all:
	@if [ ! -f $(CPU)/mos6526.v ]; then \
	    echo "  C64 chips not found. Run 'make download-cpu ARCH=c64' first."; exit 1; \
	fi
	@if [ ! -f $(ROMS)/basic.hex ]; then \
	    echo "  ROMs not found. Run 'make download-rom ARCH=c64' first."; exit 1; \
	fi
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp $(F1541_CSRCS)
	@echo ""
	@echo "Build complete. Run with: ./obj_dir/Vsoc"

run: all
	./obj_dir/Vsoc

# ── Run a game from the EMULATED 1541 floppy (full 6502+VIA+GCR drive) ────────
# Hands-free: mounts a .d64, then auto-types LOAD"<file>",8 + RUN.  Shares the
# drive code + IEC glue with c16/plus4.
#   make run-floppy ARCH=c64 D64=path/to/disk.d64 [PROGRAM=NAME]
# With PROGRAM=, auto-types LOAD"NAME",8 + RUN.  Without it, just mounts.
run-c64-floppy:
	@test -n "$(D64)" || { echo "Usage: make run-floppy ARCH=c64 D64=<disk.d64> [PROGRAM=<name>]"; exit 1; }
	@test -f "$(D64)" || { echo "Disk image not found: $(D64)"; exit 1; }
	@test -f $(ROM1541) || { echo "Missing 1541 ROM at $(ROM1541)."; exit 1; }
	$(MAKE) all
	@FL=""; test -z "$(FAST)" || FL="--fastload"; \
	if [ -n "$(PROGRAM)" ]; then \
	    printf 'LOAD"%s",8\r\001RUN\r' "$(PROGRAM)" > $(ROMS)/floppy.uart; \
	    echo "Mounting $(D64), auto-loading \"$(PROGRAM)\" via the emulated 1541..."; \
	    AUTOTYPE_BOOT_MS=$${AUTOTYPE_BOOT_MS:-5000} ./obj_dir/Vsoc $$FL --autotype $(ROMS)/floppy.uart --d64 "$(D64)" --rom $(ROM1541); \
	else \
	    echo "Mounting $(D64) via the emulated 1541 (type LOAD\"\$$\",8 + LIST for the directory)..."; \
	    ./obj_dir/Vsoc $$FL --d64 "$(D64)" --rom $(ROM1541); \
	fi

# ── EasyFlash cartridge (README.md) ─────────────────────────────────
# check-easyflash: the copyright-free self-testing cart (mk_ef_testcart.py)
# boots in Ultimax mode, walks all 64 banks on both chips, tests the 256 B
# cart RAM, the kill state, and the Am29F040 emulation EAPI needs
# (autoselect / byte program / sector erase).  Result tokens land in RAM
# and --check-ef reads them out.  ~1 s of machine time.
check-easyflash: all $(ROMS)/ef_test.flat
	./obj_dir/Vsoc --headless --ef $(ROMS)/ef_test.flat --check-ef 1000000 \
	    2>&1 | tee /tmp/c64_ef.log
	@grep -q "EF-TEST: PASS" /tmp/c64_ef.log \
	    && echo "  PASS: EasyFlash banking + flash emulation" \
	    || { echo "  FAIL: see /tmp/c64_ef.log"; exit 1; }

# check-efpush: the QSPI ROM_BEGIN/DATA/END push path end-to-end — four
# 4 KiB slices (one per 256 KiB flat-image chunk, loader banks 3..6) go
# over the emulated link into PSRAM and are compared back byte-for-byte.
#
# TWO RATES, and the fast one is the point.  The push FIFO in front of the
# PSRAM writer has NO flow control, so this path is only correct while the
# master stays under the drain rate, and the default 8 (~0.25 MB/s) is ten
# times slower than anything the board does — it proved the wiring and
# nothing about the timing.  Measured 2026-08-06 by sweeping --qspi-half:
# clean at 0.5 and 0.99 MB/s, 52 dropped bytes at 1.97 MB/s.  The board's
# 4-lane link is 1.5 MB/s, i.e. inside that band — which is what a cart
# that loaded fine and booted to a blank screen was.
#
# The FIRST bank pushed is thrown away on purpose: the model starts pushing
# at t=0, before the fabric is out of reset, so that one is always lost.  The
# real MCU never does this (biosLinkSettle waits for a PING answer first).
EFPUSH_ARGS = --headless --qspi \
	    --rom-bin 3:/tmp/c64_ef_chunk0.bin \
	    --rom-bin 3:/tmp/c64_ef_chunk0.bin --rom-bin 4:/tmp/c64_ef_chunk1.bin \
	    --rom-bin 5:/tmp/c64_ef_chunk2.bin --rom-bin 6:/tmp/c64_ef_chunk3.bin \
	    --check-ef 900000 \
	    --ef-verify 0:/tmp/c64_ef_chunk0.bin --ef-verify 1:/tmp/c64_ef_chunk1.bin \
	    --ef-verify 2:/tmp/c64_ef_chunk2.bin --ef-verify 3:/tmp/c64_ef_chunk3.bin

check-efpush: all $(ROMS)/ef_test.flat
	@for k in 0 1 2 3; do \
	    dd if=$(ROMS)/ef_test.flat of=/tmp/c64_ef_chunk$$k.bin \
	       bs=4096 count=1 skip=$$((k * 64)) 2>/dev/null; done
	@for h in 8 4; do \
	    echo "  push at --qspi-half $$h:"; \
	    ./obj_dir/Vsoc $(EFPUSH_ARGS) --qspi-half $$h \
	        2>&1 | tee /tmp/c64_efpush_$$h.log | grep -E "drops|PASS|FAIL"; \
	    grep -q "EF-PUSH: PASS" /tmp/c64_efpush_$$h.log \
	        || { echo "  FAIL: see /tmp/c64_efpush_$$h.log"; exit 1; }; \
	done
	@echo "  PASS: cart image push over the link (both rates, zero drops)"

# ── check-shot: screen grab against the FPGA-mode video path ────────────────
# The --shot sweep in the normal sim exercises the SIMULATION framebuffer
# video path; the board runs the genlocked line-buffer branch of soc.v, and
# shot_cap.v counts its lines off THAT timing.  This target builds the SoC
# with SIMULATION undefined (as for the bitstream) and runs the same
# SHOT_ARM/STATUS/READ sweep the MCU firmware runs, with the firmware's own
# geometry (400x240 logical, panel line = logical*2).
#   make check-shot ARCH=c64
SHOT_VFLAGS = \
    --cc --exe --build --top-module soc \
    -I$(CPU) -I$(CPU6502) -I$(VIC) -I$(SID) -I$(PROJ) -I$(COMMON) \
    --Mdir obj_dir_shot --no-timing \
    -Wno-BLKSEQ -Wno-UNDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-UNSIGNED -Wno-IMPLICIT \
    -Wno-CASEOVERLAP -Wno-CASEX -Wno-MULTIDRIVEN -Wno-LATCH \
    -Wno-TIMESCALEMOD \
    -CFLAGS "-I$(F1541_DIR) -I$(COMMON)"

# One paired arm (2 lines) per panel frame = ~20 ms of machine time, so the
# 240-line sweep needs ~2.4 s.  The grab now FREEZES the machine for its whole
# duration (SHOT_FREEZE, like the MCU firmware does), so it must arm after
# the boot screen is fully painted — at 2 s this sim's C64 is still booting
# and a frozen grab is honestly black; 4 s is comfortably past READY.
check-shot:
	$(MAKE) EASYFLASH=0 shot-build
	./obj_dir_shot/Vsoc 8000000 /tmp/c64_fpga_shot.ppm 4000000
	@python3 -c "import collections,sys;\
d=open('/tmp/c64_fpga_shot.ppm','rb').read();\
px=d[d.index(b'255\n')+4:];\
c=collections.Counter(tuple(px[i:i+3]) for i in range(0,len(px),3));\
n=len(px)//3;\
print('  grab %d px, top colours %s' % (n, c.most_common(3)));\
sys.exit(0 if n == 400*240 and c.most_common(1)[0][1] < n * 0.99 else 1)" \
	  && echo "  PASS: screen grab over the FPGA video path" \
	  || { echo "  FAIL: grab is blank or short — /tmp/c64_fpga_shot.ppm"; exit 1; }

shot-build:
	verilator $(SHOT_VFLAGS) $(VSRCS) sim_fpga_shot.cpp

$(ROMS)/ef_test.flat: $(ROMS)/mk_ef_testcart.py
	python3 $(ROMS)/mk_ef_testcart.py $@ $(ROMS)/ef_test.crt

# run a real EasyFlash .crt (e.g. Prince of Persia):
#   make run-crt ARCH=c64 CRT=path/to/game.crt
run-c64-crt: all
	@test -n "$(CRT)" || { echo "Usage: make run-crt ARCH=c64 CRT=<file.crt>"; exit 1; }
	@test -f "$(CRT)" || { echo "CRT not found: $(CRT)"; exit 1; }
	python3 $(ROMS)/crt2flat.py "$(CRT)" /tmp/c64_cart.flat
	./obj_dir/Vsoc --ef /tmp/c64_cart.flat

# obj_dir_* variants come from the FPGA-mode video harness (obj_dir_fpga),
# game builds (obj_dir_game) and gate-level experiments (obj_dir_gl).
clean:
	rm -rf obj_dir obj_dir_*

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
	@# kernal_stock.hex = unpatched KERNAL (the IEC/real-1541 build uses it);
	@# kernal.hex then gets the QSPI fastload detour patched in.
	@cp $(ROMS)/kernal.hex $(ROMS)/kernal_stock.hex
	@python3 ../../common/kernal_fastload_patch.py
	@echo ""
	@echo "  Done!"
	@echo ""

list-c64-games:
	@echo ""
	@echo "  Commodore 64 Game Loader"
	@echo ""
	@echo "  Download .prg or .d64 files from csdb.dk, c64.com, or gamebase64.com"
	@echo "  and place them in retro-arch/c64/roms/games/"
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
	    echo "  Place $(GAME).prg or $(GAME).d64 in retro-arch/c64/roms/games/"; \
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
	    echo "  Place $(GAME).prg or $(GAME).d64 in retro-arch/c64/roms/games/"; \
	    echo "  Sources: csdb.dk  c64.com  gamebase64.com"; \
	    exit 1; \
	fi
	@echo "  Building..."
	@rm -rf obj_dir
	@$(MAKE) -s SIM_GAME="$(GAME)" _build-game

_build-game:
	verilator $(VFLAGS) -DGAME_PRG -CFLAGS "-DGAME_PRG" $(VSRCS) sim_top.cpp $(F1541_CSRCS)
	@echo "  Running $(GAME)..."
	@./obj_dir/Vsoc

# ── Run a local .prg baked into the RAM init image (no catalog needed) ───────
#   make run-prg ARCH=c64 PRG=path/to/game.prg [TARGET=fpga]
run-c64-prg:
	@test -n "$(PRG)" || { echo "Usage: make run-prg ARCH=c64 PRG=<file.prg> [TARGET=fpga]"; exit 1; }
	@test -f "$(PRG)" || { echo "PRG not found: $(PRG)"; exit 1; }
	@python3 $(ROMS)/prg2hex.py "$(PRG)" $(ROMS)/game.hex
	@if [ "$(TARGET)" = "fpga" ]; then \
	    cd $(PROJ) && GAME="$$(basename "$(PRG)" .prg)" HW="$(HW)" bash run.sh; \
	else \
	    rm -rf obj_dir; \
	    $(MAKE) -s SIM_GAME="$$(basename "$(PRG)" .prg)" _build-game; \
	fi

# ── check-cpu: 6502 opcode conformance (documented + undocumented) ───────────
# The Arlet core is shared by c64/c16/plus4, so run this after any
# change to common/cpu/6502/cpu_6502.v.  720 self-checking cases, ~15 s, no ROMs.
check-cpu:
	$(MAKE) -C $(COMMON)/cpu/6502 check
