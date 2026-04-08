
CC = gcc
CFLAGS = -Wall -Wextra -pedantic -std=c11

SRCS = gcasm.c compile.c parse.c arch.c

OBJS = $(SRCS:.c=.o)

TARGET = gcasm

# Default target
all: $(TARGET)

# Link object files to create the executable
$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $(TARGET) $(OBJS)

# arch.c includes user_mnemonics.inc and user_archs.inc (managed by make copyarch/delarch)
user_mnemonics.inc:
	@echo "/* User-created mnemonic tables — managed by make copyarch/delarch. */" > $@

user_archs.inc:
	@echo "/* User-created cpu_t entries — managed by make copyarch/delarch. */" > $@

arch.o: arch.c user_mnemonics.inc user_archs.inc
	$(CC) $(CFLAGS) -c $< -o $@

# Compile source files to object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Clean up build files
clean:
	rm -f $(OBJS) $(TARGET) rom.bin rom.hex romL.vh romH.vh romL2.vh romH2.vh

# Phony targets
.PHONY: all clean