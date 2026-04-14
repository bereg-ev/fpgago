/*
 * sim_top.cpp — C16 Verilator + SDL2 desktop simulation
 *
 * Compiles the C16 SoC via Verilator and renders the LCD pixel output
 * in an SDL2 window. Keyboard input is forwarded via UART.
 *
 * Build:  cd arch/c16/sim-desktop && make
 * Run:    ./obj_dir/Vsoc
 *
 * Keys:
 *   ESC         — quit
 *   Printable   — sent to C16 as ASCII via UART
 *   Enter       — RETURN (0x0D)
 *   Backspace   — DEL (0x08)
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <queue>
#include <vector>

#include "verilated.h"
#include "Vsoc.h"
#include "Vsoc___024root.h"

double sc_time_stamp() { return 0; }

#include <SDL.h>

static const int LCD_W     = 480;
static const int LCD_H     = 272;
static const int WIN_SCALE = 2;

static const int RESET_CYCLES = 32;
static const int UART_BIT_TIME = 3;

/* ── RGB565 → ARGB8888 ────────────────────────────────────────────── */
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

/* ── Software UART TX → RX pin ────────────────────────────────────── */
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

/* ── UART TX → stdout ─────────────────────────────────────────────── */
static void uart_print(Vsoc* top)
{
    static int     state     = 0;
    static int     clk_count = 0;
    static uint8_t rx_byte   = 0;
    static uint8_t prev_tx   = 1;

    uint8_t cur_tx = (uint8_t)top->tx;

    if (state == 0)
    {
        if (prev_tx == 1 && cur_tx == 0)
        {
            state     = 1;
            clk_count = 0;
            rx_byte   = 0;
        }
    }
    else
    {
        if (++clk_count >= UART_BIT_TIME + 1)
        {
            clk_count = 0;
            if (state <= 8)
            {
                if (cur_tx)
                    rx_byte |= (1u << (state - 1));
                state++;
            }
            else
            {
                fputc(rx_byte, stdout);
                fflush(stdout);
                state = 0;
            }
        }
    }

    prev_tx = cur_tx;
}

/* ══════════════════════════════════════════════════════════════════════
 * 4.  Auto-typer: feed a file to UART after boot
 *
 * If AUTOTYPE_FILE is defined at compile time, the file is read into
 * memory and its bytes are injected into the UART queue after a boot
 * delay.  For .prg games, this is just "RUN\r".  For .bas programs,
 * it's the entire source plus "RUN\r".
 * ══════════════════════════════════════════════════════════════════════ */
static std::vector<uint8_t> autotype_data;
static size_t autotype_pos = 0;
static int    autotype_delay = 0;     /* frames to wait before next char  */

static void autotype_load(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "autotype: cannot open %s\n", path); return; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    autotype_data.resize((size_t)sz);
    fread(autotype_data.data(), 1, (size_t)sz, f);
    fclose(f);
    autotype_delay = 120;      /* wait 120 frames for C16 BASIC to boot */
    autotype_pos = 0;
    fprintf(stderr, "autotype: loaded %ld bytes from %s\n", sz, path);
}

/* Called once per frame.  Pushes ONE character into the UART queue,
 * then waits a few frames so the C16 KERNAL's keyboard scan can
 * detect the key press, see it released, and be ready for the next.
 * After RETURN, waits longer for the C16 to tokenize the line.      */
static void autotype_tick()
{
    if (autotype_data.empty() || autotype_pos >= autotype_data.size())
        return;

    if (autotype_delay > 0) { autotype_delay--; return; }

    uint8_t ch = autotype_data[autotype_pos++];
    uart_queue.push(ch);

    if (ch == 0x0Du)
        autotype_delay = 60;   /* wait 60 frames after RETURN (line tokenization) */
    else
        autotype_delay = 10;   /* wait 10 frames between characters              */
}

