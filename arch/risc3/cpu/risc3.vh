// RISC3 ISA definitions
// 16-bit instruction width (with optional 16-bit IMM prefix for large constants)
// 16 x 32-bit general-purpose registers (R0-R15)
// Flags: Z (zero), C (carry), N (negative), V (overflow)
//
// Register conventions (same as RISC2):
//   R0-R3:  args/return values (caller-saved)
//   R4-R7:  temporaries (caller-saved)
//   R8-R13: callee-saved
//   R14:    SP (stack pointer, grows downward)
//   R15:    LR (link register, set by CALL)
//
// ─────────────────────────────────────────────────────────────────────────────
// INSTRUCTION FORMATS  (all 16-bit halfwords)
// ─────────────────────────────────────────────────────────────────────────────
//
// Format 00 — ALU reg-reg
//   [15:14] = 00
//   [13:10] = ALU opcode (4 bits)
//   [9:6]   = dst  (4 bits)
//   [5:2]   = src  (4 bits)
//   [1:0]   = 00   (disambiguates from Format 01)
//
// Format 01 — ALU reg-imm6
//   [15:14] = 01
//   [13:10] = ALU opcode (4 bits)
//   [9:6]   = dst  (4 bits)
//   [5:0]   = 6-bit signed immediate  (-32..31)
//             With IMM prefix: extended to 18-bit signed
//
// Format 10 — LOAD/STORE (normal)
//   [15:14] = 10
//   [13]    = 0=LOAD  1=STORE
//   [12:11] = size:  00=u32  01=u8  10=u16  11=SP-relative (see below)
//   [10:7]  = Rd (load dst) / Rs (store src)
//   [6:4]   = Rb (base register, R0-R7 only)
//   [3:0]   = 4-bit unsigned displacement, scaled by access size:
//               u32: disp×4  → 0,4,8,...,60  (16 offsets)
//               u16: disp×2  → 0,2,4,...,30  (16 offsets)
//               u8:  disp×1  → 0,1,2,...,15  (16 offsets)
//
// Format 10 — LOAD/STORE SP-relative  (size=11)
//   [15:14] = 10
//   [13]    = 0=LOAD  1=STORE  (always u32, word-aligned)
//   [12:11] = 11
//   [10:7]  = Rd / Rs
//   [6:0]   = 7-bit unsigned offset ×4  (0..508 bytes)
//
// Format 11-00 — Branch conditional
//   [15:12] = 1100
//   [11:8]  = condition code (see COND_* defines below)
//   [7:0]   = 8-bit signed offset in halfwords  (±128 halfwords = ±256 bytes)
//             With IMM prefix: extended to 20-bit offset (±512K halfwords = ±1 MB)
//
// Format 11-01 — Jump / Call / Return / System
//   [15:12] = 1101
//   [11:8]  = sub-opcode (see JSUB_* defines below)
//   [7:4]   = Rn (register operand)
//   [3:0]   = 0000
//
// Format 11-10 — PUSH / POP
//   [15:12] = 1110
//   [11:8]  = sub-opcode (see PSUB_* defines below)
//   [7:4]   = Rn
//   [3:0]   = 0000
//
// Format 11-11 — IMM prefix
//   [15:12] = 1111
//   [11:0]  = 12-bit upper extension
//   Applied to the NEXT instruction's immediate field: {imm12, next_imm}
//
// ─────────────────────────────────────────────────────────────────────────────
// ALU OPCODES  (4-bit, used in formats 00 and 01)
// ─────────────────────────────────────────────────────────────────────────────
`define ALU_MOV   4'h0   // dst = src/imm                     (no flags)
`define ALU_ADD   4'h1   // dst += src/imm                    (Z C N V)
`define ALU_SUB   4'h2   // dst -= src/imm                    (Z C N V)
`define ALU_AND   4'h3   // dst &= src/imm                    (Z N; C=V=0)
`define ALU_OR    4'h4   // dst |= src/imm                    (Z N; C=V=0)
`define ALU_XOR   4'h5   // dst ^= src/imm                    (Z N; C=V=0)
`define ALU_CMP   4'h6   // flags only, no write (SUB result) (Z C N V)
`define ALU_RCL   4'h7   // rotate carry left 1 bit           (C=old msb)
`define ALU_RCR   4'h8   // rotate carry right 1 bit          (C=old lsb)
`define ALU_SHL   4'h9   // dst <<= src/imm  logical          (Z C N; V=0)
`define ALU_SHR   4'hA   // dst >>= src/imm  logical          (Z N; C=last bit out)
`define ALU_SAR   4'hB   // dst >>= src/imm  arithmetic       (Z N; C=last bit out)
`define ALU_MUL   4'hC   // dst *= src/imm  (low 32 bits)     (Z N)
// 4'hD-4'hF reserved

// ─────────────────────────────────────────────────────────────────────────────
// BRANCH CONDITION CODES  [11:8] in format 11-00
// ─────────────────────────────────────────────────────────────────────────────
`define COND_JZ    4'h0   // Z=1            (equal / zero)
`define COND_JNZ   4'h1   // Z=0            (not equal / not zero)
`define COND_JC    4'h2   // C=1            (unsigned carry / borrow)
`define COND_JNC   4'h3   // C=0
`define COND_JN    4'h4   // N=1            (negative)
`define COND_JNN   4'h5   // N=0            (not negative)
`define COND_JV    4'h6   // V=1            (overflow)
`define COND_JNV   4'h7   // V=0
`define COND_JGE   4'h8   // N==V           (signed >=)
`define COND_JLT   4'h9   // N!=V           (signed <)
`define COND_JGT   4'hA   // !Z && (N==V)   (signed >)
`define COND_JLE   4'hB   // Z  || (N!=V)   (signed <=)
`define COND_JUGE  4'hC   // C=0            (unsigned >=)
`define COND_JULT  4'hD   // C=1            (unsigned <)
`define COND_CALL  4'hE   // always + R15=PC+2  (direct call, branch and link)
`define COND_JMP   4'hF   // always true    (unconditional branch)

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT 11-01 SUB-OPCODES  (Jump/Call/System)
// ─────────────────────────────────────────────────────────────────────────────
`define JSUB_JMP       4'h0   // JMP  Rn   — indirect jump (enables jump tables)
`define JSUB_CALL      4'h1   // CALL Rn   — indirect call; R15 = PC+2
`define JSUB_RET       4'h2   // RET       — jump to R15
`define JSUB_IRET      4'h3   // IRET      — restore saved PC+flags+priv
`define JSUB_NOP       4'h4   // NOP
`define JSUB_SLEEP     4'h5   // SLEEP     — low-power halt until next IRQ
`define JSUB_ENTERUSER 4'h6   // ENTERUSER Rn — privileged: priv=0, jump to Rn
// 4'h7-4'hF reserved

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT 11-10 SUB-OPCODES  (Push/Pop)
// ─────────────────────────────────────────────────────────────────────────────
`define PSUB_PUSH  4'h0   // PUSH Rn  — R14-=4; MEM[R14]=Rn
`define PSUB_POP   4'h1   // POP  Rn  — Rn=MEM[R14]; R14+=4
// 4'h2-4'hF reserved (future PUSHM/POPM)

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE STAGES
// ─────────────────────────────────────────────────────────────────────────────
`define STAGE_FETCH      3'h0
`define STAGE_DECODE     3'h1
`define STAGE_EXECUTE    3'h2
`define STAGE_MEMORY     3'h3
`define STAGE_WRITEBACK  3'h4
`define STAGE_IRQ        3'h5

