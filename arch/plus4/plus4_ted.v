/*
 * plus4_ted.v — TED (MOS 7360) emulation for Commodore Plus/4
 *
 * Implements the subset needed for text-mode BASIC:
 *   - 40×25 color text display (16 colors × 8 luminance)
 *   - Timer 1 with IRQ (for jiffy clock / keyboard scan)
 *   - Raster IRQ (stub: fires once per frame)
 *   - Keyboard matrix scanning ($FD30)
 *   - ROM/RAM banking ($FF3E/$FF3F)
 *   - Color palette registers
 *
 * Register map: $FF00-$FF3F (active), mirrored at $FD00-$FD3F
 *
 *   $FF00-$FF01: Timer 1 (low/high, auto-reload)
 *   $FF02-$FF03: Timer 2 (low/high, stub)
 *   $FF04-$FF05: Timer 3 (low/high, stub)
 *   $FF06: Vertical control (rows, blank, modes)
 *   $FF07: Horizontal control (columns, multicolor)
 *   $FF08: Keyboard latch (active accent accent)
 *   $FF09: IRQ status (R: flags, W: clear)
 *   $FF0A: IRQ enable
 *   $FF0B: Raster compare high bit + misc
 *   $FF0C-$FF0D: Cursor position (stub)
 *   $FF0E-$FF12: Sound + bitmap base (stubs)
 *   $FF13: Character base address
 *   $FF14: Video matrix base address
 *   $FF15: Background color 0
 *   $FF16: Background color 1
 *   $FF17: Background color 2
 *   $FF18: Background color 3
 *   $FF19: Border color
 *   $FF1A: Character position high
 *   $FF1B: Character position low
 *   $FF1C: Raster position high + misc
 *   $FF1D: Raster position low
 *   $FF1E-$FF1F: (stubs)
 *   $FF3E: ROM select (write enables ROM banking)
 *   $FF3F: RAM select (write disables ROM banking)
 */

