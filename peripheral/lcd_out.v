`include "project.vh"

module lcd_out(
	input clk,
  input rst,
	input [10:0] ctrl_data,
	input [2:0] ctrl_addr,
	input ctrl_we,

	output reg lcd_hsync,
	output reg lcd_vsync,
	output lcd_de,
	output reg [10:0] row,
	output reg [10:0] col
);

	reg [10:0] h1_reg, h2_reg, h3_reg, h4_reg;
	reg [10:0] v1_reg, v2_reg, v3_reg, v4_reg;
	reg v_active, h_active;

	assign lcd_de = v_active & h_active;

	// Vsync, Back porch, Active video, Front porch

	wire v1 = row == v1_reg;
	wire v2 = row == v2_reg;
	wire v3 = row == v3_reg;
	wire v4 = row == v4_reg;

	// Hsync, Back porch, Active video, Front porch

	wire h1 = col == h1_reg;
	wire h2 = col == h2_reg;
	wire h3 = col == h3_reg;
	wire h4 = col == h4_reg;

	always @(posedge clk or negedge rst)
	if (!rst)
		{lcd_hsync, lcd_vsync, h_active, v_active, col, row} <= 0;
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
			col <= 0;

			if (v1)
	      lcd_vsync = 1;

			if (v2)
		    v_active = 1;

			if (v3)
		    v_active = 0;

			if (v4)
			begin
		    row <= 0;
		    lcd_vsync = 0;
			end
			else
//		    row <= {row[9:0], row[1] ^ row[10]};
		    row <= row + 1;
	  end
	  else
//		col <= {col[9:0], col[1] ^ col[10]};
			col <= col + 1;
	end
/*
	else
	begin
	    h_active = 0;
	    v_active = 0;
	end
*/

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
// Priority:
//   SIMULATION_SDL  - Verilator/SDL2 desktop sim: full 480x272 frame
//   SIMULATION      - iverilog waveform sim: tiny 30x2 frame (fast)
//   (default)       - real hardware: 480x272 frame
`ifdef SIMULATION_SDL
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
