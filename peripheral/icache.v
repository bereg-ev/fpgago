/*
 * icache.v — Direct-mapped instruction cache + data cache for RISC2 + X SDRAM
 *
 * Instruction cache:
 *   Geometry : 256 lines × 4 words = 1 024 instructions = 4 KB
 *   Line size: 16 bytes = 4 × 32-bit words = 8 × 16-bit SDRAM halfwords
 *   BRAMs    : 3 × ram_1k_18  (tag, data-lo, data-hi)
 *
 * Data cache (shares SDRAM controller with instruction cache):
 *   Geometry : 256 lines × 4 words = 4 KB  (same as icache)
 *   Line size: 16 bytes
 *   BRAMs    : 3 × ram_1k_18  (dtag, ddata-lo, ddata-hi)
 *   Policy   : read-allocate, write-through with invalidation
 *
 * Address breakdown (cpu_addr / data_addr [23:0], byte-addressed):
 *   [23:12]  tag        (12 bits)
 *   [11:4]   line index (8 bits  → 256 lines)
 *   [3:2]    word       (2 bits  → 4 words per line)
 *   [1:0]    byte       (always 0 for 32-bit access)
 *
 * SDRAM mapping (same for both caches):
 *   row  = { addr[21:9], addr[23:22] }   (row + bank)
 *   col  = { addr[8:4], 3'b000 }         (8-hword aligned)
 *   stop = col + 7                        (8 halfwords = 4 words = 1 line)
 *
 * ROM bypass: addr[23:12] == 0 served directly from rom_data, no cache.
 */

module icache(
    input  wire        clk,
    input  wire        rst,

    /* CPU instruction port */
    input  wire [23:0] cpu_addr,
    output reg  [31:0] cpu_instr,
    output wire        cpu_valid,

    /* ROM bypass */
    input  wire [31:0] rom_data,

    /* Code upload write port (existing) */
    input  wire [23:0] wr_addr,
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    output wire        wr_busy,

    /* CPU data port — cached read/write access to X SDRAM */
    input  wire [23:0] data_addr,
    input  wire        data_rd,         /* 1-cycle pulse: CPU load from SDRAM */
    input  wire [31:0] data_wr_val,     /* store data */
    input  wire [3:0]  data_wr_strobe,  /* byte-lane enables */
    input  wire        data_wr_en,      /* 1-cycle pulse: CPU store to SDRAM */
    output wire [31:0] data_out,        /* read result */
    output wire        data_valid,      /* read data ready */
    output wire        data_wr_busy,    /* write buffer full */

    /* X SDRAM physical bus */
    output wire        sd_clk,
    output wire        sd_cke,
    output wire        sd_cs,
    output wire        sd_ras,
    output wire        sd_cas,
    output wire        sd_we,
    output wire [12:0] sd_a,
    inout  wire [15:0] sd_d,
    output wire [ 1:0] sd_ba,
    output wire        sd_ldqm,
    output wire        sd_udqm,
    output wire [ 7:0] dbg
);

assign sd_clk = clk;

/* ── SDRAM instance (shared by both caches) ──────────────────────────────── */
wire [15:0] sd_bram_di;
wire        sd_bram_we;
wire        sd_rdy;

reg  [14:0] sd_r_row;
reg  [ 9:0] sd_r_col, sd_r_stop;
reg         sd_start_read, sd_start_init;

reg  [14:0] sd_w_row;
reg  [ 9:0] sd_w_col, sd_w_stop;
reg         sd_start_write;
reg         sd_fill_en;
reg  [15:0] sd_fill_const;

