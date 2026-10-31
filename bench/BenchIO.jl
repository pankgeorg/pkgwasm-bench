# IO workloads compiled to Wasm with WasmCodegen and run natively from the same source.
#
# Entry points (the names of PkgWasm's, so runner/pkgwasm.mjs runs the module unchanged):
#   pkgwasm_abi_version() -> Int32(3)
#   pkgwasm_init()        -> 0 after the runtime's Base globals (ARGS, ENV, cwd) are set
#   pkgwasm_main()        -> 0 ok, 1 error; ARGS = [workload, input, scratch, result file]
#
# Every workload writes `<key>=<value>` lines to the result file: values that must match
# between Wasm and native, and `ns=<elapsed>` (the workload alone, without startup), which
# the comparison skips.
module BenchIO

using SHA, Tar, TOML
import WasmCodegen

pkgwasm_abi_version()::Int32 = Int32(3)

function pkgwasm_init()::Int32
    WasmCodegen.Runtime.init_base_globals!()
    return Int32(0)
end

pkgwasm_main()::Int32 = run_workload(ARGS)

function run_workload(args::Vector{String})::Int32
    length(args) == 4 || return Int32(1)
    w, input, scratch, result = args[1], args[2], args[3], args[4]
    return try
        out = IOBuffer()
        t0 = time_ns()
        if w == "tar"
            w_tar(out, input, scratch)
        elseif w == "walk"
            w_walk(out, input)
        elseif w == "walkdir"
            w_walkdir(out, input)
        elseif w == "lines"
            w_lines(out, scratch)
        elseif w == "read"
            w_read(out, input)
        elseif w == "cp"
            w_cp(out, input, scratch)
        elseif w == "toml"
            w_toml(out, input)
        elseif w == "dir"
            w_dir(out, scratch)
        else
            error("unknown workload $w")
        end
        t1 = time_ns()
        print(out, "ns=", t1 - t0, "\n")
        write(result, take!(out))
        Int32(0)
    catch e
        write(result, "error=workload failed\n")
        Int32(1)
    end
end

hexs(b::Vector{UInt8}) = bytes2hex(b)

# ---------------------------------------------------------------- git tree hash
# A directory's git tree hash, as Pkg's GitTools.tree_hash computes it (SHA-1, symlinks
# as blobs of their target, executable bit kept, empty directories skipped).
function blob_hash(path::String)::Vector{UInt8}
    data = read(path)
    ctx = SHA1_CTX()
    update!(ctx, codeunits(string("blob ", length(data), "\0")))
    update!(ctx, data)
    return digest!(ctx)
end

function link_hash(target::String)::Vector{UInt8}
    ctx = SHA1_CTX()
    update!(ctx, codeunits(string("blob ", sizeof(target), "\0")))
    update!(ctx, codeunits(target))
    return digest!(ctx)
end

struct TreeEntry
    key::String      # git sort key: a directory's name sorts as name * "/"
    name::String
    mode::String
    hash::Vector{UInt8}
end

function tree_hash(root::String)::Vector{UInt8}
    entries = TreeEntry[]
    for name in readdir(root)
        name == ".git" && continue
        p = joinpath(root, name)
        st = lstat(p)
        if islink(st)
            push!(entries, TreeEntry(name, name, "120000", link_hash(readlink(p))))
        elseif isdir(st)
            h = tree_hash(p)
            isempty(h) && continue
            push!(entries, TreeEntry(string(name, "/"), name, "40000", h))
        else
            exe = (filemode(st) & 0o100) != 0
            push!(entries, TreeEntry(name, name, exe ? "100755" : "100644", blob_hash(p)))
        end
    end
    isempty(entries) && return UInt8[]
    sort!(entries; by = e -> e.key)
    body = IOBuffer()
    for e in entries
        write(body, e.mode, " ", e.name, "\0")
        write(body, e.hash)
    end
    b = take!(body)
    ctx = SHA1_CTX()
    update!(ctx, codeunits(string("tree ", length(b), "\0")))
    update!(ctx, b)
    return digest!(ctx)
end

# ---------------------------------------------------------------- workloads
# Tar.extract of every .tar in `input` (as PkgWasm unpacks a package), the git tree hash of
# the extracted tree, then Tar.create of it and Tar.tree_hash of the new tarball.
function w_tar(out::IOBuffer, input::String, scratch::String)
    n = 0
    for f in readdir(input)
        endswith(f, ".tar") || continue
        name = f[1:end-4]
        dst = joinpath(scratch, "x", name)
        Tar.extract(joinpath(input, f), dst; copy_symlinks = false)
        h1 = hexs(tree_hash(dst))
        newtar = joinpath(scratch, string(name, ".new.tar"))
        Tar.create(dst, newtar)
        h2 = open(Tar.tree_hash, newtar)
        print(out, name, "=", h1, " ", h2, " ", filesize(newtar), "\n")
        n += 1
    end
    print(out, "tarballs=", n, "\n")
end

mutable struct WalkStats
    files::Int
    dirs::Int
    links::Int
    bytes::Int
    modes::UInt
end

