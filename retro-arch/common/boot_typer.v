`timescale 1ns / 1ps
/*
 * boot_typer.v — replay a baked keystroke script into kbd_typer after boot
 * (c16 / plus4 / c64, GAME_PRG builds).
 *
 * On real hardware there is no host or MCU to send the autorun string over
 * UART, so a small script ROM (autorun.hex, PETSCII bytes as produced by
 * roms/prg2hex.py, 0x00-terminated) is replayed into the kbd_typer input a
 * fixed delay after reset.  This is what makes a baked-in PRG game start
 * hands-free on the board; in simulation the same RTL replaces --autotype
 * for GAME_PRG builds, so the exact hardware path is what gets tested.
 *
 * Script bytes:
 *   0x00  end of script (stop forever; ROM is 0-padded)
 *   0x01  long wait (WAIT_MS) — same convention as the sim autotyper
 *   else  PETSCII key, emitted as a 1-clk key_valid pulse
 *
 * Pacing mirrors the sim autotyper: CHAR_MS between keys, RET_MS after
 * RETURN (BASIC needs time to execute the line).  The kbd_typer FIFO is
 * 64 deep and drains at ~35ms/key, so 100ms/char never overflows it.
 *
 * The whole schedule restarts on reset.  That is deliberate: BRAM init
 * (the preloaded PRG) survives a board reset, and the KERNAL only clobbers
 * the few bytes the autorun script re-POKEs — so reset + replay restarts
 * the game without reconfiguring the FPGA.
 */
module boot_typer #(
    parameter CLK_HZ  = 28_375_000,
    parameter SIZE    = 128,      // script ROM depth (autorun.hex is padded)
    parameter HEXFILE = "../roms/autorun.hex",
    parameter BOOT_MS = 2500,     // reset -> first key (KERNAL to READY)
    parameter CHAR_MS = 100,      // between keys
    parameter RET_MS  = 500,      // after RETURN
    parameter WAIT_MS = 6000      // 0x01 sentinel
)(
    input            clk,
    input            rst,         // active-low, same as the SoCs
    output reg [7:0] key_data,
    output reg       key_valid    // 1-clk pulse per key
);

localparam [31:0] BOOT_CYC = BOOT_MS * (CLK_HZ / 1000);
localparam [31:0] CHAR_CYC = CHAR_MS * (CLK_HZ / 1000);
localparam [31:0] RET_CYC  = RET_MS  * (CLK_HZ / 1000);
localparam [31:0] WAIT_CYC = WAIT_MS * (CLK_HZ / 1000);

// Tiny script ROM: force LUT mapping, don't burn an EBR on 128 bytes.
(* ram_style = "logic" *)
reg [7:0] script [0:SIZE-1];
initial $readmemh(HEXFILE, script);

// FF init values match the async-reset values (ECP5 rule: yosys constfolds
// a never-deasserted reset away, and GSR init is what remains — see the
// uart tx power-up bug).
reg [31:0]            timer = BOOT_CYC;
reg [$clog2(SIZE)-1:0] pos  = 0;
reg                   done  = 0;

wire [7:0] cur = script[pos];    // combinational read (logic ROM)

always @(posedge clk or negedge rst)
    if (!rst) begin
        timer     <= BOOT_CYC;
        pos       <= 0;
        done      <= 0;
        key_data  <= 0;
        key_valid <= 0;
    end else begin
        key_valid <= 0;
        if (timer != 0)
            timer <= timer - 1;
        else if (!done) begin
            if (cur == 8'h00)
                done <= 1;
            else if (cur == 8'h01) begin
                timer <= WAIT_CYC;
                pos   <= pos + 1'b1;
            end else begin
                key_data  <= cur;
                key_valid <= 1;
                timer     <= (cur == 8'h0D) ? RET_CYC : CHAR_CYC;
                pos       <= pos + 1'b1;
            end
        end
    end

endmodule
