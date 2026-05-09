/*
 * psram_iface.v — Drop-in replacement for icache.v in HW=v2 builds.
 *
 * Exposes the *exact same* CPU-side ports as peripheral/icache.v so soc.v can
 * `ifdef HW_V2` swap one module for the other without touching anything else.
 * Internally it talks to peripheral/psram.v (a tiny SPI master) and serves:
 *
 *   - CPU instruction fetches  (cpu_addr / cpu_instr / cpu_valid)
 *       ROM range (addr[23:15]==0): served directly from rom_data, 1 cycle.
 *       Otherwise: PSRAM read.  A 1-word "last fetch" register avoids
 *       re-issuing PSRAM reads for the very common case of staying on the
 *       same word for two cycles.
 *
 *   - CPU data loads/stores  (data_addr, data_rd, data_wr_*, data_out, ...)
 *       Loads have the same 1-word last-read cache.
 *       Stores: full-word stores (strobe == 4'b1111) go straight to PSRAM.
 *               Sub-word stores do a read-modify-write at this layer.
 *
 *   - Code upload writes  (wr_addr, wr_data, wr_en, wr_busy)
 *       Same priority ordering as icache.v.
 *
 * Arbitration priority inside the FSM (highest first):
 *   1. code upload (wr_en)
 *   2. CPU store   (data_wr_pending)
 *   3. CPU load    (data_rd_pending && !data_hit)
 *   4. CPU fetch   (!is_rom_i && !inst_hit)
 *
 * Cache strategy: deliberately the simplest thing that's not painfully slow.
 * One-word read cache per port; writes invalidate matching tags; nothing else.
 */

module psram_iface(
    input  wire        clk,
    input  wire        rst,

    /* CPU instruction port */
    input  wire [23:0] cpu_addr,
    output reg  [31:0] cpu_instr,
    output wire        cpu_valid,

    /* ROM bypass */
    input  wire [31:0] rom_data,

    /* Code upload write port */
    input  wire [23:0] wr_addr,
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    output wire        wr_busy,

    /* CPU data port */
    input  wire [23:0] data_addr,
    input  wire        data_rd,
    input  wire [31:0] data_wr_val,
    input  wire [3:0]  data_wr_strobe,
    input  wire        data_wr_en,
    output wire [31:0] data_out,
    output wire        data_valid,
    output wire        data_wr_busy,

    /* PSRAM pins */
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3,

    output wire [ 7:0] dbg
);

/* ══════════════════════════════════════════════════════════════════════════
 * 1-word read caches
 * ════════════════════════════════════════════════════════════════════════ */
reg [23:0] inst_cache_addr;
reg [31:0] inst_cache_data;
reg        inst_cache_valid;

reg [23:0] data_cache_addr;
reg [31:0] data_cache_data;
reg        data_cache_valid;

