# Source from this workspace: . env/env.sh [lane]
W=/home/pgeorgakopoulos/pkgwasm-bench
export JULIA=/home/pgeorgakopoulos/solverlink/julia/julia-1.13.2/bin/julia
export NODE=/home/pgeorgakopoulos/wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node
export NODE24_JLL_FLAGS=--experimental-wasm-jspi
LANE=${1:-${PKGWASM_LANE:-bench}}
mkdir -p "$W/depot/$LANE"
export JULIA_DEPOT_PATH=$W/depot/$LANE:/home/pgeorgakopoulos/wasm-pkg/env/depot/shared:/home/pgeorgakopoulos/solverlink/depot:
export JULIA_PKG_OFFLINE=true JULIA_PKG_PRECOMPILE_AUTO=0
export JULIA_PKG_USE_CLI_GIT=true JULIA_NUM_THREADS=2 JULIA_NUM_PRECOMPILE_TASKS=2
export HEAVY=
export WASMOPT=/home/pgeorgakopoulos/solverlink/depot/artifacts/08a7abded1b1c3841367954bd8651f019597bbfa/bin/wasm-opt
export PATH=$(dirname "$NODE"):$(dirname "$WASMOPT"):$PATH
export TMPDIR=$W/out/tmp
mkdir -p "$TMPDIR"
export BENCH_CPUSET=72-79
