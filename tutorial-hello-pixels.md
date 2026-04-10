In the previous Hello world tutorial we added a new CPU instruction to risc1 and wrote assembly code to use it. 
Now let's move on to risc2, which runs C code and has a memory bus — opening the door to direct framebuffer access. 
Our goal is simple: draw pixels to the screen from C.

Unlike risc1, where we had to work with a character display, risc2 drives a graphical LCD at 480x272 pixels. 
The framebuffer sits in memory, and writing a value to the right address puts a color on the screen. 
That's as close as it gets to "Hello World" in hardware graphics.

Let's create a new game project:

`make newgame GAME=hello-pixels ARCH=risc2`

This generates the folder structure under `games/hello-pixels/` with template source files and Makefiles configured for the risc2 CPU. 
Open `games/hello-pixels/src/engine/game.c` and replace its contents with this:

```c
#include "game.h"
#include "../hal/hal.h"

void game_init(game_t *g)
{
    int x, y;
    g->counter = 0;

    for (y = 0; y < SCREEN_H; y++) {
        for (x = 0; x < SCREEN_W; x++) {
            unsigned short r = x * 31 / SCREEN_W;
            unsigned short green = y * 63 / SCREEN_H;
            unsigned short b = 31 - r;
            unsigned short color = (r << 11) | (green << 5) | b;
            lcd_set_pixel(x, y, color);
        }
    }
    lcd_present();
}

void game_tick(game_t *g, int input)
{
    (void)input;
    g->counter++;
}
```

What this does: inside `game_init`, for every pixel on the screen, it computes an RGB565 color value based on the pixel's position. 
Red increases from left to right, green increases from top to bottom, and blue decreases from left to right. 
The result is a smooth diagonal gradient that fills the entire screen. The call to `lcd_present()` at the end flushes the last row and swaps the display buffers.

RGB565 means 5 bits for red, 6 bits for green, and 5 bits for blue — 16 bits per pixel, which is the native format of the LCD controller. The bit layout looks like this:

```
Bit:  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
       R  R  R  R  R  G  G  G  G  G  G  B  B  B  B  B
```

The `lcd_set_pixel` and `lcd_present` functions are provided by `hal.h`. 
Under the hood, `lcd_set_pixel` writes the color value to a scanline buffer at the column corresponding to x. 
When the row changes, the previous row is flushed to the framebuffer in SDRAM. When targeting SDL2, it simply writes to an in-memory pixel array.

Let's try the SDL2 simulation first, since it's much faster:

`make run GAME=hello-pixels TARGET=sdl2`

<img src="/media/hello-pixels-sdl2.png" style="max-width: 800px">

You should see the gradient fill the window almost instantly. Now let's try the Verilator simulation:

`make run GAME=hello-pixels ARCH=risc2 TARGET=verilator`

<img src="/media/hello-pixels-verilator.png" style="max-width: 800px">

This time it takes noticeably longer. 
You will first see the random initial contents of SDRAM, then the gradient will appear row by row as the CPU writes each pixel. 
This is what it looks like on real hardware too — the CPU is executing Verilog-simulated instructions one by one, 
and each pixel write goes through the memory bus to the framebuffer.

This difference between the SDL2 and Verilator simulations is worth understanding. 
SDL2 runs your C code natively on your desktop — it's fast but doesn't simulate the hardware. 
Verilator compiles all the Verilog (CPU, memory bus, LCD controller) into C++ and simulates every clock cycle. 
It's slow, but what you see is exactly what the FPGA would produce.

Now let's make it more interesting. Replace `game.c` with a checkerboard pattern:

```c
#include "game.h"
#include "../hal/hal.h"

#define TILE_SIZE 16

void game_init(game_t *g)
{
    int x, y;
    g->counter = 0;

    for (y = 0; y < SCREEN_H; y++) {
        for (x = 0; x < SCREEN_W; x++) {
            int tx = x / TILE_SIZE;
            int ty = y / TILE_SIZE;
            unsigned short color;
            if ((tx + ty) % 2 == 0) {
                color = 0xFFFF;  /* white */
            } else {
                color = 0x18E3;  /* dark green */
            }
            lcd_set_pixel(x, y, color);
        }
    }
    lcd_present();
}

void game_tick(game_t *g, int input)
{
    (void)input;
    g->counter++;
}
```

`make run GAME=hello-pixels TARGET=sdl2`

<img src="/media/hello-pixels-checker.png" style="max-width: 800px">

Notice that we used integer division (`x / TILE_SIZE`) to determine which tile a pixel belongs to. 
The risc2 CPU does not have a hardware divider — the compiler generates a software division routine. 
For a pixel-drawing demo this is fine, but in a real game you would want to avoid division in performance-critical loops. 
Using bit shifts (powers of two) or lookup tables is the standard approach.

This tutorial covered the basics: creating a risc2 C project, writing pixels to the framebuffer via `lcd_set_pixel`, 
and understanding the difference between SDL2 and Verilator simulations. From here, you can draw lines, shapes, text, 
sprites — everything a game needs starts with putting the right color at the right pixel.
