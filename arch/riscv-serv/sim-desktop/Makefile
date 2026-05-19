#
# sim-desktop/Makefile — Verilator simulation of the riscv-serv minimal SoC.
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
    $(PROJ)/cpu_serv.v \
    $(PROJ)/serv_aligner.v \
    $(PROJ)/serv_alu.v \
    $(PROJ)/serv_bufreg.v \
    $(PROJ)/serv_bufreg2.v \
    $(PROJ)/serv_compdec.v \
    $(PROJ)/serv_csr.v \
    $(PROJ)/serv_ctrl.v \
    $(PROJ)/serv_decode.v \
    $(PROJ)/serv_immdec.v \
    $(PROJ)/serv_mem_if.v \
    $(PROJ)/serv_rf_if.v \
    $(PROJ)/serv_rf_ram.v \
    $(PROJ)/serv_rf_ram_if.v \
    $(PROJ)/serv_rf_top.v \
    $(PROJ)/serv_state.v \
    $(PROJ)/serv_top.v

.PHONY: all run clean
all:
	verilator $(VFLAGS) $(VSRCS) sim_top.cpp
	@echo ""
	@echo "Build complete. Run with: SIM_EXIT_ON_NEWLINE=1 ./obj_dir/Vsoc"

run: all
	SIM_EXIT_ON_NEWLINE=1 SIM_MAX_CYCLES=10000 ./obj_dir/Vsoc

clean:
	rm -rf obj_dir
