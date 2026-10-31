#!/usr/bin/env node
// PkgWasm Node runner (PLAN D6; ABI.md v2 §5–6). Owner: L5 e2e.
//
//   node pkgwasm.mjs --wasm FILE --dir ABS [--dir ABS ...] [--env K=V ...] [--no-network]
//                    [--platform-tag k=v ...] [--platform-from-frozen]
//                    [--timing FILE] [--trace-fs FILE]
//                    [--allow-spawn NAME[=ABS] ...] [--pass-env NAME ...] -- <cmd> [pkgs...]
//
// - Preopens: exactly the --dir list, identity-mapped (guest path == host path), absolute.
//   The same list is given to the julia_io adapter for its path validation (ABI §4).
// - Env: exactly the --env list; only JULIA_DEPOT_PATH, JULIA_PROJECT, JULIA_PKG_SERVER,
//   HOME, PWD, TMPDIR and JULIA_PKG_* are accepted. Nothing is inherited from process.env.
// - WASI args: ["pkgwasm", <cmd>, pkgs...].
// - --no-network constructs the adapter with networking disabled (http_start -> ENOTCAPABLE).
// - --platform-tag / --platform-from-frozen: host platform overrides for julia_io.host_platform
//   (ABI v3, PLAN D13), passed to makeJuliaIO({platformTags}).
// - --allow-spawn NAME[=ABS] (also --allow-spawn=NAME[=ABS]; ABI.md §4c/§6.1, PLAN D14): process
//   creation, for the program selector NAME only, executing ABS (default: NAME looked up in the
//   runner's PATH at startup). Off by default. With it, the host's PATH, GIT_*, XDG_CONFIG_HOME,
//   SSH_AUTH_SOCK, SSH_ASKPASS, SSH_ASKPASS_REQUIRE, proxy variables, LANG/LC_*, TERM and DISPLAY
//   are passed into the guest env (and so to its children); --pass-env NAME passes more. An
//   explicit --env wins. The adapter's dispose() runs in the outer `finally`.
//
// Lifecycle (ABI §6, v3): WASI + julia_io + julia_regex adapters → instantiate (start function must call no import;
// enforced here) → bindMemory → wasi.initialize → ABI version check → promising(init) →
// (only if init returned 0) promising(main) → exit code = main's return.
// Outer boundary (ABI §5.3): traps, foreign WebAssembly.Exceptions, unexpected rejections and
// any runner failure print a diagnostic and exit 70. Usage errors exit 2.

import fs from 'node:fs';
import { validateStart } from './validate_start.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const EXIT_INTERNAL = 70;
export const EXIT_USAGE = 2;
const ABI_VERSION = 3;   // ABI.md v3 (julia_io.host_platform)
const ENV_ALLOWED = new Set(['JULIA_DEPOT_PATH', 'JULIA_PROJECT', 'JULIA_PKG_SERVER', 'HOME', 'PWD', 'TMPDIR']);
const envAllowed = (k) => ENV_ALLOWED.has(k) || k.startsWith('JULIA_PKG_');
const NAMESPACES = new Set(['wasi_snapshot_preview1', 'julia_io', 'julia_regex', 'julia', 'julia_task']);   // ABI v3 §2, §4d

class UsageError extends Error {}

