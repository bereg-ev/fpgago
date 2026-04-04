/*
 * demo.c — Rotating cube demo, diagnostic version with UART + waits.
 *
 * All types are int/unsigned — NO char/short (LLVM RISC2 backend EXTLOAD crash).
 * Strings are int arrays terminated by 0.
 */

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

#define IO_SET_BIT   (*(volatile unsigned int*)0x0F0000)
#define IO_CLR_BIT   (*(volatile unsigned int*)0x0F0001)
#define IO_READ_BIT  (*(volatile unsigned int*)0x0F0002)
#define UART_TX      (*(volatile unsigned int*)0x0F0003)
#define UART_RX      (*(volatile unsigned int*)0x0F0004)

/* ── UART helpers (int only, no char) ──────────────────────────────────── */
static void uart_putc(int ch) {
    while (IO_READ_BIT & 4) { }
    UART_TX = ch;
}

/* Print a string packed as an int array (one ASCII char per int, 0-terminated) */
static void uart_msg(const int *s) {
    int i = 0;
    while (s[i] != 0) {
        uart_putc(s[i]);
        i++;
    }
}

/* Shorter: print a few chars inline */
static void uart_crlf(void) { uart_putc(13); uart_putc(10); }

/* Print 32-bit value as hex — extract nibbles from bottom, no variable shifts */
static void uart_puth(unsigned int v) {
    int nibs[8];
    int n = 0;
    int i;
    if (v == 0) { uart_putc('0'); return; }
    while (v != 0) {
        nibs[n] = v & 15;
        /* v >>= 4 using four single-bit shifts (avoids __lshrsi3 call) */
        v = v >> 1;
        v = v >> 1;
        v = v >> 1;
        v = v >> 1;
        n = n + 1;
    }
    i = n - 1;
    while (i >= 0) {
        int d = nibs[i];
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
        i = i - 1;
    }
}

/* Print signed value as hex with sign */
static void uart_putd(int v) {
    if (v < 0) {
        uart_putc('-');
        uart_puth((unsigned int)(0 - v));
    } else {
        uart_puth((unsigned int)v);
    }
}

static int uart_getc(void) {
    while (!(IO_READ_BIT & 1)) { }   /* wait for rxrdy = bit 0 */
    return UART_RX;
}

static void uart_wait_key(void) {
    uart_putc('>');
    uart_getc();
    uart_crlf();
}

/* Print label=value expect=exp */
static void uart_check(int label_ch, int value, int expected) {
    uart_putc(' '); uart_putc(' '); uart_putc(label_ch); uart_putc('=');
    uart_putd(value);
    uart_putc(' '); uart_putc('e'); uart_putc('x'); uart_putc('p'); uart_putc('=');
    uart_putd(expected);
    if (value == expected) {
        uart_putc(' '); uart_putc('O'); uart_putc('K');
    } else {
        uart_putc(' '); uart_putc('F'); uart_putc('A'); uart_putc('I'); uart_putc('L');
    }
    uart_crlf();
}

/* ── GPU helpers ───────────────────────────────────────────────────────── */
static void gpu_wait(void) { while (GPU_STATUS & 1); }

static void gpu_clear(unsigned int c) {
    gpu_wait();
    GPU_CLR_COLOR = c;
    GPU_CMD       = CMD_CLEAR_FB;
}

static void gpu_swap(void) {
    gpu_wait();
    GPU_CMD = CMD_SWAP_BUFFERS;
}

static void gpu_tri(int x0, int y0, int x1, int y1, int x2, int y2,
                    unsigned int colour) {
    gpu_wait();
    GPU_V0X = x0;  GPU_V0Y = y0;
    GPU_V1X = x1;  GPU_V1Y = y1;
    GPU_V2X = x2;  GPU_V2Y = y2;
    GPU_TRI_COLOR = colour;
    GPU_CMD = CMD_DRAW_TRI;
}

