`timescale 1ns / 1ps
/*
 * kbd_matrix.v — shared 8x8 keyboard matrix readout (c16 / plus4 / c64).
 *
 * matrix[row*8+col] = 1 means the key is pressed. row_n is the active-low
 * row select the machine drives (TED keyport latch on c16/plus4, CIA1 PA
 * on c64); col_n is the active-low column readback (kbus / CIA1 PB).
 */
module kbd_matrix(
    input  [63:0] matrix,
    input  [7:0]  row_n,
    output [7:0]  col_n
);

genvar c, r;
generate
    for (c = 0; c < 8; c = c + 1) begin : cols
        wire [7:0] hit;
        for (r = 0; r < 8; r = r + 1) begin : rows
            assign hit[r] = matrix[r*8 + c] & ~row_n[r];
        end
        assign col_n[c] = ~(|hit);
    end
endgenerate

endmodule
