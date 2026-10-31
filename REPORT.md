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


## Measurement definitions

Each measured cell is median [min–max] over five rounds. Table 1 sums the separately launched command processes within a scenario and takes their maximum RSS per round; the appendix lists every command. RSS is process peak from GNU time, in MiB. Wall seconds use the harness monotonic clock around GNU time. Ratios are paired by round and have their own median and range. Load1 ranges cover the commands in that row; each batch’s uptime/top snapshot is retained alongside CSV. Build sizes and host-call counts are fixed observations rather than five-run timing estimates. Optimizer timings are five independent invocations; builds themselves are single executions.

Table 2 operation timers exclude process startup. Native cold includes first-call JIT; native warmed runs the same workload once first in the same process. End-to-end wall/RSS remain in the appendix. Every workload and flag variant is checked without timing before measured batches. No OS cache flush was attempted on the shared host.


## Table 1 — Pkg cases

| Case (sum of fresh processes) | Stock Pkg, precompile off | PkgWasm native | Wasm | Wasm/stock | Wasm/native fork | Load1 range |
| --- | --- | --- | --- | --- | --- | --- |
| M4-cold | 2.892 [2.797–2.949] s; 410.8 [409.1–413.2] MiB | 72.044 [71.648–73.218] s; 1208.3 [1205.4–1212.7] MiB | 3.442 [3.290–3.466] s; 738.1 [737.7–745.3] MiB | 1.19 [1.16–1.21] | 0.048 [0.046–0.048] | 20.98–28.89 |
| M4-warm | 2.952 [2.838–2.987] s; 410.8 [409.9–411.7] MiB | 71.865 [68.054–73.565] s; 1207.9 [1203.9–1209.9] MiB | 2.504 [2.460–2.531] s; 717.2 [714.8–802.3] MiB | 0.85 [0.83–0.87] | 0.035 [0.034–0.036] | 16.68–29.65 |
| M4-noop | 1.832 [1.777–1.903] s; 383.3 [382.7–383.7] MiB | 67.244 [64.293–70.875] s; 1202.6 [1193.2–1203.9] MiB | 1.170 [1.145–1.196] s; 712.6 [710.5–716.7] MiB | 0.64 [0.63–0.65] | 0.017 [0.017–0.018] | 16.14–31.93 |
| S-status | 1.500 [1.482–1.529] s; 371.7 [371.6–372.1] MiB | 71.395 [71.071–71.984] s; 1201.5 [1199.8–1202.7] MiB | 1.393 [1.372–1.421] s; 612.7 [604.9–613.9] MiB | 0.93 [0.90–0.96] | 0.020 [0.019–0.020] | 15.18–19.47 |
| S-resolve | 1.990 [1.962–2.023] s; 378.3 [378.3–379.0] MiB | 70.806 [70.481–71.210] s; 1202.8 [1201.7–1208.6] MiB | 1.464 [1.425–1.498] s; 614.5 [607.0–746.3] MiB | 0.73 [0.72–0.76] | 0.021 [0.020–0.021] | 15.78–19.51 |
| S-rm | 2.201 [2.182–2.236] s; 375.3 [374.8–376.1] MiB | 72.141 [72.019–72.703] s; 1202.2 [1199.2–1204.5] MiB | 1.517 [1.440–1.606] s; 605.1 [600.8–611.2] MiB | 0.68 [0.66–0.73] | 0.021 [0.020–0.022] | 15.66–18.82 |
| S-instantiate | 4.150 [3.824–4.191] s; 381.1 [380.4–381.7] MiB | 137.301 [125.142–137.861] s; 1200.4 [1188.8–1203.1] MiB | 2.468 [2.434–2.547] s; 716.7 [713.7–730.6] MiB | 0.60 [0.59–0.64] | 0.018 [0.018–0.020] | 3.82–17.36 |
| S-add | 5.687 [5.638–5.732] s; 602.6 [596.6–609.0] MiB | 75.695 [75.112–76.948] s; 1288.1 [1286.5–1293.2] MiB | 15.602 [15.473–15.656] s; 971.0 [966.8–1024.8] MiB | 2.73 [2.72–2.78] | 0.21 [0.20–0.21] | 3.24–5.25 |
| S-fail | 1.603 [1.591–1.651] s; 382.1 [381.4–382.9] MiB | 65.614 [65.302–66.716] s; 1181.7 [1179.5–1188.9] MiB | 1.016 [0.978–1.032] s; 198.4 [193.1–283.9] MiB | 0.63 [0.60–0.64] | 0.015 [0.015–0.016] | 2.81–6.10 |
| S-compressed | 12.805 [12.562–12.878] s; 609.1 [607.8–609.8] MiB | 272.275 [268.800–276.848] s; 1287.4 [1284.9–1291.1] MiB | 26.757 [26.688–27.006] s; 830.3 [818.7–946.9] MiB | 2.10 [2.08–2.13] | 0.098 [0.098–0.100] | 2.83–12.23 |
| S-registry | 16.094 [15.261–16.340] s; 418.6 [417.9–420.3] MiB | 403.301 [377.959–413.009] s; 1229.0 [1227.5–1231.1] MiB | 8.322 [8.230–8.333] s; 364.0 [353.4–373.5] MiB | 0.51 [0.51–0.55] | 0.020 [0.020–0.022] | 4.90–31.03 |
| S-registry-compressed | 8.967 [8.330–9.154] s; 388.3 [387.7–390.3] MiB | 205.805 [193.602–208.319] s; 1205.9 [1204.9–1208.0] MiB | 3.583 [3.478–3.705] s; 361.5 [355.8–367.6] MiB | 0.40 [0.39–0.42] | 0.018 [0.017–0.018] | 8.04–35.98 |
| S-git | 20.993 [19.489–21.743] s; 378.5 [378.5–379.1] MiB | 602.661 [578.354–606.682] s; 1203.3 [1200.8–1218.9] MiB | 9.921 [9.779–10.308] s; 609.8 [609.3–723.5] MiB | 0.48 [0.47–0.51] | 0.017 [0.016–0.017] | 4.66–29.88 |
| S-artifacts | 10.327 [10.079–10.491] s; 422.6 [422.2–423.6] MiB | 292.050 [281.707–303.785] s; 1234.5 [1225.3–1266.9] MiB | 5.707 [5.657–5.773] s; 820.3 [814.2–957.9] MiB | 0.55 [0.54–0.57] | 0.019 [0.019–0.020] | 10.42–29.45 |
| S-gc | 15.015 [14.320–15.203] s; 620.5 [619.2–621.2] MiB | 357.099 [344.245–373.085] s; 1319.9 [1316.6–1320.7] MiB | 15.590 [15.401–15.715] s; 820.9 [814.0–977.1] MiB | 1.04 [1.03–1.08] | 0.044 [0.041–0.045] | 7.14–33.09 |
| S-gc-auto | 7.696 [7.653–7.789] s; 422.5 [422.1–423.7] MiB | 226.188 [220.456–230.305] s; 1230.0 [1224.1–1264.9] MiB | 4.519 [4.453–4.678] s; 824.1 [820.1–827.2] MiB | 0.59 [0.58–0.60] | 0.020 [0.020–0.021] | 9.99–28.48 |


## Startup, measured separately

| Process | Wall s | Peak MiB | Load1 range |
| --- | --- | --- | --- |
| julia -e 0 | 0.194 [0.189–0.196] | 153.8 [153.8–153.8] | 14.67–14.86 |
| julia + load Pkg | 0.675 [0.659–0.690] | 271.9 [271.9–272.5] | 14.71–14.86 |
| julia + load PkgWasm | 0.401 [0.389–0.407] | 231.9 [231.2–231.9] | 14.71–14.86 |
| node -e 0 | 0.043 [0.041–0.044] | 39.4 [38.8–39.4] | 14.71–14.86 |
| node compile pkgwasm.wasm | 0.077 [0.072–0.080] | 53.1 [52.5–53.1] | 14.71–14.86 |


## Table 2 — IO workloads

| Workload | Native cold op | Native warmed op | Wasm op | Wasm/warmed | Top host calls (one untimed run) | Load1 range |
| --- | --- | --- | --- | --- | --- | --- |
| tar | 3.360 [3.206–3.469] s | 0.425 [0.421–0.440] s | 2.960 [2.941–2.994] s | 7.00 [6.69–7.12] | wasi_snapshot_preview1.path_filestat_get: 12994; wasi_snapshot_preview1.fd_seek: 10524; julia_io.path_mode: 10245 | 11.05–25.79 |
| walk | 0.621 [0.569–2.528] s | 0.556 [0.545–0.724] s | 8.352 [8.315–8.510] s | 15.01 [11.69–15.25] | wasi_snapshot_preview1.path_filestat_get: 156866; julia_io.path_mode: 156866; wasi_snapshot_preview1.fd_close: 15027 | 12.41–25.75 |
| walkdir | 0.674 [0.652–0.774] s | 0.668 [0.649–0.735] s | 7.029 [6.894–7.283] s | 10.77 [9.38–10.91] | wasi_snapshot_preview1.path_filestat_get: 126816; julia_io.path_mode: 126816; wasi_snapshot_preview1.fd_close: 15027 | 15.33–26.08 |
| lines | 0.068 [0.065–0.071] s | 0.060 [0.057–0.061] s | 1.535 [1.270–1.584] s | 25.87 [22.36–26.78] | wasi_snapshot_preview1.fd_write: 400001; wasi_snapshot_preview1.fd_read: 64; wasi_snapshot_preview1.random_get: 5 | 16.93–26.00 |
| read | 0.910 [0.900–0.952] s | 0.900 [0.895–0.906] s | 3.958 [3.948–3.980] s | 4.41 [4.38–4.42] | wasi_snapshot_preview1.fd_read: 3200; wasi_snapshot_preview1.clock_time_get: 5; wasi_snapshot_preview1.random_get: 5 | 15.79–25.92 |
| cp | 0.123 [0.118–0.338] s | 0.111 [0.110–0.115] s | 0.868 [0.854–0.888] s | 7.87 [7.46–8.07] | julia_io.path_mode: 6866; wasi_snapshot_preview1.path_filestat_get: 6862; wasi_snapshot_preview1.fd_close: 3985 | 14.98–26.11 |
| toml | 2.064 [2.037–4.862] s | 1.989 [1.956–2.032] s | 11.094 [10.937–11.339] s | 5.54 [5.44–5.70] | wasi_snapshot_preview1.path_filestat_get: 135516; julia_io.path_mode: 135516; wasi_snapshot_preview1.fd_read: 116330 | 13.87–26.35 |
| dir | 0.460 [0.450–0.542] s | 0.444 [0.431–0.530] s | 1.775 [1.736–1.879] s | 3.98 [3.55–4.11] | julia_io.path_mode: 20004; wasi_snapshot_preview1.path_filestat_get: 20002; wasi_snapshot_preview1.fd_close: 10003 | 13.28–26.11 |


## Table 3 — flag sweep

The O3 reference row shows the first paired baseline batch; every variant ratio uses its own adjacent O3 runs, retained individually in the appendices. Runtime load covers both sides of the Pkg/IO pairs; optimizer loads are in the optimizer appendix. These five-run ranges are observed spreads, not confidence intervals.

