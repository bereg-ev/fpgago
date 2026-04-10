/*
 * pet_keyboard.v — PIA1 (6520) emulation with CB1 vertical retrace IRQ
 *
 * The PET uses PIA1 for keyboard scanning and vertical retrace IRQ:
 *
 * Keyboard scanning:
 *   Port A lower nibble selects the keyboard row via a 74145 decoder:
 *     porta[3:0] = 0: no row (used for "any key" check — OR of all rows)
 *     porta[3:0] = 1: row 0  (table offset 0-7)
 *     porta[3:0] = 2: row 1  (table offset 8-15)
 *     ...
 *     porta[3:0] = 10: row 9 (table offset 72-79)
 *   Port B returns column states (0 = key pressed, active-low)
 *
 * The keyboard decode table at $E6F7 in the editor ROM maps
 * (row * 8 + col) to PETSCII codes.  The mapping below is derived
 * directly from that table:
 *
 *        PB0    PB1    PB2    PB3    PB4    PB5    PB6    PB7
 *  R0:    `      =      .    (n/u)   x03    <     SPC     [
 *  R1:   RVS     -      0    STOP    >     (n/u)   ]      @
 *  R2:   STOP    +      2    (n/u)   ?      ,      N      V
 *  R3:    X      3      1     RET    ;      M      B      C
 *  R4:    Z      *      5    (n/u)   :      K      H      F
 *  R5:    S      6      4    (n/u)   L      J      G      D
 *  R6:    A      /      8    (n/u)   P      I      Y      R
 *  R7:    W      9      7     ^      O      U      T      E
 *  R8:    Q     DEL   DOWN  (n/u)    )      \      '      $
 *  R9:    "    RIGHT  HOME    _      (      &      %      #
 */

