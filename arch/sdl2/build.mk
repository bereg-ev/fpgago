# arch/sdl2/build.mk — Shared SDL2 build pipeline for fpgago games.
#
# Include from games/<game>/Makefile after setting:
#   GAME_NAME    — name of the binary
#   HAL_KIND     — "pixel" or "char" (selects arch/sdl2/hal_<kind>.c)
#   GAME_SRCS    — game C sources (e.g., game.c render.c main.c glyphs.c)
#   EXTRA_CFLAGS — optional extra gcc flags
#
# Provides targets:
#   all       — build the binary (lands in $(BUILD_DIR)/$(GAME_NAME))
#   run-sdl2  — build + run
#   clean     — wipe this arch's build dir only
#
# Per-arch build dir keeps SDL2 .o files out of the way of cross-compiled
# .o files from arch/risc2 / arch/riscv-darkrv when the same game is built
# for multiple targets.

REPO_ROOT  ?= ../..
ARCH_DIR   ?= $(REPO_ROOT)/arch/sdl2
PERIPH_DIR ?= $(REPO_ROOT)/peripheral
BUILD_DIR  ?= build-sdl2

CC      ?= gcc
SDL_CFG ?= sdl2-config

CFLAGS  = -Wall -Wextra -std=c99 -O2 \
          -I. -I$(ARCH_DIR) -I$(PERIPH_DIR) \
          $(shell $(SDL_CFG) --cflags) \
          $(EXTRA_CFLAGS)
LDFLAGS = $(shell $(SDL_CFG) --libs)

ifeq ($(HAL_KIND),)
  $(error HAL_KIND must be set (pixel|char) in games/<game>/Makefile)
endif
HAL_SRC  = $(ARCH_DIR)/hal_$(HAL_KIND).c
ALL_SRCS = $(GAME_SRCS) $(HAL_SRC)
OBJS     = $(addprefix $(BUILD_DIR)/,$(notdir $(ALL_SRCS:.c=.o)))

TARGET   = $(BUILD_DIR)/$(GAME_NAME)

vpath %.c . $(ARCH_DIR)

.PHONY: all clean run-sdl2

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $@

$(TARGET): $(OBJS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

run-sdl2: all
	./$(TARGET)

clean:
	rm -rf $(BUILD_DIR)