/* ── main ──────────────────────────────────────────────────────────── */
int main(int argc, char** argv)
{
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    /* Check for --autotype <file> argument */
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--autotype") == 0 && i + 1 < argc)
            autotype_load(argv[++i]);
    }

    if (SDL_Init(SDL_INIT_VIDEO) < 0)
    {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_StartTextInput();

#ifndef SIM_TITLE
#define SIM_TITLE "Commodore C16 — FPGAgo Simulation"
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

    static uint32_t fb[LCD_W * LCD_H];
    memset(fb, 0, sizeof(fb));

    int  pixel_idx  = 0;
    bool prev_de    = false;
    bool prev_vsync = true;
    bool running    = true;
    int  rst_count  = 0;

    top->rst = 0;
    top->rx  = 1;
    top->clk = 0;
    top->eval();

    top->joy = 0x1F;  /* all released (active-low) */

    fprintf(stderr,
        "Commodore C16 simulation started.\n"
        "LCD: %d x %d  window: %d x %d\n"
        "Type to interact with BASIC. ESC to quit.\n"
        "Joystick: arrow keys + Space=fire\n",
        LCD_W, LCD_H, LCD_W * WIN_SCALE, LCD_H * WIN_SCALE);

    while (running && !ctx->gotFinish())
    {
        /* Rising edge */
        top->clk = 1;
        top->eval();

        if (rst_count < RESET_CYCLES)
        {
            if (++rst_count == RESET_CYCLES)
                top->rst = 1;
        }

        uart_drive(top);
        uart_print(top);

        /* LCD pixel capture */
        if (prev_de && pixel_idx < LCD_W * LCD_H)
        {
            fb[pixel_idx] = rgb565_to_argb8888((uint16_t)top->lcd_data);
            pixel_idx++;
        }
        prev_de = (bool)top->lcd_de;

        /* Frame boundary: vsync falling edge */
        bool cur_vsync = (bool)top->lcd_vsync;
        if (prev_vsync && !cur_vsync)
        {
            SDL_UpdateTexture(texture, NULL, fb, LCD_W * (int)sizeof(uint32_t));
            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);
            pixel_idx = 0;

            /* Auto-typer: feed one line per frame after boot */
            autotype_tick();

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
                else if (ev.type == SDL_KEYDOWN || ev.type == SDL_KEYUP)
                {
                    SDL_Keycode sym = ev.key.keysym.sym;
                    bool pressed = (ev.type == SDL_KEYDOWN);

                    /* Joystick: arrows + WASD, space/ctrl = fire (active-low) */
                    /* joy bits: [0]=up [1]=down [2]=left [3]=right [4]=fire */
                    /* MiST JOY0 convention: [0]=right [1]=left [2]=down [3]=up [4]=fire */
                    switch (sym) {
                    case SDLK_UP:    case SDLK_w: if (pressed) top->joy &= ~8u;  else top->joy |= 8u;  break;
                    case SDLK_DOWN:  case SDLK_s: if (pressed) top->joy &= ~4u;  else top->joy |= 4u;  break;
                    case SDLK_LEFT:  case SDLK_a: if (pressed) top->joy &= ~2u;  else top->joy |= 2u;  break;
                    case SDLK_RIGHT: case SDLK_d: if (pressed) top->joy &= ~1u;  else top->joy |= 1u;  break;
                    case SDLK_SPACE: case SDLK_LCTRL: case SDLK_RCTRL:
                        if (pressed) top->joy &= ~16u; else top->joy |= 16u; break;
                    default: break;
                    }

                    /* Keyboard (only on press) */
                    if (pressed) {
                        if (sym == SDLK_ESCAPE)
                            running = false;
                        else if (sym == SDLK_RETURN || sym == SDLK_KP_ENTER)
                            uart_queue.push(0x0Du);
                        else if (sym == SDLK_BACKSPACE)
                            uart_queue.push(0x08u);
                    }
                }
            }
        }
        prev_vsync = cur_vsync;

        /* Falling edge */
        top->clk = 0;
        top->eval();
    }

    top->final();
    delete top;
    delete ctx;

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
