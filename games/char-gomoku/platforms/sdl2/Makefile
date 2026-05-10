CC      = gcc
CFLAGS  = -Wall -Wextra -std=c99 -O2 \
          -I../.. -I. \
          $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs)

PORTABLE = ../../game.c ../../render.c
LOCAL    = main.c hal_sdl2.c
SRCS     = $(PORTABLE) $(LOCAL)
OBJS     = $(notdir $(SRCS:.c=.o))
TARGET   = char-gomoku

vpath %.c ../.. .

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
