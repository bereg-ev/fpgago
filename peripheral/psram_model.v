/*
 * psram_model.v — Functional model of the APS6404L PSRAM (sim-only).
 *
 * Recognises:
 *   SPI mode (power-up):
 *     0x35  Enter QPI mode  (CE# falls, 8 bits on SIO0, CE# rises)
 *
 *   QPI mode:
 *     0xEB  Fast Read Quad I/O    cmd(2 nibbles)+addr(6 nibbles)+6 dummy+data
 *     0x38  Quad I/O Write        cmd(2 nibbles)+addr(6 nibbles)+data
 *
 * Verilator-friendly: ONE always block per register.  We drive the FSM from
 * `posedge psram_sclk or negedge psram_ce_n` and disambiguate by the SCLK
 * level — SCLK is idle low between transactions, so a CE# falling edge
 * arrives while SCLK is 0; an SCLK rising edge arrives while we're inside
 * a transaction.
 *
 * Memory: 8 MB.  Initial content uses an LCG to be visually distinct from
 * sdram_model.v's `$random` pattern so the screen tells which chip a stray
 * fetch came from.
 */

module psram_chip_model(
    input  wire psram_sclk,
    input  wire psram_ce_n,
    inout  wire psram_sio0,
    inout  wire psram_sio1,
    inout  wire psram_sio2,
    inout  wire psram_sio3
);

/* public: sims may preload images directly (c64 --ef EasyFlash flat cart) */
reg [7:0] mem [0:(8*1024*1024)-1] /* verilator public_flat_rw */;

integer mi;
reg [31:0] lcg;
initial begin
    lcg = 32'hDEAD_BEEF;
    for (mi = 0; mi < 8*1024*1024; mi = mi + 1) begin
        lcg     = lcg * 32'd1103515245 + 32'd12345;
        mem[mi] = lcg[23:16];
    end
end

/* ── Mode flag: SPI on power-up, QPI after we receive 0x35 ─────────────── */
reg qpi_mode;

/* ── Per-transaction FSM state ─────────────────────────────────────────── */
localparam P_CMD   = 3'd0;
localparam P_ADDR  = 3'd1;
localparam P_DUMMY = 3'd2;
localparam P_DATA  = 3'd3;
localparam P_DONE  = 3'd4;
localparam P_SPIA  = 3'd5;   /* SPI Read-ID: 24 address bits after 0x9F   */
localparam P_SPID  = 3'd6;   /* SPI Read-ID: ID stream out on SIO1 (MISO) */

reg [2:0]  phase;
reg [4:0]  bit_in_phase;
reg [7:0]  cmd_byte;
reg [23:0] addr_sr;
reg [22:0] cur_addr;
reg [7:0]  rd_byte;
reg [7:0]  wr_byte_sr;
reg        is_read;
reg        is_id;          /* Read-ID (0x9F) transaction */
reg        is_qpi_xfer;

/* APS6404L Read-ID byte stream: MFID, KGD, then EID. */
function [7:0] id_byte_f;
    input [22:0] a;
    case (a[2:0])
        3'd0: id_byte_f = 8'h0D;   /* MFID (AP Memory) */
        3'd1: id_byte_f = 8'h5D;   /* KGD ID */
        3'd2: id_byte_f = 8'h52;
        3'd3: id_byte_f = 8'h99;
        default: id_byte_f = 8'h00;
    endcase
endfunction

/* ── SPI-mode Read-ID output (one bit per falling edge, like the chip) ──
 * psram_fast's init probe issues 0x9F + 24 address bits in 1-bit SPI mode
 * BEFORE entering QPI, and captures 16 ID bits from SIO1.  The model
 * originally answered Read-ID only as a QPI transaction, so a testbench
 * running the real init saw dbg_id = 0 — while the board saw 0x0D5D.  A
 * model gap in exactly the class the P_DUMMY note below warns about:
 * mirroring the master's assumptions instead of the silicon.
 * The real part shifts MISO on FALLING SCLK edges (mode 0); doing the same
 * keeps the master's rising-edge sample race-free by half a bit period. */
