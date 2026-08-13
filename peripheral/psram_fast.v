/*
 * psram_fast.v — Dual-clock QPI master for the AP Memory APS6404L (8 MB).
 *
 * PHASE-3 REWRITE (2026-07-29): the original was a fork of the pre-bring-up
 * psram.v and carried every bug that cost the slow path its 17 board runs
 * (nested-'z pads, 5 dummy cycles, combinational ~psram_clk SCLK gating).
 * This version is the board-proven psram.v protocol engine — single-level
 * tristates, silicon-calibrated 6+1 dummy alignment, byte + linear-burst
 * word reads with per-word strobes — moved into a fast `psram_clk` domain:
 *
 *   SCLK = psram_clk / 2 (2 psram_clk cycles per QPI bit, registered — the
 *   exact scheme the slow engine proved on the board at CLKDIV=1), so a
 *   120 MHz psram_clk gives a 60 MHz SCLK, up from 19.4.
 *
 * The one-time init (SPI Read-ID probe + 0x35 enter-QPI) runs SCLK at
 * psram_clk/16 — the chip's 1-bit SPI mode is slower than QPI and there is
 * zero reason to gamble the mode switch on margin.
 *
 * Read capture: the nominal sample point is the end of the SCLK-high phase
 * (as proven on the slow engine).  At tens-of-MHz SCLK the pad round trip
 * (FF→pad + chip tV + pad→FF) eats into that margin, so the consume strobes
 * can be delayed a whole number of psram_clk cycles with -DPSRAM_FAST_SKEW=N
 * (0..7, default 0) — the DDR3 read-eye lesson, as a build-time knob.  CE#
 * stays low through the drain so a delayed consume never reads a dead bus.
 *
 * Clock-domain crossing (kept from the old psram_fast, sim-proven): request
 * payload and response words ride dual-port mailboxes; only two 1-bit
 * toggles cross domains, each through a 2-FF synchroniser with LEVEL-compare
 * consumers, so an event can never be missed on an unlucky phase.  Burst
 * responses are written per-word into the response mailbox by the fast side
 * and REPLAYED as word_rdy pulses on the clk side after the single ack —
 * one toggle crossing per transaction, and mem_iface's line fill sees the
 * same word_rdy/word_idx/rdy contract as the slow engine.
 *
 * tCEM note: CE# low is bounded by 8 us.  At SCLK >= 30 MHz even an 8-word
 * burst is < 2.5 us — the mem_iface line size is not tCEM-limited here.
 */
`default_nettype none

`ifndef PSRAM_FAST_SKEW
`define PSRAM_FAST_SKEW 0
`endif

