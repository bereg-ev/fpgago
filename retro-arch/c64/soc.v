/*
 * soc.v — Commodore 64 System-on-Chip (cycle-exact VIC-II)
 *
 * Architecture: the Kawari VIC-II is the CLOCK MASTER.  The SoC clock is
 * dot4x (PAL 31.527955 MHz) and the VIC divides it into the 0.985248 MHz
 * phi clock (clk_phi output).  Everything CPU/CIA side advances on
 * one-dot4x-tick pulses derived from phi edges:
 *
 *   phi2_p — first dot4x tick of the phi HIGH phase (CPU RDY / advance)
 *   phi2_n — first dot4x tick of the phi LOW phase  (write commit — this
 *            is the real 6510 write instant: end of the phi high phase)
 *
 * Badline / sprite DMA stalls: the VIC's BA output gates CPU RDY on read
 * cycles only (cpu_rdy = phi2_p && (BA || WE)).  That reproduces the real
 * 6510 rule — the CPU halts on the first READ cycle while BA is low but
 * completes pending writes — because a 6502 never issues more than three
 * consecutive write cycles.  AEC needs no CPU-side handling in this flat
 * bus model (RAM/color/char ROM have separate read paths for VIC and CPU).
 *
 * VIC bus master fetches (c/g/p/s accesses) are fed combinationally from
 * the exported full 14-bit fetch address (vic_addr_full, a local Kawari
 * mod in addressgen): dbi = {color nibble, ram/char-ROM byte}, held valid
 * across the half cycle exactly like the bus in upstream's own simulator.
 * The VIC samples it at its internal DATA_DAV point.
 *
 * With RDY on the phi FALLING edge, all peripherals run on the live CPU
 * bus (no transaction latches): the address is held [phi low, phi high],
 * the VIC/CIAs see ce/cs during the high phase, reads are sampled and
 * writes committed at the end of the high phase — the real 6510 bus
 * lifecycle, keeping register writes in cycle-phase with the raster.
 *
 * Cores: 6510 = Arlet 6502 + I/O-port wrapper; CIA = MiSTer mos6526;
 * VIC-II = vicii-kawari (GPLv3, randyrossi/vicii-kawari) with small
 * clearly-marked local mods (flat-bus taps, sim chip select).
 *
 * Memory map (default bank: LORAM=1, HIRAM=1, CHAREN=1):
 *   $0000-$0001  6510 I/O port (DDR, Port)
 *   $0002-$9FFF  RAM
 *   $A000-$BFFF  BASIC ROM
 *   $C000-$CFFF  RAM
 *   $D000-$D3FF  VIC-II (Kawari, PAL 6569R3)
 *   $D400-$D7FF  SID (MiSTer/reDIP-SID core, 6581 mode, mono PCM out)
 *   $D800-$DBFF  Color RAM
 *   $DC00-$DCFF  CIA1 (keyboard, joystick)
 *   $DD00-$DDFF  CIA2 (serial, NMI, VIC bank)
 *   $E000-$FFFF  KERNAL ROM
 */

`include "project.vh"

/* Either feature puts the APS6404L in the build; both put it there TOGETHER
 * (one chip, one engine, psram_hub.v between).  Verilog has no `ifdef A||B`,
 * so this stands in for it; undef'd at the end of the file so it cannot leak
 * into whatever yosys reads next. */
`ifdef EASYFLASH
`define C64_PSRAM
`endif
`ifdef FDRIVE
`ifndef C64_PSRAM
`define C64_PSRAM
`endif
`endif

module soc(
    input        clk,   // dot4x: PAL 31.527955 MHz
    input        rst,
    input        rx,
    output       tx,
    output       led1,  // CPU-RDY heartbeat ~1.8 Hz
    output       led2,  // VIC-frame heartbeat ~1.5 Hz
    input  [4:0] joy,  // active-low joystick 2: up,down,left,right,fire
    input  [7:0] btn,  // active-low board buttons: up,down,left,right,A,B,C,D
    output [15:0] lcd_data,
    output       lcd_pwm,     // backlight enable, PWM-dimmed (SET_BRIGHT)
    output       lcd_de,
    output       lcd_vsync,
    output       lcd_hsync,
    // IEC serial bus (1 = released/HIGH, 0 = pulled/LOW) — for the 1541 floppy
    output wire  iec_atn_out,
    output wire  iec_clk_out,
    output wire  iec_data_out,
    input  wire  iec_clk_in,
    input  wire  iec_data_in,
    // SID audio, mono signed PCM (one sample per phi cycle ≈ 0.985 MHz);
    // the FPGA top serializes it to the board's I2S DAC, the simulator
    // dumps/plays it directly.
    output wire signed [15:0] audio_pcm,
    // MCU⇄FPGA SPI link + fastload engine (common/qspi_slave.v, C64 mode).
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
`ifndef SIMULATION
`ifdef FDRIVE
    // QPI PSRAM pads + psram_fast's fast clock (fabric-1541 ROM + GCR;
    // in simulation the behavioural engine replaces all of this)
    , input  wire psram_clk,
    output wire psram_sclk,
    output wire psram_ce_n,
    inout  wire psram_sio0,
    inout  wire psram_sio1,
    inout  wire psram_sio2,
    inout  wire psram_sio3
`elsif EASYFLASH
    // QSPI PSRAM pads (EasyFlash cart image; in simulation the pads stay
    // internal and psram_chip_model attaches below)
    , output wire psram_sclk,
    output wire psram_ce_n,
    inout  wire psram_sio0,
    inout  wire psram_sio1,
    inout  wire psram_sio2,
    inout  wire psram_sio3
`endif
`endif
`ifdef SIMULATION
    , output wire [15:0] dbg_cpu_addr   // C64 6510 address bus (sim tracing)
`endif
);
`ifdef SIMULATION
    assign dbg_cpu_addr = cpu_addr;
`endif

/* ── VIC-II (Kawari) — clock master ────────────────────────────────────── */
wire        vic_phi;          // 0.985248 MHz phi from the VIC
wire        vic_irq;          // active high
wire        vic_aec;          // low = VIC owns the bus
wire        vic_ba;           // low = CPU must stall (reads)
wire        vic_rst;          // VIC internal power-on reset (self-timed)
wire [7:0]  vic_dbo;          // register read data (ce protocol, unused by CPU)
wire [7:0]  vic_dbo_live;     // combinational live read data for the CPU
wire [13:0] vic_addr_full;    // full 14-bit VIC fetch address (local mod)
wire [3:0]  vic_pixel;        // native 4-bit color index
wire [9:0]  vic_raster_x;
wire [8:0]  vic_raster_line;
wire [11:0] vic_ado_unused;
wire [1:0]  vic_chip;
reg  [11:0] vic_dbi;

/* Register access runs on the LIVE CPU bus.  With RDY on the phi falling
 * edge, Arlet's address-hold window spans exactly [phi low, phi high] —
 * the real 6510 lifecycle — so the VIC latches the register address at
 * its own RAS fall inside the high phase and serves/commits at the end
 * of the high phase, all within the live window.  cpu_live gates ce so
 * a BA-stalled read cycle (address held for multiple phi periods) can't
 * re-trigger read side effects ($D01E/$D01F clear on read). */
/* Every CPU-side peripheral select carries `!ef_hold` for the same reason
 * the RAM write moved to cpu_rdy (see the comment there): while the cart
 * stalls the CPU, Arlet's AB is combinational off a STALE DIMUX and WE is
 * already asserted, so a select built from the live address can point at
 * the wrong register — and a level-held select fires on EVERY phi edge of
 * the stall instead of once.  For the VIC that means phantom accesses to
 * $D019/$D011 in the middle of a raster split; PoP acks its raster IRQ with
 * `ASL $D019`, and the board showed the bottom of the screen jumping a
 * couple of lines several times a second under cart load (2026-08-06).
 * ef_hold is constant 0 in a build with no cart, so this is a no-op there. */
wire vic_ce_n = ~(sel_vic && cpu_live && mrun && !ef_hold);

