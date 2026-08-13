//
// tb_qspi_slave.v — self-checking bench for qspi_slave.v
//
// Models both sides: the RP2350 PIO SPI master (mode 0, MSB first, ~1 MHz
// against a 28 MHz system clock) and the C16 core's EXP bus (latched
// laddr/wdata + one-clk trailing-edge strobes). Covers PING, a full
// fastload transaction (submit → REQ_FETCH → DATA_PUSH → XFER_END → CPU
// drain), and the error flag.
//
//   iverilog -I . -o /tmp/tb_qspi_slave qspi_slave.v tb_qspi_slave.v && vvp /tmp/tb_qspi_slave
//
`timescale 1ns/1ps

module tb_qspi_slave;

    reg clk = 0;
    reg rst = 0;

    reg  sck  = 0;
    reg  ss   = 1;
    reg  mosi = 0;
    wire req;

    // 1-lane (legacy) mode: SD0 = MOSI in, SD1 = MISO out.  The other two
    // lanes read as the board's 10k pull-ups.
    wire [3:0] sd_out, sd_oe;
    wire       miso = sd_out[1];

    reg  [15:0] exp_addr  = 0;
    wire [7:0]  exp_rdata;
    reg  [3:0]  exp_laddr = 0;
    reg  [7:0]  exp_wdata = 0;
    reg         exp_wstb  = 0;
    reg         exp_rstb  = 0;

    reg  [7:0]  btn = 8'hFF;
    wire        bios_mode;
    wire [4:0]  vol_scale;
    wire [6:0]  bright_scale;
    wire [10:0] txt_waddr;
    wire [15:0] txt_wdata;
    wire        txt_wen;

    qspi_slave dut (
        .clk(clk), .rst(rst),
        .spi_sck(sck), .spi_ss(ss),
        .spi_sd_in({3'b111, mosi}), .spi_sd_out(sd_out), .spi_sd_oe(sd_oe),
        .req(req),
        .btn(btn), .bios_mode(bios_mode), .vol_scale(vol_scale),
        .bright_scale(bright_scale),
        .btn_mode(), .btn_mode_stb(), .drive_1541(),
        .shot_arm_stb(), .shot_line(), .shot_dense(), .shot_pair(),
        .shot_freeze(),
        .shot_armed(1'b0), .shot_ready(1'b0),
        .shot_raddr(), .shot_rdata(16'h0000),
        .txt_waddr(txt_waddr), .txt_wdata(txt_wdata), .txt_wen(txt_wen),
        .exp_addr(exp_addr), .exp_rdata(exp_rdata),
        .exp_laddr(exp_laddr), .exp_wdata(exp_wdata),
        .exp_wstb(exp_wstb), .exp_rstb(exp_rstb),
        /* no fabric 1541 here: FD_STATUS reads all-zero (tied, never
         * left open -- netlist-sim-undriven-wires) */
        .fd_stat(8'h00), .fd_done(8'h00)
    );

    // shadow text RAM: capture every write-port commit
    reg [15:0] shadow [0:2047];
    integer sh_writes = 0;
    always @(posedge clk)
        if (txt_wen) begin
            shadow[txt_waddr] <= txt_wdata;
            sh_writes = sh_writes + 1;
        end

    always #17.857 clk = ~clk;          // 28 MHz
    localparam HALF = 500;              // 1 MHz SPI

    integer errors = 0;

    task check;
        input [7:0] got;
        input [7:0] want;
        input [255:0] what;   // 32 chars; 128 silently truncated longer ones
        begin
            if (got !== want) begin
                $display("FAIL %0s: got %02x want %02x", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    task check1;
        input got;
        input want;
        input [255:0] what;
        begin
            if (got !== want) begin
                $display("FAIL %0s: got %b want %b", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // ── SPI master model ──
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

    // ── EXP bus model (CPU side) ──
    task cpu_write;                       // write $FE2x
        input [3:0] a;
        input [7:0] v;
        begin
            @(negedge clk);
            exp_laddr = a; exp_wdata = v; exp_wstb = 1;
            @(negedge clk);
            exp_wstb = 0;
            @(negedge clk);
        end
    endtask

    task cpu_read;                        // read $FE2x (with pop strobe)
        input  [3:0] a;
        output [7:0] v;
        begin
            @(negedge clk);
            exp_addr = {12'hFE2, a};
            @(negedge clk);
            v = exp_rdata;
            exp_laddr = a; exp_rstb = 1;
            @(negedge clk);
            exp_rstb = 0;
            @(negedge clk);
        end
    endtask

    reg [7:0] r0, r1, r2, r3, r4, r5, b;
    integer k;

    initial begin
        repeat (10) @(posedge clk);
        rst = 1;
        repeat (10) @(posedge clk);

        // ── PING ──
        spi_begin;
        xfer_byte(8'h04, r0); xfer_byte(8'h00, r1); xfer_byte(8'h00, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4);
        spi_end;
        check(r0, 8'h5C, "ping magic0");
        check(r2, 8'hA5, "pong");
        check(r3, 8'd0,  "ping count");
        check(r4, 8'hFB, "~cmd");

        // ── CPU submits a LOAD request for "AB" ──
        check1(req, 1'b0, "req idle");
        cpu_write(4'h0, 8'h00);          // reset engine
        cpu_write(4'h1, "A");
        cpu_write(4'h1, "B");
        cpu_write(4'h0, 8'h01);          // submit
        @(posedge clk);
        check1(req, 1'b1, "req after submit");

        // ── MCU fetches the request ──
        spi_begin;
        xfer_byte(8'h10, r0);            // REQ_FETCH
        xfer_byte(8'h00, r1);
        xfer_byte(8'h00, r2);            // reqtype
        xfer_byte(8'h00, r3);            // name_len
        xfer_byte(8'h00, r4);            // name[0]
        xfer_byte(8'h00, r5);            // name[1]
        spi_end;
        check(r2, 8'h01, "reqtype LOAD");
        check(r3, 8'd2,  "name_len");
        check(r4, "A",   "name[0]");
        check(r5, "B",   "name[1]");
        check1(req, 1'b1, "req = feed-me after fetch");

        // ── MCU pushes 4 bytes, then EOF ──
        spi_begin;
        xfer_byte(8'h11, r0);            // DATA_PUSH
        xfer_byte(8'd4, r1);             // LEN (informational)
        xfer_byte(8'h11, r1);
        xfer_byte(8'h22, r1);
        xfer_byte(8'h33, r1);
        xfer_byte(8'h44, r1);
        spi_end;

        // CPU: status must show avail, count 4
        @(negedge clk); exp_addr = 16'hFE20; @(negedge clk);
        check(exp_rdata & 8'hC0, 8'h80, "status avail, not done");
        @(negedge clk); exp_addr = 16'hFE22; @(negedge clk);
        check(exp_rdata, 8'd4, "fifo count");

        spi_begin;
        xfer_byte(8'h12, r0);            // XFER_END
        xfer_byte(8'h01, r1);            // flags: EOF
        spi_end;
        check1(req, 1'b0, "req low after EOF");

        // ── CPU drains: 11 22 33 44 then done ──
        cpu_read(4'h1, b); check(b, 8'h11, "data0");
        cpu_read(4'h1, b); check(b, 8'h22, "data1");
        cpu_read(4'h1, b); check(b, 8'h33, "data2");
        cpu_read(4'h1, b); check(b, 8'h44, "data3");
        @(negedge clk); exp_addr = 16'hFE20; @(negedge clk);
        check(exp_rdata & 8'hE0, 8'h40, "status done, no err");

        // ── error flag path ──
        cpu_write(4'h0, 8'h00);          // reset
        cpu_write(4'h1, "Z");
        cpu_write(4'h0, 8'h01);          // submit
        spi_begin; xfer_byte(8'h10, r0); xfer_byte(8'h00, r1);
        xfer_byte(8'h00, r2); xfer_byte(8'h00, r3); spi_end;
        spi_begin; xfer_byte(8'h12, r0); xfer_byte(8'h03, r1); spi_end; // EOF+ERR
        @(negedge clk); exp_addr = 16'hFE20; @(negedge clk);
        check(exp_rdata & 8'hE0, 8'h60, "status done+err");

        // ── ROM window sanity: $FD60 reads the routine's first byte (85) ──
        @(negedge clk); exp_addr = 16'hFD60; @(negedge clk);
        check(exp_rdata, 8'h85, "rom[0] = STA zp");
        @(negedge clk); exp_addr = 16'h1234; @(negedge clk);
        check(exp_rdata, 8'hFF, "bus idle FF");

        // ── BIOS: MODE_SET ──
        check1(bios_mode, 1'b0, "bios_mode idle");
        spi_begin; xfer_byte(8'h20, r0); xfer_byte(8'h01, r1); spi_end;
        check1(bios_mode, 1'b1, "bios_mode set");

        // ── BIOS: TEXT_WRITE two cells at 0x102, autoincrement ──
        spi_begin;
        xfer_byte(8'h21, r0);
        xfer_byte(8'h02, r1); xfer_byte(8'h01, r1);   // cell 0x102
        xfer_byte("H", r1);  xfer_byte(8'h1F, r1);    // 'H' white-on-blue
        xfer_byte("i", r1);  xfer_byte(8'h4E, r1);    // 'i' yellow-on-red
        spi_end;
        check(shadow[11'h102][7:0],  "H",   "tw char0");
        check(shadow[11'h102][15:8], 8'h1F, "tw attr0");
        check(shadow[11'h103][7:0],  "i",   "tw char1");
        check(shadow[11'h103][15:8], 8'h4E, "tw attr1");

        // ── BIOS: TEXT_FILL 1000 cells at 0, with a colliding TEXT_WRITE ──
        sh_writes = 0;
        spi_begin;
        xfer_byte(8'h22, r0);
        xfer_byte(" ", r1);  xfer_byte(8'h17, r1);    // fill char/attr
        xfer_byte(8'h00, r1); xfer_byte(8'h00, r1);   // cell 0
        xfer_byte(8'hE8, r1); xfer_byte(8'h03, r1);   // count 1000
        spi_end;
        // fire a direct write while the fill may still be running
        spi_begin;
        xfer_byte(8'h21, r0);
        xfer_byte(8'hDC, r1); xfer_byte(8'h05, r1);   // cell 1500
        xfer_byte("Z", r1);  xfer_byte(8'h70, r1);
        spi_end;
        repeat (1200) @(posedge clk);                 // let the fill finish
        check(shadow[11'd0][7:0],    " ",   "fill first");
        check(shadow[11'd999][15:8], 8'h17, "fill last attr");
        check(shadow[11'd999][7:0],  " ",   "fill last char");
        check(shadow[11'd1500][7:0], "Z",   "collide write");
        if (sh_writes !== 1001) begin
            $display("FAIL fill+write commit count: got %0d want 1001", sh_writes);
            errors = errors + 1;
        end

        // ── BIOS: BTN_READ ──
        btn = 8'hAB;
        repeat (4) @(posedge clk);
        spi_begin;
        xfer_byte(8'h23, r0); xfer_byte(8'h00, r1);
        xfer_byte(8'h00, r2); xfer_byte(8'h00, r3);
        spi_end;
        check(r2, 8'hAB, "btn value");
        check(r3, 8'h54, "btn inverted");

        // ── BIOS: MODE_SET back to Commodore ──
        spi_begin; xfer_byte(8'h20, r0); xfer_byte(8'h00, r1); spi_end;
        check1(bios_mode, 1'b0, "bios_mode cleared");

        // ── SET_VOLUME: 5 → scale 8, echo + ack framing ──
        // Power-up is MUTE in the shipped (non-GAME_PRG/SIMULATION) build:
        // the MCU unmutes with biosApplyVolume right after configuration, so
        // a board with a dead link fails silent instead of loud.
        check(vol_scale, 5'd0, "vol_scale muted at reset");
        spi_begin;
        xfer_byte(8'h07, r0); xfer_byte(8'h01, r1); xfer_byte(8'd5, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4); xfer_byte(8'h00, r5);
        spi_end;
        check(r0, 8'h5C, "vol magic0");
        check(r3, 8'hA5, "vol pong");
        check(r4, 8'd5,  "vol echo");
        check(r5, 8'hF8, "vol ~cmd");
        check(vol_scale, 5'd8, "vol_scale 5 -> 8");
        spi_begin;
        xfer_byte(8'h07, r0); xfer_byte(8'h01, r1); xfer_byte(8'd10, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4); xfer_byte(8'h00, r5);
        spi_end;
        check(r4, 8'd10, "vol echo 10");
        check(vol_scale, 5'd16, "vol_scale 10 -> unity");

        // ── SET_BRIGHT: same frame shape as SET_VOLUME (0x0C, ~cmd 0xF3) ──
        // Unlike volume this powers up LIT, at the same level the MCU uses
        // for a virgin board (5 -> duty 11): the panel must be readable
        // before the MCU gets its first SET_BRIGHT out.
        check(bright_scale, 7'd11, "bright powers up at level 5");
        spi_begin;
        xfer_byte(8'h0C, r0); xfer_byte(8'h01, r1); xfer_byte(8'd5, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4); xfer_byte(8'h00, r5);
        spi_end;
        check(r0, 8'h5C, "bright magic0");
        check(r3, 8'hA5, "bright pong");
        check(r4, 8'd5,  "bright echo");
        check(r5, 8'hF3, "bright ~cmd");
        check(bright_scale, 7'd11, "bright 5 -> duty 11/64");
        spi_begin;
        xfer_byte(8'h0C, r0); xfer_byte(8'h01, r1); xfer_byte(8'd1, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4); xfer_byte(8'h00, r5);
        spi_end;
        check(bright_scale, 7'd1, "bright 1 -> dimmest duty 1/64");
        spi_begin;                       // out of range clamps to full on
        xfer_byte(8'h0C, r0); xfer_byte(8'h01, r1); xfer_byte(8'd99, r2);
        xfer_byte(8'h00, r3); xfer_byte(8'h00, r4); xfer_byte(8'h00, r5);
        spi_end;
        check(r4, 8'd10, "bright echo clamps to 10");
        check(bright_scale, 7'd64, "bright 99 -> full on");

        // volume must be untouched by all of that (separate registers)
        check(vol_scale, 5'd16, "vol_scale survives SET_BRIGHT");

        if (errors == 0) $display("PASS: all checks OK");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
