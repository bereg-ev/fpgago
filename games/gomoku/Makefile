# games/gomoku/Makefile — flat per-game build entry.
#
# Replaces the old per-arch platforms/<arch>/Makefile trio.  The arch's
# build.mk does the heavy lifting; this file only declares what the game
# is made of (HAL kind, source files, name).
#
# Invocation (driven by the top-level Makefile):
#   make ARCH=sdl2          run-sdl2
#   make ARCH=risc2         run-verilator | run-fpga | run-gtkwave
#   make ARCH=riscv-darkrv  run-verilator | run-fpga

GAME_NAME = gomoku
HAL_KIND  = pixel
GAME_SRCS = game.c render.c main.c

ARCH      ?= sdl2
REPO_ROOT ?= ../../
ARCH_DIR  ?= $(REPO_ROOT)/arch/$(ARCH)

include $(ARCH_DIR)/build.mk
