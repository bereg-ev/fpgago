/*
 * sim_top.cpp — Verilator + SDL2 desktop simulation
 *
 * Compiles the real Verilog SoC (via Verilator) and renders the LCD pixel
 * output in an SDL2 window.  Keyboard input is forwarded to the CPU through
 * the UART serial interface.
 *
 * Build :  cd project/risc2-video/sim-desktop && make
 * Run   :  ./obj_dir/Vsoc
 *
 * Keys
 *   ESC         — quit
 *   Printable   — sent to CPU as ASCII bytes via UART
 *   Enter       — 0x0D
 *   Backspace   — 0x08
 *
 * With CPU_DEBUGGER enabled (default in project.vh):
 *   S — single step one CPU instruction
 *   C — continue (run freely)
 *   P — print CPU register dump via UART TX → stdout
 *   R — reset CPU
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <queue>

#include "verilated.h"
#include "Vsoc.h"
#include "Vsoc___024root.h"

/* Verilator ≥5 requires this symbol even with --no-timing */
double sc_time_stamp() { return 0; }

#include <SDL.h>

/* ── LCD frame dimensions — must match SIMULATION_SDL values in lcd_out.v ── */
static const int LCD_W     = 480;
static const int LCD_H     = 272;
static const int WIN_SCALE = 2;     /* display window = 960 × 544           */

/* ── Simulation reset pulse length (clock cycles) ── */
static const int RESET_CYCLES = 32;

/* ── UART bit time — must match UART_BIT_TIME when SIMULATION is defined ── */
/*    project.vh: `define UART_BIT_TIME 3 (under `ifdef SIMULATION)          */
static const int UART_BIT_TIME = 3;

/* ══════════════════════════════════════════════════════════════════════════
 * 1.  RGB565 → ARGB8888 conversion
 * ══════════════════════════════════════════════════════════════════════════ */
static uint32_t rgb565_to_argb8888(uint16_t px)
{
    /* Extract 5-6-5 channels */
    uint32_t r = (px >> 11) & 0x1Fu;
    uint32_t g = (px >>  5) & 0x3Fu;
    uint32_t b = (px      ) & 0x1Fu;
    /* Expand to 8 bits by replicating MSBs into the vacated LSBs */
    r = (r << 3) | (r >> 2);
    g = (g << 2) | (g >> 4);
    b = (b << 3) | (b >> 2);
    return (0xFFu << 24) | (r << 16) | (g << 8) | b;
}

/* ══════════════════════════════════════════════════════════════════════════
 * 2.  Software UART transmitter
 *
 * Drives top->rx from a byte queue, one bit per UART_BIT_TIME clock cycles.
 * Call once per simulated rising-clock edge.
 * Format: 1 start bit (0), 8 data bits LSB-first, 1 stop bit (1).
 * ══════════════════════════════════════════════════════════════════════════ */
static std::queue<uint8_t> uart_queue;

