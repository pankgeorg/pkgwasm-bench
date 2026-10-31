# Build out/pkgwasm.wasm from the PkgWasm entry points (PLAN.md M5.2, D5, D8). Owner: L5 e2e.
#
#   $HEAVY $JULIA runner/build.jl [--wcg DIR] [--builder DIR] [--pkgwasm DIR]
#                                 [--patch FILE ...] [--out FILE]
#                                 [--trim safe|unsafe] [--verify error|warn|off]
#                                 [--no-optimize] [--setup-only] [--hooks-fallback] [--env-dir DIR]
#                                 [--g3]   (= --trim safe --verify error: the G3 gate, zero diagnostics)
#                                 [--tasks none|jspi]   (S2: Config(tasks) and PkgWasm's `tasks` preference;
#                                                        jspi = stock concurrent downloads, Node only)
#
# Defaults: the integration checkouts src/{WasmCodegen,WasmBuilder,PkgWasm}.jl, the project
# patch runner/patches/pkgwasm-host.jl (L2, D2), out/pkgwasm.wasm, trim=:safe, verify=:error
# (the final gate). Use --trim unsafe --verify warn for bring-up (G2).
#
# The build runs in a generated environment (out/build-env) whose [sources] point at the
# chosen checkouts. Before PkgWasm is loaded, the environment-derived inputs are set to
# *sentinels* (PLAN D8 relocation test): anything the image captures from the build host's
# env instead of reading it at runtime in pkgwasm_init shows up as a sentinel string in the
# module bytes, which this script reports (and the relocation test fails on).
#
# Writes <out> and <out>.build.toml: inputs (commits, dirty flags), config, elapsed time,
# peak RSS, size, diagnostics, imports/exports (via Node), embedded host strings.

import TOML, Pkg
include(joinpath(@__DIR__, "imagescan.jl"))

const ROOT = normpath(joinpath(@__DIR__, ".."))
const NODE = get(ENV, "NODE", joinpath(homedir(), "wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node"))

# Sentinels for D8: values the image must not capture. `pkgwasm_init` reads the real values
# from WASI env at runtime.
# They are real directories (out/sentinel/*, each with a SENTINEL marker file) so the
# relocation test can preopen them as decoys and prove they are never accessed.
const SENTINEL_ROOT = joinpath(ROOT, "out", "sentinel")
const SENTINELS = Dict(
    "HOME" => joinpath(SENTINEL_ROOT, "home"),
    "TMPDIR" => joinpath(SENTINEL_ROOT, "tmp"),
    "JULIA_DEPOT_PATH" => joinpath(SENTINEL_ROOT, "depot"),
    "JULIA_PROJECT" => joinpath(SENTINEL_ROOT, "project"),
    "PWD" => joinpath(SENTINEL_ROOT, "cwd"),
    "JULIA_PKG_SERVER" => "http://pkgwasm-sentinel.invalid",
    "JULIA_PKG_OFFLINE" => "true",                   # must not leak into the image's OFFLINE_MODE
    "JULIA_PKG_GC_AUTO" => "true",
    "JULIA_PKG_PRECOMPILE_AUTO" => "1",
)
const BUILD_HOME = homedir()   # before the sentinels replace HOME
# Strings whose presence in the module means a build-host value was embedded.
host_markers(env_dir) = unique!(filter(!isempty, [
    "pkgwasm-sentinel", ROOT, env_dir, Sys.BINDIR, BUILD_HOME, homedir(), DEPOT_PATH...,
]))

# Canonical path: resolve symlinks of the nearest existing ancestor (review-5 #14b).
function canonpath(p)
    p = abspath(p); rest = String[]
    while !ispath(p) && dirname(p) != p
        pushfirst!(rest, basename(p)); p = dirname(p)
    end
    return joinpath(realpath(p), rest...)
end
path_inside(p, root) = startswith(canonpath(p) * "/", rstrip(canonpath(root), '/') * "/")

