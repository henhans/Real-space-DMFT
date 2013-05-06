

!###############################################################
! PROGRAM  : RDMFT_VARS_GLOBAL
! TYPE     : Module
! PURPOSE  : Contains global variables
! AUTHORS  : Adriano Amaricci & Antonio Privitera
! NAME
!   xxx_disorder/trap  
! DESCRIPTION
!   This a layer interface to different codes solving the Real-space Dynamical Mean Field Theory.
!   Each code must be implemented separetely, for convenience some driver routines are in drivers/ dir.
!   The structure is very easy: a tight-binding hamiltonian is generated at first and the DMFT problem  
!   is solved in the local wannier basis, solving the impurity problem at each lattice site. Simmetries 
!   can be used to reduce the size of the problem. Lattice sites are related via self-consistency. 
!   The code is MPI parallel.     
! OPTIONS
!  wdis=[0.5]    -- degree of local disorder.
!  Nside=[10]    -- linear size of the cluster to be solved.
!  a0trap=[0]    -- bottom of the trap. here kept separated from mu.
!  v0trap=[0.1]  -- fix the parabolic shape of the trap.
!  nread=[0.0]   -- density value for chemical potential search.
!  ndelta=[0.1]  -- starting value for chemical potential shift.
!  nerror=[1.d-4]-- max error in adjusting chemical potential. 
!  symmflag=[T]  -- Enforce trap cubic symmetry in the xy-plane.
!  optimized=[T] -- Optimized Crossover, find trap parameters to have N_wanted particles and nread density at the trap center.
!  n_wanted=[0]  -- Required number of particles in the trap. Fix to 0 (default) for mufixed
!  n_tol=[0.1]   -- Tolerance over the total density
!  chitrap=[0.1] -- Tentative value of the global trap compressibility
!  pbcflag=[T]   -- periodic boundary conditions.
!  idum=[1234567]-- initial seed for the random variable sample.	
!###############################################################

module RDMFT_VARS_GLOBAL
  !Scientific library
  USE COMMON_VARS
  USE TIMER, ONLY:start_timer,stop_timer,eta
  USE IOTOOLS
  USE MATRIX
  USE RANDOM,    ONLY:nrand,init_random_number
  USE STATISTICS
  USE INTEGRATE, ONLY:kronig
  USE FUNCTIONS, ONLY:fermi
  USE TOOLS,     ONLY:check_convergence
  USE BROYDEN,   ONLY:broydn    ! added broyden to the accessible modules

  !Impurity solver interface
  USE SOLVER_INTERFACE
  !parallel library
  USE MPI
  implicit none

  !Revision software:
  !=========================================================
  include "revision.inc"

  !Lattice size:
  !=========================================================
  integer   :: Nside,Ns,Nindip,iloop

  !Frequency and time arrays:
  !=========================================================
  real(8),dimension(:),allocatable :: wm,tau
  real(8),dimension(:),allocatable :: wr,t


  !Large matrices for Lattice Hamiltonian/GF
  !=========================================================
  integer,dimension(:),allocatable   :: icol,irow
  integer,dimension(:,:),allocatable :: ij2site
  integer,dimension(:), allocatable  :: indipsites !***to be renamed***
  real(8),dimension(:,:),allocatable :: H0,Id


  !Local density and order parameter profiles:
  !=========================================================
  real(8),dimension(:),allocatable    :: nii,dii,gap_ii
  complex(8),dimension(:),allocatable :: cdii


  !Global variables
  !=========================================================
  real(8) :: Wdis               !Disorder strength
  integer :: idum               !disorder seed
  real(8) :: a0trap             !Trap bottom
  real(8) :: V0trap             !Trap curvature in x,y directions (assumed circular symmetry)

  !***To be renamed***

  integer :: N_wanted           !Required number of particles for canonical calculations [set 0 for fixmu]
  real(8) :: N_tol              !Tolerance over the number of particles
  real(8) :: chitrap            !Tentative value for the global trap compressibility dN/d(mu_{tot})

  !real(8) :: gammatrap          !Trap_asymmetry in the third dimension (not implemented yet)
  !integer :: dim                !Spatial dimension (1,2,3) not implemented yet     


  !Other variables:
  !=========================================================
  character(len=20) :: name_dir
  logical           :: pbcflag
  logical           :: symmflag
  logical           :: optimized                ! added to set the optimized crossover from input file. If TRUE
  logical           :: densfixed                ! we use both N_wanted\=0 and nread to fix the central density 
  real(8)           :: nread,nerror,ndelta  ! used to fix the central density in the optimized crossover
  real(8)           :: eav ! average energy of the random variables, see init

  !TEST 
  !=========================================================
  real(8)                                 :: r
  real(8)                                 :: n_tot,delta_tot,n_center
  integer                                 :: is,esp,lm
  logical                                 :: converged,convergedN,convergedD
  complex(8),allocatable,dimension(:,:,:) :: fg,sigma,sigma_tmp
  real(8),allocatable,dimension(:)        :: nii_tmp,dii_tmp,gap_ii_tmp
  real(8),allocatable,dimension(:)        :: acheck
  real(8),dimension(2)                    :: dens_w

  !Random energies
  !=========================================================
  real(8),dimension(:),allocatable   :: erandom,etrap


  interface symmetrize
     module procedure c_symmetrize,r_symmetrize
  end interface symmetrize

  interface reshuffled
     module procedure dv_reshuffled,zv_reshuffled,&
          dm_reshuffled,zm_reshuffled
  end interface reshuffled

  !Namelist:
  !=========================================================
  namelist/disorder/&
       Wdis,     &
       V0trap,   &
       a0trap,   &
       Nside,    &
       idum,     &
       nread,    &
       nerror,   &
       ndelta,   &
       symmflag, &
       optimized,& 
       N_wanted, &
       N_tol,    &
       chitrap,  &   
       pbcflag



