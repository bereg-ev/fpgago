/*
 * sid_envelope.v — SID ADSR envelope generator (yosys-safe port)
 *
 * Port of the MiSTer C64 sid_envelope.sv (GPL).  Behavior unchanged;
 * the '{...} rate table became a function and the always-block-local
 * registers were hoisted to module scope (yosys chokes on both).
 */

module sid_envelope
(
	input            clock,
	input            ce_1m,

	input            reset,
	input            gate,
	input     [ 7:0] att_dec,
	input     [ 7:0] sus_rel,

	output reg [7:0] envelope
);

localparam ST_RELEASE  = 0;
localparam ST_ATTACK   = 1;
localparam ST_DEC_SUS  = 2;

reg [1:0] state;

/* rate-counter periods: time-per-step * 1MHz / 256 steps */
function [14:0] env_rate(input [3:0] idx);
	case (idx)
		4'd0:  env_rate = 15'd8;      //   2ms
		4'd1:  env_rate = 15'd31;     //   8ms
		4'd2:  env_rate = 15'd62;     //  16ms
		4'd3:  env_rate = 15'd94;     //  24ms
		4'd4:  env_rate = 15'd148;    //  38ms
		4'd5:  env_rate = 15'd219;    //  56ms
		4'd6:  env_rate = 15'd266;    //  68ms
		4'd7:  env_rate = 15'd312;    //  80ms
		4'd8:  env_rate = 15'd391;    // 100ms
		4'd9:  env_rate = 15'd976;    // 250ms
		4'd10: env_rate = 15'd1953;   // 500ms
		4'd11: env_rate = 15'd3125;   // 800ms
		4'd12: env_rate = 15'd3906;   //   1s
		4'd13: env_rate = 15'd11719;  //   3s
		4'd14: env_rate = 15'd19531;  //   5s
		4'd15: env_rate = 15'd31250;  //   8s
	endcase
endfunction

wire [14:0] rate_period = env_rate((state == ST_ATTACK)  ? att_dec[7:4] :
                                   (state == ST_DEC_SUS) ? att_dec[3:0] :
                                                           sus_rel[3:0]);

reg        hold_zero;
reg  [4:0] exponential_counter_period;
reg        gate_edge;
reg [14:0] rate_counter;
reg  [4:0] exponential_counter;

always @(posedge clock) begin
	case (envelope)
		'hff: exponential_counter_period <= 0;
		'h5d: exponential_counter_period <= 1;
		'h36: exponential_counter_period <= 3;
		'h1a: exponential_counter_period <= 7;
		'h0e: exponential_counter_period <= 15;
		'h06: exponential_counter_period <= 29;
		'h00: exponential_counter_period <= 0;
	endcase

	if (reset) begin
		state <= ST_RELEASE;
		gate_edge <= gate;
		envelope  <= 0;
		hold_zero <= 1;
		exponential_counter <= 0;
		exponential_counter_period <= 0;
		rate_counter <= 0;
	end
	else if (ce_1m) begin

		rate_counter <= rate_counter + 1'd1;
		if (rate_counter == rate_period) begin
			rate_counter <= 0;

			exponential_counter <= exponential_counter + 1'b1;
			if (state == ST_ATTACK || exponential_counter == exponential_counter_period) begin
				exponential_counter <= 0;

				case (state)
					ST_ATTACK: begin
							envelope <= envelope + 1'b1;
							if (envelope == 8'hfe) state <= ST_DEC_SUS;
						end

					ST_DEC_SUS: begin
							if (envelope != {2{sus_rel[7:4]}} && !hold_zero) begin
								envelope <= envelope - 1'b1;
							end
						end

					ST_RELEASE: begin
							if (!hold_zero) envelope <= envelope - 1'b1;
						end
				endcase

				if (state != ST_ATTACK && envelope == 1) hold_zero <= 1;
			end
		end

		gate_edge <= gate;
		if (~gate_edge & gate) begin
			state <= ST_ATTACK;
			hold_zero <= 0;
		end
		if (gate_edge & ~gate) state <= ST_RELEASE;
	end
end

endmodule
