# games/tic-tac-toe/Makefile — flat per-game build entry.

GAME_NAME = tic-tac-toe
HAL_KIND  = char
GAME_SRCS = game.c render.c main.c

ARCH      ?= sdl2
REPO_ROOT ?= ../../
ARCH_DIR  ?= $(REPO_ROOT)/arch/$(ARCH)

include $(ARCH_DIR)/build.mk
