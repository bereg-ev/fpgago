//
// qspi_slave.v — MCU⇄FPGA link slave + fastload engine (v2 board)
//
// Physical wiring (v2, fpga-gameconsole-2; MCU is always the SPI master):
//
//   net            RP2350   ECP5 ball   role here
//   FPGA-QSPI-SD0  GPIO6    A7          MOSI  (MCU → FPGA)
//   FPGA-QSPI-SD1  GPIO7    B7          MISO  (FPGA → MCU)
//   FPGA-QSPI-SD2  GPIO8    A8          REQ   (FPGA → MCU service request)
//   FPGA-QSPI-SD3  GPIO9    A9          spare (unconnected)
//   FPGA-QSPI-SCK  GPIO10   A10         SCK   (mode 0: idle low, sample on rise)
//   FPGA-QSPI-SS   GPIO11   B10         SS    (active low, frames a transaction)
//
// All SPI inputs are 2FF-synchronized in the system clock domain, so SCK must
// stay well below clk/6 (MCU side runs 1 MHz against ~28 MHz retro clocks).
//
// ── SPI framing (MSB first, one transaction per SS-low window) ────────────
//   master sends  [CMD][arg/dummy bytes...]
//   slave MISO    byte 0..1: 0x5C presence magic, byte 2+: response
//
//   0x04 PING       → resp 0xA5, ping_count, ~CMD (0xFB), 0x5C…
//   0x07 SET_VOLUME → master: [0x07][ALEN=1][vol 0..10];
//                     resp byte3 0xA5, byte4 = vol echo, byte5 = ~CMD (0xF8).
//                     Drives the vol_scale output (0..16, 16 = unity) the
//                     socs multiply into their audio path.
//   0x0C SET_BRIGHT → master: [0x0C][ALEN=1][bright 0..10];
//                     resp byte3 0xA5, byte4 = bright echo, byte5 = ~CMD
//                     (0xF3).  Drives bright_scale (0..64 duty) into
//                     common/lcd_backlight.v — the panel backlight is the
//                     biggest single load on the battery.  Powers up at
//                     BRI_PWRUP (5), matching the MCU's virgin-board default.
//   0x08 SET_BTNMODE → master: [0x08][ALEN=1][mode 0..3];
//                     resp byte3 0xA5, byte4 = mode echo, byte5 = ~CMD (0xF7).
//                     Drives btn_mode + a 1-clk btn_mode_stb pulse the socs
//                     feed to kbd_buttons (0=TEXT keys, 1=JOY1, 2=JOY2,
//                     3=BOTH ports at once).
//   0x10 REQ_FETCH  → resp [reqtype][name_len][name×16]; reqtype 0x01 = LOAD
//                     pending request, 0x00 = none. Frame end clears pending.
//   0x11 DATA_PUSH  → master: [0x11][LEN][LEN data bytes] → load FIFO
//   0x12 XFER_END   → master: [0x12][flags]; bit0 = EOF, bit1 = error
//   0x09 VERSION_READ → resp byte2 0xA5 tag, byte3-6 = bitstream date (u32,
//                     big-endian, decimal YYMMDDHHMM), byte7 = build# in day.
//   0x0A LINK_CFG   → master: [0x0A][ALEN=1][lanes 1|2|4];
//                     resp byte3 0xA5, byte4 = lanes echo, byte5 = ~CMD (0xF5).
//                     The new lane count takes effect at the NEXT frame (SS
//                     rise applies it), so this frame completes in the old
//                     mode.  Boot is always 1 lane (legacy full-duplex).
//
// ── multi-lane framing (lanes = 2 or 4) ───────────────────────────────────
//   Half-duplex on SD0..SD{L-1}, MSB-first (SD{L-1} carries the MSB of each
//   2/4-bit chunk), same mode-0 clocking.  Per frame:
//     bytes [0, A)   master drives (command + args); A = 1 for read commands
//                    (PING/REQ_FETCH/VERSION/BTN_READ), 3 for echo commands
//                    (SET_VOLUME/SET_BTNMODE/DRIVE_MODE/LINK_CFG/SET_BRIGHT)
//     byte  A        turnaround — nobody drives; the board 10k pull-ups own
//                    the bus (sampled as 0xFF, ignored)
//     bytes A+1..    slave drives the response.  Read commands keep the
//                    LEGACY byte positions (first response byte at index 2);
//                    echo commands land one byte later than legacy (0xA5 at
//                    index 4 instead of 3).
//   Pure-write commands (DATA_PUSH/XFER_END/MODE_SET/TEXT_*) are master-
//   driven end-to-end and keep their exact legacy layout at any lane count.
//   The 0x5C presence magic exists only in 1-lane mode (probing/negotiation
//   happens there before any upshift).
//
//   0x0B DRIVE_MODE → master: [0x0B][ALEN=1][mode];
//                     resp byte3 0xA5, byte4 = mode echo, byte5 = ~CMD (0xF4).
//                     mode bit0: 0 = QSPI fastload (KERNAL LOAD detour serves
//                     the fastload routine), 1 = real-1541 IEC (the detour
//                     window serves a transparent fallback stub instead, so
//                     the baked KERNAL patch costs ~7 cycles and every LOAD
//                     goes down the stock IEC path — no watchdog stall).
//                     Single-bitstream mode switch; see PLAN docs.
//   0x0D FD_STATUS  → resp byte2 0xA5, byte3 = fabric-1541 status
//                     {4'b0, armed, led, motor, image_pushed}, byte4 = the
//                     8-bit load-done counter, byte5 = ~CMD (0xF2).
//                     Only the FDRIVE build wires it (elsewhere both bytes
//                     read 0, which the MCU reads as "no fabric drive").
//                     The counter is what the BIOS autostart waits on: the
//                     fabric drive's LOADs are invisible to the MCU — no
//                     fastload XFER_END, no IEC pins to sniff — so without
//                     this the "@load" macro step could only time out.
//   unknown         → resp 0x3C repeated
//
// ── floppy image host commands (parameter FDD=1; unused here) ───────────────
// The MCU plays the MiSTer HPS role for the chipset's ao486 floppy.v: it
// mounts an .img by programming the mgmt register file and serves sector
// requests through the byte-wide FIFO at mgmt reg 0xF.  The slave owns the
// mgmt bus (fdd_mgmt_* ports); `fdd_request` (read/write wanted) latches
// the LBA from mgmt reg 0 and raises REQ until the request is served.
//   0x50 FDD_MOUNT  → master: [0x50][flags][cyls][spt][heads][tot_lo][tot_hi]
//                     flags: bit0 = media present (0 = eject), bit1 = write
//                     protect, bit7 = drive.  Writes the geometry registers
//                     then media-present, one per clk.
//   0x51 FDD_STATUS → resp byte2 0xA5, byte3 = {5'b0, valid, wr, rd},
//                     byte4/5 = LBA hi/lo ({drive, sector[14:0]} from mgmt
//                     reg 0), byte6 = ~CMD.  valid=1 means the LBA bytes are
//                     current; REQ is only raised once valid.
//   0x52 FDD_PUSH   → master: [0x52][512 data bytes] — read-sector data into
//                     the floppy FIFO (mgmt reg 0xF), one write per byte.
//   0x53 FDD_PULL   → resp byte2 0xA5, byte3.. = 512 FIFO bytes (write
//                     sector drain; FIFO head presented then popped).
//   0x54 FDD_CTRL   → master: [0x54][ctl]; ctl bit0 = pulse machine reset
//                     (mount-and-reboot on disc launch; a mid-session disc
//                     swap sends MOUNT alone and does not reset).  ctl bit1
//                     = write CPU speed: bits[3:2] land in fdd_turbo (the
//                     XT_CE_Generator clk_select: 0=4.77 1=7.16 2=9.54
//                     3=max); with bit1 clear the speed is untouched, so
//                     reset-only and speed-only writes compose freely.
//
// ── BIOS-mode commands (MCU-driven 80x25 text screen, bios_text.v) ────────
//   0x20 MODE_SET   → master: [0x20][mode]; mode bit0: 1 = BIOS screen shown
//                     and the machine frozen, 0 = Commodore resumes
//   0x21 TEXT_WRITE → master: [0x21][cell_lo][cell_hi][char][attr]...; each
//                     char+attr pair writes one cell, autoincrementing
//   0x22 TEXT_FILL  → master: [0x22][char][attr][cell_lo][cell_hi][cnt_lo]
//                     [cnt_hi]; hardware fill engine, one cell per clk
//   0x23 BTN_READ   → resp [btn][~btn]; live board buttons, active low
//
// ── CPU register window (EXP bus from the machine core) ──────────────────
//   $FE20 W: 0x00 = reset engine (FIFO/name/flags), 0x01 = submit LOAD
//            request (raises REQ until the MCU fetches it)
//   $FE20 R: STATUS {avail, done, err, 5'b0}; done = EOF latched & FIFO empty
//   $FE21 W: append filename char (max 16)
//   $FE21 R: FIFO data (read strobe pops)
//   $FE22 R: FIFO count (debug)
//
// ── DOS-over-link bus channel (DRIVE_MODE 2) ─────────────────────────────
// The KERNAL's serial primitives are detoured into the routine window too,
// so a title that talks to the drive through channel I/O (OPEN/PRINT#/GET#,
// U1/B-P block reads — the Pirates! class) moves its bytes over the link
// instead of the 1.35 ms-per-byte IEC wire.  Every outgoing byte funnels
// through one KERNAL routine ($ED40) and every incoming byte through
// another ($EE13), so two detours cover the whole bus.
//
//   $DF03 W: byte sent UNDER ATN (LISTEN/TALK/SECOND/UNLSN/UNTLK).  Appends
//            to the name buffer, decodes addressing, and submits the
//            transaction (ATN bytes are the transaction boundaries).
//   $DF04 W: channel data byte (CIOUT).  Appends; submits when the buffer
//            is full, so a long write streams instead of overflowing.
//   $DF03 R: BUS STATUS {own, avail, eoi, done, err, pending, 2'b0}
//            own     = the last LISTEN/TALK addressed OUR device, so the
//                      detour owns this transaction; 0 = hand it back to
//                      the stock KERNAL (a real device may be out there)
//            eoi     = the byte at the FIFO head is the LAST of the
//                      transfer (cnt==1 with EOF latched) — ACPTR needs
//                      this WITH the byte, not after it
//            pending = the MCU has not fetched the submitted bytes yet
//
// REQ_FETCH answers reqtype 0x02 for these, with the ATN mask in bytes
// 20/21: one bit per buffered byte, 1 = that byte was sent under ATN.
//   $FD60-$FDCF R: fastload 6502 routine ROM (generated fastload_rom.vh) —
//            the 264 I/O hole shadows the KERNAL image here, so the routine
//            the patched KERNAL jumps to is served by this window instead.
//
// A ~1.2 s watchdog (2^25 sys clocks) covers a dead/absent MCU: it forces
// err+done so the 6502 routine falls back to the real KERNAL LOAD path.
//
// REQ = request pending, or (transfer open & not ended & FIFO has ≥32 free):
// the MCU's own state machine distinguishes "fetch me" from "feed me".
//
module qspi_slave #(
    // 0 = 264 machines (c16/plus4): regs $FE20-2, routine $FD60/$FE30
    // 1 = C64: regs $DF00-2 (I/O2), routine $DE00-$DE7F (I/O1)
    parameter C64 = 0,
    // 1 = floppy image host bridge (unused by the Commodore machines):
    // FDD_* commands drive the
    // ao486 floppy.v mgmt bus through the fdd_mgmt_* ports
    parameter FDD = 0,
    // 1 = ROM bank loader (ROM-free bitstreams): ROM_* commands write the
    // machine's kernal/basic/chargen arrays after configuration, so no
    // copyrighted bytes ship in the bit.  bitstreams/README.md.
    parameter ROMLOAD = 0,
    // Width of the per-bank byte pointer.  16 bits (64 KB) covers every
    // Commodore bank; a machine with larger ROMs raises it, because a half is
    // 512 KB.  Consumers connect narrower wires and Verilog truncates, so
    // widening this costs the existing machines nothing.
    parameter ROM_AW = 16
)(
    input clk,
    input rst,          // active-low async, same idiom as the retro SoCs

    input  spi_sck,
    input  spi_ss,
    // Data lanes SD3..SD0.  1-lane (boot/legacy): SD0 = MOSI in, SD1 = MISO
    // out.  Multi-lane (LINK_CFG): half-duplex on SD0..SD{L-1}, per-lane
    // output enables.  The top level resolves the pads (SD2 doubles as REQ
    // while SS is high; SD3/A9 doubles as IEC DATA in drive mode).
    input  [3:0] spi_sd_in,
    output [3:0] spi_sd_out,
    output [3:0] spi_sd_oe,
    output req,

    // BIOS mode (all in the same clk domain)
    input  [7:0]      btn,        // live board buttons (active low), BTN_READ
    output reg        bios_mode,  // 1 = BIOS screen shown, machine frozen
    output reg [4:0]  vol_scale,  // audio scale 0..16 (16 = unity), SET_VOLUME
    output reg [6:0]  bright_scale, // backlight duty 0..64 (64 = full on),
                                    // SET_BRIGHT -> common/lcd_backlight.v
    output reg [1:0]  btn_mode,     // 0=TEXT 1=JOY1 2=JOY2, SET_BTNMODE
    output reg        btn_mode_stb, // 1-clk pulse when btn_mode was written
    output reg        drive_1541,   // DRIVE_MODE bit0: real-1541 IEC (fastload
                                    // detour serves the fallback stub)
    output reg        dos_link,     // DRIVE_MODE bit1: DOS over the link (the
                                    // KERNAL bus detours are live)
    // 1 = the link is the addressed device, so the fabric must present the
    // IEC lines the way a drive would.  The bus detours replace every
    // BYTE-level handshake, but not the wire-level talker turnaround at the
    // tail of TKSA ($EDCC-$EDDA): there the C64 releases ATN and CLK and then
    // spins on `JSR $EEA9 / BMI` until the DRIVE pulls CLK low.  Nothing on
    // an idle wire ever does, so every channel read hung there.  Holding CLK
    // low while we own the bus is exactly what the real drive does at that
    // point in the protocol.
    output            bus_hold_clk,

    // Fabric 1541 taps (FD_STATUS 0x0D).  Tie both to 0 on a machine without
    // the fabric drive — an undriven input bakes x into the LUTs
    // (netlist-sim-undriven-wires).
    input  [7:0]      fd_stat,    // {4'b0, armed, led, motor, image_pushed}
    input  [7:0]      fd_done,    // load-done counter, free-running, wraps

    // screen grab (shot_cap.v; all in the same clk domain)
    output reg        shot_arm_stb, // 1-clk pulse: arm shot_line capture
    output reg [8:0]  shot_line,
    output reg        shot_dense,   // 1 = 800 px, 0 = 400 px subsampled
    output reg        shot_pair,    // 1 = also capture shot_line+2 (2x grabs)
    output reg        shot_freeze,  // 1 = halt the machine (video free-runs)
                                    // for a tear-free grab; SHOT_FREEZE cmd
    input             shot_armed,
    input             shot_ready,
    output [9:0]      shot_raddr,   // line-buffer read port (sync, 1 clk)
    input  [15:0]     shot_rdata,
    output reg [10:0] txt_waddr,  // bios_text.v text RAM write port
    output reg [15:0] txt_wdata,
    output reg        txt_wen,

    // expansion bus from the machine core (single clk domain)
    input  [15:0] exp_addr,    // live CPU address (combinational reads)
    output [7:0]  exp_rdata,   // 8'hFF when not ours (wired-AND bus)
    input  [3:0]  exp_laddr,   // latched low addr for the strobes below
    input  [7:0]  exp_wdata,   // latched write data
    input         exp_wstb,    // 1-clk pulse: CPU wrote $FE2x
    input         exp_rstb,    // 1-clk pulse: CPU read  $FE2x

    // floppy image host bridge (FDD=1; tie fdd_request/fdd_mgmt_rdata to 0
    // and leave the outputs open on machines without it)
    input  [1:0]  fdd_request,     // floppy.v request: {write, read} wanted
    output reg [15:0] fdd_mgmt_addr,
    output reg [15:0] fdd_mgmt_wdata,
    output reg        fdd_mgmt_write,
    output reg        fdd_mgmt_read,
    input  [15:0] fdd_mgmt_rdata,
    output reg        fdd_reset_stb, // 1-clk pulse: FDD_CTRL machine reset
    output reg [1:0]  fdd_turbo,     // FDD_CTRL CPU speed (XT clk_select)

    // ROM bank loader (ROMLOAD=1; leave open / tie rom_valid unused otherwise).
    // The SoC decodes rom_bank into the per-array write strobes and holds the
    // machine in reset until the banks it needs are marked valid.
    output reg [2:0]  rom_bank,      // bank selected by ROM_BEGIN
    output reg [ROM_AW-1:0] rom_addr, // byte offset within that bank
    output reg [7:0]  rom_data,
    output reg        rom_we,        // 1-clk write strobe
    output reg [7:0]  rom_valid      // per-bank "fully written" bits
);

    localparam MAGIC = 8'h5C;
    localparam ERR   = 8'h3C;

    localparam CMD_PING       = 8'h04;
    localparam CMD_SET_VOLUME = 8'h07;
    localparam CMD_SET_BTNMODE = 8'h08;
    localparam CMD_VERSION_READ = 8'h09;   // → [0xA5][date b3..b0][build]
    localparam CMD_LINK_CFG   = 8'h0A;     // lanes 1|2|4, applied at SS rise
    localparam CMD_DRIVE_MODE = 8'h0B;     // 0 = fastload, 1 = real-1541 IEC
    localparam CMD_SET_BRIGHT = 8'h0C;     // backlight 0..10, SET_VOLUME shape
    localparam CMD_FD_STATUS  = 8'h0D;     // fabric-1541 status + load counter

    // Bitstream version, baked in at synthesis from build-iec.sh's -D defines
    // (VER_DATE = decimal YYMMDDHHMM as a u32, VER_BUILD = build# within day).
    // Absent on non-c64 / unstamped builds → 0, and the 0xA5 present-tag below
    // lets the MCU tell a version-aware bitstream from a pre-version one.
