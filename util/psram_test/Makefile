# psram_test — pure-asm PSRAM controller unit test
#
# main.asm is hand-written (not generated from C), so this Makefile bypasses
# arch/risc2/build.mk and invokes gcasm directly.
#
# Run targets ride on the standard arch/risc2/sim-desktop driver.

REPO_ROOT ?= ../../
ARCH_DIR  ?= $(REPO_ROOT)arch/risc2
GCASM     ?= $(REPO_ROOT)util/gcasm/gcasm

ALL_ASM = $(ARCH_DIR)/startup.s $(ARCH_DIR)/runtime.s main.asm
ROM_VH  = romL.vh romH.vh $(foreach n,2 3 4 5 6 7 8,romL$(n).vh romH$(n).vh)

.PHONY: all install run-verilator run-fpga run-gtkwave clean

all: rom.bin

rom.bin: main.asm
	$(GCASM) -crisc2 $(ALL_ASM)

install: rom.bin
	cp rom.bin $(ROM_VH) rom.hex $(ARCH_DIR)/

run-verilator: install
	$(MAKE) -C $(ARCH_DIR)/sim-desktop run

run-fpga: install
	cd $(ARCH_DIR) && HW=$(HW) bash run.sh

run-gtkwave: install
	cd $(ARCH_DIR) && bash simulate.sh

clean:
	rm -f rom.bin rom.hex $(ROM_VH)
