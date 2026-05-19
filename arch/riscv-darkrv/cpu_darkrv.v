/* cpu_darkrv — adapter around DarkRISCV that exposes a simple bus interface.
 *
 * DarkRISCV (https://github.com/darklife/darkriscv) is a small open-source
 * RV32I core by Marcelo Samsoniuk (BSD-3).  Source file: darkriscv.v.
 *
 * Bus interface exposed here (matches the convention used in this repo):
 *  - instr_addr / instr_value : direct BRAM read, 1-cycle synchronous latency.
 *  - data_addr / data_in_value / data_out_value with rd/wr pulses + byte strobe.
 *
 * Adapter notes:
 *  - DarkRISCV's RES is active-high; we expose active-low `rst` and invert.
 *  - 32-bit addr buses are truncated to 24-bit (16 MB address space).
 *  - IDACK is tied high (ROM is always ready).  DDACK is driven from the
 *    SoC: it stays 1 for combinational memory paths (BRAM, MMIO) and pulses
 *    for slow memories like PSRAM so the pipeline stalls cleanly.
 */
`default_nettype none

// DarkRISCV configuration (subset of upstream config.vh).
// Keep these aligned with darkriscv.v's `ifdefs.
`define __3STAGE__
`define __HARVARD__
`define __RESETPC__ 32'd0
// RV32I (not RV32E) → 32 architectural registers.
`define RLEN 32

module cpu_darkrv (
    input         clk,
    input         rst,             // active-low

    output [23:0] instr_addr,
    input  [31:0] instr_value,

    output [23:0] data_addr,
    input  [31:0] data_in_value,
    output        data_rd,
    output [31:0] data_out_value,
    output [3:0]  data_out_strobe,
    output        data_wr,
    input         data_ack         // 1 = transaction complete this cycle
);

    wire [31:0] iaddr_full;
    wire [31:0] daddr_full;

    darkriscv u_dark (
        .CLK   (clk),
        .RES   (~rst),

        // instruction bus
        .IDREQ (),
        .IADDR (iaddr_full),
        .IDATA (instr_value),
        .IDACK (1'b1),
        .IBERR (1'b0),

        // data bus
        .DDREQ (),
        .DADDR (daddr_full),
        .DLEN  (),
        .DBE   (data_out_strobe),
        .DRW   (),
        .DRD   (data_rd),
        .DWR   (data_wr),
        .DATAO (data_out_value),
        .DATAI (data_in_value),
        .DDACK (data_ack),
        .DBERR (1'b0),

        .DEBUG ()
    );

    assign instr_addr = iaddr_full[23:0];
    assign data_addr  = daddr_full[23:0];

endmodule

`default_nettype wire
