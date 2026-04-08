
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "parse.h"
#include "arch.h"

mnemonic_t risc1_mnemonics[] = {
  {"nop", (int)0 << 14, 0, 0},
  {"out", (int)1 << 14, 2, 0},
  {"in", (int)2 << 14, 2, 0},

  {"jnz", ((int)3 << 14) + ((int)0 << 11), 1, FLAG_JUMP},
  {"jz",  ((int)3 << 14) + ((int)1 << 11), 1, FLAG_JUMP},
  {"jnc", ((int)3 << 14) + ((int)2 << 11), 1, FLAG_JUMP},
  {"jc",  ((int)3 << 14) + ((int)3 << 11), 1, FLAG_JUMP},
  {"jmp", ((int)3 << 14) + ((int)4 << 11), 1, FLAG_JUMP},
  {"call", ((int)3 << 14) + ((int)7 << 11), 1, FLAG_JUMP},
  {"ret", ((int)3 << 14) + ((int)6 << 11), 0, 0},

  {"mov", (int)7 << 14, 2, FLAG_ALU},
  {"and", (int)8 << 14, 2, FLAG_ALU},
  {"or" , (int)9 << 14, 2, FLAG_ALU},
  {"xor", (int)10 << 14, 2, FLAG_ALU},
  {"add", (int)11 << 14, 2, FLAG_ALU},
  {"sub", (int)12 << 14, 2, FLAG_ALU},
  {"rcl", (int)13 << 14, 2, FLAG_ALU},
  {"rcr", (int)14 << 14, 2, FLAG_ALU},
  {"cmp", (int)15 << 14, 2, FLAG_ALU},
};

mnemonic_t risc2_mnemonics[] = {
  {"nop", (unsigned int)0 << 27, 0, 0},
  {"load", (unsigned int)1 << 27, 2, FLAG_BYTE_WORD_DWORD},
  {"store", (unsigned int)2 << 27, 2, FLAG_BYTE_WORD_DWORD},

  {"jnz", ((unsigned int)3 << 27) + ((int)0 << 24), 1, FLAG_JUMP},
  {"jz",  ((unsigned int)3 << 27) + ((int)1 << 24), 1, FLAG_JUMP},
  {"jnc", ((unsigned int)3 << 27) + ((int)2 << 24), 1, FLAG_JUMP},
  {"jc",  ((unsigned int)3 << 27) + ((int)3 << 24), 1, FLAG_JUMP},
  {"jmp", ((unsigned int)3 << 27) + ((int)4 << 24), 1, FLAG_JUMP},
  {"call", ((unsigned int)3 << 27) + ((int)7 << 24), 1, FLAG_JUMP},
  /* Signed branches: reuse IRET slot [26:24]=101 with [23]=1, [22]=GE/LT, offset=[21:0] */
  {"jge", ((unsigned int)3 << 27) + ((int)5 << 24) + (1 << 23), 1, FLAG_JUMP22},
  {"jlt", ((unsigned int)3 << 27) + ((int)5 << 24) + (1 << 23) + (1 << 22), 1, FLAG_JUMP22},

  {"ret", ((unsigned int)3 << 27) + ((int)6 << 24), 0, 0},
  {"iret", ((unsigned int)3 << 27) + ((int)5 << 24), 0, 0},

  {"imm", (unsigned int)4 << 27, 1, 0},
  {"sleep", (unsigned int)5 << 27, 0, 0},

  {"imm", (unsigned int)4 << 27, 2, 0},
  {"sleep", (unsigned int)5 << 27, 0, 0},

  {"mov", (unsigned int)7 << 27, 2,  FLAG_ALU},
  {"and", (unsigned int)8 << 27, 2,  FLAG_ALU},
  {"or" , (unsigned int)9 << 27, 2,  FLAG_ALU},
  {"xor", (unsigned int)10 << 27, 2, FLAG_ALU},
  {"add", (unsigned int)11 << 27, 2, FLAG_ALU},
  {"sub", (unsigned int)12 << 27, 2, FLAG_ALU},
  {"rcl", (unsigned int)13 << 27, 2, FLAG_ALU},
  {"rcr", (unsigned int)14 << 27, 2, FLAG_ALU},
  {"cmp", (unsigned int)15 << 27, 2, FLAG_ALU},
};

