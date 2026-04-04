
//
//	store-nal forditott operandus legyen, hogy megmaradjon a dest <= scr logika
//	in/out-nal hasonlokepp
//
/*
		  TODO

		- ecp5 block ram init!!!!

		- cimke maradjon case sensitive, csak mnemonic es register legyen lower case
		- zarojelek megkovetelese in out -nal
		- teszteles: cimke es utasitas, fiktiv reg
		- konstans: dec, hex, char
		- .offset
		- .define PORT_NAME  $A5
		- .include
		- .db, .dw, .dd (risc1-nek ez nem hasznalhato)
*/


#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "parse.h"
#include "compile.h"
#include "arch.h"

int main(int argc, char** argv)
{
	int i, paramDone = 0;
	compile_t compile;

  if (argc == 1)
  {
		printf("Usage: asmcomp [params] [infile1.asm] [infoleN.asm]\n");
		return 1;
  }

	compileInit(&compile);

	for (i = 1; i < argc; i++)
	{
		if (paramDone == 0)
		{
			if (argv[i][0] == '-')
			{
				switch (argv[i][1])
				{
					case 'c':
						if (compile.arch.initialised)
						{
							printf("multiple cpu definitions\n");
							exit(1);
						}

						archInit(&compile.arch, &argv[i][2]);
						compile.cpu = compile.arch.cpu;
						break;

					default:
						printf("invalid parameter: %s\n", argv[i]);
						exit(1);
						break;
				}

				continue;
			}

			paramDone = 1;

			if (compile.arch.initialised == 0)
			{
				printf("no cpu selected\n");
				exit(1);
			}
		}

		compileAddSourceFile(&compile, argv[i]);
	}

	compileStart(&compile);

	return 0;
}
