# Timing harness for the Pkg cases: stock Pkg vs PkgWasm natively vs PkgWasm in Wasm, on the
# runner's scenario machinery (runner/scenarios.jl: initial states, frozen server, env policy,
# compare.jl), with every command timed in its own process under /usr/bin/time.
#
#   julia harness/pkgbench.jl prepare-m4 PKG...       resolve the M4 manifest (stock), build fixtures/initial/m4
#   julia harness/pkgbench.jl validate --out DIR [--wasm FILE] [CASE...]
#       untimed, online frozen server (fills fixtures/cache): stock runs become the local
#       baseline DIR/stock/<case>; native and Wasm runs are compared with it; stock is also
#       compared with fixtures/baseline (the other host's aarch64 / 1.13.2 baseline)
#   julia harness/pkgbench.jl time --out DIR [--rounds 5] [--impls stock,native,wasm] [--wasm FILE]
#         [--nodeflags "..."] [--label L] [--baseline DIR] [CASE...]
#       timed rounds, offline frozen server; each round runs every case with the implementations
#       interleaved (order rotated per round); appends one row per command to DIR/results.csv
#
# CASE: M4 (= M4-cold, M4-warm, M4-noop) or a scenario name from fixtures/scenarios.toml.
# Every native command runs with the frozen env policy, JULIA_PKG_PRECOMPILE_AUTO=0 included.

include(joinpath(@__DIR__, "..", "runner", "scenarios.jl"))
using Printf

const M4_TEMPLATE = joinpath(FIX, "initial", "m4")
const IMPL_RUNNER = Dict("stock" => "pkg", "native" => "pkgwasm-native", "wasm" => "wasm")
const PKGWASM_SRC = joinpath(ROOT, "src", "PkgWasm.jl")
const MY_CGROUP = strip(read("/proc/self/cgroup", String))
# Wasm implementations by name: "wasm" (--wasm/--nodeflags) and any `--variant NAME=FILE[::NODEFLAGS]`
const VARIANTS = Dict{String, Tuple{String, Vector{String}}}()
iswasm(impl) = startswith(impl, "wasm")

# the native host's platform tags (minus julia_version: the module adds its own), so the Wasm
# module reports the same Julia-System header as stock Julia on this machine
host_platform_flags() = String[x for (k, v) in sort!(collect(Base.BinaryPlatforms.tags(Base.BinaryPlatforms.HostPlatform())))
                                 if k != "julia_version" for x in ("--platform-tag", "$k=$v")]

function my_wasm_cmd(rundir, env, args; wasm, network, nodeflags = String[], spawn = String[], timing = "", trace = "")
    flags = ["--wasm", wasm, "--dir", rundir]
    isempty(timing) || push!(flags, "--timing", timing)
    isempty(trace) || push!(flags, "--trace-fs", trace)
    for k in sort!(collect(keys(env)))
        k == "PATH" && continue
        push!(flags, "--env", "$k=$(env[k])")
    end
    network || push!(flags, "--no-network")
    push!(flags, "--platform-from-frozen")
    for p in spawn
        push!(flags, "--allow-spawn=$p")
    end
    script = joinpath(ROOT, "runner", "pkgwasm.mjs")
    # (git, for S-git, is looked up in the runner's PATH)
    return setenv(`$NODE $nodeflags $script $flags -- $args`, "PATH" => get(ENV, "PATH", "/usr/bin:/bin"); dir = rundir)
end

# /usr/bin/time around `cmd`: (wall seconds by the monotonic clock, peak RSS KiB, exit code)
function timed(cmd::Cmd, stdout_file, stderr_file)
    tf = tempname()
    wrapped = Cmd(Cmd(["/usr/bin/time", "-f", "%M %e", "-o", tf, cmd.exec...]); env = cmd.env, dir = cmd.dir)
    t0 = time_ns()
    p = run(pipeline(ignorestatus(wrapped); stdout = stdout_file, stderr = stderr_file))
    wall = (time_ns() - t0) / 1e9
    line = split(strip(last(readlines(tf))))
    rm(tf; force = true)
    return wall, parse(Int, line[1]), p.exitcode
end

loadavg() = parse(Float64, split(read("/proc/loadavg", String))[1])
other_heavy_scopes() = String[]
function wait_quiet(; max_wait = 0, load_max = 80)
    return (true, loadavg(), 0)