sdram sdram_x(
    .clk(clk),              .rst(rst),
    .r_row(sd_r_row),       .w_row(sd_w_row),
    .bram_di(sd_bram_di),   .bram_do(16'b0),   .bram_we(sd_bram_we),
    .start_read(sd_start_read), .start_write(sd_start_write),
    .start_init(sd_start_init),
    .rdy(sd_rdy),
    .w_addr(),              .r_addr(),
    .w_stop(sd_w_stop),     .w_col(sd_w_col),
    .w_addr_start(10'b0),
    .r_col(sd_r_col),       .r_stop(sd_r_stop),
    .fill_en(sd_fill_en),   .fill_const(sd_fill_const),
    .sd_cke(sd_cke),        .sd_cs(sd_cs),
    .sd_ras(sd_ras),        .sd_cas(sd_cas),   .sd_we(sd_we),
    .sd_a(sd_a),            .sd_d(sd_d),       .sd_ba(sd_ba),
    .sd_ldqm(sd_ldqm),      .sd_udqm(sd_udqm),
    .dbg(dbg),
    .write_pending()
);

/* ══════════════════════════════════════════════════════════════════════════
 * INSTRUCTION CACHE BRAMs
 * ══════════════════════════════════════════════════════════════════════════ */

reg         tag_wr_en;
reg  [ 7:0] tag_wr_addr;
reg  [12:0] tag_wr_data;
wire [17:0] tag_rd_raw;

ram_1k_18 tag_bram(
    .clk_a(clk), .we_a(tag_wr_en),
    .addr_a({2'b0, tag_wr_addr}), .din_a({5'b0, tag_wr_data}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({2'b0, cpu_addr[11:4]}), .din_b(18'b0), .dout_b(tag_rd_raw)
);

reg         dat_wr_en;
reg  [ 9:0] dat_wr_addr;
reg  [15:0] dat_wr_lo, dat_wr_hi;
wire [17:0] dat_rd_lo_raw, dat_rd_hi_raw;

ram_1k_18 data_bram_lo(
    .clk_a(clk), .we_a(dat_wr_en),
    .addr_a(dat_wr_addr), .din_a({2'b0, dat_wr_lo}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({cpu_addr[11:4], cpu_addr[3:2]}), .din_b(18'b0), .dout_b(dat_rd_lo_raw)
);

ram_1k_18 data_bram_hi(
    .clk_a(clk), .we_a(dat_wr_en),
    .addr_a(dat_wr_addr), .din_a({2'b0, dat_wr_hi}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({cpu_addr[11:4], cpu_addr[3:2]}), .din_b(18'b0), .dout_b(dat_rd_hi_raw)
);

wire [15:0] dat_rd_lo = dat_rd_lo_raw[15:0];
wire [15:0] dat_rd_hi = dat_rd_hi_raw[15:0];
wire [12:0] tag_rd    = tag_rd_raw[12:0];

/* ── Instruction cache hit detection ─────────────────────────────────────── */
reg [23:0] prev_addr;
always @(posedge clk or negedge rst)
    if (!rst) prev_addr <= 24'hfffffc;
    else      prev_addr <= cpu_addr;

`ifdef SIMULATION
wire is_rom = (prev_addr[23:15] == 9'b0);
`elsif EXTENDED_MEM
wire is_rom = (prev_addr[23:14] == 10'b0);
`else
wire is_rom = (prev_addr[23:12] == 12'b0);
`endif
wire is_hit = tag_rd[12] && (tag_rd[11:0] == prev_addr[23:12]);

/* ══════════════════════════════════════════════════════════════════════════
 * DATA CACHE BRAMs
 * ══════════════════════════════════════════════════════════════════════════ */

reg         dtag_wr_en;
reg  [ 7:0] dtag_wr_addr;
reg  [12:0] dtag_wr_data;
wire [17:0] dtag_rd_raw;

ram_1k_18 dtag_bram(
    .clk_a(clk), .we_a(dtag_wr_en),
    .addr_a({2'b0, dtag_wr_addr}), .din_a({5'b0, dtag_wr_data}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({2'b0, data_addr[11:4]}), .din_b(18'b0), .dout_b(dtag_rd_raw)
);

reg         ddat_wr_en;
reg  [ 9:0] ddat_wr_addr;
reg  [15:0] ddat_wr_lo, ddat_wr_hi;
wire [17:0] ddat_rd_lo_raw, ddat_rd_hi_raw;

ram_1k_18 ddata_bram_lo(
    .clk_a(clk), .we_a(ddat_wr_en),
    .addr_a(ddat_wr_addr), .din_a({2'b0, ddat_wr_lo}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({data_addr[11:4], data_addr[3:2]}), .din_b(18'b0), .dout_b(ddat_rd_lo_raw)
);

ram_1k_18 ddata_bram_hi(
    .clk_a(clk), .we_a(ddat_wr_en),
    .addr_a(ddat_wr_addr), .din_a({2'b0, ddat_wr_hi}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b({data_addr[11:4], data_addr[3:2]}), .din_b(18'b0), .dout_b(ddat_rd_hi_raw)
);

wire [15:0] ddat_rd_lo = ddat_rd_lo_raw[15:0];
wire [15:0] ddat_rd_hi = ddat_rd_hi_raw[15:0];
wire [12:0] dtag_rd    = dtag_rd_raw[12:0];

/* ── Data cache hit detection ────────────────────────────────────────────── */
reg [23:0] prev_data_addr;
always @(posedge clk or negedge rst)
    if (!rst) prev_data_addr <= 24'h0;
    else      prev_data_addr <= data_addr;

wire d_is_hit = dtag_rd[12] && (dtag_rd[11:0] == prev_data_addr[23:12]);

/* Track whether a data read is pending (set on data_rd pulse, cleared on hit/fill) */
reg d_read_pending;
always @(posedge clk or negedge rst)
    if (!rst) d_read_pending <= 0;
    else begin
        if (data_rd) d_read_pending <= 1;
        else if (d_is_hit || fstate == FS_DREAD_TAG) d_read_pending <= 0;
    end

/* ── Data write buffer (edge-detected to prevent re-latch when CPU frozen) ─ */
reg        wr_data_pending;
reg [23:0] dwr_addr_reg;
reg [31:0] dwr_data_reg;
reg        data_wr_en_prev;

always @(posedge clk or negedge rst)
    if (!rst) begin
        wr_data_pending <= 0;
        dwr_addr_reg <= 0;
        dwr_data_reg <= 0;
        data_wr_en_prev <= 0;
    end else begin
        data_wr_en_prev <= data_wr_en;
        /* Latch on rising edge of data_wr_en only */
        if (data_wr_en && !data_wr_en_prev && !wr_data_pending) begin
            wr_data_pending <= 1;
            dwr_addr_reg <= data_addr;
            dwr_data_reg <= data_wr_val;
        end
        if (dwr_pickup) wr_data_pending <= 0;
    end

reg dwr_pickup;
assign data_wr_busy = wr_data_pending;


/* ══════════════════════════════════════════════════════════════════════════
 * STATE MACHINE (unified for instruction cache, data cache, and writes)
 * ══════════════════════════════════════════════════════════════════════════ */

localparam FS_IDLE        = 4'd0;
localparam FS_WAIT        = 4'd1;   /* icache miss: wait for SDRAM rdy    */
localparam FS_BURST       = 4'd2;   /* icache miss: receive 8 halfwords   */
localparam FS_TAG         = 4'd3;   /* icache miss: write tag, output     */
localparam FS_WRITE_HI    = 4'd4;   /* write: high halfword to SDRAM      */
localparam FS_WRITE_LO    = 4'd5;   /* write: low halfword to SDRAM       */
localparam FS_WRITE_DONE  = 4'd6;   /* write: wait for completion         */
localparam FS_DREAD_WAIT  = 4'd7;   /* dcache miss: wait for SDRAM rdy    */
localparam FS_DREAD_BURST = 4'd8;   /* dcache miss: receive 8 halfwords   */
localparam FS_DREAD_TAG   = 4'd9;   /* dcache miss: write tag, output     */

reg [3:0]  fstate;
reg [23:0] fill_addr;
reg [ 3:0] fill_cnt;
reg [15:0] fill_hi_buf;
reg [31:0] fill_words [0:3];
reg        init_sent;
reg        fill_is_data;   /* 1 = filling data cache, 0 = filling icache */

reg [23:0] wr_addr_reg;
reg [31:0] wr_data_reg;

assign wr_busy = (fstate == FS_WRITE_HI) ||
                 (fstate == FS_WRITE_LO) ||
                 (fstate == FS_WRITE_DONE);

always @(posedge clk or negedge rst)
if (!rst) begin
    fstate        <= FS_IDLE;
    fill_addr     <= 24'b0;
    fill_cnt      <= 4'b0;
    fill_hi_buf   <= 16'b0;
    fill_words[0] <= 32'b0;
    fill_words[1] <= 32'b0;
    fill_words[2] <= 32'b0;
    fill_words[3] <= 32'b0;
    sd_r_row      <= 15'b0;
    sd_r_col      <= 10'b0;
    sd_r_stop     <= 10'b0;
    sd_start_read <= 1'b0;
    sd_start_init <= 1'b0;
    init_sent     <= 1'b0;
    wr_addr_reg   <= 24'b0;
    wr_data_reg   <= 32'b0;
    sd_w_row      <= 15'b0;
    sd_w_col      <= 10'b0;
    sd_w_stop     <= 10'b0;
    sd_start_write<= 1'b0;
    sd_fill_en    <= 1'b0;
    sd_fill_const <= 16'b0;
    fill_is_data  <= 1'b0;
    dwr_pickup    <= 1'b0;
end else begin
    dwr_pickup <= 1'b0;   /* default: one-shot */

    if (!init_sent) begin
        sd_start_init <= ~sd_start_init;
        init_sent     <= 1'b1;
    end

    case (fstate)
        /* ── Idle: priority check ────────────────────────────────────────── */
        FS_IDLE: begin
            if (wr_en) begin
                /* Code upload write (existing, highest priority) */
                wr_addr_reg <= wr_addr;
                wr_data_reg <= wr_data;
                fstate      <= FS_WRITE_HI;
            end else if (wr_data_pending) begin
                /* Data store: write-through to SDRAM + invalidate cache */
                wr_addr_reg <= dwr_addr_reg;
                wr_data_reg <= dwr_data_reg;
                dwr_pickup  <= 1'b1;
                fstate      <= FS_WRITE_HI;
                /* Cache line invalidation handled in combinational block */
            end else if (d_read_pending && !d_is_hit) begin
                /* Data cache miss */
                fill_addr    <= prev_data_addr;
                fill_is_data <= 1'b1;
                fstate       <= FS_DREAD_WAIT;
            end else if (!is_rom && !is_hit) begin
                /* Instruction cache miss (existing) */
                fill_addr    <= prev_addr;
                fill_is_data <= 1'b0;
                fstate       <= FS_WAIT;
            end
        end

        /* ══ INSTRUCTION CACHE MISS ═══════════════════════════════════════ */
        FS_WAIT: begin
            if (sd_rdy) begin
                sd_r_row      <= {fill_addr[21:9], fill_addr[23:22]};
                sd_r_col      <= {fill_addr[8:4], 3'b000};
                sd_r_stop     <= {fill_addr[8:4], 3'b000} + 10'd7;
                sd_start_read <= ~sd_start_read;
                fill_cnt      <= 4'b0;
                fstate        <= FS_BURST;
            end
        end

        FS_BURST: begin
            if (sd_bram_we) begin
                if (!fill_cnt[0])
                    fill_hi_buf <= sd_bram_di;
                else
                    fill_words[fill_cnt[2:1]] <= {fill_hi_buf, sd_bram_di};
                fill_cnt <= fill_cnt + 4'b1;
                if (fill_cnt == 4'd7)
                    fstate <= FS_TAG;
            end
        end

        FS_TAG: begin
            fstate <= FS_IDLE;
        end

        /* ══ DATA CACHE MISS ══════════════════════════════════════════════ */
        FS_DREAD_WAIT: begin
            if (sd_rdy) begin
                sd_r_row      <= {fill_addr[21:9], fill_addr[23:22]};
                sd_r_col      <= {fill_addr[8:4], 3'b000};
                sd_r_stop     <= {fill_addr[8:4], 3'b000} + 10'd7;
                sd_start_read <= ~sd_start_read;
                fill_cnt      <= 4'b0;
                fstate        <= FS_DREAD_BURST;
            end
        end

        FS_DREAD_BURST: begin
            if (sd_bram_we) begin
                if (!fill_cnt[0])
                    fill_hi_buf <= sd_bram_di;
                else
                    fill_words[fill_cnt[2:1]] <= {fill_hi_buf, sd_bram_di};
                fill_cnt <= fill_cnt + 4'b1;
                if (fill_cnt == 4'd7)
                    fstate <= FS_DREAD_TAG;
            end
        end

        FS_DREAD_TAG: begin
            fstate <= FS_IDLE;
        end

        /* ══ WRITE PATH (shared: code upload + data store) ════════════════ */
        FS_WRITE_HI: begin
            if (sd_rdy) begin
                sd_w_row      <= {wr_addr_reg[21:9], wr_addr_reg[23:22]};
                sd_w_col      <= {1'b0, wr_addr_reg[8:1]};
                sd_w_stop     <= 10'd0;
                sd_fill_en    <= 1'b1;
                sd_fill_const <= wr_data_reg[31:16];
                sd_start_write<= ~sd_start_write;
                fstate        <= FS_WRITE_LO;
            end
        end

        FS_WRITE_LO: begin
            if (sd_rdy) begin
                sd_w_col      <= {1'b0, wr_addr_reg[8:1]} + 10'd1;
                sd_fill_const <= wr_data_reg[15:0];
                sd_start_write<= ~sd_start_write;
                fstate        <= FS_WRITE_DONE;
            end
        end

        FS_WRITE_DONE: begin
            if (sd_rdy) begin
                sd_fill_en <= 1'b0;
                fstate     <= FS_IDLE;
            end
        end
    endcase
end

/* ── Combinational BRAM write signals: instruction cache ─────────────────── */
always @(*) begin
    dat_wr_en   = 1'b0;
    dat_wr_addr = 10'b0;
    dat_wr_lo   = 16'b0;
    dat_wr_hi   = 16'b0;
    tag_wr_en   = 1'b0;
    tag_wr_addr = 8'b0;
    tag_wr_data = 13'b0;

    if (fstate == FS_BURST && sd_bram_we && fill_cnt[0]) begin
        dat_wr_en   = 1'b1;
        dat_wr_addr = {fill_addr[11:4], fill_cnt[2:1]};
        dat_wr_hi   = fill_hi_buf;
        dat_wr_lo   = sd_bram_di;
    end

    if (fstate == FS_TAG) begin
        tag_wr_en   = 1'b1;
        tag_wr_addr = fill_addr[11:4];
        tag_wr_data = {1'b1, fill_addr[23:12]};
    end
end

/* ── Combinational BRAM write signals: data cache ────────────────────────── */
always @(*) begin
    ddat_wr_en   = 1'b0;
    ddat_wr_addr = 10'b0;
    ddat_wr_lo   = 16'b0;
    ddat_wr_hi   = 16'b0;
    dtag_wr_en   = 1'b0;
    dtag_wr_addr = 8'b0;
    dtag_wr_data = 13'b0;

    /* Fill data cache line during burst */
    if (fstate == FS_DREAD_BURST && sd_bram_we && fill_cnt[0]) begin
        ddat_wr_en   = 1'b1;
        ddat_wr_addr = {fill_addr[11:4], fill_cnt[2:1]};
        ddat_wr_hi   = fill_hi_buf;
        ddat_wr_lo   = sd_bram_di;
    end

    /* Write data cache tag on fill completion */
    if (fstate == FS_DREAD_TAG) begin
        dtag_wr_en   = 1'b1;
        dtag_wr_addr = fill_addr[11:4];
        dtag_wr_data = {1'b1, fill_addr[23:12]};
    end

    /* Invalidate data cache line on data store (clear valid bit) */
    if (fstate == FS_IDLE && wr_data_pending) begin
        dtag_wr_en   = 1'b1;
        dtag_wr_addr = dwr_addr_reg[11:4];
        dtag_wr_data = 13'b0;   /* valid=0 */
    end
end

/* ── Instruction cache output mux ────────────────────────────────────────── */
assign cpu_valid = is_rom || is_hit || (fstate == FS_TAG);

always @(*) begin
    if (is_rom)
        cpu_instr = rom_data;
    else if (fstate == FS_TAG)
        cpu_instr = fill_words[fill_addr[3:2]];
    else
        cpu_instr = {dat_rd_hi, dat_rd_lo};
end

/* ── Data cache output mux ───────────────────────────────────────────────── */
assign data_valid = (d_read_pending && d_is_hit) || (fstate == FS_DREAD_TAG);

assign data_out = (fstate == FS_DREAD_TAG) ?
    fill_words[fill_addr[3:2]] : {ddat_rd_hi, ddat_rd_lo};

endmodule