/* ── Const data in ROM ─────────────────────────────────────────────────── */
static const int sin_tab[256] = {
      0,   6,  13,  19,  25,  31,  38,  44,  50,  56,  62,  68,  74,  80,  86,  92,
     98, 104, 109, 115, 121, 126, 132, 137, 142, 147, 152, 157, 162, 167, 171, 176,
    180, 185, 189, 193, 197, 201, 205, 208, 212, 215, 219, 222, 225, 228, 231, 234,
    236, 239, 241, 243, 245, 247, 248, 250, 251, 252, 253, 254, 255, 255, 256, 256,
    256, 256, 256, 255, 255, 254, 253, 252, 251, 250, 248, 247, 245, 243, 241, 239,
    236, 234, 231, 228, 225, 222, 219, 215, 212, 208, 205, 201, 197, 193, 189, 185,
    180, 176, 171, 167, 162, 157, 152, 147, 142, 137, 132, 126, 121, 115, 109, 104,
     98,  92,  86,  80,  74,  68,  62,  56,  50,  44,  38,  31,  25,  19,  13,   6,
      0,  -6, -13, -19, -25, -31, -38, -44, -50, -56, -62, -68, -74, -80, -86, -92,
    -98,-104,-109,-115,-121,-126,-132,-137,-142,-147,-152,-157,-162,-167,-171,-176,
   -180,-185,-189,-193,-197,-201,-205,-208,-212,-215,-219,-222,-225,-228,-231,-234,
   -236,-239,-241,-243,-245,-247,-248,-250,-251,-252,-253,-254,-255,-255,-256,-256,
   -256,-256,-256,-255,-255,-254,-253,-252,-251,-250,-248,-247,-245,-243,-241,-239,
   -236,-234,-231,-228,-225,-222,-219,-215,-212,-208,-205,-201,-197,-193,-189,-185,
   -180,-176,-171,-167,-162,-157,-152,-147,-142,-137,-132,-126,-121,-115,-109,-104,
    -98, -92, -86, -80, -74, -68, -62, -56, -50, -44, -38, -31, -25, -19, -13,  -6
};

#define N_VERTS 8
#define N_TRIS  12
#define CUBE_S  64
#define CUBE_Z  300
#define FOCAL   200
#define SCR_CX  240
#define SCR_CY  136

static const int vx_c[8] = {-CUBE_S,  CUBE_S,  CUBE_S, -CUBE_S, -CUBE_S,  CUBE_S,  CUBE_S, -CUBE_S};
static const int vy_c[8] = {-CUBE_S, -CUBE_S,  CUBE_S,  CUBE_S, -CUBE_S, -CUBE_S,  CUBE_S,  CUBE_S};
static const int vz_c[8] = {-CUBE_S, -CUBE_S, -CUBE_S, -CUBE_S,  CUBE_S,  CUBE_S,  CUBE_S,  CUBE_S};
static const int tri_a[12] = {0, 0, 5, 5, 4, 4, 1, 1, 3, 3, 4, 4};
static const int tri_b[12] = {1, 2, 4, 7, 0, 3, 5, 6, 2, 6, 5, 1};
static const int tri_c[12] = {2, 3, 7, 6, 3, 7, 6, 2, 6, 7, 1, 0};
static const unsigned int face_col[6] = {
    RGB565(31,0,0), RGB565(0,63,0), RGB565(0,0,31),
    RGB565(31,63,0), RGB565(31,0,31), RGB565(0,63,31)
};

/* ── Working arrays in data RAM ──────────────────────────────────────── */
#define RAM  0x010000
#define SX   ((int*)(RAM +   0))
#define SY   ((int*)(RAM +  32))
#define RZ   ((int*)(RAM +  64))
#define TAVG ((int*)(RAM +  96))
#define TIDX ((int*)(RAM + 144))