function parse_args(args)
    o = Dict{String, Any}(
        "wcg" => joinpath(ROOT, "src/WasmCodegen.jl"), "builder" => joinpath(ROOT, "src/WasmBuilder.jl"),
        "pkgwasm" => joinpath(ROOT, "src/PkgWasm.jl"), "irs" => joinpath(ROOT, "src/IRStructurizer.jl"), "patches" => String[],
        "out" => joinpath(ROOT, "out/pkgwasm.wasm"), "trim" => "safe", "verify" => "error",
        "optimize" => true, "setup_only" => false, "hooks_fallback" => false,
        "env_dir" => joinpath(ROOT, "out", "build-env"), "tasks" => "none")
    i = 1
    val() = (i < length(args) || error("$(args[i]) needs a value"); i += 1; args[i])
    while i <= length(args)
        a = args[i]
        if a == "--wcg"; o["wcg"] = abspath(val())
        elseif a == "--builder"; o["builder"] = abspath(val())
        elseif a == "--pkgwasm"; o["pkgwasm"] = abspath(val())
        elseif a == "--irs"; o["irs"] = abspath(val())
        elseif a == "--patch"; push!(o["patches"], abspath(val()))
        elseif a == "--out"; o["out"] = abspath(val())
        elseif a == "--trim"; o["trim"] = val()
        elseif a == "--verify"; o["verify"] = val()
        elseif a == "--no-optimize"; o["optimize"] = false
        elseif a == "--setup-only"; o["setup_only"] = true
        elseif a == "--hooks-fallback"; o["hooks_fallback"] = true
        elseif a == "--env-dir"; o["env_dir"] = abspath(val())
        elseif a == "--tasks"; o["tasks"] = val()
        elseif a == "--g3"; o["trim"] = "safe"; o["verify"] = "error"   # the G3 acceptance gate
        else error("unknown argument $a")
        end
        i += 1
    end
    isempty(o["patches"]) && push!(o["patches"], joinpath(ROOT, "runner/patches/pkgwasm-host.jl"))
    o["trim"] in ("safe", "unsafe") || error("--trim must be safe or unsafe")
    o["verify"] in ("error", "warn", "off") || error("--verify must be error, warn or off")
    o["tasks"] in ("none", "jspi") || error("--tasks must be none or jspi")
    for k in ("wcg", "builder", "pkgwasm", "irs")
        isfile(joinpath(o[k], "Project.toml")) || error("--$k $(o[k]) is not a package checkout")
    end
    for root in (joinpath(ROOT, "out", "relocation-cache"), joinpath(ROOT, "out", "sentinel"))
        # review-4 #14: these dirs are wiped/preopened as decoys by the relocation test
        path_inside(o["out"], root) && error("--out $(o["out"]) lies inside $root, which the relocation test wipes or uses as a decoy")
    end
    for p in o["patches"]
        isfile(p) || error("patch file $p does not exist (L2 owns runner/patches/pkgwasm-host.jl)")
    end
    return o
end

function git_info(dir)
    q(c) = readchomp(pipeline(c; stderr = devnull))
    rev = try q(`git -C $dir rev-parse HEAD`) catch; "unknown (not a git checkout)" end
    dirty = try !isempty(q(`git -C $dir status --porcelain --untracked-files=no`)) catch; true end
    return Dict("path" => dir, "commit" => rev, "dirty" => dirty)
end

# The build environment: WasmCodegen + WasmBuilder + PkgWasm from the given checkouts.
function setup_env(o)
    env = o["env_dir"]   # separate dirs allow concurrent builds of different checkouts
    mkpath(env)
    name(dir) = TOML.parsefile(joinpath(dir, "Project.toml"))
    wcg, wb, pw, irs = name(o["wcg"]), name(o["builder"]), name(o["pkgwasm"]), name(o["irs"])
    pw["name"] == "PkgWasm" || error("--pkgwasm $(o["pkgwasm"]) is package $(pw["name"]), not PkgWasm (needs L3's rename, M3.1)")
    proj = Dict(
        # D9 (pkg-trim): PkgWasm's compile-time preference selects the Wasm Context IO type.
        # Only the build project sets it; native scenario runs use their own projects (default
        # "native"). Harmless for a PkgWasm that does not read it.
        # S2: `tasks` selects the serial (none, S1) or the stock concurrent (jspi) download pool.
        "preferences" => Dict("PkgWasm" => Dict("target" => "wasm", "tasks" => o["tasks"])),
        # (this host: IRStructurizer pinned here too; WasmCodegen's own [sources] name the other host's path)
        "deps" => Dict(wcg["name"] => wcg["uuid"], wb["name"] => wb["uuid"], pw["name"] => pw["uuid"], irs["name"] => irs["uuid"]),
        "sources" => Dict(wcg["name"] => Dict("path" => o["wcg"]), wb["name"] => Dict("path" => o["builder"]),
                          pw["name"] => Dict("path" => o["pkgwasm"]), irs["name"] => Dict("path" => o["irs"])))
    open(io -> TOML.print(io, proj; sorted = true), joinpath(env, "Project.toml"), "w")
    rm(joinpath(env, "Manifest.toml"); force = true)   # re-resolve against the chosen checkouts
    return env
