/* vga_sprite.v - VGA controller
 *
 * Copyright (C) 2006, Balazs Beregnyei <bereg@impulzus.com>
 * All rights reserved.
 *
 * 2006/12/14
 */

module vga_sprite(clk, rst, row, col, pixel_out, collision, ctrl_addr, ctrl_data, ctrl_we);

    input clk, rst;
    input [10:0] row, col;
    input [15:0] ctrl_data;
    input [15:0] ctrl_addr;
    input ctrl_we;
  
    output [15:0] pixel_out;
    output [3:0] collision;
	
    wire [3:0] active;
    wire [15:0] pixel_out0;
    wire [15:0] pixel_out1;
    wire [15:0] pixel_out2;
    wire [15:0] pixel_out3;
    
    reg [15:0] pixel_out;
    reg [3:0] collision;
  
    vga_sprite_entity s0(clk, rst, row, col, active[0], pixel_out0, ctrl_addr, ctrl_data, ctrl_we, 3'h0);
    vga_sprite_entity s1(clk, rst, row, col, active[1], pixel_out1, ctrl_addr, ctrl_data, ctrl_we, 3'h1);
//    vga_sprite_entity s2(clk, rst, row, col, active[2], pixel_out2, ctrl_addr, ctrl_data, ctrl_we, 3'h2);
//    vga_sprite_entity s3(clk, rst, row, col, active[3], pixel_out3, ctrl_addr, ctrl_data, ctrl_we, 3'h3);

    always @(posedge clk or negedge rst)
    if (!rst)
    begin
	pixel_out <= 0;
	collision <= 0;
    end
    else begin
//	pixel_out <= pixel_out0 | pixel_out1 | pixel_out2 | pixel_out3;
	pixel_out <= pixel_out0 | pixel_out1;
	
	if (active != 1 && active != 2 && active != 4 && active != 8)
	    collision <= collision | active;
    end
        
endmodule

module vga_sprite_entity(clk, rst, row, col, active, pixel_out, ctrl_addr, ctrl_data, ctrl_we, sprite_num);

    input clk, rst;
    input [10:0] row, col;
    input [15:0] ctrl_data;
    input [15:0] ctrl_addr;
    input ctrl_we;
    input [2:0] sprite_num;
    
    output [15:0] pixel_out;
    output active;
	
    reg [10:0] x, y, x0;
    reg [9:0] addrb;
    reg [9:0] base;
    reg [9:0] dx, dy, x_size, y_size, x_size0, y_size0;
    reg active, enabled, hit;
    reg [15:0] pixel_out;

    wire mem_ena = (ctrl_addr[15:13] == 3'b010 && ctrl_addr[12:10] == sprite_num);
    wire [15:0] dob;
    
    RAMB16_S18_S18 ram0(.DOA(), .ADDRA(ctrl_addr[9:0]), .CLKA(clk), .DIA(ctrl_data), .ENA(mem_ena), .SSRA(1'b0), .WEA(ctrl_we), 
			.DOB(dob), .ADDRB(addrb), .CLKB(clk), .DIB(), .ENB(1'b1), .SSRB(1'b0), .WEB(1'b0),
			.DIPA(2'b0));

    always @(posedge clk or negedge rst)
    if (!rst)
	pixel_out <= 0;
    else
	if (hit & enabled & active)
	    pixel_out <= dob;
	else    
	    pixel_out <= 0;

    always @(posedge clk or negedge rst)
    if (!rst)
    begin
	dx <= 0;
	dy <= 0;
	active <= 0;  
	hit <= 0;  
	addrb <= 0;
	x_size0 <= 0;
	y_size0 <= 0;
	x0 <= 0;
    end
    else begin
	if (hit)
	begin
	    if (dx != x_size0)
	    begin
		dx <= dx + 1;
		addrb <= addrb + 1;
		active <= 1;
	    end
	    else begin
		active <= 0;
		
		if (col == x0)
		begin
		    if (dy != y_size0)
		    begin
			dy <= dy + 1;
			dx <= 0;
		    end	
		    else
			hit <= 0;
		end
	    end
	end
	else begin
	
	    active <= 0;
	    
	    if (row == y && col == x && enabled)
	    begin
		hit <= 1;
		dx <= 0;
		dy <= 0;
		addrb <= base;
		x0 <= x;
		x_size0 <= x_size;
		y_size0 <= y_size;
	    end
	end
    end
    
    always @(posedge clk or negedge rst)
    if (!rst)
    begin
	x <= 0;
	y <= 0;	
	x_size <= 0;
	y_size <= 0;
	base <= 0;
	enabled <= 0;	
    end
    else begin
	if (ctrl_we && ctrl_addr[13] == 1 && ctrl_addr[12:10] == sprite_num)
	begin
	    case (ctrl_addr[2:0])
		0:	base <= ctrl_data[9:0];
		1:	x <= ctrl_data;
		2:	y <= ctrl_data;
		3:	x_size <= ctrl_data[9:0];
		4:	{enabled, y_size} <= {ctrl_data[15], ctrl_data[10:0]};
	    endcase
	end
    end
    
endmodule
