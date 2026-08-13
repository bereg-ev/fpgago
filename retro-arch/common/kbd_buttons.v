`timescale 1ns / 1ps
/*
 * kbd_buttons.v — shared board-button front-end (c16 / plus4 / c64).
 *
 * The board has 8 push buttons: 4 arrows + A/B/C/D (active-low, external
 * pull-ups). Three mapping modes (BIOS-selectable over the QSPI link via
 * SET_BTNMODE, see qspi_slave.v):
 *
 *   MODE_TEXT (0): arrows HOLD the machine's cursor matrix keys
 *     (so the KERNAL's own auto-repeat drives directory navigation),
 *     A = RETURN, B = SPACE. Both joy ports idle released.
 *
 *   MODE_JOY1 (1): arrows + B (SW2) = FIRE drive JOYSTICK PORT 1; no
 *     matrix keys touched (A is reserved so mashing fire can't hit the
 *     chord).
 *
 *   MODE_JOY2 (2): same, on JOYSTICK PORT 2.
 *
 *   MODE_BOTH (3): the buttons drive PORT 1 AND PORT 2 at the same time.
 *     Multi-part titles poll a different port per module — Pirates! reads
 *     port 1 in the demo/attract and port 2 once the career starts — and on
 *     real hardware that meant unplugging the stick mid-game.  With one
 *     synthetic joystick there is no reason for the ports to be exclusive.
 *     Port 1 sits on the keyboard lines, so a held direction reads as a
 *     keypress unless the soc gates joy1_blank during the scan (the c64
 *     does; see soc.v).  MODE_JOY1/JOY2 stay exact for titles that mind.
 *
 * C = F1 and D = F2 in EVERY mode — games prompt "PRESS F1" from a
 * joystick screen, so the F keys must not depend on the mapping mode
 * (2026-07-19; replaces the old C=RUN/STOP and D=mode-toggle bindings).
 *
 * Holding A+B together for ~1s toggles TEXT <-> the last-used joystick
 * mode, so the classic "chord = switch to cursor keys for BASIC" habit
 * still works; WHICH port the joystick lands on is remembered (default
 * DEFAULT_MODE, or whatever the BIOS last selected).
 *
 * Matrix key positions are parameters because the c16/plus4 matrix has
 * dedicated cursor and F keys while the c64 uses SHIFT+CRSR for up/left
 * and SHIFT+F1 for F2.
 */
module kbd_buttons #(
    parameter CLK_HZ = 28_375_000,
    parameter [1:0] DEFAULT_MODE = 2'd2,   // power-up mode (c64: JOY2, 264: JOY1)
    parameter [5:0] KEY_UP      = 6'd0,
    parameter       UP_SHIFT    = 1'b0,
    parameter [5:0] KEY_DOWN    = 6'd0,
    parameter       DOWN_SHIFT  = 1'b0,
    parameter [5:0] KEY_LEFT    = 6'd0,
    parameter       LEFT_SHIFT  = 1'b0,
    parameter [5:0] KEY_RIGHT   = 6'd0,
    parameter       RIGHT_SHIFT = 1'b0,
    parameter [5:0] KEY_BTNA    = 6'd0,    // RETURN
    parameter [5:0] KEY_BTNB    = 6'd0,    // SPACE
    parameter [5:0] KEY_F1      = 6'd0,    // btn C, every mode
    parameter       F1_SHIFT    = 1'b0,
    parameter [5:0] KEY_F2      = 6'd0,    // btn D, every mode
    parameter       F2_SHIFT    = 1'b0,
    parameter [5:0] KEY_SHIFT   = {3'd1, 3'd7}   // LSHIFT (same on all)
)(
    input clk,
    input rst,                 // active-low
    input [7:0] btn_n,         // active-low {D,C,B,A,right,left,down,up}
    input       mode_set,      // 1-clk strobe: load mode_in (BIOS/QSPI)
    input [1:0] mode_in,       // 0 = TEXT, 1 = JOY1, 2 = JOY2, 3 = BOTH
    input       joy1_blank,    // 1 = hide the port-1 pull this cycle (BOTH
                               //     mode keyboard-scan gating; tie 0 if the
                               //     soc does not need it)
    output reg [1:0] mode,     // current mode (0..3)
    output [4:0] joy1_n,       // active-low {fire,up,down,left,right}, port 1
    output [4:0] joy2_n,       // active-low {fire,up,down,left,right}, port 2
    output reg [63:0] matrix   // held matrix keys (OR with the typer's)
);

localparam [1:0] MODE_TEXT = 2'd0;
localparam [1:0] MODE_JOY1 = 2'd1;
localparam [1:0] MODE_JOY2 = 2'd2;
localparam [1:0] MODE_BOTH = 2'd3;

/* ── Sync + ~2ms debounce (one shared counter, all bits settle together) */
localparam [15:0] DB_CYC = CLK_HZ / 500;
localparam [24:0] CHORD_CYC = CLK_HZ;      // A+B held ~1s = mode toggle
reg [7:0]  sync0 = 8'hFF, sync1 = 8'hFF, stable = 8'hFF, stable_prev = 8'hFF;
reg [15:0] db_cnt = 0;
reg [24:0] chord_cnt = 0;
reg chord_fired = 0;

/* JOY is the power-on default (most games want the joystick; the chord
 * switches to TEXT mode for BASIC/directory work). last_joy remembers the
 * port so the toggle round-trips TEXT <-> that port. */
reg [1:0] last_joy = DEFAULT_MODE;
initial mode = DEFAULT_MODE;

always @(posedge clk) begin
    if (!rst) begin
        sync0 <= 8'hFF; sync1 <= 8'hFF;
        stable <= 8'hFF; stable_prev <= 8'hFF;
        db_cnt <= 0; mode <= DEFAULT_MODE; last_joy <= DEFAULT_MODE;
        chord_cnt <= 0; chord_fired <= 0;
    end else begin
        sync0 <= btn_n;
        sync1 <= sync0;
        if (sync1 != stable) begin
            if (db_cnt == DB_CYC) begin
                stable <= sync1;
                db_cnt <= 0;
            end else
                db_cnt <= db_cnt + 1'b1;
        end else
            db_cnt <= 0;

        stable_prev <= stable;

        // A+B held for CHORD_CYC: toggle mode once per hold (D used to do
        // this on a tap, but D is the F2 key now)
        if (!stable[4] && !stable[5]) begin
            if (!chord_fired) begin
                if (chord_cnt == CHORD_CYC) begin
                    mode <= (mode == MODE_TEXT) ? last_joy : MODE_TEXT;
                    chord_fired <= 1'b1;
                end else
                    chord_cnt <= chord_cnt + 1'b1;
            end
        end else begin
            chord_cnt <= 0;
            chord_fired <= 0;
        end

        // BIOS override (QSPI SET_BTNMODE) wins over any local toggle in
        // the same clk; a joystick selection also becomes the remembered
        // port for later chord toggles.
        if (mode_set) begin
            mode <= mode_in;
            if (mode_in != MODE_TEXT)
                last_joy <= mode_in;
        end
    end
end

wire up_p    = ~stable[0];
wire down_p  = ~stable[1];
wire left_p  = ~stable[2];
wire right_p = ~stable[3];
wire a_p     = ~stable[4];
wire b_p     = ~stable[5];
wire c_p     = ~stable[6];
wire d_p     = ~stable[7];

wire [4:0] joy_pressed_n = ~{b_p, up_p, down_p, left_p, right_p};  // FIRE = B (SW2)
/* BOTH drives either port; joy1_blank only ever hides the port-1 copy, so a
 * scan-gated soc still can't lose the port-2 read the game is doing. */
wire joy1_on = (mode == MODE_JOY1) || (mode == MODE_BOTH && !joy1_blank);
wire joy2_on = (mode == MODE_JOY2) || (mode == MODE_BOTH);
assign joy1_n = joy1_on ? joy_pressed_n : 5'h1F;
assign joy2_n = joy2_on ? joy_pressed_n : 5'h1F;

/* Shift envelope for SHIFT+CRSR directions (c64): SHIFT must be visible
 * to every KERNAL scan pass that sees the key, so SHIFT rises ~3ms before
 * the key bit is exposed and falls ~3ms after it is dropped. Directions
 * without a shift requirement pass straight through. */
localparam [15:0] LEAD_CYC = 3 * (CLK_HZ / 1000);
wire shift_want = ((mode == MODE_TEXT) &&
                   ((up_p    && UP_SHIFT)   || (down_p  && DOWN_SHIFT) ||
                    (left_p  && LEFT_SHIFT) || (right_p && RIGHT_SHIFT))) ||
                  (c_p && F1_SHIFT) || (d_p && F2_SHIFT);
reg shift_held = 0;     // drives the SHIFT matrix bit
reg shift_ready = 0;    // shift has led long enough to expose the keys
reg [15:0] env_cnt = 0;
always @(posedge clk) begin
    if (!rst) begin
        shift_held <= 0; shift_ready <= 0; env_cnt <= 0;
    end else if (shift_want) begin
        shift_held <= 1;
        if (!shift_ready) begin
            if (env_cnt == LEAD_CYC) begin shift_ready <= 1; env_cnt <= 0; end
            else env_cnt <= env_cnt + 1'b1;
        end
    end else begin
        shift_ready <= 0;
        if (shift_held) begin
            if (env_cnt == LEAD_CYC) begin shift_held <= 0; env_cnt <= 0; end
            else env_cnt <= env_cnt + 1'b1;
        end else
            env_cnt <= 0;
    end
end

always @* begin
    matrix = 64'd0;
    if (mode == MODE_TEXT) begin
        if (up_p    && (!UP_SHIFT    || shift_ready)) matrix[KEY_UP]    = 1'b1;
        if (down_p  && (!DOWN_SHIFT  || shift_ready)) matrix[KEY_DOWN]  = 1'b1;
        if (left_p  && (!LEFT_SHIFT  || shift_ready)) matrix[KEY_LEFT]  = 1'b1;
        if (right_p && (!RIGHT_SHIFT || shift_ready)) matrix[KEY_RIGHT] = 1'b1;
        if (a_p) matrix[KEY_BTNA] = 1'b1;
        if (b_p) matrix[KEY_BTNB] = 1'b1;
    end
    // F1/F2 work in EVERY mode (games ask for them from joystick screens)
    if (c_p && (!F1_SHIFT || shift_ready)) matrix[KEY_F1] = 1'b1;
    if (d_p && (!F2_SHIFT || shift_ready)) matrix[KEY_F2] = 1'b1;
    if (shift_held) matrix[KEY_SHIFT] = 1'b1;
end

endmodule
