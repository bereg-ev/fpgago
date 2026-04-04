
/* sdram.v - SDRAM controller
 *
 * Copyright (C) 2014, Balazs Beregnyei <balazs.beregnyei@gmail.com>
 * All rights reserved.
 *
 * 2014/06/09
 */

`include "project.vh"

// Elpida EDS2516ADTA: (4 bank x 13 bit row x 9 bit col) x 16 bit

`define		CMD_NOP   				3'b111
`define		CMD_PRECHARGE  		3'b010
`define		CMD_AUTO_REFRESH		3'b001
`define		CMD_LOAD_MODE_REG		3'b000
`define		CMD_ACTIVE   			3'b011
`define		CMD_READ   				3'b101
`define		CMD_WRITE  				3'b100


module sdram(
	input clk,
	input rst,
	input [14:0] r_row,
	input [14:0] w_row,

	output reg [(`SD_WIDTH - 1):0] bram_di,
	input [(`SD_WIDTH - 1):0] bram_do,
	output reg bram_we,

	input start_read,
	input start_write,
	input start_init,
	output reg rdy,
	output reg [(`BRAM_ADDR_WIDTH - 1):0] w_addr,
	output reg [(`BRAM_ADDR_WIDTH - 1):0] r_addr,
	input [(`BRAM_ADDR_WIDTH - 1):0] w_stop,
	input [(`BRAM_ADDR_WIDTH - 1):0] w_col,
	input [(`BRAM_ADDR_WIDTH - 1):0] w_addr_start,
	input [(`BRAM_ADDR_WIDTH - 1):0] r_col,
	input [(`BRAM_ADDR_WIDTH - 1):0] r_stop,

	output reg sd_cke,
	output reg sd_cs,
	output reg sd_ras,
	output reg sd_cas,
	output reg sd_we,
	output reg [12:0] sd_a,
	inout [(`SD_WIDTH - 1):0] sd_d,
	output reg [1:0] sd_ba,

	output sd_ldqm,
	output sd_udqm,

	input fill_en,
	input [15:0] fill_const,
	output [7:0] dbg,
	output wire write_pending
	);

	assign {sd_udqm, sd_ldqm} = 2'b00;
	assign write_pending = (start_write != start_write0);

	reg [2:0] read_cmd, write_cmd, init_cmd, rdy_cmd;		// RAS, CAS, WE signals during read, write, init
	reg read, write, init, initialized, write_burst, write_burst2;
	reg [12:0] a_r, a_r_abs, a_w, a_i;

	assign dbg = {3'h0, read, write, init, initialized, rdy};

	always @(posedge clk or negedge rst)
	if (!rst)
		{initialized, write_burst2, sd_ras, sd_cas, sd_we, sd_a, sd_ba, sd_cs, sd_cke, write_burst2} <= 0;
	else
	begin
		initialized <= initialized | init;
		{sd_ras, sd_cas, sd_we} <= init ? init_cmd : (read ? read_cmd : (write ? write_cmd : rdy_cmd));
		{sd_cs, sd_cke} <= (init | read | write) ? 2'b01 : 2'b10;
		sd_ba <= init ? 2'h0 : (read ? r_row[1:0] : (write ? w_row[1:0] : 2'h0));
		sd_a <= init ? a_i : (read ? a_r : (write ? a_w : 0));
		write_burst2 <= write_burst;
	end

	reg [7:0] refresh_cnt;

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
		{rdy, refresh_cnt} <= 0;
		rdy_cmd <= `CMD_NOP;
	end else
	begin
		refresh_cnt <= refresh_cnt + 1;
		rdy <= initialized ? ~(read | write | init) : (rdy | init);
		rdy_cmd = (refresh_cnt == 8'hff) ? `CMD_AUTO_REFRESH : `CMD_NOP;
	end

	assign sd_d = write_burst2 ? (fill_en ? fill_const : bram_do) : 16'bZ;

//	---------------- INIT state machine --------------------------------

	reg start_init0;
	reg [8:0] init_sh;
`ifdef SIMULATION
	reg [1:0] init_wait;
`else
	reg [7:0] init_wait;
`endif

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
		{start_init0, init, init_sh, init_wait, a_i} <= 0;
		init_cmd <= `CMD_NOP;
	end else
	begin
		if (!init && start_init != start_init0)
		begin
			init <= 1;
			start_init0 <= start_init;
			init_wait <= 0;
			init_sh <= 1;
		end

		if (init)
		begin
			init_wait <= init_wait + 1;

			if (init_wait == 0)
				init_sh <= {init_sh[7:0], 1'b0};

			if (init_sh[1] && init_wait == 0)
				init_cmd <= `CMD_PRECHARGE;
			else if ((init_sh[2] || init_sh[3]) && init_wait == 0)
				init_cmd <= `CMD_AUTO_REFRESH;
			else if (init_sh[4] && init_wait == 0)
			begin
				init_cmd <= `CMD_LOAD_MODE_REG;
				a_i <= 13'h0030;			// 0020: CAS latency = 2, 0030: CAS latency = 3
												// xxx7: full page, xxx0: single
			end
			else if ((init_sh[5] || init_sh[6]) && init_wait == 0)
				init_cmd <= `CMD_AUTO_REFRESH;
			else
			begin
				init_cmd <= `CMD_NOP;
				a_i <= 13'h0400;			// A10 = 1: PRECHARGE all
			end
		end

		if (init_sh[8])
			init <= 0;
    end

