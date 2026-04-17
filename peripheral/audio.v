/*
 * audio.v — 3-channel SID-style audio synthesizer with I2S output
 *
 * Each voice has:
 *   - 16-bit phase accumulator frequency (determines pitch)
 *   - 8-bit volume (0 = silent, 255 = max)
 *   - waveform select: 0=triangle, 1=sawtooth, 2=square, 3=noise, 4=sine
 *
 * Phase accumulators run at the I2S sample rate (48 kHz).
 * Mixed output is serialised as 24-bit left-justified I2S.
 *
 * I2S timing (hardware: ~19.375 MHz OSCG clock, MS4344/CS4344 DAC):
 *   MCLK = ~clk                ≈ 19.375 MHz
 *   BCLK = MCLK / 8            ≈ 2.42 MHz  (24 cycles per channel)
 *   LRCK = MCLK / 384          ≈ 50,456 Hz (MCLK/LRCK = 384, DAC supported)
 *   Both L+R channels receive identical mono audio.
 *
 * Register map (accent via accent accent accent accent accent accent):
 *   Offset  R/W  Description
 *   0x00    W    Voice 0 frequency low byte  [7:0]
 *   0x01    W    Voice 0 frequency high byte [15:8]
 *   0x02    W    Voice 0 volume [7:0]
 *   0x03    W    Voice 0 waveform [2:0]  (0=tri 1=saw 2=square 3=noise 4=sine)
 *   0x04    W    Voice 1 frequency low byte
 *   0x05    W    Voice 1 frequency high byte
 *   0x06    W    Voice 1 volume
 *   0x07    W    Voice 1 waveform
 *   0x08    W    Voice 2 frequency low byte
 *   0x09    W    Voice 2 frequency high byte
 *   0x0A    W    Voice 2 volume
 *   0x0B    W    Voice 2 waveform
 *   0x0C    W    Master volume [7:0] (default 255)
 *   0x0D    R    Status: bit 0 = sample tick (auto-clear on read)
 *
 * Frequency formula:  f_out = freq * sample_rate / 65536
 *   sample_rate = LRCK freq ≈ 50,456 Hz
 *   Example: 440 Hz → freq = 440 * 65536 / 50456 ≈ 571 (0x023B)
 *
 * Hardware pins directly from this module:
 *   i2s_data, i2s_mclk, i2s_lrck, i2s_bclk, audio_en
 */