export function parseArgs(argv) {
  const o = { wasm: null, dirs: [], env: {}, network: true, timing: null, traceFs: null,
    platformTags: {}, platformFromFrozen: null, args: [], spawn: null, passEnv: [] };
  let i = 0;
  const need = (flag) => {
    if (i + 1 >= argv.length) throw new UsageError(`${flag} needs a value`);
    return argv[++i];
  };
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { o.args = argv.slice(i + 1); break; }
    else if (a === '--wasm') o.wasm = need(a);
    else if (a === '--dir') o.dirs.push(need(a));
    else if (a === '--env') {
      const kv = need(a);
      const eq = kv.indexOf('=');
      if (eq <= 0) throw new UsageError(`--env expects K=V, got ${JSON.stringify(kv)}`);
      const k = kv.slice(0, eq);
      if (!envAllowed(k)) throw new UsageError(`--env ${k} is not in the env policy (D6)`);
      if (k in o.env) throw new UsageError(`--env ${k} given twice`);
      o.env[k] = kv.slice(eq + 1);
    }
    else if (a === '--no-network') o.network = false;
    else if (a === '--platform-tag') {
      const kv = need(a);
      const eq = kv.indexOf('=');
      if (eq <= 0 || eq === kv.length - 1) throw new UsageError(`--platform-tag expects k=v, got ${JSON.stringify(kv)}`);
      const k = kv.slice(0, eq);
      if (k in o.platformTags) throw new UsageError(`--platform-tag ${k} given twice`);
      o.platformTags[k] = kv.slice(eq + 1);
    }
    else if (a === '--platform-from-frozen') o.platformFromFrozen = FROZEN_TOML;
    else if (a === '--allow-spawn' || a.startsWith('--allow-spawn=')) {
      const v = a === '--allow-spawn' ? need(a) : a.slice('--allow-spawn='.length);
      const eq = v.indexOf('=');
      const name = eq < 0 ? v : v.slice(0, eq);
      if (!name || name.includes('/')) throw new UsageError(`--allow-spawn expects NAME[=ABS], got ${JSON.stringify(v)}`);
      const exe = eq < 0 ? lookupPath(name) : v.slice(eq + 1);
      if (!path.isAbsolute(exe)) throw new UsageError(`--allow-spawn ${name}: ${JSON.stringify(exe)} is not an absolute path`);
      o.spawn ??= {};
      if (name in o.spawn) throw new UsageError(`--allow-spawn ${name} given twice`);
      o.spawn[name] = exe;
    }
    else if (a === '--pass-env') o.passEnv.push(need(a));
    else if (a === '--timing') o.timing = need(a);
    else if (a === '--trace-fs') o.traceFs = need(a);
    else throw new UsageError(`unknown argument ${JSON.stringify(a)}`);
  }
  if (!o.wasm) throw new UsageError('--wasm FILE is required');
  if (o.passEnv.length > 0 && !o.spawn) throw new UsageError('--pass-env needs --allow-spawn');
  if (o.spawn) o.env = { ...spawnEnv(process.env, o.passEnv), ...o.env };   // (an explicit --env wins)
  o.platformTags = resolvePlatformTags(o.platformTags, o.platformFromFrozen);
  if (o.dirs.length === 0) throw new UsageError('at least one --dir is required');
  if (o.args.length === 0) throw new UsageError('missing command after --');
  for (const d of o.dirs) {
    if (!path.isAbsolute(d)) throw new UsageError(`--dir ${d} is not absolute`);
    const bare = d.length > 1 ? d.replace(/\/+$/, '') : d;
    if (path.normalize(bare) !== bare) throw new UsageError(`--dir ${d} is not normalised`);
    let st;
    try { st = fs.statSync(d); } catch { throw new UsageError(`--dir ${d} does not exist`); }
    if (!st.isDirectory()) throw new UsageError(`--dir ${d} is not a directory`);
  }
  o.dirs = o.dirs.map((d) => (d.length > 1 ? d.replace(/\/+$/, '') : d));
  return o;
}

// ---- host platform (PLAN D13, ABI v3 julia_io.host_platform) ----
// The adapter detects arch/os/libc; these tags override it key by key. --platform-from-frozen
// takes fixtures/frozen.toml [platform_tags] (the native baselines' HostPlatform()), adding
// arch/os/libc only where they differ from what Node detects; explicit --platform-tag wins.
export const FROZEN_TOML = fileURLToPath(new URL('../fixtures/frozen.toml', import.meta.url));

export function detectedPlatform() {
  const arch = { x64: 'x86_64', arm64: 'aarch64', ia32: 'i686', arm: 'armv7l', ppc64: 'powerpc64le', riscv64: 'riscv64' }[process.arch] ?? process.arch;
  const os = { linux: 'linux', darwin: 'macos', win32: 'windows', freebsd: 'freebsd' }[process.platform] ?? process.platform;
  const d = { arch, os };
  if (os === 'linux') d.libc = process.report?.getReport?.().header?.glibcVersionRuntime ? 'glibc' : 'musl';
  return d;
}

// Minimal reader for one flat `[table]` of `key = "value"` lines.
export function readTomlTable(file, table) {
  const out = {};
  let inside = false;
  for (const raw of fs.readFileSync(file, 'utf8').split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const h = line.match(/^\[([^\]]+)\]$/);
    if (h) { inside = h[1].trim() === table; continue; }
    if (!inside) continue;
    const m = line.match(/^([A-Za-z0-9_]+)\s*=\s*"([^"]*)"$/);
    if (!m) throw new Error(`${file} [${table}]: cannot parse ${JSON.stringify(raw)}`);
    out[m[1]] = m[2];
  }
  return out;
}

