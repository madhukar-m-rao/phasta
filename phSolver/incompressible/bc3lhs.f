      subroutine bc3LHS (iBC,  BC,  iens,  xlhs )
c
c----------------------------------------------------------------------
c
c This routine satisfies the BC of LHS mass matrix for all  
c elements in this block.
c
c input:
c  iBC   (nshg)             : boundary condition code
c  BC    (nshg,ndofBC)      : Dirichlet BC constraint parameters
c  ien   (npro,nshape)      : ien array for this element
c  xlhs (bsz,16,nshl,nshl) : element consistent mass matrix before BC
c
c output:
c  xlhs (bsz,16,nshl,nshl) : LHS mass matrix after BC is satisfied
c
c
c Farzin Shakib, Winter 1987.
c Zdenek Johan,  Spring 1990. (Modified for general divariant gas)
c Ken Jansen, Summer 2000. Incompressible (only needed on xlhs)
c----------------------------------------------------------------------
c
      include "common.h"
c
      dimension iBC(nshg),      ien(npro,nshl)
      real*8 BC(nshg,ndofBC), xlhs(bsz,16,nshl,nshl)
      integer aa,b
      integer iens(npro,nshl)
c
c prefer to show explicit absolute value needed for cubic modes and
c higher rather than inline abs on pointer as in past versions
c iens is the signed ien array ien is unsigned
c
      ien=abs(iens)
 
c
c.... loop over elements
c
c        return
      do iel = 1, npro
c
c.... loop over number of shape functions for this element
c
        do inod = 1, nshl
c
c.... set up parameters
c
          in  = abs(ien(iel,inod))
! not sure what is wrong with this but it does not work.
! in reality one should never set dirichlet pressure BC's as it eliminated the continuity
! equation BAD and weak pressure always doees a better job
!
          if(usingpetsc.gt.20) then
            if(btest(ibc(in),2)) then
              xlhs(iel,4:12:4,:,inod) = zero   !take out row 4 of all rows for inod
              xlhs(iel,13:15,inod,:) = zero    !take out column 4 of all columns for inod
              xlhs(iel,16,inod,inod) = 1
            endif
          endif
              
          if (ibits(iBC(in),3,3) .eq. 0) goto 5000 ! NO velocity BC's
          if (ibits(iBC(in),3,3) .eq. 7) then !{ three components set
            if(usingpetsc.gt.-1) then ! { leaving conditional in to compare for leslib
! which does not really need this since preconditioner takes care of BC's

! first take care of the fact that since u,v,w are set on this node, 
! all columns (: in column) for this row (inod in row spot) must be zeroed 
! to make a trivial equation for this nodes three momentum eqns.
                    !for this inod row's xyz mom eqns  take out all the columns/delta 
              xlhs(iel,1: 3,inod,:) = zero  ! to delta u
              xlhs(iel,5: 7,inod,:) = zero  ! to delta v
              xlhs(iel,9:11,inod,:) = zero  ! to delta w
              xlhs(iel,13:15,inod,:)= zero  ! to delta p
! now we also want to be sure that all nodes coupling to this node (row blocks) know that 
! this is a constrained dof so we zero the entire column for the first 3 columns associated 
! with this node (inod in column now) for all rows (: in row spot)
                    !for this inod column, take out all eqns/rows dep on u,v,w delta
              xlhs(iel,1:12,:,inod) = zero  ! take out all eqns/rows dep on u,v,w delta

! note there is overlap...also that  13:16 not set for (:.ne.inod,inod) because the pressure
! may not be set on this inod and it can influence other nodes equations.  Likewise, 4:16:4 
! not set for (inod,:.ne.inod) because this captures inod's continuity dependence on other 
! nodes delta u variation

!finally make the diagonal 1 so that trivial equation of 1 delta u,v,w = 0 is formed
              xlhs(iel, 1,inod,inod) = one 
              xlhs(iel, 6,inod,inod) = one 
              xlhs(iel,11,inod,inod) = one 
            endif !usingpetsc conditional
            goto 5000 ! } 3  handled for PETSc
          endif ! } three components set 

