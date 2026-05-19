`include "./risc2.vh"

/* cpu_risc2p2 — 2-stage pipelined variant of cpu_risc2
 *
 * Designed for direct-BRAM memory (no icache).  The SoC wires the
 * instruction port straight to ROM BRAMs and drives clk_en=1, instr_valid=1.
 * This means: every cycle, instr_value at cycle K = mem[instr_addr at cycle K-1]
 * (BRAM sync-read latency = 1 cycle), and there are no stalls from cache
 * busy signals.
 *
 * Pipeline:
 *   IF : instr_addr <= pc (registered).  Each posedge presents a new pc.
 *   EX : decode + reg read + ALU + branch + reg write + flag write in one
 *        cycle, using the instr that was fetched 1 cycle ago.
 *
 * Both stages overlap every cycle → CPI = 1 for ALU/STORE.
 * Taken branch costs 2 bubble cycles (squash + icache refill latency).
 * LOAD stalls until data_in_valid (1 cycle for BRAM-range data).
 *
 * Binary compatible with cpu_risc2 — same encoding, flag semantics, IMM-prefix
 * rule, R7-arith flag-neutral rule, CALL link, IRET restore.
 */
module cpu_risc2p2 (
  input clk,
  input clk_en,            // assumed 1 by the SoC for pipelined CPUs
  input rst,

  output reg [23:0] instr_addr,
  input [31:0] instr_value,
  input instr_valid,       // assumed 1 by the SoC for pipelined CPUs

  output reg [23:0] data_addr,
  input [31:0] data_in_value,
  input data_in_valid,
  output reg data_rd,
  output reg [31:0] data_out_value,
  output reg [3:0] data_out_strobe,
  output reg data_wr,
  input data_out_rdy,

  input irq,
  input [2:0] irq_num,
  output reg irq_ack,

  output [127:0] cpuDbg
);

  // ────────────────────────────────────────────────────────────────────────
  // Architectural state
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] cpu_registers[0:15];
  reg c_flag, z_flag, n_flag, v_flag;
  reg [11:0] imm_upper;

  // IRQ shadow regs
  reg c_flag_irq, z_flag_irq;
  reg [11:0] imm_upper_irq;
  reg [23:0] iret_addr;
  reg irq_pending;
  reg [2:0] irq_num_pending;

  // ────────────────────────────────────────────────────────────────────────
  // Pipeline state
  // ────────────────────────────────────────────────────────────────────────
  reg [23:0] pc;             // PC of NEXT instr we will fetch (= instr_addr next cycle)
  reg [23:0] ir_pc_pending;  // PC of the instr the icache is responding for THIS cycle
  reg [31:0] ir;             // instruction in EX
  reg [23:0] ir_pc;          // PC of ir
  reg ir_valid;              // 1 = ir holds a real instruction; 0 = bubble
  reg [1:0] squash_count;    // bubble count after branch (2 cycles)
  reg boot_settle;           // 1 for first cycle after reset (BRAM dout garbage)

  // LOAD wait state
  reg load_pending;
  reg load_started;             // 1 after first cycle of load_pending; gives the SoC
                                // a cycle to register data_in_valid in response to data_rd.
                                // Without this, we'd sample the stale (pre-request) data_in_valid=1
                                // on the very first load_pending cycle and capture garbage.
  reg [3:0] load_rd;
  reg [1:0] load_size;
  reg [23:0] load_addr_saved;

  // ────────────────────────────────────────────────────────────────────────
  // Decode (combinational on ir)
  // ────────────────────────────────────────────────────────────────────────
  wire [4:0]  op       = ir[31:27];
  wire        imm_mode = ir[26];
  wire [1:0]  size     = ir[25:24];
  wire [3:0]  rd       = ir[23:20];
  wire [3:0]  rsb_idx  = ir[19:16];
  wire [15:0] disp16   = ir[15:0];
  wire [19:0] imm20    = ir[19:0];

  wire op_is_load  = (op == `INSTR_LOAD);
  wire op_is_store = (op == `INSTR_STORE);
  wire op_is_jmp   = (op == `INSTR_JMP);
  wire op_is_imm   = (op == `INSTR_IMM);
  wire op_is_mov   = (op == `INSTR_MOV);
  wire op_is_cmp   = (op == `INSTR_CMP);
  wire op_is_arith = (op >= 5'h8 && op <= 5'hE);

  wire writes_reg_alu = op_is_mov || op_is_arith;
  wire writes_flags   = op_is_cmp || (op_is_arith && rd != 4'h7);

  wire [31:0] opa_val = cpu_registers[rd];
  wire [31:0] opb_val = imm_mode ? {imm_upper, imm20}
                                  : cpu_registers[rsb_idx];

  wire [32:0] alu_out;
  alu_risc2 alu0(opa_val, opb_val, op, c_flag, alu_out);

  wire [23:0] load_addr =
       imm_mode ? {imm_upper[3:0], imm20}
                : cpu_registers[rsb_idx][23:0] + {8'h0, disp16};
  wire [23:0] store_addr = opb_val[23:0];

  // ────────────────────────────────────────────────────────────────────────
  // Branch resolution
  // ────────────────────────────────────────────────────────────────────────
  wire [23:0] pc_plus4    = ir_pc + 24'd4;
  wire [23:0] pc_branch   = ir_pc + ir[23:0];
  wire [23:0] pc_jge_jlt  = ir_pc + {{2{ir[21]}}, ir[21:0]};

  reg        branch_taken;
  reg [23:0] branch_target;
  always @* begin
    branch_taken  = 1'b0;
    branch_target = pc_plus4;
    if (op_is_jmp) begin
      if (ir[26:24] == 3'h5 && ir[23]) begin
        if (ir[22] == (n_flag != v_flag)) begin
          branch_taken  = 1'b1;
          branch_target = pc_jge_jlt;
        end
      end
      else if (ir[26:24] == 3'h5) begin
        branch_taken  = 1'b1;
        branch_target = iret_addr;
      end
      else if ((ir[26:25] == 2'h0 && ir[24] == z_flag) ||
               (ir[26:25] == 2'h1 && ir[24] == c_flag) ||
               (ir[26:25] == 2'h2)) begin
        branch_taken  = 1'b1;
        branch_target = pc_branch;
      end
      else if (ir[26:24] == 3'h7) begin
        branch_taken  = 1'b1;
        branch_target = pc_branch;
      end
      else if (ir[26:24] == 3'h6) begin
        branch_taken  = 1'b1;
        branch_target = cpu_registers[4'hf][23:0];
      end
    end
  end

  wire is_call = op_is_jmp && (ir[26:24] == 3'h7);
  wire is_iret = op_is_jmp && (ir[26:24] == 3'h5) && !ir[23];

  // ────────────────────────────────────────────────────────────────────────
  // STORE / LOAD data path
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] store_data;
  reg [3:0]  store_strobe;
  always @* begin
    case (size)
      2'b00: begin store_data = opa_val; store_strobe = 4'b1111; end
      2'b01: begin
        case (store_addr[1:0])
          2'b00: begin store_data = {opa_val[7:0], 24'b0};        store_strobe = 4'b1000; end
          2'b01: begin store_data = {8'b0, opa_val[7:0], 16'b0};  store_strobe = 4'b0100; end
          2'b10: begin store_data = {16'b0, opa_val[7:0], 8'b0};  store_strobe = 4'b0010; end
          2'b11: begin store_data = {24'b0, opa_val[7:0]};        store_strobe = 4'b0001; end
        endcase
      end
      2'b10: begin
        if (store_addr[1])
          begin store_data = {16'b0, opa_val[15:0]}; store_strobe = 4'b0011; end
        else
          begin store_data = {opa_val[15:0], 16'b0}; store_strobe = 4'b1100; end
      end
      default: begin store_data = opa_val; store_strobe = 4'b1111; end
    endcase
  end

  reg [31:0] load_writeback;
  always @* begin
    case (load_size)
      2'b00: load_writeback = data_in_value;
      2'b10: load_writeback = {16'b0, load_addr_saved[1] ? data_in_value[15:0]
                                                          : data_in_value[31:16]};
      2'b01: load_writeback = {24'b0,
                                load_addr_saved[1:0] == 2'b11 ? data_in_value[7:0]   :
                                load_addr_saved[1:0] == 2'b10 ? data_in_value[15:8]  :
                                load_addr_saved[1:0] == 2'b01 ? data_in_value[23:16] :
                                                                data_in_value[31:24]};
      default: load_writeback = data_in_value;
    endcase
  end

  // ────────────────────────────────────────────────────────────────────────
  // Debug bus
  // ────────────────────────────────────────────────────────────────────────
  assign cpuDbg = {instr_addr[15:0], ir[31:0],
                   data_addr[7:0], data_in_value[7:0], data_out_value[7:0],
                   7'b0, data_rd, 7'b0, data_wr,
                   8'b0, cpu_registers[0]};

  // ────────────────────────────────────────────────────────────────────────
  // Pipeline control wires
  // ────────────────────────────────────────────────────────────────────────
  wire ex_branch     = ir_valid && branch_taken;
  wire ex_load_start = ir_valid && op_is_load;

  // ────────────────────────────────────────────────────────────────────────
  // Sequential
  // ────────────────────────────────────────────────────────────────────────
  task reset_registers;
    integer i;
    begin for (i = 0; i < 16; i = i + 1) cpu_registers[i] = 32'b0; end
  endtask

  // Both `pc` and `ir_pc_pending` track the fetch pipeline:
  //   - At cycle K, instr_addr = pc(K).  The icache fetches mem[pc(K)].
  //   - At cycle K+1, instr_value = mem[pc(K)].  We latch into ir.  ir_pc = pc(K).
  //   - ir_pc_pending is the PC of the instr the icache is currently producing
  //     (= pc value from 1 cycle ago).
  always @* instr_addr = pc;

  always @(posedge clk or negedge rst) begin
    if (!rst) begin
      pc                <= 24'h000000;
      ir_pc_pending     <= 24'h000000;
      ir                <= 32'b0;
      ir_pc             <= 24'b0;
      ir_valid          <= 1'b0;
      squash_count      <= 2'd0;
      boot_settle       <= 1'b1;        // 1 cycle to let BRAM dout settle
      imm_upper         <= 12'b0;
      {c_flag, z_flag, n_flag, v_flag} <= 4'b0;
      {c_flag_irq, z_flag_irq, imm_upper_irq, iret_addr} <= 0;
      irq_pending       <= 1'b0;
      irq_num_pending   <= 3'b0;
      irq_ack           <= 1'b0;
      data_addr         <= 24'b0;
      data_rd           <= 1'b0;
      data_wr           <= 1'b0;
      data_out_value    <= 32'b0;
      data_out_strobe   <= 4'b0;
      load_pending      <= 1'b0;
      load_started      <= 1'b0;
      load_rd           <= 4'b0;
      load_size         <= 2'b0;
      load_addr_saved   <= 24'b0;
      reset_registers;
    end else begin
      data_wr <= 1'b0;
      irq_ack <= 1'b0;

      if (irq)
        {irq_pending, irq_num_pending} <= {1'b1, irq_num};

      // ── IF: advance pc; track in-flight pc ──
      // ir_pc_pending tracks the address the icache is responding for THIS
      // cycle = pc value from previous cycle.
      ir_pc_pending <= pc;

      // ── EX stage ──
      if (load_pending) begin
        // Stall the front-end too: pc must not advance during LOAD wait
        // because the icache is still preparing the post-LOAD instr response.
        data_rd <= 1'b0;
        // The SoC drives data_in_valid LOW one cycle after seeing data_rd=1
        // (for BRAM/ROM/PSRAM ranges).  On the FIRST cycle of load_pending
        // the SoC hasn't reacted yet, so data_in_valid is still the stale
        // pre-request value (=1).  Skip that cycle by gating on load_started.
        if (!load_started) begin
          load_started <= 1'b1;
        end else if (data_in_valid) begin
          cpu_registers[load_rd] <= load_writeback;
          load_pending <= 1'b0;
          load_started <= 1'b0;
          // After the rollback at ex_load_start, pc has been held at L+4
          // throughout the LOAD wait, so the icache's dout_b is stable on
          // mem[L+4].  We need 1 squash cycle to advance pc from L+4 to L+8
          // BEFORE the normal latch fires, so that the icache sees the new
          // address one cycle later and we can latch mem[L+4] then mem[L+8]
          // back-to-back without duplicating.
          squash_count <= 2'd1;
        end
      end else if (ir_valid) begin
        // ── reg/flag writes ──
        if (writes_reg_alu)
          cpu_registers[rd] <= alu_out[31:0];

        if (op_is_cmp) begin
          {c_flag, z_flag} <= {alu_out[32], alu_out[31:0] == 32'h0};
          n_flag <= alu_out[31];
          v_flag <= (opa_val[31] ^ opb_val[31]) & (opa_val[31] ^ alu_out[31]);
        end else if (writes_flags) begin
          c_flag <= alu_out[32];
          z_flag <= (alu_out[31:0] == 32'h0);
          n_flag <= alu_out[31];
          if (op == `INSTR_SUB)
            v_flag <= (opa_val[31] ^ opb_val[31]) & (opa_val[31] ^ alu_out[31]);
          else if (op == `INSTR_ADD)
            v_flag <= ~(opa_val[31] ^ opb_val[31]) & (opa_val[31] ^ alu_out[31]);
          else
            v_flag <= 1'b0;
        end

        imm_upper <= op_is_imm ? ir[11:0] : 12'b0;

        if (op_is_load) begin
          data_rd         <= 1'b1;
          data_addr       <= load_addr;
          load_pending    <= 1'b1;
          load_started    <= 1'b0;        // wait one cycle for the SoC's data_in_valid to settle
          load_rd         <= rd;
          load_size       <= size;
          load_addr_saved <= load_addr;
        end else if (op_is_store) begin
          data_wr         <= 1'b1;
          data_addr       <= store_addr;
          data_out_value  <= store_data;
          data_out_strobe <= store_strobe;
        end

        if (is_call)
          cpu_registers[4'hf] <= {8'b0, pc_plus4};

        if (is_iret) begin
          c_flag    <= c_flag_irq;
          z_flag    <= z_flag_irq;
          imm_upper <= imm_upper_irq;
          irq_ack   <= 1'b1;
        end
      end

      // ── IF: advance pc / latch / squash ──
      // load_pending check FIRST: during a LOAD wait, the captured post-LOAD
      // instr is sitting in `ir` (and may be a branch / LOAD itself), but we
      // must NOT act on it.  Holding everything until load_pending clears.
      if (boot_settle) begin
        boot_settle <= 1'b0;
        // pc holds at 0; ir_valid stays 0
      end else if (load_pending) begin
        // pc was rolled back to ir_pc+4 at LOAD's EX; the icache is settling
        // on mem[ir_pc+4] (= post-LOAD instr).  ir_valid is 0 (cleared at
        // LOAD's EX) so no spurious EX during the wait.
      end else if (ex_branch) begin
        pc           <= branch_target;
        squash_count <= 2'd1;          // 1 cycle to discard in-flight bubble
        ir_valid     <= 1'b0;
      end else if (ex_load_start) begin
        // Roll pc back to ir_pc + 4 (= post-LOAD instr address).  During the
        // load wait the icache will re-fetch starting from this address, so
        // when the load completes the post-LOAD instruction is freshly in
        // dout_b — no capture/duplicate problem.  This adds ~2 cycles per
        // LOAD vs a capture-based scheme but is robust against chained LOADs
        // where pc-holding would leave the icache stuck.
        pc       <= pc_plus4;            // = ir_pc + 4
        ir_valid <= 1'b0;
      end else if (squash_count != 0) begin
        squash_count <= squash_count - 1;
        ir_valid     <= 1'b0;
        pc           <= pc + 24'd4;    // keep fetch pipeline flowing
      end else begin
        // Normal: latch instr_value (= mem[ir_pc_pending]) and advance pc
        ir       <= instr_value;
        ir_pc    <= ir_pc_pending;
        ir_valid <= 1'b1;
        pc       <= pc + 24'd4;
      end

      // ── IRQ entry: only when pipeline naturally drained ──
      // Critical: a normal latch may have just fired in the IF block above,
      // setting ir_valid<=1.  We must override that with ir_valid<=0 so the
      // latched (but not-yet-executed) instruction is not run; save its addr
      // (= ir_pc_pending = what icache was about to deliver) as iret_addr so
      // IRET resumes at that exact instr.  squash_count=1 gives the icache
      // one cycle to re-fetch mem[0x04] before the next normal latch.
      if (irq_pending && !load_pending && !ir_valid && !ex_branch && squash_count == 0) begin
        c_flag_irq    <= c_flag;
        z_flag_irq    <= z_flag;
        imm_upper_irq <= imm_upper;
        imm_upper     <= 12'b0;
        iret_addr     <= ir_pc_pending;
        pc            <= {19'b0, irq_num_pending, 2'b0};
        irq_pending   <= 1'b0;
        squash_count  <= 2'd1;
        ir_valid      <= 1'b0;        // override the normal-latch's ir_valid<=1
      end
    end
  end

endmodule
