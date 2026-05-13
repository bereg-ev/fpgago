/*
 * ddr3_axi_sim.v — Behavioural AXI4 slave for DDR3-test simulation.
 *
 * Replaces the entire ddr3_axi + DFI + ECP5 PHY chain with a flat host-side
 * memory.  Same interface as ddr3_axi (signal naming follows the upstream
 * controller so soc.v can swap the two through `ifdef SIMULATION`).
 *
 * Coverage: enough to validate the peripheral wrapper and the test program.
 *   - INCR bursts up to 256 beats, 32-bit data, byte-strobe writes.
 *   - 0-cycle command latency (AWREADY/ARREADY combinational).
 *   - 1 cycle from accepted W beat to BVALID, after WLAST.
 *   - 1 cycle from accepted AR to first RVALID, then back-to-back beats.
 *
 * Memory size is set by ADDR_WORDS (default 256K words = 1 MB).  Anything
 * outside that range wraps back into the array (good enough for sim of the
 * lower-region tests; the full-region random sweep needs real silicon).
 */

module ddr3_axi_sim #(
    parameter ADDR_WORDS = 262144     /* 1 MB / 4 = 256K words */
) (
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire        inport_awvalid_i,
    input  wire [31:0] inport_awaddr_i,
    input  wire [ 3:0] inport_awid_i,
    input  wire [ 7:0] inport_awlen_i,
    input  wire [ 1:0] inport_awburst_i,
    output reg         inport_awready_o,

    input  wire        inport_wvalid_i,
    input  wire [31:0] inport_wdata_i,
    input  wire [ 3:0] inport_wstrb_i,
    input  wire        inport_wlast_i,
    output reg         inport_wready_o,

    output reg         inport_bvalid_o,
    output wire [ 1:0] inport_bresp_o,
    output reg  [ 3:0] inport_bid_o,
    input  wire        inport_bready_i,

    input  wire        inport_arvalid_i,
    input  wire [31:0] inport_araddr_i,
    input  wire [ 3:0] inport_arid_i,
    input  wire [ 7:0] inport_arlen_i,
    input  wire [ 1:0] inport_arburst_i,
    output reg         inport_arready_o,

    output reg         inport_rvalid_o,
    output reg  [31:0] inport_rdata_o,
    output wire [ 1:0] inport_rresp_o,
    output reg         inport_rlast_o,
    output reg  [ 3:0] inport_rid_o,
    input  wire        inport_rready_i
);

assign inport_bresp_o = 2'b00;
assign inport_rresp_o = 2'b00;

/* The flat memory.  Verilator stores this as host RAM. */
reg [31:0] mem [0:ADDR_WORDS-1];

initial begin : init_mem
    integer k;
    for (k = 0; k < ADDR_WORDS; k = k + 1) mem[k] = 32'h0;
end

/* ── Write channel ──────────────────────────────────────────────────────── */
reg        wr_active;
reg [31:0] wr_addr;
reg [ 7:0] wr_len_left;
reg [ 3:0] wr_id;

wire [(31 - 2):0] wr_word_idx_full = wr_addr[31:2];
wire [(31 - 2):0] wr_word_idx      = wr_word_idx_full % ADDR_WORDS;

always @(posedge clk_i) begin
    if (rst_i) begin
        wr_active        <= 1'b0;
        inport_awready_o <= 1'b0;
        inport_wready_o  <= 1'b0;
        inport_bvalid_o  <= 1'b0;
        inport_bid_o     <= 4'h0;
        wr_addr          <= 32'h0;
        wr_len_left      <= 8'h0;
        wr_id            <= 4'h0;
    end else begin
        /* B-channel handshake clears bvalid. */
        if (inport_bvalid_o && inport_bready_i)
            inport_bvalid_o <= 1'b0;

        if (!wr_active) begin
            inport_awready_o <= 1'b1;
            inport_wready_o  <= 1'b0;
            if (inport_awvalid_i && inport_awready_o) begin
                wr_active        <= 1'b1;
                wr_addr          <= inport_awaddr_i;
                wr_len_left      <= inport_awlen_i;
                wr_id            <= inport_awid_i;
                inport_awready_o <= 1'b0;
                inport_wready_o  <= 1'b1;
            end
        end else begin
            inport_wready_o <= 1'b1;
            if (inport_wvalid_i && inport_wready_o) begin
                /* Apply write with byte strobes. */
                if (inport_wstrb_i[0])
                    mem[wr_word_idx][ 7: 0] <= inport_wdata_i[ 7: 0];
                if (inport_wstrb_i[1])
                    mem[wr_word_idx][15: 8] <= inport_wdata_i[15: 8];
                if (inport_wstrb_i[2])
                    mem[wr_word_idx][23:16] <= inport_wdata_i[23:16];
                if (inport_wstrb_i[3])
                    mem[wr_word_idx][31:24] <= inport_wdata_i[31:24];

                if (inport_wlast_i) begin
                    wr_active       <= 1'b0;
                    inport_wready_o <= 1'b0;
                    inport_bvalid_o <= 1'b1;
                    inport_bid_o    <= wr_id;
                end else begin
                    wr_addr     <= wr_addr     + 32'd4;
                    wr_len_left <= wr_len_left - 8'd1;
                end
            end
        end
    end
end

/* ── Read channel ───────────────────────────────────────────────────────── */
reg        rd_active;
reg [31:0] rd_addr;
reg [ 7:0] rd_len_left;
reg [ 3:0] rd_id;

wire [(31 - 2):0] rd_word_idx_full = rd_addr[31:2];
wire [(31 - 2):0] rd_word_idx      = rd_word_idx_full % ADDR_WORDS;

always @(posedge clk_i) begin
    if (rst_i) begin
        rd_active        <= 1'b0;
        inport_arready_o <= 1'b0;
        inport_rvalid_o  <= 1'b0;
        inport_rdata_o   <= 32'h0;
        inport_rlast_o   <= 1'b0;
        inport_rid_o     <= 4'h0;
        rd_addr          <= 32'h0;
        rd_len_left      <= 8'h0;
        rd_id            <= 4'h0;
    end else begin
        if (inport_rvalid_o && inport_rready_i) begin
            inport_rvalid_o <= 1'b0;
            inport_rlast_o  <= 1'b0;
        end

        if (!rd_active) begin
            inport_arready_o <= 1'b1;
            if (inport_arvalid_i && inport_arready_o) begin
                rd_active        <= 1'b1;
                rd_addr          <= inport_araddr_i;
                rd_len_left      <= inport_arlen_i;
                rd_id            <= inport_arid_i;
                inport_arready_o <= 1'b0;
            end
        end else if (!inport_rvalid_o || (inport_rvalid_o && inport_rready_i)) begin
            inport_rdata_o  <= mem[rd_word_idx];
            inport_rid_o    <= rd_id;
            inport_rvalid_o <= 1'b1;
            inport_rlast_o  <= (rd_len_left == 8'd0);
            if (rd_len_left == 8'd0) begin
                rd_active <= 1'b0;
            end else begin
                rd_addr     <= rd_addr     + 32'd4;
                rd_len_left <= rd_len_left - 8'd1;
            end
        end
    end
end

endmodule
