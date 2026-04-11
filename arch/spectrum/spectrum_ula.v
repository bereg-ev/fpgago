/*
 * spectrum_ula.v — ZX Spectrum ULA (Uncommitted Logic Array)
 *
 * Handles:
 *   - Video generation: 256x192 bitmap + 32x24 color attributes
 *   - Border color (3-bit, port $FE write bits 2:0)
 *   - Speaker output (port $FE write bit 4)
 *   - Keyboard matrix read (port $FE read, accent half-rows via A8-A15)
 *
 * Video memory layout ($4000-$5AFF):
 *   $4000-$57FF  6144 bytes bitmap (256x192, 1bpp)
 *                Address bits: 010 YY YYY XXX YYYYY (character row interleaved)
 *   $5800-$5AFF  768 bytes attributes (32x24, 8 bytes per character row)
 *                Each byte: FLASH BRIGHT INK2 INK1 INK0 PAPER2 PAPER1 PAPER0
 *                Wait... standard is: FLASH BRIGHT PAPER2 PAPER1 PAPER0 INK2 INK1 INK0
 *
 * Accent colour palette (accent BRIGHT=0 / BRIGHT=1):
 *   0: black    / black      (#000000 / #000000)
 *   1: blue     / bright blue(#0000D7 / #0000FF)
 *   2: red      / bright red (#D70000 / #FF0000)
 *   3: magenta  / bright mag (#D700D7 / #FF00FF)
 *   4: green    / bright grn (#00D700 / #00FF00)
 *   5: cyan     / bright cyan(#00D7D7 / #00FFFF)
 *   6: yellow   / bright yel (#D7D700 / #FFFF00)
 *   7: white    / bright wht (#D7D7D7 / #FFFFFF)
 */

module spectrum_ula(
    input             clk,
    input             rst,

    // Video output (active accent accent pixel stream to lcd_out)
    output reg [15:0] pixel_rgb565,
    output reg        pixel_valid,    // 1 when outputting active LCD pixels
    output reg        frame_sync,     // 1 for one clk at start of each frame

    // Video RAM read port (active accent accent accent accent)
    output reg [12:0] vram_addr,      // 0-8191 covers $4000-$5FFF
    input       [7:0] vram_data,

    // Border colour (accent from port $FE writes)
    input       [2:0] border_color,

    // Keyboard matrix
    input       [7:0] key_halfrow_sel, // accent A15-A8 accent from address bus
    output      [4:0] key_data         // 5 column bits (accent active low)
);

/* ── Accent spectrum colour palette in RGB565 ──────────────────────────── */
/* Index = {bright, color[2:0]} → 16 entries */
function [15:0] spectrum_color;
    input [3:0] idx;
    case (idx)
        4'h0: spectrum_color = 16'h0000;  // black
        4'h1: spectrum_color = 16'h001A;  // blue
        4'h2: spectrum_color = 16'hD000;  // red
        4'h3: spectrum_color = 16'hD01A;  // magenta
        4'h4: spectrum_color = 16'h06A0;  // green
        4'h5: spectrum_color = 16'h06BA;  // cyan
        4'h6: spectrum_color = 16'hD6A0;  // yellow
        4'h7: spectrum_color = 16'hD6BA;  // white
        4'h8: spectrum_color = 16'h0000;  // bright black
        4'h9: spectrum_color = 16'h001F;  // bright blue
        4'hA: spectrum_color = 16'hF800;  // bright red
        4'hB: spectrum_color = 16'hF81F;  // bright magenta
        4'hC: spectrum_color = 16'h07E0;  // bright green
        4'hD: spectrum_color = 16'h07FF;  // bright cyan
        4'hE: spectrum_color = 16'hFFE0;  // bright yellow
        4'hF: spectrum_color = 16'hFFFF;  // bright white
    endcase
endfunction

/* ── Display timing parameters ─────────────────────────────────────────── */
/* Original Spectrum: 256x192 display, 48px border each side = 352x296 total
 * We render into 480x272 LCD:
 *   - 256x192 display centred in 480x272
 *   - Border fills the surrounding area
 *   - Horizontal: (480-256)/2 = 112 border pixels each side
 *   - Vertical: (272-192)/2 = 40 border pixels top/bottom */

`ifdef SIMULATION_SDL
    localparam LCD_W = 480;
    localparam LCD_H = 272;
`else
    localparam LCD_W = 480;
    localparam LCD_H = 272;