/* ─────────────────────────────────────────────────────────────────────────
 * RISC3 ISA (16-bit instructions, 16 registers, 4 flags: Z C N V)
 *
 * Instruction formats:
 *   00: ALU reg-reg   [15:14]=00 [13:10]=op [9:6]=dst [5:2]=src [1:0]=00
 *   01: ALU reg-imm6  [15:14]=01 [13:10]=op [9:6]=dst [5:0]=imm6(signed)
 *   10: LOAD/STORE    [13]=L/S [12:11]=size [10]=sign [9:6]=Rd [5:2]=Rb [1:0]=disp
 *       SP-relative:  [13]=L/S [12:11]=11 [10:7]=Rd [6:0]=off7
 *   11-00: Branch     [15:12]=1100 [11:8]=cond [7:0]=off8(halfwords)
 *   11-01: Jump/Sys   [15:12]=1101 [11:8]=sub  [7:4]=Rn
 *   11-10: Push/Pop   [15:12]=1110 [11:8]=sub  [7:4]=Rn
 *   11-11: IMM prefix [15:12]=1111 [11:0]=imm12 (extends next instr's imm)
 *
 * Assembly syntax:
 *   ALU:         add r0, r1      add r0, #5
 *   LOAD:        load r0, (r1)   load r0, (r1+#4)
 *   LOAD typed:  load.b / load.sb / load.h / load.sh / load.sp
 *   STORE:       store (r1), r0  store (r1+#4), r0
 *   STORE typed: store.b / store.h / store.sp
 *   Branches:    jz lbl  jnz lbl  jge lbl  jlt lbl  jmp lbl (uncond)
 *   Indirect:    jmpi r0  calli r0  ret  iret  push r0  pop r0
 *   System:      enteruser r0  sleep  nop  imm #0x123
 * ───────────────────────────────────────────────────────────────────────── */

/* ALU op codes (4-bit) */
#define R3_MOV  0u
#define R3_ADD  1u
#define R3_SUB  2u
#define R3_AND  3u
#define R3_OR   4u
#define R3_XOR  5u
#define R3_CMP  6u
#define R3_RCL  7u
#define R3_RCR  8u
#define R3_SHL  9u
#define R3_SHR 10u
#define R3_SAR 11u
#define R3_MUL 12u

/* ALU base codes: Format 00 = [15:14]=00, [13:10]=alu_op */
#define R3_ALU(op)  ((unsigned int)(op) << 10)

/* Branch condition codes */
#define R3_JZ    0u
#define R3_JNZ   1u
#define R3_JC    2u
#define R3_JNC   3u
#define R3_JN    4u
#define R3_JNN   5u
#define R3_JV    6u
#define R3_JNV   7u
#define R3_JGE   8u
#define R3_JLT   9u
#define R3_JGT  10u
#define R3_JLE  11u
#define R3_JUGE 12u
#define R3_JULT 13u
#define R3_CALL 14u
#define R3_JMPX 15u   /* unconditional (condition always true) */

/* Branch base codes: Format 11-00 = [15:12]=1100 */
#define R3_BR(cond)  (0xC000u | ((unsigned int)(cond) << 8))

/* Jump/System sub-opcodes and base codes: Format 11-01 = [15:12]=1101 */
#define R3_JSUB_JMPI      0u
#define R3_JSUB_CALLI     1u
#define R3_JSUB_RET       2u
#define R3_JSUB_IRET      3u
#define R3_JSUB_NOP       4u
#define R3_JSUB_SLEEP     5u
#define R3_JSUB_ENTERUSER 6u
#define R3_JS(sub)   (0xD000u | ((unsigned int)(sub) << 8))

/* Push/Pop sub-opcodes and base codes: Format 11-10 = [15:12]=1110 */
#define R3_PSUB_PUSH 0u
#define R3_PSUB_POP  1u
#define R3_PP(sub)   (0xE000u | ((unsigned int)(sub) << 8))

