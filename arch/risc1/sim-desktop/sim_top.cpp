/*
 * sim_top.cpp — Verilator + SDL2 desktop simulation for RISC1 character-LCD SoC
 *
 * Build :  cd project/risc1-video/sim-desktop && make
 * Run   :  ./obj_dir/Vsoc
 *
 * Keys
 *   ESC         — quit
 *   W/A/S/D     — snake direction (sent via UART)
 *   Enter       — 0x0D  (restart after game over)
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
static const int WIN_SCALE = 2;

/* ── Simulation reset pulse length (clock cycles) ── */
static const int RESET_CYCLES = 32;

/* ── UART bit time — must match UART_BIT_TIME when SIMULATION is defined ── */
static const int UART_BIT_TIME = 3;

/* ══════════════════════════════════════════════════════════════════════════
 * RGB565 → ARGB8888 conversion
 * ══════════════════════════════════════════════════════════════════════════ */
static uint32_t rgb565_to_argb8888(uint16_t px)
{
    uint32_t r = (px >> 11) & 0x1Fu;
    uint32_t g = (px >>  5) & 0x3Fu;
    uint32_t b = (px      ) & 0x1Fu;
    r = (r << 3) | (r >> 2);
    g = (g << 2) | (g >> 4);
    b = (b << 3) | (b >> 2);
    return (0xFFu << 24) | (r << 16) | (g << 8) | b;
}

/* ══════════════════════════════════════════════════════════════════════════
 * Software UART transmitter — drives top->rx from keyboard queue
 * ══════════════════════════════════════════════════════════════════════════ */
static std::queue<uint8_t> uart_queue;

static void uart_drive(Vsoc* top)
{
    static int     state     = 0;
    static int     clk_count = 0;
    static uint8_t tx_byte   = 0;

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

    if (++clk_count < UART_BIT_TIME + 1)
        return;
    clk_count = 0;

    if (state == 1)
    {
        top->rx = 0;
        state   = 2;
    }
    else if (state >= 2 && state <= 9)
    {
        top->rx = (tx_byte >> (state - 2)) & 1u;
        state++;
    }
    else
    {
        top->rx = 1;
        state   = 0;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * SDL2 Audio — mirrors the Verilog audio.v waveform generation
 * ══════════════════════════════════════════════════════════════════════════ */
static const int AUDIO_SAMPLE_RATE = 48000;

struct AudioVoice {
    uint16_t freq;
    uint8_t  volume;
    uint8_t  waveform;
    uint16_t phase;
    uint16_t lfsr;
};

static struct {
    AudioVoice voice[3];
    uint8_t    master_vol;
} audio_state;

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
        case 0: idx = ph & 0x3F;    break;
        case 1: idx = (~ph) & 0x3F; break;
        case 2: idx = ph & 0x3F;    break;
        case 3: idx = (~ph) & 0x3F; break;
        default: idx = 0; break;
    }
    int8_t mag = sine_lut[idx];
    return (ph & 0x80) ? (int8_t)(-mag) : mag;
}

static int8_t gen_wave(uint8_t wave_sel, uint16_t ph, uint16_t noise)
{
    switch (wave_sel) {
        case 0: return (ph & 0x8000) ? (int8_t)(~(uint8_t)(ph >> 7)) : (int8_t)(ph >> 7);
        case 1: return (int8_t)((ph >> 8) - 0x80);
        case 2: return (ph & 0x8000) ? -128 : 127;
        case 3: return (int8_t)((noise >> 8) - 0x80);
        case 4: return sine_wave((uint8_t)(ph >> 8));
        default: return 0;
    }
}

