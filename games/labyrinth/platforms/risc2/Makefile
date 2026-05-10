# Labyrinth — RISC2 platform
#
# Wolfenstein-style raycaster.  Engine sources here are RISC2-tuned variants
# (raycast_risc2.c uses dcache scanline writes + an embedded 16x16 brick
# texture; map_risc2.c hardcodes the level instead of loading from disk).
# All MMIO uses memmap.h symbols.
REPO_ROOT    = ../../../../
INCLUDE_DIRS = ../.. . $(ARCH_DIR)
VPATH_DIRS   = . ../..
GAME_SRCS    = main.c raycast_risc2.c trig_risc2.c map_risc2.c player_risc2.c
EXTRA_CFLAGS = -DPLATFORM_RISC2

include $(REPO_ROOT)arch/risc2/build.mk
