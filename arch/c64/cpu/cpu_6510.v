/*
 * cpu_6510.v — MOS 6510 CPU (6502 + 6-bit I/O port)
 *
 * Wraps the Arlet Ottens 6502 core and adds:
 *   $0000 — Data Direction Register (DDR): 1=output, 0=input
 *   $0001 — I/O Port:
 *     Bit 0: LORAM  (1=BASIC ROM visible)
 *     Bit 1: HIRAM  (1=KERNAL ROM visible)
 *     Bit 2: CHAREN (1=I/O visible, 0=Char ROM visible at $D000)
 *     Bit 3: Cassette data output
 *     Bit 4: Cassette switch sense (input)
 *     Bit 5: Cassette motor control
 *
 * Default after reset: DDR=$2F, Port=$37
 *   LORAM=1, HIRAM=1, CHAREN=1 → standard BASIC+KERNAL+I/O layout
 */

module cpu_6510(
    input         clk,
    input         reset,      // active high reset
    input   [7:0] DI,
    output  [7:0] DO,
    output [15:0] AB,
    output        WE,
    input         IRQ,
    input         NMI,
    input         RDY,

    // I/O port output (directly accessible by SoC for memory banking)
    output  [5:0] port_out,
    // Port register read values (for SoC data mux)
    output  [7:0] port_ddr_out,
    output  [7:0] port_read_out
);

    /* ── 6502 core ─────────────────────────────────────────────────────── */
    wire [7:0] cpu_do;
    wire [15:0] cpu_ab;
    wire cpu_we;

    cpu cpu_inst(
        .clk   (clk),
        .reset (reset),
        .AB    (cpu_ab),
        .DI    (DI),
        .DO    (cpu_do),
        .WE    (cpu_we),
        .IRQ   (IRQ),
        .NMI   (NMI),
        .RDY   (RDY)
    );

    /* ── I/O Port ($0000-$0001) ────────────────────────────────────────── */
    reg [7:0] ddr;         // Data Direction Register ($0000)
    reg [7:0] port_reg;    // Port Register ($0001)

    wire port_sel    = (cpu_ab == 16'h0000 || cpu_ab == 16'h0001);
    wire port_sel_rd = port_sel && !cpu_we;
    wire port_sel_wr = port_sel && cpu_we;

    // Read: DDR at $0000, Port at $0001
    wire [7:0] port_data_out = (cpu_ab[0] == 0) ? ddr : (port_reg & ddr) | (8'hFF & ~ddr);

    // Output to SoC: only bits where DDR=1 (output mode)
    assign port_out = port_reg[5:0] & ddr[5:0];
    assign port_ddr_out = ddr;
    assign port_read_out = (port_reg & ddr) | (8'hFF & ~ddr);

    always @(posedge clk) begin
        if (reset) begin
            ddr      <= 8'h2F;     // bits 0-3,5 = output; bit 4 = input
            port_reg <= 8'h37;     // LORAM=1, HIRAM=1, CHAREN=1
        end else if (port_sel_wr && RDY) begin
            if (cpu_ab[0] == 0)
                ddr <= cpu_do;
            else
                port_reg <= cpu_do;
        end
    end

    /* ── Pass through signals ──────────────────────────────────────────── */
    assign AB = cpu_ab;
    assign DO = cpu_do;
    assign WE = cpu_we;  // writes to $0000/$0001 go to BOTH port and RAM (like real 6510)

endmodule