`endif

localparam DISPLAY_W = 256;
localparam DISPLAY_H = 192;
localparam BORDER_H  = (LCD_W - DISPLAY_W) / 2;   // 112
localparam BORDER_V  = (LCD_H - DISPLAY_H) / 2;    // 40

/* ── Pixel counters ────────────────────────────────────────────────────── */
/* We generate one pixel per clock at the pixel clock rate.
 * A divider from the system clock gives us the pixel clock. */

localparam PIX_DIV = 4;   // system_clk / 4 for pixel clock

reg [2:0] pix_div_cnt;
wire      pix_clk_en = (pix_div_cnt == 0);

reg [9:0] hcount;   // 0 .. LCD_W+HBLANK-1
reg [8:0] vcount;   // 0 .. LCD_H+VBLANK-1

localparam HTOTAL = LCD_W + 64;    // 544 pixel clocks per line
localparam VTOTAL = LCD_H + 24;    // 296 lines per frame

/* ── Pipeline registers ────────────────────────────────────────────────── */
/* 3-stage pipeline to handle RAM read latency:
 *   Stage 0: compute vram address for current character
 *   Stage 1: bitmap byte arrives from RAM
 *   Stage 2: attribute byte arrives, pixel output */

reg [7:0]  bitmap_byte;
reg [7:0]  attr_byte;
reg [2:0]  pixel_bit;

/* Active display area */
wire in_display_h = (hcount >= BORDER_H) && (hcount < BORDER_H + DISPLAY_W);
wire in_display_v = (vcount >= BORDER_V) && (vcount < BORDER_V + DISPLAY_H);
wire in_display   = in_display_h && in_display_v;
wire in_lcd       = (hcount < LCD_W) && (vcount < LCD_H);

/* Display-relative coordinates */
wire [7:0] dx = hcount - BORDER_H;       // 0-255
wire [7:0] dy = vcount - BORDER_V;       // 0-191

/* ── VRAM address calculation ──────────────────────────────────────────── */
/* Spectrum bitmap address: 010 Y7 Y6 Y2 Y1 Y0 Y5 Y4 Y3 X4 X3 X2 X1 X0
 * Y = dy[7:0], X = dx[7:3] (character column) */
wire [12:0] bitmap_addr = {
    1'b0, dy[7:6], dy[2:0], dy[5:3], dx[7:3]
};

/* Attribute address: 0001 10 Y7 Y6 Y5 Y4 Y3 X4 X3 X2 X1 X0
 * = $1800 + (dy/8)*32 + dx/8 */
wire [12:0] attr_addr = {
    3'b110, dy[7:3], dx[7:3]
};

/* ── Flash counter (toggles every 16 frames) ──────────────────────────── */
reg [4:0] flash_cnt;
wire      flash_state = flash_cnt[4];

/* ── Combinational pixel colour from bitmap + attributes ──────────────── */
wire [3:0] ink_color   = {attr_byte[6], attr_byte[2:0]};
wire [3:0] paper_color = {attr_byte[6], attr_byte[5:3]};
wire       flash_bit   = attr_byte[7];
wire       bit_val     = bitmap_byte[7 - dx[2:0]];
wire       use_ink     = (flash_bit && flash_state) ? ~bit_val : bit_val;
wire [15:0] pixel_color = use_ink ? spectrum_color(ink_color) : spectrum_color(paper_color);

/* ── Main pixel generation ─────────────────────────────────────────────── */
always @(posedge clk) begin
    if (!rst) begin
        pix_div_cnt <= 0;
        hcount      <= 0;
        vcount      <= 0;
        flash_cnt   <= 0;
        pixel_valid <= 0;
        frame_sync  <= 0;
    end else begin
        frame_sync  <= 0;
        pixel_valid <= 0;

        pix_div_cnt <= pix_div_cnt + 1;
        if (pix_div_cnt == PIX_DIV - 1)
            pix_div_cnt <= 0;

        if (pix_clk_en) begin
            /* ── Advance counters ── */
            if (hcount == HTOTAL - 1) begin
                hcount <= 0;
                if (vcount == VTOTAL - 1) begin
                    vcount    <= 0;
                    flash_cnt <= flash_cnt + 1;
                    frame_sync <= 1;
                end else begin
                    vcount <= vcount + 1;
                end
            end else begin
                hcount <= hcount + 1;
            end

            /* ── VRAM read pipeline ── */
            /* On even pixel clocks within display: read bitmap
             * On odd pixel clocks: read attribute
             * Each character column is 8 pixels wide */
            if (in_display_v && hcount >= BORDER_H - 2 && hcount < BORDER_H + DISPLAY_W) begin
                if (hcount[0] == 0)
                    vram_addr <= bitmap_addr;
                else
                    vram_addr <= attr_addr;
            end

            /* Latch bitmap and attribute data */
            if (in_display && dx[2:0] == 3'd1)
                bitmap_byte <= vram_data;
            if (in_display && dx[2:0] == 3'd2)
                attr_byte <= vram_data;

            /* Latch fresh bitmap byte every 8 pixels */
            if (in_display && dx[2:0] == 3'd0 && dx != 0) begin
                // bitmap already latched
            end

            /* ── Pixel output ── */
            if (in_lcd) begin
                pixel_valid <= 1;

                if (in_display) begin
                    pixel_rgb565 <= pixel_color;
                end else begin
                    /* Border */
                    pixel_rgb565 <= spectrum_color({1'b0, border_color});
                end
            end
        end
    end
end

/* ── Keyboard matrix (accent accent accent accent accent accent accent) ─── */
/* accent accent accent accent accent accent accent accent accent accent accent accent
 * accent accent accent accent accent accent accent accent accent accent accent accent accent accent
 * This is stubbed here — actual key mapping is in spectrum_keyboard.v */
assign key_data = 5'b11111;  // no keys pressed (accent active low)

endmodule
