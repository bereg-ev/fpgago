/* cpu_picorv32 — adapter around PicoRV32 mapping its unified memory bus
 * (mem_valid / mem_ready / mem_addr / mem_rdata / mem_wdata / mem_wstrb /
 *  mem_instr) onto the simple bus used by soc.v.
 *
 * PicoRV32 (https://github.com/YosysHQ/picorv32) is by Claire Wolf (ISC).
 *
 * Notes:
 *  - PicoRV32's resetn is active-low; our `rst` is also active-low → pass-through.
 *  - Single bus: mem_instr distinguishes fetch from data.  We multiplex onto
 *    the SoC's separate instr / data ports below.
 *  - Memory protocol: CPU drives mem_valid until SoC drives mem_ready high.
 *    Our BRAM is synchronous (1-cycle).  We register the request and ack on
 *    the next cycle.
 */
`default_nettype none

module cpu_picorv32 (
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

    // ── PicoRV32 unified bus ────────────────────────────────────────────
    wire        mem_valid;
    wire        mem_instr;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;
    reg         mem_ready;

    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .COMPRESSED_ISA(0),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_IRQ(0),
        .CATCH_MISALIGN(0),
        .CATCH_ILLINSN(0),
        .STACKADDR(32'h0000_8000)   // SP init (top of RAM — doesn't matter for our ROM-only test)
    ) u_pico (
        .clk        (clk),
        .resetn     (rst),
        .trap       (),

        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),

        // Look-ahead interface — unused
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),
        .mem_la_wdata (),
        .mem_la_wstrb (),

        // PCPI / IRQ — unused
        .pcpi_valid (),
        .pcpi_insn  (),
        .pcpi_rs1   (),
        .pcpi_rs2   (),
        .pcpi_wr    (1'b0),
        .pcpi_rd    (32'd0),
        .pcpi_wait  (1'b0),
        .pcpi_ready (1'b0),

        .irq        (32'd0),
        .eoi        ()
    );

    // ── Demux: route PicoRV32's request onto fetch port (mem_instr=1) or
    // data port (mem_instr=0).  BRAM is 1-cycle synchronous → we register
    // the in-flight request and ack on the next cycle. ──────────────────
    reg in_flight;
    reg in_flight_instr;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            in_flight       <= 1'b0;
            in_flight_instr <= 1'b0;
            mem_ready       <= 1'b0;
        end else begin
            mem_ready <= 1'b0;
            if (mem_valid && !in_flight) begin
                in_flight       <= 1'b1;
                in_flight_instr <= mem_instr;
            end else if (in_flight) begin
                in_flight <= 1'b0;
                mem_ready <= 1'b1;
            end
        end
    end

    // Drive the SoC's fetch / data lines from the same PicoRV32 bus.
    // For fetch: only the address matters; data comes back via instr_value.
    // For data: handle read (data_rd) and write (data_wr) separately.
    assign instr_addr       = mem_addr[23:0];

    assign data_addr        = mem_addr[23:0];
    assign data_rd          = mem_valid && !mem_instr && (mem_wstrb == 4'b0) && !in_flight;
    assign data_wr          = mem_valid && !mem_instr && (mem_wstrb != 4'b0) && !in_flight;
    assign data_out_value   = mem_wdata;
    assign data_out_strobe  = mem_wstrb;

    // Return read data the cycle the ack pulses.
    assign mem_rdata = in_flight_instr ? instr_value : data_in_value;

endmodule

`default_nettype wire
