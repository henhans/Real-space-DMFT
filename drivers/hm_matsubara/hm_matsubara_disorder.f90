!########################################################
!     PURPOSE  :solve the disordered (D) Hubbard model (HM) 
!using Modified Perturbation THeory (MPT), w/ DMFT
!     COMMENTS :
!DISORDER REALIZATION DEPENDS ON THE PARAMETER int idum:
!SO THAT DIFFERENT REALIZATIONS (STATISTICS) ARE PERFORMED 
!CALLING THIS PROGRAM MANY TIMES WHILE PROVIDING A *DIFFERENT* SEED.
!THE RESULT OF EACH CALCULATION IS STORED IN A DIFFERENT DIR
!     AUTHORS  : A.Amaricci
!########################################################
MODULE COMMON_BROYDN
  USE BROYDEN
  implicit none
  integer                :: siteId
  real(8)                :: xmu0,n,n0
  complex(8),allocatable :: fg(:,:),sigma(:,:)
  complex(8),allocatable :: fg0(:),gamma(:)
  real(8),allocatable    :: fgt(:,:),fg0t(:)
end module COMMON_BROYDN



function funcv(x)
  USE RDMFT_VARS_GLOBAL
  USE COMMON_BROYDN
  implicit none
  real(8),dimension(:),intent(in)  ::  x
  real(8),dimension(size(x))       ::  funcv
  xmu0=x(1)
  fg0 = one/(one/gamma +xmu-xmu0-U*(n-0.5d0))
  call fftgf_iw2tau(fg0,fg0t,beta)
  n0=-real(fg0t(L))
  funcv(1)=n-n0
  write(101+mpiID,"(3(f13.9))")n,n0,xmu0
end function funcv