vicii vic0(
    .sim_chip     (2'b01),        // CHIP6569R3 — PAL
    .standard_sw  (1'b1),
    .rst          (vic_rst),      // output
    .clk_dot4x    (clk),
    .clk_phi      (vic_phi),
    .clk_col16x   (1'b0),         // luma/chroma path compiled out
    .ado          (vic_ado_unused),
    .adi          (cpu_addr[5:0]),
    .dbo          (vic_dbo),
    .dbi          (vic_dbi),
    .ce           (vic_ce_n),
    .rw           (~cpu_we),
    .irq          (vic_irq),
    .lp           (1'b1),
    .aec          (vic_aec),
    .ba_d2        (vic_ba),
    .ras          (),
    .cas          (),
    .ls245_data_dir(),
    .ls245_addr_dir(),
    .vic_write_db (),
    .vic_write_ab (),
    .rw_ctl       (),
    .chip         (vic_chip),
    // fpgago local-mod taps
    .vic_addr_full    (vic_addr_full),
    .pixel_color3_out (vic_pixel),
    .raster_x_out     (vic_raster_x),
    .raster_line_out  (vic_raster_line),
    /* Live-bus read port: Arlet's effective address is only valid on the
     * consuming RDY tick (AB is combinational for computed addresses), so
     * read DATA must come combinationally, like RAM.  Writes and read
     * side effects use the normal ce/RAS-latched protocol above, which
     * works because write cycles hold a registered, stable address. */
    .adi_live         (cpu_addr[5:0]),
    .read_strobe_live (cpu_rdy && sel_vic && !cpu_we),
    .dbo_live         (vic_dbo_live)
);

/* ── phi edge pulses ───────────────────────────────────────────────────── */
reg prev_phi;
always @(posedge clk) prev_phi <= vic_phi;
wire phi2_p =  vic_phi & ~prev_phi;   // first tick of phi HIGH phase
wire phi2_n = ~vic_phi &  prev_phi;   // first tick of phi LOW phase

/* BIOS-mode freeze: the C64 has no WAIT pin, but every CPU-side element
 * (CPU RDY, CIA1/2, SID, RAM/color write commits, chip selects) advances
 * on the phi pulses — gating them with mrun freezes the whole machine
 * mid-cycle and releasing resumes it exactly there.  The Kawari VIC is
 * the clock master and free-runs (its display is muxed away); its raster
 * IRQ may latch once while frozen, which the resumed CPU services like
 * any raster IRQ.
 *
 * shot_freeze is the same halt WITHOUT the display mux flip: the VIC keeps
 * painting the (now static) machine screen, so shot_cap can walk a
 * tear-free frame during a grab. */
wire mrun = ~bios_mode & ~shot_freeze;

/* Gate IRQs until the CPU has had time to execute SEI.
 * Count phi2 cycles (not system clocks) for proper timing. */
reg [7:0] irq_gate_cnt;
wire irq_gated = (irq_gate_cnt < 8'd200);  // ~200 CPU cycles
wire cpu_irq = irq_gated ? 1'b0 : (~cia1_irq_n | vic_irq);
wire cpu_nmi = irq_gated ? 1'b0 : (~cia2_irq_n | ctrl_nmi);

always @(posedge clk) begin
    if (!rst) irq_gate_cnt <= 0;
    else if (irq_gated && phi2_p) irq_gate_cnt <= irq_gate_cnt + 1;
end

/* ── CPU advance + badline stall ───────────────────────────────────────── */
/* The CPU advances once per phi cycle on the FALLING edge (phi2_n): Arlet
 * presents the next address right after its RDY tick, so the address-hold
 * window spans [phi low, phi high] — the real 6510 lifecycle: address
 * setup during phi low, bus transfer during phi high, data sampled and
 * writes committed at the end of the high phase (= the phi2_n tick).
 * All peripherals are driven from the LIVE bus; no transaction latches.
 *
 * cpu_live: this phi cycle will actually complete (reads halt while BA
 * is low; writes always finish — a 6502 never issues more than three
 * consecutive writes, which reproduces the real 6510 BA rule).  It gates
 * RDY and every side-effectful chip select. */
wire cpu_live = vic_ba | cpu_we;
/* ef_hold: an EasyFlash PSRAM access is in flight (line-buffer miss or a
 * flash program write).  Suppressing the phi2_n tick stalls the CPU in
 * whole phi cycles — exactly a BA badline stall, invisible to software.
 * Line hits answer within the cycle, so steady-state costs nothing. */
wire cpu_rdy /* verilator public_flat_rd */ = phi2_n && cpu_live && mrun && !ef_hold;

/* ── ROM bank loader link (bitstreams/README.md phases 1-2) ──────
 * ROMLOAD=1 turns on qspi_slave's ROM_* commands (the instance is further
 * down); under !ROMLESS the whole block is a constant and folds away.
 *
 * Under ROMLESS the three ROM arrays ship EMPTY and the bytes arrive at
 * runtime over the link — the MCU on hardware, the C++ MCU model
 * (--rom-bank) in simulation.  Bank id IS the declaration order in the
 * bit's `roms=` tag, so fabric and firmware cannot drift:
 *     bank 0 = kernal, bank 1 = basic, bank 2 = chargen.
 * The 6510 is held in RESET until every bank is valid (below), so it
 * never fetches its vectors out of an empty KERNAL.
 *
 * No second port is added anywhere: ROMs are only ever written while the
 * machine is frozen (bios_mode), so the write borrows the EXISTING read
 * port with its address muxed — the same gen_ram shape the RAM uses.
 * That also keeps the char ROM off the true-dual-port 4Kx4 geometry that
 * is dead on this silicon (ecp5-ebr-4kx4-deadbits). */
`ifdef ROMLESS
localparam ROMLOAD_P = 1;
`elsif EASYFLASH
localparam ROMLOAD_P = 1;   // the cart image arrives over the same loader
`elsif FDRIVE
localparam ROMLOAD_P = 1;   // the drive image arrives over the same loader
`else
localparam ROMLOAD_P = 0;
`endif
/* EasyFlash raises the per-bank pointer to 18 bits: the 1 MiB flat cart
 * image travels as four 256 KiB chunks in loader banks 3..6 (bank order:
 * 3/4 = ROML chip, 5/6 = ROMH chip).  Banks 0-2 stay kernal/basic/chargen
 * and connect narrower wires as before. */
`ifdef FDRIVE
/* The fabric drive's whole image (16 KB DOS ROM, pad, then 35 GCR tracks of
 * 8 KiB) is ONE 512 KiB loader bank, because EasyFlash already holds banks
 * 3..6 and bank 7 is the only one left.  Widening the per-bank pointer is
 * free on the MCU side — the push is a bank select plus a byte stream and
 * the slave counts. */
localparam QL_ROM_AW = 19;
`elsif EASYFLASH
localparam QL_ROM_AW = 18;
`else
localparam QL_ROM_AW = 16;
`endif
wire [2:0]  ql_rom_bank;
wire [QL_ROM_AW-1:0] ql_rom_addr;
wire [7:0]  ql_rom_data;
wire        ql_rom_we;
wire [7:0]  ql_rom_valid;

wire [15:0] rom_dl_addr;
wire [7:0]  rom_dl_data;
wire        rom_kernal_we, rom_basic_we, rom_char_we, rom_ready;
`ifdef ROMLESS
assign rom_dl_addr   = ql_rom_addr;
assign rom_dl_data   = ql_rom_data;
assign rom_kernal_we = ql_rom_we && (ql_rom_bank == 3'd0);
assign rom_basic_we  = ql_rom_we && (ql_rom_bank == 3'd1);
assign rom_char_we   = ql_rom_we && (ql_rom_bank == 3'd2);
assign rom_ready     = &ql_rom_valid[2:0];
`else
assign rom_dl_addr   = 16'd0;
assign rom_dl_data   = 8'd0;
assign rom_kernal_we = 1'b0;
assign rom_basic_we  = 1'b0;
assign rom_char_we   = 1'b0;
assign rom_ready     = 1'b1;         // ROMs are baked in — always ready
`endif

/* ── 6510 CPU ──────────────────────────────────────────────────────────── */
wire [15:0] cpu_addr;
wire  [7:0] cpu_data_out /* verilator public_flat_rd */;
reg   [7:0] cpu_data_in;
wire        cpu_we /* verilator public_flat_rd */;
wire  [5:0] cpu_port;     // I/O port bits [5:0]
wire  [7:0] cpu_ddr;      // DDR register (for reads to $0000)
wire  [7:0] cpu_port_read; // Port register (for reads to $0001)
wire        cia1_irq_n, cia2_irq_n;

cpu_6510 cpu(
    .clk    (clk),
    // active-high; ctrl_reset = UART $02 / U21.  ~rom_ready holds the 6510
    // under ROMLESS until every bank has been pushed (constant 0 otherwise),
    // so it never fetches its vectors out of an empty KERNAL.
    .reset  (!rst | ctrl_reset | ~rom_ready),
    .DI     (cpu_data_in),
    .DO     (cpu_data_out),
    .AB     (cpu_addr),
    .WE     (cpu_we),
    .IRQ    (cpu_irq),
    .NMI    (cpu_nmi),
    .RDY    (cpu_rdy),
    .port_out(cpu_port),
    .port_ddr_out(cpu_ddr),
    .port_read_out(cpu_port_read)
);

/* ── Memory banking (PLA simplified) ──────────────────────────────────── */
wire loram  = cpu_port[0];   // 1 = BASIC ROM visible at $A000
wire hiram  = cpu_port[1];   // 1 = KERNAL ROM visible at $E000
wire charen = cpu_port[2];   // 1 = I/O visible at $D000, 0 = Char ROM

/* ── EasyFlash cartridge state (retro-arch/c64/README.md) ──────
 * One bitstream serves both worlds at runtime: with no cart pushed the
 * /GAME //EXROM lines idle high and every term below folds back to the
 * original PLA; once the loader has delivered all four flat-image chunks
 * (banks 3..6) `cart_mounted` rises, the cart owns I/O1/I/O2 and the
 * fastload windows go dark (cart games never LOAD from disk — a d64
 * session simply doesn't mount a cart). */
`ifdef EASYFLASH
reg  [5:0] ef_bank    /* verilator public_flat_rd */ = 6'd0;  // $DE00 (W)
reg  [7:0] ef_mode    /* verilator public_flat_rd */ = 8'd0;  // $DE02 (W): L000_0MXG
reg        cart_force /* verilator public_flat_rw */ = 1'b0;  // sim: --ef
reg        cart_mounted = 1'b0;
always @(posedge clk)
    cart_mounted <= (&ql_rom_valid[6:3]) | cart_force;

/* $DE02 → line states, INVERTED senses per the EF Programmer's Guide:
 * /EXROM = !X;  M=1: /GAME = !G,  M=0: /GAME = "boot" jumper = LOW.
 * Reset value $00 = Ultimax, bank 0 — how every EF cart boots. */
wire ef_game_n  = cart_mounted ? (ef_mode[2] ? ~ef_mode[0] : 1'b0) : 1'b1;
wire ef_exrom_n = ~(cart_mounted & ef_mode[1]);

/* register writes; a machine reset re-arms the cart's boot state exactly
 * like the /RESET line on the real cartridge port */
always @(posedge clk)
    if (!rst || ctrl_reset || !cart_mounted) begin
        ef_bank <= 6'd0;
        ef_mode <= 8'd0;
    end else if (cpu_rdy && cpu_we && sel_io && cart_mounted &&
                 (cpu_addr[11:8] == 4'hE)) begin
        if (cpu_addr[7:0] == 8'h00) ef_bank <= cpu_data_out[5:0];
        if (cpu_addr[7:0] == 8'h02) ef_mode <= cpu_data_out;
    end
`else
wire cart_mounted = 1'b0;
wire ef_game_n  = 1'b1;
wire ef_exrom_n = 1'b1;
wire [5:0] ef_bank = 6'd0;
wire [7:0]  ef_push_ovr = 8'd0;     // no loader to drop anything: P dump 00
wire [15:0] ef_psram_id = 16'd0;    // ...and no PSRAM engine to answer
`endif
wire ef_ultimax = ~ef_game_n & ef_exrom_n;

/* Address decode from LIVE cpu_addr (for combinational read mux).
 * Cartridge terms follow the real PLA:
 *   ROML $8000 = loram && hiram && /EXROM low   (8K and 16K modes)
 *   ROMH $A000 = hiram && /GAME low && /EXROM low        (16K mode)
 *   ROMH $E000 = Ultimax (replaces the KERNAL)
 *   BASIC needs /GAME high (an 8K cart keeps BASIC, a 16K cart evicts it)
 * With no cart both lines read high and everything folds to the original. */
wire sel_roml   = (cpu_addr[15:13] == 3'b100) &&
                  ((loram && hiram && !ef_exrom_n) || ef_ultimax);
wire sel_romh_a = (cpu_addr[15:13] == 3'b101) &&
                  hiram && !ef_game_n && !ef_exrom_n;
wire sel_romh_e = (cpu_addr[15:13] == 3'b111) && ef_ultimax;
wire sel_cart   = sel_roml || sel_romh_a || sel_romh_e;

wire sel_basic  = loram && hiram && ef_game_n &&
                  (cpu_addr >= 16'hA000) && (cpu_addr <= 16'hBFFF);
wire sel_kernal = hiram && (cpu_addr >= 16'hE000) && !ef_ultimax;
/* $D000-$DFFF is I/O or char ROM only while LORAM or HIRAM is set; with
 * both clear the PLA maps plain RAM there NO MATTER what CHAREN says
 * (bank modes 24/28).  Pirates! relocates its packed payload through
 * $D000 under $01=$34 and decrunches reading it back — with the old
 * `charen`-only decode those reads returned I/O registers.  Ultimax is
 * an ADDED term, never a change to the (loram||hiram) one: there the real
 * PLA maps I/O regardless of $01, and char ROM not at all. */
wire dxxx_window = (cpu_addr >= 16'hD000) && (cpu_addr <= 16'hDFFF) &&
                   ((loram || hiram) || ef_ultimax);
wire sel_io     = (charen || ef_ultimax) && dxxx_window;
wire sel_charrom = !charen && dxxx_window && !ef_ultimax;

wire sel_vic    = sel_io && (cpu_addr[11:8] <= 4'h3);
wire sel_sid    = sel_io && (cpu_addr[11:8] >= 4'h4) && (cpu_addr[11:8] <= 4'h7);
wire sel_color  = sel_io && (cpu_addr[11:8] >= 4'h8 && cpu_addr[11:8] <= 4'hB);
wire sel_cia1   = sel_io && (cpu_addr[11:8] == 4'hC);
wire sel_cia2   = sel_io && (cpu_addr[11:8] == 4'hD);

/* QSPI fastload engine: routine window $DE00-$DE7F (I/O1) + registers
 * $DF00-$DF0F (I/O2).  Strobes fire on cpu_rdy — the one tick per phi
 * cycle where the live CPU bus is valid (same discipline as the VIC
 * read_strobe_live).
 * With an EasyFlash cart mounted BOTH pages belong to the cart ($DE00/
 * $DE02 registers, $DF00-$DFFF cart RAM) and the fastload/DOS windows are
 * gated off — mode exclusivity, decided at runtime by cart_mounted. */
wire sel_exp = sel_io && !cart_mounted &&
               ((cpu_addr[11:8] == 4'hE) || (cpu_addr[11:8] == 4'hF));
/* Strobes fire for the REGISTER page ($DFxx) ONLY: the $DExx routine
 * window is code the CPU FETCHES from — a fetch at $DEx1 must not pop
 * the FIFO (that exact bug: every-other-byte corruption). */
wire sel_exp_reg = sel_io && (cpu_addr[11:8] == 4'hF) && !cart_mounted;
wire [7:0] exp_rdata;
wire        bios_mode;
wire [4:0]  vol_scale;
wire [6:0]  bright_scale;

// Backlight: PWM-dimmable from the BIOS (SET_BRIGHT over the link).  Powers
// up full on; R2 pulls the pin low while the fabric is unconfigured, so an
// unprogrammed board stays dark.
lcd_backlight bl0(.clk(clk), .scale(bright_scale), .pwm(lcd_pwm));
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
wire bus_hold_clk;      // link owns the bus -> present CLK low (see below)
/* fabric-1541 taps for FD_STATUS (0x0D); the FDRIVE block below drives them,
 * every other build ties them off (an undriven input bakes x into the LUTs) */
wire [7:0] fd_stat_w, fd_done_w;
qspi_slave #(.C64(1), .ROMLOAD(ROMLOAD_P), .ROM_AW(QL_ROM_AW)) qspi0(
    .clk(clk), .rst(rst),
    .spi_sck(spi_sck), .spi_ss(spi_ss), .spi_sd_in(spi_sd_in),
    .spi_sd_out(spi_sd_out), .spi_sd_oe(spi_sd_oe), .req(spi_req),
    .drive_1541(drive_1541), .bus_hold_clk(bus_hold_clk),
    .shot_arm_stb(shot_arm_stb), .shot_line(shot_line),
    .shot_dense(shot_dense), .shot_pair(shot_pair),
    .shot_freeze(shot_freeze), .shot_armed(shot_armed),
    .shot_ready(shot_ready), .shot_raddr(shot_raddr),
    .shot_rdata(shot_rdata),
    .btn(btn), .bios_mode(bios_mode), .vol_scale(vol_scale),
    .bright_scale(bright_scale),
    .btn_mode(btn_mode), .btn_mode_stb(btn_mode_stb),
    .txt_waddr(txt_waddr), .txt_wdata(txt_wdata), .txt_wen(txt_wen),
    .exp_addr(cpu_addr), .exp_rdata(exp_rdata),
    .exp_laddr(cpu_addr[3:0]), .exp_wdata(cpu_data_out),
    .exp_wstb(cpu_rdy && sel_exp_reg && cpu_we),
    .exp_rstb(cpu_rdy && sel_exp_reg && !cpu_we),
    .rom_bank(ql_rom_bank), .rom_addr(ql_rom_addr),
    .rom_data(ql_rom_data), .rom_we(ql_rom_we), .rom_valid(ql_rom_valid),
    .fdd_request(2'b00), .fdd_mgmt_rdata(16'h0000),
    .fdd_mgmt_addr(), .fdd_mgmt_wdata(), .fdd_mgmt_write(),
    .fdd_mgmt_read(), .fdd_reset_stb(), .fdd_turbo(),
    .fd_stat(fd_stat_w), .fd_done(fd_done_w)
);

/* ── RAM (64 KB) ──────────────────────────────────────────────────────── */
reg [7:0] ram [0:65535] /* verilator public_flat_rw */;
initial begin : ram_init
`ifdef SIMULATION
    /* Deterministic zeros for the simulator ONLY.  In the yosys build a
     * for-loop clear takes priority over the $readmemh below and the
     * whole game image lands as zeros in the EBR INIT (verified with a
     * minimal case, cause of "RUN does nothing" on the board
     * 2026-07-09).  EBR INITVAL defaults to zero anyway, so hardware
     * powers up with the same zeros without the loop. */
    integer i;
    for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
`endif
`ifdef GAME_PRG
    $readmemh("../roms/game.hex", ram);
`endif
end

/* ALL RAM/ROM reads are SYNCHRONOUS (q <= mem[addr]) so yosys can map
 * them onto EBR — a combinational read of a 64KB array never fits fabric.
 *
 * ONE r/w port in the exact gen_ram shape the working c16/plus4 builds
 * map (write + read sharing the address bus in a single always block →
 * shallow x18 read slices + fabric mux).  TWO independent read ports
 * would force yosys into deep true-dual-port geometries (16Kx1 / 4Kx4)
 * whose high READ address bits are dead on this silicon+toolchain (the
 * ecp5-ebr-4kx4 rule — cause of the 2026-07-09 blank-screen bring-up).
 *
 * The single port is therefore TIME-MULTIPLEXED: the CPU owns the one
 * phi2_n tick — which is both its read-capture tick (cpu_rdy) and the
 * write-commit tick, so reads and writes share cpu_addr — and the VIC
 * owns every other tick.  Stealing that tick from the VIC is safe: the
 * DATA_DAV samplers fire at the half-cycle boundary ticks (H0/L0) and
 * consume the PRE-edge value, i.e. the H15/L15 reads; the phi2_n-tick
 * (L0) read is visible only during L1, which no DAV consumer samples.
 * Write commit at phi2_n = end of the phi high phase, live signals.
 * Only I/O writes bypass RAM: like the real PLA, writes land in the RAM
 * under BASIC/KERNAL/char ROM whenever those are banked in for reads. */
wire        ram_cpu_slot = phi2_n;
wire [15:0] ram_addr = ram_cpu_slot ? cpu_addr : vic_abs_addr;
reg  [7:0]  ram_q;
/* Ultimax maps only 4 KB of RAM ($0000-$0FFF); writes elsewhere fall on
 * open bus on real hardware (and EAPI's flash-command writes to the ROML/
 * ROMH windows must NOT shadow into RAM there). */
wire ram_wr_ok = !(ef_ultimax && (cpu_addr[15:12] != 4'h0));
/* The write commits on cpu_rdy, NOT on the bare phi2_n slot.  Those were the
 * same thing until the cartridge could stall the CPU, and the difference is
 * a memory corrupter: Arlet's core builds AB COMBINATIONALLY out of DIMUX
 * (`ABS1: AB = {DIMUX, ADD}`, `INDY0: AB = {ZEROPAGE, DIMUX}`) and
 * `DIMUX = ~RDY ? DIHOLD : DI`, while WE in those same states is already
 * `store`.  So the instant RDY drops, the address bus swings to a STALE
 * value with WE still high — and a write committed on phi2_n alone lands
 * the right byte at the wrong address.  One line-buffer miss coinciding
 * with a store's address cycle was enough to scribble over a byte of
 * decompressed code half a second before Prince of Persia jumped into it
 * (board + sim, 2026-08-06).  cpu_rdy is exactly "the CPU really is being
 * clocked this tick", which is the only moment its bus means anything.
 * With no cart, ef_hold is constant 0 and cpu_rdy == phi2_n for a write
 * (cpu_live is `vic_ba | cpu_we`), so nothing else changes behaviour. */
always @(posedge clk) begin
    if (rst && cpu_rdy && cpu_we && !sel_io && mrun && ram_wr_ok)
        ram[ram_addr] <= cpu_data_out;
    ram_q <= ram[ram_addr];
end

/* ── ROMs ──────────────────────────────────────────────────────────────── */
reg [7:0] basic_rom [0:8191];
reg [7:0] kernal_rom [0:8191];
reg [7:0] char_rom [0:4095];

/* ROM content arrives one of two ways: baked at synthesis (default), or —
 * under ROMLESS — pushed at runtime through the write ports below, so the
 * shipped bitstream carries no copyrighted bytes.
 *
 * The ROMLESS branch still needs an EXPLICIT all-zero power-up value: an
 * EBR with no init bakes x into the netlist and miscompiles on silicon
 * only (netlist-sim-undriven-wires).  The two branches are mutually
 * exclusive on purpose — yosys drops a $readmemh that follows a for-loop
 * clear, so they must never both run. */
`ifdef ROMLESS
initial begin : rom_zero
    integer i;
    for (i = 0; i < 8192; i = i + 1) begin
        basic_rom[i]  = 8'h00;
        kernal_rom[i] = 8'h00;
    end
    for (i = 0; i < 4096; i = i + 1) char_rom[i] = 8'h00;
end
`else
initial $readmemh("../roms/basic.hex", basic_rom);
initial $readmemh("../roms/kernal.hex", kernal_rom);
initial $readmemh("../roms/chargen.hex", char_rom);
`endif

/* char ROM is read by both CPU and VIC → same slot-multiplexed single
 * read port as the RAM (a true-dual-port 4Kx4 mapping here is EXACTLY
 * the geometry proven dead on v1 silicon). */
wire [11:0] char_addr = ram_cpu_slot ? cpu_addr[11:0] : vic_addr_full[11:0];

/* Write + read share one address bus per array (the gen_ram shape yosys
 * maps to a single-port EBR).  The ROM write only ever fires while the
 * machine is frozen, so stealing the read address for that tick costs the
 * machine nothing. */
wire [12:0] basic_a  = rom_basic_we  ? rom_dl_addr[12:0] : cpu_addr[12:0];
wire [12:0] kernal_a = rom_kernal_we ? rom_dl_addr[12:0] : cpu_addr[12:0];
wire [11:0] char_a   = rom_char_we   ? rom_dl_addr[11:0] : char_addr;

reg [7:0] basic_q, kernal_q, char_q;
always @(posedge clk) begin
    if (rom_basic_we) basic_rom[basic_a] <= rom_dl_data;
    basic_q  <= basic_rom[basic_a];
end
always @(posedge clk) begin
    if (rom_kernal_we) kernal_rom[kernal_a] <= rom_dl_data;
    kernal_q <= kernal_rom[kernal_a];
end
always @(posedge clk) begin
    if (rom_char_we) char_rom[char_a] <= rom_dl_data;
    char_q   <= char_rom[char_a];
end

/* ── Color RAM (1K x 4 bits) ──────────────────────────────────────────── */
reg [3:0] color_ram [0:1023];
initial begin : color_init
    integer i;
    for (i = 0; i < 1024; i = i + 1) color_ram[i] = 4'hE; // light blue
end

/* Same slot-multiplexed single r/w port as the RAM (CPU owns the phi2_n
 * tick for both read capture and write commit, VIC owns the rest). */
wire [9:0] color_addr = ram_cpu_slot ? cpu_addr[9:0] : vic_addr_full[9:0];
reg [3:0] color_q;
always @(posedge clk) begin
    if (rst && cpu_rdy && cpu_we && sel_color && mrun)   // cpu_rdy: see the
        color_ram[color_addr] <= cpu_data_out[3:0];      // RAM write above
    color_q <= color_ram[color_addr];
end

/* ── EasyFlash: cart RAM, memory backend, loader push ──────────────────── */
`ifdef EASYFLASH
/* 256 B cartridge RAM at $DF00-$DFFF, ALWAYS visible while a cart is
 * mounted (even with the ROM banked out — the spec's "kill" state keeps
 * it).  Same gen_ram single-port shape as every other array here. */
wire sel_efram = sel_io && (cpu_addr[11:8] == 4'hF) && cart_mounted;
reg [7:0] ef_ram [0:255];
initial begin : ef_ram_init
    integer i;
    for (i = 0; i < 256; i = i + 1) ef_ram[i] = 8'h00;
end
reg [7:0] efram_q;
always @(posedge clk) begin
    if (cpu_rdy && cpu_we && sel_efram && mrun)
        ef_ram[cpu_addr[7:0]] <= cpu_data_out;
    efram_q <= ef_ram[cpu_addr[7:0]];
end

/* cart access strobes: one per phi cycle, at the live-bus tick */
wire ef_rd_stb = cpu_rdy && sel_cart && !cpu_we;
wire ef_wr_stb = cpu_rdy && sel_cart && cpu_we;
wire ef_chip   = sel_romh_a | sel_romh_e;      // 0 = ROML, 1 = ROMH

/* loader push: banks 3..6 = flat-image chunks (256 KiB each) */
wire        ef_push_we   = ql_rom_we && (ql_rom_bank >= 3'd3) &&
                           (ql_rom_bank <= 3'd6);
wire [19:0] ef_push_addr = {ql_rom_bank[1:0] - 2'd3, ql_rom_addr[17:0]};

wire [7:0] ef_rdata;
wire       ef_rvalid, ef_busy;
wire [7:0]  ef_push_ovr;
wire [15:0] ef_psram_id;

/* command port to the shared engine (instantiated once, further down) */
wire [23:0] ef_ps_addr;
wire        ef_ps_rd, ef_ps_wr, ef_ps_byte;
wire [3:0]  ef_ps_words;
wire [31:0] ef_ps_wdata, ef_ps_rdata;
wire        ef_ps_rdy, ef_ps_word_rdy, ef_ps_busy;
wire [2:0]  ef_ps_word_idx;

c64_easyflash ef0(
    .clk(clk), .rst(rst),
    .rd_stb(ef_rd_stb), .wr_stb(ef_wr_stb),
    .chip(ef_chip), .bank(ef_bank), .offs(cpu_addr[12:0]),
    .wdata(cpu_data_out),
    .rdata(ef_rdata), .rvalid(ef_rvalid), .busy(ef_busy),
    .push_we(ef_push_we), .push_addr(ef_push_addr),
    .push_data(ql_rom_data), .push_ovr(ef_push_ovr),
    .ps_addr(ef_ps_addr), .ps_rd(ef_ps_rd), .ps_wr(ef_ps_wr),
    .ps_byte(ef_ps_byte), .ps_words(ef_ps_words), .ps_wdata_o(ef_ps_wdata),
    .ps_rdata(ef_ps_rdata), .ps_rdy(ef_ps_rdy),
    .ps_word_rdy(ef_ps_word_rdy), .ps_word_idx(ef_ps_word_idx),
    .ps_busy(ef_ps_busy)
);

/* stall + one-clk commit cover: rvalid lands in ef_rdata_q/ef_commit, the
 * commit writes cpu_data_in one clk later, and only then may the next
 * cpu_rdy tick fire */
reg       ef_commit  /* verilator public_flat_rd */;
reg [7:0] ef_rdata_q /* verilator public_flat_rd */;
always @(posedge clk) begin
    ef_commit <= ef_rvalid;
    if (ef_rvalid) ef_rdata_q <= ef_rdata;
end
wire ef_hold = ef_busy | ef_rvalid | ef_commit;
`else
wire ef_hold = 1'b0;
`endif

/* ── VIC bus-master fetch feed ─────────────────────────────────────────── */
/* Bank from CIA2 PA0/PA1 (inverting drivers, pulled up when released). */
wire [1:0] vic_bank = ~(cia2_pa_out[1:0] | ~cia2_pa_oe[1:0]);
/* Char ROM shadows VIC $1000-$1FFF in banks 0 and 2. */
wire vic_sees_charrom = (vic_addr_full[13:12] == 2'b01) && !vic_bank[0];
wire [15:0] vic_abs_addr = {vic_bank, vic_addr_full};

/* The fetch data is the one-tick-registered EBR read of vic_abs_addr
 * (ram_q / char_q / color_q above, VIC slot ticks).  Timing:
 * vic_addr_full is stable across the half cycle and still holds the
 * ENDING access's address at the DATA_DAV=0 boundary tick where
 * bus_access samples dbi, so the one-tick-old registered read is exactly
 * the data the combinational feed delivered there — and the new
 * address's data is ready 14 ticks before the next DAV. */
reg vic_charsel_q;
always @(posedge clk)
    vic_charsel_q <= vic_sees_charrom;
wire [7:0] vic_fetch_byte = vic_charsel_q ? char_q : ram_q;

/* dbi: when the VIC owns the bus (AEC low) feed its fetch; when the CPU
 * owns it, mirror the CPU-driven data bus (register writes sample
 * dbi[7:0]; the VIC also records it as last_bus for idle fetches). */
always @(*) begin
    if (!vic_aec)
        vic_dbi = {color_q, vic_fetch_byte};
    else
        vic_dbi = {4'hF, cpu_we ? cpu_data_out : cpu_data_in};
end

/* ── SID ($D400-$D7FF, 6581) ──────────────────────────────────────────── */
/* Register writes commit on the phi2_n tick like RAM/color writes (one-clk
 * cs pulse, live cpu_addr/cpu_data_out are stable there).  Reads come from
 * sid_top's COMBINATIONAL data_out and are captured at the cpu_rdy tick
 * below (sid_q), the same live-bus pattern as the VIC/CIA _live ports.
 * SID reads have no side effects, so a BA-stalled repeated read is safe.
 * ce_1m = phi2_p: the SID's 1 MHz cycle starts half a phi after the write
 * commit, so a register write is always visible to the very next cycle.
 * POT inputs read $FF (no paddles, lines float high). */
wire  [7:0] sid_rdata;
wire signed [17:0] sid_audio;

sid_top sid0(
    .reset   (!rst),
    .clk     (clk),
    .ce_1m   (phi2_p && mrun),
    .cs      (sel_sid && cpu_live && phi2_n && mrun && !ef_hold),  // stall: see vic_ce_n
    .we      (cpu_we),
    .addr    (cpu_addr[4:0]),
    .data_in (cpu_data_out),
    .data_out(sid_rdata),
    .pot_x   (8'hFF),
    .pot_y   (8'hFF),
    .mode    (1'b0),          // 6581
    .fc_offset(13'd0),
    .audio   (sid_audio)
);

/* Muted in BIOS mode (the SID is frozen, so its output would hold a level).
 * vol_scale (0..16, SET_VOLUME over the link): 16 = unity, bit-exact. */
wire signed [15:0] sid_pcm = sid_audio[17:2];
wire signed [21:0] vol_prod = sid_pcm * $signed({1'b0, vol_scale});
assign audio_pcm = bios_mode ? 16'sd0 : vol_prod[19:4];

/* ── CIA1 (keyboard, joystick, IRQ) ───────────────────────────────────── */
wire [7:0] cia1_data_out, cia1_data_live, cia2_data_live;
wire [7:0] cia1_pa_out, cia1_pb_out;
wire [7:0] cia1_pa_oe, cia1_pb_oe;

// Keyboard matrix — at 1 MHz, CIA PA output is in sync with CPU
wire [7:0] key_row_select = cia1_pa_out | ~cia1_pa_oe;
wire [7:0] key_col_result;

/* Joystick port 1 shares CIA1 PB with the keyboard columns (same bit
 * order as port 2 on PA: PB0=up PB1=down PB2=left PB3=right PB4=fire,
 * active low) — the joystick pulls the column lines, like real HW. */
wire [7:0] cia1_pb_joy1 = {3'b111, btn_joy1_n[4], btn_joy1_n[0],
                           btn_joy1_n[1], btn_joy1_n[2], btn_joy1_n[3]};

mos6526 cia1(
    .mode   (1'b0),
    .clk    (clk),
    .phi2_p (phi2_p && mrun),
    .phi2_n (phi2_n && mrun),
    .res_n  (rst),
    .cs_n   (~(sel_cia1 && cpu_live && mrun && !ef_hold)),  // stall: see vic_ce_n
    .rw     (~cpu_we),
    .rs     (cpu_addr[3:0]),
    .db_in  (cpu_data_out),
    .db_out (cia1_data_out),
    .db_out_live (cia1_data_live),
    .pa_in  (cia1_pa_in),
    .pa_out (cia1_pa_out),
    .pa_oe  (cia1_pa_oe),
    .pb_in  (key_col_result & cia1_pb_joy1),
    .pb_out (cia1_pb_out),
    .pb_oe  (),
    .flag_n (1'b1),
    .pc_n   (),
    .tod    (tod_clk),
    .sp_in  (1'b1),
    .sp_out (),
    .cnt_in (1'b1),
    .cnt_out(),
    .irq_n  (cia1_irq_n)
);

/* ── CIA2 (serial, NMI, VIC bank) ─────────────────────────────────────── */
wire [7:0] cia2_data_out;

/* IEC serial bus on CIA2 Port A (C64 pinout):
 *   PA3 = ATN out, PA4 = CLK out, PA5 = DATA out  (inverting drivers: PAx=1
 *         pulls the line LOW; our iec_*_out uses 1=released, so invert).
 *   PA6 = CLK in,  PA7 = DATA in  (read the bus line level, 1 = released).
 * A line is driven only when configured as an output (pa_oe bit set). */
wire [7:0] cia2_pa_out, cia2_pa_oe;
assign iec_atn_out  = ~(cia2_pa_out[3] & cia2_pa_oe[3]);
assign iec_clk_out  = ~(cia2_pa_out[4] & cia2_pa_oe[4]);
assign iec_data_out = ~(cia2_pa_out[5] & cia2_pa_oe[5]);
/* PRA reads return PIN levels: output pins read back their DRIVEN value
 * (pa_out already folds in DDR pull-ups), inputs the external line.
 * Feeding constant 1s here broke every KERNAL read-modify-write of $DD00
 * (CINT's VIC-bank RMW wrote 1s into PA3-5 → ATN/CLK/DATA latched LOW →
 * every real-drive LOAD hung at "SEARCHING FOR"). */
/* The MCU-emulated 1541 drives CLK/DATA asynchronously to this 31 MHz dot
 * clock.  Feeding the raw pads straight into the CIA (as before) meant the
 * KERNAL's tight CLK-polling loop could sample a line mid-transition and read
 * the wrong level — one bad sample desyncs the byte framing and the LOAD dies
 * partway through (the "gets to a few KB then fails at a random spot" bug).
 * A 2-FF synchronizer removes the metastability window.  Idle level is 1
 * (open-drain, released → pulled up), so the flops power up at 1; they are only
 * ever assigned from a signal, so the ecp5 rst-constfold trap does not apply. */
reg iec_clk_s1  = 1'b1, iec_clk_s2  = 1'b1;
reg iec_data_s1 = 1'b1, iec_data_s2 = 1'b1;
always @(posedge clk) begin
    iec_clk_s1  <= iec_clk_in;   iec_clk_s2  <= iec_clk_s1;
    iec_data_s1 <= iec_data_in;  iec_data_s2 <= iec_data_s1;
end

`ifdef FDRIVE
/* ── fabric 1541 (common/drive1541, c64/README.md) ──────────
 * The whole drive — Arlet 6502 + SO, two via6522s, GCR engine — clocks
 * off THIS PLL via a stretchable /32 phi (LOCKSTEP with the C64: the
 * rate every sim result was proven at).  IEC is internal wires; the
 * external pads still participate in the wired-AND so nothing else
 * changes.  DOS ROM + pre-encoded GCR tracks live in PSRAM behind
 * drive_psram.v (ROM at 0x200000, tracks at 0x210000), streamed in by
 * the MCU through ROM-push banks 3..4 (shared with EasyFlash's flat
 * image — a build/run uses the cart OR the drive, never both).
 * The drive is held in reset until an image has been pushed, and for
 * ~2 ms after the last push byte (the mount settles, then the drive
 * boots its DOS like a power-on). */
wire fd_clk_pull_raw, fd_data_pull_raw;
wire fd_stall;

/* A PARKED drive must be electrically ABSENT, not merely quiet.
 *
 * drive_1541's ATN auto-ack is combinational and matches the real board's
 * 74LS gate: iec_data_pull = orb[1] | (~ATN ^ ATNA), and under reset ATNA is
 * 0 — so a drive held in reset STILL pulls DATA low every time the C64
 * asserts ATN.  On a real machine that is correct (the gate is powered even
 * while the DOS is booting).  Here it is not: with DRIVE_MODE on fastload or
 * DOS-over-link this drive is not the drive at all, and a wire that answers
 * ATN but can never talk is worse than an empty one — the KERNAL sees the
 * ack as "device 8 present", sends the name, and waits for a talker that
 * does not exist.  That is the DOS-1541 freeze right after SEARCHING FOR
 * (the sims missed it because the harness's C-model 1541 was on the wire
 * too, answering in the fabric drive's place).
 *
 * Absent until it is genuinely running: not selected, no image pushed, or
 * still inside the post-push settle. */
wire fd_present    = ~fd_rst;
wire fd_clk_pull   = fd_present & fd_clk_pull_raw;
wire fd_data_pull  = fd_present & fd_data_pull_raw;

/* wire levels as the drive sees them (everyone ANDed, incl. own pulls).
 * FDRIVE sims MUST run --no-floppy: the harness's default C-model 1541
 * competes as a second device 8 AND its feedback folds the C64's outputs
 * into iec_*_in, double-pathing them against iec_*_out with ~1 us of skew
 * (at $ED8B — CLK-assert + DATA-release in one CIA write — the stale
 * synchronizer held DATA low through the drive's bit-8 sample and every
 * $F0 secondary arrived as $70: OPEN became a DATA channel, filename
 * discarded, FILE NOT FOUND).  With --no-floppy the pads read constant 1,
 * exactly like the board's pulled-up externals. */
wire fd_wire_atn  = iec_atn_out;
wire fd_wire_clk  = iec_clk_out  & iec_clk_s2  & ~fd_clk_pull;
wire fd_wire_data = iec_data_out & iec_data_s2 & ~fd_data_pull;

/* push: bank 7 → PSRAM 0x200000 + offset (512 KiB, the whole drive image;
 * banks 3..6 belong to the EasyFlash cart in the same bitstream) */
wire        fd_push_we   = ql_rom_we && (ql_rom_bank == 3'd7);
wire [21:0] fd_push_addr = {3'b100, ql_rom_addr[18:0]};

/* reset: with the machine, plus held until 2 ms after the last push */
reg        fd_pushed = 1'b0;
reg [16:0] fd_cool = 17'd0;
always @(posedge clk) begin
    if (fd_push_we) begin
        fd_pushed <= 1'b1;
        fd_cool   <= 17'h1FFFF;
    end else if (fd_cool != 17'd0)
        fd_cool <= fd_cool - 17'd1;
end
/* ...and PARKED unless DRIVE_MODE selected it (bit0 = drive_1541, which on
 * this build means "the fabric drive is the drive").  Without this gate the
 * fabric drive is unconditionally device 8 and the other three engines are
 * dead: DOS-over-link (DRIVE_MODE 2) drives the same internal wires through
 * bus_hold_clk and would fight it byte for byte, and in fastload mode a
 * spinning drive is pure noise on a bus the KERNAL detour has taken over.
 * Parked = held in reset: PSRAM keeps the pushed image, so re-arming the
 * mode boots the DOS again without a re-push. */
wire fd_rst = ~rst | ~fd_pushed | (fd_cool != 17'd0) | ~drive_1541;

/* stretchable /32 phi: held while a ROM byte is outstanding; frozen with
 * the machine so BIOS pauses pause the drive too */
reg [5:0] fd_div = 6'd0;
reg       fd_tick = 1'b0;
reg [23:0] fd_stall_clks = 24'd0;
always @(posedge clk) begin
    fd_tick <= 1'b0;
    if (fd_rst) begin
        fd_div <= 6'd0;
        fd_stall_clks <= 24'd0;
    end else if (fd_div >= 6'd31) begin
        if (!fd_stall && mrun) begin
            fd_tick <= 1'b1;
            fd_div  <= 6'd0;
        end else if (fd_stall)
            fd_stall_clks <= fd_stall_clks + 24'd1;
    end else
        fd_div <= fd_div + 6'd1;
end

wire [13:0] fd_rom_addr;
wire        fd_rom_sel;
wire [7:0]  fd_rom_data;
wire [21:0] fd_gcr_addr;
wire [7:0]  fd_gcr_data;

wire [23:0] fd_ps_addr;
wire        fd_ps_rd, fd_ps_wr, fd_ps_byte;
wire [3:0]  fd_ps_words;
wire [31:0] fd_ps_wdata, fd_ps_rdata;
wire        fd_ps_rdy, fd_ps_busy;
wire        fd_push_busy;   /* the QSPI push has no backpressure; the link
                             * byte rate (~us/byte) dwarfs a 16-clk write */

wire        fd_dbg_motor, fd_dbg_led;
wire [6:0]  fd_dbg_ht;
wire [15:0] fd_dbg_ab;

wire [7:0]  fd_ram85;

drive_1541 fdrive(
    .clk(clk), .rst(fd_rst), .tick(fd_tick),
    .iec_atn(fd_wire_atn), .iec_clk_in(fd_wire_clk),
    .iec_data_in(fd_wire_data),
    .iec_clk_pull(fd_clk_pull_raw), .iec_data_pull(fd_data_pull_raw),
    .rom_addr(fd_rom_addr), .rom_sel(fd_rom_sel), .rom_data(fd_rom_data),
    .gcr_addr(fd_gcr_addr), .gcr_data(fd_gcr_data),
    .disk_writable(1'b0),
    .dbg_motor(fd_dbg_motor), .dbg_led(fd_dbg_led),
    .dbg_halftrack(fd_dbg_ht), .dbg_cpu_ab(fd_dbg_ab),
    .dbg_ram85(fd_ram85)
);

/* ── load-done event for the BIOS autostart (FD_STATUS 0x0D) ───────────
 * The MCU cannot see this drive work: no fastload XFER_END, no IEC pins to
 * sniff.  So the fabric raises the same event the MCU's own drive engine
 * raises — at ATN release, secondary $E0 in drive RAM $85 = CLOSE channel 0,
 * which is how every KERNAL LOAD ends (iec1541.c, verbatim).  The counter
 * free-runs and wraps at 8 bits; the MCU only ever compares it to a baseline
 * it took moments earlier, so wrapping costs nothing.  Machine reset clears
 * it; a drive PARK (fd_rst via DRIVE_MODE) deliberately does not, so a mode
 * flip cannot fake an event into a macro that is already waiting. */
reg       fd_atn_q = 1'b1;
reg [7:0] fd_load_done = 8'd0;
always @(posedge clk) begin
    fd_atn_q <= fd_wire_atn;
    if (!rst)
        fd_load_done <= 8'd0;
    else if (fd_wire_atn && !fd_atn_q && fd_ram85 == 8'hE0)
        fd_load_done <= fd_load_done + 8'd1;
end

assign fd_stat_w = {4'b0000, drive_1541, fd_dbg_led, fd_dbg_motor, fd_pushed};
assign fd_done_w = fd_load_done;

`ifdef SIMULATION
/* +fdwire: every IEC wire transition as the drive sees it */
reg [8:0] fdw_d = 9'h1FF;
integer   fdw_n = 0;
always @(posedge clk) begin : fdwire
    reg [8:0] cur;
    cur = {fd_wire_atn, fd_wire_clk, fd_wire_data,
           fd_clk_pull, fd_data_pull,
           iec_clk_out, iec_data_out, iec_clk_s2, iec_data_s2};
    if ($test$plusargs("fdwire") && cur != fdw_d && fdw_n < 400 &&
        fd_tick_cnt > 32'd8250000) begin
        fdw_n = fdw_n + 1;
        $display("[fdwire] t=%d atn=%b clk=%b data=%b (fd c=%b d=%b) (c64 c=%b d=%b) (ext c=%b d=%b) ab=%h",
                 fd_tick_cnt, cur[8], cur[7], cur[6], cur[5], cur[4],
                 cur[3], cur[2], cur[1], cur[0], fd_dbg_ab);
    end
    fdw_d <= cur;
end

/* +fddbg: one line per ~66 ms of the fabric drive's vital signs */
reg [31:0] fd_tick_cnt = 32'd0;
always @(posedge clk) if (fd_tick) fd_tick_cnt <= fd_tick_cnt + 32'd1;
reg [20:0] fd_dbg_cnt = 21'd0;
reg fd_led_d = 1'b0;
always @(posedge clk) begin
    fd_led_d <= fd_dbg_led;
    if ($test$plusargs("fdled") && fd_dbg_led != fd_led_d)
        $display("[fdled] %b ticks=%d", fd_dbg_led, fd_tick_cnt);
    begin : fdpc
        reg [7:0] page_d;
        reg       armed;
        integer   pcn;
        integer   k;
        if (!fd_wire_atn && fd_tick_cnt > 32'd2500000) armed = 1;
        if (fd_tick && armed && pcn < 60 && $test$plusargs("fdpc") &&
            fd_dbg_ab[15:8] != page_d &&
            fd_dbg_ab[15:12] >= 4'hC && fd_dbg_ab[15:12] <= 4'hD) begin
            pcn = pcn + 1;
            $display("[fdpc] %h %d", fd_dbg_ab, fd_tick_cnt);
        end
        if (fd_tick) page_d = fd_dbg_ab[15:8];
        if (fd_tick && fd_dbg_ab == 16'hEA2D &&
            $test$plusargs("fdbyte"))
            $display("[fdbyte] t=%d atnbyte=%h", fd_tick_cnt,
                     fdrive.ram['h85]);
        if (fd_tick && fd_tick_cnt == 32'd9000000 &&
            $test$plusargs("fdram")) begin
            $write("[fdram] zp70:");
            for (k = 'h70; k <= 'h87; k = k + 1) $write(" %h", fdrive.ram[k]);
            $write("\n[fdram] buf: ");
            for (k = 'h200; k <= 'h212; k = k + 1) $write(" %h", fdrive.ram[k]);
            $display("");
        end
    end
    fd_dbg_cnt <= fd_dbg_cnt + 21'd1;
    if ($test$plusargs("fddbg") && fd_dbg_cnt == 21'd0)
        $display("[fd] ticks=%d ab=%h motor=%b clkp=%b datap=%b | atn=%b clk=%b data=%b | cia2 pa=%h oe=%h outs a=%b c=%b d=%b",
                 fd_tick_cnt, fd_dbg_ab,
                 fd_dbg_motor, fd_clk_pull, fd_data_pull,
                 fd_wire_atn, fd_wire_clk, fd_wire_data,
                 cia2_pa_out, cia2_pa_oe,
                 iec_atn_out, iec_clk_out, iec_data_out);
end
`endif

drive_psram fdrive_mem(
    /* machine reset only — the first push byte arrives on the same clk
     * that fd_pushed rises, and a reset gated on it EATS that byte (found
     * as rom[0]=junk failing the DOS ROM checksum).  The drive-reset span
     * instead FLUSHES the GCR FIFO so no stale pre-push bytes survive. */
    .clk(clk), .rst(~rst), .gcr_flush(fd_rst),
    .rom_addr(fd_rom_addr), .rom_sel(fd_rom_sel), .rom_data(fd_rom_data),
    .gcr_addr(fd_gcr_addr), .gcr_data(fd_gcr_data),
    .stall(fd_stall),
    .push_we(fd_push_we), .push_addr(fd_push_addr),
    .push_data(ql_rom_data), .push_busy(fd_push_busy),
    .ps_addr(fd_ps_addr), .ps_rd(fd_ps_rd), .ps_wr(fd_ps_wr),
    .ps_byte(fd_ps_byte), .ps_words(fd_ps_words), .ps_wdata(fd_ps_wdata),
    .ps_rdata(fd_ps_rdata), .ps_rdy(fd_ps_rdy), .ps_busy(fd_ps_busy)
);

/* The drive CANNOT run slow: the KERNAL's bit-valid windows are ~20-26 us
 * and a drive stretched by per-ROM-cycle fetch overruns misses them (found
 * the hard way: OPEN's command bytes corrupted, dir never searched, TALK
 * had nothing to send).  psram.v at CLKDIV=1 needs ~37 clk per byte — over
 * the 32-clk phi — so the FPGA build uses psram_fast (SCLK = 2x clk via
 * the PLL's second output, ~12-16 clk per byte incl. CDC: no stretch on
 * the ROM path at all; GCR collisions stay inside the phi).  The sim runs
 * the contract-exact behavioural engine at psram_fast-realistic latencies
 * (modelling the fast clock would cost
 * 4 evals per clk for nothing). */
`endif  /* FDRIVE */

/* ── the PSRAM subsystem: one chip, one engine, up to two clients ───────
 * There is exactly one APS6404L on the board, so EasyFlash and the fabric
 * 1541 share it through psram_hub.v (drive first — see the hub's header for
 * why that priority is not negotiable).  Which ENGINE serves them follows
 * the drive: it cannot run slow, so any build with FDRIVE uses psram_fast
 * off the PLL's second output, and the cart rides along at that speed.  A
 * cart-only build keeps the exact engine its board bring-up proved. */
`ifdef C64_PSRAM
wire [23:0] eng_addr;
wire        eng_rd, eng_wr, eng_byte;
wire [3:0]  eng_words;
wire [31:0] eng_wdata, eng_rdata;
wire        eng_rdy, eng_word_rdy, eng_busy;
wire [2:0]  eng_word_idx;
wire [31:0] eng_dbg_id;

/* pads exist as local wires only where a pin-level engine is instantiated
 * (the FDRIVE sim runs the behavioural engine and has no pads at all) */
`ifdef SIMULATION
`ifndef FDRIVE
wire psram_sclk, psram_ce_n;
wire psram_sio0, psram_sio1, psram_sio2, psram_sio3;
`endif
`endif

`ifdef FDRIVE
  `ifdef EASYFLASH
psram_hub pshub(
    .clk(clk), .rst(rst),
    .c0_addr(fd_ps_addr), .c0_rd(fd_ps_rd), .c0_wr(fd_ps_wr),
    .c0_byte(fd_ps_byte), .c0_words(fd_ps_words), .c0_wdata(fd_ps_wdata),
    .c0_rdy(fd_ps_rdy), .c0_word_rdy(), .c0_word_idx(),
    .c0_busy(fd_ps_busy),
    .c1_addr(ef_ps_addr), .c1_rd(ef_ps_rd), .c1_wr(ef_ps_wr),
    .c1_byte(ef_ps_byte), .c1_words(ef_ps_words), .c1_wdata(ef_ps_wdata),
    .c1_rdy(ef_ps_rdy), .c1_word_rdy(ef_ps_word_rdy),
    .c1_word_idx(ef_ps_word_idx), .c1_busy(ef_ps_busy),
    .e_addr(eng_addr), .e_rd(eng_rd), .e_wr(eng_wr),
    .e_byte(eng_byte), .e_words(eng_words), .e_wdata(eng_wdata),
    .e_rdy(eng_rdy), .e_word_rdy(eng_word_rdy),
    .e_word_idx(eng_word_idx), .e_busy(eng_busy)
);
assign fd_ps_rdata = eng_rdata;
assign ef_ps_rdata = eng_rdata;
  `else
assign eng_addr  = fd_ps_addr;  assign eng_rd    = fd_ps_rd;
assign eng_wr    = fd_ps_wr;    assign eng_byte  = fd_ps_byte;
assign eng_words = fd_ps_words; assign eng_wdata = fd_ps_wdata;
assign fd_ps_rdata = eng_rdata; assign fd_ps_rdy = eng_rdy;
assign fd_ps_busy  = eng_busy;
  `endif
`else   /* EASYFLASH only: the cart owns the engine outright */
assign eng_addr  = ef_ps_addr;  assign eng_rd    = ef_ps_rd;
assign eng_wr    = ef_ps_wr;    assign eng_byte  = ef_ps_byte;
assign eng_words = ef_ps_words; assign eng_wdata = ef_ps_wdata;
assign ef_ps_rdata    = eng_rdata;   assign ef_ps_rdy      = eng_rdy;
assign ef_ps_word_rdy = eng_word_rdy; assign ef_ps_word_idx = eng_word_idx;
assign ef_ps_busy     = eng_busy;
`endif

`ifdef EASYFLASH
assign ef_psram_id = eng_dbg_id[15:0];      // MFID, KGD
`endif

/* The drive CANNOT run slow: the KERNAL's bit-valid windows are ~20-26 us
 * and a drive stretched by per-ROM-cycle fetch overruns misses them (found
 * the hard way: OPEN's command bytes corrupted, dir never searched, TALK
 * had nothing to send).  psram.v at CLKDIV=1 needs ~37 clk per byte — over
 * the 32-clk phi — so any FDRIVE build uses psram_fast (SCLK = 2x clk via
 * the PLL's second output, ~12-16 clk per byte incl. CDC: no stretch on
 * the ROM path at all; GCR collisions stay inside the phi).  The sim runs
 * the contract-exact behavioural engine at psram_fast-realistic latencies
 * (modelling the fast clock would cost
 * 4 evals per clk for nothing). */
`ifdef FDRIVE
  `ifdef SIMULATION
psram_cmd_behav #(.RD_LAT(14), .WR_LAT(8)) fd_ps0(
    .clk(clk),
    .cmd_addr(eng_addr), .cmd_rd(eng_rd), .cmd_wr(eng_wr),
    .cmd_byte(eng_byte), .cmd_words(eng_words), .cmd_wdata(eng_wdata),
    .rdata(eng_rdata), .rdy(eng_rdy),
    .word_rdy(eng_word_rdy), .word_idx(eng_word_idx), .busy(eng_busy)
);
assign eng_dbg_id = 32'h0000_0D5D;      // what an APS6404L answers
  `else
psram_fast fd_ps0(
    .clk(clk), .psram_clk(psram_clk), .rst(rst),
    .cmd_addr(eng_addr), .cmd_rd(eng_rd), .cmd_wr(eng_wr),
    .cmd_byte(eng_byte), .cmd_words(eng_words), .cmd_wdata(eng_wdata),
    .rdata(eng_rdata), .rdy(eng_rdy),
    .word_rdy(eng_word_rdy), .word_idx(eng_word_idx), .busy(eng_busy),
    .psram_sclk(psram_sclk), .psram_ce_n(psram_ce_n),
    .psram_sio0(psram_sio0), .psram_sio1(psram_sio1),
    .psram_sio2(psram_sio2), .psram_sio3(psram_sio3),
    /* raw bring-up console unused here — tie EVERY input (undriven inputs
     * bake x into LUTs: the netlist-sim-undriven-wires hard rule) */
    .raw_en(1'b0), .raw_sclk(1'b0), .raw_ce_n(1'b1),
    .raw_oe(1'b0), .raw_sio(4'b0), .raw_sio_in(),
    .dbg_id(eng_dbg_id)
);
  `endif
`else   /* cart only — the slow engine its bring-up proved, unchanged */
psram ef_ps0 (
    .clk(clk), .rst(rst),
    .cmd_addr(eng_addr), .cmd_rd(eng_rd), .cmd_wr(eng_wr),
    .cmd_byte(eng_byte), .cmd_words(eng_words), .cmd_wdata(eng_wdata),
    .rdata(eng_rdata), .rdy(eng_rdy),
    .word_rdy(eng_word_rdy), .word_idx(eng_word_idx), .busy(eng_busy),
    .psram_sclk(psram_sclk), .psram_ce_n(psram_ce_n),
    .psram_sio0(psram_sio0), .psram_sio1(psram_sio1),
    .psram_sio2(psram_sio2), .psram_sio3(psram_sio3),
    .raw_en(1'b0), .raw_sclk(1'b0), .raw_ce_n(1'b1),
    .raw_oe(1'b0), .raw_sio(4'b0), .raw_sio_in(),
    .dbg_state(), .dbg_id(eng_dbg_id)
);
`endif

`ifdef SIMULATION
`ifndef FDRIVE
/* the QPI engine needs the behavioural APS6404L to talk to (junk-filled —
 * real DRAM is never zeros) */
psram_chip_model psram_chip0 (
    .psram_sclk (psram_sclk), .psram_ce_n (psram_ce_n),
    .psram_sio0 (psram_sio0), .psram_sio1 (psram_sio1),
    .psram_sio2 (psram_sio2), .psram_sio3 (psram_sio3)
);
`endif
`endif
`endif  /* C64_PSRAM */

/* DOS-over-link: while the link owns the bus the fabric pulls CLK low on the
 * machine's behalf, because the drive would.  See bus_hold_clk in
 * common/qspi_slave.v — without it the TKSA turnaround at $EDD6 spins for
 * ever and the machine never reaches ACPTR. */
`ifndef FDRIVE
wire fd_clk_pull  = 1'b0;           /* no fabric drive in this build */
wire fd_data_pull = 1'b0;
assign fd_stat_w = 8'h00;           /* FD_STATUS reads "no fabric drive" */
assign fd_done_w = 8'h00;
`endif
wire iec_clk_lvl  = iec_clk_s2  & ~bus_hold_clk & ~fd_clk_pull;
wire iec_data_lvl = iec_data_s2 & ~fd_data_pull;

wire [7:0] cia2_pa_in = {iec_data_lvl & cia2_pa_out[7],
                         iec_clk_lvl  & cia2_pa_out[6],
                         cia2_pa_out[5:0]};

mos6526 cia2(
    .mode   (1'b0),
    .clk    (clk),
    .phi2_p (phi2_p && mrun),
    .phi2_n (phi2_n && mrun),
    .res_n  (rst),
    .cs_n   (~(sel_cia2 && cpu_live && mrun && !ef_hold)),  // stall: see vic_ce_n
    .rw     (~cpu_we),
    .rs     (cpu_addr[3:0]),
    .db_in  (cpu_data_out),
    .db_out (cia2_data_out),
    .db_out_live (cia2_data_live),
    .pa_in  (cia2_pa_in),
    .pa_out (cia2_pa_out),
    .pa_oe  (cia2_pa_oe),
    .pb_in  (8'hFF),
    .pb_out (),
    .pb_oe  (),
    .flag_n (1'b1),
    .pc_n   (),
    .tod    (tod_clk),
    .sp_in  (1'b1),
    .sp_out (),
    .cnt_in (1'b1),
    .cnt_out(),
    .irq_n  (cia2_irq_n)
);

/* ── TOD clock (50 Hz from the VIC raster) ─────────────────────────────── */
/* Two toggles per PAL frame (lines 0 and 156) = 50 Hz square wave, the
 * mains reference the CIA TOD divider expects. */
reg tod_clk;
reg [8:0] prev_raster_line;
always @(posedge clk) begin
    if (!rst) begin
        tod_clk <= 0;
        prev_raster_line <= 0;
    end else begin
        prev_raster_line <= vic_raster_line;
        if (prev_raster_line != vic_raster_line &&
            (vic_raster_line == 9'd0 || vic_raster_line == 9'd156))
            tod_clk <= ~tod_clk;
    end
end

/* ── Keyboard: UART PETSCII → shared typer → 8x8 matrix ────────────────── */
/* (see retro-arch/common/kbd_typer.v for the protocol) */
localparam SOC_CLK_HZ = 31_527_955;
wire [7:0] uart_rx_data;
wire       uart_rx_raw;      // uart rxen TOGGLES per byte
reg        uart_rx_prev;
always @(posedge clk) uart_rx_prev <= uart_rx_raw;
wire uart_rx_valid = uart_rx_raw ^ uart_rx_prev;   // 1-clk pulse per byte

/* ── UART control bytes (never typed) ─────────────────────────────────────
 *   $02 = machine reset (CPU reset pulse; the KERNAL re-inits the chips)
 *   $03 = RUN/STOP tap — handled by c64_kbd_map, passes through the typer
 *   $04 = RUN/STOP+RESTORE: hold STOP ~150ms and pulse NMI mid-hold      */
wire uart_is_ctrl = (uart_rx_data == 8'h02) || (uart_rx_data == 8'h04);
reg [15:0] ctrl_rst_cnt;
wire ctrl_reset = (ctrl_rst_cnt != 0);
reg [22:0] rs_cnt;
wire ctrl_stop_hold = (rs_cnt != 0);
wire ctrl_nmi = (rs_cnt > 23'd1_500_000) && (rs_cnt < 23'd3_000_000);
always @(posedge clk or negedge rst)
    if (!rst) begin
        ctrl_rst_cnt <= 0;
        rs_cnt <= 0;
    end else begin
        if (uart_rx_valid && uart_rx_data == 8'h02) ctrl_rst_cnt <= 16'hFFFF;
        else if (ctrl_rst_cnt != 0) ctrl_rst_cnt <= ctrl_rst_cnt - 1'b1;
        if (uart_rx_valid && uart_rx_data == 8'h04) rs_cnt <= 23'd4_600_000;
        else if (rs_cnt != 0) rs_cnt <= rs_cnt - 1'b1;
    end
wire [63:0] ctrl_matrix = ctrl_stop_hold ? (64'd1 << 6'd63) : 64'd0; // STOP {7,7}

wire [7:0] map_code;
wire map_valid, map_shift, map_cbm, map_ctrl, map_prefix;
wire [5:0] map_key;
c64_kbd_map kbd_map(
    .code(map_code), .valid(map_valid), .shift(map_shift),
    .cbm(map_cbm), .ctrl(map_ctrl), .prefix(map_prefix), .key(map_key)
);

`ifdef GAME_PRG
/* Hands-free start: baked autorun script (pointer POKEs + RUN/SYS from
 * roms/prg2hex.py) typed by hardware after boot — replaces the old
 * sim_top.cpp C++ autorun, so sim and future hardware share the path. */
wire [7:0] boot_key;
wire       boot_key_valid;
boot_typer #(.CLK_HZ(SOC_CLK_HZ)) boot_typer0(
    .clk(clk), .rst(rst),
    .key_data(boot_key), .key_valid(boot_key_valid)
);
wire [7:0] typer_rx_data  = boot_key_valid ? boot_key : uart_rx_data;
wire       typer_rx_valid = (uart_rx_valid & ~uart_is_ctrl) | boot_key_valid;
`else
wire [7:0] typer_rx_data  = uart_rx_data;
wire       typer_rx_valid = uart_rx_valid & ~uart_is_ctrl;
`endif

wire [63:0] typer_matrix;
kbd_typer #(.CLK_HZ(SOC_CLK_HZ)) kbd_typer0(
    .clk(clk), .rst(rst),
    .rx_data(typer_rx_data), .rx_valid(typer_rx_valid),
    .map_code(map_code), .map_valid(map_valid),
    .map_shift(map_shift), .map_cbm(map_cbm), .map_ctrl(map_ctrl),
    .map_prefix(map_prefix), .map_key(map_key),
    .shift_key({3'd1, 3'd7}),        // LSHIFT
    .cbm_key  ({3'd7, 3'd5}),        // C=
    .ctrl_key ({3'd7, 3'd2}),        // CTRL
    .matrix(typer_matrix)
);

/* Board buttons: TEXT mode holds SHIFT+CRSR matrix keys + RETURN/SPACE,
 * JOY modes drive joystick port 1 or 2; the BIOS selects over the link
 * (SET_BTNMODE), the A+B chord toggles TEXT <-> last joystick port. */
wire [63:0] btn_matrix;
wire [4:0] btn_joy1_n, btn_joy2_n;
wire [1:0] kbd_btn_mode;

/* BOTH mode (3) mirrors the buttons onto port 1 as well, and port 1 pulls
 * the very lines the keyboard scan reads ($DC01) — a held direction would
 * read as a keypress in whatever column the scan is driving, which on a
 * title that also reads the keyboard (Pirates!) is spurious commands all
 * game.  So the port-1 copy is hidden from the scan.
 *
 * WHICH reads are the scan is decided by where the CPU is executing, not by
 * bus timing.  A "recently wrote a column to $DC00" window cannot tell
 * SCNKEY's $EA90 (STA $DC00 #$00 / LDA $DC01) from the identical idiom a
 * game uses to sample the keyboard and joystick 1 in one pass — and it ate
 * Pirates!' intro, which polls port 1 exactly that way (board-tested
 * 2026-08-04: BOTH worked in the game, dead in the demo).
 *
 * Only KERNAL code turns $DC01 bits into keypresses (SCNKEY $EA87 and
 * UDTIM's $F6C9 STOP probe are the whole population), and every one of those
 * reads is absolute-addressed, so the CPU cycle right before the read is
 * that instruction's own operand fetch — in KERNAL ROM.  Game code, wherever
 * it lives, fetches from RAM or BASIC ROM.  kernal_age counts CPU cycles
 * since the bus last addressed KERNAL ROM (cpu_live gates it, so a VIC-
 * stolen cycle does not age the count); <= 1 means "this read belongs to
 * KERNAL code".  Bonus: UDTIM's $91 STOP-key byte stays clean, so RUN/STOP
 * still works with a direction held.
 *
 * Deliberately NOT applied in MODE_JOY1: picking port 1 explicitly should
 * behave exactly like real hardware, phantom keypresses included.
 *
 * NOT COMPILED IN by default (`JOY1_SCAN_BLANK`).  Board-tested twice on
 * 2026-08-04 — first with a 32-cycle post-write window, then with the gate
 * below — and Pirates!' intro stayed dead under both while the game kept
 * working, which is the signature of the port-1 copy never arriving at all,
 * not of it arriving and being blanked.  Two implementations failing
 * identically clears the blanking of suspicion, so the mirror ships raw
 * while the actual cause is being bisected; the phantom-key risk this
 * guarded against has not been observed yet, and if it shows up it will
 * show up as stray keyboard commands while a direction is held. */
reg [1:0] kernal_age = 2'd3;        // saturating; 0 = this cycle is in ROM
always @(posedge clk) begin
    if (!rst)
        kernal_age <= 2'd3;
    else if (phi2_p && cpu_live && mrun)
        kernal_age <= sel_kernal      ? 2'd0 :
                      (kernal_age == 2'd3) ? 2'd3 : kernal_age + 1'b1;
end
`ifdef JOY1_SCAN_BLANK
wire btn_joy1_blank = (kbd_btn_mode == 2'd3) && (kernal_age <= 2'd1);
`else
wire btn_joy1_blank = 1'b0;
`endif

kbd_buttons #(.CLK_HZ(SOC_CLK_HZ),
    .DEFAULT_MODE(2'd2),          // c64 games overwhelmingly use port 2
    .KEY_UP     ({3'd0, 3'd7}), .UP_SHIFT(1'b1),    // SHIFT+CRSR-DN
    .KEY_DOWN   ({3'd0, 3'd7}),
    .KEY_LEFT   ({3'd0, 3'd2}), .LEFT_SHIFT(1'b1),  // SHIFT+CRSR-R
    .KEY_RIGHT  ({3'd0, 3'd2}),
    .KEY_BTNA   ({3'd0, 3'd1}),   // RETURN
    .KEY_BTNB   ({3'd7, 3'd4}),   // SPACE
    .KEY_F1     ({3'd0, 3'd4}),   // btn C = F1 (every mode)
    .KEY_F2     ({3'd0, 3'd4}), .F2_SHIFT(1'b1)  // btn D = F2 = SHIFT+F1
) kbd_buttons0(
    // BIOS mode: buttons go to the MCU (BTN_READ over the link), not to
    // the frozen machine
    .clk(clk), .rst(rst), .btn_n(bios_mode ? 8'hFF : btn),
    .mode_set(btn_mode_stb), .mode_in(btn_mode), .mode(kbd_btn_mode),
    .joy1_blank(btn_joy1_blank),
    .joy1_n(btn_joy1_n), .joy2_n(btn_joy2_n), .matrix(btn_matrix)
);

kbd_matrix kbd_matrix0(
    .matrix(typer_matrix | btn_matrix | ctrl_matrix),
    .row_n(key_row_select), .col_n(key_col_result)
);

/* Joystick port 2 shares CIA1 PA with the keyboard rows:
 * PA0=up PA1=down PA2=left PA3=right PA4=fire (active low).
 * joy[4:0] = {fire, up, down, left, right}. */
wire [4:0] joy2_n = joy & btn_joy2_n;
/* Pin level = driven row-select value AND the joystick's open-collector
 * pull (same PRA-reads-pins rule as CIA2 — matches real HW, where a
 * joystick in port 2 can pull keyboard row lines). */
wire [7:0] cia1_pa_in = cia1_pa_out & {3'b111, joy2_n[4], joy2_n[0],
                                       joy2_n[1], joy2_n[2], joy2_n[3]};

/* ── UART ──────────────────────────────────────────────────────────────── */
wire uart_txbusy;
uart uart_inst(
    .clk    (clk),
    .rst    (rst),
    .rx     (rx),
    .tx     (tx),
    .rxdata (uart_rx_data),
    .rxen   (uart_rx_raw),
    .txdata (dbg_byte),
    .txen   (dbg_txen),
    .txbusy (uart_txbusy)
);

/* ── Debug: 'P' over UART dumps a status snapshot ──────────────────────── */
/* Response: 16 hex digits + CRLF = AAAAPPPPRRRRBBCC where
 *   AAAA = CPU address at the last RDY tick (hot address / where it loops)
 *   PPPP = free-running phi2 counter   (changes between two Ps ⇒ VIC's
 *          clock divider is alive)
 *   RRRR = VIC raster line             (changes ⇒ raster advancing)
 *   BB   = {5'b0, charen, hiram, loram} (browsable banking state, $37
 *          after a healthy KERNAL boot)
 *   CC   = cpu_rdy counter             (frozen while PPPP moves ⇒ CPU
 *          stalled on BA / dead)
 * The 'P' also lands in kbd_typer and types P on the machine — harmless,
 * and doubles as a keyboard-path liveness check. */
reg [15:0] dbg_addr_q /* verilator public_flat_rd */;
reg [15:0] dbg_phi_cnt;
reg  [7:0] dbg_rdy_cnt;
always @(posedge clk) begin
    if (phi2_p) dbg_phi_cnt <= dbg_phi_cnt + 1;
    if (cpu_rdy) begin
        dbg_rdy_cnt <= dbg_rdy_cnt + 1;
        dbg_addr_q  <= cpu_addr;
    end
end

function [7:0] dbg_hex(input [3:0] v);
    dbg_hex = (v < 10) ? ("0" + v) : ("A" + v - 4'd10);
endfunction

reg [87:0] dbg_pay;
reg  [4:0] dbg_left;   // bytes still to send (24 = 22 nibbles + CR + LF)
reg        dbg_txen;
reg  [1:0] dbg_st;     // 0 idle, 1 start byte, 2 wait busy, 3 wait done
wire [7:0] dbg_byte = (dbg_left == 5'd2) ? 8'h0D :
                      (dbg_left == 5'd1) ? 8'h0A :
                                           dbg_hex(dbg_pay[87:84]);
always @(posedge clk) begin
    if (!rst) begin
        dbg_st <= 0; dbg_left <= 0; dbg_txen <= 0;
    end else case (dbg_st)
        2'd0: if (uart_rx_valid && uart_rx_data == "P") begin
                  /* AAAA PPPP RRRR BC RR OO IIII
                   *   AAAA cpu_addr at the last ready tick   PPPP phi count
                   *   RRRR raster line                       RR   ready count
                   *   B    cart state {0,mounted,/EXROM,/GAME}: 3 = healthy
                   *        no-cart boot, 4 = cart in 16K mode
                   *   C    {0,charen,hiram,loram}
                   *   OO   cart loader DROP COUNTER — MUST read 00.  The
                   *        push FIFO has no flow control, so a master that
                   *        outruns the PSRAM writer silently loses bytes and
                   *        the cart boots to a blank screen with nothing
                   *        else to see (board-reported 2026-08-06, a 4-lane
                   *        push at 1.5 MB/s against a ~1.3 MB/s drain).
                   *   IIII PSRAM SPI Read-ID: 0D5D on an APS6404L.  Together
                   *        these two say which of "no memory", "holes in the
                   *        image" and "neither" a blank screen is.
                   * Both are also the ONLY readers of those signals — unread,
                   * yosys deletes the counter and the ID register outright. */
                  dbg_pay  <= {dbg_addr_q, dbg_phi_cnt,
                               7'b0, vic_raster_line,
                               1'b0, cart_mounted, ef_exrom_n, ef_game_n,
                               1'b0, charen, hiram, loram,
                               dbg_rdy_cnt, ef_push_ovr, ef_psram_id};
                  dbg_left <= 5'd24;
                  dbg_st   <= 2'd1;
              end
        2'd1: if (!uart_txbusy) begin
                  dbg_txen <= ~dbg_txen;         // toggle starts a byte
                  dbg_st   <= 2'd2;
              end
        2'd2: if (uart_txbusy) dbg_st <= 2'd3;   // byte accepted
        2'd3: if (!uart_txbusy) begin            // byte fully shifted out
                  if (dbg_left > 5'd2)           // don't shift for CR/LF
                      dbg_pay <= {dbg_pay[83:0], 4'b0};
                  dbg_left <= dbg_left - 5'd1;
                  dbg_st   <= (dbg_left == 5'd1) ? 2'd0 : 2'd1;
              end
    endcase
end

/* ── LED heartbeats ────────────────────────────────────────────────────── */
/* led1 blinks ~1.8 Hz from the CPU RDY stream (CPU advancing);
 * led2 blinks ~1.5 Hz from VIC frames (raster running).  Both dark or
 * frozen tells which half of the clock/reset chain is dead. */
reg [19:0] beat_rdy;
reg  [5:0] beat_frame;
always @(posedge clk) begin
    if (cpu_rdy) beat_rdy <= beat_rdy + 1;
    if (prev_raster_line != vic_raster_line && vic_raster_line == 9'd0)
        beat_frame <= beat_frame + 1;
end
assign led1 = beat_rdy[19];
assign led2 = beat_frame[4];

/* ── CPU data bus: two-stage registered read ───────────────────────────── */
/* Arlet's computed-address reads are live on the bus for exactly the one
 * cpu_rdy tick (T), so everything that depends on cpu_addr is captured at
 * T: the EBR sync-read ports take the address there (ram_cpu_q & co land
 * one tick later) and the combinational peripheral live-read data + bank
 * selects are latched as-is.  At T+1 (cpu_rdy_d) cpu_data_in commits from
 * the latched selects and the just-landed EBR data.  The CPU core only
 * samples DI at RDY ticks — the next one is a full phi cycle away — so
 * the one-tick-late commit is invisible to it, and it is what lets the
 * 64KB RAM and the ROMs live in synchronous-read EBR on the FPGA. */
reg cpu_rdy_d;
reg sel_ddr_q, sel_port_q, sel_basic_q, sel_kernal_q, sel_charrom_q;
reg sel_vic_q, sel_sid_q, sel_color_q, sel_cia1_q, sel_cia2_q, sel_exp_q;
reg sel_cart_q /* verilator public_flat_rd */, sel_efram_q;
reg [7:0] ddr_q, port_q, vic_q, sid_q, cia1_q, cia2_q, exp_q;

always @(posedge clk) begin
    cpu_rdy_d <= cpu_rdy;
    if (cpu_rdy) begin
        sel_ddr_q     <= (cpu_addr == 16'h0000);
        sel_port_q    <= (cpu_addr == 16'h0001);
        sel_basic_q   <= sel_basic;
        sel_kernal_q  <= sel_kernal;
        sel_charrom_q <= sel_charrom;
        sel_vic_q     <= sel_vic;
        sel_sid_q     <= sel_sid;
        sel_color_q   <= sel_color;
        sel_cia1_q    <= sel_cia1;
        sel_cia2_q    <= sel_cia2;
        ddr_q         <= cpu_ddr;
        port_q        <= cpu_port_read;
        vic_q         <= vic_dbo_live;
        sid_q         <= sid_rdata;
        cia1_q        <= cia1_data_live;
        cia2_q        <= cia2_data_live;
        sel_exp_q     <= sel_exp;
        exp_q         <= exp_rdata;
        sel_cart_q    <= sel_cart;
`ifdef EASYFLASH
        sel_efram_q   <= sel_efram;
`else
        sel_efram_q   <= 1'b0;
`endif
    end
end

always @(posedge clk) begin
    if (cpu_rdy_d)
        cpu_data_in <=
            sel_ddr_q     ? ddr_q :
            sel_port_q    ? port_q :
            sel_cart_q    ? 8'hFF :        // placeholder — EF commit below
`ifdef EASYFLASH
            sel_efram_q   ? efram_q :
`endif
            sel_basic_q   ? basic_q :
            sel_kernal_q  ? kernal_q :
            sel_charrom_q ? char_q :
            sel_vic_q     ? vic_q :
            sel_sid_q     ? sid_q :
            sel_color_q   ? {4'hF, color_q} :
            sel_cia1_q    ? cia1_q :
            sel_cia2_q    ? cia2_q :
            sel_exp_q     ? exp_q :
                            ram_q;
`ifdef EASYFLASH
    /* cart data lands whenever the PSRAM path answers (a hit: 2 clks after
     * the rdy tick; a miss: whenever the burst returns — ef_hold keeps the
     * next rdy tick away until this commit has happened, and the CPU only
     * samples DI at rdy ticks).  Textually later, so it wins the clk. */
    if (ef_commit && sel_cart_q)
        cpu_data_in <= ef_rdata_q;
`endif
end

/* ── C64 colour palette (16 colours in RGB565) ─────────────────────────── */
function [15:0] pal565(input [3:0] c);
    case (c)
        4'h0: pal565 = 16'h0000;  // black
        4'h1: pal565 = 16'hFFFF;  // white
        4'h2: pal565 = 16'hA104;  // red
        4'h3: pal565 = 16'h5EFB;  // cyan
        4'h4: pal565 = 16'hA1D7;  // purple
        4'h5: pal565 = 16'h4547;  // green
        4'h6: pal565 = 16'h2015;  // blue
        4'h7: pal565 = 16'hDF40;  // yellow
        4'h8: pal565 = 16'hA345;  // orange
        4'h9: pal565 = 16'h6262;  // brown
        4'hA: pal565 = 16'hD34A;  // light red
        4'hB: pal565 = 16'h4228;  // dark grey
        4'hC: pal565 = 16'h7BCF;  // grey
        4'hD: pal565 = 16'h8F0C;  // light green
        4'hE: pal565 = 16'h5C1E;  // light blue
        4'hF: pal565 = 16'hB596;  // light grey
    endcase
endfunction

/* ── Video out ─────────────────────────────────────────────────────────── */
/* Machine-mode LCD signals (muxed against the BIOS text screen below) */
wire m_hs, m_vs, m_de;
reg [15:0] m_data;

`ifdef SIMULATION
/* Simulation: capture the native VIC raster into a framebuffer, read it
 * back via lcd_out timing (same pattern as c16/soc.v).  PAL 6569 frame is
 * 504x312 dots; we grab a 480x272 window centered on the picture (the
 * 320x200 text window sits at raster_x 136..455, lines 51..250; the
 * surrounding capture area shows border color, as on a real CRT). */
wire [10:0] lcd_col, lcd_row;

lcd_out lcd0(
    .clk(clk), .rst(rst),
    .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
    .lcd_hsync(m_hs), .lcd_vsync(m_vs), .lcd_de(m_de),
    .row(lcd_row), .col(lcd_col)
);

localparam CAP_X0 = 10'd56;   // 136 - (480-320)/2
localparam CAP_Y0 = 9'd15;    // 51 - (272-200)/2
reg [15:0] framebuf [0:480*272-1];
wire [9:0] cap_x = vic_raster_x - CAP_X0;
wire [8:0] cap_y = vic_raster_line - CAP_Y0;
wire cap_en = (vic_raster_x >= CAP_X0) && (cap_x < 10'd480) &&
              (vic_raster_line >= CAP_Y0) && (cap_y < 9'd272);
always @(posedge clk)
    if (cap_en)
        framebuf[cap_y * 480 + cap_x] <= pal565(vic_pixel);

wire [9:0] fb_rx = lcd_col[9:0];
wire [8:0] fb_ry = lcd_row[8:0];
always @(posedge clk)
    if (!rst) m_data <= 0;
    else if (m_de) m_data <= framebuf[fb_ry * 480 + fb_rx];
`else
/* FPGA: single-BRAM line buffer genlocked to the VIC raster — the same
 * scheme as the c16 build (c16/soc.v), retuned for VIC-II timing.  A
 * 400-px window of each VIC line is captured at native dot rate, then
 * read back TWICE per VIC line (vertical doubling) with every pixel
 * repeated twice (horizontal doubling) → 800x480 on the panel.
 *
 * Rates: one PAL VIC line = 504 dots = 2016 dot4x clocks, so one LCD
 * sub-line is 1008 clocks (~31.3 kHz at the ~31.5 MHz dot4x = LCD pixel
 * clock); a frame is 312 VIC lines = 624 sub-lines ≈ 50 Hz — the same
 * line/frame rates the panel already locks to on the c16 build.  The
 * sub-line counter is re-aligned at every VIC line start, so clock-ratio
 * drift only ever trims blanked back-porch clocks — no rolling. */
localparam LCD_CAP_X0  = 10'd96;   // capture raster_x 96..495: 400 px
                                   // centered on the text window (136..455)
localparam LCD_HTOTAL  = 11'd1008; // one LCD sub-line = VIC line / 2
localparam LCD_HACTIVE = 11'd800;  // 400 source px, pixel-doubled
localparam LCD_HFP     = 11'd16;   // front porch
localparam LCD_HPW     = 11'd48;   // hsync pulse width
localparam LCD_VSTART  = 9'd31;    // first shown VIC line (text lines
localparam LCD_VEND    = 9'd271;   // 51..250 +20 border each side) ×2 = 480

reg [15:0] lbram [0:1023];        // ping-pong halves — one DP16KD
reg [15:0] lbram_rd;
reg        lb_half;
reg  [9:0] prev_raster_x;
wire       vic_line_start = (vic_raster_x == 10'd0) && (prev_raster_x != 10'd0);

/* Write port: capture the current VIC line (writes repeat across the 4
 * dot4x ticks of a dot; the last one wins, same as the sim framebuffer). */
wire [9:0] lb_cap_x = vic_raster_x - LCD_CAP_X0;
always @(posedge clk)
    if (lb_cap_x < 10'd400)
        lbram[{lb_half, lb_cap_x[8:0]}] <= pal565(vic_pixel);

reg [10:0] lh_cnt;                // LCD sub-line counter (0..1007)
reg lcd_hs_r, lcd_vs_r, lcd_de_r;
always @(posedge clk)
    if (!rst) begin
        lb_half <= 0; prev_raster_x <= 0; lh_cnt <= 0;
        lcd_hs_r <= 1; lcd_vs_r <= 1; lcd_de_r <= 0;
    end else begin
        prev_raster_x <= vic_raster_x;
        if (vic_line_start) begin
            lh_cnt  <= 0;
            lb_half <= ~lb_half;
        end else if (lh_cnt == LCD_HTOTAL - 1)
            lh_cnt <= 0;
        else
            lh_cnt <= lh_cnt + 1;

        lcd_de_r <= (lh_cnt < LCD_HACTIVE) &&
                    (vic_raster_line >= LCD_VSTART) &&
                    (vic_raster_line < LCD_VEND);
        lcd_hs_r <= !((lh_cnt >= LCD_HACTIVE + LCD_HFP) &&
                      (lh_cnt < LCD_HACTIVE + LCD_HFP + LCD_HPW));
        lcd_vs_r <= !((vic_raster_line >= 9'd285) &&
                      (vic_raster_line < 9'd288));
    end

assign m_hs = lcd_hs_r;
assign m_vs = lcd_vs_r;
assign m_de = lcd_de_r;

/* Read port: pixel-double — source column = output column / 2 (0..399);
 * reads the OTHER half (the line captured during the previous VIC line). */
wire [8:0] rd_idx = lh_cnt[9:1];
always @(posedge clk)
    lbram_rd <= lbram[{~lb_half, rd_idx}];

always @(posedge clk)
    if (!rst) m_data <= 0;
    else m_data <= lcd_de_r ? lbram_rd : 16'h0000;
`endif

/* ── BIOS text screen (MCU-driven over the QSPI link) + output mux ─────── */
wire b_hs, b_vs, b_de;
wire [15:0] b_data;
bios_text #(.HTOTAL(1008)) bios0(    // 1008-clk sub-line: the panel's
    .clk(clk), .rst(rst),            // proven line rate at dot4x
    .wr_addr(txt_waddr), .wr_data(txt_wdata), .wr_en(txt_wen),
    .lcd_hsync(b_hs), .lcd_vsync(b_vs), .lcd_de(b_de), .lcd_data(b_data)
);

/* Switch sources at the OUTGOING source's vsync edge (inside vertical
 * blanking) so the panel never sees a torn frame.  The VIC free-runs while
 * the machine is frozen, so an edge always arrives within one frame. */
reg bios_active, m_vs_p, b_vs_p;
always @(posedge clk)
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
 *    stream the line buffer to the MCU → USB hostlink → desktop). ─────── */
shot_cap shot0(
    .clk(clk), .rst(rst),
    .px_data(lcd_data), .px_de(lcd_de), .px_vs(lcd_vsync),
    .arm_stb(shot_arm_stb), .arm_line(shot_line), .arm_dense(shot_dense),
    .arm_pair(shot_pair),
    .armed(shot_armed), .ready(shot_ready),
    .raddr(shot_raddr), .rdata(shot_rdata)
);

endmodule

`undef C64_PSRAM
