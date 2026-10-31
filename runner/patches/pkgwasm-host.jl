# PkgWasm project patch (PLAN.md D2; owner: lane L2 `wcg-event`): the Wasm implementations
# of the host seam `PkgWasm.Host` (fork file `src/Host.jl`, owned by lane L3), on top of the
# WasmCodegen runtime's `julia_io` events (`WasmCodegen.Runtime.Host`, ABI.md v2 §4).
#
# Applied with `Config(extra_patches=[this file])`: it is included in the patch sandbox, where
# `WasmCodegen` and `PkgWasm` are bound, after the default patches. It only (re)defines
# methods, which are deleted when the patch session ends.
#
# As natively, everything that leaves the seam is a `HostError` with the message prefixed by
# "download <url>: " / "decompress <src>: " (natively: `as_host_error`). By design, host
# failures carry the host's WASI errno (ECONNREFUSED, EHOSTUNREACH, ECANCELED, ELOOP, EILSEQ,
# ...), where natively every `Downloads.RequestError` is EIO; other errors are EIO, as natively.
# Response headers are as the server sent them (as libcurl). The partial-file handling
# (`dest * ".partial"`, renamed when complete, removed on failure, and on status >= 400 with
# `dest`) is `Runtime.Host.http_download`'s.

let RH = WasmCodegen.Runtime.Host
    @eval PkgWasm.Host begin
        # (`as_host_error`'s `sprint(showerror, err)` is a dynamic call in the closed world: the
        # runtime's `error_text` shows the exceptions it knows)
        function wasm_host_error(@nospecialize(err), what::String)
            err isa $RH.HostCallError && return HostError(Int(err.errno), string(what, ": ", err.msg))
            err isa HostError && return err
            return HostError(WASI_EIO, string(what, ": ", $RH.error_text(err)))
        end

        function download(url::String, dest::String, headers::Vector{Pair{String, String}})::Response
            head = try
                $RH.http_download(url, dest, headers)
            catch err
                throw(wasm_host_error(err, "download $url"))
            end
            return Response(head.status, head.url, head.headers)
        end

        # PLAN D13: the host's tags (ABI v3 `host_platform`) and this program's Julia version,
        # built from the tags, never by parsing a triplet (`platform_from_tags`), then made a
        # host platform as the native `HostPlatform()` is (`HostPlatform(p)`: its version tags
        # are upper bounds when artifacts are selected).
        function platform()::Base.BinaryPlatforms.Platform
            tags = try
                $RH.host_platform()
            catch err
                throw(wasm_host_error(err, "host platform"))
            end
            # (VERSION as a literal: printing a VersionNumber needs a regex, see below; the
            # build's Julia is the program's)
            return Base.BinaryPlatforms.HostPlatform(platform_from_tags(tags, $(string(VERSION))))
        end

        # `Platform(arch, os; tags..., julia_version)` (the host's julia_version ignored), built
        # without what a closed world cannot compile or Wasm cannot run yet:
        # - no keyword splat: the Dict method the keyword method calls, with its Dict{String,Any};
        # - the tags the constructor normalises as versions (`libgfortran_version`, ...) are
        #   added after it, as the constructor stores them, when they are plain (1 to 3 decimal
        #   components): `string(tryparse(VersionNumber, v))`, which needs a PCRE regex (in
        #   `tryparse`, and in printing a VersionNumber) until lane wcg-regex lands. Others go
        #   through the constructor (and need it).
        function platform_from_tags(tags::Vector{Pair{String, String}}, julia_version::String)
            arch = os = ""
            d = Dict{String, Any}()
            later = Pair{String, String}[]
            for (k, v) in tags
                k = lowercase(k)
                if k == "arch"
                    arch = v
                elseif k == "os"
                    os = v
                elseif k == "julia_version"
                    # (the host's is ignored)
                elseif k in ("validate_strict", "compare_strategies")
                    # (the constructor's keywords, not tags: an error there too, a TypeError)
                    throw(ArgumentError("host platform: $k is not a platform tag"))
                elseif k in ("libgfortran_version", "libstdcxx_version", "os_version")
                    n = plain_version(v)
                    n === nothing ? (d[k] = v) : push!(later, k => n)
                else
                    d[k] = v
                end
            end
            (isempty(arch) || isempty(os)) &&
                throw(HostError(WASI_EIO, "host platform: the host gave no arch or os"))
            d["julia_version"] = julia_version
            p = Base.BinaryPlatforms.Platform(arch, os, d)
            for (k, n) in later
                p[k] = n
            end
            return p
        end

        # "a", "a.b" or "a.b.c" (decimal) as `string(VersionNumber(v))` gives it ("a.b.c",
        # without leading zeros), or `nothing`
        function plain_version(v::String)
            parts = split(v, '.')
            1 <= length(parts) <= 3 || return nothing
            n = UInt32[0, 0, 0]
            for (i, p) in enumerate(parts)
                (!isempty(p) && all(isdigit, p) && sizeof(p) <= 9) || return nothing
                n[i] = parse(UInt32, p)
            end
            return string(n[1], '.', n[2], '.', n[3])
        end

        function decompress(src::String, dst::String)::Nothing
            try
                $RH.decompress(src, dst)
            catch err
                throw(wasm_host_error(err, "decompress $src"))
            end
            return nothing
        end
    end