export function resolvePlatformTags(explicit, frozenFile, detected = detectedPlatform()) {
  const tags = {};
  if (frozenFile) {
    const fz = readTomlTable(frozenFile, 'platform_tags');
    if (Object.keys(fz).length === 0) throw new UsageError(`${frozenFile} has no [platform_tags]`);
    for (const [k, v] of Object.entries(fz)) {
      if (k === 'julia_version') continue;   // the module adds its own VERSION (ABI v3)
      if (['arch', 'os', 'libc'].includes(k) && detected[k] === v) continue;
      tags[k] = v;
    }
  }
  return { ...tags, ...explicit };
}

// Wrap every function import so that a call during instantiation (the start function) is
// caught: ABI v2 §6.2 says the start function calls no import at all.
function guardImports(imports, phase) {
  const out = {};
  for (const [ns, obj] of Object.entries(imports)) {
    out[ns] = {};
    for (const [name, v] of Object.entries(obj)) {
      if (typeof v !== 'function') { out[ns][name] = v; continue; }   // e.g. WebAssembly.Suspending
      out[ns][name] = function (...a) {
        if (phase.name === 'instantiate') {
          phase.violation ??= `${ns}.${name}`;
          throw new Error(`start function called import ${ns}.${name} (ABI v2 §6.2 forbids host calls before bindMemory/initialize)`);
        }
        return v.apply(this, a);
      };
    }
  }
  return out;
}

// Suspending imports (julia_io.poll) are objects, not functions, so guardImports cannot wrap
// them after the fact (review-1 #3). Instead, while the adapter is being constructed, every
// the program NAME in the runner's PATH (--allow-spawn without a path)
function lookupPath(name) {
  for (const d of (process.env.PATH || '').split(path.delimiter)) {
    if (!d) continue;
    const p = path.join(d, name);
    try { fs.accessSync(p, fs.constants.X_OK); if (fs.statSync(p).isFile()) return p; } catch {}
  }
  throw new UsageError(`--allow-spawn ${name}: not found in PATH`);
}
// the host variables passed into the guest env when spawning is enabled (ABI.md §6.1)
const PASS_ENV = new Set(['PATH', 'XDG_CONFIG_HOME', 'SSH_AUTH_SOCK', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'TERM', 'DISPLAY', 'LANG']);
const PROXY_ENV = new Set(['http_proxy', 'https_proxy', 'ftp_proxy', 'all_proxy', 'no_proxy']);
export function spawnEnv(hostEnv, extra = []) {
  const env = {};
  for (const [k, v] of Object.entries(hostEnv)) {
    if (PASS_ENV.has(k) || k.startsWith('GIT_') || k.startsWith('LC_') || PROXY_ENV.has(k.toLowerCase()) || extra.includes(k)) env[k] = v;
  }
  return env;
}

// `new WebAssembly.Suspending(fn)` gets a guarded fn: a call during instantiation records the
// violation in `phase` (which a Wasm catch_all cannot erase) and throws.
function makeGuardedJuliaIO(makeJuliaIO, opts, phase) {
  const Real = WebAssembly.Suspending;
  const made = new Map();   // Suspending object -> { name }
  WebAssembly.Suspending = function (fn) {
    const label = { name: '<suspending import>' };
    const guarded = function (...a) {
      if (phase.name === 'instantiate') {
        phase.violation ??= `julia_io.${label.name}`;
        throw new Error(`start function called import julia_io.${label.name} (ABI v2 §6.2)`);
      }
      return fn.apply(this, a);
    };
    const obj = new Real(guarded);
    made.set(obj, label);
    return obj;
  };
  try {
    const io = makeJuliaIO(opts);
    for (const [name, v] of Object.entries(io.imports.julia_io)) {
      if (made.has(v)) made.get(v).name = name;
    }
    return io;
  } finally {
    WebAssembly.Suspending = Real;
  }
}

