/*
 * tb_cpu6502.v — bare 6502 + 64 KB RAM, for the opcode conformance test.
 *
 * The image in +image=<hex> is loaded into RAM, the CPU is released from
 * reset, and the run ends when the program writes to $FFFF.  RAM $2000-$2FFF
 * (where the test program parks its captured registers) is written back out
 * to +dump=<hex> for the checker to diff against a reference model.
 *
 * Bus contract copied from soc.v: AB is combinational out of the core, the
 * RAM read is REGISTERED (DI carries the byte for the address driven in the
 * previous cycle), and writes commit on the clock edge.  An asynchronous read
 * here would shift every fetch by a cycle and the core would not even reach
 * its reset vector.
 */
`timescale 1ns/1ps

module tb;

reg         clk   = 0;
reg         reset = 1;
wire [15:0] AB;
wire  [7:0] DO;
wire        WE;

reg   [7:0] mem [0:65535];
reg   [7:0] DI = 0;

always @(posedge clk)
    DI <= mem[AB];

reg         done  = 0;
integer     cycles = 0;
integer     max_cycles;
reg [1023:0] image_path;
reg [1023:0] dump_path;
reg [1023:0] cyc_path;
reg         cyc_en = 0;

/* ── cycle probe ──────────────────────────────────────────────────────────
 * The generator brackets each instruction under test with STA $BFFE (start)
 * and STA $BFFD (end).  The write-to-write cycle delta is the instruction's
 * cycle count plus a constant bracket overhead, which the checker calibrates
 * away with a leading NOP case.  Deltas land in cyc[] in program order and
 * are dumped to +cycdump=<hex>. */
integer     t0 = 0;
reg [15:0]  cyc [0:1023];
integer     ci = 0;

cpu dut(
    .clk   (clk),
    .reset (reset),
    .AB    (AB),
    .DI    (DI),
    .DO    (DO),
    .WE    (WE),
    .IRQ   (1'b0),
    .NMI   (1'b0),
    .RDY   (1'b1),
    .SO    (1'b0),
    .DI_STABLE(1'b0)
);

always #5 clk = ~clk;

initial begin
    if (!$value$plusargs("image=%s", image_path)) begin
        $display("tb_cpu6502: need +image=<hex>");
        $finish;
    end
    if (!$value$plusargs("dump=%s", dump_path)) begin
        $display("tb_cpu6502: need +dump=<hex>");
        $finish;
    end
    if (!$value$plusargs("maxcycles=%d", max_cycles))
        max_cycles = 20000000;
    if ($value$plusargs("cycdump=%s", cyc_path))
        cyc_en = 1;

    $readmemh(image_path, mem);
    repeat (4) @(posedge clk);
    reset <= 0;
end

always @(posedge clk)
    if (!reset) begin
        cycles <= cycles + 1;
        if (WE) begin
            mem[AB] <= DO;
            if (AB == 16'hFFFF)
                done <= 1;
            if (AB == 16'hBFFE)
                t0 <= cycles;
            if (AB == 16'hBFFD && ci < 1024) begin
                cyc[ci] <= cycles - t0;
                ci <= ci + 1;
            end
        end
    end

/* fires the edge after the sentinel write, so it has landed in mem */
always @(posedge clk)
    if (done) begin
        $writememh(dump_path, mem, 16'h2000, 16'h3FFF);
        if (cyc_en)
            $writememh(cyc_path, cyc, 0, ci ? ci - 1 : 0);
        $display("tb_cpu6502: done in %0d cycles", cycles);
        $finish;
    end else if (!reset && cycles > max_cycles) begin
        $display("tb_cpu6502: TIMEOUT after %0d cycles, AB=$%04h", cycles, AB);
        $writememh(dump_path, mem, 16'h2000, 16'h3FFF);
        $finish;
    end

endmodule
