
 module ram_1k_18 (
    input wire clk_a,            // Clock for Port A
    input wire we_a,             // Write enable for Port A
    input wire [9:0] addr_a,     // Address for Port A
    input wire [17:0] din_a,     // Data input for Port A
    output wire [17:0] dout_a,   // Data output for Port A

    input wire clk_b,            // Clock for Port B
    input wire we_b,             // Write enable for Port B
    input wire [9:0] addr_b,     // Address for Port B
    input wire [17:0] din_b,     // Data input for Port B
    output wire [17:0] dout_b    // Data output for Port B

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
    output wire [17:0] dout_a,

    input wire clk_b,
    input wire we_b,
    input wire [11:0] addr_b,
    input wire [17:0] din_b,
    output wire [17:0] dout_b
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
    output wire [17:0] dout_a,   // Data output for Port A

    input wire clk_b,            // Clock for Port B
    input wire we_b,             // Write enable for Port B
    input wire [9:0] addr_b,     // Address for Port B
    input wire [17:0] din_b,     // Data input for Port B
    output wire [17:0] dout_b    // Data output for Port B
);

// Correct instantiation of the DP16KD dual-port RAM
    (* ram_style = "block" *)                  // Hint for synthesis tools
    DP16KD #(
        .DATA_WIDTH_A(18),
        .DATA_WIDTH_B(18),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),
        .RESETMODE("SYNC"),

        .INITVAL_00(init_00), .INITVAL_01(init_01), .INITVAL_02(init_02), .INITVAL_03(init_03),
        .INITVAL_04(init_04), .INITVAL_05(init_05), .INITVAL_06(init_06), .INITVAL_07(init_07),
        .INITVAL_08(init_08), .INITVAL_09(init_09), .INITVAL_0A(init_0a), .INITVAL_0B(init_0b),
        .INITVAL_0C(init_0c), .INITVAL_0D(init_0d), .INITVAL_0E(init_0e), .INITVAL_0F(init_0f),
        .INITVAL_10(init_10), .INITVAL_11(init_11), .INITVAL_12(init_12), .INITVAL_13(init_13),
        .INITVAL_14(init_14), .INITVAL_15(init_15), .INITVAL_16(init_16), .INITVAL_17(init_17),
        .INITVAL_18(init_18), .INITVAL_19(init_19), .INITVAL_1A(init_1a), .INITVAL_1B(init_1b),
        .INITVAL_1C(init_1c), .INITVAL_1D(init_1d), .INITVAL_1E(init_1e), .INITVAL_1F(init_1f),
        .INITVAL_20(init_20), .INITVAL_21(init_21), .INITVAL_22(init_22), .INITVAL_23(init_23),
        .INITVAL_24(init_24), .INITVAL_25(init_25), .INITVAL_26(init_26), .INITVAL_27(init_27),
        .INITVAL_28(init_28), .INITVAL_29(init_29), .INITVAL_2A(init_2a), .INITVAL_2B(init_2b),
        .INITVAL_2C(init_2c), .INITVAL_2D(init_2d), .INITVAL_2E(init_2e), .INITVAL_2F(init_2f),
        .INITVAL_30(init_30), .INITVAL_31(init_31), .INITVAL_32(init_32), .INITVAL_33(init_33),
        .INITVAL_34(init_34), .INITVAL_35(init_35), .INITVAL_36(init_36), .INITVAL_37(init_37),
        .INITVAL_38(init_38), .INITVAL_39(init_39), .INITVAL_3A(init_3a), .INITVAL_3B(init_3b),
        .INITVAL_3C(init_3c), .INITVAL_3D(init_3d), .INITVAL_3E(init_3e), .INITVAL_3F(init_3f)

        ) _TECHMAP_REPLACE_
        (
        .CEA(1'b1), .OCEA(1'b1),
        .CSA0(1'b0),
        .CSA1(1'b0),
        .CSA2(1'b0),
        .CEB(1'b1), .OCEB(1'b1),
        .CLKA(clk_a),                         // Clock for Port A
        .WEA(we_a),                           // Write enable for Port A

        .ADA0(1'b0),                          // Data output for Port B
        .ADA1(1'b0),                          // Data output for Port B
        .ADA2(1'b0),                          // Data output for Port B
        .ADA3(1'b0),                          // Data output for Port B
        .ADA4(addr_a[0]),                          // Data output for Port B
        .ADA5(addr_a[1]),                          // Data output for Port B
        .ADA6(addr_a[2]),                          // Data output for Port B
        .ADA7(addr_a[3]),                          // Data output for Port B
        .ADA8(addr_a[4]),                          // Data output for Port B
        .ADA9(addr_a[5]),                          // Data output for Port B
        .ADA10(addr_a[6]),                          // Data output for Port B
        .ADA11(addr_a[7]),                          // Data output for Port B
        .ADA12(addr_a[8]),                          // Data output for Port B
        .ADA13(addr_a[9]),                          // Data output for Port B

        .DIA0(din_a[0]),                          // Data output for Port B
        .DIA1(din_a[1]),                          // Data output for Port B
        .DIA2(din_a[2]),                          // Data output for Port B
        .DIA3(din_a[3]),                          // Data output for Port B
        .DIA4(din_a[4]),                          // Data output for Port B
        .DIA5(din_a[5]),                          // Data output for Port B
        .DIA6(din_a[6]),                          // Data output for Port B
        .DIA7(din_a[7]),                          // Data output for Port B
        .DIA8(din_a[8]),                          // Data output for Port B
        .DIA9(din_a[9]),                          // Data output for Port B
        .DIA10(din_a[10]),                          // Data output for Port B
        .DIA11(din_a[11]),                          // Data output for Port B
        .DIA12(din_a[12]),                          // Data output for Port B
        .DIA13(din_a[13]),                          // Data output for Port B
        .DIA14(din_a[14]),                          // Data output for Port B
        .DIA15(din_a[15]),                          // Data output for Port B
        .DIA16(din_a[16]),                          // Data output for Port B
        .DIA17(din_a[17]),                          // Data output for Port B

        .DOA0(dout_a[0]),                          // Data output for Port B
        .DOA1(dout_a[1]),                          // Data output for Port B
        .DOA2(dout_a[2]),                          // Data output for Port B
        .DOA3(dout_a[3]),                          // Data output for Port B
        .DOA4(dout_a[4]),                          // Data output for Port B
        .DOA5(dout_a[5]),                          // Data output for Port B
        .DOA6(dout_a[6]),                          // Data output for Port B
        .DOA7(dout_a[7]),                          // Data output for Port B
        .DOA8(dout_a[8]),                          // Data output for Port B
        .DOA9(dout_a[9]),                          // Data output for Port B
        .DOA10(dout_a[10]),                          // Data output for Port B
        .DOA11(dout_a[11]),                          // Data output for Port B
        .DOA12(dout_a[12]),                          // Data output for Port B
        .DOA13(dout_a[13]),                          // Data output for Port B
        .DOA14(dout_a[14]),                          // Data output for Port B
        .DOA15(dout_a[15]),                          // Data output for Port B
        .DOA16(dout_a[16]),                          // Data output for Port B
        .DOA17(dout_a[17]),                          // Data output for Port B

        .CLKB(clk_b),                         // Clock for Port B
        .WEB(we_b),                           // Write enable for Port B

        .ADB0(1'b0),                          // Data output for Port B
        .ADB1(1'b0),                          // Data output for Port B
        .ADB2(1'b0),                          // Data output for Port B
        .ADB3(1'b0),                          // Data output for Port B
        .ADB4(addr_b[0]),                          // Data output for Port B
        .ADB5(addr_b[1]),                          // Data output for Port B
        .ADB6(addr_b[2]),                          // Data output for Port B
        .ADB7(addr_b[3]),                          // Data output for Port B
        .ADB8(addr_b[4]),                          // Data output for Port B
        .ADB9(addr_b[5]),                          // Data output for Port B
        .ADB10(addr_b[6]),                          // Data output for Port B
        .ADB11(addr_b[7]),                          // Data output for Port B
        .ADB12(addr_b[8]),                          // Data output for Port B
        .ADB13(addr_b[9]),                          // Data output for Port B

        .DIB0(din_b[0]),                          // Data output for Port B
        .DIB1(din_b[1]),                          // Data output for Port B
        .DIB2(din_b[2]),                          // Data output for Port B
        .DIB3(din_b[3]),                          // Data output for Port B
        .DIB4(din_b[4]),                          // Data output for Port B
        .DIB5(din_b[5]),                          // Data output for Port B
        .DIB6(din_b[6]),                          // Data output for Port B
        .DIB7(din_b[7]),                          // Data output for Port B
        .DIB8(din_b[8]),                          // Data output for Port B
        .DIB9(din_b[9]),                          // Data output for Port B
        .DIB10(din_b[10]),                          // Data output for Port B
        .DIB11(din_b[11]),                          // Data output for Port B
        .DIB12(din_b[12]),                          // Data output for Port B
        .DIB13(din_b[13]),                          // Data output for Port B
        .DIB14(din_b[14]),                          // Data output for Port B
        .DIB15(din_b[15]),                          // Data output for Port B
        .DIB16(din_b[16]),                          // Data output for Port B
        .DIB17(din_b[17]),                          // Data output for Port B

        .DOB0(dout_b[0]),                          // Data output for Port B
        .DOB1(dout_b[1]),                          // Data output for Port B
        .DOB2(dout_b[2]),                          // Data output for Port B
        .DOB3(dout_b[3]),                          // Data output for Port B
        .DOB4(dout_b[4]),                          // Data output for Port B
        .DOB5(dout_b[5]),                          // Data output for Port B
        .DOB6(dout_b[6]),                          // Data output for Port B
        .DOB7(dout_b[7]),                          // Data output for Port B
        .DOB8(dout_b[8]),                          // Data output for Port B
        .DOB9(dout_b[9]),                          // Data output for Port B
        .DOB10(dout_b[10]),                          // Data output for Port B
        .DOB11(dout_b[11]),                          // Data output for Port B
        .DOB12(dout_b[12]),                          // Data output for Port B
        .DOB13(dout_b[13]),                          // Data output for Port B
        .DOB14(dout_b[14]),                          // Data output for Port B
        .DOB15(dout_b[15]),                          // Data output for Port B
        .DOB16(dout_b[16]),                          // Data output for Port B
        .DOB17(dout_b[17])                          // Data output for Port B
    );

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
    output wire [8:0] dout_a,   // Data output for Port A

    input wire clk_b,            // Clock for Port B
    input wire we_b,             // Write enable for Port B
    input wire [10:0] addr_b,     // Address for Port B
    input wire [8:0] din_b,     // Data input for Port B
    output wire [8:0] dout_b    // Data output for Port B
);

// Correct instantiation of the DP16KD dual-port RAM
    (* ram_style = "block" *)                  // Hint for synthesis tools
    DP16KD #(
        .DATA_WIDTH_A(9),
        .DATA_WIDTH_B(9),
        .INITVAL_00(init_00), .INITVAL_01(init_01), .INITVAL_02(init_02), .INITVAL_03(init_03),
        .INITVAL_04(init_04), .INITVAL_05(init_05), .INITVAL_06(init_06), .INITVAL_07(init_07),
        .INITVAL_08(init_08), .INITVAL_09(init_09), .INITVAL_0A(init_0a), .INITVAL_0B(init_0b),
        .INITVAL_0C(init_0c), .INITVAL_0D(init_0d), .INITVAL_0E(init_0e), .INITVAL_0F(init_0f),
        .INITVAL_10(init_10), .INITVAL_11(init_11), .INITVAL_12(init_12), .INITVAL_13(init_13),
        .INITVAL_14(init_14), .INITVAL_15(init_15), .INITVAL_16(init_16), .INITVAL_17(init_17),
        .INITVAL_18(init_18), .INITVAL_19(init_19), .INITVAL_1A(init_1a), .INITVAL_1B(init_1b),
        .INITVAL_1C(init_1c), .INITVAL_1D(init_1d), .INITVAL_1E(init_1e), .INITVAL_1F(init_1f),
        .INITVAL_20(init_20), .INITVAL_21(init_21), .INITVAL_22(init_22), .INITVAL_23(init_23),
        .INITVAL_24(init_24), .INITVAL_25(init_25), .INITVAL_26(init_26), .INITVAL_27(init_27),
        .INITVAL_28(init_28), .INITVAL_29(init_29), .INITVAL_2A(init_2a), .INITVAL_2B(init_2b),
        .INITVAL_2C(init_2c), .INITVAL_2D(init_2d), .INITVAL_2E(init_2e), .INITVAL_2F(init_2f),
        .INITVAL_30(init_30), .INITVAL_31(init_31), .INITVAL_32(init_32), .INITVAL_33(init_33),
        .INITVAL_34(init_34), .INITVAL_35(init_35), .INITVAL_36(init_36), .INITVAL_37(init_37),
        .INITVAL_38(init_38), .INITVAL_39(init_39), .INITVAL_3A(init_3a), .INITVAL_3B(init_3b),
        .INITVAL_3C(init_3c), .INITVAL_3D(init_3d), .INITVAL_3E(init_3e), .INITVAL_3F(init_3f)
        ) _TECHMAP_REPLACE_
        (
        .CLKA(clk_a),                         // Clock for Port A
        .WEA(we_a),                           // Write enable for Port A

        .ADA0(1'b0),                          // Data output for Port B
        .ADA1(1'b0),                          // Data output for Port B
        .ADA2(1'b0),                          // Data output for Port B
        .ADA3(addr_a[0]),                          // Data output for Port B
        .ADA4(addr_a[1]),                          // Data output for Port B
        .ADA5(addr_a[2]),                          // Data output for Port B
        .ADA6(addr_a[3]),                          // Data output for Port B
        .ADA7(addr_a[4]),                          // Data output for Port B
        .ADA8(addr_a[5]),                          // Data output for Port B
        .ADA9(addr_a[6]),                          // Data output for Port B
        .ADA10(addr_a[7]),                          // Data output for Port B
        .ADA11(addr_a[8]),                          // Data output for Port B
        .ADA12(addr_a[9]),                          // Data output for Port B
        .ADA13(addr_a[10]),                          // Data output for Port B

        .DIA0(din_a[0]),                          // Data output for Port B
        .DIA1(din_a[1]),                          // Data output for Port B
        .DIA2(din_a[2]),                          // Data output for Port B
        .DIA3(din_a[3]),                          // Data output for Port B
        .DIA4(din_a[4]),                          // Data output for Port B
        .DIA5(din_a[5]),                          // Data output for Port B
        .DIA6(din_a[6]),                          // Data output for Port B
        .DIA7(din_a[7]),                          // Data output for Port B
        .DIA8(din_a[8]),                          // Data output for Port B
        .DIA9(din_a[9]),                          // Data output for Port B

        .DOA0(dout_a[0]),                          // Data output for Port B
        .DOA1(dout_a[1]),                          // Data output for Port B
        .DOA2(dout_a[2]),                          // Data output for Port B
        .DOA3(dout_a[3]),                          // Data output for Port B
        .DOA4(dout_a[4]),                          // Data output for Port B
        .DOA5(dout_a[5]),                          // Data output for Port B
        .DOA6(dout_a[6]),                          // Data output for Port B
        .DOA7(dout_a[7]),                          // Data output for Port B
        .DOA8(dout_a[8]),                          // Data output for Port B
        .DOA9(dout_a[9]),                          // Data output for Port B

        .CLKB(clk_b),                         // Clock for Port B
        .WEB(we_b),                           // Write enable for Port B

        .ADB0(1'b0),                          // Data output for Port B
        .ADB1(1'b0),                          // Data output for Port B
        .ADB2(1'b0),                          // Data output for Port B
        .ADB3(addr_b[0]),                          // Data output for Port B
        .ADB4(addr_b[1]),                          // Data output for Port B
        .ADB5(addr_b[2]),                          // Data output for Port B
        .ADB6(addr_b[3]),                          // Data output for Port B
        .ADB7(addr_b[4]),                          // Data output for Port B
        .ADB8(addr_b[5]),                          // Data output for Port B
        .ADB9(addr_b[6]),                          // Data output for Port B
        .ADB10(addr_b[7]),                          // Data output for Port B
        .ADB11(addr_b[8]),                          // Data output for Port B
        .ADB12(addr_b[9]),                          // Data output for Port B
        .ADB13(addr_b[10]),                          // Data output for Port B

        .DIB0(din_b[0]),                          // Data output for Port B
        .DIB1(din_b[1]),                          // Data output for Port B
        .DIB2(din_b[2]),                          // Data output for Port B
        .DIB3(din_b[3]),                          // Data output for Port B
        .DIB4(din_b[4]),                          // Data output for Port B
        .DIB5(din_b[5]),                          // Data output for Port B
        .DIB6(din_b[6]),                          // Data output for Port B
        .DIB7(din_b[7]),                          // Data output for Port B
        .DIB8(din_b[8]),                          // Data output for Port B
        .DIB9(din_b[9]),                          // Data output for Port B

        .DOB0(dout_b[0]),                          // Data output for Port B
        .DOB1(dout_b[1]),                          // Data output for Port B
        .DOB2(dout_b[2]),                          // Data output for Port B
        .DOB3(dout_b[3]),                          // Data output for Port B
        .DOB4(dout_b[4]),                          // Data output for Port B
        .DOB5(dout_b[5]),                          // Data output for Port B
        .DOB6(dout_b[6]),                          // Data output for Port B
        .DOB7(dout_b[7]),                          // Data output for Port B
        .DOB8(dout_b[8]),                          // Data output for Port B
        .DOB9(dout_b[9])                          // Data output for Port B
    );

endmodule