| Variant | Pkg bytes | wasm-opt s | Cold compile; instantiate ms | M4 cold s; MiB | Cold/paired O3 | M4 warm s; MiB | Warm/paired O3 | IO op ratio vs paired O3 | Pkg gates | Runtime load1 range |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| O3 | 5160359 | 44.870 [44.380–46.110] | 33.4 [29.2–33.8]; 17.2 [16.6–20.9] | 3.507 [3.464–3.638] s; 743.4 [735.7–821.3] MiB | reference | 2.545 [2.476–2.589] s; 722.9 [717.2–723.3] MiB | reference | tar —; walk —; lines — | 16/16 | 22.67–35.97 |
| O4 | blocked | blocked | —; — | blocked | — | blocked | — | tar —; walk —; lines — | blocked | — |
| O3conv | 5039129 | 209.990 [207.010–214.570] | 30.3 [28.1–30.9]; 17.1 [16.8–17.5] | 3.544 [3.448–3.590] s; 739.2 [730.7–740.3] MiB | 1.00 [0.98–1.03] | 2.551 [2.527–2.604] s; 718.6 [717.3–720.6] MiB | 1.00 [0.98–1.03] | tar 0.98 [0.98–1.02]; walk 0.99 [0.98–1.01]; lines 1.18 [0.85–1.23] | 16/16 | 22.67–35.97 |
| O3x2 | 5108813 | 58.040 [57.310–58.400] | 32.7 [28.4–35.1]; 17.2 [17.1–17.5] | 3.548 [3.532–3.633] s; 741.0 [733.8–754.4] MiB | 1.00 [0.99–1.02] | 2.555 [2.517–2.605] s; 723.2 [716.2–728.7] MiB | 1.00 [0.94–1.01] | tar 0.99 [0.97–1.00]; walk 1.00 [0.99–1.02]; lines 1.01 [0.85–1.26] | 16/16 | 31.26–37.96 |
| Os | 4914055 | 42.050 [41.850–42.440] | 33.5 [30.5–34.4]; 16.9 [16.2–17.0] | 3.549 [3.481–3.571] s; 657.0 [608.9–674.9] MiB | 1.01 [0.97–1.02] | 2.551 [2.490–2.637] s; 567.1 [561.9–567.6] MiB | 1.04 [1.01–1.05] | tar 1.05 [1.04–1.06]; walk 0.99 [0.98–1.00]; lines 0.95 [0.84–0.98] | 16/16 | 13.47–29.54 |
| gufaopt | 5164579 | 51.970 [51.600–52.690] | 32.0 [29.0–33.1]; 17.1 [16.7–17.7] | 3.432 [3.406–3.561] s; 744.1 [737.7–829.5] MiB | 0.99 [0.95–1.02] | 2.570 [2.465–2.605] s; 723.8 [717.8–822.2] MiB | 1.00 [0.98–1.05] | tar 1.00 [0.98–1.03]; walk 1.00 [0.99–1.03]; lines 0.99 [0.87–1.17] | 16/16 | 29.61–36.72 |
| tmerge | 5160359 | 44.450 [44.120–44.950] | 31.5 [28.7–32.7]; 16.4 [15.9–17.0] | 3.437 [3.288–3.555] s; 739.0 [736.8–744.3] MiB | 1.00 [0.96–1.05] | 2.486 [2.413–2.532] s; 723.0 [713.2–724.9] MiB | 1.01 [0.98–1.02] | tar 1.00 [0.99–1.02]; walk 1.00 [0.98–1.01]; lines 1.05 [0.84–1.25] | 16/16 | 18.36–31.31 |
| atr | 5160359 | 44.590 [44.160–45.720] | 31.5 [29.1–33.9]; 17.0 [16.4–20.9] | 3.468 [3.386–3.593] s; 743.8 [738.5–748.1] MiB | 1.00 [0.95–1.04] | 2.483 [2.466–2.512] s; 719.4 [711.4–736.7] MiB | 1.00 [0.96–1.01] | tar 1.01 [0.99–1.03]; walk 1.00 [0.97–1.02]; lines 1.03 [0.85–1.20] | 16/16 | 27.43–30.32 |
| rut | 5160359 | 44.780 [44.260–45.650] | 31.7 [30.0–32.3]; 16.7 [16.4–17.8] | 3.430 [3.422–3.466] s; 739.8 [736.9–744.1] MiB | 1.00 [0.97–1.03] | 2.466 [2.451–2.484] s; 720.9 [715.0–725.5] MiB | 1.01 [0.98–1.01] | tar 1.00 [1.00–1.01]; walk 1.00 [0.99–1.02]; lines 0.96 [0.85–1.03] | 16/16 | 13.48–27.87 |
| mono | 5161808 | 205.980 [188.550–222.560] | 31.3 [29.8–32.5]; 16.3 [16.1–16.9] | 3.294 [3.270–3.321] s; 735.7 [729.3–737.2] MiB | 1.00 [0.97–1.00] | 2.405 [2.344–2.468] s; 714.4 [712.8–724.4] MiB | 1.02 [0.99–1.04] | tar 0.99 [0.98–1.00]; walk 1.00 [0.96–1.01]; lines 0.98 [0.86–1.04] | 16/16 | 6.77–14.89 |
| gccombo | 5164579 | 53.290 [52.990–53.940] | 31.8 [30.9–34.1]; 16.8 [16.3–17.2] | 3.551 [3.410–3.575] s; 743.0 [732.4–752.1] MiB | 1.02 [0.99–1.04] | 2.509 [2.427–2.542] s; 722.0 [714.0–726.6] MiB | 1.00 [0.98–1.04] | tar 0.99 [0.99–1.01]; walk 1.00 [0.99–1.03]; lines 1.02 [0.84–1.06] | 16/16 | 9.61–33.15 |
| tnh (unsafe) | 5054227 | 43.930 [43.590–44.140] | 31.3 [28.7–32.8]; 16.7 [16.1–18.5] | 3.428 [3.320–3.518] s; 745.9 [739.7–749.5] MiB | 1.00 [0.97–1.03] | 2.457 [2.350–2.631] s; 720.8 [716.9–724.2] MiB | 0.99 [0.98–1.04] | tar 0.99 [0.98–0.99]; walk 1.01 [1.00–1.01]; lines 0.87 [0.84–1.20] | 16/16 | 17.44–32.06 |
| node-noliftoff | 5160359 | same O3 | 33.3 [30.8–34.6]; 17.6 [16.8–17.9] | 11.165 [10.940–11.241] s; 753.0 [749.2–753.9] MiB | 3.21 [3.13–3.24] | 10.059 [9.572–10.191] s; 752.7 [752.3–754.3] MiB | 4.00 [3.95–4.07] | tar 1.30 [1.25–1.31]; walk 1.02 [0.99–1.04]; lines 1.10 [0.94–1.13] | 16/16 | 18.63–30.37 |
| node-liftoffonly | 5160359 | same O3 | 29.6 [27.2–33.5]; 16.5 [15.9–17.7] | 18.159 [18.073–18.314] s; 307.6 [305.0–347.8] MiB | 5.23 [4.99–5.40] | 13.653 [13.627–13.871] s; 199.5 [198.7–200.7] MiB | 5.39 [5.24–5.53] | tar 3.29 [3.26–3.29]; walk 2.74 [2.72–2.78]; lines 1.66 [1.56–2.03] | 16/16 | 13.92–31.13 |
| node-nodyntier | 5160359 | same O3 | 31.8 [31.1–34.6]; 16.3 [16.0–17.2] | 3.836 [3.788–4.026] s; 940.6 [937.8–946.0] MiB | 1.14 [1.14–1.20] | 2.769 [2.675–2.837] s; 821.7 [814.8–828.0] MiB | 1.13 [0.49–1.16] | tar 1.05 [1.03–1.06]; walk 1.02 [1.00–1.05]; lines 1.06 [0.83–1.31] | 16/16 | 5.74–16.12 |
| node-nolazy | 5160359 | same O3 | 274.5 [273.1–286.1]; 16.2 [16.0–20.2] | 3.405 [3.364–3.524] s; 1087.2 [1040.8–1120.8] MiB | 1.03 [1.01–1.07] | 2.472 [2.454–2.571] s; 936.4 [929.0–992.3] MiB | 1.04 [1.02–1.08] | tar 1.00 [0.99–1.01]; walk 1.02 [1.00–1.04]; lines 1.12 [1.07–1.28] | 16/16 | 4.45–10.82 |
| node-semi32 | 5160359 | same O3 | 34.1 [27.1–35.8]; 16.4 [16.3–16.6] | 3.422 [3.379–3.437] s; 738.7 [730.5–744.7] MiB | 1.00 [0.95–1.01] | 2.475 [2.410–2.506] s; 718.2 [713.1–720.0] MiB | 1.00 [0.99–1.03] | tar 0.99 [0.99–1.02]; walk 1.00 [0.99–1.01]; lines 1.01 [0.99–1.05] | 16/16 | 6.71–18.36 |
| node-semi64 | 5160359 | same O3 | 31.7 [28.9–32.9]; 16.2 [16.0–17.1] | 3.390 [3.354–3.610] s; 743.3 [736.5–752.0] MiB | 0.98 [0.97–1.05] | 2.450 [2.422–2.563] s; 719.0 [713.3–721.2] MiB | 1.00 [1.00–1.03] | tar 1.00 [0.99–1.01]; walk 1.00 [0.98–1.01]; lines 1.00 [0.98–1.16] | 16/16 | 6.71–12.86 |
| node-semi128 | 5160359 | same O3 | 31.5 [29.5–39.6]; 16.4 [16.1–16.7] | 3.410 [3.343–3.496] s; 738.9 [736.4–746.5] MiB | 1.00 [0.99–1.03] | 2.466 [2.413–2.510] s; 718.4 [716.1–724.0] MiB | 1.00 [0.85–1.04] | tar 1.00 [0.99–1.03]; walk 1.00 [0.98–1.00]; lines 1.02 [0.85–1.06] | 16/16 | 7.31–10.76 |

Node labels: node-noliftoff = `--no-liftoff`; node-liftoffonly = `--liftoff-only`; node-nodyntier = `--no-wasm-dynamic-tiering`; node-nolazy = `--no-wasm-lazy-compilation`; node-semi32/64/128 = `--max-semi-space-size=32/64/128`, respectively. Each uses the same O3 bytes. The no-lazy pair additionally imports tools/compile-keepalive.mjs on BOTH sides, after separate baseline/variant gates; see the liveness correction below.


## Equivalence and blockers


Every base Pkg implementation passed its local equivalence gates; stock matched every committed scenario baseline.


IO gates: all 24 pass


| Variant | Pkg gates | IO gates | Failed cases |
| --- | --- | --- | --- |
| O3 | 16/16 | base 24/24 | — |
| O4 | blocked | blocked | — |
| O3conv | 16/16 | 3/3 | — |
| O3x2 | 16/16 | 3/3 | — |
| Os | 16/16 | 3/3 | — |
| gufaopt | 16/16 | 3/3 | — |
| tmerge | 16/16 | 3/3 | — |
| atr | 16/16 | 3/3 | — |
| rut | 16/16 | 3/3 | — |
| mono | 16/16 | 3/3 | — |
| gccombo | 16/16 | 3/3 | — |
| tnh | 16/16 | 3/3 | — |
| node-noliftoff | 16/16 | 3/3 | — |
| node-liftoffonly | 16/16 | 3/3 | — |
| node-nodyntier | 16/16 | 3/3 | — |
| node-nolazy | 16/16 | 3/3 | — |
| node-semi32 | 16/16 | 3/3 | — |
| node-semi64 | 16/16 | 3/3 | — |
| node-semi128 | 16/16 | 3/3 | — |


Additional O3 keepalive baseline gates: 16/16 Pkg, 3/3 IO.


## Build verification

identical=False


out/pkgwasm.wasm.build.toml: {'status': 'ok', 'julia': '1.13.2', 'size_bytes': 5160488, 'elapsed_s': 405.8, 'maxrss_mib': 1789.3, 'diagnostics_count': 0, 'verifier_errors': 0, 'embedded_host_strings': [], 'poison_strings_found': []}


out/raw/pkgwasm.raw.wasm.build.toml: {'status': 'ok', 'julia': '1.13.2', 'size_bytes': 10073679, 'elapsed_s': 360.4, 'maxrss_mib': 1659.8, 'diagnostics_count': 0, 'verifier_errors': 0, 'embedded_host_strings': ['/home/pgeorgakopoulos', '/home/pgeorgakopoulos/pkgwasm-bench/'], 'poison_strings_found': []}


## Cached compilation

```
COMMAND ['/home/pgeorgakopoulos/wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node', 'tools/cache-probe.mjs', 'out/variants/O3.wasm']
same_process_structured_clone_module=true
serialized_bytes=2
cross_process_cache_unavailable=Unable to deserialize cloned data.

```

The tested Node v8 serialization API cannot persist this WebAssembly.Module for another fresh process. Same-process structuredClone preserves a Module, so in-process reuse is possible; it was not measured as a cached CLI workload. No cross-process cache timing is substituted. The phase tables report the initial WebAssembly.compile call; lazy/background V8 compilation can occur later, so compile_only is not an upper bound on every compilation cost or a predicted cache speedup.


## Recommendations

Keep the existing **O3 and default Node tiering/GC settings** for this workload. No successful Binaryen variant demonstrates a general runtime improvement beyond the byte-identical controls' variation. Extra type passes that emit identical bytes add no runtime optimization; converge and monomorphize substantially increase optimizer cost without a corresponding runtime benefit. The tables retain every five-run spread and load range; these are small samples on a shared host.

Use **Os as an optional size/memory profile**, rather than the fastest default. It emits 4,914,055 bytes versus O3's 5,160,359 (fixed artifact sizes). Its warm M4 peak is 567.1 [561.9–567.6] MiB, with runtime load1 13.47–29.54; warm wall ratio is 1.04 [1.01–1.05] and Tar ratio 1.05 [1.04–1.06] against adjacent O3. This is a measured memory/time tradeoff, not a speed recommendation.

Avoid **no-liftoff**, **liftoff-only**, and **no dynamic tiering** for this fresh-process CLI. The first two produce large M4 regressions; disabling dynamic tiering also increases the M4 median and RSS. Semi-space 32/64/128 provides no consistent general gain in these samples. The complete paired spreads and workload-dependent effects are in Table 3. Eager compilation with the paired keepalive repair is also slower: M4 cold ratio 1.03 [1.01–1.07], warm 1.04 [1.02–1.08], and lines 1.12 [1.07–1.28], at runtime load1 4.45–10.82. Its M4 cold peak is 1087.2 [1040.8–1120.8] MiB. Retain lazy compilation for this CLI.

Do not enable **tnh** as a general default. It passes the fixture checks but supplies no clear overall gain, and assumes away trapping execution that this finite corpus cannot exclude. O4 is blocked by Binaryen 130's assertion on both inputs. A fresh-process persisted Module cache is unavailable through the tested Node v8 serialization API; same-process reuse would require a different lifetime/protocol.

Prioritize **small-write coalescing** and **metadata-call reduction** as engineering experiments. The separate counter run observes 400,001 fd_write imports for 100,000 lines, and 156,866 each of path_mode and path_filestat_get for recursive metadata walking. The operation ratios to warmed native are 25.87 [22.36–26.78] for lines (load1 16.93–26.00) and 15.01 [11.69–15.25] for walk (12.41–25.75). These counts identify traffic to investigate; they do not prove what fraction of time a batching implementation would save. The read+SHA workload also remains slower with only 3,200 fd_read imports, so host-call count alone does not explain every workload.

For the practical CLI comparison, **stock wins M4 cold, while Wasm wins warm/no-op**: paired Wasm/stock wall ratios 1.19 [1.16–1.21], 0.85 [0.83–0.87], 0.64 [0.63–0.65], respectively (load1 20.98–28.89, 16.68–29.65, 16.14–31.93; stock auto-precompile off). Wasm's peak RSS is higher in these M4 cases. S-add and S-compressed also favor stock. Use the full per-case table rather than claiming a universal Wasm advantage; the native fork's missing precompile workload makes its fresh-process numbers a separate deployment comparison.


## Exact rerun commands

```bash
cd /home/pgeorgakopoulos/pkgwasm-bench
. env/env.sh build
"$JULIA" --startup-file=no runner/scenarios.jl prepare
mkdir -p fixtures/initial/m4/project fixtures/initial/m4/depot/registries
cp -a fixtures/m4-original/project/. fixtures/initial/m4/project/
cp -a fixtures/m4-original/prep-depot/registries/. fixtures/initial/m4/depot/registries/
cp -an fixtures/m4-original/cache/. fixtures/cache/
"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn
. env/env.sh raw
"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn --no-optimize --env-dir out/raw/build-env --out out/raw/pkgwasm.raw.wasm
. env/env.sh io-build
"$JULIA" --startup-file=no --project=bench/env -e 'import Pkg; Pkg.instantiate()'
"$JULIA" --startup-file=no --project=bench/env bench/build.jl out/raw/bench.raw.wasm
. env/env.sh harness
python3 harness/overnight.py > out/controller.log 2>&1
python3 harness/report.py
```

