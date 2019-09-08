import LinearAlgebra: I, Symmetric, cond, diagm, dot
using RunLengthArrays
import Healpix

################################################################################
# Pointing generation (used for testing)

function build_F(ntod, baseline_lengths)
    F = zeros(ntod, length(baseline_lengths))

    startidx = 1
    for (i, cur_len) in enumerate(baseline_lengths)
        nelems = min(ntod - startidx + 1, cur_len)
        F[startidx:(startidx + nelems - 1), i] .= 1
        startidx += nelems
    end
    
    F
end

function build_P_and_psi(pixidx, npix)
    ntod = length(pixidx)
    P = zeros(ntod, 3npix)
    psi = Array{Float64}(undef, ntod)

    curangle = 0.0
    for (idx, curpix) in enumerate(pixidx)
        psi[idx] = curangle

        P[idx, 1 + 3(curpix - 1)] = 1
        P[idx, 2 + 3(curpix - 1)] = cos(2curangle)
        P[idx, 3 + 3(curpix - 1)] = sin(2curangle)

        curangle += 2π / ntod
    end

    P, psi
end

generate_pixidx(ntod, npix) = Iterators.take(Iterators.cycle(1:npix), ntod) |> collect

################################################################################

# Here we build a number of vectors and matrices that solve the full map-making
# equation by explicitly building all the matrices in full form. The values here
# will be compared with the ones produced by the map-maker.
#
# Unlike the destriping code, we do *not* split baselines/TODs/etc. among MPI
# processes: each MPI process carries the full computation.

NTOD = 512
BASELINES = RunLengthArray{Int, Float64}(
    Int[NTOD/8, NTOD/4, NTOD/4, 3NTOD/8],
    Float64[2, -3, 1, 0],
)

# Map with NSIDE = 1
skymap = Healpix.PolarizedMap{Float64, Healpix.RingOrder}(
    Float64[1,   3,   -4,    6,    5,   -1,   -4,    2,   8,   0,   -1,   -2],
    Float64[1.0, 1.8,  0.7,  6.8, -2.2,  6.0,  0.3, -0.3, 4.7, 7.2,  5.1,  7.2],
    Float64[1.2, 0.4,  0.7, -1.4,  5.4,  4.9,  4.1, -1.0, 4.2, 5.9,  2.4,  3.8],
)

