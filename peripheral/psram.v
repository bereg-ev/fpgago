/*
 * psram.v — QPI master for AP Memory APS6404L-3SQN-SN (8 MB PSRAM).
 *
 * SINGLE-CLOCK version (no CDC).  The chip's protocol FSM runs on the same
 * `clk` as the rest of the SoC.  At 19.4 MHz that gives ~22 cycles per
 * 32-bit access in QPI = ~1.1 µs.
 *
 * A future revision will split this into a fast PSRAM-clock domain driven
 * by a PLL — that's where the 4× bandwidth from "PLL + QPI" actually
 * lives.  For now, prove correctness end-to-end at 1×.
 *
 * One-time power-up: enter QPI mode by clocking 0x35 out on SIO0 in
 * standard SPI mode.  After that, all reads (0xEB) and writes (0x38) are
 * 4-bit-wide QPI bursts.
 *
 * Per-transaction timing (clk cycles):
 *   QPI READ  (0xEB): 2 cmd + 6 addr + 6 dummy + 8 data = 22 cycles
 *   QPI WRITE (0x38): 2 cmd + 6 addr + 8 data            = 16 cycles
 *
 * SCK = ~clk while clocking, else 0.  Rising SCK lands on negedge clk;
 * master sets up SIO[3:0] on posedge clk, slave samples half a cycle
 * later, and master samples read data on posedge clk after the slave has
 * been driving since the previous negedge.  Standard SPI mode-0.
 */

/* One QPI bit-period = 2*CLKDIV clk cycles (SCLK = clk / (2*CLKDIV)).
 * CLKDIV=4 (4.8 MHz at the 38.75 MHz v2 clk) is board-proven; override per
 * build with -DPSRAM_CLKDIV=N.  ⚠ tCEM: the APS6404L allows CE# low for at
 * most 8 us, which couples burst length to SCLK — a burst of W words holds
 * CE# for ~(16 + 8*W) bit-periods:
 *   CLKDIV=4 (206 ns/bit): W<=2   CLKDIV=2 (103 ns/bit): W<=5
 *   CLKDIV=1 (52 ns/bit):  W<=8
 * Keep PSRAM_LINE_WORDS (mem_iface) inside these bounds. */
`ifndef PSRAM_CLKDIV
`define PSRAM_CLKDIV 4
`endif

module psram #(
    parameter CLKDIV = `PSRAM_CLKDIV
)(
    input  wire        clk,
    input  wire        rst,            /* active-low, async */

    input  wire [23:0] cmd_addr,
    input  wire        cmd_rd,
    input  wire        cmd_wr,
    /* cmd_byte=1: single-BYTE transfer (2 data nibbles instead of 8).
     * Read result lands in rdata[7:0]; write data is taken from
     * cmd_wdata[7:0].  cmd_byte=0: full 32-bit transfer (original).
     * Tie to 1'b0 where the 32-bit interface is wanted. */
    input  wire        cmd_byte,
    /* Number of 32-bit WORDS to read in one linear burst (1..8; 0 = 1).
     * Reads only — writes are always a single word/byte.  Each completed
     * word raises `word_rdy` for one clk with its index on `word_idx` and
     * the word in rdata[31:0]; `rdy` still pulses once at the end.  Tie to
     * 4'd1 for the classic single-word interface. */
    input  wire [3:0]  cmd_words,
    input  wire [31:0] cmd_wdata,
    output wire [31:0] rdata,
    output reg         rdy,            /* 1-cycle pulse on completion */
    output reg         word_rdy,       /* 1-cycle pulse per burst word */
    output reg  [2:0]  word_idx,       /* which word word_rdy refers to */
    output wire        busy,

    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3,

    /* ── Raw GPIO override (psram_test bring-up console) ─────────────────────
     * When raw_en=1 the QPI engine's pin drives are masked and the four data
     * pins + SCLK + CE# are driven straight from raw_*: SCLK/CE# always, and
     * SIO0..3 only when raw_oe=1 (else Hi-Z, so the chip can drive them back
     * for a software-bit-banged SPI read).  raw_sio_in continuously exposes
     * the live SIO0..3 input levels for reading MISO.  raw_en=0 → normal. */
    input  wire        raw_en,
    input  wire        raw_sclk,
    input  wire        raw_ce_n,
    input  wire        raw_oe,
    input  wire [3:0]  raw_sio,
    output wire [3:0]  raw_sio_in,

    output wire [3:0]  dbg_state,      /* current FSM state — bring-up watchdog */
    output reg  [31:0] dbg_id          /* QPI Read-ID (0x9F) result, latched after init */
);