// --trace-fs: log every path-taking host call, one tab-separated line each:
//   <ns>.<import> \t <dirfd or -> \t <raw path argument> \t <resolved absolute guest path>
// for the relocation test and the E1–E6 "only scenario dirs" check. WASI p1 path calls carry
// (dirfd, path_ptr, path_len). Preopen fds are 3.. in --dir order (node:wasi); directory fds
// opened later by path_open are tracked from its fd out-param and dropped on fd_close. An
// absolute raw WASI path (invalid: WASI paths are relative to dirfd) resolves to
// "!absolute:<raw>", an unknown dirfd to "!fd<N>:<raw>"; neither can pass as in-scope.
const WASI_PATH_ARGS = {
  path_open: [[0, 2, 3]], path_filestat_get: [[0, 2, 3]], path_filestat_set_times: [[0, 2, 3]],
  path_create_directory: [[0, 1, 2]], path_remove_directory: [[0, 1, 2]], path_unlink_file: [[0, 1, 2]],
  path_readlink: [[0, 1, 2]], path_rename: [[0, 1, 2], [3, 4, 5]], path_symlink: [[2, 3, 4]],
  path_link: [[0, 2, 3], [4, 5, 6]],
};
// path_symlink: only `link` (args 2,3) is accessed; `target` is raw data (ABI v3), not a path access
const JULIA_IO_PATH_ARGS = { decompress: [[0, 1], [2, 3]], path_mode: [[0, 1]], path_chmod: [[0, 1]], path_symlink: [[2, 3]] };
// Fields are escaped (\\, \t, \n, \r) so a path containing a delimiter cannot forge a
// field; readers must require exactly 4 fields (review-2 #11).
const escField = (x) => String(x).replace(/[\\\t\n\r]/g, (c) => ({ '\\': '\\\\', '\t': '\\t', '\n': '\\n', '\r': '\\r' })[c]);
const traceLine = (...fields) => fields.map(escField).join('\t');
function makeFsTracer(dirs, memRef) {
  const lines = [];
  const fds = new Map(dirs.map((d, i) => [i + 3, d]));
  const str = (off, len) => Buffer.from(new Uint8Array(memRef.memory.buffer, off >>> 0, len >>> 0)).toString('utf8');
  function resolve(fd, raw) {
    if (raw.startsWith('/')) return `!absolute:${raw}`;
    const base = fds.get(fd);
    return base === undefined ? `!fd${fd}:${raw}` : path.posix.normalize(path.posix.join(base, raw));
  }
  function wrap(ns, imports, table, absolute) {
    const out = { ...imports };
    for (const [name, specs] of Object.entries(table)) {
      const f = imports[name];
      if (typeof f !== 'function') continue;
      out[name] = function (...a) {
        let opened = null;
        try {
          for (const sp of specs) {
            if (absolute) {
              const raw = str(a[sp[0]], a[sp[1]]);
              lines.push(traceLine(`${ns}.${name}`, '-', raw, raw.startsWith('/') ? path.posix.normalize(raw) : `!relative:${raw}`));
            } else {
              const fd = a[sp[0]], raw = str(a[sp[1]], a[sp[2]]);
              const res = resolve(fd, raw);
              lines.push(traceLine(`${ns}.${name}`, String(fd), raw, res));
              if (name === 'path_open') opened = res;
            }
          }
        } catch (e) { lines.push(traceLine(`${ns}.${name}`, '-', '', `!unreadable:${e.message}`)); }
        const r = f.apply(this, a);
        if (opened !== null && r === 0 && !opened.startsWith('!')) {
          // path_open(fd, dirflags, path, len, oflags, rights_base, rights_inh, fdflags, fd_out)
          try { fds.set(new DataView(memRef.memory.buffer).getUint32(a[8] >>> 0, true), opened); } catch {}
        }
        return r;
      };
    }
    if (ns === 'wasi') {
      // directory-fd provenance (review-2 #7): any successful close forgets the fd (preopens
      // included); fd_renumber(from, to) moves it (closing `to`).
      if (typeof imports.fd_close === 'function') {
        out.fd_close = function (fd, ...rest) {
          const r = imports.fd_close.call(this, fd, ...rest);
          if (r === 0) fds.delete(fd);
          return r;
        };
      }
      if (typeof imports.fd_renumber === 'function') {
        out.fd_renumber = function (from, to, ...rest) {
          const r = imports.fd_renumber.call(this, from, to, ...rest);
          if (r === 0) {
            const base = fds.get(from);
            fds.delete(from);
            if (base === undefined) fds.delete(to); else fds.set(to, base);
            lines.push(traceLine('wasi.fd_renumber', `${from}->${to}`, '', base ?? `!fd${from}:`));
          }
          return r;
        };
      }
    }
    return out;
  }
  return {
    wrapWasi: (imp) => wrap('wasi', imp, WASI_PATH_ARGS, false),
    wrapJuliaIO: (imp) => wrap('julia_io', imp, JULIA_IO_PATH_ARGS, true),
    lines,
  };
}