// ─────────────────────────────────────────────────────────────────────────────
// MMU / PERIPHERAL MEMORY MAP  (0xF00000 region)
// ─────────────────────────────────────────────────────────────────────────────
// Existing RISC2 peripherals kept at same addresses.
// New MMU registers:
`define MMU_BASE_ADDR    24'hF00020   // [23:0] user process start address (R/W, privileged)
`define MMU_LIMIT_ADDR   24'hF00024   // [23:0] user process size           (R/W, privileged)
`define MMU_SAVEPC_ADDR  24'hF00028   // [23:0] IRQ-saved PC                (R,   kernel only)

// IRQ fault vectors (instruction addresses, must be in kernel ROM)
`define FAULT_MMU_DATA   24'h000018   // MMU data access violation
`define FAULT_MMU_CODE   24'h00001C   // MMU instruction fetch violation
`define FAULT_PRIV       24'h000020   // privileged instruction in user mode

// ─────────────────────────────────────────────────────────────────────────────
// INSTRUCTION FIELD EXTRACTORS  (for use in cpu_risc3.v)
// ─────────────────────────────────────────────────────────────────────────────
// instr = 16-bit instruction register
`define FMT(instr)       (instr[15:14])          // 2-bit format selector
`define ALU_OP(instr)    (instr[13:10])           // 4-bit ALU opcode
`define FLD_DST(instr)   (instr[9:6])             // 4-bit dst register
`define FLD_SRC(instr)   (instr[5:2])             // 4-bit src register (Format 00)
`define FLD_IMM6(instr)  ({instr[5:0]})           // 6-bit immediate    (Format 01, signed)
`define FLD_SIZE(instr)  (instr[12:11])           // 2-bit size
`define FLD_LDST(instr)  (instr[13])              // 0=load 1=store
`define FLD_RD(instr)    (instr[10:7])            // Rd/Rs in load/store (normal + SP-relative)
`define FLD_RB(instr)    (instr[6:4])             // base register (R0-R7)
`define FLD_DISP(instr)  (instr[3:0])             // 4-bit displacement
`define FLD_SPOFF(instr) (instr[6:0])             // 7-bit SP-relative offset
`define FLD_SPRD(instr)  (instr[10:7])            // Rd/Rs in SP-relative (same as FLD_RD)
`define FLD_COND(instr)  (instr[11:8])            // branch condition
`define FLD_BOFF(instr)  (instr[7:0])             // 8-bit branch offset (signed)
`define FLD_JSUB(instr)  (instr[11:8])            // jump/system sub-opcode
`define FLD_JRN(instr)   (instr[7:4])             // register operand in format 11-01/11-10
`define FLD_PSUB(instr)  (instr[11:8])            // push/pop sub-opcode
`define FLD_IMM12(instr) (instr[11:0])            // 12-bit IMM prefix

// Format 2-bit codes
`define FMT_ALU_RR  2'b00
`define FMT_ALU_RI  2'b01
`define FMT_MEM     2'b10
`define FMT_CTRL    2'b11

// Format 11 (ctrl) upper 2 bits [13:12]
`define CTRL_BRANCH 2'b00   // [15:12]=1100
`define CTRL_JUMP   2'b01   // [15:12]=1101
`define CTRL_PUSHPOP 2'b10  // [15:12]=1110
`define CTRL_IMM    2'b11   // [15:12]=1111