reg ce_n_r;

/* ── States ─────────────────────────────────────────────────────────────── */
localparam S_INIT_CSL  = 4'd0;   /* CE# low for SPI 0x35 */
localparam S_INIT_CMD  = 4'd1;   /* shift 8 bits of 0x35 on SIO0 (SPI) */
localparam S_INIT_CSH  = 4'd2;   /* raise CE#, chip now in QPI */
localparam S_IDLE      = 4'd3;
localparam S_CMD       = 4'd4;   /* 2 nibbles (8 bits) of cmd */
localparam S_ADDR      = 4'd5;   /* 6 nibbles (24 bits) of address */
localparam S_DUMMY     = 4'd6;   /* read only: 6 dummy cycles */
localparam S_WDATA     = 4'd7;   /* 8 nibbles of write data */
localparam S_RDATA     = 4'd8;   /* 8 nibbles of read data */
localparam S_CSHIGH    = 4'd9;   /* CE# back high */
/* One-time Read-ID (0x9F) probe done right after init: cmd(2)+addr(6)+data(8),
 * no dummy.  Latches the 32-bit result into dbg_id for the bring-up test. */
localparam S_ID_START  = 4'd10;  /* CE# low, drive first cmd nibble */
localparam S_ID_CMD    = 4'd11;  /* 2 nibbles of 0x9F */
localparam S_ID_ADDR   = 4'd12;  /* 6 nibbles of addr (0) */
localparam S_ID_RDATA  = 4'd13;  /* 8 nibbles of ID data */
localparam S_ID_CSH    = 4'd14;  /* CE# high, latch dbg_id */
/* One-time SPI-mode Read-ID (0x9F) BEFORE entering QPI — bring-up: proves the
 * chip is alive and receiving commands (it powers up in SPI).  cmd(8b)+addr(24b)
 * out on SIO0, then read 16b (MFID,KGD) on SIO1; latched into dbg_id. */
localparam S_SID_CSL   = 5'd15;  /* CE# low, drive first cmd bit (SPI) */
localparam S_SID_CMD   = 5'd16;  /* shift 32 bits (0x9F + 24b addr) on SIO0 */
localparam S_SID_RD    = 5'd17;  /* read 16 bits on SIO1 (SO) */
localparam S_SID_CSH   = 5'd18;  /* CE# high, latch dbg_id, then enter QPI */

reg [4:0]  state;
reg [6:0]  bit_cnt;         /* up to 8 words = 64 data nibbles per burst */
reg [7:0]  init_sr;
reg [23:0] addr_sr;
reg [31:0] data_sr;
reg [31:0] rdata_sr;
reg [31:0] sid_sr;       /* SPI Read-ID: cmd+addr shift-out register */
reg [15:0] id_spi_sr;    /* SPI Read-ID: MFID/KGD shift-in register */
reg [31:0] id_sr;
reg        is_read_lat;
reg        is_byte_lat;
reg [3:0]  words_lat;
reg [2:0]  wcnt;            /* burst word counter for word_rdy/word_idx */

reg       spi_phase;
reg       qpi_drive;
reg [3:0] sio_out;

/* ── SIO pad drivers ────────────────────────────────────────────────────────
 * HARD RULE (yosys/ECP5): an inout pad MUST be driven by a SINGLE-level
 * `oe ? val : 1'bz`.  The original code nested ternaries with 1'bz in several
 * branches; yosys cannot infer a tristate from that and silently collapses it
 * into a push-pull LUT driver — the synthesized port degrades to `output`, the
 * pad never releases, and every read returns the FPGA's own drive instead of
 * the chip's.  That was the root cause of 17 failed bring-up runs (writes and
 * clocking were fine all along; only the read direction was dead).
 * Compute oe/drv as plain logic (no 'z), then tristate exactly once. */
wire [3:0] sio_oe;
wire [3:0] sio_drv;

/* SIO1 is MISO during 1-bit SPI (spi_phase) — never driven then. */
assign sio_oe[0] = raw_en ? raw_oe : (spi_phase | qpi_drive);
assign sio_oe[1] = raw_en ? raw_oe : (~spi_phase & qpi_drive);
assign sio_oe[2] = raw_en ? raw_oe : (spi_phase | qpi_drive);
assign sio_oe[3] = raw_en ? raw_oe : (spi_phase | qpi_drive);