//	---------------- READ state machine --------------------------------

	reg start_read0, read_burst, readst0, readst1, readst2, we0, we1, we2, rrefresh;
	reg [8:0] read_sh;
	reg [(`BRAM_ADDR_WIDTH - 1):0] r_addr0, r_addr1, r_addr2;
	wire read_go = rdy && initialized && (start_init == start_init0) && (start_read != start_read0);
	    // priority: 1) init, 2) read, 3) write

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
		{start_read0, read, read_sh, read_cmd, a_r, read_burst, readst0, readst1, readst2} <= 0;
		{bram_we, we0, we1, bram_di, r_addr, r_addr0, r_addr1, r_addr2, rrefresh, a_r_abs} <= 0;
	end else
	begin
		if (read_go)
		begin
			read <= 1;
			read_cmd <= `CMD_NOP;
			read_burst <= 0;
			start_read0 <= start_read;
		end

		read_sh <= {read_sh[7:0], read_go};

		if (read_sh[0] == 1'b1)
		begin
			read_cmd <= `CMD_PRECHARGE;
			a_r <= 0;
		end
		else if (read_sh[1] == 1'b1)
			read_cmd <= `CMD_NOP;
		else if (read_sh[2] == 1'b1)
		begin
			read_cmd <= `CMD_NOP;
			a_r <= r_row[14:2];
		end
		else if (read_sh[3] == 1'b1)
		begin
			read_cmd <= `CMD_ACTIVE;
		end
		else if (read_sh[4] == 1'b1)
		begin
			read_cmd <= `CMD_NOP;
			a_r <= r_col;
			a_r_abs <= 0;
		end
		else if (read_sh[5] == 1'b1)
			read_cmd <= `CMD_NOP;
		else if (read_sh[6] == 1'b1)
		begin
			read_cmd <= `CMD_READ;
			read_burst <= 1;
		end
		else if (read_burst)
			read_cmd <= `CMD_READ;
		else if (rrefresh)
		begin
			read_cmd <= `CMD_AUTO_REFRESH;
			rrefresh <= 0;
		end
		else
			read_cmd <= `CMD_NOP;

		if (read_burst)
		begin
			a_r <= a_r + 1;
			a_r_abs <= a_r_abs + 1;

			if (a_r[8:0] == r_stop[8:0])
				{rrefresh, read_burst, readst0, read_cmd} <= {3'b101, `CMD_NOP}; //3'h7};
		end
		else
				readst0 <= 0;

		{bram_we, we0, we1, we2} <= {we0, we1, we2, read_burst};
		r_addr <= r_addr2;
		r_addr2 <= r_addr1;
		r_addr1 <= r_addr0;
		r_addr0 <= a_r_abs; // a_r;
		bram_di <= sd_d;

		readst1 <= readst0;
		readst2 <= readst1;

		if (readst2)
			read <= 0;
	end

//	---------------- WRITE state machine --------------------------------

	reg start_write0, wrefresh;
	reg [8:0] write_sh;
	wire write_go = rdy && initialized && (start_init == start_init0) && (start_read == start_read0) && (start_write != start_write0);
	    // priority: 1) init, 2) read, 3) write

	always @(posedge clk or negedge rst)
	if (!rst)
	begin
		{start_write0, write, write_cmd, write_sh, a_w, write_burst, wrefresh, w_addr} <= 0;
	end else
	begin
		if (write_go)
		begin
			write <= 1;
			start_write0 <= start_write;
			write_cmd <= `CMD_NOP;
			a_w <= 0;
			w_addr <= w_addr_start;
		end

		write_sh <= {write_sh[7:0], write_go};

		if (write_sh[0] == 1'b1)
		begin
			write_cmd <= `CMD_PRECHARGE;
			a_w <= 0;
		end
		else if (write_sh[3] == 1'b1)
		begin
			write_cmd <= `CMD_ACTIVE;
			a_w <= w_row[14:2];
		end
		else if (write_sh[5] == 1'b1)
		begin
		end
		else if (write_sh[6] == 1'b1)
		begin
			write_cmd <= `CMD_WRITE;
			write_burst <= 1;
			a_w[12:0] <= {3'b001, 1'b0, w_col[8:0]};	// A10 = 1: auto precharge
		end
		else if (write_burst)
			write_cmd <= `CMD_WRITE;
		else if (wrefresh)
		begin
			write_cmd <= `CMD_AUTO_REFRESH;
			wrefresh <= 0;
		end
		else
			write_cmd <= `CMD_NOP;

		if (write_burst)
		begin
			a_w <= a_w + 1;
			w_addr <= w_addr + 1;

			if (w_addr[8:0] == w_stop[8:0])
				{wrefresh, write_burst, write, write_cmd} <= {3'b100, `CMD_NOP}; //3'h7};
		end
	end

	always @(posedge clk or negedge rst)
	if (!rst)
	begin

	end else
	begin

	end

endmodule