c.... 1 or 2 component velocities
c
c
c.... x1-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 1) then
c
! we want to project out the x1 component of the velocity from the tangent  
! matix which is, mathematically, M^e = S^T M^e S. We will do the M^e S
! product first. It has the effect of
! subtracting the column of the block-9 matrix from each column of the block-9
! matrix  that is going to survive (weighted by the coefficient in the
! BC array associated with that row) FOR EACH column  of the
! nshl by nshl matrix FOR EACH element.  THEN the transpose of the
! operation is carried out (replace the word "column" by row
! EVERYWHERE). The following code has been set up so that we only have to 
! give the starting position in each case since we know the block-9 matrix is
! ordered like this   
!note as of 16-Sept-25  mapping this directly to 4x4 system to eliminate the need for
! xKebe....Suspect there was a  transpose problem here  that is fixed at same time

! index map
!xKebe -> xlhs
! 1:3  -> 1:3
! 4:6  -> 1:3
! 7:9  -> 1:3
! leaving the comments in xkebe 3x3 form but the above map explains 4x4 form

! yes this is pretty clearly the transposed numbering  
!OLD CODE COMMENT
!  1 2 3
!  4 5 6
!  7 8 9

! should be 
!  1 5 9
!  2 6 10
!  3 7 11


c
c  adjusting the second column for the eventual removal of the first
c  column of the block-9 submatrix
c
            irem1=1
            irem2=irem1+1
            irem3=irem2+1

            iadj1=5
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 

            enddo
! block status ' denotes colunn 1 projected off.
!  1 5' 9
!  2 6' 10
!  3 7' 11
c
c  adjusting the third column for the eventual removal of the first
c  column of the block-9 submatrix
c
            iadj1=9
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem3,i,inod) 
! block status
!  1 5' 9'
!  2 6' 10'
!  3 7' 11'
            enddo
            do i=1,nshl
c
c done with the first  columns_block-9 for columns AND rows of nshl
c
               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 


! block status
!  0 5' 9'
!  0 6' 10'
!  0 7' 11'

            enddo
c
c  now adjust the second row_block-9 for EACH row nshl for EACH element 
c

            iadj1=2
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=1
            irem2=irem1+4
            irem3=irem2+4
            do i = 1, nshl
! might think the next line is not needed but it is since only diag block 2 entry zero
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                      - BC(in,4) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 

            enddo
! block status
!  0 5' 9'
!  0 6'' 10''
!  0 7' 11'


            iadj1=3
            iadj2=iadj1+4
            iadj3=iadj2+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                      - BC(in,5) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem3,inod,i) 

! block status
!  0 5' 9'
!  0 6'' 10''
!  0 7'' 11''
            enddo
            do i=1,nshl

c
c eliminate the first row of block-9 for all rows
c 
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

            enddo

! block status
!  0 0   0
!  0 5'' 6''
!  0 8'' 9''

! Be aware that this simple inod,inod block status of the block does not reflect that when 
! we eliminated columns we did it for columns in nshl as well for the given
! inod. Conversely when we eliminated rows in the block we did so for ALL
!  rows in nshl as can be seen by the transpose of i and inod.

            xlhs(iel,1,inod,inod)=one
! block status
!  1 0   0
!  0 5'' 6''
!  0 8'' 9''
!
! that takes care of momentum velocity tangent (K) but not G or -G^T. PETSc needs this.
! the following could be folded into the above but, since leslib code takes care of this 
! via the preconditioner keeping the using petsc flag for now and keeping separate.
            if(usingpetsc.gt.-1) then !lazy way for now
                    xlhs(iel, 4,:,inod)=0 ! take out cont-u couple for all rows as u set
                    xlhs(iel,13,inod,:)=0 ! take out xmom-p couple for all columns as u triv
            endif
          endif ! x1-velocity
c
c.... x2-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 2) then
c
!  1 5 9
!  2 6 10
!  3 7 11


c
c  adjusting the first column for the eventual removal of the second
c  column of the block-9 submatrix
c
            irem1=5
            irem2=irem1+1
            irem3=irem2+1

            iadj1=1
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 

            enddo
! block status ' denotes colunn 2 projected off.
!  1' 5 9
!  2' 6 10
!  3' 7 11
c
c  adjusting the third column for the eventual removal of the second
c  column of the block-9 submatrix
c
            iadj1=9
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem3,i,inod) 
! block status
!  1' 5 9'
!  2' 6 10'
!  3' 7 11'
            enddo
            do i=1,nshl
c
c done with the second  columns_block-9 for columns AND rows of nshl
c
               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 


