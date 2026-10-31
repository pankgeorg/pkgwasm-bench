# Source from this repository: . env/env.sh [lane]
W=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export JULIA=${JULIA:-$(command -v julia)}
export NODE=${NODE:-$(command -v node)}
export WASMOPT=${WASMOPT:-$(command -v wasm-opt)}
if test -z "$JULIA" || test -z "$NODE" || test -z "$WASMOPT"; then
    echo 'Set JULIA, NODE and WASMOPT to the pinned toolchain executables.' >&2
    return 1
fi
LANE=${1:-${PKGWASM_LANE:-bench}}
mkdir -p "$W/depot/$LANE" "$W/out/tmp"
export JULIA_DEPOT_PATH="$W/depot/$LANE:${JULIA_READONLY_DEPOTS:+$JULIA_READONLY_DEPOTS:}"
export JULIA_PKG_OFFLINE=${JULIA_PKG_OFFLINE:-true}
export JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_PKG_USE_CLI_GIT=true
export JULIA_NUM_THREADS=2 JULIA_NUM_PRECOMPILE_TASKS=2
export NODE24_JLL_FLAGS=--experimental-wasm-jspi
export HEAVY=
export PATH="$(dirname "$NODE"):$(dirname "$WASMOPT"):$PATH"
export TMPDIR="$W/out/tmp"
export BENCH_CPUSET=${BENCH_CPUSET:-$(python3 -c 'import os; print(",".join(map(str,sorted(os.sched_getaffinity(0))[-8:])))')}
