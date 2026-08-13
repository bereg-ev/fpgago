/*
 * psram_cmd_behav.v — behavioural stand-in for psram.v / psram_fast.v
 * (SIM ONLY).
 *
 * Same command/response contract — cmd pulse accepted when idle, `busy`,
 * `rdy` completion pulse — but the QPI protocol is a counter and the 8 MB
 * chip a 4 MB array.  Latencies are deliberately PESSIMISTIC against
 * psram_fast at 60 MHz SCLK + CDC (byte read ~15 clk real → 18 modelled),
 * so a design that meets its deadlines here has margin on silicon.  The
 * real engine is board-proven (psram_test console) and has its own pin-
 * level TBs; this file exists so check-drive-psram can run whole DOS
 * transactions at sim speed.
 *
 * Burst reads (cmd_words > 1 with cmd_byte=0) are modelled too, because the
 * EasyFlash line buffer fills with a 4-word burst and shares this engine in
 * the combined bitstream: one `word_rdy` pulse per 32-bit word, MSB-first
 * within the word (rdata[31:24] is the LOWEST address — the real engine's
 * order), then the single `rdy`.
 */

`default_nettype none

module psram_cmd_behav #(
    parameter RD_LAT = 18,
    parameter WR_LAT = 12
)(
    input  wire        clk,
    input  wire [23:0] cmd_addr,
    input  wire        cmd_rd,
    input  wire        cmd_wr,
    input  wire        cmd_byte,
    input  wire [3:0]  cmd_words,
    input  wire [31:0] cmd_wdata,
    output reg  [31:0] rdata,
    output reg         rdy,
    output reg         word_rdy,
    output reg  [2:0]  word_idx,
    output wire        busy
);

reg [7:0] mem [0:4194303];               /* 4 MB */

integer rd_lat = RD_LAT;
initial void'($value$plusargs("rdlat=%d", rd_lat));

reg [7:0]  cnt = 8'd0;
reg        is_rd = 1'b0;
reg        is_burst = 1'b0;
reg [3:0]  words_left = 4'd0;
reg [2:0]  widx = 3'd0;
reg [21:0] a;
reg [7:0]  wd;

/* a burst word costs ~4 clks on the real engine once the command overhead
 * is paid: first word at rd_lat, then one every WORD_LAT */
localparam WORD_LAT = 4;

assign busy = (cnt != 8'd0) || (words_left != 4'd0);

initial begin
    rdata = 32'd0; rdy = 1'b0; word_rdy = 1'b0; word_idx = 3'd0;
    a = 22'd0; wd = 8'd0;
end

always @(posedge clk) begin
    rdy      <= 1'b0;
    word_rdy <= 1'b0;
    if (cnt != 8'd0) begin
        cnt <= cnt - 8'd1;
        if (cnt == 8'd1) begin
            if (!is_rd) begin
                mem[a] <= wd;
                rdy <= 1'b1;
            end else if (!is_burst) begin
                rdata <= {24'b0, mem[a]};
                rdy   <= 1'b1;
            end else begin
                /* one 32-bit word, lowest address in the top byte */
                rdata <= {mem[a], mem[a + 22'd1],
                          mem[a + 22'd2], mem[a + 22'd3]};
                word_rdy <= 1'b1;
                word_idx <= widx;
                a        <= a + 22'd4;
                widx     <= widx + 3'd1;
                if (words_left == 4'd1) begin
                    words_left <= 4'd0;
                    rdy <= 1'b1;
                end else begin
                    words_left <= words_left - 4'd1;
                    cnt <= WORD_LAT[7:0];
                end
            end
        end
    end else if (cmd_rd || cmd_wr) begin
        a     <= cmd_addr[21:0];
        wd    <= cmd_wdata[7:0];
        is_rd <= cmd_rd;
        cnt   <= cmd_rd ? rd_lat[7:0] : WR_LAT[7:0];
        widx  <= 3'd0;
        if (cmd_rd && !cmd_byte) begin
            is_burst   <= 1'b1;
            words_left <= (cmd_words == 4'd0) ? 4'd1 : cmd_words;
        end else begin
            is_burst   <= 1'b0;
            words_left <= 4'd0;
        end
    end
end

endmodule
