/*
 * sim_top.cpp — C16 Verilator + SDL2 desktop simulation
 *
 * Compiles the C16 SoC via Verilator and renders the LCD pixel output
 * in an SDL2 window. Keyboard input is forwarded via UART.
 *
 * Build:  cd retro-arch/plus4/sim-desktop && make
 * Run:    ./obj_dir/Vsoc
 *
 * Keys: see retro-arch/common/sdl_kbd_input.h (shared PETSCII protocol,
 * arrows = cursor keys or joystick via the board buttons, F12 toggles).
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <queue>
#include <vector>

#include "verilated.h"
#include "Vsoc.h"
#include "Vsoc___024root.h"

double sc_time_stamp() { return 0; }

#include <SDL.h>

/* Shared 1541 floppy + IEC-bus glue (same code for c16 / plus4 / c64). */
#include "iec_floppy_sim.h"
#include "qspi_mcu_sim.h"   /* --qspi: MCU model serving the fastload link */
/* Shared TED/SID audio capture: --wav <path> dump + --audio live SDL
 * playback of soc.audio_pcm (sampled once per sim-us, /20 decimate). */
#include "sim_audio.h"
/* Scripted board-button presses for headless runs: --btn mask:start:end */
#include "sim_btn.h"
/* Shared SDL keyboard/button input glue (PETSCII protocol + board buttons). */
#include "sdl_kbd_input.h"

/* C16/Plus4 clock is 28.375 MHz → ~28 cycles per microsecond. */
static const int CYCLES_PER_US = 28;
static uint32_t  g_sim_us         = 0;
static int       g_us_cycle_count = 0;

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

