/*
 * verilog model of 6502 CPU.
 *
 * (C) Arlet Ottens, <arlet@c-scape.nl>
 *
 * Feel free to use this code in any project (commercial or not), as long as you
 * keep this message, and the copyright notice. This code is provided "as is",
 * without any warranties of any kind.
 */

/*
 * UNDOCUMENTED ("illegal") NMOS OPCODES — added 2026-08-07 for Blue Max
 * ---------------------------------------------------------------------
 * Real 6502/6510 silicon executes the unused opcode slots as well-defined
 * side effects of the decode ROM, and C64 crackers/crunchers use them
 * constantly (Blue Max #433 dies on `SAX $24` / `ISC $24` in the very first
 * instructions of its Exomizer-style decruncher — it never reaches the game,
 * in ANY drive mode, because the failure is in the CPU, not the disk path).
 *
 * Every illegal opcode lives in the `cc = 11` column, i.e. IR[1:0] == 2'b11,
 * and reuses the addressing-mode field IR[4:2] of the cc=01 column, so the
 * existing state dispatch mostly works already — only the $x3 / $xB / even
 * $xF slots needed new entries.  IR[7:5] selects the operation:
 *
 *   000 SLO  ASL mem ; ORA mem      100 SAX  store A & X
 *   001 RLA  ROL mem ; AND mem      101 LAX  LDA mem ; LDX mem
 *   010 SRE  LSR mem ; EOR mem      110 DCP  DEC mem ; CMP mem
 *   011 RRA  ROR mem ; ADC mem      111 ISC  INC mem ; SBC mem
 *
 * The read-modify-write pairs (SLO/RLA/SRE/RRA/DCP/ISC) are implemented as
 * `combo` ops: the existing RMW0/WRITE chain does the memory half, then
 * the FETCH cycle — which an RMW instruction already spends — runs the ALU a
 * second time with `op2` and the written-back value (`RMW_RESULT`) as the B
 * operand, and DECODE commits the register/flags exactly as for the plain
 * accumulator op.  No extra cycles.
 *
 * The immediate column ($0B $2B ANC, $4B ALR, $6B ARR, $8B XAA, $AB LAX#,
 * $CB SBX, $EB SBC#) is decoded too; ALR/ARR need a second ALU pass because
 * the ALU cannot AND and shift in one go, so they get the extra ILL2 state.
 *
 * NOT implemented (unstable on real silicon — the result depends on analog
 * behaviour of the address high byte, and no shipping game relies on them):
 *   $93/$9F AHX, $9B TAS, $9C SHY, $9E SHX  — treated as plain stores of A&X
 *                                             ($93/$9F) or ignored ($9B),
 *   $BB LAS  — treated as LAX abs,Y (S is not modified),
 *   $8B XAA  — the unstable "A | magic" term is dropped: A = A & X & imm,
 *   $AB LAX# — likewise dropped: A = X = imm.
 *   $x2 JAM  — left jamming the state machine, as on real hardware.
 */

module cpu( clk, reset, AB, DI, DO, WE, IRQ, NMI, RDY, SO, DI_STABLE );

input clk;
input reset;
output reg [15:0] AB;
input [7:0] DI;
output [7:0] DO;
output WE;
input IRQ;
input NMI;
input RDY;
input SO;      /* set-overflow strobe (1541 byte-ready → V); tie 0 elsewhere */
input DI_STABLE; /* 1 = DI is registered and stable across RDY stalls, so
                  * DIMUX may bypass DIHOLD — this keeps AB (which is
                  * combinational from DIMUX in the ABS1/JMP1/... states)
                  * VALID mid-stall, which a prefetching memory backend
                  * (the 1541's PSRAM ROM path) depends on.  Tie 0 where DI
                  * can be transient during a stall (the C64: the VIC owns
                  * the bus mid-badline and DI carries ITS fetches — DIHOLD
                  * is what preserves the CPU's byte there). */

reg  [15:0] PC /* verilator public_flat_rd */;
reg  [7:0] ABL;
reg  [7:0] ABH;
wire [7:0] ADD;

reg  [7:0] DIHOLD;
reg  DIHOLD_valid;
wire [7:0] DIMUX;

reg  [7:0] IRHOLD;
reg  IRHOLD_valid;
reg  [7:0] RMW_RESULT = 0;  /* value the RMW half of a combo op wrote back */

reg  [7:0] AXYS[3:0];

reg  C = 0;
reg  Z = 0;
reg  I = 0;
reg  D = 0;
reg  V = 0;
reg  N = 0;
wire AZ;
wire AV;
wire AN;
wire HC;

