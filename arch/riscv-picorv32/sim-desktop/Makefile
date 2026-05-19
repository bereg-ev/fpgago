#
# sim-desktop/Makefile — Verilator simulation of the riscv-picorv32 minimal SoC.
#

PROJ    = ..
TOP     = soc
VFLAGS  = \
    --cc \
    --exe \
    --build \
    --top-module $(TOP) \
    -I$(PROJ) \
    --Mdir obj_dir \
    --no-timing \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-WIDTHCONCAT \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM \
    -Wno-CASEINCOMPLETE \
    -Wno-CASEX \
    -Wno-INITIALDLY \
    -Wno-UNDRIVEN \
    -Wno-PINMISSING \
    -Wno-UNOPTFLAT \
    -Wno-TIMESCALEMOD

VSRCS = \
    $(PROJ)/soc.v \
    $(PROJ)/cpu_picorv32.v \
    $(PROJ)/picorv32.v

.PHONY: all run clean
all:
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: SIM_EXIT_ON_NEWLINE=1 ./obj_dir/Vsoc"

run: all
	SIM_EXIT_ON_NEWLINE=1 ./obj_dir/Vsoc

clean:
	rm -rf obj_dir
