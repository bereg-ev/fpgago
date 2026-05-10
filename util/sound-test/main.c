/*
 * sound-test — UART console audio test utility for the 3-channel synthesizer
 *
 * Commands (single-key, no Enter needed):
 *
 *   1 / 2 / 3      Select voice (1, 2, or 3)
 *   t               Set waveform: triangle
 *   y               Set waveform: sawtooth
 *   s               Set waveform: square
 *   n               Set waveform: noise
 *   i               Set waveform: sine
 *   + / =           Frequency up   (×1.06, ~one semitone)
 *   - / _           Frequency down (÷1.06)
 *   ] / }           Volume up   (+16)
 *   [ / {           Volume down (-16)
 *   > / .           Master volume up   (+16)
 *   < / ,           Master volume down (-16)
 *   p               Play: set current voice volume to 255
 *   x               Stop: set current voice volume to 0
 *   q               Quiet: stop all voices
 *   c               Play C major chord (C4+E4+G4 on voices 1-3)
 *   m               Play C major scale ascending
 *   w               Sweep: frequency sweep from 100 Hz to 4000 Hz
 *   h / ?           Print help
 *
 * Frequency register:  freq_reg = Hz * 65536 / 48000
 * Default at start:    voice 1 = 440 Hz sine, vol 0 (silent)
 */

/* ── UART registers ─────────────────────────────────────────────────────── */
#define IO_STATUS    (*(volatile unsigned int*)0xF0002)
#define IO_UART_TX   (*(volatile unsigned int*)0xF0003)
#define IO_UART_RX   (*(volatile unsigned int*)0xF0004)
#define UART_RXRDY   (1 << 0)
#define UART_TXBUSY  (1 << 2)

/* ── Audio registers (MMIO base 0x0B0000) ────────────────────────────── */
#define AUD(reg)     (*(volatile unsigned int*)(0x0B0000 + (reg)))

#define AUD_FREQ_LO(v)   AUD((v)*4 + 0)
#define AUD_FREQ_HI(v)   AUD((v)*4 + 1)
#define AUD_VOLUME(v)    AUD((v)*4 + 2)
#define AUD_WAVEFORM(v)  AUD((v)*4 + 3)
#define AUD_MASTER       AUD(0x0C)

/* Waveform IDs */
#define WAVE_TRI   0
#define WAVE_SAW   1
#define WAVE_SQ    2
#define WAVE_NOISE 3
#define WAVE_SINE  4

/* ── Soft state (mirrors what we wrote to hardware) ──────────────────── */
static unsigned int  freq_reg[3];       /* 16-bit phase increment */
static unsigned int  volume[3];         /* 0..255 */
static unsigned int  waveform[3];       /* 0..4 */
static unsigned int  master_vol;
static int           cur_voice;         /* 0..2 */

/* ── UART helpers ────────────────────────────────────────────────────── */
static void uart_putc(int ch)
{
    while (IO_STATUS & UART_TXBUSY) { /* spin */ }
    IO_UART_TX = (unsigned int)(ch & 0xFF);
}

