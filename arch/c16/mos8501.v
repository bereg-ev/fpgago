`timescale 1ns / 1ps
// MOS 8501 CPU shell — wraps Arlet's verilog-6502 with I/O port at $0000-$0001.
// Drop-in replacement for the T65-based mos8501 from the MiST C16 project.
//
// Pipeline note: The Arlet 6502 expects one-clock memory latency (address on
// cycle N, data on cycle N+1). But the TED bus uses the CPU address immediately
// after cpuenable, making data arrive for the CURRENT address instead of the
// previous one. We fix this by latching address/WE/DO at cpuenable — the
// non-blocking capture gets the pre-update values (current state), so the TED
// cycle processes the correct address while the CPU advances to the next state.

module mos8501(
    input clk,
    input reset,
    input enable,
    input irq_n,
    input [7:0] data_in,
    output wire [7:0] data_out,
    output [15:0] address,
    input gate_in,
    output rw,
    input [7:0] port_in,
    output [7:0] port_out,
    input rdy,
    input aec
);

wire [15:0] core_address;
wire [7:0] core_data_out;
wire core_we;

// Arlet verilog-6502 core
cpu cpu_core(
    .clk(clk),
    .reset(reset),
    .AB(core_address),
    .DI(core_data_in),
    .DO(core_data_out),
    .WE(core_we),
    .IRQ(~irq_n),
    .NMI(1'b0),
    .RDY(enable)
);

// Pipeline registers: latch CPU outputs at cpuenable.
// Non-blocking RHS evaluates with pre-update state, so these capture
// the CURRENT state's address/WE/DO before the state machine advances.
reg [15:0] pipe_addr;
reg        pipe_we;
reg [7:0]  pipe_do;

always @(posedge clk)
    if (reset) begin
        pipe_addr <= 16'hffff;
        pipe_we   <= 0;
        pipe_do   <= 0;
    end else if (enable) begin
        pipe_addr <= core_address;
        pipe_we   <= core_we;
        pipe_do   <= core_data_out;
    end

// External address uses piped value (one cpuenable cycle behind CPU)
assign address = (aec) ? pipe_addr : 16'hffff;

// Port access detection: piped address for external bus, live for CPU reads
wire pipe_port_access = (pipe_addr[15:1] == 0);
wire live_port_access = (core_address[15:1] == 0);

// Data output register (active when mux is low and writing)
reg [7:0] data_out_reg;
reg rw_reg, aec_reg;

always @(posedge clk)
    if (gate_in) begin
        if (pipe_port_access && pipe_we)
            data_out_reg <= pipe_addr[0] ? 8'h01 : 8'h00;
        else
            data_out_reg <= pipe_do;
    end

always @(posedge clk)
    if (gate_in)
        rw_reg <= ~pipe_we;

always @(posedge clk)
    aec_reg <= aec;

assign rw = (~aec_reg) ? 1'b1 : rw_reg;
assign data_out = (~aec_reg | gate_in | rw) ? 8'hff : data_out_reg;

// I/O port registers — use live CPU signals (internal, not through TED bus)
reg [7:0] port_dir = 8'b0;
reg [7:0] port_data = 8'b0;

always @(posedge clk)
    if (reset) begin
        port_dir <= 0;
        port_data <= 0;
    end else if (enable)
        if (live_port_access & core_we)
            if (core_address[0] == 0)
                port_dir <= core_data_out;
            else
                port_data <= core_data_out;

// Port I/O mux
wire [7:0] port_io;
genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : port_mux
        assign port_io[gi] = port_dir[gi] ? port_data[gi] : port_in[gi];
    end
endgenerate

assign port_out = port_data;

// CPU data input: port registers or external bus.
// data_in_reg updates every clock so it's fresh at cpuenable.
// Port read detection uses pipe_addr (registered) to avoid a combinational
// loop through AB → port_access → DI → DIMUX → AB in JMP1 state.
reg [7:0] data_in_reg;
always @(posedge clk)
    data_in_reg <= data_in;

wire pipe_port_rd = (pipe_addr[15:1] == 0) & ~pipe_we;

reg [7:0] core_data_in;
always @*
    if (pipe_port_rd)
        core_data_in = pipe_addr[0] ? port_io : port_dir;
    else
        core_data_in = data_in_reg;

endmodule