reg  [7:0] AI;
reg  [7:0] BI;
wire [7:0] IR;
reg  [7:0] DO;
reg  WE;
reg  CI;
wire CO;
wire [7:0] PCH = PC[15:8];
wire [7:0] PCL = PC[7:0];

reg NMI_edge = 0;

reg [1:0] regsel;
wire [7:0] regfile = AXYS[regsel];

parameter
        SEL_A    = 2'd0,
        SEL_S    = 2'd1,
        SEL_X    = 2'd2,
        SEL_Y    = 2'd3;

`ifdef SIM
wire [7:0]   A = AXYS[SEL_A];
wire [7:0]   X = AXYS[SEL_X];
wire [7:0]   Y = AXYS[SEL_Y];
wire [7:0]   S = AXYS[SEL_S];
`endif

/* A & X — the operand SAX stores and the accumulator XAA/SBX start from */
wire [7:0] AND_AX = AXYS[SEL_A] & AXYS[SEL_X];

wire [7:0] P = { N, V, 2'b11, D, I, Z, C };

reg [5:0] state;

reg PC_inc;
reg [15:0] PC_temp;

reg [1:0] src_reg;
reg [1:0] dst_reg;

/* ── undocumented-opcode control (see the header comment) ─────────────────
 * All initialised, so `combo`/`alu2` can never present an x to the state
 * machine or the ALU before the first DECODE. */
reg ill       = 0;      /* executing opcode is from the cc=11 column     */
reg [3:0] op2 = 0;      /* ALU op for the FETCH pass of a combo op       */
reg sax       = 0;      /* store A & X instead of a register             */
reg lax       = 0;      /* the register write also lands in X            */
reg axand     = 0;      /* the FETCH A-operand is A & X (XAA, SBX)       */
reg anc       = 0;      /* ANC: C = result bit 7                         */
reg arr       = 0;      /* ARR: C = result bit 6, V = bit 6 ^ bit 5      */
reg alu2      = 0;      /* needs the second ALU pass (ALR, ARR)          */

reg index_y;
reg load_reg;
reg inc;
reg write_back;
reg load_only;
reg store;
reg adc_sbc;
reg compare;
reg shift;
reg rotate;
reg backwards;
reg cond_true;
reg [2:0] cond_code;
reg shift_right;
reg alu_shift_right;
reg [3:0] op;
reg [3:0] alu_op;
reg adc_bcd;
reg adj_bcd;

/* SLO RLA SRE RRA DCP ISC — an illegal op that both writes memory back and
 * then feeds the result through the ALU into A (or a compare) */
wire combo = ill & write_back;

reg bit_ins;
reg plp;
reg php;
reg clc;
reg sec;
reg cld;
reg sed;
reg cli;
reg sei;
reg clv;
reg brk;

reg res;

parameter
        OP_OR  = 4'b1100,
        OP_AND = 4'b1101,
        OP_EOR = 4'b1110,
        OP_ADD = 4'b0011,
        OP_SUB = 4'b0111,
        OP_ROL = 4'b1011,
        OP_A   = 4'b1111;

parameter
    ABS0   = 6'd0,
    ABS1   = 6'd1,
    ABSX0  = 6'd2,
    ABSX1  = 6'd3,
    ABSX2  = 6'd4,
    BRA0   = 6'd5,
    BRA1   = 6'd6,
    BRA2   = 6'd7,
    BRK0   = 6'd8,
    BRK1   = 6'd9,
    BRK2   = 6'd10,
    BRK3   = 6'd11,
    DECODE = 6'd12,
    FETCH  = 6'd13,
    INDX0  = 6'd14,
    INDX1  = 6'd15,
    INDX2  = 6'd16,
    INDX3  = 6'd17,
    INDY0  = 6'd18,
    INDY1  = 6'd19,
    INDY2  = 6'd20,
    INDY3  = 6'd21,
    JMP0   = 6'd22,
    JMP1   = 6'd23,
    JMPI0  = 6'd24,
    JMPI1  = 6'd25,
    JSR0   = 6'd26,
    JSR1   = 6'd27,
    JSR2   = 6'd28,
    JSR3   = 6'd29,
    PULL0  = 6'd30,
    PULL1  = 6'd31,
    PULL2  = 6'd32,
    PUSH0  = 6'd33,
    PUSH1  = 6'd34,
    REG    = 6'd36,
    RTI0   = 6'd37,
    RTI1   = 6'd38,
    RTI2   = 6'd39,
    RTI3   = 6'd40,
    RTI4   = 6'd41,
    RTS0   = 6'd42,
    RTS1   = 6'd43,
    RTS2   = 6'd44,
    RTS3   = 6'd45,
    WRITE  = 6'd46,
    ZP0    = 6'd47,
    ZPX0   = 6'd48,
    ZPX1   = 6'd49,
    ILL2   = 6'd51,   /* second ALU pass for ALR/ARR: shift the AND result */
    RMW0   = 6'd50;   /* RMW dummy write of the unmodified value (real 6502
                       * behavior) — I/O with write-1-to-clear registers
                       * (VIC $D019, TED $FF09) is acked by INC/LSR/ASL's
                       * first write, so it cannot be skipped.
                       *
                       * RMW0 directly follows the addressing state: the read
                       * initiated there has its data on DIMUX during RMW0
                       * (the same one-state-later relation every load uses),
                       * so RMW0 both writes DIMUX back unmodified AND runs
                       * the ALU on it; WRITE then stores the result.  A
                       * separate READ state here (2026-07-20..08-08) made
                       * every RMW instruction ONE CYCLE LONGER than NMOS
                       * silicon — which desynced cycle-counted drive-code
                       * fastloaders (Street Fighter #3634: the C64-side
                       * $DD00 sample slid onto the drive's SECOND 2-bit
                       * write).  zp RMW = 5 cycles, abs 6, abs,X 7 — the
                       * check-cpu cycle gate now locks all of these. */

