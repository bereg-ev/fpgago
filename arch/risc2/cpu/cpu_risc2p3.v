`include "./risc2.vh"

/* cpu_risc2p3 — 3-stage pipelined variant of cpu_risc2
 *
 * Designed for direct-BRAM memory (no icache).  The SoC wires the instruction
 * port straight to ROM BRAMs and drives clk_en=1, instr_valid=1.  Same memory
 * assumptions as cpu_risc2p2.
 *
 * Pipeline:
 *   IF  : present pc to ROM BRAM.  Data arrives next cycle.
 *   ID/EX: decode + reg read (with forwarding from EXMEM) + ALU + branch
 *          resolve + addr gen + store data prep + LOAD request.  Latch into
 *          EXMEM.
 *   MEM/WB: handle LOAD data capture, STORE pulse, reg writeback, flag write,
 *           CALL link reg, IRET restore.
 *
 * Stage timing (steady state, CPI = 1 for ALU/STORE):
 *   Cyc K:    IF presents pc.       icache fetching.       (instr arrives K+1)
 *   Cyc K+1:  ID/EX decodes/EXs.    EXMEM latched.
 *   Cyc K+2:  MEM/WB writes back.
 *
 * Hazards:
 *   • RAW reg dependency between back-to-back instructions:
 *     - ALU-ALU: forward EXMEM.alu_out to ID/EX inputs (next-cycle visibility
 *       of arch reg write happens via the same EXMEM latch).
 *     - LOAD result needed by following instr: data_in_valid is the gate.
 *       For BRAM-range loads (1-cycle wait) this introduces a 1-cycle stall
 *       between the LOAD and its consumer.
 *   • Flag dependency between CMP/arith and JCC: forward EXMEM.{c,z,n,v}.
 *   • Branch: resolved in ID/EX.  Squash IFID + 1 in-flight icache fetch
 *     (2 bubble cycles before EX of branch target).
 *
 * Binary compatible with cpu_risc2 — same encoding, flag semantics, IMM-prefix
 * rule, R7-arith flag-neutral rule, CALL link, IRET restore.
 */
module cpu_risc2p3 (
  input clk,
  input clk_en,
  input rst,

  output reg [23:0] instr_addr,
  input [31:0] instr_value,
  input instr_valid,

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

  // IRQ shadow (minimal — labyrinth doesn't use it but keep for ISA compat)
  reg c_flag_irq, z_flag_irq;
  reg [11:0] imm_upper_irq;
  reg [23:0] iret_addr;
  reg irq_pending;
  reg [2:0] irq_num_pending;

  // ────────────────────────────────────────────────────────────────────────
  // IF stage state
  // ────────────────────────────────────────────────────────────────────────
  reg [23:0] pc;
  reg [23:0] pc_in_flight;   // pc from previous cycle (= addr icache is responding for)
  reg        squash_count;   // 1 if next icache response should be discarded
  reg        boot_settle;    // 1 for first cycle out of reset

  // ────────────────────────────────────────────────────────────────────────
  // IFID latch (between IF and ID/EX)
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] ifid_instr;
  reg [23:0] ifid_pc;
  reg        ifid_valid;

  // ────────────────────────────────────────────────────────────────────────
  // EXMEM latch (between ID/EX and MEM/WB)
  // ────────────────────────────────────────────────────────────────────────
  reg [4:0]  exmem_op;
  reg [1:0]  exmem_size;
  reg [3:0]  exmem_rd;
  reg [31:0] exmem_alu;            // ALU result (also CALL link addr for is_call)
  reg [23:0] exmem_data_addr;
  reg [23:0] exmem_load_addr_saved; // saved load addr for byte/halfword lane select
  reg [31:0] exmem_store_data;
  reg [3:0]  exmem_store_strobe;
  reg        exmem_is_load;
  reg        exmem_is_store;
  reg        exmem_is_call;
  reg        exmem_is_iret;
  reg        exmem_writes_reg;
  reg        exmem_writes_flags;
  reg        exmem_c, exmem_z, exmem_n, exmem_v;
  reg [23:0] exmem_pc_plus4;
  reg        exmem_valid;
  // Set 0 when a LOAD is latched into EXMEM; flips to 1 on the FIRST cycle in
  // MEM/WB so the data_in_valid check skips the stale pre-update value.  The
  // SoC drives data_in_valid LOW one cycle after seeing data_rd=1; in p3 the
  // gap between ID/EX (asserting data_rd) and MEM/WB (checking data_in_valid)
  // is only 1 cycle, so the first MEM/WB cycle sees the pre-LOAD value (=1).
  reg        exmem_load_started;

  // ────────────────────────────────────────────────────────────────────────
  // ID/EX decode (combinational on ifid_instr)
  // ────────────────────────────────────────────────────────────────────────
  wire [4:0]  id_op       = ifid_instr[31:27];
  wire        id_imm_mode = ifid_instr[26];
  wire [1:0]  id_size     = ifid_instr[25:24];
  wire [3:0]  id_rd       = ifid_instr[23:20];
  wire [3:0]  id_rsb_idx  = ifid_instr[19:16];
  wire [15:0] id_disp16   = ifid_instr[15:0];
  wire [19:0] id_imm20    = ifid_instr[19:0];

  wire id_op_is_load  = (id_op == `INSTR_LOAD);
  wire id_op_is_store = (id_op == `INSTR_STORE);
  wire id_op_is_jmp   = (id_op == `INSTR_JMP);
  wire id_op_is_imm   = (id_op == `INSTR_IMM);
  wire id_op_is_mov   = (id_op == `INSTR_MOV);
  wire id_op_is_cmp   = (id_op == `INSTR_CMP);
  wire id_op_is_arith = (id_op >= 5'h8 && id_op <= 5'hE);

  wire id_writes_reg_alu = id_op_is_mov || id_op_is_arith;
  wire id_writes_flags   = id_op_is_cmp || (id_op_is_arith && id_rd != 4'h7);

  // ────────────────────────────────────────────────────────────────────────
  // Load-data extension (combinational on data_in_value + saved info from EXMEM)
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] load_writeback;
  always @* begin
    case (exmem_size)
      2'b00: load_writeback = data_in_value;
      2'b10: load_writeback = {16'b0, exmem_load_addr_saved[1] ? data_in_value[15:0]
                                                                 : data_in_value[31:16]};
      2'b01: load_writeback = {24'b0,
                                exmem_load_addr_saved[1:0] == 2'b11 ? data_in_value[7:0]   :
                                exmem_load_addr_saved[1:0] == 2'b10 ? data_in_value[15:8]  :
                                exmem_load_addr_saved[1:0] == 2'b01 ? data_in_value[23:16] :
                                                                       data_in_value[31:24]};
      default: load_writeback = data_in_value;
    endcase
  end

  // ────────────────────────────────────────────────────────────────────────
  // Forwarding from EXMEM to ID/EX inputs
  // ────────────────────────────────────────────────────────────────────────
  // Source operands as the encoded instr expects them.  Note opa uses rd field
  // ([23:20]) per the cpu_risc2 ISA — that's the "regA" source AND the destination.
  wire load_data_ready      = exmem_load_started && data_in_valid;
  wire opa_match_exmem_alu  = exmem_valid && exmem_writes_reg && !exmem_is_load
                              && (exmem_rd == id_rd);
  wire opb_match_exmem_alu  = exmem_valid && exmem_writes_reg && !exmem_is_load
                              && (exmem_rd == id_rsb_idx);
  wire opa_match_exmem_load = exmem_valid && exmem_is_load && load_data_ready
                              && (exmem_rd == id_rd);
  wire opb_match_exmem_load = exmem_valid && exmem_is_load && load_data_ready
                              && (exmem_rd == id_rsb_idx);

  wire [31:0] reg_rd_val = cpu_registers[id_rd];
  wire [31:0] reg_rsb_val= cpu_registers[id_rsb_idx];

  wire [31:0] opa_fwd  = opa_match_exmem_alu  ? exmem_alu
                       : opa_match_exmem_load ? load_writeback
                       :                        reg_rd_val;

  wire [31:0] opb_reg  = opb_match_exmem_alu  ? exmem_alu
                       : opb_match_exmem_load ? load_writeback
                       :                        reg_rsb_val;

  wire [31:0] id_opa_val = opa_fwd;
  wire [31:0] id_opb_val = id_imm_mode ? {imm_upper, id_imm20} : opb_reg;

  // Flag forwarding: if EXMEM is writing flags this cycle (about to commit at
  // end of cycle), use EXMEM's flags; otherwise the arch flags.
  wire fwd_flags  = exmem_valid && exmem_writes_flags;
  wire c_eff = fwd_flags ? exmem_c : c_flag;
  wire z_eff = fwd_flags ? exmem_z : z_flag;
  wire n_eff = fwd_flags ? exmem_n : n_flag;
  wire v_eff = fwd_flags ? exmem_v : v_flag;

  // ────────────────────────────────────────────────────────────────────────
  // ID/EX ALU
  // ────────────────────────────────────────────────────────────────────────
  wire [32:0] id_alu_out;
  alu_risc2 alu0(id_opa_val, id_opb_val, id_op, c_eff, id_alu_out);

  // Load / store addresses
  wire [23:0] id_load_addr =
       id_imm_mode ? {imm_upper[3:0], id_imm20}
                   : opb_reg[23:0] + {8'h0, id_disp16};
  wire [23:0] id_store_addr = id_opb_val[23:0];

  // STORE data lane routing
  reg [31:0] id_store_data;
  reg [3:0]  id_store_strobe;
  always @* begin
    case (id_size)
      2'b00: begin id_store_data = id_opa_val; id_store_strobe = 4'b1111; end
      2'b01: begin
        case (id_store_addr[1:0])
          2'b00: begin id_store_data = {id_opa_val[7:0], 24'b0};        id_store_strobe = 4'b1000; end
          2'b01: begin id_store_data = {8'b0, id_opa_val[7:0], 16'b0};  id_store_strobe = 4'b0100; end
          2'b10: begin id_store_data = {16'b0, id_opa_val[7:0], 8'b0};  id_store_strobe = 4'b0010; end
          2'b11: begin id_store_data = {24'b0, id_opa_val[7:0]};        id_store_strobe = 4'b0001; end
        endcase
      end
      2'b10: begin
        if (id_store_addr[1])
          begin id_store_data = {16'b0, id_opa_val[15:0]}; id_store_strobe = 4'b0011; end
        else
          begin id_store_data = {id_opa_val[15:0], 16'b0}; id_store_strobe = 4'b1100; end
      end
      default: begin id_store_data = id_opa_val; id_store_strobe = 4'b1111; end
    endcase
  end

  // ────────────────────────────────────────────────────────────────────────
  // Branch resolution in ID/EX (uses forwarded flags and RET-reads-R15)
  // ────────────────────────────────────────────────────────────────────────
  wire [23:0] id_pc_plus4   = ifid_pc + 24'd4;
  wire [23:0] id_pc_branch  = ifid_pc + ifid_instr[23:0];
  wire [23:0] id_pc_jge_jlt = ifid_pc + {{2{ifid_instr[21]}}, ifid_instr[21:0]};

  reg        id_branch_taken;
  reg [23:0] id_branch_target;
  always @* begin
    id_branch_taken  = 1'b0;
    id_branch_target = id_pc_plus4;
    if (id_op_is_jmp) begin
      if (ifid_instr[26:24] == 3'h5 && ifid_instr[23]) begin
        if (ifid_instr[22] == (n_eff != v_eff)) begin
          id_branch_taken  = 1'b1;
          id_branch_target = id_pc_jge_jlt;
        end
      end
      else if (ifid_instr[26:24] == 3'h5) begin
        id_branch_taken  = 1'b1;
        id_branch_target = iret_addr;
      end
      else if ((ifid_instr[26:25] == 2'h0 && ifid_instr[24] == z_eff) ||
               (ifid_instr[26:25] == 2'h1 && ifid_instr[24] == c_eff) ||
               (ifid_instr[26:25] == 2'h2)) begin
        id_branch_taken  = 1'b1;
        id_branch_target = id_pc_branch;
      end
      else if (ifid_instr[26:24] == 3'h7) begin
        id_branch_taken  = 1'b1;
        id_branch_target = id_pc_branch;
      end
      else if (ifid_instr[26:24] == 3'h6) begin
        // RET — read R15.  Forward if needed.
        id_branch_taken  = 1'b1;
        id_branch_target = (exmem_valid && exmem_writes_reg && !exmem_is_load &&
                            exmem_rd == 4'hf) ? exmem_alu[23:0]
                         : (exmem_valid && exmem_is_load && load_data_ready &&
                            exmem_rd == 4'hf) ? load_writeback[23:0]
                         : cpu_registers[4'hf][23:0];
      end
    end
  end

  wire id_is_call = id_op_is_jmp && (ifid_instr[26:24] == 3'h7);
  wire id_is_iret = id_op_is_jmp && (ifid_instr[26:24] == 3'h5) && !ifid_instr[23];

  // Flag computation for EXMEM latch
  reg [3:0] id_flags_new;  // {c,z,n,v}
  always @* begin
    if (id_op_is_cmp) begin
      id_flags_new = {id_alu_out[32], id_alu_out[31:0] == 32'h0, id_alu_out[31],
                      (id_opa_val[31] ^ id_opb_val[31]) & (id_opa_val[31] ^ id_alu_out[31])};
    end else if (id_op_is_arith) begin
      id_flags_new = {id_alu_out[32], id_alu_out[31:0] == 32'h0, id_alu_out[31],
                      (id_op == `INSTR_SUB) ? ((id_opa_val[31] ^ id_opb_val[31]) & (id_opa_val[31] ^ id_alu_out[31]))
                    : (id_op == `INSTR_ADD) ? (~(id_opa_val[31] ^ id_opb_val[31]) & (id_opa_val[31] ^ id_alu_out[31]))
                    :                         1'b0};
    end else begin
      id_flags_new = {c_flag, z_flag, n_flag, v_flag};  // don't care; not committed
    end
  end

  // ────────────────────────────────────────────────────────────────────────
  // Load-use stall detection
  //
  // If EXMEM is a LOAD whose result isn't ready yet (data_in_valid=0) AND the
  // instr now in ID/EX reads that reg, we must stall ID/EX for 1 cycle so the
  // load can complete and forward its data.
  // ────────────────────────────────────────────────────────────────────────
  wire id_uses_rsa_for_alu  = id_op_is_mov || id_op_is_arith || id_op_is_cmp || id_op_is_store;
  wire id_uses_rsb_for_alu  = (!id_imm_mode) && (id_op_is_mov || id_op_is_arith || id_op_is_cmp
                                                  || id_op_is_load || id_op_is_store);
  wire id_uses_r15_for_ret  = id_op_is_jmp && (ifid_instr[26:24] == 3'h6);

  wire load_use_hazard = exmem_valid && exmem_is_load && !load_data_ready &&
                         ifid_valid && (
                           (id_uses_rsa_for_alu && exmem_rd == id_rd) ||
                           (id_uses_rsb_for_alu && exmem_rd == id_rsb_idx) ||
                           (id_uses_r15_for_ret && exmem_rd == 4'hf)
                         );

  // Pipeline stall: when MEM/WB is still waiting on LOAD data, the whole
  // pipeline must hold.
  wire mem_stall = exmem_valid && exmem_is_load && !load_data_ready;

  // STORE-LOAD structural hazard: ID/EX's LOAD sets data_addr<=id_load_addr,
  // and MEM/WB's STORE sets data_addr<=exmem_data_addr.  Both at same edge,
  // and ID/EX comes LATER in the always block so its assignment wins —
  // meaning the STORE writes to the LOAD's address instead of its own.
  // Stall ID/EX by 1 cycle when an STORE in EXMEM is about to fire MEM/WB
  // and ID/EX has a LOAD/STORE that wants data_addr.
  wire store_memop_conflict = exmem_valid && exmem_is_store && ifid_valid &&
                              (id_op_is_load || id_op_is_store);

  // ────────────────────────────────────────────────────────────────────────
  // Debug bus
  // ────────────────────────────────────────────────────────────────────────
  assign cpuDbg = {instr_addr[15:0], ifid_instr[31:0],
                   data_addr[7:0], data_in_value[7:0], data_out_value[7:0],
                   7'b0, data_rd, 7'b0, data_wr,
                   8'b0, cpu_registers[0]};

  // Aliases for sim probes
  wire [31:0] ir       = ifid_instr;
  wire [23:0] ir_pc    = ifid_pc;
  wire        ir_valid = ifid_valid;

  // ────────────────────────────────────────────────────────────────────────
  // Sequential
  // ────────────────────────────────────────────────────────────────────────
  task reset_registers;
    integer i;
    begin for (i = 0; i < 16; i = i + 1) cpu_registers[i] = 32'b0; end
  endtask

  always @* instr_addr = pc;

  always @(posedge clk or negedge rst) begin
    if (!rst) begin
      pc                <= 24'h000000;
      pc_in_flight      <= 24'h000000;
      ifid_instr        <= 32'b0;
      ifid_pc           <= 24'b0;
      ifid_valid        <= 1'b0;
      squash_count      <= 1'b0;
      boot_settle       <= 1'b1;
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
      // EXMEM
      exmem_op          <= 5'b0;
      exmem_size        <= 2'b0;
      exmem_rd          <= 4'b0;
      exmem_alu         <= 32'b0;
      exmem_data_addr   <= 24'b0;
      exmem_load_addr_saved <= 24'b0;
      exmem_store_data  <= 32'b0;
      exmem_store_strobe<= 4'b0;
      exmem_is_load     <= 1'b0;
      exmem_is_store    <= 1'b0;
      exmem_is_call     <= 1'b0;
      exmem_is_iret     <= 1'b0;
      exmem_writes_reg  <= 1'b0;
      exmem_writes_flags<= 1'b0;
      {exmem_c, exmem_z, exmem_n, exmem_v} <= 4'b0;
      exmem_pc_plus4    <= 24'b0;
      exmem_valid       <= 1'b0;
      exmem_load_started<= 1'b0;
      reset_registers;
    end else begin
      data_wr <= 1'b0;
      data_rd <= 1'b0;
      irq_ack <= 1'b0;
      pc_in_flight <= pc;

      if (irq)
        {irq_pending, irq_num_pending} <= {1'b1, irq_num};

      if (clk_en) begin
        // ── MEM/WB stage ──────────────────────────────────────────────────
        if (exmem_valid) begin
          if (exmem_is_load) begin
            if (!exmem_load_started) begin
              // First MEM/WB cycle for this LOAD — data_in_valid is still the
              // stale pre-LOAD value (=1).  Skip this cycle.
              exmem_load_started <= 1'b1;
            end else if (data_in_valid) begin
              cpu_registers[exmem_rd] <= load_writeback;
              `ifdef DEBUG_WB
              $display("[t=%0t WB-LOAD pc=%h] r%0d <= %h (load_writeback)",
                       $time, exmem_pc_plus4 - 4, exmem_rd, load_writeback);
              `endif
              exmem_valid        <= 1'b0;       // consumed
              exmem_load_started <= 1'b0;       // ready for next LOAD
              // 1-cycle squash AFTER the post-LOAD instr is latched.
              // Sequence after the IF-stage rollback to ifid_pc+4:
              //   cycle K   : LOAD writeback fires here; IF latches mem[L+4]
              //               (post-LOAD instr) into IFID; pc advances to L+8.
              //   cycle K+1 : BRAM dout still shows mem[L+4] because at K's
              //               edge BRAM sampled pre-update pc = L+4.  If IF
              //               took the normal `else` branch here it would
              //               re-latch the same instr — duplicating it.  This
              //               squash makes IF take branch 4 instead, discard
              //               the stale BRAM output, and advance pc to L+c.
              //   cycle K+2 : BRAM dout = mem[L+8]; IF latches normally.
              squash_count <= 1'b1;
            end
            // else: hold; mem_stall keeps upstream frozen
          end else begin
            // Non-LOAD: commit at end of this cycle
            if (exmem_writes_reg) begin
              cpu_registers[exmem_rd] <= exmem_alu;
              `ifdef DEBUG_WB
              $display("[t=%0t WB-ALU  pc=%h] r%0d <= %h (alu)",
                       $time, exmem_pc_plus4 - 4, exmem_rd, exmem_alu);
              `endif
            end
            if (exmem_writes_flags) begin
              c_flag <= exmem_c;
              z_flag <= exmem_z;
              n_flag <= exmem_n;
              v_flag <= exmem_v;
            end
            if (exmem_is_call) begin
              cpu_registers[4'hf] <= {8'b0, exmem_pc_plus4};
              `ifdef DEBUG_WB
              $display("[t=%0t WB-CALL pc=%h] r15 <= %h",
                       $time, exmem_pc_plus4 - 4, {8'b0, exmem_pc_plus4});
              `endif
            end
            if (exmem_is_iret) begin
              c_flag    <= c_flag_irq;
              z_flag    <= z_flag_irq;
              imm_upper <= imm_upper_irq;
              irq_ack   <= 1'b1;
            end
            if (exmem_is_store) begin
              data_wr         <= 1'b1;
              data_addr       <= exmem_data_addr;
              data_out_value  <= exmem_store_data;
              data_out_strobe <= exmem_store_strobe;
            end
            exmem_valid <= 1'b0;
          end
        end

        // ── ID/EX stage → EXMEM latch ────────────────────────────────────
        if (mem_stall || load_use_hazard || store_memop_conflict) begin
          // Insert bubble into EXMEM next cycle (but only after MEM/WB
          // finishes its current work — handled above).  Hold IFID.
          if (!mem_stall) exmem_valid <= 1'b0;
          // (when mem_stall, exmem_valid stays true because LOAD still pending)
        end else if (ifid_valid) begin
          exmem_op           <= id_op;
          exmem_size         <= id_size;
          exmem_rd           <= id_rd;
          exmem_alu          <= id_alu_out[31:0];
          exmem_data_addr    <= id_op_is_load ? id_load_addr : id_store_addr;
          exmem_load_addr_saved <= id_load_addr;
          exmem_store_data   <= id_store_data;
          exmem_store_strobe <= id_store_strobe;
          exmem_is_load      <= id_op_is_load;
          exmem_is_store     <= id_op_is_store;
          exmem_is_call      <= id_is_call;
          exmem_is_iret      <= id_is_iret;
          exmem_writes_reg   <= id_writes_reg_alu;
          exmem_writes_flags <= id_writes_flags;
          {exmem_c, exmem_z, exmem_n, exmem_v} <= id_flags_new;
          exmem_pc_plus4     <= id_pc_plus4;
          exmem_valid        <= 1'b1;
          exmem_load_started <= 1'b0;     // reset; MEM/WB raises on first cycle

          // IMM-prefix latch for next ID/EX cycle
          imm_upper <= id_op_is_imm ? ifid_instr[11:0] : 12'b0;

          // LOAD: fire data_rd this cycle (becomes visible at end-of-cycle for icache)
          if (id_op_is_load) begin
            data_rd   <= 1'b1;
            data_addr <= id_load_addr;
          end

          // Branch redirect (resolved in ID/EX)
          if (id_branch_taken) begin
            pc           <= id_branch_target;
            squash_count <= 1'b1;
            ifid_valid   <= 1'b0;     // current IFID will be advanced past; squash IF next cycle
          end
        end else begin
          // No valid IFID — bubble into EXMEM
          exmem_valid <= 1'b0;
        end

        // ── IF stage ─────────────────────────────────────────────────────
        if (boot_settle) begin
          boot_settle <= 1'b0;
          // pc holds at 0; ifid_valid stays 0
        end else if (mem_stall || load_use_hazard || store_memop_conflict) begin
          // Hold IFID, hold pc
        end else if (ifid_valid && id_branch_taken) begin
          // Branch just took in ID/EX — squash next, redirect pc (already done above)
        end else if (ifid_valid && id_op_is_load) begin
          // LOAD is entering EX this cycle.  Roll pc BACK to ifid_pc+4 (the
          // post-LOAD instr address) so BRAM re-fetches mem[ifid_pc+4] during
          // the LOAD wait.  When the wait ends, BRAM dout is the post-LOAD
          // instr — fresh, not a cached duplicate — and the next IF cycle
          // latches it via the normal `else` path below.  Costs +1 cycle per
          // LOAD vs the cache approach but avoids the double-issue hazard
          // where the cached instr in IFID and the same instr still sitting
          // in BRAM dout both got committed.
          //
          // CRITICAL: this branch must be checked BEFORE the squash branch
          // below.  Back-to-back LOADs hit a state where LOAD2 is entering EX
          // AND squash_count=1 from LOAD1's WB.  If squash fires first, pc
          // advances by 4 (skipping past the post-LOAD2 instr in BRAM) and
          // the post-LOAD2 instr is lost forever — e.g., in hal_fill_rect's
          // LOAD,LOAD,ADD,RET epilogue, the `add r14,#c` would be silently
          // dropped, leaking SP by 12 bytes per call.  Rollback subsumes the
          // squash's intent (it clears ifid_valid and steers pc to the right
          // address), so we also clear squash_count here.
          pc           <= ifid_pc + 24'd4;
          ifid_valid   <= 1'b0;
          squash_count <= 1'b0;
        end else if (squash_count != 0) begin
          squash_count <= 1'b0;
          ifid_valid   <= 1'b0;
          pc           <= pc + 24'd4;     // keep fetch flowing past in-flight squash
        end else if (ifid_valid && id_op_is_store &&
                     (instr_value[31:27] == `INSTR_LOAD ||
                      instr_value[31:27] == `INSTR_STORE)) begin
          // PREDICTED store_memop_conflict for next cycle.  Current IFID is
          // a STORE entering EX, AND BRAM dout (the instr we'd latch into
          // IFID for next cycle) is also LOAD/STORE.  At the next cycle
          // EX=store, IFID=load/store → store_memop_conflict fires, stalling
          // ID/EX.  But the stall would have held pc at the advanced value,
          // meaning BRAM samples the next-next addr at the stall edge and
          // the post-store instr (currently in BRAM dout) is silently lost.
          //
          // Fix: latch IFID as usual BUT do NOT advance pc.  BRAM keeps
          // sampling the same addr during the stall, so the post-store
          // instr stays in BRAM dout.  After the stall, IF normally latches
          // the post-store instr.  Set squash_count=1 so the cycle right
          // after the stall ends (when IF would otherwise re-latch the same
          // stale BRAM output) takes the squash branch instead.
          ifid_instr   <= instr_value;
          ifid_pc      <= pc_in_flight;
          ifid_valid   <= 1'b1;
          squash_count <= 1'b1;
          // pc HOLDS — do not advance.
        end else begin
          // Normal IF: latch instr_value (= mem[pc_in_flight]) and advance pc
          ifid_instr <= instr_value;
          ifid_pc    <= pc_in_flight;
          ifid_valid <= 1'b1;
          pc         <= pc + 24'd4;
        end

        // ── IRQ entry: only when pipeline naturally drained ──────────────
        // Critical: the normal IF block above may have just latched a new
        // instr (ifid_valid<=1).  We override that here so the latched-but-
        // unexecuted instr is dropped, and save its addr (= pc_in_flight)
        // as iret_addr so IRET resumes exactly there.
        if (irq_pending && !exmem_valid && !ifid_valid && !id_branch_taken
            && squash_count == 0 && !mem_stall) begin
          c_flag_irq    <= c_flag;
          z_flag_irq    <= z_flag;
          imm_upper_irq <= imm_upper;
          imm_upper     <= 12'b0;
          iret_addr     <= pc_in_flight;
          pc            <= {19'b0, irq_num_pending, 2'b0};
          irq_pending   <= 1'b0;
          squash_count  <= 1'b1;
          ifid_valid    <= 1'b0;        // override normal IF latch's ifid_valid<=1
        end
      end
    end
  end

endmodule
