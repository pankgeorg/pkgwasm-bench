# G3 ledger deltas (owner: L5 e2e). Compares a G3 build with lanes/g3-diagnostics.md.
#
#   julia runner/g3-delta.jl <codegen report> <verifier report> [ledger.md]
#   julia runner/g3-delta.jl --rows <verifier report>      (V-row markdown table, owner suggestions)
#
# <codegen report>:  build.jl report of a trim=:safe, verify=:warn build (its `diagnostics`)
# <verifier report>: build.jl report of a --g3 build (its `verifier_report`)
# Prints, for each side, the ledger rows not seen any more (CLOSED, incl. rows already marked
# DONE) and the build's entries that have no ledger row (NEW: to be reported to the
# coordinator). Row identity: codegen = MethodInstance + reason (first 150 chars, whitespace
# normalised); verifier = error message + innermost frame without its file:line.
# Exit 0 iff there are no NEW rows.

import TOML

norm(x) = replace(strip(String(x)), r"\s+" => " ")
cg_key(mi, why) = norm(first(mi, 150)) * " || " * norm(first(why, 150))
# frame "f(args) @ Mod src/file.jl:123" -> "f(args) @ Mod" (locations move with edits)
frame_key(fr) = norm(replace(fr, r" @ (\S+) \S+$" => s" @ \1", "`" => ""))
# (the ledger cuts long frames at 160 chars, location included: compare the first 100 chars of
# the location-stripped frame, which are the same whether or not the location was cut off)
vf_key(msg, fr) = norm(first(msg, 140)) * " || " * first(frame_key(fr), 100)

function build_codegen(report)
    keys = String[]
    for d in get(TOML.parsefile(report), "diagnostics", String[])
        mi, why = split(d, " => "; limit = 2)
        push!(keys, cg_key(replace(mi, "MethodInstance for " => ""),
                           replace(first(split(why, "\n")), "WasmCodegen: unsupported: " => "")))
    end
    return keys
end

# The full verifier text: the separate file build.jl writes (verifier_report_file), else the
# report's inline field (older reports; may be truncated — then the count check below fails).
function verifier_text(report)
    r = TOML.parsefile(report)
    f = get(r, "verifier_report_file", "")
    t = isempty(f) ? get(r, "verifier_report", "") : read(f, String)
    n = get(r, "verifier_errors", nothing)
    found = length(collect(eachmatch(r"^Error #\d+:"m, t)))
    n === nothing || n == found || error("$report: verifier text has $found errors, the report counted $n (truncated?)")
    return t
end

# (number, message, innermost frame with location, its module) of every verifier error
function verifier_rows(report)
    rows = Tuple{Int, String, String, String}[]
    for b in split(verifier_text(report), r"(?m)^(?=Error #\d+:)")
        m = match(r"^Error #(\d+): ([^\n]*)", b)
        m === nothing && continue
        fr = match(r"\[1\] ([^\n]*)\n\s*@ (\S+) (\S+)", b)
        where = fr === nothing ? "?" : string(fr.captures[1], " @ ", fr.captures[2], " ",
                                              replace(fr.captures[3], r"^.*/src/" => "src/"))
        push!(rows, (parse(Int, m.captures[1]), replace(strip(m.captures[2]), "|" => "/"), where,
                     fr === nothing ? "?" : fr.captures[2]))
    end
    return rows
end

build_verifier(report) = [vf_key(msg, where) for (_, msg, where, _) in verifier_rows(report)]

# owner suggestion by the innermost frame's module
suggest_owner(mod) = startswith(mod, "PkgWasm") ? "pkg-fork/pkg-trim (PkgWasm)" :
                     mod in ("Base", "Core") ? "wcg-runtime (Base)" :
                     mod == "LibGit2" ? "pkg-fork (git, D14)" :
                     startswith(mod, "WasmCodegen") ? "wcg-runtime/wcg-sync ($mod)" : "coordinator ($mod)"

# markdown rows in the format of lanes/e2e/g3-verifier.md
function print_rows(io, report)
    println(io, "| V# | owner (suggested) | error | innermost frame |\n|---|---|---|---|")
    for (n, msg, where, mod) in verifier_rows(report)
        println(io, "| V", n, " | ", suggest_owner(mod), " | ", first(msg, 140), " | `", first(where, 160), "` |")
    end
end

# Rows are `| id | owner | `subject` | text | state |`; the text may itself contain " | ", so
# split from both ends. id all digits = codegen row (subject = MethodInstance, text = reason);
# any other id (V12, N665-62, ...) = verifier row (subject = innermost frame, text = error).
function ledger(path)
    cg, vf = Tuple{String,String,String}[], Tuple{String,String,String}[]   # (id, key, state)
    for l in eachline(path)
        startswith(l, "| ") && endswith(rstrip(l), "|") || continue
        cols = split(strip(rstrip(l), ['|', ' ']), " | ")
        length(cols) >= 5 || continue
        id, subject, state = strip(cols[1]), strip(cols[3]), strip(cols[end])
        text = join(cols[4:end-1], " | ")
        (startswith(subject, "`") && occursin(r"^[A-Za-z0-9-]+$", id)) || continue
        subject = strip(subject, '`')
        if occursin(r"^\d+$", id)
            push!(cg, (id, cg_key(subject, text), state))
        else
            push!(vf, (id, vf_key(text, subject), state))
        end
    end
    return cg, vf
end

function delta(io, side, rows, built)
    remaining = copy(built)
    closed = String[]
    for (id, key, state) in rows
        i = findfirst(==(key), remaining)
        i === nothing ? push!(closed, "$id ($state)") : deleteat!(remaining, i)
    end
    println(io, side, ": build ", length(built), ", ledger ", length(rows), ", closed ", length(closed),
            ", NEW ", length(remaining))
    isempty(closed) || println(io, "  CLOSED: ", join(closed, ", "))
    for k in remaining
        println(io, "  NEW: ", k)
    end
    return length(remaining)
end

function main(args)
    if length(args) == 2 && args[1] == "--rows"
        print_rows(stdout, args[2])   # the V-row table of a --g3 report
        return 0
    end
    length(args) >= 2 || (println(stderr, "usage: g3-delta.jl <codegen report> <verifier report> [ledger.md] | --rows <verifier report>"); return 2)
    led = length(args) >= 3 ? args[3] : joinpath(@__DIR__, "..", "lanes", "g3-diagnostics.md")
    cg, vf = ledger(led)
    n = delta(stdout, "codegen (trim=:safe)", cg, build_codegen(args[1]))
    n += delta(stdout, "verifier (verify=:error)", vf, build_verifier(args[2]))
    return n == 0 ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
