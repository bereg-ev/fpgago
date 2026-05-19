/*
 * soc.v — DarkRISCV SoC with framebuffer, RAM, and UART for the labyrinth port.
 *
 * Address map (32-bit, top 8 bits ignored — effective 24-bit space):
 *
 *   0x00000000..0x0000FFFF   ROM        (64 KB, code + rodata)
 *   0x00010000..0x0001FFFF   RAM        (64 KB, stack + globals + heap)
 *   0x00100000..0x001FFFFF   FRAMEBUFFER (1 MB; engine uses 480*272*4 = 522 KB)
 *   0x00200000               UART_STATUS (read: bit0=rxrdy; rest=0)
 *   0x00200004               UART_TX     (write: byte → sim stdout)
 *   0x00200008               UART_RX     (read:  byte from sim input; clears rxrdy)
 *   0x0020000C               FRAME_READY (write: signal "frame complete")
 *
 * The 1 MB framebuffer is just a RAM region the sim harness peeks at every
 * FRAME_READY pulse and uploads to an SDL2 texture.
 *
 * External-memory options (compile-time, mutually exclusive):
 *   default (RAM_BRAM)  — both RAM region and FB stay on-chip.
 *   RAM_PSRAM           — moves the 64 KB RAM region (0x10000) to an
 *                         APS6404L QSPI PSRAM via psram_ram.v.
 *                         ~22-cycle reads, ~38 for partial-strobe stores.
 *                         FB stays on-chip.
 *   RAM_SDRAM           — moves the FRAMEBUFFER (0x100000) to Elpida SDRAM
 *                         via fb_sdram.v (1-row write-back cache).
 *                         Code/data RAM stays on-chip.  See fb_sdram.v for
 *                         the row-cache trade-offs.
 */
