/*
 * pet_keyboard.v — PIA1 (6520) emulation with CB1 vertical retrace IRQ
 *
 * Keyboard scanning:
 *   Port A lower nibble selects the row via a 74145 BCD decoder:
 *     porta[3:0] = 0: no row (any-key check returns no keys)
 *     porta[3:0] = 1..9: row 0..8 of the keyboard matrix
 *   Port B returns column states (0 = key pressed, active-low)
 *
 * The key→matrix mapping is derived from the ROM decode table at $E6F7.
 * The KERNAL's scan loop starts X at 80, uses 8 for the any-key check,
 * then scans rows with X = 72 down to 1.  For physical row R and
 * Port B bit C, the table index is: X = 72 - R*8 - C.
 *
 * Physical matrix (rows 0-8, columns PB0-PB7):
 *
 *        PB0   PB1   PB2   PB3   PB4   PB5   PB6   PB7
 *  R0:    "     $     '     \     )    (n/u)  DOWN   DEL
 *  R1:    Q     E     T     U     O     ^      7     9
 *  R2:    W     R     Y     I     P    (n/u)   8     /
 *  R3:    A     D     G     J     L    (n/u)   4     6
 *  R4:    S     F     H     K     :    (n/u)   5     *
 *  R5:    Z     C     B     M     ;    RET     1     3
 *  R6:    X     V     N     ,     ?    (n/u)   2     +
 *  R7:   STOP   @     ]    (n/u)  >    STOP    0     -
 *  R8:   RVS    [    SPC    <    x03   (n/u)   .     =
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

    reg [7:0] key_matrix [0:8];   // 9 rows × 8 columns
    reg [15:0] key_timer;

    integer i;

    // ── ASCII → PET matrix (from ROM table, X = 72 - row*8 - col) ───
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
            // Letters
            8'h61: begin map_row=3; map_col=0; end  // a
            8'h62: begin map_row=5; map_col=2; end  // b
            8'h63: begin map_row=5; map_col=1; end  // c
            8'h64: begin map_row=3; map_col=1; end  // d
            8'h65: begin map_row=1; map_col=1; end  // e
            8'h66: begin map_row=4; map_col=1; end  // f
            8'h67: begin map_row=3; map_col=2; end  // g
            8'h68: begin map_row=4; map_col=2; end  // h
            8'h69: begin map_row=2; map_col=3; end  // i
            8'h6A: begin map_row=3; map_col=3; end  // j
            8'h6B: begin map_row=4; map_col=3; end  // k
            8'h6C: begin map_row=3; map_col=4; end  // l
            8'h6D: begin map_row=5; map_col=3; end  // m
            8'h6E: begin map_row=6; map_col=2; end  // n
            8'h6F: begin map_row=1; map_col=4; end  // o
            8'h70: begin map_row=2; map_col=4; end  // p
            8'h71: begin map_row=1; map_col=0; end  // q
            8'h72: begin map_row=2; map_col=1; end  // r
            8'h73: begin map_row=4; map_col=0; end  // s
            8'h74: begin map_row=1; map_col=2; end  // t
            8'h75: begin map_row=1; map_col=3; end  // u
            8'h76: begin map_row=6; map_col=1; end  // v
            8'h77: begin map_row=2; map_col=0; end  // w
            8'h78: begin map_row=6; map_col=0; end  // x
            8'h79: begin map_row=2; map_col=2; end  // y
            8'h7A: begin map_row=5; map_col=0; end  // z
            // Uppercase → same + shift
            8'h41: begin map_row=3; map_col=0; map_shift=1; end  // A
            8'h42: begin map_row=5; map_col=2; map_shift=1; end  // B
            8'h43: begin map_row=5; map_col=1; map_shift=1; end  // C
            8'h44: begin map_row=3; map_col=1; map_shift=1; end  // D
            8'h45: begin map_row=1; map_col=1; map_shift=1; end  // E
            8'h46: begin map_row=4; map_col=1; map_shift=1; end  // F
            8'h47: begin map_row=3; map_col=2; map_shift=1; end  // G
            8'h48: begin map_row=4; map_col=2; map_shift=1; end  // H
            8'h49: begin map_row=2; map_col=3; map_shift=1; end  // I
            8'h4A: begin map_row=3; map_col=3; map_shift=1; end  // J
            8'h4B: begin map_row=4; map_col=3; map_shift=1; end  // K
            8'h4C: begin map_row=3; map_col=4; map_shift=1; end  // L
            8'h4D: begin map_row=5; map_col=3; map_shift=1; end  // M
            8'h4E: begin map_row=6; map_col=2; map_shift=1; end  // N
            8'h4F: begin map_row=1; map_col=4; map_shift=1; end  // O
            8'h50: begin map_row=2; map_col=4; map_shift=1; end  // P
            8'h51: begin map_row=1; map_col=0; map_shift=1; end  // Q
            8'h52: begin map_row=2; map_col=1; map_shift=1; end  // R
            8'h53: begin map_row=4; map_col=0; map_shift=1; end  // S
            8'h54: begin map_row=1; map_col=2; map_shift=1; end  // T
            8'h55: begin map_row=1; map_col=3; map_shift=1; end  // U
            8'h56: begin map_row=6; map_col=1; map_shift=1; end  // V
            8'h57: begin map_row=2; map_col=0; map_shift=1; end  // W
            8'h58: begin map_row=6; map_col=0; map_shift=1; end  // X
            8'h59: begin map_row=2; map_col=2; map_shift=1; end  // Y
            8'h5A: begin map_row=5; map_col=0; map_shift=1; end  // Z
            // Digits
            8'h30: begin map_row=7; map_col=6; end  // 0
            8'h31: begin map_row=5; map_col=6; end  // 1
            8'h32: begin map_row=6; map_col=6; end  // 2
            8'h33: begin map_row=5; map_col=7; end  // 3
            8'h34: begin map_row=3; map_col=6; end  // 4
            8'h35: begin map_row=4; map_col=6; end  // 5
            8'h36: begin map_row=3; map_col=7; end  // 6
            8'h37: begin map_row=1; map_col=6; end  // 7
            8'h38: begin map_row=2; map_col=6; end  // 8
            8'h39: begin map_row=1; map_col=7; end  // 9
            // Control
            8'h0D: begin map_row=5; map_col=5; end  // RETURN
            8'h20: begin map_row=8; map_col=2; end  // SPACE
            8'h08: begin map_row=0; map_col=7; end  // Backspace → DEL
            8'h7F: begin map_row=0; map_col=7; end  // DEL
            // Symbols
            8'h22: begin map_row=0; map_col=0; end  // "
            8'h24: begin map_row=0; map_col=1; end  // $
            8'h27: begin map_row=0; map_col=2; end  // '
            8'h28: begin map_row=0; map_col=4; end  // (
            8'h29: begin map_row=0; map_col=4; end  // )
            8'h2A: begin map_row=4; map_col=7; end  // *
            8'h2B: begin map_row=6; map_col=7; end  // +
            8'h2C: begin map_row=6; map_col=3; end  // ,
            8'h2D: begin map_row=7; map_col=7; end  // -
            8'h2E: begin map_row=8; map_col=6; end  // .
            8'h2F: begin map_row=2; map_col=7; end  // /
            8'h3A: begin map_row=4; map_col=4; end  // :
            8'h3B: begin map_row=5; map_col=4; end  // ;
            8'h3C: begin map_row=8; map_col=3; end  // <
            8'h3D: begin map_row=8; map_col=7; end  // =
            8'h3E: begin map_row=7; map_col=4; end  // >
            8'h3F: begin map_row=6; map_col=4; end  // ?
            8'h40: begin map_row=7; map_col=1; end  // @
            8'h5B: begin map_row=8; map_col=1; end  // [
            8'h5C: begin map_row=0; map_col=3; end  // backslash
            8'h5D: begin map_row=7; map_col=2; end  // ]
            8'h5E: begin map_row=1; map_col=5; end  // ^
            default: map_valid = 0;
        endcase
    end

    // ── Key press/release + CB1 edge detection ───────────────────────
    always @(posedge clk or negedge rst)
        if (!rst) begin
            for (i = 0; i < 9; i = i + 1)
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
            if (key_timer > 0) begin
                key_timer <= key_timer - 1;
                if (key_timer == 1)
                    for (i = 0; i < 9; i = i + 1)
                        key_matrix[i] <= 8'h00;
            end

            if (uart_rx_valid && map_valid && map_row < 9) begin
                key_matrix[map_row][map_col] <= 1'b1;
                key_timer <= 16'd50000;
            end

            cb1_prev <= cb1;
            if (crb[1] ? (cb1 && !cb1_prev) : (!cb1 && cb1_prev))
                irq_flag_b1 <= 1'b1;

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

            if (rd && addr[1:0] == 2'd2 && crb[2])
                irq_flag_b1 <= 1'b0;
        end

    // ── Keyboard scan ────────────────────────────────────────────────
    // porta[3:0] is a binary row number (1-9 = rows 0-8, 0 = no row)
    wire [3:0] row_sel = porta[3:0];

    reg [7:0] scanned_cols;
    always @* begin
        if (row_sel >= 4'd1 && row_sel <= 4'd9)
            scanned_cols = key_matrix[row_sel - 1];
        else
            scanned_cols = 8'h00;  // row 0 or >9: no keys
    end

    // ── PIA1 read mux ────────────────────────────────────────────────
    always @* begin
        case (addr[1:0])
            2'd0: dout = cra[2] ? (porta | ~ddra) : ddra;
            2'd1: dout = {irq_flag_b1, 1'b0, cra[5:0]};
            2'd2: dout = crb[2] ? ~scanned_cols : ddrb;
            2'd3: dout = {irq_flag_b1, 1'b0, crb[5:0]};
        endcase
    end

endmodule
