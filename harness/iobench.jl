# Timing harness for the bench/ IO workloads: BenchIO natively (cold: first call JIT-compiles;
# warm: the timed call after a warm-up call in the same process) vs in Wasm (runner/pkgwasm.mjs).
#
#   julia harness/iobench.jl prepare                  build bench/data (inputs; see below)
#   julia harness/iobench.jl time --out DIR --wasm FILE [--rounds 5] [--label L] [--nodeflags "..."]
#                                 [--impls native,native-warm,wasm] [WORKLOAD...]
#   julia harness/iobench.jl count --out DIR --wasm FILE [WORKLOAD...]
#       one instrumented Wasm run per workload with tools/countcalls.mjs (host-call counts)
#
# Each run gets a fresh scratch dir; its result file must match the native (cold) result of the
# same round, `ns*` keys (timers) excepted. Rows go to DIR/io.csv.

using Printf, TOML
const ROOT = normpath(joinpath(@__DIR__, ".."))
const DATA = joinpath(ROOT, "bench", "data")
const SCRATCH = joinpath(ROOT, "bench", "scratch")
const NODE = get(ENV, "NODE", joinpath(homedir(), "wasm-pkg/repos/npm-tools/node24/node_modules/.bin/node"))
const JL = joinpath(Sys.BINDIR, Base.julia_exename())
const MY_CGROUP = strip(read("/proc/self/cgroup", String))
# Wasm implementations by name: "wasm" (--wasm/--nodeflags) and any `--variant NAME=FILE[::NODEFLAGS]`
const VARIANTS = Dict{String, Tuple{String, Vector{String}}}()

const WORKLOADS = [
    "tar" => joinpath(DATA, "tars"),
    "walk" => joinpath(DATA, "depot"),
    "walkdir" => joinpath(DATA, "depot"),
    "lines" => DATA,
    "read" => joinpath(DATA, "big.bin"),
    "cp" => joinpath(DATA, "pkgs"),
    "toml" => joinpath(DATA, "depot", "registries", "General"),
    "dir" => DATA,
]

function prepare()
    mkpath(DATA)
    fix = joinpath(ROOT, "fixtures")
    # package tarballs of fixtures/cache, decompressed (Pkg decompresses on the host, then Tar.extract)
    tars = mkpath(joinpath(DATA, "tars"))
    for (dir, _, files) in walkdir(joinpath(fix, "cache", "package")), f in files
        m = match(r"^([0-9a-f]{40})\.(zst|gz)$", f)
        m === nothing && continue
        dst = joinpath(tars, string(basename(dir), "-", m.captures[1][1:8], ".tar"))
        isfile(dst) && continue
        js = m.captures[2] == "zst" ? "zstdDecompressSync" : "gunzipSync"
        run(`$NODE -e "const z=require('zlib'),fs=require('fs');fs.writeFileSync(process.argv[2], z.$js(fs.readFileSync(process.argv[1])))" $(joinpath(dir, f)) $dst`)
    end
    # a populated depot: the unpacked frozen General registry + the M4 packages
    depot = joinpath(DATA, "depot")
    if !isdir(depot)
        run(`cp -a $(joinpath(fix, "initial", "registry", "depot")) $depot`)
        m4pk = joinpath(ROOT, "out", "validate", "stock", "M4-cold", "depot", "packages")
        isdir(m4pk) && run(`cp -a $m4pk $(joinpath(depot, "packages"))`)
    end
    # a package tree for cp: the M4 packages
    pk = joinpath(DATA, "pkgs")
    isdir(pk) || run(`cp -a $(joinpath(depot, "packages")) $pk`)
    # 100 MiB of incompressible bytes
    big = joinpath(DATA, "big.bin")
    if !isfile(big) || filesize(big) != 100 * 2^20
        open(big, "w") do io
            x = UInt64(0x9e3779b97f4a7c15)
            buf = Vector{UInt64}(undef, 2^17)
            for _ in 1:100
                for i in eachindex(buf)
                    x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17   # xorshift64
                    buf[i] = x
                end
                write(io, buf)
            end
        end
    end
    for (w, p) in WORKLOADS
        println(rpad(w, 8), p, ispath(p) ? "" : "  MISSING")
    end
end

loadavg() = parse(Float64, split(read("/proc/loadavg", String))[1])
other_heavy_scopes() = String[]
function wait_quiet(; max_wait=0, load_max=80)
    return (true, loadavg())
