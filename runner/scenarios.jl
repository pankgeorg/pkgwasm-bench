# Scenario orchestrator (PLAN.md M5.1/M5.3). Owner: L5 e2e. Native Julia 1.13.2.
#
#   julia runner/scenarios.jl prepare [--force]
#       Build the initial-state templates fixtures/initial/{empty,registry,two} with stock
#       Pkg through the frozen server (fills fixtures/cache).
#   julia runner/scenarios.jl baseline [S...]
#       Run scenarios with stock Pkg 1.13.2 and store fixtures/baseline/<S>/
#       (project/, out/, server.log, summary.toml).
#   julia runner/scenarios.jl relocation --wasm FILE --out DIR [S...]
#       D8 relocation test on a build.jl module (sentinel decoys preopened; see relocation()).
#   julia runner/scenarios.jl run --impl pkg|pkgwasm-native|wasm --out DIR [opts] [S...]
#       Run scenarios into DIR/<S>/ and compare each against fixtures/baseline/<S>.
#       opts: --pkgwasm PATH   PkgWasm checkout for pkgwasm-native (default src/PkgWasm.jl)
#             --wasm FILE      module for wasm (default out/pkgwasm.wasm)
#             --offline        frozen server serves only fixtures/cache
#             --platform-from-frozen  wasm: host platform tags from fixtures/frozen.toml (D13)
#             --keep           keep run dirs of passing scenarios (default: kept anyway)
#
# With no scenario names, all scenarios in fixtures/scenarios.toml run, in file order.
# Each command runs in a fresh process (native) or a fresh Wasm instance (one command per
# instance, ABI §6). Exit status is 0 iff every scenario is equivalent to its baseline.

import TOML, Dates
include(joinpath(@__DIR__, "compare.jl"))
include(joinpath(@__DIR__, "imagescan.jl"))

const ROOT = normpath(joinpath(@__DIR__, ".."))
const FIX = realpath(joinpath(ROOT, "fixtures"))   # (a real path: outputs name the run dir one way only)
const FROZEN = TOML.parsefile(joinpath(FIX, "frozen.toml"))
const SCEN_FILE = joinpath(FIX, "scenarios.toml")
scenario_names() = [String(m.captures[1]) for m in eachmatch(r"^\[(S-[A-Za-z-]+)\]"m, read(SCEN_FILE, String))]
const SCENARIOS = TOML.parsefile(SCEN_FILE)
const JULIA_EXE = joinpath(Sys.BINDIR, Base.julia_exename())
const NODE = get(ENV, "NODE", joinpath(homedir(), "wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node"))

# ---------------------------------------------------------------- frozen server
struct Server
    proc::Base.Process
    url::String
end
function start_server(log::AbstractString; offline::Bool = false)
    args = [NODE, joinpath(@__DIR__, "pkgserver.mjs"), "--log", log]
    offline && push!(args, "--offline")
    out = Pipe()
    proc = run(pipeline(Cmd(args); stdout = out, stderr = stderr); wait = false)
    close(out.in)
    t = @async readline(out)
    if timedwait(() -> istaskdone(t), 30.0) !== :ok
        kill(proc, Base.SIGKILL)
        error("frozen server printed no LISTENING line within 30 s")
    end
    line = fetch(t)
    m = match(r"^LISTENING (http://127\.0\.0\.1:\d+)$", line)
    m === nothing && (kill(proc, Base.SIGKILL); error("frozen server failed to start: $(repr(line))"))
    return Server(proc, m.captures[1])
end
# SIGTERM (the server aborts fills and exits within 2 s), then SIGKILL after 10 s; always reaped.
function stop_server(s::Server)
    process_running(s.proc) && kill(s.proc)
    if timedwait(() -> !process_running(s.proc), 10.0) !== :ok
        kill(s.proc, Base.SIGKILL)
    end
    wait(s.proc)
    return nothing
end

