
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "parse.h"
#include "compile.h"

void printLine(line_t *line, char *pre, char *post)
{
  int i;

  printf("%s", pre);

  for (i = 0; i < line->wordNum; i++)
    printf("%s ", line->words[i]);

  printf("%s", post);
}

mnemonic_t getOpcode(compile_t *d, line_t *line, char *s)
{
  int i;
  mnemonic_t *m = d->arch.cpu.mnemonics;

  line->byteWordDword = TYPE_DWORD;

  /* Pass 1: exact match (must come before size-suffix detection so that
   * mnemonics like "load.sp" or "store.h" are found before "load"+"p" is
   * misinterpreted as a size-suffix variant). */
  for (i = 0; i < d->arch.cpu.mnemonicNum; i++)
  {
    if (!strcmp(m[i].name, s))
      return m[i];
  }

  /* Pass 2: size-suffix match  ("<mnem>.<b|w|d>") */
  for (i = 0; i < d->arch.cpu.mnemonicNum; i++)
  {
    int len = strlen(s);

    if (len > 2 && s[len - 2] == '.')
    {
      if (memcmp(m[i].name, s, len - 2))
        continue;

      TRY((m[i].flags & FLAG_BYTE_WORD_DWORD) == 0, "byte/word/dword type not allowed");

      switch (s[len - 1])
      {
        case 'b': case 'B': line->byteWordDword = TYPE_BYTE; break;
        case 'w': case 'W': line->byteWordDword = TYPE_WORD; break;
        case 'd': case 'D': line->byteWordDword = TYPE_DWORD; break;
        default: TRY(1, "invalid type modifier"); break;
      }

      return m[i];
    }
  }

  printf("line %d: unknown mnemonic %s\n", line->lineNum, s);
  exit(1);
}

label_t *findLabel(char *s, label_t *from)
{
  while (from)
  {
		if (!strcmp(from->name, s))
	    return from;

		from = from->next;
  }

  return NULL;
}

void allocateNewLabel(compile_t *d, line_t *line, char *s)
{
  label_t *labeltmp;

  s[strlen(s) - 1] = 0;
  strncpy(&line->labelName[0], s, 63);
//  printf("label found: %s\n", s);

  TRY((labeltmp = findLabel(s, d->labels)) != NULL, "label \"%s\" already defined in line %d", s, labeltmp->lineNum)

  labeltmp = (label_t*)malloc(sizeof(label_t));
  labeltmp->pc = d->pc;
  labeltmp->lineNum = line->lineNum;
  strncpy(labeltmp->name, s, 127);
  labeltmp->next = d->labels;
  d->labels = labeltmp;
}

int handleLabel(compile_t *d, line_t *line)
{
  unsigned long i;

  if (line->words[0][strlen(line->words[0]) - 1] == ':')
  {
    allocateNewLabel(d, line, line->words[0]);
    line->label = 1;

    for (i = 0; i < sizeof(line->words) / sizeof(char*) - 1; i++)
      line->words[i] = line->words[i + 1];

    if (--line->wordNum == 0)
      return 1;
  }

  return 0;
}

void addDirectByte(compile_t *d, line_t *line, unsigned char c)
{
  line->directDwords[line->directBytesValid / 4] |= ((c & 0xff) << (8 * (3 - (line->directBytesValid % 4))));
  line->directBytesValid++;

  if ((line->directBytesValid % 4) == 0)
    d->pc += 1;
}