The controller source records every variant and command. Each invocation is also written as COMMAND in out/logs/*.log. It appends CSV; move old output aside inside this workspace before a full rerun to avoid combining runs. fixtures/initial/m4 contains only the original project and prep-depot/registries; recreate that template from fixtures/m4-original if removed.


## Raw data and detailed command timings

- out/table1/results.csv, out/startup/startup.csv, out/table2/io.csv, out/table3/results.csv, out/table3-io/io.csv and out/opt.csv.
- out/logs contains build, validation, instrumentation, and controller command logs.
- out/validate and out/sweep-eq contain gate files, per-command captured state, stdout/stderr and request logs.
- out/table*/load-*.txt and out/startup/load-*.txt contain uptime and busiest processes before each timed round.
- harness/report-preamble.md and harness/recommendations.md retain this run’s narrative. report.py refreshes tables from CSV; review narrative observations/recommendations against any new rerun rather than treating the old prose as new evidence.


| Scenario | Command | Args | Stock precompile off s; MiB | Native s; MiB | Wasm s; MiB | Load1 range |
| --- | --- | --- | --- | --- | --- | --- |
| M4-cold | 1 | instantiate | 2.892 [2.797–2.949] s; 410.8 [409.1–413.2] MiB | 72.044 [71.648–73.218] s; 1208.3 [1205.4–1212.7] MiB | 3.442 [3.290–3.466] s; 738.1 [737.7–745.3] MiB | 20.98–28.89 |
| M4-warm | 1 | instantiate | 2.952 [2.838–2.987] s; 410.8 [409.9–411.7] MiB | 71.865 [68.054–73.565] s; 1207.9 [1203.9–1209.9] MiB | 2.504 [2.460–2.531] s; 717.2 [714.8–802.3] MiB | 16.68–29.65 |
| M4-noop | 1 | instantiate | 1.832 [1.777–1.903] s; 383.3 [382.7–383.7] MiB | 67.244 [64.293–70.875] s; 1202.6 [1193.2–1203.9] MiB | 1.170 [1.145–1.196] s; 712.6 [710.5–716.7] MiB | 16.14–31.93 |
| S-status | 1 | status | 1.500 [1.482–1.529] s; 371.7 [371.6–372.1] MiB | 71.395 [71.071–71.984] s; 1201.5 [1199.8–1202.7] MiB | 1.393 [1.372–1.421] s; 612.7 [604.9–613.9] MiB | 15.18–19.47 |
| S-resolve | 1 | resolve | 1.990 [1.962–2.023] s; 378.3 [378.3–379.0] MiB | 70.806 [70.481–71.210] s; 1202.8 [1201.7–1208.6] MiB | 1.464 [1.425–1.498] s; 614.5 [607.0–746.3] MiB | 15.78–19.51 |
| S-rm | 1 | rm JSON | 2.201 [2.182–2.236] s; 375.3 [374.8–376.1] MiB | 72.141 [72.019–72.703] s; 1202.2 [1199.2–1204.5] MiB | 1.517 [1.440–1.606] s; 605.1 [600.8–611.2] MiB | 15.66–18.82 |
| S-instantiate | 1 | instantiate | 2.630 [2.411–2.657] s; 381.1 [380.4–381.7] MiB | 70.922 [64.984–71.062] s; 1200.4 [1188.8–1203.1] MiB | 1.340 [1.304–1.388] s; 716.7 [713.7–730.6] MiB | 5.00–17.36 |
| S-instantiate | 2 | instantiate | 1.522 [1.412–1.534] s; 371.0 [370.4–371.2] MiB | 66.380 [60.158–66.857] s; 1199.2 [1180.5–1202.5] MiB | 1.137 [1.095–1.159] s; 619.1 [612.5–630.1] MiB | 3.82–16.91 |
| S-add | 1 | add Example JSON | 5.687 [5.638–5.732] s; 602.6 [596.6–609.0] MiB | 75.695 [75.112–76.948] s; 1288.1 [1286.5–1293.2] MiB | 15.602 [15.473–15.656] s; 971.0 [966.8–1024.8] MiB | 3.24–5.25 |
| S-fail | 1 | add NoSuchPkg | 1.603 [1.591–1.651] s; 382.1 [381.4–382.9] MiB | 65.614 [65.302–66.716] s; 1181.7 [1179.5–1188.9] MiB | 1.016 [0.978–1.032] s; 198.4 [193.1–283.9] MiB | 2.81–6.10 |
| S-compressed | 1 | status | 1.717 [1.692–1.720] s; 385.0 [383.9–386.2] MiB | 65.357 [64.864–66.799] s; 1190.3 [1189.1–1202.5] MiB | 2.487 [2.428–2.529] s; 668.2 [631.2–681.5] MiB | 2.87–12.23 |
| S-compressed | 2 | resolve | 4.023 [3.978–4.044] s; 588.8 [586.9–589.0] MiB | 66.549 [65.859–68.323] s; 1287.4 [1283.2–1291.1] MiB | 11.266 [11.175–11.332] s; 803.3 [795.6–946.9] MiB | 2.83–9.26 |
| S-compressed | 3 | rm JSON | 2.372 [2.326–2.450] s; 390.7 [389.5–391.1] MiB | 66.797 [65.573–68.476] s; 1196.5 [1190.0–1209.3] MiB | 1.638 [1.619–1.677] s; 603.8 [602.6–612.9] MiB | 3.11–9.32 |
| S-compressed | 4 | add JSON | 4.613 [4.518–4.719] s; 609.1 [607.8–609.8] MiB | 73.274 [71.770–74.065] s; 1276.0 [1270.8–1284.9] MiB | 11.416 [11.305–11.487] s; 823.3 [806.8–830.3] MiB | 3.08–9.38 |
| S-registry | 1 | registry add General | 3.305 [3.223–3.372] s; 418.6 [417.9–420.3] MiB | 69.685 [64.364–71.734] s; 1229.0 [1227.5–1231.1] MiB | 3.889 [3.826–3.940] s; 358.1 [353.4–373.5] MiB | 6.43–27.47 |
| S-registry | 2 | registry status | 3.033 [2.795–3.061] s; 390.3 [390.0–391.2] MiB | 66.778 [60.448–68.571] s; 1205.4 [1189.3–1208.1] MiB | 1.877 [1.856–1.889] s; 352.7 [350.5–364.0] MiB | 6.37–27.46 |
| S-registry | 3 | registry update | 3.166 [3.020–3.206] s; 389.2 [388.8–390.0] MiB | 69.181 [62.385–70.364] s; 1205.3 [1189.1–1207.3] MiB | 0.923 [0.900–0.929] s; 169.9 [169.1–172.9] MiB | 4.90–27.84 |
| S-registry | 4 | status | 1.411 [1.335–1.431] s; 360.7 [360.5–361.1] MiB | 71.067 [66.428–73.097] s; 1197.3 [1187.2–1201.1] MiB | 0.427 [0.415–0.430] s; 169.1 [159.4–169.4] MiB | 6.62–31.03 |
| S-registry | 5 | registry rm General | 2.786 [2.596–2.804] s; 384.5 [384.1–386.0] MiB | 65.835 [60.481–67.843] s; 1203.8 [1188.2–1206.7] MiB | 0.865 [0.849–0.872] s; 169.5 [157.6–176.2] MiB | 5.20–29.03 |
| S-registry | 6 | registry status | 2.447 [2.291–2.513] s; 363.0 [362.2–363.1] MiB | 65.845 [62.586–67.435] s; 1198.4 [1182.9–1199.3] MiB | 0.334 [0.324–0.338] s; 167.8 [154.8–169.5] MiB | 5.46–29.40 |
| S-registry-compressed | 1 | registry status | 3.047 [2.807–3.095] s; 388.3 [387.7–390.3] MiB | 68.286 [60.350–69.710] s; 1204.3 [1183.5–1207.7] MiB | 1.859 [1.789–1.889] s; 361.5 [355.8–367.6] MiB | 15.17–32.88 |
| S-registry-compressed | 2 | registry update | 3.177 [2.938–3.220] s; 387.9 [387.1–389.6] MiB | 70.306 [65.136–71.932] s; 1204.9 [1191.1–1207.3] MiB | 0.893 [0.865–0.933] s; 169.6 [169.5–180.6] MiB | 8.04–35.00 |
| S-registry-compressed | 3 | registry rm General | 2.770 [2.584–2.839] s; 382.9 [382.2–385.8] MiB | 66.678 [63.468–68.115] s; 1205.3 [1202.2–1208.0] MiB | 0.835 [0.809–0.886] s; 161.8 [160.2–166.2] MiB | 9.97–35.98 |
| S-git | 1 | registry add git/Reg | 2.461 [2.300–2.564] s; 367.9 [366.8–367.9] MiB | 67.830 [61.567–69.400] s; 1197.9 [1185.4–1198.9] MiB | 0.563 [0.533–0.582] s; 164.8 [155.8–185.8] MiB | 5.55–27.52 |
| S-git | 2 | add Foo | 2.267 [2.102–2.343] s; 377.3 [377.3–377.4] MiB | 80.126 [70.818–80.680] s; 1202.6 [1198.8–1218.9] MiB | 1.764 [1.734–1.818] s; 600.8 [592.4–613.9] MiB | 5.82–28.75 |
| S-git | 3 | add git/Foo#dev | 2.947 [2.702–3.075] s; 377.9 [377.2–378.1] MiB | 79.025 [70.509–79.688] s; 1200.4 [1198.9–1202.0] MiB | 1.733 [1.666–1.848] s; 603.2 [594.1–603.4] MiB | 5.14–28.03 |
| S-git | 4 | add file://{rundir}/git/Foo#v0.1.0 | 2.903 [2.665–3.003] s; 378.5 [377.9–378.6] MiB | 78.793 [78.368–79.675] s; 1200.0 [1193.9–1201.4] MiB | 1.628 [1.604–1.774] s; 606.3 [589.6–608.1] MiB | 4.66–29.12 |
| S-git | 5 | add file://{rundir}/git/Foo:sub/Bar | 3.032 [2.799–3.095] s; 378.5 [377.8–379.1] MiB | 78.568 [77.583–78.949] s; 1200.1 [1199.6–1204.9] MiB | 1.691 [1.618–1.712] s; 609.1 [599.0–723.5] MiB | 5.59–29.88 |
| S-git | 6 | develop file://{rundir}/git/Foo | 2.963 [2.742–3.057] s; 377.9 [377.3–378.0] MiB | 77.321 [71.098–77.962] s; 1200.3 [1193.0–1201.5] MiB | 1.516 [1.502–1.579] s; 595.8 [586.4–609.8] MiB | 5.54–27.98 |
| S-git | 7 | registry update | 2.856 [2.698–2.985] s; 370.5 [370.4–370.8] MiB | 69.091 [63.236–69.527] s; 1196.3 [1187.4–1198.0] MiB | 0.556 [0.541–0.605] s; 155.5 [155.0–165.9] MiB | 5.42–27.86 |
| S-git | 8 | status | 1.563 [1.471–1.622] s; 366.1 [365.9–366.6] MiB | 71.542 [65.754–72.281] s; 1197.3 [1184.3–1198.7] MiB | 0.517 [0.493–0.528] s; 164.8 [155.7–167.4] MiB | 5.42–28.77 |
| S-artifacts | 1 | add Bzip2_jll | 3.717 [3.648–3.778] s; 422.2 [419.4–422.6] MiB | 80.157 [73.779–85.280] s; 1234.5 [1225.3–1266.9] MiB | 1.611 [1.566–1.617] s; 820.3 [814.2–957.9] MiB | 17.76–27.74 |
| S-artifacts | 2 | instantiate | 1.527 [1.487–1.544] s; 369.0 [368.6–369.2] MiB | 68.171 [62.928–70.287] s; 1198.9 [1194.8–1202.0] MiB | 1.370 [1.361–1.388] s; 606.6 [600.3–616.0] MiB | 10.42–28.18 |
| S-artifacts | 3 | instantiate | 3.494 [3.439–3.574] s; 421.5 [421.2–423.6] MiB | 72.016 [67.441–75.337] s; 1200.7 [1187.2–1201.4] MiB | 1.336 [1.308–1.383] s; 607.1 [599.4–617.6] MiB | 18.13–29.45 |
| S-artifacts | 4 | status | 1.544 [1.504–1.595] s; 370.1 [369.7–370.5] MiB | 72.881 [67.918–74.865] s; 1200.3 [1199.4–1202.6] MiB | 1.395 [1.392–1.409] s; 615.3 [604.7–708.1] MiB | 15.70–27.83 |
| S-gc | 1 | add Example JSON Bzip2_jll | 6.520 [6.343–6.586] s; 620.5 [619.2–621.2] MiB | 81.907 [80.579–83.668] s; 1319.9 [1316.6–1320.7] MiB | 12.079 [11.968–12.200] s; 820.9 [814.0–977.1] MiB | 17.51–26.81 |
| S-gc | 2 | rm JSON Bzip2_jll | 2.199 [2.090–2.258] s; 373.3 [373.0–373.5] MiB | 73.217 [66.841–76.674] s; 1200.0 [1188.6–1201.9] MiB | 1.115 [1.079–1.121] s; 691.4 [670.2–727.4] MiB | 18.57–27.27 |
| S-gc | 3 | gc | 2.401 [2.258–2.446] s; 367.1 [366.6–367.4] MiB | 65.087 [59.582–69.221] s; 1197.3 [1183.5–1199.1] MiB | 0.549 [0.528–0.563] s; 164.7 [155.7–199.1] MiB | 10.04–27.09 |
| S-gc | 4 | gc --verbose | 2.343 [2.221–2.388] s; 366.7 [366.1–366.8] MiB | 64.811 [62.238–69.227] s; 1194.5 [1182.7–1199.2] MiB | 0.447 [0.439–0.453] s; 156.7 [154.2–165.4] MiB | 7.14–33.09 |
| S-gc | 5 | status | 1.509 [1.409–1.525] s; 369.2 [369.0–369.3] MiB | 72.493 [71.496–76.057] s; 1198.3 [1195.6–1201.1] MiB | 1.372 [1.354–1.396] s; 620.2 [603.1–694.2] MiB | 15.79–30.06 |
| S-gc-auto | 1 | add Example Bzip2_jll | 3.705 [3.675–3.866] s; 422.5 [422.1–423.7] MiB | 82.865 [73.762–84.278] s; 1230.0 [1224.1–1264.9] MiB | 1.619 [1.602–1.712] s; 824.1 [820.1–827.2] MiB | 21.99–27.86 |
| S-gc-auto | 2 | rm Bzip2_jll | 2.448 [2.369–2.496] s; 374.8 [374.2–375.4] MiB | 72.594 [71.220–75.017] s; 1200.2 [1184.3–1204.3] MiB | 1.526 [1.446–1.552] s; 599.6 [597.5–605.0] MiB | 9.99–28.02 |
| S-gc-auto | 3 | status | 1.516 [1.427–1.603] s; 369.3 [369.1–369.3] MiB | 72.424 [69.020–74.718] s; 1197.0 [1192.1–1203.4] MiB | 1.388 [1.370–1.414] s; 602.9 [595.5–708.8] MiB | 18.75–28.48 |