mnemonic_t risc3_mnemonics[] = {
  /* ── ALU reg-reg / reg-imm (arch hook converts to Format 01 when '#' immediate) ── */
  {"mov",  R3_ALU(R3_MOV), 2, FLAG_ALU},
  {"add",  R3_ALU(R3_ADD), 2, FLAG_ALU},
  {"sub",  R3_ALU(R3_SUB), 2, FLAG_ALU},
  {"and",  R3_ALU(R3_AND), 2, FLAG_ALU},
  {"or",   R3_ALU(R3_OR),  2, FLAG_ALU},
  {"xor",  R3_ALU(R3_XOR), 2, FLAG_ALU},
  {"cmp",  R3_ALU(R3_CMP), 2, FLAG_ALU},
  {"rcl",  R3_ALU(R3_RCL), 2, FLAG_ALU},
  {"rcr",  R3_ALU(R3_RCR), 2, FLAG_ALU},
  {"shl",  R3_ALU(R3_SHL), 2, FLAG_ALU},
  {"shr",  R3_ALU(R3_SHR), 2, FLAG_ALU},
  {"sar",  R3_ALU(R3_SAR), 2, FLAG_ALU},
  {"mul",  R3_ALU(R3_MUL), 2, FLAG_ALU},

  /* ── LOAD (re-encoded entirely in archAfterProcessLine) ── */
  /* All load variants share the same mnemonic.code placeholder 0x8000;
   * archAfterProcessLine identifies the variant from the mnemonic name. */
  {"load",    0x8000u, 2, 0},   /* u32, base+disp4                */
  {"load.b",  0x8000u, 2, 0},   /* u8  zero-extend                */
  {"load.h",  0x8000u, 2, 0},   /* u16 zero-extend                */
  {"load.sp", 0x8000u, 2, 0},   /* SP-relative u32, off7*4        */

  /* ── STORE (re-encoded in archAfterProcessLine, operands swapped in Before) ── */
  {"store",    0xA000u, 2, 0},  /* u32, base+disp2                */
  {"store.b",  0xA000u, 2, 0},  /* u8                             */
  {"store.h",  0xA000u, 2, 0},  /* u16                            */
  {"store.sp", 0xA000u, 2, 0},  /* SP-relative u32, off7*4        */

  /* ── Conditional branches (FLAG_JUMP → processJump fills [7:0] offset) ── */
  {"jz",   R3_BR(R3_JZ),   1, FLAG_JUMP},
  {"jnz",  R3_BR(R3_JNZ),  1, FLAG_JUMP},
  {"jc",   R3_BR(R3_JC),   1, FLAG_JUMP},
  {"jnc",  R3_BR(R3_JNC),  1, FLAG_JUMP},
  {"jn",   R3_BR(R3_JN),   1, FLAG_JUMP},
  {"jnn",  R3_BR(R3_JNN),  1, FLAG_JUMP},
  {"jv",   R3_BR(R3_JV),   1, FLAG_JUMP},
  {"jnv",  R3_BR(R3_JNV),  1, FLAG_JUMP},
  {"jge",  R3_BR(R3_JGE),  1, FLAG_JUMP},
  {"jlt",  R3_BR(R3_JLT),  1, FLAG_JUMP},
  {"jgt",  R3_BR(R3_JGT),  1, FLAG_JUMP},
  {"jle",  R3_BR(R3_JLE),  1, FLAG_JUMP},
  {"juge", R3_BR(R3_JUGE), 1, FLAG_JUMP},
  {"jult", R3_BR(R3_JULT), 1, FLAG_JUMP},
  {"call", R3_BR(R3_CALL), 1, FLAG_JUMP},
  {"jmp",  R3_BR(R3_JMPX), 1, FLAG_JUMP},   /* unconditional (cond=0xF = always) */

  /* ── Indirect jump/call (1 register operand; arch hook moves reg to [7:4]) ── */
  {"jmpi",     R3_JS(R3_JSUB_JMPI),      1, 0},  /* JMP  Rn (indirect)       */
  {"calli",    R3_JS(R3_JSUB_CALLI),     1, 0},  /* CALL Rn (indirect)       */
  {"ret",      R3_JS(R3_JSUB_RET),       0, 0},
  {"iret",     R3_JS(R3_JSUB_IRET),      0, 0},
  {"nop",      R3_JS(R3_JSUB_NOP),       0, 0},
  {"sleep",    R3_JS(R3_JSUB_SLEEP),     0, 0},
  {"enteruser",R3_JS(R3_JSUB_ENTERUSER), 1, 0},  /* privileged; arch fixes reg pos */

  /* ── Push / Pop (arch hook moves reg to [7:4]) ── */
  {"push", R3_PP(R3_PSUB_PUSH), 1, 0},
  {"pop",  R3_PP(R3_PSUB_POP),  1, 0},

  /* ── IMM prefix (arch hook re-encodes imm12 at [11:0]) ── */
  {"imm",  0xF000u, 1, 0},
};

