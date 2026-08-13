// lcd_backlight.v — PWM dimmer for the panel backlight enable (lcd_pwm, N4)
//
// The pin drives the MT9284 boost's enable through R2 (which pulls it low
// whenever the fabric is unconfigured, so an unprogrammed board is dark).
// Before this module every ARCH just tied it high — the backlight is the
// single biggest load on the battery (~100-200 mA of a ~350 mA total), so it
// is now dimmable from the BIOS over the QSPI link (qspi_slave.v SET_BRIGHT
// 0x0C -> bright_scale).
//
// 64 duty steps at ~1 kHz (with the default PHASE_LSB on a ~30 MHz machine
// clock).  Two things set that frequency:
//   * fast enough that neither the eye nor a camera sees flicker, and
//   * slow enough that the boost's own control loop can follow it — but the
//     minimum non-zero pulse (1/64 of the period, ~16 us) still has to be
//     long enough for the converter to actually start switching.  If step 1
//     ever makes the panel flicker or buzz on real hardware, raise the duty
//     floor in the LUT rather than slowing the PWM down.
//
// scale is 0..64 = off..full.  Anything >= 64 is a constant 1, so full
// brightness is genuinely DC — no switching noise at the default setting.
module lcd_backlight #(
    // Period = 2^(PHASE_LSB+6) clocks.  9 -> 32768 clocks: 961 Hz at
    // 31.5 MHz (c64 dot4x), 763 Hz at 25 MHz.  Bump it on a slower core.
    parameter PHASE_LSB = 9
) (
    input        clk,
    input  [6:0] scale,     // 0 = off .. 64 = full on
    output reg   pwm
);
    // No reset port on purpose: this must come up ON.  A power-up initial is
    // enough here (and matches the ECP5 rule that an FF's init value has to
    // agree with its async-SR value — there is no SR to disagree with).
    initial pwm = 1'b1;

    reg [PHASE_LSB+5:0] cnt = 0;
    wire [5:0] phase = cnt[PHASE_LSB+5:PHASE_LSB];

    always @(posedge clk) begin
        cnt <= cnt + 1'b1;
        pwm <= (scale > {1'b0, phase});   // registered: no comparator glitches
    end
endmodule