# The order is I1, Q1, U1, I2, Q2, U2…
m = reshape([skymap.i skymap.q skymap.u]', 3length(skymap.i))

NPIX = length(skymap.i)
PIXIDX = generate_pixidx(NTOD, NPIX)

diagCw = [1.1 for _ in 1:NTOD]
Cw = diagm(0 => diagCw)
invCw = inv(Cw)

P, PSI = build_P_and_psi(PIXIDX, NPIX)
F = build_F(NTOD, runs(BASELINES))
M = P' * invCw * P
invM = inv(M)
Z = I - P * invM * P' * invCw
D = F' * invCw * Z * F

y = P * m + F * values(BASELINES)

# These are the terms in the destriping equation "Ax = b"
A = F' * invCw * Z * F
b = F' * invCw * Z * y

baseline_guess = inv(F' * invCw * Z * F) * F' * invCw * Z * y
# Remove the average
baseline_guess .-= sum(baseline_guess) / length(baseline_guess)
# This is the maximum-likelihood map
map_guess = inv(P' * invCw * P) * P' * invCw * (y - F * baseline_guess)

################################################################################
# True map-maker

# The code that follows structures the data depending whether we are
# using MPI or not:
#
# 1. When we are *not* using MPI, there are two observations
# 2. When we are using MPI, we force the usage of two processes, and each
#    process holds only one observation.

obs_range1 = 1:sum(runs(BASELINES)[1:2])
obs_range2 = (sum(runs(BASELINES)[1:2]) + 1):NTOD

mpicomm = if Harlequin.use_mpi()
    # If use_mpi returns true, this means that this file
    # ("test_mapmaking.jl") is being run within "test_mpi.jl", which
    # has already imported the MPI library. So we can freely use
    # functions in the MPI package

    MPI.Init()
    MPI.COMM_WORLD
else
    nothing
end

# Range of validity of the array of baselines
baseline_range = if Harlequin.use_mpi()
    (MPI.Comm_rank(mpicomm) == 0) ? (1:2) : (3:4)
else
    1:4
end

rank_baselines = if Harlequin.use_mpi()
    @assert MPI.Comm_size(mpicomm) == 2

    RunLengthArray{Int, Float64}(
        runs(BASELINES)[baseline_range],
        values(BASELINES)[baseline_range],
    )
else
    BASELINES
end

rank_runs = if Harlequin.use_mpi()
    [runs(rank_baselines)]
else
    [runs(rank_baselines)[1:2], runs(rank_baselines)[3:4]]
end

rank_baselines = if Harlequin.use_mpi()
    [collect(rank_baselines)]
else
    [collect(BASELINES)[obs_range1], collect(BASELINES)[obs_range2]]
end

time_samp = 0.01 # Integration time for one sample; it is not really used

# This holds the same information as matrix M = P' ⋅ Cw^-1 ⋅ P
nobs_matrix = [NobsMatrixElement{Float64}() for i in 1:NPIX]

obs_list = [
    Observation{Float64}(
        pixidx = PIXIDX[obs_range1],
        psi_angle = PSI[obs_range1],
        tod = y[obs_range1],
        sigma_squared = diagCw[obs_range1],
        name = "Det1",
    )
    Observation{Float64}(
        pixidx = PIXIDX[obs_range2],
        psi_angle = PSI[obs_range2],
        tod = y[obs_range2],
        sigma_squared = diagCw[obs_range2],
        name = "Det2",
    )
]

# When using MPI, we only use two processes and assign the two
# observations to each of them
obs_list = Harlequin.use_mpi() ? [obs_list[MPI.Comm_rank(mpicomm) + 1]] : obs_list

let io = IOBuffer()
    show(io, obs_list[1])
    show(io, "text/plain", obs_list[1])
end

compute_nobs_matrix!(nobs_matrix, obs_list, comm = mpicomm)

# Test that NobsMatrixElement objects can be showed
let io = IOBuffer()
    show(io, nobs_matrix[1])
    show(io, "text/plain", nobs_matrix[1])
end

# Verify that nobs_matrix is really a representation of matrix M
for i in 1:NPIX
    startidx = 1 + 3(i - 1)
    subm = @view M[startidx:(startidx + 2), startidx:(startidx + 2)]
    @test nobs_matrix[i].invm ≈ inv(subm)
    @test Symmetric(nobs_matrix[i].m) * nobs_matrix[i].invm ≈ I
end

# Test compute_z_and_group!

@test length(runs(BASELINES)) == 4

dest_baselines = if use_mpi()
    [
        Float64[0.0, 0.0],
    ]
else
    [
        Float64[0.0, 0.0],
        Float64[0.0, 0.0],
    ]
end

destriping_data = DestripingData{Float64, Healpix.RingOrder}(
    1,
    obs_list,
    rank_runs,
    max_iterations = 15,
    threshold = 1e-14,
    use_preconditioner = true,
    comm = mpicomm,
)

# Check that the "show" method works in all its forms

let io = IOBuffer()
    show(io, destriping_data)
    show(io, "text/plain", destriping_data)
end

compute_z_and_group!(
    dest_baselines,
    rank_runs,
    destriping_data,
    obs_list,
    comm = mpicomm,
)

@test collect(Iterators.flatten(dest_baselines)) ≈ b[baseline_range]

left_side = if use_mpi()
    [
        Float64[0.0, 0.0],
    ]
else
    [
        Float64[0.0, 0.0],
        Float64[0.0, 0.0],
    ]
end

reset_maps!(destriping_data)

compute_z_and_group!(
    left_side, 
    rank_baselines,
    rank_runs,
    destriping_data,
    obs_list,
    comm = mpicomm,
)

@test collect(Iterators.flatten(left_side)) ≈ (A * values(BASELINES))[baseline_range]

reset_maps!(destriping_data)

destripe!(
    obs_list,
    destriping_data,
    comm = mpicomm,
)

estimated_baselines = collect(Iterators.flatten([x.values for x in destriping_data.baselines]))
@test estimated_baselines ≈ values(BASELINES)[baseline_range]

@test (abs.(destriping_data.skymap.i .- skymap.i) |> maximum) < 0.3
@test (abs.(destriping_data.skymap.q .- skymap.q) |> maximum) < 0.3
@test (abs.(destriping_data.skymap.u .- skymap.u) |> maximum) < 0.3