module plus4_ted(
    input clk,
    input rst,

    // CPU interface
    input [7:0] addr,           // register offset (0-$3F)
    input [7:0] din,
    output reg [7:0] dout,
    input we,                   // write enable (one cycle)
    input rd,                   // read select
    input cpu_clk_en,           // CPU clock enable (RDY)

    // Video output
    input [10:0] row,
    input [10:0] col,

    // Screen RAM read port (from main_ram, 1-cycle registered)
    output reg [9:0] screen_addr,
    input [7:0] screen_data,

    // Color RAM read port (from main_ram, 1-cycle registered)
    output reg [9:0] color_addr,
    input [7:0] color_data,

    // Character ROM read port (1-cycle registered)
    output reg [10:0] char_addr,
    input [7:0] char_data,

    // Video pixel output
    output reg [15:0] pixel_out,
    output reg        pixel_active,


    // Keyboard
    input [7:0] uart_rx_data,
    input uart_rx_valid,

    // IRQ output
    output irq,

    // ROM banking
    output reg rom_enabled,

    // Vertical sync (from lcd_out, for raster counting)
    input lcd_vsync,

    // Cursor position (from KERNAL ZP, updated by SoC)
    input [4:0] cursor_row,   // 0-24
    input [5:0] cursor_col    // 0-39
);

    // ════════════════════════════════════════════════════════════════
    //  TED Registers
    // ════════════════════════════════════════════════════════════════

    // Timers
    reg [15:0] t1_counter, t1_latch;
    reg [15:0] t2_counter, t3_counter;

    // IRQ
    reg [7:0] irq_status;    // $FF09: bit3=T1, bit2=T2, bit1=raster, bit0=T3
    reg [7:0] irq_enable;    // $FF0A: same bit layout

    wire irq_active = |(irq_status[3:0] & irq_enable[3:0]);
    assign irq = irq_active;

    // Video control
    reg [7:0] reg_06, reg_07;     // vertical/horizontal control
    reg [7:0] reg_13, reg_14;     // char base, video matrix base

    reg [7:0] reg_15, reg_16, reg_17, reg_18, reg_19;  // colors

    // Raster
    reg [8:0] raster_line;
    reg vsync_prev;

    // Sound stubs
    reg [7:0] reg_0e, reg_0f, reg_10, reg_11, reg_12;

    // Misc stubs
    reg [7:0] reg_0b, reg_0c, reg_0d;

    // ════════════════════════════════════════════════════════════════
    //  Keyboard Matrix (8×8, UART-to-matrix bridge)
    // ════════════════════════════════════════════════════════════════

    reg [7:0] key_matrix [0:7];
    reg [17:0] key_timer;
    reg [7:0] kbd_row_select;   // written via $FD30 / $FF08

    integer i;

    // ASCII → Plus/4 matrix lookup (from KERNAL ROM table at $E026)
    reg [2:0] map_row, map_col;
    reg       map_valid;

    always @* begin
        map_valid = 1;
        map_row   = 0;
        map_col   = 0;
        case (uart_rx_data)
            // Letters (from ROM decode table)
            8'h61: begin map_row=1; map_col=2; end  // a
            8'h62: begin map_row=3; map_col=4; end  // b
            8'h63: begin map_row=2; map_col=4; end  // c
            8'h64: begin map_row=2; map_col=2; end  // d
            8'h65: begin map_row=1; map_col=6; end  // e
            8'h66: begin map_row=2; map_col=5; end  // f
            8'h67: begin map_row=3; map_col=2; end  // g
            8'h68: begin map_row=3; map_col=5; end  // h
            8'h69: begin map_row=4; map_col=1; end  // i
            8'h6A: begin map_row=4; map_col=2; end  // j
            8'h6B: begin map_row=4; map_col=5; end  // k
            8'h6C: begin map_row=5; map_col=2; end  // l
            8'h6D: begin map_row=4; map_col=4; end  // m
            8'h6E: begin map_row=4; map_col=7; end  // n
            8'h6F: begin map_row=4; map_col=6; end  // o
            8'h70: begin map_row=5; map_col=1; end  // p
            8'h71: begin map_row=7; map_col=6; end  // q
            8'h72: begin map_row=2; map_col=1; end  // r
            8'h73: begin map_row=1; map_col=5; end  // s
            8'h74: begin map_row=2; map_col=6; end  // t
            8'h75: begin map_row=3; map_col=6; end  // u
            8'h76: begin map_row=3; map_col=7; end  // v
            8'h77: begin map_row=1; map_col=1; end  // w
            8'h78: begin map_row=2; map_col=7; end  // x
            8'h79: begin map_row=3; map_col=1; end  // y
            8'h7A: begin map_row=1; map_col=4; end  // z
            // Digits
            8'h30: begin map_row=4; map_col=3; end  // 0
            8'h31: begin map_row=7; map_col=0; end  // 1
            8'h32: begin map_row=7; map_col=3; end  // 2
            8'h33: begin map_row=1; map_col=0; end  // 3
            8'h34: begin map_row=1; map_col=3; end  // 4
            8'h35: begin map_row=2; map_col=0; end  // 5
            8'h36: begin map_row=2; map_col=3; end  // 6
            8'h37: begin map_row=3; map_col=0; end  // 7
            8'h38: begin map_row=3; map_col=3; end  // 8
            8'h39: begin map_row=4; map_col=0; end  // 9
            // Control
            8'h0D: begin map_row=0; map_col=1; end  // RETURN
            8'h20: begin map_row=7; map_col=4; end  // SPACE
            8'h08: begin map_row=0; map_col=0; end  // Backspace → DEL
            8'h7F: begin map_row=0; map_col=0; end  // DEL
            // Symbols
            8'h2A: begin map_row=6; map_col=1; end  // *
            8'h2B: begin map_row=6; map_col=6; end  // +
            8'h2C: begin map_row=5; map_col=7; end  // ,
            8'h2D: begin map_row=5; map_col=6; end  // -
            8'h2E: begin map_row=5; map_col=4; end  // .
            8'h2F: begin map_row=6; map_col=7; end  // /
            8'h3A: begin map_row=5; map_col=5; end  // :
            8'h3B: begin map_row=6; map_col=2; end  // ;
            8'h3D: begin map_row=6; map_col=5; end  // =
            8'h40: begin map_row=0; map_col=7; end  // @
            8'h5C: begin map_row=0; map_col=2; end  // backslash
            default: map_valid = 0;
        endcase
    end

    // Keyboard scan: row select is written to $FF08/$FD30
    reg [7:0] scanned_cols;
    always @* begin
        scanned_cols = 8'hFF;  // all released (active-low)
        for (i = 0; i < 8; i = i + 1)
            if (!kbd_row_select[i])
                scanned_cols = scanned_cols & ~key_matrix[i];
    end

    // ════════════════════════════════════════════════════════════════
    //  TED Color Palette → RGB565
    // ════════════════════════════════════════════════════════════════

    // TED has 16 colors × 8 luminance levels = 128 entries.
    // For simplicity, use a fixed 16-color palette (mid luminance).
    function [15:0] ted_color;
        input [3:0] color;
        input [2:0] luma;
        begin
            case (color)
                4'h0: ted_color = 16'h0000;  // black
                4'h1: ted_color = {5'd31, 6'd63, 5'd31};  // white
                4'h2: ted_color = {5'd28, 6'd8,  5'd8};   // red
                4'h3: ted_color = {5'd4,  6'd56, 5'd24};  // cyan
                4'h4: ted_color = {5'd24, 6'd8,  5'd28};  // purple
                4'h5: ted_color = {5'd8,  6'd52, 5'd8};   // green
                4'h6: ted_color = {5'd4,  6'd8,  5'd28};  // blue
                4'h7: ted_color = {5'd28, 6'd56, 5'd8};   // yellow
                4'h8: ted_color = {5'd24, 6'd24, 5'd4};   // orange
                4'h9: ted_color = {5'd16, 6'd20, 5'd4};   // brown
                4'hA: ted_color = {5'd24, 6'd40, 5'd24};  // yellow-green
                4'hB: ted_color = {5'd28, 6'd20, 5'd20};  // pink
                4'hC: ted_color = {5'd8,  6'd40, 5'd28};  // blue-green
                4'hD: ted_color = {5'd12, 6'd20, 5'd28};  // light blue
                4'hE: ted_color = {5'd12, 6'd12, 5'd28};  // dark blue
                4'hF: ted_color = {5'd12, 6'd48, 5'd12};  // light green
            endcase
            // Simple luminance scaling (shift toward white for higher luma)
            if (luma > 4)
                ted_color = ted_color | 16'h4208;  // brighten
        end
    endfunction

    // ════════════════════════════════════════════════════════════════
    //  Video Pipeline (5-stage, same structure as PET)
    // ════════════════════════════════════════════════════════════════

    // Plus/4 display: 40×25 chars, 8×8 pixels = 320×200
    // LCD: 480×272.  Center offsets:
    localparam OFFSET_X = (480 - 320) / 2;   // 80
    localparam OFFSET_Y = (272 - 200) / 2;   // 36

    // Prefetch 4 cycles ahead
    wire [10:0] pre_col = col + 11'd4;
    wire in_x = (pre_col >= OFFSET_X) && (pre_col < OFFSET_X + 11'd320);
    wire in_y = (row >= OFFSET_Y) && (row < OFFSET_Y + 11'd200);
    wire in_window = in_x & in_y;

    wire [8:0] pet_x = pre_col - OFFSET_X;
    wire [7:0] pet_y = row - OFFSET_Y;
    wire [5:0] char_col_v = pet_x[8:3];
    wire [4:0] char_row_v = pet_y[7:3];
    wire [2:0] glyph_y = pet_y[2:0];
    wire [2:0] pixel_x = pet_x[2:0];
    wire [9:0] row_base = {char_row_v, 5'b0} + {2'b0, char_row_v, 3'b0};

    // P0: register addresses
    reg p0_valid;
    reg [2:0] p0_pixel_x, p0_glyph_y;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            screen_addr <= 0;
            color_addr  <= 0;
            p0_valid    <= 0;
            p0_pixel_x  <= 0;
            p0_glyph_y  <= 0;
        end else begin
            screen_addr <= row_base + {4'b0, char_col_v};
            color_addr  <= row_base + {4'b0, char_col_v};
            p0_valid    <= in_window;
            p0_pixel_x  <= pixel_x;
            p0_glyph_y  <= glyph_y;
        end

    // P1: wait for screen/color RAM read
    reg p1_valid;
    reg [2:0] p1_pixel_x, p1_glyph_y;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            p1_valid <= 0; p1_pixel_x <= 0; p1_glyph_y <= 0;
        end else begin
            p1_valid   <= p0_valid;
            p1_pixel_x <= p0_pixel_x;
            p1_glyph_y <= p0_glyph_y;
        end

    // P2: screen_data + color_data valid → compute char ROM addr
    reg p2_valid;
    reg [2:0] p2_pixel_x;
    reg [7:0] p2_color;
    reg p2_reverse;
    reg p2_is_cursor;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            char_addr  <= 0;
            p2_valid   <= 0;
            p2_pixel_x <= 0;
            p2_color   <= 0;
            p2_reverse <= 0;
            p2_is_cursor <= 0;
        end else begin
            // Character ROM: use screen_data[6:0] as char index (128 chars)
            // reg_13[2] selects upper/lower 1KB (character set)
            // screen_data[7] = reverse video flag (handled at pixel output)
            char_addr  <= {reg_13[2], screen_data[6:0], p1_glyph_y};
            p2_valid   <= p1_valid;
            p2_pixel_x <= p1_pixel_x;
            p2_color   <= color_data;
            p2_reverse <= screen_data[7];
            p2_is_cursor <= (char_row_v == cursor_row) && (char_col_v == cursor_col);
        end

    // P3: wait for char ROM read
    reg p3_valid;
    reg [2:0] p3_pixel_x;
    reg [7:0] p3_color;
    reg p3_reverse;
    reg p3_is_cursor;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            p3_valid <= 0; p3_pixel_x <= 0; p3_color <= 0; p3_reverse <= 0; p3_is_cursor <= 0;
        end else begin
            p3_valid   <= p2_valid;
            p3_pixel_x <= p2_pixel_x;
            p3_color   <= p2_color;
            p3_reverse <= p2_reverse;
            p3_is_cursor <= p2_is_cursor;
        end

    // P4: char_data valid → select pixel, apply color
    wire glyph_bit_raw = char_data[3'd7 - p3_pixel_x];
    wire glyph_bit = p3_reverse ? ~glyph_bit_raw : glyph_bit_raw;

    // Foreground: from color RAM (bits 0-3 = color, bits 4-6 = luminance)
    wire [15:0] fg_color = ted_color(p3_color[3:0], p3_color[6:4]);
    // Background: from TED register $FF15
    wire [15:0] bg_color = ted_color(reg_15[3:0], reg_15[6:4]);

    // Cursor blink: show solid block at cursor position, toggling ~2Hz
    wire blink_phase = frame_cnt[4];
    wire cursor_on = p3_is_cursor & blink_phase;

    reg [31:0] frame_cnt;
    always @(posedge clk or negedge rst)
        if (!rst) frame_cnt <= 0;
        else if (!lcd_vsync && vsync_prev) frame_cnt <= frame_cnt + 1;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            pixel_out    <= 16'h0000;
            pixel_active <= 0;
        end else begin
            pixel_active <= p3_valid;
            if (cursor_on)
                pixel_out <= fg_color;  // solid block for cursor
            else
                pixel_out <= glyph_bit ? fg_color : bg_color;
        end

    // ════════════════════════════════════════════════════════════════
    //  Timers + IRQ + Keyboard + Registers
    // ════════════════════════════════════════════════════════════════

    always @(posedge clk or negedge rst)
        if (!rst) begin
            t1_counter  <= 16'hFFFF;
            t1_latch    <= 16'hFFFF;
            t2_counter  <= 16'hFFFF;
            t3_counter  <= 16'hFFFF;
            irq_status  <= 8'h00;
            irq_enable  <= 8'h00;
            reg_06 <= 8'h27;  // 25 rows, screen on
            reg_07 <= 8'h40;  // 40 columns
            reg_13 <= 8'hD0;  // char base at $D000
            reg_14 <= 8'h03;  // video matrix at $0C00
            reg_15 <= 8'h71;  // background: white
            reg_16 <= 8'h00;
            reg_17 <= 8'h00;
            reg_18 <= 8'h00;
            reg_19 <= 8'h00;  // border: black
            reg_0b <= 8'h00;
            reg_0c <= 8'h00;
            reg_0d <= 8'h00;
            reg_0e <= 8'h00;
            reg_0f <= 8'h00;
            reg_10 <= 8'h00;
            reg_11 <= 8'h00;
            reg_12 <= 8'h00;
            rom_enabled <= 1;
            kbd_row_select <= 8'hFF;
            raster_line <= 0;
            vsync_prev  <= 1;
            for (i = 0; i < 8; i = i + 1)
                key_matrix[i] <= 8'h00;
            key_timer <= 0;
        end else begin

            // ── Timer 1: countdown on CPU clock ──
            if (cpu_clk_en) begin
                if (t1_counter == 16'h0000) begin
                    irq_status[3] <= 1;  // T1 IRQ flag
                    t1_counter <= t1_latch;
                end else
                    t1_counter <= t1_counter - 1;
            end

            // ── Raster counter + compare IRQ ──
            // Count raster lines; fire IRQ when line matches $FF0B compare
            vsync_prev <= lcd_vsync;
            if (!lcd_vsync && vsync_prev)
                raster_line <= 0;
            else if (col == 0 && row < 312)
                raster_line <= raster_line + 1;

            // Raster compare: fire when line matches reg_0b (compare value)
            // High bit of compare is in irq_enable[0] ($FF0A bit 0)
            if (col == 1 && raster_line[7:0] == reg_0b && raster_line[8] == irq_enable[0])
                irq_status[1] <= 1;

            // ── Keyboard auto-release ──
            if (key_timer > 0) begin
                key_timer <= key_timer - 1;
                if (key_timer == 1)
                    for (i = 0; i < 8; i = i + 1)
                        key_matrix[i] <= 8'h00;
            end

            // ── New key from UART ──
            if (uart_rx_valid && map_valid) begin
                key_matrix[map_row][map_col] <= 1'b1;
                key_timer <= 18'd200000;  // hold key for >1 frame (~160K cycles)
            end

            // ── Register writes ──
            if (we) begin
                case (addr[5:0])
                    6'h00: t1_latch[7:0]  <= din;
                    6'h01: begin
                        t1_latch[15:8] <= din;
                        t1_counter <= {din, t1_latch[7:0]};
                        irq_status[3] <= 0;
                    end
                    6'h02: t2_counter[7:0] <= din;
                    6'h03: t2_counter[15:8] <= din;
                    6'h04: t3_counter[7:0] <= din;
                    6'h05: t3_counter[15:8] <= din;
                    6'h06: reg_06 <= din;
                    6'h07: reg_07 <= din;
                    6'h08: kbd_row_select <= din;  // $FF08 keyboard latch
                    6'h30: kbd_row_select <= din;  // $FD30 keyboard PIO
                    6'h09: irq_status <= irq_status & ~din;  // write 1 to clear
                    6'h0A: irq_enable <= din;
                    6'h0B: reg_0b <= din;
                    6'h0C: reg_0c <= din;
                    6'h0D: reg_0d <= din;
                    6'h0E: reg_0e <= din;
                    6'h0F: reg_0f <= din;
                    6'h10: reg_10 <= din;
                    6'h11: reg_11 <= din;
                    6'h12: reg_12 <= din;
                    6'h13: reg_13 <= din;
                    6'h14: reg_14 <= din;
                    6'h15: reg_15 <= din;
                    6'h16: reg_16 <= din;
                    6'h17: reg_17 <= din;
                    6'h18: reg_18 <= din;
                    6'h19: reg_19 <= din;
                    6'h3E: rom_enabled <= 1;
                    6'h3F: rom_enabled <= 0;
                endcase
            end

            // ── Reading timer low clears IRQ flag ──
            if (rd && addr[5:0] == 6'h00)
                irq_status[3] <= 0;
        end

    // ── Register reads ──
    always @* begin
        case (addr[5:0])
            6'h00: dout = t1_counter[7:0];
            6'h01: dout = t1_counter[15:8];
            6'h02: dout = t2_counter[7:0];
            6'h03: dout = t2_counter[15:8];
            6'h04: dout = t3_counter[7:0];
            6'h05: dout = t3_counter[15:8];
            6'h06: dout = reg_06;
            6'h07: dout = reg_07;
            6'h08: dout = scanned_cols;  // $FF08 keyboard read
            6'h30: dout = scanned_cols;  // $FD30 keyboard PIO read
            6'h09: dout = {irq_active, irq_status[6:0]};
            6'h0A: dout = irq_enable;
            6'h0B: dout = reg_0b;
            6'h0C: dout = reg_0c;
            6'h0D: dout = reg_0d;
            6'h0E: dout = reg_0e;
            6'h0F: dout = reg_0f;
            6'h10: dout = reg_10;
            6'h11: dout = reg_11;
            6'h12: dout = reg_12;
            6'h13: dout = reg_13;
            6'h14: dout = reg_14;
            6'h15: dout = reg_15;
            6'h16: dout = reg_16;
            6'h17: dout = reg_17;
            6'h18: dout = reg_18;
            6'h19: dout = reg_19;
            6'h1C: dout = {raster_line[8], 7'h7F};
            6'h1D: dout = raster_line[7:0];
            default: dout = 8'hFF;
        endcase
    end

endmodule