! block status
!  1' 0 9'
!  2' 0 10'
!  3' 0 11'

            enddo
c
c  now adjust the first row_block-9 for EACH row nshl for EACH element 
c

            iadj1=1
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=2
            irem2=irem1+4
            irem3=irem2+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 

            enddo
! block status
!  1'' 0 9''
!  2'  0 10'
!  3'  0 11'


            iadj1=3
            iadj2=iadj1+4
            iadj3=iadj2+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem3,inod,i) 

! block status
!  1'' 0 9''
!  2'  0 10'
!  3'' 0 11''
            enddo
            do i=1,nshl

c
c eliminate the second row of block-9 for all rows
c 
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

            enddo

! block status
!  1'' 0 9''
!  0   0 0
!  3'' 0 11''

! Be aware that this simple inod,inod block status of the block does not reflect that when 
! we eliminated columns we did it for columns in nshl as well for the given
! inod. Conversely when we eliminated rows in the block we did so for ALL
!  rows in nshl as can be seen by the transpose of i and inod.

            xlhs(iel,6,inod,inod)=one
! block status
!  1'' 0 9''
!  0   1 0
!  3'' 0 11''
!
! that takes care of momentum velocity tangent (K) but not G or -G^T. PETSc needs this.
! the following could be folded into the above but, since leslib code takes care of this 
! via the preconditioner keeping the using petsc flag for now and keeping separate.
            if(usingpetsc.gt.-1) then !lazy way for now
                    xlhs(iel, 8,:,inod)=0 ! take out cont-v couple for all rows as v set
                    xlhs(iel,14,inod,:)=0 ! take out ymom-p couple for all columns as v triv
            endif
          endif ! x2-velocity
c
c.... x3-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 4) then
c
!  1 5 9
!  2 6 10
!  3 7 11


c
c  adjusting the first column for the eventual removal of the third
c  column of the block-9 submatrix
c
            irem1=9
            irem2=irem1+1
            irem3=irem2+1

            iadj1=1
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 

            enddo
! block status ' denotes colunn 3 projected off.
!  1' 5 9
!  2' 6 10
!  3' 7 11
c
c  adjusting the second  column for the eventual removal of the third
c  column of the block-9 submatrix
c
            iadj1=5
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem1,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem2,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,5) * xlhs(iel,irem3,i,inod) 
! block status
!  1' 5' 9
!  2' 6' 10
!  3' 7' 11
            enddo
            do i=1,nshl
c
c done with the third  columns_block-9 for columns AND rows of nshl
c
               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 


! block status
!  1' 5' 0
!  2' 6' 0
!  3' 7' 0

            enddo
c
c  now adjust the first row_block-9 for EACH row nshl for EACH element 
c

            iadj1=1
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=3
            irem2=irem1+4
            irem3=irem2+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 

            enddo
! block status
!  1'' 5''0
!  2'  6' 0
!  3'  7' 0


            iadj1=2
            iadj2=iadj1+4
            iadj3=iadj2+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem1,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem2,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,5) * xlhs(iel,irem3,inod,i) 

! block status
!  1'' 5''0
!  2'' 6''0
!  3'  7' 0
            enddo
            do i=1,nshl

c
c eliminate the third row of block-9 for all rows
c 
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

            enddo

! block status
!  1'' 5''0
!  2'' 6''0
!  0   0  0

! Be aware that this simple inod,inod block status of the block does not reflect that when 
! we eliminated columns we did it for columns in nshl as well for the given
! inod. Conversely when we eliminated rows in the block we did so for ALL
!  rows in nshl as can be seen by the transpose of i and inod.

            xlhs(iel,11,inod,inod)=one
! block status
!  1'' 5''0
!  2'' 6''0
!  0   0  1
!
! that takes care of momentum velocity tangent (K) but not G or -G^T. PETSc needs this.
! the following could be folded into the above but, since leslib code takes care of this 
! via the preconditioner keeping the using petsc flag for now and keeping separate.
            if(usingpetsc.gt.-1) then !lazy way for now
                    xlhs(iel,12,:,inod)=0 ! take out cont-u couple for all rows as u set
                    xlhs(iel,15,inod,:)=0 ! take out xmom-p couple for all columns as u triv
            endif
          endif ! x1-velocity
