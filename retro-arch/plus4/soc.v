`timescale 1ns / 1ps
`include "project.vh"

// IEC ports exist in BOTH the sim (the C++ 1541 model drives them) and the
// real-1541 FPGA build (-DIEC1541, riding the reclaimed config pins).  Verilog
// has no `ifdef OR, so fold the two triggers into one helper macro.
`ifdef SIMULATION
  `define PLUS4_IEC_PORTS
`endif
`ifdef IEC1541
  `define PLUS4_IEC_PORTS
`endif

// Plus/4 SoC — rebuilt on top of the working C16 core module.
// The C16 and Plus/4 share the same TED 8360 chip, same 8501 CPU,
// and same keyboard matrix. Only the ROM contents differ.
// Plus/4 has 64KB RAM and function ROMs (3+1 software).

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
    // TED audio, mono signed PCM (FPGA top → peripheral/i2s_pcm.v →
    // board I2S DAC; sim dumps/plays it directly)
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
`ifdef PLUS4_IEC_PORTS
    ,
    // IEC bus (release semantics: 1 = released/HIGH, 0 = pulled/LOW)
    output wire iec_atn_out,
    output wire iec_clk_out,
    output wire iec_data_out,
    input  wire iec_clk_in,
    input  wire iec_data_in
`endif
`ifdef SIMULATION
    , output wire [15:0] dbg_cpu_addr   // Plus/4 8501 address bus (sim tracing)
`endif
);

    // ================================================================
    //  C16 core (shared TED+CPU+keyboard module, works for Plus/4 too)
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

    /* TED snd_pcm → positive-only signed 16-bit (same scaling and
     * rationale as c16/soc.v: silence = 0, AC-coupled DAC path).
     * Muted in BIOS mode: the TED free-runs while the CPU is frozen.
     * vol_scale (0..16, SET_VOLUME over the link): 16 = unity. */
    wire [19:0] vol_prod = {c16_audio_pcm, 9'b0} * vol_scale;
    assign audio_pcm = bios_mode ? 16'd0 : {1'b0, vol_prod[18:4]};

    // RAM interface: reconstruct 16-bit address from multiplexed 8-bit A bus.
    reg [7:0] ram_row;
    wire [15:0] ram_addr = {c16_a, ram_row};
    reg [7:0] ram_dout;

    reg [7:0] ram [0:65535] /* verilator public_flat_rw */;  // Plus/4 has 64KB RAM

`ifdef GAME_PRG
    // PRG baked into the RAM init image (full 64KB game.hex from
    // roms/prg2hex.py) — costs zero extra BRAM, works in sim and in the
    // bitstream alike.  The KERNAL boot only clobbers low memory
    // ($0000-$0FE7), the BASIC NEW marker at $1000-$1002, one RAM-size
    // probe byte at $7FFF and the KERNAL pages at $FCF9+/$FFF6+ (measured
    // with +wrlog); the autorun script restores the few clobbered PRG
    // bytes with POKEs before RUN, so this also survives a board reset
    // (BRAM keeps its contents, boot_typer replays the script).
    initial $readmemh("../roms/game.hex", ram);
`endif

    always @(posedge clk) begin
        if (c16_ras) ram_row <= c16_a;
        if (!c16_cas && !c16_rw)
            ram[ram_addr] <= c16_dout;
        ram_dout <= ram[ram_addr];
    end

    wire [7:0] din_mux = ram_dout;

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

`ifdef PLUS4_IEC_PORTS
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
`endif

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

`ifdef SIMULATION
    C16 #(.HAS_FUNCTION_ROM(1)) c16_core(
`else
    // FPGA: no function ROMs — ECP5-25K has only 56 DP16KD blocks
    // 64KB RAM (32) + basic (8) + kernal (8) + TED/linebuf (4) = 52 ≤ 56
    C16 #(.HAS_FUNCTION_ROM(0)) c16_core(