/* ═══════════════════════════════════════════════════════════════════════ */
int main(void) {
    int ax, ay, i, j;

    /* ── P1: hardcoded triangle ──────────────────────────────────────── */
    uart_putc('P'); uart_putc('1'); uart_crlf();
    gpu_clear(RGB565(0, 0, 8));
    gpu_tri(200, 50, 300, 200, 100, 200, RGB565(0, 63, 0));
    gpu_swap();
    uart_wait_key();

    /* ── P2: ROM data reads ──────────────────────────────────────────── */
    uart_putc('P'); uart_putc('2'); uart_crlf();
    uart_check('A', sin_tab[0],  0);
    uart_check('B', sin_tab[64], 256);
    uart_check('C', sin_tab[128], 0);
    uart_check('D', vx_c[0], -64);
    uart_check('E', vx_c[1],  64);
    {
        int s64 = sin_tab[64];
        gpu_clear(RGB565(0, 0, 8));
        gpu_tri(s64, 50, s64 + 50, 200, s64 - 50, 200, RGB565(31, 0, 0));
        gpu_swap();
    }
    uart_wait_key();

    /* ── P3: multiply + shift ────────────────────────────────────────── */
    uart_putc('P'); uart_putc('3'); uart_crlf();
    uart_check('A', 64 * 256, 16384);
    uart_check('B', (64 * 256) >> 8, 64);
    uart_check('C', (-64) * 256, -16384);
    uart_check('D', ((-64) * 256) >> 8, -64);
    {
        int s1 = (64 * 256) >> 8;
        int s2 = ((-64) * 256) >> 8;
        gpu_clear(RGB565(0, 0, 8));
        gpu_tri(240+s1, 50, 240+s1+40, 150, 240+s1-40, 150, RGB565(0,63,31));
        gpu_tri(240+s2, 50, 240+s2+40, 150, 240+s2-40, 150, RGB565(31,0,31));
        gpu_swap();
    }
    uart_wait_key();

    /* ── P4: divide ──────────────────────────────────────────────────── */
    uart_putc('P'); uart_putc('4'); uart_crlf();
    /* a: 51200/300 should be 170 = 0xAA */
    {
        int d = 51200 / 300;
        uart_check('A', d, 170);
    }
    /* b: 51200/236 should be 216 = 0xD8 */
    {
        int d = 51200 / 236;
        uart_check('B', d, 216);
    }
    uart_wait_key();

    /* ── P5: static cube at angle 0 ──────────────────────────────────── */
    uart_putc('P'); uart_putc('5'); uart_crlf();
    {
        int cay = sin_tab[64];
        int say = sin_tab[0];
        int cax = sin_tab[64];
        int sax = sin_tab[0];

        for (i = 0; i < N_VERTS; i++) {
            int x = vx_c[i];
            int y = vy_c[i];
            int z = vz_c[i];
            int nx = (x * cay - z * say) >> 8;
            int nz = (x * say + z * cay) >> 8;
            int ny = (y * cax - nz * sax) >> 8;
            int nz2 = (y * sax + nz * cax) >> 8;
            int fz = nz2 + CUBE_Z;
            RZ[i] = fz;
            if (fz <= 0) fz = 1;
            int scale = FOCAL * 256 / fz;
            int px = ((nx * scale) >> 8) + SCR_CX;
            int py = ((ny * scale) >> 8) + SCR_CY;
            if (px < 0)   px = 0;
            if (px > 479) px = 479;
            if (py < 0)   py = 0;
            if (py > 271) py = 271;
            SX[i] = px;
            SY[i] = py;
            uart_putc('v'); uart_putd(i);
            uart_putc(' '); uart_putd(px);
            uart_putc(','); uart_putd(py);
            uart_crlf();
        }

        gpu_clear(RGB565(0, 0, 8));
        for (i = 0; i < N_TRIS; i++) {
            int t = i;
            int a = tri_a[t];
            int b = tri_b[t];
            int c = tri_c[t];
            int cross = (SX[b]-SX[a])*(SY[c]-SY[a])
                      - (SY[b]-SY[a])*(SX[c]-SX[a]);
            if (cross <= 0) continue;
            gpu_tri(SX[a], SY[a], SX[b], SY[b], SX[c], SY[c],
                    face_col[t >> 1]);
        }
        gpu_swap();
    }
    uart_wait_key();

    /* ── P6: rotating cube ───────────────────────────────────────────── */
    uart_putc('P'); uart_putc('6'); uart_crlf();
    ax = 0;
    ay = 0;
    gpu_clear(RGB565(0, 0, 8));
    gpu_swap();

    for (;;) {
        int cay = sin_tab[(ay + 64) & 255];
        int say = sin_tab[ay & 255];
        int cax = sin_tab[(ax + 64) & 255];
        int sax = sin_tab[ax & 255];

        gpu_clear(RGB565(0, 0, 8));

        for (i = 0; i < N_VERTS; i++) {
            int x = vx_c[i];
            int y = vy_c[i];
            int z = vz_c[i];
            int nx = (x * cay - z * say) >> 8;
            int nz = (x * say + z * cay) >> 8;
            int ny = (y * cax - nz * sax) >> 8;
            int nz2 = (y * sax + nz * cax) >> 8;
            int fz = nz2 + CUBE_Z;
            RZ[i] = fz;
            if (fz <= 0) fz = 1;
            int scale = FOCAL * 256 / fz;
            int px = ((nx * scale) >> 8) + SCR_CX;
            int py = ((ny * scale) >> 8) + SCR_CY;
            if (px < 0)   px = 0;
            if (px > 479) px = 479;
            if (py < 0)   py = 0;
            if (py > 271) py = 271;
            SX[i] = px;
            SY[i] = py;
        }

        for (i = 0; i < N_TRIS; i++) {
            TAVG[i] = RZ[tri_a[i]] + RZ[tri_b[i]] + RZ[tri_c[i]];
            TIDX[i] = i;
        }
        for (i = 1; i < N_TRIS; i++) {
            int idx = TIDX[i];
            int z   = TAVG[idx];
            j = i - 1;
            while (j >= 0 && TAVG[TIDX[j]] < z) {
                TIDX[j+1] = TIDX[j];
                j--;
            }
            TIDX[j+1] = idx;
        }

        for (i = 0; i < N_TRIS; i++) {
            int t = TIDX[i];
            int a = tri_a[t];
            int b = tri_b[t];
            int c = tri_c[t];
            int cross = (SX[b]-SX[a])*(SY[c]-SY[a])
                      - (SY[b]-SY[a])*(SX[c]-SX[a]);
            if (cross <= 0) continue;
            gpu_tri(SX[a], SY[a], SX[b], SY[b], SX[c], SY[c],
                    face_col[t >> 1]);
        }

        gpu_swap();
        ax = (ax + 1) & 255;
        ay = (ay + 2) & 255;
    }

    return 0;
}