function checkModuleImports(mod) {
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (!NAMESPACES.has(imp.module)) throw new Error(`module imports from forbidden namespace ${imp.module}.${imp.name} (ABI §2)`);
    if (imp.module === 'julia' && imp.name !== 'write_byte') throw new Error(`legacy import julia.${imp.name} is not allowed (ABI §2: only write_byte)`);
  }
}

// Legacy panic path julia.write_byte(fd, byte): buffered per fd, flushed on newline/exit.
function makeLegacy() {
  const bufs = { 1: [], 2: [] };
  const flush = (fd) => {
    if (bufs[fd]?.length) { fs.writeSync(fd, Buffer.from(bufs[fd])); bufs[fd] = []; }
  };
  return {
    imports: { julia: { write_byte(fd, b) {
      const f = fd === 1 ? 1 : 2;
      bufs[f].push(b & 0xff);
      if ((b & 0xff) === 10) flush(f);
    } } },
    flush: () => { flush(1); flush(2); },
  };
}

export async function run(o, { log = (s) => process.stderr.write(s) } = {}) {
  const t = { start: performance.now() };
  const mark = (k) => { t[k] = Math.round(performance.now() - t.start); };
  const { WASI } = await import('node:wasi');   // dynamic: after the warning filter is installed
  const { makeJuliaIO } = await import(new URL('./julia_io.mjs', import.meta.url));
  const { makeJuliaRegex } = await import(new URL('./julia_regex.mjs', import.meta.url));   // ABI v3 §4b (L6)
  const legacy = makeLegacy();
  const phase = { name: 'setup', violation: null };
  let tracer = null;
  let io = null;
  let jt = null;   // julia_task (ABI §4d), for modules built with tasks
  const flushTrace = () => { if (tracer) fs.writeFileSync(o.traceFs, tracer.lines.map((l) => l + '\n').join('')); };
  try {
    const bytes = fs.readFileSync(o.wasm);
    const compileStart = performance.now();
    const mod = await WebAssembly.compile(bytes);
    t.compile_only = performance.now() - compileStart;
    mark('compile');
    checkModuleImports(mod);
    validateStart(bytes, mod);
    mark('validateStart');

    const preopens = Object.fromEntries(o.dirs.map((d) => [d, d]));
    const wasi = new WASI({ version: 'preview1', args: ['pkgwasm', ...o.args], env: o.env, preopens, returnOnExit: true });
    io = makeGuardedJuliaIO(makeJuliaIO, { preopens: o.dirs, network: o.network, platformTags: o.platformTags,
                                            ...(o.spawn ? { spawn: { allow: o.spawn } } : {}) }, phase);

    const rx = makeJuliaRegex();   // ABI v3 §6 step 1: synchronous imports, harmless if unused
    const { makeJuliaTask, importsJuliaTask } = await import(new URL('./julia_task.mjs', import.meta.url));
    if (importsJuliaTask(mod)) jt = makeJuliaTask({ busy: () => io.stats().open > 0 });
    const memRef = { memory: null };
    tracer = o.traceFs ? makeFsTracer(o.dirs, memRef) : null;
    const wasiImp = tracer ? tracer.wrapWasi(wasi.wasiImport) : wasi.wasiImport;
    const jioImp = tracer ? { julia_io: tracer.wrapJuliaIO(io.imports.julia_io) } : io.imports;

    phase.name = 'instantiate';
    // The exact start body was checked above. Keep node:wasi functions intact so
    // V8 can use their native fast path; JS adapters retain the lifecycle guard.
    const imports = { wasi_snapshot_preview1: wasiImp,
      ...guardImports({ ...jioImp, julia_regex: rx.imports, ...legacy.imports, ...(jt ? jt.imports : {}) }, phase) };
    let instance;
    const instantiateStart = performance.now();
    try {
      instance = await WebAssembly.instantiate(mod, imports);
    } catch (e) {
      if (phase.violation) throw new Error(`start function called import ${phase.violation} (ABI v2 §6.2)`);
      throw e;
    }
    if (phase.violation) throw new Error(`start function called import ${phase.violation} (ABI v2 §6.2)`);
    phase.name = 'run';
    t.instantiate_only = performance.now() - instantiateStart;
    mark('instantiate');

    const ex = instance.exports;
    if (!(ex.memory instanceof WebAssembly.Memory)) throw new Error('module does not export "memory" (ABI §1)');
    io.bindMemory(ex.memory);
    rx.bindMemory(ex.memory);   // ABI v3 §6 step 3
    memRef.memory = ex.memory;
    wasi.initialize(instance);
    jt?.bind(instance);
    const root = (f) => (jt ? jt.call(f) : WebAssembly.promising(f)());   // (ABI §4d: task 0)

    if (typeof ex.pkgwasm_abi_version !== 'function') throw new Error('module exports no pkgwasm_abi_version (ABI §6)');
    const v = ex.pkgwasm_abi_version();
    if (v !== ABI_VERSION) throw new Error(`module ABI version ${v} != runner ABI version ${ABI_VERSION}`);
    for (const f of ['pkgwasm_init', 'pkgwasm_main']) {
      if (typeof ex[f] !== 'function') throw new Error(`module exports no ${f} (ABI §6)`);
    }

    // One promising invocation at a time (ABI §5.4): strictly sequential awaits.
    const initStart = performance.now();
    const st = await root(ex.pkgwasm_init);
    t.init_only = performance.now() - initStart;
    mark('init');
    if (st !== 0) {
      legacy.flush();
      flushTrace();
      return { code: st, timing: t, phase: 'init' };
    }
    const mainStart = performance.now();
    const rc = await root(ex.pkgwasm_main);
    t.main_only = performance.now() - mainStart;
    mark('main');
    legacy.flush();
    flushTrace();
    return { code: rc, timing: t, phase: 'main' };
  } catch (e) {
    legacy.flush();
    try { flushTrace(); } catch {}
    log(`pkgwasm runner: ${describe(e)}\n`);
    return { code: EXIT_INTERNAL, timing: t, phase: 'internal', error: e };
  } finally {
    jt?.shutdown();   // (ABI §4d: first, so that no abandoned task resumes during disposal)
    if (io) await io.dispose();   // (ABI §4c A.4: children ended, endpoints released; also after a trap)
  }
}

