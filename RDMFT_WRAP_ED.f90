!###############################################################
! PROGRAM  : RDMFT_WRAP_IPT
! PURPOSE  : Contains the main function performin RDMFT calculation
! for the ED solver
! AUTHORS  : Adriano Amaricci, Giacomo Mazza
!###############################################################
module RDMFT_WRAP_ED
  USE RDMFT_INPUT_VARS
  USE RDMFT_VARS_GLOBAL
  USE RDMFT_AUX_FUNX
  USE TIMER
  USE FFTGF
  USE IOTOOLS,   only:reg,sread
  USE RANDOM,    only:nrand,init_random_number
  USE STATISTICS
  USE FUNCTIONS, only:fermi
  !Impurity solver interface
  USE DMFT_ED
  implicit none
  private
  
  public :: ed_solve_sc_impurity_mats
  public :: init_lattice_baths

contains

  !+----------------------------------------------------------------+
  !PURPOSE  : parallel solution of impurity problem SC-version
  !+----------------------------------------------------------------+
  subroutine ed_solve_sc_impurity_mats(bath_,eloc,Delta,Gmats,Greal,Smats,Sreal)
    real(8)                  :: bath_(:,:,:),bath_tmp(size(bath_,1),size(bath_,2))
    real(8)                  :: eloc(Nlat)
    complex(8),intent(inout) :: Delta(2,Nlat,Lmats)
    complex(8),intent(inout) :: Gmats(2,Nlat,Lmats)
    complex(8),intent(inout) :: Greal(2,Nlat,Lreal)
    complex(8),intent(inout) :: Smats(2,Nlat,Lmats)
    complex(8),intent(inout) :: Sreal(2,Nlat,Lreal)
    complex(8)               :: Smats_tmp(2,Nlat,Lmats)
    complex(8)               :: Sreal_tmp(2,Nlat,Lreal)
    complex(8)               :: Delta_tmp(2,Nlat,Norb,Norb,Lmats),Delta_tmp_tmp(2,Nlat,Norb,Norb,Lmats)
    complex(8)               :: calG(2,Lmats),cdet
    integer                  :: ilat,i

    real(8)    :: nii_tmp(Nlat),dii_tmp(Nlat),pii_tmp(Nlat)

    logical :: check_dim
    character(len=5) :: tmp_suffix

    if(size(bath_,3).ne.Nlat) stop "init_lattice_bath: wrong bath size dimension 3 (Nlat)"
    do ilat=1+mpiID,Nlat,mpiSIZE
       check_dim = check_bath_dimension(bath_(:,:,ilat))
       if(.not.check_dim) stop "init_lattice_bath: wrong bath size dimension 1 or 2 "
    end do
    if(mpiID==0)write(LOGfile,*)"Solve impurity:"
    call start_timer
    Smats_tmp = zero
    Sreal_tmp = zero
    Delta_tmp = zero
    nii_tmp   = 0.d0
    dii_tmp   = 0.d0
    pii_tmp   = 0.d0

    LOGfile = 800+mpiID
    if(mpiID==0) LOGfile=6
    do ilat=1+mpiID,Nlat,mpiSIZE
       write(tmp_suffix,'(I4.4)') ilat
       ed_file_suffix="_site"//trim(tmp_suffix)
       call ed_solver(bath_(:,:,ilat))
       Smats_tmp(1,ilat,:) = impSmats(1,1,1,1,:)
       Smats_tmp(2,ilat,:) = impSAmats(1,1,1,1,:)

       Sreal_tmp(1,ilat,:) = impSreal(1,1,1,1,:)
       Sreal_tmp(2,ilat,:) = impSAreal(1,1,1,1,:)

       nii_tmp(ilat)   = ed_dens(1)
       dii_tmp(ilat)   = ed_docc(1)
       pii_tmp(ilat)   = ed_phisc(1)
       call eta(ilat,Nlat,file="Impurity.eta")
    enddo
    call stop_timer
    call MPI_ALLREDUCE(Smats_tmp,Smats,2*Nlat*Lmats,MPI_DOUBLE_COMPLEX,MPI_SUM,MPI_COMM_WORLD,MPIerr)
    call MPI_ALLREDUCE(Sreal_tmp,Sreal,2*Nlat*Lreal,MPI_DOUBLE_COMPLEX,MPI_SUM,MPI_COMM_WORLD,MPIerr)
    call MPI_ALLREDUCE(nii_tmp,nii,Nlat,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,MPIerr)
    call MPI_ALLREDUCE(dii_tmp,dii,Nlat,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,MPIerr)
    call MPI_ALLREDUCE(pii_tmp,pii,Nlat,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,MPIerr)
    
    !compute Gloc
    call get_sc_gloc_mats(eloc,Smats,Gmats)
    call get_sc_gloc_real(eloc,Sreal,Greal)

    !for each site get_delta and fit it
    do ilat=1+mpiID,Nlat,mpiSIZE
       write(tmp_suffix,'(I4.4)') ilat
       ed_file_suffix="_site"//trim(tmp_suffix)
       do i=1,Lmats
          cdet       = abs(Gmats(1,ilat,i))**2 + (Gmats(2,ilat,i))**2
          calG(1,i) = conjg(Gmats(1,ilat,i))/cdet + Smats(1,ilat,i)
          calG(2,i) =  Gmats(2,ilat,i)/cdet + Smats(2,ilat,i) 
          if(cg_scheme=='weiss')then
             cdet             =  abs(calG(1,i))**2 + (calG(2,i))**2
             Delta_tmp(1,ilat,1,1,i)  =  conjg(calG(1,i))/cdet
             Delta_tmp(2,ilat,1,1,i)  =  calG(2,i)/cdet
          else
             cdet       = abs(Gmats(1,ilat,i))**2 + (Gmats(2,ilat,i))**2
             Delta_tmp(1,ilat,1,1,i) = xi*wm(i) + xmu - Smats(1,ilat,i) - &
                  conjg(Gmats(1,ilat,i))/cdet 
             Delta_tmp(2,ilat,1,1,i) = -(Gmats(2,ilat,i)/cdet + Smats(2,ilat,i))
          endif
       end do
       call chi2_fitgf(Delta_tmp(:,ilat,:,:,:),bath_(:,:,ilat),ispin=1,iverbose=.true.)
    end do
    call MPI_ALLREDUCE(Delta_tmp(:,:,1,1,:),Delta,2*Nlat*Lmats,MPI_DOUBLE_COMPLEX,MPI_SUM,MPI_COMM_WORLD,MPIerr)

  end subroutine ed_solve_sc_impurity_mats





  
  !+- PURPOSE: allocate and initialize lattice baths -+!
  subroutine init_lattice_baths(bath)
    real(8),dimension(:,:,:) :: bath
    integer :: ilat
    logical :: check_dim
    character(len=5) :: tmp_suffix
    if(size(bath,3).ne.Nlat) stop "init_lattice_bath: wrong bath size dimension 3 (Nlat)"
    do ilat=1,Nlat
       check_dim = check_bath_dimension(bath(:,:,ilat))
       if(.not.check_dim) stop "init_lattice_bath: wrong bath size dimension 1 or 2 "
       write(tmp_suffix,'(I4.4)') ilat
       ed_file_suffix="_site"//trim(tmp_suffix)
       call init_ed_solver(bath(:,:,ilat),iverbose=.false.)
    end do
  end subroutine init_lattice_baths



end module RDMFT_WRAP_ED