end
function batch_snapshot(out, tag)
    open(joinpath(out, "load-$tag.txt"), "w") do io
        run(pipeline(`uptime`; stdout=io))
        run(pipeline(`/bin/sh -c "top -bn1 | head -20"`; stdout=io))
    end
end

# ---------------------------------------------------------------- one case run
struct CmdResult
    i::Int
    args::Vector{String}
    wall::Float64
    rss_kib::Int
    exit::Int
    wasm_ms::Dict{String, Any}
    load1::Float64
end

# Runs the commands of `name` (scenario) in `rundir` (already set up), each timed.
function run_commands(name, rundir, impl; offline, commands, sc, measured=true)
    wasm, nodeflags = iswasm(impl) ? VARIANTS[impl] : ("", String[])
    network = get(sc, "network", true)
    server = start_server(joinpath(rundir, "server.log"); offline)
    res = CmdResult[]
    layout = String[]
    try
        for (i, args) in enumerate(commands)
            for step in get(get(sc, "before", Dict{String, Any}()), string(i), String[])
                apply_setup(step, rundir)
            end
            env = scenario_env!(run_env(rundir, server; native = !iswasm(impl)), sc)
            args = expand_args(args, rundir)
            out = joinpath(rundir, "out")
            tj = joinpath(out, "$i.timing.json")
            cmd = iswasm(impl) ?
                my_wasm_cmd(rundir, env, args; wasm, network, nodeflags, timing = measured ? tj : "",
                            spawn = String.(get(sc, "spawn", String[]))) :
                native_cmd(rundir, env, args; impl = IMPL_RUNNER[impl], pkgwasm = PKGWASM_SRC,
                           errfile = joinpath(out, "$i.error"))
            command_load = loadavg()
            wall, rss, code = if measured
                timed(cmd, joinpath(out, "$i.stdout"), joinpath(out, "$i.stderr"))
            else
                p = run(pipeline(ignorestatus(cmd); stdout=joinpath(out, "$i.stdout"), stderr=joinpath(out, "$i.stderr")))
                (0.0, 0, p.exitcode)
            end
            write(joinpath(out, "$i.exit"), string(code))
            ms = Dict{String, Any}()
            if isfile(tj)
                m = match(r"\"ms\":\{([^}]*)\}", read(tj, String))
                m === nothing || for kv in split(m.captures[1], ',')
                    k, v = split(kv, ':'); ms[strip(k, '"')] = parse(Float64, v)
                end
            end
            push!(res, CmdResult(i, args, wall, rss, code, ms, command_load))
            record_step(rundir, i)
            for e in step_layout_errors(sc, i, rundir)
                push!(layout, "after command $i: $e")
            end
        end
    finally
        stop_server(server)
    end
    return res, layout
end

function copy_state(src, dst)
    for d in ("depot", "project")
        rm(joinpath(dst, d); force=true, recursive=true)
        run(`cp -a $(joinpath(src, d)) $(joinpath(dst, d))`)
    end
    # A cloned depot's usage logs must refer to its cloned project. Otherwise the
    # comparator sees distinct predecessor roots for stock and Wasm/native.
    logs = joinpath(dst, "depot", "logs")
    if isdir(logs)
        for f in readdir(logs; join=true)
            endswith(f, ".toml") || continue
            write(f, replace(read(f, String), abspath(src) => abspath(dst)))
        end
    end
end

const M4_SC = Dict{String, Any}("commands" => [["instantiate"]], "network" => true, "expect_exit" => [0], "env" => Dict("JULIA_PKG_CONCURRENT_DOWNLOADS" => "8"))

