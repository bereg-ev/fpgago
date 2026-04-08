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
 * 4.  main()
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char** argv)
{
    /* ── Verilator context ── */
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    /* ── SDL2 init ── */
    if (SDL_Init(SDL_INIT_VIDEO) < 0)
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

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
