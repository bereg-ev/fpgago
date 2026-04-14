/*

 */

module lcd_char(
    input clk,
    input rst,
    input [10:0] row,
    input [10:0] col,
    input [15:0] ctrl_data,
    input [23:0] ctrl_addr,
    input ctrl_we,

    output reg [15:0] char_pixel_out,
    output reg        char_active     /* high when char_pixel_out is within the character window */
);
    reg [12:0] txt_addr, tmp_txt_addr;
    reg enabled, hit, dx_en;
    reg [10:0] x, y;
    reg [2:0] dx;
    reg [3:0] dy;
    reg [7:0] chnumx, dnx;
    reg [6:0] chnumy, dny;
    reg [15:0] colorchar;
    reg [7:0] outbyte;

    /* char_active: 2-cycle delayed in_window signal to match char_pixel_out pipeline */
    wire [10:0] x_end = x + {chnumx, 3'b0};   /* x + chnumx * 8  */
    wire [10:0] y_end = y + {chnumy, 4'b0};   /* y + chnumy * 16 */
    wire in_window = (col >= x) && (col < x_end) && (row >= y) && (row < y_end) && enabled;
    reg  in_window_d1;

		reg ctrl_we_2;
    reg [23:0] ctrl_addr_d;
    reg [15:0] ctrl_data_d;
    reg txt_ena;
    reg chr_ena;

//    wire txt0_ena = (ctrl_addr[15:13] == 3'b100 & ctrl_addr[12] == 1'b0);	// text RAM
//    wire txt1_ena = (ctrl_addr[15:13] == 3'b100 & ctrl_addr[12:11] == 2'b10);	// text RAM
//   wire chr_ena = (ctrl_addr[15:13] == 3'b001 & ctrl_addr[12:10] == 3'b0);	// character RAM (128 char * 16 byte/char)

    wire [15:0] txt0_dob, txt1_dob;
    wire [17:0] chr_dob;
		wire [3:0] dummy;

		ram_1k_18 ramtxt0 (
//		ram_1k_18 #(
//`include "ibm8x16.vh"
//		) ramtxt0 (
      .clk_a(clk), .we_a(ctrl_we_2 & txt_ena), .addr_a(ctrl_addr_d[9:0]), .din_a({2'b0, ctrl_data_d[15:0]}), //.dout_a(instr_data[17:0]),
      .clk_b(clk), .we_b(1'b0), .addr_b(txt_addr[9:0]), .din_b(18'b0), .dout_b({dummy[1:0], txt0_dob})
    );

		/* Font RAM — behavioral dual-port with $readmemh init.
		   Using ram_1k_18 (inferred BRAM) instead of dual_port_ram_1k_18
		   (explicit DP16KD _TECHMAP_REPLACE_) so yosys preserves the write port. */
		reg [17:0] fontmem [0:1023];
		initial $readmemh("ibm8x16.hex", fontmem);

		reg [17:0] chr_dob_r;
		assign chr_dob = chr_dob_r;

		always @(posedge clk)
		    if (ctrl_we_2 & chr_ena)
		        fontmem[ctrl_addr_d[9:0]] <= {2'b0, ctrl_data_d};
		    // no else-read on port A (write-only from CPU)

		always @(posedge clk)
		    chr_dob_r <= fontmem[{colorchar[6:0], dy[3:1]}];


//	ramchr(.DOB(), .ADDRB(ctrl_addr[9:0]), .CLKB(clk), .DIB(ctrl_data), .ENB(chr_ena), .SSRB(1'b0), .WEB(ctrl_we & chr_ena),
//	.DOA(chr_dob), .ADDRA({colorchar[6:0], dy[3:0]}), .CLKA(clk), .DIA(), .ENA(1'b1), .SSRA(1'b0), .WEA(1'b0),
//	.DIPA(1'b0), .DIPB(2'b0));

/*
    RAMB16_S4_S4 ramtxt0(.DOA(), .ADDRA(ctrl_addr[11:0]), .CLKA(clk), .DIA(ctrl_data[15:12]), .ENA(txt0_ena), .SSRA(1'b0), .WEA(ctrl_we & txt0_ena),
	.DOB(txt0_dob[15:12]), .ADDRB(txt_addr[11:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0)
	);

    RAMB16_S4_S4 ramtxt1(.DOA(), .ADDRA(ctrl_addr[11:0]), .CLKA(clk), .DIA(ctrl_data[11:8]), .ENA(txt0_ena), .SSRA(1'b0), .WEA(ctrl_we & txt0_ena),
	.DOB(txt0_dob[11:8]), .ADDRB(txt_addr[11:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0)
	);

    RAMB16_S4_S4 ramtxt2(.DOA(), .ADDRA(ctrl_addr[11:0]), .CLKA(clk), .DIA(ctrl_data[7:4]), .ENA(txt0_ena), .SSRA(1'b0), .WEA(ctrl_we & txt0_ena),
	.DOB(txt0_dob[7:4]), .ADDRB(txt_addr[11:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0)
	);

    RAMB16_S4_S4 ramtxt3(.DOA(), .ADDRA(ctrl_addr[11:0]), .CLKA(clk), .DIA(ctrl_data[3:0]), .ENA(txt0_ena), .SSRA(1'b0), .WEA(ctrl_we & txt0_ena),
	.DOB(txt0_dob[3:0]), .ADDRB(txt_addr[11:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0)
	);

    RAMB16_S9_S9 ramtxt4(.DOA(), .ADDRA(ctrl_addr[10:0]), .CLKA(clk), .DIA(ctrl_data[15:8]), .ENA(txt1_ena), .SSRA(1'b0), .WEA(ctrl_we & txt1_ena),
	.DOB(txt1_dob[15:8]), .ADDRB(txt_addr[10:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0),
	.DIPA(1'b0)
	);

    RAMB16_S9_S9 ramtxt5(.DOA(), .ADDRA(ctrl_addr[10:0]), .CLKA(clk), .DIA(ctrl_data[7:0]), .ENA(txt1_ena), .SSRA(1'b0), .WEA(ctrl_we & txt1_ena),
	.DOB(txt1_dob[7:0]), .ADDRB(txt_addr[10:0]), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0),
	.DIPA(1'b0)
	);
*/
  always @(posedge clk or negedge rst)
  if (!rst)
	  {dx, dnx, dy, dny, dx_en} <= 0;
  else
  begin
		ctrl_we_2 <= ctrl_we;
		ctrl_addr_d <= ctrl_addr;
		ctrl_data_d <= ctrl_data;
		txt_ena <= ctrl_addr[23:16] == 8'h0e;	// text RAM
		chr_ena <= ctrl_addr[23:16] == 8'h0d;	// font ROM

	  if (hit & dx_en)
	  begin
	    dx <= dx + 1;

	    if (dx == 3'b111)
		    dnx <= dnx + 1;

	    if (dnx == chnumx)
	    begin
		    dx_en <= 0;
		    dy <= dy + 1;

		    if (dy == 4'b1111)
		      dny <= dny + 1;
	    end
	  end else
	  begin
	    if (~hit)
	    begin
		    dy <= 0;
		    dny <= 0;
	    end

	    dx <= 3;
	    dnx <= 0;

	    if (col == x && hit)
		    dx_en <= 1;
	  end
  end

  always @(posedge clk or negedge rst)
  if (!rst)
    {txt_addr, tmp_txt_addr, hit, outbyte, char_pixel_out} <= 0;
  else
  begin
	  if (dx == 3'b110 & dx_en)
	    outbyte <= (dy[0] == 1'b0 ? chr_dob[7:0] : chr_dob[15:8]);
	  else
	    outbyte <= {outbyte[6:0], 1'b0};

    if (outbyte[7])
  	  char_pixel_out <= 16'hffff;
    else
      char_pixel_out <= 0;

	  if (hit)
	  begin
	    if (dny == chnumy)
		    hit <= 0;

	    if (dx == 3'b010)
		    txt_addr <= txt_addr + 1;

	    if (dx == 3'b100)
	    begin
		    if (~txt_addr[12])
		      colorchar <= txt0_dob[15:0];
		    else
		      colorchar <= txt1_dob[15:0];
	    end

	    if (~dx_en & dnx == chnumx)
	    begin
		    if (dy != 0)
		      txt_addr <= tmp_txt_addr;
		    else
		      txt_addr <= tmp_txt_addr + chnumx;  /* advance to next character row */
	    end

	    if (dx_en & dnx == 0)
		    tmp_txt_addr <= txt_addr;
	  end else
	  begin
	    outbyte <= {outbyte[6:0], 1'b0};

	    if (row == y && col == x && enabled)      // check if we reached the rectangle of the char display
	    begin
		    hit <= 1;
		    txt_addr <= 0;
		    tmp_txt_addr <= 0;
	    end
	  end
  end

  /* char_active: 2-cycle delay of in_window to align with char_pixel_out */
  always @(posedge clk or negedge rst)
  if (!rst)
    {in_window_d1, char_active} <= 2'b0;
  else
  begin
    in_window_d1 <= in_window;
    char_active  <= in_window_d1;
  end

  always @(posedge clk or negedge rst)
  if (!rst)
  begin
		x <= 11'h003;
	  y <= 0;
	  chnumx <= 32;
	  chnumy <= 10;
	  enabled <= 0;
  end else
  begin
	  /* CPU can write x/y/chnumx/chnumy at ctrl_addr[23:16] == 8'h0c */
	  if (ctrl_we && ctrl_addr[23:16] == 8'h0c)
	  begin
	    case (ctrl_addr[2:0])
		    3'd0: x       <= ctrl_data[10:0];
		    3'd1: y       <= ctrl_data[10:0];
		    3'd2: chnumx  <= ctrl_data[7:0];
		    3'd3: {enabled, chnumy} <= {ctrl_data[15], ctrl_data[6:0]};
	    endcase
	  end
  end

endmodule
