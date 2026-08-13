`timescale 1ns / 1ps
`include "project.vh"

module soc(
    input clk,
    input rst,
    output reg led1,
    output reg led2,
    input rx,
    output wire tx,
    input [4:0] joy,  // active-low joystick: up,down,left,right,fire
    input [7:0] btn,  // active-low board buttons: up,down,left,right,A,B,C,D
    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk,
    // IEC serial bus (1 = released/HIGH, 0 = pulled/LOW) — for the 1541 floppy
    output wire iec_atn_out,
    output wire iec_clk_out,
    output wire iec_data_out,
    input  wire iec_clk_in,
    input  wire iec_data_in,
    // TED audio, mono signed PCM (the FPGA top serializes it to the
    // board's I2S DAC via peripheral/i2s_pcm.v, the simulator dumps or
    // plays it directly)
    output wire signed [15:0] audio_pcm,
    // MCU⇄FPGA SPI link + fastload engine (common/qspi_slave.v).
    // FPGA: board pins (v2). Sim: driven by the C++ MCU model.
    // Data lanes SD3..SD0 (1-lane legacy: SD0=MOSI in, SD1=MISO out; multi-
    // lane via LINK_CFG).  The top level resolves the pads (SD2 = REQ while
    // SS high; SD3/A9 = IEC DATA while drive_1541).
    input  wire spi_sck,
    input  wire spi_ss,
    input  wire [3:0] spi_sd_in,
    output wire [3:0] spi_sd_out,
    output wire [3:0] spi_sd_oe,
    output wire spi_req,
    output wire drive_1541
`ifdef SIMULATION
    , output wire [15:0] dbg_cpu_addr   // C16 8501 address bus (sim tracing)
`endif
);

    // ================================================================
    //  C16 core
    // ================================================================
    wire c16_hsync, c16_vsync, c16_csync, c16_hblank, c16_vblank;
    wire [3:0] c16_r, c16_g, c16_b;
    wire c16_ras, c16_cas, c16_rw;
    wire [7:0] c16_a, c16_dout;
    wire c16_tick8;
    wire c16_cs0, c16_cs1;
    wire [3:0] c16_rom_sel;
    wire [13:0] c16_rom_addr;
    wire c16_pal;
    wire [5:0] c16_audio_pcm;

    /* TED snd_pcm is the unsigned 6-bit sum of the two volume-scaled
     * channels; scale to a positive-only 16-bit range (silence = 0, no
     * turn-on pop; the DAC path is AC-coupled so the DC offset while a
     * tone plays is harmless — the real TED output has one too).
     * Muted in BIOS mode: the TED free-runs while the CPU is frozen, so
     * whatever tone was playing would otherwise hold forever.
     * vol_scale (0..16, SET_VOLUME over the link) multiplies the master
     * level; 16 = unity, i.e. bit-exact legacy loudness. */
    wire [19:0] vol_prod = {c16_audio_pcm, 9'b0} * vol_scale;
    assign audio_pcm = bios_mode ? 16'd0 : {1'b0, vol_prod[18:4]};

    // RAM interface: reconstruct 16-bit address from multiplexed 8-bit A bus.
    // Latch low byte while RAS is HIGH (mux=1 guaranteed), use high byte at CAS.
    reg [7:0] ram_row;
    wire [15:0] ram_addr = {c16_a, ram_row};
    reg [7:0] ram_dout;

    reg [7:0] ram [0:16383] /* verilator public_flat_rw */;  // C16 has 16KB RAM

