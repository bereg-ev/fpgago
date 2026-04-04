/*
  18.432 MHz: mclk
  2.304 MHz: bclk (= mclk / 8)
  48 kHz: lrck (= mclk / 384)

  440 Hz: play 109 samples (left & right)
*/

module i2s(
  input clk,
  input rst,

  output reg en,
  output reg bclk,
  output reg lrck,
  output mclk,
  output data
);

assign mclk = !clk;

reg [8:0] cnt;

always @(posedge clk or negedge rst)
  if (!rst)
  begin
	  {en} <= 1;
    {cnt, lrck, bclk} <= 0;
  end
  else
  begin
    if (cnt == 9'd383)
      cnt <= 0;
    else
      cnt <= cnt + 1;

    if (cnt[2:0] == 3'b0)
      bclk <= !bclk;

    if (cnt[8:0] == 0)
      lrck <= !lrck;
  end

reg bclk0, lrck0;
reg [23:0] amplitude, dout;
reg [7:0] sampleCnt;

wire bclk_edge = (!bclk0 && bclk);   /* renamed: 'bit' is reserved in SV */
wire sample = (!lrck0 && lrck);

assign data = dout[23];

always @(posedge clk or negedge rst)
  if (!rst)
    {dout, bclk0, lrck0, sampleCnt} <= 0;
  else
  begin
    {bclk0, lrck0} <= {bclk, lrck};

//    if (sampleCnt == 8'h0)
//      amplitude <= 24'h800000;       // default amplitude of the triangle
//    else
    if (sample)
    begin
      if (sampleCnt == 8'h0)
        amplitude <= 24'h000000;       // default amplitude of the triangle
      else if (sampleCnt < 8'd26)
//        amplitude <= amplitude + 1;
        amplitude[21:16] <= amplitude[21:16] + 1;
      else
//        amplitude <= amplitude - 1;
        amplitude[21:16] <= amplitude[21:16] - 1;
    end
//      amplitude[19:12] <= amplitude[19:12] + 1;

    if (sample)
      dout <= amplitude;
    else if (bclk_edge)
      dout[23:0] <= {dout[22:0], 1'b0};

    if (sample)
    begin
      if (sampleCnt == 8'd49)
        sampleCnt <= 0;
      else
        sampleCnt <= sampleCnt + 1;
    end
  end
endmodule
