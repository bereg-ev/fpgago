/*
 * sid_filter.v — SID state-variable filter + mixer/volume (yosys-safe port)
 *
 * Port of sid_filter.sv: Copyright (C) 2022 Alexey Melnikov, based on
 * the filter from reDIP-SID, Copyright (C) 2022 Dag Lem
 * (CERN-OHL-S v2, https://github.com/daglem/reDIP-SID).
 *
 * Behavior unchanged.  The port expands the SV size casts to explicit
 * sign extensions, turns the '{...} 1/Q table into a function and
 * hoists the always-local registers.  The state machine still runs the
 * vlp/vlp2 (etc.) two-slot rotation: state[2:0] wraps twice per 1 MHz
 * cycle, so the filter evaluates twice and the double swap restores
 * slot parity — required even single-SID.
 *
 * One shared multiplier computes o = c ± (a * b) across all states
 * (maps to one DSP pair on ECP5).
 */

module sid_filter
(
	input               clk,
	input         [2:0] state,
	input               mode,       // 0 = 6581, 1 = 8580

	input        [15:0] F0,
	input         [7:0] Res_Filt,
	input         [7:0] Mode_Vol,
	input signed [21:0] voice1,
	input signed [21:0] voice2,
	input signed [21:0] voice3,
	input signed [21:0] ext_in,

	output       [17:0] audio
);

localparam signed [23:0] MIXER_DC_6581 = -24'sd58254;  // (-1 << 20)/18

// Clamp to 16 bits.
function signed [15:0] clamp(input signed [16:0] x);
	clamp = (x[16] ^ x[15]) ? {x[16], {15{x[15]}}} : x[15:0];
endfunction

// 1/Q << 10; index = {mode, Res_Filt[7:4]}
function [10:0] q_recip(input [4:0] idx);
	case (idx)
		// MOS6581: 1/Q =~ ~res/8 (not used - op-amps are not ideal)
		5'd0:  q_recip = 11'd1448;
		5'd1:  q_recip = 11'd1324;
		5'd2:  q_recip = 11'd1219;
		5'd3:  q_recip = 11'd1129;
		5'd4:  q_recip = 11'd1052;
		5'd5:  q_recip = 11'd984;
		5'd6:  q_recip = 11'd925;
		5'd7:  q_recip = 11'd872;
		5'd8:  q_recip = 11'd826;
		5'd9:  q_recip = 11'd783;
		5'd10: q_recip = 11'd745;
		5'd11: q_recip = 11'd711;
		5'd12: q_recip = 11'd679;
		5'd13: q_recip = 11'd651;
		5'd14: q_recip = 11'd624;
		5'd15: q_recip = 11'd600;
		// MOS8580: 1/Q =~ 2^((4 - res)/8)
		5'd16: q_recip = 11'd1448;
		5'd17: q_recip = 11'd1328;
		5'd18: q_recip = 11'd1218;
		5'd19: q_recip = 11'd1117;
		5'd20: q_recip = 11'd1024;
		5'd21: q_recip = 11'd939;
		5'd22: q_recip = 11'd861;
		5'd23: q_recip = 11'd790;
		5'd24: q_recip = 11'd724;
		5'd25: q_recip = 11'd664;
		5'd26: q_recip = 11'd609;
		5'd27: q_recip = 11'd558;
		5'd28: q_recip = 11'd512;
		5'd29: q_recip = 11'd470;
		5'd30: q_recip = 11'd431;
		5'd31: q_recip = 11'd395;
	endcase
endfunction

// o = c +- (a * b)
reg signed  [31:0] c;
reg                s;
reg signed  [15:0] a;
reg signed  [15:0] b;
wire signed [31:0] m = a * b;
wire signed [31:0] o = s ? (c - m) : (c + m);

// Filter states for two SID chips, updated as follows:
// vlp = vlp - w0*vbp
// vbp = vbp - w0*vhp
// vhp = 1/Q*vbp - vlp - vi
reg signed [15:0] vlp, vlp2;
reg signed [15:0] vbp, vbp2;
reg signed [15:0] vhp, vhp2;