# ---------------------------------------------------------------- environments
# The env policy (frozen.toml [env]) plus per-run paths. Nothing else is inherited except
# PATH, so the caller's JULIA_* settings cannot leak into baselines.
function run_env(rundir::AbstractString, server::Server; native::Bool)
    env = Dict{String, String}(String(k) => String(v) for (k, v) in FROZEN["env"])
    env["PATH"] = get(ENV, "PATH", "/usr/bin:/bin")
    env["HOME"] = joinpath(rundir, "home")
    env["TMPDIR"] = joinpath(rundir, "tmp")
    env["PWD"] = rundir
    env["JULIA_PROJECT"] = joinpath(rundir, "project")
    # native: trailing ':' appends the bundled depots (precompiled stdlibs, no registries);
    # wasm: the scenario depot only (stdlib metadata is embedded, D10)
    env["JULIA_DEPOT_PATH"] = joinpath(rundir, "depot") * (native ? ":" : "")
    env["JULIA_PKG_SERVER"] = server.url
    return env
end
# a scenario's own env entries (`env = {...}` in scenarios.toml; e.g. S-git: stock with CLI git)
scenario_env!(env, sc) = (for (k, v) in get(sc, "env", Dict{String, Any}()); env[String(k)] = String(v); end; env)
# `{rundir}` in a command's arguments (S-git: file:// URLs of the fixture repositories)
expand_args(args, rundir) = String[replace(a, "{rundir}" => rstrip(rundir, '/')) for a in args]

# ---------------------------------------------------------------- initial states
const INIT_KINDS = ("empty", "registry", "two", "two-compressed")
initial_dir(kind) = joinpath(FIX, "initial", kind)

function fresh_rundir(rundir)
    rm(rundir; force = true, recursive = true)
    for d in ("depot", "project", "home", "tmp", "out")
        mkpath(joinpath(rundir, d))
    end
    return rundir
end

# Remove depot state that is host/time specific and not part of the fixture.
function scrub_depot(depot)
    for d in ("logs", "compiled", "servers")
        rm(joinpath(depot, d); force = true, recursive = true)
    end
end

# PkgWasm (native) precompile cache: a depot stacked *behind* the scenario depot, primed
# once per run, so scenario depots stay free of compiled/ and runs don't recompile.
const PKGWASM_CACHE_DEPOT = joinpath(ROOT, "out", "pkgwasm-native-depot")
function prime_pkgwasm(pkgwasm)
    mkpath(PKGWASM_CACHE_DEPOT)
    # inherit the caller's env ($HEAVY's systemd-run needs the session bus vars)
    e = Dict{String, String}(k => v for (k, v) in ENV if !startswith(k, "JULIA_"))
    e["JULIA_DEPOT_PATH"] = PKGWASM_CACHE_DEPOT * ":"
    heavy = split(get(ENV, "HEAVY", ""))
    code = "pushfirst!(LOAD_PATH, $(repr(pkgwasm))); Base.require(Main, :PkgWasm)"
    run(setenv(`$heavy $JULIA_EXE --startup-file=no -e $code`, e))
end

function native_cmd(rundir, env, args; impl = "pkg", pkgwasm = "", errfile = "")
    e = copy(env)
    e["PKGWASM_NATIVE_IMPL"] = impl == "pkg" ? "Pkg" : "PkgWasm"
    if impl != "pkg"
        e["PKGWASM_NATIVE_PATH"] = pkgwasm
        e["JULIA_DEPOT_PATH"] = joinpath(rundir, "depot") * ":" * PKGWASM_CACHE_DEPOT * ":"
    end
    isempty(errfile) || (e["PKGWASM_ERROR_FILE"] = errfile)
    return setenv(`$JULIA_EXE --startup-file=no --history-file=no $(joinpath(@__DIR__, "native_pkg.jl")) $args`, e; dir = rundir)
end

# A template is valid if it holds exactly the frozen registry (content-verified), or no
# registry for "empty", and every Manifest source is installed.
function template_errors(kind)
    dir = initial_dir(kind)
    s = summarize(dir)
    kind == "empty" && return isempty(s["registries"]) && isempty(s["packages"]) ? String[] : ["empty template is not empty"]
    return validity_errors(dir, s)
end