# readdir recursion with stat + lstat of every entry (the metadata pattern of Pkg's
# tree hashing and gc); names are digested in walk order (readdir is sorted).
function walk!(s::WalkStats, ctx::SHA256_CTX, dir::String)
    for name in readdir(dir)
        p = joinpath(dir, name)
        update!(ctx, codeunits(p))
        ls = lstat(p)
        if islink(ls)
            s.links += 1
            continue
        end
        st = stat(p)
        s.modes = xor(s.modes, UInt(filemode(st)))
        if isdir(st)
            s.dirs += 1
            walk!(s, ctx, p)
        else
            s.files += 1
            s.bytes += filesize(st)
        end
    end
end

function print_walk(out::IOBuffer, s::WalkStats, ctx::SHA256_CTX)
    print(out, "files=", s.files, "\ndirs=", s.dirs, "\nlinks=", s.links, "\nbytes=", s.bytes,
          "\nmodes=", s.modes, "\nnames=", hexs(digest!(ctx)), "\n")
end

function w_walk(out::IOBuffer, input::String)
    s = WalkStats(0, 0, 0, 0, UInt(0))
    ctx = SHA256_CTX()
    update!(ctx, codeunits(input))   # (paths below are digested relative to the same root)
    walk!(s, ctx, input)
    print_walk(out, s, ctx)
end

# Base.walkdir (a Channel fed by a task) with stat + lstat of every file
function w_walkdir(out::IOBuffer, input::String)
    s = WalkStats(0, 0, 0, 0, UInt(0))
    ctx = SHA256_CTX()
    for (root, dirs, files) in walkdir(input)
        s.dirs += length(dirs)
        for f in files
            p = joinpath(root, f)
            update!(ctx, codeunits(p))
            ls = lstat(p)
            if islink(ls)
                s.links += 1
                continue
            end
            st = stat(p)
            s.modes = xor(s.modes, UInt(filemode(st)))
            s.files += 1
            s.bytes += filesize(st)
        end
    end
    print_walk(out, s, ctx)
end

# 100k short lines with println, each a small write on the stream
function w_lines(out::IOBuffer, scratch::String)
    f = joinpath(scratch, "lines.txt")
    open(f, "w") do io
        for i in 1:100_000
            println(io, "line ", i, " of the small-write benchmark")
        end
    end
    print(out, "size=", filesize(f), "\nsha256=", hexs(open(sha256, f)), "\n")
end

# read(path) of the whole file, then read! into a 1 MiB buffer chunk by chunk; SHA-256 of both
function w_read(out::IOBuffer, input::String)
    t0 = time_ns()
    data = read(input)
    h1 = hexs(sha256(data))
    t1 = time_ns()
    ctx = SHA256_CTX()
    buf = Vector{UInt8}(undef, 1 << 20)
    total = open(input) do io
        countbytes = 0
        left = filesize(io)
        while left > 0
            n = min(left, length(buf))
            if n == length(buf)
                read!(io, buf)
                update!(ctx, buf)
            else
                b = Vector{UInt8}(undef, n)
                read!(io, b)
                update!(ctx, b)
            end
            left -= n
            countbytes += n
        end
        countbytes
    end
    h2 = hexs(digest!(ctx))
    t2 = time_ns()
    print(out, "size=", length(data), "\nread_sha256=", h1, "\nreadbang_sha256=", h2, "\nreadbang_bytes=", total,
          "\nns_read=", t1 - t0, "\nns_readbang=", t2 - t1, "\n")
end

# recursive cp of a tree, then its git tree hash
function w_cp(out::IOBuffer, input::String, scratch::String)
    dst = joinpath(scratch, "copy")
    t0 = time_ns()
    cp(input, dst)
    t1 = time_ns()
    print(out, "tree=", hexs(tree_hash(dst)), "\nns_cp=", t1 - t0, "\n")
end

# TOML.parsefile of every Package.toml/Versions.toml/Deps.toml/Compat.toml below `input`
function w_toml(out::IOBuffer, input::String)
    s = Int[0, 0, 0]   # files, top-level keys, Versions.toml entries
    toml_walk!(s, input)
    print(out, "files=", s[1], "\nkeys=", s[2], "\nversions=", s[3], "\n")
end

function toml_walk!(s::Vector{Int}, dir::String)
    for name in readdir(dir)
        p = joinpath(dir, name)
        if isdir(p)
            toml_walk!(s, p)
        elseif name == "Package.toml" || name == "Versions.toml" || name == "Deps.toml" || name == "Compat.toml"
            d = TOML.parsefile(p)
            s[1] += 1
            s[2] += length(d)
            name == "Versions.toml" && (s[3] += length(d))
        end
    end
end

# mktempdir, 10k empty files in it, readdir, then recursive rm
function w_dir(out::IOBuffer, scratch::String)
    d = mktempdir(scratch)
    t0 = time_ns()
    for i in 1:10_000
        touch(joinpath(d, string("f", lpad(i, 5, '0'))))
    end
    t1 = time_ns()
    names = readdir(d)
    t2 = time_ns()
    rm(d; recursive = true)
    t3 = time_ns()
    ctx = SHA256_CTX()
    for n in names
        update!(ctx, codeunits(n))
    end
    print(out, "entries=", length(names), "\nnames=", hexs(digest!(ctx)), "\ngone=", !ispath(d),
          "\nns_create=", t1 - t0, "\nns_readdir=", t2 - t1, "\nns_rm=", t3 - t2, "\n")
end

end # module