# set up `case` in rundir; for M4-warm/M4-noop `prev` is the completed M4-cold run dir of the same impl
function registry_cache_checkpoint(work)
    result = Dict{String, String}()
    tar = joinpath(work, "depot", "registries", "General.tar.zst")
    if isfile(tar)
        st = stat(tar)
        result["compressed_identity"] = string(st.size, '\t', st.mtime, '\t', st.ctime, '\t', st.inode, '\t', tar)
    end
    dir = joinpath(work, "depot", "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "registry_cache")
    if isdir(dir)
        for p in readdir(dir; join=true)
            endswith(p, ".idx") || continue
            result[basename(p)] = join(first(readlines(p), 3), "\n")
        end
    end
    return result
end

# M4 keeps one physical depot for cold -> warm -> noop. Registry cache keys include
# absolute path, inode and ctime, so copying a warm depot would invalidate its cache.
function setup_case(case, resultdir; prev = "")
    if startswith(case, "M4-")
        work = joinpath(dirname(resultdir), "M4-work")
        if case == "M4-cold"
            fresh_rundir(work)
            copy_state(M4_TEMPLATE, work)
        else
            isdir(joinpath(work, "depot")) || error("M4 warm/noop requires a preceding cold run")
            rm(joinpath(work, "out"); recursive=true, force=true)
            mkpath(joinpath(work, "out"))
            rm(joinpath(work, "server.log"); force=true)
            case == "M4-warm" && rm(joinpath(work, "depot", "packages"); recursive=true, force=true)
        end
        open(io -> TOML.print(io, registry_cache_checkpoint(work); sorted=true), joinpath(work, "out", "cache-before.toml"), "w")
        return work
    end
    setup_scenario(case, resultdir)
    return resultdir
end

function seal_case(case, work, resultdir, impl)
    work == resultdir && return resultdir
    after = registry_cache_checkpoint(work)
    before = TOML.parsefile(joinpath(work, "out", "cache-before.toml"))
    if iswasm(impl) && case in ("M4-warm", "M4-noop")
        indexes = filter(k -> endswith(k, ".idx"), collect(keys(before)))
        isempty(indexes) && error("M4 warm/noop has no preexisting registry index")
        before == after || error("M4 warm/noop changed registry identity or cache generation")
    end
    open(io -> TOML.print(io, after; sorted=true), joinpath(work, "out", "cache-after.toml"), "w")
    fresh_rundir(resultdir)
    copy_state(work, resultdir)  # snapshots only; the active depot is never copied between cases
    run(`cp -a $(joinpath(work, "out", ".")) $(joinpath(resultdir, "out"))`)
    cp(joinpath(work, "server.log"), joinpath(resultdir, "server.log"); force=true)
    return resultdir
end

case_sc(case) = startswith(case, "M4-") ? M4_SC : SCENARIOS[case]

function compare_case(case, expected, actual)
    sc = case_sc(case)
    checks, _ = compare(expected, actual; bytes = false,
                        compare_error = get(sc, "compare_error", false),
                        compare_stdout = get(sc, "compare_stdout", false),
                        compare_stderr = get(sc, "compare_stderr", false),
                        mask_rundir = get(sc, "mask_rundir", false),
                        final_registry = get(sc, "final_registry", "frozen"))
    bad = filter(c -> !c.ok, checks)
    return isempty(bad), String[string(c.name, ": ", join(first(c.detail, 3), " | ")) for c in bad]
end

expand_cases(cases) = isempty(cases) ? vcat(["M4-cold", "M4-warm", "M4-noop"], scenario_names()) :
    reduce(vcat, [c == "M4" ? ["M4-cold", "M4-warm", "M4-noop"] : [c] for c in cases])

# ---------------------------------------------------------------- prepare-m4
function prepare_m4(pkgs)
    two = initial_dir("two-compressed")
    isdir(two) || error("run `runner/scenarios.jl prepare` first")
    work = joinpath(FIX, "initial", ".m4work")
    fresh_rundir(work)
    run(`cp -a $(joinpath(two, "depot", "registries")) $(joinpath(work, "depot", "registries"))`)
    server = start_server(joinpath(work, "server.log"))
    try
        env = run_env(work, server; native = true)
        run(native_cmd(work, env, ["add"; pkgs]))
    finally
        stop_server(server)
    end
    m = TOML.parsefile(joinpath(work, "project", "Manifest.toml"))
    n = count(((k, v),) -> any(e -> haskey(e, "git-tree-sha1"), v), m["deps"])
    jll = [k for (k, v) in m["deps"] if endswith(k, "_jll") && any(e -> haskey(e, "git-tree-sha1"), v)]
    println("prepare-m4: $n packages with tree hashes (JLLs: $(jll))")
    rm(M4_TEMPLATE; recursive = true, force = true)
    mkpath(joinpath(M4_TEMPLATE, "depot"))
    run(`cp -a $(joinpath(two, "depot", "registries")) $(joinpath(M4_TEMPLATE, "depot", "registries"))`)
    mv(joinpath(work, "project"), joinpath(M4_TEMPLATE, "project"))
    rm(work; recursive = true)
    return n
end

# ---------------------------------------------------------------- validate
function validate(cases, out; impls = ["stock", "native", "wasm"], baseline = out)
    mkpath(out)
    previous = joinpath(out, "validate.txt")
    rows = isfile(previous) ? filter(l -> isempty(split(l)) || !(first(split(l)) in cases), readlines(previous)) : String[]
    gatefile = joinpath(out, "gates.toml")
    gates = isfile(gatefile) ? TOML.parsefile(gatefile) : Dict{String, Any}()
    for case in cases
        dirs = Dict{String, String}("stock" => joinpath(baseline, "stock", case))
        for impl in impls
            resultdir = joinpath(out, impl, case)
            prev = startswith(case, "M4-") && case != "M4-cold" ? joinpath(out, impl, "M4-cold") : ""
            rundir = setup_case(case, resultdir; prev)
            sc = case_sc(case)
            res, layout = run_commands(case, rundir, impl; offline = false, commands = sc["commands"], sc, measured=false)
            seal_case(case, rundir, resultdir, impl)
            dirs[impl] = resultdir
            exits = [r.exit for r in res]
            ok_exit = exits == sc["expect_exit"]
            ok, why = impl == "stock" ? (true, String[]) : compare_case(case, dirs["stock"], resultdir)
            isempty(layout) || (ok = false; append!(why, layout))
            gates["$case/$impl"] = ok_exit && ok
            line = @sprintf("%-22s %-7s exits %-20s %s %s", case, impl, string(exits), ok_exit ? "" : "UNEXPECTED-EXIT",
                            impl == "stock" ? "(local baseline)" : ok ? "EQUIVALENT to stock" : "DIFFERS: " * join(why, " || "))
            println(line); flush(stdout); push!(rows, line)
            if !startswith(case, "M4-")
                ok2, why2 = compare_case(case, joinpath(FIX, "baseline", case), resultdir)
                l2 = @sprintf("%-22s %-7s vs fixtures/baseline (aarch64, 1.13.2): %s", case, impl,
                              ok2 ? "EQUIVALENT" : "differs: " * join(why2, " || "))
                gates["$case/$impl"] &= ok2
                println(l2); flush(stdout); push!(rows, l2)
            end
        end
    end
    open(io -> TOML.print(io, gates; sorted=true), joinpath(out, "gates.toml"), "w")
    write(joinpath(out, "validate.txt"), join(rows, "\n") * "\n")
end

# ---------------------------------------------------------------- time
function time_rounds(cases, out; rounds, impls, label, baseline, quiet_wait)
    csv = joinpath(out, "results.csv")
    isfile(csv) || write(csv, "label,round,case,cmd,args,impl,wall_s,maxrss_kib,exit,equivalent,load1,other_scopes,compile_ms,instantiate_ms,init_ms,main_ms\n")
    for r in 1:rounds
        batch_snapshot(out, "$label-r$r")
        quiet, l0, nscopes = wait_quiet(; max_wait = quiet_wait)
        println("round $r/$rounds  load $l0  fixed_affinity=true  ($(Libc.strftime("%H:%M:%S", time())))")
        order = circshift(impls, r - 1)
        for case in cases
            sc = case_sc(case)
            for impl in order
                resultdir = joinpath(out, "runs", label, "r$r", impl, case)
                prev = startswith(case, "M4-") && case != "M4-cold" ? joinpath(out, "runs", label, "r$r", impl, "M4-cold-keep") : ""
                rundir = setup_case(case, resultdir; prev)
                l = loadavg(); ns = length(other_heavy_scopes())
                res, layout = run_commands(case, rundir, impl; offline = true, commands = sc["commands"], sc)
                seal_case(case, rundir, resultdir, impl)
                exits = [x.exit for x in res]
                eq = if isempty(baseline)
                    exits == sc["expect_exit"]
                else
                    b = startswith(case, "M4-") ? joinpath(baseline, "stock", case) : joinpath(baseline, "stock", case)
                    exits == sc["expect_exit"] && first(compare_case(case, b, resultdir)) && isempty(layout)
                end
                for x in res
                    open(csv, "a") do io
                        @printf(io, "%s,%d,%s,%d,%s,%s,%.4f,%d,%d,%s,%.2f,%d,%s,%s,%s,%s\n", label, r, case, x.i,
                                replace(join(x.args, " "), "," => ";", rundir => "{rundir}"), impl, x.wall, x.rss_kib, x.exit, eq, x.load1, ns,
                                get(x.wasm_ms, "compile_only", ""), get(x.wasm_ms, "instantiate_only", ""),
                                get(x.wasm_ms, "init_only", ""), get(x.wasm_ms, "main_only", ""))
                    end
                end
                tot = sum(x.wall for x in res)
                @printf("  %-22s %-7s %7.3f s  rss %6.0f MiB  exits %s  eq=%s\n", case, impl, tot,
                        maximum(x.rss_kib for x in res) / 1024, string(exits), eq); flush(stdout)

            end
        end
    end
end

function startup(out; rounds, wasm)
    csv = joinpath(out, "startup.csv")
    isfile(csv) || write(csv, "round,what,wall_s,maxrss_kib,load1\n")
    jl = joinpath(Sys.BINDIR, Base.julia_exename())
    nativedepot = PKGWASM_CACHE_DEPOT * ":"
    cmds = [
        "julia -e 0" => `$jl --startup-file=no --history-file=no -e 0`,
        "julia + load Pkg" => `$jl --startup-file=no --history-file=no -e 'Base.require(Main, :Pkg)'`,
        "julia + load PkgWasm" => setenv(`$jl --startup-file=no --history-file=no -e "pushfirst!(LOAD_PATH, $(repr(PKGWASM_SRC))); Base.require(Main, :PkgWasm)"`,
                                         "JULIA_DEPOT_PATH" => nativedepot, "PATH" => ENV["PATH"]),
        "node -e 0" => `$NODE -e 0`,
        "node compile pkgwasm.wasm" => `$NODE -e "const fs=require('fs');const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));console.log(WebAssembly.Module.exports(m).length)" $wasm`,
    ]
    for r in 1:rounds, (what, c) in cmds
        batch_snapshot(out, "startup-r$r-$(findfirst(x -> first(x) == what, cmds))")
        wall, rss, code = timed(c, devnull, devnull)
        code == 0 || error("startup $what failed")
        open(io -> @printf(io, "%d,%s,%.4f,%d,%.2f\n", r, what, wall, rss, loadavg()), csv, "a")
        @printf("  startup %-40s %.3f s  %5.0f MiB\n", what, wall, rss / 1024)
    end
end

function parse_variants!(rest; wasm, nodeflags)
    VARIANTS["wasm"] = (wasm, nodeflags)
    while (i = findfirst(==("--variant"), rest)) !== nothing
        spec = rest[i + 1]; deleteat!(rest, i:i+1)
        name, rhs = split(spec, '='; limit = 2)
        file, flags = occursin("::", rhs) ? split(rhs, "::"; limit = 2) : (rhs, "")
        VARIANTS[String(name)] = (abspath(String(file)), String.(split(flags)))
    end
end

function main_bench(args)
    sub, rest = args[1], args[2:end]
    opt(flag, default) = (i = findfirst(==(flag), rest)) === nothing ? default : (v = rest[i + 1]; deleteat!(rest, i:i+1); v)
    if sub == "prepare-m4"
        prepare_m4(rest)
    elseif sub == "validate"
        out = abspath(opt("--out", ""))
        wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "pkgwasm.wasm")))
        impls = String.(split(opt("--impls", "stock,native,wasm"), ','))
        baseline = abspath(opt("--baseline", out))
        parse_variants!(rest; wasm, nodeflags = String[])
        "native" in impls && prime_pkgwasm(PKGWASM_SRC)
        validate(expand_cases(rest), out; impls, baseline)
    elseif sub == "time"
        out = abspath(opt("--out", ""))
        wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "pkgwasm.wasm")))
        rounds = parse(Int, opt("--rounds", "5"))
        impls = String.(split(opt("--impls", "stock,native,wasm"), ','))
        nodeflags = String.(split(opt("--nodeflags", "")))
        label = opt("--label", "base")
        baseline = opt("--baseline", "")
        quiet_wait = parse(Int, opt("--quiet-wait", "900"))
        mkpath(out)
        parse_variants!(rest; wasm, nodeflags)
        "native" in impls && prime_pkgwasm(PKGWASM_SRC)
        time_rounds(expand_cases(rest), out; rounds, impls, label, baseline, quiet_wait)
    elseif sub == "startup"
        out = abspath(opt("--out", ""))
        mkpath(out)
        prime_pkgwasm(PKGWASM_SRC)
        startup(out; rounds = parse(Int, opt("--rounds", "5")), wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "pkgwasm.wasm"))))
    else
        error("unknown subcommand $sub")
    end
end

main_bench(ARGS)
