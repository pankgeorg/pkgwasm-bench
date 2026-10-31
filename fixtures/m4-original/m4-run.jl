# M4 (lane s2-pkg): time `instantiate` of the ~30-package M4 manifest with PkgWasm modules,
# S1 (serial) vs S2 (8 download workers), direct and through a latency relay.
#
#   julia m4-run.jl --label L --wasm FILE --runner DIR [--delay MS] [--runs N] [--native]
#
# Each run: a fresh run dir with the frozen registry already installed (only package sources
# are downloaded), `instantiate` with JULIA_PKG_CONCURRENT_DOWNLOADS=8, wall time of the whole
# process. Then every installed source's git tree hash is checked against the manifest.
# Appends one TOML table per run to results.toml (raw runs kept, review-1 #9).
import TOML, Pkg

const M = @__DIR__
const W = "/home/pgeorgakopoulos/wasm-pkg"
const NODE = ENV["NODE"]

function opts(args)
    o = Dict{String, Any}("delay" => "0", "runs" => "3", "native" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--native"; o["native"] = true
        else o[lstrip(a, '-')] = args[i += 1]
        end
        i += 1
    end
    return o
end

function start(cmd)
    out = Pipe()
    p = run(pipeline(cmd; stdout = out, stderr = devnull); wait = false)
    close(out.in)
    line = readline(out)
    startswith(line, "LISTENING ") || error("no LISTENING line from $cmd: $(repr(line))")
    return p, String(line[length("LISTENING ")+1:end])
end

function check_sources(depot, manifest)
    bad = String[]
    n = 0
    for (name, entries) in TOML.parsefile(manifest)["deps"], e in entries
        th = get(e, "git-tree-sha1", nothing)
        th === nothing && continue
        n += 1
        slug = Base.version_slug(Base.UUID(e["uuid"]), Base.SHA1(hex2bytes(th)))
        dir = joinpath(depot, "packages", name, slug)
        got = isdir(dir) ? bytes2hex(Pkg.GitTools.tree_hash(dir)) : "missing"
        got == th || push!(bad, "$name: $got != $th")
    end
    return n, bad
end

function main(args)
    o = opts(args)
    srv, url = start(`$NODE $W/runner/pkgserver.mjs --offline --cache $M/cache --log $M/server-$(o["label"]).log`)
    relay = nothing
    if o["delay"] != "0"
        relay, url = start(`$NODE $M/relay.mjs $url $(o["delay"])`)
    end
    frozen_env = TOML.parsefile("$W/fixtures/frozen.toml")["env"]
    try
        for r in 1:parse(Int, o["runs"])
            rd = mktempdir(get(ENV, "TMPDIR", tempdir()); prefix = "m4-")
            for d in ("home", "tmp", "depot/registries", "project")
                mkpath(joinpath(rd, d))
            end
            run(`cp -a $M/prep-depot/registries/. $rd/depot/registries/`)
            for f in ("Project.toml", "Manifest.toml")
                cp(joinpath(M, "project", f), joinpath(rd, "project", f))
            end
            env = Dict{String, String}(String(k) => String(v) for (k, v) in frozen_env)
            merge!(env, Dict("HOME" => "$rd/home", "TMPDIR" => "$rd/tmp", "PWD" => rd,
                "JULIA_PROJECT" => "$rd/project", "JULIA_DEPOT_PATH" => "$rd/depot",
                "JULIA_PKG_SERVER" => url, "JULIA_PKG_CONCURRENT_DOWNLOADS" => "8"))
            cmd = if o["native"]
                env["PATH"] = ENV["PATH"]
                env["JULIA_DEPOT_PATH"] *= ":"
                setenv(`$(Base.julia_cmd()) --startup-file=no -e "import Pkg; Pkg.instantiate()"`, env; dir = rd)
            else
                flags = ["--wasm", o["wasm"], "--dir", rd]
                for k in sort!(collect(keys(env)))
                    push!(flags, "--env", "$k=$(env[k])")
                end
                setenv(`$NODE $(o["runner"])/pkgwasm.mjs $flags -- instantiate`; dir = rd)
            end
            log = joinpath(M, "$(o["label"])-run$r.log")
            t0 = time()
            p = run(pipeline(ignorestatus(cmd); stdout = log, stderr = log))
            dt = round(time() - t0; digits = 3)
            # the fixed cost (init, registry load, manifest check): `instantiate` again, nothing to download
            t1 = time()
            p2 = run(pipeline(ignorestatus(cmd); stdout = log * ".noop", stderr = log * ".noop"))
            dt_noop = round(time() - t1; digits = 3)
            n, bad = check_sources("$rd/depot", "$rd/project/Manifest.toml")
            rec = Dict("label" => o["label"], "run" => r, "delay_ms" => parse(Int, o["delay"]),
                       "exit" => p.exitcode, "seconds" => dt, "noop_exit" => p2.exitcode, "noop_seconds" => dt_noop, "download_seconds" => round(dt - dt_noop; digits = 3), "packages" => n, "hash_mismatches" => bad,
                       "wasm" => get(o, "wasm", "native"), "date" => string(Libc.strftime("%Y-%m-%dT%H:%M:%S", time())))
            open(io -> (println(io, "[[run]]"); TOML.print(io, rec; sorted = true); println(io)), joinpath(M, "results.toml"), "a")
            println("$(o["label"]) run $r: exit $(p.exitcode), $(dt) s (no-op $(dt_noop) s, exit $(p2.exitcode); difference $(round(dt - dt_noop; digits = 3)) s), $n packages, $(length(bad)) hash mismatches")
            rm(rd; recursive = true, force = true)
        end
    finally
        relay === nothing || kill(relay)
        kill(srv)
    end
end

main(ARGS)
