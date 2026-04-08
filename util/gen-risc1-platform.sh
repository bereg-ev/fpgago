#!/bin/bash
# gen-risc1-platform.sh — Generate a platform Makefile for a RISC1 architecture copy
#
# Usage: gen-risc1-platform.sh <dst-arch> <output-makefile>
#
# The generated Makefile builds the game assembly with gcasm using the
# copied arch's ISA name, copies ROM to the target architecture, and
# provides run-* targets for verilator/fpga/gtkwave simulation.

set -euo pipefail

DST="${1:?Usage: $0 <dst-arch> <output-makefile>}"
OUT="${2:?Usage: $0 <dst-arch> <output-makefile>}"

cat > "$OUT" << 'EOF'
# Auto-generated platform Makefile (copy of risc1)
REPO_ROOT = ../../../../../
ARCH_DIR  = $(REPO_ROOT)arch/ARCHNAME
ASM       = $(REPO_ROOT)util/gcasm/gcasm
GAME_DIR  = ../../..

.PHONY: all clean run-verilator run-fpga run-gtkwave

all:
	$(ASM) -cARCHNAME $(GAME_DIR)/*.asm
	cp romL.vh $(ARCH_DIR)/romL.vh

run-verilator: all
	$(MAKE) -C $(ARCH_DIR)/sim-desktop run SIM_GAME=$(SIM_GAME) SIM_ARCH=$(SIM_ARCH)

run-fpga: all
	cd $(ARCH_DIR) && bash run.sh

run-gtkwave: all
	cd $(ARCH_DIR) && bash simulate.sh

clean:
	rm -f rom.bin romL.vh romH.vh rom.hex
EOF

sed "s/ARCHNAME/$DST/g" "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
