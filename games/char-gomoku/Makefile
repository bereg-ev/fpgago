# games/char-gomoku/Makefile — flat per-game build entry.
#
# Includes glyphs.c which uploads the custom board-cell bitmaps via
# hal_upload_glyph(); see games/char-gomoku/glyphs.h.

GAME_NAME = char-gomoku
HAL_KIND  = char
GAME_SRCS = game.c render.c main.c glyphs.c

ARCH      ?= sdl2
REPO_ROOT ?= ../../
ARCH_DIR  ?= $(REPO_ROOT)/arch/$(ARCH)

include $(ARCH_DIR)/build.mk
