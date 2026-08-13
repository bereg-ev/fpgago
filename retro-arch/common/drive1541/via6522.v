/*
 * via6522.v — MOS 6522 VIA for the FPGA 1541 (see c64/README.md).
 *
 * Register-exact mirror of the PROVEN reference model the whole compat
 * corpus was verified against: common/floppy1541/via6522.c.  Where that model
 * deviates from a real 6522 (T2 stops after underflow instead of free
 * counting, no CA2/CB2 edge inputs, no shift-register engine — the 1541
 * uses none of these), this RTL deviates identically ON PURPOSE: the
 * lockstep TB (tb_via6522.cpp) compares full state against the C model
 * every cycle, and the drive-level TB compares against floppy1541.c's
 * full emulation.  Fix real-silicon gaps in BOTH models or neither.
 *
 * Timing contract: `tick` is one drive phi cycle (strobe).  A register
 * access (`acc_stb`, with `tick` on the same fabric edge from the drive
 * glue) applies its side effects BEFORE the tick's edge-detect/timer
 * step — the same order as the C model (access during the instruction,
 * via6522_tick after).  `rdata` is combinational from pre-edge state,
 * exactly the value the C model's read returns.
 */

module via6522(
    input  wire        clk,
    input  wire        rst,        // sync, active high; values match reset()

    input  wire        tick,       // one 6502 drive cycle elapses
    input  wire        acc_stb,    // register access this cycle
    input  wire        acc_we,     // 1 = write
    input  wire [3:0]  acc_addr,
    input  wire [7:0]  acc_wdata,
    output reg  [7:0]  rdata,      // combinational read data

    input  wire [7:0]  pa_in,      // input pin states
    input  wire [7:0]  pb_in,
    input  wire        ca1,        // control inputs (active-high, like the
    input  wire        cb1,        //  C model: glue does any inversion)

    output wire        irq,

    // port views for the glue (pin = ddr ? or : pin_in, done outside)
    output wire [7:0]  ora_q,
    output wire [7:0]  orb_q,
    output wire [7:0]  ddra_q,
    output wire [7:0]  ddrb_q,
    output wire        t1_pb7_q,
    output wire        acr7_q,

    // lockstep-TB state taps (pruned in synthesis when unconnected)
    output wire [15:0] dbg_t1c,
    output wire [15:0] dbg_t1l,
    output wire [15:0] dbg_t2c,
    output wire [7:0]  dbg_t2l,
    output wire [7:0]  dbg_sr,
    output wire [7:0]  dbg_acr,
    output wire [7:0]  dbg_pcr,
    output wire [6:0]  dbg_ifr,
    output wire [6:0]  dbg_ier,
    output wire        dbg_t1_active,
    output wire        dbg_t2_active
);

/* IFR/IER bit positions (bit 7 = "any", computed) */
localparam B_CA2 = 0, B_CA1 = 1, B_SR = 2, B_CB2 = 3, B_CB1 = 4,
           B_T2  = 5, B_T1  = 6;

reg [7:0]  orb  = 8'h00, ora  = 8'h00;
reg [7:0]  ddrb = 8'h00, ddra = 8'h00;
reg [15:0] t1c  = 16'hFFFF, t1l = 16'hFFFF;
reg [15:0] t2c  = 16'hFFFF;
reg [7:0]  t2l  = 8'hFF;
reg [7:0]  sr   = 8'h00, acr = 8'h00, pcr = 8'h00;
reg [6:0]  ifr  = 7'h00, ier = 7'h00;
reg        t1_active = 1'b0, t2_active = 1'b0;
reg        t1_pb7 = 1'b1;
reg        ca1_prev = 1'b0, cb1_prev = 1'b0;

assign irq      = |(ifr & ier);
assign ora_q    = ora;
assign orb_q    = orb;
assign ddra_q   = ddra;
assign ddrb_q   = ddrb;
assign t1_pb7_q = t1_pb7;
assign acr7_q   = acr[7];

assign dbg_t1c = t1c;  assign dbg_t1l = t1l;
assign dbg_t2c = t2c;  assign dbg_t2l = t2l;
assign dbg_sr  = sr;   assign dbg_acr = acr;  assign dbg_pcr = pcr;
assign dbg_ifr = ifr;  assign dbg_ier = ier;
assign dbg_t1_active = t1_active;
assign dbg_t2_active = t2_active;

/* Port B read value: output bits from ORB, inputs from pins, PB7 from the
 * T1 toggle when ACR7 free-run output mode is on. */
wire [7:0] irb_base = (orb & ddrb) | (pb_in & ~ddrb);
wire [7:0] irb = acr[7] ? {t1_pb7, irb_base[6:0]} : irb_base;
wire [7:0] ira = (ora & ddra) | (pa_in & ~ddra);