end

function module_interface(file)
    js = """
    const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1]));
    console.log(JSON.stringify({imports: WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name + ':' + i.kind),
                                exports: WebAssembly.Module.exports(m).map(e => e.name + ':' + e.kind)}));"""
    out = read(`$NODE -e $js $file`, String)
    m = match(r"\"imports\":\[(.*?)\],\"exports\":\[(.*?)\]", out)
    split_list(s) = isempty(s) ? String[] : [strip(x, '"') for x in split(s, "\",\"")]
    return split_list(m.captures[1]), split_list(m.captures[2])
end

function main(args)
    o = parse_args(args)
    env = setup_env(o)
    Pkg.activate(env; io = devnull)
    Pkg.instantiate()
    o["setup_only"] && (println("build env ready: $env"); return 0)

    for d in ("home", "tmp", "depot", "project", "cwd")
        mkpath(joinpath(SENTINEL_ROOT, d))
        write(joinpath(SENTINEL_ROOT, d, "SENTINEL"), "build-time sentinel; must never be accessed at runtime\n")
    end
    for (k, v) in SENTINELS
        ENV[k] = v
    end
    @eval using WasmCodegen
    @eval using PkgWasm
    # anything that captures DEPOT_PATH/LOAD_PATH at build time captures the sentinels too
    push!(DEPOT_PATH, joinpath(SENTINEL_ROOT, "depot"))
    push!(LOAD_PATH, joinpath(SENTINEL_ROOT, "project"))
    latest(name) = Base.invokelatest(getfield, Main, name)
    return Base.invokelatest(build, o, env, latest(:WasmCodegen), latest(:PkgWasm))
end

# Review-1 #5: poison PkgWasm's in-memory state with distinguishable build-time values, so
# an image that captures instead of re-initialising it fails the relocation scenarios:
#  - REGISTRY_CACHE holds a decoy "General" (same UUID, only a fake Example 9.9.9, package
#    info eagerly parsed) loaded from CACHE_POISON_ROOT/depot. The cache is keyed by path and
#    validated only by tree hash, so the decoy claims the *frozen* tree hash: the relocation
#    case "S-add@cache-key" runs S-add with its depot at exactly that path, and a surviving
#    cache then serves the decoy (no JSON, Example 9.9.9) -> divergence (review-3 #5;
#    mechanism verified natively: stale -> Example 9.9.9 / JSON missing, reset -> 0.5.5);
#  - UPDATED_REGISTRY_THIS_SESSION = true (would skip the registry update S-fail/S-add do);
#  - OFFLINE_MODE = true (would make S-add/S-fail fail without network).
const CACHE_POISON_ROOT = joinpath(ROOT, "out", "relocation-cache")
frozen_tree_hash() = TOML.parsefile(joinpath(ROOT, "fixtures", "frozen.toml"))["registry_tree_hash"]

function write_decoy_registry(depot)
    r = joinpath(depot, "registries", "General")
    mkpath(joinpath(r, "E", "Example"))
    write(joinpath(r, "Registry.toml"), """
        name = "General"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://pkgwasm-sentinel.invalid/decoy-General.git"
        description = "DECOY registry from the build host; must never be used at runtime"
        [packages]
        7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
        """)
    write(joinpath(r, "E", "Example", "Package.toml"), """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        repo = "https://pkgwasm-sentinel.invalid/Example.jl.git"
        """)
    write(joinpath(r, "E", "Example", "Versions.toml"), """
        ["9.9.9"]
        git-tree-sha1 = "0000000000000000000000000000000000000000"
        """)
    write(joinpath(r, ".tree_info.toml"), "git-tree-sha1 = \"$(frozen_tree_hash())\"\n")
    return r
end

