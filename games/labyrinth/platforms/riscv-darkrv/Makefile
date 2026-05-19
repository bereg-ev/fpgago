# Labyrinth — riscv-darkrv platform
#
# Wolfenstein-style raycaster running on the DarkRISCV RV32I core.
# Engine source files (player.c, raycast.c, texture.c) come from
# games/labyrinth/platforms/sdl2/  — pure C, no SDL dependency.

REPO_ROOT    = ../../../../
INCLUDE_DIRS = . ../.. $(REPO_ROOT)arch/riscv-darkrv
# Engine: raycast.c + texture.c are local (16bpp RGB565).  player.c is
# shared with platforms/sdl2/ (pure C, no pixel format dependency).
VPATH_DIRS   = . ../sdl2
GAME_SRCS    = main.c map_riscv.c trig_data.c \
               player.c raycast.c texture.c
# PLATFORM_RISCV_DARKRV selects the `const extern` trig table declaration in
# trig.h so the tables live in .rodata (ROM), not .bss (RAM).
EXTRA_CFLAGS = -DPLATFORM_RISCV_DARKRV

include $(REPO_ROOT)arch/riscv-darkrv/build.mk
