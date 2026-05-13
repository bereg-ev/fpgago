/*
 * ddr3_iface.v — DDR3 test peripheral
 *
 * CPU-facing register file with two staging BRAMs (256x32, 1KB each):
 *
 *   WBRAM  — write direction  (CPU writes here; AXI master ships to DDR3)
 *   RBRAM  — read  direction  (AXI master fills from DDR3; CPU reads here)
 *
 * The BRAMs are NOT memory-mapped.  They're accessed through a pair of
 * (addr, data) registers each.  Every CPU access to the *_DATA register
 * reads/writes BRAM[*_ADDR] and then auto-increments *_ADDR.  This keeps
 * the test loop tight (write the address pointer once, then stream).
 *
 * DDR3 transactions are kicked off by writing DDR3_CMD.  The peripheral
 * issues one AXI4-INCR burst per command (up to 256 beats = 1 KB).
 *
 * Register map (within the peripheral page, byte offsets):
 *   0x00  WBRAM_ADDR    R/W   write-buffer pointer        (low 8 bits used)
 *   0x04  WBRAM_DATA    R/W   write-buffer data, ptr++ on every access
 *   0x08  RBRAM_ADDR    R/W   read-buffer pointer
 *   0x0C  RBRAM_DATA    R/W   read-buffer data, ptr++ on every access
 *   0x10  DDR3_ADDR     R/W   target byte address in DDR3
 *   0x14  DDR3_LEN      R/W   transfer length in 32-bit words (1..256)
 *   0x18  DDR3_CMD      W     1 = WRITE wbram->DDR3, 2 = READ DDR3->rbram
 *                             3 = clear sticky error
 *   0x1C  DDR3_STATUS   R     bit0=busy, bit1=axi_err_sticky
 *
 * Access width: all registers are 32 bits.  CPU must use full-word stores;
 * sub-word stores to *_DATA still write the full 32 bits of data_wdata
 * (no per-lane masking — keeps WBRAM as a single inferable 256x32 BRAM).
 *
 * AXI write path uses a 1-deep skid register to absorb the 1-cycle BRAM
 * read latency under W-channel stalls (achieves 50%-of-line throughput,
 * which is plenty for a memory tester).
 */

module ddr3_iface(
    input  wire        clk,
    input  wire        rst,

    /* CPU register port (peripheral page slice 0x008300..0x0083FF). */
    input  wire [23:0] data_addr,
    input  wire [31:0] data_wdata,
    input  wire [ 3:0] data_wstrb,
    input  wire        data_we,
    input  wire        data_re,
    output reg  [31:0] data_rdata,

    /* AXI4 master toward the DDR3 controller. */
    output reg         m_awvalid,
    output reg  [31:0] m_awaddr,
    output reg  [ 7:0] m_awlen,
    output wire [ 1:0] m_awburst,
    output wire [ 3:0] m_awid,
    input  wire        m_awready,

    output wire        m_wvalid,
    output wire [31:0] m_wdata,
    output wire [ 3:0] m_wstrb,
    output wire        m_wlast,
    input  wire        m_wready,

    input  wire        m_bvalid,
    input  wire [ 1:0] m_bresp,
    input  wire [ 3:0] m_bid,
    output wire        m_bready,

    output reg         m_arvalid,
    output reg  [31:0] m_araddr,
    output reg  [ 7:0] m_arlen,
    output wire [ 1:0] m_arburst,
    output wire [ 3:0] m_arid,
    input  wire        m_arready,

    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire [ 1:0] m_rresp,
    input  wire        m_rlast,
    input  wire [ 3:0] m_rid,
    output wire        m_rready
);