reg [31:0] spi_id_sr;
reg        spi_id_oe, spi_id_bit;
always @(negedge psram_sclk or posedge psram_ce_n) begin
    if (psram_ce_n) begin
        spi_id_oe <= 1'b0;
        spi_id_sr <= {id_byte_f(23'd0), id_byte_f(23'd1),
                      id_byte_f(23'd2), id_byte_f(23'd3)};
    end else if (phase == P_SPID) begin
        spi_id_oe  <= 1'b1;
        spi_id_bit <= spi_id_sr[31];
        spi_id_sr  <= {spi_id_sr[30:0], 1'b0};
    end
end

/* ── SIO output (combinational drive based on FSM state) ───────────────── */
wire [7:0] rd_src = is_id ? id_byte_f(cur_addr) : mem[cur_addr];
wire driving = is_read && phase == P_DATA && !psram_ce_n;
wire even_nibble = (bit_in_phase[0] == 1'b0);
wire [3:0] sio_q_bits = even_nibble ? rd_src[7:4] : rd_byte[3:0];

assign psram_sio0 = driving ? sio_q_bits[0] : 1'bz;
assign psram_sio1 = driving   ? sio_q_bits[1]
                  : spi_id_oe ? spi_id_bit
                              : 1'bz;
assign psram_sio2 = driving ? sio_q_bits[2] : 1'bz;
assign psram_sio3 = driving ? sio_q_bits[3] : 1'bz;

wire [3:0] sio_in = {psram_sio3, psram_sio2, psram_sio1, psram_sio0};

initial begin
    qpi_mode     = 1'b0;
    phase        = P_CMD;
    bit_in_phase = 5'd0;
    cmd_byte     = 8'd0;
    addr_sr      = 24'd0;
    cur_addr     = 23'd0;
    is_read      = 1'b0;
    is_qpi_xfer  = 1'b0;
    rd_byte      = 8'd0;
    wr_byte_sr   = 8'd0;
end

/* ── ONE FSM block.  Combined sensitivity:
 *      negedge ce_n: arm a new transaction (sclk is low here).
 *      posedge ce_n: end of transaction; if we just received 0x35 in SPI,
 *                    flip qpi_mode; clear pending state.
 *      posedge sclk: sample SIO and advance the phase counter.
 * Disambiguate by checking which signal "fired".  SCLK is always 0 across
 * any CE# edge (the master deasserts/reasserts CE# while SCLK is idle low),
 * so we can use sclk as a flag. ─────────────────────────────────────────── */
always @(posedge psram_sclk or negedge psram_ce_n or posedge psram_ce_n) begin
    if (!psram_ce_n && !psram_sclk) begin
        /* CE# just fell → start a new transaction. */
        phase        <= P_CMD;
        bit_in_phase <= 5'd0;
        cmd_byte     <= 8'd0;
        addr_sr      <= 24'd0;
        is_read      <= 1'b0;
        is_id        <= 1'b0;
        is_qpi_xfer  <= qpi_mode;
    end
    else if (psram_ce_n) begin
        /* CE# just rose → end of transaction.  If we were in SPI and the
         * just-completed command was 0x35, switch to QPI for next time. */
        if (!is_qpi_xfer && cmd_byte == 8'h35) qpi_mode <= 1'b1;
    end
    else begin
        /* posedge SCLK while CE# asserted → process one bit/nibble. */
        case (phase)
        P_CMD: begin
            if (is_qpi_xfer) begin
                cmd_byte <= {cmd_byte[3:0], sio_in};
                if (bit_in_phase == 5'd1) begin
                    phase        <= P_ADDR;
                    bit_in_phase <= 5'd0;
                    is_read      <= ({cmd_byte[3:0], sio_in} == 8'hEB ||
                                     {cmd_byte[3:0], sio_in} == 8'h9F);
                    is_id        <= ({cmd_byte[3:0], sio_in} == 8'h9F);
                end else begin
                    bit_in_phase <= 5'd1;
                end
            end else begin
                cmd_byte <= {cmd_byte[6:0], sio_in[0]};
                if (bit_in_phase == 5'd7) begin
                    bit_in_phase <= 5'd0;
                    /* SPI Read-ID carries a 24-bit address before the chip
                     * answers; everything else (0x35 QPI-entry above all)
                     * is command-only. */
                    phase <= ({cmd_byte[6:0], sio_in[0]} == 8'h9F) ? P_SPIA
                                                                   : P_DONE;
                end else begin
                    bit_in_phase <= bit_in_phase + 5'd1;
                end
            end
        end

        P_SPIA: begin
            /* swallow the 24 address bits, then drive the ID stream */
            if (bit_in_phase == 5'd23) begin
                bit_in_phase <= 5'd0;
                phase        <= P_SPID;
            end else
                bit_in_phase <= bit_in_phase + 5'd1;
        end

        P_SPID: ;   /* output happens in the negedge block above */

        P_ADDR: begin
            addr_sr <= {addr_sr[19:0], sio_in};
            if (bit_in_phase == 5'd5) begin
                cur_addr     <= {addr_sr[18:0], sio_in};
                bit_in_phase <= 5'd0;
                phase        <= is_read ? (is_id ? P_DATA : P_DUMMY) : P_DATA;
            end else begin
                bit_in_phase <= bit_in_phase + 5'd1;
            end
        end

        P_DUMMY: begin
            /* 7 edges, not 6: BOARD-CALIBRATED 2026-07-29.  The real
             * APS6404L drives its first data nibble on the falling edge
             * AFTER wait cycle 6, so the first rising edge that samples
             * valid data is the 7th after the address phase.  The model
             * originally advanced after 6 edges — mirroring psram.v's
             * assumption instead of the silicon — which let a one-nibble-
             * early sampling bug pass simulation and fail on the board
             * (readback shifted right by one nibble). */
            if (bit_in_phase == 5'd6) begin
                bit_in_phase <= 5'd0;
                phase        <= P_DATA;
            end else begin
                bit_in_phase <= bit_in_phase + 5'd1;
            end
        end

        P_DATA: begin
            if (is_read) begin
                /* Master is sampling combinational sio_q on each rising
                 * SCLK; we just need to advance address every other tick. */
                if (bit_in_phase[0] == 1'b1) begin
                    rd_byte  <= rd_src;
                    cur_addr <= cur_addr + 23'd1;
                end else begin
                    rd_byte  <= rd_src;
                end
                bit_in_phase <= bit_in_phase + 5'd1;
            end else begin
                wr_byte_sr <= {wr_byte_sr[3:0], sio_in};
                if (bit_in_phase[0] == 1'b1) begin
                    mem[cur_addr] <= {wr_byte_sr[3:0], sio_in};
                    cur_addr      <= cur_addr + 23'd1;
                end
                bit_in_phase <= bit_in_phase + 5'd1;
            end
        end

        default: ;
        endcase
    end
end

endmodule
