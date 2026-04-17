
`include "project.vh"

module fpga_gameconsole (
    output led1,
    output led2,

    output tx,
    input rx,

    output i2s_en,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_mclk,
    output i2s_data,

    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk
);

    wire clk;
    reg rst;
    reg [2:0] lockCnt;

    defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;
    OSCG OSCI1 (.OSC(clk));

    always @(posedge clk)
    begin
        lockCnt <= lockCnt + 1;

        if (lockCnt == 3'b111)
            rst <= 1;
    end

    // Drive lcd_clk directly from OSCG — don't route through SoC
    // to avoid nextpnr misidentifying the IO pad as the clock source
    assign lcd_clk = clk;

    soc soc0(
        .clk(clk), .rst(rst),
        .led1(led1), .led2(led2),
        .tx(tx), .rx(rx),
        .i2s_en(i2s_en), .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_mclk(i2s_mclk), .i2s_data(i2s_data),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .lcd_data(lcd_data), .lcd_pwm(lcd_pwm), .lcd_clk()
    );

    initial begin
        lockCnt <= 0;
`ifdef SIMULATION
        rst <= 0;
`endif
    end

endmodule
