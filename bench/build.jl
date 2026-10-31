# Compile BenchIO.jl to Wasm, unoptimized (wasm-opt variants are applied by tools/wasmopt.sh):
#   $HEAVY $JULIA --heap-size-hint=8G --project=bench/env bench/build.jl <out.raw.wasm>
using WasmCodegen
const WC = WasmCodegen
include(joinpath(@__DIR__, "BenchIO.jl"))

out = abspath(ARGS[1])
entries = [WC.Entry(getfield(BenchIO, f), (); name = string(f))
           for f in (:pkgwasm_abi_version, :pkgwasm_init, :pkgwasm_main)]
hooks = isdefined(WC.Runtime, :sanitize_base_globals!) ? Any[WC.Runtime.sanitize_base_globals!] : Any[]
config = WC.Config(; optimize = nothing, pre_image_hooks = hooks)
t = @elapsed c = WC.compile(entries; config)
mkpath(dirname(out))
write(out, c.bytes)
diags = [string(mi, " => ", sprint(showerror, d)) for (mi, d) in c.cgm.diagnostics]
write(out * ".diagnostics.txt", join(diags, "\n"))
println("bench: $(length(c.bytes)) bytes raw, $(length(c.cgm.funcs)) functions, $(length(diags)) diagnostics, ",
        "exceptions $(c.cgm.exceptions), compiled in $(round(t; digits = 1)) s, maxrss $(round(Sys.maxrss() / 2^20)) MiB")