function poison!(PW::Module)
    done = String[]
    depot = joinpath(CACHE_POISON_ROOT, "depot")
    rm(CACHE_POISON_ROOT; force = true, recursive = true)
    write_decoy_registry(depot)
    try
        regs = PW.Registry.reachable_registries(; depots = [depot])
        for reg in regs, (uuid, pkg) in reg   # force package info to be parsed and cached
            PW.Registry.registry_info(reg, pkg)
        end
        push!(done, "REGISTRY_CACHE: decoy General ($(length(PW.Registry.REGISTRY_CACHE)) entries)")
    catch e
        push!(done, "REGISTRY_CACHE: NOT poisoned ($(sprint(showerror, e)))")
    end
    for g in (:UPDATED_REGISTRY_THIS_SESSION, :OFFLINE_MODE)
        if isdefined(PW, g)
            getfield(PW, g)[] = true
            push!(done, "$g = true")
        else
            push!(done, "$g: not defined in PkgWasm")
        end
    end
    return done
end

# Strings only the poisoned build-time state contains: the decoy registry's description and
# repo, and the cache key (its path). If the image still holds the build-time REGISTRY_CACHE
# (or any registry object loaded from the decoy), these bytes are in the module.
const POISON_MARKERS = ["DECOY registry from the build host", "decoy-General.git", "pkgwasm-sentinel.invalid/Example.jl"]

