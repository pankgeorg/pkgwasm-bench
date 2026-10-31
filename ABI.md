# PkgWasm host ABI, v3 (frozen for S1)

v3 (2026-10-28 18:00) = v2 + `julia_io.host_platform` (user decision: the host runtime answers `HostPlatform()`; no build-time platform constant). The `julia_regex` namespace (§4b) was appended to v3 at 18:50. v3 also gained `julia_io.path_symlink` (18:45; additive and imported on demand, so no version bump). `ABI_VERSION` is now **3**.

v2 (2026-10-28 15:50) supersedes v1 after Astra review-2 (#20–#28). Its changes are: lifecycle order, interest-filtered `poll` with readiness retirement, exact wire encoding, the handle state table, path validation, fstat semantics, and the Staging API. `ABI_VERSION` is now **2**.

The coordinator owns this file. Changes are made only by coordinator edit, which bumps `ABI_VERSION`, and every lane rebases after a change. The module exports `pkgwasm_abi_version() -> i32` returning `3`. The JS adapter refuses to run a module whose version differs.

## 1. Linear memory

- There is exactly **one memory**, index 0, exported as `"memory"`.
  - Initial size: **96 pages** (6 MiB).
  - It is never grown in S1. Running out of staging space throws a Julia `ErrorException("staging overflow")`.
  - Little-endian. Records use natural alignment. All offsets are **u32 values carried in i32**.
- The layout is owned by the Julia runtime (`WasmCodegen.Runtime.Staging`):

| Range | Use |
|---|---|
| `[0, 64 KiB)` | Reserved: null guard, plus ABI scratch (iovecs, out-params, `poll` ready list) at fixed offsets defined in `Staging` |
| `[64 KiB, 1 MiB)` | Path and record arena: a scoped bump allocator, reset at scope exit, try/finally-safe, nestable |
| `[1 MiB, 6 MiB)` | Data arena: IO chunks of at most 1 MiB, plus record buffers |

- **Lifetimes.**
  - Hosts **must copy** every input (paths, request records) out of linear memory before the import returns. No host keeps a view across calls.
  - JS recreates its `Uint8Array`/`DataView` on every call (`new Uint8Array(memory.buffer)`). Growth is not used in S1, but adapters must not cache the view anyway.
- **Pointers.** Linear offsets are **not** Julia `Ptr`s. Julia `Ptr` keeps WasmCodegen's (virtual address, owner) representation unchanged. The runtime moves bytes with explicit primitives:
  - `Staging.load8/16/32/64(off)` and `store8/16/32/64(off, v)`;
  - `copy_to_linear!(off, src::Union{Memory{UInt8},Vector{UInt8},String}, src_index, n)`;
  - `copy_from_linear!(dst, dst_index, off, n)`.
- Passive data segments for GC arrays must keep working alongside the memory.

### 1.1 Staging API (frozen; implemented by L1 in `WasmCodegen.Runtime.Staging`; L2 codes against it)

Offsets are `UInt32`, 0-based bytes. Julia indices are 1-based. Constants:

| Constant | Value | Use |
|---|---|---|
| `SCRATCH_OUT` | `0x0100` | 256 bytes; single-call out-params (nwritten, filestat buf ptr, …) |
| `SCRATCH_IOVEC` | `0x0200` | 256 bytes; up to 16 iovecs |
| `POLL_INTEREST` | `0x1000` | 4 KiB; up to 1024 i32 |
| `POLL_READY` | `0x2000` | 4 KiB; up to 1024 i32 |
| `RECORD_BASE` / `RECORD_END` | `0x10000` / `0x100000` | Record arena |
| `DATA_BASE` / `DATA_END` | `0x100000` / `0x600000` | Data arena |

Functions:

```julia
Staging.with_scope(f)            # saves both arena tops, runs f(), restores them in `finally` (exception-safe, nestable)
Staging.alloc_record(n; align=4)::UInt32   # within the current scope; throws ErrorException("staging overflow")
Staging.alloc_data(n; align=8)::UInt32     # n ≤ 1 MiB per call; same overflow rule
Staging.put_str!(off, s::Union{String,SubString{String}})::UInt32  # writes u32 len + bytes, returns next offset
Staging.put_u32!(off, v)::UInt32
Staging.get_u32(off)::UInt32 ; Staging.get_str(off)::Tuple{String,UInt32}   # value, next offset
Staging.load8/16/32/64(off) ; Staging.store8/16/32/64(off, v)
Staging.copy_to_linear!(off, src, src_index::Int, n::Int)
Staging.copy_from_linear!(dst, dst_index::Int, off, n::Int)
Staging.raw_path(s::String)::Tuple{UInt32,UInt32}   # (off, len) of raw bytes in the record arena of the current scope
```

The scratch regions are **not** scoped: they're valid only between building the arguments and returning from one import call. Never suspend, and never call another import, while a scratch region is in use. The one exception is that `poll` reads `POLL_INTEREST` and writes `POLL_READY` itself.

## 2. Import namespaces

Only these namespaces may appear in a module:

| Namespace | Use |
|---|---|
| `wasi_snapshot_preview1` | Standard p1 signatures (§3) |
| `julia_io` | Defined in §4 |
| `julia_regex` | Defined in §4b: Julia `Regex` (PCRE2 semantics) on the host's regex engine |
| `julia` | Legacy. Only `write_byte(i32,i32)` survives, as the panic path |

**Generic import ccall.** `ccall((:name, "wasi_snapshot_preview1" | "julia_io"), RT, (ArgT...), ...)` lowers to a Wasm import.
- `RT` and each `ArgT` must be `Int32`, `UInt32`, `Int64`, `UInt64` or `Cvoid`. Anything else is a compile error.
- Import identity is the (module, name) pair. The library string is no longer dropped for these two namespaces.
- The same rule applies to `julia_regex`. Every other library string keeps today's behaviour: `RUNTIME_CCALLS` by symbol, else unsupported.
- Only runtime code and runtime-installed patches use this. User and Pkg code never do.

## 3. `wasi_snapshot_preview1` subset

Standard WASI p1 signatures and errno numbering. The set used:
- `args_sizes_get`, `args_get`, `environ_sizes_get`, `environ_get`
- `clock_time_get`, `random_get`
- `fd_prestat_get`, `fd_prestat_dir_name`
- `fd_read`, `fd_write`, `fd_pread`, `fd_pwrite`, `fd_seek`, `fd_tell`, `fd_close`, `fd_sync`
- `fd_fdstat_get`, `fd_filestat_get`, `fd_filestat_set_size`, `fd_filestat_set_times`, `fd_readdir`
- `path_open`, `path_filestat_get`, `path_filestat_set_times`, `path_create_directory`, `path_remove_directory`, `path_unlink_file`, `path_rename`, `path_symlink`, `path_readlink`, `path_link`

Not used:
- `poll_oneoff`, because it blocks the Node event loop;
- `fd_read(0)`, stdin is unsupported in S1;
- `proc_exit`, because the reactor returns its exit code instead.

**Paths.**
- The runner preopens a fixed list of directories with **guest path == host path** (identity mapping, absolute).
- The Julia runtime resolves an absolute path to `(preopen fd, relative path)` by longest prefix, and keeps a virtual cwd (initial value from env `PWD`, else the first preopen).
- A path outside every preopen gives `ENOENT`, which surfaces as UV `ENOENT`.
- **Documented S1 divergence (18:59, wcg-sync review-2 #16):** `..` is resolved **lexically** (by the runtime's resolver, by Node's WASI and by `checkPath`), whereas native POSIX resolves `link/..` physically, through the symlink. Paths whose meaning depends on this differ from native. Pkg and Tar never build such paths. A physical resolver is post-S1 item P2.


**Host create modes (2026-10-29, perf2 P1c):** a host creates directories with mode 0777 and files with mode 0666, each less its process umask, when the guest does not ask for another mode (uvwasi and wasmtime-wasi do). The runtime relies on this and does not re-read and fix up the mode of a new directory or file created with Base's default modes. A host that creates with other defaults must say so; the runtime then needs its mode fix-up back.

## 4. `julia_io` (version 1)

**Conventions**
- Status returns are `i32`: `0` means OK and a positive value is a **WASI errno**.
- Handle returns are `i32`: `≥ 0` is a handle and `< 0` is a negated WASI errno.
- "Not ready" is `-EAGAIN` (WASI 6), or `6` in status position.
- **No import throws or rejects for expected failures** (network errors, HTTP failures, bad data, filesystem errors). They come back as error codes, with a message available through `errmsg`.

**Wire encoding (exact).**
- A record starts at a 4-byte-aligned offset, and inside it fields are **packed with no padding**. `str` = u32 byte length followed by that many bytes (UTF-8, not NUL-terminated); `u32` = 4 bytes little-endian, unaligned inside records.
- Standalone path arguments `(path_off, path_len)` are **raw bytes without a length prefix**: an absolute guest path, UTF-8, not NUL-terminated.
- Output buffers with `cap < 4` give `-EINVAL`.
- Shared byte-vector fixtures live in `runner/test/abi-vectors.json` (owned by L2): odd lengths, non-ASCII, empty strings, short buffers. Julia-side encoders are tested against the same vectors.

| Import | Signature | Semantics |
|---|---|---|
| `http_start` | `(spec_off i32, spec_len i32) -> i32 handle` | spec = `str method, str url, u32 n, (str name, str value)*n, u32 flags` (bit0 = follow redirects, max 10). There is no request body in v1. Starts the request; never blocks. |
| `http_head` | `(h, out_off, out_cap) -> i32` | Not ready: `-EAGAIN`. Ready: writes `u32 status, str final_url, u32 n, (str name, str value)*n` and returns the bytes written. If `out_cap` is too small, it writes the required u32 at `out_off` and returns `-ENOBUFS` (42). Transport failure: `-errno` (e.g. `-ECONNREFUSED`, `-EIO`). |
| `read` | `(h, off, len) -> i64` | `>0` bytes copied; `0` EOF; `-EAGAIN` not ready; `<0` `-errno`. Demand-driven: the adapter buffers at most **4 MiB** per handle (high-water mark) and pauses the stream reader above it. |
| `timer_start` | `(ns i64) -> i32 handle` | Becomes ready after `ns` nanoseconds. |
| `poll` | `(interest_off, n_interest, timeout_ns i64, out_off, cap) -> i32` | `interest` is an array of `n_interest` i32 handles (`n_interest ≥ 1`). It writes up to `cap` handles **from the interest set** that are ready and returns the count. Ready handles outside the interest set are ignored and stay ready. `timeout_ns = -1` waits indefinitely and `0` doesn't wait; it returns `0` on timeout. An interest handle that is unknown or closed is reported as ready, and its next call returns `-EBADF`. **This is the only suspending import.** It never rejects. |
| `errmsg` | `(h, out_off, cap) -> i32` | Copies the last error message for the handle (UTF-8, truncated to `cap`) and returns its length. `h = -1` means the last handle-less error. |
| `cancel` | `(h) -> i32` | Aborts an in-flight operation. Idempotent. |
| `close` | `(h) -> i32` | Releases the handle. Using a closed handle returns `-EBADF`. |
| `decompress` | `(src_off, src_len, dst_off, dst_len) -> i32 status` | **Synchronous in S1.** Paths are absolute guest paths. The format comes from magic bytes: gzip `1f 8b`, zstd `28 b5 2f fd`. Anything else gives `EILSEQ` (25). The output goes to `dst` + `".partial"` and is renamed to `dst` on success; on failure it is removed. Error text is available via `errmsg(-1)`. |
| `host_platform` | `(out_off, cap) -> i32` | Synchronous. Writes a record `u32 n, (str key, str value)*n` describing the **host machine**, and returns the bytes written. If `cap` is too small it gives `-ENOBUFS` with the required u32 at `out_off`. Keys use Base.BinaryPlatforms names: `arch` (`x86_64`, `aarch64`, `i686`, `armv7l`, `powerpc64le`, `riscv64`), `os` (`linux`, `macos`, `windows`, `freebsd`), `libc` (`glibc` or `musl`; Linux only), and optionally `libgfortran_version`, `cxxstring_abi`, `libstdcxx_version` and any other tag. Detected values come first. **Runner configuration overrides them key by key**, and supplies the tags the host can't detect: Node can't see `libgfortran_version`/`cxxstring_abi`/`libstdcxx_version`, so they're omitted unless configured. The module adds `julia_version` itself (its own `VERSION`); a host-provided `julia_version` is ignored. |
| `path_symlink` | `(target_off, target_len, link_off, link_len) -> i32 status` | Creates a symlink at the absolute guest path `link`, whose content is `target`. `target` is **raw data**: any string, absolute or escaping, never accessed, never validated, exactly like native `symlink(2)` and Base/Tar semantics. Only `link` goes through `checkPath` (no follow on the final component). Exists because Node's WASI `path_symlink` rejects absolute and escaping targets. Owner: L1. |
| `path_mode` | `(path_off, path_len, follow i32) -> i32` | Returns the POSIX `st_mode` (type and permission bits) of an absolute guest path, or `-errno`. It exists because p1 filestat has no permission bits. |
| `path_chmod` | `(path_off, path_len, mode i32) -> i32 status` | Real chmod. |

**Path validation for `julia_io` path imports** (`decompress`, `path_mode`, `path_chmod`): the adapter validates every path with one shared helper, `checkPath(path, {follow})`, in `julia_io.mjs` (owned by L2), against the **same preopen list the runner gives WASI** (passed to the adapter by L5's runner). Rules:
- reject non-absolute paths and NUL bytes;
- normalise `.` and `..` lexically;
- match a preopen on **path-component boundaries**;
- then `realpath` the deepest existing ancestor (the full path if `follow`) and require that it is still inside a preopen.

Failures return `-ENOTCAPABLE` (76) or status 76. Tests cover outside paths, `..` escapes and symlink escapes for each import.

**Readiness** is level-triggered, with explicit **retirement** (§4.1 has the full state table):
- `http`: ready iff the **next** `http_head` or `read` call would return something other than `-EAGAIN` **and** that result hasn't been delivered yet. Concretely:
  - the head is available and `http_head` hasn't yet succeeded on this handle (a successful `http_head` retires head readiness);
  - or body bytes are buffered;
  - or EOF hasn't been returned yet;
  - or a terminal error or cancellation hasn't been returned yet.
- `timer`: ready from the moment it fires until it's closed. Use the interest set to avoid spinning on it.

### 4.1 Handle states

| State | `http_head` | `read` | poll-ready | Transitions |
|---|---|---|---|---|
| pending | `-EAGAIN` | `-EAGAIN` | no | → head-ready, or → failed |
| head-ready | record (first time) | `-EAGAIN`, or bytes | yes, until head is taken and no bytes are buffered | → streaming |
| streaming | record (again; not ready-inducing) | bytes, or `-EAGAIN` | iff bytes are buffered | → eof, or → failed |
| eof | record | `0` (repeatable) | until the first `0` has been returned | — |
| failed / cancelled | `-errno` (`-ECANCELED` = -11 after cancel) | `-errno` | until the error has been returned once | — |
| closed | `-EBADF` | `-EBADF` | reported ready if in interest | — |

- `cancel(h)` moves any non-terminal state to **cancelled** and aborts the fetch. It is idempotent and returns 0. On a closed handle it returns `-EBADF`.
- `close(h)` aborts any pending activity, frees buffers and timers, and returns 0. A **second `close` returns `-EBADF`**: close is not idempotent.
- **Julia callers** close every handle, close every fd, and exit every `Staging` scope in `finally` blocks on all paths.

## 4b. `julia_regex` (version 1) — added to v3 at 18:50 from lane L6's proposal (`lanes/wcg-regex/abi-proposal.md`)

**Conventions.** As §4: handle/count returns are `i32`, `≥ 0` a value, `< 0` a negated WASI errno;
status returns `0` or a positive errno. No import throws or rejects for expected failures
(a bad pattern, an unsupported construct, no match, a bad offset). Unexpected exceptions become
`-EIO` from handle/count imports and positive `EIO` from status imports (`subject`, `free`), with the message kept for `errmsg`. Hosts copy every input out of linear memory before
returning and recreate views per call. Records use §4's wire encoding (packed, `u32` LE, `str` =
`u32` length + bytes). Offsets into the subject are **UTF-8 byte offsets** (as PCRE2's code units).

| Import | Signature | Semantics |
|---|---|---|
| `compile` | `(pat_off, pat_len, options u32, out_off, out_cap) -> i32 handle` | `pat` is the pattern's raw bytes (PCRE2 syntax, UTF-8 when `options` has `PCRE2_UTF`, else bytes). `options` are PCRE2 compile option bits as Base passes them. **Success:** a handle ≥ 0, and at `out` the record `u32 capture_count, u32 name_count, (u32 group, str name)*name_count`. **Pattern error** (a PCRE2 syntax error, or a construct the host cannot match with PCRE2's semantics): `-EINVAL`, and at `out` the record `u32 code, u32 offset, str message` (`code`: PCRE2's compile error number, or **900** for "valid PCRE2 the host does not support"; `offset`: byte offset in the pattern; `message`: PCRE2's text for PCRE2's errors). **Too small `out_cap`:** `-ENOBUFS` and the needed size as `u32` at `out` (if `out_cap ≥ 4`). `out_cap < 4`: `-EINVAL`. The same `(pattern, options)` may return the same handle again (handles are reference counted). |
| `subject` | `(off, len, append i32) -> i32 status` | Stages the subject bytes for the next `match`: `append = 0` starts a new subject, `1` appends (for subjects larger than one staging chunk). The staged subject becomes current at the next `match` and stays current for later `match` calls until another `subject`. Status import: returns `0`, or positive `EIO` (29) on an unexpected host failure (never a negative value). |
| `match` | `(h, start u32, options u32, out_off, out_cap) -> i32 rc` | Matches the current subject from byte offset `start` with PCRE2 match options `options` (as Base passes them: `NO_UTF_CHECK`, `ANCHORED`, `ENDANCHORED`, `NOTEMPTY_ATSTART`; also `NOTBOL`, `NOTEOL`, `NOTEMPTY`). **Match:** `rc ≥ 1` = 1 + the highest group set (PCRE2's rc), and at `out` `2·(capture_count+1)` `u32` byte offsets (start, end per group; `0xFFFFFFFF` = unset), always all of them. **No match:** `0`. `-EBADF`: unknown handle. `-EINVAL`: `start` beyond the subject. `out_cap < 4`: `-EINVAL`. `out_cap < 8·(capture_count+1)`: writes the needed size (u32) at `out` and returns `-ENOBUFS`; the staged subject is kept. `-ENOTSUP` (58): match options the host does not support (`PARTIAL_*`, `NO_START_OPTIMIZE`, ...), **or** a subject that is not valid UTF-8 (in UTF mode) with a pattern whose **static minimum match length is 0**. In that length a character, class or `.` counts 1; assertions, anchors and `\b` count 0; a sequence adds; an alternation takes its smallest branch; a repetition multiplies by its minimum count; a back reference counts its group's minimum length where the pattern requires the group to be set (group minimums through other groups' references too, to a fixed point; a reference to a group whose minimum depends on itself through references counts 0), else 0 (always 0 with `PCRE2_MATCH_UNSET_BACKREF`). This equals PCRE2's own `INFO_MINLENGTH == 0` on 338 of 340 corpus patterns; the 2 differences are conservative (wording made exact 21:45, review-3 #8; first added 19:32: PCRE2 JIT empty-match resumption around invalid bytes isn't reproducible; non-nullable patterns are exact on invalid UTF-8, 4.1M brute-force cases); message in `errmsg`. |
| `free` | `(h) -> i32 status` | Status import: drops one reference to the handle; positive `EBADF` if unknown, positive `EIO` on an unexpected host failure. (Julia never calls it in S1: Base frees patterns in finalizers, which do not run.) |
| `errmsg` | `(out_off, cap) -> i32 len` | The last error message (UTF-8, truncated to `cap`), and its length. |

**Semantics contract.** The host matches **as PCRE2 10.46 with Unicode 16** would for every
pattern it accepts: the same match, the same captures, the same offsets, for Base's default options
(`UTF | UCP | MATCH_INVALID_UTF | ALT_BSUX`, match `NO_UTF_CHECK`) and the `a/i/m/s/x` flags. A
pattern it cannot match that way it rejects (code 900, a message naming the construct); it never
matches approximately. Known exception (the only one; 19:00, after L6's corpus showed 389,729/389,729 cases equal): (a) a start offset that is not a character boundary as Julia's `String` indexing has them, i.e. inside a valid UTF-8 character, or inside an invalid sequence (a lead byte and the continuation bytes it claims). This is undefined in PCRE2 under `NO_UTF_CHECK` and Julia's indices never produce it; the host starts at the next character. Invalid-UTF-8 subjects are otherwise matched exactly as PCRE2 does (evidence: `runner/test/julia_regex.test.mjs`, `lanes/wcg-regex/investigation.md` §3).

**Lifetimes.** Handles live until `free` (in S1: the instance's life). The current subject is
replaced by the next `subject`; the host may keep the decoded form of the last subject and reuse it
when the same bytes are staged again.

### 4b.1 Error mapping on the Julia side (informative)

`Runtime.HostRegex` turns these into what Base expects of PCRE2: compile `-EINVAL` → `errorcode`
and `erroroffset` set and a null code (Base: `PCRE compilation error: <message> at offset <n>`, the
same text as natively for PCRE2's errors); `match` 0 → `PCRE2_ERROR_NOMATCH`, `-EINVAL` →
`PCRE2_ERROR_BADOFFSET`, any other negative → an error code whose message is
`Wasm regex (julia_regex): <errmsg>` (Base throws `PCRE.exec error: ...`).


<!-- §4c frozen 2026-10-29 by the coordinator from lanes/git-host/abi-proposal.md rev 3 (sha256 5827ce79), user decision to resume D14. Additive to v3: ABI_VERSION stays 3. -->
## §4c. `julia_io` process extension: `spawn`, `proc_status`, `proc_pipe`, `proc_kill`

**Purpose.** Base's process API in Wasm, on the host's processes. PkgWasm uses it for the git CLI (PLAN D14).

**Scope of native equivalence.** Native equivalence holds for a **POSIX host profile** (Linux, macOS) and **representable inputs**:
- NUL-free valid UTF-8 strings;
- unique, case-sensitive environment names;
- the supported stdio forms and Cmd settings (§B);
- the executable policy of §A.6.

A native input outside this scope fails **explicitly, before spawning**; it is never normalised silently. On other platforms `spawn` returns `-ENOTSUP` in preflight until an equivalent profile is specified (the Node adapter: on `win32`).

**Conventions.** §4's conventions apply, with one sign rule made explicit:
- handle/count imports return `≥ 0` or a negated WASI errno;
- the **status** import `proc_kill` returns `0` or a **positive** errno;
- the existing `close`/`cancel` keep §4.1's negative errors;
- an unexpected host failure becomes `EIO` in the sign of its return position;
- records start 4-byte aligned and are packed;
- inputs are copied before returning;
- no import throws or rejects for an expected failure.

Validation errors don't retire readiness and don't consume a one-shot `proc_pipe` transfer.

**Handle kinds.** These join §4's table, sharing its id space and `poll`:

| Kind | What | Imports |
|---|---|---|
| **proc** | a child process | `proc_status`, `proc_pipe`, `proc_kill`, `poll`, `errmsg`, `close`, `cancel` (→ `-ENOTSUP`) |
| **pipe** | the parent (readable) end of child fd 1 or 2 | `read`, `poll`, `errmsg`, `cancel`, `close` |

A call on a handle of the wrong kind returns `EBADF` in its return position's sign: `-EBADF` from handle/count imports and from `close`/`cancel`, `+EBADF` from `proc_kill`.

### A. Imports

| Import | Signature | Semantics |
|---|---|---|
| `spawn` | `(spec_off, spec_len) -> i32 handle` | Starts a child process; **never waits for the child**. **Preflight:** record parsing (§A.1), platform and authorization (§A.6) and `dir` validation complete before any resource is acquired. A preflight failure starts nothing and allocates no handle. Preflight errors: `-EINVAL` (record), `-ENOTCAPABLE` (not enabled, shut down, program not allowed, `dir` outside the preopens), `-ENOTSUP` (an unimplemented platform profile; the `detach` flag where unsupported; a host mode that cannot keep §A.1's exact environment). **Acquisition** (pipes, the process): a synchronous failure closes every acquired parent resource and returns its errno (`-EMFILE`, `-ENOENT`, …). **Start failures** a host only learns asynchronously (program not found or not executable, `EAGAIN` from the process table, …) are reported by `proc_status`. |
| `proc_status` | `(h, out_off, out_cap) -> i32` | `out_off` must be 4-byte aligned and `out_cap ≥ 12`, **checked in every state**, else `-EINVAL`. Results, **all repeatable**: `-EAGAIN` starting (the outcome is not known yet; only this); `0` running; `4` the start **failed**, writing `u32 errno` at `out_off` (`ENOENT`, `EACCES`, `ENOEXEC`, `EAGAIN`, `E2BIG`, …; message in `errmsg(h)`); `12` exited, writing `i64 exit_code, i32 term_signal` (packed, LE; `term_signal` is the POSIX signal number or 0; `exit_code` is 0 when signalled, as libuv). Any other negative result is a failure of the query itself (`-EBADF` for a handle that is not a proc). |
| `proc_pipe` | `(h, fd i32) -> i32 handle` | Transfers the pipe of child fd `fd` (1 or 2, stdio kind 2) to a new readable handle. It can be taken **once per fd**; otherwise, or for an fd that is not a pipe, `-EINVAL`. **Readable pipes are read by the host from `spawn` on**, so bytes, EOF and errors that arrive before `proc_pipe`, even after the exit, are kept and handed over. |
| `read` (§4) | `(h, off, len) -> i64` | On a readable pipe: §4's body semantics. `>0` bytes; `0` EOF (repeatable); `-EAGAIN` nothing buffered; `-errno` terminal (a premature close of the stream without EOF is `-EIO`); `-ECANCELED` after `cancel`. Terminal results are repeatable. `len = 0` gives `-EINVAL`. |
| `proc_kill` | `(h, signum i32) -> i32 status` | Sends POSIX signal `signum` as `uv_process_kill` (`0`: an existence/permission probe). `0` OK; `ESRCH` (71) when the process is not running (starting, failed, exited, or the kill raced its exit); `EPERM` or another errno for a failed kill; `EINVAL` for a signal the host doesn't know; `EBADF` for a handle that is not a proc. |

**`close` and `cancel` on the new kinds** (the existing imports):

| Call | proc | pipe |
|---|---|---|
| `close(h)` | Releases the handle; **the child keeps running** (as `uv_close` of a process handle). Its **untaken** pipes are destroyed: a writing child gets `EPIPE`/`SIGPIPE`. Pipes already transferred stay independently owned (§A.4). | Destroys the stream and frees its buffer. |
| `cancel(h)` | `-ENOTSUP` (use `proc_kill`) | Non-terminal → *cancelled*: buffered bytes discarded, stream aborted; `read` → `-ECANCELED`. **Terminal (eof, failed, cancelled): a no-op** that keeps buffered bytes, the original result and its retirement state. |

`close`/`cancel` on a closed or unknown handle returns `-EBADF`, as §4.1.

### A.1 The spawn record

```
u32 argc,  str argv[argc]
u32 envc,  str env[envc]
str dir
u32 flags
u32 nstdio, (u32 kind, str path)[nstdio]
```

| Field | Rule |
|---|---|
| `argc` | 1..4096 |
| `argv[0]` | non-empty: the program **selector** (§A.6) and the child's own `argv[0]`. The rest of `argv` is passed unchanged: raw data, never interpreted as paths |
| `envc`, `env` | ≤ 65536 entries `NAME=value`: `NAME` non-empty, without `=`, **no duplicate names**. The **actual** child environment is exactly this list, with nothing from the host. A host whose platform or library adds variables must suppress them (Node 24: `NODE_V8_COVERAGE`), or reject spawning with `ENOTSUP` in preflight |
| `dir` | the child's cwd: an **absolute** guest path validated by `checkPath` (follow). Empty is invalid outside test escapes (§F). (Julia resolves an empty or relative `Cmd.dir` against its virtual cwd before encoding.) A missing or non-directory `dir` is a start failure (`proc_status` 4, `ENOENT`/`ENOTDIR`), as libuv |
| `flags` | bit0 `detach` (a new session; such a child is neither signalled nor awaited at shutdown). Every other bit gives `-EINVAL`. A host may answer `-ENOTSUP` to `detach` |
| `nstdio` | exactly **3** (fds 0, 1, 2) |
| `kind` | `0` null (`/dev/null`); `1` inherit (the host's fd of the same number); `2` pipe (**fds 1–2 only**). Kind 2 for fd 0 and kinds ≥ 3 give `-EINVAL` (reserved for a later stdin/file-redirect extension) |
| `path` | always empty (reserved for that extension); non-empty gives `-EINVAL` |
| (end) | no trailing bytes |

### A.2 States and readiness (level-triggered, with retirement)

**proc**

| State | `proc_status` | poll-ready | Next |
|---|---|---|---|
| starting | `-EAGAIN` | no (pending) | running, failed |
| running | `0` | until `0` has been returned once (pending afterwards) | exited |
| failed | `4` + errno | until `4` has been returned once | — |
| exited | `12` + record | until `12` has been returned once (an exit before the start was delivered retires both) | — |
| closed | `-EBADF` | reported ready if in interest | — |

**readable pipe**: §4.1's body states (streaming, eof, failed, cancelled, closed) with its readiness.
- **The ABI delivery queue holds at most 4 MiB per pipe**, enforced on **every** chunk, taken or untaken, including chunks a host's runtime delivers on its own (Node resumes child stdio at process exit).
- A chunk that would cross the bound stays upstream: in the host stream's own buffer (Node: at most its high-water mark, 64 KiB, plus one returned chunk) and the kernel pipe buffer. Those are finite and excluded from the 4 MiB.
- Reading resumes once the guest has drained the queue.
- **A paused pipe blocks a child that keeps writing**, so the guest must drain every pipe it requested (§B's pump).

**`poll` and the new kinds.** §4's `poll` row applies unchanged (interest-filtered, `0` on timeout, never retires readiness, unknown and closed handles reported ready). **One rule is added, for an interest set of only §4c handles that are not ready:** an indefinite `poll` (timeout `-1`) returns `-EINVAL` at once when none of them is **pending**, since nothing could wake it. (This is the Node adapter's existing behaviour; §4 itself states no such rule for the other kinds, and this extension does not add one for them.) Finite timeouts simply expire.

**Pending** (able to become ready without another guest call):
- a starting or running proc;
- a pipe in a non-terminal state (streaming).

Retired terminal handles (an exited or failed proc whose status was returned; a pipe whose EOF, error or cancellation was returned) are not pending.

The host wakes a suspended `poll` on every transition, including failed starts and pipe errors.

### A.3 Errors (WASI numbering)

- **Process errors:** `ENOENT` 44, `EACCES` 2, `ENOEXEC` 45, `E2BIG` 1, `EAGAIN` 6, `EMFILE` 33, `ENFILE` 41, `ENOMEM` 48, `ENOSYS` 52, `ESRCH` 71, `EPERM` 63, `ETXTBSY` 74, `ENOTDIR` 54, `ELOOP` 32, `ENAMETOOLONG` 37, `EPIPE` 64, `EBUSY` 10, `ECANCELED` 11, `EBADF` 8, `EINVAL` 28, `ENOTSUP` 58, `ENOTCAPABLE` 76.
- Only unrecognised failures become `EIO` 29.
- §7 maps these to UV codes by table, never by negating the WASI number.

### A.4 Ownership and shutdown

- **Children.** The host owns each child it started, independently of guest handles, until its start fails or it exits and is reaped.
- **Pipe endpoints.** The host separately owns every parent pipe endpoint (taken or untaken) until its own close finishes.
- **`close(proc)`** destroys only the **untaken** endpoints.
- **Shutdown** (Node: `io.dispose({graceMs})`; repeatable):
  1. rejects new work (`spawn` → `-ENOTCAPABLE`);
  2. sends SIGTERM to every live **non-detached direct** child, and SIGKILL after `graceMs` (default 2000);
  3. aborts and releases every parent endpoint, keeping error listeners until cleanup finishes;
  4. completes when every non-detached child has failed to start or exited **and every endpoint's close has completed** (a descendant still holding the other end doesn't delay it); repeated calls return the same completion.
- **Detached children** are neither signalled nor awaited, and don't keep the host alive.
- **No descendant's exit or EOF is required.**
- A Rust host keeps a reaper independent of guest handles (dropping `std::process::Child` doesn't reap it) and makes its pipe threads interruptible at shutdown.

### A.5 Capability and security

- Process creation is **off by default**; the runner enables it explicitly (§F).
- **A spawned program is trusted host code running with the runner's rights.**
  - It sees the host filesystem, network and credentials.
  - It runs helpers, hooks, filters and aliases chosen by its configuration, environment and arguments.
  - Preopens don't confine it, and the runner's `--no-network` constrains `julia_io` networking only, not a spawned program.
- The executable policy restricts which programs start, not what they do.

### A.6 Executable policy (normative)

- **Production profile.** The host holds a map from **selector names** to **absolute host executables**, e.g. `git → /usr/bin/git`.
  - `spawn` authorizes `basename(argv[0])` against the map and executes **only the mapped executable**, with `argv[0]` passed to the child as given.
  - In this profile the guest's `PATH`, a `/` in `argv[0]` and `dir` don't select the executable. An explicit path to another binary is not honoured: the basename is the selector. This is a deliberate divergence from native lookup.
  - The child's `PATH` is still passed in its environment, for the child's own lookups.
  - An unmapped selector gives `-ENOTCAPABLE`.
- **Test profile** (§F `allow: true`, tests only). Native lookup: a selector without `/` is searched in the given env's `PATH`; with `/`, a relative path resolves against `dir`.

### B. Julia side (informative)

`WasmCodegen.Runtime.Process` (lane git-host) patches Base's process API onto §4c. **Supported:**
- `run`, `success`, `read(::AbstractCmd[, String])`, `readchomp`, `eachline(::AbstractCmd)`;
- `open(::AbstractCmd, "r")`, with `Process.out` as a runtime `HostPipe <: IO`;
- `pipeline(cmd; stdout, stderr)` on a single command;
- `wait`, `kill`, `process_running`, `process_exited`, `ignorestatus`, `setenv`, `addenv`, `Cmd(dir=…)`, `ProcessFailedException`.

**The stdio forms supported:**
- `devnull`;
- same-number inherited stdio (`RawFD(n)` or `stdin`/`stdout`/`stderr` on fd n);
- for stdout/stderr, **in-memory sinks** (`IOBuffer`, copied from a pipe) and `HostPipe`s.

**Rejected loudly** (`ArgumentError` naming the construct):
- any stdin other than `devnull` or inherited (an `IOBuffer` source, `open(cmd, "w")`);
- filename redirections (`FileRedirect`, `pipeline(cmd, stdout="f")`);
- arbitrary OS-backed IO, including an `IOStream`: a pipe copy of it is not a native-equivalent fd redirection;
- fd duplication or sharing (stdout routed to fd 2);
- more than three fds;
- pipelines of several commands (`|`, `&`);
- non-default Cmd flags, `uid`/`gid`/`cpus`;
- `getpid(::Process)`;
- `open(f, cmd)`'s Timer-based cleanup path.

**One pump.** Every blocking process operation runs one loop. Each pass:
1. does bounded non-blocking work on every actionable endpoint: reads every pipe into its sink (runtime captures, and user `HostPipe` buffers, whose bytes are **kept for the user, never discarded**);
2. services `proc_status`;
3. rechecks the operation's completion condition.

It polls only after a pass without progress, on the pending interests (§A.2), removing retired ones. Sinks are in-memory, so no work inside the loop blocks on anything else.

**Exit and `wait`.**
- The exit is recorded as soon as `proc_status` reports it, independently of pipe EOF. `process_running`/`process_exited` query the host when called, so they don't need a prior `wait`.
- `wait(p)` (`syncd = true`) waits for the exit **and** the runtime-owned copy sinks (Base's `syncd` Tasks). `wait(p, false)` waits for the exit only.
- User `HostPipe`s stay readable after the exit and are neither drained to EOF nor closed by `wait`.
- `read(::Cmd)` reads stdout to EOF, then checks success.

**Errors** (see also C):
- Spawn failures: `IOError("could not spawn " * repr(cmd) * ": <uv strerror> (<UV name>)", uv)`, raised from `_spawn`, as natively.
- A capture read failure **fails the operation even if the child exits 0**. Base wraps it in `TaskFailedException`; the single-Task runtime throws the inner `IOError` (a **documented divergence**: no Task exists to wrap).
- `kill` of an exited process, and a `proc_kill` `ESRCH` race, are no-ops, as Base.

`` `… $args` `` uses a type-stable `cmd_gen`. Base's version splats a heterogeneous tuple, which WasmCodegen rejects, and Pkg's `` `git clone $args` `` needs it.

### C. Error mapping on the Julia side (informative)

| Host result | Julia |
|---|---|
| `spawn` preflight/acquisition `-errno`, `proc_status` 4 | `IOError("could not spawn …", uv)`, as natively. `ENOTCAPABLE` → EACCES's UV code, with the host's message via `errmsg` |
| `proc_status` 12, nonzero exit or signal | `ProcessFailedException` from `run`/`read` (unless `ignorestatus`); `false` from `success` |
| `read` on a `HostPipe` | `IOError`, as natively |
| a capture failure | `IOError` (natively wrapped in `TaskFailedException`; divergence) |

### D. Hosts without process support (wasmtime and others)

- WASI (p1/p2/p3) has no process creation. A host must define **each import the module requests** with its exact signature, or instantiation fails before any Julia code runs. Providing all four stubs is the recommended policy.
- **Unsupported-host stubs:**
  - `spawn` → `-ENOSYS` (52), with `errmsg(-1)` = "process creation is not supported by this host";
  - `proc_status`, `proc_pipe` → `-EBADF`;
  - `proc_kill` → `+EBADF`.
- `run` then throws `IOError("could not spawn …: function not implemented (ENOSYS)")`, and git-based Pkg operations fail with Pkg's `PkgError`.
- An embedder that wants processes implements §4c with `std::process::Command` (after `env_clear()`), pipe reader threads or `mio` feeding the shared handle table, a reaper, and `libc::kill`, under §A.4.
- The stock Wasmtime CLI doesn't implement custom namespaces; a configured linker is required.
- **Three distinct failure classes:**
  - a **missing import** (a link error at instantiation);
  - a **disabled capability** (`-ENOTCAPABLE`);
  - an **unsupported host** (`-ENOSYS`).

### E. Shared vectors

`runner/test/abi-vectors.json` gains spawn records. Julia's encoder and the adapter's decoder are tested against the same vectors:
- valid records with an odd-length argv, non-ASCII, a leading U+FEFF, an empty env and maximal flags;
- rejected records: truncated, trailing bytes, NUL, invalid UTF-8, a duplicate env name, `nstdio ≠ 3`, a stdin pipe, kinds ≥ 3, a non-empty path, reserved flag bits.

---


<!-- §4d frozen 2026-10-29 by the coordinator from lanes/s2-wcg/abi-4d.md (sha256 c3891ff3), user decision to start S2. Optional v3 capability: a module is S2 iff it imports julia_task; pkgwasm_abi_version stays 3. -->
## §4d. `julia_task` (version 1): Julia Tasks on JSPI hosts (S2)

A module built with `Config(tasks=:jspi)` imports the namespace `julia_task` and exports
`jl_task_entry`. It runs only on hosts with JSPI (Node ≥ 24.20; earlier 24.x with
`--experimental-wasm-jspi`). Hosts without JSPI (wasmtime) use the S1 build
(`tasks=:none`), which imports and exports neither. The module's scheduler (Julia's own,
compiled) decides which task runs; the host only moves stacks.

| Import / export | Signature | Semantics |
|---|---|---|
| import `switch` | `(from i32, to i32) -> ()` | **Suspending** (`new WebAssembly.Suspending(...)`). Parks task `from`: its stack waits on a promise that only a later `switch(_, from)` or `exit(_, from)` resolves. Then it resumes task `to` (resolves its parked promise) or, if `to` has no stack yet, starts it: `WebAssembly.promising(exports.jl_task_entry)(to)`. `switch(id, id)` parks and resumes the same task: the module calls it to let the host run its event loop while it waits for host events and no other task can run. Never rejects. |
| import `exit` | `(from i32, to i32) -> ()` | Synchronous. Task `from` is ending: its `jl_task_entry` returns right after this call. Resumes or starts `to` as `switch` does, without parking `from`. `from ≠ to`. |
| export `jl_task_entry` | `(id i32) -> i32` | The first run of task `id` on a new stack. The host calls it only through `promising`, only from `switch`/`exit`, never for id 0. It calls `exit(id, _)` before it returns, and returns 0. |

**Task ids.** i32 in `0..65535`. 0 is the root task: the task of the root call (below).
Ids ≥ 1 are the module's other tasks; the module reuses an id only after that task's `exit`.

**Transfers** (`switch`, `exit`). Exactly one Wasm stack runs at a time. A transfer is
valid iff: `from` is the task whose stack is running; `to` is in range; `to` is either
parked, or `to ≥ 1` and has no stack (never started, or exited); for `exit`, `from ≥ 1`
and `from ≠ to`. The host defers the resumption or start of `to` until the calling stack
has suspended (`switch`) or returned (`exit`): there is never a JS frame between a
`promising` call and a suspension. It defers it as a **macrotask** (`setImmediate`) while
the host has outstanding work (open `julia_io` handles: timers, HTTP requests, processes),
so that Node's timers and I/O run between task switches as native Julia's `wait()` runs
libuv's events; otherwise as a **microtask**. An invalid transfer is a fatal host error: it
fails the root call in flight (below); the stack that made it stays parked forever.

**Root calls.** A root call is a `promising` call of one of the module's other exports
(`pkgwasm_init`, `pkgwasm_main`) made through the host; its task is 0. At most one root call
is in flight (§5.4). A task's stack only runs while a root call is in flight. When a root
call returns, tasks that are still parked stay parked: a later root call of the same
command (`pkgwasm_main` after `pkgwasm_init`) may resume them, as natively tasks scheduled
during init run during main.

**Failure.** If the root call or any `jl_task_entry` promise rejects (a trap such as a
stack overflow, or a `WebAssembly.Exception` escaping), or a transfer is invalid, or a
`jl_task_entry` returns without its `exit`, the host fails the root call in flight with
that error and the instance becomes **terminal**. (Julia exceptions inside a task do not
reach the host: the task fails, as natively, and `fetch`/`wait` report it.)

**Shutdown.** At the end of the command, after success or failure, the host makes the
instance terminal (`shutdown()`), **before** `julia_io` disposal (§6.1).

**Terminal state.** Parked stacks are dropped and never resumed; a resumption or start
already queued does not run; later failures go nowhere; later root calls are refused. The
`finally` blocks of abandoned tasks do not run, so the host handles they held are released
by `julia_io` disposal. The instance is not used again: one command, one instance (§6).

**`julia_io` with tasks.** Unchanged. `poll` suspends the stack of the task that calls it
while all other tasks are parked (the module polls only when no task can run, or with
timeout 0). Its interest set is every handle some task waits for plus the active timers;
readiness stays level-triggered, so any number of tasks may wait for one handle.

### 4d.1 Amendments for S2 modules (modules that import `julia_task`)

These apply only to S2 modules; S1 modules follow §2, §4, §5 and §6 unchanged.

**§2 (namespaces).** Add a row: `julia_task` — defined in §4d; only in modules built with
tasks. The generic import ccall rule applies to it as to `julia_io` (runtime code only).
The runner's namespace allowlist includes `julia_task`.

**§4, `poll`.** "This is the only suspending import." becomes: "Of `julia_io`, this is the
only suspending import (§4d adds `julia_task.switch`)." In §4's header and the adapter's
comments, "the suspending imports are `julia_io.poll` and `julia_task.switch`".

**§5.2 (Julia side).** The catch/report/return convention applies to root exports. It does
not apply to `jl_task_entry`: a task's Julia exception is its result (the task fails), and
whatever escapes `jl_task_entry` fails the root call (§4d Failure).

**§5.3 (outer JS boundary).** Also covers a rejection the julia_task host reports for the
root call (a task's trap): exit 70.

**§5.4.** "The runner never has two `promising` invocations in flight on one instance (S1 is
single-Task)." becomes: "The runner never has two **root** calls in flight on one instance.
In an S2 module, the host itself makes further `promising` calls of `jl_task_entry` from
`switch`/`exit` during the root call (§4d); they are part of it. The julia_task host
asserts one root call at a time; `julia_io` asserts that no import is called while `poll`
is suspended."

**§6 (lifecycle), for S2 modules.**
- Step 1: also `jt = makeJuliaTask({ busy: () => io.stats().open > 0 })`, iff the module
  imports `julia_task` (capability detection). A host that cannot provide it refuses the
  module (exit 70).
- Step 2: `julia_task: jt.imports.julia_task` in the import object (the start function
  calls no import, as before).
- After step 4: `jt.bind(instance)` (the module must export `jl_task_entry`, else exit 70).
- Steps 6 and 7: the root calls are `await jt.call(exports.pkgwasm_init)` and
  `await jt.call(exports.pkgwasm_main)`.

**§6.1, Shutdown.** The runner's outer `finally` calls `jt.shutdown()` and then awaits
`io.dispose()`, including after a trap or an exit 70.

### 4d.2 Notes (informative)

- **What S1 sees:** nothing. A `tasks=:none` module imports no `julia_task` and exports no
  `jl_task_entry`; the runner creates no host for it.
- **Not task-friendly yet:** `Runtime.Process`'s pump polls its handles directly (inside a
  staging scope), so a process wait suspends the whole program for its duration, as in S1.
  Correct, but no other task runs meanwhile (FOLLOW-UPS).
- **Measured cost** (Node 24.22.1): ~640 ns per host switch without outstanding host work,
  ~9 µs with (one `setImmediate` turn each); `lanes/s2-wcg/STATUS.md`.

## 5. Error boundary

1. **Host side.** Every import body is wrapped in try/catch. Unexpected JS exceptions become `EIO`, with the message stored for `errmsg`. `poll` resolves; it never rejects.
2. **Julia side.** Each export wraps its body in `try … catch e; showerror(HostStream(2), e); return 1; end`. The runtime turns errnos into the matching Julia exception: `IOError` / `SystemError` / `Base.UVError` with the UV code, or `PkgWasm.Host.HostError(status, msg)` for the network and decompress seams. `finally` blocks run.
3. **Outer JS boundary.** The runner wraps instantiate/initialize/main in a JS try/catch. It covers Wasm traps (`RuntimeError`), unknown `WebAssembly.Exception`s and unexpected rejections, prints a diagnostic, and sets exit code 70.
4. **One call at a time.** The runner never has two `promising` invocations in flight on one instance (S1 is single-Task). The adapter asserts this.

## 6. Reactor lifecycle (Node) — v2

1. Construct `wasi = new WASI({version:'preview1', args, env, preopens, returnOnExit:true})` and `io = makeJuliaIO({preopens, network})`.
2. Instantiate with the WASI imports, `julia_io` and **`julia_regex: rx.imports`** added to the import object, where `rx = makeJuliaRegex()` (`runner/julia_regex.mjs`). `julia_regex` is also added to the runner's import-namespace allowlist. The `julia_regex` imports are synchronous, and supplying the namespace to a module that doesn't use it is harmless.
   - **The start function calls no import at all**, WASI or `julia_io`. Node raises `ERR_WASI_NOT_STARTED` before memory is bound (verified by Astra on 24.22.1).
   - So the Task RNG seed and anything else host-dependent moves into `pkgwasm_init` (L1).
3. Bind memory: `io.bindMemory(instance.exports.memory)` and `rx.bindMemory(instance.exports.memory)`.
4. `wasi.initialize(instance)`. There is no `_initialize` export, or a trivial one.
5. Check `pkgwasm_abi_version() === 3`; otherwise exit 70 with a message.
6. `st = await WebAssembly.promising(exports.pkgwasm_init)()`. Init:
   - seeds the RNG via `random_get`;
   - reads WASI args and env;
   - sets the virtual cwd;
   - initialises `ENV`, `DEPOT_PATH`, `LOAD_PATH`, `ARGS`, `homedir`, `tempdir`, the active project, and the Pkg globals (PLAN D8).

   **If `st !== 0`, don't call main.** Exit with `st`, after printing whatever init wrote to stderr.
7. `rc = await WebAssembly.promising(exports.pkgwasm_main)()`, then `process.exitCode = rc`.

One instance runs one command; it is never re-initialised. L5 tests that the start function makes no host calls and that a nonzero init short-circuits, as part of G1 acceptance.

### 6.1 Process extension (from §4c part F)
#### F. Lifecycle (§6) and runner additions

- **Step 1.** `io = makeJuliaIO({preopens, network, spawn})`. `spawn` is absent by default, meaning no process creation.
  - **Production:** `spawn: { allow: { <selector>: <absolute host path> } }`.
  - **Tests only:** `spawn: { allow: true, testEscapes: true }` (native lookup, §A.6). Under `testEscapes`, the adapter also accepts `envc = 0xFFFFFFFF` (the host's environment) and an empty `dir` (the host's cwd).
- **Runner flags.**
  - `--allow-spawn=git[=/abs/path]` maps `git` to the given path, or to the runner's own `PATH` lookup at startup.
  - With spawning enabled, the runner passes these host variables into WASI's env, so Julia's `ENV` carries them to children:
    - `PATH`, `GIT_*`, `XDG_CONFIG_HOME`;
    - `SSH_AUTH_SOCK`, `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE`;
    - proxy variables (all cases);
    - `LANG`/`LC_*`, `TERM`, `DISPLAY`.
  - `--pass-env NAME` passes more. A variable passed this way is visible to the guest as well as to its children.
  - An explicit `--env NAME=value` wins over pass-through. Omitted host variables stay absent.
- **Shutdown.** The runner's outer `finally` (§5.3) awaits `io.dispose()`, including after a trap or an exit 70.

---

## 7. Errno mapping

WASI errnos in host returns are mapped by the runtime to libuv codes (negated Linux errnos) wherever Base compares against `Base.UV_E*`.

| WASI errno | Name | UV code |
|---|---|---|
| 44 | ENOENT | -2 |
| 20 | EEXIST | -17 |
| 55 | ENOTEMPTY | -39 |
| 2 | EACCES | -13 |
| 63 | EPERM | -1 |
| 10 | EBUSY | -16 |
| 54 | ENOTDIR | -20 |
| 31 | EISDIR | -21 |
| 75 | EXDEV | -18 |
| 8 | EBADF | -9 |
| 28 | EINVAL | -22 |
| 29 | EIO | -5 |
| 6 | EAGAIN | -11 |
| 52 | ENOSYS | -38 |

The full table lives in `Runtime.Errno`, and `strerror` texts match Linux glibc.
