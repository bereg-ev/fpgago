
module OSCG #(
  parameter DIV = "1"
)(
  output reg OSC
);

always #1 OSC = ~OSC;

initial begin
  OSC = 0;
end

endmodule

module DELAYG (
  input A,
  output Z
);
assign Z = A;

endmodule

module ram_1k_18 (
    input wire clk_a,            // Clock for Port A
    input wire we_a,             // Write enable for Port A
    input wire [9:0] addr_a,     // Address for Port A
    input wire [17:0] din_a,     // Data input for Port A
    output reg [17:0] dout_a,   // Data output for Port A

    input wire clk_b,            // Clock for Port B
    input wire we_b,             // Write enable for Port B
    input wire [9:0] addr_b,     // Address for Port B
    input wire [17:0] din_b,     // Data input for Port B
    output reg [17:0] dout_b    // Data output for Port B

 );

  reg [17:0] mem[0:1023];

  always @(posedge clk_a)
    if (we_a)
      mem[addr_a] <= din_a;
    else
      dout_a <= mem[addr_a];

  always @(posedge clk_b)
    if (we_b)
      mem[addr_b] <= din_b;
    else
      dout_b <= mem[addr_b];

 endmodule

module ram_4k_18 (
    input wire clk_a,
    input wire we_a,
    input wire [11:0] addr_a,
    input wire [17:0] din_a,
    output reg [17:0] dout_a,

    input wire clk_b,
    input wire we_b,
    input wire [11:0] addr_b,
    input wire [17:0] din_b,
    output reg [17:0] dout_b
 );

  reg [17:0] mem[0:4095];

  always @(posedge clk_a)
    if (we_a)
      mem[addr_a] <= din_a;
    else
      dout_a <= mem[addr_a];

  always @(posedge clk_b)
    if (we_b)
      mem[addr_b] <= din_b;
    else
      dout_b <= mem[addr_b];

 endmodule