program hmmpt_matsubara_disorder
  USE RDMFT_VARS_GLOBAL
  USE COMMON_BROYDN
  implicit none
  integer                               :: i,is
  real(8)                               :: x(1),r
  logical                               :: check,converged  
  complex(8),allocatable,dimension(:,:) :: sigma_tmp
  real(8),allocatable,dimension(:)      :: nii_tmp,dii_tmp

  !GLOBAL INITIALIZATION:
  !=====================================================================
  include "init_global_disorder.f90"


  !ALLOCATE WORKING ARRAYS:
  !=====================================================================

  allocate(fg(Ns,L),sigma(Ns,L))
  allocate(fg0(L),gamma(L))
  allocate(fgt(Ns,0:L),fg0t(0:L))
  !
  allocate(sigma_tmp(Ns,L))
  allocate(nii_tmp(Ns),dii_tmp(Ns))
  !
  allocate(wm(L),tau(0:L))
  wm(:)  = pi/beta*real(2*arange(1,L)-1,8)
  tau(0:)= linspace(0.d0,beta,L+1,mesh=dtau)


  !START DMFT LOOP SEQUENCE:
  !=====================================================================
  call setup_initial_sigma()
  iloop=0 ; converged=.false.
  do while(.not.converged)
     iloop=iloop+1
     call start_loop(iloop,nloop,"DMFT-loop")

     !SOLVE G_II (GLOCAL)
     call get_gloc_mpi()

     !SOLVE IMPURITY MODEL, FOR ALL LATTICE SITES:
     call solve_impurity_mpi()

     converged=check_convergence(sigma,eps_error,Nsuccess,nloop,id=0)
     if(nread/=0.d0)call search_mu(converged)
     call MPI_BCAST(converged,1,MPI_LOGICAL,0,MPI_COMM_WORLD,mpiERR)
     call print_out(converged)
     call end_loop()
  enddo
  if(mpiID==0)call system("mv -vf *.err "//trim(adjustl(trim(name_dir)))//"/")
  call close_mpi()


contains

  !******************************************************************
  !******************************************************************

  !+-------------------------------------------------------------------+
  !PURPOSE  : 
  !+-------------------------------------------------------------------+
  subroutine setup_initial_sigma()
    logical :: check
    if(mpiID==0)then
       inquire(file="LSigma_iw.restart",exist=check)
       if(.not.check)inquire(file="LSigma_iw.restart.gz",exist=check)
       if(check)then
          call msg(bg_yellow("Reading Self-energy from file:"),lines=2)
          call sread("LSigma_iw.restart",sigma(1:Ns,1:L),wm(1:L))
       endif
    else
       call msg(bg_yellow("Using Hartree-Fock self-energy"),lines=2)
       sigma=zero!u*(n-0.5d0)
    endif
    call MPI_BCAST(sigma,Ns*L,MPI_DOUBLE_COMPLEX,0,MPI_COMM_WORLD,mpiERR)
  end subroutine setup_initial_sigma



  !******************************************************************
  !******************************************************************





  !+-------------------------------------------------------------------+
  !PURPOSE  : 
  !+-------------------------------------------------------------------+
  subroutine get_gloc_mpi() 
    complex(8) :: zeta,Gloc(Ns,Ns),gf_tmp(Ns,1:L)
    integer    :: i
    call msg("Get local GF:",id=0)
    call start_timer
    gf_tmp=zero ; fg=zero
    do i=1+mpiID,L,mpiSIZE
       zeta  = xi*wm(i) + xmu
       Gloc  = zero-H0
       do is=1,Ns
          Gloc(is,is) = Gloc(is,is) + zeta - erandom(is) - sigma(is,i) 
       enddo
       call mat_inversion_sym(Gloc,Ns)
       do is=1,Ns
          gf_tmp(is,i) = Gloc(is,is)
       enddo
       call eta(i,L,999)
    enddo
    call stop_timer
    call MPI_REDUCE(gf_tmp,fg,Ns*L,MPI_DOUBLE_COMPLEX,MPI_SUM,0,MPI_COMM_WORLD,MPIerr)
    call MPI_BCAST(fg,Ns*L,MPI_DOUBLE_COMPLEX,0,MPI_COMM_WORLD,mpiERR)
    call MPI_BARRIER(MPI_COMM_WORLD,mpiERR)
  end subroutine get_gloc_mpi



  !******************************************************************
  !******************************************************************



  !+-------------------------------------------------------------------+
  !PURPOSE  : 
  !+-------------------------------------------------------------------+
  subroutine solve_impurity_mpi()
    integer    :: is
    logical    :: disorder
    disorder=.false. ; if(Wdis/=0)disorder=.true.
    call msg("Solve impurity:")
    disorder=.true.
    if(disorder)then
       call start_timer
       sigma_tmp=zero
       nii_tmp  =zero
       do is=1+mpiID,Ns,mpiSIZE
          call solve_per_site(is)
          call eta(is,Ns,998)
       enddo
       call stop_timer
       call MPI_REDUCE(sigma_tmp,sigma,Ns*L,MPI_DOUBLE_COMPLEX,MPI_SUM,0,MPI_COMM_WORLD,MPIerr)
       call MPI_BCAST(sigma,Ns*L,MPI_DOUBLE_COMPLEX,0,MPI_COMM_WORLD,mpiERR)
       !
       call MPI_REDUCE(nii_tmp,nii,Ns,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,MPIerr)
       call MPI_BCAST(nii,Ns,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,mpiERR)
    else
       call solve_per_site(is=1)
       forall(is=1:Ns)sigma(is,:)=sigma_tmp(1,:)
    endif
  end subroutine solve_impurity_mpi



  !******************************************************************
  !******************************************************************






  !+-------------------------------------------------------------------+
  !PURPOSE  : 
  !+-------------------------------------------------------------------+
  subroutine solve_per_site(is)
    complex(8),dimension(:,:),allocatable,save :: sold
    integer :: is
    siteId=is
    if(.not.allocated(sold))allocate(sold(Ns,1:L))
    sold(is,:)=sigma(is,:)
    call fftgf_iw2tau(fg(is,:),fgt(is,:),beta)
    n=-real(fgt(is,L))
    !
    nii_tmp(is)=2.d0*n
    !
    gamma = one/(one/fg(is,:) + sigma(is,:))
    xmu0=0.d0 ; x(1)=xmu
    call broydn(x,check)
    xmu0=x(1)
    !Evaluate self-energy and put it into Sigma_tmp to be mpi_reduced later on
    !
    sigma_tmp(is,:) = solve_mpt_matsubara(fg0,n,n0,xmu0)
    sigma_tmp(is,:) = weigth*sigma_tmp(is,:) + (1.d0-weigth)*sold(is,:)
    !
  end subroutine solve_per_site



  !******************************************************************
  !******************************************************************



  !+-------------------------------------------------------------------+
  !PURPOSE  : Print out results
  !+-------------------------------------------------------------------+
  subroutine print_out(converged)
    integer                 :: i,j,is,M,row,col
    real(8)                 :: nimp
    real(8),dimension(Ns)   :: cdwii,rii,sii,zii
    real(8)                 :: mean,sdev,var,skew,kurt
    real(8),dimension(2,Ns) :: data_covariance
    real(8),dimension(2)    :: data_mean,data_sdev
    real(8),dimension(2,2)  :: covariance_nd
    logical                 :: converged
    complex(8)              :: afg(1:L),asig(1:L)

    if(mpiID==0)then
       nimp=sum(nii)/real(Ns,8)
       print*,"nimp  =",nimp
       call splot(trim(adjustl(trim(name_dir)))//"/navVSiloop.ipt",iloop,nimp,append=TT)
       call splot(trim(adjustl(trim(name_dir)))//"/LSigma_iw.ipt",sigma,wm)
       call splot(trim(adjustl(trim(name_dir)))//"/LG_iw.ipt",fg,wm)

       if(converged)then
          !Plot averaged local functions
          afg(:)  = sum(fg(1:Ns,1:L),dim=1)/dble(Ns) 
          asig(:) = sum(sigma(1:Ns,1:L),dim=1)/dble(Ns)
          call splot(trim(adjustl(trim(name_dir)))//"/aG_iw.ipt",wm,afg)
          call splot(trim(adjustl(trim(name_dir)))//"/aSigma_iw.ipt",wm,asig)

          !Plot observables: n,n_cdw,rho,sigma,zeta
          do is=1,Ns
             row=irow(is) 
             col=icol(is)
             cdwii(is) = (-1.d0)**(row+col)*nii(is)
             sii(is)   = dimag(sigma(is,1))-&
                  wm(1)*(dimag(sigma(is,2))-dimag(sigma(is,1)))/(wm(2)-wm(1))
             rii(is)   = dimag(fg(is,1))-&
                  wm(1)*(dimag(fg(is,2))-dimag(fg(is,1)))/(wm(2)-wm(1))
             zii(is)   = 1.d0/( 1.d0 + abs( dimag(sigma(is,1))/wm(1) ))
          enddo
          rii=abs(rii)
          sii=abs(sii)
          zii=abs(zii)
          call splot(trim(adjustl(trim(name_dir)))//"/nVSisite.data",nii)
          call splot(trim(adjustl(trim(name_dir)))//"/cdwVSisite.data",cdwii)
          call splot(trim(adjustl(trim(name_dir)))//"/rhoVSisite.data",rii)
          call splot(trim(adjustl(trim(name_dir)))//"/sigmaVSisite.data",sii)
          call splot(trim(adjustl(trim(name_dir)))//"/zetaVSisite.data",zii)
          call splot(trim(adjustl(trim(name_dir)))//"/erandomVSisite.ipt",erandom)


          call get_moments(nii,mean,sdev,var,skew,kurt)
          data_mean(1)=mean ; data_sdev(1)=sdev
          call splot(trim(adjustl(trim(name_dir)))//"/statistics.n.data",mean,sdev,var,skew,kurt)
          !
          call get_moments(zii,mean,sdev,var,skew,kurt)
          data_mean(2)=mean ; data_sdev(2)=sdev
          call splot(trim(adjustl(trim(name_dir)))//"/statistics.z.data",mean,sdev,var,skew,kurt)
          !
          call get_moments(sii,mean,sdev,var,skew,kurt)
          call splot(trim(adjustl(trim(name_dir)))//"/statistics.sigma.data",mean,sdev,var,skew,kurt)
          !
          call get_moments(rii,mean,sdev,var,skew,kurt)
          call splot(trim(adjustl(trim(name_dir)))//"/statistics.rho.data",mean,sdev,var,skew,kurt)

          data_covariance(1,:)=nii
          data_covariance(2,:)=zii
          covariance_nd = get_covariance(data_covariance,data_mean)
          open(10,file=trim(adjustl(trim(name_dir)))//"/covariance_n.z.data")
          do i=1,2
             write(10,"(2f24.12)")(covariance_nd(i,j),j=1,2)
          enddo
          close(10)

          forall(i=1:2,j=1:2)covariance_nd(i,j) = covariance_nd(i,j)/(data_sdev(i)*data_sdev(j))
          open(10,file=trim(adjustl(trim(name_dir)))//"/correlation_n.z.data")
          do i=1,2
             write(10,"(2f24.12)")(covariance_nd(i,j),j=1,2)
          enddo
          close(10)

       endif
    endif
    return
  end subroutine print_out



  !******************************************************************
  !******************************************************************






  subroutine search_mu(convergence)
    real(8)               :: naverage
    logical,intent(inout) :: convergence
    real(8)               :: ndelta1
    integer               :: nindex1    
    if(mpiID==0)then
       naverage=sum(nii(:))/real(Ns,8)
       nindex1=nindex
       ndelta1=ndelta
       if((naverage >= nread+nerror))then
          nindex=-1
       elseif(naverage <= nread-nerror)then
          nindex=1
       else
          nindex=0
       endif
       if(nindex1+nindex==0)then !avoid loop forth and back
          ndelta=ndelta1/2.d0 !decreasing the step
       else
          ndelta=ndelta1
       endif
       xmu=xmu+real(nindex,8)*ndelta
       write(*,"(A,f15.12,A,f15.12,A,f15.12,A,f15.12)")" n=",naverage," /",nread,&
            "| shift=",nindex*ndelta,"| xmu=",xmu
       write(*,"(A,f15.12)")"dn=",abs(naverage-nread)
       print*,""
       if(abs(naverage-nread)>nerror)convergence=.false.
       call splot(trim(adjustl(trim(name_dir)))//"/muVSiter.ipt",iloop,xmu,abs(naverage-nread),append=.true.)
    endif
    call MPI_BCAST(xmu,1,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,mpiERR)
  end subroutine search_mu


  !******************************************************************
  !******************************************************************



end program


