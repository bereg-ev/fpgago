
`define CMD_STEP        8'h53    // 'S'
`define CMD_CONTINUE    8'h43    // 'C'
`define CMD_PRINT       8'h50    // 'P'
`define CMD_RESET       8'h52    // 'R'

module testbench();

  reg clk, rst, rx;
  wire led1, led2, tx;
  wire [15:0] xd;
  reg [15:0] cnt;

  always #1 clk = ~clk;
  always #2 cnt = cnt + 1;

  assign xd = (cnt[15:0] > 16'h0130) ? cnt : 16'h56ab;

  fpga_gameconsole game0(.led1(led1), .led2(led2), .tx(tx), .rx(rx),
    .xd(xd)
  );

task uartrx;
  input [7:0] data;
  integer i;
  begin
    #8 rx = 0;      // start bit

    for (i = 0; i < 8; i = i + 1)
      #8 rx = data[i];

    #8 rx = 1;      // stop
  end
endtask

initial begin
  $dumpfile("out.vcd");
  $dumpvars(0, game0);
end

initial begin
  clk = 0;
  rx = 1;
  cnt = 0;
  #1 rst = 1;
  #10 rst = 0;
  #10 rst = 1;

  #100 rx = 1;

//  #1000 uartrx(8'h79);

  #9000 uartrx(8'h31);
  #3000 uartrx(8'h32);
  #3000 uartrx(8'h33);
  #3000 uartrx(8'h34);
  #3000 uartrx(8'h35);

  #9000 uartrx(8'h50);

  #15000 uartrx(8'h53);
  #100 uartrx(8'h50);

  #15000 uartrx(8'h53);
  #100 uartrx(8'h50);

  #15000 uartrx(8'h53);
  #100 uartrx(8'h50);

/*
  #400 uartrx(8'h32);
  #100 uartrx(`CMD_STEP);
  #10 uartrx(`CMD_STEP);
  #10 uartrx(`CMD_STEP);
  #100 uartrx(`CMD_PRINT);

// enable bootloader with 00 00 00

  #1000 uartrx(8'h00);
  uartrx(8'h00);
  uartrx(8'h00);

  uartrx(8'h01);
  uartrx(8'he2);
  uartrx(8'h01);

  uartrx(8'h00);
  uartrx(8'h62);
  uartrx(8'h00);

  uartrx(8'h01);
  uartrx(8'he0);
  uartrx(8'h38);

  uartrx(8'h00);
  uartrx(8'hf8);
  uartrx(8'h3a);


  #100 uartrx(`CMD_RESET);
  #100 uartrx(`CMD_CONTINUE);
  #100 uartrx(8'h31);
  #100 uartrx(`CMD_RESET);

*/

  #15200 rst = 1;


  $finish(2);
end

endmodule
`default_nettype wire