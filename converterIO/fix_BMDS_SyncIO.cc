#include <stdio.h>
#include <iostream>
#include <string.h>
#include <stdlib.h>
//#define OMPI_SKIP_MPICXX 1 //Added in the CMakeList.txt file
#include <mpi.h>
#include <math.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "phastaIO.h"

inline int
cscompare( const char teststring[],
	   const char targetstring[] )
{
  char* s1 = const_cast<char*>(teststring);
  char* s2 = const_cast<char*>(targetstring);

  while( *s1 == ' ') s1++;
  while( *s2 == ' ') s2++;
  while( ( *s1 )
	 && ( *s2 )
	 && ( *s2 != '?')
	 && ( tolower( *s1 )==tolower( *s2 ) ) ) {
    s1++;
    s2++;
    while( *s1 == ' ') s1++;
    while( *s2 == ' ') s2++;
  }
  if ( !( *s1 ) || ( *s1 == '?') ) return 1;
  else return 0;
}

int main(int argc, char *argv[]) {

  MPI_Init(&argc,&argv);

  int myrank, N_procs;
  MPI_Comm_rank(MPI_COMM_WORLD, &myrank);
  MPI_Comm_size(MPI_COMM_WORLD, &N_procs);

  FILE * pFile;
  char target[1024], pool[256];
  char * temp, * token;
  int ret,i, j, k, N_restart_integer, N_restart_double;
  int N_geombc_double, N_geombc_integer;
  int N_steps, N_parts, N_files;

  pFile = fopen("./IO.N2O.input","r");
  if (pFile == NULL)
    printf("Error openning\n");

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_geombc_double = atoi(temp);

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_geombc_integer = atoi(temp);

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_restart_double = atoi(temp);

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_restart_integer = atoi(temp);

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_steps = atoi(temp);

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_parts = atoi(temp);

  if(myrank==0){
    printf("numpe is %d and start is %d\n",N_parts,N_steps);
  }

  fgets( target, 1024, pFile );
  token = strtok ( target, ";" );strcpy(pool,token);
  temp = strtok ( pool, ":" );temp = strtok ( NULL, ":" );
  N_files = atoi(temp);

  double ***Dfield, ***FixedDfield; int ***Ifield;
  double *CoordsOld,*CoordsNew;
  int ***paraD, ***paraI, *expectD, *expectI;
  char **fieldNameD, **fileTypeD, **dataTypeD, **headerTypeD;
  char **fieldNameI, **fileTypeI, **dataTypeI, **headerTypeI;

  int* WriteLockD = new int[N_restart_double];
  int* WriteLockI = new int[N_restart_integer];

  int nppp = N_parts/N_procs;
  int startpart = myrank * nppp +1;
  int endpart = startpart + nppp - 1;
  char gfname[255], numTemp[128];
  int iarray[10], igeom, isize;


  if (N_parts != N_procs) {
      printf("Input error: number of parts should be equal to the number of procs!\n");
      printf("Please modify the IO.O2N.input file!\n");
      return 0;
  }



  ///////////////////// reading ///////////////////////////////

  int nppf = N_parts/N_files;
  int N_geombc = N_geombc_double + N_geombc_integer;
  int readHandle, GPID;
  char fname[255],fieldtag[255];
  char dirname[1024];

  int irestart;

  Dfield = new double**[N_restart_double];
  FixedDfield = new double**[N_restart_double];
  Ifield = new int**[N_restart_integer];

  paraD = new int**[N_restart_double];
  paraI = new int**[N_restart_integer];

  expectD = new int[N_restart_double];
  expectI = new int[N_restart_integer];

  fieldNameD = new char*[N_restart_double];
  fileTypeD = new char*[N_restart_double];
  dataTypeD = new char*[N_restart_double];
  headerTypeD = new char*[N_restart_double];

  fieldNameI = new char*[N_restart_integer];
  fileTypeI = new char*[N_restart_integer];
  dataTypeI = new char*[N_restart_integer];
  headerTypeI = new char*[N_restart_integer];

  if (N_restart_double>0)
    for ( i = 0; i < N_restart_double; i++ )
      {
	WriteLockD[i]=0;
	Dfield[i] = new double*[nppp];
	FixedDfield[i] = new double*[nppp];

	paraD[i] = new int*[nppp];

	fieldNameD[i] = new char[128];
	fileTypeD[i] = new char[128];
	dataTypeD[i] = new char[128];
	headerTypeD[i] = new char[128];
      }

  if (N_restart_integer>0)
    for ( i = 0; i < N_restart_integer; i++ )
      {
	WriteLockI[i]=0;
	Ifield[i] = new int*[nppp];

	paraI[i] = new int*[nppp];

	fieldNameI[i] = new char[128];
	fileTypeI[i] = new char[128];
	dataTypeI[i] = new char[128];
	headerTypeI[i] = new char[128];
      }


  ///////////////////// reading ///////////////////////////////

  int N_restart = N_restart_double + N_restart_integer;
  int readHandle1;

  bzero((void*)fname,255);
  sprintf(fname,"./%d-procs_case-SyncIO-%d-BM/restart-dat.%d.%d",N_parts,N_files,N_steps,((int)(myrank/(N_procs/N_files))+1));

  //if(myrank==0){
  //  printf("Myrank is %d - Filename is %s \n",myrank,fname);
  //}

  int nfields;
  queryphmpiio(fname, &nfields, &nppf);
  //initphmpiio(&N_restart, &nppf, &N_files,&readHandle1, "write") ;//WRONG
  initphmpiio(&nfields, &nppf, &N_files, &readHandle1, "read");
  openfile(fname, "read", &readHandle1);

  for ( i = 0; i < N_restart_double; i++ )
    {
      fgets( target, 1024, pFile );
      temp = strtok( target, ";" );
      token = strtok( temp, "," );
      strcpy( fileTypeD[i], token );
      token = strtok ( NULL, "," );
      strcpy( fieldNameD[i], token );
      token = strtok ( NULL, "," );
      strcpy( dataTypeD[i], token );
      token = strtok ( NULL, "," );
      strcpy( headerTypeD[i], token );
      token = strtok ( NULL, "," );
      strcpy( numTemp, token );
      expectD[i] = atoi (numTemp);

      for (  j = 0; j < nppp; j++  )
	{
	  paraD[i][j] = new int[expectD[i]];

	  for ( k = 0; k < 10; k++ )
	    iarray[k]=0;

	  GPID = startpart + j;
	  bzero((void*)fieldtag,255);
	  sprintf(fieldtag,"%s@%d",fieldNameD[i],GPID);

          //printf("myrank %d - filedtag %s\n",myrank,fieldtag);

	  iarray[0]=-1;
	  readheader( &readHandle1,
		       fieldtag,
		       (void*)iarray,
		       &expectD[i],
		       "double",
		       "binary" );

	  if ( iarray[0]==-1 )
	      WriteLockD[i]=1;
	  if ( WriteLockD[i]==0 )
	    {
	      for ( k = 0; k < expectD[i]; k++ )
		paraD[i][j][k] = iarray[k];

	      if ( cscompare("block",headerTypeD[i]) )
		{
		  if ( expectD[i]==1)
		    isize = paraD[i][j][0];
		  else
		    isize = paraD[i][j][0] * paraD[i][j][1];

		  Dfield[i][j] = new double[isize];
		  FixedDfield[i][j] = new double[isize];
		  readdatablock( &readHandle1,
				  fieldtag,
				  (void*)Dfield[i][j],
				  &isize,
				  "double",
				  "binary" );
		}

	    }
	}
    }

  for ( i = 0; i < N_restart_integer; i++ )
    {
      fgets( target, 1024, pFile );
      temp = strtok( target, ";" );
      token = strtok( temp, "," );
      strcpy( fileTypeI[i], token );
      token = strtok ( NULL, "," );
      strcpy( fieldNameI[i], token );
      token = strtok ( NULL, "," );
      strcpy( dataTypeI[i], token );
      token = strtok ( NULL, "," );
      strcpy( headerTypeI[i], token );
      token = strtok ( NULL, "," );
      strcpy( numTemp, token );
      expectI[i] = atoi (numTemp);

      for ( j = 0; j < nppp; j++ )
	{
	  paraI[i][j] = new int[expectI[i]];

	  for ( k = 0; k < 10; k++ )
	    iarray[k]=0;

	  GPID = startpart + j;
	  bzero((void*)fieldtag,255);
	  sprintf(fieldtag,"%s@%d",fieldNameI[i],GPID);
	  iarray[0]=-1;

	  //printf("Rank %d, fieldname is %s \n",myrank,fieldtag);

	  readheader( &readHandle1,
		       fieldtag,
		       (void*)iarray,
		       &expectI[i],
		       "integer",
		       "binary" );

	  if ( iarray[0]==-1)
	      WriteLockI[i]=1;
	  if ( WriteLockI[i]==0 )
	    {
	      for ( k = 0; k < expectI[i]; k++ )
		paraI[i][j][k] = iarray[k];

	      if ( cscompare("block",headerTypeI[i]) )
		{
		  if ( expectI[i]==1)
		    isize = paraI[i][j][0];
		  else
		    isize = paraI[i][j][0] * paraI[i][j][1];

		  Ifield[i][j] = new int[isize];
		  readdatablock( &readHandle1,
				  fieldtag,
				  (void*)Ifield[i][j],
				  &isize,
				  "integer",
				  "binary" );
		}
	    }
	}

    }

  closefile(&readHandle1, "write");
  finalizephmpiio(&readHandle1);

  // read coordinates from broken and good mds ordered posix geombbc.dat
  if(myrank==0){
    printf("Starting to read coordinates (doubles) in the broken geombc.dat.## files\n");
  }

  // nppp=1; // leave the loop in caase later we have this work for multiple parts per process
 //  startpart=myrank+1; // same
  int itwo=2;
  int subdir;
  int DIR_FANOUT=2048;
 // for ( i = 0; i < nppp; i++ )
 //   {
      
      if(0) { // this approach won't work with phastaIO that handles the fanout internally
      if(N_parts > DIR_FANOUT) {
      subdir = (startpart+i-1) / DIR_FANOUT;
        sprintf(gfname,"./%d-procs_case-1PPP-BM/%d/geombc.dat.%d",N_parts, subdir, startpart+i);
      }
      else 
        sprintf(gfname,"./%d-procs_case-1PPP-BM/geombc.dat.%d",N_parts, startpart+i);
      }
// alt approach  needs to move outside of loop if made multiple parts per process
      bzero((void*)gfname,255);
      sprintf(gfname,"./%d-procs_case-1PPP-BM",N_parts);
      ret=chdir(gfname);
      if(ret<0) {
          printf("ERROR - Could not chdir to %s  \n",gfname); 
          return 1; 
      }
      bzero((void*)gfname,255);
      sprintf(gfname,"geombc.dat.%d", startpart+i);
      if(myrank==0) {
      bzero((void*)dirname,sizeof(dirname));
      getcwd(dirname, sizeof(dirname));
      printf("current working directory for BM file open is %s \n", dirname);
      }
// end alt approach
      openfile(gfname,"read",&igeom);

          for ( k = 0; k < 10; k++ )
            iarray[k]=0;

          iarray[0]=-1;
          readheader( &igeom,
                       "co-ordinates",
                       (void*)iarray,
                       &itwo,
                       "double",
                       "binary" );

          if ( cscompare("block",headerTypeD[j]) )
            {

              isize = iarray[0]*3; //  computenitems(i,j,myrank,fieldNameD[j],paraD,expectD[j],numVariables[i]);
              //printf("fieldname: %s part: %d isize: %d\n",fieldNameD[j],startpart+i,isize); 

              CoordsOld = new double[isize];
              readdatablock( &igeom,   // this was changed to point to new direccory and should get new coords
                              "co-ordinates",
                              (void*)CoordsOld,
                              &isize,
                              "double",
                              "binary" );
            }
//        }
//      MPI_Barrier(MPI_COMM_WORLD);
      closefile(&igeom, "read");
      ret=chdir("..");
      if(ret<0) {
          printf("ERROR - Could not chdir back to cwd  \n"); 
          return 1; 
      }
      if(myrank==0) {
        bzero((void*)dirname,sizeof(dirname));
        getcwd(dirname, sizeof(dirname));
        printf("current working directory after BM is %s \n", dirname);
      }
 
  if(myrank==0){
    printf("Starting to read coordinates (doubles) in the good mds ordered geombc.dat.## files\n");
  }

  // nppp=1; // leave the loop in caase later we have this work for multiple parts per process
 //  startpart=myrank+1; // same
  
  for ( i = 0; i < nppp; i++ )
    {
      if(0) {
      if(N_parts > DIR_FANOUT) {
      subdir = (startpart+i-1) / DIR_FANOUT;
        sprintf(gfname,"./%d-procs_case-1PPP-GM/%d/geombc.dat.%d",N_parts, subdir, startpart+i);
      }
      else 
        sprintf(gfname,"./%d-procs_case-1PPP-GM/geombc.dat.%d",N_parts, startpart+i);
      }
// alt approach  needs to move outside of loop if made multiple parts per process
      bzero((void*)gfname,255);
      sprintf(gfname,"./%d-procs_case-1PPP-GM",N_parts);
      ret=chdir(gfname);
      if(ret<0) {
          printf("ERROR - Could not chdir to %s  \n",gfname); 
          return 1; 
      }
      bzero((void*)gfname,255);
      sprintf(gfname,"geombc.dat.%d", startpart+i);
      if(myrank==0) {
      bzero((void*)dirname,sizeof(dirname));
      getcwd(dirname, sizeof(dirname));
      printf("current working directory for GM file open is %s \n", dirname);
      }
// end alt approach
      openfile(gfname,"read",&igeom);

          for ( k = 0; k < 10; k++ )
            iarray[k]=0;

          iarray[0]=-1;
          readheader( &igeom,
                       "co-ordinates",
                       (void*)iarray,
                       &itwo,
                       "double",
                       "binary" );

          if ( cscompare("block",headerTypeD[j]) )
            {

              isize = iarray[0]*3; //  computenitems(i,j,myrank,fieldNameD[j],paraD,expectD[j],numVariables[i]);
              //printf("fieldname: %s part: %d isize: %d\n",fieldNameD[j],startpart+i,isize); 

              CoordsNew = new double[isize];
              readdatablock( &igeom,   // this was changed to point to new direccory and should get new coords
                              "co-ordinates",
                              (void*)CoordsNew,
                              &isize,
                              "double",
                              "binary" );
            }
        }
//      MPI_Barrier(MPI_COMM_WORLD);
      closefile(&igeom, "read");
      ret=chdir("..");
      if(ret<0) {
          printf("ERROR - Could not chdir back to cwd  \n"); 
          return 1; 
      }
      if(myrank==0) {
        bzero((void*)dirname,sizeof(dirname));
        getcwd(dirname, sizeof(dirname));
        printf("current working directory after GM is %s \n", dirname);
      }

 ///////////////////// Fixing ///////////////////////////////

  double etol=1e-7;
  for ( i = 0; i < nppp; i++ ) {
//DEBUG     bzero((void*)fname,255);
//DEBUG     sprintf(fname,"./%d-procs_case-SyncIO-%d-FM/fixlog.%d.%d",N_parts,N_files,myrank,i);
//DEBUG     pFile = fopen(fname,"w");
//DEBUG     fprintf(pFile,"start\n");
//DEBUG     MPI_Barrier(MPI_COMM_WORLD);

    j=0;
//    if ( expectD[i]==1)
//      isize = paraD[i][j][0];
//    else
//      isize = paraD[i][j][0] * paraD[i][j][1];
//FAIL    isize = computenitems(i,j,myrank,fieldNameD[j],paraD,expectD[j],numVariables[i]);
    int nverts=paraD[0][i][0]; //FAIL isize/numVariables[i];  // probably paraD[i][0]
    int k,k2,kf,kd,ipm,ipm2;
    int iskip=nverts;
    int iskip2=2*nverts;
    int ifound;
    double xO,yO,zO,xN,yN,zN,pO,pN;
//DEBUG    fprintf(pFile,"start loop k over %d verts \n ",nverts);
//DEBUG    MPI_Barrier(MPI_COMM_WORLD);
    for ( k = 0; k < nverts; k++ ) { // k counts old coordinate
      ipm=k; // pointer to the x for kth coordinate
      xO=CoordsOld[ipm];
      yO=CoordsOld[(ipm+iskip)];
      zO=CoordsOld[(ipm+iskip2)];
//DEBUG      fprintf(pFile,"start loop looking for %f %f %f \n ",xO,yO,zO);
      for ( k2 = 0; k2 < nverts; k2++ ) { // k2 counts new coordinates
        ipm2=k2; // pointer
        xN=CoordsNew[ipm2];
        yN=CoordsNew[(ipm2+iskip)];
        zN=CoordsNew[(ipm2+iskip2)];
        ifound=0;
        if(abs(xO -xN) <etol &&
           abs(yO -yN) < etol &&
           abs(zO -zN) < etol ) {
//DEBUG           fprintf(pFile,"%d %d \n",k,k2);
           ifound=1;
           if(k==nverts/10 && myrank==0 ) //  && i==0)
              printf("10 percent complete of first ppp: k=%d k2=%d\n", k, k2);
           for ( kf=0; kf < N_restart_double; kf++) {  // kf counts the double fields being transferred
             int nvarsIR=paraD[kf][i][1];
//DEBUG             fprintf(pFile,"field number %d attempting to map %d variables \n",kf+1,nvarsIR);
             for ( kd=0; kd < nvarsIR; kd++)  {  // note paraD AND Dfield areflipped relative to Geom??
               FixedDfield[kf][i][k2+kd*nverts]= Dfield[kf][i][k+kd*nverts];
//fordeug               pN=FixedDfield[kf][i][k2+kd*nverts]= Dfield[kf][i][k+kd*nverts];
//fordeug               pO=Dfield[kf][i][k+kd*nverts];
             }
           }
           break;
        }
      }
//DEBUG      if(ifound==0) fprintf(pFile," k=%d no match \n",k);
      if(ifound==0) printf(" k=%d no match \n",k);
    }
//DEBUG    fprintf(pFile,"all %d verts found for this part \n",nverts);
//DEBUG    fclose(pFile);
  }

  if(myrank==0 ) //  && i==0)
     printf("finished fixing \n");

  ///////////////////// Writing SyncIO///////////////////////////////

  FILE * AccessoryFileHandle;

  if (myrank==0)
    {    

//MR CHANGE
      bzero((void*)gfname,64);
      sprintf(gfname,"./%d-procs_case-SyncIO-%d-FM",N_parts,N_files);
      if(0<mkdir(gfname,0777)) { printf("ERROR - Could not create procs_case-SyncIO directory\n"); return 1; }
//MR CHANGE END

      bzero((void*)gfname,64);
      sprintf(gfname,"./%d-procs_case-SyncIO-%d-FM/numstart.dat",N_parts,N_files);
      AccessoryFileHandle=fopen(gfname,"w");
      fprintf(AccessoryFileHandle,"%d",N_steps);
      fclose(AccessoryFileHandle);

      bzero((void*)gfname,64);
      sprintf(gfname,"./%d-procs_case-SyncIO-%d-FM/numpe.in",N_parts,N_files);
      AccessoryFileHandle=fopen(gfname,"w");
      fprintf(AccessoryFileHandle,"%d",N_parts);
      fclose(AccessoryFileHandle);
    }    


  int writeHandle;

  bzero((void*)fname,255);
  sprintf(fname,"./%d-procs_case-SyncIO-%d-FM/restart-dat.%d.%d",N_parts,N_files,N_steps,((int)(myrank/(N_procs/N_files))+1));
  initphmpiio(&N_restart, &nppf, &N_files,&writeHandle, "write");
  openfile(fname, "write", &writeHandle);

  MPI_Barrier(MPI_COMM_WORLD);
  if(myrank==0){
    printf("Starting to write some blocks (doubles) in the restart-dat.##.## files\n");
  }

  for ( i = 0; i < N_restart_double; i++ )
    {
      for (  j = 0; j < nppp; j++  )
        {

          if (WriteLockD[i]==0)
            {
              GPID = startpart + j;
              bzero((void*)fieldtag,255);
              sprintf(fieldtag,"%s@%d",fieldNameD[i],GPID);

              if ( expectD[i]==1)
                isize = paraD[i][j][0];
              else
                isize = paraD[i][j][0] * paraD[i][j][1];

              for ( k = 0; k < expectD[i]; k++ )
                iarray[k] = paraD[i][j][k];

              if ( cscompare("header",headerTypeD[i]) )
                isize = 0;

              writeheader( &writeHandle,
                            fieldtag,
                            (void*)iarray,
                            &expectD[i],
                            &isize,
                            "double",
                            "binary");

              writedatablock( &writeHandle,
                               fieldtag,
                               (void*)FixedDfield[i][j],
                               &isize,
                               "double",
                               "binary" );
              if ( cscompare("block",headerTypeD[i]) )
                delete [] FixedDfield[i][j];
                delete [] Dfield[i][j];
            }
        delete [] paraD[i][j];
        }
    }

  MPI_Barrier(MPI_COMM_WORLD);
  if(myrank==0){
    printf("Starting to write some blocks (integers) in the restart.dat.##.## files\n");
  }

  for ( i = 0; i < N_restart_integer; i++ )
    {
      for (  j = 0; j < nppp; j++  )
        {

          if (WriteLockI[i]==0)
            {
              GPID = startpart + j;
              bzero((void*)fieldtag,255);
              sprintf(fieldtag,"%s@%d",fieldNameI[i],GPID);

              if ( expectI[i]==1)
                isize = paraI[i][j][0];
              else
                isize = paraI[i][j][0] * paraI[i][j][1];

              for ( k = 0; k < expectI[i]; k++ )
                iarray[k] = paraI[i][j][k];

              if ( cscompare("header",headerTypeI[i]) )
                isize = 0;

              writeheader( &writeHandle,
                            fieldtag,
                            (void*)iarray,
                            &expectI[i],
                            &isize,
                            "integer",
                            "binary");

              writedatablock( &writeHandle,
                               fieldtag,
                               (void*)Ifield[i][j],
                               &isize,
                               "integer",
                               "binary" );

       if ( cscompare("block",headerTypeI[i]) )
         delete [] Ifield[i][j];
            }
   delete [] paraI[i][j];
        }

    }

  MPI_Barrier(MPI_COMM_WORLD);
  if(myrank==0){
    printf("Closing restart-dat.##.## files\n");
  }

  closefile(&writeHandle, "write");
  finalizephmpiio(&writeHandle);

  if(0) { // skip it for now
  //////////////////////////writing posix////////////////////////////

  int irstou;
  int magic_number = 362436;
  int* mptr = &magic_number;
  int nitems = 1;
  int ret;

  bzero((void*)fname,255);
  sprintf(fname,"./%d-procs_case-1PPP",N_parts);
  if(myrank == 0) {
    ret=mkdir(fname,0777);
    if(ret<0) {
      if(errno == EEXIST) {
       // acceptable
      } else {
        printf("ERROR - Could not create procs_case-1PPP directory\n"); 
        return 1; 
      }
    }
    printf("mkdir 1PPP succeeded on %d \n", myrank);

  }
  MPI_Barrier(MPI_COMM_WORLD);
  ret=chdir(fname);
  if(ret<0) {
      printf("ERROR - Could not chdir procs_case-1PPP directory\n"); 
      return 1; 
  }
  if(myrank == 0) printf("chdir to 1PPP succeeded on %d \n", myrank);

  // newer versions of phastaIO do the fanout for posix but assume that calling program is already in the 
  // posix part_case directory. 
  bzero((void*)fname,255);
  sprintf(fname,"restart.%d.%d",N_steps,myrank+1);
  if(myrank ==0) {
     printf( "rank0 is going to open file %s \n",fname);
     bzero((void*)dirname,sizeof(dirname));
     getcwd(dirname, sizeof(dirname));
     printf("in a fanout created in phastaIO underneath %s \n", dirname);
  }
  openfile(fname,"write", &irstou);

  writestring( &irstou,"# PHASTA Input File Version 2.0\n");
  writestring( &irstou,
		"# format \"keyphrase : sizeofnextblock usual headers\"\n");

  bzero( (void*)fname, 255 );
  writestring( &irstou, fname );

  writestring( &irstou, fname );
  writestring( &irstou,"\n");


  isize = 1;
  nitems = 1;
  iarray[ 0 ] = 1;
  writeheader( &irstou, "byteorder magic number ",
		(void*)iarray, &nitems, &isize, "integer", "binary" );

  nitems = 1;
  writedatablock( &irstou, "byteorder magic number ",
		   (void*)mptr, &nitems, "integer", "binary" );

  for ( i = 0; i < N_restart_double; i++ )
    {
      for ( j = 0; j < nppp; j++ )
	{
	  if ( WriteLockD[i] == 0 )
	    {
	      if ( cscompare("header",headerTypeD[i]) )
		{
		  bzero( (void*)fname, 255 );
		  sprintf(fname,"%s : < 0 > %d\n", fieldNameD[i],paraD[i][j][0]);
		  writestring( &irstou, fname );
		}

	      if ( cscompare("block",headerTypeD[i]) )
		{
		  if ( expectD[i]==1 )
		    isize = paraD[i][j][0];
		  else
		    isize = paraD[i][j][0] * paraD[i][j][1];

		  for ( k = 0; k < expectD[i]; k++ )
		    iarray[k] = paraD[i][j][k];

		  if ( cscompare("header",headerTypeD[i]) )
		    isize = 0;

		  writeheader( &irstou,
				fieldNameD[i],
				(void*)iarray,
				&expectD[i],
				&isize,
				"double",
				"binary");
		  writedatablock( &irstou,
				   fieldNameD[i],
				   (void*)Dfield[i][j],
				   &isize,
				   "double",
				   "binary");
		}


              if ( cscompare("block",headerTypeD[i]) )
                delete [] Dfield[i][j];
	    }
	  delete [] paraD[i][j];
	}
    }

  for ( i = 0; i < N_restart_integer; i++ )
    {
      for ( j = 0; j < nppp; j++ )
	{

	  if ( WriteLockI[i] == 0 )
	    {

	      if ( cscompare("header",headerTypeI[i]) )
		{
		  bzero( (void*)fname, 255 );
		  sprintf(fname,"%s : < 0 > %d\n", fieldNameI[i],paraI[i][j][0]);
		  writestring( &irstou, fname );
		}

	      if ( cscompare("block",headerTypeI[i]) )
		{
		  if ( expectI[i]==1 )
		    isize = paraI[i][j][0];
		  else
		    isize = paraI[i][j][0] * paraI[i][j][1];

		  for ( k = 0; k < expectI[i]; k++ )
		    iarray[k] = paraI[i][j][k];

		  writeheader( &irstou,
				fieldNameI[i],
				(void*)iarray,
				&expectI[i],
				&isize,
				"integer",
				"binary");
		  writedatablock( &irstou,
				   fieldNameI[i],
				   (void*)Ifield[i][j],
				   &isize,
				   "integer",
				   "binary");
		}

              if ( cscompare("block",headerTypeI[i]) )
                delete [] Ifield[i][j];
	    }
	  delete [] paraI[i][j];
	}
    }


  closefile( &irstou, "write" );
  MPI_Barrier(MPI_COMM_WORLD);

} // hack out posix write

  if (N_restart_double>0)
    for ( i = 0; i < N_restart_double; i++ )
      {
	delete [] Dfield[i];
	delete [] paraD[i];

	delete [] fieldNameD[i];
	delete [] fileTypeD[i];
	delete [] dataTypeD[i];
	delete [] headerTypeD[i];
      }

  if (N_restart_integer>0)
    for ( i = 0; i < N_restart_integer; i++ )
      {
	delete [] Ifield[i];
	delete [] paraI[i];

	delete [] fieldNameI[i];
	delete [] fileTypeI[i];
	delete [] dataTypeI[i];
	delete [] headerTypeI[i];
      }

  delete [] Dfield;
  delete [] CoordsOld;
  delete [] CoordsNew;
  delete [] Ifield;

  delete [] paraD;
  delete [] paraI;

  delete [] expectD;
  delete [] expectI;

  delete [] fieldNameD;
  delete [] fileTypeD;
  delete [] dataTypeD;
  delete [] headerTypeD;

  delete [] fieldNameI;
  delete [] fileTypeI;
  delete [] dataTypeI;
  delete [] headerTypeI;

  delete [] WriteLockD;
  delete [] WriteLockI;

  fclose(pFile);

  if (myrank==0)
    {
      printf("\nFinished transfer, please check data using:\n");
      printf(" grep -a ': <' filename \n\n");
    }

  MPI_Finalize();

}

