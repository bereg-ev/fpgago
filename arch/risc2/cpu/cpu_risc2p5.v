`include "./risc2.vh"

/* cpu_risc2p5 — 5-stage pipelined variant of cpu_risc2
 *
 * Designed for direct-BRAM memory (no icache).  Same SoC wiring as p2/p3:
 * clk_en=1, instr_valid=1, instr_value direct from ROM BRAM.
 *
 * Pipeline:
 *   IF  : present pc to ROM BRAM.  Data arrives next cycle.
 *   ID  : decode + reg read.  Captures opa/opb register values (forwarded
 *         later in EX as needed) and source register indices.  Latch IDEX.
 *   EX  : forwarding muxes (EXMEM, MEMWB → EX inputs) + ALU + branch resolve
 *         + addr gen + store data prep + LOAD request.  Latch EXMEM.
 *   MEM : capture LOAD data when data_in_valid; STORE pulse asserted via
 *         EXMEM.  Latch MEMWB with the value to write back.
 *   WB  : write register file, write flags, CALL link, IRET restore.
 *
 * Hazards:
 *   • RAW (reg): forward EXMEM.alu_out (for non-load 1-ahead) and MEMWB.value
 *     (for 2-ahead, including loads) to EX inputs.
 *   • RAW (flags): forward EXMEM.{c,z,n,v} and MEMWB.{c,z,n,v} to JCC's branch
 *     resolver in EX.
 *   • Load-use: detected at ID — if IDEX (= EX-stage instr) is LOAD and the
 *     instr in ID reads its rd, stall ID 1 cycle, bubble IDEX.
 *   • Memory wait: when EXMEM is LOAD and data_in_valid=0, stall the whole
 *     pipeline (MEM stage holds).
 *   • Branch (resolved in EX): squash IFID + IDEX (2 in-flight bubbles)
 *     and 1 cycle of icache lag — total 3 bubble cycles.
 *   • IMM-prefix: imm_upper updated at end of IMM's ID stage (not EX), so the
 *     next instr's ID sees it.  Gated on ID actually advancing (no stall).
 *
 * Binary compatible with cpu_risc2 — same encoding, flag semantics, IMM-prefix
 * rule, R7-arith flag-neutral rule, CALL link, IRET restore.
 */
module cpu_risc2p5 (
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

  // IRQ shadow regs
  reg c_flag_irq, z_flag_irq;
  reg [11:0] imm_upper_irq;
  reg [23:0] iret_addr;
  reg irq_pending;
  reg [2:0] irq_num_pending;

  // ────────────────────────────────────────────────────────────────────────
  // IF stage state
  // ────────────────────────────────────────────────────────────────────────
  reg [23:0] pc;
  reg [23:0] pc_in_flight;     // pc from previous cycle (= addr icache responds for)
  reg [1:0]  squash_count;     // 0..2 — # of in-flight responses to discard
  reg        boot_settle;

  // ────────────────────────────────────────────────────────────────────────
  // IFID latch (between IF and ID)
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] ifid_instr;
  reg [23:0] ifid_pc;
  reg        ifid_valid;

  // ────────────────────────────────────────────────────────────────────────
  // IDEX latch (between ID and EX) — values + source indices for forwarding
  // ────────────────────────────────────────────────────────────────────────
  reg [4:0]  idex_op;
  reg [1:0]  idex_size;
  reg [3:0]  idex_rd;
  reg [3:0]  idex_rsa_idx;     // = ir[23:20] (also the destination index)
  reg [3:0]  idex_rsb_idx;     // = ir[19:16]
  reg [31:0] idex_opa_val;     // captured at ID (forwarded later in EX)
  reg [31:0] idex_opb_val;     // captured at ID, either reg value or full immediate
  reg        idex_opb_is_imm;  // 1 = opb is immediate (no forwarding needed)
  reg [23:0] idex_pc;          // for branch target computation
  reg [23:0] idex_pc_plus4;    // for CALL link
  reg        idex_is_load, idex_is_store, idex_is_jmp, idex_is_imm,
             idex_is_mov, idex_is_cmp, idex_is_arith,
             idex_is_call, idex_is_iret;
  reg [2:0]  idex_jmp_sub;     // ifid_instr[26:24]
  reg        idex_jmp_bit23;
  reg        idex_jmp_bit22;
  reg [23:0] idex_disp24;      // ir[23:0]
  reg [21:0] idex_disp22;      // ir[21:0] (for JGE/JLT signed offset)
  reg [15:0] idex_disp16;      // ir[15:0] (for LOAD offset)
  reg [19:0] idex_imm20;       // ir[19:0]
  reg        idex_writes_reg, idex_writes_flags;
  reg        idex_valid;

  // ────────────────────────────────────────────────────────────────────────
  // EXMEM latch (between EX and MEM)
  // ────────────────────────────────────────────────────────────────────────
  reg [4:0]  exmem_op;
  reg [1:0]  exmem_size;
  reg [3:0]  exmem_rd;
  reg [31:0] exmem_alu;
  reg [23:0] exmem_data_addr;
  reg [23:0] exmem_load_addr_saved;
  reg [31:0] exmem_store_data;
  reg [3:0]  exmem_store_strobe;
  reg        exmem_is_load, exmem_is_store, exmem_is_call, exmem_is_iret;
  reg        exmem_writes_reg, exmem_writes_flags;
  reg        exmem_c, exmem_z, exmem_n, exmem_v;
  reg [23:0] exmem_pc_plus4;
  reg        exmem_valid;
  // 0 when LOAD just entered EXMEM (= MEM stage's first cycle for this LOAD),
  // flips to 1 after 1 stall cycle so data_in_valid check skips the stale
  // pre-update value (SoC takes 1 cycle to react to data_rd=1).
  reg        exmem_load_started;

  // ────────────────────────────────────────────────────────────────────────
  // MEMWB latch (between MEM and WB)
  // ────────────────────────────────────────────────────────────────────────
  reg [3:0]  memwb_rd;
  reg [31:0] memwb_value;       // alu_out for non-load, loaded_data for load
  reg        memwb_is_call, memwb_is_iret;
  reg        memwb_writes_reg, memwb_writes_flags;
  reg        memwb_c, memwb_z, memwb_n, memwb_v;
  reg [23:0] memwb_pc_plus4;
  reg        memwb_valid;

  // ────────────────────────────────────────────────────────────────────────
  // ID stage — decode IFID combinationally
  // ────────────────────────────────────────────────────────────────────────
  wire [4:0]  id_op       = ifid_instr[31:27];
  wire        id_imm_mode = ifid_instr[26];
  wire [1:0]  id_size     = ifid_instr[25:24];
  wire [3:0]  id_rd       = ifid_instr[23:20];
  wire [3:0]  id_rsb_idx  = ifid_instr[19:16];
  wire [15:0] id_disp16   = ifid_instr[15:0];
  wire [19:0] id_imm20    = ifid_instr[19:0];
  wire [21:0] id_disp22   = ifid_instr[21:0];
  wire [23:0] id_disp24   = ifid_instr[23:0];

  wire id_op_is_load  = (id_op == `INSTR_LOAD);
  wire id_op_is_store = (id_op == `INSTR_STORE);
  wire id_op_is_jmp   = (id_op == `INSTR_JMP);
  wire id_op_is_imm   = (id_op == `INSTR_IMM);
  wire id_op_is_mov   = (id_op == `INSTR_MOV);
  wire id_op_is_cmp   = (id_op == `INSTR_CMP);
  wire id_op_is_arith = (id_op >= 5'h8 && id_op <= 5'hE);
  wire id_is_call     = id_op_is_jmp && (ifid_instr[26:24] == 3'h7);
  wire id_is_iret     = id_op_is_jmp && (ifid_instr[26:24] == 3'h5) && !ifid_instr[23];
  wire id_is_ret      = id_op_is_jmp && (ifid_instr[26:24] == 3'h6);

  wire id_writes_reg_alu = id_op_is_mov || id_op_is_arith;
  wire id_writes_flags   = id_op_is_cmp || (id_op_is_arith && id_rd != 4'h7);

  // For RET we need to read R15 as the branch target.  RET's encoding has
  // id_rd=0 and imm_mode=1, so neither id_rd nor id_rsb_idx points to R15 by
  // default.  Override id_rsa_idx to 4'hf for RET so idex_opa_val gets R15
  // (with proper MEMWB forwarding), then EX uses ex_opa as branch_target.
  wire [3:0] id_rsa_for_decode = id_is_ret ? 4'hf : id_rd;
  wire [3:0] id_rsb_for_decode = id_is_ret ? 4'hf : id_rsb_idx;

  // Reg-file reads (combinational).  Forwarding from MEMWB happens here so
  // that an instr writing a reg in WB this cycle is visible to ID this cycle.
  // (This is the "write-then-read in the same cycle" forwarding for the 3-ahead
  // case where ID reads regs that WB is currently writing.)
  wire memwb_writes_rd_at_id_rsa = memwb_valid && memwb_writes_reg && (memwb_rd == id_rsa_for_decode);
  wire memwb_writes_rd_at_id_rsb = memwb_valid && memwb_writes_reg && (memwb_rd == id_rsb_for_decode);

  wire [31:0] id_reg_rsa = memwb_writes_rd_at_id_rsa ? memwb_value : cpu_registers[id_rsa_for_decode];
  wire [31:0] id_reg_rsb = memwb_writes_rd_at_id_rsb ? memwb_value : cpu_registers[id_rsb_for_decode];

  // opb for non-immediate operations = reg value; for immediate = {imm_upper, imm20}
  wire [31:0] id_opb_val_decoded = id_imm_mode ? {imm_upper, id_imm20} : id_reg_rsb;

  // ────────────────────────────────────────────────────────────────────────
  // EX stage — forwarding from EXMEM/MEMWB to EX inputs
  // ────────────────────────────────────────────────────────────────────────
  // 1-ahead forwarding: instr in MEM stage now (= EXMEM latch).  Forward its
  // alu result (non-load only — load data isn't available here).
  wire exmem_fwd_rsa = exmem_valid && exmem_writes_reg && !exmem_is_load
                       && (exmem_rd == idex_rsa_idx);
  wire exmem_fwd_rsb = exmem_valid && exmem_writes_reg && !exmem_is_load
                       && (exmem_rd == idex_rsb_idx);

  // 2-ahead forwarding: instr in WB stage now (= MEMWB latch).  Forward its
  // value (alu_out for non-load, loaded_data for load).
  wire memwb_fwd_rsa = memwb_valid && memwb_writes_reg
                       && (memwb_rd == idex_rsa_idx);
  wire memwb_fwd_rsb = memwb_valid && memwb_writes_reg
                       && (memwb_rd == idex_rsb_idx);

  wire [31:0] ex_opa = exmem_fwd_rsa ? exmem_alu
                     : memwb_fwd_rsa ? memwb_value
                     :                 idex_opa_val;

  wire [31:0] ex_opb_reg_fwd = exmem_fwd_rsb ? exmem_alu
                             : memwb_fwd_rsb ? memwb_value
                             :                 idex_opb_val;
  // If opb was decoded as an immediate, no forwarding — use the latched value.
  wire [31:0] ex_opb = idex_opb_is_imm ? idex_opb_val : ex_opb_reg_fwd;

  // Flag forwarding for branch resolution in EX.
  wire ex_fwd_flags_exmem = exmem_valid && exmem_writes_flags;
  wire ex_fwd_flags_memwb = memwb_valid && memwb_writes_flags;
  wire c_eff = ex_fwd_flags_exmem ? exmem_c
             : ex_fwd_flags_memwb ? memwb_c
             :                      c_flag;
  wire z_eff = ex_fwd_flags_exmem ? exmem_z
             : ex_fwd_flags_memwb ? memwb_z
             :                      z_flag;
  wire n_eff = ex_fwd_flags_exmem ? exmem_n
             : ex_fwd_flags_memwb ? memwb_n
             :                      n_flag;
  wire v_eff = ex_fwd_flags_exmem ? exmem_v
             : ex_fwd_flags_memwb ? memwb_v
             :                      v_flag;

  // ALU in EX
  wire [32:0] ex_alu_out;
  alu_risc2 alu0(ex_opa, ex_opb, idex_op, c_eff, ex_alu_out);

  // Addresses
  wire [23:0] ex_load_addr =
       idex_opb_is_imm ? {idex_opb_val[23:20], idex_opb_val[19:0]} // = imm[23:0]
                       : ex_opb_reg_fwd[23:0] + {8'h0, idex_disp16};
  // Note: for LOAD with imm mode, cpu_risc2 uses {imm_upper[3:0], instr[19:0]} = lower 24 of imm.
  // idex_opb_val for imm mode was set to {imm_upper, imm20} = the full 32-bit immediate.
  // So ex_load_addr in imm mode = idex_opb_val[23:0].

  wire [23:0] ex_store_addr = ex_opb[23:0];

  // STORE data routing
  reg [31:0] ex_store_data;
  reg [3:0]  ex_store_strobe;
  always @* begin
    case (idex_size)
      2'b00: begin ex_store_data = ex_opa; ex_store_strobe = 4'b1111; end
      2'b01: begin
        case (ex_store_addr[1:0])
          2'b00: begin ex_store_data = {ex_opa[7:0], 24'b0};        ex_store_strobe = 4'b1000; end
          2'b01: begin ex_store_data = {8'b0, ex_opa[7:0], 16'b0};  ex_store_strobe = 4'b0100; end
          2'b10: begin ex_store_data = {16'b0, ex_opa[7:0], 8'b0};  ex_store_strobe = 4'b0010; end
          2'b11: begin ex_store_data = {24'b0, ex_opa[7:0]};        ex_store_strobe = 4'b0001; end
        endcase
      end
      2'b10: begin
        if (ex_store_addr[1])
          begin ex_store_data = {16'b0, ex_opa[15:0]}; ex_store_strobe = 4'b0011; end
        else
          begin ex_store_data = {ex_opa[15:0], 16'b0}; ex_store_strobe = 4'b1100; end
      end
      default: begin ex_store_data = ex_opa; ex_store_strobe = 4'b1111; end
    endcase
  end

  // Branch resolution in EX
  wire [23:0] ex_pc_branch  = idex_pc + idex_disp24;
  wire [23:0] ex_pc_jge_jlt = idex_pc + {{2{idex_disp22[21]}}, idex_disp22};

  reg        ex_branch_taken;
  reg [23:0] ex_branch_target;
  always @* begin
    ex_branch_taken  = 1'b0;
    ex_branch_target = idex_pc_plus4;
    if (idex_is_jmp) begin
      if (idex_jmp_sub == 3'h5 && idex_jmp_bit23) begin
        if (idex_jmp_bit22 == (n_eff != v_eff)) begin
          ex_branch_taken  = 1'b1;
          ex_branch_target = ex_pc_jge_jlt;
        end
      end
      else if (idex_jmp_sub == 3'h5) begin
        ex_branch_taken  = 1'b1;
        ex_branch_target = iret_addr;
      end
      else if ((idex_jmp_sub[2:1] == 2'h0 && idex_jmp_sub[0] == z_eff) ||
               (idex_jmp_sub[2:1] == 2'h1 && idex_jmp_sub[0] == c_eff) ||
               (idex_jmp_sub == 3'h4)) begin
        ex_branch_taken  = 1'b1;
        ex_branch_target = ex_pc_branch;
      end
      else if (idex_jmp_sub == 3'h7) begin   // CALL
        ex_branch_taken  = 1'b1;
        ex_branch_target = ex_pc_branch;
      end
      else if (idex_jmp_sub == 3'h6) begin   // RET — opa was loaded with R15 in ID
        ex_branch_taken  = 1'b1;
        ex_branch_target = ex_opa[23:0];     // forwarded R15
      end
    end
  end

  // Flag computation in EX (for latching into EXMEM, written in WB)
  reg [3:0] ex_flags_new;  // {c, z, n, v}
  always @* begin
    if (idex_is_cmp) begin
      ex_flags_new = {ex_alu_out[32], ex_alu_out[31:0] == 32'h0, ex_alu_out[31],
                      (ex_opa[31] ^ ex_opb[31]) & (ex_opa[31] ^ ex_alu_out[31])};
    end else if (idex_is_arith) begin
      ex_flags_new = {ex_alu_out[32], ex_alu_out[31:0] == 32'h0, ex_alu_out[31],
                      (idex_op == `INSTR_SUB) ? ((ex_opa[31] ^ ex_opb[31]) & (ex_opa[31] ^ ex_alu_out[31]))
                    : (idex_op == `INSTR_ADD) ? (~(ex_opa[31] ^ ex_opb[31]) & (ex_opa[31] ^ ex_alu_out[31]))
                    :                           1'b0};
    end else begin
      ex_flags_new = {c_flag, z_flag, n_flag, v_flag};
    end
  end

  // ────────────────────────────────────────────────────────────────────────
  // MEM stage — load data extension
  // ────────────────────────────────────────────────────────────────────────
  reg [31:0] mem_load_writeback;
  always @* begin
    case (exmem_size)
      2'b00: mem_load_writeback = data_in_value;
      2'b10: mem_load_writeback = {16'b0, exmem_load_addr_saved[1] ? data_in_value[15:0]
                                                                    : data_in_value[31:16]};
      2'b01: mem_load_writeback = {24'b0,
                                    exmem_load_addr_saved[1:0] == 2'b11 ? data_in_value[7:0]   :
                                    exmem_load_addr_saved[1:0] == 2'b10 ? data_in_value[15:8]  :
                                    exmem_load_addr_saved[1:0] == 2'b01 ? data_in_value[23:16] :
                                                                           data_in_value[31:24]};
      default: mem_load_writeback = data_in_value;
    endcase
  end

  // ────────────────────────────────────────────────────────────────────────
  // Hazard detection (ID stage)
  // ────────────────────────────────────────────────────────────────────────
  // What sources does the current ID instr read?
  wire id_uses_rsa_for_alu = id_op_is_mov || id_op_is_arith || id_op_is_cmp || id_op_is_store;
  wire id_uses_rsb_for_alu = (!id_imm_mode) && (id_op_is_load || id_op_is_store
                                                  || id_op_is_mov || id_op_is_arith || id_op_is_cmp);

  // Load-use: previous instr (now in IDEX/EX) is a LOAD whose result the
  // current ID instr needs.  Stall ID for 1 cycle.
  wire load_use_hazard = idex_valid && idex_is_load && ifid_valid && (
       (id_uses_rsa_for_alu && idex_rd == id_rd) ||
       (id_uses_rsb_for_alu && idex_rd == id_rsb_for_decode) ||
       (id_is_ret           && idex_rd == 4'hf)
  );

  // Memory wait: when EXMEM is LOAD with data not yet ready, stall pipeline.
  // load_data_ready combines load_started (= one cycle has passed since LOAD
  // entered EXMEM, so SoC has reacted to data_rd) with data_in_valid.
  wire load_data_ready = exmem_load_started && data_in_valid;
  wire mem_stall = exmem_valid && exmem_is_load && !load_data_ready;

  // STORE-LOAD structural hazard: MEM's STORE writes data_addr<=exmem_data_addr,
  // and EX's LOAD writes data_addr<=ex_load_addr.  Both fire same edge, and EX
  // comes LATER in the always block so its assignment wins — STORE would write
  // to the LOAD's address instead.  Stall EX/ID by 1 cycle.
  wire store_memop_conflict = exmem_valid && exmem_is_store && idex_valid &&
                              (idex_is_load || idex_is_store);

  // Stall the front end (IF/ID and IDEX latch) on any of the above.
  wire pipeline_stall = mem_stall || load_use_hazard || store_memop_conflict;

  // ────────────────────────────────────────────────────────────────────────
  // Debug bus & sim probes
  // ────────────────────────────────────────────────────────────────────────
  assign cpuDbg = {instr_addr[15:0], ifid_instr[31:0],
                   data_addr[7:0], data_in_value[7:0], data_out_value[7:0],
                   7'b0, data_rd, 7'b0, data_wr,
                   8'b0, cpu_registers[0]};

  // Provide ir/ir_pc/ir_valid aliases for sim_top probes
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
      squash_count      <= 2'd0;
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
      // IDEX
      idex_valid          <= 1'b0;
      idex_writes_reg     <= 1'b0;
      idex_writes_flags   <= 1'b0;
      idex_is_load        <= 1'b0;
      idex_is_store       <= 1'b0;
      idex_is_call        <= 1'b0;
      idex_is_iret        <= 1'b0;
      idex_is_jmp         <= 1'b0;
      // EXMEM
      exmem_valid         <= 1'b0;
      exmem_writes_reg    <= 1'b0;
      exmem_writes_flags  <= 1'b0;
      exmem_is_load       <= 1'b0;
      exmem_is_store      <= 1'b0;
      exmem_is_call       <= 1'b0;
      exmem_is_iret       <= 1'b0;
      exmem_load_started  <= 1'b0;
      // MEMWB
      memwb_valid         <= 1'b0;
      memwb_writes_reg    <= 1'b0;
      memwb_writes_flags  <= 1'b0;
      memwb_is_call       <= 1'b0;
      memwb_is_iret       <= 1'b0;
      reset_registers;
    end else begin
      data_wr <= 1'b0;
      data_rd <= 1'b0;
      irq_ack <= 1'b0;
      pc_in_flight <= pc;

      if (irq)
        {irq_pending, irq_num_pending} <= {1'b1, irq_num};

      if (clk_en) begin
        // ──────────────────────────────────────────────────────────────
        // WB stage: commit MEMWB to architectural state
        // ──────────────────────────────────────────────────────────────
        if (memwb_valid) begin
          if (memwb_writes_reg)
            cpu_registers[memwb_rd] <= memwb_value;
          if (memwb_writes_flags) begin
            c_flag <= memwb_c;
            z_flag <= memwb_z;
            n_flag <= memwb_n;
            v_flag <= memwb_v;
          end
          if (memwb_is_call)
            cpu_registers[4'hf] <= {8'b0, memwb_pc_plus4};
          if (memwb_is_iret) begin
            c_flag    <= c_flag_irq;
            z_flag    <= z_flag_irq;
            imm_upper <= imm_upper_irq;
            irq_ack   <= 1'b1;
          end
        end

        // ──────────────────────────────────────────────────────────────
        // MEM stage: process EXMEM → MEMWB
        // ──────────────────────────────────────────────────────────────
        if (mem_stall) begin
          // EXMEM stays put (LOAD waiting); inject bubble into MEMWB
          memwb_valid <= 1'b0;
          // First MEM cycle for a LOAD: data_in_valid is still the stale
          // pre-update value (=1).  Flip exmem_load_started so subsequent
          // cycles correctly gate on data_in_valid.
          if (exmem_is_load && !exmem_load_started)
            exmem_load_started <= 1'b1;
        end else if (exmem_valid) begin
          memwb_rd           <= exmem_rd;
          memwb_writes_reg   <= exmem_writes_reg || exmem_is_load;
          memwb_writes_flags <= exmem_writes_flags;
          memwb_is_call      <= exmem_is_call;
          memwb_is_iret      <= exmem_is_iret;
          memwb_c            <= exmem_c;
          memwb_z            <= exmem_z;
          memwb_n            <= exmem_n;
          memwb_v            <= exmem_v;
          memwb_pc_plus4     <= exmem_pc_plus4;
          memwb_value        <= exmem_is_load ? mem_load_writeback : exmem_alu;
          memwb_valid        <= 1'b1;
          exmem_load_started <= 1'b0;   // reset for any future LOAD

          // Issue STORE pulse for memory write
          if (exmem_is_store) begin
            data_wr         <= 1'b1;
            data_addr       <= exmem_data_addr;
            data_out_value  <= exmem_store_data;
            data_out_strobe <= exmem_store_strobe;
          end

          // After a LOAD completes, the IF stage held pc throughout the wait
          // so BRAM presented mem[pc_held] to the IF latch.  IF will latch
          // that instr next cycle, but BRAM is still presenting the same
          // value (= pc only advances now), so without a squash IF would
          // double-latch the same instr.
          if (exmem_is_load) squash_count <= 2'd1;
        end else begin
          memwb_valid <= 1'b0;
        end

        // ──────────────────────────────────────────────────────────────
        // EX stage: process IDEX → EXMEM
        // ──────────────────────────────────────────────────────────────
        if (mem_stall) begin
          // EX stalled too (EXMEM holds LOAD).  Don't update EXMEM.
        end else if (store_memop_conflict) begin
          // STORE is firing in MEM this cycle (writing data_addr<=store_addr).
          // If EX latched a LOAD/STORE this cycle it would overwrite data_addr
          // (EX comes later in this always block).  Bubble EXMEM so MEM has
          // nothing to do next cycle, and hold IDEX (= done in ID block).
          exmem_valid <= 1'b0;
        end else if (idex_valid) begin
          exmem_op             <= idex_op;
          exmem_size           <= idex_size;
          exmem_rd             <= idex_rd;
          exmem_alu            <= ex_alu_out[31:0];
          exmem_data_addr      <= idex_is_load ? ex_load_addr : ex_store_addr;
          exmem_load_addr_saved<= ex_load_addr;
          exmem_store_data     <= ex_store_data;
          exmem_store_strobe   <= ex_store_strobe;
          exmem_is_load        <= idex_is_load;
          exmem_is_store       <= idex_is_store;
          exmem_is_call        <= idex_is_call;
          exmem_is_iret        <= idex_is_iret;
          exmem_writes_reg     <= idex_writes_reg;
          exmem_writes_flags   <= idex_writes_flags;
          {exmem_c, exmem_z, exmem_n, exmem_v} <= ex_flags_new;
          exmem_pc_plus4       <= idex_pc_plus4;
          exmem_valid          <= 1'b1;
          exmem_load_started   <= 1'b0;   // MEM stage raises this on first cycle

          // LOAD: assert data_rd this cycle (request data; SoC delivers next cycle)
          if (idex_is_load) begin
            data_rd   <= 1'b1;
            data_addr <= ex_load_addr;
          end
        end else begin
          exmem_valid <= 1'b0;
        end

        // ──────────────────────────────────────────────────────────────
        // ID stage: decode IFID → IDEX
        // ──────────────────────────────────────────────────────────────
        if (mem_stall || load_use_hazard || store_memop_conflict) begin
          // Stall: hold IFID.  For load_use_hazard, bubble IDEX (= remove the
          // post-LOAD consumer instr; the LOAD has already moved on to EX).
          // For mem_stall or store_memop_conflict, hold IDEX (= keep the
          // LOAD/STORE here so EX can retry next cycle).
          if (!mem_stall && !store_memop_conflict) idex_valid <= 1'b0;
        end else if (ifid_valid) begin
          idex_op           <= id_op;
          idex_size         <= id_size;
          idex_rd           <= id_rd;
          idex_rsa_idx      <= id_rsa_for_decode; // = id_rd normally, R15 for RET
          idex_rsb_idx      <= id_rsb_for_decode; // = id_rsb_idx normally, R15 for RET
          idex_opa_val      <= id_reg_rsa;
          idex_opb_val      <= id_opb_val_decoded;
          idex_opb_is_imm   <= id_imm_mode;
          idex_pc           <= ifid_pc;
          idex_pc_plus4     <= ifid_pc + 24'd4;
          idex_is_load      <= id_op_is_load;
          idex_is_store     <= id_op_is_store;
          idex_is_jmp       <= id_op_is_jmp;
          idex_is_imm       <= id_op_is_imm;
          idex_is_mov       <= id_op_is_mov;
          idex_is_cmp       <= id_op_is_cmp;
          idex_is_arith     <= id_op_is_arith;
          idex_is_call      <= id_is_call;
          idex_is_iret      <= id_is_iret;
          idex_jmp_sub      <= ifid_instr[26:24];
          idex_jmp_bit23    <= ifid_instr[23];
          idex_jmp_bit22    <= ifid_instr[22];
          idex_disp24       <= id_disp24;
          idex_disp22       <= id_disp22;
          idex_disp16       <= id_disp16;
          idex_imm20        <= id_imm20;
          idex_writes_reg   <= id_writes_reg_alu;
          idex_writes_flags <= id_writes_flags;
          idex_valid        <= 1'b1;

          // IMM-prefix takes effect at end of IMM's ID stage — so the NEXT
          // instr's ID sees imm_upper.  Cleared by the consumer's ID.
          imm_upper <= id_op_is_imm ? ifid_instr[11:0] : 12'b0;
        end else begin
          idex_valid <= 1'b0;
        end

        // ──────────────────────────────────────────────────────────────
        // IF stage + branch / squash control
        // ──────────────────────────────────────────────────────────────
        if (boot_settle) begin
          boot_settle <= 1'b0;
          // pc holds at 0
        end else if (idex_valid && ex_branch_taken && !mem_stall) begin
          // Branch resolved in EX this cycle.  IFID + IDEX in-flight bubbles
          // are handled via _valid<=0 below.  squash_count=1 covers the BRAM
          // 1-cycle latency: after pc<=target this edge, BRAM samples target
          // at next edge and dout_a presents mem[target] one cycle later.
          // squash_count=2 would skip the first instr at target.
          pc           <= ex_branch_target;
          squash_count <= 2'd1;
          ifid_valid   <= 1'b0;
          idex_valid   <= 1'b0;   // override the IDEX update above to bubble
        end else if (pipeline_stall) begin
          // Hold IFID and pc
        end else if (squash_count != 0) begin
          squash_count <= squash_count - 2'd1;
          ifid_valid   <= 1'b0;
          pc           <= pc + 24'd4;
        end else if (ifid_valid && id_op_is_load) begin
          // LOAD moves to IDEX this cycle.  Next cycle load_use_hazard may
          // stall the pipeline if the LOAD's consumer is the post-LOAD instr.
          // If we advance pc normally here, BRAM advances past the instr
          // AFTER the consumer (which we'll need when the stall ends).
          // Latch IFID normally (= consumer instr) but HOLD pc so BRAM keeps
          // presenting mem[pc] until stall ends.
          //
          // NOTE: cpu_risc2p3.v has a proven rollback-based fix for an
          // analogous LOAD-IFID hazard.  The naive port to p5 (rollback
          // pc<=ifid_pc+4) produces a black screen because p5's 5-stage
          // pipeline has additional ID/EX/MEM latency that interacts with
          // the rollback differently than p3's 3-stage layout.  TODO: design
          // a p5-specific rollback that accounts for the extra stages.
          ifid_instr <= instr_value;
          ifid_pc    <= pc_in_flight;
          ifid_valid <= 1'b1;
          // pc HOLDS
        end else begin
          // Normal IF advance + latch
          ifid_instr <= instr_value;
          ifid_pc    <= pc_in_flight;
          ifid_valid <= 1'b1;
          pc         <= pc + 24'd4;
        end

        // ──────────────────────────────────────────────────────────────
        // IRQ entry: only when pipeline drained
        //
        // Critical: the IF block above may have just latched a new instr
        // (ifid_valid<=1).  We override that here so the latched-but-
        // unexecuted instr is dropped, and save its addr (= pc_in_flight)
        // as iret_addr so IRET resumes there.  squash_count=1 is enough
        // for the icache to re-fetch mem[vector] before normal latch.
        // ──────────────────────────────────────────────────────────────
        if (irq_pending && !idex_valid && !exmem_valid && !memwb_valid
            && !ifid_valid && squash_count == 0 && !pipeline_stall) begin
          c_flag_irq    <= c_flag;
          z_flag_irq    <= z_flag;
          imm_upper_irq <= imm_upper;
          imm_upper     <= 12'b0;
          iret_addr     <= pc_in_flight;
          pc            <= {19'b0, irq_num_pending, 2'b0};
          irq_pending   <= 1'b0;
          squash_count  <= 2'd1;
          ifid_valid    <= 1'b0;        // override normal IF latch
        end
      end
    end
  end

endmodule