| IO workload | Implementation | Wall s; MiB | Load1 range |
| --- | --- | --- | --- |
| tar | native | 5.613 [5.368–5.804] s; 376.6 [376.3–377.1] MiB | 11.05–25.78 |
| tar | native-warm | 5.921 [5.733–6.171] s; 378.4 [376.7–378.9] MiB | 12.70–25.79 |
| tar | wasm | 3.251 [3.220–3.308] s; 285.3 [283.0–303.5] MiB | 11.84–25.78 |
| walk | native | 2.877 [2.741–4.771] s; 374.2 [374.0–374.3] MiB | 14.49–25.69 |
| walk | native-warm | 3.460 [3.339–3.747] s; 384.2 [383.7–385.0] MiB | 12.41–25.71 |
| walk | wasm | 8.530 [8.480–8.677] s; 76.7 [75.8–78.6] MiB | 13.58–25.75 |
| walkdir | native | 2.927 [2.793–3.068] s; 374.9 [374.8–375.0] MiB | 17.14–26.08 |
| walkdir | native-warm | 3.671 [3.502–3.791] s; 384.8 [384.1–386.0] MiB | 15.33–26.00 |
| walkdir | wasm | 7.200 [7.063–7.459] s; 95.5 [94.6–97.3] MiB | 16.11–25.65 |
| lines | native | 2.330 [2.224–2.339] s; 356.7 [356.1–356.8] MiB | 16.93–25.91 |
| lines | native-warm | 2.409 [2.304–2.454] s; 364.3 [363.6–364.3] MiB | 16.93–25.91 |
| lines | wasm | 1.713 [1.442–1.766] s; 91.5 [89.8–93.3] MiB | 16.93–26.00 |
| read | native | 3.178 [3.064–3.219] s; 449.8 [448.5–450.0] MiB | 15.79–25.92 |
| read | native-warm | 4.098 [4.010–4.156] s; 448.6 [448.6–448.7] MiB | 15.79–25.85 |
| read | wasm | 4.139 [4.112–4.160] s; 169.2 [169.0–170.8] MiB | 16.29–25.92 |
| cp | native | 2.418 [2.301–2.616] s; 355.0 [354.9–355.6] MiB | 15.32–25.86 |
| cp | native-warm | 2.576 [2.465–2.651] s; 366.7 [366.6–366.8] MiB | 14.98–26.11 |
| cp | wasm | 1.048 [1.015–1.056] s; 79.6 [77.9–80.5] MiB | 15.32–26.11 |
| toml | native | 4.328 [4.202–7.175] s; 394.9 [394.3–395.5] MiB | 14.29–26.35 |
| toml | native-warm | 6.299 [6.259–6.419] s; 395.5 [395.4–396.0] MiB | 13.87–26.32 |
| toml | wasm | 11.284 [11.123–11.534] s; 135.8 [128.5–149.5] MiB | 14.98–26.08 |
| dir | native | 2.728 [2.683–2.855] s; 357.8 [357.2–357.9] MiB | 13.28–26.11 |
| dir | native-warm | 3.189 [2.995–3.419] s; 366.7 [366.2–366.9] MiB | 13.28–26.10 |
| dir | wasm | 1.960 [1.915–2.064] s; 95.7 [94.1–102.6] MiB | 13.28–26.11 |


## Optimizer costs, both modules

| Module | Variant | Flags | Bytes | Optimizer s | Peak MiB | Load1 range |
| --- | --- | --- | --- | --- | --- | --- |
| pkgwasm | O3 | -O3 | 5160359 | 44.870 [44.380–46.110] | 2241.5 [2116.5–2279.8] | 4.25–10.31 |
| pkgwasm | O3conv | -O3 --converge | 5039129 | 209.990 [207.010–214.570] | 4001.8 [3788.4–4029.7] | 10.12–19.41 |
| bench | O3 | -O3 | 923339 | 8.490 [8.410–8.640] | 360.1 [352.7–361.6] | 9.53–11.58 |
| bench | O3conv | -O3 --converge | 893528 | 36.570 [35.970–36.880] | 676.8 [670.4–689.7] | 6.96–17.98 |
| pkgwasm | O3x2 | -O3 -O3 | 5108813 | 58.040 [57.310–58.400] | 2616.0 [2508.5–2671.6] | 7.56–11.29 |
| bench | O3x2 | -O3 -O3 | 912121 | 10.400 [10.210–10.670] | 385.6 [363.9–388.4] | 9.63–11.04 |
| pkgwasm | Os | -Os | 4914055 | 42.050 [41.850–42.440] | 2000.2 [1956.3–2058.6] | 6.59–11.62 |
| bench | Os | -Os | 873777 | 5.990 [5.890–6.040] | 335.5 [330.2–336.7] | 8.64–11.01 |
| pkgwasm | gufaopt | -O3 --gufa-optimizing | 5164579 | 51.970 [51.600–52.690] | 2204.8 [2160.7–2276.8] | 5.68–16.34 |
| bench | gufaopt | -O3 --gufa-optimizing | 917343 | 9.620 [9.430–9.770] | 368.7 [367.1–376.0] | 5.91–7.14 |
| pkgwasm | tmerge | --type-merging -O3 | 5160359 | 44.450 [44.120–44.950] | 2205.2 [2135.6–2242.9] | 9.40–16.54 |
| bench | tmerge | --type-merging -O3 | 923339 | 8.390 [8.330–8.550] | 352.7 [348.1–356.5] | 9.48–14.30 |
| pkgwasm | atr | --abstract-type-refining -O3 | 5160359 | 44.590 [44.160–45.720] | 2209.4 [2152.6–2261.5] | 10.56–17.45 |
| bench | atr | --abstract-type-refining -O3 | 923339 | 8.380 [8.300–8.420] | 352.5 [339.9–361.6] | 7.94–9.63 |
| pkgwasm | rut | --remove-unused-types -O3 | 5160359 | 44.780 [44.260–45.650] | 2253.4 [2207.5–2284.8] | 7.05–12.19 |
| bench | rut | --remove-unused-types -O3 | 923339 | 8.480 [8.410–8.500] | 353.5 [350.2–356.3] | 7.22–8.56 |
| pkgwasm | mono | --monomorphize -O3 | 5161808 | 205.980 [188.550–222.560] | 2431.9 [2407.6–2497.6] | 9.53–31.82 |
| bench | mono | --monomorphize -O3 | 921393 | 23.000 [22.280–24.150] | 412.2 [406.8–424.3] | 16.24–30.22 |
| pkgwasm | gccombo | --abstract-type-refining --type-merging --remove-unused-types -O3 --gufa-optimizing | 5164579 | 53.290 [52.990–53.940] | 2227.6 [2096.1–2283.5] | 8.82–15.83 |
| bench | gccombo | --abstract-type-refining --type-merging --remove-unused-types -O3 --gufa-optimizing | 917343 | 9.730 [9.540–9.900] | 370.5 [358.5–373.3] | 9.31–11.92 |
| pkgwasm | tnh | -O3 -tnh | 5054227 | 43.930 [43.590–44.140] | 2187.4 [2161.4–2211.2] | 6.22–16.46 |
| bench | tnh | -O3 -tnh | 905513 | 8.150 [8.100–8.420] | 352.7 [344.9–354.5] | 10.58–14.38 |


## IO sweep details

