
`include "project.vh"

module fpga_gameconsole (
    output led1,
    output led2,

    output tx,
    input rx,

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

    // ECP5 OSCG: 310 MHz / 11 ≈ 28.18 MHz (close to C16 PAL 28.375 MHz)
    defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;
    OSCG OSCI1 (.OSC(clk));

    always @(posedge clk)
    begin
        lockCnt <= lockCnt + 1;

        if (lockCnt == 3'b111)
            rst <= 1;
    end

    // Drive lcd_clk directly from OSCG
    assign lcd_clk = clk;

    soc soc0(
        .clk(clk), .rst(rst),
        .led1(led1), .led2(led2),
        .tx(tx), .rx(rx),
        .joy(5'b11111),  // no joystick on FPGA (active-low)
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
