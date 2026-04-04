/*
 * test_gfx.c — GPU3D basic graphics test: rectangles + diagonal lines
 *
 * Draws the EXACT same scene as test_gfx.asm so you can compare output.
 * If this works but test_gfx.asm doesn't (or vice versa), you know which
 * layer has the bug.
 *
 * Build:
 *   ~/llvm-risc2-build/bin/clang --target=risc2 -O1 -S -x c \
 *       gpu3d_demo/test_gfx.c -o gpu3d_demo/test_gfx_c.s
 *   Then concatenate startup.s + runtime.s + test_gfx_c.s and assemble:
 *   cat gpu3d_demo/startup.s gpu3d_demo/runtime.s gpu3d_demo/test_gfx_c.s > gpu3d_demo/test_gfx_combined.s
 *   ../../asm-compiler/gcasm -crisc2 gpu3d_demo/test_gfx_combined.s
 */

/* ── GPU3D register access ───────────────────────────────────────────────── */
#define GPU_BASE      0x0A0000
#define GPU_REG(n)    (*(volatile unsigned int*)(GPU_BASE + (n)*4))
#define GPU_V0X       GPU_REG(0)
#define GPU_V0Y       GPU_REG(1)
#define GPU_V1X       GPU_REG(2)
#define GPU_V1Y       GPU_REG(3)
#define GPU_V2X       GPU_REG(4)
#define GPU_V2Y       GPU_REG(5)
#define GPU_TRI_COLOR GPU_REG(6)
#define GPU_CLR_COLOR GPU_REG(7)
#define GPU_CMD       GPU_REG(8)
#define GPU_STATUS    GPU_REG(9)

#define CMD_DRAW_TRI     1
#define CMD_CLEAR_FB     2
#define CMD_SWAP_BUFFERS 3

#define RGB565(r,g,b)  (((r)<<11)|((g)<<5)|(b))

/* ── I/O ─────────────────────────────────────────────────────────────────── */
#define IO_SET_BIT  (*(volatile unsigned int*)0x0F0000)
#define LCD_CHAR_X  (*(volatile unsigned int*)0x0C0000)

static void gpu_wait(void) { while (GPU_STATUS & 1); }

static void gpu_clear(unsigned int color) {
    gpu_wait();
    GPU_CLR_COLOR = color;
    GPU_CMD       = CMD_CLEAR_FB;
}

static void gpu_swap(void) {
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
}

static void gpu_tri(int x0, int y0, int x1, int y1, int x2, int y2,
                    unsigned int color) {
    gpu_wait();
    GPU_V0X = x0;  GPU_V0Y = y0;
    GPU_V1X = x1;  GPU_V1Y = y1;
    GPU_V2X = x2;  GPU_V2Y = y2;
    GPU_TRI_COLOR = color;
    GPU_CMD = CMD_DRAW_TRI;
}

/* Draw a filled rectangle as two triangles */
static void gpu_rect(int x0, int y0, int x1, int y1, unsigned int color) {
    gpu_tri(x0, y0, x1, y0, x1, y1, color);   /* upper-right triangle */
    gpu_tri(x0, y0, x1, y1, x0, y1, color);   /* lower-left triangle  */
}

/* Draw a diagonal line as a thin triangle (2px wide at one end) */
static void gpu_line(int x0, int y0, int x1, int y1, unsigned int color) {
    gpu_tri(x0, y0, x1, y1, x1, y1 - 2, color);
}

int main(void) {
    /* Disable lcd_char overlay */
    LCD_CHAR_X = 480;

    /* Clear to dark blue */
    gpu_clear(RGB565(0, 0, 16));

    /* Rectangle 1: RED (50,30)-(200,100) */
    gpu_rect(50, 30, 200, 100, RGB565(31, 0, 0));

    /* Rectangle 2: GREEN (220,30)-(430,100) */
    gpu_rect(220, 30, 430, 100, RGB565(0, 63, 0));

    /* Rectangle 3: YELLOW (100,140)-(380,230) */
    gpu_rect(100, 140, 380, 230, RGB565(31, 63, 0));

    /* Diagonal line 1: WHITE from (10,10) to (470,260) */
    gpu_line(10, 10, 470, 260, RGB565(31, 63, 31));

    /* Diagonal line 2: CYAN from (470,10) to (10,260) */
    gpu_line(470, 10, 10, 260, RGB565(0, 63, 31));

    /* Show the frame */
    gpu_swap();

    /* LED1 on = test done */
    IO_SET_BIT = 1;

    /* Halt */
    for (;;);

    return 0;
}
