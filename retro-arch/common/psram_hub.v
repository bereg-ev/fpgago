/*
 * psram_hub.v — two clients, one APS6404L.
 *
 * The c64 has ONE PSRAM and two things that want it: the EasyFlash cart
 * image (c64_easyflash.v) and the fabric 1541's DOS ROM + GCR tracks
 * (drive_psram.v).  Both already speak the psram.v / psram_fast.v command
 * contract, so sharing is arbitration, not translation:
 *
 *   client asserts cmd_rd/cmd_wr for ONE clk with addr/byte/words valid,
 *   only while its `busy` is low; the engine answers with a `rdy` pulse
 *   (plus `word_rdy`/`word_idx` per word of a burst read).
 *
 * Priority is FIXED: client 0 first.  Wire the DRIVE there.  The drive's
 * phi can stretch around a fetch, but the KERNAL's ~20-26 us bit windows
 * cannot (the fabric 1541 notes in c64/README.md: a drive running 1.2x slow
 * corrupts ATN secondaries), so the drive must never queue behind more than
 * the one cart access already in flight.  Worst case for the drive is that
 * transaction's tail: a 4-word burst at 56.75 MHz SCLK is ~0.8 us, absorbed
 * by exactly the phi stretch the design already has.
 *
 * Each client gets a ONE-DEEP request register.  A client's cmd pulse lasts
 * a single clk, so without it a request raised in the same clk the other
 * client is granted would simply vanish — the classic arbiter data loss.
 * `busy` back to a client is high while its own slot is occupied, which is
 * what makes the 1-deep slot sufficient: it cannot be asked to hold two.
 *
 * Pure clk-domain glue: no CDC here (psram_fast does its own).
 */

`default_nettype none

module psram_hub (
    input  wire        clk,
    input  wire        rst,             /* active LOW, soc idiom */

    /* ── client 0 (priority — the fabric 1541) ─────────────────────────── */
    input  wire [23:0] c0_addr,
    input  wire        c0_rd,
    input  wire        c0_wr,
    input  wire        c0_byte,
    input  wire [3:0]  c0_words,
    input  wire [31:0] c0_wdata,
    output wire        c0_rdy,
    output wire        c0_word_rdy,
    output wire [2:0]  c0_word_idx,
    output wire        c0_busy,

    /* ── client 1 (the EasyFlash cart) ─────────────────────────────────── */
    input  wire [23:0] c1_addr,
    input  wire        c1_rd,
    input  wire        c1_wr,
    input  wire        c1_byte,
    input  wire [3:0]  c1_words,
    input  wire [31:0] c1_wdata,
    output wire        c1_rdy,
    output wire        c1_word_rdy,
    output wire [2:0]  c1_word_idx,
    output wire        c1_busy,

    /* ── the engine ────────────────────────────────────────────────────── */
    output reg  [23:0] e_addr,
    output reg         e_rd,
    output reg         e_wr,
    output reg         e_byte,
    output reg  [3:0]  e_words,
    output reg  [31:0] e_wdata,
    input  wire        e_rdy,
    input  wire        e_word_rdy,
    input  wire [2:0]  e_word_idx,
    input  wire        e_busy
);

    /* pending request slots */
    reg        q0_v, q1_v;
    reg        q0_wr, q1_wr;
    reg        q0_byte, q1_byte;
    reg [23:0] q0_addr, q1_addr;
    reg [3:0]  q0_words, q1_words;
    reg [31:0] q0_wdata, q1_wdata;

    reg        active;                  /* a transaction is in flight */
    reg        owner;                   /* whose it is */

    /* A client may present a new request whenever its own slot is free —
     * it never has to know about the other one. */
    assign c0_busy = q0_v;
    assign c1_busy = q1_v;

    assign c0_rdy      = e_rdy      && active && (owner == 1'b0);
    assign c0_word_rdy = e_word_rdy && active && (owner == 1'b0);
    assign c0_word_idx = e_word_idx;
    assign c1_rdy      = e_rdy      && active && (owner == 1'b1);
    assign c1_word_rdy = e_word_rdy && active && (owner == 1'b1);
    assign c1_word_idx = e_word_idx;

    /* power-up values mirror the async-reset values (ecp5-rst-constfold) */
    initial begin
        q0_v = 1'b0; q1_v = 1'b0; active = 1'b0; owner = 1'b0;
        q0_wr = 1'b0; q1_wr = 1'b0; q0_byte = 1'b1; q1_byte = 1'b1;
        q0_addr = 24'd0; q1_addr = 24'd0;
        q0_words = 4'd1; q1_words = 4'd1;
        q0_wdata = 32'd0; q1_wdata = 32'd0;
        e_addr = 24'd0; e_rd = 1'b0; e_wr = 1'b0;
        e_byte = 1'b1; e_words = 4'd1; e_wdata = 32'd0;
    end

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            q0_v <= 1'b0; q1_v <= 1'b0;
            active <= 1'b0; owner <= 1'b0;
            e_rd <= 1'b0; e_wr <= 1'b0;
        end else begin
            e_rd <= 1'b0;
            e_wr <= 1'b0;

            /* capture (a client only fires while its slot is free) */
            if (c0_rd || c0_wr) begin
                q0_v <= 1'b1; q0_wr <= c0_wr; q0_addr <= c0_addr;
                q0_byte <= c0_byte; q0_words <= c0_words; q0_wdata <= c0_wdata;
            end
            if (c1_rd || c1_wr) begin
                q1_v <= 1'b1; q1_wr <= c1_wr; q1_addr <= c1_addr;
                q1_byte <= c1_byte; q1_words <= c1_words; q1_wdata <= c1_wdata;
            end

            if (e_rdy)
                active <= 1'b0;

            /* issue — same guard the clients used to apply themselves */
            if (!active && !e_busy && !e_rd && !e_wr && !e_rdy) begin
                if (q0_v) begin
                    e_addr <= q0_addr; e_byte <= q0_byte;
                    e_words <= q0_words; e_wdata <= q0_wdata;
                    e_rd <= ~q0_wr; e_wr <= q0_wr;
                    q0_v <= 1'b0; owner <= 1'b0; active <= 1'b1;
                end else if (q1_v) begin
                    e_addr <= q1_addr; e_byte <= q1_byte;
                    e_words <= q1_words; e_wdata <= q1_wdata;
                    e_rd <= ~q1_wr; e_wr <= q1_wr;
                    q1_v <= 1'b0; owner <= 1'b1; active <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