cpu_t cpus[] = {
  { "risc1", "risc1", 4, risc1_mnemonics, sizeof(risc1_mnemonics) / sizeof(mnemonic_t),
    1,              // the Program Counter gets incremented by this
    16, 0x0f,       // 16 registers and bitmask for its 4 bit references
    9, 0,           // operand-1 and operand-2 bitshifts within the instruction word
    13, 1,          // indication of const operand-2 is bit 13, and "1" means constant, "0" means register
    0x7ff, 11, 0,   // 11 bit signed relative jump addr with 0 shift within the instruction word
    8, 0xff, 0,     // 8 bit constants at the bottom of the opcode
    3,               // 18-bit instructions (single 1Kx18 ROM, not split)
    8,               // 8-bit cpu
  },

  { "risc2", "risc2", 4, risc2_mnemonics, sizeof(risc2_mnemonics) / sizeof(mnemonic_t),
    4,              // the Program Counter gets incremented by this
    16, 0x0f,       // 16 registers and bitmask for its 4 bit references
    20, 16,         // operand-1 and operand-2 bitshifts within the instruction word
    26, 1,          // indication of const operand-2 is bit 26, and "1" means constant, "0" means register
    0xffffff, 24, 0,// 11 bit signed relative jump addr with 0 shift within the instruction word
    20, 0xfffff, 0, // 8 bit constants at the bottom of the opcode
    4,               // 32 bit instructions
    32,              // 32-bit cpu
  },

  /* RISC3 — 16-bit instructions, 16 registers, Z/C/N/V flags */
  { "risc3", "risc3", 4, risc3_mnemonics, sizeof(risc3_mnemonics) / sizeof(mnemonic_t),
    1,              // pcIncrease: pc counts in 16-bit halfword units (1 per instruction)
    16, 0x0f,       // 16 registers, 4-bit register field mask
    6, 2,           // op1_bitshift=6 (dst at [9:6]),  op2_bitshift=2 (src at [5:2])
    14, 1,          // const indicator: set bit 14 to 1 → makes [15:14]=01 (Format 01 immediate)
    0xff, 8, 0,     // branch offset: 8-bit at [7:0], signed halfword offset
    6, 0x3f, 0,     // 6-bit immediate at [5:0]
    2,              // 16-bit instructions (2 bytes each)
    32,             // 32-bit registers
  },

  /* ── User-created architecture copies (managed by make copyarch/delarch) ── */
#include "user_archs.inc"
};

/* RISC2 load displacement: passed from archBeforeProcessLine to archAfterProcessLine.
 * 0xFFFFFFFF means no displacement (plain register addressing). */
static unsigned int risc2_load_disp = 0xFFFFFFFF;

/* RISC3 memory displacement (in bytes): passed between arch hook calls.
 * 0xFFFFFFFF = no displacement provided (use 0). */
static unsigned int risc3_mem_disp = 0xFFFFFFFF;

/* ── Helper: parse a hex constant string.
 * The assembler convention is bare hex digits after '#' (e.g. "#3F" = 63).
 * Also accepts the "0x" prefix for convenience in arch-hook calls. ── */
static int parseImm(const char *s, unsigned int *out)
{
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    return hex2bin((char*)s + 2, out);
  return hex2bin((char*)s, out);
}

/* ── Helper: parse register number from "rN" or "rNN" string ── */
static unsigned int regFromStr(const char *s)
{
  unsigned int r = (unsigned int)(s[1] - '0');
  if (s[2] != '\0') r = r * 10 + (unsigned int)(s[2] - '0');
  return r & 0xFu;
}