end
function batch_snapshot(out, tag)
    open(joinpath(out, "load-$tag.txt"), "w") do io
        run(pipeline(`uptime`; stdout=io))
        run(pipeline(`/bin/sh -c "top -bn1 | head -20"`; stdout=io))
    end
end

function timed(cmd::Cmd, so, se)
    tf = tempname()
    wrapped = Cmd(Cmd(["/usr/bin/time", "-f", "%M %e", "-o", tf, cmd.exec...]); env = cmd.env, dir = cmd.dir)
    t0 = time_ns()
    p = run(pipeline(ignorestatus(wrapped); stdout = so, stderr = se))
    wall = (time_ns() - t0) / 1e9
    line = split(strip(last(readlines(tf))))
    rm(tf; force = true)
    return wall, parse(Int, line[1]), p.exitcode
end

function workload_cmd(impl, w, input, scratch, result; preload = String[], env = Dict{String, String}())
    if startswith(impl, "wasm")
        wasm, nodeflags = VARIANTS[impl]
        c = `$NODE $preload $nodeflags $(joinpath(ROOT, "runner", "pkgwasm.mjs")) --wasm $wasm --dir $DATA --dir $scratch --dir $(dirname(result))
             --env HOME=$scratch --env TMPDIR=$scratch --env PWD=$scratch --timing $(result * ".timing.json") -- $w $input $scratch $result`
    else
        c = `$JL --startup-file=no --history-file=no --project=$(joinpath(ROOT, "bench", "env")) $(joinpath(ROOT, "bench", "native.jl")) $w $input $scratch $result`
        impl == "native-warm" && (env = merge(env, Dict("BENCH_WARM" => "1")))
    end
    e = Dict{String, String}("PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "TMPDIR" => scratch, "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", ""))
    return setenv(c, merge(e, env); dir = scratch)
end

read_result(f) = isfile(f) ? Dict(String(k) => String(v) for (k, v) in (split(l, '=', limit = 2) for l in eachline(f) if occursin('=', l))) :
                             Dict("error" => "no result file")
checked(d) = Dict(k => v for (k, v) in d if !startswith(k, "ns"))

fresh_scratch(tag) = (d = joinpath(SCRATCH, tag); rm(d; recursive = true, force = true); mkpath(d); mkpath(joinpath(d, "x")); d)

function time_rounds(names, out; rounds, impls, label, quiet_wait)
    csv = joinpath(out, "io.csv")
    isfile(csv) || write(csv, "label,round,workload,impl,wall_s,maxrss_kib,exit,equivalent,ns,ns_detail,load1,other_scopes,compile_ms,instantiate_ms\n")
    for r in 1:rounds
        batch_snapshot(out, "$label-r$r")
        quiet, l0 = wait_quiet(; max_wait = quiet_wait)
        println("round $r/$rounds  load $l0  fixed_affinity=true")
        for w in names
            input = Dict(WORKLOADS)[w]
            ref = nothing
            order = circshift(impls, r - 1)
            results = Dict{String, Dict{String, String}}()
            rows = Any[]
            for impl in order
                scratch = fresh_scratch("$label-$impl")
                impl == "native-warm" && mkpath(joinpath(scratch, "warm"))
                result = joinpath(out, "results", "$label-$w-$impl-r$r.txt")
                mkpath(dirname(result))
                l = loadavg(); ns = length(other_heavy_scopes())
                wall, rss, code = timed(workload_cmd(impl, w, input, scratch, result),
                                        result * ".stdout", result * ".stderr")
                d = read_result(result)
                results[impl] = d
                t = Dict{String, Float64}()
                tj = result * ".timing.json"
                if isfile(tj)
                    m = match(r"\"ms\":\{([^}]*)\}", read(tj, String))
                    m === nothing || for kv in split(m.captures[1], ','); k, v = split(kv, ':'); t[strip(k, '"')] = parse(Float64, v); end
                end
                push!(rows, (impl, wall, rss, code, d, l, ns, t))
                rm(scratch; recursive = true, force = true)
            end
            # reference: this round's native result, else the last stored native result
            reff = joinpath(ROOT, "out", "ioref", "$w.txt")
            if haskey(results, "native")
                mkpath(dirname(reff))
                write(reff, join(["$k=$v" for (k, v) in sort!(collect(checked(results["native"])))], "\n") * "\n")
            end
            refd = checked(read_result(reff))
            for (impl, wall, rss, code, d, l, ns, t) in rows
                eq = code == 0 && !haskey(d, "error") && checked(d) == refd
                detail = join(["$k:$v" for (k, v) in sort!(collect(d)) if startswith(k, "ns_")], ";")
                open(csv, "a") do io
                    @printf(io, "%s,%d,%s,%s,%.4f,%d,%d,%s,%s,%s,%.2f,%d,%s,%s\n", label, r, w, impl, wall, rss, code, eq,
                            get(d, "ns", ""), detail, l, ns, get(t, "compile_only", ""), get(t, "instantiate_only", ""))
                end
                nsv = tryparse(Int, get(d, "ns", ""))
                @printf("  %-8s %-12s wall %7.3f s  op %8s  rss %5.0f MiB  exit %d  eq=%s%s\n", w, impl, wall,
                        nsv === nothing ? "-" : @sprintf("%.3f s", nsv / 1e9), rss / 1024, code, eq,
                        haskey(d, "error") ? "  error=" * d["error"] : "")
            end
        end
    end
end

function count_calls(names, out; wasm)
    for w in names
        input = Dict(WORKLOADS)[w]
        scratch = fresh_scratch("count")
        result = joinpath(out, "counts", "$w.txt"); mkpath(dirname(result))
        cf = joinpath(out, "counts", "$w.calls.json")
        cmd = workload_cmd("wasm", w, input, scratch, result;
                           preload = ["--import", joinpath(ROOT, "tools", "countcalls.mjs")], env = Dict("COUNT_CALLS_FILE" => cf))
        wall, rss, code = timed(cmd, result * ".stdout", result * ".stderr")
        println("  $w: exit $code, $(isfile(cf) ? read(cf, String) : "no counts")")
        rm(scratch; recursive = true, force = true)
    end
end

function validate(names, out; impls)
    gates = Dict{String, Any}()
    for w in names
        ref = checked(read_result(joinpath(ROOT, "out", "ioref", "$w.txt")))
        for impl in impls
            scratch = fresh_scratch("validate-$(basename(out))-$impl")
            impl == "native-warm" && mkpath(joinpath(scratch, "warm"))
            result = joinpath(out, "$w-$impl.txt")
            c = workload_cmd(impl, w, Dict(WORKLOADS)[w], scratch, result)
            proc = run(pipeline(ignorestatus(c); stdout=result*".stdout", stderr=result*".stderr"))
            d = checked(read_result(result))
            if impl == "native" && proc.exitcode == 0 && !haskey(d, "error")
                ref = d
                reff = joinpath(ROOT, "out", "ioref", "$w.txt")
                mkpath(dirname(reff)); cp(result, reff; force=true)
            end
            ok = proc.exitcode == 0 && !haskey(d, "error") && d == ref
            gates["$w/$impl"] = ok
            println("$w $impl exit=$(proc.exitcode) equivalent=$ok result=$d"); flush(stdout)
            rm(scratch; recursive=true, force=true)
        end
    end
    open(io -> TOML.print(io, gates; sorted=true), joinpath(out, "gates.toml"), "w")
end

function main(args)
    sub, rest = args[1], args[2:end]
    opt(flag, default) = (i = findfirst(==(flag), rest)) === nothing ? default : (v = rest[i + 1]; deleteat!(rest, i:i+1); v)
    if sub == "prepare"
        prepare()
        return
    end
    out = abspath(opt("--out", "")); mkpath(out)
    wasm = abspath(opt("--wasm", joinpath(ROOT, "out", "bench.wasm")))
    names = isempty(rest) ? first.(WORKLOADS) : rest
    if sub in ("time", "validate")
        rounds = parse(Int, opt("--rounds", "5"))
        impls = String.(split(opt("--impls", "native,native-warm,wasm"), ','))
        nodeflags = String.(split(opt("--nodeflags", "")))
        label = opt("--label", "base")
        quiet_wait = parse(Int, opt("--quiet-wait", "900"))
        VARIANTS["wasm"] = (wasm, nodeflags)
        while (i = findfirst(==("--variant"), rest)) !== nothing
            spec = rest[i + 1]; deleteat!(rest, i:i+1)
            name, rhs = split(spec, '='; limit = 2)
            file, flags = occursin("::", rhs) ? split(rhs, "::"; limit = 2) : (rhs, "")
            VARIANTS[String(name)] = (abspath(String(file)), String.(split(flags)))
        end
        names = isempty(rest) ? first.(WORKLOADS) : rest
        sub == "validate" ? validate(names, out; impls) : time_rounds(names, out; rounds, impls, label, quiet_wait)
    elseif sub == "count"
        VARIANTS["wasm"] = (wasm, String[])
        count_calls(names, out; wasm)
    end
end

main(ARGS)