end

# PkgWasm's seam `Host.init_runtime()::Nothing` (G2 preview blocker B1; PkgWasm 17f089822): called first in pkgwasm_init,
# before PkgWasm's globals; natively nothing, in Wasm the runtime's initialisation of Base's
# globals (ARGS, DEPOT_PATH, LOAD_PATH, the active project, the task RNG, the working
# directory), `WasmCodegen.Runtime.init_base_globals!` (lane wcg-sync, M1.3). Feature-detected
# while those land: without the seam nothing is defined (pkgwasm_init does not call it);
# with the seam but not the runtime function, it fails loudly instead of running the native
# no-op.
if isdefined(PkgWasm, :Host) && isdefined(PkgWasm.Host, :init_runtime)
    if isdefined(WasmCodegen.Runtime, :init_base_globals!)
        let init = WasmCodegen.Runtime.init_base_globals!
            @eval PkgWasm.Host init_runtime()::Nothing = ($init(); nothing)
        end
    else
        @eval PkgWasm.Host init_runtime()::Nothing =
            error("PkgWasm.Host.init_runtime: this WasmCodegen has no Runtime.init_base_globals! " *
                  "(lane wcg-sync M1.3): Base's globals cannot be initialised")
    end
end


# PkgWasm's seam `Host.std_stream(fd::Int32)` (G3 V2, V18, V39; pkg-fork): the stream that
# `StdStream` (Context IO) writes to. Natively `Base.stdout`/`Base.stderr` (bindings typed
# `IO`); in Wasm the runtime's concrete `HostStream(fd)`, so the writes dispatch statically
# (no `::IO` annotation here: the concrete type must stay visible to callers).
# Feature-detected: a PkgWasm without the seam builds as before.
if isdefined(PkgWasm, :Host) && isdefined(PkgWasm.Host, :std_stream)
    let HS = WasmCodegen.Runtime.HostStream
        @eval PkgWasm.Host std_stream(fd::Int32) = $HS(fd)
    end
end

# PLAN D4 update (artifacts): `Artifacts.parse_mapping` of a table (an `Overrides.toml` UUID
# entry; `load_overrides` runs on every `artifact_exists`) as a loop. The stdlib builds the
# Dict from a generator whose element type is the abstract `Pair{String}`, which WasmCodegen
# does not represent. Same values: each entry parsed by the stdlib's own methods.
let A = Base.maybe_root_module(Base.PkgId(Base.UUID("56f22d72-fd6d-98f1-02f0-08ddc0907c33"), "Artifacts"))
    A === nothing || @eval A function parse_mapping(mapping::Dict{String, Any}, name::String, override_file::String)
        d = Dict{String, Any}()
        for (k, v) in mapping
            d[k] = v isa String ? parse_mapping(v, name, override_file) :
                   v isa Dict{String, Any} ? parse_mapping(v, name, override_file) : nothing
        end
        return d
    end
end

# PLAN D4 update (artifacts): `hash(::Base.SHA1, ::UInt)` (Dict{SHA1} keys: artifact downloads,
# Artifacts' override table) without `jl_type_hash`. Base hashes `(SHA1, a.bytes)`, and
# `hash(SHA1, h)` is `hash(Base._jl_type_hash(SHA1), h)`; that type hash is taken here, at
# build time, so the values are exactly the native ones (also for Dicts in the image).
@eval Base hash(a::SHA1, h::UInt) = hash(($(Base._jl_type_hash(Base.SHA1)), a.bytes), h)
