/*
 * spectrum_keyboard.v — ZX Spectrum keyboard matrix with UART bridge
 *
 * The Spectrum keyboard is an 8x5 matrix of 40 keys.
 * The CPU reads port $FE with address lines A8-A15 selecting half-rows:
 *   A8=0  → half-row 0: SHIFT, Z, X, C, V
 *   A9=0  → half-row 1: A, S, D, F, G
 *   A10=0 → half-row 2: Q, W, E, R, T
 *   A11=0 → half-row 3: 1, 2, 3, 4, 5
 *   A12=0 → half-row 4: 0, 9, 8, 7, 6
 *   A13=0 → half-row 5: P, O, I, U, Y
 *   A14=0 → half-row 6: ENTER, L, K, J, H
 *   A15=0 → half-row 7: SPACE, SYMSHIFT, M, N, B
 *
 * Multiple address lines can be low simultaneously (accent OR of rows).
 * Data bits 0-4 return column state (0=pressed, accent active low).
 *
 * This module receives ASCII from UART and simulates key press/release
 * by setting the appropriate row/column bits in the matrix.
 */

module spectrum_keyboard(
    input             clk,
    input             rst,

    // UART received byte (active accent accent accent)
    input       [7:0] uart_rx_data,
    input             uart_rx_valid,   // toggles on each byte received

    // Keyboard matrix read
    input       [7:0] halfrow_sel,   // A15-A8 (active low selects row)
    output reg  [4:0] key_columns    // column bits (active low = pressed)
);

/* ── Key matrix state: 8 half-rows × 5 columns ────────────────────────── */
/* key_matrix[row][col] = 1 means key is pressed */
reg [4:0] key_matrix [0:7];
reg       caps_shift;    // CAPS SHIFT held (half-row 0, col 0)
reg       sym_shift;     // SYMBOL SHIFT held (half-row 7, col 1)

/* ── Key hold timer ────────────────────────────────────────────────────── */
/* Hold key just long enough for the ROM to see it in one scan.
 * The ROM scans the keyboard during the interrupt handler (~every 20ms).
 * At 50 MHz: one frame = 1,000,000 clocks. Hold for ~1.5 frames. */
reg [20:0] key_timer;
wire       key_held = (key_timer != 0);

/* ── Edge detect on UART rx (rxen toggles, so detect any change) ───── */
reg prev_uart_rx_valid;
wire uart_rx_pulse = (uart_rx_valid != prev_uart_rx_valid);

always @(posedge clk) begin
    if (!rst)
        prev_uart_rx_valid <= 0;
    else
        prev_uart_rx_valid <= uart_rx_valid;
end

/* ── UART to matrix mapping ────────────────────────────────────────────── */
reg [2:0] press_row;
reg [2:0] press_col;
reg       press_caps;
reg       press_sym;
reg       press_valid;

