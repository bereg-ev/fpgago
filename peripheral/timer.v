module timer(
  input clk,
  input rst,

  output reg timer_irq,
  input timer_irq_ack

);

always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {timer_irq} <= 0;
  end else
  begin
    /* preDivider is 8-bit; 8'hf10e8 was a 20-bit literal (iverilog truncated
     * it silently to 8'he8 = 232).  Use the correct 8-bit value explicitly. */
    timer_irq <= (divider == `TIMER_DIVIDER && preDivider == 8'he8);
  end

reg [7:0] preDivider;
reg [7:0] divider;

always @(posedge clk or negedge rst)
  if (!rst)
    {preDivider, divider} <= 0;
  else begin
    preDivider <= preDivider + 1;

    if (preDivider == 0)
    begin

      divider <= divider + 1;

      if (divider == `TIMER_DIVIDER)
        divider <= 0;
    end
  end



endmodule
