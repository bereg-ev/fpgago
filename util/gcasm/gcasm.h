
#ifndef __GCASM__
#define __GCASM__


typedef struct labels
{
    int pc;
    int line;
    char name[128];
    struct labels *next;
} labels;

//int whitespace(char c);
//int line2words(char *s);
//int str2reg(char *s);

// --------------------  architecture specific ---------------------------

#define IBIT	18
//#define ABSJMP
//#define IMM
#define MAXDATA	255     // 8 bit reg, max value
#define MAXPC	2048





#endif