| Variant pair | Implementation | Workload | Op s | Wall s; MiB | Compile ms | Instantiate ms | Load1 range |
| --- | --- | --- | --- | --- | --- | --- | --- |
| O3conv | wasm | tar | 3.004 [2.986–3.062] | 3.351 [3.273–3.395] s; 287.6 [284.5–322.2] MiB | 11.2 [10.2–13.5] | 5.5 [5.4–5.6] | 24.93–31.39 |
| O3conv | wasm-O3conv | tar | 2.988 [2.932–3.051] | 3.259 [3.198–3.325] s; 215.9 [207.2–217.9] MiB | 9.8 [9.2–12.7] | 5.4 [5.4–5.6] | 24.93–31.39 |
| O3conv | wasm | walk | 8.418 [8.315–8.519] | 8.594 [8.500–8.704] s; 76.2 [75.4–77.3] MiB | 11.5 [9.3–12.0] | 5.6 [5.5–5.7] | 23.42–31.81 |
| O3conv | wasm-O3conv | walk | 8.361 [8.257–8.477] | 8.533 [8.442–8.663] s; 77.9 [77.1–78.7] MiB | 11.3 [8.3–12.4] | 5.5 [5.5–5.8] | 22.67–31.91 |
| O3conv | wasm | lines | 1.300 [1.293–1.544] | 1.488 [1.472–1.725] s; 92.6 [90.5–93.2] MiB | 11.0 [9.7–14.3] | 5.6 [5.5–5.7] | 25.59–31.69 |
| O3conv | wasm-O3conv | lines | 1.526 [1.313–1.603] | 1.703 [1.490–1.784] s; 92.2 [91.2–92.9] MiB | 11.2 [8.3–11.5] | 5.5 [5.4–5.5] | 25.59–31.69 |
| O3x2 | wasm | tar | 3.001 [2.966–3.063] | 3.292 [3.249–3.370] s; 284.5 [256.7–322.0] MiB | 10.3 [9.6–12.2] | 5.5 [5.5–5.7] | 31.63–37.50 |
| O3x2 | wasm-O3x2 | tar | 2.967 [2.937–2.989] | 3.211 [3.190–3.252] s; 214.1 [208.2–220.3] MiB | 12.4 [9.7–13.8] | 5.5 [5.5–5.6] | 31.26–37.06 |
| O3x2 | wasm | walk | 8.383 [8.293–8.454] | 8.549 [8.464–8.636] s; 77.8 [77.3–79.7] MiB | 10.4 [7.6–12.8] | 5.5 [5.4–5.6] | 31.71–35.68 |
| O3x2 | wasm-O3x2 | walk | 8.386 [8.344–8.424] | 8.561 [8.517–8.602] s; 77.6 [76.7–79.3] MiB | 9.8 [8.7–13.2] | 5.5 [5.5–5.6] | 31.58–35.62 |
| O3x2 | wasm | lines | 1.511 [1.267–1.575] | 1.685 [1.434–1.752] s; 91.8 [91.0–93.6] MiB | 9.9 [9.1–11.9] | 5.5 [5.4–5.6] | 31.42–34.53 |
| O3x2 | wasm-O3x2 | lines | 1.521 [1.322–1.597] | 1.694 [1.494–1.773] s; 92.8 [92.3–93.7] MiB | 9.7 [8.7–11.2] | 5.5 [5.4–5.6] | 31.42–34.53 |
| Os | wasm | tar | 2.991 [2.937–3.030] | 3.286 [3.203–3.332] s; 298.4 [279.8–313.3] MiB | 10.8 [9.5–11.9] | 5.5 [5.4–5.6] | 14.47–22.67 |
| Os | wasm-Os | tar | 3.121 [3.101–3.147] | 3.381 [3.343–3.405] s; 213.7 [199.8–222.3] MiB | 10.3 [9.3–14.0] | 5.5 [5.4–5.8] | 14.47–22.67 |
| Os | wasm | walk | 8.342 [8.239–8.352] | 8.509 [8.411–8.534] s; 76.8 [76.4–78.2] MiB | 10.6 [9.7–11.5] | 5.4 [5.4–5.6] | 15.01–23.02 |
| Os | wasm-Os | walk | 8.215 [8.189–8.310] | 8.389 [8.354–8.478] s; 76.4 [75.2–77.6] MiB | 9.6 [8.4–11.5] | 5.5 [5.4–5.5] | 14.49–24.15 |
| Os | wasm | lines | 1.310 [1.250–1.525] | 1.490 [1.416–1.704] s; 92.2 [90.3–93.0] MiB | 10.7 [9.1–13.4] | 5.4 [5.4–5.5] | 13.47–24.46 |
| Os | wasm-Os | lines | 1.215 [1.098–1.449] | 1.387 [1.282–1.633] s; 90.5 [87.6–91.8] MiB | 11.3 [8.4–12.6] | 5.5 [5.4–5.6] | 13.47–24.83 |
| gufaopt | wasm | tar | 3.006 [2.969–3.057] | 3.296 [3.265–3.372] s; 285.8 [281.5–305.0] MiB | 11.6 [11.0–12.1] | 5.6 [5.5–5.6] | 29.62–31.81 |
| gufaopt | wasm-gufaopt | tar | 3.010 [2.967–3.061] | 3.313 [3.277–3.363] s; 284.7 [258.0–320.2] MiB | 10.4 [8.9–13.0] | 5.6 [5.4–5.6] | 29.77–31.43 |
| gufaopt | wasm | walk | 8.442 [8.372–8.466] | 8.615 [8.552–8.644] s; 76.7 [75.8–78.4] MiB | 10.9 [9.7–13.7] | 5.6 [5.5–5.6] | 29.61–30.91 |
| gufaopt | wasm-gufaopt | walk | 8.418 [8.380–8.582] | 8.593 [8.562–8.759] s; 77.0 [75.4–78.5] MiB | 11.1 [9.7–13.4] | 5.5 [5.5–5.6] | 29.62–30.51 |
| gufaopt | wasm | lines | 1.543 [1.335–1.637] | 1.727 [1.526–1.814] s; 92.5 [89.6–92.7] MiB | 11.1 [8.9–12.6] | 5.6 [5.5–5.8] | 29.85–30.87 |
| gufaopt | wasm-gufaopt | lines | 1.545 [1.318–1.677] | 1.722 [1.500–1.869] s; 91.9 [91.2–92.9] MiB | 9.3 [8.1–12.2] | 5.6 [5.5–5.8] | 29.88–32.09 |
| tmerge | wasm | tar | 3.028 [3.008–3.041] | 3.332 [3.329–3.370] s; 303.7 [289.4–320.1] MiB | 9.3 [7.9–12.2] | 5.5 [5.4–5.6] | 18.36–26.77 |
| tmerge | wasm-tmerge | tar | 3.023 [2.998–3.103] | 3.318 [3.297–3.450] s; 283.6 [281.2–287.2] MiB | 11.6 [10.4–12.7] | 5.6 [5.4–5.6] | 19.62–26.77 |
| tmerge | wasm | walk | 8.366 [8.327–8.465] | 8.547 [8.500–8.633] s; 76.9 [76.7–79.6] MiB | 9.7 [9.4–10.9] | 5.5 [5.5–5.6] | 21.37–27.43 |
| tmerge | wasm-tmerge | walk | 8.395 [8.200–8.478] | 8.564 [8.369–8.650] s; 77.6 [75.7–77.8] MiB | 10.3 [8.0–12.0] | 5.5 [5.4–5.6] | 22.31–26.88 |
| tmerge | wasm | lines | 1.513 [1.270–1.592] | 1.697 [1.449–1.776] s; 92.0 [89.0–92.5] MiB | 10.5 [9.9–12.2] | 5.5 [5.4–5.7] | 22.18–26.01 |
| tmerge | wasm-tmerge | lines | 1.585 [1.331–1.624] | 1.769 [1.513–1.808] s; 91.3 [90.5–92.2] MiB | 11.9 [7.9–14.9] | 5.5 [5.5–5.6] | 22.18–25.29 |
| atr | wasm | tar | 2.990 [2.958–3.013] | 3.314 [3.240–3.317] s; 304.0 [239.2–309.3] MiB | 10.2 [9.5–11.5] | 5.5 [5.5–5.6] | 27.50–28.68 |
| atr | wasm-atr | tar | 3.009 [2.998–3.080] | 3.309 [3.296–3.383] s; 282.6 [280.1–302.6] MiB | 11.2 [9.2–12.8] | 5.6 [5.5–5.7] | 27.55–28.62 |
| atr | wasm | walk | 8.411 [8.231–8.623] | 8.582 [8.405–8.804] s; 76.4 [75.6–77.7] MiB | 11.9 [9.2–12.2] | 5.5 [5.5–5.6] | 27.50–28.53 |
| atr | wasm-atr | walk | 8.367 [8.362–8.438] | 8.539 [8.531–8.610] s; 76.9 [74.9–77.4] MiB | 9.5 [8.3–11.4] | 5.6 [5.5–5.7] | 27.52–28.58 |
| atr | wasm | lines | 1.541 [1.301–1.604] | 1.719 [1.482–1.787] s; 91.1 [89.9–92.4] MiB | 10.2 [9.8–11.6] | 5.7 [5.5–5.7] | 27.43–28.18 |
| atr | wasm-atr | lines | 1.545 [1.307–1.587] | 1.725 [1.486–1.772] s; 92.1 [89.6–92.4] MiB | 11.4 [10.0–12.7] | 5.6 [5.5–5.6] | 27.43–28.18 |
| rut | wasm | tar | 2.950 [2.921–2.975] | 3.243 [3.205–3.277] s; 284.8 [280.6–312.8] MiB | 10.5 [9.8–11.9] | 5.5 [5.4–5.6] | 15.63–27.75 |
| rut | wasm-rut | tar | 2.954 [2.953–2.968] | 3.234 [3.227–3.247] s; 282.1 [253.4–299.6] MiB | 10.3 [8.4–12.2] | 5.5 [5.4–5.5] | 15.63–27.29 |
| rut | wasm | walk | 8.327 [8.228–8.426] | 8.496 [8.399–8.601] s; 76.0 [75.6–77.0] MiB | 11.5 [10.8–12.1] | 5.5 [5.4–5.6] | 13.48–26.48 |
| rut | wasm-rut | walk | 8.355 [8.259–8.441] | 8.522 [8.431–8.615] s; 76.3 [75.9–76.4] MiB | 11.6 [11.0–11.8] | 5.4 [5.4–5.5] | 15.10–25.31 |
| rut | wasm | lines | 1.493 [1.282–1.583] | 1.660 [1.462–1.757] s; 91.5 [89.9–91.9] MiB | 11.5 [9.4–12.0] | 5.4 [5.4–5.5] | 15.65–24.64 |
| rut | wasm-rut | lines | 1.289 [1.270–1.568] | 1.458 [1.436–1.749] s; 91.1 [90.8–92.5] MiB | 11.2 [8.8–13.1] | 5.4 [5.4–5.5] | 15.65–24.03 |
| mono | wasm | tar | 2.970 [2.937–2.982] | 3.242 [3.201–3.266] s; 293.3 [283.3–308.8] MiB | 11.8 [9.7–13.1] | 5.4 [5.3–5.5] | 8.82–14.89 |
| mono | wasm-mono | tar | 2.937 [2.905–2.969] | 3.155 [3.136–3.217] s; 208.8 [204.0–213.9] MiB | 11.8 [8.5–12.8] | 5.4 [5.4–5.6] | 8.67–14.26 |
| mono | wasm | walk | 8.406 [8.223–8.528] | 8.574 [8.389–8.691] s; 77.6 [76.5–78.6] MiB | 11.1 [9.3–12.4] | 5.4 [5.3–5.4] | 8.66–14.26 |
| mono | wasm-mono | walk | 8.323 [8.213–8.488] | 8.486 [8.378–8.651] s; 76.3 [74.3–77.4] MiB | 11.2 [9.8–11.8] | 5.4 [5.4–5.5] | 8.53–13.45 |
| mono | wasm | lines | 1.473 [1.287–1.491] | 1.647 [1.458–1.655] s; 90.6 [89.4–91.2] MiB | 10.0 [9.2–11.6] | 5.4 [5.3–5.6] | 10.56–14.89 |
| mono | wasm-mono | lines | 1.289 [1.259–1.518] | 1.451 [1.432–1.690] s; 91.6 [90.6–92.3] MiB | 10.4 [8.9–11.7] | 5.4 [5.4–5.5] | 10.56–13.65 |
| gccombo | wasm | tar | 3.036 [3.005–3.083] | 3.342 [3.310–3.416] s; 290.7 [265.6–317.9] MiB | 10.9 [9.8–12.8] | 5.6 [5.5–5.7] | 28.28–32.50 |
| gccombo | wasm-gccombo | tar | 3.027 [2.998–3.047] | 3.321 [3.301–3.349] s; 287.8 [280.8–290.5] MiB | 10.5 [9.4–11.7] | 5.5 [5.5–5.5] | 28.34–32.50 |
| gccombo | wasm | walk | 8.350 [8.282–8.482] | 8.530 [8.448–8.657] s; 77.8 [75.6–78.1] MiB | 9.0 [8.7–11.9] | 5.5 [5.5–5.6] | 29.02–32.14 |
| gccombo | wasm-gccombo | walk | 8.417 [8.301–8.582] | 8.597 [8.482–8.755] s; 77.0 [76.1–78.2] MiB | 10.2 [9.4–11.5] | 5.6 [5.5–5.7] | 28.93–32.70 |
| gccombo | wasm | lines | 1.532 [1.319–1.597] | 1.717 [1.498–1.778] s; 93.1 [90.6–93.7] MiB | 9.7 [7.9–11.3] | 5.5 [5.4–5.6] | 29.74–33.15 |
| gccombo | wasm-gccombo | lines | 1.343 [1.312–1.637] | 1.526 [1.492–1.838] s; 91.3 [89.7–92.1] MiB | 10.1 [8.6–11.1] | 5.6 [5.6–5.7] | 29.74–33.15 |
| tnh | wasm | tar | 3.005 [2.985–3.080] | 3.307 [3.282–3.400] s; 285.3 [282.7–312.8] MiB | 9.9 [7.7–11.5] | 5.5 [5.5–5.6] | 21.43–31.57 |
| tnh | wasm-tnh | tar | 2.968 [2.947–3.008] | 3.230 [3.198–3.260] s; 205.1 [199.0–205.4] MiB | 9.5 [8.9–10.9] | 5.5 [5.4–5.5] | 21.88–32.06 |
| tnh | wasm | walk | 8.389 [8.209–8.412] | 8.562 [8.389–8.586] s; 76.9 [75.4–77.4] MiB | 9.8 [8.5–12.9] | 5.5 [5.5–5.6] | 22.51–31.97 |
| tnh | wasm-tnh | walk | 8.375 [8.289–8.514] | 8.550 [8.463–8.687] s; 76.6 [75.8–77.2] MiB | 9.8 [8.7–11.2] | 5.5 [5.4–5.6] | 23.83–31.57 |
| tnh | wasm | lines | 1.541 [1.305–1.588] | 1.718 [1.483–1.771] s; 91.4 [90.5–92.0] MiB | 9.7 [9.4–12.7] | 5.6 [5.5–5.8] | 24.41–31.78 |
| tnh | wasm-tnh | lines | 1.353 [1.338–1.587] | 1.546 [1.514–1.776] s; 90.4 [90.0–90.8] MiB | 11.4 [10.4–12.6] | 5.5 [5.5–5.6] | 25.02–31.80 |
| node-noliftoff | wasm | tar | 3.020 [2.978–3.131] | 3.313 [3.278–3.444] s; 288.4 [279.4–295.1] MiB | 9.5 [9.1–11.5] | 5.5 [5.5–5.6] | 29.05–29.81 |
| node-noliftoff | wasm-node-noliftoff | tar | 3.903 [3.882–3.919] | 4.659 [4.634–4.695] s; 156.4 [153.2–178.8] MiB | 10.2 [8.3–12.1] | 5.9 [5.8–5.9] | 28.96–29.96 |
| node-noliftoff | wasm | walk | 8.337 [8.224–8.502] | 8.507 [8.395–8.689] s; 77.6 [76.6–78.6] MiB | 10.2 [9.4–12.2] | 5.6 [5.5–5.7] | 28.97–29.68 |
| node-noliftoff | wasm-node-noliftoff | walk | 8.522 [8.428–8.625] | 9.269 [9.166–9.365] s; 96.9 [95.7–98.3] MiB | 11.9 [10.8–13.1] | 5.9 [5.8–6.0] | 28.89–29.87 |
| node-noliftoff | wasm | lines | 1.534 [1.323–1.572] | 1.717 [1.498–1.751] s; 91.8 [89.9–93.0] MiB | 10.8 [9.8–12.1] | 5.6 [5.5–5.6] | 29.39–30.13 |
| node-noliftoff | wasm-node-noliftoff | lines | 1.484 [1.449–1.765] | 2.157 [2.116–2.442] s; 96.2 [95.0–96.7] MiB | 11.3 [10.5–13.4] | 5.9 [5.7–6.0] | 29.39–29.96 |
| node-liftoffonly | wasm | tar | 2.997 [2.982–3.025] | 3.299 [3.266–3.338] s; 285.7 [283.2–293.2] MiB | 10.3 [8.4–12.1] | 5.5 [5.4–5.6] | 22.55–29.77 |
| node-liftoffonly | wasm-node-liftoffonly | tar | 9.865 [9.771–9.907] | 10.233 [10.077–10.266] s; 270.4 [241.9–272.0] MiB | 10.8 [9.8–12.8] | 5.6 [5.4–5.7] | 21.87–29.95 |
| node-liftoffonly | wasm | walk | 8.439 [8.356–8.521] | 8.605 [8.525–8.696] s; 78.8 [75.8–79.0] MiB | 10.2 [9.6–11.5] | 5.5 [5.4–5.6] | 19.52–29.81 |
| node-liftoffonly | wasm-node-liftoffonly | walk | 23.165 [23.127–23.390] | 23.392 [23.337–23.615] s; 76.9 [75.7–78.0] MiB | 10.8 [9.5–11.9] | 5.5 [5.3–5.6] | 17.44–29.67 |
| node-liftoffonly | wasm | lines | 1.504 [1.288–1.617] | 1.671 [1.461–1.808] s; 92.4 [92.1–93.3] MiB | 10.1 [9.2–13.3] | 5.5 [5.4–5.6] | 13.92–29.77 |
| node-liftoffonly | wasm-node-liftoffonly | lines | 2.585 [2.435–2.729] | 2.790 [2.642–2.956] s; 69.9 [69.5–71.4] MiB | 11.3 [9.3–13.5] | 5.4 [5.3–5.6] | 13.92–30.01 |
| node-nodyntier | wasm | tar | 3.054 [3.016–3.070] | 3.358 [3.308–3.391] s; 310.7 [280.2–321.9] MiB | 11.2 [9.4–13.7] | 5.5 [5.5–5.8] | 11.58–15.34 |
| node-nodyntier | wasm-node-nodyntier | tar | 3.191 [3.173–3.219] | 3.534 [3.522–3.582] s; 286.9 [266.8–318.8] MiB | 10.4 [10.0–12.3] | 5.5 [5.4–5.6] | 11.93–15.87 |
| node-nodyntier | wasm | walk | 8.302 [8.181–8.484] | 8.480 [8.354–8.664] s; 77.3 [75.4–78.2] MiB | 11.1 [8.6–12.5] | 5.5 [5.5–5.5] | 11.87–15.87 |
| node-nodyntier | wasm-node-nodyntier | walk | 8.502 [8.444–8.586] | 8.730 [8.660–8.808] s; 102.9 [99.4–104.9] MiB | 11.3 [9.2–12.5] | 5.5 [5.4–5.5] | 11.82–16.12 |
| node-nodyntier | wasm | lines | 1.526 [1.249–1.611] | 1.705 [1.421–1.789] s; 91.2 [90.4–92.8] MiB | 12.1 [8.8–12.2] | 5.5 [5.4–5.6] | 11.75–15.34 |
| node-nodyntier | wasm-node-nodyntier | lines | 1.600 [1.344–1.656] | 1.826 [1.573–1.879] s; 99.6 [98.5–100.8] MiB | 9.8 [8.9–11.8] | 5.5 [5.4–5.6] | 12.02–14.93 |
| node-semi32 | wasm | tar | 2.989 [2.947–3.009] | 3.245 [3.216–3.288] s; 292.2 [287.6–310.9] MiB | 9.5 [8.9–11.2] | 5.4 [5.4–5.5] | 6.86–8.70 |
| node-semi32 | wasm-node-semi32 | tar | 2.961 [2.935–3.008] | 3.187 [3.154–3.229] s; 229.8 [228.0–231.2] MiB | 11.6 [9.3–12.1] | 5.4 [5.4–5.4] | 7.18–8.24 |
| node-semi32 | wasm | walk | 8.265 [8.181–8.375] | 8.433 [8.344–8.538] s; 76.9 [75.9–77.9] MiB | 10.9 [9.5–13.4] | 5.4 [5.3–5.4] | 6.93–7.66 |
| node-semi32 | wasm-node-semi32 | walk | 8.294 [8.208–8.367] | 8.459 [8.375–8.531] s; 76.8 [76.2–78.3] MiB | 10.7 [8.1–12.3] | 5.4 [5.3–5.4] | 6.93–7.81 |
| node-semi32 | wasm | lines | 1.492 [1.266–1.540] | 1.654 [1.431–1.710] s; 92.9 [91.2–93.0] MiB | 10.5 [9.2–12.3] | 5.4 [5.4–5.5] | 6.71–7.59 |
| node-semi32 | wasm-node-semi32 | lines | 1.501 [1.273–1.567] | 1.675 [1.440–1.738] s; 91.9 [90.9–93.0] MiB | 11.5 [8.5–12.3] | 5.4 [5.4–5.5] | 6.71–7.59 |
| node-semi64 | wasm | tar | 2.971 [2.963–3.013] | 3.257 [3.221–3.306] s; 285.8 [247.2–307.9] MiB | 11.7 [9.1–12.1] | 5.4 [5.3–5.4] | 6.71–9.85 |
| node-semi64 | wasm-node-semi64 | tar | 2.987 [2.951–3.028] | 3.241 [3.208–3.308] s; 280.8 [244.1–281.9] MiB | 9.5 [7.1–12.9] | 5.4 [5.4–5.5] | 6.73–9.30 |
| node-semi64 | wasm | walk | 8.402 [8.208–8.488] | 8.565 [8.377–8.650] s; 78.1 [76.1–78.5] MiB | 10.6 [9.1–11.0] | 5.4 [5.3–5.4] | 6.97–8.48 |
| node-semi64 | wasm-node-semi64 | walk | 8.309 [8.283–8.464] | 8.481 [8.455–8.633] s; 78.1 [77.0–78.9] MiB | 11.6 [10.8–11.9] | 5.4 [5.3–5.5] | 7.05–8.02 |
| node-semi64 | wasm | lines | 1.496 [1.281–1.506] | 1.665 [1.452–1.680] s; 91.7 [90.0–92.5] MiB | 11.0 [9.7–12.8] | 5.4 [5.3–5.5] | 6.71–7.62 |
| node-semi64 | wasm-node-semi64 | lines | 1.492 [1.477–1.504] | 1.663 [1.649–1.668] s; 91.3 [91.1–94.0] MiB | 10.8 [8.7–13.1] | 5.4 [5.4–5.4] | 6.71–7.62 |
| node-semi128 | wasm | tar | 3.020 [2.968–3.062] | 3.311 [3.234–3.381] s; 283.0 [272.8–286.2] MiB | 11.1 [7.9–11.8] | 5.4 [5.3–5.4] | 7.79–10.71 |
| node-semi128 | wasm-node-semi128 | tar | 3.043 [2.957–3.089] | 3.336 [3.217–3.384] s; 282.5 [278.0–305.2] MiB | 10.1 [8.2–12.9] | 5.4 [5.3–5.4] | 7.79–10.71 |
| node-semi128 | wasm | walk | 8.465 [8.369–8.468] | 8.640 [8.537–8.646] s; 76.5 [76.1–78.2] MiB | 10.9 [9.1–11.8] | 5.4 [5.4–5.5] | 7.72–10.57 |
| node-semi128 | wasm-node-semi128 | walk | 8.434 [8.272–8.482] | 8.614 [8.438–8.646] s; 77.5 [77.1–77.8] MiB | 9.9 [9.4–11.5] | 5.4 [5.3–5.5] | 7.91–10.50 |
| node-semi128 | wasm | lines | 1.487 [1.472–1.509] | 1.664 [1.641–1.683] s; 91.8 [90.8–92.7] MiB | 11.3 [8.8–12.3] | 5.4 [5.4–5.5] | 7.68–10.22 |
| node-semi128 | wasm-node-semi128 | lines | 1.546 [1.249–1.579] | 1.720 [1.418–1.763] s; 90.9 [90.3–91.6] MiB | 9.6 [7.7–12.6] | 5.4 [5.3–5.4] | 7.68–10.76 |
| node-nolazy | wasm | tar | 2.973 [2.959–3.001] | 3.248 [3.229–3.270] s; 290.2 [282.9–306.5] MiB | 10.4 [8.5–10.8] | 5.4 [5.4–5.4] | 4.67–8.33 |
| node-nolazy | wasm-node-nolazy | tar | 2.980 [2.957–3.014] | 3.313 [3.290–3.352] s; 271.9 [270.8–291.2] MiB | 40.1 [38.4–50.8] | 5.3 [5.3–5.4] | 4.54–8.30 |
| node-nolazy | wasm | walk | 8.501 [8.448–8.642] | 8.661 [8.614–8.804] s; 78.9 [75.1–83.2] MiB | 8.7 [7.7–10.8] | 5.3 [5.3–5.4] | 4.54–7.41 |
| node-nolazy | wasm-node-nolazy | walk | 8.665 [8.488–8.814] | 8.895 [8.717–9.040] s; 100.6 [98.1–106.5] MiB | 40.2 [40.1–41.1] | 5.3 [5.3–5.4] | 4.61–6.96 |
| node-nolazy | wasm | lines | 1.476 [1.250–1.546] | 1.645 [1.417–1.712] s; 91.1 [89.7–91.9] MiB | 9.0 [8.3–10.7] | 5.4 [5.3–5.4] | 4.45–6.56 |
| node-nolazy | wasm-node-nolazy | lines | 1.625 [1.476–1.658] | 1.858 [1.710–1.884] s; 102.9 [101.2–119.9] MiB | 41.1 [39.5–49.9] | 5.3 [5.3–5.4] | 4.45–6.36 |


