/* cpu_serv — adapter around SERV (bit-serial RV32I) mapping its Wishbone-like
 * ibus / dbus onto the simple bus the SoC uses.
 *
 * SERV (https://github.com/olofk/serv) is by Olof Kindgren (ISC).  The CPU is
 * bit-serial — ~33 cycles per instruction — but uses an order of magnitude
 * less FPGA area than a conventional RV32 core.
 *
 * Bus mapping (Wishbone-classic):
 *   cyc=1 means "I want this transaction"; we ack with `ack=1` on the next
 *   cycle.  Our ROM is synchronous (1-cycle), so ack-after-cyc fits natively.
 *
 *   Instruction bus is read-only: when o_ibus_cyc=1, latch o_ibus_adr, return
 *   instr_value as i_ibus_rdt next cycle with i_ibus_ack=1.
 *
 *   Data bus:
 *     o_dbus_we=0 → read:  return data_in_value as i_dbus_rdt, ack next cycle.
 *     o_dbus_we=1 → write: pulse data_wr with the strobe (o_dbus_sel) + value.
 */
`default_nettype none

module cpu_serv (
    input         clk,
    input         rst,             // active-low

    output [23:0] instr_addr,
    input  [31:0] instr_value,

    output [23:0] data_addr,
    input  [31:0] data_in_value,
    output        data_rd,
    output [31:0] data_out_value,
    output [3:0]  data_out_strobe,
    output        data_wr
);

    // ── SERV bus signals ─────────────────────────────────────────────────
    wire [31:0] ibus_adr;
    wire        ibus_cyc;
    wire [31:0] dbus_adr;
    wire [31:0] dbus_dat;
    wire [3:0]  dbus_sel;
    wire        dbus_we;
    wire        dbus_cyc;

    wire        ibus_ack;
    wire        dbus_ack;
    wire [31:0] ibus_rdt;
    wire [31:0] dbus_rdt;

    serv_rf_top #(
        .RESET_PC       (32'd0),
        .COMPRESSED     (1'b0),
        .ALIGN          (1'b0),
        .MDU            (1'b0),
        .PRE_REGISTER   (1),
        .RESET_STRATEGY ("MINI"),
        .WITH_CSR       (1),
        .W              (1)
    ) u_serv (
        .clk          (clk),
        .i_rst        (~rst),         // SERV's reset is active-high
        .i_timer_irq  (1'b0),

        .o_ibus_adr   (ibus_adr),
        .o_ibus_cyc   (ibus_cyc),
        .i_ibus_rdt   (ibus_rdt),
        .i_ibus_ack   (ibus_ack),

        .o_dbus_adr   (dbus_adr),
        .o_dbus_dat   (dbus_dat),
        .o_dbus_sel   (dbus_sel),
        .o_dbus_we    (dbus_we),
        .o_dbus_cyc   (dbus_cyc),
        .i_dbus_rdt   (dbus_rdt),
        .i_dbus_ack   (dbus_ack),

        // Extension interfaces — unused
        .o_ext_funct3 (),
        .i_ext_ready  (1'b0),
        .i_ext_rd     (32'd0),
        .o_ext_rs1    (),
        .o_ext_rs2    (),
        .o_mdu_valid  ()
    );

    // ── Drive SoC fetch / data buses ─────────────────────────────────────
    assign instr_addr      = ibus_adr[23:0];
    assign data_addr       = dbus_adr[23:0];
    assign data_out_value  = dbus_dat;
    assign data_out_strobe = dbus_sel;
    // Pulse data_rd/data_wr only on the ack cycle so the SoC's slaves see a
    // single transaction (otherwise UART would print each char twice because
    // dbus_cyc stays asserted for ≥2 cycles around the ack).
    assign data_rd         = dbus_cyc_d && !dbus_we;
    assign data_wr         = dbus_cyc_d && dbus_we;

    // ── Wishbone-style ack
    //
    // Pattern: when SERV raises cyc, we pulse ack=1 for ONE cycle on the
    // NEXT cycle, when the synchronous ROM's dout is valid.  The ack pulse
    // gates SERV to capture the read data, then SERV deasserts cyc.
    //
    // 1-cycle delay state machine: register cyc into _d, raise ack=_d.
    reg ibus_cyc_d;
    reg dbus_cyc_d;
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            ibus_cyc_d <= 1'b0;
            dbus_cyc_d <= 1'b0;
        end else begin
            // Hold _d high only when cyc is high and ack hasn't yet pulsed.
            ibus_cyc_d <= ibus_cyc & ~ibus_ack;
            dbus_cyc_d <= dbus_cyc & ~dbus_ack;
        end
    end
    // ack: one cycle after cyc rises.  Capture the ROM dout into rdt at the
    // same time (the SoC's instr_value / data_in_value are already valid
    // because the BRAM was sampled the cycle before).
    assign ibus_ack = ibus_cyc_d;
    assign dbus_ack = dbus_cyc_d;
    assign ibus_rdt = instr_value;
    assign dbus_rdt = data_in_value;

endmodule

`default_nettype wire
