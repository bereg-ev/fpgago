`timescale 1ns / 1ps
/*
 * c64_kbd_map.v — PETSCII-flavored UART byte → C64 matrix position.
 *
 * Matrix (row, col):
 *        c0    c1    c2    c3    c4    c5    c6    c7
 *  r0:  DEL   RET  CRS-R   F7    F1    F3    F5  CRS-DN
 *  r1:   3     W     A     4     Z     S     E   LSHIFT
 *  r2:   5     R     D     6     C     F     T     X
 *  r3:   7     Y     G     8     B     H     U     V
 *  r4:   9     I     J     0     M     K     O     N
 *  r5:   +     P     L     -     .     :     @     ,
 *  r6:   £     *     ;   HOME RSHIFT   =     ↑     /
 *  r7:   1     ←   CTRL    2   SPACE   C=    Q   STOP
 *
 * Protocol: same as c16_kbd_map.v — including $84/$8E (C=/CTRL on their own)
 * and the $80/$81/$82 modifier prefixes.  Extra c64 keys: '^' ($5E) = ↑,
 * '_' ($5F) = ←. PC function keys $85-$8C → F1..F8 (even ones via SHIFT).
 */
module c64_kbd_map(
    input  [7:0] code,
    output reg       valid,
    output reg       shift,
    output reg       cbm,      // hold C= with this key
    output reg       ctrl,     // hold CTRL with this key
    output reg       prefix,   // not a key: arm the above for the NEXT byte
    output reg [5:0] key       // {row[2:0], col[2:0]}
);

always @* begin
    valid  = 1'b1;
    shift  = 1'b0;
    cbm    = 1'b0;
    ctrl   = 1'b0;
    prefix = 1'b0;
    key    = 6'd0;

    if ((code >= 8'h41 && code <= 8'h5A) ||
        (code >= 8'h61 && code <= 8'h7A) ||
        (code >= 8'hC1 && code <= 8'hDA)) begin
        shift = code[7];                       // $C1-$DA = shifted letters
        case (code[4:0])                       // 1..26 = A..Z
            5'd1:  key = {3'd1, 3'd2};  // A
            5'd2:  key = {3'd3, 3'd4};  // B
            5'd3:  key = {3'd2, 3'd4};  // C
            5'd4:  key = {3'd2, 3'd2};  // D
            5'd5:  key = {3'd1, 3'd6};  // E
            5'd6:  key = {3'd2, 3'd5};  // F
            5'd7:  key = {3'd3, 3'd2};  // G
            5'd8:  key = {3'd3, 3'd5};  // H
            5'd9:  key = {3'd4, 3'd1};  // I
            5'd10: key = {3'd4, 3'd2};  // J
            5'd11: key = {3'd4, 3'd5};  // K
            5'd12: key = {3'd5, 3'd2};  // L
            5'd13: key = {3'd4, 3'd4};  // M
            5'd14: key = {3'd4, 3'd7};  // N
            5'd15: key = {3'd4, 3'd6};  // O
            5'd16: key = {3'd5, 3'd1};  // P
            5'd17: key = {3'd7, 3'd6};  // Q
            5'd18: key = {3'd2, 3'd1};  // R
            5'd19: key = {3'd1, 3'd5};  // S
            5'd20: key = {3'd2, 3'd6};  // T
            5'd21: key = {3'd3, 3'd6};  // U
            5'd22: key = {3'd3, 3'd7};  // V
            5'd23: key = {3'd1, 3'd1};  // W
            5'd24: key = {3'd2, 3'd7};  // X
            5'd25: key = {3'd3, 3'd1};  // Y
            5'd26: key = {3'd1, 3'd4};  // Z
            default: valid = 1'b0;
        endcase
    end else begin
        case (code)
            8'h30: key = {3'd4, 3'd3};                      // 0
            8'h31: key = {3'd7, 3'd0};                      // 1
            8'h32: key = {3'd7, 3'd3};                      // 2
            8'h33: key = {3'd1, 3'd0};                      // 3
            8'h34: key = {3'd1, 3'd3};                      // 4
            8'h35: key = {3'd2, 3'd0};                      // 5
            8'h36: key = {3'd2, 3'd3};                      // 6
            8'h37: key = {3'd3, 3'd0};                      // 7
            8'h38: key = {3'd3, 3'd3};                      // 8
            8'h39: key = {3'd4, 3'd0};                      // 9
            8'h21: begin key = {3'd7, 3'd0}; shift = 1; end // ! = SHIFT+1
            8'h22: begin key = {3'd7, 3'd3}; shift = 1; end // " = SHIFT+2
            8'h23: begin key = {3'd1, 3'd0}; shift = 1; end // # = SHIFT+3
            8'h24: begin key = {3'd1, 3'd3}; shift = 1; end // $ = SHIFT+4
            8'h25: begin key = {3'd2, 3'd0}; shift = 1; end // % = SHIFT+5
            8'h26: begin key = {3'd2, 3'd3}; shift = 1; end // & = SHIFT+6
            8'h27: begin key = {3'd3, 3'd0}; shift = 1; end // ' = SHIFT+7
            8'h28: begin key = {3'd3, 3'd3}; shift = 1; end // ( = SHIFT+8
            8'h29: begin key = {3'd4, 3'd0}; shift = 1; end // ) = SHIFT+9
            8'h2A: key = {3'd6, 3'd1};                      // *
            8'h2B: key = {3'd5, 3'd0};                      // +
            8'h2C: key = {3'd5, 3'd7};                      // ,
            8'h2D: key = {3'd5, 3'd3};                      // -
            8'h2E: key = {3'd5, 3'd4};                      // .
            8'h2F: key = {3'd6, 3'd7};                      // /
            8'h3A: key = {3'd5, 3'd5};                      // :
            8'h3B: key = {3'd6, 3'd2};                      // ;
            8'h3C: begin key = {3'd5, 3'd7}; shift = 1; end // < = SHIFT+,
            8'h3D: key = {3'd6, 3'd5};                      // =
            8'h3E: begin key = {3'd5, 3'd4}; shift = 1; end // > = SHIFT+.
            8'h3F: begin key = {3'd6, 3'd7}; shift = 1; end // ? = SHIFT+/
            8'h40: key = {3'd5, 3'd6};                      // @
            8'h5B: begin key = {3'd5, 3'd5}; shift = 1; end // [ = SHIFT+:
            8'h5D: begin key = {3'd6, 3'd2}; shift = 1; end // ] = SHIFT+;
            8'h5C: key = {3'd6, 3'd0};                      // \ = £
            8'h5E: key = {3'd6, 3'd6};                      // ^ = ↑
            8'h5F: key = {3'd7, 3'd1};                      // _ = ←
            8'h20: key = {3'd7, 3'd4};                      // SPACE
            8'h0D: key = {3'd0, 3'd1};                      // RETURN
            8'h8D: begin key = {3'd0, 3'd1}; shift = 1; end // SHIFT+RETURN
            8'h14,
            8'h08,
            8'h7F: key = {3'd0, 3'd0};                      // DEL
            8'h94: begin key = {3'd0, 3'd0}; shift = 1; end // INST
            8'h13: key = {3'd6, 3'd3};                      // HOME
            8'h93: begin key = {3'd6, 3'd3}; shift = 1; end // CLR
            8'h11: key = {3'd0, 3'd7};                      // cursor down
            8'h91: begin key = {3'd0, 3'd7}; shift = 1; end // cursor up
            8'h1D: key = {3'd0, 3'd2};                      // cursor right
            8'h9D: begin key = {3'd0, 3'd2}; shift = 1; end // cursor left
            8'h03: key = {3'd7, 3'd7};                      // STOP
            8'h83: begin key = {3'd7, 3'd7}; shift = 1; end // RUN
            8'h84: key = {3'd7, 3'd5};                      // C=
            8'h8E: key = {3'd7, 3'd2};                      // CTRL
            // modifier prefixes: hold for the next key, then release
            8'h80: begin prefix = 1; shift = 1; end
            8'h81: begin prefix = 1; cbm   = 1; end
            8'h82: begin prefix = 1; ctrl  = 1; end
            8'h85: key = {3'd0, 3'd4};                      // F1
            8'h86: begin key = {3'd0, 3'd4}; shift = 1; end // F2
            8'h87: key = {3'd0, 3'd5};                      // F3
            8'h88: begin key = {3'd0, 3'd5}; shift = 1; end // F4
            8'h89: key = {3'd0, 3'd6};                      // F5
            8'h8A: begin key = {3'd0, 3'd6}; shift = 1; end // F6
            8'h8B: key = {3'd0, 3'd3};                      // F7
            8'h8C: begin key = {3'd0, 3'd3}; shift = 1; end // F8
            default: valid = 1'b0;
        endcase
    end
end

endmodule