/* Word-aligned addresses (low 2 bits ignored). */
wire [23:0] cpu_word_addr  = {cpu_addr[23:2],  2'b00};
wire [23:0] data_word_addr = {data_addr[23:2], 2'b00};

/* prev_addr — instr_addr from one clock ago.  rom_data is the BRAM ROM's
 * read for the address sampled at the previous posedge, so the ROM-bypass
 * `is_rom` check has to use prev_addr, otherwise we would announce
 * "instruction valid" the cycle BEFORE rom_data has the right word. */
reg [23:0] prev_addr;
always @(posedge clk or negedge rst) begin
    if (!rst) prev_addr <= 24'hfffffc;
    else      prev_addr <= cpu_addr;
end

/* ROM range: 0x000000 .. 0x007FFF served directly from rom_data. */
`ifdef SIMULATION
wire is_rom_i = (prev_addr[23:15] == 9'b0);
`elsif EXTENDED_MEM
wire is_rom_i = (prev_addr[23:15] == 9'b0);
`else
wire is_rom_i = (prev_addr[23:12] == 12'b0);
`endif

/* Hit logic — caches are simple registers, no read latency; check current addr. */
wire inst_hit = inst_cache_valid && (inst_cache_addr == cpu_word_addr);
wire data_hit = data_cache_valid && (data_cache_addr == data_word_addr);

/* ══════════════════════════════════════════════════════════════════════════
 * Pending request latches (one per kind of request)
 * ════════════════════════════════════════════════════════════════════════ */
reg        data_rd_pending;
reg [23:0] data_rd_addr_lat;

reg        data_wr_pending;
reg [23:0] data_wr_addr_lat;
reg [31:0] data_wr_val_lat;
reg [3:0]  data_wr_strobe_lat;

reg        upload_pending;
reg [23:0] upload_addr_lat;
reg [31:0] upload_data_lat;

/* ══════════════════════════════════════════════════════════════════════════
 * PSRAM controller instance
 * ════════════════════════════════════════════════════════════════════════ */
reg  [23:0] ps_addr;
reg         ps_rd;
reg         ps_wr;
reg  [31:0] ps_wdata;
wire [31:0] ps_rdata;
wire        ps_rdy;
wire        ps_busy;

psram psram0(
    .clk(clk),
    .rst(rst),
    .cmd_addr(ps_addr),
    .cmd_rd(ps_rd), .cmd_wr(ps_wr),
    .cmd_wdata(ps_wdata),
    .rdata(ps_rdata),
    .rdy(ps_rdy),
    .busy(ps_busy),
    .psram_sclk(psram_sclk),
    .psram_ce_n(psram_ce_n),
    .psram_sio0(psram_sio0),
    .psram_sio1(psram_sio1),
    .psram_sio2(psram_sio2),
    .psram_sio3(psram_sio3)
);

/* ══════════════════════════════════════════════════════════════════════════
 * Outputs visible to the CPU — combinational, matching icache.v's shape.
 * ════════════════════════════════════════════════════════════════════════ */
assign cpu_valid = is_rom_i || inst_hit;

reg [31:0] cpu_instr_comb;
always @(*) begin
    if (is_rom_i)        cpu_instr_comb = rom_data;
    else if (inst_hit)   cpu_instr_comb = inst_cache_data;
    else                 cpu_instr_comb = 32'b0;
end
/* The module declares cpu_instr as `output reg [31:0]`.  Drive it from the
 * combinational result so the existing port direction stays unchanged. */
always @(*) cpu_instr = cpu_instr_comb;

reg data_valid_r;
assign data_valid = data_valid_r;
assign data_out   = data_cache_data;

assign data_wr_busy = data_wr_pending;
assign wr_busy      = upload_pending;

assign dbg = {3'b0, ps_busy, state};

/* ══════════════════════════════════════════════════════════════════════════
 * Latch incoming requests (rising-edge detect on the strobes)
 * ════════════════════════════════════════════════════════════════════════ */
reg data_wr_en_prev;
reg wr_en_prev;

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        data_rd_pending     <= 1'b0;
        data_rd_addr_lat    <= 24'b0;
        data_wr_pending     <= 1'b0;
        data_wr_addr_lat    <= 24'b0;
        data_wr_val_lat     <= 32'b0;
        data_wr_strobe_lat  <= 4'b0;
        upload_pending      <= 1'b0;
        upload_addr_lat     <= 24'b0;
        upload_data_lat     <= 32'b0;
        data_wr_en_prev     <= 1'b0;
        wr_en_prev          <= 1'b0;
    end else begin
        data_wr_en_prev <= data_wr_en;
        wr_en_prev      <= wr_en;

        /* Data read pulse: on a miss we set pending; cleared when serviced. */
        if (data_rd && !data_hit && !data_rd_pending)
            data_rd_pending <= 1'b1;
        if (rd_done) data_rd_pending <= 1'b0;
        if (data_rd) data_rd_addr_lat <= data_word_addr;

        /* Data write: latch on rising edge, prevent re-latch while busy. */
        if (data_wr_en && !data_wr_en_prev && !data_wr_pending) begin
            data_wr_pending    <= 1'b1;
            data_wr_addr_lat   <= data_word_addr;
            data_wr_val_lat    <= data_wr_val;
            data_wr_strobe_lat <= data_wr_strobe;
        end
        if (wr_done) data_wr_pending <= 1'b0;

        /* Code upload: rising-edge latch, same pattern. */
        if (wr_en && !wr_en_prev && !upload_pending) begin
            upload_pending  <= 1'b1;
            upload_addr_lat <= wr_addr;
            upload_data_lat <= wr_data;
        end
        if (upload_done) upload_pending <= 1'b0;
    end
end

/* ══════════════════════════════════════════════════════════════════════════
 * Top-level FSM — arbitrates one transaction at a time over the PSRAM ctrl.
 * ════════════════════════════════════════════════════════════════════════ */
localparam T_IDLE     = 4'd0;
localparam T_READ     = 4'd1;   /* PSRAM read in progress */
localparam T_WRITE    = 4'd2;   /* PSRAM write in progress (full word) */
localparam T_RMW_READ = 4'd3;   /* sub-word store: PSRAM read phase */
localparam T_RMW_MERGE= 4'd4;   /* sub-word store: 1-cycle merge */
localparam T_RMW_WRITE= 4'd5;   /* sub-word store: PSRAM write phase */
localparam T_FETCH    = 4'd6;   /* PSRAM read for instruction fetch */

reg [3:0] state;

/* Tag of which request the current transaction is servicing.  Used to know
 * which cache to populate / which pending bit to clear when ps_rdy fires. */
localparam SRC_NONE   = 3'd0;
localparam SRC_DREAD  = 3'd1;
localparam SRC_DWRITE = 3'd2;
localparam SRC_FETCH  = 3'd3;
localparam SRC_UPLOAD = 3'd4;
localparam SRC_RMW    = 3'd5;

reg [2:0] src;

/* One-cycle pulses to the latch logic above. */
reg rd_done, wr_done, upload_done;

/* RMW staging */
reg [31:0] rmw_old;
reg [31:0] rmw_new;
reg [23:0] rmw_addr;
reg [3:0]  rmw_strobe;

/* Helper to merge bytes for RMW. */
function [31:0] merge_bytes;
    input [31:0] old_word;
    input [31:0] new_word;
    input [3:0]  strobe;
    begin
        merge_bytes[ 7: 0] = strobe[0] ? new_word[ 7: 0] : old_word[ 7: 0];
        merge_bytes[15: 8] = strobe[1] ? new_word[15: 8] : old_word[15: 8];
        merge_bytes[23:16] = strobe[2] ? new_word[23:16] : old_word[23:16];
        merge_bytes[31:24] = strobe[3] ? new_word[31:24] : old_word[31:24];
    end
endfunction

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state            <= T_IDLE;
        src              <= SRC_NONE;
        ps_addr          <= 24'b0;
        ps_rd            <= 1'b0;
        ps_wr            <= 1'b0;
        ps_wdata         <= 32'b0;
        rd_done          <= 1'b0;
        wr_done          <= 1'b0;
        upload_done      <= 1'b0;
        inst_cache_addr  <= 24'h000000;
        inst_cache_data  <= 32'b0;
        inst_cache_valid <= 1'b0;
        data_cache_addr  <= 24'h000000;
        data_cache_data  <= 32'b0;
        data_cache_valid <= 1'b0;
        data_valid_r     <= 1'b0;
        rmw_old          <= 32'b0;
        rmw_new          <= 32'b0;
        rmw_addr         <= 24'b0;
        rmw_strobe       <= 4'b0;
    end else begin
        /* defaults: pulses go low unless re-asserted below */
        ps_rd        <= 1'b0;
        ps_wr        <= 1'b0;
        rd_done      <= 1'b0;
        wr_done      <= 1'b0;
        upload_done  <= 1'b0;
        data_valid_r <= 1'b0;

        /* ── Data port: report a hit immediately on data_rd. */
        if (data_rd && data_hit)
            data_valid_r <= 1'b1;

        case (state)
        T_IDLE: begin
            /* Wait until the controller is idle before issuing a new request.
             * In particular, the controller stays busy through its one-time
             * QPI-init phase after reset — we must hold off until ps_busy
             * goes low or our cmd_rd / cmd_wr pulse is dropped on the floor. */
            if (ps_busy) begin
                /* idle: do nothing this cycle */
            end
            /* Priority arbitration */
            else if (upload_pending) begin
                ps_addr  <= upload_addr_lat;
                ps_wdata <= upload_data_lat;
                ps_wr    <= 1'b1;
                src      <= SRC_UPLOAD;
                state    <= T_WRITE;
                /* Code upload also writes through the icache region —
                 * invalidate the inst cache if it matches. */
                if (inst_cache_valid && inst_cache_addr == upload_addr_lat)
                    inst_cache_valid <= 1'b0;
            end
            else if (data_wr_pending) begin
                if (data_wr_strobe_lat == 4'b1111) begin
                    ps_addr  <= data_wr_addr_lat;
                    ps_wdata <= data_wr_val_lat;
                    ps_wr    <= 1'b1;
                    src      <= SRC_DWRITE;
                    state    <= T_WRITE;
                    /* Update / invalidate caches that matched this address. */
                    if (data_cache_valid && data_cache_addr == data_wr_addr_lat) begin
                        data_cache_data  <= data_wr_val_lat;
                    end
                    if (inst_cache_valid && inst_cache_addr == data_wr_addr_lat)
                        inst_cache_valid <= 1'b0;
                end else begin
                    /* Sub-word store: read first, merge, write back. */
                    ps_addr    <= data_wr_addr_lat;
                    ps_rd      <= 1'b1;
                    src        <= SRC_RMW;
                    rmw_addr   <= data_wr_addr_lat;
                    rmw_new    <= data_wr_val_lat;
                    rmw_strobe <= data_wr_strobe_lat;
                    state      <= T_RMW_READ;
                end
            end
            else if (data_rd_pending && !data_hit) begin
                ps_addr <= data_rd_addr_lat;
                ps_rd   <= 1'b1;
                src     <= SRC_DREAD;
                state   <= T_READ;
            end
            else if (!is_rom_i && !inst_hit) begin
                ps_addr <= cpu_word_addr;
                ps_rd   <= 1'b1;
                src     <= SRC_FETCH;
                state   <= T_FETCH;
            end
        end

        T_READ: begin
            if (ps_rdy) begin
                data_cache_addr  <= ps_addr;
                data_cache_data  <= ps_rdata;
                data_cache_valid <= 1'b1;
                data_valid_r     <= 1'b1;
                rd_done          <= 1'b1;
                state            <= T_IDLE;
            end
        end

        T_FETCH: begin
            if (ps_rdy) begin
                inst_cache_addr  <= ps_addr;
                inst_cache_data  <= ps_rdata;
                inst_cache_valid <= 1'b1;
                state            <= T_IDLE;
            end
        end

        T_WRITE: begin
            if (ps_rdy) begin
                if (src == SRC_UPLOAD) upload_done <= 1'b1;
                else                   wr_done     <= 1'b1;
                state <= T_IDLE;
            end
        end

        T_RMW_READ: begin
            if (ps_rdy) begin
                rmw_old <= ps_rdata;
                state   <= T_RMW_MERGE;
            end
        end

        T_RMW_MERGE: begin
            ps_addr  <= rmw_addr;
            ps_wdata <= merge_bytes(rmw_old, rmw_new, rmw_strobe);
            ps_wr    <= 1'b1;
            state    <= T_RMW_WRITE;
            /* Update / invalidate caches now that we know the merged word. */
            if (data_cache_valid && data_cache_addr == rmw_addr)
                data_cache_data <= merge_bytes(rmw_old, rmw_new, rmw_strobe);
            if (inst_cache_valid && inst_cache_addr == rmw_addr)
                inst_cache_valid <= 1'b0;
        end

        T_RMW_WRITE: begin
            if (ps_rdy) begin
                wr_done <= 1'b1;
                state   <= T_IDLE;
            end
        end

        default: state <= T_IDLE;
        endcase
    end
end

endmodule