`ifdef GAME_PRG
    // PRG baked into the RAM init image (full 16KB game.hex from
    // roms/prg2hex.py, already wrapped to the 14-bit physical space) —
    // costs zero extra BRAM.  The KERNAL boot only clobbers low memory and
    // a few probe bytes (measured with +wrlog); the autorun script
    // restores the clobbered PRG bytes with POKEs before RUN.  See
    // plus4/soc.v for the full story.
    initial $readmemh("../roms/game.hex", ram);
`endif

    wire [13:0] ram_addr14 = ram_addr[13:0];  // 16KB address space

    always @(posedge clk) begin
        if (c16_ras) ram_row <= c16_a;   // latch low byte while RAS high (mux=1)
        if (!c16_cas && !c16_rw)         // write on CAS when RW=0
            ram[ram_addr14] <= c16_dout;
        ram_dout <= ram[ram_addr14];      // always read
    end

    // Data input to C16: just RAM data. ROMs are internal to the C16 module.
    wire [7:0] din_mux = ram_dout;

    // 2-FF synchronizer on the async IEC inputs: the MCU-hosted 1541 drives
    // CLK/DATA on its own clock, and a raw sample caught mid-transition (slow
    // ~10k-pullup edges) desyncs a load at a random spot.  Idle = 1 (released,
    // pulled up), so the flops power up at 1; only ever assigned, so the ecp5
    // rst-constfold trap does not apply.
    reg iec_clk_s1  = 1'b1, iec_clk_s2  = 1'b1;
    reg iec_data_s1 = 1'b1, iec_data_s2 = 1'b1;
    always @(posedge clk) begin
        iec_clk_s1  <= iec_clk_in;   iec_clk_s2  <= iec_clk_s1;
        iec_data_s1 <= iec_data_in;  iec_data_s2 <= iec_data_s1;
    end

    // ── ROM load port (bitstreams/README.md, phases 1-2) ──────────
    // FPGATED's kernal/basic ROMs already carry a write port; it was tied off
    // here.  Under ROMLESS the arrays ship empty and these wires carry the
    // bytes in, written by whoever drives the QSPI link — the MCU on hardware,
    // the C++ MCU model (--rom) in simulation.  The machine is held in RESET
    // until rom_ready, so the 8501 never fetches from an empty KERNAL.
    wire [13:0] rom_dl_addr;
    wire [7:0]  rom_dl_data;
    wire        rom_kernal_we, rom_basic_we, rom_ready;
`ifdef ROMLESS
    // bank 0 = kernal, bank 1 = basic (the MCU sends the same ids)
    assign rom_dl_addr   = ql_rom_addr[13:0];
    assign rom_dl_data   = ql_rom_data;
    assign rom_kernal_we = ql_rom_we && (ql_rom_bank == 3'd0);
    assign rom_basic_we  = ql_rom_we && (ql_rom_bank == 3'd1);
    assign rom_ready     = &ql_rom_valid[1:0];
`else
    assign rom_dl_addr   = 14'd0;
    assign rom_dl_data   = 8'd0;
    assign rom_kernal_we = 1'b0;
    assign rom_basic_we  = 1'b0;
    assign rom_ready     = 1'b1;         // ROMs are baked in — always ready
`endif

    C16 c16_core(
        .CLK28(clk),
        .RESET(~rst | ctrl_reset | ~rom_ready),
        // BIOS mode: WAIT stalls the 8501 mid-instruction (the TED free-runs;
        // its display is muxed away and its audio muted) — releasing WAIT
        // resumes the machine exactly where it stopped.  shot_freeze is the
        // same stall with the machine screen kept on-glass (tear-free grabs).
        .WAIT(bios_mode | shot_freeze),
        .HSYNC(c16_hsync),
        .VSYNC(c16_vsync),
        .CSYNC(c16_csync),
        .HBLANK(c16_hblank),
        .VBLANK(c16_vblank),
        .RED(c16_r),
        .GREEN(c16_g),
        .BLUE(c16_b),
        .RAS(c16_ras),
        .CAS(c16_cas),
        .RW(c16_rw),
        .A(c16_a),
        .DIN(din_mux),
        .DOUT(c16_dout),
        .CS0(c16_cs0),
        .CS1(c16_cs1),
        .ROM_SEL(c16_rom_sel),
        .ROM_ADDR(c16_rom_addr),
        .JOY0(joy & btn_joy1_n),     // port 1 (selected via $FF08 data $FA)
        .JOY1(btn_joy2_n),           // port 2 (selected via $FF08 data $FD)
        .PS2DAT(1'b1),
        .PS2CLK(1'b1),
        .IEC_DATAIN(iec_data_s2),
        .IEC_CLKIN(iec_clk_s2),
        .IEC_DATAOUT(iec_data_out),
        .IEC_CLKOUT(iec_clk_out),
        .IEC_ATNOUT(iec_atn_out),
        .CASS_READ(1'b1),
        .CASS_SENSE(1'b1),
        .SID_TYPE(2'b00),
        .AUDIO_PCM(c16_audio_pcm),
        .dl_addr(rom_dl_addr),
        .dl_data(rom_dl_data),
        .kernal_dl_write(rom_kernal_we),
        .basic_dl_write(rom_basic_we),
        .PAL(c16_pal),
        .RS232_RX(1'b1),  // idle; keyboard uses separate UART
        .RS232_TX(),      // disconnected; tx driven by uart_kb echo
        .RS232_DCD(1'b1),
        .RS232_DSR(1'b1),
        .KBD_ROW(kbd_row),
        .KBD_COL_N(kbd_col_n),
        .TICK8(c16_tick8),
        .EXP_ADDR(exp_addr),
        .EXP_RDATA(exp_rdata),
        .EXP_LADDR(exp_laddr),
        .EXP_WDATA(exp_wdata),
        .EXP_WSTB(exp_wstb),
        .EXP_RSTB(exp_rstb)
    );

    // ================================================================
    //  MCU⇄FPGA link slave + fastload engine
    // ================================================================
    wire [15:0] exp_addr;
    wire [7:0]  exp_rdata;
    wire [3:0]  exp_laddr;
    wire [7:0]  exp_wdata;
    wire        exp_wstb, exp_rstb;
    wire        bios_mode;
    wire [4:0]  vol_scale;
    wire [6:0]  bright_scale;
    wire [1:0]  btn_mode;
    wire        btn_mode_stb;
    wire [10:0] txt_waddr;
    wire [15:0] txt_wdata;
    wire        txt_wen;

    /* screen grab (shot_cap.v, instantiated after the output mux below) */
    wire        shot_arm_stb, shot_dense, shot_pair, shot_armed, shot_ready;
    wire        shot_freeze;
    wire [8:0]  shot_line;
    wire [9:0]  shot_raddr;
    wire [15:0] shot_rdata;
    // ── ROM bank loader link (bitstreams/README.md phase 2) ───────
    // ROMLOAD=1 turns on qspi_slave's ROM_* commands; under !ROMLESS the whole
    // block is a constant and folds away.
`ifdef ROMLESS
    localparam ROMLOAD_P = 1;
