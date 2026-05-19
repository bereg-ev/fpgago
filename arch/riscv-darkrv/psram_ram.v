/*
 * psram_ram.v — Thin "RAM-shaped" wrapper around peripheral/psram.v.
 *
 * Designed for the DarkRISCV data bus: one CPU client, no instruction port,
 * no code-upload port, no ROM bypass.  Provides a single-word read/write
 * interface with a 1-cycle ack pulse that the soc.v uses to drive DDACK.
 *
 * CPU-facing handshake (per access):
 *   cycle 0   : CPU asserts rd|wr with addr (and wdata/wstrobe for wr).
 *               This module returns ack=0 → DDACK=0 → DarkRISCV stalls.
 *   cycle N   : when PSRAM signals rdy, ack pulses high for 1 cycle and
 *               rdata is valid.  CPU's REGS write captures it.
 *   cycle N+1 : SETTLE — FSM declines to start a new transaction this
 *               cycle so the CPU can advance its pipeline cleanly.
 *               (Without this 1-cycle gap the FSM would mis-trigger on the
 *                just-completed level-held rd signal — see DarkRISCV's
 *                XLCC register update at the same edge the CPU advances.)
 *
 * Partial-strobe stores (sb/sh) become a read-modify-write internally.
 */
`default_nettype none

module psram_ram (
    input  wire        clk,
    input  wire        rst,            // active-low

    /* CPU-facing word-bus */
    input  wire [23:0] addr,           // byte address (low 2 bits ignored for word ops)
    input  wire        rd,
    input  wire        wr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrobe,
    output reg  [31:0] rdata,
    output wire        ack,            // 1-cycle pulse on completion

    /* PSRAM chip pins (passed through to peripheral/psram.v) */
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3
);

    localparam ST_IDLE      = 3'd0;
    localparam ST_READ      = 3'd1;
    localparam ST_WRITE     = 3'd2;
    localparam ST_RMW_READ  = 3'd3;
    localparam ST_RMW_WRITE = 3'd4;
    localparam ST_SETTLE    = 3'd5;

    reg [2:0]  state;
    reg [23:0] saved_addr;
    reg [31:0] saved_wdata;
    reg [3:0]  saved_wstrobe;

    reg        ps_rd_pulse;
    reg        ps_wr_pulse;
    reg [23:0] ps_addr;
    reg [31:0] ps_wdata;
    wire       ps_rdy;
    wire       ps_busy;
    wire [31:0] ps_rdata;

    psram u_psram (
        .clk        (clk),
        .rst        (rst),
        .cmd_addr   (ps_addr),
        .cmd_rd     (ps_rd_pulse),
        .cmd_wr     (ps_wr_pulse),
        .cmd_wdata  (ps_wdata),
        .rdata      (ps_rdata),
        .rdy        (ps_rdy),
        .busy       (ps_busy),
        .psram_sclk (psram_sclk),
        .psram_ce_n (psram_ce_n),
        .psram_sio0 (psram_sio0),
        .psram_sio1 (psram_sio1),
        .psram_sio2 (psram_sio2),
        .psram_sio3 (psram_sio3)
    );

    reg ack_pulse;
    assign ack = ack_pulse;

    /* RMW byte merge: take orig for lanes where strobe=0, new_data for lanes=1. */
    function [31:0] merge_bytes;
        input [31:0] orig;
        input [31:0] new_data;
        input [3:0]  strobe;
        begin
            merge_bytes = {
                strobe[3] ? new_data[31:24] : orig[31:24],
                strobe[2] ? new_data[23:16] : orig[23:16],
                strobe[1] ? new_data[15: 8] : orig[15: 8],
                strobe[0] ? new_data[ 7: 0] : orig[ 7: 0]
            };
        end
    endfunction

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state         <= ST_IDLE;
            ps_rd_pulse   <= 1'b0;
            ps_wr_pulse   <= 1'b0;
            ack_pulse     <= 1'b0;
            rdata         <= 32'b0;
            saved_addr    <= 24'b0;
            saved_wdata   <= 32'b0;
            saved_wstrobe <= 4'b0;
            ps_addr       <= 24'b0;
            ps_wdata      <= 32'b0;
        end else begin
            // Defaults (overridden by case branches as needed)
            ps_rd_pulse <= 1'b0;
            ps_wr_pulse <= 1'b0;
            ack_pulse   <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (rd) begin
                        ps_addr     <= addr;
                        ps_rd_pulse <= 1'b1;
                        state       <= ST_READ;
                    end else if (wr) begin
                        if (wstrobe == 4'b1111) begin
                            ps_addr     <= addr;
                            ps_wdata    <= wdata;
                            ps_wr_pulse <= 1'b1;
                            state       <= ST_WRITE;
                        end else begin
                            // Partial: read-modify-write.
                            saved_addr    <= addr;
                            saved_wdata   <= wdata;
                            saved_wstrobe <= wstrobe;
                            ps_addr       <= addr;
                            ps_rd_pulse   <= 1'b1;
                            state         <= ST_RMW_READ;
                        end
                    end
                end

                ST_READ: begin
                    if (ps_rdy) begin
                        rdata     <= ps_rdata;
                        ack_pulse <= 1'b1;
                        state     <= ST_SETTLE;
                    end
                end

                ST_WRITE: begin
                    if (ps_rdy) begin
                        ack_pulse <= 1'b1;
                        state     <= ST_SETTLE;
                    end
                end

                ST_RMW_READ: begin
                    if (ps_rdy) begin
                        ps_addr     <= saved_addr;
                        ps_wdata    <= merge_bytes(ps_rdata, saved_wdata, saved_wstrobe);
                        ps_wr_pulse <= 1'b1;
                        state       <= ST_RMW_WRITE;
                    end
                end

                ST_RMW_WRITE: begin
                    if (ps_rdy) begin
                        ack_pulse <= 1'b1;
                        state     <= ST_SETTLE;
                    end
                end

                ST_SETTLE: begin
                    // 1-cycle gap so the CPU can advance and we don't refire
                    // on the just-completed (level-held) rd/wr signal.
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
