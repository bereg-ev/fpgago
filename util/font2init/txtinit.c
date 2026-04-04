
#include <stdio.h>
#include <stdlib.h>

void err(char *s)
{
    printf("%s\n", s);
    exit(1);
}

int main(int argc, char **argv)
{
    FILE *f2;
    int i, j;
    
    if ((f2 = fopen(argv[1], "w")) == NULL)
	err("file write error");

    for (i = 0; i < 64; i++)
    {
		fprintf(f2, ".init_%.2x(320'h", i);
	
		for (j = 0; j < 16; j++)
	    	fprintf(f2, "0%.4x", i * 16 + (15 - j));
//	    	fprintf(f2, "0%.2x%.2x", i * 32 + (15 - j) * 2 + 1, i * 32 + (15 - j) * 2);
	    
		fprintf(f2, "),\n");    
    }

    fclose(f2);
}