`endif
        .CLK28(clk),
        .RESET(~rst | ctrl_reset | ~rom_ready),
        // BIOS mode: WAIT stalls the 8501 mid-instruction (TED free-runs,
        // its display muxed away, audio muted); release = exact resume.
        // shot_freeze = same stall, machine screen kept on-glass (grabs)
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
`ifdef PLUS4_IEC_PORTS
        .IEC_DATAIN(iec_data_s2),
        .IEC_CLKIN(iec_clk_s2),
        .IEC_DATAOUT(iec_data_out),
        .IEC_CLKOUT(iec_clk_out),
        .IEC_ATNOUT(iec_atn_out),
`else
        .IEC_DATAIN(1'b1),
        .IEC_CLKIN(1'b1),
`endif
        .CASS_READ(1'b1),
        .CASS_SENSE(1'b1),
        .SID_TYPE(2'b00),
        .AUDIO_PCM(c16_audio_pcm),
        .dl_addr(rom_dl_addr),
        .dl_data(rom_dl_data),
        .kernal_dl_write(rom_kernal_we),
        .basic_dl_write(rom_basic_we),
        .PAL(c16_pal),
        .RS232_RX(1'b1),
        .RS232_TX(),
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

`ifdef SIMULATION
    assign dbg_cpu_addr = c16_core.cpu_addr;   // hierarchical ref (like c16_core.mux)
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
    // FPGA: line buffer with LCD timing locked to TED sync — verbatim copy
    // of the board-proven c16/soc.v block (2× pixel/line doubling for the
    // 800x480 panel; the old plus4 block drove 480-wide single-scan timing,
    // which showed a quarter-size picture and then lost the panel).
    // One DP16KD BRAM (1024x16, ping-pong halves).
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

    // LCD timing generator locked to TED, 2x zoom for the 800x480 panel:
    // two 912-clk LCD sub-lines per ~1824-clk TED line (vertical doubling),
    // each pixel doubled horizontally; 240 TED lines -> 480 panel lines.
    localparam LCD_HTOTAL  = 912;   // one LCD sub-line = TED line / 2
    localparam LCD_HACTIVE = 800;   // 400 source px, pixel-doubled
    localparam LCD_HFP     = 16;    // front porch
    localparam LCD_HPW     = 48;    // hsync pulse width
    localparam LCD_VSTART  = 36;    // first shown TED line  (20 + 16)
    localparam LCD_VEND    = 276;   // last+1 shown TED line (292 - 16)

    reg [10:0] lh_cnt;         // LCD sub-line horizontal counter (0..911)
    reg [8:0] ted_line;        // TED line counter (for vertical crop)
    reg lcd_hs_r, lcd_vs_r, lcd_de_r;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            lh_cnt <= 0; ted_line <= 0;
            lcd_hs_r <= 1; lcd_vs_r <= 1; lcd_de_r <= 0;
        end else begin
            if (!fpga_hs_prev && c16_hsync)
                lh_cnt <= 0;
            else if (lh_cnt == LCD_HTOTAL - 1)
                lh_cnt <= 0;
            else
                lh_cnt <= lh_cnt + 1;

            if (!fpga_hs_prev && c16_hsync)
                ted_line <= ted_line + 1;
            if (!c16_vsync && fpga_vs_prev)
                ted_line <= 0;

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
    //  Keyboard: UART PETSCII -> shared typer -> 8x8 matrix (kbus)
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
    reg uart_rx_prev;
    always @(posedge clk) uart_rx_prev <= uart_rx_raw;
    wire uart_rx_valid = uart_rx_raw ^ uart_rx_prev;

    // Echo received byte back via UART TX
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

    // Board buttons: TEXT mode holds the Plus/4 cursor keys + RETURN/SPACE,
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
    // line): logs every RAM write as "<cycle> <addr>" to ram_writes.log.
    // Used to find which addresses the KERNAL clobbers between reset and
    // READY, i.e. which part of a preloaded PRG needs a BRAM restore copy.
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
        end
`else
    always @(posedge clk or negedge rst)
        if (!rst) begin led1 <= 0; led2 <= 0; end
        else begin
            if (uart_rx_valid) led1 <= ~led1;
            led2 <= (kbd_btn_mode != 2'd0);   // LED2: TEXT(off)/JOY(on) mode
        end
`endif

endmodule
