# FPGA 1541 building blocks (retro-arch/c64/README.md).
#
#   make check-via     via6522.v lockstep vs common/floppy1541/via6522.c (~10 s)
#   make check-drive   full drive + real DOS ROM, IEC-scripted (~2-4 min)
#   make check         everything

F1541_DIR = $(abspath ../floppy1541)
CPU6502   = ../cpu/6502
ROM1541   = ../../plus4/roms/1541.bin

.PHONY: check check-via check-drive check-drive-psram clean

check: check-via check-drive check-drive-psram

check-via:
	verilator --cc via6522.v --exe tb_via6522.cpp \
	    -CFLAGS "-I$(F1541_DIR) -O2" --build -j 4 \
	    -Mdir obj_via -o via_tb --top-module via6522
	./obj_via/via_tb

check-drive:
	@test -f $(ROM1541) || { echo "need the 16KB 1541 ROM at $(ROM1541)"; exit 1; }
	verilator --cc -Wno-fatal drive_1541.v via6522.v \
	    $(CPU6502)/cpu_6502.v $(CPU6502)/ALU.v \
	    --exe tb_drive1541.cpp $(F1541_DIR)/cpu6502.c $(F1541_DIR)/via6522.c \
	    -CFLAGS "-I$(F1541_DIR) -O2" --build -j 4 \
	    -Mdir obj_drive -o drive_tb --top-module drive_1541
	cd obj_drive && ./drive_tb +rom=../$(ROM1541)

# same DOS conformance, but ROM+GCR live in the (behavioural, pessimistic-
# latency) PSRAM behind drive_psram.v, loaded via the push port, with the
# stretchable-phi generator — the full phase-3 memory path (~5-10 min).
check-drive-psram:
	@test -f $(ROM1541) || { echo "need the 16KB 1541 ROM at $(ROM1541)"; exit 1; }
	verilator --cc -Wno-fatal drive_psram_top.v drive_1541.v drive_psram.v \
	    psram_cmd_behav.v via6522.v \
	    $(CPU6502)/cpu_6502.v $(CPU6502)/ALU.v \
	    --exe tb_drive1541.cpp $(F1541_DIR)/cpu6502.c $(F1541_DIR)/via6522.c \
	    -CFLAGS "-I$(F1541_DIR) -O2 -DPSRAM_TOP" --build -j 4 \
	    -Mdir obj_dpsram -o dpsram_tb --top-module drive_psram_top
	cd obj_dpsram && ./dpsram_tb +rom=../$(ROM1541)

clean:
	rm -rf obj_via obj_drive obj_dpsram