module dual_port_ram_1k_18 #(
    parameter [319:0] init_00 = 320'h0, parameter [319:0] init_01 = 320'h0, parameter [319:0] init_02 = 320'h0, parameter [319:0] init_03 = 320'h0,
    parameter [319:0] init_04 = 320'h0, parameter [319:0] init_05 = 320'h0, parameter [319:0] init_06 = 320'h0, parameter [319:0] init_07 = 320'h0,
    parameter [319:0] init_08 = 320'h0, parameter [319:0] init_09 = 320'h0, parameter [319:0] init_0a = 320'h0, parameter [319:0] init_0b = 320'h0,
    parameter [319:0] init_0c = 320'h0, parameter [319:0] init_0d = 320'h0, parameter [319:0] init_0e = 320'h0, parameter [319:0] init_0f = 320'h0,
    parameter [319:0] init_10 = 320'h0, parameter [319:0] init_11 = 320'h0, parameter [319:0] init_12 = 320'h0, parameter [319:0] init_13 = 320'h0,
    parameter [319:0] init_14 = 320'h0, parameter [319:0] init_15 = 320'h0, parameter [319:0] init_16 = 320'h0, parameter [319:0] init_17 = 320'h0,
    parameter [319:0] init_18 = 320'h0, parameter [319:0] init_19 = 320'h0, parameter [319:0] init_1a = 320'h0, parameter [319:0] init_1b = 320'h0,
    parameter [319:0] init_1c = 320'h0, parameter [319:0] init_1d = 320'h0, parameter [319:0] init_1e = 320'h0, parameter [319:0] init_1f = 320'h0,
    parameter [319:0] init_20 = 320'h0, parameter [319:0] init_21 = 320'h0, parameter [319:0] init_22 = 320'h0, parameter [319:0] init_23 = 320'h0,
    parameter [319:0] init_24 = 320'h0, parameter [319:0] init_25 = 320'h0, parameter [319:0] init_26 = 320'h0, parameter [319:0] init_27 = 320'h0,
    parameter [319:0] init_28 = 320'h0, parameter [319:0] init_29 = 320'h0, parameter [319:0] init_2a = 320'h0, parameter [319:0] init_2b = 320'h0,
    parameter [319:0] init_2c = 320'h0, parameter [319:0] init_2d = 320'h0, parameter [319:0] init_2e = 320'h0, parameter [319:0] init_2f = 320'h0,
    parameter [319:0] init_30 = 320'h0, parameter [319:0] init_31 = 320'h0, parameter [319:0] init_32 = 320'h0, parameter [319:0] init_33 = 320'h0,
    parameter [319:0] init_34 = 320'h0, parameter [319:0] init_35 = 320'h0, parameter [319:0] init_36 = 320'h0, parameter [319:0] init_37 = 320'h0,
    parameter [319:0] init_38 = 320'h0, parameter [319:0] init_39 = 320'h0, parameter [319:0] init_3a = 320'h0, parameter [319:0] init_3b = 320'h0,
    parameter [319:0] init_3c = 320'h0, parameter [319:0] init_3d = 320'h0, parameter [319:0] init_3e = 320'h0, parameter [319:0] init_3f = 320'h0
 )(
  input wire clk_a,            // Clock for Port A
  input wire we_a,             // Write enable for Port A
  input wire [9:0] addr_a,     // Address for Port A
  input wire [17:0] din_a,     // Data input for Port A
  output reg [17:0] dout_a,   // Data output for Port A

  input wire clk_b,            // Clock for Port B
  input wire we_b,             // Write enable for Port B
  input wire [9:0] addr_b,     // Address for Port B
  input wire [17:0] din_b,     // Data input for Port B
  output reg [17:0] dout_b    // Data output for Port B
);

  reg [17:0] mem[0:1023];

  always @(posedge clk_a)
    if (we_a)
      mem[addr_a] <= din_a;
    else
      dout_a <= mem[addr_a];

  always @(posedge clk_b)
    if (we_b)
      mem[addr_b] <= din_b;
    else
      dout_b <= mem[addr_b];

  integer i;
  integer j;

  reg [319:0] init_values [0:63];

  initial
  begin
    init_values[0]  = init_00; init_values[1]  = init_01; init_values[2]  = init_02; init_values[3]  = init_03;
    init_values[4]  = init_04; init_values[5]  = init_05; init_values[6]  = init_06; init_values[7]  = init_07;
    init_values[8]  = init_08; init_values[9]  = init_09; init_values[10] = init_0a; init_values[11] = init_0b;
    init_values[12] = init_0c; init_values[13] = init_0d; init_values[14] = init_0e; init_values[15] = init_0f;

    init_values[16] = init_10; init_values[17] = init_11; init_values[18] = init_12; init_values[19] = init_13;
    init_values[20] = init_14; init_values[21] = init_15; init_values[22] = init_16; init_values[23] = init_17;
    init_values[24] = init_18; init_values[25] = init_19; init_values[26] = init_1a; init_values[27] = init_1b;
    init_values[28] = init_1c; init_values[29] = init_1d; init_values[30] = init_1e; init_values[31] = init_1f;

    init_values[32] = init_20; init_values[33] = init_21; init_values[34] = init_22; init_values[35] = init_23;
    init_values[36] = init_24; init_values[37] = init_25; init_values[38] = init_26; init_values[39] = init_27;
    init_values[40] = init_28; init_values[41] = init_29; init_values[42] = init_2a; init_values[43] = init_2b;
    init_values[44] = init_2c; init_values[45] = init_2d; init_values[46] = init_2e; init_values[47] = init_2f;

    init_values[48] = init_30; init_values[49] = init_31; init_values[50] = init_32; init_values[51] = init_33;
    init_values[52] = init_34; init_values[53] = init_35; init_values[54] = init_36; init_values[55] = init_37;
    init_values[56] = init_38; init_values[57] = init_39; init_values[58] = init_3a; init_values[59] = init_3b;
    init_values[60] = init_3c; init_values[61] = init_3d; init_values[62] = init_3e; init_values[63] = init_3f;

    for (i = 0; i < 64; i = i + 1)
    begin
      for (j = 0; j < 16; j = j + 1)
        mem[i * 16 + j]  = init_values[i][20 * j+:18];
    end

  end
