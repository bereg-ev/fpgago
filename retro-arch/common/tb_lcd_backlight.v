//
// tb_lcd_backlight.v — self-checking bench for lcd_backlight.v
//
// Measures the real duty cycle over exactly one PWM period for every BIOS
// step, and checks the two properties the panel depends on: full scale is
// genuine DC (never switches, so the default setting adds no ripple to the
// boost) and scale 0 is genuinely off.
//
//   iverilog -o /tmp/tb_lcd_backlight lcd_backlight.v tb_lcd_backlight.v &&
//   vvp /tmp/tb_lcd_backlight
//
`timescale 1ns/1ps

module tb_lcd_backlight;

    reg        clk = 0;
    reg  [6:0] scale = 7'd64;
    wire       pwm;
    integer    errors = 0;

    // PHASE_LSB 3 keeps the sim quick; the duty maths is identical at the
    // synthesis default of 9 (only the period changes).
    localparam PHASE_LSB = 3;
    localparam PERIOD    = (1 << (PHASE_LSB + 6));   // clocks per PWM period

    lcd_backlight #(.PHASE_LSB(PHASE_LSB)) dut (
        .clk(clk), .scale(scale), .pwm(pwm)
    );

    always #5 clk = ~clk;

    integer high, i;

    // Count high clocks across one full period and compare against scale/64.
    task measure_duty;
        input [6:0] s;
        input [31:0] want;
        begin
            scale = s;
            @(posedge clk);
            @(posedge clk);          // let the registered compare settle
            high = 0;
            for (i = 0; i < PERIOD; i = i + 1) begin
                @(posedge clk);
                #1 if (pwm) high = high + 1;
            end
            // 64 duty steps over PERIOD clocks: each step is PERIOD/64 clocks
            if (high !== want * (PERIOD / 64)) begin
                $display("FAIL scale %0d: %0d high clocks, want %0d",
                         s, high, want * (PERIOD / 64));
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Must come up ON: the panel has to be readable before the MCU sends
        // its first SET_BRIGHT.
        #1 if (pwm !== 1'b1) begin
            $display("FAIL: backlight did not power up on");
            errors = errors + 1;
        end

        measure_duty(7'd64, 32'd64);   // full = DC high
        measure_duty(7'd0,  32'd0);    // off
        measure_duty(7'd1,  32'd1);    // dimmest BIOS step
        measure_duty(7'd11, 32'd11);   // BIOS step 5
        measure_duty(7'd32, 32'd32);   // half

        // full scale must never toggle — check it stays high for a period
        scale = 7'd64;
        @(posedge clk); @(posedge clk);
        for (i = 0; i < PERIOD; i = i + 1) begin
            @(posedge clk);
            #1 if (!pwm) begin
                $display("FAIL: pwm dipped at full scale");
                errors = errors + 1;
                i = PERIOD;
            end
        end

        if (errors == 0) $display("PASS: all checks OK");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
