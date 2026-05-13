# util/ddr3-test/Makefile — DDR3 controller bring-up test app.
#
# Self-contained C → ROM build pipeline (does NOT include arch/risc2/build.mk
# because the standard run-fpga / run-verilator targets there assume the
# regular gameconsole SoC).  Targets here:
#
#   make             — compile main.c → rom.bin/rom.hex/romL/H*.vh in this dir
#   make synth       — install + run.sh (synth + bitstream → out.bit)
#   make sim         — install + Verilator headless harness in sim/
#   make clean

REPO_ROOT = ../../
ARCH_DIR  = $(REPO_ROOT)arch/risc2
GCASM     = $(REPO_ROOT)util/gcasm/gcasm

# RISC2 Clang lives in llvm-risc2-build (see ./setup.sh llvm).
-include $(REPO_ROOT).config.mk
CLANG    ?= $(REPO_ROOT)llvm-risc2-build/bin/clang

CFLAGS = --target=risc2 -O1 -S -x c -fno-jump-tables -ffreestanding \
         -I. -I$(ARCH_DIR)

# Frame-index lowering fix-up (same one as arch/risc2/build.mk).
FIX_FRAME = perl -0pe \
    's/\tmov r7, r14\n\tadd r7, \#([0-9a-f]+)\n\tadd (r\d+), \#0/\tmov $$2, r14\n\tadd $$2, \#$$1/g'

ALL_ASM = $(ARCH_DIR)/startup.s $(ARCH_DIR)/runtime.s main.asm
ROM_VH  = romL.vh romH.vh $(foreach n,2 3 4 5 6 7 8,romL$(n).vh romH$(n).vh)

.PHONY: all synth sim clean check-clang

all: rom.bin

check-clang:
	@if [ ! -x "$(CLANG)" ] && [ ! -x "$(CLANG).exe" ]; then \
	    echo "ERROR: RISC2 Clang not found at $(CLANG)"; \
	    echo "Run './setup.sh llvm' from the repo root."; \
	    exit 1; \
	fi

main.asm: main.c | check-clang
	$(CLANG) $(CFLAGS) $< -o $@.tmp
	sed "s/_LBB/_MAIN_LBB/g" $@.tmp | $(FIX_FRAME) > $@
	@rm -f $@.tmp

rom.bin: $(ALL_ASM)
	$(GCASM) -crisc2 $(ALL_ASM)

synth: rom.bin
	bash run.sh

sim: rom.bin
	$(MAKE) -C sim run

clean:
	rm -f main.asm rom.bin rom.hex $(ROM_VH) out.*
	$(MAKE) -C sim clean 2>/dev/null || true
