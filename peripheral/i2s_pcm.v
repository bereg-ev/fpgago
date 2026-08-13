/*
 * i2s_pcm.v — free-running PCM → I2S serializer for the MS4344 DAC
 *
 * Streams a mono signed 16-bit PCM input to both channels of the v2
 * board's MS4344 (CS4344-compatible) I2S DAC.  Clock scheme copied from
 * the board-proven peripheral/audio.v:
 *
 *   MCLK = clk / 2            (registered, jitter-free)
 *   BCLK = clk / 8            (toggles every 4 clk)
 *   LRCK = clk / 768          (LRCK_HALF = 383) → MCLK/LRCK = 384 ✓
 *   sample rate = LRCK ≈ clk / 768  (31.0 MHz dot4x → ~40.4 kHz)
 *
 * Format: 24-bit left-justified, {pcm, 8'b0}; the DAC auto-detects the
 * MCLK/LRCK ratio.  The pcm input is sampled at the LRCK rising edge
 * and sent to both half-periods (L = R = mono).  No interpolation —
 * the source (SID) already changes at ~1 MHz, plain decimation is fine.
 *
 * FF init values match the async-reset values (the ecp5-rst-constfold
 * rule: yosys must not be able to fold the reset away meaningfully).
 */

module i2s_pcm (
    input clk,
    input rst,                       // active low, async (as audio.v)

    input signed [15:0] pcm,         // mono sample stream

    output              i2s_data,
    output              i2s_mclk,
    output reg          i2s_lrck,
    output reg          i2s_bclk,
    output              i2s_en
);

    localparam [8:0] LRCK_HALF = 9'd383;

    reg mclk_reg = 0;
    always @(posedge clk or negedge rst)
        if (!rst) mclk_reg <= 0;
        else      mclk_reg <= !mclk_reg;
    assign i2s_mclk = mclk_reg;
    assign i2s_en   = 1'b1;

    reg [8:0] clk_cnt = 0;
    initial begin
        i2s_bclk = 0;
        i2s_lrck = 0;
    end

    always @(posedge clk or negedge rst)
        if (!rst) begin
            clk_cnt  <= 0;
            i2s_bclk <= 0;
            i2s_lrck <= 0;
        end else begin
            if (clk_cnt == LRCK_HALF)
                clk_cnt <= 0;
            else
                clk_cnt <= clk_cnt + 1;

            if (clk_cnt[1:0] == 2'b0)
                i2s_bclk <= !i2s_bclk;

            if (clk_cnt == 0)
                i2s_lrck <= !i2s_lrck;
        end

    reg        bclk0 = 0, lrck0 = 0;
    wire       bclk_edge   = (!bclk0 && i2s_bclk);
    wire       frame_tick  = (lrck0 && !i2s_lrck);   // LRCK falling = frame end
    wire       lrck_edge   = (lrck0 != i2s_lrck);

    reg [15:0] sample = 0;           /* latched at frame END so the next
                                      * frame's L and R halves (loaded at
                                      * the two following lrck edges) carry
                                      * the SAME sample */
    reg [23:0] dout   = 0;

    assign i2s_data = dout[23];

    always @(posedge clk or negedge rst)
        if (!rst) begin
            {bclk0, lrck0} <= 0;
            sample <= 0;
            dout   <= 0;
        end else begin
            {bclk0, lrck0} <= {i2s_bclk, i2s_lrck};

            if (frame_tick)
                sample <= pcm;

            if (lrck_edge)
                dout <= {sample, 8'b0};
            else if (bclk_edge)
                dout <= {dout[22:0], 1'b0};
        end

endmodule
