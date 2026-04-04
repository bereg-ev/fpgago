ASM = ../../util/gcasm/gcasm
PROJECT = ../../arch/risc1

all: build copy

build:
	$(ASM) -crisc1 snake.asm

copy: build
	cp romL.vh $(PROJECT)/romL.vh

clean:
	rm -f rom.bin romL.vh romH.vh rom.hex

simulate: copy
	cd $(PROJECT) && ./simulate.sh

sdl: copy
	cd $(PROJECT)/sim-desktop && make run

run: copy
	cd $(PROJECT)/sim-desktop && make run

.PHONY: all build copy clean simulate sdl run