/* combinational read data — value only; side effects on the clock edge */
always @* begin
    case (acc_addr)
        4'h0:    rdata = irb;
        4'h1:    rdata = ira;
        4'h2:    rdata = ddrb;
        4'h3:    rdata = ddra;
        4'h4:    rdata = t1c[7:0];
        4'h5:    rdata = t1c[15:8];
        4'h6:    rdata = t1l[7:0];
        4'h7:    rdata = t1l[15:8];
        4'h8:    rdata = t2c[7:0];
        4'h9:    rdata = t2c[15:8];
        4'hA:    rdata = sr;
        4'hB:    rdata = acr;
        4'hC:    rdata = pcr;
        4'hD:    rdata = {irq, ifr};
        4'hE:    rdata = {1'b1, ier};
        default: rdata = ira;               /* $F: port A, no handshake */
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        orb <= 8'h00; ora <= 8'h00; ddrb <= 8'h00; ddra <= 8'h00;
        t1c <= 16'hFFFF; t1l <= 16'hFFFF; t2c <= 16'hFFFF; t2l <= 8'hFF;
        sr <= 8'h00; acr <= 8'h00; pcr <= 8'h00;
        ifr <= 7'h00; ier <= 7'h00;
        t1_active <= 1'b0; t2_active <= 1'b0; t1_pb7 <= 1'b1;
        ca1_prev <= 1'b0; cb1_prev <= 1'b0;
    end else begin : via_step
        /* blocking locals so the access→tick ordering matches the C model
         * within one fabric edge */
        reg [6:0]  ifr_n;
        reg [15:0] t1c_n, t1l_n, t2c_n;
        reg [7:0]  t2l_n, acr_n, pcr_n;
        reg [6:0]  ier_n;
        reg        t1a_n, t2a_n, pb7_n;

        ifr_n = ifr;  t1c_n = t1c;  t1l_n = t1l;  t2c_n = t2c;
        t2l_n = t2l;  acr_n = acr;  pcr_n = pcr;  ier_n = ier;
        t1a_n = t1_active;  t2a_n = t2_active;  pb7_n = t1_pb7;

        /* ── register access (side effects; rdata already served) ── */
        if (acc_stb) begin
            if (acc_we) begin
                case (acc_addr)
                    4'h0: begin orb <= acc_wdata;
                                ifr_n = ifr_n & ~(7'h08 | 7'h10); end
                    4'h1: begin ora <= acc_wdata;
                                ifr_n = ifr_n & ~(7'h01 | 7'h02); end
                    4'h2: ddrb <= acc_wdata;
                    4'h3: ddra <= acc_wdata;
                    4'h4: t1l_n = {t1l_n[15:8], acc_wdata};
                    4'h5: begin                     /* T1C-H: start */
                        t1l_n = {acc_wdata, t1l_n[7:0]};
                        t1c_n = {acc_wdata, t1l_n[7:0]};
                        ifr_n = ifr_n & ~(7'h40);
                        t1a_n = 1'b1;
                        pb7_n = 1'b1;
                    end
                    4'h6: t1l_n = {t1l_n[15:8], acc_wdata};
                    4'h7: begin                     /* T1L-H: latch only */
                        t1l_n = {acc_wdata, t1l_n[7:0]};
                        ifr_n = ifr_n & ~(7'h40);
                    end
                    4'h8: t2l_n = acc_wdata;
                    4'h9: begin                     /* T2C-H: start */
                        t2c_n = {acc_wdata, t2l_n};
                        ifr_n = ifr_n & ~(7'h20);
                        t2a_n = 1'b1;
                    end
                    4'hA: sr  <= acc_wdata;
                    4'hB: acr_n = acc_wdata;
                    4'hC: pcr_n = acc_wdata;
                    4'hD: ifr_n = ifr_n & ~acc_wdata[6:0];
                    4'hE: ier_n = acc_wdata[7] ? (ier_n |  acc_wdata[6:0])
                                               : (ier_n & ~acc_wdata[6:0]);
                    default: ora <= acc_wdata;      /* $F: no flag clear */
                endcase
            end else begin
                case (acc_addr)
                    4'h0: ifr_n = ifr_n & ~(7'h08 | 7'h10); /* CB2|CB1 */
                    4'h1: ifr_n = ifr_n & ~(7'h01 | 7'h02); /* CA2|CA1 */
                    4'h4: ifr_n = ifr_n & ~(7'h40);          /* T1 */
                    4'h8: ifr_n = ifr_n & ~(7'h20);          /* T2 */
                    default: ;
                endcase
            end
        end

        /* ── one drive cycle: edges then timers (C model order) ── */
        if (tick) begin
            if (ca1 != ca1_prev) begin
                if (pcr_n[0] ? ca1 : ~ca1)
                    ifr_n = ifr_n | 7'h02;
                ca1_prev <= ca1;
            end
            if (cb1 != cb1_prev) begin
                if (pcr_n[4] ? cb1 : ~cb1)
                    ifr_n = ifr_n | 7'h10;
                cb1_prev <= cb1;
            end

            if (t1a_n) begin
                if (t1c_n == 16'h0000) begin        /* underflow this tick */
                    ifr_n = ifr_n | 7'h40;
                    pb7_n = ~pb7_n;
                    if (acr_n[6])
                        t1c_n = t1l_n;              /* free-run reload */
                    else begin
                        t1c_n = 16'hFFFF;
                        t1a_n = 1'b0;               /* one-shot: stop */
                    end
                end else
                    t1c_n = t1c_n - 16'd1;
            end

            if (t2a_n && !acr_n[5]) begin           /* timed mode only */
                if (t2c_n == 16'h0000) begin
                    ifr_n = ifr_n | 7'h20;
                    t2c_n = 16'hFFFF;
                    t2a_n = 1'b0;                   /* C model: stops */
                end else
                    t2c_n = t2c_n - 16'd1;
            end
        end

        ifr <= ifr_n;  t1c <= t1c_n;  t1l <= t1l_n;  t2c <= t2c_n;
        t2l <= t2l_n;  acr <= acr_n;  pcr <= pcr_n;  ier <= ier_n;
        t1_active <= t1a_n;  t2_active <= t2a_n;  t1_pb7 <= pb7_n;
    end
end

endmodule