always @(*) begin
    press_row   = 0;
    press_col   = 0;
    press_caps  = 0;
    press_sym   = 0;
    press_valid = 0;

    if (uart_rx_pulse) begin
        press_valid = 1;
        case (uart_rx_data)
            /* ── Letters (accent lower case maps to uppercase on Spectrum) ── */
            "a","A": begin press_row = 1; press_col = 0; end
            "b","B": begin press_row = 7; press_col = 4; end
            "c","C": begin press_row = 0; press_col = 3; end
            "d","D": begin press_row = 1; press_col = 2; end
            "e","E": begin press_row = 2; press_col = 2; end
            "f","F": begin press_row = 1; press_col = 3; end
            "g","G": begin press_row = 1; press_col = 4; end
            "h","H": begin press_row = 6; press_col = 4; end
            "i","I": begin press_row = 5; press_col = 2; end
            "j","J": begin press_row = 6; press_col = 3; end
            "k","K": begin press_row = 6; press_col = 2; end
            "l","L": begin press_row = 6; press_col = 1; end
            "m","M": begin press_row = 7; press_col = 2; end
            "n","N": begin press_row = 7; press_col = 3; end
            "o","O": begin press_row = 5; press_col = 1; end
            "p","P": begin press_row = 5; press_col = 0; end
            "q","Q": begin press_row = 2; press_col = 0; end
            "r","R": begin press_row = 2; press_col = 3; end
            "s","S": begin press_row = 1; press_col = 1; end
            "t","T": begin press_row = 2; press_col = 4; end
            "u","U": begin press_row = 5; press_col = 3; end
            "v","V": begin press_row = 0; press_col = 4; end
            "w","W": begin press_row = 2; press_col = 1; end
            "x","X": begin press_row = 0; press_col = 2; end
            "y","Y": begin press_row = 5; press_col = 4; end
            "z","Z": begin press_row = 0; press_col = 1; end

            /* ── Numbers ── */
            "0": begin press_row = 4; press_col = 0; end
            "1": begin press_row = 3; press_col = 0; end
            "2": begin press_row = 3; press_col = 1; end
            "3": begin press_row = 3; press_col = 2; end
            "4": begin press_row = 3; press_col = 3; end
            "5": begin press_row = 3; press_col = 4; end
            "6": begin press_row = 4; press_col = 4; end
            "7": begin press_row = 4; press_col = 3; end
            "8": begin press_row = 4; press_col = 2; end
            "9": begin press_row = 4; press_col = 1; end

            /* ── Special keys ── */
            8'h0D: begin press_row = 6; press_col = 0; end  // ENTER
            " ":   begin press_row = 7; press_col = 0; end  // SPACE
            8'h08: begin press_row = 4; press_col = 0; press_caps = 1; end  // Backspace = CAPS+0 (DELETE)

            /* ── Symbol shift combos (punctuation) ── */
            "!": begin press_row = 3; press_col = 0; press_sym = 1; end  // SYM+1
            "@": begin press_row = 3; press_col = 1; press_sym = 1; end  // SYM+2
            "#": begin press_row = 3; press_col = 2; press_sym = 1; end  // SYM+3
            "$": begin press_row = 3; press_col = 3; press_sym = 1; end  // SYM+4
            "%": begin press_row = 3; press_col = 4; press_sym = 1; end  // SYM+5
            "&": begin press_row = 4; press_col = 4; press_sym = 1; end  // SYM+6
            "'": begin press_row = 4; press_col = 3; press_sym = 1; end  // SYM+7
            "(": begin press_row = 4; press_col = 2; press_sym = 1; end  // SYM+8
            ")": begin press_row = 4; press_col = 1; press_sym = 1; end  // SYM+9
            "_": begin press_row = 4; press_col = 0; press_sym = 1; end  // SYM+0
            "+": begin press_row = 6; press_col = 2; press_sym = 1; end  // SYM+K
            "-": begin press_row = 6; press_col = 3; press_sym = 1; end  // SYM+J
            "*": begin press_row = 7; press_col = 4; press_sym = 1; end  // SYM+B
            "/": begin press_row = 0; press_col = 4; press_sym = 1; end  // SYM+V
            "=": begin press_row = 6; press_col = 1; press_sym = 1; end  // SYM+L
            "<": begin press_row = 2; press_col = 3; press_sym = 1; end  // SYM+R
            ">": begin press_row = 2; press_col = 4; press_sym = 1; end  // SYM+T
            ";": begin press_row = 5; press_col = 1; press_sym = 1; end  // SYM+O
            ":": begin press_row = 0; press_col = 1; press_sym = 1; end  // SYM+Z
            "\"":begin press_row = 5; press_col = 0; press_sym = 1; end  // SYM+P
            ",": begin press_row = 7; press_col = 3; press_sym = 1; end  // SYM+N
            ".": begin press_row = 7; press_col = 2; press_sym = 1; end  // SYM+M
            "?": begin press_row = 0; press_col = 3; press_sym = 1; end  // SYM+C

            default: press_valid = 0;
        endcase
    end
end

/* ── Key press/release state machine ───────────────────────────────────── */
integer i;

always @(posedge clk) begin
    if (!rst) begin
        for (i = 0; i < 8; i = i + 1)
            key_matrix[i] <= 5'b00000;
        caps_shift <= 0;
        sym_shift  <= 0;
        key_timer  <= 0;
    end else begin
        /* Count down key hold timer */
        if (key_timer != 0)
            key_timer <= key_timer - 1;

        /* On timer expiry, release all keys */
        if (key_timer == 1) begin
            for (i = 0; i < 8; i = i + 1)
                key_matrix[i] <= 5'b00000;
            caps_shift <= 0;
            sym_shift  <= 0;
        end

        /* New key press from UART */
        if (press_valid && !key_held) begin
            key_matrix[press_row][press_col] <= 1;
            caps_shift <= press_caps;
            sym_shift  <= press_sym;
            key_timer  <= 21'd1500000;  // hold for ~1.5 frames at 50 MHz
        end
    end
end

/* ── Matrix readout: combine selected half-rows ────────────────────────── */
/* A low bit in halfrow_sel selects that row. Multiple rows can be selected.
 * Result is OR of all selected rows, then inverted (active low output). */

always @(*) begin
    reg [4:0] combined;
    combined = 5'b00000;

    if (!halfrow_sel[0]) combined = combined | key_matrix[0] | {4'b0, caps_shift};
    if (!halfrow_sel[1]) combined = combined | key_matrix[1];
    if (!halfrow_sel[2]) combined = combined | key_matrix[2];
    if (!halfrow_sel[3]) combined = combined | key_matrix[3];
    if (!halfrow_sel[4]) combined = combined | key_matrix[4];
    if (!halfrow_sel[5]) combined = combined | key_matrix[5];
    if (!halfrow_sel[6]) combined = combined | key_matrix[6];
    if (!halfrow_sel[7]) combined = combined | key_matrix[7] | {3'b0, sym_shift, 1'b0};

    key_columns = ~combined;  // active low
end

endmodule