static int uart_getc(void)
{
    while (!(IO_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(IO_UART_RX & 0xFF);
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex8(unsigned int v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[(v >> 4) & 0xF]);
    uart_putc(hex[v & 0xF]);
}

static void uart_puthex16(unsigned int v)
{
    uart_puthex8(v >> 8);
    uart_puthex8(v);
}

static void uart_putdec(unsigned int v)
{
    /* Print unsigned int in decimal. Max 5 digits for freq values. */
    char buf[6];
    int i = 0;
    if (v == 0) {
        uart_putc('0');
        return;
    }
    while (v > 0) {
        buf[i++] = (char)('0' + (v % 10));
        v = v / 10;
    }
    while (i > 0)
        uart_putc(buf[--i]);
}

/* ── Frequency conversion ────────────────────────────────────────────── */
/* freq_reg = Hz * 65536 / sample_rate
 *
 * Hardware sample rate = MCLK / 384 ≈ 50456 Hz (at 19.375 MHz OSCG).
 * SDL2 sim sample rate = 48000 Hz.
 *
 * Shift-add approximations (avoid runtime mul/div):
 * 65536/50456 ≈ 1.29888 ≈ 1 + 1/4 + 1/16 - 1/64 + 1/512  (hw, 0.004%)
 * 65536/48000 ≈ 1.36533 ≈ 1 + 1/4 + 1/8 + 1/128 + 1/256   (sim, 0.16%)
 */
#ifdef SIMULATION
static unsigned int hz_to_reg(unsigned int hz)
{
    return hz + (hz >> 2) + (hz >> 3) + (hz >> 7) + (hz >> 8);
}
#else
static unsigned int hz_to_reg(unsigned int hz)
{
    return hz + (hz >> 2) + (hz >> 4) - (hz >> 6) + (hz >> 9);
}
#endif

/* Hz ≈ freq_reg * sample_rate / 65536
 * hw:  50456/65536 ≈ 0.76990 ≈ 1/2 + 1/4 + 1/64 + 1/256  (0.05%)
 * sim: 48000/65536 ≈ 0.73242 ≈ 1/2 + 1/4 - 1/64 + 1/128   (0.14%)
 */
#ifdef SIMULATION
static unsigned int reg_to_hz(unsigned int reg)
{
    if (reg == 0) return 0;
    return (reg >> 1) + (reg >> 2) - (reg >> 6) + (reg >> 7);
}
#else
static unsigned int reg_to_hz(unsigned int reg)
{
    if (reg == 0) return 0;
    return (reg >> 1) + (reg >> 2) + (reg >> 6) + (reg >> 8);
}
#endif

/* ── Hardware write helpers ──────────────────────────────────────────── */
static void set_freq(int v, unsigned int reg)
{
    freq_reg[v] = reg & 0xFFFF;
    AUD_FREQ_LO(v) = reg & 0xFF;
    AUD_FREQ_HI(v) = (reg >> 8) & 0xFF;
}

static void set_volume(int v, unsigned int vol)
{
    if (vol > 255) vol = 255;
    volume[v] = vol;
    AUD_VOLUME(v) = vol;
}

static void set_waveform(int v, unsigned int w)
{
    waveform[v] = w;
    AUD_WAVEFORM(v) = w;
}

static void set_master(unsigned int vol)
{
    if (vol > 255) vol = 255;
    master_vol = vol;
    AUD_MASTER = vol;
}

/* ── Names ───────────────────────────────────────────────────────────── */
static const char *wave_name(unsigned int w)
{
    switch (w) {
        case WAVE_TRI:   return "triangle";
        case WAVE_SAW:   return "sawtooth";
        case WAVE_SQ:    return "square";
        case WAVE_NOISE: return "noise";
        case WAVE_SINE:  return "sine";
        default:         return "???";
    }
}

/* ── Status print ────────────────────────────────────────────────────── */
static void print_voice(int v)
{
    uart_puts("  voice ");
    uart_putc('1' + v);
    uart_puts(": ");
    uart_puts(wave_name(waveform[v]));
    uart_puts("  freq=");
    uart_putdec(reg_to_hz(freq_reg[v]));
    uart_puts(" Hz (0x");
    uart_puthex16(freq_reg[v]);
    uart_puts(")  vol=");
    uart_putdec(volume[v]);
    if (v == cur_voice)
        uart_puts("  <--");
    uart_puts("\r\n");
}

static void print_status(void)
{
    int v;
    uart_puts("\r\n--- Audio status ---\r\n");
    for (v = 0; v < 3; v++)
        print_voice(v);
    uart_puts("  master vol=");
    uart_putdec(master_vol);
    uart_puts("\r\n");
}

static void print_help(void)
{
    uart_puts("\r\n");
    uart_puts("=== Sound Test ===\r\n");
    uart_puts("1/2/3     select voice\r\n");
    uart_puts("t/y/s/n/i waveform: tri/saw/square/noise/sine\r\n");
    uart_puts("+/-       frequency up/down (semitone)\r\n");
    uart_puts("]/[       volume up/down\r\n");
    uart_puts(">/< (./ ,) master volume up/down\r\n");
    uart_puts("p         play (vol=255)\r\n");
    uart_puts("x         stop voice\r\n");
    uart_puts("q         stop all (quiet)\r\n");
    uart_puts("c         C major chord\r\n");
    uart_puts("m         C major scale\r\n");
    uart_puts("w         frequency sweep\r\n");
    uart_puts("h/?       help\r\n");
}

/* ── Simple delay (busy-wait) ────────────────────────────────────────── */
static void delay(unsigned int n)
{
    volatile unsigned int i;
    for (i = 0; i < n; i++) { }
}

/* ── Musical tests ───────────────────────────────────────────────────── */

/* Note frequencies in Hz (octave 4) */
#define NOTE_C4  262
#define NOTE_D4  294
#define NOTE_E4  330
#define NOTE_F4  349
#define NOTE_G4  392
#define NOTE_A4  440
#define NOTE_B4  494
#define NOTE_C5  523

static void play_chord(void)
{
    /* C major chord: C4 + E4 + G4 on voices 0-2 */
    uart_puts("Playing C major chord (C4+E4+G4)...\r\n");
    set_waveform(0, WAVE_SINE);
    set_waveform(1, WAVE_SINE);
    set_waveform(2, WAVE_SINE);
    set_freq(0, hz_to_reg(NOTE_C4));
    set_freq(1, hz_to_reg(NOTE_E4));
    set_freq(2, hz_to_reg(NOTE_G4));
    set_volume(0, 200);
    set_volume(1, 200);
    set_volume(2, 200);
    print_status();
}

static void play_scale(void)
{
    static const unsigned int notes[] = {
        NOTE_C4, NOTE_D4, NOTE_E4, NOTE_F4,
        NOTE_G4, NOTE_A4, NOTE_B4, NOTE_C5
    };
    int n;

    uart_puts("Playing C major scale on voice ");
    uart_putc('1' + cur_voice);
    uart_puts("...\r\n");

    set_waveform(cur_voice, WAVE_SINE);
    set_volume(cur_voice, 255);

    for (n = 0; n < 8; n++) {
        set_freq(cur_voice, hz_to_reg(notes[n]));
        uart_puts("  ");
        uart_putdec(notes[n]);
        uart_puts(" Hz\r\n");
        delay(80000);
    }

    /* Leave last note playing */
    uart_puts("Scale done.\r\n");
}

static void freq_sweep(void)
{
    unsigned int hz;

    uart_puts("Frequency sweep 100-4000 Hz on voice ");
    uart_putc('1' + cur_voice);
    uart_puts("...\r\n");

    set_waveform(cur_voice, waveform[cur_voice]);
    set_volume(cur_voice, 255);

    for (hz = 100; hz <= 4000; hz += 20) {
        set_freq(cur_voice, hz_to_reg(hz));
        delay(4000);
    }

    uart_puts("Sweep done. Stopped at 4000 Hz.\r\n");
}

/* ── Main ────────────────────────────────────────────────────────────── */
int main(void)
{
    int ch;
    unsigned int f;

    /* Init state */
    cur_voice = 0;
    master_vol = 255;
    set_master(255);

    /* Default: voice 0 = 440 Hz sine, silent */
    set_freq(0, hz_to_reg(440));
    set_waveform(0, WAVE_SINE);
    set_volume(0, 0);

    set_freq(1, hz_to_reg(523));
    set_waveform(1, WAVE_TRI);
    set_volume(1, 0);

    set_freq(2, hz_to_reg(330));
    set_waveform(2, WAVE_SQ);
    set_volume(2, 0);

    print_help();
    print_status();
    uart_puts("\r\n> ");

    for (;;) {
        ch = uart_getc();

        switch (ch) {
        /* Voice select */
        case '1': cur_voice = 0; uart_puts("Voice 1\r\n"); break;
        case '2': cur_voice = 1; uart_puts("Voice 2\r\n"); break;
        case '3': cur_voice = 2; uart_puts("Voice 3\r\n"); break;

        /* Waveform select */
        case 't':
            set_waveform(cur_voice, WAVE_TRI);
            uart_puts("triangle\r\n");
            break;
        case 'y':
            set_waveform(cur_voice, WAVE_SAW);
            uart_puts("sawtooth\r\n");
            break;
        case 's':
            set_waveform(cur_voice, WAVE_SQ);
            uart_puts("square\r\n");
            break;
        case 'n':
            set_waveform(cur_voice, WAVE_NOISE);
            uart_puts("noise\r\n");
            break;
        case 'i':
            set_waveform(cur_voice, WAVE_SINE);
            uart_puts("sine\r\n");
            break;

        /* Frequency up: multiply by ~1.0595 (semitone) ≈ *17/16 */
        case '+':
        case '=':
            f = freq_reg[cur_voice];
            f = f + (f >> 4);           /* f * 17/16 */
            if (f > 0xFFFF) f = 0xFFFF;
            if (f == 0) f = 1;
            set_freq(cur_voice, f);
            uart_putdec(reg_to_hz(f));
            uart_puts(" Hz\r\n");
            break;

        /* Frequency down: divide by ~1.0595 ≈ *15/16 */
        case '-':
        case '_':
            f = freq_reg[cur_voice];
            f = f - (f >> 4);           /* f * 15/16 */
            if (f == 0) f = 1;
            set_freq(cur_voice, f);
            uart_putdec(reg_to_hz(f));
            uart_puts(" Hz\r\n");
            break;

        /* Volume up/down */
        case ']':
        case '}':
            f = volume[cur_voice] + 16;
            set_volume(cur_voice, f);
            uart_puts("vol=");
            uart_putdec(volume[cur_voice]);
            uart_puts("\r\n");
            break;
        case '[':
        case '{':
            f = volume[cur_voice];
            if (f >= 16) f -= 16; else f = 0;
            set_volume(cur_voice, f);
            uart_puts("vol=");
            uart_putdec(volume[cur_voice]);
            uart_puts("\r\n");
            break;

        /* Master volume */
        case '>':
        case '.':
            f = master_vol + 16;
            set_master(f);
            uart_puts("master=");
            uart_putdec(master_vol);
            uart_puts("\r\n");
            break;
        case '<':
        case ',':
            f = master_vol;
            if (f >= 16) f -= 16; else f = 0;
            set_master(f);
            uart_puts("master=");
            uart_putdec(master_vol);
            uart_puts("\r\n");
            break;

        /* Play / stop */
        case 'p':
            set_volume(cur_voice, 255);
            uart_puts("Playing voice ");
            uart_putc('1' + cur_voice);
            uart_puts("\r\n");
            break;
        case 'x':
            set_volume(cur_voice, 0);
            uart_puts("Stopped voice ");
            uart_putc('1' + cur_voice);
            uart_puts("\r\n");
            break;
        case 'q':
            set_volume(0, 0);
            set_volume(1, 0);
            set_volume(2, 0);
            set_master(255);
            /* Reset to defaults */
            set_freq(0, hz_to_reg(440));
            set_waveform(0, WAVE_SINE);
            set_freq(1, hz_to_reg(523));
            set_waveform(1, WAVE_TRI);
            set_freq(2, hz_to_reg(330));
            set_waveform(2, WAVE_SQ);
            cur_voice = 0;
            uart_puts("Reset + stopped\r\n");
            break;

        /* Hardware test modes: bypass pipeline, direct phase→waveform→I2S */
        case 'b':
            AUD_MASTER = 0x42;
            master_vol = 0x42;
            uart_puts("HW test: 440 Hz tone\r\n");
            break;
        case 'c':
            AUD_MASTER = 0x43;
            master_vol = 0x43;
            uart_puts("HW test: C major chord\r\n");
            break;
        case 'm':
            AUD_MASTER = 0x4D;
            master_vol = 0x4D;
            uart_puts("HW test: C major scale\r\n");
            break;
        case 'w':
            freq_sweep();
            break;

        /* Status / help */
        case 'h':
        case '?':
            print_help();
            print_status();
            break;

        case '\r':
        case '\n':
            print_status();
            break;

        default:
            break;
        }

        uart_puts("> ");
    }

    return 0;
}
