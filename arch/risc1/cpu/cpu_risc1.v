
`include "./risc1.vh"

/*
  challenge: AND, OR nelkuli proci, maszkolj biteket

  reset: NOP es stage2-decode legyen, addr = ffff hogy utana addr = 0 legyen
*/

module cpu_risc1 (
  input clk,
  input clk_en,
  input rst,
  output reg [9:0] instr_addr,
  input [17:0] instr_data,

  output reg [7:0] port_addr,
  input [7:0] port_data_in,
  output reg [7:0] port_data_out,
  output reg port_wr,
  output reg port_rd,

  output [127:0] cpuDbg
  );

  reg [7:0] cpu_registers[0:15];
  reg c_flag, z_flag;

  reg [10:0] stack[0:15];
  reg [3:0] stack_pointer, stack_pointer_next, stack_pointer_prev;

  reg [17:0] instr_reg;
  reg [2:0] stage;
  reg [7:0] opa, opb;
  reg [9:0] jump_addr, instr_addr_next;
  wire [8:0] alu_out;

  alu_risc1 alu0(opa, opb, instr_reg[17:14], c_flag, alu_out);

  task reset_registers;
    integer i;
    begin for (i = 0; i < 16; i = i + 1) begin cpu_registers[i] = 8'b0; stack[i] = 8'b0; end end
  endtask

  wire [7:0] reg0 = cpu_registers[0];
  wire [7:0] reg1 = cpu_registers[1];
  wire [7:0] reg2 = cpu_registers[2];
  wire [7:0] reg3 = cpu_registers[3];

  wire [10:0] stack0 = stack[0];
  wire [10:0] stack1 = stack[1];
  wire [10:0] stack2 = stack[2];
  wire [10:0] stack15 = stack[15];

  assign cpuDbg = {6'b0, instr_addr[9:0], 5'b0, stage[2:0], 6'b0, instr_data[17:0],   // 6 bytes
    port_addr, port_data_in, port_data_out, 7'b0, port_rd, 7'b0, port_wr,        // 5 bytes
    reg0, reg1, reg2, 8'b0, 8'b0, 8'b0                // 5 bytes

    };

  always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {opa, opb, instr_reg, jump_addr, c_flag, z_flag, port_addr, port_data_out, port_rd, port_wr, stack_pointer} <= 0;
    instr_addr <= 10'h3ff;
    stage <= `STAGE_2_DECODE;
    reset_registers;
  end else
//  if (clk_en)
  begin
    case(stage)
      `STAGE_1_FETCH:
        if (clk_en)
        begin
          instr_reg <= instr_data;
          stage <= `STAGE_2_DECODE;
        end

      `STAGE_2_DECODE:
        begin
          opa <= cpu_registers[instr_reg[12:9]];
          opb <= instr_reg[13] ? instr_reg[7:0] : cpu_registers[instr_reg[3:0]];
          jump_addr <= instr_addr + instr_reg[9:0];
          stack_pointer_prev <= stack_pointer - 1;
          stack_pointer_next <= stack_pointer + 1;
          instr_addr_next = instr_addr + 1;

          if (instr_reg[17:14] == `INSTR_IN)
            {port_rd, port_addr} <= {1'b1, instr_reg[13] ? instr_reg[7:0] : cpu_registers[instr_reg[3:0]]};

          stage <= `STAGE_3_EXECUTE;
        end

      `STAGE_3_EXECUTE:
        begin
          port_rd <= 0;

          if (instr_reg[17:14] == `INSTR_OUT)
            {port_wr, port_addr, port_data_out} <= {1'b1, opb, opa};

          if (instr_reg[17:14] == `INSTR_JMP)
          begin
            if ((instr_reg[13:12] == 2'h0 && instr_reg[11] == z_flag) ||
                (instr_reg[13:12] == 2'h1 && instr_reg[11] == c_flag) ||
                (instr_reg[13:12] == 2'h2))
              instr_addr <= jump_addr;
            else if (instr_reg[13:11] == 3'h7)     // CALL
            begin
              stack[stack_pointer] <= instr_addr_next;
              stack_pointer <= stack_pointer_next;
              instr_addr <= jump_addr;
            end
            else if (instr_reg[13:11] == 3'h6)     // RET
            begin
              instr_addr <= stack[stack_pointer_prev];   // 4 bit ????
              stack_pointer <= stack_pointer_prev;
            end
            else
              instr_addr <= instr_addr_next;
          end else
            instr_addr <= instr_addr_next;

          stage <= `STAGE_4_WRITEBACK;

        end

      `STAGE_4_WRITEBACK:
        begin
          {port_rd, port_wr} <= {1'b0, 1'b0};

          if (instr_reg[17:14] == `INSTR_IN)
            cpu_registers[instr_reg[12:9]] <= port_data_in;

          if (instr_reg[17:14] == `INSTR_CMP)
            {c_flag, z_flag} <= {alu_out[8], alu_out[7:0] == 8'h0};
          else if (instr_reg[17:14] == `INSTR_MOV || instr_reg[17] == 1'b1)    // MOV and all the ALU instructions
            {cpu_registers[instr_reg[12:9]], c_flag, z_flag} <= {alu_out[7:0], alu_out[8], alu_out[7:0] == 8'h0};

          stage <= `STAGE_1_FETCH;
        end
    endcase
  end
endmodule
