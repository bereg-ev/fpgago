/*
 * drive_1541.v — a complete Commodore 1541 in fabric (c64/README.md).
 *
 * The drive's 6502 (the shared Arlet core, NMOS-cycle-exact and
 * conformance-gated) runs the REAL DOS ROM against two via6522 instances,
 * a GCR read engine and the head mechanism.  Behavior deliberately mirrors
 * the proven reference emulation (common/floppy1541/floppy1541.c full-emu mode) —
 * the model the whole compat corpus was verified against — including its
 * simplifications (no CA2/CB2 inputs, T2 stops on underflow, SOE ignored:
 * byte-ready always drives SO).  tb_drive1541.cpp runs the real ROM through
 * a KERNAL-style scripted IEC master and checks DOS-level behavior.
 *
 * Clocking: everything on `clk` (fabric); `tick` is a one-clk strobe = one
 * drive phi cycle.  The divider lives OUTSIDE (soc: DDS off the PLL —
 * AUTHENTIC 1.000 MHz or LOCKSTEP 985.248 kHz; TB: every Nth clk, N ≥ 2).
 * The read rails are captured AT the tick that ends a cycle, so the CPU's
 * same-edge consume sees the previous cycle's data and the new data holds
 * through the following cycle — the tb_cpu6502 bus contract.
 *
 * External memory (PSRAM in the soc, plain arrays in the TB):
 *   rom_addr/rom_data   16 KB DOS ROM ($C000-$FFFF).  Must be valid on the
 *                       fabric cycle after rom_addr settles (registered or
 *                       combinational); with N clks per phi the provider has
 *                       N-1 cycles.
 *   gcr_addr/gcr_data   pre-encoded GCR track stream, laid out exactly like
 *                       the reference encoder: per track, sectors 0..n-1,
 *                       each F1541_GCR_SECTOR_LEN = 363 bytes
 *                       (5×FF | 10 hdr | 9×55 | 5×FF | 325 data | 9×55),
 *                       tracks at TRACK_STRIDE intervals.  The engine
 *                       presents the NEXT byte's address a full byte-time
 *                       (≥26 µs) early — a PSRAM fetch is trivial.
 *
 * IEC wires are LEVELS (1 = released/high), pulls are 1 = pull low.  The
 * hardware ATN-auto-ack (ATN xor ATNA drives DATA low) is combinational,
 * as on the real board.
 */

module drive_1541 #(
    parameter TRACK_STRIDE = 22'd8192      /* GCR track slot spacing */
)(
    input  wire        clk,
    input  wire        rst,                /* sync, active high */
    input  wire        tick,               /* one drive phi cycle */

    /* IEC bus */
    input  wire        iec_atn,            /* wire level, 1 = released */
    input  wire        iec_clk_in,
    input  wire        iec_data_in,
    output wire        iec_clk_pull,       /* 1 = pull low */
    output wire        iec_data_pull,

    /* DOS ROM ($C000-$FFFF) */
    output wire [13:0] rom_addr,
    output wire        rom_sel,           /* this phi's bus cycle is in ROM */
    input  wire [7:0]  rom_data,

    /* pre-encoded GCR track stream */
    output wire [21:0] gcr_addr,
    input  wire [7:0]  gcr_data,

    input  wire        disk_writable,      /* 0 = write-protected */

    /* status taps (BIOS/debug; pruned when unconnected) */
    output wire        dbg_motor,
    output wire        dbg_led,
    output wire [6:0]  dbg_halftrack,
    output wire [15:0] dbg_cpu_ab,
    /* Last byte the DOS wrote to RAM $0085 — its "secondary address of the
     * command in progress".  $E0 there at ATN release means CLOSE channel 0,
     * which is what ends every KERNAL LOAD; that is exactly the test the C
     * reference uses (iec1541.c: `d->ram[0x85] == 0xE0`), and the soc turns
     * it into the load-done event the BIOS autostart waits on.  Snooped on
     * the write instead of read back so the 2 KB RAM keeps its single port. */
    output reg  [7:0]  dbg_ram85
);

/* ── CPU ──────────────────────────────────────────────────────────────── */
wire [15:0] AB;
wire [7:0]  DO;
wire        WE;
reg  [7:0]  DI;
wire        via1_irq, via2_irq;
reg         so_pulse = 1'b0;