module pet_keyboard(
    input clk,
    input rst,
    input [3:0] addr,
    input [7:0] din,
    output reg [7:0] dout,
    input we,
    input rd,
    input [7:0] uart_rx_data,
    input uart_rx_valid,
    input cb1,
    output irq
);

    reg [7:0] ddra, ddrb;
    reg [7:0] porta;
    reg [7:0] cra, crb;
    reg cb1_prev;
    reg irq_flag_b1;

    assign irq = irq_flag_b1 & crb[0];

    // Keyboard matrix: 10 rows × 8 columns
    reg [7:0] key_matrix [0:9];
    reg [15:0] key_timer;

    integer i;

    // ── ASCII → PET matrix lookup (from ROM table at $E6F7) ──────────
    reg [3:0] map_row;
    reg [2:0] map_col;
    reg       map_valid;
    reg       map_shift;

    always @* begin
        map_valid = 1;
        map_shift = 0;
        map_row   = 0;
        map_col   = 0;
        case (uart_rx_data)
            // Letters (lowercase ASCII → unshifted PET position)
            8'h61: begin map_row=6; map_col=0; end  // a
            8'h62: begin map_row=3; map_col=6; end  // b
            8'h63: begin map_row=3; map_col=7; end  // c
            8'h64: begin map_row=5; map_col=7; end  // d
            8'h65: begin map_row=7; map_col=7; end  // e
            8'h66: begin map_row=4; map_col=7; end  // f
            8'h67: begin map_row=5; map_col=6; end  // g
            8'h68: begin map_row=4; map_col=6; end  // h
            8'h69: begin map_row=6; map_col=5; end  // i
            8'h6A: begin map_row=5; map_col=5; end  // j
            8'h6B: begin map_row=4; map_col=5; end  // k
            8'h6C: begin map_row=5; map_col=4; end  // l
            8'h6D: begin map_row=3; map_col=5; end  // m
            8'h6E: begin map_row=2; map_col=6; end  // n
            8'h6F: begin map_row=7; map_col=4; end  // o
            8'h70: begin map_row=6; map_col=4; end  // p
            8'h71: begin map_row=8; map_col=0; end  // q
            8'h72: begin map_row=6; map_col=7; end  // r
            8'h73: begin map_row=5; map_col=0; end  // s
            8'h74: begin map_row=7; map_col=6; end  // t
            8'h75: begin map_row=7; map_col=5; end  // u
            8'h76: begin map_row=2; map_col=7; end  // v
            8'h77: begin map_row=7; map_col=0; end  // w
            8'h78: begin map_row=3; map_col=0; end  // x
            8'h79: begin map_row=6; map_col=6; end  // y
            8'h7A: begin map_row=4; map_col=0; end  // z
            // Uppercase → same position + shift
            8'h41: begin map_row=6; map_col=0; map_shift=1; end  // A
            8'h42: begin map_row=3; map_col=6; map_shift=1; end  // B
            8'h43: begin map_row=3; map_col=7; map_shift=1; end  // C
            8'h44: begin map_row=5; map_col=7; map_shift=1; end  // D
            8'h45: begin map_row=7; map_col=7; map_shift=1; end  // E
            8'h46: begin map_row=4; map_col=7; map_shift=1; end  // F
            8'h47: begin map_row=5; map_col=6; map_shift=1; end  // G
            8'h48: begin map_row=4; map_col=6; map_shift=1; end  // H
            8'h49: begin map_row=6; map_col=5; map_shift=1; end  // I
            8'h4A: begin map_row=5; map_col=5; map_shift=1; end  // J
            8'h4B: begin map_row=4; map_col=5; map_shift=1; end  // K
            8'h4C: begin map_row=5; map_col=4; map_shift=1; end  // L
            8'h4D: begin map_row=3; map_col=5; map_shift=1; end  // M
            8'h4E: begin map_row=2; map_col=6; map_shift=1; end  // N
            8'h4F: begin map_row=7; map_col=4; map_shift=1; end  // O
            8'h50: begin map_row=6; map_col=4; map_shift=1; end  // P
            8'h51: begin map_row=8; map_col=0; map_shift=1; end  // Q
            8'h52: begin map_row=6; map_col=7; map_shift=1; end  // R
            8'h53: begin map_row=5; map_col=0; map_shift=1; end  // S
            8'h54: begin map_row=7; map_col=6; map_shift=1; end  // T
            8'h55: begin map_row=7; map_col=5; map_shift=1; end  // U
            8'h56: begin map_row=2; map_col=7; map_shift=1; end  // V
            8'h57: begin map_row=7; map_col=0; map_shift=1; end  // W
            8'h58: begin map_row=3; map_col=0; map_shift=1; end  // X
            8'h59: begin map_row=6; map_col=6; map_shift=1; end  // Y
            8'h5A: begin map_row=4; map_col=0; map_shift=1; end  // Z
            // Digits
            8'h30: begin map_row=1; map_col=2; end  // 0
            8'h31: begin map_row=3; map_col=2; end  // 1
            8'h32: begin map_row=2; map_col=2; end  // 2
            8'h33: begin map_row=3; map_col=1; end  // 3
            8'h34: begin map_row=5; map_col=2; end  // 4
            8'h35: begin map_row=4; map_col=2; end  // 5
            8'h36: begin map_row=5; map_col=1; end  // 6
            8'h37: begin map_row=7; map_col=2; end  // 7
            8'h38: begin map_row=6; map_col=2; end  // 8
            8'h39: begin map_row=7; map_col=1; end  // 9
            // Symbols
            8'h20: begin map_row=0; map_col=6; end  // SPACE
            8'h0D: begin map_row=3; map_col=3; end  // RETURN
            8'h2C: begin map_row=2; map_col=5; end  // ,
            8'h2E: begin map_row=0; map_col=2; end  // .
            8'h2F: begin map_row=6; map_col=1; end  // /
            8'h3B: begin map_row=3; map_col=4; end  // ;
            8'h3A: begin map_row=4; map_col=4; end  // :
            8'h40: begin map_row=1; map_col=7; end  // @
            8'h2B: begin map_row=2; map_col=1; end  // +
            8'h2D: begin map_row=1; map_col=1; end  // -
            8'h2A: begin map_row=4; map_col=1; end  // *
            8'h3D: begin map_row=0; map_col=1; end  // =
            8'h3F: begin map_row=2; map_col=4; end  // ?
            8'h3C: begin map_row=0; map_col=5; end  // <
            8'h3E: begin map_row=1; map_col=4; end  // >
            8'h5B: begin map_row=0; map_col=7; end  // [
            8'h5D: begin map_row=1; map_col=6; end  // ]
            8'h22: begin map_row=9; map_col=0; end  // "
            8'h23: begin map_row=9; map_col=7; end  // #
            8'h24: begin map_row=8; map_col=7; end  // $
            8'h25: begin map_row=9; map_col=6; end  // %
            8'h26: begin map_row=9; map_col=5; end  // &
            8'h27: begin map_row=8; map_col=6; end  // '
            8'h28: begin map_row=9; map_col=4; end  // (
            8'h29: begin map_row=8; map_col=4; end  // )
            8'h5C: begin map_row=8; map_col=5; end  // backslash
            8'h5E: begin map_row=7; map_col=3; end  // ^
            8'h21: begin map_row=9; map_col=0; map_shift=1; end  // ! (shift+")
            // Control keys
            8'h08: begin map_row=8; map_col=1; end  // Backspace → DEL
            8'h7F: begin map_row=8; map_col=1; end  // DEL
            default: map_valid = 0;
        endcase
    end

    // Left SHIFT is not in the decode table — it's detected separately
    // by the KERNAL scan code checking a specific matrix position.
    // From the PET schematic, LSHIFT is at the position that the KERNAL
    // checks via a BIT test.  Looking at the scan code, the shift state
    // is stored in $98 bit 0.  The scan detects shift when table entry
    // is $01.  There's no $01 in our table, so shift must be on a
    // separate wire or detected outside the matrix.
    //
    // On the PET 2001, SHIFT is detected by checking if ANY column is
    // active when row 8/9 special positions are scanned.  The shift
    // flag is set by the scan code at $E6A1 when it finds key code $01.
    //
    // For our UART-to-matrix bridge, when map_shift=1, we need to make
    // the KERNAL detect a shift state.  The simplest approach: set a
    // bit in key_matrix that maps to a known shift-like position.
    // Looking at the scan code around $E6CF: `46 98` = LSR $98
    // (shift flag right into carry), `90 02` = BCC (if no shift).
    // $98 is the key-shift flag.  It's set to 1 when the table lookup
    // returns $01, and combined via `09 80` = ORA #$80.
    //
    // There's no table entry $01 in our ROM table.  The PET KERNAL
    // detects shift by reading row 8 directly — specifically, LSHIFT
    // is wired to a separate input.  For simplicity, we'll handle shift
    // by setting $98 directly... but we can't write to CPU RAM from here.
    //
    // Alternative: PET KERNAL checks for shift via the keyboard matrix.
    // Let me just not support shift for now — the PET accepts uppercase
    // letters directly since it's the default mode.

    // ── Key press/release + CB1 edge detection ───────────────────────
    always @(posedge clk or negedge rst)
        if (!rst) begin
            for (i = 0; i < 10; i = i + 1)
                key_matrix[i] <= 8'h00;
            key_timer   <= 0;
            ddra        <= 8'h00;
            ddrb        <= 8'h00;
            porta       <= 8'hFF;
            cra         <= 8'h00;
            crb         <= 8'h00;
            cb1_prev    <= 1'b1;
            irq_flag_b1 <= 1'b0;
        end else begin
            // Key auto-release
            if (key_timer > 0) begin
                key_timer <= key_timer - 1;
                if (key_timer == 1)
                    for (i = 0; i < 10; i = i + 1)
                        key_matrix[i] <= 8'h00;
            end

            // New key from UART
            if (uart_rx_valid && map_valid) begin
                key_matrix[map_row][map_col] <= 1'b1;
                key_timer <= 16'd50000;
            end

            // CB1 edge detection
            cb1_prev <= cb1;
            if (crb[1] ? (cb1 && !cb1_prev) : (!cb1 && cb1_prev))
                irq_flag_b1 <= 1'b1;

            // PIA register writes
            if (we) begin
                case (addr[1:0])
                    2'd0: begin
                        if (cra[2]) porta <= din;
                        else        ddra  <= din;
                    end
                    2'd1: cra <= din;
                    2'd2: begin
                        if (!crb[2]) ddrb <= din;
                    end
                    2'd3: crb <= din;
                endcase
            end

            // Reading Port B clears CB1 IRQ flag
            if (rd && addr[1:0] == 2'd2 && crb[2])
                irq_flag_b1 <= 1'b0;
        end

    // ── Keyboard matrix scan ─────────────────────────────────────────
    // The PET KERNAL selects rows via porta[3:0] as a binary number:
    //   porta[3:0] = 0: "any key" check (OR of ALL rows)
    //   porta[3:0] = 1: row 0
    //   porta[3:0] = 2: row 1
    //   ...
    //   porta[3:0] = 10: row 9
    // The 74145 BCD-to-decimal decoder on the real PET converts the
    // 4-bit value to a one-hot row select.

    wire [3:0] row_sel = porta[3:0];

    reg [7:0] scanned_cols;
    always @* begin
        if (row_sel == 4'd0) begin
            // All rows — "any key pressed?" check
            scanned_cols = 8'h00;
            for (i = 0; i < 10; i = i + 1)
                scanned_cols = scanned_cols | key_matrix[i];
        end else if (row_sel <= 4'd10) begin
            scanned_cols = key_matrix[row_sel - 1];
        end else begin
            scanned_cols = 8'h00;
        end
    end

    // PIA1 data out mux
    always @* begin
        case (addr[1:0])
            2'd0: dout = cra[2] ? (porta | ~ddra) : ddra;
            2'd1: dout = {irq_flag_b1, 1'b0, cra[5:0]};
            2'd2: dout = crb[2] ? ~scanned_cols : ddrb;
            2'd3: dout = {irq_flag_b1, 1'b0, crb[5:0]};
        endcase
    end

endmodule