static void audio_callback(void* /*userdata*/, Uint8* stream, int len)
{
    int16_t* out = (int16_t*)stream;
    int samples = len / (int)sizeof(int16_t);
    for (int s = 0; s < samples; s++) {
        int32_t mix = 0;
        for (int v = 0; v < 3; v++) {
            AudioVoice& av = audio_state.voice[v];
            av.phase += av.freq;
            uint16_t fb = ((av.lfsr >> 15) ^ (av.lfsr >> 14) ^ (av.lfsr >> 12) ^ (av.lfsr >> 3)) & 1;
            av.lfsr = (uint16_t)((av.lfsr << 1) | fb);
            mix += (int32_t)gen_wave(av.waveform, av.phase, av.lfsr) * (int32_t)av.volume;
        }
        int32_t final_val = (mix * (int32_t)audio_state.master_vol) >> 10;
        if (final_val > 32767) final_val = 32767;
        if (final_val < -32768) final_val = -32768;
        out[s] = (int16_t)final_val;
    }
}

static void audio_sync_from_verilog(Vsoc* top)
{
    auto* r = top->rootp;
    for (int i = 0; i < 3; i++) {
        audio_state.voice[i].freq     = r->soc__DOT__audio0__DOT__freq[i];
        audio_state.voice[i].volume   = r->soc__DOT__audio0__DOT__volume[i];
        audio_state.voice[i].waveform = r->soc__DOT__audio0__DOT__waveform[i];
    }
    audio_state.master_vol = r->soc__DOT__audio0__DOT__master_vol;
}

/* ══════════════════════════════════════════════════════════════════════════
 * main()
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char** argv)
{
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    /* ── SDL2 init ── */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) < 0)
    {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_StartTextInput();

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
        SDL_PauseAudioDevice(audio_dev, 0);

    /* ── Framebuffer ── */
    static uint32_t fb[LCD_W * LCD_H];
    memset(fb, 0, sizeof(fb));

    /* ── Simulation state ── */
    int  pixel_idx  = 0;
    bool prev_de    = false;
    bool prev_vsync = true;
    bool running    = true;
    int  rst_count  = 0;

    /* ── Assert reset ── */
    top->rst = 0;
    top->rx  = 1;
    top->clk = 0;
    top->eval();

    fprintf(stderr,
        SIM_TITLE " — started.\n"
        "LCD: %d x %d  window: %d x %d\n"
        "Controls: WASD = move, any key after game over = restart, ESC = quit\n",
        LCD_W, LCD_H, LCD_W * WIN_SCALE, LCD_H * WIN_SCALE);

    /* ═══════════════════════════════════════════════
     * Main simulation loop
     * ═══════════════════════════════════════════════ */
    while (running && !ctx->gotFinish())
    {
        /* ── Rising edge ── */
        top->clk = 1;
        top->eval();

        /* Release reset */
        if (rst_count < RESET_CYCLES)
        {
            if (++rst_count == RESET_CYCLES)
                top->rst = 1;
        }

        uart_drive(top);

        /* ── LCD pixel capture ── */
        if (prev_de && pixel_idx < LCD_W * LCD_H)
        {
            fb[pixel_idx] = rgb565_to_argb8888((uint16_t)top->lcd_data);
            pixel_idx++;
        }
        prev_de = (bool)top->lcd_de;

        /* ── Frame boundary: vsync falling edge ── */
        bool cur_vsync = (bool)top->lcd_vsync;
        if (prev_vsync && !cur_vsync)
        {
            /* Sync audio register state from Verilog model */
            audio_sync_from_verilog(top);

            SDL_UpdateTexture(texture, NULL, fb, LCD_W * (int)sizeof(uint32_t));
            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);
            pixel_idx = 0;

            /* Handle SDL events once per frame */
            SDL_Event ev;
            while (SDL_PollEvent(&ev))
            {
                if (ev.type == SDL_QUIT)
                    running = false;

                if (ev.type == SDL_TEXTINPUT)
                {
                    uint8_t ch = (uint8_t)ev.text.text[0];
                    if (ch >= 32 && ch <= 126)
                        uart_queue.push(ch);
                }
                else if (ev.type == SDL_KEYDOWN)
                {
                    SDL_Keycode sym = ev.key.keysym.sym;

                    if (sym == SDLK_ESCAPE)
                        running = false;
                    else if (sym == SDLK_RETURN || sym == SDLK_KP_ENTER)
                        uart_queue.push(0x0Du);
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
