/*
 * verilog model of 6502 CPU.
 *
 * (C) Arlet Ottens, <arlet@c-scape.nl>
 *
 * Feel free to use this code in any project (commercial or not), as long as you
 * keep this message, and the copyright notice. This code is provided "as is",
 * without any warranties of any kind.
 */

module cpu( clk, reset, AB, DI, DO, WE, IRQ, NMI, RDY );

input clk;
input reset;
output reg [15:0] AB;
input [7:0] DI;
output [7:0] DO;
output WE;
input IRQ;
input NMI;
input RDY;

reg  [15:0] PC;
reg  [7:0] ABL;
reg  [7:0] ABH;
wire [7:0] ADD;

reg  [7:0] DIHOLD;
reg  DIHOLD_valid;
wire [7:0] DIMUX;

reg  [7:0] IRHOLD;
reg  IRHOLD_valid;

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

wire [7:0] P = { N, V, 2'b11, D, I, Z, C };

reg [5:0] state;

reg PC_inc;
reg [15:0] PC_temp;

reg [1:0] src_reg;
reg [1:0] dst_reg;

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
    READ   = 6'd35,
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
    ZPX1   = 6'd49;

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
        FETCH,
        BRA0,
        BRA2,
        BRK3,
        JMPI1,
        JMP1,
        RTI4,
        RTS3:           PC_inc = 1;

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
        READ,
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

        JSR0,
        BRK0:    DO = PCH;

        JSR1,
        BRK1:    DO = PCL;

        PUSH1:   DO = php ? P : ADD;

        BRK2:    DO = (IRQ | NMI_edge) ? (P & 8'b1110_1111) : P;

        default: DO = regfile;
    endcase

always @*
    case( state )
        BRK0,
        BRK1,
        BRK2,
        JSR0,
        JSR1,
        PUSH1,
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
    if( write_register & RDY )
        AXYS[regsel] <= (state == JSR0) ? DIMUX : { ADD[7:4] + ADJH, ADD[3:0] + ADJL };

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
        READ:   alu_op = op;

        BRA1:   alu_op = backwards ? OP_SUB : OP_ADD;

        FETCH,
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
    if( state == FETCH || state == REG || state == READ )
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

        BRA0,
        READ:   AI = DIMUX;

        BRA1:   AI = ABH;

        FETCH:  AI = load_only ? 0 : regfile;

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
         READ,
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
         RTS0:  BI = 8'h00;

         BRA0:  BI = PCL;

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

        READ,
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
        if( adc_sbc | shift | compare )
            C <= CO;
        else if( plp )
            C <= ADD[0];
        else begin
            if( sec ) C <= 1;
            if( clc ) C <= 0;
        end
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
    if( state == RTI2 )
        V <= DIMUX[6];
    else if( state == DECODE ) begin
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

assign DIMUX = ~RDY ? DIHOLD : DI;

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
            endcase

        ZP0     : state <= write_back ? READ : FETCH;

        ZPX0    : state <= ZPX1;
        ZPX1    : state <= write_back ? READ : FETCH;

        ABS0    : state <= ABS1;
        ABS1    : state <= write_back ? READ : FETCH;

        ABSX0   : state <= ABSX1;
        ABSX1   : state <= (CO | store | write_back) ? ABSX2 : FETCH;
        ABSX2   : state <= write_back ? READ : FETCH;

        INDX0   : state <= INDX1;
        INDX1   : state <= INDX2;
        INDX2   : state <= INDX3;
        INDX3   : state <= FETCH;

        INDY0   : state <= INDY1;
        INDY1   : state <= INDY2;
        INDY2   : state <= (CO | store) ? INDY3 : FETCH;
        INDY3   : state <= FETCH;

        READ    : state <= WRITE;
        WRITE   : state <= FETCH;
        FETCH   : state <= DECODE;

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
                8'bxxx01000:
                                load_reg <= 1;

                default:        load_reg <= 0;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b1110_1000,
                8'b1100_1010,
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
                8'bxxxx_1001:
                                index_y <= 1;

                default:        index_y <= 0;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b100x_x1x0,
                8'b100x_xx01:
                                store <= 1;

                default:        store <= 0;

        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0xxx_x110,
                8'b11xx_x110:
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
                8'b111x_x110,
                8'b11x0_1000:
                                inc <= 1;

                default:        inc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'bx11x_xx01:
                                adc_sbc <= 1;

                default:        adc_sbc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'b011x_xx01:
                                adc_bcd <= D;

                default:        adc_bcd <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0xxx_x110,
                8'b0xxx_1010:
                                shift <= 1;

                default:        shift <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b11x0_0x00,
                8'b11x0_1100,
                8'b110x_xx01:
                                compare <= 1;

                default:        compare <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b01xx_xx10:
                                shift_right <= 1;

                default:        shift_right <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0x1x_1010,
                8'b0x1x_x110:
                                rotate <= 1;

                default:        rotate <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b00xx_xx10:
                                op <= OP_ROL;

                8'b0010_x100:
                                op <= OP_AND;

                8'b01xx_xx10:
                                op <= OP_A;

                8'b1000_1000,
                8'b1100_1010,
                8'b110x_x110,
                8'b11xx_xx01,
                8'b11x0_0x00,
                8'b11x0_1100:   op <= OP_SUB;

                8'b010x_xx01,
                8'b00xx_xx01:
                                op <= { 2'b11, IR[6:5] };

                default:        op <= OP_ADD;
        endcase

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
