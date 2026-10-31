# PkgWasm e2e fixtures (owner: L5 e2e)

- `frozen.toml` — frozen General registry (UUID + tree hash), server, platform, env policy.
- `scenarios.toml` — S-status, S-resolve, S-rm, S-instantiate, S-add, S-fail.
- `instantiate/` — committed Project/Manifest for S-instantiate.
- `baseline/<S>/` — native stock Pkg 1.13.2 results: `project/`, `out/<i>.{exit,stdout,stderr,error}`, `server.log`, `summary.toml`.
- `initial/` (not versioned) — initial-state templates, rebuilt by `runner/scenarios.jl prepare`.
- `cache/` (not versioned) — immutable Pkg-server payloads cached by `runner/pkgserver.mjs`.

Usage (from /home/pgeorgakopoulos/wasm-pkg, after `. env/env.sh <lane>`):

    $JULIA runner/scenarios.jl prepare                       # once; builds fixtures/initial
    $JULIA runner/scenarios.jl run --impl pkgwasm-native --pkgwasm <PkgWasm checkout> --out <dir> [S-...]
    $JULIA runner/compare.jl compare fixtures/baseline/S-add <rundir> --scenario S-add --bytes

`run` copies the initial state, starts the frozen server, runs each command in a fresh
process (`runner/native_pkg.jl`, the native twin of `pkgwasm_main`), and compares against
the baseline. Exit 0 iff all scenarios are equivalent.
