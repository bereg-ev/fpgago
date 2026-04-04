
module testbench();

  reg clk, rst, rx;
  wire led1, led2, tx;
  wire lcd_hsync, lcd_vsync, lcd_de, lcd_pwm, lcd_clk;
  wire [15:0] lcd_data;

  always #1 clk = ~clk;

  soc soc0(
      .clk(clk), .rst(rst), .led1(led1), .led2(led2),
      .tx(tx), .rx(rx),
      .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
      .lcd_data(lcd_data), .lcd_pwm(lcd_pwm), .lcd_clk(lcd_clk)
  );

initial begin
  $dumpfile("out.vcd");
  $dumpvars(0, soc0);
end

initial begin
  clk = 0;
  rx  = 1;
  #1  rst = 1;
  #10 rst = 0;
  #10 rst = 1;

  #200000 $finish(2);
end

endmodule
`default_nettype wire
