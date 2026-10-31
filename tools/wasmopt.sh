#!/usr/bin/env bash
# wasm-opt exactly as WasmCodegen's driver runs it (src/driver.jl `wasm_opt`), with the
# Config.optimize part replaced by the given options:
#   tools/wasmopt.sh IN.wasm OUT.wasm <options...>     e.g.  -O3   |  -O4  |  -O3 -tnh
# Prints "wasmopt_s=<seconds>" on stdout. Binaryen_jll 0.130.0 (wasm-opt version 130).
set -euo pipefail
ulimit -c 0 # optimizer assertions are logged; do not generate large core files
WASMOPT=${WASMOPT:-$(command -v wasm-opt)}
in=$1 out=$2; shift 2
FEATURES="--enable-gc --enable-reference-types --enable-multivalue --enable-bulk-memory
          --enable-nontrapping-float-to-int --enable-sign-ext
          --enable-exception-handling --enable-tail-call --enable-mutable-globals"
t0=$(date +%s.%N)
"$WASMOPT" "$@" $FEATURES --closed-world --type-ssa --gufa "$in" -o "$out"
t1=$(date +%s.%N)
awk -v a="$t0" -v b="$t1" 'BEGIN {printf "wasmopt_s=%.6f\n", b-a}'
