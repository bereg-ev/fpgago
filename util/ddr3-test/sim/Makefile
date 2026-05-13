# util/ddr3-test/sim/Makefile — Verilator harness for the ddr3-test SoC.
#
# Build:  make
# Run  :  make run         (default 2M cycles)
#         SIM_SCRIPT="iq" make run    (send 'i' then 'q')

REPO_ROOT  = ../../../
ARCH_DIR   = $(REPO_ROOT)arch/risc2
CPU_DIR    = $(ARCH_DIR)/cpu
PER_DIR    = $(REPO_ROOT)peripheral
UTIL_DIR   = $(REPO_ROOT)util
TEST_DIR   = ..

VERILATOR  ?= verilator
CXX        ?= clang++
CXXFLAGS   ?= -O2 -std=c++17 -Wall

VFLAGS  = --cc --exe \
          -DSIMULATION \
          -I$(TEST_DIR) -I$(CPU_DIR) -I. \
          --top-module ddr3_test_soc \
          --no-timing \
          -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-PINMISSING -Wno-CASEINCOMPLETE

# In sim we use ecp5_simul.v instead of ecp5.v — same module names, but
# the _simul variant has behavioural BRAM models instead of DP16KD primitives.
VSRCS = \
    $(TEST_DIR)/ddr3_test_soc.v \
    $(CPU_DIR)/cpu_risc2.v \
    $(CPU_DIR)/alu_risc2.v \
    $(UTIL_DIR)/ecp5_simul.v \
    $(PER_DIR)/uart.v \
    $(PER_DIR)/ddr3_iface.v \
    ddr3_axi_sim.v

CPPSRCS = sim_top.cpp

.PHONY: all run clean

all: obj_dir/Vddr3_test_soc

obj_dir/Vddr3_test_soc: $(VSRCS) $(CPPSRCS) $(TEST_DIR)/rom.hex
	$(VERILATOR) $(VFLAGS) $(VSRCS) $(CPPSRCS)
	$(MAKE) -C obj_dir -f Vddr3_test_soc.mk

run: obj_dir/Vddr3_test_soc
	./obj_dir/Vddr3_test_soc

clean:
	rm -rf obj_dir