`else
    localparam ROMLOAD_P = 0;
`endif
    wire [2:0]  ql_rom_bank;
    wire [15:0] ql_rom_addr;
    wire [7:0]  ql_rom_data;
    wire        ql_rom_we;
    wire [7:0]  ql_rom_valid;

    qspi_slave #(.ROMLOAD(ROMLOAD_P)) qspi0(
        .clk(clk), .rst(rst),
        .spi_sck(spi_sck), .spi_ss(spi_ss), .spi_sd_in(spi_sd_in),
        .spi_sd_out(spi_sd_out), .spi_sd_oe(spi_sd_oe), .req(spi_req),
        .drive_1541(drive_1541),
        .shot_arm_stb(shot_arm_stb), .shot_line(shot_line),
        .shot_dense(shot_dense), .shot_pair(shot_pair),
        .shot_freeze(shot_freeze), .shot_armed(shot_armed),
        .shot_ready(shot_ready), .shot_raddr(shot_raddr),
        .shot_rdata(shot_rdata),
        .btn(btn), .bios_mode(bios_mode), .vol_scale(vol_scale),
        .bright_scale(bright_scale),
        .btn_mode(btn_mode), .btn_mode_stb(btn_mode_stb),
        .txt_waddr(txt_waddr), .txt_wdata(txt_wdata), .txt_wen(txt_wen),
        .exp_addr(exp_addr), .exp_rdata(exp_rdata),
        .exp_laddr(exp_laddr), .exp_wdata(exp_wdata),
        .exp_wstb(exp_wstb), .exp_rstb(exp_rstb),
        .fdd_request(2'b00), .fdd_mgmt_rdata(16'h0000),
        .fdd_mgmt_addr(), .fdd_mgmt_wdata(), .fdd_mgmt_write(),
        .fdd_mgmt_read(), .fdd_reset_stb(), .fdd_turbo(),
        .rom_bank(ql_rom_bank), .rom_addr(ql_rom_addr),
        .rom_data(ql_rom_data), .rom_we(ql_rom_we),
        .rom_valid(ql_rom_valid),
        /* no fabric 1541 here: FD_STATUS reads all-zero (tied, never
         * left open -- netlist-sim-undriven-wires) */
        .fd_stat(8'h00), .fd_done(8'h00)
    );