function describe(e) {
  if (e instanceof WebAssembly.RuntimeError) return `wasm trap: ${e.message}\n${e.stack ?? ''}`;
  if (typeof WebAssembly.Exception === 'function' && e instanceof WebAssembly.Exception) return 'uncaught WebAssembly.Exception escaped the module (no Julia catch)';
  if (e instanceof Error) return `${e.name}: ${e.message}`;
  return `non-Error thrown: ${String(e)}`;
}

async function main() {
  let o;
  try {
    o = parseArgs(process.argv.slice(2));
  } catch (e) {
    if (e instanceof UsageError) {
      process.stderr.write(`pkgwasm runner: ${e.message}\nusage: node pkgwasm.mjs --wasm FILE --dir ABS... [--env K=V...] [--no-network] [--platform-tag k=v...] [--platform-from-frozen] [--timing FILE] [--trace-fs FILE] [--allow-spawn NAME[=ABS]...] [--pass-env NAME...] -- <cmd> [pkgs...]\n`);
      process.exitCode = EXIT_USAGE;
      return;
    }
    throw e;
  }
  const r = await run(o);
  if (o.timing) {
    try { fs.writeFileSync(o.timing, JSON.stringify({ code: r.code, phase: r.phase, ms: r.timing }) + '\n'); } catch {}
  }
  process.exitCode = r.code;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // Last-resort boundary: anything escaping run() still exits 70 with a diagnostic.
  const die = (what) => (e) => {
    process.stderr.write(`pkgwasm runner: ${what}: ${describe(e)}\n`);
    process.exit(EXIT_INTERNAL);
  };
  // node:wasi is "experimental" on Node 24: drop that one warning so stderr carries only
  // the module's output (compare.jl matches error text against the stderr tail).
  process.removeAllListeners('warning');
  process.on('warning', (w) => {
    if (w.name === 'ExperimentalWarning' && /WASI/.test(w.message)) return;
    process.stderr.write(`${w.name}: ${w.message}\n`);
  });
  process.on('uncaughtException', die('uncaught exception'));
  process.on('unhandledRejection', die('unhandled rejection'));
  main().catch(die('runner failure'));
}