c     
c.... x1-velocity and x2-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 3 ) then
c
! See comment above. Now we are eliminating the 2nd and 1st column then
! same rows of
! the block-9 matrix
!  1 5 9
!  2 6 10
!  3 7 11
c
c  adjusting the 3rd column for the eventual removal of the first and second
c  column of the block-9 submatrix
c
            irem1=1
            irem2=irem1+1
            irem3=irem2+1

            ire21=5
            ire22=ire21+1
            ire23=ire22+1

            iadj1=9
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire21,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire22,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire23,i,inod) 

! Status of the block-9 matrix
!  1 5 9'
!  2 6 10'
!  3 7 11'
            enddo
            do i=1,nshl
c
c done with the first and second columns_block-9 for columns AND rows of nshl
c

               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 

               xlhs(iel,ire21,i,inod) = zero 
               xlhs(iel,ire22,i,inod) = zero 
               xlhs(iel,ire23,i,inod) = zero 

! Status of the block-9 matrix
!  0 0 9'
!  0 0 10'
!  0 0 11'

            enddo
c
c  now adjust the 3rd row_block-9 for EACH row nshl for EACH element 
c

            iadj1=3
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=1
            irem2=irem1+4
            irem3=irem2+4
            ire21=2
            ire22=ire21+4
            ire23=ire22+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem1,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire21,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire22,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire23,inod,i) 


! Status of the block-9 matrix
!  0 0 9'
!  0 0 10'
!  0 0 11''
            enddo
            do i=1,nshl
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

               xlhs(iel,ire21,inod,i) = zero 
               xlhs(iel,ire22,inod,i) = zero 
               xlhs(iel,ire23,inod,i) = zero 

! Status of the block-9 matrix
!  0 0 0
!  0 0 0
!  0 0 11''

            enddo
            xlhs(iel,1,inod,inod)=one
            xlhs(iel,6,inod,inod)=one
            if(usingpetsc.gt.-1) then !lazy way for now
               xlhs(iel,4:8:4,:,inod)=0 ! take out cont-uv couple for all rows as uv set
               xlhs(iel,13:14,inod,:)=0 ! take out xymom-p couple for all columns as uv triv
            endif
         endif !x1 and x2 velocity
c     
c.... x1-velocity and x3-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 5 ) then
c
! See comment above. Now we are eliminating the third and 1st column then
! same rows of
! the block-9 matrix
!  1 5 9
!  2 6 10
!  3 7 11
c
c  adjusting the 2nd column for the eventual removal of the first and third
c  column of the block-9 submatrix
c
            irem1=1
            irem2=irem1+1
            irem3=irem2+1

            ire21=9
            ire22=ire21+1
            ire23=ire22+1

            iadj1=5
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire21,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire22,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire23,i,inod) 

! Status of the block-9 matrix
!  1 5' 9
!  2 6' 10
!  3 7' 11
            enddo
            do i=1,nshl
c
c done with the first and third columns_block-9 for columns AND rows of nshl
c

               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 

               xlhs(iel,ire21,i,inod) = zero 
               xlhs(iel,ire22,i,inod) = zero 
               xlhs(iel,ire23,i,inod) = zero 

! Status of the block-9 matrix
!  0 5' 0
!  0 6' 0
!  0 7' 0

            enddo
c
c  now adjust the 2nd row_block-9 for EACH row nshl for EACH element 
c

            iadj1=2
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=1
            irem2=irem1+4
            irem3=irem2+4
            ire21=3
            ire22=ire21+4
            ire23=ire22+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem1,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire21,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire22,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire23,inod,i) 


! Status of the block-9 matrix
!  0 5' 0
!  0 6''0
!  0 7' 0
            enddo
            do i=1,nshl
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

               xlhs(iel,ire21,inod,i) = zero 
               xlhs(iel,ire22,inod,i) = zero 
               xlhs(iel,ire23,inod,i) = zero 

! Status of the block-9 matrix
!  0 0   0
!  0 6'' 0
!  0 0   0

            enddo
            xlhs(iel,1,inod,inod)=one
            xlhs(iel,11,inod,inod)=one
            if(usingpetsc.gt.-1) then ! petsc needs this 
               xlhs(iel, 4:12:8,:,inod)=0 ! take out cont-uv couple for all rows as uv set
               xlhs(iel,13:15:2,inod,:)=0 ! take out xymom-p couple for all columns as uv triv
            endif
         endif !x1 and x3 velocity 
