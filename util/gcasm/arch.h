
#ifndef __ARCH_H__
#define __ARCH_H__

#define FLAG_ALU                1
#define FLAG_JUMP               2
#define FLAG_BYTE_WORD_DWORD    4
#define FLAG_JUMP22             8   /* signed branch with 22-bit offset (JGE/JLT) */

typedef struct
{
  char *name;
  unsigned int code;
  int numOperand;
  int flags;

} mnemonic_t;

typedef struct cpu_t
{
  char *name;
  int maxWordsInAsm;      // 4:  instruction + operand1 + comma + operand2
  mnemonic_t *mnemonics;
  int mnemonicNum;
  int pcIncrease;
  int regNum;
  int op_bitmask, op1_bitshift, op2_bitshift;
  int op2_reg_const_bitshift, op2_const_bitval;
  int jmp_bitmask, jmp_bitnum, jmp_bitshift;
  int const_bitsize, const_bitmask, const_bitshift;
  int instrByteSize;
  int bits;
} cpu_t;

typedef struct
{
  cpu_t cpu;
  int initialised;

} arch_t;

#define TRY(function, ...) { if (function) { printf("line %d: ", line->lineNum); printf(__VA_ARGS__); printf("\n"); exit(1); }}

int archBeforeProcessLine(cpu_t *cpu, mnemonic_t mnemonic, char **words, line_t *line);
void archAfterProcessLine(cpu_t *cpu, mnemonic_t mnemonic, char **words, line_t *line);

void archInit(arch_t *d, char *cpuName);

#endif