int handleDirectBytes(compile_t *d, line_t *line, line_t *prev_line)
{
  line_t *output_line = line;
  const char* types[3] = {".dd", ".db", ".dw"};
  int i, type = -1;

  if (line->words[0][0] != '.')
    return 0;

  for (i = 0; i < 3; i++)
    if (!strcmp(line->words[0], types[i]))
      type = i;

  TRY(type == -1, "unknown keyword %s", line->words[0]);

  if (prev_line && (prev_line->directBytesValid % 4) != 0)
  {
    TRY(type == 0, "not aligned to 4 bytes boundary")
    TRY(type == 2 && (prev_line->directBytesValid % 4) != 2, "not aligned to 2 bytes boundary")
    output_line = prev_line;
    line->skipLine = 1;
  }

  line->pc = d->pc;

  for (i = 1; i < line->wordNum; i++)
  {
    unsigned int c, strLen;
    char *strVal;

    if ((i % 2) == 1)
    {
      int res = parseDirectBytes(&line->words[i][0], &c, &strLen, &strVal);
      TRY(res < 0, "invalid constant %s", line->words[i])
      TRY(c > 255 && type == TYPE_BYTE, "byte constant is too large: %s", line->words[i])
      TRY(c > 0xffff && type == TYPE_WORD, "word constant is too large: %s", line->words[i])

      if ((output_line->directBytesValid % 4) == 0)
        output_line->directDwords[line->directBytesValid / 4] = 0;

      if (type == TYPE_DWORD)
      {
        output_line->directDwords[output_line->directBytesValid / 4] = c;
        output_line->directBytesValid += 4;
        d->pc += 1;
      }
      else if (type == TYPE_WORD)
      {
        output_line->directDwords[output_line->directBytesValid / 4] |= ((c & 0xffff) << (8 * (2 - (output_line->directBytesValid % 4))));
        output_line->directBytesValid += 2;

        if ((output_line->directBytesValid % 4) == 0)
          d->pc += 1;
      }
      else if (type == TYPE_BYTE)
      {
        if (strLen)
        {
          for (unsigned int i = 0; i < strLen; i++)
            addDirectByte(d, output_line, strVal[i]);

          addDirectByte(d, output_line, 0);
        }
        else
          addDirectByte(d, output_line, c);
      }
    }
    else
    {
      TRY(strcmp(line->words[i], ","), "no comma after %s", line->words[i - 1])
    }
  }

  return 1;
}

void handleOpcodeAndOperandNum(compile_t *d, line_t *line)
{
  d->mnemonic = getOpcode(d, line, line->words[0]);
  line->binary = d->mnemonic.code;
  int numOp = d->mnemonic.numOperand;
  int reqWordNum = 1 + (numOp == 0 ? 0 : (numOp == 1 ? 1 : (numOp == 2 ? 3 : 99)));

  TRY(line->wordNum < reqWordNum, "missing operand")
  TRY(line->wordNum > reqWordNum, "too many operands or missing ';' comment separator")
}

void processRegOperand(compile_t *d, line_t *line, char *s, int bitshift)
{
  TRY(s[0] != 'r' || (s[1] < '0' && s[1] > '9') || (strlen(s) == 3 && (s[1] < '0' && s[1] > '9') || strlen(s) > 3) ,
    "invalid register: %s", s)

  int regId = s[1] - '0';

  if (s[2] != 0)
    regId = 10 * regId + s[2] - '0';

  line->binary &= ~(d->cpu.op_bitmask << bitshift);
  line->binary |= ((regId & d->cpu.op_bitmask) << bitshift);
}

void setConstOperand(compile_t *d, line_t *line)
{
  if (d->cpu.op2_const_bitval)      // set 1 as indication of constant operand
    line->binary |= ((int)1 << d->cpu.op2_reg_const_bitshift);
  else                            // set 0 as indication of constant operand
    line->binary &= ~((int)1 << d->cpu.op2_reg_const_bitshift);
}

void processConstOperand(compile_t *d, line_t *line, char *s)
{
  unsigned int c;
  int res;

  if (s[0] == '\'' && s[2] == '\'') {
    /* Character literal: 'X' */
    c = (unsigned int)(unsigned char)s[1];
    res = 0;
  } else {
    res = hex2bin(&s[1], &c);
  }

  TRY((s[0] != '#' && s[0] != '\'') || res < 0, "invalid constant: %s", s)
  TRY(c > 255 && d->cpu.bits == 8, "constant is %s bigger than 8 bits", s)
  TRY(c > 65535 && d->cpu.bits == 16, "constant is %s bigger than 16 bits", s)
  line->binary &= ~(d->cpu.const_bitmask << d->cpu.const_bitshift);
  line->binary |= ((c & d->cpu.const_bitmask) << d->cpu.const_bitshift);
  setConstOperand(d, line);
}

