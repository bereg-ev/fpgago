`timescale 1ns / 1ps
/*
 * kbd_typer.v — shared UART→keyboard-matrix typer (c16 / plus4 / c64).
 *
 * Receives a PETSCII-flavored byte stream (see the per-platform
 * c16_kbd_map.v / c64_kbd_map.v for the exact code list), buffers it in a
 * 64-entry FIFO so fast typing / autotype bursts are never dropped, and
 * "presses" one key at a time on the 8x8 matrix:
 *
 *   - the matched key (plus LSHIFT when the mapper asks for it) is held
 *     for HOLD_MS, long enough to be seen by at least one full KERNAL
 *     IRQ scan (20ms PAL frame) no matter the scan phase;
 *   - consecutive DIFFERENT keys are typed back-to-back with no gap: the
 *     KERNAL registers a key on scan-to-scan change, so rollover works;
 *   - a GAP_MS release pause is inserted only when the next byte lands on
 *     the SAME matrix key (e.g. "ll"), which the KERNAL would otherwise
 *     fold into one press;
 *   - the MODIFIERS (LSHIFT / C= / CTRL) ENVELOPE the key by LEAD_MS on
 *     both sides: the KERNAL scan pass reads the modifier row and the key
 *     row at different instants, so a key that appears/disappears mid-pass
 *     without the envelope can be registered with the wrong shift state
 *     ('"' typed as '2').
 *
 * The PETSCII→matrix lookup lives in an external combinational mapper fed
 * from map_code (platform matrices differ); the mapper answers with
 * map_valid/map_shift/map_cbm/map_ctrl/map_prefix/map_key in the following
 * cycle.
 *
 * A mapper code with map_prefix set is not a keypress: it ARMS its modifiers
 * for the NEXT key and is otherwise invisible (no press, no timing).  That
 * is how C=/CTRL combos reach the machine without burning ~70 code points on
 * a "modifier + X" table per platform — the BIOS on-screen keyboard sends
 * "$81 A" for C=+A.  Prefixes stack ("$81 $80 A" = C=+SHIFT+A) and are
 * consumed by the key they lead.
 */
module kbd_typer #(
    parameter CLK_HZ  = 28_375_000,
    parameter HOLD_MS = 35,
    parameter GAP_MS  = 25,
    parameter LEAD_MS = 3      // shift envelope before/after the key
)(
    input clk,
    input rst,                     // active-low
    input [7:0] rx_data,
    input rx_valid,                // 1-clk pulse per received byte
    output reg [7:0] map_code,     // to the external mapper (combinational)
    input map_valid,
    input map_shift,
    input map_cbm,
    input map_ctrl,
    input map_prefix,              // arm the modifiers, don't press anything
    input [5:0] map_key,           // {row[2:0], col[2:0]} from the mapper
    input [5:0] shift_key,         // {row,col} of the LSHIFT matrix key
    input [5:0] cbm_key,           // {row,col} of the C= key
    input [5:0] ctrl_key,          // {row,col} of the CTRL key
    output reg [63:0] matrix       // 1 = key held, index = row*8+col
);

localparam [20:0] HOLD_CYC = HOLD_MS * (CLK_HZ / 1000);
localparam [20:0] GAP_CYC  = GAP_MS  * (CLK_HZ / 1000);
localparam [20:0] LEAD_CYC = LEAD_MS * (CLK_HZ / 1000);

/* ── 64-byte FIFO ──────────────────────────────────────────────────── */
reg [7:0] fifo [0:63];
reg [5:0] wptr = 0, rptr = 0;
reg [6:0] count = 0;
reg pop = 0;

wire push = rx_valid && (count != 7'd64);   // overflow: drop newest

always @(posedge clk) begin
    if (!rst) begin
        wptr <= 0; rptr <= 0; count <= 0;
    end else begin
        if (push) begin
            fifo[wptr] <= rx_data;
            wptr <= wptr + 1'b1;
        end
        if (pop)
            rptr <= rptr + 1'b1;
        count <= count + (push ? 7'd1 : 7'd0) - (pop ? 7'd1 : 7'd0);
    end
end

/* ── Press scheduler ───────────────────────────────────────────────── */
localparam [2:0] S_IDLE = 3'd0, S_MAP = 3'd1, S_GAP = 3'd2,
                 S_LEAD = 3'd3, S_PRESS = 3'd4, S_LAG = 3'd5, S_POST = 3'd6;
reg [2:0]  state = S_IDLE;
reg [20:0] timer = 0;                    // per-state countdown
reg [20:0] since_rel = {21{1'b1}};       // saturating: time since key release
reg [5:0]  last_key = 0;
reg        have_last = 0;
reg        cur_mod = 0;                  // this key is holding modifier(s)

/* Modifiers for the key being mapped: what its own code asks for, plus
 * whatever prefix bytes armed ahead of it.  `pend` survives S_GAP (it is
 * cleared only by the press that consumes it). */
reg  [2:0] pend = 0;                     // {ctrl, cbm, shift}
wire [2:0] mods = pend | {map_ctrl, map_cbm, map_shift};
wire [63:0] mod_hold = (mods[0] ? (64'd1 << shift_key) : 64'd0)
                     | (mods[1] ? (64'd1 << cbm_key)   : 64'd0)
                     | (mods[2] ? (64'd1 << ctrl_key)  : 64'd0);

initial begin
    map_code = 0;
    matrix   = 0;
end

always @(posedge clk) begin
    if (!rst) begin
        state <= S_IDLE; matrix <= 64'd0; map_code <= 8'd0;
        timer <= 0; since_rel <= {21{1'b1}};
        last_key <= 0; have_last <= 0; cur_mod <= 0; pend <= 3'd0; pop <= 0;
    end else begin
        pop <= 1'b0;
        if (since_rel != {21{1'b1}})
            since_rel <= since_rel + 1'b1;

        case (state)
        S_IDLE: if (count != 0 && !pop) begin
            map_code <= fifo[rptr];
            pop   <= 1'b1;
            state <= S_MAP;
        end

        S_MAP: begin   // mapper result for map_code is valid now
            if (!map_valid)
                state <= S_IDLE;                       // unknown byte: skip
            else if (map_prefix) begin                 // arms the next key
                pend  <= mods;
                state <= S_IDLE;
            end
            else if (have_last && map_key == last_key && since_rel < GAP_CYC)
                state <= S_GAP;                        // same key again: pause
            else begin
                cur_mod <= |mods;
                pend    <= 3'd0;
                if (|mods) begin                       // modifiers lead the key
                    matrix <= mod_hold;
                    timer <= LEAD_CYC;
                    state <= S_LEAD;
                end else begin
                    matrix[map_key] <= 1'b1;
                    timer <= HOLD_CYC;
                    state <= S_PRESS;
                end
            end
        end

        S_GAP: if (since_rel >= GAP_CYC) begin
            cur_mod <= |mods;
            pend    <= 3'd0;
            if (|mods) begin
                matrix <= mod_hold;
                timer <= LEAD_CYC;
                state <= S_LEAD;
            end else begin
                matrix[map_key] <= 1'b1;
                timer <= HOLD_CYC;
                state <= S_PRESS;
            end
        end

        S_LEAD: begin                    // modifiers held alone before the key
            timer <= timer - 1'b1;
            if (timer == 21'd1) begin
                matrix[map_key] <= 1'b1;
                timer <= HOLD_CYC;
                state <= S_PRESS;
            end
        end

        S_PRESS: begin
            timer <= timer - 1'b1;
            if (timer == 21'd1) begin
                matrix[map_key] <= 1'b0;   // key up; modifiers may linger
                last_key  <= map_key;
                have_last <= 1'b1;
                since_rel <= 21'd0;
                timer <= LEAD_CYC;
                state <= cur_mod ? S_LAG : S_IDLE;
            end
        end

        S_LAG: begin                     // modifiers trail the key ...
            timer <= timer - 1'b1;
            if (timer == 21'd1) begin
                matrix <= 64'd0;
                timer <= LEAD_CYC;
                state <= S_POST;
            end
        end

        S_POST: begin                    // ... and the next key waits a bit
            timer <= timer - 1'b1;       // so no scan pairs it with them
            if (timer == 21'd1)
                state <= S_IDLE;
        end
        endcase
    end
end

endmodule
