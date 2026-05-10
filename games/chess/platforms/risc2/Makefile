# Chess — RISC2 platform
#
# Game state (game_t) and zobrist tables live in external RAM at 0x100000
# (PSRAM on HW=v2), not in the 16KB BRAM data region.  See main.c.
REPO_ROOT    = ../../../../
INCLUDE_DIRS = ../.. . $(ARCH_DIR)
VPATH_DIRS   = . ../..
GAME_SRCS    = game.c render.c hal_risc2.c main.c
EXTRA_CFLAGS = -fno-builtin -DRISC2_PLATFORM

include $(REPO_ROOT)arch/risc2/build.mk
