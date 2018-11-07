#include <stdio.h>
#include <string.h>

int main(int argc, char* argv[]){
	char horizon [50];
	char profile [50];
	int trace;
	float twt;
	FILE* outfile;
	char line [200];
	char outname [100];
	
	FILE* infile = fopen(argv[1], "r");
	
	while(!feof(infile)){
		strcpy(outname,"");
		fgets(line, sizeof(line), infile);
		sscanf(line, "%s %s %i %f", horizon, profile, &trace, &twt);
		strcat(outname, profile);
		strcat(outname, "/");
		strcat(outname, horizon);
		strcat(outname, ".tmp");
		outfile = fopen(outname,"a");
		fprintf(outfile, "%i %f\n", trace, twt);
		fclose(outfile);
	}

return 0;
}