c     
c.... x2-velocity and x3-velocity
c
          if ( ibits(iBC(in),3,3) .eq. 6 ) then
c
! See comment above. Now we are eliminating the 2nd and third column then
! same rows of
! the block-9 matrix
!  1 5 9
!  2 6 10
!  3 7 11
c
c  adjusting the first column for the eventual removal of the second and third
c  column of the block-9 submatrix
c
            irem1=5
            irem2=irem1+1
            irem3=irem2+1

            ire21=9
            ire22=ire21+1
            ire23=ire22+1

            iadj1=1
            iadj2=iadj1+1
            iadj3=iadj2+1
            do i = 1, nshl
               xlhs(iel,iadj1,i,inod) = xlhs(iel,iadj1,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem1,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire21,i,inod) 
               xlhs(iel,iadj2,i,inod) = xlhs(iel,iadj2,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem2,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire22,i,inod) 
               xlhs(iel,iadj3,i,inod) = xlhs(iel,iadj3,i,inod) 
     &                     - BC(in,4) * xlhs(iel,irem3,i,inod) 
     &                     - BC(in,6) * xlhs(iel,ire23,i,inod) 

! Status of the block-9 matrix
!  1' 5 9
!  2' 6 10
!  3' 7 11
            enddo
            do i=1,nshl
c
c done with the second and third columns_block-9 for columns AND rows of nshl
c

               xlhs(iel,irem1,i,inod) = zero 
               xlhs(iel,irem2,i,inod) = zero 
               xlhs(iel,irem3,i,inod) = zero 

               xlhs(iel,ire21,i,inod) = zero 
               xlhs(iel,ire22,i,inod) = zero 
               xlhs(iel,ire23,i,inod) = zero 

! Status of the block-9 matrix
!  1' 0  0
!  2' 0  0
!  3' 0  0

            enddo
c
c  now adjust the first row_block-9 for EACH row nshl for EACH element 
c

            iadj1=1
            iadj2=iadj1+4
            iadj3=iadj2+4
            irem1=2
            irem2=irem1+4
            irem3=irem2+4
            ire21=3
            ire22=ire21+4
            ire23=ire22+4
            do i = 1, nshl
               xlhs(iel,iadj1,inod,i) = xlhs(iel,iadj1,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem1,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire21,inod,i) 
               xlhs(iel,iadj2,inod,i) = xlhs(iel,iadj2,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem2,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire22,inod,i) 
               xlhs(iel,iadj3,inod,i) = xlhs(iel,iadj3,inod,i) 
     &                     - BC(in,4) * xlhs(iel,irem3,inod,i) 
     &                     - BC(in,6) * xlhs(iel,ire23,inod,i) 


! Status of the block-9 matrix
!  1'' 0  0
!  2'  0  0
!  3'  0  0
            enddo
            do i=1,nshl
               xlhs(iel,irem1,inod,i) = zero 
               xlhs(iel,irem2,inod,i) = zero 
               xlhs(iel,irem3,inod,i) = zero 

               xlhs(iel,ire21,inod,i) = zero 
               xlhs(iel,ire22,inod,i) = zero 
               xlhs(iel,ire23,inod,i) = zero 

! Status of the block-9 matrix
!  1'' 0 0
!  0   0 0
!  0   0 0

            enddo
            xlhs(iel,6,inod,inod)=one
            xlhs(iel,11,inod,inod)=one
            if(usingpetsc.gt.-1) then ! petsc needs this 
               xlhs(iel, 8:12:4,:,inod)=0 ! take out cont-uv couple for all rows as uv set
               xlhs(iel,14:15:1,inod,:)=0 ! take out xymom-p couple for all columns as uv triv
            endif
          endif ! end of x2-x3 velocity
 5000     continue
        
c        
c.... end loop over shape functions (nodes)
c        
        enddo
c
c.... end loop over elements
c     
      enddo
c
c These elements should assemble to a matrix with the rows and columns 
c associated with the Dirichlet nodes zeroed out.  Note that since at elemement level the
! actual diagonal entry wont be 1 but will the number of times the node is repeated on the 
! boundary.   Note also that diag preconditioning somewhat takes care of the same thing
! so much of this is not needed when doing that with leslib or svLS
c
c     
c.... return
c
        return
        end