/* SIO2/3 = WP#/HOLD#, held high during SPI so the chip stays enabled. */
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

wire sclk_active = (state == S_INIT_CMD) ||
                   (state == S_CMD)      ||
                   (state == S_ADDR)     ||
                   (state == S_DUMMY)    ||
                   (state == S_WDATA)    ||
                   (state == S_RDATA)    ||
                   (state == S_ID_CMD)   ||
                   (state == S_ID_ADDR)  ||
                   (state == S_ID_RDATA) ||
                   (state == S_SID_CMD)  ||
                   (state == S_SID_RD);

/* ── QPI clock divider ──────────────────────────────────────────────────────
 * Original design toggled SCLK at the full CPU clock (~38.4 MHz) and sampled
 * read data on the same clock — too fast for the board round-trip, so the chip
 * returned nothing.  Now one QPI bit = (2*CLKDIV) CPU cycles: SCLK is low for
 * the first CLKDIV cycles (master sets up SIO) and high for the last CLKDIV
 * (chip samples on the rising edge); the FSM advances and the master samples
 * read data at `tick` (end of the high phase, max settling for the round-trip).
 *   SCLK freq = CPU_clk / (2*CLKDIV).  At 38.4 MHz: CLKDIV=4 → 4.8 MHz.
 * Sweep this (2/4/8) to find the margin. */
reg  [4:0] div_cnt;
wire       tick = (div_cnt == (2*CLKDIV - 1));
assign psram_sclk = raw_en ? raw_sclk
                  : ((sclk_active && (div_cnt >= CLKDIV)) ? 1'b1 : 1'b0);

/* ── Command capture ────────────────────────────────────────────────────────
 * cmd_rd/cmd_wr are single-cycle pulses from the requester, but the FSM only
 * advances on `tick` (once per 2*CLKDIV clocks since the QPI clock divider) —
 * sampled directly in S_IDLE, 7 of 8 pulses would be silently dropped and the
 * requester would wait for a rdy that never comes.  Latch the command every
 * clk and let S_IDLE consume the latch at its own pace.  Latching stops the
 * moment the transaction starts (state leaves S_IDLE), so a requester that
 * holds cmd_* as a level can't double-fire; `busy` covers the latched-but-
 * not-yet-started window so requesters gate on it either way. */
reg        pend_rd, pend_wr, pend_byte;
reg [3:0]  pend_words;
reg [23:0] pend_addr;
reg [31:0] pend_wdata;

assign rdata = rdata_sr;
assign busy  = (state != S_IDLE) | pend_rd | pend_wr;
assign dbg_state = state[3:0];

