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

module psram(
    input  wire        clk,
    input  wire        rst,            /* active-low, async */

    input  wire [23:0] cmd_addr,
    input  wire        cmd_rd,
    input  wire        cmd_wr,
    input  wire [31:0] cmd_wdata,
    output wire [31:0] rdata,
    output reg         rdy,            /* 1-cycle pulse on completion */
    output wire        busy,

    output wire        psram_sclk,
    output reg         psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3
);

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

reg [3:0]  state;
reg [4:0]  bit_cnt;
reg [7:0]  init_sr;
reg [23:0] addr_sr;
reg [31:0] data_sr;
reg [31:0] rdata_sr;
reg        is_read_lat;

reg       spi_phase;
reg       qpi_drive;
reg [3:0] sio_out;

assign psram_sio0 = spi_phase ? sio_out[0] : (qpi_drive ? sio_out[0] : 1'bz);
assign psram_sio1 = spi_phase ? 1'bz       : (qpi_drive ? sio_out[1] : 1'bz);
assign psram_sio2 = spi_phase ? 1'b1       : (qpi_drive ? sio_out[2] : 1'bz);
assign psram_sio3 = spi_phase ? 1'b1       : (qpi_drive ? sio_out[3] : 1'bz);

wire [3:0] sio_in = {psram_sio3, psram_sio2, psram_sio1, psram_sio0};

wire sclk_active = (state == S_INIT_CMD) ||
                   (state == S_CMD)      ||
                   (state == S_ADDR)     ||
                   (state == S_DUMMY)    ||
                   (state == S_WDATA)    ||
                   (state == S_RDATA);
assign psram_sclk = sclk_active ? ~clk : 1'b0;

assign rdata = rdata_sr;
assign busy  = (state != S_IDLE);

/* Diagnostic counter — bumped every time CE# rises after a transaction. */
reg [31:0] xfer_count;

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state       <= S_INIT_CSL;
        bit_cnt     <= 5'd0;
        init_sr     <= 8'h35;
        addr_sr     <= 24'b0;
        data_sr     <= 32'b0;
        rdata_sr    <= 32'b0;
        is_read_lat <= 1'b0;
        rdy         <= 1'b0;
        psram_ce_n  <= 1'b1;
        spi_phase   <= 1'b0;
        qpi_drive   <= 1'b0;
        sio_out     <= 4'b0;
        xfer_count  <= 32'b0;
    end else begin
        rdy <= 1'b0;        /* default: rdy is a 1-cycle pulse */

        case (state)
        S_INIT_CSL: begin
            psram_ce_n <= 1'b0;
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
            psram_ce_n <= 1'b1;
            spi_phase  <= 1'b0;
            sio_out    <= 4'b0;
            state      <= S_IDLE;
        end

        S_IDLE: begin
            psram_ce_n <= 1'b1;
            qpi_drive  <= 1'b0;
            if (cmd_rd | cmd_wr) begin
                addr_sr     <= cmd_addr;
                data_sr     <= cmd_wdata;
                is_read_lat <= cmd_rd;
                sio_out     <= cmd_rd ? 4'hE : 4'h3;
                psram_ce_n  <= 1'b0;
                qpi_drive   <= 1'b1;
                bit_cnt     <= 5'd1;
                state       <= S_CMD;
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
                    /* Wait 5 cycles in S_DUMMY (bit_cnt 4..0).  The S_ADDR
                     * IF cycle itself contributes a 6th SCK edge between
                     * last-addr-sample and first-data-sample on the slave,
                     * so 5 explicit dummy cycles here gives the chip's
                     * required 6 wait SCKs. */
                    bit_cnt   <= 5'd4;
                    state     <= S_DUMMY;
                end else begin
                    sio_out <= data_sr[31:28];
                    data_sr <= {data_sr[27:0], 4'b0};
                    bit_cnt <= 5'd7;
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
                bit_cnt <= 5'd7;
                state   <= S_RDATA;
            end else begin
                bit_cnt <= bit_cnt - 5'd1;
            end
        end

        S_RDATA: begin
            rdata_sr <= {rdata_sr[27:0], sio_in};
            if (bit_cnt == 0) state <= S_CSHIGH;
            else              bit_cnt <= bit_cnt - 5'd1;
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
            psram_ce_n <= 1'b1;
            qpi_drive  <= 1'b0;
            rdy        <= 1'b1;
            xfer_count <= xfer_count + 32'd1;
            state      <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