int archBeforeProcessLine(cpu_t *cpu, mnemonic_t mnemonic, char **words, line_t *line)
{
  char *tmp;

  /* ── RISC1 ── */
  if (!strcmp(cpu->base_isa, "risc1") && !strcmp(words[0], "out"))
  {
    tmp = words[1];
    words[1] = words[3];
    words[3] = tmp;
  }

  /* ── RISC2 ── */
  if (!strcmp(cpu->base_isa, "risc2") && !strncmp(line->words[0], "store", 5))
  {
    tmp = words[1];
    words[1] = words[3];
    words[3] = tmp;
  }

  risc2_load_disp = 0xFFFFFFFF;
  if (!strcmp(cpu->base_isa, "risc2") && !strncmp(words[0], "load", 4) && line->wordNum >= 4)
  {
    char *plus = strchr(words[3], '+');
    if (plus != NULL && plus[1] == '#')
    {
      hex2bin(plus + 2, &risc2_load_disp);
      *plus = 0;
    }
  }

  /* ── RISC3 ── */
  if (!strcmp(cpu->base_isa, "risc3"))
  {
    risc3_mem_disp = 0;   /* default: zero displacement */

    /* STORE: swap operands so word[1]=data_reg, word[3]=addr_expr
     * Syntax: store (base[+#disp]), src  →  after swap: src, (base[+#disp]) */
    if (!strncmp(words[0], "store", 5) && (strncmp(words[0], "store.sp", 8) != 0)
        && line->wordNum >= 4)
    {
      tmp = words[1];
      words[1] = words[3];
      words[3] = tmp;
    }

    /* LOAD / STORE: split "rN+#disp" in the memory operand (word[3]) */
    if (((!strncmp(words[0], "load", 4) && strcmp(words[0], "load.sp"))
      || (!strncmp(words[0], "store", 5) && strcmp(words[0], "store.sp")))
      && line->wordNum >= 4)
    {
      char *plus = strchr(words[3], '+');
      if (plus != NULL && plus[1] == '#')
      {
        parseImm(plus + 2, &risc3_mem_disp);
        *plus = 0;  /* truncate to base register name */
      }
    }
  }

  return 1;
}