endmodule


 module dual_port_ram_2k_9 #(
    parameter [319:0] init_00 = 320'h0, parameter [319:0] init_01 = 320'h0, parameter [319:0] init_02 = 320'h0, parameter [319:0] init_03 = 320'h0,
    parameter [319:0] init_04 = 320'h0, parameter [319:0] init_05 = 320'h0, parameter [319:0] init_06 = 320'h0, parameter [319:0] init_07 = 320'h0,
    parameter [319:0] init_08 = 320'h0, parameter [319:0] init_09 = 320'h0, parameter [319:0] init_0a = 320'h0, parameter [319:0] init_0b = 320'h0,
    parameter [319:0] init_0c = 320'h0, parameter [319:0] init_0d = 320'h0, parameter [319:0] init_0e = 320'h0, parameter [319:0] init_0f = 320'h0,
    parameter [319:0] init_10 = 320'h0, parameter [319:0] init_11 = 320'h0, parameter [319:0] init_12 = 320'h0, parameter [319:0] init_13 = 320'h0,
    parameter [319:0] init_14 = 320'h0, parameter [319:0] init_15 = 320'h0, parameter [319:0] init_16 = 320'h0, parameter [319:0] init_17 = 320'h0,
    parameter [319:0] init_18 = 320'h0, parameter [319:0] init_19 = 320'h0, parameter [319:0] init_1a = 320'h0, parameter [319:0] init_1b = 320'h0,
    parameter [319:0] init_1c = 320'h0, parameter [319:0] init_1d = 320'h0, parameter [319:0] init_1e = 320'h0, parameter [319:0] init_1f = 320'h0,
    parameter [319:0] init_20 = 320'h0, parameter [319:0] init_21 = 320'h0, parameter [319:0] init_22 = 320'h0, parameter [319:0] init_23 = 320'h0,
    parameter [319:0] init_24 = 320'h0, parameter [319:0] init_25 = 320'h0, parameter [319:0] init_26 = 320'h0, parameter [319:0] init_27 = 320'h0,
    parameter [319:0] init_28 = 320'h0, parameter [319:0] init_29 = 320'h0, parameter [319:0] init_2a = 320'h0, parameter [319:0] init_2b = 320'h0,
    parameter [319:0] init_2c = 320'h0, parameter [319:0] init_2d = 320'h0, parameter [319:0] init_2e = 320'h0, parameter [319:0] init_2f = 320'h0,
    parameter [319:0] init_30 = 320'h0, parameter [319:0] init_31 = 320'h0, parameter [319:0] init_32 = 320'h0, parameter [319:0] init_33 = 320'h0,
    parameter [319:0] init_34 = 320'h0, parameter [319:0] init_35 = 320'h0, parameter [319:0] init_36 = 320'h0, parameter [319:0] init_37 = 320'h0,
    parameter [319:0] init_38 = 320'h0, parameter [319:0] init_39 = 320'h0, parameter [319:0] init_3a = 320'h0, parameter [319:0] init_3b = 320'h0,
    parameter [319:0] init_3c = 320'h0, parameter [319:0] init_3d = 320'h0, parameter [319:0] init_3e = 320'h0, parameter [319:0] init_3f = 320'h0
 )(
  input wire clk_a,            // Clock for Port A
  input wire we_a,             // Write enable for Port A
  input wire [10:0] addr_a,     // Address for Port A
  input wire [8:0] din_a,     // Data input for Port A
  output reg [8:0] dout_a,   // Data output for Port A

  input wire clk_b,            // Clock for Port B
  input wire we_b,             // Write enable for Port B
  input wire [10:0] addr_b,     // Address for Port B
  input wire [8:0] din_b,     // Data input for Port B
  output reg [8:0] dout_b    // Data output for Port B
);

  reg [9:0] mem[0:2047];

  always @(posedge clk_a)
    if (we_a)
      mem[addr_a] <= din_a;
    else
      dout_a <= mem[addr_a];

  always @(posedge clk_b)
    if (we_b)
      mem[addr_b] <= din_b;
    else
      dout_b <= mem[addr_b];

  initial
  begin

//`include "simul.vh"

  end
endmodule

// Simulation-only ROM for 32KB program space.
// Internally stores 32-bit words loaded from rom.hex; the HI_HALF parameter
// selects which 16-bit half each instance outputs:
//   HI_HALF=0 → bits [15:0]  (romL instance)
//   HI_HALF=1 → bits [31:16] (romH instance)
module dual_port_ram_4k_18 #(parameter HI_HALF = 0) (
    input  wire        clk_a,
    input  wire        we_a,
    input  wire [12:0] addr_a,
    input  wire [17:0] din_a,
    output reg  [17:0] dout_a,
    input  wire        clk_b,
    input  wire        we_b,
    input  wire [12:0] addr_b,
    input  wire [17:0] din_b,
    output reg  [17:0] dout_b
);
    reg [31:0] mem [0:8191];
    initial $readmemh("../rom.hex", mem);
    always @(posedge clk_a)
        dout_a <= {2'b0, HI_HALF ? mem[addr_a][31:16] : mem[addr_a][15:0]};
    always @(posedge clk_b)
        dout_b <= {2'b0, HI_HALF ? mem[addr_b][31:16] : mem[addr_b][15:0]};
endmodule