always @*
    case( state )
        DECODE:         if( (~I & IRQ) | NMI_edge )
                            PC_temp = { ABH, ABL };
                        else
                            PC_temp = PC;

        JMP1,
        JMPI1,
        JSR3,
        RTS3,
        RTI4:           PC_temp = { DIMUX, ADD };

        BRA1:           PC_temp = { ABH, ADD };

        BRA2:           PC_temp = { ADD, PCL };

        BRK2:           PC_temp =      res ? 16'hfffc :
                                  NMI_edge ? 16'hfffa : 16'hfffe;

        default:        PC_temp = PC;
    endcase

always @*
    case( state )
        DECODE:         if( (~I & IRQ) | NMI_edge )
                            PC_inc = 0;
                        else
                            PC_inc = 1;

        ABS0,
        ABSX0,
        BRA0,
        BRA2,
        BRK3,
        JMPI1,
        JMP1,
        RTI4,
        ILL2,
        RTS3:           PC_inc = 1;

        /* ALR/ARR hold PC over FETCH and re-present the next opcode address
         * during ILL2, so DECODE still lands on the right instruction */
        FETCH:          PC_inc = ~alu2;

        BRA1:           PC_inc = CO ^~ backwards;

        default:        PC_inc = 0;
    endcase

always @(posedge clk)
    if( RDY )
        PC <= PC_temp + PC_inc;

parameter
        ZEROPAGE  = 8'h00,
        STACKPAGE = 8'h01;

always @*
    case( state )
        ABSX1,
        INDX3,
        INDY2,
        JMP1,
        JMPI1,
        RTI4,
        ABS1:           AB = { DIMUX, ADD };

        BRA2,
        INDY3,
        ABSX2:          AB = { ADD, ABL };

        BRA1:           AB = { ABH, ADD };

        JSR0,
        PUSH1,
        RTS0,
        RTI0,
        BRK0:           AB = { STACKPAGE, regfile };

        BRK1,
        JSR1,
        PULL1,
        RTS1,
        RTS2,
        RTI1,
        RTI2,
        RTI3,
        BRK2:           AB = { STACKPAGE, ADD };

        INDY1,
        INDX1,
        ZPX1,
        INDX2:          AB = { ZEROPAGE, ADD };

        ZP0,
        INDY0:          AB = { ZEROPAGE, DIMUX };

        REG,
        RMW0,
        WRITE:          AB = { ABH, ABL };

        default:        AB = PC;
    endcase

always @(posedge clk)
    if( state != PUSH0 && state != PUSH1 && RDY &&
        state != PULL0 && state != PULL1 && state != PULL2 )
    begin
        ABL <= AB[7:0];
        ABH <= AB[15:8];
    end