void processJump(compile_t *d, line_t *line)
{
  label_t *labeltmp;
  char *s = line->words[1];

  TRY((labeltmp = findLabel(s, d->labels)) == 0, "label \"%s\" not found in pass2", s)

  int mask = (d->mnemonic.flags & FLAG_JUMP22) ? 0x3fffff : d->cpu.jmp_bitmask;
  line->binary &= ~(mask << d->cpu.jmp_bitshift);
  line->binary |= ((((labeltmp->pc - line->pc) * d->cpu.pcIncrease) & mask) << d->cpu.jmp_bitshift);
}

void processOffset(compile_t *d, line_t *line)
{
  label_t *labeltmp;
  char *s = &line->words[3][1];

  TRY((labeltmp = findLabel(s, d->labels)) == 0, "label \"%s\" not found in pass2", s)

  line->binary &= ~(d->cpu.const_bitmask << d->cpu.const_bitshift);
  TRY(((labeltmp->pc * d->cpu.pcIncrease) & d->cpu.jmp_bitmask) != labeltmp->pc * d->cpu.pcIncrease, "offset operand too big")
  line->binary |= ((labeltmp->pc  * d->cpu.pcIncrease) << d->cpu.const_bitshift);
}

void compileLine(compile_t *d, line_t *line, line_t *prev_line)
{
  line->pc = d->pc;

  if (line->wordNum == 0)
    return;

//  parseDebugLine(line);

  if (handleDirectBytes(d, line, prev_line))
    return;

  if (prev_line && (prev_line->directBytesValid % 4) != 0)
  {
//    printLine(line, "BUG ", "\n");
    prev_line->directBytesValid += (4 - (prev_line->directBytesValid % 4));
    line->pc++;
    d->pc++;
  }

  if (handleLabel(d, line))
    return;

  if (archBeforeProcessLine(&d->cpu, d->mnemonic, &line->words[0], line))
  {
    handleOpcodeAndOperandNum(d, line);
    TRY(line->wordNum == 4 && strcmp(line->words[2], ","), "missing \";\" between operand 1 and 2")

    if (d->mnemonic.numOperand == 1)
    {
      if ((d->mnemonic.flags & (FLAG_JUMP | FLAG_JUMP22)) == 0)      // cannot handle jumps here, but in pass 2 when we have all the labels
      {
        if (line->words[1][0] == '#' || line->words[1][0] == '\'')
          processConstOperand(d, line, line->words[1]);
        else
          processRegOperand(d, line, line->words[1], d->cpu.op2_bitshift);
      }
    }

    if (d->mnemonic.numOperand == 2)
    {
      processRegOperand(d, line, line->words[1], d->cpu.op1_bitshift);

      if (line->words[3][0] == '#' || line->words[3][0] == '\'')
        processConstOperand(d, line, line->words[3]);
      else if (line->words[3][0] == '@')
      {
        TRY((d->mnemonic.flags & FLAG_ALU) == 0, "offset operand is not allowed");
        setConstOperand(d, line);
        line->offsetOperand = 1;   // do nothing mode here: calculate the address later in pass2
      }
      else
        processRegOperand(d, line, line->words[3], d->cpu.op2_bitshift);
    }

    archAfterProcessLine(&d->arch.cpu, d->mnemonic, &line->words[0], line);
    line->binaryValid = 1;
    d->pc += 1; // d->cpu.pcIncrease;
  }

//  printf("%.5x    ", line->binary);
//  printLine(d, line, "", "\n");
}

