# BenchIO natively: julia --project=bench/env bench/native.jl <workload> <input> <scratch> <result>
# With BENCH_WARM=1 the workload runs once first (scratch/warm, result.warm), so the timed call's
# `ns` excludes JIT compilation.
include(joinpath(@__DIR__, "BenchIO.jl"))
if get(ENV, "BENCH_WARM", "") == "1"
    w, input, scratch, result = ARGS
    mkpath(joinpath(scratch, "warm", "x"))
    BenchIO.run_workload([w, input, joinpath(scratch, "warm"), result * ".warm"]) == 0 || exit(1)
    rm(joinpath(scratch, "warm"); recursive = true)
end
exit(BenchIO.run_workload(ARGS))
