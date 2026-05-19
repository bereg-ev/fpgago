# games/labyrinth2/Makefile — flat per-game build entry.

GAME_NAME = labyrinth2
HAL_KIND  = pixel
GAME_SRCS = main.c raycast.c player.c map.c trig.c texture.c
# Full textured raycast (no diagnostic flags)

ARCH      ?= sdl2
REPO_ROOT ?= ../../
ARCH_DIR  ?= $(REPO_ROOT)/arch/$(ARCH)

include $(ARCH_DIR)/build.mk
