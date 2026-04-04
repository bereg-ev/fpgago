
#include <stdio.h>
#include <stdlib.h>

void err(char *s)
{
    printf("%s\n", s);
    exit(1);
}

int main(int argc, char **argv)
{
    FILE *f1, *f2;
    unsigned char t[2048];
    int i, j;
    
    if ((f1 = fopen(argv[1], "r")) == NULL)
	err("file open error");

    if ((f2 = fopen(argv[2], "w")) == NULL)
	err("file write error");

    if (fread(t, 2048, 1, f1) != 1)
	err("file read error");
	
    fclose(f1);	
	
    for (i = 0; i < 64; i++)
    {
		fprintf(f2, ".init_%.2x(320'h", i);
	
		for (j = 0; j < 16; j++)
	    	fprintf(f2, "0%.2x%.2x", t[i * 32 + (15 - j) * 2 + 1], t[i * 32 + (15 - j) * 2]);
	    
		fprintf(f2, "),\n");    
    }

    fclose(f2);
}