module psram_fast #(
    parameter SKEW = `PSRAM_FAST_SKEW,   /* read-capture delay, psram_clk cycles */
    parameter INIT_DIV = 8               /* init SCLK = psram_clk / (2*INIT_DIV) */
)(
    input  wire        clk,            /* SoC bus clock (slow)              */
    input  wire        psram_clk,      /* QPI clock (fast, from a PLL)      */
    input  wire        rst,            /* active-low, async                 */

    /* ── Command interface (clk domain) — identical to psram.v ─────────── */
    input  wire [23:0] cmd_addr,
    input  wire        cmd_rd,
    input  wire        cmd_wr,
    input  wire        cmd_byte,       /* 1 = single-byte transfer          */
    input  wire [3:0]  cmd_words,      /* burst words for reads (1..8; 0=1) */
    input  wire [31:0] cmd_wdata,
    output wire [31:0] rdata,
    output reg         rdy,            /* 1-cycle pulse on completion (clk) */
    output reg         word_rdy,       /* 1-cycle pulse per burst word (clk)*/
    output reg  [2:0]  word_idx,
    output wire        busy,

    /* ── PSRAM chip pins (psram_clk domain) ────────────────────────────── */
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3,

    /* ── Raw GPIO override (psram_test console) — identical contract to
     * psram.v: raw_en=1 masks the engine's pin drives, SIO0..3 driven only
     * when raw_oe=1, raw_sio_in exposes the live input levels.  Software
     * bit-bang is quasi-static, so no CDC care is needed. */
    input  wire        raw_en,
    input  wire        raw_sclk,
    input  wire        raw_ce_n,
    input  wire        raw_oe,
    input  wire [3:0]  raw_sio,
    output wire [3:0]  raw_sio_in,

    output reg  [31:0] dbg_id          /* init-time SPI Read-ID (psram_clk domain;
                                        * quasi-static after init — safe to read) */
);

    /* ════════════════════════════════════════════════════════════════════
     * Mailboxes + toggles (CDC)
     * ════════════════════════════════════════════════════════════════════ */
    localparam REQ_W = 62;   /* {is_read, is_byte, words[3:0], addr[23:0], wdata[31:0]} */

    reg [REQ_W-1:0] req_box;                 /* clk → psram_clk (single slot) */
    reg [31:0]      resp_ram [0:7];          /* psram_clk → clk (burst words) */

    reg  req_tog;                            /* clk → psram_clk */
    reg  ack_tog;                            /* psram_clk → clk */

    /* ════════════════════════════════════════════════════════════════════
     * clk domain — accept, and on ack REPLAY the response words as
     * word_rdy pulses followed by the completion rdy.
     * ════════════════════════════════════════════════════════════════════ */
    reg        busy_r;
    reg        rd_lat;                       /* accepted cmd was a read      */
    reg [3:0]  words_clk;                    /* accepted burst length        */
    reg [1:0]  ack_sync;
    reg        ack_seen;
    reg        replaying;
    reg [3:0]  repl_cnt;
    reg [31:0] resp_rdata;                   /* registered mailbox read      */
    reg [2:0]  resp_raddr;

    assign busy  = busy_r;
    assign rdata = resp_rdata;

    always @(posedge clk) resp_rdata <= resp_ram[resp_raddr];

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            req_tog    <= 1'b0;
            busy_r     <= 1'b0;
            rd_lat     <= 1'b0;
            words_clk  <= 4'd1;
            rdy        <= 1'b0;
            word_rdy   <= 1'b0;
            word_idx   <= 3'd0;
            ack_sync   <= 2'b0;
            ack_seen   <= 1'b0;
            replaying  <= 1'b0;
            repl_cnt   <= 4'd0;
            resp_raddr <= 3'd0;
        end else begin
            rdy      <= 1'b0;
            word_rdy <= 1'b0;
            ack_sync <= {ack_sync[0], ack_tog};

            /* Accept: commit the payload, then flip the toggle (same edge —
             * the 2-FF sync on the far side gives the payload 2+ fast cycles
             * to settle before it is read). */
            if (!busy_r && (cmd_rd || cmd_wr)) begin
                req_box   <= {cmd_rd, cmd_byte,
                              (cmd_words == 4'd0) ? 4'd1 : cmd_words,
                              cmd_addr, cmd_wdata};
                rd_lat    <= cmd_rd;
                words_clk <= (cmd_byte || !cmd_rd) ? 4'd1 :
                             ((cmd_words == 4'd0) ? 4'd1 : cmd_words);
                req_tog   <= ~req_tog;
                busy_r    <= 1'b1;
            end

            /* Ack: for writes finish immediately; for reads walk the
             * response mailbox — one word per clk, mem_iface-compatible. */
            if (busy_r && !replaying && (ack_sync[1] != ack_seen)) begin
                ack_seen <= ack_sync[1];
                if (rd_lat) begin
                    replaying  <= 1'b1;
                    repl_cnt   <= 4'd0;
                    resp_raddr <= 3'd0;      /* word 0 lands in resp_rdata next clk */
                end else begin
                    busy_r <= 1'b0;
                    rdy    <= 1'b1;
                end
            end
            else if (replaying) begin
                /* resp_rdata now holds word repl_cnt; prefetch the next. */
                word_rdy   <= 1'b1;
                word_idx   <= repl_cnt[2:0];
                resp_raddr <= repl_cnt[2:0] + 3'd1;
                repl_cnt   <= repl_cnt + 4'd1;
                if (repl_cnt + 4'd1 == words_clk) begin
                    replaying <= 1'b0;
                    busy_r    <= 1'b0;
                    rdy       <= 1'b1;       /* rdata = last replayed word...    */
                    resp_raddr<= repl_cnt[2:0];  /* ...hold it (single-word case:
                                              * ps_rdata must stay word 0)       */
                end
            end
        end
    end

    /* ════════════════════════════════════════════════════════════════════
     * psram_clk domain — the psram.v protocol FSM at CLKDIV=1, with the
     * init states running at INIT_DIV.
     * ════════════════════════════════════════════════════════════════════ */
    localparam S_INIT_CSL  = 5'd0;
    localparam S_INIT_CMD  = 5'd1;
    localparam S_INIT_CSH  = 5'd2;
    localparam S_IDLE      = 5'd3;
    localparam S_CMD       = 5'd4;
    localparam S_ADDR      = 5'd5;
    localparam S_DUMMY     = 5'd6;
    localparam S_WDATA     = 5'd7;
    localparam S_RDATA     = 5'd8;   /* generate the data SCLKs             */
    localparam S_RDRAIN    = 5'd9;   /* wait for the delayed consumes       */
    localparam S_CSHIGH    = 5'd10;
    localparam S_SID_CSL   = 5'd15;  /* SPI Read-ID probe (before QPI)      */
    localparam S_SID_CMD   = 5'd16;
    localparam S_SID_RD    = 5'd17;
    localparam S_SID_CSH   = 5'd18;

    reg [4:0]  state;
    reg [6:0]  bit_cnt;
    reg [7:0]  init_sr;
    reg [31:0] sid_sr;
    reg [15:0] id_spi_sr;
    reg [23:0] addr_sr;
    reg [31:0] data_sr;
    reg        is_read_lat;
    reg        is_byte_lat;
    reg [3:0]  words_lat;
    reg        ce_n_r;
    reg        spi_phase;
    reg        qpi_drive;
    reg [3:0]  sio_out;

    reg [1:0]  req_sync;
    reg        req_serviced;

    /* ── SIO pads: HARD RULE — oe/drv as plain logic, tristate exactly once. */
    wire [3:0] sio_oe;
    wire [3:0] sio_drv;
    assign sio_oe[0]  = raw_en ? raw_oe : (spi_phase | qpi_drive);
    assign sio_oe[1]  = raw_en ? raw_oe : (~spi_phase & qpi_drive); /* MISO in SPI */
    assign sio_oe[2]  = raw_en ? raw_oe : (spi_phase | qpi_drive);
    assign sio_oe[3]  = raw_en ? raw_oe : (spi_phase | qpi_drive);
    assign sio_drv[0] = raw_en ? raw_sio[0] : sio_out[0];
    assign sio_drv[1] = raw_en ? raw_sio[1] : sio_out[1];
    assign sio_drv[2] = raw_en ? raw_sio[2] : (spi_phase ? 1'b1 : sio_out[2]);
    assign sio_drv[3] = raw_en ? raw_sio[3] : (spi_phase ? 1'b1 : sio_out[3]);
    assign psram_sio0 = sio_oe[0] ? sio_drv[0] : 1'bz;
    assign psram_sio1 = sio_oe[1] ? sio_drv[1] : 1'bz;
    assign psram_sio2 = sio_oe[2] ? sio_drv[2] : 1'bz;
    assign psram_sio3 = sio_oe[3] ? sio_drv[3] : 1'bz;
    wire [3:0] sio_in = {psram_sio3, psram_sio2, psram_sio1, psram_sio0};
    assign raw_sio_in = sio_in;

    assign psram_ce_n = raw_en ? raw_ce_n : ce_n_r;

    /* ── Bit-period divider: init states run INIT_DIV, everything else 1. */
    wire in_init = (state == S_SID_CSL) || (state == S_SID_CMD) ||
                   (state == S_SID_RD)  || (state == S_SID_CSH) ||
                   (state == S_INIT_CSL) || (state == S_INIT_CMD) ||
                   (state == S_INIT_CSH);
    wire [4:0] cur_half = in_init ? INIT_DIV[4:0] : 5'd1;
    reg  [4:0] div_cnt;
    wire       tick = (div_cnt == (2*cur_half - 1));

    wire sclk_active = (state == S_INIT_CMD) || (state == S_CMD)   ||
                       (state == S_ADDR)     || (state == S_DUMMY) ||
                       (state == S_WDATA)    || (state == S_RDATA) ||
                       (state == S_SID_CMD)  || (state == S_SID_RD);
    assign psram_sclk = raw_en ? raw_sclk
                      : ((sclk_active && (div_cnt >= cur_half)) ? 1'b1 : 1'b0);

    /* ── Read-capture strobe delay line (see header).  A strobe is generated
     * at each data tick (the nominal end-of-high sample point) and consumed
     * SKEW psram_clk cycles later against the live pad value. */
    wire gen_strobe = tick && (state == S_RDATA);
    reg  [7:0] strobe_pipe;
    wire       consume = (SKEW == 0) ? gen_strobe : strobe_pipe[SKEW-1];

    reg [31:0] rdata_sr;
    reg [6:0]  con_cnt;                      /* consumed nibbles            */
    reg [6:0]  con_total;
    wire [31:0] rdata_new = {rdata_sr[27:0], sio_in};

    always @(posedge psram_clk or negedge rst) begin
        if (!rst) begin
            state        <= S_SID_CSL;
            bit_cnt      <= 7'd0;
            init_sr      <= 8'h35;
            sid_sr       <= {8'h9F, 24'h0};
            id_spi_sr    <= 16'b0;
            addr_sr      <= 24'b0;
            data_sr      <= 32'b0;
            is_read_lat  <= 1'b0;
            is_byte_lat  <= 1'b0;
            words_lat    <= 4'd1;
            ce_n_r       <= 1'b1;
            spi_phase    <= 1'b0;
            qpi_drive    <= 1'b0;
            sio_out      <= 4'b0;
            dbg_id       <= 32'b0;
            req_sync     <= 2'b0;
            req_serviced <= 1'b0;
            ack_tog      <= 1'b0;
            div_cnt      <= 5'd0;
            strobe_pipe  <= 8'b0;
            rdata_sr     <= 32'b0;
            con_cnt      <= 7'd0;
            con_total    <= 7'd8;
        end else begin
            req_sync    <= {req_sync[0], req_tog};
            strobe_pipe <= {strobe_pipe[6:0], gen_strobe};

            if (tick) div_cnt <= 5'd0;
            else      div_cnt <= div_cnt + 5'd1;

            /* ── Consume path: runs every psram_clk, decoupled from tick. */
            if (consume && con_cnt != con_total) begin
                rdata_sr <= rdata_new;
                con_cnt  <= con_cnt + 7'd1;
                if (is_byte_lat) begin
                    if (con_cnt == 7'd1)          /* 2nd nibble = byte done */
                        resp_ram[0] <= {24'b0, rdata_new[7:0]};
                end
                else if (con_cnt[2:0] == 3'd7)    /* 8th nibble of a word   */
                    resp_ram[con_cnt[5:3]] <= rdata_new;
            end

            if (tick) begin
            case (state)
            /* ── init: SPI Read-ID probe, then 0x35 enter-QPI (slow SCLK) ── */
            S_SID_CSL: begin
                ce_n_r    <= 1'b0;
                spi_phase <= 1'b1;
                sio_out   <= {3'b000, sid_sr[31]};
                sid_sr    <= {sid_sr[30:0], 1'b0};
                bit_cnt   <= 7'd31;
                state     <= S_SID_CMD;
            end
            S_SID_CMD: begin
                sio_out <= {3'b000, sid_sr[31]};
                sid_sr  <= {sid_sr[30:0], 1'b0};
                if (bit_cnt == 0) begin
                    bit_cnt <= 7'd15;
                    state   <= S_SID_RD;
                end else bit_cnt <= bit_cnt - 7'd1;
            end
            S_SID_RD: begin
                id_spi_sr <= {id_spi_sr[14:0], psram_sio1};
                if (bit_cnt == 0) state <= S_SID_CSH;
                else              bit_cnt <= bit_cnt - 7'd1;
            end
            S_SID_CSH: begin
                ce_n_r    <= 1'b1;
                spi_phase <= 1'b0;
                dbg_id    <= {16'b0, id_spi_sr};
                state     <= S_INIT_CSL;
            end
            S_INIT_CSL: begin
                ce_n_r    <= 1'b0;
                spi_phase <= 1'b1;
                sio_out   <= {3'b000, init_sr[7]};
                init_sr   <= {init_sr[6:0], 1'b0};
                bit_cnt   <= 7'd7;
                state     <= S_INIT_CMD;
            end
            S_INIT_CMD: begin
                sio_out <= {3'b000, init_sr[7]};
                init_sr <= {init_sr[6:0], 1'b0};
                if (bit_cnt == 0) state <= S_INIT_CSH;
                else              bit_cnt <= bit_cnt - 7'd1;
            end
            S_INIT_CSH: begin
                ce_n_r    <= 1'b1;
                spi_phase <= 1'b0;
                sio_out   <= 4'b0;
                state     <= S_IDLE;
            end

            S_IDLE: begin
                ce_n_r    <= 1'b1;
                qpi_drive <= 1'b0;
                if (req_sync[1] != req_serviced) begin
                    req_serviced <= req_sync[1];
                    is_read_lat  <= req_box[61];
                    is_byte_lat  <= req_box[60];
                    words_lat    <= req_box[59:56];
                    addr_sr      <= req_box[55:32];
                    /* byte write: MSnibble-first → byte in [31:24] */
                    data_sr      <= req_box[60] ? {req_box[7:0], 24'b0}
                                                : req_box[31:0];
                    sio_out      <= req_box[61] ? 4'hE : 4'h3;
                    ce_n_r       <= 1'b0;
                    qpi_drive    <= 1'b1;
                    bit_cnt      <= 7'd1;
                    con_cnt      <= 7'd0;
                    con_total    <= req_box[60] ? 7'd2 : {req_box[59:56], 3'b000};
                    state        <= S_CMD;
                end
            end

            S_CMD: begin
                if (bit_cnt == 0) begin
                    sio_out <= addr_sr[23:20];
                    addr_sr <= {addr_sr[19:0], 4'b0};
                    bit_cnt <= 7'd5;
                    state   <= S_ADDR;
                end else begin
                    sio_out <= is_read_lat ? 4'hB : 4'h8;
                    bit_cnt <= 7'd0;
                end
            end

            S_ADDR: begin
                if (bit_cnt == 0) begin
                    if (is_read_lat) begin
                        qpi_drive <= 1'b0;
                        /* 6 explicit dummies + the transition edge = the
                         * BOARD-CALIBRATED 7th-edge first sample (phase 1). */
                        bit_cnt   <= 7'd5;
                        state     <= S_DUMMY;
                    end else begin
                        sio_out <= data_sr[31:28];
                        data_sr <= {data_sr[27:0], 4'b0};
                        bit_cnt <= is_byte_lat ? 7'd1 : 7'd7;
                        state   <= S_WDATA;
                    end
                end else begin
                    sio_out <= addr_sr[23:20];
                    addr_sr <= {addr_sr[19:0], 4'b0};
                    bit_cnt <= bit_cnt - 7'd1;
                end
            end

            S_DUMMY: begin
                if (bit_cnt == 0) begin
                    bit_cnt <= is_byte_lat ? 7'd1 : ({words_lat, 3'b000} - 7'd1);
                    state   <= S_RDATA;
                end else begin
                    bit_cnt <= bit_cnt - 7'd1;
                end
            end

            S_RDATA: begin
                /* generation only — the consume path above does the
                 * sampling, possibly SKEW cycles later */
                if (bit_cnt == 0) state <= S_RDRAIN;
                else              bit_cnt <= bit_cnt - 7'd1;
            end

            S_RDRAIN: ;   /* completion is decided by the consume counter
                           * in the un-ticked block below */

            S_WDATA: begin
                if (bit_cnt == 0) state <= S_CSHIGH;
                else begin
                    sio_out <= data_sr[31:28];
                    data_sr <= {data_sr[27:0], 4'b0};
                    bit_cnt <= bit_cnt - 7'd1;
                end
            end

            S_CSHIGH: begin
                ce_n_r    <= 1'b1;
                qpi_drive <= 1'b0;
                ack_tog   <= ~ack_tog;
                state     <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
            end   /* tick */

            /* S_RDRAIN completes on the CONSUME counter, not on tick —
             * CE# stays low until the last delayed sample is in. */
            if (state == S_RDRAIN && con_cnt == con_total) begin
                ce_n_r    <= 1'b1;
                qpi_drive <= 1'b0;
                ack_tog   <= ~ack_tog;
                state     <= S_IDLE;
            end
        end
    end

endmodule
