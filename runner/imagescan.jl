# Find build-host strings in a WasmCodegen module (PLAN D8 relocation). Owner: L5 e2e.
#
#   julia runner/imagescan.jl <module.wasm> <marker>...      prints the markers found
#
# WasmCodegen serialises image Strings as GC byte arrays (packed i8), small ones as constant
# `array.new_fixed $T n (i32.const b)...` expressions, so the bytes are *not* contiguous in
# the binary and a raw byte search misses them. This decodes every such i8-valued constant
# array via Binaryen's `wasm-dis` and searches those strings as well as the raw module
# bytes (data segments).
#
# Scope (review-4): recognises the array type forms Binaryen 132 prints for ordinary packed-i8
# arrays ((array [mut] i8), (sub [final] [$parent] ...)), which is what WasmCodegen emits
# (layout.jl ArrayType(FieldType(storage, true))). It is not a full type parser: e.g. `shared`
# arrays are not recognised. An empty scan is evidence for these representations only; the
# relocation test's behavioural S-add@cache-key case does not depend on it.

const WASM_DIS = let p = joinpath(@__DIR__, "..", "repos", "npm-tools", "node_modules", ".bin", "wasm-dis")
    isfile(p) ? p : "wasm-dis"
end

# All byte strings of constant byte arrays in the module, plus the raw module bytes.
# Only arrays whose type has a packed i8 element are decoded; each `i32.const` operand is
# stored as its low 8 bits (wasm packed-field semantics), so any i32 value is accepted and
# truncated (review-3 #13). Arrays of other element types are not byte strings.
function image_byte_strings(wasm::AbstractString)
    found = Vector{UInt8}[read(wasm)]
    text = read(pipeline(`$WASM_DIS $wasm`; stderr = devnull), String)
    i8types = Set{String}()
    for m in eachmatch(r"\(type (\$\S+) (?:\(sub (?:final )?(?:\$\S+ )?)?\(array (?:\(mut i8\)|i8)\)", text)
        push!(i8types, m.captures[1])
    end
    lines = split(text, '\n')
    i = 1
    while i <= length(lines)
        m = match(r"\(array\.new_fixed (\$\S+) (\d+)\s*$", lines[i])
        i += 1
        (m === nothing || !(m.captures[1] in i8types)) && continue
        n = parse(Int, m.captures[2])
        buf = UInt8[]
        j = i
        while length(buf) < n && j <= length(lines)
            c = match(r"^\s*\(i32\.const (-?\d+)\)\s*$", lines[j])
            c === nothing && break          # non-constant operand: not a literal string
            push!(buf, UInt8(parse(Int, c.captures[1]) & 0xff))
            j += 1
        end
        length(buf) == n && n > 0 && push!(found, buf)
    end
    return found
end

function scan_markers(wasm::AbstractString, markers)
    strs = image_byte_strings(wasm)
    hay = join((String(copy(s)) for s in strs), '\0')
    return sort!(unique!([m for m in markers if !isempty(m) && occursin(m, hay)]))
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 2 || (println(stderr, "usage: imagescan.jl <module.wasm> <marker>..."); exit(2))
    foreach(println, scan_markers(ARGS[1], ARGS[2:end]))
end