always @*
    case( state )
        WRITE:   DO = ADD;

        /* dummy write of the value still on the bus from the addressing
         * state's read — the NMOS write-original-back cycle */
        RMW0:    DO = DIMUX;

        JSR0,
        BRK0:    DO = PCH;

        JSR1,
        BRK1:    DO = PCL;

        PUSH1:   DO = php ? P : ADD;

        BRK2:    DO = (IRQ | NMI_edge) ? (P & 8'b1110_1111) : P;

        default: DO = sax ? AND_AX : regfile;
    endcase

always @*
    case( state )
        BRK0,
        BRK1,
        BRK2,
        JSR0,
        JSR1,
        PUSH1,
        RMW0,
        WRITE:   WE = 1;

        INDX3,
        INDY3,
        ABSX2,
        ABS1,
        ZPX1,
        ZP0:     WE = store;

        default: WE = 0;
    endcase

reg write_register;

always @*
    case( state )
        DECODE: write_register = load_reg & ~plp;

        PULL1,
         RTS2,
         RTI3,
         BRK3,
         JSR0,
         JSR2 : write_register = 1;

       default: write_register = 0;
    endcase

always @(posedge clk)
    adj_bcd <= adc_sbc & D;

reg [3:0] ADJL;
reg [3:0] ADJH;

always @* begin
    casex( {adj_bcd, adc_bcd, HC} )
         3'b0xx: ADJL = 4'd0;
         3'b100: ADJL = 4'd10;
         3'b101: ADJL = 4'd0;
         3'b110: ADJL = 4'd0;
         3'b111: ADJL = 4'd6;
    endcase
end

always @* begin
    casex( {adj_bcd, adc_bcd, CO} )
         3'b0xx: ADJH = 4'd0;
         3'b100: ADJH = 4'd10;
         3'b101: ADJH = 4'd0;
         3'b110: ADJH = 4'd0;
         3'b111: ADJH = 4'd6;
    endcase
end

always @(posedge clk)
    if( write_register & RDY ) begin
        AXYS[regsel] <= (state == JSR0) ? DIMUX : { ADD[7:4] + ADJH, ADD[3:0] + ADJL };
        /* LAX loads X as well as A.  regsel is SEL_A here (write_register is
         * only set outside DECODE for PLA/RTS/RTI/BRK/JSR, where lax is 0). */
        if( lax )
            AXYS[SEL_X] <= { ADD[7:4] + ADJH, ADD[3:0] + ADJL };
    end

always @*
    case( state )
        INDY1,
        INDX0,
        ZPX0,
        ABSX0  : regsel = index_y ? SEL_Y : SEL_X;

        DECODE : regsel = dst_reg;

        BRK0,
        BRK3,
        JSR0,
        JSR2,
        PULL0,
        PULL1,
        PUSH1,
        RTI0,
        RTI3,
        RTS0,
        RTS2   : regsel = SEL_S;

        default: regsel = src_reg;
    endcase

ALU ALU( .clk(clk),
         .op(alu_op),
         .right(alu_shift_right),
         .AI(AI),
         .BI(BI),
         .CI(CI),
         .BCD(adc_bcd & (state == FETCH)),
         .CO(CO),
         .OUT(ADD),
         .V(AV),
         .Z(AZ),
         .N(AN),
         .HC(HC),
         .RDY(RDY) );

always @*
    case( state )
        RMW0:   alu_op = op;

        BRA1:   alu_op = backwards ? OP_SUB : OP_ADD;

        /* combo ops reuse the FETCH cycle for their accumulator half */
        FETCH:  alu_op = combo ? op2 : op;

        ILL2:   alu_op = OP_A;

        REG :   alu_op = op;

        DECODE,
        ABS1:   alu_op = 1'bx;

        PUSH1,
        BRK0,
        BRK1,
        BRK2,
        JSR0,
        JSR1:   alu_op = OP_SUB;

     default:   alu_op = OP_ADD;
    endcase

always @*
    if( state == FETCH )
        /* SRE/RRA shift in the READ half only — the FETCH half is EOR/ADC */
        alu_shift_right = combo ? 1'b0 : shift_right;
    else if( state == ILL2 )
        alu_shift_right = 1;          /* ALR/ARR: LSR/ROR the AND result */
    else if( state == REG || state == RMW0 )
        alu_shift_right = shift_right;
    else
        alu_shift_right = 0;

always @(posedge clk)
    if( RDY )
        backwards <= DIMUX[7];

always @*
    case( state )
        JSR1,
        RTS1,
        RTI1,
        RTI2,
        BRK1,
        BRK2,
        INDX1:  AI = ADD;

        REG,
        ZPX0,
        INDX0,
        ABSX0,
        RTI0,
        RTS0,
        JSR0,
        JSR2,
        BRK0,
        PULL0,
        INDY1,
        PUSH0,
        PUSH1:  AI = regfile;

        /* RMW0: the freshly-read value — the ALU computes the modified
         * result during the dummy-write cycle; WRITE stores it */
        BRA0,
        RMW0:   AI = DIMUX;

        BRA1:   AI = ABH;

        ILL2:   AI = ADD;               /* ALR/ARR second pass */

        FETCH:  AI = axand    ? AND_AX :   /* XAA, SBX */
                     load_only ? 8'h00  :
                                 regfile;

        DECODE,
        ABS1:   AI = 8'hxx;

        default:  AI = 0;
    endcase

always @*
    case( state )
         BRA1,
         RTS1,
         RTI0,
         RTI1,
         RTI2,
         INDX1,
         RMW0,
         REG,
         JSR0,
         JSR1,
         JSR2,
         BRK0,
         BRK1,
         BRK2,
         PUSH0,
         PUSH1,
         PULL0,
         ILL2,
         RTS0:  BI = 8'h00;

         BRA0:  BI = PCL;

         /* a combo op's accumulator half operates on what it just wrote back */
         FETCH: BI = combo ? RMW_RESULT : DIMUX;

         DECODE,
         ABS1:  BI = 8'hxx;

         default:       BI = DIMUX;
    endcase

always @*
    case( state )
        INDY2,
        BRA1,
        ABSX1:  CI = CO;

        DECODE,
        ABS1:   CI = 1'bx;

        /* ARR rotates the carry in; ALR shifts a 0 in */
        ILL2:   CI = arr ? C : 1'b0;

        RMW0,
        REG:    CI = rotate ? C :
                     shift ? 0 : inc;

        FETCH:  CI = rotate  ? C :
                     compare ? 1 :
                     (shift | load_only) ? 0 : C;

        PULL0,
        RTI0,
        RTI1,
        RTI2,
        RTS0,
        RTS1,
        INDY0,
        INDX1:  CI = 1;

        default:        CI = 0;
    endcase

always @(posedge clk )
    if( shift && state == WRITE )
        C <= CO;
    else if( state == RTI2 )
        C <= DIMUX[0];
    else if( ~write_back && state == DECODE ) begin
        if( anc )                       /* ANC: C = bit 7 of A & imm */
            C <= AN;
        else if( arr )                  /* ARR: C = bit 6 of the result */
            C <= ADD[6];
        else if( adc_sbc | shift | compare )
            C <= CO;
        else if( plp )
            C <= ADD[0];
        else begin
            if( sec ) C <= 1;
            if( clc ) C <= 0;
        end
    end
    /* Combo ops: RRA/ISC/DCP take C from their accumulator half; SLO/RLA/SRE
     * keep the carry their shift already wrote during WRITE. */
    else if( combo && state == DECODE ) begin
        if( adc_sbc | compare )
            C <= CO;
    end

always @(posedge clk)
    if( state == WRITE )
        Z <= AZ;
    else if( state == RTI2 )
        Z <= DIMUX[1];
    else if( state == DECODE ) begin
        if( plp )
            Z <= ADD[1];
        else if( (load_reg & (regsel != SEL_S)) | compare | bit_ins )
            Z <= AZ;
    end

always @(posedge clk)
    if( state == WRITE )
        N <= AN;
    else if( state == RTI2 )
        N <= DIMUX[7];
    else if( state == DECODE ) begin
        if( plp )
            N <= ADD[7];
        else if( (load_reg & (regsel != SEL_S)) | compare )
            N <= AN;
    end else if( state == FETCH && bit_ins )
        N <= DIMUX[7];

always @(posedge clk)
    if( state == BRK3 )
        I <= 1;
    else if( state == RTI2 )
        I <= DIMUX[2];
    else if( state == REG ) begin
        if( sei ) I <= 1;
        if( cli ) I <= 0;
    end else if( state == DECODE )
        if( plp ) I <= ADD[2];

always @(posedge clk )
    if( state == RTI2 )
        D <= DIMUX[3];
    else if( state == DECODE ) begin
        if( sed ) D <= 1;
        if( cld ) D <= 0;
        if( plp ) D <= ADD[3];
    end

always @(posedge clk )
    if( SO )
        /* hardware set-overflow: wins over a same-cycle CLV, exactly like
         * the C reference (byte-ready applied after the instruction) */
        V <= 1;
    else if( state == RTI2 )
        V <= DIMUX[6];
    else if( state == DECODE ) begin
        if( arr )     V <= ADD[6] ^ ADD[5];   /* ARR */
        else
        if( adc_sbc ) V <= AV;
        if( clv )     V <= 0;
        if( plp )     V <= ADD[6];
    end else if( state == FETCH && bit_ins )
        V <= DIMUX[6];

always @(posedge clk )
    if( reset )
        IRHOLD_valid <= 0;
    else if( RDY ) begin
        if( state == PULL0 || state == PUSH0 ) begin
            IRHOLD <= DIMUX;
            IRHOLD_valid <= 1;
        end else if( state == DECODE )
            IRHOLD_valid <= 0;
    end

assign IR = (IRQ & ~I) | NMI_edge ? 8'h00 :
                     IRHOLD_valid ? IRHOLD : DIMUX;

always @(posedge clk )
    if( RDY )
        DIHOLD <= DI;

/* The modified value a combo op writes back, held for its FETCH-cycle ALU
 * pass (the data bus carries our own write during WRITE, so DIMUX is not a
 * dependable source for it). */
always @(posedge clk )
    if( RDY && state == WRITE )
        RMW_RESULT <= ADD;

assign DIMUX = (~RDY & ~DI_STABLE) ? DIHOLD : DI;

always @(posedge clk or posedge reset)
    if( reset )
        state <= BRK0;
    else if( RDY ) case( state )
        DECODE  :
            casex ( IR )
                8'b0000_0000:   state <= BRK0;
                8'b0010_0000:   state <= JSR0;
                8'b0010_1100:   state <= ABS0;
                8'b0100_0000:   state <= RTI0;
                8'b0100_1100:   state <= JMP0;
                8'b0110_0000:   state <= RTS0;
                8'b0110_1100:   state <= JMPI0;
                8'b0x00_1000:   state <= PUSH0;
                8'b0x10_1000:   state <= PULL0;
                8'b0xx1_1000:   state <= REG;
                8'b1xx0_00x0:   state <= FETCH;
                8'b1xx0_1100:   state <= ABS0;
                8'b1xxx_1000:   state <= REG;
                8'bxxx0_0001:   state <= INDX0;
                8'bxxx0_01xx:   state <= ZP0;
                8'bxxx0_1001:   state <= FETCH;
                8'bxxx0_1101:   state <= ABS0;
                8'bxxx0_1110:   state <= ABS0;
                8'bxxx1_0000:   state <= BRA0;
                8'bxxx1_0001:   state <= INDY0;
                8'bxxx1_01xx:   state <= ZPX0;
                8'bxxx1_1001:   state <= ABSX0;
                8'bxxx1_11xx:   state <= ABSX0;
                8'bxxxx_1010:   state <= REG;

                /* Undocumented opcodes.  The odd-column slots ($x7 $xB-odd
                 * $xF-odd $x3-odd) already alias the patterns above; these
                 * are the ones that fell through and jammed the core.  Every
                 * pattern here is an illegal opcode — none can shadow a
                 * documented one. */
                8'bxxx0_0011:   state <= INDX0;   /* (zp,X)  $03 .. $E3 */
                8'bxxx1_0011:   state <= INDY0;   /* (zp),Y  $13 .. $F3 */
                8'bxxx0_1011:   state <= FETCH;   /* #imm    $0B .. $EB */
                8'bxxx1_1011:   state <= ABSX0;   /* abs,Y   $1B .. $FB */
                8'bxxx0_1111:   state <= ABS0;    /* abs     $0F .. $EF */
                8'b0000_1100:   state <= ABS0;    /* NOP abs $0C        */
            endcase

        ZP0     : state <= write_back ? RMW0 : FETCH;

        ZPX0    : state <= ZPX1;
        ZPX1    : state <= write_back ? RMW0 : FETCH;

        ABS0    : state <= ABS1;
        ABS1    : state <= write_back ? RMW0 : FETCH;

        ABSX0   : state <= ABSX1;
        ABSX1   : state <= (CO | store | write_back) ? ABSX2 : FETCH;
        ABSX2   : state <= write_back ? RMW0 : FETCH;

        /* the write_back arms are for the illegal (zp,X)/(zp),Y RMW ops —
         * no documented opcode read-modify-writes through an indirection */
        INDX0   : state <= INDX1;
        INDX1   : state <= INDX2;
        INDX2   : state <= INDX3;
        INDX3   : state <= write_back ? RMW0 : FETCH;

        INDY0   : state <= INDY1;
        INDY1   : state <= INDY2;
        INDY2   : state <= (CO | store | write_back) ? INDY3 : FETCH;
        INDY3   : state <= write_back ? RMW0 : FETCH;

        RMW0    : state <= WRITE;
        WRITE   : state <= FETCH;
        FETCH   : state <= alu2 ? ILL2 : DECODE;
        ILL2    : state <= DECODE;

        REG     : state <= DECODE;

        PUSH0   : state <= PUSH1;
        PUSH1   : state <= DECODE;

        PULL0   : state <= PULL1;
        PULL1   : state <= PULL2;
        PULL2   : state <= DECODE;

        JSR0    : state <= JSR1;
        JSR1    : state <= JSR2;
        JSR2    : state <= JSR3;
        JSR3    : state <= FETCH;

        RTI0    : state <= RTI1;
        RTI1    : state <= RTI2;
        RTI2    : state <= RTI3;
        RTI3    : state <= RTI4;
        RTI4    : state <= DECODE;

        RTS0    : state <= RTS1;
        RTS1    : state <= RTS2;
        RTS2    : state <= RTS3;
        RTS3    : state <= FETCH;

        BRA0    : state <= cond_true ? BRA1 : DECODE;
        BRA1    : state <= (CO ^ backwards) ? BRA2 : DECODE;
        BRA2    : state <= DECODE;

        JMP0    : state <= JMP1;
        JMP1    : state <= DECODE;

        JMPI0   : state <= JMPI1;
        JMPI1   : state <= JMP0;

        BRK0    : state <= BRK1;
        BRK1    : state <= BRK2;
        BRK2    : state <= BRK3;
        BRK3    : state <= JMP0;

    endcase

always @(posedge clk)
     if( reset )
         res <= 1;
     else if( state == DECODE )
         res <= 0;

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b0xx01010,
                8'b0xxxxx01,
                8'b100x10x0,
                8'b1010xxx0,
                8'b10111010,
                8'b1011x1x0,
                8'b11001010,
                8'b1x1xxx01,
                8'bxxx01000,
                /* illegal: SLO RLA SRE RRA (+ ANC ALR ARR imm) -> A */
                8'b0xxx_xx11,
                8'b1000_1011,   /* XAA #imm         -> A */
                8'b101x_xx11,   /* LAX (+$AB, $BB)  -> A (and X, via lax) */
                8'b1100_1011,   /* SBX #imm         -> X */
                8'b111x_xx11:   /* ISC (+SBC #$EB)  -> A */
                                load_reg <= 1;

                default:        load_reg <= 0;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b1110_1000,
                8'b1100_1010,
                8'b1100_1011,   /* SBX #imm (illegal) */
                8'b101x_xx10:
                                dst_reg <= SEL_X;

                8'b0x00_1000,
                8'b1001_1010:
                                dst_reg <= SEL_S;

                8'b1x00_1000,
                8'b101x_x100,
                8'b1010_x000:
                                dst_reg <= SEL_Y;

                default:        dst_reg <= SEL_A;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b1011_1010:
                                src_reg <= SEL_S;

                8'b100x_x110,
                8'b100x_1x10,
                8'b1110_xx00,
                8'b1100_1010:
                                src_reg <= SEL_X;

                8'b100x_x100,
                8'b1001_1000,
                8'b1100_xx00,
                8'b1x00_1000:
                                src_reg <= SEL_Y;

                default:        src_reg <= SEL_A;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'bxxx1_0001,
                8'b10x1_x110,
                8'bxxxx_1001,
                /* illegal: (zp),Y and abs,Y forms */
                8'bxxx1_0011,   /* $13 .. $F3  (zp),Y      */
                8'bxxx1_1011,   /* $1B .. $FB  abs,Y       */
                8'b10x1_0111,   /* $97 SAX zp,Y  $B7 LAX zp,Y */
                8'b10x1_1111:   /* $9F           $BF LAX abs,Y */
                                index_y <= 1;

                default:        index_y <= 0;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b100x_x1x0,
                8'b100x_xx01,
                /* illegal SAX: $83 $87 $8F $97 (and $93/$9F, whose unstable
                 * "& (H+1)" term we drop — they store plain A & X here) */
                8'b100x_0011,
                8'b100x_0111,
                8'b100x_1111:
                                store <= 1;

                default:        store <= 0;

        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                /* the illegal immediate column touches no memory */
                8'bxxx0_1011:   write_back <= 0;

                8'b0xxx_x110,
                8'b11xx_x110,
                8'b0xxx_xx11,   /* SLO RLA SRE RRA */
                8'b11xx_xx11:   /* DCP ISC         */
                                write_back <= 1;

                default:        write_back <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b101x_xxxx:
                                load_only <= 1;
                default:        load_only <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'bxxx0_1011:   inc <= 0;   /* illegal immediate column */

                8'b111x_x110,
                8'b11x0_1000,
                8'b111x_xx11:   /* ISC — the INC half */
                                inc <= 1;

                default:        inc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'b1110_1011:   adc_sbc <= 1;   /* SBC #imm (illegal alias) */
                8'bxxx0_1011:   adc_sbc <= 0;   /* rest of the imm column   */

                8'bx11x_xx01,
                8'bx11x_xx11:   /* RRA (ADC half) and ISC (SBC half) */
                                adc_sbc <= 1;

                default:        adc_sbc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'bxxx0_1011:   adc_bcd <= 0;   /* illegal immediate column */

                8'b011x_xx01,
                8'b011x_xx11:   /* RRA */
                                adc_bcd <= D;

                default:        adc_bcd <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0100_1011:   shift <= 1;   /* ALR — C from the LSR half */
                8'bxxx0_1011:   shift <= 0;   /* rest of the imm column    */

                8'b0xxx_x110,
                8'b0xxx_1010,
                8'b0xxx_xx11:   /* SLO RLA SRE RRA */
                                shift <= 1;

                default:        shift <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b1100_1011:   compare <= 1;   /* SBX #imm */
                8'bxxx0_1011:   compare <= 0;   /* rest of the imm column */

                8'b11x0_0x00,
                8'b11x0_1100,
                8'b110x_xx01,
                8'b110x_xx11:   /* DCP — the CMP half */
                                compare <= 1;

                default:        compare <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'bxxx0_1011:   shift_right <= 0;   /* imm column: ILL2 shifts */

                8'b01xx_xx10,
                8'b01xx_xx11:   /* SRE RRA */
                                shift_right <= 1;

                default:        shift_right <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'bxxx0_1011:   rotate <= 0;   /* illegal immediate column */

                8'b0x1x_1010,
                8'b0x1x_x110,
                8'b0x1x_xx11:   /* RLA RRA */
                                rotate <= 1;

                default:        rotate <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                /* illegal immediate column first — it must not fall into the
                 * cc=11 patterns added below */
                8'b0xx0_1011,           /* ANC $0B $2B, ALR $4B, ARR $6B */
                8'b1000_1011:           /* XAA $8B                       */
                                op <= OP_AND;

                8'b1100_1011,           /* SBX $CB */
                8'b1110_1011:           /* SBC $EB */
                                op <= OP_SUB;

                8'b1010_1011:           /* LAX #imm $AB */
                                op <= OP_ADD;

                8'b00xx_xx10,
                8'b00xx_xx11:   /* + SLO RLA: the ASL/ROL half */
                                op <= OP_ROL;

                8'b0010_x100:
                                op <= OP_AND;

                8'b01xx_xx10,
                8'b01xx_xx11:   /* + SRE RRA: the LSR/ROR half */
                                op <= OP_A;

                8'b1000_1000,
                8'b1100_1010,
                8'b110x_x110,
                8'b11xx_xx01,
                8'b110x_xx11,   /* DCP: the DEC half */
                8'b11x0_0x00,
                8'b11x0_1100:   op <= OP_SUB;

                8'b010x_xx01,
                8'b00xx_xx01:
                                op <= { 2'b11, IR[6:5] };

                default:        op <= OP_ADD;   /* + ISC: the INC half */
        endcase

/* ALU op for the FETCH pass of a combo op (only sampled when combo is set) */
always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b000x_xx11:   op2 <= OP_OR;    /* SLO -> ORA */
                8'b001x_xx11:   op2 <= OP_AND;   /* RLA -> AND */
                8'b010x_xx11:   op2 <= OP_EOR;   /* SRE -> EOR */
                8'b011x_xx11:   op2 <= OP_ADD;   /* RRA -> ADC */
                default:        op2 <= OP_SUB;   /* DCP -> CMP, ISC -> SBC */
        endcase

/* the remaining one-off illegal-opcode controls */
always @(posedge clk )
     if( state == DECODE && RDY ) begin
        ill   <= (IR[1:0] == 2'b11);
        anc   <= (IR == 8'h0B) || (IR == 8'h2B);
        arr   <= (IR == 8'h6B);
        alu2  <= (IR == 8'h4B) || (IR == 8'h6B);
        axand <= (IR == 8'h8B) || (IR == 8'hCB);
        casex( IR )
                8'b100x_0011,
                8'b100x_0111,
                8'b100x_1111:   sax <= 1;    /* SAX stores A & X */
                default:        sax <= 0;
        endcase
        casex( IR )
                8'b101x_xx11:   lax <= 1;    /* LAX also loads X */
                default:        lax <= 0;
        endcase
     end

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0010_x100:
                                bit_ins <= 1;

                default:        bit_ins <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY ) begin
        php <= (IR == 8'h08);
        clc <= (IR == 8'h18);
        plp <= (IR == 8'h28);
        sec <= (IR == 8'h38);
        cli <= (IR == 8'h58);
        sei <= (IR == 8'h78);
        clv <= (IR == 8'hb8);
        cld <= (IR == 8'hd8);
        sed <= (IR == 8'hf8);
        brk <= (IR == 8'h00);
     end

always @(posedge clk)
    if( RDY )
        cond_code <= IR[7:5];

always @*
    case( cond_code )
            3'b000: cond_true = ~N;
            3'b001: cond_true = N;
            3'b010: cond_true = ~V;
            3'b011: cond_true = V;
            3'b100: cond_true = ~C;
            3'b101: cond_true = C;
            3'b110: cond_true = ~Z;
            3'b111: cond_true = Z;
    endcase

reg NMI_1 = 0;

always @(posedge clk)
    NMI_1 <= NMI;

always @(posedge clk )
    if( NMI_edge && state == BRK3 )
        NMI_edge <= 0;
    else if( NMI & ~NMI_1 )
        NMI_edge <= 1;

endmodule
