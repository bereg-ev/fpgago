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

reg [7:0] mem [0:(8*1024*1024)-1];

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

reg [2:0]  phase;
reg [4:0]  bit_in_phase;
reg [7:0]  cmd_byte;
reg [23:0] addr_sr;
reg [22:0] cur_addr;
reg [7:0]  rd_byte;
reg [7:0]  wr_byte_sr;
reg        is_read;
reg        is_qpi_xfer;

/* ── SIO output (combinational drive based on FSM state) ───────────────── */
wire driving = is_read && phase == P_DATA && !psram_ce_n;
wire even_nibble = (bit_in_phase[0] == 1'b0);
wire [3:0] sio_q_bits = even_nibble ? mem[cur_addr][7:4] : rd_byte[3:0];

assign psram_sio0 = driving ? sio_q_bits[0] : 1'bz;
assign psram_sio1 = driving ? sio_q_bits[1] : 1'bz;
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
                    is_read      <= ({cmd_byte[3:0], sio_in} == 8'hEB);
                end else begin
                    bit_in_phase <= 5'd1;
                end
            end else begin
                cmd_byte <= {cmd_byte[6:0], sio_in[0]};
                if (bit_in_phase == 5'd7) begin
                    bit_in_phase <= 5'd0;
                    phase        <= P_DONE;
                end else begin
                    bit_in_phase <= bit_in_phase + 5'd1;
                end
            end
        end

        P_ADDR: begin
            addr_sr <= {addr_sr[19:0], sio_in};
            if (bit_in_phase == 5'd5) begin
                cur_addr     <= {addr_sr[18:0], sio_in};
                bit_in_phase <= 5'd0;
                phase        <= is_read ? P_DUMMY : P_DATA;
            end else begin
                bit_in_phase <= bit_in_phase + 5'd1;
            end
        end

        P_DUMMY: begin
            if (bit_in_phase == 5'd5) begin
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
                    rd_byte  <= mem[cur_addr];
                    cur_addr <= cur_addr + 23'd1;
                end else begin
                    rd_byte  <= mem[cur_addr];
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
