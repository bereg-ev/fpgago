/*
 * sid_dac.v — MOS 6581 non-linear DAC model (yosys-safe port)
 *
 * Port of sid_dac.sv from reDIP-SID (Copyright (C) 2022 Dag Lem,
 * CERN-OHL-S v2, https://github.com/daglem/reDIP-SID) — see the
 * upstream file for the R-2R ladder discontinuity explanation.
 *
 * Functionally identical to the upstream 2R/R = 2.20, TERM = 0,
 * SCALEBITS = 4 tables; the generate/always_comb adder chain and the
 * real-typed parameter are replaced by a plain function with a constant
 * for-loop sum (everything const-folds at synthesis — no logic beyond
 * the adders).
 */

module sid_dac #(
	parameter BITS = 12   // 12 (waveform), 8 (envelope) or 11 (cutoff)
)(
	input  [BITS-1:0] vin,
	output [BITS-1:0] vout
);

localparam SCALEBITS = 4;
localparam MSB       = BITS + SCALEBITS - 1;

/* Per-bit output contribution, scaled by 2^SCALEBITS (values from
 * reSID measurements of the 6581 ladder). */
function [14:0] bitval(input [3:0] i);
	begin
		bitval = 0;
		case (BITS)
			12: case (i)
				4'd0:  bitval = 'h21;
				4'd1:  bitval = 'h30;
				4'd2:  bitval = 'h55;
				4'd3:  bitval = 'ha0;
				4'd4:  bitval = 'h135;
				4'd5:  bitval = 'h256;
				4'd6:  bitval = 'h486;
				4'd7:  bitval = 'h8c6;
				4'd8:  bitval = 'h1102;
				4'd9:  bitval = 'h20f8;
				4'd10: bitval = 'h3fec;
				4'd11: bitval = 'h7bed;
				default: bitval = 0;
			endcase
			8: case (i)
				4'd0:  bitval = 'h1d;
				4'd1:  bitval = 'h2a;
				4'd2:  bitval = 'h4b;
				4'd3:  bitval = 'h8d;
				4'd4:  bitval = 'h110;
				4'd5:  bitval = 'h20e;
				4'd6:  bitval = 'h3fb;
				4'd7:  bitval = 'h7b8;
				default: bitval = 0;
			endcase
			11: case (i)
				4'd0:  bitval = 'h20;
				4'd1:  bitval = 'h2f;
				4'd2:  bitval = 'h52;
				4'd3:  bitval = 'h9c;
				4'd4:  bitval = 'h12b;
				4'd5:  bitval = 'h243;
				4'd6:  bitval = 'h463;
				4'd7:  bitval = 'h880;
				4'd8:  bitval = 'h107b;
				4'd9:  bitval = 'h1ff4;
				4'd10: bitval = 'h3df3;
				default: bitval = 0;
			endcase
		endcase
	end
endfunction

/* Sum contributions of the set bits, + 0.5 LSB for round-by-truncate. */
reg [MSB:0] acc;
integer i;
always @* begin
	acc = 1 << (SCALEBITS - 1);
	for (i = 0; i < BITS; i = i + 1)
		if (vin[i])
			acc = acc + bitval(i[3:0]);
end

assign vout = acc[MSB -: BITS];

endmodule
