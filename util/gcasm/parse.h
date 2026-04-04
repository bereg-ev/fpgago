#ifndef __PARSE_H__
#define __PARSE_H__

#define MAX_LINE_LEN          1024
#define MAX_DIRECT_DWORDS     32
#define MAX_WORDS_PER_LINE    65         // 32 x .db/.dw/.dd with comma, OR label: opcode + operand1 + comma + operand2 + comma + operand3

#define TYPE_BYTE     1
#define TYPE_WORD     2
#define TYPE_DWORD    0

typedef struct line_t
{
  int lineNum;
  int wordNum;
  int strOffset[MAX_WORDS_PER_LINE];            // offsets within strBuf
  int parenthesis[MAX_WORDS_PER_LINE];
  char *strBuf;
  unsigned int binary, directDwords[MAX_DIRECT_DWORDS];
  int pc;
  int binaryValid, directBytesValid, offsetOperand;
  int label;
  char *words[MAX_WORDS_PER_LINE];
  char labelName[64];
  struct line_t *next;
  int byteWordDword;
  int skipLine;         // when direct bytes go to the previous line which isn't finished / aligned yet
} line_t;

typedef struct parse
{
  int lineNum;
  line_t *lineFirst;
  line_t *lineLast;

} parse_t;

#define TRY0(function, ...) { if (function) { printf(__VA_ARGS__); printf("\n"); exit(1); }}

void parseDebugLine(line_t *line);
int nibble2bin(char c);
int hex2bin(char *s, unsigned int *out);
int dec2bin(char *s, unsigned int *out);
void parseInit(parse_t *d);
void parseAddLine(parse_t *d, char *line);
int parseDirectBytes(char* s, unsigned int *retVal, unsigned int *strLen, char **strVal);

#endif