`ifdef BIT_VER_DATE
    localparam [31:0] VER_DATE  = `BIT_VER_DATE;
`else
    localparam [31:0] VER_DATE  = 32'd0;
`endif
`ifdef BIT_VER_BUILD
    localparam [7:0]  VER_BUILD = `BIT_VER_BUILD;
`else
    localparam [7:0]  VER_BUILD = 8'd0;
`endif
    localparam CMD_REQ_FETCH  = 8'h10;
    localparam CMD_DATA_PUSH  = 8'h11;
    localparam CMD_XFER_END   = 8'h12;
    // 0x13 XFER_STAT → [0xA5][cnt][~cmd]: bytes sitting in the FIFO that the
    // machine has NOT read yet.  The server needs this to keep the promise a
    // real drive keeps for free — that a byte the host never handshook for
    // was never sent.  It pushes ahead for speed, so on an UNTALK it asks how
    // much was left over and hands exactly that many bytes back to the DOS.
    localparam CMD_XFER_STAT  = 8'h13;
    localparam CMD_MODE_SET   = 8'h20;
    localparam CMD_TEXT_WRITE = 8'h21;
    localparam CMD_TEXT_FILL  = 8'h22;
    localparam CMD_BTN_READ   = 8'h23;

    // screen grab (common/shot_cap.v line capture):
    //   0x30 SHOT_ARM    [flags][line_lo][line_hi]  flags bit0 = dense,
    //                    bit1 = pair (also line+2; second line at byte 1024)
    //   0x31 SHOT_STATUS → [0xA5][{5'b0,freeze,armed,ready}][~CMD]
    //   0x32 SHOT_READ   [off_lo][off_hi] → [0xA5][line-buffer bytes…]
    //                    (RGB565 LE from byte offset, auto-increment; the
    //                    frame byte counter saturates at 255 so the MCU
    //                    chunks reads to ≤240 bytes)
    //   0x33 SHOT_FREEZE [on]  halt the machine (like BIOS mode, but the
    //                    display mux stays on the machine screen) so a
    //                    multi-second line-by-line grab is tear-free
    localparam CMD_SHOT_ARM    = 8'h30;
    localparam CMD_SHOT_STATUS = 8'h31;
    localparam CMD_SHOT_READ   = 8'h32;
    localparam CMD_SHOT_FREEZE = 8'h33;

    // ROM bank loader (ROMLOAD=1).  ROM_DATA carries as many bytes as the
    // master cares to send; the write pointer only rewinds on ROM_BEGIN, so a
    // bank is streamed as one BEGIN, N DATA frames, one END.
    localparam CMD_ROM_BEGIN  = 8'h60;     // [0x60][bank] select + rewind
    localparam CMD_ROM_DATA   = 8'h61;     // [0x61][bytes…]
    localparam CMD_ROM_END    = 8'h62;     // [0x62] mark the bank valid
    localparam CMD_ROM_STATUS = 8'h63;     // → [0xA5][valid mask][~cmd]

    localparam CMD_FDD_MOUNT  = 8'h50;
    localparam CMD_FDD_STATUS = 8'h51;
    localparam CMD_FDD_PUSH   = 8'h52;
    localparam CMD_FDD_PULL   = 8'h53;
    localparam CMD_FDD_CTRL   = 8'h54;

    // ── input synchronizers ────────────────────────────────────────────────
    // Power-up values match the async reset values (the ECP5 rule: yosys may
    // const-fold a never-deasserted rst, so FF INIT must equal reset state).
    reg [2:0] sck_s  = 3'b000;
    reg [2:0] ss_s   = 3'b111;
    reg [3:0] sd_s1  = 4'b0000;   // 2-FF per data lane
    reg [3:0] sd_s   = 4'b0000;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            sck_s  <= 3'b000;
            ss_s   <= 3'b111;
            sd_s1  <= 4'b0000;
            sd_s   <= 4'b0000;
        end else begin
            sck_s  <= {sck_s[1:0], spi_sck};
            ss_s   <= {ss_s[1:0], spi_ss};
            sd_s1  <= spi_sd_in;
            sd_s   <= sd_s1;
        end

    wire sck_rise = sck_s[1] & ~sck_s[2];
    wire sck_fall = ~sck_s[1] & sck_s[2];
    wire ss_fall  = ~ss_s[1] & ss_s[2];
    wire ss_rise  = ss_s[1] & ~ss_s[2];
    wire selected = ~ss_s[1];

    // ── lane state (LINK_CFG; boot = 1 lane, legacy full-duplex) ──────────
    reg [2:0] lanes      = 3'd1;
    reg [2:0] lanes_next = 3'd1;
    // edges (SCK rises) per byte - 1: 8/1/-1, 4/2-1, 2/4-1
    wire [2:0] edges_last = (lanes == 3'd4) ? 3'd1 :
                            (lanes == 3'd2) ? 3'd3 : 3'd7;
    // lane-reset escape: >=16 SCK rises while DESELECTED revert to 1 lane.
    // Never happens in normal traffic (the master only clocks under SS low);
    // the MCU emits the burst at boot so a rebooted master and a lane-
    // shifted slave always re-meet in legacy mode.
    reg [4:0] idle_clks = 0;

    // ── SPI frame state ────────────────────────────────────────────────────
    reg [7:0] rx_sr    = 0;
    reg [7:0] tx_sr    = 0;
    reg [2:0] bitcnt   = 0;
    reg [7:0] byte_idx = 0;    // completed bytes this frame (saturating)
    reg [7:0] cmd      = 0;
    reg [7:0] ping_cnt = 0;

    wire [7:0] rx_byte = (lanes == 3'd4) ? {rx_sr[3:0], sd_s} :
                         (lanes == 3'd2) ? {rx_sr[5:0], sd_s[1:0]} :
                                           {rx_sr[6:0], sd_s[0]};
    wire byte_done = sck_rise && (bitcnt == edges_last);

    // ── fastload engine state ──────────────────────────────────────────────
    reg [7:0]  name [0:15];
    reg [4:0]  name_len  = 0;   // 0..16
    reg        pending   = 0;   // LOAD request waiting for REQ_FETCH
    reg        submitted = 0;   // transfer open (CMD 0x01 .. XFER_END/reset)
    reg        eof_lat   = 0;
    reg        err_lat   = 0;

    // 64-byte FIFO
    reg [7:0]  fifo [0:63];
    reg [5:0]  wr_ptr = 0;
    reg [5:0]  rd_ptr = 0;
    reg [6:0]  cnt    = 0;

    wire avail = (cnt != 0);
    wire done  = eof_lat && (cnt == 0);

    // ── DOS-over-link bus channel ─────────────────────────────────────────
    // The outgoing direction reuses name[] as its buffer (same 16 bytes, same
    // REQ_FETCH path) with a parallel mask saying which of those bytes went
    // under ATN.  The incoming direction reuses the load FIFO outright: the
    // MCU pushes channel bytes with DATA_PUSH and closes with XFER_END
    // exactly as it does for a LOAD.
    localparam [4:0] BUS_DEV = 5'd8;      // the emulated drive's device number
    reg [15:0] bus_mask = 0;              // 1 = that name[] byte was under ATN
    reg        bus_own  = 0;              // the drive is the addressed device
    reg        bus_took = 0;              // ...counting the byte just written:
                                          // UNLSN/UNTLK un-address us but are
                                          // still OURS to deliver, and letting
                                          // them fall through to the stock
                                          // sender would time out on an empty
                                          // wire and set ST=$80 device-absent
    reg        req_bus  = 0;              // pending request is bus, not LOAD
    // What the REQ_FETCH frame in flight ANNOUNCED at resp_idx 2.  `req` is
    // held high by `submitted` for the whole of an open push transfer (it is
    // also the "FIFO has room, keep pushing" signal), so the MCU polls
    // REQ_FETCH back-to-back and most of those frames report type 0x00 —
    // "nothing for you".  A frame that reported nothing consumed nothing, and
    // must not run the frame-end buffer clear: a bus byte the CPU appends
    // while such a frame is in flight would be wiped before any MCU ever saw
    // it.  That is a lost LISTEN/TALK/secondary, and the machine then hangs in
    // the ACPTR detour waiting for a channel that was never opened (Axe of
    // Rage, 2026-08-07: TKSA's $6F destroyed by an empty fetch, sim hot PCs
    // parked on $DEC8-$DECE).
    reg        fetch_ann = 0;
    // Diagnostics: how many times the machine has read BUS STATUS since the
    // last TALK addressed to us.  ACPTR reads it 2-3 times per byte, so this
    // separates "the detour ran once and gave up" from "it spun waiting".
    reg [7:0]  bus_stat_rd = 0;

    // EOI belongs WITH the last byte: the head is last iff EOF is latched and
    // it is the only byte left.  That is why the FIFO needs no per-byte tag.
    wire rx_eoi = eof_lat && (cnt == 7'd1);

    // ── BIOS text-screen state ─────────────────────────────────────────────
    reg [10:0] tw_addr   = 0;   // TEXT_WRITE autoincrement cell pointer
    reg [7:0]  tw_char   = 0;   // latched char byte awaiting its attr
    reg [10:0] fill_addr = 0;   // TEXT_FILL engine
    reg [11:0] fill_cnt  = 0;   // 0 = idle
    reg [7:0]  fill_char = 0;
    reg [7:0]  fill_attr = 0;
    reg [7:0]  fill_lo   = 0;   // count low byte staging
    reg [7:0]  btn_q     = 0;
    always @(posedge clk) btn_q <= btn;

    // ── floppy image host state (FDD=1; constant-folded away otherwise) ───
    reg [7:0]  fdd_flags = 0;   // MOUNT staging: bit0 present, bit1 wp, bit7 drive
    reg [7:0]  fdd_cyls  = 0;
    reg [7:0]  fdd_spt   = 0;
    reg [7:0]  fdd_heads = 0;
    reg [15:0] fdd_total = 0;
    reg [2:0]  fdd_mount_st = 0;    // 0 idle, 1..6 = geometry write sequence
    reg [15:0] fdd_lba   = 0;       // {drive, sector[14:0]} from mgmt reg 0
    reg        fdd_lba_valid = 0;
    reg [1:0]  fdd_req_q = 0;       // request type latched with the LBA
    reg [1:0]  fdd_lba_st = 0;      // 0 idle, 1 addr set, 2 settle, 3 capture
    reg        fdd_pop   = 0;       // pending FIFO pop (FDD_PULL)
    reg [9:0]  fdd_cnt   = 0;       // PUSH byte counter (byte_idx saturates)
    reg [7:0]  fdd_push_byte = 0;   // PUSH byte staged for the mgmt engine
    reg        fdd_push_stb  = 0;

    // ── ROM loader state (ROMLOAD=1; constant-folded away otherwise) ──────
    // rom_ptr survives across SPI transactions: a 16 KB bank arrives as many
    // ROM_DATA frames and only ROM_BEGIN rewinds it.
    reg [ROM_AW-1:0] rom_ptr = 0;
    initial begin
        rom_bank  = 3'd0;
        rom_addr  = {ROM_AW{1'b0}};
        rom_data  = 8'd0;
        rom_we    = 1'b0;
        rom_valid = 8'd0;
    end

    // ── volume: 0..10 from the MCU → 0..16 multiplier (16 = unity) ────────
    // Hardware builds power up MUTED: the MCU applies the KV-stored volume
    // right after configuration (biosApplyVolume), so until that lands the
    // board is silent, and a dead link fails silent instead of loud.
    // Exceptions that keep the legacy unity power-up: GAME_PRG (standalone
    // board build, no MCU to unmute) and SIMULATION (plain sims run without
    // the --qspi MCU model; the model itself sends SET_VOLUME at boot).
`ifdef GAME_PRG
    localparam [7:0] VOL_PWRUP = 8'd10;   // raw 0..10
    localparam [4:0] VOL_PWRUP_SCALE = 5'd16;
`elsif SIMULATION
    localparam [7:0] VOL_PWRUP = 8'd10;
    localparam [4:0] VOL_PWRUP_SCALE = 5'd16;
`else
    localparam [7:0] VOL_PWRUP = 8'd0;
    localparam [4:0] VOL_PWRUP_SCALE = 5'd0;
`endif
    // Backlight, unlike volume, powers up LIT in every build: the panel has
    // to be readable before the MCU gets a SET_BRIGHT out, and a board whose
    // link is dead must not be left staring at a black screen.  The level
    // matches the MCU's virgin-board default (BRI_DEFAULT in bios_ui.c) so an
    // unconfigured board and a freshly-flashed one look the same — and a
    // standalone GAME_PRG build (no MCU at all) is not stuck at full tilt
    // burning the battery.  A board with a stored level shows this for the
    // few ms between configuration and biosApplyBright().
    localparam [7:0] BRI_PWRUP       = 8'd5;   // raw 0..10
    localparam [6:0] BRI_PWRUP_SCALE = 7'd11;  // = bri_lut(5), duty 0..64

    reg [7:0] vol_q = VOL_PWRUP; // raw value, echoed in the response
    reg [7:0] btnmode_q = 8'd0; // raw SET_BTNMODE value, echoed in the response
    reg [7:0] dmode_q = 8'd0;   // raw DRIVE_MODE value, echoed in the response
    reg [7:0] lcfg_q  = 8'd1;   // raw LINK_CFG value, echoed in the response
    reg [7:0] bri_q   = BRI_PWRUP; // raw SET_BRIGHT value, echoed in the resp
    initial vol_scale = VOL_PWRUP_SCALE;
    initial bright_scale = BRI_PWRUP_SCALE;
    initial btn_mode  = 2'd0;   // value only meaningful with btn_mode_stb
    initial btn_mode_stb = 1'b0;
    initial dos_link   = 1'b0;
    initial drive_1541 = 1'b0;  // power-up: fastload (matches the pre-single-
                                // bit behaviour until the MCU applies the KV)
    initial shot_arm_stb = 1'b0;
    initial shot_line    = 9'd0;
    initial shot_dense   = 1'b0;
    initial shot_pair    = 1'b0;
    initial shot_freeze  = 1'b0;

    function [4:0] vol_lut;
        input [7:0] v;
        case (v)
            8'd0:  vol_lut = 5'd0;
            8'd1:  vol_lut = 5'd2;
            8'd2:  vol_lut = 5'd3;
            8'd3:  vol_lut = 5'd5;
            8'd4:  vol_lut = 5'd6;
            8'd5:  vol_lut = 5'd8;
            8'd6:  vol_lut = 5'd10;
            8'd7:  vol_lut = 5'd11;
            8'd8:  vol_lut = 5'd13;
            8'd9:  vol_lut = 5'd14;
            default: vol_lut = 5'd16;   // 10 and any out-of-range = unity
        endcase
    endfunction

    // Backlight 0..10 → duty 0..64.  Deliberately NOT linear: perceived
    // brightness goes roughly as the square root of the duty, so a linear
    // ramp would put every useful step in the bottom third of the bar.  This
    // curve makes the 10 BIOS steps look evenly spaced.  Step 1 is 1/64
    // (~16 us on at 1 kHz) — the dimmest the boost can be asked for; raise
    // this floor if the panel is unhappy down there.
    function [6:0] bri_lut;
        input [7:0] v;
        case (v)
            8'd0:  bri_lut = 7'd0;      // off (not reachable from the BIOS)
            8'd1:  bri_lut = 7'd1;
            8'd2:  bri_lut = 7'd2;
            8'd3:  bri_lut = 7'd4;
            8'd4:  bri_lut = 7'd7;
            8'd5:  bri_lut = 7'd11;
            8'd6:  bri_lut = 7'd17;
            8'd7:  bri_lut = 7'd25;
            8'd8:  bri_lut = 7'd35;
            8'd9:  bri_lut = 7'd48;
            default: bri_lut = 7'd64;   // 10 and any out-of-range = full on
        endcase
    endfunction

    // watchdog: MCU must fetch/feed within ~1.2s or the transfer is failed.
    // Paused in BIOS mode: the frozen CPU stops draining the FIFO and must
    // NOT look like a dead MCU (a mid-LOAD freeze would fire err+eof).
    reg [24:0] wdog = 0;
    wire wdog_run = (pending || (submitted && !eof_lat && !err_lat)) &&
                    !bios_mode;

    assign bus_hold_clk = dos_link && bus_own;

    assign req = pending ||
                 (submitted && !eof_lat && !err_lat && (cnt <= 7'd32)) ||
                 (FDD != 0 && fdd_lba_valid);

    // ── fastload routine ROM, generated by kernal_fastload_patch.py ───────
    wire sel_romA, sel_romB, sel_regs;
    wire [7:0] rom_addr8;
    reg  [7:0] rom_q;
    generate if (C64) begin : fl_c64
        // routine window $DE00-$DEFF (I/O1); regs $DF00-$DF0F (I/O2).
        // The soc gates accesses on its I/O bank select.  The window is the
        // full page since the bus detours moved in above $DE80.
        assign sel_romA  = (exp_addr[15:8] == 8'hDE);
        assign sel_romB  = 1'b0;
        assign sel_regs  = (exp_addr[15:4] == 12'hDF0);
        assign rom_addr8 = exp_addr[7:0];
        wire [7:0] fl_rom_addr = rom_addr8;
        `include "fastload_rom_c64.vh"
    end else begin : fl_264
        // window A $FD60-$FDCF (main, table idx 0+), window B $FE30-$FE3F
        // (GETB, idx 112+) — both in the 264 always-mapped I/O hole so the
        // code runs in either bank; regs $FE20-$FE2F.
        assign sel_romA = (exp_addr[15:8] == 8'hFD) &&
                          (exp_addr[7:0] >= 8'h60) && (exp_addr[7:0] <= 8'hCF);
        assign sel_romB = (exp_addr[15:4] == 12'hFE3);
        assign sel_regs = (exp_addr[15:4] == 12'hFE2);
        assign rom_addr8 = sel_romB ? (exp_addr[7:0] - 8'h30 + 8'd112)
                                    : (exp_addr[7:0] - 8'h60);
        wire [6:0] fl_rom_addr = rom_addr8[6:0];
        `include "fastload_rom.vh"
    end endgenerate

    // ── real-1541 fallback stub (DRIVE_MODE 1) ─────────────────────────────
    // The KERNAL LOAD detour is baked into ROM (JMP into our routine window).
    // In real-1541 mode the window serves this stub instead of the fastload
    // routine: the two displaced original bytes, then a jump back into the
    // stock LOAD path — the detour becomes a ~7-cycle no-op and every LOAD
    // goes down the authentic IEC path with no engine/watchdog involvement.
    //   C64: hook $F4A5 (STA $93 / LDA #$00), resume $F4A9
    //   264: hook $F04A (same bytes),         resume $F04E
    localparam [15:0] STUB_RESUME = C64 ? 16'hF4A9 : 16'hF04E;
    reg [7:0] stub_q;
    always @* begin
        case (rom_addr8)
            8'd0:    stub_q = 8'h85;              // STA $93
            8'd1:    stub_q = 8'h93;
            8'd2:    stub_q = 8'hA9;              // LDA #$00
            8'd3:    stub_q = 8'h00;
            8'd4:    stub_q = 8'h4C;              // JMP resume
            8'd5:    stub_q = STUB_RESUME[7:0];
            8'd6:    stub_q = STUB_RESUME[15:8];
            default: stub_q = 8'hFF;
        endcase
    end

    // ── bus-detour fallback stubs (any mode but DOS-over-link) ─────────────
    // The two bus detours are baked into the KERNAL ROM as well, so when the
    // link is not serving the DOS the window must hand each one straight back
    // to the stock code — displaced bytes re-executed, then a jump past them.
    //   $ED40 send  (SEI / JSR $EE97),      resume $ED44
    //   $EE13 ACPTR (SEI / LDA #$00 / STA $A5), resume $EE18
    reg [7:0] bus_stub_q;
    always @* begin
        case (rom_addr8)
            8'h80:   bus_stub_q = 8'h78;          // SEI
            8'h81:   bus_stub_q = 8'h20;          // JSR $EE97
            8'h82:   bus_stub_q = 8'h97;
            8'h83:   bus_stub_q = 8'hEE;
            8'h84:   bus_stub_q = 8'h4C;          // JMP $ED44
            8'h85:   bus_stub_q = 8'h44;
            8'h86:   bus_stub_q = 8'hED;
            8'hC0:   bus_stub_q = 8'h78;          // SEI
            8'hC1:   bus_stub_q = 8'hA9;          // LDA #$00
            8'hC2:   bus_stub_q = 8'h00;
            8'hC3:   bus_stub_q = 8'h85;          // STA $A5
            8'hC4:   bus_stub_q = 8'hA5;
            8'hC5:   bus_stub_q = 8'h4C;          // JMP $EE18
            8'hC6:   bus_stub_q = 8'h18;
            8'hC7:   bus_stub_q = 8'hEE;
            default: bus_stub_q = 8'hFF;
        endcase
    end

    // ── CPU-side reads (combinational, wired-AND convention) ───────────────
    wire sel_rom  = sel_romA | sel_romB;

    // The window splits at $DE80: below it the LOAD fastload routine (live
    // unless the real 1541 owns the bus), above it the bus detours (live only
    // in DOS-over-link mode).  Each half falls back to its own stub.
    wire bus_half = C64 && rom_addr8[7];

    wire [7:0] status = {avail, done, err_lat, 5'b00000};
    wire [7:0] bus_status = {bus_took, avail, rx_eoi, done,
                             err_lat, pending, 2'b00};

    assign exp_rdata =
        sel_rom  ? (bus_half ? (dos_link   ? rom_q : bus_stub_q)
                             : (drive_1541 ? stub_q : rom_q)) :
        sel_regs ? ((exp_addr[3:0] == 4'h0) ? status :
                    (exp_addr[3:0] == 4'h1) ? fifo[rd_ptr] :
                    (exp_addr[3:0] == 4'h2) ? {1'b0, cnt} :
                    (exp_addr[3:0] == 4'h3) ? bus_status : 8'hFF)
                 : 8'hFF;

    // ── SPI response byte for frame position idx ───────────────────────────
    // (memory read done outside the function: idx 4..19 → name[0..15])
    wire [3:0] name_rd_idx = byte_idx[3:0] - 4'd4;
    wire [7:0] name_rd     = name[name_rd_idx];

    function [7:0] resp;
        input [7:0] c;
        input [7:0] idx;
        input [7:0] nbyte;
        input [7:0] bbyte;
        input [7:0] vbyte;
        input [7:0] mbyte;
        input [7:0] dbyte;
        input [7:0] lbyte;
        input [7:0] tbyte;
        input [7:0] sbyte;
        input [7:0] rbyte;
        begin
            if (idx < 8'd2)
                resp = MAGIC;
            else if (c == CMD_PING)
                case (idx)
                    8'd2:    resp = 8'hA5;
                    8'd3:    resp = ping_cnt;
                    8'd4:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_SET_VOLUME)
                case (idx)
                    8'd3:    resp = 8'hA5;
                    8'd4:    resp = vbyte;      // echo (latched at byte 2)
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_SET_BRIGHT)
                case (idx)
                    8'd3:    resp = 8'hA5;
                    8'd4:    resp = rbyte;      // echo (latched at byte 2)
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_SET_BTNMODE)
                case (idx)
                    8'd3:    resp = 8'hA5;
                    8'd4:    resp = mbyte;      // echo (latched at byte 2)
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_DRIVE_MODE)
                case (idx)
                    8'd3:    resp = 8'hA5;
                    8'd4:    resp = dbyte;      // echo (latched at byte 2)
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_LINK_CFG)
                case (idx)
                    8'd3:    resp = 8'hA5;
                    8'd4:    resp = lbyte;      // echo (latched at byte 2)
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_FD_STATUS)
                case (idx)
                    8'd2:    resp = 8'hA5;
                    8'd3:    resp = fd_stat;
                    8'd4:    resp = fd_done;
                    8'd5:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_SHOT_STATUS)
                case (idx)
                    8'd2:    resp = 8'hA5;
                    8'd3:    resp = tbyte;      // {6'b0, armed, ready}
                    8'd4:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_XFER_STAT)
                case (idx)
                    8'd2:    resp = 8'hA5;
                    8'd3:    resp = {1'b0, cnt};   // unread bytes in the FIFO
                    8'd4:    resp = bus_status;    // what the machine sees
                    8'd5:    resp = bus_stat_rd;   // BUS STATUS reads
                    8'd6:    resp = ~c;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_SHOT_READ) begin
                if (idx == 8'd3)
                    resp = 8'hA5;
                else if (idx >= 8'd4)
                    resp = sbyte;               // line-buffer byte stream
                else
                    resp = MAGIC;
            end
            else if (c == CMD_REQ_FETCH) begin
                if (idx == 8'd2)
                    resp = pending ? (req_bus ? 8'h02 : 8'h01) : 8'h00;
                else if (idx == 8'd3)
                    resp = {3'b000, name_len};
                else if (idx >= 8'd4 && idx < 8'd20)
                    resp = nbyte;
                else if (idx == 8'd20)
                    resp = bus_mask[7:0];
                else if (idx == 8'd21)
                    resp = bus_mask[15:8];
                else
                    resp = MAGIC;
            end
            else if (c == CMD_BTN_READ)
                case (idx)
                    8'd2:    resp = bbyte;
                    8'd3:    resp = ~bbyte;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_VERSION_READ)
                case (idx)
                    8'd2:    resp = 8'hA5;            // present tag (vs 0x3C ERR)
                    8'd3:    resp = VER_DATE[31:24];  // date, big-endian
                    8'd4:    resp = VER_DATE[23:16];
                    8'd5:    resp = VER_DATE[15:8];
                    8'd6:    resp = VER_DATE[7:0];
                    8'd7:    resp = VER_BUILD;
                    default: resp = MAGIC;
                endcase
            else if (c == CMD_DATA_PUSH || c == CMD_XFER_END ||
                     c == CMD_MODE_SET || c == CMD_TEXT_WRITE ||
                     c == CMD_TEXT_FILL)
                resp = MAGIC;
            else
                resp = ERR;
        end
    endfunction

    // FDD command responses (reads module-scope fdd_* state directly; only
    // reachable when FDD=1 — the tx-load mux gates on the parameter)
    wire is_fdd_cmd = (cmd == CMD_FDD_MOUNT) || (cmd == CMD_FDD_STATUS) ||
                      (cmd == CMD_FDD_PUSH)  || (cmd == CMD_FDD_PULL)   ||
                      (cmd == CMD_FDD_CTRL);
    function [7:0] fdd_resp;
        input [7:0] c;
        input [7:0] idx;
        begin
            if (idx < 8'd2)
                fdd_resp = MAGIC;
            else if (c == CMD_FDD_STATUS)
                case (idx)
                    8'd2:    fdd_resp = 8'hA5;
                    8'd3:    fdd_resp = {5'b0, fdd_lba_valid, fdd_req_q};
                    8'd4:    fdd_resp = fdd_lba[15:8];
                    8'd5:    fdd_resp = fdd_lba[7:0];
                    8'd6:    fdd_resp = ~c;
                    default: fdd_resp = MAGIC;
                endcase
            else if (c == CMD_FDD_PULL) begin
                if (idx == 8'd2)
                    fdd_resp = 8'hA5;
                else
                    fdd_resp = fdd_mgmt_rdata[7:0];   // FIFO head (show-ahead)
            end
            else
                fdd_resp = MAGIC;       // MOUNT/PUSH/CTRL are master-driven
        end
    endfunction

    // ROM command responses (only reachable when ROMLOAD=1 — the tx-load mux
    // gates on the parameter).  Only ROM_STATUS reads anything back; the rest
    // are master-driven writes.
    wire is_rom_cmd = (cmd == CMD_ROM_BEGIN) || (cmd == CMD_ROM_DATA) ||
                      (cmd == CMD_ROM_END)   || (cmd == CMD_ROM_STATUS);
    function [7:0] rom_resp;
        input [7:0] c;
        input [7:0] idx;
        begin
            if (idx < 8'd2)
                rom_resp = MAGIC;
            else if (c == CMD_ROM_STATUS)
                case (idx)
                    8'd2:    rom_resp = 8'hA5;
                    8'd3:    rom_resp = rom_valid;
                    8'd4:    rom_resp = ~c;
                    default: rom_resp = MAGIC;
                endcase
            else
                rom_resp = MAGIC;
        end
    endfunction

    // ── data-lane outputs ──────────────────────────────────────────────────
    // 1 lane: SD1 = MISO, driven whenever selected (legacy behaviour; the
    // pad floats to the pull-up when deselected).  Multi-lane: all L lanes
    // driven only during the slave phase (after the turnaround byte).
    function [7:0] atn_len;         // master-driven byte count per command
        input [7:0] c;
        begin
            if (c == CMD_PING || c == CMD_REQ_FETCH ||
                c == CMD_VERSION_READ || c == CMD_BTN_READ ||
                c == CMD_SHOT_STATUS || c == CMD_XFER_STAT ||
                c == CMD_FDD_STATUS || c == CMD_FDD_PULL ||
                c == CMD_ROM_STATUS || c == CMD_FD_STATUS)
                atn_len = 8'd1;
            else if (c == CMD_SET_VOLUME || c == CMD_SET_BTNMODE ||
                     c == CMD_DRIVE_MODE || c == CMD_LINK_CFG ||
                     c == CMD_SET_BRIGHT || c == CMD_SHOT_READ)
                atn_len = 8'd3;
            else
                atn_len = 8'hFF;    // write/unknown: slave never drives
        end
    endfunction

    // echo-shaped commands (3 master bytes) land one byte later than legacy
    // in multi-lane mode; SHOT_READ shares the shape ([cmd][off_lo][off_hi])
    wire is_echo_cmd = (cmd == CMD_SET_VOLUME) || (cmd == CMD_SET_BTNMODE) ||
                       (cmd == CMD_DRIVE_MODE) || (cmd == CMD_LINK_CFG) ||
                       (cmd == CMD_SET_BRIGHT) || (cmd == CMD_SHOT_READ);
    wire [7:0] resp_idx = (lanes != 3'd1 && is_echo_cmd) ? byte_idx - 8'd1
                                                         : byte_idx;

    wire ml_drive = selected && (atn_len(cmd) != 8'hFF) &&
                    (byte_idx > atn_len(cmd));

    // ── screen-grab read pointer (byte index into the shot line buffer) ───
    reg [10:0] shot_ptr = 0;
    assign shot_raddr = shot_ptr[10:1];
    wire [7:0] shot_byte  = shot_ptr[0] ? shot_rdata[15:8] : shot_rdata[7:0];
    wire [7:0] shot_state = {5'b0, shot_freeze, shot_armed, shot_ready};

    assign spi_sd_out = (lanes == 3'd4) ? tx_sr[7:4] :
                        (lanes == 3'd2) ? {2'b00, tx_sr[7:6]} :
                                          {2'b00, tx_sr[7], 1'b0};
    assign spi_sd_oe  = (lanes == 3'd1) ? (selected ? 4'b0010 : 4'b0000) :
                        ml_drive        ? ((lanes == 3'd4) ? 4'b1111
                                                           : 4'b0011)
                                        : 4'b0000;

    // ── main sequential block ───────────────────────────────────────────────
    wire do_push = byte_done && cmd == CMD_DATA_PUSH && byte_idx >= 8'd2 &&
                   cnt < 7'd64;
    wire do_pop  = exp_rstb && (exp_laddr == 4'h1) && (cnt != 0);
    // TEXT_WRITE pair commit: char at odd byte_idx (3,5,...), attr at the
    // following even one — the commit tick (wins the write port over fill)
    wire tw_commit = byte_done && cmd == CMD_TEXT_WRITE &&
                     byte_idx >= 8'd4 && !byte_idx[0];
    wire do_engine_reset = exp_wstb && (exp_laddr == 4'h0) &&
                           (exp_wdata == 8'h00);

    always @(posedge clk or negedge rst)
        if (!rst) begin
            rx_sr    <= 0;
            tx_sr    <= 0;
            bitcnt   <= 0;
            byte_idx <= 0;
            cmd      <= 0;
            ping_cnt <= 0;
            name_len <= 0;
            pending  <= 0;
            submitted<= 0;
            eof_lat  <= 0;
            err_lat  <= 0;
            wr_ptr   <= 0;
            rd_ptr   <= 0;
            cnt      <= 0;
            wdog     <= 0;
            bios_mode<= 0;
            txt_waddr<= 0;
            txt_wdata<= 0;
            txt_wen  <= 0;
            tw_addr  <= 0;
            tw_char  <= 0;
            fill_addr<= 0;
            fill_cnt <= 0;
            fill_char<= 0;
            fill_attr<= 0;
            fill_lo  <= 0;
            vol_q    <= VOL_PWRUP;
            vol_scale<= VOL_PWRUP_SCALE;
            bri_q    <= BRI_PWRUP;
            bright_scale <= BRI_PWRUP_SCALE;
            btnmode_q<= 8'd0;
            btn_mode <= 2'd0;
            btn_mode_stb <= 1'b0;
            dmode_q  <= 8'd0;
            drive_1541 <= 1'b0;
            dos_link   <= 1'b0;
            bus_mask   <= 16'd0;
            bus_own    <= 1'b0;
            bus_took   <= 1'b0;
            req_bus    <= 1'b0;
            fetch_ann  <= 1'b0;
            bus_stat_rd <= 8'd0;
            lcfg_q   <= 8'd1;
            lanes    <= 3'd1;
            lanes_next <= 3'd1;
            idle_clks<= 0;
            shot_arm_stb <= 1'b0;
            shot_line    <= 9'd0;
            shot_dense   <= 1'b0;
            shot_pair    <= 1'b0;
            shot_freeze  <= 1'b0;
            shot_ptr     <= 11'd0;
            fdd_flags    <= 8'd0;
            fdd_cyls     <= 8'd0;
            fdd_spt      <= 8'd0;
            fdd_heads    <= 8'd0;
            fdd_total    <= 16'd0;
            fdd_mount_st <= 3'd0;
            fdd_lba      <= 16'd0;
            fdd_lba_valid<= 1'b0;
            fdd_req_q    <= 2'd0;
            fdd_lba_st   <= 2'd0;
            fdd_pop      <= 1'b0;
            fdd_cnt      <= 10'd0;
            fdd_push_byte<= 8'd0;
            fdd_push_stb <= 1'b0;
            fdd_mgmt_addr  <= 16'd0;
            fdd_mgmt_wdata <= 16'd0;
            fdd_mgmt_write <= 1'b0;
            fdd_mgmt_read  <= 1'b0;
            fdd_reset_stb  <= 1'b0;
            fdd_turbo      <= 2'b00;
            rom_bank       <= 3'd0;
            rom_addr       <= {ROM_AW{1'b0}};
            rom_data       <= 8'd0;
            rom_we         <= 1'b0;
            rom_valid      <= 8'd0;
            rom_ptr        <= {ROM_AW{1'b0}};
        end else begin
            btn_mode_stb <= 1'b0;   // strobe defaults low; write below wins
            shot_arm_stb <= 1'b0;
            fdd_reset_stb <= 1'b0;
            rom_we       <= 1'b0;
            // ── watchdog first: any later reset assignment overrides it ──
            if (wdog_run) begin
                wdog <= wdog + 1'b1;
                if (&wdog) begin
                    err_lat <= 1'b1;
                    eof_lat <= 1'b1;
                    pending <= 0;
                    // drop a half-built bus batch too: the LOAD path clears
                    // the buffer with an engine reset per call, the bus path
                    // has no such point and would carry the stale bytes into
                    // the next transaction
                    req_bus  <= 0;
                    name_len <= 0;
                    bus_mask <= 16'd0;
                end
            end

            // ── SPI shift engine ──
            if (ss_fall) begin
                bitcnt   <= 0;
                byte_idx <= 0;
                cmd      <= 0;
                tx_sr    <= MAGIC;
                idle_clks<= 0;
                fdd_cnt  <= 10'd0;
            end else if (selected) begin
                if (sck_rise) begin
                    rx_sr  <= rx_byte;
                    if (bitcnt == edges_last) begin
                        bitcnt <= 0;
                        if (byte_idx == 0)
                            cmd <= rx_byte;
                        if (byte_idx != 8'hFF)
                            byte_idx <= byte_idx + 1'b1;
                    end else
                        bitcnt <= bitcnt + 1'b1;
                end
                if (sck_fall) begin
                    if (bitcnt == 0) begin
                        tx_sr <= (FDD != 0 && is_fdd_cmd)
                                 ? fdd_resp(cmd, resp_idx)
                                 : (ROMLOAD != 0 && is_rom_cmd)
                                 ? rom_resp(cmd, resp_idx)
                                 : resp(cmd, resp_idx, name_rd, btn_q, vol_q,
                                        btnmode_q, dmode_q, lcfg_q,
                                        shot_state, shot_byte, bri_q);
                        // REQ_FETCH announces its type at resp_idx 2.  Latch
                        // it HERE, at the instant that byte is committed to
                        // the shift register, so the frame-end clear consumes
                        // exactly what this frame told the MCU it was getting.
                        // Latching at frame START instead would race the other
                        // way: a byte written before idx 2 would be reported
                        // AND kept, so the next frame would deliver it twice.
                        if (cmd == CMD_REQ_FETCH && resp_idx == 8'd2)
                            fetch_ann <= pending;
                        // SHOT_READ: post-increment as each data byte loads
                        // (the next byte's BRAM word prefetches during the
                        // ≥8 SPI clocks the current byte takes to shift out)
                        if (cmd == CMD_SHOT_READ && resp_idx >= 8'd4)
                            shot_ptr <= shot_ptr + 1'b1;
                        // FDD_PULL: data bytes stream from idx 3; pop the
                        // floppy FIFO as each byte loads (present-then-pop:
                        // the show-ahead head advances to the next byte well
                        // before the next load, ≥8 SPI clocks away).  The
                        // fdd_cnt bound stops the preload at the final SCK
                        // fall from popping a 513th byte.
                        if (FDD != 0 && cmd == CMD_FDD_PULL &&
                            resp_idx >= 8'd3 && fdd_cnt < 10'd512) begin
                            fdd_pop <= 1'b1;
                            fdd_cnt <= fdd_cnt + 1'b1;
                        end
                    end else
                        tx_sr <= (lanes == 3'd4) ? {tx_sr[3:0], 4'b0000} :
                                 (lanes == 3'd2) ? {tx_sr[5:0], 2'b00} :
                                                   {tx_sr[6:0], 1'b0};
                end
            end else begin
                // deselected: count stray SCK rises — the master's lane-reset
                // escape burst (see idle_clks above)
                if (sck_rise) begin
                    if (idle_clks >= 5'd15) begin
                        lanes      <= 3'd1;
                        lanes_next <= 3'd1;
                    end else
                        idle_clks <= idle_clks + 1'b1;
                end
            end

            // ── FIFO: push/pop may coincide in one clk ──
            if (exp_rstb && exp_laddr == 4'h3 && bus_stat_rd != 8'hFF)
                bus_stat_rd <= bus_stat_rd + 1'b1;

            if (do_push) begin
                fifo[wr_ptr] <= rx_byte;
                wr_ptr <= wr_ptr + 1'b1;
                wdog   <= 0;
            end
            if (do_pop)
                rd_ptr <= rd_ptr + 1'b1;
            case ({do_push, do_pop})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: ;
            endcase

            // ── XFER_END flags (frame byte 1) ──
            if (byte_done && cmd == CMD_XFER_END && byte_idx == 8'd1) begin
                eof_lat <= 1'b1;
                err_lat <= err_lat | rx_byte[1];
            end

            // ── BIOS text screen ──
            // Fill engine: one cell per clk on the shared write port; a
            // direct TEXT_WRITE commit (below) wins the port and the fill
            // stalls for that clk (SPI pairs arrive ~28 clks apart, so a
            // fill always completes).
            txt_wen <= 1'b0;
            if (fill_cnt != 0 && !tw_commit) begin
                txt_waddr <= fill_addr;
                txt_wdata <= {fill_attr, fill_char};
                txt_wen   <= 1'b1;
                fill_addr <= fill_addr + 1'b1;
                fill_cnt  <= fill_cnt - 1'b1;
            end

            if (byte_done && cmd == CMD_MODE_SET && byte_idx == 8'd1)
                bios_mode <= rx_byte[0];

            // SET_VOLUME: [0x07][ALEN][vol] — vol at byte 2
            if (byte_done && cmd == CMD_SET_VOLUME && byte_idx == 8'd2) begin
                vol_q     <= (rx_byte > 8'd10) ? 8'd10 : rx_byte;
                vol_scale <= vol_lut(rx_byte);
            end

            // SET_BRIGHT: [0x0C][ALEN][bright] — same shape as SET_VOLUME
            if (byte_done && cmd == CMD_SET_BRIGHT && byte_idx == 8'd2) begin
                bri_q        <= (rx_byte > 8'd10) ? 8'd10 : rx_byte;
                bright_scale <= bri_lut(rx_byte);
            end

            // SET_BTNMODE: [0x08][ALEN][mode] — mode at byte 2 (0..3, >3 → 2)
            if (byte_done && cmd == CMD_SET_BTNMODE && byte_idx == 8'd2) begin
                btnmode_q    <= rx_byte;
                btn_mode     <= (rx_byte[7:2] != 0) ? 2'd2 : rx_byte[1:0];
                btn_mode_stb <= 1'b1;
            end

            // DRIVE_MODE: [0x0B][ALEN][mode] — mode at byte 2, bit0 used
            if (byte_done && cmd == CMD_DRIVE_MODE && byte_idx == 8'd2) begin
                dmode_q    <= rx_byte;
                drive_1541 <= rx_byte[0];
                dos_link   <= rx_byte[1];
            end

            // LINK_CFG: [0x0A][ALEN][lanes] — lanes at byte 2 (1/2/4 only);
            // applied at SS rise so this frame's ack completes in the old mode
            if (byte_done && cmd == CMD_LINK_CFG && byte_idx == 8'd2) begin
                lcfg_q <= rx_byte;
                if (rx_byte == 8'd1 || rx_byte == 8'd2 || rx_byte == 8'd4)
                    lanes_next <= rx_byte[2:0];
            end

            // SHOT_ARM: [0x30][flags][line_lo][line_hi]
            if (byte_done && cmd == CMD_SHOT_ARM) begin
                if (byte_idx == 8'd1) begin
                    shot_dense <= rx_byte[0];
                    shot_pair  <= rx_byte[1];
                end
                else if (byte_idx == 8'd2)
                    shot_line[7:0] <= rx_byte;
                else if (byte_idx == 8'd3) begin
                    shot_line[8]  <= rx_byte[0];
                    shot_arm_stb  <= 1'b1;      // 1-clk (default low below)
                end
            end

            // SHOT_FREEZE: [0x33][on] — level, held until written again
            if (byte_done && cmd == CMD_SHOT_FREEZE && byte_idx == 8'd1)
                shot_freeze <= rx_byte[0];

            // SHOT_READ: [0x32][off_lo][off_hi] then the byte stream
            if (byte_done && cmd == CMD_SHOT_READ) begin
                if (byte_idx == 8'd1)
                    shot_ptr[7:0] <= rx_byte;
                else if (byte_idx == 8'd2)
                    shot_ptr[10:8] <= rx_byte[2:0];
            end

            // TEXT_WRITE: [cell_lo][cell_hi] then char+attr pairs
            if (byte_done && cmd == CMD_TEXT_WRITE) begin
                if (byte_idx == 8'd1)
                    tw_addr[7:0] <= rx_byte;
                else if (byte_idx == 8'd2)
                    tw_addr[10:8] <= rx_byte[2:0];
                else if (byte_idx[0])            // 3, 5, 7, ... char byte
                    tw_char <= rx_byte;
                else begin                       // 4, 6, 8, ... attr byte
                    txt_waddr <= tw_addr;
                    txt_wdata <= {rx_byte, tw_char};
                    txt_wen   <= 1'b1;
                    tw_addr   <= tw_addr + 1'b1;
                end
            end

            // TEXT_FILL: [char][attr][cell_lo][cell_hi][cnt_lo][cnt_hi];
            // the count-high byte arms the engine, so it lands last
            if (byte_done && cmd == CMD_TEXT_FILL)
                case (byte_idx)
                    8'd1: fill_char <= rx_byte;
                    8'd2: fill_attr <= rx_byte;
                    8'd3: fill_addr[7:0]  <= rx_byte;
                    8'd4: fill_addr[10:8] <= rx_byte[2:0];
                    8'd5: fill_lo <= rx_byte;
                    8'd6: fill_cnt <= {rx_byte[3:0], fill_lo};
                    default: ;
                endcase

            // ── floppy image host (FDD=1; all branches fold away at FDD=0) ──
            // FDD_MOUNT: [flags][cyls][spt][heads][tot_lo][tot_hi] — the
            // total-high byte arms the 6-step geometry write engine
            if (FDD != 0 && byte_done && cmd == CMD_FDD_MOUNT)
                case (byte_idx)
                    8'd1: fdd_flags <= rx_byte;
                    8'd2: fdd_cyls  <= rx_byte;
                    8'd3: fdd_spt   <= rx_byte;
                    8'd4: fdd_heads <= rx_byte;
                    8'd5: fdd_total[7:0] <= rx_byte;
                    8'd6: begin
                        fdd_total[15:8] <= rx_byte;
                        fdd_mount_st    <= 3'd1;
                    end
                    default: ;
                endcase

            // FDD_CTRL: [ctl] — bit0 pulses the machine reset, bit1 writes
            // the CPU speed from bits[3:2]
            if (FDD != 0 && byte_done && cmd == CMD_FDD_CTRL &&
                byte_idx == 8'd1) begin
                if (rx_byte[0])
                    fdd_reset_stb <= 1'b1;
                if (rx_byte[1])
                    fdd_turbo <= rx_byte[3:2];
            end

            // FDD_PUSH bytes land from byte_idx 1; byte_idx saturates at
            // 255 so fdd_cnt does the real counting (512 max as a guard).
            // The byte is staged for the mgmt engine (SPI bytes are ≥48
            // clks apart, so the 1-clk handoff can never collide).
            if (FDD != 0 && byte_done && cmd == CMD_FDD_PUSH &&
                byte_idx >= 8'd1 && fdd_cnt < 10'd512) begin
                fdd_cnt       <= fdd_cnt + 1'b1;
                fdd_push_byte <= rx_byte;
                fdd_push_stb  <= 1'b1;
            end

            // ── ROM loader ────────────────────────────────────────────────
            // BEGIN selects a bank, rewinds the write pointer and drops that
            // bank's valid bit, so a re-push is never half-old/half-new.
            if (ROMLOAD != 0 && byte_done && cmd == CMD_ROM_BEGIN &&
                byte_idx == 8'd1) begin
                rom_bank  <= rx_byte[2:0];
                rom_ptr   <= {ROM_AW{1'b0}};
                rom_valid[rx_byte[2:0]] <= 1'b0;
            end
            // DATA bytes land from byte_idx 1 and carry the pointer with them.
            // rom_addr is loaded from the PRE-increment pointer so address,
            // data and strobe all present the same byte on the next edge.
            if (ROMLOAD != 0 && byte_done && cmd == CMD_ROM_DATA &&
                byte_idx >= 8'd1) begin
                rom_addr <= rom_ptr;
                rom_data <= rx_byte;
                rom_we   <= 1'b1;
                rom_ptr  <= rom_ptr + 1'b1;
            end
            if (ss_rise) begin
                if (cmd == CMD_PING)
                    ping_cnt <= ping_cnt + 1'b1;
                // END carries no payload, so it commits at the frame end —
                // same shape as PING.
                if (ROMLOAD != 0 && cmd == CMD_ROM_END)
                    rom_valid[rom_bank] <= 1'b1;
                if (cmd == CMD_REQ_FETCH) begin
                    // The MCU polled, so it is alive: feed the watchdog on
                    // EVERY fetch, empty ones included.  (A real push feeds it
                    // at do_push as well, so this is not the only source.)
                    wdog    <= 0;
                    // A fetched request is consumed WHATEVER its type, so the
                    // next one starts at the top of the buffer.  This used to
                    // clear only for req_bus, on the reasoning that the LOAD
                    // path clears the buffer itself with the engine reset it
                    // issues per call — but a BUS transaction never issues
                    // one, so the first bus byte after a LOAD appended after
                    // the stale filename and the round arrived with it glued
                    // to the front (board-captured: "64KSUPPORT<LISTEN 8>").
                    // Harmless where it lands, but a 16-char name saturates
                    // name_len and the append path then drops the byte AND
                    // skips the submit while bus_took still tells the machine
                    // it was delivered — a silently lost LISTEN/TALK hangs.
                    //
                    // ...but ONLY for a frame that actually carried a request.
                    // `fetch_ann` is what this frame reported at resp_idx 2;
                    // an empty (type 0x00) poll consumed nothing and so must
                    // clear nothing, or it eats a byte written while it was in
                    // flight.  See fetch_ann's declaration.
                    if (fetch_ann) begin
                        pending  <= 0;
                        name_len <= 0;
                        bus_mask <= 16'd0;
                        req_bus  <= 0;
                    end
                end
                lanes <= lanes_next;    // LINK_CFG takes effect between frames
            end

            // ── CPU-side strobes (engine reset wins over everything) ──
            if (exp_wstb && (exp_laddr == 4'h1) && name_len < 5'd16) begin
                name[name_len[3:0]] <= exp_wdata;
                name_len <= name_len + 1'b1;
            end
            if (exp_wstb && (exp_laddr == 4'h0) && exp_wdata == 8'h01) begin
                pending   <= 1;
                submitted <= 1;
                req_bus   <= 0;
                wdog      <= 0;
            end

            // ── DOS-over-link: bus bytes from the KERNAL detours ──
            // $DF03 = under ATN, $DF04 = channel data.  Both append to the
            // same buffer; the mask remembers which were which.
            if (exp_wstb && (exp_laddr == 4'h3 || exp_laddr == 4'h4) &&
                name_len < 5'd16) begin
                name[name_len[3:0]] <= exp_wdata;
                bus_mask[name_len[3:0]] <= (exp_laddr == 4'h3);
                name_len <= name_len + 1'b1;
                // ATN bytes are the transaction boundaries, so they submit;
                // data bytes submit only to keep the buffer from overflowing
                // (a long channel write streams 16 bytes at a time).
                if ((exp_laddr == 4'h3) || (name_len == 5'd15)) begin
                    pending <= 1;
                    req_bus <= 1;
                    wdog    <= 0;
                end
            end
            if (exp_wstb && (exp_laddr == 4'h3)) begin
                // Addressing: the detour must know whether WE are the device
                // being talked to, or whether the byte belongs to the stock
                // KERNAL path (some other device on the wire).
                // UNLSN/UNTLK first: $3F and $5F sit INSIDE the LISTEN/TALK
                // ranges (device field $1F = "all devices"), so testing the
                // range first would read $3F as "LISTEN 31" and drop the byte
                // on the floor — the same $1F exclusion the drive's own ATN
                // decoder makes.
                if (exp_wdata == 8'h3F || exp_wdata == 8'h5F) begin
                    bus_took <= bus_own;      // ours to deliver, then release
                    bus_own  <= 1'b0;
                end
                else if (exp_wdata[7:5] == 3'b001 || exp_wdata[7:5] == 3'b010)
                begin
                    bus_own  <= (exp_wdata[4:0] == BUS_DEV);
                    bus_took <= (exp_wdata[4:0] == BUS_DEV);
                end
                else
                    bus_took <= bus_own;      // secondary address: unchanged
                // TALK addressed to us opens a fresh incoming transfer: the
                // FIFO must not still hold bytes from the previous one, or
                // the first GET# would read stale data.  Assignments below
                // the FIFO block on purpose — this wins the same clk.
                if (exp_wdata[7:5] == 3'b010 && exp_wdata[4:0] == BUS_DEV) begin
                    wr_ptr    <= 0;
                    rd_ptr    <= 0;
                    cnt       <= 0;
                    eof_lat   <= 0;
                    err_lat   <= 0;
                    submitted <= 1;
                    bus_stat_rd <= 0;
                end
            end
            if (do_engine_reset) begin
                name_len  <= 0;
                bus_mask  <= 16'd0;
                req_bus   <= 0;
                pending   <= 0;
                submitted <= 0;
                eof_lat   <= 0;
                err_lat   <= 0;
                wr_ptr    <= 0;
                rd_ptr    <= 0;
                cnt       <= 0;
                wdog      <= 0;
            end

            // ── floppy mgmt-bus engine (FDD=1) ──
            // One op per clk; the ops are protocol-exclusive (mount frames
            // never overlap sector frames, and the LBA read only runs while
            // no transfer is streaming), so a simple priority chain is safe.
            if (FDD != 0) begin
                fdd_mgmt_write <= 1'b0;
                fdd_mgmt_read  <= 1'b0;
                if (fdd_mount_st != 3'd0) begin
                    // geometry regs then media-present, img_host order;
                    // addr bit 7 = drive select
                    fdd_mgmt_write <= 1'b1;
                    fdd_mgmt_addr  <= {8'hF2, fdd_flags[7], 7'h00} |
                                      {12'h0,
                                       (fdd_mount_st == 3'd1) ? 4'h2 :
                                       (fdd_mount_st == 3'd2) ? 4'h3 :
                                       (fdd_mount_st == 3'd3) ? 4'h5 :
                                       (fdd_mount_st == 3'd4) ? 4'h4 :
                                       (fdd_mount_st == 3'd5) ? 4'h1 : 4'h0};
                    fdd_mgmt_wdata <=
                        (fdd_mount_st == 3'd1) ? {8'h00, fdd_cyls}  :
                        (fdd_mount_st == 3'd2) ? {8'h00, fdd_spt}   :
                        (fdd_mount_st == 3'd3) ? {8'h00, fdd_heads} :
                        (fdd_mount_st == 3'd4) ? fdd_total          :
                        (fdd_mount_st == 3'd5) ? {15'h0, fdd_flags[1]}
                                               : {15'h0, fdd_flags[0]};
                    fdd_mount_st <= (fdd_mount_st == 3'd6) ? 3'd0
                                                           : fdd_mount_st + 3'd1;
                end
                else if (fdd_push_stb) begin
                    fdd_push_stb   <= 1'b0;
                    fdd_mgmt_addr  <= 16'hF20F;
                    fdd_mgmt_wdata <= {8'h00, fdd_push_byte};
                    fdd_mgmt_write <= 1'b1;
                end
                else if (fdd_pop) begin
                    fdd_pop        <= 1'b0;
                    fdd_mgmt_addr  <= 16'hF20F;
                    fdd_mgmt_read  <= 1'b1;    // pops the show-ahead FIFO
                end
                else if (fdd_request != 2'b00 && !fdd_lba_valid) begin
                    // latch {drive, sector} from mgmt reg 0: set the address,
                    // one settle clk for the readback mux, then capture
                    fdd_mgmt_addr <= 16'hF200;
                    if (fdd_lba_st == 2'd2) begin
                        fdd_lba       <= fdd_mgmt_rdata;
                        fdd_req_q     <= fdd_request;
                        fdd_lba_valid <= 1'b1;
                        fdd_lba_st    <= 2'd0;
                    end else
                        fdd_lba_st <= fdd_lba_st + 2'd1;
                end
                if (fdd_request == 2'b00) begin
                    fdd_lba_valid <= 1'b0;   // request served: rearm
                    fdd_lba_st    <= 2'd0;
                end
            end
        end

`ifdef SIMULATION
    // engine trace for sim debugging: QSPI_DEBUG env has no reach here, so
    // gate on a plusarg (+qspidbg on the sim command line)
    reg dbg_en = 0;
    initial if ($test$plusargs("qspidbg")) dbg_en = 1;
    reg req_p = 0;
    always @(posedge clk) begin
        if (dbg_en && exp_wstb)
            $display("[qspi] wstb laddr=%0h wdata=%02h (pend=%b sub=%b nlen=%0d)",
                     exp_laddr, exp_wdata, pending, submitted, name_len);
        if (dbg_en && do_pop)
            $display("[qspi] %0t pop %02h cnt=%0d", $time, fifo[rd_ptr], cnt);
        if (dbg_en && do_push)
            $display("[qspi] %0t push %02h cnt=%0d", $time, rx_byte, cnt);
        if (dbg_en && exp_rstb)
            $display("[qspi] %0t rstb laddr=%0h status=%02h", $time, exp_laddr,
                     {avail, done, err_lat, 5'b0});
        req_p <= req;
        if (dbg_en && (req != req_p))
            $display("[qspi] req=%b (pend=%b sub=%b eof=%b err=%b cnt=%0d)",
                     req, pending, submitted, eof_lat, err_lat, cnt);
    end
    // trace the CPU's fetches from the routine window (throttled)
    reg [15:0] romrd_prev = 0;
    integer romrd_budget = 80;
    always @(posedge clk) begin
        if (dbg_en && sel_rom && exp_addr != romrd_prev && romrd_budget > 0) begin
            romrd_budget = romrd_budget - 1;
            $display("[qspi] romrd %04h -> %02h", exp_addr, rom_q);
        end
        if (sel_rom) romrd_prev <= exp_addr;
    end
`endif

endmodule
