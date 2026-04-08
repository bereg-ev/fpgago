
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

/* ── User-created mnemonic tables (managed by make copyarch/delarch) ── */
#include "user_mnemonics.inc"

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

  /* ── User-created architecture copies (managed by make copyarch/delarch) ── */
#include "user_archs.inc"
};

/* RISC2 load displacement: passed from archBeforeProcessLine to archAfterProcessLine.
 * 0xFFFFFFFF means no displacement (plain register addressing). */
static unsigned int risc2_load_disp = 0xFFFFFFFF;



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
