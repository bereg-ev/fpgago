/*
 * sdl_kbd_input.h — shared SDL keyboard/button input for the retro sims
 * (c16 / plus4 / c64).  Include AFTER iec_floppy_sim.h (uses g_uart_queue).
 *
 * UART key protocol (decoded by kbd_typer + c16_kbd_map / c64_kbd_map):
 *   printable ASCII   typed as-is ('A'-'Z' and 'a'-'z' are both the plain
 *                     letter key — what BASIC keywords need)
 *   0xC1-0xDA         SHIFT+letter (PC Shift+letter arrives here; gives
 *                     graphics chars / keyword abbreviations like L SHIFT+O)
 *   0x0D RETURN  0x8D SHIFT+RETURN  0x14 DEL  0x94 INST
 *   0x13 HOME    0x93 CLR   0x11/0x91/0x1D/0x9D cursor down/up/right/left
 *   0x03 STOP    0x83 RUN   0x1B ESC   0x85-0x8C PC F1..F8
 *
 * Board buttons (drives top->btn, active-low):
 *   bit0 up  bit1 down  bit2 left  bit3 right
 *   bit4 A (fire / RETURN)  bit5 B (SPACE)  bit6 C (RUN/STOP)
 *   bit7 D (CURSOR <-> JOY mode toggle)
 *
 * PC bindings:
 *   Arrows      board arrow buttons: CURSOR mode (default) moves the
 *               machine's character cursor with native KERNAL auto-repeat;
 *               JOY mode drives the joystick
 *   L/R Ctrl    board button A (joystick fire / RETURN in cursor mode)
 *   F12         toggle CURSOR <-> JOY mode (shown in the window title)
 *   F1-F8       machine function keys     F9  RUN/STOP (shift: RUN)
 *   F10         machine ESC key (c16/plus4)
 *   Home/Ins/Del/Backspace/Return         as labeled (shift variants work)
 *   ESC         quit the simulator
 */
#ifndef SDL_KBD_INPUT_H
#define SDL_KBD_INPUT_H

static uint8_t     g_btn_level   = 0xFF;   /* active-low button levels */
static int         g_btn_d_pulse = 0;      /* frames left to hold D low */
static bool        g_ui_mode_joy = false;  /* mirrors the RTL mode FF */
static SDL_Window* g_kbd_win     = NULL;
static const char* g_kbd_title   = "sim";

static inline void retro_kbd_update_title(void)
{
    if (!g_kbd_win) return;
    char buf[256];
    snprintf(buf, sizeof(buf), "%s  [arrows=%s, F12 switches]",
             g_kbd_title, g_ui_mode_joy ? "JOYSTICK" : "CURSOR");
    SDL_SetWindowTitle(g_kbd_win, buf);
}

static inline void retro_kbd_init(SDL_Window* w, const char* title)
{
    g_kbd_win   = w;
    g_kbd_title = title;
    retro_kbd_update_title();
}

/* Feed one SDL event. Sets *running = false on quit. */
static inline void retro_kbd_event(const SDL_Event* ev, bool* running)
{
    if (ev->type == SDL_QUIT) { *running = false; return; }

    if (ev->type == SDL_TEXTINPUT)
    {
        uint8_t ch = (uint8_t)ev->text.text[0];
        if (ch >= 'A' && ch <= 'Z')
            g_uart_queue.push((uint8_t)(0xC1 + (ch - 'A')));  /* SHIFT+letter */
        else if (ch >= 0x20 && ch <= 0x7E)
            g_uart_queue.push(ch);
        return;
    }

    if (ev->type != SDL_KEYDOWN && ev->type != SDL_KEYUP)
        return;

    SDL_Keycode sym  = ev->key.keysym.sym;
    bool press = (ev->type == SDL_KEYDOWN);

    /* Board buttons: level-held; RTL debounces, machine handles repeat. */
    uint8_t bit = 0;
    switch (sym) {
    case SDLK_UP:    bit = 0x01; break;
    case SDLK_DOWN:  bit = 0x02; break;
    case SDLK_LEFT:  bit = 0x04; break;
    case SDLK_RIGHT: bit = 0x08; break;
    case SDLK_LCTRL:
    case SDLK_RCTRL: bit = 0x10; break;   /* button A: fire / RETURN */
    default: break;
    }
    if (bit) {
        if (press) g_btn_level &= (uint8_t)~bit;
        else       g_btn_level |= bit;
        return;
    }

    if (!press) return;
    bool sh = (ev->key.keysym.mod & KMOD_SHIFT) != 0;

    if (sym >= SDLK_F1 && sym <= SDLK_F8) {
        g_uart_queue.push((uint8_t)(0x85 + (sym - SDLK_F1)));
        return;
    }

    switch (sym) {
    case SDLK_ESCAPE:    *running = false;                       break;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:  g_uart_queue.push(sh ? 0x8D : 0x0D);    break;
    case SDLK_BACKSPACE:
    case SDLK_DELETE:    g_uart_queue.push(sh ? 0x94 : 0x14);    break;
    case SDLK_INSERT:    g_uart_queue.push(0x94);                break;
    case SDLK_HOME:      g_uart_queue.push(sh ? 0x93 : 0x13);    break;
    case SDLK_F9:        g_uart_queue.push(sh ? 0x83 : 0x03);    break;
    case SDLK_F10:       g_uart_queue.push(0x1B);                break;
    case SDLK_F12:
        g_btn_d_pulse = 4;              /* hold D low ~4 frames > debounce */
        g_ui_mode_joy = !g_ui_mode_joy;
        retro_kbd_update_title();
        break;
    default: break;
    }
}

/* Call once per video frame; returns the byte to drive top->btn with. */
static inline uint8_t retro_kbd_btn_frame(void)
{
    uint8_t b = g_btn_level;
    if (g_btn_d_pulse > 0) { g_btn_d_pulse--; b &= 0x7F; }
    return b;
}

#endif /* SDL_KBD_INPUT_H */
