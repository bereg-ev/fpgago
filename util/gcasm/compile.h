
#ifndef __COMPILE_H__
#define __COMPILE_H__

#include "arch.h"
#include "parse.h"

#define MODE_LOWER_16_BITS    1
#define MODE_UPPER_16_BITS    2
#define MODE_32_BITS          4
#define MODE_FULL_18_BITS     8

typedef struct label_t
{
    int pc;
    int lineNum;
    char name[128];
    struct label_t *next;
} label_t;

typedef struct
{
  int pc;
  cpu_t cpu;
  parse_t parse;
  arch_t arch;
  label_t *labels;
  mnemonic_t mnemonic;
//  char *words[5];
} compile_t;

#define TRY(function, ...) { if (function) { printf("line %d: ", line->lineNum); printf(__VA_ARGS__); printf("\n"); exit(1); }}

#define TRY0(function, ...) { if (function) { printf(__VA_ARGS__); printf("\n"); exit(1); }}

void compileStart(compile_t *d);
void compileAddSourceFile(compile_t *d, char *fname);
void compileInit(compile_t *d);

#endif
