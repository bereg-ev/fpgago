
`include "./risc2.vh"

/*
- IMM utasitas
- IRQ, IRET
- byte, word, dword
- displacement

*/

module cpu_risc2 (
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

  reg [31:0] cpu_registers[0:15];
  reg c_flag, z_flag, n_flag, v_flag, c_flag_irq, z_flag_irq, irqNext;
  reg [11:0] immUpper_irq;

  reg [31:0] instr_reg;
  reg [2:0] stage, irqNumNext;
  reg [31:0] opa, opb, memory_in;
  reg [11:0] immUpper;
  reg [23:0] jump_addr, instr_addr_next, iret_addr;
  wire [32:0] alu_out;

  alu_risc2 alu0(opa, opb, instr_reg[31:27], c_flag, alu_out);

  task reset_registers;
    integer i;
    begin for (i = 0; i < 16; i = i + 1) begin cpu_registers[i] = 32'b0; end end
  endtask

  wire [31:0] reg0 = cpu_registers[0];
  wire [31:0] reg1 = cpu_registers[1];
  wire [31:0] reg2 = cpu_registers[2];
  wire [31:0] reg3 = cpu_registers[3];

  assign cpuDbg = {instr_addr[15:0], instr_value[31:0],   // 6 bytes
    data_addr[7:0], data_in_value[7:0], data_out_value[7:0], 7'b0, data_rd, 7'b0, data_wr,        // 5 bytes
    8'b0, reg0                 // 5 bytes
    };

  always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {opa, opb, instr_reg, jump_addr, c_flag, z_flag, n_flag, v_flag, data_addr, data_out_value, data_rd, data_wr} <= 0;
    {c_flag_irq, z_flag_irq, irq_ack, iret_addr, data_out_strobe, immUpper, immUpper_irq, irqNext, irqNumNext} <= 0;
    instr_addr <= 24'hfffffc;
    stage <= `STAGE_2_DECODE;
    reset_registers;
  end else
  begin
    if (irq)
      {irqNext, irqNumNext} <= {1'b1, irq_num};

    case(stage)
      `STAGE_1_FETCH:
        begin
          irq_ack <= 0;

          if (irqNext && clk_en)
          begin
            instr_addr <= {19'b0, irqNumNext[2:0], 2'b0};
            iret_addr <= instr_addr;
            stage <= `STAGE_6_IRQ;
          end
          else if (instr_valid && clk_en)
          begin
            instr_reg <= instr_value;
            stage <= `STAGE_2_DECODE;
          end
        end

      `STAGE_2_DECODE:
        begin
          opa <= cpu_registers[instr_reg[23:20]];
          opb <= instr_reg[26] ? {immUpper, instr_reg[19:0]} : cpu_registers[instr_reg[19:16]];
          jump_addr <= instr_addr + instr_reg[23:0];
          immUpper <= (instr_reg[31:27] == `INSTR_IMM) ? instr_reg[11:0] : 12'b0;
          instr_addr_next = instr_addr + 4;

          if (instr_reg[31:27] == `INSTR_LOAD)
            {data_rd, data_addr} <= {1'b1, instr_reg[26] ? {immUpper[3:0], instr_reg[19:0]} : cpu_registers[instr_reg[19:16]][23:0] + {8'h0, instr_reg[15:0]}};

          stage <= `STAGE_3_EXECUTE;
        end

      `STAGE_3_EXECUTE:
        begin
          data_rd <= 0;

          if (instr_reg[31:27] == `INSTR_STORE)
          begin
            data_wr   <= 1'b1;
            data_addr <= opb[23:0];
            case (instr_reg[25:24])
              2'b00: begin // dword
                data_out_value  <= opa;
                data_out_strobe <= 4'b1111;
              end
              2'b01: begin // byte — route opa[7:0] to correct lane (big-endian)
                case (opb[1:0])
                  2'b00: begin data_out_value <= {opa[7:0], 24'b0}; data_out_strobe <= 4'b1000; end
                  2'b01: begin data_out_value <= {8'b0, opa[7:0], 16'b0}; data_out_strobe <= 4'b0100; end
                  2'b10: begin data_out_value <= {16'b0, opa[7:0], 8'b0}; data_out_strobe <= 4'b0010; end
                  2'b11: begin data_out_value <= {24'b0, opa[7:0]}; data_out_strobe <= 4'b0001; end
                endcase
              end
              2'b10: begin // halfword — route opa[15:0] to correct lane
                if (opb[1])
                  begin data_out_value <= {16'b0, opa[15:0]}; data_out_strobe <= 4'b0011; end
                else
                  begin data_out_value <= {opa[15:0], 16'b0}; data_out_strobe <= 4'b1100; end
              end
              default: begin
                data_out_value  <= opa;
                data_out_strobe <= 4'b1111;
              end
            endcase
          end

          if (instr_reg[31:27] == `INSTR_JMP)
          begin
            if (instr_reg[26:24] == 3'h5 && instr_reg[23])
              // JGE/JLT: signed branch (reuses IRET slot with [23]=1)
              // [22]=0 → JGE (N==V), [22]=1 → JLT (N!=V)
              // offset = sign_extend([21:0])
              if (instr_reg[22] == (n_flag != v_flag))  // JGE: take when N==V ([22]=0, cond true); JLT: take when N!=V ([22]=1, cond true)
                instr_addr <= instr_addr + {{2{instr_reg[21]}}, instr_reg[21:0]};
              else
                instr_addr <= instr_addr_next;
            else if (instr_reg[26:24] == 3'h5)     // IRET (original, [23]=0)
              instr_addr <= iret_addr;
            else if ((instr_reg[26:25] == 2'h0 && instr_reg[24] == z_flag) ||
                (instr_reg[26:25] == 2'h1 && instr_reg[24] == c_flag) ||
                (instr_reg[26:25] == 2'h2))
              instr_addr <= jump_addr;
            else if (instr_reg[26:24] == 3'h7)     // CALL
              instr_addr <= jump_addr;
            else if (instr_reg[26:24] == 3'h6)     // RET
              instr_addr <= cpu_registers[4'hf];
            else
              instr_addr <= instr_addr_next;
          end else
            instr_addr <= instr_addr_next;

          stage <= `STAGE_4_MEMORY;

        end

      `STAGE_4_MEMORY:
        begin
          {data_rd, data_wr} <= {1'b0, 1'b0};

          if (data_in_valid)
          begin
            memory_in <= data_in_value;
            stage <= `STAGE_5_WRITEBACK;
          end
        end

      `STAGE_5_WRITEBACK:
        begin

          if (instr_reg[31:27] == `INSTR_LOAD)
          begin
            if (instr_reg[25:24] == 2'b00)
              cpu_registers[instr_reg[23:20]] <= memory_in;
            else if (instr_reg[25:24] == 2'b10)  // halfword → zero-extend
              cpu_registers[instr_reg[23:20]] <= {16'b0, data_addr[1] ? memory_in[15:0] : memory_in[31:16]};
            else if (instr_reg[25:24] == 2'b01)  // byte → zero-extend
              cpu_registers[instr_reg[23:20]] <= {24'b0,
                data_addr[1:0] == 2'b11 ? memory_in[7:0] :
                (data_addr[1:0] == 2'b10 ? memory_in[15:8] :
                (data_addr[1:0] == 2'b01 ? memory_in[23:16] : memory_in[31:24]))};
          end

          if (instr_reg[31:27] == `INSTR_JMP && instr_reg[26:24] == 3'h7)     // CALL
            cpu_registers[4'hf] <= instr_addr_next;

          if (instr_reg[31:27] == `INSTR_JMP && instr_reg[26:24] == 3'h5 && ~instr_reg[23])     // IRET (not JGE/JLT)
          begin
            {c_flag, z_flag, irq_ack} <= {c_flag_irq, z_flag_irq, 1'b1};
            immUpper <= immUpper_irq;
          end

          if (instr_reg[31:27] == `INSTR_CMP)
          begin
            // CMP (subtraction): set all four flags
            {c_flag, z_flag} <= {alu_out[32], alu_out[31:0] == 32'h0};
            n_flag <= alu_out[31];
            v_flag <= (opa[31] ^ opb[31]) & (opa[31] ^ alu_out[31]);  // signed overflow for SUB/CMP
          end
          else if (instr_reg[31:27] == `INSTR_MOV)    // MOV: write register, do NOT update flags (LLVM expects flag-neutral MOV)
            cpu_registers[instr_reg[23:20]] <= alu_out[31:0];
          else if (instr_reg[31:30] == 2'b01 && instr_reg[23:20] == 4'h7)
            // ALU targeting R7 (frame-index scratch): write register, do NOT update
            // flags.  LLVM's eliminateFrameIndex inserts "mov r7,r14; add r7,#off"
            // between CMP and conditional branch — the ADD must be flag-neutral.
            cpu_registers[4'h7] <= alu_out[31:0];
          else if (instr_reg[31:30] == 2'b01)    // ALU instructions (AND/OR/XOR/ADD/SUB/RCL/RCR)
          begin
            {cpu_registers[instr_reg[23:20]], c_flag, z_flag} <= {alu_out[31:0], alu_out[32], alu_out[31:0] == 32'h0};
            n_flag <= alu_out[31];
            // V flag: signed overflow (different formula for ADD vs SUB)
            if (instr_reg[31:27] == `INSTR_SUB)
              v_flag <= (opa[31] ^ opb[31]) & (opa[31] ^ alu_out[31]);
            else if (instr_reg[31:27] == `INSTR_ADD)
              v_flag <= ~(opa[31] ^ opb[31]) & (opa[31] ^ alu_out[31]);
            else
              v_flag <= 1'b0;  // AND/OR/XOR/RCL/RCR: no overflow
          end

          stage <= `STAGE_1_FETCH;
        end

      `STAGE_6_IRQ:
        begin
          {c_flag_irq, z_flag_irq} <= {c_flag, z_flag};
          immUpper_irq <= immUpper;
          immUpper <= 0;  /* clear so ISR starts with clean state */
          irqNext <= 0;
          stage <= `STAGE_1_FETCH;
        end

    endcase
  end
endmodule