/* ── Software UART TX → RX pin (keystrokes come from g_uart_queue) ──── */
static void uart_drive(Vsoc* top)
{
    static int     state     = 0;
    static int     clk_count = 0;
    static uint8_t tx_byte   = 0;

    if (state == 0)
    {
        top->rx = 1;
        if (!g_uart_queue.empty())
        {
            tx_byte   = g_uart_queue.front();
            g_uart_queue.pop();
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

/* Auto-typer, PPM dump, floppy load — all shared via iec_floppy_sim.h. */

/* ── main ──────────────────────────────────────────────────────────── */
int main(int argc, char** argv)
{
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    /* Init the shared 1541 floppy + IEC glue, parse CLI (--d64/--rom/--autotype
     * /--headless/--screenshot/--exit-us). Device #8 (IEC default). */
    iec_floppy_parse_args(argc, argv, 8);
    sim_audio_parse_args(argc, argv);
    sim_btn_parse_args(argc, argv);
    sim_joy_parse_args(argc, argv);
    qspi_mcu_parse_args(argc, argv, CYCLES_PER_US);

    /* Fast-load config (Plus/4 & C16 share the BASIC 3.5 KERNAL layout).
     * RAM mask differs: C16 = 16KB ($3FFF), Plus/4 = 64KB ($FFFF). */
#ifndef FL_RAM_MASK
#define FL_RAM_MASK 0xFFFF
#endif
    g_flcfg = { /*load_vec*/0x032E, /*stub*/0x0380, /*fnadr*/0xAF, /*fnlen*/0xAB,
                /*sa*/0xAD, /*reloc_ptr*/0xB4, /*status*/0x90,
                /*ram_mask*/FL_RAM_MASK, /*valid*/true,
                /*kernal_load_default*/0xF04A };

#ifndef SIM_TITLE
#define SIM_TITLE "Commodore 16 — FPGAgo Simulation"
#endif

    SDL_Window*   window   = NULL;
    SDL_Renderer* renderer = NULL;
    SDL_Texture*  texture  = NULL;

    if (!g_headless)
    {
        if (SDL_Init(SDL_INIT_VIDEO | sim_audio_sdl_flags()) < 0)
        {
            fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
            return 1;
        }
        SDL_StartTextInput();
        sim_audio_open();

        window = SDL_CreateWindow(
            SIM_TITLE,
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
            LCD_W * WIN_SCALE, LCD_H * WIN_SCALE,
            0);
        if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }

        renderer = SDL_CreateRenderer(
            window, -1,
            SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
        if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
        SDL_RenderSetLogicalSize(renderer, LCD_W, LCD_H);

        texture = SDL_CreateTexture(
            renderer,
            SDL_PIXELFORMAT_ARGB8888,
            SDL_TEXTUREACCESS_STREAMING,
            LCD_W, LCD_H);
        if (!texture) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return 1; }
    }

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
    top->iec_clk_in  = 1;  /* released */
    top->iec_data_in = 1;
    top->spi_ss    = 1;    /* link deselected until the MCU model speaks */
    top->spi_sck   = 0;
    top->spi_sd_in = 0xF;  /* all lanes idle high (board pull-ups) */
    top->eval();

    top->joy = 0x1F;  /* all released (active-low) */
    top->btn = 0xFF;  /* all released (active-low) */
    if (!g_headless)
        retro_kbd_init(window, SIM_TITLE);

    fprintf(stderr,
        "Commodore 16 simulation started.\n"
        "LCD: %d x %d  window: %d x %d\n"
        "Type to interact with BASIC. ESC to quit.\n"
        "Arrows: CURSOR keys (default) or JOYSTICK — F12 toggles, Ctrl=fire/RETURN\n"
        "F1-F8=function keys  F9=RUN/STOP  F10=ESC  Home/Ins/Del as labeled\n",
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

        /* Speed ratio measurement: count Plus/4 instruction fetches vs the
         * drive's CPU cycles to verify the 1541:Plus4 clock ratio. */
        if (getenv("SPEED_MEAS")) {
            static uint16_t sp_prev = 0xFFFF;
            static uint64_t p4_fetches = 0;
            uint16_t a = (uint16_t)top->dbg_cpu_addr;
            if (a != sp_prev) p4_fetches++;
            sp_prev = a;
            static uint32_t sp_last = 0;
            if (g_sim_us - sp_last >= 1000000) {
                sp_last = g_sim_us;
                fprintf(stderr, "[speed] %uus: plus4_fetches=%llu drive_cyc=%llu "
                        "ratio(p4/drive)=%.2f\n", g_sim_us,
                        (unsigned long long)p4_fetches,
                        (unsigned long long)g_floppy.cpu.cycles,
                        g_floppy.cpu.cycles ? (double)p4_fetches / g_floppy.cpu.cycles : 0);
            }
        }

        /* C16 8501 CPU address trace (sim tracing of the KERNAL). */
        if (getenv("PLUS4_PC")) {
            static uint16_t p4_prev = 0xFFFF;
            static uint32_t p4_last_us = 0;
            uint16_t a = (uint16_t)top->dbg_cpu_addr;
            if (a != p4_prev && g_sim_us - p4_last_us >= 20000) {
                p4_last_us = g_sim_us;
                fprintf(stderr, "[plus4-pc] %uus addr=$%04X\n", g_sim_us, a);
            }
            p4_prev = a;
        }

        /* Fine-grained IEC feedback, EVERY Verilator cycle (shared glue). */
        iec_floppy_feedback(top);
        fastload_trap(top, (uint16_t)top->dbg_cpu_addr);
        qspi_mcu_tick(top);

        /* IEC bus / 1541 floppy.  Advance the floppy once per simulated µs
         * via the shared glue (this is the SAME call c16/c64 use). */
        if (++g_us_cycle_count >= CYCLES_PER_US)
        {
            g_us_cycle_count = 0;
            g_sim_us++;
            sim_audio_sample((int16_t)top->audio_pcm);
            if (sim_btn_active()) top->btn = sim_btn_frame(g_sim_us);
            if (sim_joy_active()) top->joy = sim_joy_frame(g_sim_us);
            iec_floppy_step(top, g_sim_us);

            /* Optional drive/IEC tracing (plus4-specific). */
            if (g_floppy_enabled && (getenv("EMU_DEBUG") || getenv("IEC_DEBUG")))
            {
                int fpga_atn  = (int)top->iec_atn_out;
                int fpga_clk  = (int)top->iec_clk_out;
                int fpga_data = (int)top->iec_data_out;
                int floppy_clk_rel  = g_floppy.out_clk  ? 0 : 1;
                int floppy_data_rel = g_floppy.out_data ? 0 : 1;
                int bus_atn  = fpga_atn;
                int bus_clk  = fpga_clk  & floppy_clk_rel;
                int bus_data = fpga_data & floppy_data_rel;

                /* Emu-mode debug: dump on bus / orb / pb_in / IFR state change */
                if (getenv("EMU_DEBUG")) {
                    static int dprev_a = -1, dprev_c = -1, dprev_d = -1;
                    static uint8_t dprev_orb = 0xFF, dprev_pb_in = 0xFF;
                    static uint8_t dprev_outc = 0xFF, dprev_outd = 0xFF;
                    static uint8_t dprev_ifr = 0xFF, dprev_pcr = 0xFF, dprev_ier = 0xFF;
                    if (bus_atn != dprev_a || bus_clk != dprev_c || bus_data != dprev_d ||
                        g_floppy.via1.orb != dprev_orb || g_floppy.via1.pb_in != dprev_pb_in ||
                        g_floppy.out_clk != dprev_outc || g_floppy.out_data != dprev_outd ||
                        g_floppy.via1.ifr != dprev_ifr ||
                        g_floppy.via1.pcr != dprev_pcr ||
                        g_floppy.via1.ier != dprev_ier)
                    {
                        fprintf(stderr,
                            "[%7u µs] pc=$%04X pb=$%02X orb=$%02X "
                            "out=(c=%d d=%d) bus(a=%d c=%d d=%d) "
                            "ifr=$%02X ier=$%02X pcr=$%02X p=$%02X\n",
                            g_sim_us, g_floppy.cpu.pc,
                            g_floppy.via1.pb_in,
                            g_floppy.via1.orb,
                            g_floppy.out_clk, g_floppy.out_data,
                            bus_atn, bus_clk, bus_data,
                            g_floppy.via1.ifr, g_floppy.via1.ier,
                            g_floppy.via1.pcr, g_floppy.cpu.p);
                        dprev_a = bus_atn; dprev_c = bus_clk; dprev_d = bus_data;
                        dprev_orb = g_floppy.via1.orb;
                        dprev_pb_in = g_floppy.via1.pb_in;
                        dprev_outc = g_floppy.out_clk;
                        dprev_outd = g_floppy.out_data;
                        dprev_ifr = g_floppy.via1.ifr;
                        dprev_pcr = g_floppy.via1.pcr;
                        dprev_ier = g_floppy.via1.ier;
                    }
                }

                /* Debug: log every IEC edge or state change */
                if (getenv("IEC_DEBUG")) {
                    static int p_atn = -1, p_clk = -1, p_data = -1;
                    static int p_fclk = -1, p_fdata = -1;
                    static int p_state = -1;
                    if (fpga_atn != p_atn || fpga_clk != p_clk ||
                        fpga_data != p_data || floppy_clk_rel != p_fclk ||
                        floppy_data_rel != p_fdata ||
                        (int)g_floppy.state != p_state)
                    {
                        fprintf(stderr,
                            "[%6u µs] FPGA atn=%d clk=%d data=%d  "
                            "FLOPPY clk=%d data=%d  state=%d addressed=%d "
                            "listening=%d talking=%d ch=%d\n",
                            g_sim_us, fpga_atn, fpga_clk, fpga_data,
                            floppy_clk_rel, floppy_data_rel,
                            g_floppy.state, g_floppy.addressed,
                            g_floppy.listening, g_floppy.talking,
                            g_floppy.cur_channel);
                        p_atn = fpga_atn; p_clk = fpga_clk; p_data = fpga_data;
                        p_fclk = floppy_clk_rel; p_fdata = floppy_data_rel;
                        p_state = (int)g_floppy.state;
                    }
                }
            }
        }

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
            if (!g_headless)
            {
                SDL_UpdateTexture(texture, NULL, fb, LCD_W * (int)sizeof(uint32_t));
                SDL_RenderClear(renderer);
                SDL_RenderCopy(renderer, texture, NULL, NULL);
                SDL_RenderPresent(renderer);
            }
            pixel_idx = 0;

            /* Auto-typer: feed one character per frame after boot */
            autotype_tick(g_sim_us);
            fastload_maintain(top);
            screenshot_tick(g_sim_us, fb, LCD_W, LCD_H);

            /* Headless auto-quit after the requested sim-time window. */
            if (g_exit_us && g_sim_us >= g_exit_us)
                running = false;

            SDL_Event ev;
            while (!g_headless && SDL_PollEvent(&ev))
                retro_kbd_event(&ev, &running);   /* shared key/button glue */
            top->btn = retro_kbd_btn_frame();
        }
        prev_vsync = cur_vsync;

        /* Falling edge */
        top->clk = 0;
        top->eval();
    }

    top->final();

    sim_audio_finish();

    /* Dump the final screen for g_headless verification. */
    if (g_screenshot_path)
        dump_ppm(g_screenshot_path, fb, LCD_W, LCD_H);

    delete top;
    delete ctx;

    if (!g_headless)
    {
        SDL_DestroyTexture(texture);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
    }

    return 0;
}
