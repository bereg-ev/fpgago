/*
 * pet_video.v — PET character display → LCD pixel output
 *
 * Renders the PET's 40×25 character screen (320×200 pixels) centered
 * on the 480×272 LCD with green-on-black phosphor look.
 *
 * Pipeline (4-cycle latency):
 *
 *   col        → combinational: compute addr/metadata for (col + 4)
 *   posedge +0 → P0: register screen_addr, p0_* metadata
 *   posedge +1 → P1: screen RAM read completes; pipeline p1_* metadata
 *   posedge +2 → P2: screen_data visible; register char_addr, p2_* metadata
 *   posedge +3 → P3: char ROM read completes; pipeline p3_* metadata
 *   posedge +4 → P4: char_data visible; register pixel_out, pixel_active
 *
 * At posedge +4, col has advanced by 4, so col == original_col + 4.
 * Using pre_col = col + 4 compensates, placing the pixel at the correct
 * LCD position.
 */

module pet_video(
    input clk,
    input rst,
    input [10:0] row,
    input [10:0] col,

    // Screen RAM read port (1-cycle registered output in soc.v)
    output reg [9:0] screen_addr,
    input [7:0] screen_data,

    // Character ROM read port (1-cycle registered output in soc.v)
    output reg [10:0] char_addr,
    input [7:0] char_data,

    output reg [15:0] pixel_out,
    output reg        pixel_active
);

    // PET display: 40 cols × 25 rows, 8×8 pixels per char = 320×200
    // LCD: 480×272.  Centering offsets:
    localparam OFFSET_X = (480 - 320) / 2;   // 80
    localparam OFFSET_Y = (272 - 200) / 2;   // 36

    localparam [15:0] COLOR_ON  = 16'h07E0;  // green phosphor
    localparam [15:0] COLOR_OFF = 16'h0000;  // black

    // ── Combinational: compute for position (col + 4) ─────────────────
    wire [10:0] pre_col = col + 11'd4;

    wire in_x = (pre_col >= OFFSET_X) && (pre_col < OFFSET_X + 11'd320);
    wire in_y = (row     >= OFFSET_Y) && (row     < OFFSET_Y + 11'd200);
    wire in_window = in_x & in_y;

    wire [8:0] pet_x = pre_col - OFFSET_X;
    wire [7:0] pet_y = row     - OFFSET_Y;
    wire [5:0] char_col = pet_x[8:3];
    wire [4:0] char_row = pet_y[7:3];
    wire [2:0] glyph_y  = pet_y[2:0];
    wire [2:0] pixel_x  = pet_x[2:0];

    // row_base = char_row * 40 = char_row * 32 + char_row * 8
    wire [9:0] row_base = {char_row, 5'b0} + {2'b0, char_row, 3'b0};

    // ── P0: register screen address + metadata ────────────────────────
    reg        p0_valid;
    reg  [2:0] p0_pixel_x;
    reg  [2:0] p0_glyph_y;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            screen_addr <= 0;
            p0_valid    <= 0;
            p0_pixel_x  <= 0;
            p0_glyph_y  <= 0;
        end else begin
            screen_addr <= row_base + {4'b0, char_col};
            p0_valid    <= in_window;
            p0_pixel_x  <= pixel_x;
            p0_glyph_y  <= glyph_y;
        end

    // ── P1: wait for screen RAM read (soc.v registers output here) ────
    reg        p1_valid;
    reg  [2:0] p1_pixel_x;
    reg  [2:0] p1_glyph_y;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            p1_valid   <= 0;
            p1_pixel_x <= 0;
            p1_glyph_y <= 0;
        end else begin
            p1_valid   <= p0_valid;
            p1_pixel_x <= p0_pixel_x;
            p1_glyph_y <= p0_glyph_y;
        end

    // ── P2: screen_data now valid — compute char ROM address ──────────
    reg        p2_valid;
    reg  [2:0] p2_pixel_x;
    reg        p2_reverse;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            char_addr  <= 0;
            p2_valid   <= 0;
            p2_pixel_x <= 0;
            p2_reverse <= 0;
        end else begin
            char_addr  <= {screen_data[6:0], p1_glyph_y};
            p2_valid   <= p1_valid;
            p2_pixel_x <= p1_pixel_x;
            p2_reverse <= screen_data[7];
        end

    // ── P3: wait for char ROM read (soc.v registers output here) ──────
    reg        p3_valid;
    reg  [2:0] p3_pixel_x;
    reg        p3_reverse;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            p3_valid   <= 0;
            p3_pixel_x <= 0;
            p3_reverse <= 0;
        end else begin
            p3_valid   <= p2_valid;
            p3_pixel_x <= p2_pixel_x;
            p3_reverse <= p2_reverse;
        end

    // ── P4: char_data now valid — compute pixel output ────────────────
    wire pixel_bit_raw = char_data[3'd7 - p3_pixel_x];
    wire pixel_bit = p3_reverse ? ~pixel_bit_raw : pixel_bit_raw;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            pixel_out    <= 16'h0000;
            pixel_active <= 1'b0;
        end else begin
            pixel_active <= p3_valid;
            pixel_out    <= pixel_bit ? COLOR_ON : COLOR_OFF;
        end

endmodule
