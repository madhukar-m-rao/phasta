      subroutine itrdrv (y,         ac,         
     &                   uold,      x,         
     &                   iBC,       BC,         
     &                   iper,      ilwork,     shp,       
     &                   shgl,      shpb,       shglb,
     &                   ifath,     nsons ) 
c
c----------------------------------------------------------------------
c
c This iterative driver is the semi-discrete, predictor multi-corrector 
c algorithm. It contains the Hulbert Generalized Alpha method which
c is 2nd order accurate for Rho_inf from 0 to 1.  The method can be
c made  first-order accurate by setting Rho_inf=-1. It uses CGP and
c GMRES iterative solvers.
c
c working arrays:
c  y      (nshg,ndof)           : Y variables
c  x      (nshg,nsd)            : node coordinates
c  iBC    (nshg)                : BC codes
c  BC     (nshg,ndofBC)         : BC constraint parameters
c  iper   (nshg)                : periodicity table
c
c
c Zdenek Johan,  Winter 1991.  (Fortran 90)
c Alberto Figueroa, Winter 2004.  CMM-FSI
c Irene Vignon, Fall 2004. Impedance BC
c----------------------------------------------------------------------
c
#ifdef HAVE_MKL
      use mkl_service
#endif
      use fncorpmod  
      use pvsQbi     !gives us splag (the spmass at the end of this run 
      use specialBC !gives us itvn
      use timedata   !allows collection of time series
      use convolImpFlow !for Imp bc
      use convolRCRFlow !for RCR bc
      use turbsa          ! used to access d2wall
      use wallData
      use fncorpmod
      use solvedata
      use iso_c_binding
      use spat_var_eps !use spatial varying eps_ls
      use STG_BC
      use spanStats
      use turbKW

c      use readarrays !reads in uold and acold
      
        include "common.h"
#ifdef HAVE_MKL
        include "kmkl.fi"
#endif
        include "mpif.h"
        include "auxmpi.h"
#ifdef HAVE_SVLS        
        include "svLS.h"
#endif
#if !defined(HAVE_SVLS) && !defined(HAVE_LESLIB)
#error "You must enable a linear solver during cmake setup"
#endif

c

        
        real*8    y(nshg,ndof),              ac(nshg,ndof),           
     &            yold(nshg,ndof),           acold(nshg,ndof),
     &            yAlpha(nshg,ndof),         acAlpha(nshg,ndof),
     &            u(nshg,nsd),               uold(nshg,nsd),
     &            uAlpha(nshg,nsd),
     &            x(numnp,nsd),              solinc(nshg,ndof),
     &            BC(nshg,ndofBC),           tf(nshg,ndof),
     &            GradV(nshg,nsdsq)

c
        real*8    res(nshg,ndof)
c     
        real*8    shp(MAXTOP,maxsh,MAXQPT),  
     &            shgl(MAXTOP,nsd,maxsh,MAXQPT), 
     &            shpb(MAXTOP,maxsh,MAXQPT),
     &            shglb(MAXTOP,nsd,maxsh,MAXQPT) 
c
        integer   rowp(nshg,nnz),         colm(nshg+1),
     &            iBC(nshg),
     &            ilwork(nlwork),
     &            iper(nshg),            ifuncs(6)

        real*8 vbc_prof(nshg,3)

        real*4 epstolSP(6),prestolSP

        character*10 cname2
        character*5  cname
        integer i_redist_counter
        real*8 redist_toler_previous
        logical iloop
c
c  stuff for dynamic model s.w.avg and wall model
c
        dimension ifath(nshg),    nsons(ndistsons)

        dimension wallubar(2),walltot(2)
c
        real*8   almit, alfit, gamit
c
        character*20    fname1,fmt1
        character*20    fname2,fmt2
        character*60    fnamepold, fvarts
        character*4     fname4c ! 4 characters
        character*255   fnameCoord
        integer         iarray(50) ! integers for headers
        integer         isgn(ndof), isgng(ndof)

        real*8, allocatable, dimension(:,:) :: rerr
        real*8, allocatable, dimension(:,:) :: ybar, strain, vorticity
        real*8, allocatable, dimension(:,:) :: wallssVec, wallssVecbar
c
c Redistancing option of fixing phi of primary vertices
c
        real*8  primvertval(nshg,2)
        integer primvert(nshg)
        integer i_primvert,numpv,numpvset
        integer  iredist_flag
          
        REAL*8,  allocatable :: BCredist(:)
        integer, allocatable :: iBCredist(:)
        real*8 tcorecp(2), tcorecpscal(2)

        real*8, allocatable, dimension(:,:,:) :: yphbar
        real*8 CFLworst(numel)
        real*8 CFLls(nshg)
c
c ----  Variables for random initial condition field
        real*8 r,randtime,var
        integer seed, randtmp, seed_size
        integer, allocatable :: seed1(:)
c ---   Variables for LES channel flow IC
        logical exlog
        integer nx, ny, nyTot, nz, nICpoints, kijNum, ijkNum
        real*8, allocatable :: xpoints(:), ypoints(:), zpoints(:)
        real*8, allocatable :: ordIC(:,:)
c ---   Variables for SA IC to SST k-omega model
        real*8 rnu, chi(nshg), fv1(nshg), nut(nshg), tmp1(nshg),
     &         tmp2(nshg), ss(nshg), ssq(nshg), tmp
c ---
        integer :: iv_rankpernode, iv_totnodes, iv_totcores
        integer :: iv_node, iv_core, iv_thread

!--------------------------------------------------------------------
!     Setting up svLS
#ifdef HAVE_SVLS
      INTEGER svLS_nFaces
      TYPE(svLS_lhsType) svLS_lhs
      TYPE(svLS_lsType) svLS_ls
! repeat for scalar solves (up to 4 at this time which is consistent with rest of PHASTA)
      TYPE(svLS_lhsType) svLS_lhs_S(4)
      TYPE(svLS_lsType) svLS_ls_S(4)
#endif
#ifdef HAVE_MKL
      irc=mkl_enable_instructions(MKL_ENABLE_AVX512_MIC)
#endif
        idflx = 0
        if(idiff >= 1 )  idflx= (nflow-1) * nsd
        if (isurf == 1) idflx=nflow*nsd

      call initmpistat()  ! see bottom of code to see just how easy it is

      call initmemstat() 
      if(myrank.lt.4) call hello()
#ifdef HAVE_OMP
      if(myrank.eq.0) write(*,*) 'Number of Blocks to Pool = ',BlockPool 
#endif
      rthreads = 0.0
      rblasphasta = 0.0
      rspmvphasta = 0.0
      rblasmkl = 0.0
      rblasaxpy = 0.0
      rspmvmkl = 0.0
      rspmvKG = 0.0
      rspmvD = 0.0
      rspmvG = 0.0
      rspmvNGt = 0.0
      rspmvNGtC = 0.0
      rspmvFull = 0.0

!--------------------------------------------------------------------
!     Setting up svLS Moved down for better org

c
c only master should be verbose
c

        if(numpe.gt.0 .and. myrank.ne.master)iverbose=0  
c

        lskeep=lstep 

        call initTimeSeries()
c
c.... open history and aerodynamic forces files
c
        if (myrank .eq. master) then
           open (unit=ihist,  file=fhist,  status='unknown')
           fforce='forces'//trim(cname2(lstep))//'.dat'
           open (unit=iforce, file=fforce, status='unknown')
           open (unit=76, file="fort.76", status='unknown')
           if(numImpSrfs.gt.0 .or. numRCRSrfs.gt.0) then
              fnamepold = 'pold'
              fnamepold = trim(fnamepold)//trim(cname2(lstep))
              fnamepold = trim(fnamepold)//'.dat'
              fnamepold = trim(fnamepold)
              open (unit=8177, file=fnamepold, status='unknown')
           endif
        endif
c
c.... initialize
c     
        ifuncs(:)  = 0              ! func. evaluation counter
        istep  = 0
        yold   = y
        acold  = ac


c ----- Add a random fluctiation to the initial velocity field
c ----- to start the WMLES branch of the IDDES model
        if (iRandomIC.eq.1) then
          if (myrank.eq.master) then
              write (*,*) "Adding random fluctuations to IC"
          endif
          call random_seed
          do kk=1, nshg
           if (d2wall(kk).lt.STGDelBL) then
             do ik=1,3
               call random_number(r) ! r is a random number between 0 and 1
               if (ik.eq.1) then
                 var = yold(kk,ik) 
                 yold(kk,ik) = var + (0.2*r*var-0.1*var) 
               else
                 yold(kk,ik) = yold(kk,ik) + (1.0*r-0.5)
               endif
             enddo
           endif
          enddo
        endif
c ----- End of modification to the initial velocity field
c ----- Write Coordinates of this part to file
cc        if (numpe > 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
cc       fnameCoord='coords'
cc        fnameCoord= trim(fnameCoord)  // cname2(myrank+1)
cc        open (unit=123,file=fnameCoord,
cc     &        status="new",action="write")
cc        write(123,*) numnp
cc        do n=1,numnp
cc           write(123,*) x(n,1),x(n,2),x(n,3)
cc        enddo
cc        close(123)
cc        if (numpe > 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
c ----- End of write coordinates to file
c
c ----- Read an initial condition for ordered meshes k,j,i
        inquire(file="InitialCondition-Ord.dat",exist=exlog)
        if(exlog) then
          open (unit=123,file="InitialCondition-Ord.dat",status="old")
          read(123,*) nICpoints
          allocate(ordIC(nICpoints,7))
          do i=1,nICpoints
            read(123,*) (ordIC(i,j),j=1,7)
          enddo
          open (unit=234,file="crdY.dat",status="old")
          read(234,*) nyTot
          read(234,*) ny
          allocate(ypoints(ny))
          do i=1,ny
            read(234,*) ypoints(i)
          enddo
          open (unit=345,file="crdX.dat",status="old")
          read(345,*) nx
          allocate(xpoints(nx))
          do i=1,nx
            read(345,*) xpoints(i)
          enddo
          open (unit=456,file="crdZ.dat",status="old")
          read(456,*) nz
          allocate(zpoints(nz))
          do i=1,nz
            read(456,*) zpoints(i)
          enddo
          do i=1,nshg
            do j=1,nx
              if (abs(x(i,1)-xpoints(j)).lt.1.0e-5) then
                ix = j
                exit         
              endif
            enddo
            do j=1,ny
              if (abs(x(i,2)-ypoints(j)).lt.1.0e-5) then
                iy = j
                exit            
              else
                iy = -1
              endif
            enddo
            do j=1,nz
              if (abs(x(i,3)-zpoints(j)).lt.1.0e-5) then
                iz = j   
                exit         
              endif
            enddo
            kjiNum = nz*nyTot*(ix-1)+nz*(iy-1)+iz 
            ijkNum = nx*nyTot*(iz-1)+nx*(iy-1)+ix
            if (iy.ne.-1) then 
               yold(i,1:3) = ordIC(ijkNum,5:7)
               yold(i,4) = ordIC(ijkNum,4)
            endif
          enddo
          deallocate(ypoints)
          deallocate(xpoints)
          deallocate(zpoints)
          deallocate(ordIC)
          close(123)
          close(234)
          close(345)
          close(456)
        else
           if(myrank.eq.master) write(*,*) 
     &                     'Did not read file InitialCondition-Ord.dat'
        endif
c ----  End of LES initial condition
!!!!!!!!!!!!!!!!!!!
!Init output fields
!!!!!!!!!!!!!!!!!!
        numerr=10+isurf
        allocate(rerr(nshg,numerr)) 
        rerr = zero


        if(ierrcalc.eq.1 .or. ioybar.eq.1) then ! we need ybar for error too
          if (ivort == 1) then
            irank2ybar=18 ! bumped by 1 to add Q
            if (iRANS.eq.-5) irank2ybar = irank2ybar+1 ! add omega for SST k-omega model
            allocate(ybar(nshg,irank2ybar)) ! more space for vorticity if requested
          else
            irank2ybar=13
            if (iRANS.eq.-5) irank2ybar = irank2ybar+1 ! add omega for SST k-omega model
            allocate(ybar(nshg,irank2ybar))
          endif
          ybar = zero ! Initialize ybar to zero, which is essential
        endif

        if(ivort == 1) then
          allocate(strain(nshg,6))
          allocate(vorticity(nshg,5))
        endif

        if(abs(itwmod).ne.1 .and. iowflux.eq.1) then
          allocate(wallssVec(nshg,3)) 
          if (ioybar .eq. 1) then
            allocate(wallssVecbar(nshg,3))
            wallssVecbar = zero ! Initialization important if mean wss computed
          endif
        else
          allocate(wallssVec(1,1))
          allocate(wallssVecbar(1,1))
        endif

! both nstepsincycle and nphasesincycle needs to be set
        if(nstepsincycle.eq.0) nphasesincycle = 0 
        if(nphasesincycle.ne.0) then
!     &     allocate(yphbar(nshg,5,nphasesincycle))
          if (ivort == 1) then
            irank2yphbar=16 ! bumped by 1 to add Q
            allocate(yphbar(nshg,irank2yphbar,nphasesincycle)) ! more space for vorticity
          else
            irank2yphbar=11
            allocate(yphbar(nshg,irank2yphbar,nphasesincycle))
          endif
          yphbar = zero
        else
          allocate(yphbar(1,1,1))
        endif

        if (ispanIDDES.eq.1) allocate(IDDESfung(nshg,nfun+1))

!!!!!!!!!!!!!!!!!!!
!END Init output fields
!!!!!!!!!!!!!!!!!!

        vbc_prof(:,1:3) = BC(:,3:5)
        if(iramp.eq.1) then
          call BCprofileInit(vbc_prof,x)
        endif
      
c
c.... ---------------> initialize Equation Solver <---------------
c
       call initEQS(iBC, rowp, colm,svLS_nFaces,
     2               svLS_LHS,svLS_ls,
     3               svLS_LHS_S,svLS_ls_S)
c
c...  prepare lumped mass if needed
c
c      if((flmpr.ne.0).or.(flmpl.ne.0)) call genlmass(x, shp,shgl)
      call genlmass(x, shp, shgl, iBC, iper, ilwork)
c... compute element volumes
c
      allocate(elem_local_size(numel))
      if (numelb .gt. 0) then
        allocate(elemb_local_size(numelb))
      else
        allocate(elemb_local_size(1))
      endif
      call getelsize(x,  shp,  shgl,  elem_local_size,
     &               shpb, shglb,  elemb_local_size)
c
c Initialize Level Set CFL array
c
       CFLls = zero
c
c set flag for freezing LS Scalar 2
c
            if (iSolvLSSclr2.eq.2) then
              allocate (iBCredist(nshg))
              allocate (BCredist(nshg))
              BCredist(:) = zero
              iBCredist(:) = 0
            endif
c
c Redistancing option of fixing phi of primary vertices
c
        i_primvert = 0
        if (i_primvert .eq. 1) then
          do inode = 1, nshg
           primvert(inode) = 0
           primvertval(inode,1) = zero 
           primvertval(inode,2) = zero
c           write(*,*) "primvertval, inode = ", primvertval(inode,1),
c     &                                  primvertval(inode,2), inode
          enddo
        endif
c
c.... -----------------> End of initialization <-----------------
c
!hack to write solution to file when using streams 
! disbled in next line      if(output_mode .eq. -1 ) then ! this is an in-memory adapt case
      if(output_mode .eq. -10 ) then ! this is an in-memory adapt case
        output_mode=0   ! only writing posix for now
        lstepSave=lstep
        lstep=lstep+10000  ! in SAM lstep was already written on the previous mesh.  Here we want solution on the new mesh
                 call  checkpoint (y,ac,acold,uold,x,shp, shgl, shpb, 
     &                       shglb,ilwork, iBC,BC,iper,wallsvec,
     &                       rerr,ybar,wallssVecBar,yphbar,
     &                       vorticity,irank2ybar,irank2yphbar,istp)
! shift the number to keep them distinct
        lstep=lstepSave
        output_mode=-1 ! reset to stream 
      endif
!end hack
c.....open the necessary files to gather time series
c
      lstep0 = lstep+1
      nsteprcr = nstep(1)+lstep
      itsq = 1  ! the loop over itsq has been removed (FINALLY) though still leaving arrays for now.
         itseq = itsq

c
c.... set up the time integration parameters
c         
         nstp   = nstep(itseq)
         nitr   = niter(itseq)
         LCtime = loctim(itseq)
         dtol(:)= deltol(itseq,:)

         call itrSetup ( y, acold )
        
c
c...initialize the coefficients for the impedance convolution,
c   which are functions of alphaf so need to do it after itrSetup
         if(numImpSrfs.gt.zero) then
            call calcImpConvCoef (numImpSrfs, ntimeptpT)
         endif
c
c...initialize the initial condition P(0)-RQ(0)-Pd(0) for RCR BC
c   need ndsurf so should be after initNABI
         if(numRCRSrfs.gt.zero) then
            call calcRCRic(y,nsrflistRCR,numRCRSrfs)
         endif
c
c  find the last solve of the flow in the step sequence so that we will
c         know when we are at/near end of step
c
c         ilast=0
         nitr=0  ! count number of flow solves in a step (# of iterations)
         do i=1,seqsize
            if(stepseq(i).eq.0) nitr=nitr+1
         enddo

!         if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
         tcorecp(:) = zero ! used in solfar.f (solflow)
         tcorecpscal(:) = zero ! used in solfar.f (solflow)
         if(myrank.eq.0)  then
            tcorecp1 = TMRC()
         endif

c
c.... loop through the time steps
c
         istop=0
         rmub=datmat(1,2,1)
         if(rmutarget.gt.0) then
            rmue=rmutarget
         else
            rmue=datmat(1,2,1) ! keep constant
         endif

        if(iramp.eq.1) then
            call BCprofileScale(vbc_prof,BC,yold) ! fix the yold values to the reset BC
            call itrBC (yold,  ac,  iBC,  BC,  iper,ilwork)
            isclr=1 ! fix scalar
            do isclr=1,nsclr
               call itrBCSclr(yold,ac,iBC,BC,iper,ilwork)
            enddo
        endif

        stopjob=-1
         do 2000 istp = 1, nstp
           call TimeRemainingIntoDoubleRunCheck()

c...       STG Inflow
           tcurrent= (lstep+1-iSTGStart)*Delt(1)
           if(iSTG.eq.1) then
             call applySTG(tcurrent,BC,x,GradV)
           endif

           if(iramp.eq.1)  then
            call BCprofileScale(vbc_prof,BC,yold)
            call itrBC (yold,  ac,  iBC,  BC,  iper,ilwork)
           endif

           call rerun_check()
           if(myrank.eq.master) write(*,*) 
     &         'stopjob,lstep,istep', stopjob,lstep,istep
           if(stopjob.eq.lstep) then
              stopjob=-2 ! this is the code to finish
             if ((irs .ge. 1) .and. (mod(lstep, ntout) .eq. 0)) then
                if(myrank.eq.master) write(*,*) 
     &         'line 473 says last step written so exit'
                goto 2002  ! the step was written last step so just exit
             else            
                if(myrank.eq.master) 
     &         write(*,*) 'line 473 says last step not written'
                istep=nstp  ! have to do this so that solution will be written 
                goto 2001
             endif
           endif

c.... if we have time varying boundary conditions update the values of BC.
c     these will be for time step n+1 so use lstep+1
c     
            if(itvn.gt.0) call BCint((lstep+1)*Delt(1), shp, shgl, 
     &                               shpb, shglb, x, BC, iBC)

c
c ... calculate the pressure contribution that depends on the history for the Imp. BC
c
            if(numImpSrfs.gt.0) then 
               call pHist(poldImp,QHistImp,ImpConvCoef,
     &                    ntimeptpT,numImpSrfs)
            endif
c
c ... calc the pressure contribution that depends on the history for the RCR BC
c     
            if(numRCRSrfs.gt.0) then 
               call CalcHopRCR (Delt(itseq), lstep, numRCRSrfs) 
               call CalcRCRConvCoef(lstep,numRCRSrfs)
               call pHist(poldRCR,QHistRCR,RCRConvCoef,nsteprcr,
     &              numRCRSrfs)
            endif

            if(iLES.gt.0) then  !complicated stuff has moved to routine below
               call lesmodels(yold,  acold,     shgl,      shp, 
     &                        iper,  ilwork,    rowp,      colm,
     &                        nsons, ifath,     x,   
     &                        iBC,   BC )
            endif

c.... set traction BCs for modeled walls
c
            if (itwmod.ne.0) then
               call asbwmod(yold,   acold,   x,      BC,     iBC,
     &                      iper,   ilwork,  ifath)
            endif

c
c.... Determine whether the vorticity field needs to be computed for this time step or not
c
            call seticomputevort
c
c.... -----------------------> predictor phase <-----------------------
c
            call itrPredict(yold, y,   acold,  ac ,  uold,  u, iBC)
            call itrBC (y,  ac,  iBC,  BC,  iper,ilwork)
            if(nsolt.eq.1) then
               isclr=0
               call itrBCSclr (y, ac,  iBC, BC, iper, ilwork)
            endif
            do isclr=1,nsclr
               call itrBCSclr (y, ac,  iBC, BC, iper, ilwork)
            enddo
            iter=0
            ilss=0  ! this is a switch thrown on first solve of LS redistance
c
c set the initial tolerance for the redistance loop
c
            if (i_redist_loop_flag.eq.1) then
              redist_toler_previous = 100.0
            endif
c
c LOOP OVER SEQUENCES
c
            istepc = 1
            iloop = .true.
            i_redist_counter=0
!            do istepc=1,seqsize
             do while (iloop) 
              icode=stepseq(istepc)
c
              if(mod(icode,5).eq.0) then ! this is a solve
                isolve=icode/10
                if(icode.eq.0) then ! flow solve (encoded as 0)
c
                  iter   = iter+1
                  ifuncs(1)  = ifuncs(1) + 1
c     
                  Force(1) = zero
                  Force(2) = zero
                  Force(3) = zero
                  HFlux    = zero
                  lhs = 1 - min(1,mod(ifuncs(1)-1,LHSupd(1))) 

                  call itrYAlpha( uold,    yold,    acold,
     &                u,       y,       ac,
     &                uAlpha,  yAlpha,  acAlpha)

            
                  if(usingpetsc.eq.1) then
#ifdef HAVE_PETSC
                    call SolFlowp(yAlpha,     acAlpha,   uAlpha,
     &                         x,             iBC,
     &                         BC,            res,
     &                         iper,          
     &                         ilwork,        shp,       shgl,
     &                         shpb,          shglb,     rowp,
     &                         colm,    
     &                         solinc,        rerr,      tcorecp,
     &                         GradV,      
     &                         fncorp)
#else
                  write(*,*) 'requested PETSc but not built for it'
                  call error('itrdrv  ','noPETSc',usingpetsc)  
               
#endif
                  else
                  
                    if(iRelTol.eq.1) then
                        if((nitr.gt.1).and.(iter.eq.nitr)) then
                           if(myrank.eq.master.and.istep.eq.1) then
                              write(*,*) 
     &                            'Changing solver tolerance'
                           endif
                           lesId=1
#ifdef SP_Solve
                           tolFactSP=tolFact
                           epstolSP=epstol
                           prestolSP=prestol
                           call resetTol(lesId, tolFactSP*epstolSP(1), tolFactSP*prestolSP) 
                        else
                          lesId=1
                         call resetTol( lesId, epstolSP(1), prestolSP)
#else
                           call resetTol(lesId, tolFact*epstol(1), tolFact*prestol) 
                        else
                          lesId=1
                         call resetTol( lesId, epstol(1), prestol)
#endif
                        endif 
                    endif
                    call SolFlow(yAlpha,     acAlpha,   uAlpha,
     &                         x,             iBC,
     &                         BC,            res,
     &                         iper,          
     &                         ilwork,        shp,       shgl,
     &                         shpb,          shglb,     rowp,     
     &                         colm,         
     &                         solinc,        rerr,      tcorecp,
     &                         GradV     
#ifdef HAVE_SVLS
     &                         ,svLS_lhs,     svLS_ls,  svLS_nFaces)
#else
     &                         )
#endif      
                  endif
                  
                else          ! scalar type solve
                  if (icode.eq.5) then ! Solve for Temperature
                                ! (encoded as (nsclr+1)*10)
                        isclr=0
                        ifuncs(2)  = ifuncs(2) + 1
                        j=1
                  else       ! solve a scalar  (encoded at isclr*10)
                        isclr=isolve  
                        ifuncs(isclr+2)  = ifuncs(isclr+2) + 1
                        j=isclr+nsolt
c  Modify psuedo time step based on CFL number for redistancing
                        if((iLSet.eq.2).and.(ilss.ge.1).and.
     &                     (i_dtlset_cfl.eq.1).and.
     &                     (isclr.eq.2)) then
                           call calc_deltau()
                           Delt(1) = dtlset ! psuedo time step for level set
                           Dtgl = one / Delt(1)
                           ilss = ilss+1
                        endif
c
                        if((iLSet.eq.2).and.(ilss.eq.0)
     &                       .and.(isclr.eq.2)) then 
                           ilss=1 ! throw switch (once per step)
                           y(:,7)=y(:,6) ! redistance field initialized
                           ac(:,7)   = zero
                           if (iSolvLSSclr2.eq.2)  then
!COMING SOON                             call get_bcredist(x,y,iBCredist,BCredist,
!COMING SOON     &                                      primvert, primvertval(:,1))
                             primvertval(:,1) = BCredist(:)
                             ib=5+isclr
                             ibb=ib+1
                             do inode = 1, nshg
                              if (iBCredist(inode).eq.1) then
                               if (btest(iBC(inode),ib)) then
                                write(*,*) "WARNING -- Bit 7 already set"
                               endif
                              endif
                             enddo
c
                             where (iBCredist.eq.1) 
                              iBC(:) = iBC(:) + 128   ! set scalar 2 (bit 7)    
                              BC(:,ibb) = BCredist(:)
                             endwhere
                             numpv = 0
                             numpvset = 0
                             do inode = 1, nshg
                               if (primvert(inode) .gt. 0) then
                               numpv = numpv + 1
                                 if (primvert(inode).eq.2) then
                                   numpvset = numpvset + 1
                                 endif
                               endif
                             enddo
                             write(*,*) lstep+1,
     &                                  " Primary Verts: set/exist = ",
     &                                  numpvset, numpv
                           endif
                           call itrBCSclr (  y,  ac,  iBC,  BC, iper,
     &                          ilwork)
c     
c....store the flow alpha, gamma parameter values and assigm them the 
c....Backward Euler parameters to solve the second levelset scalar
c     
                           alfit=alfi
                           gamit=gami
                           almit=almi
                           Deltt=Delt(1)
                           Dtglt=Dtgl
                           alfi = 1
                           gami = 1
                           almi = 1
c     Delt(1)= Deltt ! Give a pseudo time step
                           Delt(1) = dtlset ! psuedo time step for level set
                           Dtgl = one / Delt(1)
                        endif  ! level set eq. 2
                  endif ! deciding between temperature and scalar

                  lhs = 1 - min(1,mod(ifuncs(isclr+2)-1,
     &                                LHSupd(isclr+2))) 
                  if((isclr.eq.1.and.iSolvLSSclr1.eq.1) .or. 
     &               (isclr.eq.2.and.iSolvLSSclr2.eq.1) .or.
     &               (isclr.eq.2.and.iSolvLSSclr2.eq.2)) then
                      lhs=0
                      call SolSclrExp(y,          ac,        yold,
     &                         acold,         x,         iBC,
     &                         BC,            nPermDimsS,nTmpDimsS,  
     &                         apermS(1,1,j), atempS,    iper,          
     &                         ilwork,        shp,       shgl,
     &                         shpb,          shglb,     rowp,     
     &                         colm,          lhsS(1,j), 
     &                         solinc(1,isclr+5), CFLls)
                  else
                      if (iRANS.eq.-5.and.iSAIC.eq.1
     &                    .and.istep.eq.0.and.iter.eq.1.and.isclr.eq.1) then ! set SST k-w from SA solution
                         if (myrank.eq.master) 
     &                         write(*,*) 'Using SA solution as IC'
                         ! k=nut*S/sqrt(C_mu) and w=max(S/sqrt(C_mu),U/L)
                         rnu = datmat(1,2,1)/datmat(1,1,1)
                         chi = y(:,6)/rnu
                         fv1 = chi**3 / (chi**3 + saCv1**3)
                         nut = max(y(:,6)*fv1,1.0d-4*rnu)
                         tmp1 = GradV(:,1) ** 2 + GradV(:,2) ** 2
     &                         + GradV(:,3) ** 2 + GradV(:,4) ** 2
     &                         + GradV(:,5) ** 2 + GradV(:,6) ** 2
     &                         + GradV(:,7) ** 2 + GradV(:,8) ** 2
     &                         + GradV(:,9) ** 2
                         tmp2 = GradV(:,1) ** 2 + GradV(:,5) ** 2
     &                         + GradV(:,9) ** 2 + 2*(
     &                           GradV(:,2)*GradV(:,4)
     &                           + GradV(:,3)*GradV(:,7)
     &                           + GradV(:,6)*GradV(:,8))
                         ss = 0.50*(tmp1+tmp2)
                         ssq = sqrt(two*ss)
                         tmp = one/sqrt(CmuKW)
                         y(:,6) = nut*ssq*tmp
                         y(:,7) = max(ssq*tmp,sstU/sstL)
                         yold(:,6) = y(:,6)
                         yold(:,7) = y(:,7)
                         ac(:,6:7) = zero
                         acold(:,6:7) = zero
                         call itrBCSclr (y, ac,  iBC, BC, iper, ilwork)
                         call itrBCSclr (yold, acold,  iBC, BC, iper, ilwork)
                      endif
                      call itrYAlpha( uold,    yold,    acold,
     &                                u,       y,       ac,
     &                                uAlpha,  yAlpha,  acAlpha)
               
                      if(usingpetsc.eq.1) then
#ifdef HAVE_PETSC
                        call SolSclrp( yAlpha,      acAlpha,
     &                                 x,             iBC,
     &                                 BC,            
     &                                 iper,          
     &                                 ilwork,        shp,       shgl,
     &                                 shpb,          shglb,     rowp,
     &                                 colm,          res,
     &                                 solinc(1,isclr+5), tcorecpscal,
     &                                 fncorp)
#else
                        write(*,*)'requested PETSc but not built for it'
                        call error('itrdrv  ','noPETSc',usingpetsc)  
#endif
                      else
                        call SolSclr(yAlpha,      acAlpha,
     &                         x,             iBC,
     &                         BC,            
     &                         iper,          
     &                         ilwork,        shp,       shgl,
     &                         shpb,          shglb,     rowp,     
     &                         colm,          
     &                         solinc(1,isclr+5), tcorecpscal, CFLls
#ifdef HAVE_SVLS
     &                         ,svLS_lhs_S(isclr),   svLS_ls_S(isclr), svls_nfaces,
     &                         GradV )
#else
     &                         , GradV )
#endif
                      endif !implicit petsc or else
                  endif     ! explicity or implicit if/else
                endif         ! end of scalar type solve

              else ! this is an update  (mod did not equal zero)
                iupdate=icode/10  ! what to update
                if(icode.eq.1) then !update flow  
                  call itrCorrect ( y,    ac,    u,   solinc, iBC)
                  call itrBC (y,  ac,  iBC,  BC, iper, ilwork)
                else  ! update scalar
                  isclr=iupdate  !unless
                  if(icode.eq.6) isclr=0
                  if((iRANS.eq.-5).and.(iClipKW.eq.1)) then
                    if (iClipKWMeth.eq.1) then
                      call itrCorrectSclrPos(y,ac,solinc(1,isclr+5))
                    elseif (iClipKWMeth.eq.2) then
                      call itrCorrectSclrRelax(y,ac,solinc(1,isclr+5))
                    endif
                  else
                    call itrCorrectSclr (y, ac, solinc(1,isclr+5))
                  endif
                  if (ilset.eq.2 .and. isclr.eq.2)  then
                    if (ivconstraint .eq. 1) then
                      call itrBCSclr (  y,  ac,  iBC,  BC, iper,
     &                          ilwork)
c                    
c ... applying the volume constraint on second level set scalar
c
                      call solvecon (y,    x,      iBC,  BC, 
     &                          iper, ilwork, shp,  shgl)
c
                    endif   ! end of volume constraint calculations
                  endif      ! end of redistance calculations
c                     
                  call itrBCSclr (  y,  ac,  iBC,  BC, iper,
     &                       ilwork)
c
c ... update the old value for second level set scalar
c
                     if (ilset.eq.2 .and. isclr.eq.2)  then
!was COMING SOON???                         call itrUpdateDist( yold, acold, y, ac)
                         call itrUpdateDist( yold, acold, y, ac)
                     endif   

                     endif      ! end of flow or scalar update
                  endif         ! end of switch between solve or update
c
c** Conditions for Redistancing Loop **
c Here we test to see if the following conditions are met:
c	no. of redistance iterations < i_redist_max_iter
c	residual (redist_toler_curr) > redist_toler
c If these are true then we continue in the redistance loop
c
                 if(i_redist_loop_flag.eq.1) then
                   if (icode .eq. 21) then ! only check after a redistance update
                     if((ilset.eq.2).and.(isclr.eq.2)) then !redistance condition
                      if ((redist_toler_curr.gt.redist_toler).or.(i_redist_counter.lt.20)) then !condition 1
                       if (i_redist_counter.lt.i_redist_max_iter) then ! condition 2
                        i_redist_counter = i_redist_counter + 1
                        istepc = istepc - 2  ! repeat the 20 21 step
                        if(redist_toler_curr.gt.redist_toler_previous)
     &                  then
                         if(myrank.eq.master) then
                          write(*,*) "Warning: diverging!"
                         endif
                        endif
                       else
                        iloop = .false. 
                        if(myrank.eq.master) then  
                         write(*,*) "Exceeded Max # of the iterations: "
     &                              , i_redist_max_iter
                        endif
                       endif
                       redist_toler_previous=redist_toler_curr
                      else
                       if(myrank.eq.master) then
                        write(*,*) "Redistance loop converged in ",
     &                       i_redist_counter," iterations"
                       endif
                       iloop = .false. 
                      endif
                     endif
                   endif !end of the redistance condition
                 endif !end of the condition for the redistance loop
c
                 if (istepc .eq. seqsize) then
                   iloop = .false.
                 endif
                 istepc = istepc + 1
c
c**End of loop condition for Redistancing equation**
c		 		  
               end do      ! end while loop over sequence steps


c
c Check if interface has moved into region of larger interface
c
             if ((iLSet.eq.2).and.(i_check_prox.eq.1)) then 
!COMING SOON               call check_proximity(y, stopjob)
	       if(stopjob.ne.0) then
                   lstep = lstep + 1
                   goto 2001
               endif
             endif          
     
c
c.... obtain the time average statistics
c
            if (ioform .eq. 2) then
               icode=0 ! needed so that tauC and tauBar are computed again
               call stsGetStats( y,      yold,     ac,     acold,
     &                           u,      uold,     x,
     &                           shp,    shgl,     shpb,   shglb,
     &                           iBC,    BC,       iper,   ilwork,
     &                           rowp,   colm)
            endif

c     
c  Find the solution at the end of the timestep and move it to old
c
c  
c ...First to reassign the parameters for the original time integrator scheme
c
            if((iLSet.eq.2).and.(ilss.eq.1)) then 
               alfi =alfit
               gami =gamit
               almi =almit 
               Delt(1)=Deltt
               Dtgl =Dtglt
            endif          
!           if((myrank.eq.0) .and. 
!     &   ((CFLfl_max .gt. 1.0).or.(mod(lstep+1,ntout).eq.0))) then
           if((myrank.eq.0)) then 
            write(*,7001) 'CFL Flow  Step  CFLfl_max  dt',
     &                    lstep+1, CFLfl_max, delt(itseq)
           endif
           if((myrank.eq.0) .and. (iLSet.eq.2) .and.   
     &   ((CFLls_max .gt. 1.0).or.(mod(lstep+1,ntout).eq.0))) then
            write(*,7001) 'CFL LS    Step  CFLls_max  dt',
     &                    lstep+1, CFLls_max, dtlset
           endif
 7001      format(a42,1p,i8,e10.3,e10.3)
            call itrUpdate( yold,  acold,   uold,  y,    ac,   u)
            call itrBC (yold, acold,  iBC,  BC,  iper,ilwork)

            istep = istep + 1
            lstep = lstep + 1
c
c ..  Print memory consumption on BGQ
c
            call printmeminfo("itrdrv"//char(0))
c
c...Reset BC codes of primary vertices
c (need to remove dirchlet bc on primary vertices
c  by removing the 8th bit (val=128)
c
            if((iLSet.eq.2).and.(ilss.eq.1).and.(iSolvLSSclr2.eq.2))
     &      then
               where (iBCredist.eq.1)
                 iBC(:) = iBC(:) - 128   ! remove prescription on scalar 2
               endwhere
            endif
c
c ..  Compute vorticity 
c
            if ( icomputevort == 1) 
     &        call computeVort( vorticity, GradV,strain)
c
c.... update and the aerodynamic forces
c
            call forces ( yold,  ilwork )
c ... update the flow history for the impedance convolution, filter it and write it out
c    
            if(numImpSrfs.gt.zero) then
               call UpdHistConv(y,nsrflistImp,numImpSrfs) !uses Delt(1)
            endif

c 
c ... update the flow history for the RCR convolution
c    
            if(numRCRSrfs.gt.zero) then
               call UpdHistConv(y,nsrflistRCR,numRCRSrfs) !uses lstep
            endif


c...  dump TIME SERIES
            
            if (exts) then
              ! Note: freq is only defined if exts is true,
              ! i.e. if xyzts.dat is present in the #-procs_case
              if ( mod(lstep-1,freq).eq.0) call dumpTimeSeries()
            endif

            if((irscale.ge.0).or.(itwmod.gt.0)
     &                       .or.(ispanAvg.eq.1)) then 
                 call getvel (yold,     ilwork, iBC,
     &                        nsons,    ifath)
                 call getStsBar(yold, GradV, ilwork, nsons, ifath, iBC)
                 if (ispanIDDES.eq.1) then 
                   call getIDDESbar(ilwork, nsons, ifath, iBC)
                 endif
            endif

            if((irscale.ge.0).and.(myrank.eq.master)) then
               call genscale(yold,       x,       iper, 
     &                       iBC,     ifath, nsons)
        endif
c.... -------------------> error calculation  <-----------------
c 
            if(ierrcalc.eq.1 .or. ioybar.eq.1) 
     &       call collectErrorYbar(ybar,yold,wallssVec,wallssVecBar,
     &               vorticity,yphbar,rerr,irank2ybar,irank2yphbar)
c

c .. write out the instantaneous solution
2001    continue  ! we could get here by 2001 label if user requested stop
        if (((irs .ge. 1) .and. (mod(lstep, ntout) .eq. 0)) .or.
     &      istep.eq.nstep(itseq)) then
!so that we can see progress in force file close it so that it flushes
!and  then reopen in append mode
           close(iforce)
           open (unit=iforce, file=fforce, position='append')
           if(output_mode .eq. -1 ) then ! this is an in-memory adapt case
             if(istep == nstp) then ! go ahead and take care of it
               call  checkpoint (yold,ac,acold,uold,x,shp, shgl, shpb, 
     &                       shglb,ilwork, iBC,BC,iper,wallsvec,
     &                       rerr,ybar,wallssVecBar,yphbar,
     &                       vorticity,irank2ybar,irank2yphbar,istp)
             endif
             if(ntout.le.lstep) then ! user also wants file output
                  output_mode=0   ! only writing posix for now
                 call  checkpoint (yold,ac,acold,uold,x,shp, shgl, shpb, 
     &                       shglb,ilwork, iBC,BC,iper,wallsvec,
     &                       rerr,ybar,wallssVecBar,yphbar,
     &                       vorticity,irank2ybar,irank2yphbar,istp)
                  output_mode=-1 ! reset to stream 
             endif
           else
!             if (numpe.gt.1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             call checkpoint (yold,ac,acold,uold,x,shp, shgl, shpb, 
     &                       shglb,ilwork, iBC,BC,iper,wallsvec,
     &                       rerr,ybar,wallssVecBar,yphbar,
     &                       vorticity,irank2ybar,irank2yphbar,istp)
!             if (numpe.gt.1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
           endif
        endif
        !next 2 lines are two ways to end early
        if(stopjob.eq.-2) goto 2002    
        if(istop.eq.1000) goto 2002 ! stop when delta small (see rstatic)
 2000 continue ! nstp loop
 2002 continue
        call clearDoubleRunCheck()

! done with time stepping so deallocate fields already written
!
        if ((iDNS.gt.0).and.(itwmod.eq.-2)) then
          deallocate ( effvisc )
        endif
          deallocate(elem_local_size)
          deallocate(elemb_local_size)

          deallocate ( gmass )
 
          if(ioybar.eq.1) then
            deallocate(ybar)
            if(abs(itwmod).ne.1 .and. iowflux.eq.1) then
              deallocate(wallssVecbar)
            endif
            if(nphasesincycle .gt. 0) then
              deallocate(yphbar)
            endif !nphasesincyle
          endif !ioybar
          if(ivort == 1) then
            deallocate(strain,vorticity)
          endif
          if(abs(itwmod).ne.1 .and. iowflux.eq.1) then
            deallocate(wallssVec) 
          endif
          if(iRANS.lt.0.or.iSTG.eq.1) then
            deallocate(d2wall)
          endif

          if(iSTG.eq.1) deallocate(STGrnd)

          if (ispanIDDES.eq.1) deallocate(IDDESfung)

!         if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
         if(myrank.eq.0)  then
            tcorecp2 = TMRC()
             write(6,*) 'T(core) cpu = ',tcorecp2-tcorecp1
             write(6,*) '(Elm. form.',tcorecp(1),
     &                    ',Lin. alg. sol.',tcorecp(2),')'
             write(6,*) '(Elm. form. Scal.',tcorecpscal(1),
     &                   ',Lin. alg. sol. Scal.',tcorecpscal(2),')'
             write(6,*) ''

         endif

         call print_system_stats(tcorecp, tcorecpscal)
         call print_mesh_stats()
         call print_mpi_stats()
         if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
!         return
c         call MPI_Finalize()
c         call MPI_ABORT(MPI_COMM_WORLD, ierr)

         call destroyWallData
         call destroyfncorp
c
c.... close history and aerodynamic forces files
c
      if (myrank .eq. master) then
!         close (ihist)
         close (iforce)
         close(76)
         if(numImpSrfs.gt.0 .or. numRCRSrfs.gt.0) then
            close (8177)
         endif
      endif
c
c.... close varts file for probes
c
      call finalizeTimeSeries()

!      if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
      if(myrank.eq.0)  then
          write(*,*) 'itrdrv - done with aerodynamic forces'
      endif

      do isrf = 0,MAXSURF
        if ( nsrflist(isrf).ne.0 .and.
     &                     myrank.eq.irankfilesforce(isrf)) then
          iunit=60+isrf
          close(iunit)
        endif
      enddo

!      if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
      if(myrank.eq.0)  then
          write(*,*) 'itrdrv - done with MAXSURF'
      endif


 5    format(1X,F15.10,3X,F15.10,3X,F15.10,3X,F15.10)
 444  format(6(2x,e14.7))
c
c.... end
c
      if(nsolflow.eq.1) then
         call dsdF
      endif
      if((nsclr+nsolt).gt.0) then
         call dsdS
      endif

      if(iabc==1) deallocate(acs)

!      if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
      if(myrank.eq.0)  then
          write(*,*) 'itrdrv - done - BACK TO process.f'
      endif

      return
      end
      
      subroutine lesmodels(y,     ac,        shgl,      shp, 
     &                     iper,  ilwork,    rowp,      colm,    
     &                     nsons, ifath,     x,   
     &                     iBC,   BC )
      
      include "common.h"

      real*8    y(nshg,ndof),              ac(nshg,ndof),           
     &            x(numnp,nsd),
     &            BC(nshg,ndofBC)
      real*8    shp(MAXTOP,maxsh,MAXQPT),  
     &            shgl(MAXTOP,nsd,maxsh,MAXQPT)

c
      integer   rowp(nshg,nnz),         colm(nshg+1),
     &            iBC(nshg),
     &            ilwork(nlwork),
     &            iper(nshg)
      dimension ifath(nshg),    nsons(ndistsons)

      real*8, allocatable, dimension(:) :: fwr2,fwr3,fwr4
      real*8, allocatable, dimension(:) :: stabdis,cdelsq1
      real*8, allocatable, dimension(:,:) :: xavegt, xavegt2,xavegt3

      if( (iLES.gt.1) )   then ! Allocate Stuff for advanced LES models
         allocate (fwr2(nshg))
         allocate (fwr3(nshg))
         allocate (fwr4(nshg))
         allocate (xavegt(nfath,12))
         allocate (xavegt2(nfath,12))
         allocate (xavegt3(nfath,12))
         allocate (stabdis(nfath))
      endif

c.... get dynamic model coefficient
c
      ilesmod=iLES/10  
c
c digit bit set filter rule, 10 bit set model
c
      if (ilesmod.eq.0) then    ! 0 < iLES< 10 => dyn. model calculated
                                ! at nodes based on discrete filtering


         if(isubmod.eq.2) then
            call SUPGdis(y,      ac,        shgl,      shp, 
     &                   iper,   ilwork,    
     &                   nsons,  ifath,     x,   
     &                   iBC,    BC, stabdis, xavegt3)
         endif

         if( ((isubmod.eq.0).or.(isubmod.eq.2)))then ! If no
                                                     ! sub-model
                                                     ! or SUPG
                                                     ! model wanted

            if(i2filt.eq.0)then ! If simple filter
              
               if(modlstats .eq. 0) then ! If no model stats wanted
                  call getdmc (y,       shgl,      shp, 
     &                         iper,       ilwork,    nsons,
     &                         ifath,      x )
               else             ! else get model stats 
                  call stdfdmc (y,       shgl,      shp, 
     &                          iper,       ilwork,    nsons,
     &                          ifath,      x)
               endif            ! end of stats if statement  

            else                ! else if twice filtering

               call widefdmc(y,       shgl,      shp, 
     &                       iper,       ilwork,    nsons,
     &                       ifath,      x)

               
            endif               ! end of simple filter if statement

         endif                  ! end of SUPG or no sub-model if statement


         if( (isubmod.eq.1) ) then ! If DFWR sub-model wanted
            call cdelBHsq (y,       shgl,      shp, 
     &                     iper,       ilwork,    nsons,
     &                     ifath,      x,         cdelsq1)
            call FiltRat (y,       shgl,      shp, 
     &                    iper,       ilwork,    nsons,
     &                    ifath,      x,         cdelsq1,
     &                    fwr4,       fwr3)

            
            if (i2filt.eq.0) then ! If simple filter wanted
               call DFWRsfdmc(y,       shgl,      shp, 
     &                        iper,       ilwork,    nsons,
     &                        ifath,      x,         fwr2, fwr3) 
            else                ! else if twice filtering wanted 
               call DFWRwfdmc(y,       shgl,      shp, 
     &                        iper,       ilwork,    nsons,
     &                        ifath,      x,         fwr4, fwr4) 
            endif               ! end of simple filter if statement
             
         endif                  ! end of DFWR sub-model if statement

         if( (isubmod.eq.2) )then ! If SUPG sub-model wanted
            call dmcSUPG (y,           ac,         shgl,      
     &                    shp,         iper,       ilwork,    
     &                    nsons,       ifath,      x,
     &                    iBC,    BC,  rowp,       colm,
     &                    xavegt2,    stabdis)
         endif

         if(idis.eq.1)then      ! If SUPG/Model dissipation wanted
            call ediss (y,        ac,      shgl,      
     &                  shp,      iper,       ilwork,    
     &                  nsons,    ifath,      x,
     &                  iBC,      BC,  xavegt)
         endif

      endif                     ! end of ilesmod
      
      if (ilesmod .eq. 1) then  ! 10 < iLES < 20 => dynamic-mixed
                                ! at nodes based on discrete filtering
         call bardmc (y,       shgl,      shp, 
     &                iper,    ilwork,    
     &                nsons,   ifath,     x) 
      endif
      
      if (ilesmod .eq. 2) then  ! 20 < iLES < 30 => dynamic at quad
                                ! pts based on lumped projection filt. 

         if(isubmod.eq.0)then
            call projdmc (y,       shgl,      shp, 
     &                    iper,       ilwork,    x) 
         else
            call cpjdmcnoi (y,      shgl,      shp, 
     &                      iper,   ilwork,       x,
     &                      rowp,   colm, 
     &                      iBC,    BC)
         endif

      endif

      if( (iLES.gt.1) )   then ! Deallocate Stuff for advanced LES models
         deallocate (fwr2)
         deallocate (fwr3)
         deallocate (fwr4)
         deallocate (xavegt)
         deallocate (xavegt2)
         deallocate (xavegt3)
         deallocate (stabdis)
      endif
      return
      end

c
c...initialize the coefficients for the impedance convolution
c
      subroutine CalcImpConvCoef (numISrfs, numTpoints)

      use convolImpFlow !uses flow history and impedance for convolution
      
      include "common.h" !for alfi
      
      integer numISrfs, numTpoints      

      allocate (ConvCoef(numTpoints+2,3)) !same time discret. for all imp. BC
      do j=1,numTpoints+2
         ConvCoef(j,:)=0.5/numTpoints !dt/2 divided by period T=N*dt
         ConvCoef(j,1)=ConvCoef(j,1)*(1.0-alfi)*(1.0-alfi)
         ConvCoef(j,2)=ConvCoef(j,2)*(1.0+2*alfi*(1.0-alfi))
         ConvCoef(j,3)=ConvCoef(j,3)*alfi*alfi
      enddo
      ConvCoef(1,2)=zero
      ConvCoef(1,3)=zero
      ConvCoef(2,3)=zero
      ConvCoef(numTpoints+1,1)=zero
      ConvCoef(numTpoints+2,2)=zero
      ConvCoef(numTpoints+2,1)=zero  
c
c...calculate the coefficients for the impedance convolution
c 
      allocate (ImpConvCoef(numTpoints+2,numISrfs))

c..coefficients below assume Q linear in time step, Z constant
c            do j=3,numTpoints
c                ImpConvCoef(j,:) = ValueListImp(j-1,:)*ConvCoef(j,3)
c     &                             + ValueListImp(j,:)*ConvCoef(j,2)    
c     &                             + ValueListImp(j+1,:)*ConvCoef(j,1)  
c            enddo
c            ImpConvCoef(1,:) = ValueListImp(2,:)*ConvCoef(1,1)
c            ImpConvCoef(2,:) = ValueListImp(2,:)*ConvCoef(2,2)    
c     &                       + ValueListImp(3,:)*ConvCoef(2,1)
c            ImpConvCoef(numTpoints+1,:) =
c     &           ValueListImp(numTpoints,:)*ConvCoef(numTpoints+1,3)
c     &         + ValueListImp(numTpoints+1,:)*ConvCoef(numTpoints+1,2) 
c            ImpConvCoef(numTpoints+2,:) = 
c     &           ValueListImp(numTpoints+1,:)*ConvCoef(numTpoints+2,3)

c..try easiest convolution Q and Z constant per time step
      do j=3,numTpoints+1
         ImpConvCoef(j,:) = ValueListImp(j-1,:)/numTpoints
      enddo
      ImpConvCoef(1,:) =zero
      ImpConvCoef(2,:) =zero
      ImpConvCoef(numTpoints+2,:) = 
     &           ValueListImp(numTpoints+1,:)/numTpoints
c compensate for yalpha passed not y in Elmgmr()
      ImpConvCoef(numTpoints+1,:)= ImpConvCoef(numTpoints+1,:)
     &                  - ImpConvCoef(numTpoints+2,:)*(1.0-alfi)/alfi 
      ImpConvCoef(numTpoints+2,:)= ImpConvCoef(numTpoints+2,:)/alfi 
      return
      end

c 
c ... update the flow rate history for the impedance convolution, filter it and write it out
c    
      subroutine UpdHistConv(y,nsrfIdList,numSrfs)
      
      use convolImpFlow !brings ntimeptpT, QHistImp, QHistTry, QHistTryF, numImpSrfs
      use convolRCRFlow !brings QHistRCR, numRCRSrfs

      include "common.h" 
      
      integer   nsrfIdList(0:MAXSURF), numSrfs
      character*20 fname1
      character*10 cname2
      character*5 cname
      real*8    y(nshg,3) !velocity at time n+1   
      real*8    NewQ(0:MAXSURF) !temporary unknown for the flow rate
                        !that needs to be added to the flow history 

      call GetFlowQ(NewQ,y,nsrfIdList,numSrfs) !new flow at time n+1
c
c... for imp BC: shift QHist, add new constribution, filter and write out
c      
      if(numImpSrfs.gt.zero) then
         do j=1, ntimeptpT
            QHistImp(j,1:numSrfs)=QHistImp(j+1,1:numSrfs)
         enddo
         QHistImp(ntimeptpT+1,1:numSrfs) = NewQ(1:numSrfs)

c
c....filter the flow rate history
c
         cutfreq = 10           !hardcoded cutting frequency of the filter
         do j=1, ntimeptpT
            QHistTry(j,:)=QHistImp(j+1,:)
         enddo
         call Filter(QHistTryF,QHistTry,ntimeptpT,Delt(1),cutfreq)
c.... if no filter applied then uncomment next three lines
c         do j=1, ntimeptpT
c            QHistTryF(j,:)=QHistTry(j,:)
c         enddo

c         QHistImp(1,:)=zero ! why do we do this? for beta(1,:) = zero it does not really matters
         do j=1, ntimeptpT
            QHistImp(j+1,:)=QHistTryF(j,:)
         enddo
c
c.... write out the new history of flow rates to Qhistor.dat
c      
         if (((irs .ge. 1) .and. ((mod(lstep, ntout) .eq. 0) .or.
     &        (istep .eq. nstep(1)))) .and.
     &        (myrank .eq. master)) then
            open(unit=816, file='Qhistor.dat',status='replace')
            write(816,*) ntimeptpT
            do j=1,ntimeptpT+1
               write(816,*) (QHistImp(j,n),n=1, numSrfs)
            enddo
            close(816)
c... write out a copy with step number to be able to restart
            fname1 = 'Qhistor'
            fname1 = trim(fname1)//trim(cname2(lstep))//'.dat'
            open(unit=8166,file=trim(fname1),status='unknown')
            write(8166,*) ntimeptpT
            do j=1,ntimeptpT+1
               write(8166,*) (QHistImp(j,n),n=1, numSrfs)
            enddo
            close(8166)
         endif
      endif 

c
c... for RCR bc just add the new contribution
c
      if(numRCRSrfs.gt.zero) then
         QHistRCR(lstep+1,1:numSrfs) = NewQ(1:numSrfs)
c
c.... write out the new history of flow rates to Qhistor.dat
c      
         if ((irs .ge. 1) .and. (myrank .eq. master)) then
            if(istep.eq.1) then
               open(unit=816,file='Qhistor.dat',status='unknown')
            else
               open(unit=816,file='Qhistor.dat',position='append')
            endif
            if(istep.eq.1) then
               do j=1,lstep
                  write(816,*) j, (QHistRCR(j,n),n=1,numSrfs) ! read from file of previous run
               enddo
            endif
            write(816,*) lstep+1, (QHistRCR(lstep+1,n),n=1, numSrfs)
            close(816)
c... write out a copy with step number to be able to restart
            if (((irs .ge. 1) .and. ((mod(lstep, ntout) .eq. 0) .or.
     &           (istep .eq. nstep(1)))) .and.
     &           (myrank .eq. master)) then
               fname1 = 'Qhistor'
               fname1 = trim(fname1)//trim(cname2(lstep))//'.dat'
               open(unit=8166,file=trim(fname1),status='unknown')
               write(8166,*) lstep+1 
               do j=1,lstep+1
                  write(8166,*) (QHistRCR(j,n),n=1, numSrfs)
               enddo
               close(8166)
            endif
         endif
      endif
      
      return
      end

c
c...calculate the time varying coefficients for the RCR convolution
c
      subroutine CalcRCRConvCoef (stepn, numSrfs)

      use convolRCRFlow !brings in ValueListRCR, dtRCR
      
      include "common.h" !brings alfi
      
      integer numSrfs, stepn    

      RCRConvCoef = zero
      if (stepn .eq. 0) then
        RCRConvCoef(1,:) = ValueListRCR(1,:)*(1.0-alfi) +
     &   ValueListRCR(3,:)*(-alfi + 1.0 + 1/dtRCR(:) 
     &     - exp(-alfi*dtRCR(:))*(1 + 1/dtRCR(:)))
        RCRConvCoef(2,:) = ValueListRCR(1,:)*alfi 
     &     + ValueListRCR(3,:)
     &     *(alfi - 1/dtRCR(:) + exp(-alfi*dtRCR(:))/dtRCR(:))
      endif
      if (stepn .ge. 1) then
        RCRConvCoef(1,:) =-ValueListRCR(3,:)*exp(-dtRCR(:)*(stepn+alfi))
     &        *(1 + (1 - exp(dtRCR(:)))/dtRCR(:))
        RCRConvCoef(stepn+1,:) = ValueListRCR(1,:)*(1-alfi) 
     &     - ValueListRCR(3,:)*(alfi - 1 - 1/dtRCR(:) 
     &     + exp(-alfi*dtRCR(:))/dtRCR(:)*(2 - exp(-dtRCR(:))))
        RCRConvCoef(stepn+2,:) = ValueListRCR(1,:)*alfi 
     &     + ValueListRCR(3,:)
     &     *(alfi - 1/dtRCR(:) + exp(-alfi*dtRCR(:))/dtRCR(:))
      endif
      if (stepn .ge. 2) then
        do j=2,stepn
         RCRConvCoef(j,:) = ValueListRCR(3,:)/dtRCR(:)*
     &        exp(-dtRCR(:)*(stepn + alfi + 2 - j))*
     &        (1 - exp(dtRCR(:)))**2
        enddo
      endif

c compensate for yalpha passed not y in Elmgmr()
      RCRConvCoef(stepn+1,:)= RCRConvCoef(stepn+1,:)
     &                  - RCRConvCoef(stepn+2,:)*(1.0-alfi)/alfi 
      RCRConvCoef(stepn+2,:)= RCRConvCoef(stepn+2,:)/alfi 

      return
      end

c
c...calculate the time dependent H operator for the RCR convolution
c
      subroutine CalcHopRCR (timestepRCR, stepn, numSrfs)

      use convolRCRFlow !brings in HopRCR, dtRCR

      include "common.h"

      integer numSrfs, stepn      
      real*8  PdistCur(0:MAXSURF), timestepRCR
      
      HopRCR=zero
      call RCRint(timestepRCR*(stepn + alfi),PdistCur)
      HopRCR(1:numSrfs) = RCRic(1:numSrfs) 
     &     *exp(-dtRCR(1:numSrfs)*(stepn + alfi)) + PdistCur(1:numSrfs)
      return
      end
c 
c ... initialize the influence of the initial conditions for the RCR BC
c    
      subroutine calcRCRic(y,srfIdList,numSrfs)
      
      use convolRCRFlow    !brings RCRic, ValueListRCR, ValuePdist

      include "common.h"
      
      integer   srfIdList(0:MAXSURF), numSrfs, irankCoupled
      real*8    y(nshg,4) !need velocity and pressure
      real*8    Qini(0:MAXSURF) !initial flow rate
      real*8    PdistIni(0:MAXSURF) !initial distal pressure
      real*8    Pini(0:MAXSURF),CoupleArea(0:MAXSURF) ! initial pressure
      real*8    VelOnly(nshg,3), POnly(nshg)

      allocate (RCRic(0:MAXSURF))

      if(lstep.eq.0) then
         VelOnly(:,1:3)=y(:,1:3)
         call GetFlowQ(Qini,VelOnly,srfIdList,numSrfs) !get initial flow
         QHistRCR(1,1:numSrfs)=Qini(1:numSrfs) !initialize QHistRCR
         POnly(:)=y(:,4)        ! pressure
         call integrScalar(Pini,POnly,srfIdList,numSrfs) !get initial pressure integral
         POnly(:)=one           ! one to get area
         call integrScalar(CoupleArea,POnly,srfIdList,numSrfs) !get surf area
         Pini(1:numSrfs) = Pini(1:numSrfs)/CoupleArea(1:numSrfs)
      else
         Qini(1:numSrfs)=QHistRCR(1,1:numSrfs)
         Pini(1:numSrfs)=zero    ! hack
      endif
      call RCRint(istep,PdistIni) !get initial distal P (use istep)
      RCRic(1:numSrfs) = Pini(1:numSrfs) 
     &          - ValueListRCR(1,:)*Qini(1:numSrfs)-PdistIni(1:numSrfs)
      return
      end

c.........function that integrates a scalar over a boundary
      subroutine integrScalar(scalInt,scal,srfIdList,numSrfs)

      use pvsQbi !brings ndsurf, NASC

      include "common.h"
      include "mpif.h"
      
      integer   srfIdList(0:MAXSURF), numSrfs, irankCoupled, i, k
      real*8    scal(nshg), scalInt(0:MAXSURF), scalIntProc(0:MAXSURF)
      
      scalIntProc = zero
      do i = 1,nshg
        if(numSrfs.gt.zero) then
          do k = 1,numSrfs
            irankCoupled = 0
            if (srfIdList(k).eq.ndsurf(i)) then
              irankCoupled=k
              scalIntProc(irankCoupled) = scalIntProc(irankCoupled)
     &                            + NASC(i)*scal(i)
              exit
            endif      
          enddo       
        endif
      enddo
c      
c     at this point, each scalint has its "nodes" contributions to the scalar
c     accumulated into scalIntProc. Note, because NASC is on processor this
c     will NOT be the scalar for the surface yet
c
c.... reduce integrated scalar for each surface, push on scalInt
c
        npars=MAXSURF+1
       call MPI_ALLREDUCE (scalIntProc, scalInt(:), npars,
     &        MPI_DOUBLE_PRECISION,MPI_SUM, MPI_COMM_WORLD,ierr)  
   
      return
      end

      subroutine writeTimingMessage(key,iomode,timing)
      use iso_c_binding
      use phstr
      implicit none

      character(len=*) :: key
      integer :: iomode
      real*8 :: timing
      character(len=1024) :: timing_msg
      character(len=*), parameter ::
     &  streamModeString = c_char_"stream"//c_null_char,
     &  fileModeString = c_char_"disk"//c_null_char

      timing_msg = c_char_"Time to write "//c_null_char
      call phstr_appendStr(timing_msg,key)
      if ( iomode .eq. -1 ) then
        call phstr_appendStr(timing_msg, streamModeString)
      else
        call phstr_appendStr(timing_msg, fileModeString)
      endif
      call phstr_appendStr(timing_msg, c_char_' = '//c_null_char)
      call phstr_appendDbl(timing_msg, timing)
      write(6,*) trim(timing_msg)
      return
      end subroutine

      subroutine initmpistat()
        include "common.h"

        impistat = 0
        impistat2 = 0
        iISend = 0
        iISendScal = 0
        iIRecv = 0
        iIRecvScal = 0
        iWaitAll = 0
        iWaitAllScal = 0
        iAllR = 0
        iAllRScal = 0
        rISend = zero
        rISendScal = zero
        rIRecv = zero
        rIRecvScal = zero
        rWaitAll = zero
        rWaitAllScal = zero
        rAllR = zero
        rAllRScal = zero
        rCommu = zero
        rCommuScal = zero
      return
      end subroutine

      subroutine initTimeSeries()
      use timedata   !allows collection of time series
        include "common.h"
       character*60    fvarts
       character*10    cname2

        inquire(file='xyzts.dat',exist=exts)
        if(exts) then
           open(unit=626,file='xyzts.dat',status='old')
           read(626,*) ntspts, freq, tolpt, iterat, varcod
           call sTD             ! sets data structures
           
           do jj=1,ntspts       ! read coordinate data where solution desired
              read(626,*) ptts(jj,1),ptts(jj,2),ptts(jj,3)
           enddo
           close(626)

           statptts(:,:) = 0
           parptts(:,:) = zero
           varts(:,:) = zero           


           iv_rankpernode = iv_rankpercore*iv_corepernode
           iv_totnodes = numpe/iv_rankpernode
           iv_totcores = iv_corepernode*iv_totnodes
           if (myrank .eq. 0) then
             write(*,*) 'Info for probes:'
             write(*,*) '  Ranks per core:',iv_rankpercore
             write(*,*) '  Cores per node:',iv_corepernode 
             write(*,*) '  Ranks per node:',iv_rankpernode
             write(*,*) '  Total number of nodes:',iv_totnodes
             write(*,*) '  Total number of cores',iv_totcores
           endif

!           if (myrank .eq. numpe-1) then
            do jj=1,ntspts

               ! Compute the adequate rank which will take care of probe jj
               jjm1 = jj-1
               iv_node = (iv_totnodes-1)-mod(jjm1,iv_totnodes)
               iv_core = (iv_corepernode-1) - mod((jjm1 - 
     &              mod(jjm1,iv_totnodes))/iv_totnodes,iv_corepernode)
               iv_thread = (iv_rankpercore-1) - mod((jjm1- 
     &              (mod(jjm1,iv_totcores)))/iv_totcores,iv_rankpercore)
               iv_rank(jj) = iv_node*iv_rankpernode 
     &                     + iv_core*iv_rankpercore
     &                     + iv_thread
                 
               if(myrank == 0) then
                 write(*,*) '  Probe', jj, 'handled by rank',
     &                         iv_rank(jj), ' on node', iv_node
               endif

               ! Verification just in case
               if(iv_rank(jj) .lt.0 .or. iv_rank(jj) .ge. numpe) then 
                 write(*,*) 'WARNING: iv_rank(',jj,') is ', iv_rank(jj),
     &                      ' and reset to numpe-1'
                 iv_rank(jj) = numpe-1
               endif

               ! Open the varts files
               if(myrank == iv_rank(jj)) then
                 fvarts='varts/varts'
                 fvarts=trim(fvarts)//trim(cname2(jj))
                 fvarts=trim(fvarts)//trim(cname2(lstep))
                 fvarts=trim(fvarts)//'.dat'
                 fvarts=trim(fvarts)
                 open(unit=1000+jj, file=fvarts, status='unknown')
               endif
            enddo
!           endif

        endif
c
      return
      end subroutine

      subroutine finalizeTimeSeries()
      use timedata   !allows collection of time series
      include "common.h"
      if(exts) then
        do jj=1,ntspts
          if (myrank == iv_rank(jj)) then
            close(1000+jj)
          endif
        enddo
        call dTD   ! deallocates time series arrays
      endif
      return
      end subroutine



       subroutine initEQS(iBC, rowp, colm,svLS_nFaces,
     2               svLS_LHS,svLS_ls,
     3               svLS_LHS_S,svLS_ls_S)

        use solvedata
        use fncorpmod
        include "common.h"
#ifdef HAVE_SVLS        
        include "svLS.h"
        include "mpif.h"
        include "auxmpi.h"

        TYPE(svLS_lhsType) svLS_lhs
        TYPE(svLS_lsType) svLS_ls
        TYPE(svLS_commuType) communicator
        TYPE(svLS_lsType) svLS_ls_S(4)
        TYPE(svLS_lhsType) svLS_lhs_S(4)
        TYPE(svLS_commuType) communicator_S(4)
        INTEGER svLS_nFaces, gnNo, nNo, faIn, facenNo
#endif
        integer, allocatable :: gNodes(:)
        real*8, allocatable :: sV(:,:)
#ifdef SP_Solve
        real*4 epstolSP(6),prestolSP
#endif
        character*1024    servername
        integer   rowp(nshg,nnz),         colm(nshg+1),
     &            iBC(nshg)
#ifdef HAVE_LESLIB
        integer eqnType
!      IF (svLSFlag .EQ. 0) THEN  !When we get a PETSc option it also could block this or a positive leslib
        call SolverLicenseServer(servername)
!      ENDIF
#endif
c     
c.... For linear solver Library
c
c
c.... assign parameter values
c     
        do i = 1, 100
           numeqns(i) = i
        enddo
c
c.... determine how many scalar equations we are going to need to solve
c
      nsolt=mod(impl(1),2)      ! 1 if solving temperature
      nsclrsol=nsolt+nsclr      ! total number of scalars solved At
! some point we probably want to create a map, considering stepseq(), to find
! what is actually solved and only  dimension lhs to the appropriate
! size. (see 1.6.1 and earlier for a "failed" attempt at this).

      nsolflow=mod(impl(1),100)/10  ! 1 if solving flow
c
c.... Now, call lesNew routine to initialize
c     memory space
c
      call genadj(colm, rowp, icnt )  ! preprocess the adjacency list

      nnz_tot=icnt ! this is exactly the number of non-zero blocks on
                   ! this proc

      if (nsolflow.eq.1) then  ! start of setup for the flow
        lesId   = numeqns(1)
        eqnType = 1
        nDofs   = 4
!     Setting up svLS or leslib for flow
        IF (svLSFlag .EQ. 1) THEN
! ifdef svLS_1 : opening large ifdef for svLS solver setup
#ifdef HAVE_SVLS 
          call aSDf
          IF(nPrjs.eq.0) THEN
            svLSType=2  !GMRES if borrowed ACUSIM projection vectors variable set to zero
          ELSE
            svLSType=3 !NS solver
          ENDIF
!  reltol for the NSSOLVE is the stop criterion on the outer loop
!  reltolIn is (eps_GM, eps_CG) from the CompMech paper
!  for now we are using 
!  Tolerance on ACUSIM Pressure Projection for CG and
!  Tolerance on Momentum Equations for GMRES
! also using Kspaceand maxIters from setup for ACUSIM
!
          eps_outer=40.0*epstol(1)  !following papers soggestion for now
          CALL svLS_LS_CREATE(svLS_ls, svLSType, dimKry=Kspace,
     2      relTol=eps_outer, relTolIn=(/epstol(1),prestol/), 
     3      maxItr=maxIters, 
     4      maxItrIn=(/maxIters,maxIters/))

          CALL svLS_COMMU_CREATE(communicator, MPI_COMM_WORLD)
          nNo=nshg
          gnNo=nshgt
          IF  (ipvsq .GE. 2) THEN

#if((VER_CORONARY == 1)&&(VER_CLOSEDLOOP == 1))
               svLS_nFaces = 1 + numResistSrfs + numNeumannSrfs 
     2            + numImpSrfs + numRCRSrfs + numCORSrfs
#elif((VER_CORONARY == 1)&&(VER_CLOSEDLOOP == 0))
               svLS_nFaces = 1 + numResistSrfs
     2            + numImpSrfs + numRCRSrfs + numCORSrfs
#elif((VER_CORONARY == 0)&&(VER_CLOSEDLOOP == 1))
               svLS_nFaces = 1 + numResistSrfs + numNeumannSrfs 
     2            + numImpSrfs + numRCRSrfs
#else
               svLS_nFaces = 1 + numResistSrfs
     2            + numImpSrfs + numRCRSrfs
#endif

          ELSE
               svLS_nFaces = 1   !not sure about this...looks like 1 means 0 for array size issues
          END IF

          CALL svLS_LHS_CREATE(svLS_lhs, communicator, gnNo, nNo,
     2         nnz_tot, ltg, colm, rowp, svLS_nFaces)

          faIn = 1
          facenNo = 0
          DO i=1, nshg
               IF (IBITS(iBC(i),3,3) .NE. 0)  facenNo = facenNo + 1
          END DO
          ALLOCATE(gNodes(facenNo), sV(nsd,facenNo))
          sV = 0D0
          j = 0
          DO i=1, nshg
               IF (IBITS(iBC(i),3,3) .NE. 0) THEN
                  j = j + 1
                  gNodes(j) = i
                  IF (.NOT.BTEST(iBC(i),3)) sV(1,j) = 1D0
                  IF (.NOT.BTEST(iBC(i),4)) sV(2,j) = 1D0
                  IF (.NOT.BTEST(iBC(i),5)) sV(3,j) = 1D0
               END IF
          END DO
          CALL svLS_BC_CREATE(svLS_lhs, faIn, facenNo, 
     2         nsd, BC_TYPE_Dir, gNodes, sV)
          DEALLOCATE(gNodes)
          DEALLOCATE(sV)
! else of ifdef svLS_1 
#else
          if(myrank.eq.0) write(*,*) 'your input requests svLS but your cmake did not build for it'
          call error('itrdrv  ','nosVLS',svLSFlag)  
! endif of ifdef svLS_1 
#endif
        ENDIF !of svLS init. inside ifdef so we can trap above else
! note input_fform does not allow svLSFlag=1 AND leslib=1 so above or below only
#ifdef SP_Solve
        epstolSP=epstol
        prestolSP=prestol
#endif
        if(leslib.eq.1) then
! ifdef leslib_1 : setup for leslib
#ifdef HAVE_LESLIB 
!--------------------------------------------------------------------
          call myfLesNew( lesId,   41994,
     &                 eqnType,
     &                 nDofs,          minIters,       maxIters,
     &                 Kspace,         iprjFlag,        nPrjs,
#ifdef SP_Solve
     &                 ipresPrjFlag,    nPresPrjs,      epstolSP(1),
     &                 prestolSP,        iverbose,      statsflow,
#else
     &                 ipresPrjFlag,    nPresPrjs,      epstol(1),
     &                 prestol,        iverbose,        statsflow,
#endif
     &                 nPermDims,      nTmpDims,      servername  )
          call aSDf  
          call readLesRestart( lesId,  aperm, nshg, myrank, lstep,
     &                        nPermDims ) 
! else leslib_1 
#else
          if(myrank.eq.0) write(*,*) 'your input requests leslib but your cmake did not build for it'
          call error('itrdrv  ','nolslb',leslib)       
! endif leslib_1 
#endif
        endif !leslib=1

      else   ! not solving flow at all so set it solverDims to zero
         nPermDims = 0
         nTmpDims = 0
      endif

!Above is setup for flow now we do scalar
 
      if(nsclrsol.gt.0) then
       do isolsc=1,nsclrsol ! this loop sets up unique data for each scalar solved
         lesId       = numeqns(isolsc+1)
         eqnType     = 2
         nDofs       = 1
         isclpresPrjflag = 0        
         isclrnPresPrjs   = 0       
         isclprjFlag     = 1
         indx=isolsc+2-nsolt ! complicated to keep epstol(2) for
                             ! temperature followed by scalars
!  ifdef svLS_2 :   Setting up svLS for scalar
#ifdef HAVE_SVLS
         IF (svLSFlag .EQ. 1) THEN
           svLSType=2  !only option for scalars
!  reltol for the GMRES is the stop criterion 
! also using Kspaceand maxIters from setup for ACUSIM
!
           CALL svLS_LS_CREATE(svLS_ls_S(isolsc), svLSType, 
     2      dimKry=Kspace,
     3      relTol=epstol(indx), 
     4      maxItr=maxIters 
     5      )

           CALL svLS_COMMU_CREATE(communicator_S(isolsc), 
     2       MPI_COMM_WORLD)
           
           svLS_nFaces = 1   !not sure about this...should try it with zero

           CALL svLS_LHS_CREATE(svLS_lhs_S(isolsc), 
     2         communicator_S(isolsc), gnNo, nNo,
     3         nnz_tot, ltg, colm, rowp, svLS_nFaces)
           
 
              faIn = 1
              facenNo = 0
              ib=5+isolsc
              DO i=1, nshg
                 IF (btest(iBC(i),ib))  facenNo = facenNo + 1
              END DO
              ALLOCATE(gNodes(facenNo), sV(1,facenNo))
              sV = 0D0
              j = 0
              DO i=1, nshg
               IF (btest(iBC(i),ib)) THEN
                  j = j + 1
                  gNodes(j) = i
               END IF
              END DO

           CALL svLS_BC_CREATE(svLS_lhs_S(isolsc), faIn, facenNo, 
     2         1, BC_TYPE_Dir, gNodes, sV(1,:))
           DEALLOCATE(gNodes)
           DEALLOCATE(sV)

         ENDIF  !svLS handing scalar solve
#endif        
        

#ifdef HAVE_LESLIB
         if (leslib.eq.1) then
         call myfLesNew( lesId,            41994,
     &                 eqnType,
     &                 nDofs,          minIters,       maxIters,
     &                 Kspace,         isclprjFlag,        nPrjs,
#ifdef SP_Solve
     &                 isclpresPrjFlag,isclrnPresPrjs,      epstolSP(indx),
     &                 prestolSP,        iverbose,        statssclr,
#else
     &                 isclpresPrjFlag,isclrnPresPrjs,      epstol(indx),
     &                 prestol,        iverbose,        statssclr,
#endif
     &                 nPermDimsS,     nTmpDimsS,   servername )
        endif
#endif
       enddo  !loop over scalars to solve  (not checked to worked out for multiple svLS solves
       call aSDs(nsclrsol)
      else !no scalar solves at all so zero dims not used
         nPermDimsS = 0
         nTmpDimsS  = 0
      endif
      return
      end subroutine


      subroutine seticomputevort
        include "common.h"
            icomputevort = 0
            if (ivort == 1) then ! Print vorticity = True in solver.inp
              ! We then compute the vorticity only if we 
              ! 1) we write an intermediate checkpoint
              ! 2) we reach the last time step and write the last checkpoint
              ! 3) we accumulate statistics in ybar for every time step
              ! BEWARE: we need here lstep+1 and istep+1 because the lstep and 
              ! istep gets incremened after the flowsolve, further below
              if (((irs .ge. 1) .and. (mod(lstep+1, ntout) .eq. 0)) .or.
     &                   istep+1.eq.nstep(itseq) .or. ioybar == 1) then
                icomputevort = 1
              endif
            endif

!            write(*,*) 'icomputevort: ',icomputevort, ' - istep: ',
!     &                istep,' - nstep(itseq):',nstep(itseq),'- lstep:',
!     &                lstep, '- ntout:', ntout
      return
      end subroutine

      subroutine computeVort( vorticity, GradV,strain)
        include "common.h"

        real*8 gradV(nshg,nsdsq), strain(nshg,6), vorticity(nshg,5)
 
              ! vorticity components and magnitude
              vorticity(:,1) = GradV(:,8)-GradV(:,6) !omega_x
              vorticity(:,2) = GradV(:,3)-GradV(:,7) !omega_y
              vorticity(:,3) = GradV(:,4)-GradV(:,2) !omega_z
              vorticity(:,4) = sqrt(   vorticity(:,1)*vorticity(:,1)
     &                               + vorticity(:,2)*vorticity(:,2)
     &                               + vorticity(:,3)*vorticity(:,3) )
              ! Q
              strain(:,1) = GradV(:,1)                  !S11
              strain(:,2) = 0.5*(GradV(:,2)+GradV(:,4)) !S12
              strain(:,3) = 0.5*(GradV(:,3)+GradV(:,7)) !S13
              strain(:,4) = GradV(:,5)                  !S22
              strain(:,5) = 0.5*(GradV(:,6)+GradV(:,8)) !S23
              strain(:,6) = GradV(:,9)                  !S33
 
              vorticity(:,5) = 0.25*( vorticity(:,4)*vorticity(:,4)  !Q
     &                            - 2.0*(      strain(:,1)*strain(:,1)
     &                                    + 2* strain(:,2)*strain(:,2)
     &                                    + 2* strain(:,3)*strain(:,3)
     &                                    +    strain(:,4)*strain(:,4)
     &                                    + 2* strain(:,5)*strain(:,5)
     &                                    +    strain(:,6)*strain(:,6)))

      return
      end subroutine

      subroutine dumpTimeSeries()
      use timedata   !allows collection of time series
      include "common.h"
      include "mpif.h"
       character*60    fvarts
       character*10    cname2
   
                  
                  if (numpe .gt. 1) then
                     do jj = 1, ntspts
                        vartssoln((jj-1)*ndof+1:jj*ndof)=varts(jj,:)
                        ivarts=zero
                     enddo
                     do k=1,ndof*ntspts
                        if(vartssoln(k).ne.zero) ivarts(k)=1
                     enddo

!                     call MPI_REDUCE(vartssoln, vartssolng, ndof*ntspts,
!     &                    MPI_DOUBLE_PRECISION, MPI_SUM, master,
!     &                    MPI_COMM_WORLD, ierr)

!                     call MPI_BARRIER(MPI_COMM_WORLD, ierr)
                     call MPI_ALLREDUCE(vartssoln, vartssolng, 
     &                    ndof*ntspts,
     &                    MPI_DOUBLE_PRECISION, MPI_SUM,
     &                    MPI_COMM_WORLD, ierr)

!                     call MPI_REDUCE(ivarts, ivartsg, ndof*ntspts,
!     &                    MPI_INTEGER, MPI_SUM, master,
!     &                    MPI_COMM_WORLD, ierr)

!                     call MPI_BARRIER(MPI_COMM_WORLD, ierr)
                     call MPI_ALLREDUCE(ivarts, ivartsg, ndof*ntspts,
     &                    MPI_INTEGER, MPI_SUM,
     &                    MPI_COMM_WORLD, ierr)

!                     if (myrank.eq.zero) then
                     do jj = 1, ntspts

                        if(myrank .eq. iv_rank(jj)) then 
                           ! No need to update all varts components, only the one treated by the expected rank
                           ! Note: keep varts as a vector, as multiple probes could be treated by one rank
                           indxvarts = (jj-1)*ndof
                           do k=1,ndof
                              if(ivartsg(indxvarts+k).ne.0) then ! none of the vartssoln(parts) were non zero
                                 varts(jj,k)=vartssolng(indxvarts+k)/
     &                                             ivartsg(indxvarts+k)
                              endif
                           enddo
                       endif !only if myrank eq iv_rank(jj)
                     enddo
!                     endif !only on master
                  endif !only if numpe > 1

!                  if (myrank.eq.zero) then
                  do jj = 1, ntspts
                     if(myrank .eq. iv_rank(jj)) then
                        ifile = 1000+jj
                        write(ifile,555) lstep, (varts(jj,k),k=1,ndof) !Beware of format 555 - check ndof 
c                        call flush(ifile)
                        if (((irs .ge. 1) .and. 
     &                       (mod(lstep, ntout) .eq. 0))) then
                           close(ifile)                     
                           fvarts='varts/varts'
                           fvarts=trim(fvarts)//trim(cname2(jj))
                           fvarts=trim(fvarts)//trim(cname2(lskeep))
                           fvarts=trim(fvarts)//'.dat'
                           fvarts=trim(fvarts)
                           open(unit=ifile, file=fvarts,
     &                          position='append')
                        endif !only when dumping restart
                     endif
                  enddo
!                  endif !only on master

                  varts(:,:) = zero ! reset the array for next step


!555              format(i6,5(2x,E12.5e2))
555               format(i6,6(2x,E20.12e2)) !assuming ndof = 6 here 

      return
      end subroutine

      subroutine collectErrorYbar(ybar,yold,wallssVec,wallssVecBar,
     &               vorticity,yphbar,rerr,irank2ybar,irank2yphbar)
      include "common.h"
      real*8 ybar(nshg,irank2ybar),yold(nshg,ndof),vorticity(nshg,5)
      real*8 yphbar(nshg,irank2yphbar,nphasesincycle)
      real*8 wallssvec(nshg,3),wallssVecBar(nshg,3), rerr(nshg,numerr)
      save iphase, istepsinybar, icyclesinavg
c$$$c
c$$$c compute average
c$$$c
c$$$               tfact=one/istep
c$$$               ybar =tfact*yold + (one-tfact)*ybar

c compute average
c ybar(:,1:3) are average velocity components
c ybar(:,4) is average pressure
c ybar(:,5) is average speed
c ybar(:,6:8) is average of sq. of each vel. component
c ybar(:,9) is average of sq. of pressure
c ybar(:,10:12) is average of cross vel. components : uv, uw and vw
c averaging procedure justified only for identical time step sizes
c ybar(:,13) is average of eddy viscosity
c ybar(:,14:16) is average vorticity components
c ybar(:,17) is average vorticity magnitude
c ybar(:,19) is average Q
c istep is number of time step
c
      icollectybar = 0
      if(nphasesincycle.eq.0 .or.
     &            istep.gt.ncycles_startphaseavg*nstepsincycle) then
               icollectybar = 1
               if((istep-1).eq.ncycles_startphaseavg*nstepsincycle)
     &               istepsinybar = 0 ! init. to zero in first cycle in avg.
               endif

               if(icollectybar.eq.1) then
                  istepsinybar = istepsinybar+1
                  tfact=one/istepsinybar

!                  if(myrank.eq.master .and. nphasesincycle.ne.0 .and.
!     &               mod((istep-1),nstepsincycle).eq.0)
!     &               write(*,*)'nsamples in phase average:',istepsinybar

c ybar to contain the averaged ((u,v,w),p)-fields
c and speed average, i.e., sqrt(u^2+v^2+w^2)
c and avg. of sq. terms including
c u^2, v^2, w^2, p^2 and cross terms of uv, uw and vw

                  ybar(:,1) = tfact*yold(:,1) + (one-tfact)*ybar(:,1)
                  ybar(:,2) = tfact*yold(:,2) + (one-tfact)*ybar(:,2)
                  ybar(:,3) = tfact*yold(:,3) + (one-tfact)*ybar(:,3)
                  ybar(:,4) = tfact*yold(:,4) + (one-tfact)*ybar(:,4)
                  ybar(:,5) = tfact*sqrt(yold(:,1)**2+yold(:,2)**2+
     &                        yold(:,3)**2) + (one-tfact)*ybar(:,5)
                  ybar(:,6) = tfact*yold(:,1)**2 +
     &                        (one-tfact)*ybar(:,6)
                  ybar(:,7) = tfact*yold(:,2)**2 +
     &                        (one-tfact)*ybar(:,7)
                  ybar(:,8) = tfact*yold(:,3)**2 +
     &                        (one-tfact)*ybar(:,8)
                  ybar(:,9) = tfact*yold(:,4)**2 +
     &                        (one-tfact)*ybar(:,9)
                  ybar(:,10) = tfact*yold(:,1)*yold(:,2) + !uv
     &                         (one-tfact)*ybar(:,10)
                  ybar(:,11) = tfact*yold(:,1)*yold(:,3) + !uw
     &                         (one-tfact)*ybar(:,11)
                  ybar(:,12) = tfact*yold(:,2)*yold(:,3) + !vw
     &                         (one-tfact)*ybar(:,12)
                  if(nsclr.gt.0) !nut or k for SST k-omega
     &             ybar(:,13) = tfact*yold(:,6) + (one-tfact)*ybar(:,13)
                  
                  if(ivort == 1) then !vorticity
                    ybar(:,14) = tfact*vorticity(:,1) + 
     &                           (one-tfact)*ybar(:,14)
                    ybar(:,15) = tfact*vorticity(:,2) + 
     &                           (one-tfact)*ybar(:,15)
                    ybar(:,16) = tfact*vorticity(:,3) + 
     &                           (one-tfact)*ybar(:,16)
                    ybar(:,17) = tfact*vorticity(:,4) + 
     &                           (one-tfact)*ybar(:,17)
                    ybar(:,18) = tfact*vorticity(:,5) + 
     &                           (one-tfact)*ybar(:,18)
                  endif

                  if (iRANS.eq.-5) then ! omega for SST k-omega model
                    ybar(:,irank2ybar) = tfact*yold(:,7) + 
     &                           (one-tfact)*ybar(:,irank2ybar)
                  endif
                  
                  if(abs(itwmod).ne.1 .and. iowflux.eq.1) then 
                    wallssVecBar(:,1) = tfact*wallssVec(:,1)
     &                                  +(one-tfact)*wallssVecBar(:,1)
                    wallssVecBar(:,2) = tfact*wallssVec(:,2)
     &                                  +(one-tfact)*wallssVecBar(:,2)
                    wallssVecBar(:,3) = tfact*wallssVec(:,3)
     &                                  +(one-tfact)*wallssVecBar(:,3)
                  endif
               endif !icollectybar.eq.1
c
c compute phase average
c
! 
! the following chunk of code will zero out the amplitude  for (iduty-1) cycles of the jet before 
! using the time varying amplitude computed above
!
            iphaseAvgOn=1
            iduty=idnint(rampmdot(2,2))
!MAKE ALWAYS FALSE>>>>WE NEED ALL STATS I THINK

            if(iduty.lt.-1) then
                r_freq=rampmdot(2,1)
! this one switches off on phase 24 and results in uneven number of phases per file                nperiods=r_freq*(lstep+1)*Delt(1)  ! compute period number of the current step. NOTE lstep step number across all runs
! hopefully fixed by removing the "+1" on lstep
                nperiods=r_freq*(lstep)*Delt(1)  ! compute period number of the current step. NOTE lstep step number across all runs
                imod=mod(nperiods,iduty)           ! will be the remeinder of nperiods/iduty
                if(imod.gt.0) iPhaseAvgOn=0        ! set to zero except for the period with no remainder
            endif
!            if(myrank.eq.0) write(*,*) 'iduty,nperiods,imod,iphaseAvgOn', iduty,nperiods,imod,iPhaseAvgOn

               if((nphasesincycle.ne.0 ).and.
     &            (istep.gt.ncycles_startphaseavg*nstepsincycle) .and.
     &            (iPhaseAvgOn.eq.1)) then

c beginning of cycle is considered as ncycles_startphaseavg*nstepsincycle+1
                  if((istep-1).eq.ncycles_startphaseavg*nstepsincycle)
     &               icyclesinavg = 0 ! init. to zero in first cycle in avg.

                  ! find number of steps between phases
                  nstepsbtwphase = nstepsincycle/nphasesincycle ! integer value
                  if(istep.eq.-10) then ! aborted attempt to fix
                    itest=mod(lstep-1,nstepsincyle) !8005/120=85
                    iphase=itest/nstepsbtwphase  ! 85/5 =17
                  endif
                  if(mod(istep-1,nstepsincycle).eq.0) then
                     iphase = 1 ! init. to one in beginning of every cycle icyclesinavg = icyclesinavg + 1
                  endif

                  icollectphase = 0
                  istepincycle = mod(istep,nstepsincycle)   ! 1/120=0
                  if(istepincycle.eq.0) istepincycle=nstepsincycle  !120
                  if(istepincycle.eq.iphase*nstepsbtwphase) then
                     icollectphase = 1
                     iphase = iphase+1 ! use 'iphase-1' below
                  endif

                  if(icollectphase.eq.1) then
                     tfactphase = one/icyclesinavg

                     if(myrank.eq.master) then
                       write(*,*) 'nsamples in phase ',iphase-1,': ',
     &                             icyclesinavg
                     endif

                     yphbar(:,1,iphase-1) = tfactphase*yold(:,1) +
     &                          (one-tfactphase)*yphbar(:,1,iphase-1)
                     yphbar(:,2,iphase-1) = tfactphase*yold(:,2) +
     &                          (one-tfactphase)*yphbar(:,2,iphase-1)
                     yphbar(:,3,iphase-1) = tfactphase*yold(:,3) +
     &                          (one-tfactphase)*yphbar(:,3,iphase-1)
                     yphbar(:,4,iphase-1) = tfactphase*yold(:,4) +
     &                          (one-tfactphase)*yphbar(:,4,iphase-1)
                     yphbar(:,5,iphase-1) = tfactphase*sqrt(yold(:,1)**2
     &                          +yold(:,2)**2+yold(:,3)**2) +
     &                          (one-tfactphase)*yphbar(:,5,iphase-1)
                     yphbar(:,6,iphase-1) = 
     &                              tfactphase*yold(:,1)*yold(:,1) 
     &                           +(one-tfactphase)*yphbar(:,6,iphase-1)

                     yphbar(:,7,iphase-1) = 
     &                              tfactphase*yold(:,1)*yold(:,2)
     &                           +(one-tfactphase)*yphbar(:,7,iphase-1)

                     yphbar(:,8,iphase-1) = 
     &                              tfactphase*yold(:,1)*yold(:,3)
     &                           +(one-tfactphase)*yphbar(:,8,iphase-1)

                     yphbar(:,9,iphase-1) = 
     &                              tfactphase*yold(:,2)*yold(:,2)
     &                           +(one-tfactphase)*yphbar(:,9,iphase-1)

                     yphbar(:,10,iphase-1) = 
     &                              tfactphase*yold(:,2)*yold(:,3)
     &                           +(one-tfactphase)*yphbar(:,10,iphase-1)

                     yphbar(:,11,iphase-1) = 
     &                              tfactphase*yold(:,3)*yold(:,3)
     &                           +(one-tfactphase)*yphbar(:,11,iphase-1)

                     if(ivort == 1) then
                       yphbar(:,12,iphase-1) = 
     &                              tfactphase*vorticity(:,1)
     &                           +(one-tfactphase)*yphbar(:,12,iphase-1)
                       yphbar(:,13,iphase-1) = 
     &                              tfactphase*vorticity(:,2)
     &                           +(one-tfactphase)*yphbar(:,13,iphase-1)
                       yphbar(:,14,iphase-1) = 
     &                              tfactphase*vorticity(:,3)
     &                           +(one-tfactphase)*yphbar(:,14,iphase-1)
                       yphbar(:,15,iphase-1) = 
     &                              tfactphase*vorticity(:,4)
     &                           +(one-tfactphase)*yphbar(:,15,iphase-1)
                       yphbar(:,16,iphase-1) = 
     &                              tfactphase*vorticity(:,5)
     &                           +(one-tfactphase)*yphbar(:,16,iphase-1)
                    endif
                  endif !compute phase average
      endif !if(nphasesincycle.eq.0 .or. istep.gt.ncycles_startphaseavg*nstepsincycle) 
c
c compute rms
c
      if(icollectybar.eq.1) then
! shift rerr so that if we are doing LS rerr(:,7) will be curvature and then rms quantities
!shift to 8-11
                 do j=1,4
                  ie=isurf+6+j
                  rerr(:, ie)=rerr(:, ie)+(yold(:,j)-ybar(:,j))**2
                 enddo
      endif
      return
      end subroutine

      subroutine checkpoint (yold,ac,acold,uold,x,shp, shgl, shpb, 
     &                       shglb,ilwork, iBC,BC,iper,wallsvec,
     &                       rerr,ybar,wallssVecBar,yphbar,
     &                       vorticity,irank2ybar,irank2yphbar,istp)
      use solvedata
      use turbSA 
      use STG_BC
      use spanStats
      use lesArrs
      include "common.h"
      include "mpif.h"
      include "auxmpi.h"

      dimension shp(MAXTOP,maxsh,MAXQPT),
     &            shgl(MAXTOP,nsd,maxsh,MAXQPT),
     &            iper(nshg),              iBC(nshg),
     &            x(nshg,nsd),         ilwork(nlwork)

      real*8    ac(nshg,ndof),          uold(nshg,nsd),           
     &            yold(nshg,ndof),      acold(nshg,ndof),
     &            BC(nshg,ndofBC), 
     &            shpb(MAXTOP,maxsh,MAXQPT),
     &            shglb(MAXTOP,nsd,maxsh,MAXQPT) 

      real*8 ybar(nshg,irank2ybar),vorticity(nshg,5)
      real*8 yphbar(nshg,irank2yphbar,nphasesincycle)
      real*8 wallssvec(nshg,3),wallssVecBar(nshg,3), rerr(nshg,numerr)
      integer istp

!              Call to restar() will open restart file in write mode (and not append mode)
!              that is needed as other fields are written in append mode
      call restar ('out ',  yold  ,ac)
c ...
c     If the conservative statistics are wanted, write them to restart
      if ( ioform.eq.2) call stsWriteStats(istp)
c ...
      if(ivort == 1) then 
             call write_field(myrank,'a','vorticity',9,vorticity,
     &                       'd',nshg,5,lstep)
      endif
      call printmeminfo("itrdrv after checkpoint"//char(0))
       !just the instantaneous stuff for videos above but for now we continue to do all
c.... compute the consistent boundary flux
      if(abs(itwmod).ne.1 .and. iowflux.eq.1) then
               call Bflux ( yold,      acold,      uold,    x,
     &                      shp,       shgl,       shpb,   
     &                      shglb,     ilwork,     iBC,
     &                      BC,        iper,       wallssVec)
      endif
c....  print out results.
      lesId   = numeqns(1)
!      if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
      if(myrank.eq.0)  then
        tcormr1 = TMRC()
      endif
      if((nsolflow.eq.1).and.(ipresPrjFlag.eq.1)) then
#ifdef HAVE_LESLIB
        call saveLesRestart( lesId,  aperm , nshg, myrank, lstep,
     &                    nPermDims )
!        if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if(myrank.eq.0)  then
          tcormr2 = TMRC()
          write(6,*) 'call saveLesRestart for projection and'//
     &         'pressure projection vectors', tcormr2-tcormr1
        endif
#endif 
      endif

      if(ierrcalc.eq.1) then
c.....smooth the error indicators
        do i=1,ierrsmooth
          call errsmooth( rerr, x, iper, ilwork, shp, shgl, iBC )
        end do
        call LSbandError(rerr,yold)
!        if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if(myrank.eq.0)  then
          tcormr1 = TMRC()
        endif
        call write_error(myrank, lstep, nshg, numerr, rerr )
!        if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if(myrank.eq.0)  then
          tcormr2 = TMRC()
          write(6,*) 'Time to write the error fields to the disks',
     &        tcormr2-tcormr1
        endif
      endif ! ierrcalc
      if(ioybar.eq.1) then
          call write_field(myrank,'a','ybar',4,
     &              ybar,'d',nshg,irank2ybar,lstep)
        if(abs(itwmod).ne.1 .and. iowflux.eq.1) then
          call write_field(myrank,'a','wssbar',6,
     &         wallssVecBar,'d',nshg,3,lstep)
        endif

        if(nphasesincycle .gt. 0) then
!          if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
          if(myrank.eq.0)  then
            tcormr1 = TMRC()
          endif
          do iphase=1,nphasesincycle
              call write_phavg2(myrank,'a','phase_average',13,iphase,
     &          nphasesincycle,yphbar(:,:,iphase),'d',nshg,irank2yphbar,lstep)
          end do
!          if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
          if(myrank.eq.0)  then
            tcormr2 = TMRC()
            write(6,*) 'write all phase avg to the disks = ',
     &            tcormr2-tcormr1
          endif
        endif !nphasesincyle
      endif !ioybar
      if(iRANS.lt.0.or.iSTG.eq.1) then
!        if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if(myrank.eq.0)  then
          tcormr1 = TMRC()
        endif
        call write_field(myrank,'a','dwal',4,d2wall,'d',
     &                   nshg,1,lstep)
!        if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if(myrank.eq.0)  then
          tcormr2 = TMRC()
          write(6,*) 'Time to write dwal to the disks = ',
     &    tcormr2-tcormr1
        endif
      endif !iRANS or iSTG

cc....    Write the STG fields to be read in the next run
c         STGrnd(:,1:3)=dVect
c         STGrnd(:,4)=phiVect
c         STGrnd(:,5:7)=sigVect        
          if(iSTG.eq.1) then
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr1 = TMRC()
            endif
cc ......   Write the STG random variables
            call write_field(myrank,'a','STG_rnd',7,STGrnd,'d',
     &                       nKWave,7,lstep)
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write STG_rnd to the disks = ',
     &        tcormr2-tcormr1
            endif

!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr1 = TMRC()
            endif
cc ......   Write the BC array. Quick fix to problem with inflow BC in geombc files
            call write_field(myrank,'a','BCs',3,BC,'d',
     &                       nshg,ndofBC,lstep)
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write BCs to the disks = ',
     &        tcormr2-tcormr1
            endif

          endif ! end of STG fields

cc ....   Write velbar if wanted
          if (ispanAvg.eq.1) then
             if(myrank.eq.0)  then
              tcormr1 = TMRC()
             endif

             if (myrank.eq.master) then
                ifail = 0
                call rwvelb('out ',velbar,ifail) ! write the velbar field to a file
                if (ifail.ne.0) write(*,*) 
     &                            'Problem writing velbar to file'
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write velbar to the disks = ',
     &        tcormr2-tcormr1
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)

          endif
c
cc ....   Write span avg stats if wanted
          if (ispanAvg.eq.1) then
!             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             if(myrank.eq.0)  then
              tcormr1 = TMRC()
             endif

             if (myrank.eq.master) then
                ifail = 0
                call wstsBar(ifail) ! write the stsBar field to a file
                if (ifail.ne.0) write(*,*) 
     &                            'Problem writing stsBar to file'
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write stsBar to the disks = ',
     &        tcormr2-tcormr1
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)

          endif
c
cc ....   Write span avg stats for K eq if wanted
          if (ispanAvg.eq.1.and.iKeq.eq.1) then
!             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             if(myrank.eq.0)  then
              tcormr1 = TMRC()
             endif
 
             if (myrank.eq.master) then
                ifail = 0
                call wstsBarKeq(ifail) ! write the stsBar field to a file
                if (ifail.ne.0) write(*,*) 
     &                            'Problem writing stsBarKeq to file'
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
             if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write stsBarKeq to the disks = ',
     &        tcormr2-tcormr1
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)

          endif
c
cc ....   Write span avg IDDES functions
          if (ispanAvg.eq.1.and.ispanIDDES.eq.1) then
!             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD,ierr)
             if(myrank.eq.0)  then
              tcormr1 = TMRC()
             endif

             if (myrank.eq.master) then
                ifail = 0
                call wIDDESbar(ifail) ! write the IDDESbar field to a file
                if (ifail.ne.0) write(*,*)
     &                            'Problem writing IDDESbar to file'
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD,ierr)
             if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write IDDESbar to the disks = ',
     &        tcormr2-tcormr1
             endif
             if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD,ierr)
          endif