/* Diagnostic counter — bumped every time CE# rises after a transaction. */
reg [31:0] xfer_count;

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state       <= S_SID_CSL;      /* SPI Read-ID probe first, then 0x35 */
        bit_cnt     <= 5'd0;
        init_sr     <= 8'h35;
        sid_sr      <= {8'h9F, 24'h0};  /* SPI Read-ID cmd + 24-bit addr */
        id_spi_sr   <= 16'b0;
        addr_sr     <= 24'b0;
        data_sr     <= 32'b0;
        rdata_sr    <= 32'b0;
        id_sr       <= 32'b0;
        dbg_id      <= 32'b0;
        is_read_lat <= 1'b0;
        is_byte_lat <= 1'b0;
        rdy         <= 1'b0;
        ce_n_r      <= 1'b1;
        spi_phase   <= 1'b0;
        qpi_drive   <= 1'b0;
        sio_out     <= 4'b0;
        xfer_count  <= 32'b0;
        div_cnt     <= 5'd0;
        pend_rd     <= 1'b0;
        pend_wr     <= 1'b0;
        pend_byte   <= 1'b0;
        pend_words  <= 4'd1;
        pend_addr   <= 24'b0;
        pend_wdata  <= 32'b0;
        words_lat   <= 4'd1;
        wcnt        <= 3'd0;
        word_rdy    <= 1'b0;
        word_idx    <= 3'd0;
    end else begin
        rdy      <= 1'b0;   /* default: rdy/word_rdy are 1-cycle pulses */
        word_rdy <= 1'b0;

        /* Capture a command any clk while idle (see note at pend_* decl). */
        if ((cmd_rd | cmd_wr) && state == S_IDLE) begin
            pend_rd    <= cmd_rd;
            pend_wr    <= cmd_wr;
            pend_byte  <= cmd_byte;
            pend_words <= (cmd_words == 4'd0) ? 4'd1 : cmd_words;
            pend_addr  <= cmd_addr;
            pend_wdata <= cmd_wdata;
        end

        /* QPI bit-period divider: advance the FSM (and sample reads) only on
         * `tick` (end of the SCLK-high phase). */
        if (tick) div_cnt <= 5'd0;
        else      div_cnt <= div_cnt + 5'd1;

        if (tick) begin
        case (state)
        /* ── SPI-mode Read-ID (0x9F) — runs first, before entering QPI ─────── */
        S_SID_CSL: begin
            ce_n_r     <= 1'b0;
            spi_phase  <= 1'b1;            /* SPI: drive SIO0, SIO1=input, WP/HOLD high */
            sio_out    <= {3'b000, sid_sr[31]};
            sid_sr     <= {sid_sr[30:0], 1'b0};
            bit_cnt    <= 5'd31;
            state      <= S_SID_CMD;
        end

        S_SID_CMD: begin                  /* shift out 32 bits (0x9F + 24-bit addr) */
            sio_out <= {3'b000, sid_sr[31]};
            sid_sr  <= {sid_sr[30:0], 1'b0};
            if (bit_cnt == 0) begin
                bit_cnt <= 5'd15;         /* then read 16 bits (MFID, KGD) */
                state   <= S_SID_RD;
            end else bit_cnt <= bit_cnt - 5'd1;
        end

        S_SID_RD: begin                   /* sample SO on SIO1, MSB first */
            id_spi_sr <= {id_spi_sr[14:0], psram_sio1};
            if (bit_cnt == 0) state <= S_SID_CSH;
            else              bit_cnt <= bit_cnt - 5'd1;
        end

        S_SID_CSH: begin
            ce_n_r     <= 1'b1;
            spi_phase  <= 1'b0;
            dbg_id     <= {16'b0, id_spi_sr};   /* report SPI Read-ID in dbg_id */
            state      <= S_INIT_CSL;           /* now send 0x35 to enter QPI */
        end

        S_INIT_CSL: begin
            ce_n_r     <= 1'b0;
            spi_phase  <= 1'b1;
            sio_out    <= {3'b000, init_sr[7]};
            init_sr    <= {init_sr[6:0], 1'b0};
            bit_cnt    <= 5'd7;
            state      <= S_INIT_CMD;
        end

        S_INIT_CMD: begin
            sio_out <= {3'b000, init_sr[7]};
            init_sr <= {init_sr[6:0], 1'b0};
            if (bit_cnt == 0) state <= S_INIT_CSH;
            else              bit_cnt <= bit_cnt - 5'd1;
        end

        S_INIT_CSH: begin
            ce_n_r     <= 1'b1;        /* commit enter-QPI (0x35) */
            spi_phase  <= 1'b0;
            sio_out    <= 4'b0;
            state      <= S_IDLE;      /* SPI Read-ID already ran; QPI probe skipped */
        end

        /* ── One-time QPI Read-ID (0x9F) — bring-up diagnostic ─────────────── */
        S_ID_START: begin
            ce_n_r     <= 1'b0;
            qpi_drive  <= 1'b1;
            sio_out    <= 4'h9;        /* first cmd nibble of 0x9F */
            bit_cnt    <= 5'd1;
            state      <= S_ID_CMD;
        end

        S_ID_CMD: begin
            if (bit_cnt == 0) begin
                sio_out <= 4'h0;       /* first addr nibble (addr = 0) */
                bit_cnt <= 5'd5;
                state   <= S_ID_ADDR;
            end else begin
                sio_out <= 4'hF;       /* second cmd nibble */
                bit_cnt <= 5'd0;
            end
        end

        S_ID_ADDR: begin
            if (bit_cnt == 0) begin
                qpi_drive <= 1'b0;     /* release bus; chip drives ID (no dummy) */
                bit_cnt   <= 5'd7;
                state     <= S_ID_RDATA;
            end else begin
                sio_out <= 4'h0;
                bit_cnt <= bit_cnt - 5'd1;
            end
        end

        S_ID_RDATA: begin
            id_sr <= {id_sr[27:0], sio_in};
            if (bit_cnt == 0) state <= S_ID_CSH;
            else              bit_cnt <= bit_cnt - 5'd1;
        end

        S_ID_CSH: begin
            ce_n_r     <= 1'b1;
            qpi_drive  <= 1'b0;
            dbg_id     <= id_sr;
            state      <= S_IDLE;
        end

        S_IDLE: begin
            ce_n_r     <= 1'b1;
            qpi_drive  <= 1'b0;
            if (pend_rd | pend_wr) begin
                addr_sr     <= pend_addr;
                /* Byte write: the QPI write burst is MSnibble-first, so the
                 * single byte must sit in [31:24] to go out in the first two
                 * data nibbles before CE# is raised. */
                data_sr     <= pend_byte ? {pend_wdata[7:0], 24'b0} : pend_wdata;
                is_read_lat <= pend_rd;
                is_byte_lat <= pend_byte;
                words_lat   <= pend_words;
                wcnt        <= 3'd0;
                sio_out     <= pend_rd ? 4'hE : 4'h3;
                ce_n_r      <= 1'b0;
                qpi_drive   <= 1'b1;
                bit_cnt     <= 7'd1;
                state       <= S_CMD;
                pend_rd     <= 1'b0;
                pend_wr     <= 1'b0;
            end
        end

        S_CMD: begin
            if (bit_cnt == 0) begin
                sio_out <= addr_sr[23:20];
                addr_sr <= {addr_sr[19:0], 4'b0};
                bit_cnt <= 5'd5;
                state   <= S_ADDR;
            end else begin
                sio_out <= is_read_lat ? 4'hB : 4'h8;
                bit_cnt <= 5'd0;
            end
        end

        S_ADDR: begin
            if (bit_cnt == 0) begin
                if (is_read_lat) begin
                    qpi_drive <= 1'b0;
                    /* Wait 6 cycles in S_DUMMY (bit_cnt 5..0).  BOARD-
                     * CALIBRATED 2026-07-29: with 5 the readback came back
                     * shifted one nibble right (garbage first sample, last
                     * nibble lost) — the APS6404L drives its first data
                     * nibble on the falling edge AFTER wait cycle 6, so the
                     * first valid sample is the 7th SCK edge past the last
                     * address nibble: 6 explicit dummies + the S_ADDR
                     * transition edge.  psram_model.v is calibrated to the
                     * same measured behaviour. */
                    bit_cnt   <= 5'd5;
                    state     <= S_DUMMY;
                end else begin
                    sio_out <= data_sr[31:28];
                    data_sr <= {data_sr[27:0], 4'b0};
                    bit_cnt <= is_byte_lat ? 5'd1 : 5'd7;
                    state   <= S_WDATA;
                end
            end else begin
                sio_out <= addr_sr[23:20];
                addr_sr <= {addr_sr[19:0], 4'b0};
                bit_cnt <= bit_cnt - 5'd1;
            end
        end

        S_DUMMY: begin
            if (bit_cnt == 0) begin
                /* words_lat*8 data nibbles for a word burst (linear burst:
                 * the chip streams sequential bytes as long as CE# stays
                 * low — mind the tCEM table at the top). */
                bit_cnt <= is_byte_lat ? 7'd1 : ({words_lat, 3'b000} - 7'd1);
                state   <= S_RDATA;
            end else begin
                bit_cnt <= bit_cnt - 7'd1;
            end
        end

        S_RDATA: begin
            rdata_sr <= {rdata_sr[27:0], sio_in};
            /* Every 8th nibble completes a word: pulse word_rdy with its
             * index (the requester samples rdata next clk, when the shift
             * above has settled).  Fires for the final word too, one
             * bit-period before the completion rdy. */
            if (!is_byte_lat && bit_cnt[2:0] == 3'b000) begin
                word_rdy <= 1'b1;
                word_idx <= wcnt;
                wcnt     <= wcnt + 3'd1;
            end
            if (bit_cnt == 0) state <= S_CSHIGH;
            else              bit_cnt <= bit_cnt - 7'd1;
        end

        S_WDATA: begin
            if (bit_cnt == 0) state <= S_CSHIGH;
            else begin
                sio_out <= data_sr[31:28];
                data_sr <= {data_sr[27:0], 4'b0};
                bit_cnt <= bit_cnt - 5'd1;
            end
        end

        S_CSHIGH: begin
            ce_n_r     <= 1'b1;
            qpi_drive  <= 1'b0;
            rdy        <= 1'b1;
            xfer_count <= xfer_count + 32'd1;
            state      <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
        end   /* if (tick) */
    end
end

endmodule