function build(o, env, WC::Module, PW::Module)
    # D9 feature detection: a PkgWasm with the `target` preference must see "wasm" here
    target = isdefined(PW, :TARGET) ? string(getfield(PW, :TARGET)) : "n/a (PkgWasm without the D9 target preference)"
    isdefined(PW, :TARGET) && target != "wasm" &&
        error("build.jl: PkgWasm.TARGET = $(repr(target)), expected \"wasm\" from [preferences.PkgWasm] in $env/Project.toml")
    isdefined(PW, :TASKS) && string(getfield(PW, :TASKS)) != o["tasks"] &&
        error("build.jl: PkgWasm.TASKS = $(repr(getfield(PW, :TASKS))), expected $(repr(o["tasks"])) (--tasks)")
    o["tasks"] != "none" && !isdefined(PW, :TASKS) && error("build.jl: --tasks $(o["tasks"]) needs a PkgWasm with the `tasks` preference")
    poisoned = poison!(PW)
    bad = filter(p -> occursin("NOT poisoned", p) || occursin("not defined", p), poisoned)
    # review-2 #5: an unpoisoned build would make the relocation test vacuous
    isempty(bad) || error("build.jl: poisoning PkgWasm state failed, refusing to build:\n  " * join(bad, "\n  "))

    entries = [WC.Entry(getfield(PW, f), (); name = string(f))
               for f in (:pkgwasm_abi_version, :pkgwasm_init, :pkgwasm_main)]
    # D8 (REQUEST approved 18:2x): sanitise Base and PkgWasm globals inside compile, after all
    # build-time code (including poison! above), right before image emission. Hooks are used as
    # soon as they exist; availability is recorded and relocation enforces the result
    # (poison_strings_found / embedded_host_strings must be empty).
    hooks, hook_report = Any[], String[]
    for (mod, name) in ((WC.Runtime, :sanitize_base_globals!), (PW, :sanitize_globals!))
        if isdefined(mod, name)
            push!(hooks, getfield(mod, name)); push!(hook_report, "$(mod).$(name)")
        else
            push!(hook_report, "MISSING $(mod).$(name)")
        end
    end
    has_hooks = :pre_image_hooks in fieldnames(WC.Config)
    if !has_hooks
        push!(hook_report, "MISSING Config(pre_image_hooks) in this WasmCodegen")
        if o["hooks_fallback"]
            # Approximation for bring-up only: run the sanitisers now, right before compile
            # (no other build code runs in between). Not a substitute for the in-compile hook.
            for h in hooks
                h()
            end
            push!(hook_report, "FALLBACK: hooks called directly before compile (approximation)")
        end
    end
    # NB (pkg-fork, PkgWasm 32178179c): after sanitize_globals! PkgWasm is not usable natively
    # (host_platform() throws) until init_globals!(); nothing below uses PkgWasm.
    config = WC.Config(;
        (has_hooks && !isempty(hooks) ? (; pre_image_hooks = hooks) : (;))...,
        trim = Symbol(o["trim"]), verify = Symbol(o["verify"]),
        # S2: only passed for jspi, so a WasmCodegen without `Config(tasks)` still builds S1
        (o["tasks"] == "none" ? (;) : (; tasks = Symbol(o["tasks"])))...,
        on_unsupported = o["trim"] == "safe" ? :error : :trap,
        extra_patches = o["patches"], patch_bindings = Pair{Symbol, Any}[:PkgWasm => PW],
        (o["optimize"] ? () : (; optimize = nothing))...)

    t0 = time()
    status, err, comp = "ok", "", nothing
    failure_diags = String[]      # G3: codegen constructs from an UnsupportedConstructs (trim=:safe)
    verifier_report = nothing     # juliac verifier's report (TrimFailure, or the world's trim_report)
    err_bt = ""
    try
        comp = Base.invokelatest(WC.compile, entries; config)
    catch e
        status, err = "failed", sprint(showerror, e)
        # the stack of a failure that is not an expected G3 report (compiler errors)
        err_bt = sprint(Base.show_backtrace, catch_backtrace())
        if hasfield(typeof(e), :errors) && e.errors isa Vector   # WasmCodegen.UnsupportedConstructs
            failure_diags = [string(mi, " => ", sprint(showerror, d)) for (mi, d) in e.errors]
        end
        if hasfield(typeof(e), :report) && e.report isa String   # WasmCodegen.TrimFailure
            verifier_report = e.report
        end
    end
    if comp !== nothing && hasfield(typeof(comp.world), :trim_report)
        verifier_report = comp.world.trim_report[]
    end
    elapsed = round(time() - t0; digits = 1)

    report = Dict{String, Any}(
        "status" => status, "error" => first(err, 20_000),
        "date" => string(Libc.strftime("%Y-%m-%dT%H:%M:%S", time())),
        "julia" => string(VERSION),
        "inputs" => Dict("wasmcodegen" => git_info(o["wcg"]), "wasmbuilder" => git_info(o["builder"]),
                         "pkgwasm" => git_info(o["pkgwasm"]), "runner" => git_info(@__DIR__),
                         "patches" => o["patches"]),
        "config" => Dict("trim" => o["trim"], "verify" => o["verify"], "optimize" => o["optimize"], "tasks" => o["tasks"]),
        "sentinels" => SENTINELS,
        "poisoned" => poisoned,
        "pre_image_hooks" => hook_report,
        "pkgwasm_target" => target,
        "elapsed_s" => elapsed, "maxrss_mib" => round(Sys.maxrss() / 2^20; digits = 1))
    isempty(err_bt) || (report["error_backtrace"] = first(err_bt, 60_000))
    if !isempty(failure_diags)
        report["diagnostics_count"] = length(failure_diags)
        report["diagnostics"] = first(failure_diags, 2000)
    end
    if verifier_report !== nothing
        # juliac's verifier (verify=:warn reports, verify=:error fails). The full text goes to its
        # own file (it can be megabytes; a truncated copy once hid most of the V rows); the build
        # report keeps the counts over the full text, the file's path and a short head.
        vfile = o["out"] * ".verifier.txt"
        mkpath(dirname(vfile))
        write(vfile, verifier_report)
        report["verifier_errors"] = length(collect(eachmatch(r"^Error #\d+:"m, verifier_report)))
        report["verifier_warnings"] = length(collect(eachmatch(r"^Warning #\d+:"m, verifier_report)))
        report["verifier_report_file"] = vfile
        report["verifier_report_bytes"] = sizeof(verifier_report)
        report["verifier_report_head"] = first(verifier_report, 4_000)
    end
    if comp !== nothing
        bytes = comp.bytes
        mkpath(dirname(o["out"]))
        write(o["out"], bytes)
        diags = comp.cgm.diagnostics
        report["size_bytes"] = length(bytes)
        report["diagnostics_count"] = length(diags)
        report["diagnostics"] = first([string(mi, " => ", sprint(showerror, d)) for (mi, d) in diags], 500)
        imps, exps = module_interface(o["out"])
        report["imports"] = imps
        report["exports"] = exps
        # decoded image strings, not raw bytes (imagescan.jl)
        report["host_markers"] = host_markers(env)
        report["poison_markers"] = [POISON_MARKERS; joinpath(CACHE_POISON_ROOT, "depot", "registries", "General")]
        report["cache_poison_root"] = CACHE_POISON_ROOT
        report["embedded_host_strings"] = scan_markers(o["out"], report["host_markers"])
        report["poison_strings_found"] = scan_markers(o["out"], report["poison_markers"])
    end
    mkpath(dirname(o["out"]))
    open(io -> TOML.print(io, report; sorted = true), o["out"] * ".build.toml", "w")
    println("build $status in $(elapsed)s; report: $(o["out"]).build.toml")
    status == "ok" || println(stderr, err)
    return status == "ok" ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
