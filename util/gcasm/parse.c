
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "parse.h"

int nibble2bin(char c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  else if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  else if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;

  return -1;
}

int hex2bin(char *s, unsigned int *out)
{
  unsigned int ret = 0;
  int res, digits = 0;

  while (s && *s)
  {
    if ((res = nibble2bin(*s)) < 0)
      return -1;

    if (++digits > 8)
      return -1;

    ret = (ret << 4) + res;
    s++;
  }

  *out = ret;
  return 1;
}

int dec2bin(char *s, unsigned int *out)
{
  unsigned int ret = 0, next;

  while (s && *s)
  {
    if (*s < '0' || *s > '9')
      return -1;

    next = ret * 10 + (unsigned int)(*s - '0');

    if (next < ret)       // overflow
      return -1;

    ret = next;
    s++;
  }

  *out = ret;
  return 1;
}

int whitespace(char c)
{
  return (c == ' ' || c == '\n' || c == '\r' || c == '\t');
}

void separateCommas(char *in, char *out)
{
  int len = 0, strMode = 0;
  char c;

  while (*in && len < MAX_LINE_LEN - 1)
  {
    c = *in++;

    if (c == ',' && !strMode)
    {
      *out++ = ' ';
      *out++ = c;
      *out++ = ' ';
      len += 3;
    }
    else
    {
      *out++ = c;
      len++;
    }

    if (c == '\"')
      strMode = 1 - strMode;

  }
}

void line2words(line_t *line, char *s)
{
  int bufp = 0, strMode = 0;
  char c, buf0[MAX_LINE_LEN + 4], buf[MAX_LINE_LEN + 4];
  int actualOffset;

  memset((char*)line, 0, sizeof(line_t));
  memset(buf0, 0, sizeof(buf0));
  memset(buf, 0, sizeof(buf));
  separateCommas(s, buf0);
  s = buf0;

//  printf("line2words: %s", buf0);

  while (s && *s)
  {
	  while (s && *s && whitespace(*s))
      s++;

	  if (*s == 0)
	    break;

    actualOffset = bufp;

	  while (s && *s && (!whitespace(*s) || strMode) && (*s != ';' || strMode))
	  {
	    c = *s++;

      if (c == '\'')
        strMode = 1 - strMode;

      if (c >= 'A' && c <= 'Z' && !strMode)
		    c = c - 'A' + 'a';

      buf[bufp++] = c;

      if (c == '\"')
        strMode = 1 - strMode;
	  }

	  if (*s == 0 || *s == ';' || (unsigned long)bufp >= sizeof(buf))
	    break;

    buf[bufp++] = 0;

    if (line->wordNum < MAX_WORDS_PER_LINE)
    {
      int i;

      if (bufp - actualOffset >= 3 && buf[actualOffset] == '(' && buf[bufp - 2] == ')')
      {
        for (i = actualOffset; i < bufp - 3; i++)
          buf[i] = buf[i + 1];

        bufp -= 3;
        buf[bufp++] = 0;
        line->parenthesis[line->wordNum] = 1;
      }

      line->strOffset[line->wordNum] = actualOffset;
      line->wordNum++;
    }
  }

  if (bufp > 0)
  {
    TRY0((line->strBuf = (char*)malloc(bufp)) == 0, "malloc err")
    memcpy(line->strBuf, buf, bufp);
  }
}

void parseDebugLine(line_t *line)
{
  for (int i = 0; i < line->wordNum; i++)
    printf("word%d = %s\n", i, line->words[i]);

  printf("\n");
}

void parseAddLine(parse_t *d, char *s)
{
  int i;
  line_t *line;

//  printf("parseAddLine: %s", s);

  TRY0((line = malloc(sizeof(line_t))) == 0, "malloc err")
  line2words(line, s);

  for (i = 0; i < line->wordNum && i < MAX_WORDS_PER_LINE; i++)
    line->words[i] = (char*)line->strBuf + line->strOffset[i];

  d->lineNum++;
  line->lineNum = d->lineNum;

  if (d->lineLast == 0)
  {
    d->lineFirst = d->lineLast = line;
  }
  else
  {
    d->lineLast->next = line;
    d->lineLast = line;
  }
/*
*/
}

int parseDirectBytes(char* s, unsigned int *retVal, unsigned int *strLen, char **strVal)
{
  *strLen = 0;

  if (strlen(s) == 3 && s[0] == '\'' && s[2] == '\'')
  {
    *retVal = s[1];
    return 1;
  }

  if (strlen(s) > 2 && s[0] == '\"' && s[strlen(s) - 1] == '\"')
  {
    *strLen = strlen(s) - 2;
    *strVal = &s[1];
    *retVal = 0;
    return 1;
  }

  if (strlen(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    return hex2bin(&s[2], retVal);

  return dec2bin(s, retVal);
}

void parseInit(parse_t *d)
{
  memset((void*)d, 0, sizeof(parse_t));

}