cpu cpu0(
    .clk   (clk),
    .reset (rst),
    .AB    (AB),
    .DI    (DI),
    .DO    (DO),
    .WE    (WE),
    .IRQ   (via1_irq | via2_irq),
    .NMI   (1'b0),
    .RDY   (tick),
    .SO    (so_pulse),
    /* the DI rails below are registered and stable through every phi, so
     * DIMUX may bypass DIHOLD — this is what keeps AB valid MID-phi for
     * the PSRAM backend's prefetcher (see cpu_6502.v) */
    .DI_STABLE(1'b1)
);

assign dbg_cpu_ab = AB;

/* address decode (mirrors floppy1541.c emu_read/emu_write exactly) */
wire sel_ram  = (AB < 16'h1800);
wire sel_via1 = (AB >= 16'h1800) && (AB < 16'h1C00);
wire sel_via2 = (AB >= 16'h1C00) && (AB < 16'h2000);
wire sel_rom  = (AB >= 16'hC000);

assign rom_addr = AB[13:0];
assign rom_sel  = sel_rom;

/* ── 2 KB drive RAM (one EBR, registered read) ────────────────────────── */
reg [7:0] ram [0:2047];
reg [7:0] ram_q;

always @(posedge clk) begin
    if (tick && WE && sel_ram)
        ram[AB[10:0]] <= DO;
    if (tick)
        ram_q <= ram[AB[10:0]];
end

/* $85 snoop (see dbg_ram85).  Powers up 0 and is only ever assigned from a
 * signal, so the ecp5-rst-constfold trap does not apply. */
initial dbg_ram85 = 8'h00;
always @(posedge clk)
    if (rst)
        dbg_ram85 <= 8'h00;
    else if (tick && WE && sel_ram && AB[10:0] == 11'h085)
        dbg_ram85 <= DO;

/* ── VIAs ─────────────────────────────────────────────────────────────── */
wire [7:0] via1_rdata, via2_rdata;
wire [7:0] via1_orb, via1_ddrb, via2_orb, via2_ddrb;

/* VIA1 pin glue: every serial input passes a 74LS14, so a PB bit reads 1
 * when its bus line is ASSERTED (low).  emu_bus_in, verbatim. */
wire [7:0] via1_pb_in = { ~iec_atn, 2'b00 /* dev 8 */, 1'b0, 1'b0,
                          ~iec_clk_in, 1'b0, ~iec_data_in };

reg        via2_ca1 = 1'b0;               /* byte-ready pulse */
reg  [7:0] gcr_latch = 8'h55;             /* PA in: byte under the head */
reg        sync_det = 1'b0;

wire [7:0] via2_pb_in = { ~sync_det, 2'b00, disk_writable, 4'b0000 };

via6522 via1(
    .clk(clk), .rst(rst), .tick(tick),
    .acc_stb(tick && sel_via1), .acc_we(WE),
    .acc_addr(AB[3:0]), .acc_wdata(DO), .rdata(via1_rdata),
    .pa_in(8'h00), .pb_in(via1_pb_in),
    .ca1(~iec_atn), .cb1(1'b0),
    .irq(via1_irq),
    .ora_q(), .orb_q(via1_orb), .ddra_q(), .ddrb_q(via1_ddrb),
    .t1_pb7_q(), .acr7_q(),
    .dbg_t1c(), .dbg_t1l(), .dbg_t2c(), .dbg_t2l(), .dbg_sr(),
    .dbg_acr(), .dbg_pcr(), .dbg_ifr(), .dbg_ier(),
    .dbg_t1_active(), .dbg_t2_active()
);

via6522 via2(
    .clk(clk), .rst(rst), .tick(tick),
    .acc_stb(tick && sel_via2), .acc_we(WE),
    .acc_addr(AB[3:0]), .acc_wdata(DO), .rdata(via2_rdata),
    .pa_in(gcr_latch), .pb_in(via2_pb_in),
    .ca1(via2_ca1), .cb1(1'b0),
    .irq(via2_irq),
    .ora_q(), .orb_q(via2_orb), .ddra_q(), .ddrb_q(via2_ddrb),
    .t1_pb7_q(), .acr7_q(),
    .dbg_t1c(), .dbg_t1l(), .dbg_t2c(), .dbg_t2l(), .dbg_sr(),
    .dbg_acr(), .dbg_pcr(), .dbg_ifr(), .dbg_ier(),
    .dbg_t1_active(), .dbg_t2_active()
);

/* ── registered read rails → DI (tb_cpu6502 bus contract) ─────────────── */
reg [7:0] via1_q, via2_q, rom_q;
reg [1:0] sel_r;      /* 0 ram, 1 via1, 2 via2, 3 rom/open */
reg       open_r;

/* captured AT the tick ending the cycle — NBA order means the CPU's same-
 * edge consume still sees the PREVIOUS cycle's data, and this data holds
 * through the next cycle (the tb_cpu6502 `DI <= mem[AB]` contract).  The
 * providers (ROM/GCR/PSRAM glue) therefore have the WHOLE phi cycle to make
 * their data combinationally stable before its closing tick. */
always @(posedge clk)
    if (tick) begin
        via1_q <= via1_rdata;
        via2_q <= via2_rdata;
        rom_q  <= rom_data;
        sel_r  <= sel_ram ? 2'd0 : sel_via1 ? 2'd1 : sel_via2 ? 2'd2 : 2'd3;
        open_r <= !sel_ram && !sel_via1 && !sel_via2 && !sel_rom;
    end

always @* begin
    case (sel_r)
        2'd0:    DI = ram_q;
        2'd1:    DI = via1_q;
        2'd2:    DI = via2_q;
        default: DI = open_r ? 8'hFF : rom_q;
    endcase
end

/* ── IEC drive side (emu_bus_out, verbatim incl. the ATN-ack gate) ────── */
wire [7:0] via1_pb_out = via1_orb & via1_ddrb;
wire       atna        = via1_pb_out[4];
assign iec_data_pull = via1_pb_out[1] | ((~iec_atn) ^ atna);
assign iec_clk_pull  = via1_pb_out[3];

/* ── head mechanism ───────────────────────────────────────────────────── */
reg [6:0] halftrack = 7'd0;               /* mirror the C model's power-on */
reg [1:0] step_phase = 2'b00;
wire      motor_on = |(via2_orb & via2_ddrb & 8'h04);

assign dbg_motor     = motor_on;
assign dbg_led       = via2_orb[3];
assign dbg_halftrack = halftrack;

always @(posedge clk)
    if (rst) begin
        halftrack <= 7'd0;
        step_phase <= 2'b00;
    end else if (tick) begin
        if (via2_orb[1:0] != step_phase) begin : step
            reg [1:0] delta;
            delta = via2_orb[1:0] - step_phase;
            if (delta == 2'd1 && halftrack < 7'd69)
                halftrack <= halftrack + 7'd1;
            else if (delta == 2'd3 && halftrack != 7'd0)
                halftrack <= halftrack - 7'd1;
            step_phase <= via2_orb[1:0];
        end
    end

/* track geometry (d64 zones) */
wire [5:0] track = {1'b0, halftrack[6:1]} + 6'd1;   /* 1..35 */
reg  [4:0] num_sectors;
reg  [5:0] cpb;                                     /* cycles per GCR byte */
always @* begin
    if (track <= 6'd17)      begin num_sectors = 5'd21; cpb = 6'd26; end
    else if (track <= 6'd24) begin num_sectors = 5'd19; cpb = 6'd28; end
    else if (track <= 6'd30) begin num_sectors = 5'd18; cpb = 6'd30; end
    else                     begin num_sectors = 5'd17; cpb = 6'd32; end
end
/* track_len = num_sectors * 363 */
wire [18:0] tl_full   = num_sectors * 14'd363;
wire [13:0] track_len = tl_full[13:0];

/* ── GCR read engine ──────────────────────────────────────────────────── */
reg [13:0] gcr_pos = 14'd0;               /* next byte to deliver */
`ifdef SIMULATION
integer dbg_gcrn = 0;
`endif
reg [5:0]  byte_cnt = 6'd0;
reg [7:0]  ff_run = 8'd0;
reg [7:0]  gcr_hold = 8'h55;

/* clamped track index for addressing (track is 1..35 by construction) */
wire [27:0] track_base_f = (track - 6'd1) * TRACK_STRIDE;
assign gcr_addr = track_base_f[21:0] + {8'd0, gcr_pos};

always @(posedge clk) begin
    if (!tick)
        gcr_hold <= gcr_data;             /* provider has all inter-tick
                                           * cycles; last capture wins */
    if (rst) begin
        gcr_pos <= 14'd0; byte_cnt <= 6'd0; ff_run <= 8'd0;
        sync_det <= 1'b0; via2_ca1 <= 1'b0; so_pulse <= 1'b0;
        gcr_latch <= 8'h55;
    end else if (tick) begin
        via2_ca1 <= 1'b0;
        so_pulse <= 1'b0;
        if (motor_on) begin
            if (byte_cnt + 6'd1 >= cpb) begin : boundary
                reg [7:0] b;
                reg [7:0] run_n;
`ifdef SIMULATION
                if ($test$plusargs("fdgcr") && dbg_gcrn < 48) begin
                    dbg_gcrn = dbg_gcrn + 1;
                    $display("[fdgcr] addr=%h byte=%h trk=%0d pos=%0d",
                             gcr_addr, gcr_hold, track, gcr_pos);
                end
`endif
                byte_cnt <= 6'd0;
                b = gcr_hold;
                gcr_latch <= b;
                run_n = (b == 8'hFF)
                        ? ((ff_run < 8'd250) ? ff_run + 8'd1 : ff_run)
                        : 8'd0;
                ff_run   <= run_n;
                sync_det <= (run_n >= 8'd2);
                if (run_n < 8'd2) begin   /* sync suppresses byte-ready */
                    via2_ca1 <= 1'b1;
                    so_pulse <= 1'b1;
                end
                gcr_pos <= (gcr_pos + 14'd1 >= track_len) ? 14'd0
                                                          : gcr_pos + 14'd1;
            end else
                byte_cnt <= byte_cnt + 6'd1;
        end
    end
end

endmodule
