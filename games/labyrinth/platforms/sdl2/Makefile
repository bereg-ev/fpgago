# Labyrinth — SDL2 platform
#
# Wolfenstein-style raycaster.  Engine sources live here (this implementation
# uses the desktop file-loading map.c and float-free fixed-point math), and
# share their header API with the RISC2 implementation under platforms/risc2/.
#
# Run target loads ../../assets/map.txt by default.

CC      = gcc
CFLAGS  = -Wall -Wextra -pedantic -std=c11 -O2 \
          -I../.. -I. \
          $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs) -lm

ENGINE_SRCS = trig.c map.c player.c texture.c raycast.c
LOCAL_SRCS  = main.c
SRCS        = $(ENGINE_SRCS) $(LOCAL_SRCS)
OBJS        = $(SRCS:.c=.o)

ifeq ($(OS),Windows_NT)
  EXEEXT = .exe
else
  EXEEXT =
endif

TARGET = labyrinth$(EXEEXT)

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

run: $(TARGET)
	./$(TARGET) ../../assets/map.txt

clean:
	rm -f $(OBJS) $(TARGET)
