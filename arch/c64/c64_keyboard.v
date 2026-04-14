/*
 * c64_keyboard.v — C64 keyboard matrix with UART bridge
 *
 * C64 keyboard matrix:
 *        Col0    Col1    Col2    Col3    Col4    Col5    Col6    Col7
 * Row0:  DEL     RETURN  CRS-R   F7      F1      F3      F5      CRS-DN
 * Row1:  3       W       A       4       Z       S       E       LSHIFT
 * Row2:  5       R       D       6       C       F       T       X
 * Row3:  7       Y       G       8       B       H       U       V
 * Row4:  9       I       J       0       M       K       O       N
 * Row5:  +       P       L       -       .       :       @       ,
 * Row6:  POUND   *       ;       HOME    RSHIFT  =       ^       /
 * Row7:  1       <-      CTRL    2       SPACE   C=      Q       STOP
 */

module c64_keyboard(
    input             clk,
    input             rst,
    input       [7:0] uart_rx_data,
    input             uart_rx_valid,
    input       [7:0] row_select,
    output reg  [7:0] col_result
);

/* ── Edge detect UART (rxen toggles per byte) ──────────────────────────── */
reg prev_uart_valid;
wire uart_pulse = (uart_rx_valid != prev_uart_valid);
always @(posedge clk) begin
    if (!rst) prev_uart_valid <= 0;
    else prev_uart_valid <= uart_rx_valid;
end

/* ── Key state ─────────────────────────────────────────────────────────── */
reg [2:0] key_row;
reg [2:0] key_col;
reg       key_active;
reg [19:0] key_hold;  // hold counter

always @(posedge clk) begin
    if (!rst) begin
        key_active <= 0;
        key_hold   <= 0;
    end else begin
        /* Count down hold timer */
        if (key_hold != 0)
            key_hold <= key_hold - 1;

        /* Release key when timer expires */
        if (key_hold == 1)
            key_active <= 0;

        /* Accept new key only when previous is released */
        if (uart_pulse && !key_active) begin
            key_active <= 1;
            key_hold   <= 20'd500000;  // hold for 500K clocks (~10ms)
            case (uart_rx_data)
                "1":     begin key_row <= 7; key_col <= 0; end
                "2":     begin key_row <= 7; key_col <= 3; end
                "3":     begin key_row <= 1; key_col <= 0; end
                "4":     begin key_row <= 1; key_col <= 3; end
                "5":     begin key_row <= 2; key_col <= 0; end
                "6":     begin key_row <= 2; key_col <= 3; end
                "7":     begin key_row <= 3; key_col <= 0; end
                "8":     begin key_row <= 3; key_col <= 3; end
                "9":     begin key_row <= 4; key_col <= 0; end
                "0":     begin key_row <= 4; key_col <= 3; end
                "a","A": begin key_row <= 1; key_col <= 2; end
                "b","B": begin key_row <= 3; key_col <= 4; end
                "c","C": begin key_row <= 2; key_col <= 4; end
                "d","D": begin key_row <= 2; key_col <= 2; end
                "e","E": begin key_row <= 1; key_col <= 6; end
                "f","F": begin key_row <= 2; key_col <= 5; end
                "g","G": begin key_row <= 3; key_col <= 2; end
                "h","H": begin key_row <= 3; key_col <= 5; end
                "i","I": begin key_row <= 4; key_col <= 1; end
                "j","J": begin key_row <= 4; key_col <= 2; end
                "k","K": begin key_row <= 4; key_col <= 5; end
                "l","L": begin key_row <= 5; key_col <= 2; end
                "m","M": begin key_row <= 4; key_col <= 4; end
                "n","N": begin key_row <= 4; key_col <= 7; end
                "o","O": begin key_row <= 4; key_col <= 6; end
                "p","P": begin key_row <= 5; key_col <= 1; end
                "q","Q": begin key_row <= 7; key_col <= 6; end
                "r","R": begin key_row <= 2; key_col <= 1; end
                "s","S": begin key_row <= 1; key_col <= 5; end
                "t","T": begin key_row <= 2; key_col <= 6; end
                "u","U": begin key_row <= 3; key_col <= 6; end
                "v","V": begin key_row <= 3; key_col <= 7; end
                "w","W": begin key_row <= 1; key_col <= 1; end
                "x","X": begin key_row <= 2; key_col <= 7; end
                "y","Y": begin key_row <= 3; key_col <= 1; end
                "z","Z": begin key_row <= 1; key_col <= 4; end
                " ":     begin key_row <= 7; key_col <= 4; end
                8'h0D:   begin key_row <= 0; key_col <= 1; end
                8'h08:   begin key_row <= 0; key_col <= 0; end
                "+":     begin key_row <= 5; key_col <= 0; end
                "-":     begin key_row <= 5; key_col <= 3; end
                "*":     begin key_row <= 6; key_col <= 1; end
                "/":     begin key_row <= 6; key_col <= 7; end
                ":":     begin key_row <= 5; key_col <= 5; end
                ";":     begin key_row <= 6; key_col <= 2; end
                "=":     begin key_row <= 6; key_col <= 5; end
                "@":     begin key_row <= 5; key_col <= 6; end
                ".":     begin key_row <= 5; key_col <= 4; end
                ",":     begin key_row <= 5; key_col <= 7; end
                default: key_active <= 0;
            endcase
        end
    end
end

/* ── Matrix output ─────────────────────────────────────────────────────── */
always @(*) begin
    col_result = 8'hFF;
    if (key_active && !row_select[key_row])
        col_result[key_col] = 1'b0;
end

endmodule
