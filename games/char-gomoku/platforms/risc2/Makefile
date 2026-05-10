# Char-Gomoku — RISC2 platform
#
# Game state lives in external RAM at MEM_EXT_RAM_BASE (PSRAM on HW=v2).
# All MMIO uses memmap.h symbols — no hardcoded peripheral addresses.
REPO_ROOT    = ../../../../
INCLUDE_DIRS = ../.. . $(ARCH_DIR)
VPATH_DIRS   = . ../..
GAME_SRCS    = game.c render.c hal_risc2.c main.c
EXTRA_CFLAGS = -fno-builtin -DRISC2_PLATFORM

include $(REPO_ROOT)arch/risc2/build.mk