void archAfterProcessLine(cpu_t *cpu, mnemonic_t mnemonic, char **words, line_t *line)
{
  /* ── RISC2 ── */
  if (!strcmp(cpu->base_isa, "risc2"))
  {
    if (!strcmp(words[0], "imm"))
    {
      unsigned int c = (line->binary >> cpu->const_bitshift) & cpu->const_bitmask;
      TRY(line->words[1][0] != '#', "const operand needed for imm instruction");
      TRY(c > 0xfff, "imm constant bigger than 12 bits");
    }
    else if ((mnemonic.flags & FLAG_BYTE_WORD_DWORD) != 0)
    {
      line->binary |= ((line->byteWordDword & 3) << 24);
    }

    if (!strncmp(words[0], "load", 4) && risc2_load_disp != 0xFFFFFFFF)
    {
      line->binary |= (risc2_load_disp & 0xffff);
    }
    return;
  }

  /* ── RISC3 ── */
  if (!strcmp(cpu->base_isa, "risc3"))
  {
    const char *mn = words[0];   /* mnemonic string as written by programmer */

    /* ── IMM prefix: re-encode 12-bit immediate at [11:0] ── */
    if (!strcmp(mn, "imm"))
    {
      unsigned int imm12 = 0;
      TRY(words[1][0] != '#', "imm: constant operand '#' expected");
      TRY(parseImm(words[1] + 1, &imm12) < 0, "imm: invalid constant");
      TRY(imm12 > 0xFFF, "imm: constant exceeds 12 bits");
      line->binary = 0xF000u | (imm12 & 0xFFFu);
      return;
    }

    /* ── LOAD ── */
    if (!strncmp(mn, "load", 4))
    {
      /* Rd is always words[1]. Rb was placed at [5:2] by generic code; extract it.
       * For load.sp the const in words[3] wipes [9:6]
       * via processConstOperand, so always parse Rd from the word directly. */
      unsigned int Rd = regFromStr(words[1]);
      unsigned int Rb = (line->binary >> 2) & 0xFu;
      unsigned int size = 0, disp_field = 0;

      if (!strcmp(mn, "load.sp"))
      {
        /* SP-relative: [15:14]=10, [13]=0=LOAD, [12:11]=11, [10:7]=Rd, [6:0]=off7 */
        unsigned int off7 = 0;
        if (words[3][0] == '#') parseImm(words[3] + 1, &off7);
        TRY(off7 > 127, "load.sp: offset out of range (0-127)");
        line->binary = 0x8000u | (3u << 11) | (Rd << 7) | off7;
        return;
      }

      /* Determine size from mnemonic suffix (sign-extend removed from encoding) */
      if      (!strcmp(mn, "load"))    { size=0; }
      else if (!strcmp(mn, "load.b"))  { size=1; }
      else if (!strcmp(mn, "load.sb")) { size=1; }
      else if (!strcmp(mn, "load.h"))  { size=2; }
      else if (!strcmp(mn, "load.sh")) { size=2; }

      TRY(Rb > 7, "load: base register must be R0-R7");

      /* Compute scaled 4-bit displacement field from risc3_mem_disp (bytes) */
      if (risc3_mem_disp != 0)
      {
        unsigned int scale = (size == 0) ? 4u : (size == 2) ? 2u : 1u;
        disp_field = risc3_mem_disp / scale;
        TRY(disp_field > 15, "load: displacement out of range (max 60 for u32, 30 for u16, 15 for u8)");
        TRY(risc3_mem_disp % scale != 0, "load: displacement not aligned to access size");
      }

      /* Format 10: [15:14]=10 [13]=0=LOAD [12:11]=size [10:7]=Rd [6:4]=Rb [3:0]=disp */
      line->binary = 0x8000u | (0u << 13) | (size << 11)
                     | (Rd << 7) | (Rb << 4) | disp_field;
      return;
    }

    /* ── STORE ── */
    if (!strncmp(mn, "store", 5))
    {
      /* After operand swap (normal store): word[1]=Rs (data reg), word[3]=Rb (base reg).
       * store.sp has no swap: word[1]=Rs, word[3]=#off7.
       * Rs is always in words[1]; read it directly to avoid processConstOperand clobbering [9:6]. */
      unsigned int Rs = regFromStr(words[1]);
      unsigned int Rb = (line->binary >> 2) & 0xFu;
      unsigned int size = 0, disp_field = 0;

      if (!strcmp(mn, "store.sp"))
      {
        /* SP-relative: [15:14]=10, [13]=1=STORE, [12:11]=11, [10:7]=Rs, [6:0]=off7 */
        unsigned int off7 = 0;
        if (words[3][0] == '#') parseImm(words[3] + 1, &off7);
        TRY(off7 > 127, "store.sp: offset out of range (0-127)");
        line->binary = 0x8000u | (1u << 13) | (3u << 11) | (Rs << 7) | off7;
        return;
      }

      if      (!strcmp(mn, "store"))   { size = 0; }
      else if (!strcmp(mn, "store.b")) { size = 1; }
      else if (!strcmp(mn, "store.h")) { size = 2; }

      TRY(Rb > 7, "store: base register must be R0-R7");

      if (risc3_mem_disp != 0)
      {
        unsigned int scale = (size == 0) ? 4u : (size == 2) ? 2u : 1u;
        disp_field = risc3_mem_disp / scale;
        TRY(disp_field > 15, "store: displacement out of range (max 60 for u32, 30 for u16, 15 for u8)");
        TRY(risc3_mem_disp % scale != 0, "store: displacement not aligned to access size");
      }

      /* Format 10: [15:14]=10 [13]=1=STORE [12:11]=size [10:7]=Rs [6:4]=Rb [3:0]=disp */
      line->binary = 0x8000u | (1u << 13) | (size << 11)
                     | (Rs << 7) | (Rb << 4) | disp_field;
      return;
    }

    /* ── Single-register operand instructions: move register from [5:2] to [7:4] ──
     * Applies to: jmpi, calli, enteruser, push, pop
     * (Generic code placed the register at op2_bitshift=2 → bits [5:2]) */
    {
      unsigned int top4 = line->binary & 0xF000u;
      if (top4 == 0xD000u || top4 == 0xE000u)
      {
        /* Format 11-01 (Jump/System) or 11-10 (Push/Pop) */
        unsigned int reg = (line->binary >> 2) & 0xFu;
        line->binary &= ~(0xFu << 2);    /* clear [5:2] */
        line->binary |=  (reg  << 4);    /* put at [7:4] */
        /* Ensure [3:0] = 0000 and [15:12] are correct (from mnemonic base code) */
        line->binary &= 0xFF0u | 0xF000u; /* keep [15:8], clear [7:0] then set [7:4] */
        line->binary  = (mnemonic.code & 0xFF00u) | (reg << 4);
        return;
      }
    }

    /* ALU instructions: generic code already handles them correctly (Format 00 for
     * reg-reg, Format 01 for reg-imm via the bit-14 const-indicator).
     * Nothing extra needed for normal ALU ops.
     * Conditional branches: processJump (pass 2) fills [7:0] offset. */
  }
}

void archInit(arch_t *d, char *cpuName)
{
  unsigned long i;

  memset((void*)d, 0, sizeof(arch_t));

  for (i = 0; i < sizeof(cpus) / sizeof(cpu_t); i++)
  {
    if (!strcmp(cpuName, cpus[i].name))
    {
      d->initialised = 1;
      d->cpu = cpus[i];
      return;
    }
  }

  printf("unknown cpu: %s\n", cpuName);
  exit(1);
}
