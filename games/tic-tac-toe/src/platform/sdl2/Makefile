CC      = gcc
CFLAGS  = -Wall -Wextra -std=c99 -O2 \
          -I../../hal \
          -I../../engine \
          $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs)

ENGINE  = ../../engine/game.c ../../engine/render.c
SRCS    = $(ENGINE) main.c
OBJS    = $(patsubst %.c,%.o,$(notdir $(SRCS)))
TARGET  = tic-tac-toe

vpath %.c ../../engine .

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

game.o: ../../engine/game.c
	$(CC) $(CFLAGS) -c $< -o $@

render.o: ../../engine/render.c
	$(CC) $(CFLAGS) -c $< -o $@

main.o: main.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