c
cc ..... Write the eddy viscosity when doing a dynamic Smag LES (iLES=1)
          if (iLES.gt.0) then
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr1 = TMRC()
            endif
            call write_field(myrank,'a','cdelsq',6,cdelsq,'d',
     &                       nshg,3,lstep)
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write cdelsq to the disks = ',
     &        tcormr2-tcormr1
            endif
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr1 = TMRC()
            endif
            call write_field(myrank,'a','lesnut',6,lesnut,'d',
     &                       numel,2,lstep)
!            if (numpe .gt. 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
            if(myrank.eq.0)  then
              tcormr2 = TMRC()
              write(6,*) 'Time to write lesnut to the disks = ',
     &        tcormr2-tcormr1
            endif
          endif
cc ....  End of iLES conditional

      return
      end subroutine

      subroutine redistLoopDecision(i_redist_counter,istepc,
     &              redist_toler_previous,iloop)
      include "common.h"
      logical iloop
c
c** Conditions for Redistancing Loop **
c Here we test to see if the following conditions are met:
c	no. of redistance iterations < i_redist_max_iter
c	residual (redist_toler_curr) > redist_toler
c If these are true then we continue in the redistance loop
c
                 if(i_redist_loop_flag.eq.1) then
                   if (icode .eq. 21) then ! only check after a redistance update
                     if((ilset.eq.2).and.(isclr.eq.2)) then !redistance condition
                      if (redist_toler_curr.gt.redist_toler) then !condition 1
                       if (i_redist_counter.lt.i_redist_max_iter) then ! condition 2
                        i_redist_counter = i_redist_counter + 1
                        istepc = istepc - 2  ! repeat the 20 21 step
                        if(redist_toler_curr.gt.redist_toler_previous)
     &                  then
                         if(myrank.eq.master) then
! it is explicit....diverging is not tested by residual                          write(*,*) "Warning: diverging!"
                         endif
                        endif
                       else
                        iloop = .false. 
                        if(myrank.eq.master) then  
                         write(*,*) "Exceeded Max # of the iterations: "
     &                              , i_redist_max_iter
                        endif
                       endif
                       redist_toler_previous=redist_toler_curr
                      else
                       if(myrank.eq.master) then
                        write(*,*) "Redistance loop converged in ",
     &                       i_redist_counter," iterations"
                       endif
                       iloop = .false. 
                      endif
                     endif
                   endif !end of the redistance condition
                 endif !end of the condition for the redistance loop
c
                 if (istepc .eq. seqsize) then
                   iloop = .false.
                 endif
                 istepc = istepc + 1
      return
      end subroutine

      subroutine LSbandError(rerr,yold)
      use spat_var_eps   ! use spatially-varying epl_ls
      include "common.h"
      include "mpif.h"
      include "auxmpi.h"
      real*8 errmax, errmaxg,sumELS,sumELSg
      real*8 rerr(nshg,numerr),yold(nshg,ndof)
               if(isurf.eq.1) then
!depricated                 dxold=0.0035 ! initial mesh size  problem dependent
!depricated                 nbuf=5 ! this sets how many elment layers (original mesh size) to refine
!
! This could easily be made multi-banded (e.g. dxold/2 for 10 layers  dxold/4 for 3 layers,  dxold/8 for error
! but the idea is that these bands allow us to run for some time before needing to refine.
! It could also be made smarter to use the local velocity of the interface  to determine which direction from the
! interface to refine more/less (e.g. use current normal and velocity information to predict where the interface
! will be in 50 (or other N) steps and then refine in the region between current interface and N-step future 
! interface.
! NOTE with the advent of local refinement, we will have to be more careful with the time step of our VOF method
! Probably need to add local time stepping inner iteration to the VOF "solve" where we:
!  1) compute the worst CFL for VOF,
!  2) Determine the worst element time step,
!  3) Find the integer multiple of a smaller time step that will "land on" the flow's time step
!  4) Advance all VOF cells at that small time step for that integer number of time steps in correspondence to
!     each flow step
!  5) Potentially later we could do true local time stepping where element capable of a larger time step wait for 
!     smaller time step elements to complete their substeps but this is a pain to load balance  and coordinate and 
!     often not worth it for highly parallel problems.
! 
               errmax=maxval(abs(rerr(:,7)))
               !Find the maximum across parts
               if(numpe.gt.1) then
                 call MPI_ALLREDUCE(errmax, errmaxg, 1,
     &             MPI_DOUBLE_PRECISION, MPI_MAX, MPI_COMM_WORLD, ierr )
                 errmax = errmaxg
               endif
               Ethresh=dband(1)*errmax

!                 Ethresh=0.125  !This value comes from looking at ParaView, and finding an isosurface 
                               !value that encloses the high curvature region using the level set 
                               !limited function abs(rerr(:,10)/(1.0e-5+yold(:,6))
                 rerr(:,6)=esize(1) !dxold
                 where (abs(yold(:,6)).lt.dband(2)) ! dxold*nbuf)
                    rerr(:,6)=esize(2) ! dxold/two
                 endwhere
!                 where ((abs(rerr(:,7)/(1.0e-5+yold(:,6))).gt.Ethresh).and.(abs(yold(:,6)).lt.dxold*epsilon_ls*2))
                 where ((abs(rerr(:,7)).gt.Ethresh).and.(abs(yold(:,6)).lt.dband(3))) !   dxold*epsilon_ls*2))
                    rerr(:,6)=esize(3) ! dxold/four
                 endwhere
               endif
! As a rough go at addressing the above comments, there is now a variable substep
! For now, substep should be manually set to the maximum error denominator
! substep is set on line 360             if (numpe > 1) call MPI_BARRIER(MPI_COMM_WORLD, ierr)
      return
      end subroutine