# Review-1 #10: native runs append bundled depots (and, for pkgwasm-native, the precompile
# cache depot) after the scenario depot. They must not hold package or registry inputs,
# or native runs could use sources the Wasm run (scenario depot only) cannot see.
function check_extra_depots(depots)
    for d in depots, sub in ("registries", "packages")
        p = joinpath(d, sub)
        isdir(p) && !isempty(readdir(p)) && error("extra depot $d has a non-empty $sub/; native runs would see non-fixture inputs")
    end
end
const BUNDLED_DEPOTS = [abspath(Sys.BINDIR, "..", "local", "share", "julia"), abspath(Sys.BINDIR, "..", "share", "julia")]

function prepare(; force = false)
    check_extra_depots(BUNDLED_DEPOTS)
    mkpath(joinpath(FIX, "initial"))
    work = joinpath(FIX, "initial", ".work")
    rm(work; force = true, recursive = true)
    server = start_server(joinpath(FIX, "initial", "prepare-server.log"))
    try
        for kind in INIT_KINDS
            dst = initial_dir(kind)
            if isdir(dst) && !force
                v = template_errors(kind)
                isempty(v) || error("prepare: existing template $kind is invalid (rebuild with --force):\n  " * join(v, "\n  "))
                println("prepare: $kind exists and is valid (use --force to rebuild)")
                continue
            end
            fresh_rundir(work)
            env = run_env(work, server; native = true)
            if kind == "registry" || kind == "two"
                e = copy(env); e["JULIA_PKG_UNPACK_REGISTRY"] = "true"
                run(setenv(`$JULIA_EXE --startup-file=no -e 'import Pkg; Pkg.Registry.add()'`, e; dir = work))
            end
            if kind == "two"
                run(native_cmd(work, env, ["add", "Example", "JSON"]))
            end
            if kind == "two-compressed"
                # registry-tar's recipe (PLAN D11 update): the "two" recipe with the registry in
                # stock layout, registries/{CACHEDIR.TAG, General.toml, General.tar.zst}, as stock
                # Pkg 1.13 writes it by default (no JULIA_PKG_UNPACK_REGISTRY)
                run(setenv(`$JULIA_EXE --startup-file=no -e 'import Pkg; Pkg.Registry.add()'`, env; dir = work))
                run(native_cmd(work, env, ["add", "Example", "JSON"]))
                isempty(packed_layout_errors(joinpath(work, "depot"), nothing)) ||
                    error("prepare two-compressed: not the stock packed layout: $(packed_layout_errors(joinpath(work, "depot"), nothing))")
            end
            scrub_depot(joinpath(work, "depot"))
            rm(dst; force = true, recursive = true)
            mkpath(dst)
            for d in ("depot", "project")
                mv(joinpath(work, d), joinpath(dst, d))
            end
            v = template_errors(kind)
            isempty(v) || error("prepare: freshly built template $kind is invalid:\n  " * join(v, "\n  "))
            println("prepare: built $kind")
        end
    finally
        stop_server(server)
        rm(work; force = true, recursive = true)
    end
end

# Setup steps named in scenarios.toml
function apply_setup(step, rundir)
    proj = joinpath(rundir, "project")
    if step == "edit-resolve"
        f = joinpath(proj, "Project.toml")
        p = TOML.parsefile(f)
        delete!(p["deps"], "JSON")
        p["compat"] = Dict("Example" => "0.5")
        open(io -> TOML.print(io, p; sorted = true), f, "w")
    elseif step == "git-fixture"
        # PLAN D14: the package repository and git registry of S-git, in <rundir>/git
        isdefined(@__MODULE__, :GitFixture) || include(joinpath(@__DIR__, "git_fixture.jl"))
        Base.invokelatest(getfield(@__MODULE__, :GitFixture).make, rundir)
    elseif step == "rm-artifacts"
        # (S-artifacts, before a command) the installed artifacts leave the depot
        adir = joinpath(rundir, "depot", "artifacts")
        for n in (isdir(adir) ? readdir(adir) : String[])
            occursin(r"^[0-9a-f]{40}$", n) || continue
            run(`chmod -R u+w $(joinpath(adir, n))`)   # (in case the tree is read-only)
            rm(joinpath(adir, n); recursive = true)
        end
    elseif step == "copy-instantiate"
        for f in ("Project.toml", "Manifest.toml")
            cp(joinpath(FIX, "instantiate", f), joinpath(proj, f); force = true)
        end
    else
        error("unknown setup step $(repr(step))")
    end
