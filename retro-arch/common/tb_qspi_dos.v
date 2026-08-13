//
// tb_qspi_dos.v — self-checking bench for the DOS-over-link bus channel
// (qspi_slave.v with C64=1).
//
// Replays the exact sequence a Pirates!-class title puts on the serial bus —
// LISTEN 8 / SECOND / "U1:2 0 18 0" / UNLISTEN, then TALK 8 / TKSA / 256
// GET#s — from the C64 side, while the MCU side fetches the submitted bytes
// and streams the sector back.  Checks the two things the detours depend on:
// ownership (so non-8 traffic falls back to the stock KERNAL) and EOI landing
// on the LAST byte rather than after it.
//
//   iverilog -I . -o /tmp/tb_qspi_dos qspi_slave.v tb_qspi_dos.v &&
//   vvp /tmp/tb_qspi_dos
//
`timescale 1ns/1ps

module tb_qspi_dos;

    reg clk = 0, rst = 0;
    reg sck = 0, ss = 1, mosi = 0;
    wire req;
    wire [3:0] sd_out, sd_oe;
    wire miso = sd_out[1];

    reg  [15:0] exp_addr  = 0;
    wire [7:0]  exp_rdata;
    reg  [3:0]  exp_laddr = 0;
    reg  [7:0]  exp_wdata = 0;
    reg         exp_wstb  = 0, exp_rstb = 0;

    qspi_slave #(.C64(1)) dut (
        .clk(clk), .rst(rst),
        .spi_sck(sck), .spi_ss(ss),
        .spi_sd_in({3'b111, mosi}), .spi_sd_out(sd_out), .spi_sd_oe(sd_oe),
        .req(req),
        .btn(8'hFF), .bios_mode(), .vol_scale(), .bright_scale(),
        .btn_mode(), .btn_mode_stb(), .drive_1541(), .dos_link(),
        .shot_arm_stb(), .shot_line(), .shot_dense(), .shot_pair(),
        .shot_freeze(),
        .shot_armed(1'b0), .shot_ready(1'b0),
        .shot_raddr(), .shot_rdata(16'h0000),
        .txt_waddr(), .txt_wdata(), .txt_wen(),
        .exp_addr(exp_addr), .exp_rdata(exp_rdata),
        .exp_laddr(exp_laddr), .exp_wdata(exp_wdata),
        .exp_wstb(exp_wstb), .exp_rstb(exp_rstb),
        /* no fabric 1541 here: FD_STATUS reads all-zero (tied, never
         * left open -- netlist-sim-undriven-wires) */
        .fd_stat(8'h00), .fd_done(8'h00)
    );

    always #17.857 clk = ~clk;              // 28 MHz
    localparam HALF = 500;                  // 1 MHz SPI

    integer errors = 0;

    task check;
        input [7:0] got, want;
        input [511:0] what;
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %02x want %02x", what, got, want);
                errors = errors + 1;
            end else
                $display("  ok: %0s", what);
        end
    endtask

    task check1;
        input got, want;
        input [511:0] what;
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b want %b", what, got, want);
                errors = errors + 1;
            end else
                $display("  ok: %0s", what);
        end
    endtask

    // ── SPI master model (the MCU) ──
    task xfer_byte;
        input  [7:0] tx;
        output [7:0] rx;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = tx[i];
                #HALF sck = 1;
                rx[i] = miso;
                #HALF sck = 0;
            end
        end
    endtask
    task spi_begin; begin ss = 0; #(HALF*2); end endtask
    task spi_end;   begin #(HALF*2); ss = 1; #(HALF*4); end endtask

    // ── EXP bus model (the served 6502 routines) ──
    task cpu_write;
        input [3:0] a;
        input [7:0] v;
        begin
            @(negedge clk);
            exp_addr = {12'hDF0, a}; exp_laddr = a; exp_wdata = v;
            exp_wstb = 1;
            @(negedge clk);
            exp_wstb = 0;
            @(negedge clk);
        end
    endtask

    // read WITHOUT the pop strobe (status registers are side-effect free)
    task cpu_peek;
        input  [3:0] a;
        output [7:0] v;
        begin
            @(negedge clk);
            exp_addr = {12'hDF0, a};
            @(negedge clk);
            v = exp_rdata;
            @(negedge clk);
        end
    endtask

    // read WITH the pop strobe — what "LDA $DF01" does
    task cpu_pop;
        output [7:0] v;
        begin
            @(negedge clk);
            exp_addr = 16'hDF01;
            @(negedge clk);
            v = exp_rdata;
            exp_laddr = 4'h1; exp_rstb = 1;
            @(negedge clk);
            exp_rstb = 0;
            @(negedge clk);
        end
    endtask

    // MCU: fetch the pending request.  resp = [MAGIC][MAGIC][type][len]
    // [name 0..15][mask lo][mask hi]
    reg [7:0] fetch_type, fetch_len, fetch_mlo, fetch_mhi;
    reg [7:0] fetch_buf [0:15];
    task mcu_fetch;
        integer i;
        reg [7:0] b;
        begin
            spi_begin;
            xfer_byte(8'h10, b);                 // CMD_REQ_FETCH
            xfer_byte(8'h00, b);                 // MAGIC
            xfer_byte(8'h00, fetch_type);
            xfer_byte(8'h00, fetch_len);
            for (i = 0; i < 16; i = i + 1)
                xfer_byte(8'h00, fetch_buf[i]);
            xfer_byte(8'h00, fetch_mlo);
            xfer_byte(8'h00, fetch_mhi);
            spi_end;
        end
    endtask

    task mcu_push;                                // DATA_PUSH of n bytes
        input [7:0] first;
        input integer n;
        integer i;
        reg [7:0] b;
        begin
            spi_begin;
            xfer_byte(8'h11, b);
            xfer_byte(n[7:0], b);
            for (i = 0; i < n; i = i + 1)
                xfer_byte(first + i[7:0], b);
            spi_end;
        end
    endtask

    task mcu_end;                                 // XFER_END, no error
        reg [7:0] b;
        begin
            spi_begin;
            xfer_byte(8'h12, b);            // CMD_XFER_END
            xfer_byte(8'h00, b);
            spi_end;
        end
    endtask

    task mcu_mode;                                // DRIVE_MODE
        input [7:0] m;
        reg [7:0] b;
        begin
            spi_begin;
            xfer_byte(8'h0B, b);
            xfer_byte(8'h01, b);
            xfer_byte(m, b);
            spi_end;
        end
    endtask

    reg [7:0] st, v;
    integer i;

    initial begin
        repeat (10) @(posedge clk);
        rst = 1;
        repeat (10) @(posedge clk);

        mcu_mode(8'h02);                          // DOS over link

        // ── 1. the command transaction ─────────────────────────────────
        $display("-- LISTEN 8 / SECOND / U1 command / UNLISTEN");
        cpu_write(4'h3, 8'h28);                   // LISTEN 8, under ATN
        cpu_peek(4'h3, st);
        check1(st[7], 1'b1, "LISTEN 8 -> the detour owns the transaction");
        check1(req,   1'b1, "...and REQ asks the MCU to take the byte");
        mcu_fetch;
        check(fetch_type, 8'h02, "REQ_FETCH reports a bus transaction");
        check(fetch_len,  8'h01, "one byte buffered");
        check(fetch_buf[0], 8'h28, "the byte is LISTEN 8");
        check(fetch_mlo,  8'h01, "and it is tagged as sent under ATN");

        cpu_write(4'h3, 8'h6F);                   // SECOND: command channel
        cpu_write(4'h4, "U");                     // data bytes
        cpu_write(4'h4, "1");
        cpu_write(4'h3, 8'h3F);                   // UNLISTEN
        mcu_fetch;
        check(fetch_len, 8'd4, "SECOND + 2 data + UNLISTEN buffered together");
        check(fetch_buf[0], 8'h6F, "buf[0] = SECOND");
        check(fetch_buf[1], "U",   "buf[1] = data");
        check(fetch_buf[3], 8'h3F, "buf[3] = UNLISTEN");
        check(fetch_mlo, 8'b1001,  "mask marks only the ATN bytes");

        // UNLISTEN un-addresses us but is still ours to deliver — if it fell
        // through to the stock sender it would time out and set ST=$80
        cpu_peek(4'h3, st);
        check1(st[7], 1'b1, "UNLISTEN is delivered by the detour, not the wire");

        // ── 2. another device must fall back to the stock KERNAL ───────
        $display("-- LISTEN 9 (not ours)");
        cpu_write(4'h3, 8'h29);
        cpu_peek(4'h3, st);
        check1(st[7], 1'b0, "LISTEN 9 hands the bus back to the stock code");

        // ── 3. TALK + the streamed answer ──────────────────────────────
        $display("-- TALK 8 / TKSA / GET#");
        cpu_write(4'h3, 8'h48);                   // TALK 8
        cpu_peek(4'h3, st);
        check1(st[7], 1'b1, "TALK 8 addresses us again");
        check1(st[6], 1'b0, "...with the FIFO flushed of the last transfer");
        cpu_write(4'h3, 8'h62);                   // TKSA channel 2
        mcu_fetch;                                // MCU takes TALK+TKSA

        mcu_push(8'hA0, 4);                       // 4 bytes: A0 A1 A2 A3
        mcu_end;
        cpu_peek(4'h3, st);
        check1(st[6], 1'b1, "a pushed byte shows up as available");
        check1(st[5], 1'b0, "the FIRST byte is not flagged EOI");

        for (i = 0; i < 3; i = i + 1) begin
            cpu_pop(v);
            check(v, 8'hA0 + i[7:0], "byte streamed in order");
        end
        cpu_peek(4'h3, st);
        check1(st[5], 1'b1, "EOI lands ON the last byte, not after it");
        cpu_pop(v);
        check(v, 8'hA3, "...and that byte is the last one");
        cpu_peek(4'h3, st);
        check1(st[4], 1'b1, "the transfer then reports done");

        // ── 4. the window serves stubs when the link is not the DOS ────
        $display("-- mode gating");
        exp_addr = 16'hDE80; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'hAD, "DOS mode: $DE80 = the send routine (LDA)");
        exp_addr = 16'hDE81; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'h00, "...$DD00 low byte");
        mcu_mode(8'h00);                          // plain fastload
        exp_addr = 16'hDE80; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'h78, "fastload mode: $DE80 = the stub (SEI)");
        exp_addr = 16'hDE81; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'h20, "...JSR $EE97 — straight back to the KERNAL");
        exp_addr = 16'hDE84; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'h4C, "...then JMP");
        exp_addr = 16'hDE85; @(negedge clk); @(negedge clk);
        check(exp_rdata, 8'h44, "...to $ED44");

        $display("%0s (%0d failure%0s)", errors ? "TEST FAILED" : "ALL PASS",
                 errors, errors == 1 ? "" : "s");
        if (errors) $fatal(1);
        $finish;
    end

endmodule