`default_nettype none

module soc (
    input  wire        clk,
    input  wire        rst,             // active-low

    // UART (CPU-bus side — sim harness OR toplevel UART module bridges to pins)
    output reg  [7:0]  uart_tx_data,    // byte to send when uart_tx_pulse
    output reg         uart_tx_pulse,   // 1-cycle pulse on CPU SW to UART_TX
    input  wire [7:0]  uart_rx_data,    // byte to deliver to CPU
    input  wire        uart_rx_valid,   // pulse high for 1 cycle to enqueue

    // Frame signaling
    output reg         frame_ready_pulse,

    // Framebuffer scan-out: two interfaces, mutually exclusive at compile time.
    //   Sim path        — toplevel doesn't exist; sim_top peeks `fb` directly
    //                     via the public_flat_rw pragma on the BRAM.  fb_rd_*
    //                     stays in the port list for compatibility.
    //   FPGA path       — under DARK_FPGA, fb_psram drives lcd_pixel_out
    //                     directly from its internal scan-out buffer; the
    //                     toplevel passes lcd_row/col/de from peripheral
    //                     lcd_out.v straight through here.
    input  wire [17:0] fb_rd_addr,
    output reg  [31:0] fb_rd_data,
    input  wire [10:0] lcd_row_in,
    input  wire [10:0] lcd_col_in,
    input  wire        lcd_de_in,
    output wire [15:0] lcd_pixel_out,

    // PSRAM chip pins, always in the port list (FPGA toplevel needs them
    // whenever fb_psram OR psram_ram is wired in; if neither is, they sit
    // disconnected internally).  Sim attaches psram_chip_model under
    // `ifdef SIMULATION further down.
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3,
`ifdef RAM_SDRAM
    // SDRAM chip pins.  Sim-only for now (sdram_model.v inside this module).
    output wire        sd_cke, sd_cs, sd_ras, sd_cas, sd_we,
    output wire [12:0] sd_a,
    inout  wire [15:0] sd_d,
    output wire [1:0]  sd_ba,
    output wire        sd_ldqm, sd_udqm,
`endif

    output wire        fb_dummy_out    // satisfies Verilator's UNUSED filter
);

    // ── CPU ─────────────────────────────────────────────────────────────
    wire [23:0] instr_addr_24;
    wire [31:0] instr_value;
    wire [23:0] data_addr_24;
    wire [31:0] data_in_value;
    wire        data_rd;
    wire [31:0] data_out_value;
    wire [3:0]  data_out_strobe;
    wire        data_wr;

    wire        data_ack;

    cpu_darkrv cpu0 (
        .clk             (clk),
        .rst             (rst),
        .instr_addr      (instr_addr_24),
        .instr_value     (instr_value),
        .data_addr       (data_addr_24),
        .data_in_value   (data_in_value),
        .data_rd         (data_rd),
        .data_out_value  (data_out_value),
        .data_out_strobe (data_out_strobe),
        .data_wr         (data_wr),
        .data_ack        (data_ack)
    );

    wire [31:0] iaddr = {8'b0, instr_addr_24};
    wire [31:0] daddr = {8'b0, data_addr_24};

    // ── ROM (64 KB = 16K × 32-bit) — instruction bus is 1-cycle sync read
    // (matches DarkRISCV's pipeline-fetch path); data bus read is combinational
    // because DarkRISCV's __3STAGE__ samples DATAI in the same cycle DADDR is
    // presented (DDACK=1 ⇒ no stall).
    reg [31:0] rom [0:16383] /*verilator public_flat_rw*/;
    // Path is relative to where the synth/sim tool runs:
    //   sim-desktop  → "../rom.hex"   (set by sim Makefile)
    //   FPGA run.sh  → "rom.hex"      (set by run.sh)
`ifndef ROM_HEX_PATH
 `define ROM_HEX_PATH "../rom.hex"
`endif
    initial $readmemh(`ROM_HEX_PATH, rom);

    reg [31:0] rom_idata;
    reg [31:0] rom_ddata;
    always @(posedge clk) begin
        rom_idata <= rom[iaddr[15:2]];
        rom_ddata <= rom[daddr[15:2]];   // registered for BRAM inference
    end
    assign instr_value = rom_idata;

    // ── RAM (64 KB at 0x00010000-0x0001FFFF) ────────────────────────────
    //   RAM_BRAM   (default) — on-chip BRAM, combinational read.
    //   RAM_PSRAM  — backed by APS6404L QSPI PSRAM via psram_ram.v;
    //                slow (~22+ cycles per access) so CPU stalls via DDACK.
    wire ram_sel = (daddr[23:16] == 8'h01);
    wire [31:0] ram_ddata;
    wire        ram_ack;       // 1 = current ram_sel transaction done

`ifdef RAM_PSRAM
    psram_ram u_ram (
        .clk        (clk),
        .rst        (rst),
        .addr       (data_addr_24),
        .rd         (data_rd && ram_sel),
        .wr         (data_wr && ram_sel),
        .wdata      (data_out_value),
        .wstrobe    (data_out_strobe),
        .rdata      (ram_ddata),
        .ack        (ram_ack),
        .psram_sclk (psram_sclk),
        .psram_ce_n (psram_ce_n),
        .psram_sio0 (psram_sio0),
        .psram_sio1 (psram_sio1),
        .psram_sio2 (psram_sio2),
        .psram_sio3 (psram_sio3)
    );
`else
    // Default: 32 KB BRAM (8K × 32), sync read (for synth/BRAM inference),
    // byte-strobed writes.  Acked one cycle later via the simple-mem FSM
    // below.  Shrunk from 64 KB → 32 KB to fit ECP5-25F.
    reg [31:0] ram [0:8191];
    reg [31:0] ram_ddata_reg;
    always @(posedge clk) begin
        if (data_wr && ram_sel) begin
            if (data_out_strobe[0]) ram[daddr[14:2]][ 7: 0] <= data_out_value[ 7: 0];
            if (data_out_strobe[1]) ram[daddr[14:2]][15: 8] <= data_out_value[15: 8];
            if (data_out_strobe[2]) ram[daddr[14:2]][23:16] <= data_out_value[23:16];
            if (data_out_strobe[3]) ram[daddr[14:2]][31:24] <= data_out_value[31:24];
        end
        ram_ddata_reg <= ram[daddr[14:2]];
    end
    assign ram_ddata = ram_ddata_reg;
    assign ram_ack   = mem_simple_ack;     // shared 1-cycle ack with ROM/FB-bram/MMIO
`endif

    // ── 1-cycle ack FSM for the "simple" memory paths ───────────────────
    // ROM-D, BRAM-RAM, BRAM-FB, MMIO all return data 1 cycle after the
    // access is issued.  The SETTLE state stops level-held rd/wr from
    // re-firing the cycle right after ack (same idea as psram_ram.v).
    //
    // The FSM responds to any rd/wr — when the access happens to go through
    // PSRAM/SDRAM, data_ack picks ram_ack/fb_ack instead and this FSM's
    // pulse is ignored.
    reg       mem_simple_state;        // 0=IDLE, 1=SETTLE
    reg       mem_simple_ack;
    // Gate the simple-mem FSM to regions whose ack actually flows through
    // mem_simple_ack.  PSRAM-RAM (psram_ram.ack) and SDRAM-FB (fb_sdram.ack)
    // each manage their own multi-cycle handshake; if we let mem_simple
    // toggle during one of those stalls, mem_simple_ack would be high mid-
    // stall, and when the CPU advances to the *next* (mem-simple) MMIO SW
    // it would get acked on its first cycle — bypassing the
    // `mem_simple_state == IDLE` gate on the gpu_*_sel write blocks.
    // Symptom: GPU_ROW writes silently dropped right after every PSRAM
    // RAM access (only chess + RAM=psram, never bram).
    wire ram_is_external_acked =
`ifdef RAM_PSRAM
        ram_sel;
`else
        1'b0;
`endif
    wire fb_is_external_acked =
`ifdef RAM_SDRAM
        fb_sel;
`elsif DARK_FPGA
        fb_sel;
`else
        1'b0;
`endif
    wire mem_simple_active = (data_rd || data_wr)
                           && !ram_is_external_acked
                           && !fb_is_external_acked;
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            mem_simple_state <= 1'b0;
            mem_simple_ack   <= 1'b0;
        end else begin
            mem_simple_ack <= 1'b0;
            case (mem_simple_state)
                1'b0: if (mem_simple_active) begin
                          mem_simple_state <= 1'b1;
                          mem_simple_ack   <= 1'b1;
                      end
                1'b1: mem_simple_state <= 1'b0;
            endcase
        end
    end

    // DDACK back to the CPU.
    //   ram_sel  → ram_ack  (BRAM uses simple FSM; PSRAM has its own ack)
    //   fb_sel   → fb_ack   (BRAM uses simple FSM; SDRAM has its own ack)
    //   ROM/MMIO → simple FSM
    assign data_ack = ram_sel ? ram_ack :
                      fb_sel  ? fb_ack  :
                                mem_simple_ack;

    // ── Framebuffer (1 MB region at 0x00100000-0x001FFFFF) ──────────────
    //   default   — 256K × 32-bit on-chip BRAM; combinational read.
    //   RAM_SDRAM — backed by Elpida SDRAM via fb_sdram.v (1-row cache).
    //
    // The `fb` BRAM is ALWAYS instantiated as a write-shadow so the sim
    // harness can `peek` it for the SDL window (Verilator's public_flat_rw
    // can't directly look inside fb_sdram's row buffer).  In RAM_SDRAM
    // mode the CPU READS go through fb_sdram (truth), but writes still
    // also land in the shadow.  Real-HW builds would gate this on a
    // SIMULATION define — out of scope right now.
    wire        fb_sel = (daddr[23:20] == 4'h1);
    wire [31:0] fb_ddata;
    wire        fb_ack;

`ifdef DARK_FPGA
    // FPGA: FB lives in PSRAM via fb_psram (CPU MMIO scanline-flush; LCD
    // scan-out served by prefetch buffer).  No BRAM `fb` here — saves
    // ~120 DP16KDs.
    fb_psram u_fb (
        .clk        (clk),
        .rst        (rst),
        .addr       (data_addr_24),
        .rd         (data_rd && fb_sel),
        .wr         (data_wr && fb_sel),
        .wdata      (data_out_value),
        .wstrobe    (data_out_strobe),
        .rdata      (fb_ddata),
        .ack        (fb_ack),
        .lcd_row    (lcd_row_in),
        .lcd_col    (lcd_col_in),
        .lcd_de     (lcd_de_in),
        .lcd_pixel  (lcd_pixel_out),
        .psram_sclk (psram_sclk),
        .psram_ce_n (psram_ce_n),
        .psram_sio0 (psram_sio0),
        .psram_sio1 (psram_sio1),
        .psram_sio2 (psram_sio2),
        .psram_sio3 (psram_sio3)
    );
    // sim-only peek port is unused on FPGA.
    always @(posedge clk) fb_rd_data <= 32'h0;
`else
    // Sim: 16bpp RGB565 BRAM (SDL peeks `fb`).  Two write paths coexist:
    //   (1) direct writes at FB region 0x100000+y*W*2+x*2  — labyrinth's
    //       raycaster uses this; one halfword per pixel.
    //   (2) MMIO scanline-flush protocol (FB_BUF[col] + GPU_ROW + GPU_CMD)
    //       — matches risc2's HAL so games can share their hal_risc2.c
    //       implementations.
    reg [15:0] fb [0:131071] /*verilator public_flat_rw*/;
    reg [31:0] fb_ddata_reg;

    // GPU MMIO
    wire gpu_buf_sel    = (daddr[23:20] == 4'h3);            // 0x300000-0x3003BC
    wire gpu_row_sel    = (daddr == 32'h0020_0010);
    wire gpu_color_sel  = (daddr == 32'h0020_0014);
    wire gpu_cmd_sel    = (daddr == 32'h0020_0018);
    wire gpu_status_sel = (daddr == 32'h0020_001C);

    reg [15:0] scanline_buf [0:511];
    reg [10:0] gpu_row;
    reg [15:0] gpu_clear_color;
    reg [1:0]  gpu_state;          // 0=IDLE, 1=FLUSH, 2=CLEAR_FB
    reg [17:0] gpu_idx;            // FB write index
    wire       gpu_busy = (gpu_state != 2'd0);

    // Dirty-range tracking — FLUSH must NOT touch columns the HAL didn't
    // write since the previous FLUSH, otherwise stale scanline contents
    // from earlier hal_fill_rect calls bleed onto unrelated rows.
    reg [8:0] dirty_first;
    reg [8:0] dirty_last;
    reg       dirty_any;

    localparam GST_IDLE  = 2'd0;
    localparam GST_FLUSH = 2'd1;
    localparam GST_CLEAR = 2'd2;

    // GPU control register writes + FSM
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            gpu_state       <= GST_IDLE;
            gpu_row         <= 11'd0;
            gpu_clear_color <= 16'h0;
            gpu_idx         <= 18'd0;
            dirty_first     <= 9'd0;
            dirty_last      <= 9'd0;
            dirty_any       <= 1'b0;
        end else begin
            // Register writes — one-shot via mem_simple_state == IDLE
            if (data_wr && gpu_row_sel   && mem_simple_state == 1'b0)
                gpu_row <= data_out_value[10:0];
            if (data_wr && gpu_color_sel && mem_simple_state == 1'b0)
                gpu_clear_color <= data_out_value[15:0];

            // Track dirty range on every FB_BUF write so FLUSH only walks the
            // columns the HAL actually touched since the previous FLUSH.
            if (data_wr && gpu_buf_sel && mem_simple_state == 1'b0
                                       && data_out_strobe == 4'b1111) begin
                dirty_any <= 1'b1;
                if (!dirty_any) begin
                    dirty_first <= daddr[10:2];
                    dirty_last  <= daddr[10:2];
                end else begin
                    if (daddr[10:2] < dirty_first) dirty_first <= daddr[10:2];
                    if (daddr[10:2] > dirty_last)  dirty_last  <= daddr[10:2];
                end
            end

            if (data_wr && gpu_cmd_sel   && mem_simple_state == 1'b0
                                         && gpu_state == GST_IDLE) begin
                case (data_out_value[1:0])
                    2'd1: begin
                        gpu_state <= GST_FLUSH;
                        gpu_idx   <= {9'b0, dirty_first};
                    end
                    2'd2: begin
                        gpu_state <= GST_CLEAR;
                        gpu_idx   <= 18'd0;
                    end
                    default: ;   // 2'd3 SWAP_BUFFERS — no-op (single buffer)
                endcase
            end
            case (gpu_state)
                GST_FLUSH: begin
                    if (!dirty_any || gpu_idx[8:0] >= dirty_last) begin
                        gpu_state   <= GST_IDLE;
                        dirty_any   <= 1'b0;
                        dirty_first <= 9'd0;
                        dirty_last  <= 9'd0;
                    end else begin
                        gpu_idx <= gpu_idx + 18'd1;
                    end
                end
                GST_CLEAR:
                    if (gpu_idx == 18'd130559) gpu_state <= GST_IDLE;
                    else                       gpu_idx   <= gpu_idx + 18'd1;
                default: ;
            endcase
        end
    end

    // Helper: fb byte index for FLUSH = gpu_row * 480 + col
    //   480 = 256 + 128 + 64 + 32 (shift-and-add).
    wire [17:0] flush_row_base =
        ({7'b0, gpu_row} << 8) + ({7'b0, gpu_row} << 7)
      + ({7'b0, gpu_row} << 6) + ({7'b0, gpu_row} << 5);
    wire [17:0] flush_idx = flush_row_base + {9'b0, gpu_idx[8:0]};

    // Scanline buffer + FB writes (multiple sources merged here; sim only).
    always @(posedge clk) begin
        // Direct CPU writes into FB
        if (data_wr && fb_sel) begin
            if (data_out_strobe[1:0] == 2'b11)
                fb[daddr[17:1]] <= data_out_value[15: 0];
            if (data_out_strobe[3:2] == 2'b11)
                fb[daddr[17:1]] <= data_out_value[31:16];
        end
        // CPU writes into scanline buffer via FB_BUF[col]
        if (data_wr && gpu_buf_sel && mem_simple_state == 1'b0
                                   && data_out_strobe == 4'b1111)
            scanline_buf[daddr[10:2]] <= data_out_value[15:0];
        // FSM-driven FB writes
        if (gpu_state == GST_FLUSH && dirty_any)
            fb[flush_idx] <= scanline_buf[gpu_idx[8:0]];
        if (gpu_state == GST_CLEAR)
            fb[gpu_idx]   <= gpu_clear_color;

        // Data-side CPU reads
        fb_ddata_reg <= daddr[1] ? {fb[daddr[17:1]], 16'h0000}
                                 : {16'h0000, fb[daddr[17:1]]};
        fb_rd_data   <= {16'h0000, fb[fb_rd_addr[16:0]]};
    end
    assign lcd_pixel_out = 16'h0;

  `ifdef RAM_SDRAM
    fb_sdram u_fb_sdram (
        .clk      (clk),
        .rst      (rst),
        .addr     (daddr[19:0]),
        .rd       (data_rd && fb_sel),
        .wr       (data_wr && fb_sel),
        .wdata    (data_out_value),
        .wstrobe  (data_out_strobe),
        .rdata    (fb_ddata),
        .ack      (fb_ack),
        .sd_cke   (sd_cke),
        .sd_cs    (sd_cs),
        .sd_ras   (sd_ras),
        .sd_cas   (sd_cas),
        .sd_we    (sd_we),
        .sd_a     (sd_a),
        .sd_d     (sd_d),
        .sd_ba    (sd_ba),
        .sd_ldqm  (sd_ldqm),
        .sd_udqm  (sd_udqm)
    );
  `else
    assign fb_ddata = fb_ddata_reg;
    assign fb_ack   = mem_simple_ack;
  `endif
`endif

    // ── MMIO (UART + frame ready) ───────────────────────────────────────
    reg        rx_ready;
    reg [7:0]  rx_byte;
    wire       uart_status_sel = (daddr == 32'h0020_0000);
    wire       uart_tx_sel     = (daddr == 32'h0020_0004);
    wire       uart_rx_sel     = (daddr == 32'h0020_0008);
    wire       frame_ready_sel = (daddr == 32'h0020_000C);

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            uart_tx_data      <= 8'b0;
            uart_tx_pulse     <= 1'b0;
            frame_ready_pulse <= 1'b0;
            rx_ready          <= 1'b0;
            rx_byte           <= 8'b0;
        end else begin
            uart_tx_pulse     <= 1'b0;
            frame_ready_pulse <= 1'b0;

            // UART_TX, FRAME_READY, and the UART_RX read-clear are all
            // one-shot side-effects of a single CPU access.  data_wr/rd is
            // now level-held for 2 cycles (1-cycle stall via mem_simple_ack),
            // so gate on mem_simple_state==IDLE to fire exactly once at the
            // edge where we transition IDLE→SETTLE.
            if (data_wr && uart_tx_sel && mem_simple_state == 1'b0) begin
                case (data_out_strobe)
                    4'b0001: uart_tx_data <= data_out_value[ 7: 0];
                    4'b0010: uart_tx_data <= data_out_value[15: 8];
                    4'b0100: uart_tx_data <= data_out_value[23:16];
                    4'b1000: uart_tx_data <= data_out_value[31:24];
                    default: uart_tx_data <= data_out_value[ 7: 0];
                endcase
                uart_tx_pulse <= 1'b1;
            end

            if (data_wr && frame_ready_sel && mem_simple_state == 1'b0)
                frame_ready_pulse <= 1'b1;

            // UART_RX: testbench pulses uart_rx_valid + drives uart_rx_data.
            if (uart_rx_valid) begin
                rx_byte  <= uart_rx_data;
                rx_ready <= 1'b1;
            end else if (data_rd && uart_rx_sel && mem_simple_state == 1'b0) begin
                rx_ready <= 1'b0;
            end
        end
    end

    // ── Data read mux ───────────────────────────────────────────────────
    // Combinational: DarkRISCV's 3-stage pipeline expects DATAI in the same
    // cycle that DADDR/DRD are presented.
    assign data_in_value =
        (daddr[23:16] == 8'h00) ? rom_ddata        :   // ROM
        (daddr[23:16] == 8'h01) ? ram_ddata        :   // RAM
        (daddr[23:20] == 4'h1 ) ? fb_ddata         :   // FB direct
        uart_status_sel         ? {31'b0, rx_ready} :
        uart_rx_sel             ? {24'b0, rx_byte} :
`ifndef DARK_FPGA
        gpu_status_sel          ? {31'b0, gpu_busy} :
`endif
                                  32'b0;

`ifndef DARK_FPGA
    // ── LCD_CHAR (sim-only text overlay) ──────────────────────────────
    //   text  RAM at 0x400000-0x4007FF  — 32×16 cells × u32 (char code)
    //   font  RAM at 0x500000-0x500FFF  — 128 glyphs × 16 lines / 2 per word
    //   cfg   regs at 0x200020-0x20002C
    //
    // sim_top.cpp peeks lcd_text + lcd_font + config every frame_ready
    // pulse and overlays the chars on the SDL window.  Both arrays are
    // public_flat_rw; the font is preloaded from peripheral/ibm8x16.hex.
    // Byte-addressed to match risc2's LCD_TEXT(n) macro (no *4 stride).
    // Sized for char-gomoku's 60×17 = 1020 cells; 2048 leaves headroom.
    reg [15:0] lcd_text [0:2047] /*verilator public_flat_rw*/;
    reg [15:0] lcd_font [0:1023] /*verilator public_flat_rw*/;
    initial $readmemh("../../../peripheral/ibm8x16.hex", lcd_font);

    reg [10:0] lcd_char_x    /*verilator public_flat_rw*/;
    reg [10:0] lcd_char_y    /*verilator public_flat_rw*/;
    reg [7:0]  lcd_char_numx /*verilator public_flat_rw*/;
    reg [6:0]  lcd_char_numy /*verilator public_flat_rw*/;
    reg        lcd_char_enabled /*verilator public_flat_rw*/;

    wire lcd_text_sel  = (daddr[23:16] == 8'h40);
    wire lcd_font_sel  = (daddr[23:16] == 8'h50);
    wire lcd_x_sel     = (daddr == 32'h0020_0020);
    wire lcd_y_sel     = (daddr == 32'h0020_0024);
    wire lcd_numx_sel  = (daddr == 32'h0020_0028);
    wire lcd_cfg_sel   = (daddr == 32'h0020_002C);

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            lcd_char_x       <= 11'd3;
            lcd_char_y       <= 11'd0;
            lcd_char_numx    <= 8'd32;
            lcd_char_numy    <= 7'd16;
            lcd_char_enabled <= 1'b0;
        end else if (mem_simple_state == 1'b0) begin
            if (data_wr && lcd_x_sel)
                lcd_char_x <= data_out_value[10:0];
            if (data_wr && lcd_y_sel)
                lcd_char_y <= data_out_value[10:0];
            if (data_wr && lcd_numx_sel)
                lcd_char_numx <= data_out_value[7:0];
            if (data_wr && lcd_cfg_sel) begin
                lcd_char_enabled <= data_out_value[15];
                lcd_char_numy    <= data_out_value[6:0];
            end
        end
    end

    // Byte-addressed writes (HAL stores at LCD_TEXT(n) where n is a byte
    // offset, even though each SW writes the full word).  Only the low
    // halfword of CPU data is kept (char codes are 7-bit).
    always @(posedge clk) begin
        if (data_wr && lcd_text_sel && mem_simple_state == 1'b0)
            lcd_text[daddr[10:0]] <= data_out_value[15:0];
        if (data_wr && lcd_font_sel && mem_simple_state == 1'b0)
            lcd_font[daddr[9:0]]  <= data_out_value[15:0];
    end
`endif

    assign fb_dummy_out = 1'b0;

`ifdef RAM_PSRAM
 `ifdef SIMULATION
    // Sim-only: loop the PSRAM bus back through the behavioral chip model
    // so Verilator actually exercises the QPI protocol round-trip.
    psram_chip_model psram_chip0 (
        .psram_sclk (psram_sclk),
        .psram_ce_n (psram_ce_n),
        .psram_sio0 (psram_sio0),
        .psram_sio1 (psram_sio1),
        .psram_sio2 (psram_sio2),
        .psram_sio3 (psram_sio3)
    );
 `endif
`endif

`ifdef RAM_SDRAM
    // Sim-only: sdram_model.v shadows the real SDRAM device.  Its port
    // signature mirrors the chip side of peripheral/sdram.v.
    // The model handles its own ACTIVATE/READ/WRITE/PRECHARGE protocol
    // on (sd_a / sd_d / sd_ba / sd_we / sd_ras / sd_cas).
    // NB: the model in arch/risc2/sim-desktop is a functional SDRAM stub —
    //     it intercepts the parent's sdram.v signals and emulates memory.
`endif

endmodule

`default_nettype wire