void compilePass1(compile_t *d)
{
  line_t *line = d->parse.lineFirst, *prev_line = NULL;

  for (line = d->parse.lineFirst; line != 0; line = line->next)
  {
    if (line->wordNum == 0)
      continue;

    compileLine(d, line, prev_line);

    if (!line->skipLine)
      prev_line = line;
  }
}

void compilePass2(compile_t *d)
{
  line_t *line = d->parse.lineFirst;

  for (line = d->parse.lineFirst; line != 0; line = line->next)
  {
    if (!line->binaryValid)
      continue;

    d->mnemonic = getOpcode(d, line, line->words[0]);

    if (line->offsetOperand)
      processOffset(d, line);

    if ((d->mnemonic.flags & (FLAG_JUMP | FLAG_JUMP22)) != 0)
      processJump(d, line);
  }
}

void compileWriteInitLines(FILE *f, unsigned int* mem, int mode, int wordOffset)
{
  for (int paramNum = 0; paramNum < 64; paramNum++)
  {
    fprintf(f, ".init_%.2x(320'h", paramNum);

    for (int i = 0; i < 16; i++)
    {
      unsigned int bin = mem[wordOffset + paramNum * 16 + 15 - i];
      unsigned int w;
      if (mode & MODE_FULL_18_BITS)
        w = bin & 0x3ffff;
      else if (mode & MODE_LOWER_16_BITS)
        w = bin & 0xffff;
      else
        w = (bin >> 16) & 0xffff;

      fprintf(f, "%.5x", w);
    }

    fprintf(f, ")");

      if (paramNum != 63)
      fprintf(f, ",");

    fprintf(f, "\n");
  }

  fclose(f);
}