`ifdef SIMULATION
    assign dbg_cpu_addr = c16_core.cpu_addr;   // hierarchical ref (like Plus/4)
`endif

    // ================================================================
    //  Video
    // ================================================================
    wire [15:0] c16_rgb565 = {c16_r, c16_r[3], c16_g, c16_g[3:2], c16_b, c16_b[3]};
    // Backlight: PWM-dimmable from the BIOS (SET_BRIGHT over the link).
    // Powers up full on; R2 pulls the pin low while the fabric is
    // unconfigured, so an unprogrammed board stays dark.
    lcd_backlight bl0(.clk(clk), .scale(bright_scale), .pwm(lcd_pwm));
    assign lcd_clk = clk;

    // Machine-mode LCD signals (muxed against the BIOS text screen below)
    wire m_hs, m_vs, m_de;
    reg [15:0] m_data;

`ifdef SIMULATION
    // Simulation: capture into framebuffer, read back via lcd_out timing
    reg [15:0] framebuf [0:512*312-1];
    reg [8:0] fb_x, fb_y;
    reg c16_hsync_prev, c16_vsync_prev;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            fb_x <= 0; fb_y <= 0;
            c16_hsync_prev <= 1; c16_vsync_prev <= 1;
        end else begin
            c16_hsync_prev <= c16_hsync;
            c16_vsync_prev <= c16_vsync;
            if (!c16_hblank && !c16_vblank && c16_tick8) begin
                if (fb_x < 400 && fb_y < 312)
                    framebuf[{fb_y, fb_x}] <= c16_rgb565;
                fb_x <= fb_x + 1;
            end
            if (c16_hblank && !c16_hsync_prev && c16_hsync) begin
                fb_x <= 0;
                fb_y <= fb_y + 1;
            end
            if (!c16_vsync && c16_vsync_prev)
                fb_y <= 0;
        end

    wire [10:0] lcd_col, lcd_row;
    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(m_hs), .lcd_vsync(m_vs), .lcd_de(m_de),
        .row(lcd_row), .col(lcd_col)
    );
    wire [8:0] fb_rx = lcd_col[8:0] - 9'd52;
    wire [8:0] fb_ry = lcd_row[8:0] + 9'd20;
    wire in_fb = (fb_rx < 400) && (fb_ry < 312);
    always @(posedge clk or negedge rst)
        if (!rst) m_data <= 0;
        else if (m_de) m_data <= in_fb ? framebuf[{fb_ry, fb_rx}] : 16'h0000;

`else
    // FPGA: line buffer with LCD timing locked to TED sync.
    // One DP16KD BRAM (1024x16, ping-pong halves).
    // TED writes at tick8 rate; LCD reads back twice per TED line (line doubling).
    // LCD hsync/vsync derived from TED sync → no rolling.
    reg [15:0] lbram [0:1023];
    reg [15:0] lbram_rd;
    reg lb_half;
    reg [8:0] lb_wr_x;
    reg fpga_hs_prev, fpga_vs_prev;

    // Write port: TED fills line buffer
    always @(posedge clk)
        if (!c16_hblank && !c16_vblank && c16_tick8 && lb_wr_x < 400)
            lbram[{lb_half, lb_wr_x}] <= c16_rgb565;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            lb_wr_x <= 0; lb_half <= 0; fpga_hs_prev <= 1; fpga_vs_prev <= 1;
        end else begin
            fpga_hs_prev <= c16_hsync;
            fpga_vs_prev <= c16_vsync;
            if (!c16_hblank && !c16_vblank && c16_tick8)
                lb_wr_x <= lb_wr_x + 1;
            if (!fpga_hs_prev && c16_hsync) begin
                lb_wr_x <= 0;
                lb_half <= ~lb_half;
            end
        end

    // LCD timing generator locked to TED, 2x zoom for the 800x480 panel.
    //
    // The TED runs at PAL rate (~1824-clk line, ~15.6 kHz, 312 lines, ~49.5 Hz).
    // The 800x480 panel needs a ~31 kHz line rate to lock its sync, so we emit
    // TWO 912-clk LCD sub-lines per TED line (vertical line-doubling) and double
    // each pixel horizontally.  400x272 source -> 800x544; the panel shows the
    // top 800x480 (we drive exactly 480 active lines = 240 TED lines).
    //
    // NOTE: this assumes the TED line is ~1824 clocks (= 2 sub-lines).  If it
    // drifts, the sub-line is re-aligned every TED hsync, so at worst the last
    // (blanked) clocks of a sub-line are trimmed — no visible effect.
    localparam LCD_HTOTAL  = 912;   // one LCD sub-line = TED line / 2
    localparam LCD_HACTIVE = 800;   // 400 source px, pixel-doubled
    localparam LCD_HFP     = 16;    // front porch
    localparam LCD_HPW     = 48;    // hsync pulse width
    // Vertically center the 240-line crop in the TED active window (~20..292):
    // trim 16 lines off each end instead of 32 off the bottom, so the picture
    // sits centered in Y with equal top/bottom border.
    localparam LCD_VSTART  = 36;    // first shown TED line  (20 + 16)
    localparam LCD_VEND    = 276;   // last+1 shown TED line  (292 - 16); 240 x2 = 480

    reg [10:0] lh_cnt;         // LCD sub-line horizontal counter (0..911)
    reg [8:0] ted_line;        // TED line counter (for vertical crop)
    reg lcd_hs_r, lcd_vs_r, lcd_de_r;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            lh_cnt <= 0; ted_line <= 0;
            lcd_hs_r <= 1; lcd_vs_r <= 1; lcd_de_r <= 0;
        end else begin
            // Sub-line counter: wraps every 912 clks (2 per TED line),
            // re-aligned on each TED hsync.
            if (!fpga_hs_prev && c16_hsync)
                lh_cnt <= 0;
            else if (lh_cnt == LCD_HTOTAL - 1)
                lh_cnt <= 0;
            else
                lh_cnt <= lh_cnt + 1;

            // TED line counter for vertical cropping (one per TED line; each
            // TED line spans both sub-lines, so DE stays active across the
            // pair → vertical doubling happens automatically).
            if (!fpga_hs_prev && c16_hsync)
                ted_line <= ted_line + 1;
            if (!c16_vsync && fpga_vs_prev)
                ted_line <= 0;

            // LCD signals
            lcd_de_r <= (lh_cnt < LCD_HACTIVE) &&
                        (ted_line >= LCD_VSTART) && (ted_line < LCD_VEND);
            lcd_hs_r <= !((lh_cnt >= LCD_HACTIVE + LCD_HFP) &&
                          (lh_cnt < LCD_HACTIVE + LCD_HFP + LCD_HPW));
            lcd_vs_r <= c16_vsync;
        end

    assign m_hs = lcd_hs_r;
    assign m_vs = lcd_vs_r;
    assign m_de = lcd_de_r;

    // Read port: pixel-double — source column = output column / 2 (0..399).
    wire [8:0] rd_idx = lh_cnt[9:1];
    always @(posedge clk)
        lbram_rd <= lbram[{~lb_half, rd_idx}];

    always @(posedge clk or negedge rst)
        if (!rst) m_data <= 0;
        else m_data <= lcd_de_r ? ((rd_idx < 400) ? lbram_rd : 16'h0000) : 16'h0000;
`endif

    // ================================================================
    //  BIOS text screen (MCU-driven over the QSPI link) + output mux
    // ================================================================
    wire b_hs, b_vs, b_de;
    wire [15:0] b_data;
    bios_text #(.HTOTAL(912)) bios0(     // 912-clk sub-line: the panel's
        .clk(clk), .rst(rst),            // proven line rate on this clock
        .wr_addr(txt_waddr), .wr_data(txt_wdata), .wr_en(txt_wen),
        .lcd_hsync(b_hs), .lcd_vsync(b_vs), .lcd_de(b_de), .lcd_data(b_data)
    );

    // Switch sources at the OUTGOING source's vsync edge (inside vertical
    // blanking) so the panel never sees a torn frame.  The machine keeps
    // producing sync while frozen (the TED free-runs), so an edge always
    // arrives within one frame.
    reg bios_active, m_vs_p, b_vs_p;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            bios_active <= 0; m_vs_p <= 1; b_vs_p <= 1;
        end else begin
            m_vs_p <= m_vs;
            b_vs_p <= b_vs;
            if (bios_mode && !bios_active && (m_vs != m_vs_p))
                bios_active <= 1;
            else if (!bios_mode && bios_active && (b_vs != b_vs_p))
                bios_active <= 0;
        end

    assign lcd_hsync = bios_active ? b_hs   : m_hs;
    assign lcd_vsync = bios_active ? b_vs   : m_vs;
    assign lcd_de    = bios_active ? b_de   : m_de;
    assign lcd_data  = bios_active ? b_data : m_data;

    /* ── screen grab: one-line capture of the FINAL panel stream (post-mux,
     *    so machine and BIOS screens both capture; qspi_slave SHOT commands
     *    stream the line buffer to the MCU → USB hostlink → desktop). ──── */
    shot_cap shot0(
        .clk(clk), .rst(rst),
        .px_data(lcd_data), .px_de(lcd_de), .px_vs(lcd_vsync),
        .arm_stb(shot_arm_stb), .arm_line(shot_line), .arm_dense(shot_dense),
        .arm_pair(shot_pair),
        .armed(shot_armed), .ready(shot_ready),
        .raddr(shot_raddr), .rdata(shot_rdata)
    );

    // ================================================================
    //  Keyboard: UART PETSCII → shared typer → 8x8 matrix (kbus)
    //  (see retro-arch/common/kbd_typer.v for the protocol)
    // ================================================================
    wire uart_rx_raw;
    wire [7:0] uart_rx_data;
    wire uart_kb_tx;
    reg [7:0] echo_data;
    reg echo_en;
    uart uart_kb(
        .clk(clk), .rst(rst),
        .rx(rx), .rxdata(uart_rx_data), .rxen(uart_rx_raw),
        .txdata(echo_data), .txen(echo_en), .tx(uart_kb_tx), .txbusy()
    );
    // Detect any rxen toggle (rxen XORs on each received byte)
    reg uart_rx_prev;
    always @(posedge clk) uart_rx_prev <= uart_rx_raw;
    wire uart_rx_valid = uart_rx_raw ^ uart_rx_prev;

    // Echo received byte back via UART TX (debug — remove when keyboard works)
    assign tx = uart_kb_tx;
    always @(posedge clk or negedge rst)
        if (!rst) echo_en <= 0;
        else if (uart_rx_valid) begin
            echo_data <= uart_rx_data;
            echo_en <= ~echo_en;
        end

    wire [7:0] map_code;
    wire map_valid, map_shift, map_cbm, map_ctrl, map_prefix;
    wire [5:0] map_key;
    c16_kbd_map kbd_map(
        .code(map_code), .valid(map_valid), .shift(map_shift),
        .cbm(map_cbm), .ctrl(map_ctrl), .prefix(map_prefix), .key(map_key)
    );


    // ── UART control bytes (never typed) ─────────────────────────────
    //   $02 = machine reset (pulses the core's reset stretcher; also sent
    //         by the MCU on a long U21 press)
    //   $04 = RUN/STOP+RESTORE — the 264 machines have no RESTORE/NMI, so
    //         it aliases to plain RUN/STOP ($03, handled by the kbd map)
    wire uart_is_ctrl = (uart_rx_data == 8'h02);
    wire [7:0] uart_kbd_byte = (uart_rx_data == 8'h04) ? 8'h03 : uart_rx_data;
    reg [15:0] ctrl_rst_cnt;
    wire ctrl_reset = (ctrl_rst_cnt != 0);
    always @(posedge clk or negedge rst)
        if (!rst) ctrl_rst_cnt <= 0;
        else if (uart_rx_valid && uart_is_ctrl) ctrl_rst_cnt <= 16'hFFFF; // ~2.3ms
        else if (ctrl_rst_cnt != 0) ctrl_rst_cnt <= ctrl_rst_cnt - 1'b1;

`ifdef GAME_PRG
    // Hands-free start: baked autorun script (restore POKEs + RUN) typed
    // by hardware after boot — no host/MCU needed on the board.
    wire [7:0] boot_key;
    wire       boot_key_valid;
    boot_typer #(.CLK_HZ(28_375_000)) boot_typer0(
        .clk(clk), .rst(rst),
        .key_data(boot_key), .key_valid(boot_key_valid)
    );
    wire [7:0] typer_rx_data  = boot_key_valid ? boot_key : uart_kbd_byte;
    wire       typer_rx_valid = (uart_rx_valid & ~uart_is_ctrl) | boot_key_valid;