/* ── Address decode ──────────────────────────────────────────────────────── */
wire reg_range     = (data_addr[23:8] == 16'h0083);
wire is_wbram_addr = reg_range && (data_addr[7:0] == 8'h00);
wire is_wbram_data = reg_range && (data_addr[7:0] == 8'h04);
wire is_rbram_addr = reg_range && (data_addr[7:0] == 8'h08);
wire is_rbram_data = reg_range && (data_addr[7:0] == 8'h0C);
wire is_ddr3_addr  = reg_range && (data_addr[7:0] == 8'h10);
wire is_ddr3_len   = reg_range && (data_addr[7:0] == 8'h14);
wire is_ddr3_cmd   = reg_range && (data_addr[7:0] == 8'h18);
wire is_ddr3_stat  = reg_range && (data_addr[7:0] == 8'h1C);

/* ── Register file ───────────────────────────────────────────────────────── */
reg [ 7:0] wbram_ptr;
reg [ 7:0] rbram_ptr;
reg [31:0] ddr3_addr_reg;
reg [ 8:0] ddr3_len_reg;        /* 1..256 — encoded directly */
reg        busy;
reg        err_sticky;

wire wbram_cpu_we = is_wbram_data && data_we && !busy;
wire wbram_cpu_re = is_wbram_data && data_re && !busy;
wire rbram_cpu_we = is_rbram_data && data_we && !busy;
wire rbram_cpu_re = is_rbram_data && data_re && !busy;

/* ── BRAMs ───────────────────────────────────────────────────────────────── */
reg [31:0] wbram [0:255];
reg [31:0] rbram [0:255];

reg [ 7:0] wbram_b_addr;        /* BRAM port-B address (AXI side) */
reg [ 7:0] rbram_b_addr;
reg [31:0] wbram_axi_rdata;
reg [31:0] wbram_cpu_rdata;
reg [31:0] rbram_cpu_rdata;
wire       rbram_axi_we;
wire [31:0] rbram_axi_wdata;

/* Whole-word writes only — sub-word stores to WBRAM_DATA are clipped to a
 * full-word store of data_wdata.  The test app always does uint32_t stores
 * so this is invisible; saves splitting WBRAM into 4 byte-lanes. */
always @(posedge clk) begin
    if (wbram_cpu_we) wbram[wbram_ptr] <= data_wdata;
    wbram_cpu_rdata <= wbram[wbram_ptr];
    wbram_axi_rdata <= wbram[wbram_b_addr];
end

always @(posedge clk) begin
    rbram_cpu_rdata <= rbram[rbram_ptr];
    if (rbram_axi_we) rbram[rbram_b_addr] <= rbram_axi_wdata;
end

/* ── AXI master FSM ──────────────────────────────────────────────────────── */
localparam ST_IDLE  = 4'd0;
localparam ST_AW    = 4'd1;
localparam ST_W     = 4'd2;
localparam ST_B     = 4'd3;
localparam ST_AR    = 4'd4;
localparam ST_R     = 4'd5;
localparam ST_DONE  = 4'd6;

reg [3:0] axi_state;
reg [8:0] beats_total;          /* total beats (1..256) */
reg [8:0] beats_fetched;        /* BRAM reads issued */
reg [8:0] beats_sent;           /* AXI W-handshakes */
reg [8:0] beats_received;       /* AXI R-handshakes */

/* W-side skid register: holds at most one fetched beat, drives m_wdata. */
reg [31:0] skid_data;
reg        skid_valid;
reg        fetch_in_flight;     /* one BRAM read pending */

assign m_awburst = 2'b01;
assign m_arburst = 2'b01;
assign m_awid    = 4'b0;
assign m_arid    = 4'b0;
assign m_bready  = 1'b1;
assign m_rready  = 1'b1;

assign m_wvalid  = (axi_state == ST_W) && skid_valid;
assign m_wdata   = skid_data;
assign m_wstrb   = 4'b1111;
assign m_wlast   = m_wvalid && (beats_sent == beats_total - 9'd1);

assign rbram_axi_we    = (axi_state == ST_R) && m_rvalid;
assign rbram_axi_wdata = m_rdata;

/* ── CPU read mux ────────────────────────────────────────────────────────── *
 * BRAM reads (wbram/rbram_cpu_rdata) are registered with 1-cycle latency
 * matching what the SoC expects.  Other registers are also registered so all
 * reads have uniform timing. */
reg [31:0] reg_rdata_q;
always @(posedge clk) begin
    if      (is_wbram_addr) reg_rdata_q <= {24'b0, wbram_ptr};
    else if (is_rbram_addr) reg_rdata_q <= {24'b0, rbram_ptr};
    else if (is_ddr3_addr)  reg_rdata_q <= ddr3_addr_reg;
    else if (is_ddr3_len)   reg_rdata_q <= {23'b0, ddr3_len_reg};
    else if (is_ddr3_stat)  reg_rdata_q <= {30'b0, err_sticky, busy};
    else                    reg_rdata_q <= 32'h0;
end

always @(*) begin
    if      (is_wbram_data) data_rdata = wbram_cpu_rdata;
    else if (is_rbram_data) data_rdata = rbram_cpu_rdata;
    else                    data_rdata = reg_rdata_q;
end

/* ── State machine ───────────────────────────────────────────────────────── */
always @(posedge clk or negedge rst) begin
    if (!rst) begin
        wbram_ptr     <= 8'h0;
        rbram_ptr     <= 8'h0;
        ddr3_addr_reg <= 32'h0;
        ddr3_len_reg  <= 9'd1;
        busy          <= 1'b0;
        err_sticky    <= 1'b0;

        axi_state       <= ST_IDLE;
        beats_total     <= 9'd0;
        beats_fetched   <= 9'd0;
        beats_sent      <= 9'd0;
        beats_received  <= 9'd0;
        wbram_b_addr    <= 8'h0;
        rbram_b_addr    <= 8'h0;
        skid_data       <= 32'h0;
        skid_valid      <= 1'b0;
        fetch_in_flight <= 1'b0;

        m_awvalid <= 1'b0;
        m_awaddr  <= 32'h0;
        m_awlen   <= 8'h0;
        m_arvalid <= 1'b0;
        m_araddr  <= 32'h0;
        m_arlen   <= 8'h0;
    end else begin
        /* ── CPU register writes ───────────────────────────────────────── */
        if (!busy && data_we) begin
            if (is_wbram_addr) wbram_ptr     <= data_wdata[7:0];
            if (is_rbram_addr) rbram_ptr     <= data_wdata[7:0];
            if (is_ddr3_addr)  ddr3_addr_reg <= data_wdata;
            if (is_ddr3_len)   ddr3_len_reg  <= (data_wdata[8:0] == 9'd0)
                                               ? 9'd1 : data_wdata[8:0];
        end

        if (wbram_cpu_we || wbram_cpu_re) wbram_ptr <= wbram_ptr + 8'h1;
        if (rbram_cpu_we || rbram_cpu_re) rbram_ptr <= rbram_ptr + 8'h1;

        /* ── Command dispatch ──────────────────────────────────────────── */
        if (!busy && data_we && is_ddr3_cmd) begin
            case (data_wdata[1:0])
            2'd1: begin                                 /* WRITE wbram → DDR3 */
                busy           <= 1'b1;
                axi_state      <= ST_AW;
                beats_total    <= ddr3_len_reg;
                beats_fetched  <= 9'd0;
                beats_sent     <= 9'd0;
                wbram_b_addr   <= 8'h0;
                skid_valid     <= 1'b0;
                fetch_in_flight<= 1'b0;
                m_awvalid      <= 1'b1;
                m_awaddr       <= ddr3_addr_reg;
                m_awlen        <= ddr3_len_reg - 9'd1;  /* AXI: len-1 */
            end
            2'd2: begin                                 /* READ DDR3 → rbram */
                busy           <= 1'b1;
                axi_state      <= ST_AR;
                beats_total    <= ddr3_len_reg;
                beats_received <= 9'd0;
                rbram_b_addr   <= 8'h0;
                m_arvalid      <= 1'b1;
                m_araddr       <= ddr3_addr_reg;
                m_arlen        <= ddr3_len_reg - 9'd1;
            end
            2'd3: err_sticky <= 1'b0;
            default: ;
            endcase
        end

        /* ── AXI write path ────────────────────────────────────────────── */
        case (axi_state)
        ST_AW: begin
            if (m_awready && m_awvalid) begin
                m_awvalid <= 1'b0;
                axi_state <= ST_W;
            end
        end

        ST_W: begin
            /* Beat accepted by slave: invalidate skid so next BRAM read can
             * land in it. */
            if (m_wvalid && m_wready) begin
                skid_valid <= 1'b0;
                beats_sent <= beats_sent + 9'd1;
            end

            /* BRAM read result lands one cycle after wbram_b_addr is driven.
             * If a fetch was in flight, capture it now (when the skid has
             * room — either it was empty or just got drained this cycle). */
            if (fetch_in_flight && (!skid_valid || (m_wvalid && m_wready))) begin
                skid_data       <= wbram_axi_rdata;
                skid_valid      <= 1'b1;
                fetch_in_flight <= 1'b0;
            end

            /* Issue the next BRAM read whenever the skid will be empty next
             * cycle and we still have beats to fetch. */
            if (!fetch_in_flight
                && (!skid_valid || (m_wvalid && m_wready))
                && (beats_fetched < beats_total)) begin
                wbram_b_addr    <= beats_fetched[7:0];
                fetch_in_flight <= 1'b1;
                beats_fetched   <= beats_fetched + 9'd1;
            end

            /* All beats handed over → wait for B response. */
            if (m_wvalid && m_wready && (beats_sent == beats_total - 9'd1))
                axi_state <= ST_B;
        end

        ST_B: begin
            if (m_bvalid) begin
                if (m_bresp != 2'b00) err_sticky <= 1'b1;
                axi_state <= ST_DONE;
            end
        end

        /* ── AXI read path ─────────────────────────────────────────────── */
        ST_AR: begin
            if (m_arready && m_arvalid) begin
                m_arvalid <= 1'b0;
                axi_state <= ST_R;
            end
        end

        ST_R: begin
            if (m_rvalid) begin
                if (m_rresp != 2'b00) err_sticky <= 1'b1;
                rbram_b_addr   <= rbram_b_addr + 8'h1;
                beats_received <= beats_received + 9'd1;
                if (m_rlast)
                    axi_state <= ST_DONE;
            end
        end

        ST_DONE: begin
            busy      <= 1'b0;
            axi_state <= ST_IDLE;
        end

        default: axi_state <= ST_IDLE;
        endcase
    end
end

endmodule