module audio(
    input clk,
    input rst,

    /* CPU register interface */
    input  [3:0]  reg_addr,     /* 0x00..0x0D */
    input  [7:0]  reg_wdata,
    input         reg_we,
    output [7:0]  reg_rdata,

    /* I2S output */
    output        i2s_data,
    output        i2s_mclk,
    output reg    i2s_lrck,
    output reg    i2s_bclk,
    output        audio_en
);

    /* MCLK = clk/2 (registered, jitter-free).
     * MS4344 auto-detects MCLK/LRCK ratio:
     *   MCLK ≈ 9.6875 MHz, LRCK ≈ 50,456 Hz → ratio = 192 (double-speed). */
    reg mclk_reg;
    always @(posedge clk or negedge rst)
        if (!rst) mclk_reg <= 0;
        else mclk_reg <= !mclk_reg;
    assign i2s_mclk = mclk_reg;
    assign audio_en = 1'b1;

    /* ── I2S clock generation ─────────────────────────────────────────── *
     * MS4344 (CS4344) DAC requires MCLK/LRCK = 256, 384, or 512.
     * MCLK = ~clk ≈ 19.375 MHz (OSCG / 16).
     * clk_cnt counts 0..191 (192 clocks per LRCK half-period).
     * BCLK toggles every 4 clocks → 48 toggles = 24 cycles per channel.
     * LRCK toggles at cnt=0 → LRCK period = 384 clocks → MCLK/LRCK = 384. ✓
     * BCLK freq = MCLK/8 → BCLK/LRCK = 48 (24 per channel). ✓
     * Sample rate = LRCK freq = 19,375,000 / 384 ≈ 50,456 Hz.
     */
    reg [7:0] clk_cnt;          /* 0..191 → one LRCK half-period */

    always @(posedge clk or negedge rst)
        if (!rst) begin
            clk_cnt <= 0;
            i2s_bclk <= 0;
            i2s_lrck <= 0;
        end else begin
            if (clk_cnt == 8'd191)
                clk_cnt <= 0;
            else
                clk_cnt <= clk_cnt + 1;

            if (clk_cnt[1:0] == 2'b0)
                i2s_bclk <= !i2s_bclk;

            if (clk_cnt == 0)
                i2s_lrck <= !i2s_lrck;
        end

    /* Edge detectors */
    reg bclk0, lrck0;
    wire bclk_edge   = (!bclk0 && i2s_bclk);   /* BCLK rising edge → shift data */
    wire sample_tick = (!lrck0 && i2s_lrck);    /* LRCK rising edge → advance synthesis */
    wire lrck_edge   = (lrck0 != i2s_lrck);     /* either LRCK edge → reload dout for L/R */

    /* ── Voice registers ──────────────────────────────────────────────── */
    reg [15:0] freq     [0:2];
    reg [7:0]  volume   [0:2];
    reg [2:0]  waveform [0:2];
    reg [7:0]  master_vol;

    reg        status_tick;

    /* Status read */
    assign reg_rdata = (reg_addr == 4'hD) ? {7'b0, status_tick} : 8'h00;

    /* Register writes */
    always @(posedge clk or negedge rst)
        if (!rst) begin
            freq[0] <= 0; freq[1] <= 0; freq[2] <= 0;
            volume[0] <= 0; volume[1] <= 0; volume[2] <= 0;
            waveform[0] <= 0; waveform[1] <= 0; waveform[2] <= 0;
            master_vol <= 8'hFF;
            status_tick <= 0;
        end else begin
            /* Auto-clear status on read */
            if (reg_addr == 4'hD && !reg_we)
                status_tick <= 0;

            if (sample_tick)
                status_tick <= 1;

            if (reg_we) begin
                case (reg_addr)
                    4'h0: freq[0][7:0]   <= reg_wdata;
                    4'h1: freq[0][15:8]  <= reg_wdata;
                    4'h2: volume[0]      <= reg_wdata;
                    4'h3: waveform[0]    <= reg_wdata[2:0];
                    4'h4: freq[1][7:0]   <= reg_wdata;
                    4'h5: freq[1][15:8]  <= reg_wdata;
                    4'h6: volume[1]      <= reg_wdata;
                    4'h7: waveform[1]    <= reg_wdata[2:0];
                    4'h8: freq[2][7:0]   <= reg_wdata;
                    4'h9: freq[2][15:8]  <= reg_wdata;
                    4'hA: volume[2]      <= reg_wdata;
                    4'hB: waveform[2]    <= reg_wdata[2:0];
                    4'hC: master_vol     <= reg_wdata;
                endcase
            end
        end

    /* ── Phase accumulators (16-bit, updated at sample rate) ───────── */
    reg [15:0] phase [0:2];

    /* ── LFSR noise generators (one per voice, 16-bit) ────────────── */
    reg [15:0] lfsr [0:2];

    /* ── Sine LUT: pure combinational (no initial block needed) ──── */
    /* Quarter-wave: sin(i * pi/128) * 108 for i=0..63 */
    function [6:0] sine_lut;
        input [5:0] idx;
        begin
            case (idx)
                0:sine_lut=0;   1:sine_lut=3;   2:sine_lut=6;   3:sine_lut=9;
                4:sine_lut=12;  5:sine_lut=16;  6:sine_lut=19;  7:sine_lut=22;
                8:sine_lut=25;  9:sine_lut=28; 10:sine_lut=31; 11:sine_lut=34;
               12:sine_lut=37; 13:sine_lut=40; 14:sine_lut=43; 15:sine_lut=46;
               16:sine_lut=49; 17:sine_lut=51; 18:sine_lut=54; 19:sine_lut=57;
               20:sine_lut=59; 21:sine_lut=62; 22:sine_lut=64; 23:sine_lut=66;
               24:sine_lut=69; 25:sine_lut=71; 26:sine_lut=73; 27:sine_lut=75;
               28:sine_lut=77; 29:sine_lut=79; 30:sine_lut=81; 31:sine_lut=83;
               32:sine_lut=85; 33:sine_lut=86; 34:sine_lut=88; 35:sine_lut=89;
               36:sine_lut=91; 37:sine_lut=92; 38:sine_lut=94; 39:sine_lut=95;
               40:sine_lut=96; 41:sine_lut=97; 42:sine_lut=98; 43:sine_lut=99;
               44:sine_lut=100;45:sine_lut=101;46:sine_lut=102;47:sine_lut=103;
               48:sine_lut=104;49:sine_lut=104;50:sine_lut=105;51:sine_lut=105;
               52:sine_lut=106;53:sine_lut=106;54:sine_lut=107;55:sine_lut=107;
               56:sine_lut=107;57:sine_lut=107;58:sine_lut=108;59:sine_lut=108;
               60:sine_lut=108;61:sine_lut=108;62:sine_lut=108;63:sine_lut=108;
            endcase
        end
    endfunction

    /* Sine lookup with quadrant symmetry: phase[15:8] → signed 8-bit */
    function signed [7:0] sine_wave;
        input [7:0] ph;
        reg [5:0] idx;
        reg [6:0] mag;
        begin
            case (ph[7:6])
                2'b00: idx = ph[5:0];
                2'b01: idx = ~ph[5:0];
                2'b10: idx = ph[5:0];
                2'b11: idx = ~ph[5:0];
            endcase
            mag = sine_lut(idx);
            sine_wave = ph[7] ? -$signed({1'b0, mag}) : $signed({1'b0, mag});
        end
    endfunction

    /* ── Waveform generation (per-voice, signed 8-bit output) ─────── */
    function signed [7:0] gen_wave;
        input [2:0]  wave_sel;
        input [15:0] ph;
        input [15:0] noise;
        begin
            case (wave_sel)
                3'd0: begin /* Triangle: phase[15] xor folds, scale to [-128..127] */
                    if (ph[15])
                        gen_wave = ~ph[14:7];       /* falling half */
                    else
                        gen_wave = ph[14:7];        /* rising half */
                end
                3'd1: begin /* Sawtooth: phase[15:8] directly as signed */
                    gen_wave = ph[15:8] - 8'h80;
                end
                3'd2: begin /* Square: top bit → +127 or -128 */
                    gen_wave = ph[15] ? -8'sd128 : 8'sd127;
                end
                3'd3: begin /* Noise: LFSR top bits */
                    gen_wave = noise[15:8] - 8'h80;
                end
                3'd4: begin /* Sine: quarter-wave LUT */
                    gen_wave = sine_wave(ph[15:8]);
                end
                default: gen_wave = 0;
            endcase
        end
    endfunction

    /* ── Per-voice sample computation and mixing ──────────────────── */
    /* No multiply, no shift operators — yosys ECP5 synthesis gets them
     * wrong.  Volume gating and scaling done via concatenation only. */
    reg signed [7:0]  voice_sample [0:2];
    reg signed [7:0]  gated [0:2];      /* voice gated by volume (on/off) */
    reg signed [15:0] final_sample;
    reg [23:0] dout;

    integer i;

    /* 10-bit sum of 3 gated voices (max ±324, needs 10 bits signed) */
    wire signed [9:0] voice_sum = {gated[0][7], gated[0][7], gated[0]}
                                + {gated[1][7], gated[1][7], gated[1]}
                                + {gated[2][7], gated[2][7], gated[2]};

    always @(posedge clk or negedge rst)
        if (!rst) begin
            phase[0] <= 0; phase[1] <= 0; phase[2] <= 0;
            lfsr[0] <= 16'hACE1; lfsr[1] <= 16'h1234; lfsr[2] <= 16'h5678;
            voice_sample[0] <= 0; voice_sample[1] <= 0; voice_sample[2] <= 0;
            gated[0] <= 0; gated[1] <= 0; gated[2] <= 0;
            final_sample <= 0;
            dout <= 0;
            {bclk0, lrck0} <= 0;
        end else begin
            {bclk0, lrck0} <= {i2s_bclk, i2s_lrck};

            /* Stage 1: advance phase (gated by sample_tick) */
            if (sample_tick) begin
                for (i = 0; i < 3; i = i + 1) begin
                    phase[i] <= phase[i] + freq[i];
                    lfsr[i] <= {lfsr[i][14:0],
                                lfsr[i][15] ^ lfsr[i][14] ^ lfsr[i][12] ^ lfsr[i][3]};
                end
            end

            /* Stage 2: generate waveforms */
            voice_sample[0] <= gen_wave(waveform[0], phase[0], lfsr[0]);
            voice_sample[1] <= gen_wave(waveform[1], phase[1], lfsr[1]);
            voice_sample[2] <= gen_wave(waveform[2], phase[2], lfsr[2]);

            /* Stage 3: gate by volume (on/off, no scaling) */
            gated[0] <= (volume[0] != 0) ? voice_sample[0] : 8'sd0;
            gated[1] <= (volume[1] != 0) ? voice_sample[1] : 8'sd0;
            gated[2] <= (volume[2] != 0) ? voice_sample[2] : 8'sd0;

            /* Stage 4: mix and scale to 16-bit using ONLY concatenation.
             * Sum must use an explicit wide wire — additions inside
             * concatenation are evaluated at operand width (8-bit),
             * which overflows for 3 voices. */
            final_sample <= (master_vol != 0)
                ? {voice_sum, 6'b0}
                : 16'sd0;

            if (lrck_edge) begin
                dout <= {final_sample, 8'b0};
            end else if (bclk_edge) begin
                dout <= {dout[22:0], 1'b0};
            end
        end

    /* ── Hardware test modes ─────────────────────────────────────────
     * Bypass entire synthesis pipeline. Direct phase → waveform → I2S.
     * Activated by writing magic values to master_vol register (0x0C):
     *   0x42 = 'b' mode: single 440 Hz sine
     *   0x43 = 'c' mode: C major chord (C4 + E4 + G4)
     *   0x4D = 'm' mode: C major scale (auto-advancing)
     * Any other value = normal pipeline mode.
     *
     * Sine approximation via triangle wave (no LUT needed):
     *   Smooth enough for hardware validation. */

    wire test_active = (master_vol == 8'h42 || master_vol == 8'h43 || master_vol == 8'h4D);

    reg [15:0] tp0, tp1, tp2;      /* 3 test phase accumulators */
    reg [23:0] test_dout;
    reg [23:0] scale_timer;         /* counter for scale note duration */
    reg [2:0]  scale_note;          /* current note index (0-7) */
    reg [1:0]  chord_sel;           /* round-robin voice selector for chord */

    /* Triangle wave from phase: signed 8-bit, peak ±127 */
    function signed [7:0] triwave;
        input [15:0] ph;
        begin
            triwave = ph[15] ? ~ph[14:7] : ph[14:7];
        end
    endfunction

    /* Freq_reg values for C major scale at ~50 kHz sample rate.
     * freq = Hz * 65536 / 50456 (precomputed, no multiply needed). */
    function [15:0] scale_freq;
        input [2:0] note;
        begin
            case (note)
                3'd0: scale_freq = 16'd340;  /* C4  262 Hz */
                3'd1: scale_freq = 16'd382;  /* D4  294 Hz */
                3'd2: scale_freq = 16'd429;  /* E4  330 Hz */
                3'd3: scale_freq = 16'd453;  /* F4  349 Hz */
                3'd4: scale_freq = 16'd509;  /* G4  392 Hz */
                3'd5: scale_freq = 16'd571;  /* A4  440 Hz */
                3'd6: scale_freq = 16'd642;  /* B4  494 Hz */
                3'd7: scale_freq = 16'd679;  /* C5  523 Hz */
            endcase
        end
    endfunction

    /* Pre-compute triangle waveforms and chord sum as wires
     * (yosys doesn't support function_call()[bit_select]) */
    wire signed [7:0] tw0 = triwave(tp0);
    wire signed [7:0] tw1 = triwave(tp1);
    wire signed [7:0] tw2 = triwave(tp2);
    wire signed [9:0] tw_sum = {tw0[7], tw0[7], tw0}
                              + {tw1[7], tw1[7], tw1}
                              + {tw2[7], tw2[7], tw2};

    always @(posedge clk or negedge rst)
        if (!rst) begin
            tp0 <= 0; tp1 <= 0; tp2 <= 0;
            test_dout <= 0;
            scale_timer <= 0;
            scale_note <= 0;
            chord_sel <= 0;
        end else if (test_active) begin

            /* Advance phase accumulators on sample_tick */
            if (sample_tick) begin
                case (master_vol)
                    8'h42: begin  /* b: single A4 */
                        tp0 <= tp0 + 16'd571;
                    end
                    8'h43: begin  /* c: C major chord (time-division) */
                        tp0 <= tp0 + 16'd340;  /* C4 */
                        tp1 <= tp1 + 16'd429;  /* E4 */
                        tp2 <= tp2 + 16'd509;  /* G4 */
                        chord_sel <= (chord_sel == 2'd2) ? 2'd0 : chord_sel + 1;
                    end
                    8'h4D: begin  /* m: scale */
                        tp0 <= tp0 + scale_freq(scale_note);
                        /* Advance note every ~0.4 sec (20000 samples at 50 kHz) */
                        if (scale_timer == 24'd20000) begin
                            scale_timer <= 0;
                            if (scale_note == 3'd7)
                                scale_note <= 0;
                            else
                                scale_note <= scale_note + 1;
                        end else
                            scale_timer <= scale_timer + 1;
                    end
                endcase
            end

            /* Generate output and load shift register */
            if (lrck_edge) begin
                case (master_vol)
                    8'h42: /* b: single voice triangle (reduced volume) */
                        test_dout <= {{4{tw0[7]}}, tw0, 12'b0};
                    8'h43: /* c: 3-voice chord (one voice per sample, round-robin, reduced vol) */
                        case (chord_sel)
                            2'd0: test_dout <= {{4{tw0[7]}}, tw0, 12'b0};
                            2'd1: test_dout <= {{4{tw1[7]}}, tw1, 12'b0};
                            2'd2: test_dout <= {{4{tw2[7]}}, tw2, 12'b0};
                            default: test_dout <= {{4{tw0[7]}}, tw0, 12'b0};
                        endcase
                    8'h4D: /* m: single voice scale (reduced volume) */
                        test_dout <= {{4{tw0[7]}}, tw0, 12'b0};
                    default:
                        test_dout <= 0;
                endcase
            end else if (bclk_edge) begin
                test_dout <= {test_dout[22:0], 1'b0};
            end

        end else begin
            /* Reset test state when not active */
            tp0 <= 0; tp1 <= 0; tp2 <= 0;
            scale_timer <= 0;
            scale_note <= 0;
        end

    assign i2s_data = test_active ? test_dout[23] : dout[23];

endmodule
