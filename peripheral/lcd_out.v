`include "project.vh"

/*
 * lcd_out — LCD scan-timing generator.
 *
 * Generates hsync/vsync/de plus the (row,col) scan position consumed by the
 * pixel renderers (lcd_char, dcache).  The internal counters hpos/vpos run at
 * the *physical* panel resolution; the (row,col) handed to the renderers may
 * be downscaled.
 *
 * 2× UPSCALE MODE (`define LCD_SCALE2X) — for the HW=v2 800×480 panel:
 *   The physical scan runs at 800×480 but the renderers see a 400×240 logical
 *   space (row=vpos/2, col=hpos/2).  Two extra strobes tell the serial char
 *   renderer when to step:
 *     pixel_tick — high once per logical column (every 2nd physical clock) so
 *                  each rendered pixel is held for 2 physical pixels (H-double).
 *     line_tick  — high once per logical row (every 2nd physical line) so each
 *                  rendered scanline is repeated on 2 physical lines (V-double).
 *   Apps then render a 400×240 image and the panel shows it doubled to 800×480.
 *
 * Default (no LCD_SCALE2X): row/col = physical position, ticks tied high, so
 * the renderers run 1:1 exactly as before — other arches are unaffected.
 */

module lcd_out(
	input clk,
  input rst,
	input [10:0] ctrl_data,
	input [2:0] ctrl_addr,
	input ctrl_we,

	output reg lcd_hsync,
	output reg lcd_vsync,
	output lcd_de,
	output [10:0] row,
	output [10:0] col,
	output pixel_tick,        /* step one logical column (1:1 mode: always 1) */
	output line_tick,         /* step one logical row    (1:1 mode: always 1) */
	output [10:0] px_x,       /* RAW physical scan position (counts through   */
	output [10:0] px_y        /* blanking) — native-resolution overlays        */
);

	reg [10:0] h1_reg, h2_reg, h3_reg, h4_reg;
	reg [10:0] v1_reg, v2_reg, v3_reg, v4_reg;
	reg v_active, h_active;

	/* Physical scan position (panel resolution). */
	reg [10:0] hpos, vpos;

	assign lcd_de = v_active & h_active;
	assign px_x   = hpos;
	assign px_y   = vpos;

`ifdef LCD_SCALE2X
	/* Renderers see a half-resolution logical space; ticks pace the stepping. */
	assign col        = {1'b0, hpos[10:1]};
	assign row        = {1'b0, vpos[10:1]};
	assign pixel_tick = hpos[0];
	assign line_tick  = vpos[0];
`else
	assign col        = hpos;
	assign row        = vpos;
	assign pixel_tick = 1'b1;
	assign line_tick  = 1'b1;
`endif

	// Vsync, Back porch, Active video, Front porch

	wire v1 = vpos == v1_reg;
	wire v2 = vpos == v2_reg;
	wire v3 = vpos == v3_reg;
	wire v4 = vpos == v4_reg;

	// Hsync, Back porch, Active video, Front porch

	wire h1 = hpos == h1_reg;
	wire h2 = hpos == h2_reg;
	wire h3 = hpos == h3_reg;
	wire h4 = hpos == h4_reg;

	always @(posedge clk or negedge rst)
	if (!rst)
		{lcd_hsync, lcd_vsync, h_active, v_active, hpos, vpos} <= 0;
	else
	begin
	  if (h1)
			lcd_hsync = 1;

	  if (h2)
			h_active = 1;

	  if (h3)
			h_active = 0;

	  if (h4)
	  begin
			lcd_hsync = 0;
			hpos <= 0;

			if (v1)
		      lcd_vsync = 1;

			if (v2)
		    v_active = 1;

			if (v3)
		    v_active = 0;

			if (v4)
			begin
		    vpos <= 0;
		    lcd_vsync = 0;
			end
			else
		    vpos <= vpos + 1;
	  end
	  else
			hpos <= hpos + 1;
	end

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
// Priority:
//   LCD_SCALE2X     - 800x480 physical panel, renderers see 400x240 (HW v2)
//   SIMULATION_SDL  - Verilator/SDL2 desktop sim: full 480x272 frame
//   SIMULATION      - iverilog waveform sim: tiny 30x2 frame (fast)
//   (default)       - real hardware: 480x272 frame
`ifdef LCD_SCALE2X
	  // 800 x 480 physical panel.  Renderers address a 400 x 240 logical frame.
	  // Totals 1056 x 525 = 554,400 clk/frame → ~69 Hz at the v2 ~38.4 MHz clock.
	  v1_reg <= 0;
	  v2_reg <= 0;
    v3_reg <= 480;			// active rows 0..479 = 480 physical rows
    v4_reg <= 525;			// total rows (480 active + 45 blanking)
	  h1_reg <= 0;
	  h2_reg <= 0;
	  h3_reg <= 800;			// active cols 0..799 = 800 physical cols
	  h4_reg <= 1056;			// total cols (800 active + 256 blanking)
`elsif LCD_FULL800
	  // NATIVE 800 x 480 — same panel totals as SCALE2X but NO pixel doubling
	  // (col=hpos, row=vpos): the renderers/framebuffer are full 800x480.  Use
	  // when the framebuffer has room (RAM=ddr3/ddr3-pro) — no quarter-res, no
	  // 480x272-game crop.  (col/row halving above is gated on LCD_SCALE2X only.)
	  v1_reg <= 0;  v2_reg <= 0;  v3_reg <= 480;  v4_reg <= 525;
	  h1_reg <= 0;  h2_reg <= 0;  h3_reg <= 800;  h4_reg <= 1056;
`elsif SIMULATION_SDL
	  // Full-resolution for desktop simulation (sim-desktop Makefile).
	  // Both SIMULATION and SIMULATION_SDL are defined in that build;
	  // check SIMULATION_SDL first so it wins over the tiny SIMULATION frame.
	  v1_reg <= 0;				// 480 x 272
	  v2_reg <= 0;
    v3_reg <= 272;			// active rows 1..272 = 272 rows
    v4_reg <= 290;

	  h1_reg <= 0;
	  h2_reg <= 0;
	  h3_reg <= 480;
	  h4_reg <= 550;
`elsif SIMULATION
	  // Tiny frame for fast iverilog waveform simulation (sim-hdl).
	  v1_reg <= 1;
	  v2_reg <= 4;
    v3_reg <= 6;
    v4_reg <= 8;

	  h1_reg <= 3;
	  h2_reg <= 23;
	  h3_reg <= 53;
	  h4_reg <= 60;
`else
	  v1_reg <= 0;				// 480 x 272 (hardware)
	  v2_reg <= 0;
    v3_reg <= 273;
    v4_reg <= 290;

	  h1_reg <= 0;
	  h2_reg <= 0;
	  h3_reg <= 480;
	  h4_reg <= 550;
/*
	  v1_reg <= 2;			// 800 x 600
	  v2_reg <= 27;
    v3_reg <= 507;
    v4_reg <= 508;

	  h1_reg <= 2;
	  h2_reg <= 5;
	  h3_reg <= 799;
	  h4_reg <= 805;
*/
`endif

	end else
	begin
	  if (ctrl_we)
	  begin
			case (ctrl_addr[2:0])
		    0:	v1_reg <= ctrl_data;
		    1:	v2_reg <= ctrl_data;
		    2:	v3_reg <= ctrl_data;
		    3:	v4_reg <= ctrl_data;
		    4:	h1_reg <= ctrl_data;
		    5:	h2_reg <= ctrl_data;
		    6:	h3_reg <= ctrl_data;
		    7:	h4_reg <= ctrl_data;
			endcase
	  end
	end

endmodule