void compileStart(compile_t *d)
{
  FILE *fLo, *fHi, *fBin, *fHex;
  unsigned int mem[8192];
  int bit32 = d->cpu.instrByteSize == 4;
  int bit16 = d->cpu.instrByteSize == 2;   /* RISC3: 16-bit instructions packed 2-per-word */
  int bit18 = d->cpu.instrByteSize == 3;   /* RISC1: 18-bit instructions, single 1Kx18 ROM */

  for (int i = 0; i < 8192; i++)
    mem[i] = 0;

  compilePass1(d);        // turn opcodes and operands into binary code
  compilePass2(d);        // fix all jump addresses

  line_t *line = d->parse.lineFirst;

  for (line = d->parse.lineFirst; line != 0; line = line->next)
  {
    if (line->label)
    {
      /* label — no output */
    }
    else if (line->binaryValid)
    {
/*
      if (bit16)
        printf("- haddr %.4x (pc=%d)\n", line->pc / 2, line->pc);
      else
        printf("- addr %.4x\n", line->pc);

      printf(bit32 ? "%.8x  " : (bit16 ? "%.4x  " : "%.5x  "), line->binary);
      printLine(line, "", "\n");
*/
      if (bit16)
      {
        /* Pack two 16-bit instructions per 32-bit ROM word.
         * pc is in halfword units (0, 1, 2, ...).
         * Even pc → lower halfword of mem[pc/2].
         * Odd  pc → upper halfword of mem[pc/2]. */
        unsigned int word_idx = (unsigned int)line->pc / 2;
        if (word_idx < 8192)
        {
          if (line->pc & 1)
            mem[word_idx] |= (line->binary & 0xFFFFu) << 16;
          else
            mem[word_idx] |= (line->binary & 0xFFFFu);
        }
      }
      else
      {
        if ((unsigned)line->pc >= 8192) {
          fprintf(stderr, "ROM overflow: pc=0x%x exceeds 8192 words (32KB)\n", line->pc);
          exit(1);
        }
        mem[line->pc] = line->binary;
      }
    }
    else if (line->directBytesValid)
    {
      for (int i = 0; i < line->directBytesValid / 4; i++)
      {
        if (bit16)
        {
          unsigned int word_idx = (unsigned int)(line->pc + i) / 2;
          if (word_idx < 8192)
          {
            if ((line->pc + i) & 1)
              mem[word_idx] |= line->directDwords[i] << 16;
            else
              mem[word_idx] |= line->directDwords[i] & 0xFFFF;
          }
        }
        else
        {
          mem[line->pc + i] = line->directDwords[i];
        }
      }
    }
  }

  /* Output Verilog init files.
   * bit18 (RISC1): single romL.vh with full 18-bit values per init slot.
   * bit16 (RISC3): romL.vh + romH.vh (two packed 16-bit instrs per 32-bit word).
   * bit32 (RISC2): romL.vh + romH.vh (32-bit instrs split into two 16-bit halves). */
  TRY0((fLo = fopen((bit32 || bit16 || bit18) ? "romL.vh" : "rom.vh", "w+")) == NULL,
       (bit32 || bit16 || bit18) ? "can't write romL.vh" : "can't write rom.vh")
  compileWriteInitLines(fLo, mem, bit18 ? MODE_FULL_18_BITS : MODE_LOWER_16_BITS, 0);

  if (bit32 || bit16)
  {
    TRY0((fHi = fopen("romH.vh", "w+")) == NULL, "can't write romH.vh");
    compileWriteInitLines(fHi, mem, MODE_UPPER_16_BITS, 0);
  }

  /* Second ROM bank (words 1024-2047) for 8KB boot ROM */
  if (bit32)
  {
    FILE *fLo2, *fHi2;
    TRY0((fLo2 = fopen("romL2.vh", "w+")) == NULL, "can't write romL2.vh");
    compileWriteInitLines(fLo2, mem, MODE_LOWER_16_BITS, 1024);
    TRY0((fHi2 = fopen("romH2.vh", "w+")) == NULL, "can't write romH2.vh");
    compileWriteInitLines(fHi2, mem, MODE_UPPER_16_BITS, 1024);
  }

  /* Third ROM bank (words 2048-3071) for 12KB boot ROM */
  if (bit32)
  {
    FILE *fLo3, *fHi3;
    TRY0((fLo3 = fopen("romL3.vh", "w+")) == NULL, "can't write romL3.vh");
    compileWriteInitLines(fLo3, mem, MODE_LOWER_16_BITS, 2048);
    TRY0((fHi3 = fopen("romH3.vh", "w+")) == NULL, "can't write romH3.vh");
    compileWriteInitLines(fHi3, mem, MODE_UPPER_16_BITS, 2048);
  }

  TRY0((fBin = fopen("rom.bin", "w+")) == NULL, "can't write rom.bin")
  fprintf(fBin, "%c%c%c", 0, 0, 0);

  /* Find last non-zero word to avoid writing unnecessary padding */
  int romSize = 8192;
  while (romSize > 1 && mem[romSize - 1] == 0) romSize--;

  for (int i = 0; i < romSize; i++)
  {
    /* Always write 32-bit words to rom.bin (two 16-bit instrs packed per word for RISC3) */
    fprintf(fBin, "%c%c%c%c", (mem[i] >> 24) & 255, (mem[i] >> 16) & 255, (mem[i] >> 8) & 255, mem[i] & 255);
  }

  fclose(fBin);

  /* rom.hex: one 32-bit word per line in hexadecimal, for $readmemh (Verilog simulation).
   * Written for both bit32 and bit16 (RISC3) CPUs. */
  if (bit32 || bit16)
  {
    TRY0((fHex = fopen("rom.hex", "w+")) == NULL, "can't write rom.hex")
    for (int i = 0; i < romSize; i++)
      fprintf(fHex, "%08x\n", mem[i]);
    fclose(fHex);
  }
}

void compileAddSourceFile(compile_t *d, char *fname)
{
  FILE *f;
  char line[1024];

  TRY0((f = fopen(fname, "r")) == NULL, "can't open source file %s\n", fname)

	while (fgets(line, sizeof(line) - 1, f))
		parseAddLine(&d->parse, line);
}

void compileInit(compile_t *d)
{
  memset((void*)d, 0, sizeof(compile_t));
  parseInit(&d->parse);

}
