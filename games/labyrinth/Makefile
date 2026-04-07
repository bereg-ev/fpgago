# Makefile — wolf-clone raycasting engine (SDL2 platform)
#
# Usage:
#   make          — build wolf-clone executable
#   make clean    — remove build artefacts
#   make run      — build and launch with the default map
#
# Requires SDL2: brew install sdl2  (macOS)
#                sudo apt install libsdl2-dev  (Debian/Ubuntu)

CC      = gcc
CFLAGS  = -Wall -Wextra -pedantic -std=c11 \
          -O2 \
          -I src/engine \
          $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs) -lm

ENGINE_SRCS = \
    src/engine/trig.c    \
    src/engine/map.c     \
    src/engine/player.c  \
    src/engine/texture.c \
    src/engine/raycast.c

PLATFORM_SRCS = \
    src/platform/sdl2/main.c

SRCS = $(ENGINE_SRCS) $(PLATFORM_SRCS)
OBJS = $(SRCS:.c=.o)

TARGET = labyrinth

ifeq ($(OS),Windows_NT)
  EXEEXT = .exe
else
  EXEEXT =
endif

.PHONY: all clean run

all: $(TARGET)$(EXEEXT)

$(TARGET)$(EXEEXT): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

run: $(TARGET)$(EXEEXT)
	./$(TARGET)$(EXEEXT) assets/map.txt

clean:
	rm -f $(OBJS) $(TARGET) $(TARGET).exe
