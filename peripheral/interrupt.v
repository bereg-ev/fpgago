module interrupt(
  input clk,
  input rst,

  output reg cpu_irq,
  output reg [2:0] cpu_irq_num,
  input cpu_irq_ack,

  input [7:0] periph_irq,
  output [7:0] periph_irq_ack;
  reg [7:0] periph_irq_active;
);

always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {cpu_irq, cpu_irq_num} <= 0;
  end else
  begin
    if (periph_irq_active[0])

  end

always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {periph_irq_ack[0], periph_irq_active[0]} <= 0;
  end else
  begin
    if (periph_irq[0])
      periph_irq_active[0] <= 1;

  end


endmodule
