/*
 * sid_top.v — SID register file + voice/table/filter sequencing
 *
 * Single-SID plain-Verilog rewrite of the MiSTer C64 sid_top.sv (GPL).
 * The DUAL second chip, the MULTI_FILTERS curve bank, the ld_* runtime
 * table-load port, the ext audio input and the unused filter_en port
 * are dropped; everything the one chip computes is bit-identical to
 * upstream with DUAL=0 (including the state-6 → state-14 audio commit
 * and the sid_tables time-multiplexing across the three voices).
 *
 * Bus protocol (matches the c64 soc.v live-bus scheme):
 *   - cs is a one-clk pulse at the write-commit tick (phi2_n); writes
 *     latch data_in, reads refresh the open-bus byte (bus_data).
 *   - data_out is COMBINATIONAL from addr (pot/OSC3/ENV3, else the
 *     open-bus byte) so the CPU's cpu_rdy-tick capture sees it live —
 *     same pattern as vicii dbo_live / mos6526 db_out_live (the Arlet
 *     combinational-AB trap).  SID reads have no side effects.
 *
 *   ce_1m — one-clk pulse per 1 MHz cycle (phi2); the internal state
 *   counter needs >= 16 clks between pulses (dot4x gives 32).
 */

module sid_top
(
	input         reset,       // active high

	input         clk,
	input         ce_1m,

	input         cs,
	input         we,
	input   [4:0] addr,
	input   [7:0] data_in,
	output  [7:0] data_out,

	input   [7:0] pot_x,
	input   [7:0] pot_y,

	input         mode,        // 0 = 6581, 1 = 8580
	input  [12:0] fc_offset,

	output signed [17:0] audio
);

/* ── Register file ─────────────────────────────────────────────────── */
reg [15:0] Voice_1_Freq;
reg [11:0] Voice_1_Pw;
reg  [7:0] Voice_1_Control;
reg  [7:0] Voice_1_Att_dec;
reg  [7:0] Voice_1_Sus_Rel;

reg [15:0] Voice_2_Freq;
reg [11:0] Voice_2_Pw;
reg  [7:0] Voice_2_Control;
reg  [7:0] Voice_2_Att_dec;
reg  [7:0] Voice_2_Sus_Rel;

reg [15:0] Voice_3_Freq;
reg [11:0] Voice_3_Pw;
reg  [7:0] Voice_3_Control;
reg  [7:0] Voice_3_Att_dec;
reg  [7:0] Voice_3_Sus_Rel;

reg [10:0] Filter_Fc;
reg  [7:0] Filter_Res_Filt;
reg  [7:0] Filter_Mode_Vol;

reg  [7:0] bus_data;          // open-bus: last byte seen on the SID bus

wire [7:0] Misc_Osc3;
wire [7:0] Misc_Env3;