// Intermediate results for filter.
// dv shifts -w0*vbp / -w0*vhp right by 17.
wire signed [16:0] dv       = {{2{o[31]}}, o[31:17]};
wire signed [15:0] vlp_next = clamp({vlp[15], vlp} + dv);
wire signed [15:0] vbp_next = clamp({vbp[15], vbp} + dv);
wire signed [15:0] vhp_next = clamp(o[26:10]);

// voices sign-extended to 24 bits (sum of four is 24 bits)
wire signed [23:0] v1_e = {{2{voice1[21]}}, voice1};
wire signed [23:0] v2_e = {{2{voice2[21]}}, voice2};
wire signed [23:0] v3_e = {{2{voice3[21]}}, voice3};
wire signed [23:0] vx_e = {{2{ext_in[21]}}, ext_in};

// Mux for filter path.
wire signed [23:0] vi_sum = (Res_Filt[0] ? v1_e : 24'sd0) +
                            (Res_Filt[1] ? v2_e : 24'sd0) +
                            (Res_Filt[2] ? v3_e : 24'sd0) +
                            (Res_Filt[3] ? vx_e : 24'sd0);

// Mux for direct audio path.
// 3 OFF (Mode_Vol[7]) disconnects voice 3 from the direct audio path.
// The mixer DC is added here to save time in the final audio sum.
wire signed [23:0] vd_sum = (mode ? 24'sd0 : MIXER_DC_6581) +
                            (Res_Filt[0] ? 24'sd0 : v1_e) +
                            (Res_Filt[1] ? 24'sd0 : v2_e) +
                            ((Res_Filt[2] | Mode_Vol[7]) ? 24'sd0 : v3_e) +
                            (Res_Filt[3] ? 24'sd0 : vx_e);

reg [10:0]        _1_Q_lsl10;
reg signed [15:0] vi;
reg signed [15:0] vd;

// Filter
always @(posedge clk) begin
	case (state)
		2:	begin
				_1_Q_lsl10 <= q_recip({mode, Res_Filt[7:4]});

				vi <= vi_sum[22:7];   // 16'(sum >>> 7)
				vd <= vd_sum[22:7];

				// vlp = vlp - w0*vbp
				// We first calculate -w0*vbp
				c <= 0;
				s <= 1;
				a <= F0;   // w0*T << 17
				b <= vbp;  // vbp
			end
		3:	begin
				// Result for vlp ready. See calculation of vlp_next above.
				{ vlp, vlp2 } <= { vlp2, vlp_next };

				// vbp = vbp - w0*vhp
				// We first calculate -w0*vhp
				c <= 0;
				s <= 1;
				// a <= a; // w0*T << 17
				b <= vhp;  // vhp
			end
		4:	begin
				// Result for vbp ready. See calculation of vbp_next above.
				{ vbp, vbp2 } <= { vbp2, vbp_next };

				// vhp = 1/Q*vbp - vlp - vi
				c <= (-({{16{vlp2[15]}}, vlp2} + {{16{vi[15]}}, vi})) << 10;
				s <= 0;
				a <= {5'b0, _1_Q_lsl10}; // 1/Q << 10
				b <= vbp_next;           // vbp
			end
		5: begin
				// Result for vhp ready. See calculation of vhp_next above.
				{ vhp, vhp2 } <= { vhp2, vhp_next };

				// Audio output: aout = vol*amix
				// In the real SID, the signal is inverted first in the mixer
				// op-amp, and then again in the volume control op-amp.
				c <= 0;
				s <= 0;
				a <= {12'b0, Mode_Vol[3:0]}; // Master volume
				b <= clamp({vd[15], vd} +    // Audio mixer / master volume input
						(Mode_Vol[4] ? {vlp2[15], vlp2}         : 17'sd0) +
						(Mode_Vol[5] ? {vbp2[15], vbp2}         : 17'sd0) +
						(Mode_Vol[6] ? {vhp_next[15], vhp_next} : 17'sd0));
			end
	endcase
end

assign audio = o[19:2];

endmodule
