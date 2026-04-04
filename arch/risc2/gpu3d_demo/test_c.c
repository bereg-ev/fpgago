/* Test: ROM reads (const array) and RAM writes+reads */
#define UART_TX   (*(volatile unsigned int*)0x0F0003)
#define UART_STAT (*(volatile unsigned int*)0x0F0002)
static void putch(int c) { while (UART_STAT & 0x20); UART_TX = c; }

static const int testdata[4] = { 42, 99, -7, 12345 };

int main(void) {
    /* Test ROM reads */
    putch('R');
    int a = testdata[0];
    int b = testdata[1];
    int c = testdata[2];
    int d = testdata[3];
    putch(a == 42    ? 'Y' : 'N');
    putch(b == 99    ? 'Y' : 'N');
    putch(c == -7    ? 'Y' : 'N');
    putch(d == 12345 ? 'Y' : 'N');

    /* Test RAM read after write */
    putch('W');
    volatile int *ram = (volatile int *)0x010000;
    ram[0] = 42;
    int e = ram[0];
    putch(e == 42 ? 'Y' : 'N');

    /* Write all then read all */
    ram[0] = 11;
    ram[1] = 22;
    ram[2] = 33;
    int f = ram[0];
    int g = ram[1];
    int h = ram[2];
    putch(f == 11 ? 'Y' : 'N');
    putch(g == 22 ? 'Y' : 'N');
    putch(h == 33 ? 'Y' : 'N');

    putch('\n');
    for (;;);
    return 0;
}
