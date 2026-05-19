/*
 * sim_top.cpp — Verilator + SDL2 harness for the DarkRISCV labyrinth SoC.
 *
 *   - Drives clk + rst.
 *   - On every FRAME_READY pulse from the SoC, peeks the framebuffer memory
 *     and uploads it to an SDL2 texture.
 *   - Forwards keystrokes to the SoC's UART_RX register (w/a/s/d/q/e + ESC quit).
 *   - Prints any UART_TX byte to stdout (handy for debug prints from the firmware).
 *
 * Exit: ESC, window close, or SIM_MAX_CYCLES.
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <SDL.h>
#include <verilated.h>
#include "Vsoc.h"
#include "Vsoc___024root.h"

static const int SCREEN_W = 480;
static const int SCREEN_H = 272;
static const int WIN_SCALE = 2;

int main(int argc, char** argv)
{
    // No cycle ceiling by default — sim runs until ESC / window-close /
    // $finish.  Set SIM_MAX_CYCLES=N to cap; SIM_MAX_CYCLES=0 also means
    // unbounded.
    const char* mc_env = getenv("SIM_MAX_CYCLES");
    uint64_t max_cycles = mc_env ? strtoull(mc_env, nullptr, 0) : 0ULL;

    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
#ifndef SIM_TITLE
#define SIM_TITLE "DarkRISCV (ESC=quit)"
#endif
    SDL_Window*   win  = SDL_CreateWindow(SIM_TITLE,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * WIN_SCALE, SCREEN_H * WIN_SCALE, 0);
    SDL_Renderer* ren  = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture*  tex  = SDL_CreateTexture(ren,
        SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H);

    // Pixel scratch we blit out of the SoC's fb[] every frame.
    static uint32_t frame[SCREEN_W * SCREEN_H];

    top->rst = 0;
    top->clk = 0;
    top->uart_rx_data  = 0;
    top->uart_rx_valid = 0;
    top->fb_rd_addr    = 0;     // unused in sim; SDL peeks fb directly

    uint64_t cyc = 0;
    bool running = true;
    int  rx_pending = -1;   // ascii code to inject, or -1

    while (running && (max_cycles == 0 || cyc < max_cycles) && !ctx->gotFinish()) {
        if (cyc == 8) top->rst = 1;

        // Drive an enqueue cycle for a pending keystroke.
        if (rx_pending >= 0) {
            top->uart_rx_data  = (uint8_t)rx_pending;
            top->uart_rx_valid = 1;
            rx_pending = -1;
        } else {
            top->uart_rx_valid = 0;
        }

        top->clk = 1;
        top->eval();

        if (top->uart_tx_pulse) {
            fputc(top->uart_tx_data, stdout);
            fflush(stdout);
        }

        if (top->frame_ready_pulse) {
            auto* r = top->rootp;

            // ── 1. RGB565 framebuffer → ARGB ─────────────────────────────
            auto& fb = r->soc__DOT__fb;
            for (int i = 0; i < SCREEN_W * SCREEN_H; i++) {
                uint16_t px = (uint16_t)fb[i];
                uint8_t rr = ((px >> 11) & 0x1F) << 3;
                uint8_t gg = ((px >>  5) & 0x3F) << 2;
                uint8_t bb = ( px        & 0x1F) << 3;
                rr |= rr >> 5;
                gg |= gg >> 6;
                bb |= bb >> 5;
                frame[i] = 0xFF000000u | ((uint32_t)rr << 16)
                                       | ((uint32_t)gg <<  8)
                                       |  (uint32_t)bb;
            }

            // ── 2. LCD_CHAR overlay (white text on top of the FB) ────────
            if (r->soc__DOT__lcd_char_enabled) {
                auto& text = r->soc__DOT__lcd_text;   // [0..511], u32
                auto& font = r->soc__DOT__lcd_font;   // [0..1023], u32 (low 16 used)
                int x0    = r->soc__DOT__lcd_char_x;
                int y0    = r->soc__DOT__lcd_char_y;
                int numx  = r->soc__DOT__lcd_char_numx;
                int numy  = r->soc__DOT__lcd_char_numy;
                if (numx > 32) numx = 32;
                if (numy > 32) numy = 32;
                for (int cy = 0; cy < numy; cy++) {
                    for (int cx = 0; cx < numx; cx++) {
                        uint32_t ch = text[cy * numx + cx] & 0x7F;
                        // Font layout: low 8 bits = even glyph line,
                        //              high 8 bits = odd glyph line.
                        for (int gy = 0; gy < 16; gy++) {
                            uint32_t e = font[(ch << 3) | (gy >> 1)];
                            uint8_t row = (gy & 1) ? (e >> 8) : (e & 0xFF);
                            int py = y0 + cy * 16 + gy;
                            if (py < 0 || py >= SCREEN_H) continue;
                            for (int gx = 0; gx < 8; gx++) {
                                if (row & (0x80 >> gx)) {
                                    int px = x0 + cx * 8 + gx;
                                    if (px >= 0 && px < SCREEN_W)
                                        frame[py * SCREEN_W + px] = 0xFFFFFFFFu;
                                }
                            }
                        }
                    }
                }
            }

            SDL_UpdateTexture(tex, nullptr, frame, SCREEN_W * (int)sizeof(uint32_t));
            SDL_RenderClear(ren);
            SDL_RenderCopy(ren, tex, nullptr, nullptr);
            SDL_RenderPresent(ren);
        }

        top->clk = 0;
        top->eval();

        // Poll SDL events once per ~256 sim cycles so we don't drown the CPU.
        if ((cyc & 0xFF) == 0) {
            SDL_Event ev;
            while (SDL_PollEvent(&ev)) {
                if (ev.type == SDL_QUIT) { running = false; }
                if (ev.type == SDL_KEYDOWN) {
                    SDL_Keycode k = ev.key.keysym.sym;
                    if (k == SDLK_ESCAPE) { running = false; }
                    else if (k == SDLK_w || k == SDLK_UP)    rx_pending = 'w';
                    else if (k == SDLK_s || k == SDLK_DOWN)  rx_pending = 's';
                    else if (k == SDLK_a || k == SDLK_LEFT)  rx_pending = 'a';
                    else if (k == SDLK_d || k == SDLK_RIGHT) rx_pending = 'd';
                    else if (k == SDLK_q) rx_pending = 'q';
                    else if (k == SDLK_e) rx_pending = 'e';
                }
            }
        }

        cyc++;
    }

    fprintf(stderr, "\n[sim] exiting after %llu cycles.\n", (unsigned long long)cyc);

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();

    top->final();
    delete top;
    delete ctx;
    return 0;
}