## Wasm phase details

All durations below are milliseconds, independently measured per phase; each cell has five rounds. The unassigned wall remainder includes process startup, runner validation/plumbing, cleanup, exit and launch overhead; this experiment does not attribute it further. Initial compile timing excludes subsequent lazy/background compilation. Raw cumulative and phase marks remain in each command’s timing JSON.


| Source | Pair/label | Case | Command | Implementation | Compile | Instantiate | Init | Main | Unassigned wall remainder | Load1 range |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Table 1 | S-status | S-status | 1 | wasm | 32.2 [30.6–33.9] | 16.4 [16.1–17.1] | 56.6 [55.6–58.7] | 438.1 [429.6–449.6] | 859.1 [823.2–864.8] | 15.43–19.47 |
| Table 1 | S-resolve | S-resolve | 1 | wasm | 31.5 [30.3–38.1] | 17.0 [15.9–18.7] | 56.7 [54.6–59.9] | 627.9 [598.5–633.1] | 729.4 [699.5–760.7] | 17.40–19.51 |
| Table 1 | S-rm | S-rm | 1 | wasm | 32.5 [31.9–36.0] | 16.7 [16.5–17.0] | 59.6 [57.0–61.9] | 507.1 [490.4–513.7] | 897.5 [844.0–993.3] | 16.27–18.56 |
| Table 1 | S-instantiate | S-instantiate | 1 | wasm | 33.5 [30.1–35.7] | 16.3 [15.9–16.5] | 55.6 [52.1–57.0] | 987.9 [978.2–1035.0] | 244.7 [218.2–259.2] | 6.03–16.74 |
| Table 1 | S-instantiate | S-instantiate | 2 | wasm | 31.9 [28.9–33.4] | 16.1 [16.0–18.7] | 54.4 [52.5–56.8] | 405.6 [395.3–413.4] | 625.5 [588.2–647.9] | 5.79–16.52 |
| Table 1 | S-add | S-add | 1 | wasm | 30.9 [30.1–34.3] | 16.0 [15.7–16.2] | 54.4 [53.6–55.9] | 15109.1 [14980.7–15169.1] | 386.3 [382.1–397.7] | 3.61–5.25 |
| Table 1 | S-fail | S-fail | 1 | wasm | 32.4 [30.2–33.8] | 16.3 [15.6–19.2] | 53.4 [50.9–55.2] | 684.9 [667.3–694.9] | 227.2 [212.3–234.7] | 3.07–5.43 |
| Table 1 | S-compressed | S-compressed | 1 | wasm | 32.0 [29.6–33.3] | 15.8 [15.6–16.2] | 53.6 [51.1–53.9] | 1514.6 [1470.5–1535.1] | 861.2 [853.9–896.6] | 2.87–8.51 |
| Table 1 | S-compressed | S-compressed | 2 | wasm | 30.1 [26.2–34.3] | 16.9 [16.2–18.1] | 53.0 [51.0–56.5] | 10784.3 [10721.9–10858.0] | 378.5 [354.3–390.5] | 2.87–8.55 |
| Table 1 | S-compressed | S-compressed | 3 | wasm | 31.6 [27.6–35.9] | 16.1 [15.7–17.2] | 53.2 [52.4–56.5] | 677.2 [652.8–685.5] | 857.1 [846.7–922.4] | 3.11–7.99 |
| Table 1 | S-compressed | S-compressed | 4 | wasm | 31.6 [30.1–33.2] | 16.5 [15.8–20.5] | 54.7 [51.7–56.6] | 10942.9 [10854.3–11007.1] | 369.0 [351.6–387.7] | 3.11–7.99 |
| Table 1 | S-registry | S-registry | 1 | wasm | 32.8 [30.0–35.8] | 16.9 [16.4–17.5] | 58.9 [58.4–59.9] | 3481.6 [3416.6–3525.8] | 304.6 [299.9–307.9] | 15.55–27.47 |
| Table 1 | S-registry | S-registry | 2 | wasm | 31.6 [31.0–32.8] | 16.8 [16.6–17.1] | 60.0 [58.8–72.8] | 1533.3 [1520.9–1553.3] | 227.8 [226.1–235.4] | 15.55–27.35 |
| Table 1 | S-registry | S-registry | 3 | wasm | 32.6 [32.2–34.3] | 16.9 [16.5–17.2] | 59.1 [58.6–60.7] | 589.1 [574.7–594.4] | 223.8 [216.6–229.3] | 16.39–27.24 |
| Table 1 | S-registry | S-registry | 4 | wasm | 30.0 [28.5–39.4] | 16.9 [16.4–18.2] | 57.9 [56.9–59.8] | 168.0 [167.3–174.4] | 147.2 [142.2–148.2] | 16.39–27.24 |
| Table 1 | S-registry | S-registry | 5 | wasm | 31.3 [30.1–35.1] | 16.7 [16.3–17.3] | 58.4 [57.0–60.0] | 534.3 [524.6–546.9] | 219.3 [212.4–229.3] | 17.24–27.24 |
| Table 1 | S-registry | S-registry | 6 | wasm | 31.4 [30.0–33.7] | 16.8 [16.6–17.4] | 59.5 [58.1–61.2] | 80.3 [74.2–81.7] | 148.0 [137.3–150.9] | 17.24–27.24 |
| Table 1 | S-registry-compressed | S-registry-compressed | 1 | wasm | 30.0 [27.7–33.2] | 16.3 [16.2–17.4] | 55.6 [52.8–60.0] | 1494.4 [1488.5–1543.1] | 219.8 [197.7–262.9] | 17.81–31.71 |
| Table 1 | S-registry-compressed | S-registry-compressed | 2 | wasm | 33.9 [28.9–35.7] | 16.6 [15.9–16.8] | 55.8 [53.1–60.7] | 573.3 [566.8–593.5] | 212.0 [194.6–237.7] | 17.81–31.71 |
| Table 1 | S-registry-compressed | S-registry-compressed | 3 | wasm | 31.1 [28.4–38.9] | 16.8 [15.9–17.5] | 56.1 [53.0–61.0] | 530.3 [511.9–550.2] | 209.1 [195.3–224.6] | 17.81–31.71 |
| Table 1 | S-git | S-git | 1 | wasm | 33.8 [29.5–39.2] | 16.8 [16.0–17.0] | 57.0 [52.5–60.9] | 296.5 [289.2–308.0] | 156.5 [141.4–160.8] | 6.66–27.49 |
| Table 1 | S-git | S-git | 2 | wasm | 31.6 [29.6–35.8] | 16.8 [15.7–17.0] | 56.4 [52.6–59.5] | 813.4 [769.4–828.6] | 870.3 [846.1–892.8] | 6.45–27.49 |
| Table 1 | S-git | S-git | 3 | wasm | 32.9 [31.3–35.2] | 16.7 [15.9–17.5] | 59.1 [52.4–61.5] | 795.2 [745.6–848.5] | 830.0 [811.0–897.3] | 6.45–27.45 |
| Table 1 | S-git | S-git | 4 | wasm | 30.5 [29.9–34.4] | 16.8 [15.9–17.3] | 55.5 [53.1–58.1] | 701.4 [689.7–744.9] | 812.2 [806.9–928.1] | 6.45–27.45 |
| Table 1 | S-git | S-git | 5 | wasm | 32.3 [30.5–33.2] | 17.1 [16.3–17.8] | 57.1 [53.3–60.2] | 717.3 [692.5–778.8] | 822.8 [819.1–873.1] | 6.25–27.45 |
| Table 1 | S-git | S-git | 6 | wasm | 30.1 [27.4–31.6] | 16.2 [15.9–17.6] | 57.8 [54.3–60.6] | 633.5 [614.6–653.3] | 779.6 [767.1–850.9] | 6.25–27.33 |
| Table 1 | S-git | S-git | 7 | wasm | 30.2 [27.3–35.5] | 16.6 [15.6–17.0] | 56.8 [52.6–58.2] | 307.2 [301.7–339.5] | 144.4 [139.1–162.0] | 6.25–27.33 |
| Table 1 | S-git | S-git | 8 | wasm | 31.7 [29.5–35.4] | 16.2 [15.9–16.7] | 56.6 [52.3–60.1] | 262.2 [250.3–270.7] | 150.9 [142.2–156.8] | 6.25–27.33 |
| Table 1 | S-artifacts | S-artifacts | 1 | wasm | 31.1 [27.7–32.6] | 16.3 [16.1–16.3] | 56.6 [55.3–59.4] | 1080.0 [1032.1–1116.3] | 421.7 [391.2–441.9] | 17.76–27.74 |
| Table 1 | S-artifacts | S-artifacts | 2 | wasm | 30.9 [27.4–33.6] | 16.6 [16.3–17.1] | 58.5 [54.7–60.2] | 408.6 [386.9–421.2] | 858.5 [844.7–878.8] | 18.34–27.81 |
| Table 1 | S-artifacts | S-artifacts | 3 | wasm | 32.6 [29.0–33.7] | 16.6 [16.0–17.2] | 55.5 [54.8–60.2] | 601.9 [584.0–616.1] | 624.5 [592.3–692.6] | 18.34–27.67 |
| Table 1 | S-artifacts | S-artifacts | 4 | wasm | 33.3 [30.9–39.2] | 16.2 [15.9–16.8] | 57.2 [56.2–61.0] | 445.1 [434.7–462.8] | 847.9 [817.5–860.2] | 19.35–27.70 |
| Table 1 | S-gc | S-gc | 1 | wasm | 31.5 [30.6–32.9] | 16.8 [16.0–20.3] | 58.1 [53.6–60.1] | 11542.7 [11438.2–11646.7] | 439.0 [422.7–445.3] | 23.29–26.81 |
| Table 1 | S-gc | S-gc | 2 | wasm | 30.1 [26.6–35.5] | 16.5 [16.2–17.2] | 56.6 [55.9–58.0] | 517.5 [485.3–539.4] | 479.4 [439.2–530.1] | 23.97–27.27 |
| Table 1 | S-gc | S-gc | 3 | wasm | 33.3 [29.5–36.2] | 16.7 [16.4–17.0] | 56.5 [54.4–65.1] | 294.6 [284.9–302.0] | 145.4 [139.0–155.0] | 23.97–27.09 |
| Table 1 | S-gc | S-gc | 4 | wasm | 32.9 [30.4–33.8] | 17.0 [16.1–18.8] | 57.1 [53.6–58.3] | 194.1 [189.0–194.7] | 147.2 [144.2–156.0] | 24.21–27.09 |
| Table 1 | S-gc | S-gc | 5 | wasm | 30.5 [28.5–32.9] | 16.0 [15.8–16.4] | 55.9 [53.9–58.7] | 425.8 [416.9–431.5] | 844.1 [828.1–865.8] | 24.21–27.09 |
| Table 1 | S-gc-auto | S-gc-auto | 1 | wasm | 30.9 [29.2–34.7] | 16.9 [16.1–17.8] | 57.4 [55.1–62.3] | 1133.8 [1086.7–1146.3] | 407.1 [345.6–461.8] | 21.99–26.47 |
| Table 1 | S-gc-auto | S-gc-auto | 2 | wasm | 29.8 [28.3–32.3] | 16.8 [16.0–17.5] | 56.7 [53.9–61.1] | 591.5 [569.8–600.0] | 828.3 [777.4–849.1] | 22.63–26.83 |
| Table 1 | S-gc-auto | S-gc-auto | 3 | wasm | 30.2 [29.7–33.1] | 16.3 [16.2–17.1] | 57.1 [55.9–59.0] | 435.3 [414.3–442.5] | 855.7 [834.3–865.3] | 22.82–26.76 |
| Table 1 | M4 | M4-cold | 1 | wasm | 33.3 [29.1–33.5] | 16.8 [16.2–17.8] | 56.7 [53.6–57.7] | 3050.6 [2967.3–3115.0] | 255.5 [222.9–285.8] | 26.85–28.31 |
| Table 1 | M4 | M4-warm | 1 | wasm | 33.4 [29.0–38.7] | 16.5 [16.2–16.9] | 57.2 [52.7–59.0] | 2156.3 [2123.7–2167.9] | 238.5 [236.3–260.8] | 16.91–29.65 |
| Table 1 | M4 | M4-noop | 1 | wasm | 32.2 [29.1–35.4] | 16.7 [16.4–17.7] | 57.3 [55.2–62.2] | 615.0 [606.9–619.0] | 449.5 [426.1–464.4] | 22.86–31.65 |
| Flag sweep | O3conv | M4-cold | 1 | wasm | 33.4 [29.2–33.8] | 17.2 [16.6–20.9] | 59.8 [54.7–78.5] | 3111.0 [3107.8–3217.3] | 279.1 [251.6–364.8] | 26.22–35.07 |
| Flag sweep | O3conv | M4-cold | 1 | wasm-O3conv | 30.3 [28.1–30.9] | 17.1 [16.8–17.5] | 61.0 [59.6–63.7] | 3174.5 [3074.5–3202.3] | 269.5 [261.3–283.0] | 29.30–35.70 |
| Flag sweep | O3conv | M4-warm | 1 | wasm | 32.1 [29.2–33.1] | 16.9 [16.4–17.5] | 60.2 [56.8–63.2] | 2180.9 [2120.1–2220.4] | 253.6 [243.8–260.5] | 28.39–35.97 |
| Flag sweep | O3conv | M4-warm | 1 | wasm-O3conv | 31.8 [27.3–34.1] | 17.1 [16.6–17.4] | 62.4 [60.0–64.7] | 2178.9 [2152.9–2226.6] | 263.2 [249.0–266.3] | 27.80–34.69 |
| Flag sweep | O3x2 | M4-cold | 1 | wasm | 32.0 [28.7–36.8] | 17.3 [16.6–18.2] | 61.4 [58.2–64.3] | 3153.8 [3114.2–3244.8] | 264.5 [252.9–290.7] | 36.16–37.66 |
| Flag sweep | O3x2 | M4-cold | 1 | wasm-O3x2 | 32.7 [28.4–35.1] | 17.2 [17.1–17.5] | 61.1 [58.9–63.1] | 3179.0 [3156.9–3239.4] | 267.3 [258.2–286.7] | 36.33–37.72 |
| Flag sweep | O3x2 | M4-warm | 1 | wasm | 32.3 [29.0–33.6] | 17.1 [16.8–23.6] | 60.3 [55.7–81.4] | 2205.9 [2171.7–2337.5] | 262.2 [248.7–272.2] | 37.19–37.52 |
| Flag sweep | O3x2 | M4-warm | 1 | wasm-O3x2 | 33.8 [28.7–35.2] | 17.4 [16.6–17.7] | 62.6 [59.5–67.0] | 2187.3 [2148.2–2221.8] | 255.8 [252.1–271.6] | 37.06–37.96 |
| Flag sweep | Os | M4-cold | 1 | wasm | 29.7 [28.2–33.4] | 17.2 [16.5–17.7] | 57.7 [56.6–61.3] | 3139.1 [3119.5–3206.6] | 258.9 [249.3–289.8] | 24.40–29.54 |
| Flag sweep | Os | M4-cold | 1 | wasm-Os | 33.5 [30.5–34.4] | 16.9 [16.2–17.0] | 58.1 [55.8–60.7] | 3189.6 [3122.1–3200.9] | 251.0 [238.8–268.9] | 24.61–28.60 |
| Flag sweep | Os | M4-warm | 1 | wasm | 32.8 [30.8–33.1] | 16.5 [16.3–17.1] | 58.5 [54.4–62.6] | 2112.6 [2102.8–2230.3] | 241.7 [225.5–260.0] | 25.14–28.47 |
| Flag sweep | Os | M4-warm | 1 | wasm-Os | 32.3 [30.7–33.5] | 16.5 [16.4–16.8] | 55.6 [51.7–59.2] | 2210.2 [2180.6–2270.6] | 235.0 [210.6–256.4] | 25.53–28.16 |
| Flag sweep | gufaopt | M4-cold | 1 | wasm | 32.2 [28.7–34.5] | 17.0 [16.6–18.0] | 59.2 [58.5–66.9] | 3106.6 [3054.4–3196.9] | 253.8 [234.1–277.6] | 31.48–36.72 |
| Flag sweep | gufaopt | M4-cold | 1 | wasm-gufaopt | 32.0 [29.0–33.1] | 17.1 [16.7–17.7] | 58.7 [55.1–59.7] | 3090.7 [3050.9–3203.0] | 246.5 [237.6–249.5] | 31.52–35.93 |
| Flag sweep | gufaopt | M4-warm | 1 | wasm | 30.5 [29.5–34.3] | 16.9 [16.3–17.2] | 58.0 [56.0–59.6] | 2143.7 [2124.7–2262.9] | 241.1 [227.9–247.3] | 31.13–35.54 |
| Flag sweep | gufaopt | M4-warm | 1 | wasm-gufaopt | 30.5 [29.7–35.6] | 17.0 [16.5–17.7] | 60.5 [59.0–63.0] | 2208.4 [2115.7–2236.1] | 254.7 [238.4–271.8] | 31.32–35.65 |
| Flag sweep | tmerge | M4-cold | 1 | wasm | 30.7 [28.7–33.1] | 16.7 [16.2–17.2] | 56.1 [55.3–60.3] | 3083.7 [2988.9–3169.8] | 258.1 [236.5–283.9] | 24.70–31.31 |
| Flag sweep | tmerge | M4-cold | 1 | wasm-tmerge | 31.5 [28.7–32.7] | 16.4 [15.9–17.0] | 57.6 [55.7–58.6] | 3074.9 [2955.3–3193.9] | 255.6 [230.9–263.6] | 23.69–31.16 |
| Flag sweep | tmerge | M4-warm | 1 | wasm | 31.2 [26.9–35.0] | 16.7 [16.2–17.6] | 55.4 [53.4–60.7] | 2118.1 [2073.6–2145.3] | 246.5 [219.6–266.6] | 20.58–31.16 |
| Flag sweep | tmerge | M4-warm | 1 | wasm-tmerge | 31.7 [30.8–33.2] | 16.8 [16.6–17.1] | 55.8 [55.6–60.6] | 2139.4 [2079.9–2173.8] | 238.1 [228.9–247.7] | 19.33–31.08 |
| Flag sweep | atr | M4-cold | 1 | wasm | 32.4 [31.2–34.3] | 16.8 [16.4–17.4] | 60.2 [56.9–82.6] | 3101.2 [3080.0–3189.5] | 251.3 [237.4–289.5] | 29.12–30.32 |
| Flag sweep | atr | M4-cold | 1 | wasm-atr | 31.5 [29.1–33.9] | 17.0 [16.4–20.9] | 57.8 [57.4–61.6] | 3101.4 [3035.2–3226.3] | 256.3 [238.7–261.5] | 29.32–29.85 |
| Flag sweep | atr | M4-warm | 1 | wasm | 30.6 [28.9–33.1] | 16.5 [16.1–17.7] | 56.9 [56.1–60.3] | 2140.5 [2111.3–2231.6] | 246.2 [234.4–249.3] | 28.98–30.18 |
| Flag sweep | atr | M4-warm | 1 | wasm-atr | 32.5 [27.5–39.1] | 16.5 [16.3–16.8] | 57.1 [55.2–60.3] | 2136.0 [2117.3–2176.1] | 234.3 [225.1–253.2] | 29.06–30.01 |
| Flag sweep | rut | M4-cold | 1 | wasm | 30.4 [28.7–33.4] | 16.9 [16.4–17.2] | 56.5 [55.9–58.7] | 3088.4 [3000.8–3167.9] | 254.1 [226.9–280.9] | 26.68–27.42 |
| Flag sweep | rut | M4-cold | 1 | wasm-rut | 31.7 [30.0–32.3] | 16.7 [16.4–17.8] | 57.0 [56.4–60.4] | 3071.3 [3057.1–3123.1] | 246.0 [238.7–259.5] | 26.64–27.15 |
| Flag sweep | rut | M4-warm | 1 | wasm | 32.4 [28.3–36.2] | 16.8 [16.6–20.6] | 56.5 [54.9–58.9] | 2116.8 [2102.1–2156.2] | 244.7 [225.6–253.0] | 26.74–27.87 |
| Flag sweep | rut | M4-warm | 1 | wasm-rut | 32.3 [30.7–35.3] | 16.7 [16.6–17.2] | 57.6 [55.5–60.3] | 2126.6 [2113.0–2134.8] | 235.8 [229.4–244.3] | 26.80–27.64 |
| Flag sweep | mono | M4-cold | 1 | wasm | 32.0 [31.2–32.7] | 16.2 [16.0–17.0] | 51.5 [50.3–62.1] | 2967.9 [2956.0–3060.2] | 222.8 [215.0–246.2] | 6.77–10.95 |
| Flag sweep | mono | M4-cold | 1 | wasm-mono | 31.3 [29.8–32.5] | 16.3 [16.1–16.9] | 52.5 [50.2–54.2] | 2967.4 [2960.3–3004.9] | 218.9 [207.0–230.2] | 7.20–9.92 |
| Flag sweep | mono | M4-warm | 1 | wasm | 31.6 [30.6–36.2] | 16.4 [15.9–16.9] | 53.3 [51.0–54.2] | 2048.6 [2037.4–2059.9] | 217.7 [209.3–218.8] | 7.16–9.53 |
| Flag sweep | mono | M4-warm | 1 | wasm-mono | 32.5 [30.8–33.7] | 16.3 [16.0–16.4] | 53.1 [51.1–54.7] | 2074.2 [2030.4–2144.6] | 223.9 [212.7–228.1] | 7.39–9.21 |
| Flag sweep | gccombo | M4-cold | 1 | wasm | 30.2 [27.1–33.2] | 16.8 [16.2–17.6] | 56.1 [54.3–58.9] | 3085.7 [3021.2–3139.2] | 255.3 [231.5–264.8] | 9.65–21.02 |
| Flag sweep | gccombo | M4-cold | 1 | wasm-gccombo | 31.8 [30.9–34.1] | 16.8 [16.3–17.2] | 58.1 [54.2–60.4] | 3187.0 [3075.4–3207.7] | 240.0 [230.5–261.5] | 10.18–22.22 |
| Flag sweep | gccombo | M4-warm | 1 | wasm | 31.2 [28.3–32.6] | 16.4 [16.1–18.3] | 55.8 [54.3–59.4] | 2122.4 [2102.8–2176.7] | 236.6 [219.7–272.5] | 9.80–23.36 |
| Flag sweep | gccombo | M4-warm | 1 | wasm-gccombo | 32.5 [30.0–34.5] | 16.5 [15.8–16.9] | 54.2 [52.7–59.5] | 2160.7 [2099.9–2181.5] | 240.5 [223.1–258.0] | 9.61–23.97 |
| Flag sweep | tnh | M4-cold | 1 | wasm | 31.9 [27.9–33.4] | 16.7 [15.9–17.7] | 56.5 [51.5–61.9] | 3038.7 [2967.4–3156.4] | 243.7 [223.0–282.6] | 18.44–30.05 |
| Flag sweep | tnh | M4-cold | 1 | wasm-tnh | 31.3 [28.7–32.8] | 16.7 [16.1–18.5] | 49.9 [45.1–52.8] | 3069.3 [2993.8–3175.4] | 247.5 [212.4–263.0] | 17.44–29.84 |
| Flag sweep | tnh | M4-warm | 1 | wasm | 32.5 [28.7–33.8] | 16.7 [16.1–17.7] | 57.2 [52.2–61.8] | 2134.2 [2044.8–2176.3] | 240.8 [220.5–251.4] | 17.45–30.02 |
| Flag sweep | tnh | M4-warm | 1 | wasm-tnh | 31.8 [29.7–36.0] | 15.8 [15.4–17.5] | 47.8 [43.5–49.1] | 2120.0 [2041.9–2280.7] | 237.7 [217.5–249.0] | 18.14–30.00 |
| Flag sweep | node-noliftoff | M4-cold | 1 | wasm | 34.3 [28.7–39.5] | 16.7 [16.5–18.1] | 57.7 [56.1–61.1] | 3112.0 [3044.9–3153.7] | 256.9 [240.3–277.1] | 19.67–27.90 |
| Flag sweep | node-noliftoff | M4-cold | 1 | wasm-node-noliftoff | 33.3 [30.8–34.6] | 17.6 [16.8–17.9] | 603.4 [565.1–610.7] | 10226.8 [9977.5–10297.2] | 288.3 [280.9–310.9] | 18.63–28.15 |
| Flag sweep | node-noliftoff | M4-warm | 1 | wasm | 31.4 [29.1–34.6] | 16.6 [16.4–20.7] | 56.4 [55.4–58.1] | 2144.7 [2099.4–2197.9] | 235.9 [218.9–252.5] | 21.72–30.37 |
| Flag sweep | node-noliftoff | M4-warm | 1 | wasm-node-noliftoff | 32.1 [28.5–38.7] | 17.3 [17.0–17.8] | 602.7 [572.4–627.0] | 9109.3 [8674.1–9184.2] | 297.3 [276.7–330.3] | 20.50–30.18 |
| Flag sweep | node-liftoffonly | M4-cold | 1 | wasm | 30.7 [28.1–32.9] | 16.7 [16.2–16.9] | 58.7 [53.3–63.2] | 3085.9 [3034.5–3272.6] | 270.4 [214.3–277.8] | 21.79–29.90 |
| Flag sweep | node-liftoffonly | M4-cold | 1 | wasm-node-liftoffonly | 29.6 [27.2–33.5] | 16.5 [15.9–17.7] | 42.4 [40.0–45.3] | 17782.0 [17707.7–17912.1] | 288.1 [270.4–316.7] | 22.52–31.13 |
| Flag sweep | node-liftoffonly | M4-warm | 1 | wasm | 30.9 [28.1–37.7] | 16.9 [16.4–17.3] | 58.5 [56.1–62.6] | 2161.5 [2123.1–2241.6] | 251.7 [238.1–273.7] | 21.07–30.15 |
| Flag sweep | node-liftoffonly | M4-warm | 1 | wasm-node-liftoffonly | 31.9 [29.5–33.1] | 16.9 [16.3–17.2] | 45.3 [39.0–45.7] | 13270.9 [13255.4–13498.2] | 285.8 [276.1–295.5] | 21.62–29.98 |
| Flag sweep | node-nodyntier | M4-cold | 1 | wasm | 31.7 [29.2–31.9] | 16.4 [15.9–19.2] | 53.4 [50.5–55.4] | 3017.8 [2995.3–3019.9] | 233.0 [217.4–252.2] | 5.74–7.64 |
| Flag sweep | node-nodyntier | M4-cold | 1 | wasm-node-nodyntier | 31.8 [31.1–34.6] | 16.3 [16.0–17.2] | 40.1 [39.3–52.5] | 3467.4 [3442.7–3602.7] | 277.5 [258.5–321.5] | 5.92–7.51 |
| Flag sweep | node-nodyntier | M4-warm | 1 | wasm | 32.8 [30.4–151.8] | 16.6 [16.3–141.3] | 55.2 [53.2–349.8] | 2078.3 [2050.8–4436.6] | 224.3 [212.5–675.9] | 5.83–9.14 |
| Flag sweep | node-nodyntier | M4-warm | 1 | wasm-node-nodyntier | 32.3 [30.0–33.7] | 16.4 [16.0–17.0] | 41.3 [39.2–46.8] | 2362.8 [2292.2–2415.5] | 296.8 [281.9–327.5] | 6.09–10.09 |
| Flag sweep | node-semi32 | M4-cold | 1 | wasm | 31.6 [30.9–40.5] | 16.8 [16.1–21.3] | 57.9 [54.0–58.7] | 3091.1 [3044.9–3141.9] | 238.0 [224.8–294.0] | 11.08–18.36 |
| Flag sweep | node-semi32 | M4-cold | 1 | wasm-node-semi32 | 34.1 [27.1–35.8] | 16.4 [16.3–16.6] | 55.1 [53.8–58.2] | 3074.2 [3042.9–3090.5] | 234.3 [231.7–244.9] | 10.21–16.03 |
| Flag sweep | node-semi32 | M4-warm | 1 | wasm | 31.7 [30.9–35.7] | 16.6 [16.0–17.4] | 54.6 [53.6–57.9] | 2109.7 [2102.4–2151.9] | 225.0 [215.8–232.0] | 9.71–15.22 |
| Flag sweep | node-semi32 | M4-warm | 1 | wasm-node-semi32 | 32.0 [31.1–33.3] | 16.2 [16.1–28.0] | 55.1 [52.4–57.1] | 2142.4 [2091.9–2147.7] | 231.9 [216.8–246.4] | 9.42–14.40 |
| Flag sweep | node-semi64 | M4-cold | 1 | wasm | 30.7 [28.8–33.5] | 16.5 [16.2–16.8] | 55.3 [54.1–59.7] | 3102.7 [3058.1–3112.1] | 253.3 [241.5–265.0] | 8.58–12.23 |
| Flag sweep | node-semi64 | M4-cold | 1 | wasm-node-semi64 | 31.7 [28.9–32.9] | 16.2 [16.0–17.1] | 55.5 [53.7–57.8] | 3044.6 [3033.4–3257.9] | 230.0 [219.5–244.2] | 8.45–11.57 |
| Flag sweep | node-semi64 | M4-warm | 1 | wasm | 31.5 [30.2–32.5] | 16.8 [16.5–20.7] | 54.8 [53.7–58.9] | 2126.4 [2072.0–2145.5] | 229.0 [214.7–250.3] | 8.82–12.86 |
| Flag sweep | node-semi64 | M4-warm | 1 | wasm-node-semi64 | 32.3 [30.5–32.8] | 16.8 [16.7–20.6] | 57.4 [55.9–60.8] | 2123.4 [2094.7–2191.1] | 222.9 [217.4–261.8] | 8.61–11.10 |
| Flag sweep | node-semi128 | M4-cold | 1 | wasm | 30.9 [29.4–33.2] | 16.3 [16.0–16.9] | 56.4 [52.2–56.5] | 3058.4 [3018.6–3134.1] | 241.0 [236.0–257.7] | 7.31–8.78 |
| Flag sweep | node-semi128 | M4-cold | 1 | wasm-node-semi128 | 31.5 [29.5–39.6] | 16.4 [16.1–16.7] | 55.2 [53.3–55.9] | 3075.3 [3005.0–3129.9] | 236.5 [232.1–262.3] | 7.42–8.13 |
| Flag sweep | node-semi128 | M4-warm | 1 | wasm | 32.6 [29.4–36.2] | 16.3 [16.1–16.7] | 56.1 [55.4–56.5] | 2138.1 [2066.7–2478.5] | 233.8 [231.4–248.7] | 7.34–8.96 |
| Flag sweep | node-semi128 | M4-warm | 1 | wasm-node-semi128 | 31.7 [29.8–32.8] | 16.4 [15.9–16.8] | 55.8 [53.7–59.7] | 2140.0 [2089.9–2165.3] | 232.3 [218.5–245.4] | 7.37–9.12 |
| Flag sweep | node-nolazy | M4-cold | 1 | wasm | 33.0 [30.9–33.7] | 16.0 [15.9–16.3] | 52.7 [51.0–53.4] | 2974.6 [2919.8–3017.7] | 224.7 [217.0–247.3] | 8.78–10.82 |
| Flag sweep | node-nolazy | M4-cold | 1 | wasm-node-nolazy | 274.5 [273.1–286.1] | 16.2 [16.0–20.2] | 1.9 [1.9–2.1] | 2822.4 [2771.2–2921.1] | 301.4 [289.8–308.6] | 9.11–10.80 |
| Flag sweep | node-nolazy | M4-warm | 1 | wasm | 32.5 [30.2–33.2] | 16.1 [15.6–16.6] | 52.2 [50.4–54.2] | 2076.0 [2060.1–2094.7] | 214.9 [208.3–224.3] | 8.68–9.82 |
| Flag sweep | node-nolazy | M4-warm | 1 | wasm-node-nolazy | 274.3 [270.2–282.1] | 16.4 [16.3–16.6] | 1.9 [1.9–1.9] | 1896.6 [1867.0–1974.0] | 290.6 [281.2–308.3] | 8.48–9.41 |


