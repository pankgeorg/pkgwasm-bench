# PkgWasm benchmarks on arm

The run is complete. Wasm beats stock for warm/no-op M4 and loses for cold M4; warmed native wins every IO operation. The flag sweep supports retaining O3 and default Node settings, with Os as an optional size/memory tradeoff. All final gates pass; O4 is blocked by Binaryen. Full spreads, loads and recommendations follow.

This run compares the pinned PkgWasm build with stock Julia on the original arm host, exercises eight IO workloads, and measures Binaryen and Node flags. Full raw data and code changes remain in `/home/pgeorgakopoulos/pkgwasm-bench`. At the user’s later explicit request, the aggregated results were published as [WasmCodegen.jl issue #43](https://github.com/gbaraldi/WasmCodegen.jl/issues/43); this supersedes the original no-posting restriction for that issue only.

## Machine, toolchain and inputs

Host `georgettarm` (`arm.silentech.gr`), Linux aarch64, 80 ARM Neoverse-N1 cores, one socket/NUMA node, about 250 GiB RAM; shared with other users. See [host snapshot](out/host.txt). No other users' processes or workspaces were changed.

- Julia 1.13.2: `/home/pgeorgakopoulos/solverlink/julia/julia-1.13.2/bin/julia`.
- Node 24.22.1: `/home/pgeorgakopoulos/wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node`.
- Binaryen_jll 0.130.0+0, wasm-opt/wasm-dis 130, read from solverlink artifact `08a7abded1b1c3841367954bd8651f019597bbfa`.
- WasmCodegen `5d4b68e0d5eba32ee901d06e81c525efaa2d8666`; PkgWasm `9fe2f5ab458abba7b4d4f3de4aa86e64f97d67b5`; WasmBuilder `4b64c589478e8769209a3870488f65c77a751f6c`; IRStructurizer `ab056b165d5038229e2dd700df932b8a9704e03b`. All four source repositories remain clean. See [input hashes](out/source-inputs.txt) and final audit.
- Git 2.43.0 for S-git's local fixture repositories. No external git workload is used.
- Frozen platform is exactly `aarch64-linux-gnu-libgfortran5-cxx11-libstdcxx30-julia_version+1.13.2`; Wasm receives `--platform-from-frozen`. The host matches it ([platform check](out/m4-platform.txt)).
- Exact resolved build dependencies remain in [full build manifest](out/build-env/Manifest.toml), [raw build manifest](out/raw/build-env/Manifest.toml), and [IO build manifest](bench/env/Manifest.toml).

## Protocol and decisions

No heavy wrapper, memory cap, or heap-size hint was used. Runtime batches run one at a time, without overlapping builds or optimizer invocations. Timed harnesses, their implementations and local server inherit `taskset -c 72-79`, equally for all implementations. These CPUs are not reserved: the host remains shared. Optimizer-cost samples consistently use normal host affinity. Every timed batch has `uptime` and `top -bn1 | head -20` captured immediately beforehand; Runtime CSV also records load1 before each command; optimizer CSV records it after each invocation, with the pre-invocation snapshot retained in logs. Affinity, interleaving and load records reduce ambiguity but do not remove contention or OS-cache effects.

Private depots under this workspace are first in the build/harness depot stack; shared depots are read only. Build dependency resolution is offline. Actual Pkg commands use the runner's sanitized frozen environment and a fresh per-case depot; they do not inherit the build shell's JULIA settings. Build/harness Julia uses two threads; command processes retain the original runner's environment policy without a JULIA_NUM_THREADS override. The frozen server serves cached inputs; only its upstream fill and Pkg dependency/artifact fetches were permitted network access. **Stock application-package precompilation is disabled (`JULIA_PKG_PRECOMPILE_AUTO=0`) beside every stock comparison.** Registry and package cache setup and result comparison are outside measured command intervals.

Every command runs in a fresh process. Implementations rotate order over five rounds. Base equivalence precedes timing: expected exits, strict stdout/stderr and captured project/depot/request state are compared with local stock; the 13 committed scenarios also compare directly with `fixtures/baseline`. M4 has no committed baseline and uses local stock. No comparator checks were weakened.

M4 names the fixed 33-package `Pkg.instantiate()` workload, rather than a processor model. Original M4 inputs were copied from `~/wasm-pkg/out/s2-pkg/m4/` to [fixtures/m4-original](fixtures/m4-original). The reconstructed Julia 1.13.3 fixture is unused. The original `m4-run.jl` copies only `prep-depot/registries`, so the initial template contains that packed registry and original project, without prep-depot's packages/compiled caches. There are exactly 33 non-stdlib package tree hashes. Local server delay is zero, download concurrency eight. Cold means a fresh depot with registry installed; warm removes installed packages while retaining registry/scratch caches; no-op retains installed packages too. Cold is not a claim about cold OS page cache.

## Corrections needed to obtain valid comparisons

**Stock baseline differences:** the first local stock runs of **S-artifacts, S-gc and S-gc-auto** lacked the committed baseline's “Updating registry” stderr announcement. All functional captured state matched. Rebuilding the fixtures gave their update log a recent timestamp; `Pkg.API.add` has a one-day update cooldown (Julia Pkg `src/API.jl:305`). The runner now ages existing update-log timestamps to `2000-01-01` for these three scenarios, identically for every implementation. Registry contents and strict comparisons are unchanged. All final stock scenarios match their committed baselines. Original differences are retained in [out/validation-before-age-fix](out/validation-before-age-fix); corrected gates/logs are in [out/validate](out/validate) and [validate-age-fix.log](out/logs/validate-age-fix.log).

**HANDOFF finding 7:** copied M4 usage logs retained keys containing the predecessor project's path. `copy_state` now rebases those exact predecessor-root strings in copied `depot/logs/*.toml`; other usage data remains compared. This resolves the native warm mismatch without changing the comparator.

**M4 warm cache:** a second issue was found from the first measured warm/no-op results. PkgWasm's registry index key includes the compressed tarball's absolute path, size, mtime, ctime and inode (`src/PkgWasm.jl/src/Registry/registry_instance.jl:448–476`). Cloning cold depots into different paths invalidated that index. The first 45 M4 rows and states are excluded and archived in [out/m4-relocated-cache-miss](out/m4-relocated-cache-miss). Final cold → warm → no-op runs share one physical `M4-work` depot per round/implementation. Separate snapshots preserve results but never become warm inputs. Wasm warm/no-op asserts the same tar identity and index generation before/after; all ten final base checkpoints pass. No cache header or guard was modified. M4 correctness was rerun before replacement timing.

**Native fork interpretation:** PkgWasm omits stock Pkg's precompile workload (`src/PkgWasm.jl/src/PkgWasm.jl:1118`). Its import cache is primed, but fresh command processes still incur substantial first-call compilation. This differs from disabling application-package auto-precompile. Use stock as the practical native CLI comparison; a large Wasm/fork advantage is not the same as an IO throughput advantage. Separate startup measurements characterize empty/import-only processes and cannot simply be subtracted from first-command JIT cost. Table 2 explicitly includes native operation warm-up.

## Eager-compilation runner liveness correction

`--no-wasm-lazy-compilation` initially made Node exit zero before WebAssembly.compile resolved: no stdout/stderr, installed packages or IO result files. Strict gates caught the missing work, and no timing was accepted. The M4 warm assertion then stopped that validation because no index existed. A top-level-await probe reported an unsettled promise; keeping Node's event loop alive during compilation made it complete ([probes](out/logs/nolazy-toplevel-probe.log), [keepalive probe](out/logs/nolazy-keepalive-probe.log)). This isolates a process-liveness issue; it is not evidence of a Wasm workload semantic failure.

`tools/compile-keepalive.mjs` wraps only the pending WebAssembly.compile promise with a timer and clears it on resolution/rejection. It is supplied by Node --import on **both sides of the no-lazy paired comparison only**, leaving other batches unchanged. Both the O3+preload baseline and the no-lazy+preload variant receive full Pkg/selected-IO equivalence gates before timing. The original failed state/logs are retained in out/nolazy-premature-exit and out/logs. The controller includes this repair for fresh reruns. A one-time helper completed the repaired batch after the existing serial queue finished. All baseline/variant gates and five paired rounds pass.

## Path, runner and harness patches

No `src/` repository was edited. [runner.patch](out/runner.patch) records every runner change relative to snapshot `c83c3d8`:

- `runner/build.jl`: retained the handoff's `--irs` option and explicit IRStructurizer dependency/source pin to the local snapshot, plus Node's pinned host default.
- `runner/scenarios.jl`: Node default, `Dates` import, and the three scenario-specific registry-age controls above.
- `runner/pkgwasm.mjs`: added explicit `compile_only`, `instantiate_only`, `init_only`, `main_only` elapsed durations. Original cumulative marks remain. This observes phases without changing the workload.
- `runner/imagescan.jl` is unchanged; Binaryen's bin directory is supplied on PATH.

Other workspace changes:

- `env/env.sh`: rewritten for pinned arm toolchain, workspace-private depots/TMPDIR, Binaryen PATH, empty HEAVY, fixed runtime CPU set. `env/env.sh.orig` remains unchanged.
- `harness/pkgbench.jl`: original M4 setup and stable cache-preserving lifecycle; usage-log rebasing; frozen platform; strict committed/local equivalence gates and partial-gate merging; untimed validation; per-command load and per-round uptime/top; retained per-round outputs; corrected phase columns/startup compile label; removed WSL heavy-scope waits.
- `harness/iobench.jl`: untimed native/native-warm/Wasm gates, result-directory Wasm preopen, untimed scratch parent setup, unique scratch tags and scratch-local native TMPDIR; pinned Node and batch/load records; removed WSL waits.
- Both Julia load-snapshot helpers use an explicit `/bin/sh` pipeline. Their first launch failed before any operation was measured; excluded logs are in `out/failed-timing-startup`. GNU time's `%M %e` output provides the same peak-RSS/elapsed metrics as its verbose form; reported wall uses a higher-resolution harness clock.
- `bench/BenchIO.jl`: concrete argument bindings outside try/catch, constant error output, distinct local read! accumulator to avoid a boxed counter. These fix benchmark compilation, not compiler/source code. `bench/build.jl` uses default Config with optimization deferred; `bench/native.jl` performs optional same-process warm-up.
- `tools/wasmopt.sh`: environment/PATH Binaryen, awk elapsed calculation instead of bc, core dumps disabled after the O4 assertion. This imposes no memory limit. A preliminary sample affected by editing the shell wrapper while it ran is excluded in `out/preliminary-opt`.
- `tools/compile-keepalive.mjs`: scoped pending-compile lifetime repair described above; no source or main-runner modification.
- `harness/overnight.py`: serial controller, five optimizer samples, checked resume fingerprint, immediate stop on timed-batch failure, and machine-readable gate selection. `harness/report.py`, `harness/audit.py` and `tools/progress.py` provide reporting/audit/progress. One-time repair helpers and their logs are retained locally; obsolete PID helpers were moved to `out/maintenance`.

Early fixture/IO smoke checks, failed compilation diagnostics, and original progress notes are retained in `out/m4-precheck`, `out/io-precheck`, `out/logs/build-io*.log`, and [out/REPORT-progress.md](out/REPORT-progress.md); none supplies final timings. Final IO uses the zero-diagnostic default-Config build. The main controller and source, rather than the handoff's legacy `harness/sweep.sh`, are the rerun entry point.

## Build and optimizer interpretation

Pkg full/raw builds use `-O3`/no optimize respectively, unsafe trim, seam patch and verify warn, matching `heads.sh` configuration. IO uses default Config (`trim=:safe`, `on_unsupported=:error`, `verify=:warn`) with only optimization deferred and the standard runtime sanitize hook. At this commit `Config(host=:wasi)` does not exist; WASI is the sole host. All eight IO workloads compile, including `walkdir`: WasmCodegen's `trim/wasm-fs.jl:77` redirects it to the task-free iterator in `runtime/fs.jl:1423` with tasks disabled.

Full build versus raw+O3 is **not code-identical on arm**, unlike the x86 handoff. Both have 3,355 function bodies; 257 differ, 253 explained by integer constants and four also structurally (including dispatch branch order). Code sections are 4,022,570 and 4,022,572 bytes. Process-dependent hash/iteration order is a plausible explanation, not proof. [out/code-compare](out/code-compare) retains disassemblies/diff. Table 1 uses the full module; the sweep derives every optimizer variant from one raw module and gates it independently, so flag comparisons do not rely on full/raw identity.

Every variant retains the driver's feature flags plus `--closed-world --type-ssa --gufa`. Exact extra flags appear in the optimizer appendix and controller. A tiny local Binaryen debug trace confirms `-O3 -O3` really executes two pass sequences ([out/flag-probes](out/flag-probes)). `-O4` aborts on both modules in Binaryen 130 `Flatten.cpp:231`, “unexpected expr type”; it is blocked, without compiler changes or substitute flags.

For **both** modules, O3, tmerge, atr and rut have identical bytes; gufaopt and gccombo also match each other ([hashes](out/module-hashes.csv)). Their runtime differences under identical Node flags are measurement variation. `-tnh` assumes traps never happen; passing finite fixture gates cannot establish that assumption for trapping/error inputs outside these tests. It remains unsafe for a general default.

## IO input scope

Fixed inputs: 48 decompressed package tarballs; populated depot with 63,408 files and 15,025 directories (35,629,119 file bytes); 100,000 println lines (3,988,895 bytes); 100 MiB binary file; 58,525 registry TOML files; 10,000-entry directory. Tar includes extraction, tree hashing, creation and tar tree hashing. Read combines read+SHA and read!+SHA; neither measures disk bandwidth alone. Copy includes verification hashes; directory work includes file creation, readdir and recursive removal. Subphase timers remain in CSV. The sweep selects tar (Pkg extraction/creation), walk (metadata), and lines (small writes) to cover three distinct IO costs. No candidate was skipped for unsupported code.

Host calls are counted in a separate instrumented run, never used for measured durations. All eight instrumented checked outputs match native references ([instrumentation audit](out/instrumentation-check.json)). Counts include entry/result plumbing as well as the workload. Counts are one observation, not five-run timing statistics.

## Audit and retained data

All 430 final correctness gates pass. The final audit checks all six CSV files for complete five-round groups, expected row counts and true equivalence results; all base/sweep gates, the four clean pinned source commits, unchanged validated inputs, eight instrumented-output references and ten base M4 cache checkpoints. Evidence: [out/audit.json](out/audit.json), [out/audit-before-prune.json](out/audit-before-prune.json), and [out/pruned-depots.json](out/pruned-depots.json).

The user-requested disk-usage scan ran during the final semi128 IO batch (about 09:30–09:33 UTC). That metadata scan is an additional contention source for those samples; their paired spreads are retained, and no semi-space change is recommended from these small differences. No timing runs overlap the later cleanup.

After the audit, reproducible package/registry/artifact/compiled/scratch payloads in per-run depots are removed to reduce disk use. CSVs, stdout/stderr, request logs, captured state hashes/TOML, timing JSON, cache headers, projects, source and build artifacts remain. The complete base correctness states in out/validate and all fixtures are retained for targeted reruns. Per-variant and timed physical depots are no longer full replayable run directories; regenerate them with the rerun commands to repeat direct live comparisons.

Workspace disk footprint fell from 161.97 GiB to 10.02 GiB after pruning (151.95 GiB reclaimed); the filesystem has 331.98 GiB free at completion. Full base references, fixtures, modules, all CSV/logs/captured hashes and timing records remain. Allocation scans: out/disk-usage.txt and out/disk-usage-after-prune.txt; exact removed paths: out/pruned-depots.json.