contains

  !+----------------------------------------------------------------+
  !PURPOSE  : Read input file
  !+----------------------------------------------------------------+
  subroutine rdmft_read_input(inputFILE)
    character(len=*) :: inputFILE
    integer          :: i
    logical          :: control
    !local variables: default values

    Wdis            = 0.5d0
    Nside           = 10
    a0trap          = 0.d0
    v0trap          = 0.1d0
    nread           = 0.d0
    nerror          = 1.d-4
    ndelta          = 0.1d0
    symmflag        =.false.
    optimized       =.false.
    N_wanted        = Nside**2/2
    N_tol           = 0.1d0
    chitrap         = 0.1d0 
    pbcflag         = .true.
    idum            = 1234567


    !SET SIZE THRESHOLD FOR FILE ZIPPING:
    store_size=1024

    !Read input file (if any)
    inquire(file=adjustl(trim(inputFILE)),exist=control)
    if(control)then
       open(10,file=adjustl(trim(inputFILE)))
       read(10,nml=disorder)
       close(10)
    else
       open(10,file="default."//adjustl(trim(inputFILE)))
       write(10,nml=disorder)
       close(10)
       call abort("can not open INPUT file, dumping a default version in +default."//adjustl(trim(inputFILE)))
    endif

    !Parse cmd.line arguments (if any)
    call parse_cmd_variable(wdis,"WDIS")
    call parse_cmd_variable(v0trap,"V0TRAP")
    call parse_cmd_variable(a0trap,"A0TRAP")
    call parse_cmd_variable(Nside,"NSIDE")
    call parse_cmd_variable(nread,"NREAD")
    call parse_cmd_variable(nerror,"NERROR")
    call parse_cmd_variable(ndelta,"NDELTA")
    call parse_cmd_variable(n_wanted,"N_WANTED")
    call parse_cmd_variable(n_tol,"NTOL")
    call parse_cmd_variable(chitrap,"CHITRAP")
    call parse_cmd_variable(symmflag,"SYMMFLAG")
    call parse_cmd_variable(optimized,"OPTIMIZED")
    call parse_cmd_variable(pbcflag,"PBCFLAG")
    call parse_cmd_variable(idum,"IDUM")

    !Print on the screen used vars
    if(mpiID==0)then
       write(*,nml=disorder)
       open(10,file="used."//adjustl(trim(inputFILE)))
       write(10,nml=disorder)
       close(10)
    endif

    call version(revision)
  end subroutine rdmft_read_input




  !******************************************************************
  !******************************************************************
  !******************************************************************




  !+----------------------------------------------------------------+
  !PURPOSE  : Build tight-binding Hamiltonian
  !+----------------------------------------------------------------+
  subroutine get_tb_hamiltonian(centered)
    integer          :: i,jj,j,k,row,col,link(4)
    logical,optional :: centered
    logical          :: symm
    symm=.false.;if(present(centered))symm=centered
    H0=0.d0
    do row=0,Nside-1
       do col=0,Nside-1
          i=col+row*Nside+1
          if(.not.symm)then
             irow(i)=row+1
             icol(i)=col+1
             ij2site(row+1,col+1)=i
          else
             irow(i)=-Nside/2+row                     ! cambio la tabella i -> isite,jsite
             icol(i)=-Nside/2+col                     ! per farla simmetrica.. aiutera' 
             ij2site(row-Nside/2,col-Nside/2)=i       ! a implementare le simmetrie
          endif
          !
          if(pbcflag)then ! PBC are implemented using the state labels and so they are mpt affected by symm
             !HOPPING w/ PERIODIC BOUNDARY CONDITIONS
             link(1)= row*Nside+1              + mod(col+1,Nside)  ;
             link(3)= row*Nside+1              + (col-1)           ; if((col-1)<0)link(3)=(Nside+(col-1))+row*Nside+1
             link(2)= mod(row+1,Nside)*Nside+1 + col               ; 
             link(4)= (row-1)*Nside+1          + col               ; if((row-1)<0)link(4)=col+(Nside+(row-1))*Nside+1
          else   
             !without PBC
             link(1)= row*Nside+1              + col+1   ; if((col+1)==Nside)link(1)=0
             link(3)= row*Nside+1              +(col-1)  ; if((col-1)<0)     link(3)=0
             link(2)= (row+1)*Nside+1 + col              ; if((row+1)==Nside)link(2)=0
             link(4)= (row-1)*Nside+1          + col     ; if((row-1)<0)     link(4)=0
          endif
          do jj=1,4
             if(link(jj)>0)H0(i,link(jj))=-ts !! ts must be negative.
          enddo
       enddo
    enddo
  end subroutine get_tb_hamiltonian



  !******************************************************************
  !******************************************************************
  !******************************************************************



  !+----------------------------------------------------------------+
  !PURPOSE : build the list of the indipendent sites (1/8 of the square)
  !+----------------------------------------------------------------+
  subroutine get_indip_list()
    integer :: i,row,col,istate,jstate
    i=0
    do col=0,Nside/2
       do row=0,col
          i= i+1
          indipsites(i)=ij2site(row,col)
       enddo
    enddo
  end subroutine get_indip_list



  !******************************************************************
  !******************************************************************
  !******************************************************************



  !+----------------------------------------------------------------+
  !PURPOSE : implement the trap simmetries on a real vector variable 
  ! with Ns components 
  !+----------------------------------------------------------------+
  subroutine r_symmetrize(vec)
    integer                             :: row,col
    real(8), dimension(:),intent(INOUT) :: vec
    !assi cartesiani e diagonale  degeneracy=4
    do col=1,Nside/2
       vec(ij2site( col,   0))   =vec(ij2site(0,  col))
       vec(ij2site( 0,  -col))   =vec(ij2site(0,  col))
       vec(ij2site(-col,   0))   =vec(ij2site(0,  col))
       vec(ij2site(col, -col))   =vec(ij2site(col,col))
       vec(ij2site(-col, col))   =vec(ij2site(col,col))
       vec(ij2site(-col,-col))   =vec(ij2site(col,col))
    enddo
    !nel semipiano e fuori dalle linee sopramenzionate degeneracy =8 
    do col=2,Nside/2    
       do row=1,col-1
          vec(ij2site(-row, col))  =vec(ij2site(row,col)) ! riflessioni rispetto agli assi
          vec(ij2site( row,-col))  =vec(ij2site(row,col))
          vec(ij2site(-row,-col))  =vec(ij2site(row,col))
          vec(ij2site( col, row))  =vec(ij2site(row,col)) ! riflessione con la bisettrice 
          vec(ij2site(-col, row))  =vec(ij2site(row,col))
          vec(ij2site( col,-row))  =vec(ij2site(row,col))
          vec(ij2site(-col,-row))  =vec(ij2site(row,col))
       enddo
    enddo
  end subroutine r_symmetrize
  !+----------------------------------------------------------------+
  subroutine c_symmetrize(vec)
    integer                                :: row,col
    complex(8), dimension(:),intent(INOUT) :: vec
    !assi cartesiani e diagonale  degeneracy=4
    do col=1,Nside/2
       vec(ij2site( col,   0))   =vec(ij2site(0,  col))
       vec(ij2site( 0,  -col))   =vec(ij2site(0,  col))
       vec(ij2site(-col,   0))   =vec(ij2site(0,  col))
       vec(ij2site(col, -col))   =vec(ij2site(col,col))
       vec(ij2site(-col, col))   =vec(ij2site(col,col))
       vec(ij2site(-col,-col))   =vec(ij2site(col,col))
    enddo
    !nel semipiano e fuori dalle linee sopramenzionate degeneracy =8 
    do col=2,Nside/2    
       do row=1,col-1
          vec(ij2site(-row, col))  =vec(ij2site(row,col)) ! riflessioni rispetto agli assi
          vec(ij2site( row,-col))  =vec(ij2site(row,col))
          vec(ij2site(-row,-col))  =vec(ij2site(row,col))
          vec(ij2site( col, row))  =vec(ij2site(row,col)) ! riflessione con la bisettrice 
          vec(ij2site(-col, row))  =vec(ij2site(row,col))
          vec(ij2site( col,-row))  =vec(ij2site(row,col))
          vec(ij2site(-col,-row))  =vec(ij2site(row,col))
       enddo
    enddo
  end subroutine c_symmetrize



  !******************************************************************
  !******************************************************************
  !******************************************************************

  function dv_reshuffled(m_in) result(m_out)
    integer                               :: i
    real(8), dimension(Ns)           :: m_in
    real(8), dimension(Nindip)       :: m_out
    do i=1,Nindip
       m_out(i)=m_in(indipsites(i))
    enddo
  end function dv_reshuffled

  function zv_reshuffled(m_in) result(m_out)
    integer                               :: i
    complex(8), dimension(Ns)           :: m_in
    complex(8), dimension(Nindip)       :: m_out
    do i=1,Nindip
       m_out(i)=m_in(indipsites(i))
    enddo
  end function zv_reshuffled

  function dm_reshuffled(m_in) result(m_out)
    integer                               :: i
    real(8), dimension(Ns,L)           :: m_in
    real(8), dimension(Nindip,L)       :: m_out
    do i=1,Nindip
       m_out(i,:)=m_in(indipsites(i),:)
    enddo
  end function dm_reshuffled


  function zm_reshuffled(m_in) result(m_out)
    integer                               :: i
    complex(8), dimension(Ns,L)           :: m_in
    complex(8), dimension(Nindip,L)       :: m_out
    do i=1,Nindip
       m_out(i,:)=m_in(indipsites(i),:)
    enddo
  end function zm_reshuffled

end module RDMFT_VARS_GLOBAL