static void uart_drive(Vsoc* top)
{
    static int     state     = 0;       /* 0=idle, 1=start, 2-9=data, 10=stop */
    static int     clk_count = 0;
    static uint8_t tx_byte   = 0;

    /* Idle: keep line high; dequeue next byte when one arrives */
    if (state == 0)
    {
        top->rx = 1;
        if (!uart_queue.empty())
        {
            tx_byte   = uart_queue.front();
            uart_queue.pop();
            state     = 1;
            clk_count = 0;
        }
        return;
    }

    /* Hold each bit for UART_BIT_TIME+1 clock cycles (uart.v actual period) */
    if (++clk_count < UART_BIT_TIME + 1)
        return;
    clk_count = 0;

    if (state == 1)
    {
        top->rx = 0;    /* start bit */
        state   = 2;
    }
    else if (state >= 2 && state <= 9)
    {
        top->rx = (tx_byte >> (state - 2)) & 1u;   /* data bit, LSB-first */
        state++;
    }
    else    /* state == 10 */
    {
        top->rx = 1;    /* stop bit */
        state   = 0;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * 3.  Print UART TX byte to stdout
 *     Call after every rising-edge eval to forward CPU output to the terminal.
 * ══════════════════════════════════════════════════════════════════════════ */
static void uart_print(Vsoc* top)
{
    /* Deserialise the TX bit stream and print completed bytes to stdout.
     * Mirrors uart_drive() in reverse: detect start bit, sample 8 data bits
     * LSB-first at UART_BIT_TIME cycles per bit, then emit on stop bit. */
    static int     state     = 0;   /* 0=idle, 1=start, 2-9=data bits, 10=stop */
    static int     clk_count = 0;
    static uint8_t rx_byte   = 0;
    static uint8_t prev_tx   = 1;

    uint8_t cur_tx = (uint8_t)top->tx;

    if (state == 0)
    {
        /* Falling edge on tx = start bit */
        if (prev_tx == 1 && cur_tx == 0)
        {
            state     = 1;
            clk_count = 0;
            rx_byte   = 0;
        }
    }
    else
    {
        /* uart.v actual bit period = UART_BIT_TIME + 1 cycles (see uart.v line 4) */
        if (++clk_count >= UART_BIT_TIME + 1)
        {
            clk_count = 0;
            if (state <= 8)
            {
                /* Sample data bit, LSB-first */
                if (cur_tx)
                    rx_byte |= (1u << (state - 1));
                state++;
            }
            else
            {
                /* Stop bit: byte is complete */
                fputc(rx_byte, stdout);
                fflush(stdout);
                state = 0;
            }
        }
    }

    prev_tx = cur_tx;
}

/* ══════════════════════════════════════════════════════════════════════════
 * 4.  SDL2 Audio — mirrors the Verilog audio.v waveform generation
 *
 * Reads the same register values that the CPU writes to the Verilog model,
 * so simulation sound matches real hardware I2S output exactly.
 * ══════════════════════════════════════════════════════════════════════════ */
static const int AUDIO_SAMPLE_RATE = 48000;

/* Shared state: written by main loop, read by audio callback */
struct AudioVoice {
    uint16_t freq;          /* phase increment per sample */
    uint8_t  volume;        /* 0..255 */
    uint8_t  waveform;      /* 0=tri, 1=saw, 2=square, 3=noise, 4=sine */
    uint16_t phase;         /* running phase accumulator */
    uint16_t lfsr;          /* noise LFSR */
};

static struct {
    AudioVoice voice[3];
    uint8_t    master_vol;  /* 0..255, default 255 */
} audio_state;

/* Quarter-wave sine LUT (same values as audio.v) */
static const int8_t sine_lut[64] = {
     0,  3,  6,  9, 12, 16, 19, 22, 25, 28, 31, 34, 37, 40, 43, 46,
    49, 51, 54, 57, 59, 62, 64, 66, 69, 71, 73, 75, 77, 79, 81, 83,
    85, 86, 88, 89, 91, 92, 94, 95, 96, 97, 98, 99,100,101,102,103,
   104,104,105,105,106,106,107,107,107,107,108,108,108,108,108,108
};

static int8_t sine_wave(uint8_t ph)
{
    uint8_t idx;
    switch (ph >> 6) {
        case 0: idx = ph & 0x3F;        break;
        case 1: idx = (~ph) & 0x3F;     break;
        case 2: idx = ph & 0x3F;        break;
        case 3: idx = (~ph) & 0x3F;     break;
        default: idx = 0; break;
    }
    int8_t mag = sine_lut[idx];
    return (ph & 0x80) ? (int8_t)(-mag) : mag;
}

static int8_t gen_wave(uint8_t wave_sel, uint16_t ph, uint16_t noise)
{
    switch (wave_sel) {
        case 0: /* triangle */
            if (ph & 0x8000)
                return (int8_t)(~(uint8_t)(ph >> 7));
            else
                return (int8_t)(ph >> 7);
        case 1: /* sawtooth */
            return (int8_t)((ph >> 8) - 0x80);
        case 2: /* square */
            return (ph & 0x8000) ? -128 : 127;
        case 3: /* noise */
            return (int8_t)((noise >> 8) - 0x80);
        case 4: /* sine */
            return sine_wave((uint8_t)(ph >> 8));
        default:
            return 0;
    }
}

/* Triangle wave matching hardware triwave() function */
static int8_t hw_triwave(uint16_t ph)
{
    if (ph & 0x8000)
        return (int8_t)(~(uint8_t)(ph >> 7));
    else
        return (int8_t)(ph >> 7);
}

/* SDL2 runs at 48 kHz — use freq_reg = Hz * 65536 / 48000 */
static const uint16_t scale_freqs[8] = {358,401,450,476,535,601,674,713};
static const uint16_t chord_freqs[3] = {358,450,535}; /* C4, E4, G4 */

/* Test mode state (matches hardware test block) */
static struct {
    uint16_t tp0, tp1, tp2;
    uint8_t  chord_sel;
    uint32_t scale_timer;
    uint8_t  scale_note;
} test_state;

static void audio_callback(void* /*userdata*/, Uint8* stream, int len)
{
    int16_t* out = (int16_t*)stream;
    int samples = len / (int)sizeof(int16_t);
    uint8_t mode = audio_state.master_vol;

    for (int s = 0; s < samples; s++) {
        int16_t val = 0;

        if (mode == 0x42) {
            /* b: single 440 Hz triangle */
            test_state.tp0 += 601;  /* 440 Hz at 48 kHz */
            val = (int16_t)hw_triwave(test_state.tp0) << 4; /* /16 to match hw volume */
        }
        else if (mode == 0x43) {
            /* c: C major chord, round-robin */
            test_state.tp0 += chord_freqs[0];
            test_state.tp1 += chord_freqs[1];
            test_state.tp2 += chord_freqs[2];
            int8_t tw;
            switch (test_state.chord_sel) {
                case 0: tw = hw_triwave(test_state.tp0); break;
                case 1: tw = hw_triwave(test_state.tp1); break;
                default: tw = hw_triwave(test_state.tp2); break;
            }
            test_state.chord_sel++;
            if (test_state.chord_sel >= 3) test_state.chord_sel = 0;
            val = (int16_t)tw << 4;
        }
        else if (mode == 0x4D) {
            /* m: C major scale */
            test_state.tp0 += scale_freqs[test_state.scale_note];
            test_state.scale_timer++;
            if (test_state.scale_timer >= 19200) { /* 0.4s at 48 kHz */
                test_state.scale_timer = 0;
                test_state.scale_note = (test_state.scale_note >= 7) ? 0 : test_state.scale_note + 1;
            }
            val = (int16_t)hw_triwave(test_state.tp0) << 4;
        }
        else {
            /* Normal pipeline mode */
            int32_t mix = 0;
            for (int v = 0; v < 3; v++) {
                AudioVoice& av = audio_state.voice[v];
                av.phase += av.freq;
                uint16_t fb = ((av.lfsr >> 15) ^ (av.lfsr >> 14) ^ (av.lfsr >> 12) ^ (av.lfsr >> 3)) & 1;
                av.lfsr = (uint16_t)((av.lfsr << 1) | fb);
                int8_t sample = gen_wave(av.waveform, av.phase, av.lfsr);
                mix += (int32_t)sample * (int32_t)av.volume;
            }
            int32_t final_val = (mix * (int32_t)audio_state.master_vol) >> 10;
            if (final_val > 32767) final_val = 32767;
            if (final_val < -32768) final_val = -32768;
            val = (int16_t)final_val;
        }

        out[s] = val;
    }
}

/* Read audio register state from the Verilator model's audio0 instance.
 * Uses the VL_PUBLIC accessors generated by Verilator. The audio module's
 * registers are arrays, so we access them via the rootp pointer. */
static void audio_sync_from_verilog(Vsoc* top)
{
    auto* r = top->rootp;
    audio_state.master_vol = r->soc__DOT__audio0__DOT__master_vol;
    for (int i = 0; i < 3; i++) {
        audio_state.voice[i].freq     = r->soc__DOT__audio0__DOT__freq[i];
        audio_state.voice[i].waveform = r->soc__DOT__audio0__DOT__waveform[i];
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * 5.  main()
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char** argv)
{
    /* ── Verilator context ── */
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    /* ── SDL2 init ── */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) < 0)
    {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_StartTextInput();   /* enable SDL_TEXTINPUT events so shift is respected */

#ifndef SIM_TITLE
#define SIM_TITLE "FPGAgo Simulation"
#endif

    SDL_Window* window = SDL_CreateWindow(
        SIM_TITLE,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        LCD_W * WIN_SCALE, LCD_H * WIN_SCALE,
        0);
    if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }

    SDL_Renderer* renderer = SDL_CreateRenderer(
        window, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }

    /* Nearest-neighbour upscale so pixels look crisp at 2× */
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    SDL_RenderSetLogicalSize(renderer, LCD_W, LCD_H);

    SDL_Texture* texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        LCD_W, LCD_H);
    if (!texture) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return 1; }

    /* ── SDL2 Audio init ── */
    memset(&audio_state, 0, sizeof(audio_state));
    audio_state.master_vol = 255;
    audio_state.voice[0].lfsr = 0xACE1;
    audio_state.voice[1].lfsr = 0x1234;
    audio_state.voice[2].lfsr = 0x5678;


    SDL_AudioSpec want, have;
    SDL_zero(want);
    want.freq     = AUDIO_SAMPLE_RATE;
    want.format   = AUDIO_S16SYS;
    want.channels = 1;
    want.samples  = 512;
    want.callback = audio_callback;

    SDL_AudioDeviceID audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (audio_dev == 0)
        fprintf(stderr, "SDL_OpenAudioDevice: %s (audio disabled)\n", SDL_GetError());
    else
        SDL_PauseAudioDevice(audio_dev, 0);     /* start playback */

    /* ── Framebuffer: one ARGB word per pixel ── */
    static uint32_t fb[LCD_W * LCD_H];
    memset(fb, 0, sizeof(fb));

    /* ── Simulation state ── */
    int  pixel_idx  = 0;       /* sequential pixel index within the current frame  */
    bool prev_de    = false;   /* lcd_de one cycle ago (lcd_data is 1-cycle latched) */
    bool prev_vsync = true;    /* previous vsync value for falling-edge detection   */
    bool running    = true;
    int  rst_count  = 0;

    /* ── Assert reset ── */
    top->rst = 0;
    top->rx  = 1;   /* UART idle line high */
    top->clk = 0;
    top->eval();

    fprintf(stderr,
        "Desktop simulation started.\n"
        "LCD: %d x %d  window: %d x %d\n"
        "UART keys: S=step  C=continue  P=print-regs  R=reset-CPU\n",
        LCD_W, LCD_H, LCD_W * WIN_SCALE, LCD_H * WIN_SCALE);

    /* ═══════════════════════════════════════════════
     * Main simulation loop — one iteration = one full clock cycle
     * ═══════════════════════════════════════════════ */
    while (running && !ctx->gotFinish())
    {
        /* ── Rising edge ── */
        top->clk = 1;
        top->eval();

        /* Release reset after RESET_CYCLES rising edges */
        if (rst_count < RESET_CYCLES)
        {
            if (++rst_count == RESET_CYCLES)
                top->rst = 1;
        }

        /* Drive UART RX from keyboard-input queue */
        uart_drive(top);

        /* Forward CPU UART TX to stdout (placeholder) */
        uart_print(top);


        /* ─────────────────────────────────────────────────────────────────
         * LCD pixel capture
         *
         * lcd_data (soc.v) is a registered output:
         *   always @(posedge clk) if (lcd_de) lcd_data <= char_pixel_out;
         *
         * After eval() at clock N:
         *   - lcd_de  = current (combinatorial)  — valid for position N
         *   - lcd_data = value latched AT clock N = char_pixel_out from N-1
         *
         * So: read lcd_data when prev_de was 1 (it then holds the pixel
         * that was visible in the previous clock — position N-1).
         * This gives correct sequential pixel ordering with no visual shift.
         * ───────────────────────────────────────────────────────────────── */
        if (prev_de && pixel_idx < LCD_W * LCD_H)
        {
            fb[pixel_idx] = rgb565_to_argb8888((uint16_t)top->lcd_data);
            pixel_idx++;
        }
        prev_de = (bool)top->lcd_de;

        /* ─────────────────────────────────────────────────────────────────
         * Frame boundary: vsync falling edge
         *
         * With SIMULATION_SDL timing (v1=v2=0, v4=290):
         *   vsync goes LOW for exactly one clock cycle at row=290 (h4),
         *   then immediately HIGH again at row=0 of the next frame.
         * ───────────────────────────────────────────────────────────────── */
        bool cur_vsync = (bool)top->lcd_vsync;
        if (prev_vsync && !cur_vsync)
        {
            /* Sync audio register state from Verilog model to SDL2 callback */
            audio_sync_from_verilog(top);

            /* Upload completed frame to GPU texture and display */
            SDL_UpdateTexture(texture, NULL, fb, LCD_W * (int)sizeof(uint32_t));
            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);    /* blocks until monitor vsync if PRESENTVSYNC */
            pixel_idx = 0;

            /* Handle SDL events once per simulated frame */
            SDL_Event ev;
            while (SDL_PollEvent(&ev))
            {
                if (ev.type == SDL_QUIT)
                    running = false;

                if (ev.type == SDL_TEXTINPUT)
                {
                    /* SDL_TEXTINPUT gives the actual character including shift,
                     * so 'S' is 0x53 not 0x73 — debugger commands work correctly */
                    uint8_t ch = (uint8_t)ev.text.text[0];
                    if (ch >= 32 && ch <= 126)
                        uart_queue.push(ch);
                }
                else if (ev.type == SDL_KEYDOWN)
                {
                    SDL_Keycode sym = ev.key.keysym.sym;

                    if (sym == SDLK_ESCAPE)
                    {
                        running = false;
                    }
                    else if (sym == SDLK_RETURN || sym == SDLK_KP_ENTER)
                    {
                        uart_queue.push(0x0Du);
                    }
                    else if (sym == SDLK_BACKSPACE)
                    {
                        uart_queue.push(0x08u);
                    }
                    else if (sym == SDLK_UP)    uart_queue.push('w');
                    else if (sym == SDLK_DOWN)  uart_queue.push('s');
                    else if (sym == SDLK_LEFT)  uart_queue.push('a');
                    else if (sym == SDLK_RIGHT) uart_queue.push('d');
                }
            }
        }
        prev_vsync = cur_vsync;

        /* ── Falling edge ── */
        top->clk = 0;
        top->eval();
    }

    /* ── Cleanup ── */
    top->final();
    delete top;
    delete ctx;

    if (audio_dev) SDL_CloseAudioDevice(audio_dev);
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
