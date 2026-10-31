# PkgWasm benchmarks

Stock Julia versus PkgWasm on aarch64, eight IO workloads, and a Binaryen/Node flag sweep. The measured run used Julia **1.13.2**, Node **24.22.1**, Binaryen **130**, and an 80-core ARM Neoverse-N1 host.

- [Full report](REPORT.md): all three tables, wall/RSS and phase details, corrections, recommendations, and exact original-host commands.
- [Short status](STATUS.md).
- [Public results issue](https://github.com/gbaraldi/WasmCodegen.jl/issues/43).
- [Compact tables](out/session-tables.md) and [full tables](out/tables.md).
- Raw measurement CSV: [Pkg](out/table1/results.csv), [IO](out/table2/io.csv), [Pkg sweep](out/table3/results.csv), [IO sweep](out/table3-io/io.csv), [startup](out/startup/startup.csv), [optimizer cost](out/opt.csv).
- [Final audit](out/audit.json), [source pins](SOURCES.toml), and [publication inventory](PUBLICATION.json).

## Findings

Wasm is faster than stock for warm/no-op M4 and slower for cold M4. M4 names the fixed 33-package `Pkg.instantiate()` workload, not a CPU model. Warmed native Julia wins every IO operation. Metadata imports and small writes are the strongest engineering leads.

Keep O3 and default Node tiering/GC settings for this workload. Os is an optional size/memory tradeoff. No tested flag provides a clear general speed improvement. O4 hits a Binaryen assertion; tnh remains unsafe despite passing the fixture checks. See the report for five-round ranges and load context.

## What is included

This repository contains the benchmark modules, patched runner snapshot, serial controller, frozen baseline fixtures, original M4 project and packed registry, compact measurement data, audit/gate results, and the completed report. The runner snapshot starts at `c83c3d8bf8d58656c75d04d8fd7b2d1133970a7a`; [runner.patch](out/runner.patch) records the benchmark's changes.

Large generated modules, package depots, IO inputs, downloaded caches, per-run physical depots and full host/process logs are excluded. The original host report retains links to some files that remain local only. Published CSV load averages and aggregate results are included; other users' process details are not published.

The complete run passed **430 correctness gates**. It contains 645 Pkg rows, 120 IO rows, 340 Pkg-sweep rows, 510 IO-sweep rows, 25 startup rows and 110 optimizer-cost rows, in complete five-round groups. Verify this published subset without Julia or the compiler sources:

```bash
python3 tools/verify-results.py
```

## Source availability

**Compiler and Pkg sources are supplied separately.** Place clean Git checkouts at the exact commits in [SOURCES.toml](SOURCES.toml):

```text
src/WasmCodegen.jl
src/PkgWasm.jl
src/WasmBuilder.jl
src/IRStructurizer.jl
```

These are the measured local experimental snapshots. At publication, the WasmCodegen and Pkg commits are not reachable from their GitHub forks. The benchmark therefore does not claim to run out of the box from upstream main. No experimental source repository or its history is silently vendored here. On the original machine, the exact clean repositories are retained in the benchmark workspace's `src/` directory. Full `harness/audit.py` also requires these checkouts and the generated run artifacts.

## Rerun

A full run can take roughly twelve hours on the measured host because the native PkgWasm fork incurs substantial first-command JIT in every fresh process. It can temporarily consume roughly 162 GiB if all physical run states are retained. Do not schedule another timed batch concurrently. The optional cleanup below removes reproducible per-run payloads after a successful audit, retaining result records and complete base references.

Supply Julia 1.13.2, Node 24.22.1, and Binaryen 130 (`wasm-opt` and `wasm-dis`). Configure executable paths and a CPU set available to the process. The portable environment script uses a private depot first; optional shared depots are for reads only. [env/env.arm-measured.sh](env/env.arm-measured.sh) preserves the exact original host configuration.

```bash
export JULIA=/path/to/julia-1.13.2/bin/julia
export NODE=/path/to/node-24.22.1/bin/node
export WASMOPT=/path/to/binaryen-130/bin/wasm-opt
export BENCH_CPUSET=72-79   # choose an available set; use it for every implementation
. env/env.sh build

# Archive published results first; the controller appends CSV.
mv out out.published
mkdir -p out/tmp

# Fresh resolver depot may need Pkg network access to install build dependencies.
export JULIA_PKG_OFFLINE=false
"$JULIA" --startup-file=no runner/scenarios.jl prepare
mkdir -p fixtures/initial/m4/project fixtures/initial/m4/depot/registries
cp -a fixtures/m4-original/project/. fixtures/initial/m4/project/
cp -a fixtures/m4-original/prep-depot/registries/. fixtures/initial/m4/depot/registries/

"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn
. env/env.sh raw
"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn \
  --no-optimize --env-dir out/raw/build-env --out out/raw/pkgwasm.raw.wasm
. env/env.sh io-build
"$JULIA" --startup-file=no --project=bench/env -e 'import Pkg; Pkg.instantiate()'
"$JULIA" --startup-file=no --project=bench/env bench/build.jl out/raw/bench.raw.wasm
. env/env.sh harness
python3 harness/overnight.py > out/controller.log 2>&1
python3 harness/audit.py
python3 harness/report.py
# Optional, only after all batches and the audit finish:
python3 tools/prune-run-depots.py
```

Allow only Pkg package/artifact downloads and the frozen server's upstream cache fill during a run. Never update a registry in a shared depot: supply it in the private depot instead. There is no heavy wrapper, memory cap or heap-size hint.

`harness/report.py` regenerates tables from CSV. Its preamble and recommendations describe the recorded run; review that narrative against new results before publishing a rerun.

## Publication changes

The measured harness, benchmark and runner code is preserved. Publication adds this README, portable `env/env.sh`, a source-pin manifest, the compact-data verifier and checksum inventory. The optional cleanup helper uses the completed controller/audit gate rather than a one-time repair-process log. These packaging changes were made after timing and were not used to produce the recorded measurements.
