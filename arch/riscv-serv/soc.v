/* soc.v — minimal RISC-V SoC built around a swappable CPU + ROM BRAM + UART.
 *
 * Address map (24-bit):
 *   0x000000..0x007FFF : ROM (32 KB, executes the test program)
 *   0x008000..0x008003 : UART_TX (write byte to TX queue; reads return 0)
 *
 * This SoC is intentionally minimal — just enough to run a RISC-V hello-world
 * style test that pokes characters into a UART register and loops.  Bring up
 * a new RISC-V core by copying this folder, swapping cpu_darkrv for the new
 * CPU's adapter, and reusing the same rom.hex + sim_top harness.
 */
`default_nettype none

module soc (
    input             clk,
    input             rst,         // active-low

    // UART output (for the sim harness to capture)
    output reg [7:0]  uart_tx_data,
    output reg        uart_tx_pulse   // 1-cycle pulse when a byte is written
);

    // ── CPU bus ──────────────────────────────────────────────────────────
    wire [23:0] instr_addr;
    wire [31:0] instr_value;
    wire [23:0] data_addr;
    wire [31:0] data_in_value;
    wire        data_rd;
    wire [31:0] data_out_value;
    wire [3:0]  data_out_strobe;
    wire        data_wr;

    cpu_serv cpu0 (
        .clk(clk),
        .rst(rst),
        .instr_addr(instr_addr),
        .instr_value(instr_value),
        .data_addr(data_addr),
        .data_in_value(data_in_value),
        .data_rd(data_rd),
        .data_out_value(data_out_value),
        .data_out_strobe(data_out_strobe),
        .data_wr(data_wr)
    );

    // ── ROM (8K x 32-bit = 32 KB) ────────────────────────────────────────
    // Synchronous read: dout updates one cycle after addr is sampled.
    reg [31:0] rom_mem [0:8191];
    initial $readmemh("../rom.hex", rom_mem);

    reg [31:0] rom_idata;   // instruction-port read
    reg [31:0] rom_ddata;   // data-port read

    always @(posedge clk) begin
        rom_idata <= rom_mem[instr_addr[14:2]];
        rom_ddata <= rom_mem[data_addr[14:2]];
    end

    assign instr_value = rom_idata;

    // ── UART_TX register (write-only) ────────────────────────────────────
    wire uart_tx_sel = (data_addr[23:8] == 16'h0080) && (data_addr[7:2] == 6'b0);
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            uart_tx_data  <= 8'b0;
            uart_tx_pulse <= 1'b0;
        end else begin
            uart_tx_pulse <= 1'b0;
            if (data_wr && uart_tx_sel) begin
                // pick the byte indicated by the strobe (byte-store from DarkRISCV)
                case (data_out_strobe)
                    4'b0001: uart_tx_data <= data_out_value[7:0];
                    4'b0010: uart_tx_data <= data_out_value[15:8];
                    4'b0100: uart_tx_data <= data_out_value[23:16];
                    4'b1000: uart_tx_data <= data_out_value[31:24];
                    default: uart_tx_data <= data_out_value[7:0];
                endcase
                uart_tx_pulse <= 1'b1;
            end
        end
    end

    // ── Data-port read mux ───────────────────────────────────────────────
    // For this minimal SoC we only return ROM data on data reads; reads to
    // UART/MMIO return 0.  data_in_value is registered so DarkRISCV's pipeline
    // sees it the cycle after data_rd is asserted.
    reg [31:0] data_in_reg;
    always @(posedge clk) begin
        if (data_rd) begin
            if (data_addr[23:15] == 9'b0)  // ROM range
                data_in_reg <= rom_ddata;
            else
                data_in_reg <= 32'h0;
        end
    end
    assign data_in_value = data_in_reg;

endmodule

`default_nettype wire
