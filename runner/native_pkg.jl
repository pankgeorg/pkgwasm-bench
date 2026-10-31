# Native command driver: the native twin of `pkgwasm_main` (PLAN D5).
#
#   julia --startup-file=no runner/native_pkg.jl <cmd> [pkgs...]
#
# cmd ∈ add, develop, rm, resolve, instantiate, status, gc (gc [-v|--verbose] [--all]), registry (D15: registry <add|rm|update|status> [regs];
# D14: add/develop with arguments other than package names, e.g. `url#rev`, go through the Pkg REPL's
# syntax, as PkgWasm's driver parses them). Uses stock Pkg unless the env var
# PKGWASM_NATIVE_IMPL=PkgWasm, in which case the PkgWasm fork at PKGWASM_NATIVE_PATH
# (a checkout/worktree of src/PkgWasm.jl) is loaded instead and its own `pkgwasm_init` /
# `pkgwasm_main(args)` entry points run (if it defines them).
#
# Environment (depot, project, server, Pkg knobs) comes from the caller, exactly as the
# Wasm runner passes it through WASI. Exit code: 0 on success, 1 on a reported error
# (error text printed with `showerror` to stderr and also written to $PKGWASM_ERROR_FILE
# if set, for runner/compare.jl).

const IMPL = get(ENV, "PKGWASM_NATIVE_IMPL", "Pkg")

const P = if IMPL == "Pkg"
    Base.require(Main, :Pkg)
elseif IMPL == "PkgWasm"
    let path = get(ENV, "PKGWASM_NATIVE_PATH", "")
        isdir(path) || error("PKGWASM_NATIVE_PATH must point at a PkgWasm checkout (got $(repr(path)))")
        pushfirst!(LOAD_PATH, path)
        Base.require(Main, :PkgWasm)
    end
else
    error("PKGWASM_NATIVE_IMPL must be Pkg or PkgWasm (got $(repr(IMPL)))")
end

function run_cmd(args::Vector{String})
    isempty(args) && throw(ArgumentError("usage: native_pkg.jl <add|rm|resolve|instantiate|status> [pkgs...]"))
    cmd, pkgs = args[1], args[2:end]
    if (cmd == "add" || cmd == "develop") && !all(p -> occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", p), pkgs)
        # D14: the REPL's package syntax (url, path, #rev, :subdir), as `pkg> add ...`
        isdefined(P.REPLMode, :PRINTED_REPL_WARNING) && (P.REPLMode.PRINTED_REPL_WARNING[] = true)
        P.REPLMode.pkgstr(cmd * " " * join(pkgs, " "))
    elseif cmd == "add"
        isempty(pkgs) && throw(ArgumentError("add needs at least one package"))
        P.add(pkgs)
    elseif cmd == "develop"
        isempty(pkgs) && throw(ArgumentError("develop needs at least one package"))
        P.develop(pkgs)
    elseif cmd == "rm"
        isempty(pkgs) && throw(ArgumentError("rm needs at least one package"))
        P.rm(pkgs)
    elseif cmd == "resolve"
        isempty(pkgs) || throw(ArgumentError("resolve takes no packages"))
        P.resolve()
    elseif cmd == "instantiate"
        isempty(pkgs) || throw(ArgumentError("instantiate takes no packages"))
        P.instantiate()
    elseif cmd == "status"
        isempty(pkgs) || throw(ArgumentError("status takes no packages"))
        P.status()
    elseif cmd == "gc"
        # `gc [-v|--verbose] [--all]`, as the Pkg REPL's gc (PkgWasm's driver takes the same options)
        isdefined(P.REPLMode, :PRINTED_REPL_WARNING) && (P.REPLMode.PRINTED_REPL_WARNING[] = true)
        P.REPLMode.pkgstr(join(["gc"; pkgs], " "))
    elseif cmd == "registry"
        # D15: `registry <add|rm|update|status> [regs...]`, as the Pkg REPL registry mode
        # (pkg-fork's syntax; PkgWasm itself goes through pkgwasm_main)
        # (only the REPL-in-a-script warning is suppressed: PkgWasm's driver doesn't print it)
        isdefined(P.REPLMode, :PRINTED_REPL_WARNING) && (P.REPLMode.PRINTED_REPL_WARNING[] = true)
        P.REPLMode.pkgstr("registry " * join(pkgs, " "))
    else
        throw(ArgumentError("unknown command $(repr(cmd))"))
    end
    return nothing
end

function main(args)
    try
        run_cmd(args)
        return 0
    catch e
        msg = sprint(showerror, e)
        print(stderr, msg)
        println(stderr)
        errfile = get(ENV, "PKGWASM_ERROR_FILE", "")
        isempty(errfile) || write(errfile, msg)
        return 1
    end
end

# PkgWasm's own entry points (D5), when the fork has them: the same lifecycle as the Wasm
# runner (init, and main only if init returned 0), natively.
function main_entry(args)
    st = Int(P.pkgwasm_init())
    st == 0 || return st
    return Int(P.pkgwasm_main(args))
end

exit(IMPL == "PkgWasm" && isdefined(P, :pkgwasm_main) ? main_entry(ARGS) : main(ARGS))
