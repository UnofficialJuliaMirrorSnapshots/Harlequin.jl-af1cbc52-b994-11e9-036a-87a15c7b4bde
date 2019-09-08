using Harlequin
using Test

@testset "Quaternions" begin
    include("test_quaternions.jl")
end

@testset "Pointing generation" begin
    include("test_genpointings.jl")
end

@testset "Segmented time spans" begin
    include("test_sts.jl")
end

@testset "Dipole analysis" begin
    include("test_dipole.jl")
end

@testset "Beam functions" begin
    include("test_beams.jl")
end

@testset "Map-making functions" begin
    include("test_mapmaking.jl")
end

@testset "MPI" begin
    import MPI: mpiexec

    nprocs = 2  # test_mapmaking.jl assumes that only two processes are being used!
    juliaexec = joinpath(Sys.BINDIR, Base.julia_exename())
    @test success(`$mpiexec -n $nprocs $juliaexec test_mpi.jl`)
end
