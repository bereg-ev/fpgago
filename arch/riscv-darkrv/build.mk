# arch/riscv-darkrv/build.mk — Shared RISC-V/DarkRISCV C→ROM build pipeline
#
# New (flat) layout — include from games/<game>/Makefile after setting:
#   HAL_KIND     — "pixel" or "char" (auto-adds arch/riscv-darkrv/hal_<kind>.c)
#   GAME_SRCS    — game C sources only (e.g., game.c render.c main.c)
#   EXTRA_CFLAGS — additional gcc flags (optional)
#
# Legacy (platforms/) layout — still supported.  Per-game
# platforms/riscv-darkrv/Makefile sets GAME_SRCS directly (including
# hal_pixel.c / hal_char.c) and overrides INCLUDE_DIRS / VPATH_DIRS.
# HAL_KIND is left unset in that mode.
#
# Provides targets:
#   all           — build rom.hex
#   install       — copy rom.hex into arch/riscv-darkrv/
#   run-verilator — install + run Verilator+SDL2 simulator
#   clean         — remove generated files
#
# Optional knobs (forwarded to sim-desktop):
#   HW   = v1|v2  — board variant (default: v2)
#   RAM  = bram|sdram|psram|ddr3  — RAM backing for 0x00010000-0x0001FFFF
#                 (default: bram).  Constraints:
#                   sdram → HW=v1 only
#                   psram → HW=v2 only
#                   ddr3  → HW=v2 only
#
# Toolchain prerequisite: brew install riscv64-elf-gcc

# ── HW + RAM defaults and validation ─────────────────────────────────────
HW  ?= v2
RAM ?= bram

ifneq ($(filter-out v1 v2,$(HW)),)
  $(error HW=$(HW) is not valid; expected HW=v1 or HW=v2)
endif
ifneq ($(filter-out bram sdram psram ddr3,$(RAM)),)
  $(error RAM=$(RAM) is not valid; expected RAM=bram|sdram|psram|ddr3)
endif
ifeq ($(RAM),sdram)
  ifneq ($(HW),v1)
    $(error RAM=sdram requires HW=v1 (currently HW=$(HW)); SDRAM lives on the HW=v1 board)
  endif
endif
ifeq ($(RAM),psram)
  ifneq ($(HW),v2)
    $(error RAM=psram requires HW=v2 (currently HW=$(HW)); QSPI PSRAM lives on the HW=v2 board)
  endif
endif
ifeq ($(RAM),ddr3)
  ifneq ($(HW),v2)
    $(error RAM=ddr3 requires HW=v2 (currently HW=$(HW)); DDR3 lives on the HW=v2 board)
  endif
endif
# Not yet implemented for riscv-darkrv:
ifeq ($(RAM),ddr3)
  $(error RAM=ddr3 is not yet implemented for riscv-darkrv (DDR3 not validated on real HW yet). Use RAM=psram, RAM=sdram, or RAM=bram.)
endif

REPO_ROOT    ?= ../../../../
ARCH_DIR     ?= $(REPO_ROOT)arch/riscv-darkrv
INSTALL_DIR  ?= $(ARCH_DIR)

CROSS    ?= riscv64-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump

INCLUDE_DIRS ?= . $(ARCH_DIR) $(REPO_ROOT)/peripheral
VPATH_DIRS   ?= .

# Flat-layout auto-include: when the per-game Makefile sets HAL_KIND, pull in
# the matching arch HAL file and make sure the arch dir is on VPATH+include
# paths.  Legacy platforms/riscv-darkrv/Makefile leaves HAL_KIND empty.
# Legacy platforms/ Makefile builds in cwd (BUILD_DIR=.); flat layout uses a
# per-arch subdir so SDL2 .o files don't trample these and vice versa.
BUILD_DIR ?= .

ifneq ($(HAL_KIND),)
  GAME_SRCS    += hal_$(HAL_KIND).c
  VPATH_DIRS   += $(ARCH_DIR)
  INCLUDE_DIRS += . $(ARCH_DIR) $(REPO_ROOT)/peripheral
  # Games use this to compile out anything that won't fit in BRAM (e.g.
  # chess's 1 MB transposition table).  Define unconditionally — there's
  # nothing on this arch that *wants* the desktop-class code paths.
  EXTRA_CFLAGS += -DPLATFORM_RISCV_DARKRV
  BUILD_DIR     = build-riscv-darkrv
endif

vpath %.c $(VPATH_DIRS)
vpath %.s $(VPATH_DIRS) $(ARCH_DIR)

BASE_CFLAGS = -march=rv32i_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib \
              -fno-builtin -fno-stack-protector -fno-pic \
              -ffunction-sections -fdata-sections \
              -Wall -Wno-unused-function \
              $(addprefix -I,$(INCLUDE_DIRS))
ALL_CFLAGS  = $(BASE_CFLAGS) $(EXTRA_CFLAGS)

LDFLAGS = -march=rv32i_zicsr -mabi=ilp32 -nostdlib -static \
          -T $(ARCH_DIR)/link.ld -Wl,--gc-sections

GAME_OBJS = $(addprefix $(BUILD_DIR)/,$(notdir $(GAME_SRCS:.c=.o)))
ALL_OBJS  = $(BUILD_DIR)/startup.o $(GAME_OBJS)

.PHONY: all install run-verilator run-fpga run-gtkwave clean dis

all: $(BUILD_DIR)/rom.hex

$(BUILD_DIR):
	@mkdir -p $@

$(BUILD_DIR)/startup.o: $(ARCH_DIR)/startup.s | $(BUILD_DIR)
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

$(BUILD_DIR)/firmware.elf: $(ALL_OBJS) $(ARCH_DIR)/link.ld | $(BUILD_DIR)
	$(CC) $(LDFLAGS) -o $@ $(ALL_OBJS) -lgcc

$(BUILD_DIR)/firmware.bin: $(BUILD_DIR)/firmware.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD_DIR)/rom.hex: $(BUILD_DIR)/firmware.bin
	hexdump -v -e '1/4 "%08x\n"' $< > $@

install: $(BUILD_DIR)/rom.hex
	cp $(BUILD_DIR)/rom.hex $(INSTALL_DIR)/

run-verilator: install
	$(MAKE) -C $(ARCH_DIR)/sim-desktop run SIM_GAME=$(SIM_GAME) SIM_ARCH=$(SIM_ARCH) HW=$(HW) RAM=$(RAM)

run-fpga: install
	@cd $(ARCH_DIR) && HW=$(HW) RAM=$(RAM) bash run.sh

run-gtkwave:
	@echo "run-gtkwave: not yet implemented for riscv-darkrv"
	@exit 1

dis: $(BUILD_DIR)/firmware.elf
	$(OBJDUMP) -d $< | less

clean:
ifeq ($(BUILD_DIR),.)
	rm -f *.o firmware.elf firmware.bin rom.hex
else
	rm -rf $(BUILD_DIR)
endif