end

function setup_scenario(name, rundir)
    sc = SCENARIOS[name]
    fresh_rundir(rundir)
    src = initial_dir(sc["init"])
    isdir(src) || error("initial state $(sc["init"]) missing; run `scenarios.jl prepare` first")
    for d in ("depot", "project")
        rm(joinpath(rundir, d); recursive = true)
        run(`cp -a $(joinpath(src, d)) $(joinpath(rundir, d))`)
    end
    # These committed baselines include Pkg.add's registry update. Rebuilt templates
    # have a recent update log, and Pkg.add otherwise skips it for Day(1).
    if name in ("S-artifacts", "S-gc", "S-gc-auto")
        log = joinpath(rundir, "depot", "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "registry_updates.toml")
        if isfile(log)
            updates = TOML.parsefile(log)
            for k in keys(updates)
                updates[k] = Dates.DateTime(2000, 1, 1)
            end
            open(io -> TOML.print(io, updates; sorted=true), log, "w")
        end
    end
    for step in get(sc, "setup", String[])
        apply_setup(step, rundir)
    end
end

# ---------------------------------------------------------------- run one scenario
function wasm_cmd(rundir, env, args; wasm, network, trace = "", extra_dirs = String[], platform_from_frozen = false,
                  spawn = String[])
    # Runner interface (runner/pkgwasm.mjs, D6): identity-mapped preopen of the run dir only
    # (plus decoys for the relocation test), explicit env, networking off for offline
    # scenarios, every path access traced.
    flags = ["--wasm", wasm, "--dir", rundir]
    for d in extra_dirs
        push!(flags, "--dir", d)
    end
    isempty(trace) || push!(flags, "--trace-fs", trace, "--timing", trace * ".timing.json")
    for k in sort!(collect(keys(env)))
        k == "PATH" && continue
        push!(flags, "--env", "$k=$(env[k])")
    end
    network || push!(flags, "--no-network")
    platform_from_frozen && push!(flags, "--platform-from-frozen")   # PLAN D13
    for p in spawn                                                   # PLAN D14 (ABI §6.1)
        push!(flags, "--allow-spawn=$p")
    end
    return setenv(`$NODE $(joinpath(@__DIR__, "pkgwasm.mjs")) $flags -- $args`; dir = rundir)
end

# Stock packed-registry layout (S-compressed, registry-tar recipe): depot/registries holds
# exactly CACHEDIR.TAG, General.toml, General.tar.zst, with the two registry files
# byte-identical to the template's (no unpack, no rewrite), and no registries/General dir.
const PACKED_FILES = ["CACHEDIR.TAG", "General.tar.zst", "General.toml"]
function packed_layout_errors(depot, template_depot)
    d = String[]
    regs = joinpath(depot, "registries")
    got = isdir(regs) ? sort(readdir(regs)) : String[]
    got == PACKED_FILES || push!(d, "registries/ holds $(got), expected exactly $(PACKED_FILES)")
    if template_depot !== nothing
        for f in ("General.toml", "General.tar.zst")
            a, b = joinpath(template_depot, "registries", f), joinpath(regs, f)
            isfile(b) && read(a) == read(b) || push!(d, "registries/$f is not byte-identical to the template")
        end
    end
    return d
end

# Expected registry layout after command i: `registry_layout = "packed"` (every step) or
# `registry_layout_steps = ["packed", ..., "none"]` (D15 registry rm). "none": no registry
# files at all in depot/registries (CACHEDIR.TAG may remain).
function layout_at(sc, i)
    steps = get(sc, "registry_layout_steps", nothing)
    steps === nothing || return steps[i]
    return get(sc, "registry_layout", "")
end
last_layout(sc) = layout_at(sc, length(sc["commands"]))
function step_layout_errors(sc, i, rundir)
    l = layout_at(sc, i)
    l == "packed" && return packed_layout_errors(joinpath(rundir, "depot"), joinpath(initial_dir(sc["init"]), "depot"))
    if l == "none"
        regs = joinpath(rundir, "depot", "registries")
        left = isdir(regs) ? filter(!=("CACHEDIR.TAG"), readdir(regs)) : String[]
        return isempty(left) ? String[] : ["registries/ still holds $(left)"]
    end
    return String[]
end

# Stock Julia on a *copy* of the final depot + project (the run dir stays the comparison
# input): the registry must still load as :packed, and Registry.status/status/resolve work.
function stock_packed_check(rundir)
    ad = joinpath(rundir, "stock-after")
    rm(ad; force = true, recursive = true); mkpath(ad)
    for x in ("depot", "project", "home", "tmp")
        run(`cp -a $(joinpath(rundir, x)) $(joinpath(ad, x))`)
    end
    srv = start_server(joinpath(ad, "server.log"); offline = true)
    code = try
        e = run_env(ad, srv; native = true)
        prog = "import Pkg; Pkg.Registry.status(); Pkg.status(); Pkg.resolve(); " *
               "r = only(Pkg.Registry.reachable_registries()); " *
               "Pkg.Registry.get_registry_type(r) == :packed || error(\"registry is not :packed\")"
        run(pipeline(ignorestatus(setenv(`$JULIA_EXE --startup-file=no -e $prog`, e; dir = ad));
                     stdout = joinpath(ad, "stdout.txt"), stderr = joinpath(ad, "stderr.txt"))).exitcode
    finally
        stop_server(srv)
    end
    return code == 0 ? String[] : ["stock Julia on a copy of the final depot: exit $code (see $ad/stderr.txt)"]
end

# Per-command evidence (review-1 #4): the environment, the installed packages and the
# server requests made by command i (the server log is written synchronously per request).
function record_step(rundir, i)
    out = joinpath(rundir, "out")
    pdir = mkpath(joinpath(out, "$i.project"))
    for f in ("Project.toml", "Manifest.toml")
        src = joinpath(rundir, "project", f)
        isfile(src) && cp(src, joinpath(pdir, f); force = true)
    end
    open(io -> TOML.print(io, package_summary(joinpath(rundir, "depot")); sorted = true),
         joinpath(out, "$i.packages.toml"), "w")
    # installed artifacts (hash => content tree hash) after this command
    open(io -> TOML.print(io, artifact_summary(joinpath(rundir, "depot")); sorted = true),
         joinpath(out, "$i.artifacts.toml"), "w")
    # path-tracked sources (develop, PLAN D14): their trees after this command
    open(io -> TOML.print(io, path_sources(joinpath(rundir, "project")); sorted = true),
         joinpath(out, "$i.path_sources.toml"), "w")
    # D15: the registries after this command (identity, storage, content) and the keys of
    # Pkg's registry update log (scratchspaces/<Pkg uuid>/registry_updates.toml; timestamps ignored)
    regs = Dict{String, Any}("registries" => registry_summary(joinpath(rundir, "depot")),
                             "listing" => registry_listing(joinpath(rundir, "depot")),
                             "update_log_keys" => registry_update_log_keys(joinpath(rundir, "depot")))
    open(io -> TOML.print(io, regs; sorted = true), joinpath(out, "$i.registries.toml"), "w")
    log = readlines_or_empty(joinpath(rundir, "server.log"))
    seen = sum((length(readlines_or_empty(joinpath(out, "$j.requests"))) for j in 1:i-1); init = 0)
    write(joinpath(out, "$i.requests"), join(log[seen+1:end], "\n") * (length(log) > seen ? "\n" : ""))
end

function run_scenario(name, rundir; impl = "pkg", pkgwasm = "", wasm = "", offline = false, extra_dirs = String[],
                      platform_from_frozen = false)
    sc = SCENARIOS[name]
    impl == "wasm" || check_extra_depots(impl == "pkg" ? BUNDLED_DEPOTS : [BUNDLED_DEPOTS; PKGWASM_CACHE_DEPOT])
    setup_scenario(name, rundir)
    network = get(sc, "network", true)
    server = start_server(joinpath(rundir, "server.log"); offline)
    layout_viol = String[]
    t0 = time()
    try
        for (i, args) in enumerate(sc["commands"])
            # `before = { <i> = [steps...] }`: setup steps applied right before command i
            for step in get(get(sc, "before", Dict{String, Any}()), string(i), String[])
                apply_setup(step, rundir)
            end
            env = scenario_env!(run_env(rundir, server; native = impl != "wasm"), sc)
            args = expand_args(args, rundir)
            out = joinpath(rundir, "out")
            errfile = impl == "wasm" ? "" : joinpath(out, "$i.error")
            cmd = impl == "wasm" ? wasm_cmd(rundir, env, args; wasm, network, extra_dirs, platform_from_frozen,
                                            trace = joinpath(out, "$i.fstrace"), spawn = String.(get(sc, "spawn", String[]))) :
                                   native_cmd(rundir, env, args; impl, pkgwasm, errfile)
            p = run(pipeline(ignorestatus(cmd); stdout = joinpath(out, "$i.stdout"), stderr = joinpath(out, "$i.stderr")))
            write(joinpath(out, "$i.exit"), string(p.exitcode))
            record_step(rundir, i)
            for e in step_layout_errors(sc, i, rundir)
                push!(layout_viol, "after command $i: $e")
            end
            # A Wasm run reports its error text only on stderr; compare.jl matches the tail.
        end
    finally
        stop_server(server)
    end
    elapsed = round(time() - t0; digits = 1)
    viol = copy(layout_viol)
    last_layout(sc) == "packed" && append!(viol, stock_packed_check(rundir))
    if impl == "wasm"
        # E1–E6: every path the module touched is inside the scenario dir
        # (trace lines: import \t dirfd \t raw \t resolved; "!..." = absolute/unknown-fd/unreadable)
        root = rstrip(rundir, '/')
        for i in eachindex(sc["commands"]), l in readlines_or_empty(joinpath(rundir, "out", "$i.fstrace"))
            f = split(l, '\t')
            if length(f) != 4
                push!(viol, "command $i: malformed trace record $(repr(l))")
                continue
            end
            f[1] == "wasi.fd_renumber" && !startswith(f[4], "!") && continue   # provenance record
            p = unescape_trace(f[4])
            startswith(p, root * "/") || p == root || push!(viol, "command $i accessed $(repr(p)) outside the scenario dir ($l)")
        end
    end
    if !network
        reqs = isfile(joinpath(rundir, "server.log")) ? readlines(joinpath(rundir, "server.log")) : String[]
        isempty(reqs) || push!(viol, "offline scenario made $(length(reqs)) server request(s): $(first(reqs))")
    end
    return elapsed, viol
end

# Canonical path: resolve symlinks of the nearest existing ancestor (review-5 #14b).
function canonpath(p)
    p = abspath(p); rest = String[]
    while !ispath(p) && dirname(p) != p
        pushfirst!(rest, basename(p)); p = dirname(p)
    end
    return joinpath(realpath(p), rest...)
end
path_inside(p, root) = startswith(canonpath(p) * "/", rstrip(canonpath(root), '/') * "/")
readlines_or_empty(f) = isfile(f) ? readlines(f) : String[]
# inverse of pkgwasm.mjs escField: \\ \t \n \r
unescape_trace(x) = replace(x, r"\\[\\tnr]" => m -> m[2] == '\\' ? "\\" : m[2] == 't' ? "\t" : m[2] == 'n' ? "\n" : "\r")

# D8 relocation test (M5.2): the module was built by build.jl with sentinel env/paths
# (out/sentinel/*) and poisoned PkgWasm state (decoy registry cache, flags). Run offline scenarios with those sentinel dirs preopened as decoys, and
# assert: results equivalent; no traced access under the sentinel root; sentinel dirs
# byte-identical afterwards; the build report lists no embedded host strings.
# S-add/S-fail need fresh registry discovery and network, so a build-time cached decoy
# registry, OFFLINE_MODE or UPDATED_REGISTRY_THIS_SESSION surviving into the image
# (build.jl poisons all three) makes them diverge.
function relocation(; wasm, out, names = ["S-status", "S-resolve", "S-rm", "S-add", "S-fail"], platform_from_frozen = false)
    sroot = joinpath(ROOT, "out", "sentinel")
    isdir(sroot) || error("no $sroot: build the module with runner/build.jl first")
    decoys = sort!(filter(isdir, readdir(sroot; join = true)))
    snapshot() = Dict(d => tree_hash_string(d) * ":" * join(sort(readdir(d)), ",") for d in decoys)
    before = snapshot()
    allok = true
    for name in names
        rundir = joinpath(abspath(out), name)
        elapsed, viol = run_scenario(name, rundir; impl = "wasm", wasm, extra_dirs = decoys, platform_from_frozen)
        checks, br = compare(joinpath(FIX, "baseline", name), rundir; bytes = true,
                             compare_error = get(SCENARIOS[name], "compare_error", false),
                             compare_stdout = get(SCENARIOS[name], "compare_stdout", false),
                             compare_stderr = get(SCENARIOS[name], "compare_stderr", false),
                             mask_rundir = get(SCENARIOS[name], "mask_rundir", false),
                             final_registry = get(SCENARIOS[name], "final_registry", "frozen"))
        # accesses to the decoys are already flagged as "outside the scenario dir"
        isempty(viol) || push!(checks, Check("relocation", false, viol))
        allok &= report(stdout, checks, br; label = "$name [relocation, $(elapsed)s]")
    end
    # cache-key collision (review-3 #5): build.jl cached a decoy registry (frozen tree hash,
    # Example 9.9.9 only) under <cache_poison_root>/depot; S-add run at exactly that path
    # diverges if the build-time REGISTRY_CACHE survived into the image.
    rep0 = wasm * ".build.toml"
    croot = isfile(rep0) ? get(TOML.parsefile(rep0), "cache_poison_root", "") : ""
    if isempty(croot)
        allok &= report(stdout, [Check("cache-key", false, ["build report has no cache_poison_root"])], String[]; label = "S-add@cache-key")
    elseif path_inside(wasm, croot) || path_inside(rep0, croot)
        # review-4 #14: setup wipes croot; never delete the module under test
        allok &= report(stdout, [Check("cache-key", false, ["module $wasm lies inside the cache-collision dir $croot, which this case wipes; build it elsewhere"])],
                        String[]; label = "S-add@cache-key")
    else
        elapsed, viol = run_scenario("S-add", croot; impl = "wasm", wasm, extra_dirs = decoys, platform_from_frozen)
        checks, br = compare(joinpath(FIX, "baseline", "S-add"), croot; bytes = true)
        isempty(viol) || push!(checks, Check("relocation", false, viol))
        allok &= report(stdout, checks, br; label = "S-add@cache-key [relocation, $(elapsed)s]")
    end
    after = snapshot()
    d = String[]
    before == after || push!(d, "sentinel dirs changed: $(setdiff(collect(before), collect(after)))")
    rep = wasm * ".build.toml"
    if isfile(rep)
        r = TOML.parsefile(rep)
        # rescan the module itself (decoded GC byte arrays + raw bytes) with the build's markers
        for (k, what) in (("host_markers", "build-host strings"), ("poison_markers", "build-time poisoned PkgWasm state"))
            haskey(r, k) || (push!(d, "build report lacks $k"); continue)
            hits = scan_markers(wasm, r[k])
            isempty(hits) || push!(d, "module embeds $what: $(hits)")
        end
        p = get(r, "poisoned", String[])
        (length(p) >= 3 && !any(x -> occursin("NOT", x) || occursin("not defined", x), p)) ||
            push!(d, "build was not fully poisoned: $(p)")
    else
        push!(d, "no build report $rep")
    end
    allok &= report(stdout, [Check("sentinels", isempty(d), d)], String[]; label = "relocation sentinels")
    return allok
end

function baseline(names)
    for name in names
        tmp = joinpath(FIX, "baseline", ".run-" * name)
        dst = joinpath(FIX, "baseline", name)
        elapsed, viol = run_scenario(name, tmp; impl = "pkg")
        isempty(viol) || error("baseline $name: $(join(viol, "; "))")
        v = validity_errors(tmp, summarize(tmp); registry = get(SCENARIOS[name], "final_registry", "frozen"))
        isempty(v) || error("baseline $name: invalid run, not published:\n  " * join(v, "\n  "))
        exits = command_outputs(tmp)[1]
        exits == SCENARIOS[name]["expect_exit"] || error("baseline $name: exits $exits != expected $(SCENARIOS[name]["expect_exit"]); see $tmp/out")
        sm = summarize(tmp)
        sm["kind"] = "baseline"
        open(io -> TOML.print(io, sm; sorted = true), joinpath(tmp, "summary.toml"), "w")
        rm(dst; force = true, recursive = true)
        mkpath(dst)
        for d in ("project", "out")
            cp(joinpath(tmp, d), joinpath(dst, d))
        end
        for f in ("server.log", "summary.toml")
            cp(joinpath(tmp, f), joinpath(dst, f))
        end
        rm(tmp; recursive = true)
        println("baseline $name: ok ($(elapsed)s, exits $exits)")
    end
end

function run_and_compare(names; impl, out, pkgwasm, wasm, offline, platform_from_frozen = false)
    allok = true
    for name in names
        rundir = joinpath(abspath(out), name)
        elapsed, viol = run_scenario(name, rundir; impl, pkgwasm, wasm, offline, platform_from_frozen)
        checks, br = compare(joinpath(FIX, "baseline", name), rundir; bytes = true,
                             compare_error = get(SCENARIOS[name], "compare_error", false),
                             compare_stdout = get(SCENARIOS[name], "compare_stdout", false),
                             compare_stderr = get(SCENARIOS[name], "compare_stderr", false),
                             mask_rundir = get(SCENARIOS[name], "mask_rundir", false),
                             final_registry = get(SCENARIOS[name], "final_registry", "frozen"))
        isempty(viol) || push!(checks, Check("run", false, viol))   # network / layout / access checks
        ok = report(stdout, checks, br; label = "$name [$impl, $(elapsed)s]")
        allok &= ok
    end
    return allok
end

function main(args)
    isempty(args) && (println(stderr, "usage: see header of runner/scenarios.jl"); return 2)
    sub, rest = args[1], args[2:end]
    opt(flag, default) = (i = findfirst(==(flag), rest)) === nothing ? default : (v = rest[i + 1]; deleteat!(rest, i:i+1); v)
    flag(f) = (i = findfirst(==(f), rest)) === nothing ? false : (deleteat!(rest, i); true)
    if sub == "prepare"
        prepare(; force = flag("--force"))
        return 0
    elseif sub == "baseline"
        names = isempty(rest) ? scenario_names() : rest
        baseline(names)
        return 0
    elseif sub == "run"
        impl = opt("--impl", "pkg")
        out = opt("--out", "")
        isempty(out) && error("run needs --out DIR")
        pkgwasm = abspath(opt("--pkgwasm", joinpath(ROOT, "src", "PkgWasm.jl")))
        wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "pkgwasm.wasm")))
        offline = flag("--offline")
        pff = flag("--platform-from-frozen")
        flag("--keep")
        impl in ("pkg", "pkgwasm-native", "wasm") || error("unknown --impl $impl")
        names = isempty(rest) ? scenario_names() : rest
        impl == "pkgwasm-native" && prime_pkgwasm(pkgwasm)
        return run_and_compare(names; impl, out, pkgwasm, wasm, offline, platform_from_frozen = pff) ? 0 : 1
    elseif sub == "relocation"
        out = opt("--out", "")
        isempty(out) && error("relocation needs --out DIR")
        wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "pkgwasm.wasm")))
        pff = flag("--platform-from-frozen")
        return relocation(; wasm, out, platform_from_frozen = pff, (isempty(rest) ? () : (; names = rest))...) ? 0 : 1
    else
        println(stderr, "unknown subcommand $sub")
        return 2
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