## IO subphases

| Workload | Implementation | Phase | Seconds | Load1 range |
| --- | --- | --- | --- | --- |
| read | native | ns_read | 0.481 [0.475–0.526] | 15.79–25.92 |
| read | native | ns_readbang | 0.421 [0.417–0.423] | 15.79–25.92 |
| read | native-warm | ns_read | 0.479 [0.477–0.485] | 15.79–25.85 |
| read | native-warm | ns_readbang | 0.421 [0.418–0.421] | 15.79–25.85 |
| read | wasm | ns_read | 1.575 [1.568–1.581] | 16.29–25.92 |
| read | wasm | ns_readbang | 2.383 [2.379–2.404] | 16.29–25.92 |
| cp | native | ns_cp | 0.068 [0.063–0.281] | 15.32–25.86 |
| cp | native-warm | ns_cp | 0.064 [0.062–0.068] | 14.98–26.11 |
| cp | wasm | ns_cp | 0.570 [0.557–0.578] | 15.32–26.11 |
| dir | native | ns_create | 0.302 [0.296–0.372] | 13.28–26.11 |
| dir | native | ns_readdir | 0.007 [0.007–0.007] | 13.28–26.11 |
| dir | native | ns_rm | 0.142 [0.139–0.153] | 13.28–26.11 |
| dir | native-warm | ns_create | 0.295 [0.283–0.378] | 13.28–26.10 |
| dir | native-warm | ns_readdir | 0.007 [0.007–0.007] | 13.28–26.10 |
| dir | native-warm | ns_rm | 0.140 [0.138–0.144] | 13.28–26.10 |
| dir | wasm | ns_create | 0.501 [0.479–0.566] | 13.28–26.11 |
| dir | wasm | ns_readdir | 0.032 [0.031–0.032] | 13.28–26.11 |
| dir | wasm | ns_rm | 1.237 [1.212–1.270] | 13.28–26.11 |
