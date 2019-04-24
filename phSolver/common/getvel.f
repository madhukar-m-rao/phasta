      subroutine getvel (y,ilwork, iBC,
     &                   nsons, ifath, velbar)


      include "common.h"
      include "mpif.h"
      include "auxmpi.h"

c
      dimension nsons(nfath),        rinvsons(nfath),
     &          velo(nshg,nflow),    velf(nfath,nflow),
     &          velft(nfath,nflow),   
     &          velbar(nfath,nflow),
     &          y(nshg,ndof), 
     &          ifath(nshg),
     &          ilwork(nlwork),        iBC(nshg)
     
      integer periodicity      
      peroidicity = 0

c
c  for now keep the compressible numbering in velbar
c
      velo(:,1)=y(:,4)
      velo(:,2)=y(:,1)      
      velo(:,3)=y(:,2)
      velo(:,4)=y(:,3)
      if(nflow.eq.5) velo(:,5)=y(:,5)
      nsonmax=maxval(nsons)
      if ((nsonmax.eq.1)) then  ! we are doing local clipping -no homog dir
         velft=velo
      else
c     
c     zero on processor periodic nodes so that they will not be added twice
c    
         if(myrank.eq.master) then
            do i=1, nshg
               if(btest(iBC(i),10)) then 
                 periodicity = 1
                 exit
               endif
            enddo
         endif
         call MPI_BCAST(periodicity,1,MPI_INTEGER,master,
     &               MPI_COMM_WORLD,ierr)

         where(btest(iBC,10).or.btest(iBC,12))
            velo(:,1)=zero
            velo(:,2)=zero
            velo(:,3)=zero
            velo(:,4)=zero
         endwhere      
         if(nflow.eq.5) then
            where(btest(iBC,10).or.btest(iBC,12))
                velo(:,5)=zero
            endwhere
         endif         
         if (numpe.gt.1) then
            
            numtask = ilwork(1)
            itkbeg = 1
            
c     zero the nodes that are "solved" on the other processors  
            do itask = 1, numtask
               
               iacc   = ilwork (itkbeg + 2)
               numseg = ilwork (itkbeg + 4)
               
               if (iacc .eq. 0) then
                  do is = 1,numseg
                     isgbeg = ilwork (itkbeg + 3 + 2*is)
                     lenseg = ilwork (itkbeg + 4 + 2*is)
                     isgend = isgbeg + lenseg - 1
                     velo(isgbeg:isgend,:) = zero
                  enddo
               endif
               
               itkbeg = itkbeg + 4 + 2*numseg
               
            enddo !itask
            
         endif  ! numpe.gt.1

         
         velf = zero
c     
c     accumulate sum of sons to the fathers
c     
         do i = 1,nshg
            ifathi=ifath(i)
            velf(ifathi,1:nflow) = velf(ifathi,1:nflow) 
     &                             + velo(i,1:nflow)            
         enddo
         
c     
c     Now  the true fathers and serrogates combine results and update
c     each other.
c     
         if(numpe .gt. 1) then
            call drvAllreduce(velf, velft,nfath*nflow)
         else
            velft=velf
         endif
c     
c     xvelf is the sum of the sons for each father on this processor
c
c     xvelft is the sum of the sons for each father on all processor combined
c     (the same as if we had not partitioned the mesh for each processor)
c     
c     divide by # of sons to get average father for this step
c
         if (periodicity.eq.1.and.nohomog.eq.1) then
           rinvsons = one/(nsons-one)   ! division is expensive
         else
           rinvsons = one/nsons   ! division is expensive
         endif
         velft(:,1) = velft(:,1) * rinvsons(:) !  / nsons(:)
         velft(:,2) = velft(:,2) * rinvsons(:) !  / nsons(:)
         velft(:,3) = velft(:,3) * rinvsons(:) !  / nsons(:)
         velft(:,4) = velft(:,4) * rinvsons(:) !  / nsons(:)
         if(nflow.eq.5) velft(:,5) = velft(:,5) * rinvsons(:)
      endif  ! end of homog direction averaging

c      denom=max(one*(lstep),one)
c      if(wtavei.lt.0) then
c         tavef=one/denom
c      else
c         tavef=wtavei
c      endif
      
c      velbar(:,1)=velft(:,1)
c      velbar(:,2)=velft(:,2)
c      velbar(:,3)=velft(:,3)
c      velbar(:,4)=velft(:,4)

c      if(istep.eq.0) then
c         velbar(:,:)=velft(:,:)
c      else            
c         velbar(:,:)=tavef*velft(:,:)+(one-tavef)*velbar(:,:)        
c      endif

       den = max(1,lstep-istartSpanAvg)
       tfact = one/den
       velbar(:,:)=tfact*velft(:,:)+(one-tfact)*velbar(:,:)

      
      
      return
      end