`else
    wire [7:0] typer_rx_data  = uart_kbd_byte;
    wire       typer_rx_valid = uart_rx_valid & ~uart_is_ctrl;
`endif

    wire [63:0] typer_matrix;
    kbd_typer #(.CLK_HZ(28_375_000)) kbd_typer0(
        .clk(clk), .rst(rst),
        .rx_data(typer_rx_data), .rx_valid(typer_rx_valid),
        .map_code(map_code), .map_valid(map_valid),
        .map_shift(map_shift), .map_cbm(map_cbm), .map_ctrl(map_ctrl),
        .map_prefix(map_prefix), .map_key(map_key),
        .shift_key({3'd1, 3'd7}),        // SHIFT
        .cbm_key  ({3'd7, 3'd5}),        // C=
        .ctrl_key ({3'd7, 3'd2}),        // CTRL
        .matrix(typer_matrix)
    );

    // Board buttons: TEXT mode holds the C16 cursor keys + RETURN/SPACE,
    // JOY modes drive joystick port 1 or 2 (BIOS-selected via SET_BTNMODE,
    // A+B chord toggles TEXT <-> last joystick port).
    wire [63:0] btn_matrix;
    wire [4:0] btn_joy1_n, btn_joy2_n;
    wire [1:0] kbd_btn_mode;
    kbd_buttons #(.CLK_HZ(28_375_000),
        .DEFAULT_MODE(2'd1),        // 264 titles default to port 1
        .KEY_UP   ({3'd5, 3'd3}),
        .KEY_DOWN ({3'd5, 3'd0}),
        .KEY_LEFT ({3'd6, 3'd0}),
        .KEY_RIGHT({3'd6, 3'd3}),
        .KEY_BTNA ({3'd0, 3'd1}),   // RETURN
        .KEY_BTNB ({3'd7, 3'd4}),   // SPACE
        .KEY_F1   ({3'd0, 3'd4}),   // btn C = F1 (dedicated key, every mode)
        .KEY_F2   ({3'd0, 3'd5})    // btn D = F2
    ) kbd_buttons0(
        // BIOS mode: buttons go to the MCU (BTN_READ over the link), not
        // to the frozen machine
        .clk(clk), .rst(rst), .btn_n(bios_mode ? 8'hFF : btn),
        .mode_set(btn_mode_stb), .mode_in(btn_mode), .mode(kbd_btn_mode),
        .joy1_blank(1'b0),      // no scan gating here: BOTH mode mirrors raw
        .joy1_n(btn_joy1_n), .joy2_n(btn_joy2_n), .matrix(btn_matrix)
    );

    wire [7:0] kbd_row;
    wire [7:0] kbd_col_n;
    kbd_matrix kbd_matrix0(
        .matrix(typer_matrix | btn_matrix),
        .row_n(kbd_row), .col_n(kbd_col_n)
    );

    // ================================================================
    //  Misc
    // ================================================================
`ifdef SIMULATION
    // RAM write logger for boot-clobber analysis (+wrlog on the sim command
    // line): logs every RAM write as "<cycle> <addr>" (full reconstructed
    // 16-bit CPU address; physical = addr & $3FFF).  See plus4/soc.v.
    integer wrlog_fd;
    reg wrlog_en;
    initial begin
        wrlog_fd = 0; wrlog_en = 0;
        if ($test$plusargs("wrlog")) begin
            wrlog_fd = $fopen("ram_writes.log", "w");
            wrlog_en = 1;
        end
    end
    always @(posedge clk)
        if (wrlog_en && !c16_cas && !c16_rw)
            $fwrite(wrlog_fd, "%0d %04x\n", dbg_cycle, ram_addr);

    reg [31:0] dbg_cycle;
    reg c16_vs_prev;
    reg [31:0] frame_count;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            led1 <= 0; led2 <= 0; dbg_cycle <= 0;
            c16_vs_prev <= 1; frame_count <= 0;
        end else begin
            dbg_cycle <= dbg_cycle + 1;
            c16_vs_prev <= c16_vsync;
            if (!c16_vsync && c16_vs_prev)
                frame_count <= frame_count + 1;
            // Dump framebuffer pixels for first "M" (chars 3-4) and second "M" (chars 5-6)
            // in "COMMODORE": C=1, O=2, M=3, M=4, O=5, D=6...
            // Each char ~8 pixels. Line 1 starts at fb_y ~offset.
            if (dbg_cycle == 25000000) begin
                // Find text: dump rows 0,5,10,15,20,25 — first 100 pixels as binary (dark=1, light=0)
                // Find first dark pixel and dump its context
            end
        end
`else
    // FPGA debug: led1=UART rx activity, led2=TEXT(off)/JOY(on) mode
    always @(posedge clk or negedge rst)
        if (!rst) begin led1 <= 0; led2 <= 0; end
        else begin
            if (uart_rx_valid) led1 <= ~led1;
            led2 <= (kbd_btn_mode != 2'd0);
        end
`endif

endmodule
