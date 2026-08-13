`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//  Copyright 2013-2016 Istvan Hegedus
//
//  FPGATED is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FPGATED is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//
// 
// Create Date:    12:02:05 10/24/2014 
// Design Name: 	 Commodore 16 
// Module Name:    C16.v
// Project Name: 	 FPGATED
//
// Description: 	
//	This module provides the top level framework for FPGATED. It implements a Commodore 16 computer without expansion port.
// It is written for Papilio FPGATED wing 1.x but can be easily modified for any other platforms.
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module C16 (
	input wire CLK28,
	input wire RESET,
	input wire WAIT,
	
	output wire HSYNC,
	output wire VSYNC,
	output wire CSYNC,
	output wire HBLANK,
	output wire VBLANK,
	output wire [3:0] RED,
	output wire [3:0] GREEN,
	output wire [3:0] BLUE,
	
	output wire RAS,
	output wire CAS,
	output wire RW,
	output wire [7:0] A,
	input wire [7:0] DIN,
	output wire [7:0] DOUT,

	output wire CS0, // Select BASIC ROM (low active)
	output wire CS1, // Select Kernal ROM (low active)
	output wire [3:0] ROM_SEL, // 3:2 - Kernal, Cartridge1 HIGH, Function HIGH, Cartridge2 HIGH
	                           // 1:0 - BASIC, Cartridge2 LOW, Function LOW, Cartridge2 LOW

	output wire [13:0] ROM_ADDR,

	input [4:0] JOY0,
	input [4:0] JOY1,
	
	input PS2DAT,
	input PS2CLK,
	
	output IEC_DATAOUT,
	input IEC_DATAIN,
	output IEC_CLKOUT,
	input IEC_CLKIN,
	output IEC_ATNOUT,
	//input IEC_ATNIN,
	output IEC_RESET,
	
	input CASS_READ,
	output CASS_WRITE,
	input CASS_SENSE,
	output CASS_MOTOR,

	input [1:0] SID_TYPE,
	output [17:0] SID_AUDIO,

	output AUDIO_L,
	output AUDIO_R,
	output [5:0] AUDIO_PCM,

	input [13:0] dl_addr,
	input [7:0] dl_data,
	input kernal_dl_write,
	input basic_dl_write,

	output PAL,
	
	input  RS232_RX,
	output RS232_TX,
	input  RS232_DCD,
	input  RS232_DSR,
	output RS232_DTRB,
	output RS232_RTSB,

	output RGBS,

	// External keyboard matrix (shared kbd_typer/kbd_matrix in the SoC):
	// KBD_ROW is the TED keyport row select, KBD_COL_N the active-low
	// column readback, ANDed onto kbus alongside the PS/2 matrix.
	output [7:0] KBD_ROW,
	input [7:0] KBD_COL_N,
	output TICK8,   // pixel clock for framebuffer

	// Expansion bus for the QSPI fastload engine (qspi_slave.v in the SoC):
	// live address + wired-AND read data, plus once-per-CPU-cycle strobes
	// (trailing-edge detected) for the $FE2x register accesses.
	output [15:0] EXP_ADDR,
	input  [7:0]  EXP_RDATA,   // must be 8'hFF when the address isn't the slave's
	output [3:0]  EXP_LADDR,
	output [7:0]  EXP_WDATA,
	output        EXP_WSTB,
	output        EXP_RSTB
    );

parameter MODE_PAL = 1;
parameter INTERNAL_ROM = 1;
parameter HAS_FUNCTION_ROM = 0;  // 1 for Plus/4 (3+1 software)

wire [15:0] c16_addr;
wire [15:0] ted_addr;
wire [15:0] cpu_addr;
wire [7:0] c16_data,ted_data,ram_data,cpu_data,basic_data,kernal_data,port_in,port_out,keyport_data,uart_data;
wire [7:0] keyboard_row,kbus,kbus_kbd;
wire [7:0] keyscancode;
wire keyreceived;
wire [6:0] c16_color;
wire mux,cpuenable;
wire aec,rdy;
wire keyboardio;
wire uart_cs;
wire sound;
reg [7:0] c16_datalatch=8'b0;
reg sreset=1'b0;
reg [23:0] resetcounter=24'b0;
reg [15:0] c16_addrlatch=16'b0;
wire irq1;
wire keyreset;

// wire joysticks
// Joystick active-low: 0=pressed.  On the 264 machines the joysticks are
// NOT selected by the 6529 row register: the select lines are the DATA BUS
// bits driven during the $FF08 keyboard-latch WRITE (TED latches kbus on
// that write).  BASIC 3.5 JOY() writes $FA (bit2 low = joy1) / $FD (bit1
// low = joy2) — verified by disassembling the JOY() routine at $BFC4 and
// the KERNAL scan at $DB70 (STA $FD30 : STA $FF08 : LDA $FF08).  Gating on
// keyboard_row (the old code) left the joysticks permanently deselected
// for every real reader.  Side effect of the correct gating: a held
// joystick ghosts onto keyboard rows whose scan mask clears bit1/bit2 —
// exactly what real hardware does.
wire ff08_wr = (c16_addr == 16'hFF08) && !RW;
wire [4:0] joy0_sel = (ff08_wr && !c16_data[2]) ? {JOY0[4],JOY0[0],JOY0[1],JOY0[2],JOY0[3]} : 5'h1f;
wire [4:0] joy1_sel = (ff08_wr && !c16_data[1]) ? {JOY1[4],JOY1[0],JOY1[1],JOY1[2],JOY1[3]} : 5'h1f;
assign kbus[3:0] = kbus_kbd[3:0] & KBD_COL_N[3:0] & joy0_sel[3:0] & joy1_sel[3:0];
assign kbus[5:4] = kbus_kbd[5:4] & KBD_COL_N[5:4]; // no joystick line connected here
assign kbus[6] = kbus_kbd[6] & KBD_COL_N[6] & joy0_sel[4];
assign kbus[7] = kbus_kbd[7] & KBD_COL_N[7] & joy1_sel[4];
assign KBD_ROW = keyboard_row;
assign ROM_ADDR = c16_addr[13:0];

reg [3:0] rom_sel_reg;
wire kern = c16_addr[15:8] == 8'hFC; // FCXX is always kernal
assign ROM_SEL = { rom_sel_reg[3:2] & { ~kern, ~kern }, rom_sel_reg[1:0] };

always @(posedge CLK28) begin
	if (sreset)
		rom_sel_reg <= 0;
	else begin
		// FDD0-FDDF is ROM banking address
		if (c16_addr[15:4] == 12'hFDD && ~RW) rom_sel_reg <= c16_addr[3:0];
	end
end

// 8501 CPU
	mos8501 cpu (
		.clk(CLK28),
		.reset(sreset),
		.enable(cpuenable && !WAIT && rdy),
		.irq_n(ted_irq_n & acia_irq_n),
		.data_in(c16_data), 
		.data_out(cpu_data), 
		.address(cpu_addr),
		.gate_in(mux),
		.rw(RW),								// rw=high read, rw=low write
		.port_in(port_in),
		.port_out(port_out),
		.rdy(rdy),
		.aec(aec)
	);

// TED 8360 instance	
wire ted_irq_n, cpuclk;

ted mos8360(
	.clk(CLK28),
	.addr_in(c16_addr),
	.addr_out(ted_addr),
	.data_in(c16_data),
	.data_out(ted_data),
	.rw(RW),
	.cpuclk(cpuclk),
	.color(c16_color),
	.csync(CSYNC),
	.hsync(HSYNC),
	.vsync(VSYNC),
	.blankh(HBLANK),
	.blankv(VBLANK),
	.irq(ted_irq_n),
	.ba(rdy),
	.mux(mux),
	.ras(RAS),
	.cas(CAS),
	.cs0(CS0),
	.cs1(CS1),
	.aec(aec),
	.k(kbus),
	.snd(sound),
	.snd_pcm(AUDIO_PCM),
	.pal(PAL),
	.cpuenable(cpuenable),
	.tick8_out(TICK8)
	);
	
// Kernal rom

	kernal_rom #(.MODE_PAL(MODE_PAL)) kernal(
		.clk(CLK28),
		.address_in(kernal_dl_write?dl_addr:c16_addr[13:0]),
		.data_out(kernal_data_int),
		.data_in(dl_data),
		.wr(kernal_dl_write),
		.cs(CS1)
		);
wire [7:0] kernal_data_int;

// Basic rom
	basic_rom basic(
		.clk(CLK28),
		.address_in(basic_dl_write?dl_addr:c16_addr[13:0]),
		.data_out(basic_data_int),
		.data_in(dl_data),
		.wr(basic_dl_write),
		.cs(CS0)
		);
wire [7:0] basic_data_int;

// Function ROMs (3+1 software, Plus/4 only)
generate if (HAS_FUNCTION_ROM) begin : func_roms
	// Function LOW ROM ($8000-$BFFF when rom_sel[1:0]==1)
	reg [7:0] func_lo [0:16383];
	reg [7:0] func_lo_data;
	reg func_lo_cs_prev;
	wire func_lo_en = ~CS0 & func_lo_cs_prev & (rom_sel_reg[1:0] == 2'd1);
	initial $readmemh("../roms/3plus1lo.hex", func_lo);
	always @(posedge CLK28) begin
		func_lo_cs_prev <= CS0;
		if (func_lo_en) func_lo_data <= func_lo[c16_addr[13:0]];
	end
	wire [7:0] func_lo_out = (~CS0 & rom_sel_reg[1:0] == 2'd1) ? func_lo_data : 8'hFF;

	// Function HIGH ROM ($C000-$FFFF when rom_sel[3:2]==1)
	reg [7:0] func_hi [0:16383];
	reg [7:0] func_hi_data;
	reg func_hi_cs_prev;
	wire func_hi_en = ~CS1 & func_hi_cs_prev & (rom_sel_reg[3:2] == 2'd1);
	initial $readmemh("../roms/3plus1hi.hex", func_hi);
	always @(posedge CLK28) begin
		func_hi_cs_prev <= CS1;
		if (func_hi_en) func_hi_data <= func_hi[c16_addr[13:0]];
	end
	wire [7:0] func_hi_out = (~CS1 & rom_sel_reg[3:2] == 2'd1) ? func_hi_data : 8'hFF;

	// Banking via ROM_SEL (which masks $FCxx to always use KERNAL)
	// ROM_SEL[1:0]==1 → Function LOW; ROM_SEL[3:2]==1 → Function HIGH
	assign basic_data  = (ROM_SEL[1:0] == 2'd1) ? func_lo_out : (INTERNAL_ROM ? basic_data_int : (~CS0 & RW) ? DIN : 8'hFF);
	assign kernal_data = (ROM_SEL[3:2] == 2'd1) ? func_hi_out : (INTERNAL_ROM ? kernal_data_int : (~CS1 & RW) ? DIN : 8'hFF);
end else begin : no_func_roms
	assign basic_data  = INTERNAL_ROM ? basic_data_int : (~CS0 & RW) ? DIN : 8'hFF;
	assign kernal_data = INTERNAL_ROM ? kernal_data_int : (~CS1 & RW) ? DIN : 8'hFF;
end endgenerate
// Color decoder to 12bit RGB	
 
colors_to_rgb colordecode (
	.clk(CLK28),
	.color(c16_color),
	.red(RED),
	.green(GREEN),
	.blue(BLUE)
	);

// keyboard part

wire ps2_keyreceived;
wire [7:0] ps2_keyscancode;

ps2receiver ps2rcv(
    .clk(CLK28),
    .ps2_clk(PS2CLK),
    .ps2_data(PS2DAT),
    .rx_done(ps2_keyreceived),
    .ps2scancode(ps2_keyscancode)
    );

assign keyreceived = ps2_keyreceived;
assign keyscancode = ps2_keyscancode;

c16_keymatrix keyboard(
	 .clk(CLK28),
    .scancode(keyscancode),
    .receiveflag(keyreceived),
	 .row(keyboard_row),
    .kbus(kbus_kbd),
	 .keyreset(keyreset)
    );

mos6529 keyport(
	 .clk(CLK28),
    .data_in(c16_data),
    .data_out(keyport_data),
    .port_in(keyboard_row),	// keyport 6529 in C16 is unidirectional however if we read it the last written data is read back so we feed back its output.
    .port_out(keyboard_row),
    .rw(RW),
    .cs(keyboardio)
    );

assign uart_cs=(c16_addr[15:4] == 12'hfd0);
reg clk_18432en;
reg  [31:0] clk_cnt_uart;
wire [31:0] clk_rate = PAL ? 32'd28_375_168 : 32'd28_636_352;

always @(posedge CLK28) begin
	if(sreset) begin
		clk_cnt_uart <= 32'd0;
		clk_18432en <= 1'b0;
	end else begin
		clk_18432en <= 1'b0;

		if(clk_cnt_uart < clk_rate)
			clk_cnt_uart <= clk_cnt_uart + 32'd1_843_200;
		else begin
			clk_cnt_uart <= clk_cnt_uart - clk_rate + 32'd1_843_200;
			clk_18432en <= 1'b1;
		end
	end
end

wire acia_irq_n;

gen_uart_mos_6551 uart
(
	.reset(sreset),
	.clk(CLK28),
	.clk_en(clk_18432en),
	.din(c16_data),
	.dout(uart_data),
	.rnw(RW),
	.irq_n(acia_irq_n),
	.cs(uart_cs),
	.rs(c16_addr[1:0]),

	.cts_n(1'b0),
	.rx(RS232_RX),
	.tx(RS232_TX),
	.dcd_n(~RS232_DCD),
	.dsr_n(~RS232_DSR),
	.dtr_n(RS232_DTRB),
	.rts_n(RS232_RTSB)
);

assign AUDIO_R=sound;
assign AUDIO_L=sound;
assign RGBS=1'bz;				// VGA/RGBS jumper is not implemented in current version

assign keyboardio=(c16_addr[15:4]==12'hfd3)?1'b1:1'b0;		// as we don't have PLA, keyport is identified here

// C16 additional motherboard functions


always @(posedge CLK28)		// reset tries to emulate the length of a real reset
	begin
	if(RESET|keyreset) begin		// reset can be triggered by reset button or CTRL+ALT+DEL from keyboard
		resetcounter<=0;
		sreset<=1;
	end else begin
		if(resetcounter==24'd16777215)
			sreset<=0;
		else begin
			resetcounter<=resetcounter+1'd1;
			sreset<=1;
			end
		end
	end	
	
// assign VSYNC=1'b1; // set scart mode to RGB for TV

assign c16_addr=(~mux)?c16_addrlatch:cpu_addr&ted_addr;																	// C16 address bus
assign c16_data=(mux)?c16_datalatch:cpu_data&ted_data&ram_data&kernal_data&basic_data&keyport_data&cass_data&sid_data&uart_data&openbus_data&exp_data;	// C16 data bus

always @(posedge CLK28)							// addres and data bus latching emulates dynamic memory behaviour of these buses 
	begin
	c16_datalatch<=c16_data;
	c16_addrlatch<=c16_addr;
	end

// external 4464 DRAM signal connections on Papilio FPGATED wing

assign A=(~mux)?c16_addr[15:8]:c16_addr[7:0];	//  DRAM address multiplexer for TMS4464 address lines
assign DOUT=c16_data;					// only drive external TMS4464 data lines when there is a write cycle

assign ram_data=(RW & ~CAS)?DIN:8'hff;				// internal ram_data should be 0xff when external RAM's data line is in high impedance state

// connect IEC bus

assign IEC_DATAOUT=~port_out[0];
assign port_in[7]=IEC_DATAIN & IEC_DATAOUT;
assign IEC_CLKOUT=~port_out[1];
assign port_in[6]=IEC_CLKIN & IEC_CLKOUT;
assign IEC_ATNOUT=~port_out[2];
//assign ATN=IEC_ATNIN;
assign IEC_RESET=sreset;

assign     CASS_MOTOR = port_out[3];
assign     port_in[5] = 1'b1;          // pull-up
assign     port_in[4] = CASS_READ;
assign     port_in[3] = 1'b1;          // pull-up
assign     port_in[2] = 1'b1;          // pull-up
assign     port_in[1] = 1'b1;          // pull-up
assign     port_in[0] = 1'b1;          // pull-up
wire       cass_sel   = cpu_addr[15:4] == 12'hFD1;
wire [7:0] cass_data  = { 5'b11111, cass_sel ? CASS_SENSE : 1'b1, 2'b11 };
assign     CASS_WRITE = port_out[6];

wire       openbus_sel = cpu_addr[15:5] == {8'hFD, 3'b111};
wire [7:0] openbus_data = openbus_sel ? c16_datalatch : 8'hff;

// QSPI fastload expansion window ($FE20-$FE2F regs; $FD60-$FDCF routine ROM
// decoded inside qspi_slave). The address bus is stable for the whole CPU
// cycle, so the write-data/strobe capture is level-latched and the strobe
// fires on the TRAILING edge of the access — exactly once per CPU cycle,
// after the CPU has sampled read data (safe for the FIFO-pop side effect).
assign EXP_ADDR = c16_addr;
// The strobes must fire EXACTLY once per CPU access. Level/trailing-edge
// detection on the bus is unreliable here (RW and the muxed address have
// sub-cycle phases, which double-fired the FIFO pop), so sample at the
// same instant the 8501 itself advances: the TED cpuenable pulse gated by
// rdy/WAIT — one pulse per true CPU cycle, with cpu_addr/RW/data still
// holding that cycle's values.
wire exp_io_sel = (cpu_addr[15:4] == 12'hFE2);
wire exp_cycle  = cpuenable & rdy & ~WAIT;
reg  exp_wstb_r = 0, exp_rstb_r = 0;
reg [3:0] exp_laddr_lat = 0;
reg [7:0] exp_wdata_lat = 0;
always @(posedge CLK28) begin
	exp_wstb_r <= exp_cycle & exp_io_sel & ~RW;
	exp_rstb_r <= exp_cycle & exp_io_sel & RW;
	if (exp_cycle & exp_io_sel) begin
		exp_laddr_lat <= cpu_addr[3:0];
		exp_wdata_lat <= c16_data;   // write value (ignored for reads)
	end
end
assign EXP_WSTB  = exp_wstb_r;
assign EXP_RSTB  = exp_rstb_r;
assign EXP_LADDR = exp_laddr_lat;
assign EXP_WDATA = exp_wdata_lat;
wire [7:0] exp_data = RW ? EXP_RDATA : 8'hff;

// SID extension
reg sid_clk_en;
reg sid_muxD, sid_clk;
always @(posedge CLK28) begin
	sid_clk_en <= 0;
	sid_muxD <= mux;
	if (~sid_muxD & mux) begin
		sid_clk <= ~sid_clk;
		sid_clk_en <= sid_clk;
	end
end

// valid adresses for SID: FD40-FD5F and FE80-FE9F
wire cs_sid = SID_TYPE && ((c16_addr[15:5] == 'b1111_1101_010) || (c16_addr[15:5] == 'b1111_1110_100));

wire  [7:0] sid8580_data;
wire [15:0] sid8580_audio;

sid8580 sid8580
(
	.reset(sreset),
	.clk32(CLK28),
	.clk_1MHz(sid_clk_en),

	.cs(cs_sid),
	.we(~RW),
	.addr(c16_addr[4:0]),
	.data_in(c16_data),
	.data_out(sid8580_data),

	.extfilter_en(1),
	.audio_data(sid8580_audio)
);

wire  [7:0] sid6581_data;
wire [17:0] sid6581_audio;

sid_top #(.g_num_voices(3)) sid6581
(
	.reset(sreset),
	.clock(CLK28),
	.start_iter(sid_clk_en),

	.wren(~RW & cs_sid),
	.addr({ 3'd0, c16_addr[4:0] }),
	.wdata(c16_data),
	.rdata(sid6581_data),

	.extfilter_en(1),
	.sample_left(sid6581_audio)
);

assign      SID_AUDIO = SID_TYPE[0] ? sid6581_audio : (SID_TYPE[1] ? { sid8580_audio, 2'd0 } : 18'd0);
wire  [7:0] sid_data  = (cs_sid & RW) ? (SID_TYPE[0] ? sid6581_data : sid8580_data) : 8'hFF;

endmodule