assign data_out = (addr == 5'h19) ? pot_x :
                  (addr == 5'h1a) ? pot_y :
                  (addr == 5'h1b) ? Misc_Osc3 :
                  (addr == 5'h1c) ? Misc_Env3 :
                                    bus_data;

always @(posedge clk) begin
	if (reset) begin
		Voice_1_Freq    <= 0;
		Voice_1_Pw      <= 0;
		Voice_1_Control <= 0;
		Voice_1_Att_dec <= 0;
		Voice_1_Sus_Rel <= 0;
		Voice_2_Freq    <= 0;
		Voice_2_Pw      <= 0;
		Voice_2_Control <= 0;
		Voice_2_Att_dec <= 0;
		Voice_2_Sus_Rel <= 0;
		Voice_3_Freq    <= 0;
		Voice_3_Pw      <= 0;
		Voice_3_Control <= 0;
		Voice_3_Att_dec <= 0;
		Voice_3_Sus_Rel <= 0;
		Filter_Fc       <= 0;
		Filter_Res_Filt <= 0;
		Filter_Mode_Vol <= 0;
	end
	else if (cs) begin
		bus_data <= we ? data_in : data_out;
		if (we) begin
			case (addr)
				5'h00: Voice_1_Freq[7:0]  <= data_in;
				5'h01: Voice_1_Freq[15:8] <= data_in;
				5'h02: Voice_1_Pw[7:0]    <= data_in;
				5'h03: Voice_1_Pw[11:8]   <= data_in[3:0];
				5'h04: Voice_1_Control    <= data_in;
				5'h05: Voice_1_Att_dec    <= data_in;
				5'h06: Voice_1_Sus_Rel    <= data_in;
				5'h07: Voice_2_Freq[7:0]  <= data_in;
				5'h08: Voice_2_Freq[15:8] <= data_in;
				5'h09: Voice_2_Pw[7:0]    <= data_in;
				5'h0a: Voice_2_Pw[11:8]   <= data_in[3:0];
				5'h0b: Voice_2_Control    <= data_in;
				5'h0c: Voice_2_Att_dec    <= data_in;
				5'h0d: Voice_2_Sus_Rel    <= data_in;
				5'h0e: Voice_3_Freq[7:0]  <= data_in;
				5'h0f: Voice_3_Freq[15:8] <= data_in;
				5'h10: Voice_3_Pw[7:0]    <= data_in;
				5'h11: Voice_3_Pw[11:8]   <= data_in[3:0];
				5'h12: Voice_3_Control    <= data_in;
				5'h13: Voice_3_Att_dec    <= data_in;
				5'h14: Voice_3_Sus_Rel    <= data_in;
				5'h15: Filter_Fc[2:0]     <= data_in[2:0];
				5'h16: Filter_Fc[10:3]    <= data_in;
				5'h17: Filter_Res_Filt    <= data_in;
				5'h18: Filter_Mode_Vol    <= data_in;
			endcase
		end
	end
end

/* ── Voices ────────────────────────────────────────────────────────── */
wire [21:0] voice_1, voice_2, voice_3;
wire        voice_1_PA_MSB, voice_2_PA_MSB, voice_3_PA_MSB;
wire [11:0] acc_t_1, acc_t_2, acc_t_3;

/* per-voice combined-waveform bytes, refreshed by the table sequencer */
reg [7:0] st_v1, st_v2, st_v3;
reg [7:0] pt_v1, pt_v2, pt_v3;
reg [7:0] ps_v1, ps_v2, ps_v3;
reg [7:0] pst_v1, pst_v2, pst_v3;

sid_voice v1
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.mode(mode),
	.freq(Voice_1_Freq),
	.pw(Voice_1_Pw),
	.control(Voice_1_Control),
	.att_dec(Voice_1_Att_dec),
	.sus_rel(Voice_1_Sus_Rel),
	.osc_msb_in(voice_3_PA_MSB),
	.osc_msb_out(voice_1_PA_MSB),
	.voice_out(voice_1),
	.osc_out(),
	.env_out(),
	._st_out(st_v1),
	.p_t_out(pt_v1),
	.ps__out(ps_v1),
	.pst_out(pst_v1),
	.acc_t(acc_t_1)
);

sid_voice v2
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.mode(mode),
	.freq(Voice_2_Freq),
	.pw(Voice_2_Pw),
	.control(Voice_2_Control),
	.att_dec(Voice_2_Att_dec),
	.sus_rel(Voice_2_Sus_Rel),
	.osc_msb_in(voice_1_PA_MSB),
	.osc_msb_out(voice_2_PA_MSB),
	.voice_out(voice_2),
	.osc_out(),
	.env_out(),
	._st_out(st_v2),
	.p_t_out(pt_v2),
	.ps__out(ps_v2),
	.pst_out(pst_v2),
	.acc_t(acc_t_2)
);

sid_voice v3
(
	.clock(clk),
	.ce_1m(ce_1m),
	.reset(reset),
	.mode(mode),
	.freq(Voice_3_Freq),
	.pw(Voice_3_Pw),
	.control(Voice_3_Control),
	.att_dec(Voice_3_Att_dec),
	.sus_rel(Voice_3_Sus_Rel),
	.osc_msb_in(voice_2_PA_MSB),
	.osc_msb_out(voice_3_PA_MSB),
	.voice_out(voice_3),
	.osc_out(Misc_Osc3),
	.env_out(Misc_Env3),
	._st_out(st_v3),
	.p_t_out(pt_v3),
	.ps__out(ps_v3),
	.pst_out(pst_v3),
	.acc_t(acc_t_3)
);

/* ── Shared wave-table sequencing ──────────────────────────────────────
 * One sid_tables instance serves all three voices, time-multiplexed on
 * the state counter (reset by ce_1m, saturates at 15): the ROM address
 * is loaded at states 1/3/5 and the registered ROM output is captured
 * two states later (3/5/7), voice order 1,2,3 — exactly upstream's
 * schedule for chip 0. */
wire [15:0] F0;
wire  [7:0] f__st_out, f_p_t_out, f_ps__out, f_pst_out;
reg  [11:0] f_acc_t;
reg   [3:0] state;
reg   [1:0] v;

sid_tables sid_tables
(
	.clock(clk),
	.mode(mode),

	.acc_t(f_acc_t),
	._st_out(f__st_out),
	.p_t_out(f_p_t_out),
	.ps__out(f_ps__out),
	.pst_out(f_pst_out),

	.Fc(Filter_Fc),
	.Fc_offset(fc_offset),
	.F0(F0)
);

always @(posedge clk) begin
	if (~&state) state <= state + 1'd1;
	if (ce_1m) state <= 0;

	case (state)
		4'd1, 4'd3, 4'd5: begin
			f_acc_t <= (state[2:1] == 2'd0) ? acc_t_1 :
			           (state[2:1] == 2'd1) ? acc_t_2 : acc_t_3;
			v <= state[2:1];
		end
		default: ;
	endcase

	case (state)
		4'd3, 4'd5, 4'd7:
			case (v)
				2'd0: begin
					st_v1  <= f__st_out;
					pt_v1  <= f_p_t_out;
					ps_v1  <= f_ps__out;
					pst_v1 <= f_pst_out;
				end
				2'd1: begin
					st_v2  <= f__st_out;
					pt_v2  <= f_p_t_out;
					ps_v2  <= f_ps__out;
					pst_v2 <= f_pst_out;
				end
				2'd2: begin
					st_v3  <= f__st_out;
					pt_v3  <= f_p_t_out;
					ps_v3  <= f_ps__out;
					pst_v3 <= f_pst_out;
				end
				default: ;
			endcase
		default: ;
	endcase
end

/* ── Filter + mixer ────────────────────────────────────────────────── */
wire [17:0] faudio;

sid_filter sid_filter
(
	.clk(clk),
	.state(state[2:0]),
	.mode(mode),

	.F0(F0),
	.Res_Filt(Filter_Res_Filt),
	.Mode_Vol(Filter_Mode_Vol),
	.voice1(voice_1),
	.voice2(voice_2),
	.voice3(voice_3),
	.ext_in(22'sd0),

	.audio(faudio)
);

/* upstream commit schedule: capture at state 6, publish at state 14 */
reg [17:0] audio0, audio_q;
always @(posedge clk) begin
	if (state == 4'd6)  audio0  <= faudio;
	if (state == 4'd14) audio_q <= audio0;
end

assign audio = audio_q;

endmodule
