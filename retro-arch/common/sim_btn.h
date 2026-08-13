/*
 * sim_btn.h — scripted board-button presses for headless sim runs
 * (c16 / plus4 / c64 share this).
 *
 *   --btn <mask>:<start_us>:<end_us>     (repeatable)
 *
 * mask = hex bitmask of PRESSED buttons in soc btn[7:0] order
 * {D,C,B,A,right,left,down,up} — e.g. 0x80 = D (toggles CURSOR/JOY
 * mode in kbd_buttons.v), 0x18 = A(fire)+right.
 *
 * Usage: sim_btn_parse_args(argc, argv); then once per sim-µs:
 *   if (sim_btn_active()) top->btn = sim_btn_frame(g_sim_us);
 * (guarded so interactive SDL button input keeps working when no
 * --btn windows are given).
 */

#ifndef SIM_BTN_H
#define SIM_BTN_H

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>

struct sim_btn_win { uint32_t start, end; uint8_t mask; };
static std::vector<sim_btn_win> g_btn_wins;

static inline void sim_btn_parse_args(int argc, char** argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--btn") && i+1 < argc) {
            unsigned mask = 0; unsigned long s = 0, e = 0;
            /* %x: masks are documented as hex — %i silently read "80" as
             * decimal 80 (= buttons C+A), which cost an F-key debug round */
            if (sscanf(argv[++i], "%x:%lu:%lu", &mask, &s, &e) == 3) {
                g_btn_wins.push_back({(uint32_t)s, (uint32_t)e, (uint8_t)mask});
                fprintf(stderr, "btn: mask 0x%02X pressed %lu..%lu us\n",
                        mask, s, e);
            } else
                fprintf(stderr, "btn: bad --btn '%s' (want mask:start:end)\n",
                        argv[i]);
        }
    }
}

static inline bool sim_btn_active(void) { return !g_btn_wins.empty(); }

static inline uint8_t sim_btn_frame(uint32_t us)
{
    uint8_t b = 0xFF;                     /* active-low: released */
    for (size_t i = 0; i < g_btn_wins.size(); i++)
        if (us >= g_btn_wins[i].start && us < g_btn_wins[i].end)
            b &= (uint8_t)~g_btn_wins[i].mask;
    return b;
}

/* ── Direct joystick-port scripting: --joy <mask>:<start_us>:<end_us> ──
 * Drives the soc `joy` input (5 bits {fire,up,down,left,right}, active
 * low) directly — unlike --btn this bypasses kbd_buttons, so no JOY-mode
 * toggle is needed and no keyboard ghosting occurs. */
static std::vector<sim_btn_win> g_joy_wins;

static inline void sim_joy_parse_args(int argc, char** argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--joy") && i+1 < argc) {
            unsigned mask = 0; unsigned long s = 0, e = 0;
            /* %x: masks are documented as hex — %i silently read "80" as
             * decimal 80 (= buttons C+A), which cost an F-key debug round */
            if (sscanf(argv[++i], "%x:%lu:%lu", &mask, &s, &e) == 3) {
                g_joy_wins.push_back({(uint32_t)s, (uint32_t)e, (uint8_t)mask});
                fprintf(stderr, "joy: mask 0x%02X pressed %lu..%lu us\n",
                        mask, s, e);
            } else
                fprintf(stderr, "joy: bad --joy '%s' (want mask:start:end)\n",
                        argv[i]);
        }
    }
}

static inline bool sim_joy_active(void) { return !g_joy_wins.empty(); }

static inline uint8_t sim_joy_frame(uint32_t us)
{
    uint8_t j = 0x1F;
    for (size_t i = 0; i < g_joy_wins.size(); i++)
        if (us >= g_joy_wins[i].start && us < g_joy_wins[i].end)
            j &= (uint8_t)~g_joy_wins[i].mask;
    return j;
}

#endif /* SIM_BTN_H */
