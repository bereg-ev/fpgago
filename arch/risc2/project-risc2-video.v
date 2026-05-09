

`include "project.vh"

module fpga_gameconsole (
    output led1,		// onboard LED
	output led2,

	output tx, 			// serial UART to STM32
	input rx,

    output i2s_en,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_mclk,
    output i2s_data,

//    output dbg1,
//    output dbg2,

    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk,

`ifdef HW_V2
    /* HW=v2: APS6404L QSPI PSRAM (8 MB), single chip.  Y-SDRAM is gone too
     * (replaced on the v2 board by DDR3 — driver TBD). */
    output psram_sclk,
    output psram_ce_n,
    inout  psram_sio0,
    inout  psram_sio1,
    inout  psram_sio2,
    inout  psram_sio3
`else
		output xclk,		// 39 io's
    output xcke,
    output xcs,
    output xras,
    output xcas,
    output xwe,
    output [12:0] xa,
    inout  [15:0] xd,
    output [1:0] xba,
    output xldqm,
    output xudqm,

		output yclk,		// 39 io's
    output ycke,
    output ycs,
    output yras,
    output ycas,
    output ywe,
    output [12:0] ya,
    inout  [15:0] yd,
    output [1:0] yba,
    output yldqm,
    output yudqm
`endif
);

	wire clk;        // Internal OSCILLATOR clock
	reg rst;				// emulate PLL lock for the Soc, which has its own CPU reset driven by the UART
	reg [2:0] lockCnt;

//	defparam OSCI1.DIV = "32";        // 9.6 MHz
	defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;    // 16
	OSCG OSCI1 (.OSC(clk));

/* PLL is deferred — current PSRAM controller is single-clock at sys_clk.
 * Once bring-up is correct we'll add EHXPLLL to spin a faster psram_clk
 * (target ~80 MHz, chip is rated to 144 MHz QPI) and split the controller. */

  wire socdbg1, socdbg2;

//  assign dbg1 = socdbg1; // xd[0];
//  assign dbg2 = socdbg2; // xcs;

//	DELAYG xsd2ClockDelay(.A(clk), .Z(dbg2));

`ifndef HW_V2
  assign xclk = ~clk;
  assign yclk = ~clk;
`endif

//	DELAYG xsdClockDelay(.A(~clk), .Z(xclk));
//	DELAYG ysdClockDelay(.A(~clk), .Z(yclk));

	always @(posedge clk)
	begin
		lockCnt <= lockCnt + 1;

		if (lockCnt == 3'b111)
			rst <= 1;
	end

	soc soc0(
    .clk(clk),
    .rst(rst), .led1(led1), .led2(led2), .tx(tx), .rx(rx), .dbg1(socdbg1), .dbg2(socdbg2),

    .i2s_en(i2s_en), .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_mclk(i2s_mclk), .i2s_data(i2s_data),

    .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de), .lcd_clk(lcd_clk),
    .lcd_pwm(lcd_pwm), .lcd_data(lcd_data),

`ifdef HW_V2
    .psram_sclk(psram_sclk), .psram_ce_n(psram_ce_n),
    .psram_sio0(psram_sio0), .psram_sio1(psram_sio1),
    .psram_sio2(psram_sio2), .psram_sio3(psram_sio3)
`else
		.xcke(xcke), .xcs(xcs), .xras(xras), .xcas(xcas), .xwe(xwe),
    .xa(xa), .xd(xd), .xba(xba), .xldqm(xldqm), .xudqm(xudqm),

		.ycke(ycke), .ycs(ycs), .yras(yras), .ycas(ycas), .ywe(ywe),
    .ya(ya), .yd(yd), .yba(yba), .yldqm(yldqm), .yudqm(yudqm)
`endif

	);

  initial begin
    lockCnt <= 0;
`ifdef SIMULATION
    rst <= 0;   // unsupported initial value and async reset value combination ???
`endif

  end
endmodule
