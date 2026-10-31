// julia_io host adapter for PkgWasm (ABI.md v3, §4–§5). Owner: lane L2 `wcg-event`,
// except the marked `path_mode`/`path_chmod`/`path_symlink` section, which belongs to lane L1 `wcg-sync`.
//
//   const io = makeJuliaIO({ preopens: ['/abs/dir', ...], network: true,    // same preopens as WASI
//                            platformTags: { libgfortran_version: '5.0.0' } }); // host_platform overrides
//   const instance = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport, ...io.imports });
//   io.bindMemory(instance.exports.memory);
//
// Conventions (ABI §4): status returns are 0 or a positive WASI errno; handle/count returns
// are >= 0 or a negated WASI errno; "not ready" is -EAGAIN. Expected failures never throw:
// every import body is wrapped and unexpected JS exceptions become EIO with the message
// kept for `errmsg` (ABI §5.1). `poll` is the only suspending import and it never rejects.
//
// Handle states and readiness follow ABI §4.1 (level-triggered with retirement):
//   http  : ready iff the next http_head/read would return something other than -EAGAIN that
//           has not been delivered yet: head not yet taken, bytes buffered, EOF not yet
//           returned, or a terminal error/cancellation not yet returned.
//   timer : ready from firing until closed.
// `poll` only reports handles of its interest set; unknown/closed interest handles are
// reported ready (their next call gives -EBADF). A waiting poll whose interest handles can
// never become ready (nothing in flight) returns -EINVAL instead of hanging.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import os from 'node:os';
import http from 'node:http';
import https from 'node:https';
import { spawn as cpSpawn } from 'node:child_process'; // (L8 git-host: processes, ABI §4c)

export const JULIA_IO_VERSION = 1;
export const ABI_VERSION = 3;
export const HIGH_WATER = 4 * 1024 * 1024;
export const MAX_REDIRECTS = 10;
// The largest body chunk the transport hands over (node:http delivers socket reads, <= 64 KiB).
// The reader pauses above HIGH_WATER - MAX_CHUNK, so at most HIGH_WATER bytes are queued.
export const MAX_CHUNK = 256 * 1024;

// WASI p1 errno numbers (wasi-libc api.h)
export const E = Object.freeze({
  ACCES: 2, AGAIN: 6, BADF: 8, BUSY: 10, CANCELED: 11, CONNABORTED: 13, CONNREFUSED: 14,
  CONNRESET: 15, EXIST: 20, FBIG: 22, HOSTUNREACH: 23, ILSEQ: 25, INVAL: 28, IO: 29,
  ISDIR: 31, LOOP: 32, MFILE: 33, NAMETOOLONG: 37, NETDOWN: 38, NETUNREACH: 40, NOBUFS: 42,
  NOENT: 44, NOMEM: 48, NOSPC: 51, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58,
  PERM: 63, PROTO: 65, ROFS: 69, TIMEDOUT: 73, XDEV: 75, NOTCAPABLE: 76,
});

// Node/undici error codes -> WASI errno
const CODE_TO_ERRNO = {
  ENOENT: E.NOENT, EEXIST: E.EXIST, EACCES: E.ACCES, EPERM: E.PERM, EROFS: E.ROFS,
  ENOTDIR: E.NOTDIR, EISDIR: E.ISDIR, ENOTEMPTY: E.NOTEMPTY, EXDEV: E.XDEV, EBUSY: E.BUSY,
  ENOSPC: E.NOSPC, EMFILE: E.MFILE, ENAMETOOLONG: E.NAMETOOLONG, EINVAL: E.INVAL, EIO: E.IO,
  EFBIG: E.FBIG, ELOOP: E.LOOP,
  ECONNREFUSED: E.CONNREFUSED, ECONNRESET: E.CONNRESET, ECONNABORTED: E.CONNABORTED,
  ENOTFOUND: E.HOSTUNREACH, EAI_AGAIN: E.HOSTUNREACH, EAI_NONAME: E.HOSTUNREACH,
  EHOSTUNREACH: E.HOSTUNREACH, ENETUNREACH: E.NETUNREACH, ENETDOWN: E.NETDOWN,
  ETIMEDOUT: E.TIMEDOUT, UND_ERR_CONNECT_TIMEOUT: E.TIMEDOUT, UND_ERR_HEADERS_TIMEOUT: E.TIMEDOUT,
  UND_ERR_BODY_TIMEOUT: E.TIMEDOUT, UND_ERR_SOCKET: E.CONNRESET, EPIPE: E.CONNRESET,
  ERR_BUFFER_TOO_LARGE: E.FBIG, ERR_OUT_OF_RANGE: E.FBIG,
};

const utf8enc = new TextEncoder();
const utf8dec = new TextDecoder('utf-8', { fatal: true });

// Raised for adapter-contract violations (a bug in the guest or runner, not an expected
// failure). Deliberately not converted to EIO: it escapes as a trap to the outer boundary.
export class JuliaIOAssertion extends Error {
  constructor(msg) { super('julia_io: ' + msg); this.name = 'JuliaIOAssertion'; }
}

export class GuestError extends Error {
  constructor(errno, msg) { super(msg); this.errno = errno; }
}

function describe(e) {
  if (!(e instanceof Error)) return String(e);
  let m = e.message;
  const c = e.cause;
  if (c) m += ': ' + (c.code ? c.code + ' ' : '') + (c.message || String(c));
  else if (e.code && !m.includes(e.code)) m = e.code + ' ' + m;
  return m;
}

export function errnoOf(e) {
  if (e instanceof GuestError) return e.errno;
  if (e && e.name === 'AbortError') return E.CANCELED;
  const c = e && e.cause;
  for (const x of [c && c.code, e && e.code, c && c.cause && c.cause.code]) {
    if (x && CODE_TO_ERRNO[x] !== undefined) return CODE_TO_ERRNO[x];
  }
  return E.IO;
}

// ---- wire encoding (ABI §4 "Wire encoding"); shared with the tests and abi-vectors.json ----
export function encodeRecord(fields) {
  // fields: [['u32', n] | ['str', s]]
  const parts = [];
  let n = 0;
  for (const [t, v] of fields) {
    if (t === 'u32') { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v >>> 0, true); parts.push(b); n += 4; }
    else { const s = utf8enc.encode(v); const b = new Uint8Array(4 + s.length); new DataView(b.buffer).setUint32(0, s.length, true); b.set(s, 4); parts.push(b); n += b.length; }
  }
  const out = new Uint8Array(n);
  let p = 0;
  for (const b of parts) { out.set(b, p); p += b.length; }
  return out;
}
export const encodeSpec = ({ method, url, headers = [], flags = 0 }) => encodeRecord([
  ['str', method], ['str', url], ['u32', headers.length],
  ...headers.flatMap(([k, v]) => [['str', k], ['str', v]]), ['u32', flags]]);
export const encodeHead = ({ status, url, headers = [] }) => encodeRecord([
  ['u32', status], ['str', url], ['u32', headers.length],
  ...headers.flatMap(([k, v]) => [['str', k], ['str', v]])]);

class Reader {
  constructor(b, what) { this.b = b; this.dv = new DataView(b.buffer, b.byteOffset, b.byteLength); this.p = 0; this.what = what; }
  u32() { if (this.p + 4 > this.b.length) throw new GuestError(E.INVAL, `${this.what}: truncated`); const v = this.dv.getUint32(this.p, true); this.p += 4; return v; }
  str() {
    const n = this.u32();
    if (this.p + n > this.b.length) throw new GuestError(E.INVAL, `${this.what}: truncated`);
    let s;
    try { s = utf8dec.decode(this.b.subarray(this.p, this.p + n)); } catch { throw new GuestError(E.ILSEQ, `${this.what}: invalid UTF-8`); }
    this.p += n; return s;
  }
  end() { if (this.p !== this.b.length) throw new GuestError(E.INVAL, `${this.what}: ${this.b.length - this.p} trailing bytes`); }
}
export function decodeSpec(b) {
  const r = new Reader(b, 'http spec');
  const method = r.str(), url = r.str(), n = r.u32();
  if (n > 1024) throw new GuestError(E.INVAL, 'http spec: too many headers');
  const headers = [];
  for (let i = 0; i < n; i++) headers.push([r.str(), r.str()]);
  const flags = r.u32();
  r.end();
  return { method, url, headers, flags };
}
export function decodeHead(b) {
  const r = new Reader(b, 'http head');
  const status = r.u32(), url = r.str(), n = r.u32(), headers = [];
  for (let i = 0; i < n; i++) headers.push([r.str(), r.str()]);
  r.end();
  return { status, url, headers };
}

// ---- path validation (ABI §4 "Path validation"), shared by every julia_io path import ----
// Fails closed: a component that cannot be examined or resolved (other than "does not
// exist") is a denial. It checks pathnames; it cannot exclude a concurrent writer replacing
// a checked directory with a symlink before the use (TOCTOU) — that would need
// directory-relative opens, which Node's fs lacks. S1 assumes no such concurrent writer.
const within = (p, d) => p === d || p.startsWith(d === path.sep ? d : d + path.sep);
const ABSENT = new Set(['ENOENT', 'ENOTDIR']);

export function makeCheckPath(preopens) {
  const lexical = preopens.map((p) => {
    if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error('julia_io: preopen must be an absolute path: ' + p);
    return path.resolve(p);
  });
  const real = lexical.map((p) => {
    try { return fs.realpathSync.native(p); }
    catch (e) { throw new Error(`julia_io: preopen ${p} cannot be resolved: ${e.message}`); }
  });
  // checkPath(p, {follow}) -> normalised absolute host path, or throws GuestError(ENOTCAPABLE)
  return function checkPath(p, { follow = true } = {}) {
    const deny = (why) => { throw new GuestError(E.NOTCAPABLE, `path not permitted (${why}): ${p}`); };
    if (typeof p !== 'string' || p.includes('\0')) deny('NUL byte');
    if (!path.isAbsolute(p)) deny('not absolute');
    const r = path.resolve(p); // lexical . and .. normalisation
    if (!lexical.some((d) => within(r, d))) deny('outside every preopen');
    // the deepest existing ancestor (the path itself when following)
    let probe = follow ? r : path.dirname(r);
    for (;;) {
      try { fs.lstatSync(probe); break; }
      catch (e) { if (!ABSENT.has(e.code)) deny(`cannot examine ${probe}: ${e.code || e.message}`); }
      const up = path.dirname(probe);
      if (up === probe) deny('no existing ancestor');
      probe = up;
    }
    let rp;
    try { rp = fs.realpathSync.native(probe); }
    catch (e) { deny(`cannot resolve ${probe}: ${e.code || e.message}`); } // e.g. a dangling symlink, ELOOP
    if (!real.some((d) => within(rp, d))) deny('resolves outside every preopen');
    return r;
  };
}

// ---- host platform (ABI v3 `host_platform`, PLAN D13) ----
// process.arch / process.platform -> Base.BinaryPlatforms names
const ARCH = { x64: 'x86_64', arm64: 'aarch64', ia32: 'i686', arm: 'armv7l', riscv64: 'riscv64' };
const OS = { linux: 'linux', darwin: 'macos', win32: 'windows', freebsd: 'freebsd' };

// The detected tags of the host: arch, os and (Linux) libc; a value Node cannot map is absent.
// (`opts` stand in for the process, in tests; an explicit `glibc: undefined` is a musl host)
export function detectPlatform(opts = {}) {
  const arch = opts.arch ?? process.arch, platform = opts.platform ?? process.platform;
  const endianness = opts.endianness ?? os.endianness();
  const glibc = 'glibc' in opts ? opts.glibc : process.report.getReport().header.glibcVersionRuntime;
  const tags = [];
  const a = arch === 'ppc64' ? (endianness === 'LE' ? 'powerpc64le' : undefined) : ARCH[arch];
  if (a) tags.push(['arch', a]);
  const o = OS[platform];
  if (o) tags.push(['os', o]);
  if (o === 'linux') tags.push(['libc', glibc ? 'glibc' : 'musl']);
  return tags;
}

// Detected tags, then the runner's overrides key by key (a detected key keeps its position,
// a new key is appended). Keys are lower-cased, as Base.BinaryPlatforms stores them.
// `julia_version` is never emitted (the module adds its own), and is dropped before any
// check. Tags are checked as BinaryPlatforms checks them (`add_tag!`: none of `+- /<>:"'\|?*`
// in a lower-cased name or value; empty values allowed), and the keyword names of the
// Platform constructor, which are not tags, are refused.
const TAG_NONOS = `+- /<>:"'\\|?*`;
const NOT_TAGS = new Set(['validate_strict', 'compare_strategies']);
export function mergePlatform(detected, overrides = {}) {
  if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides))
    throw new Error('julia_io: platformTags must be an object of string tags');
  const tags = detected.filter(([k]) => k !== 'julia_version').map(([k, v]) => [k, v]);
  for (const [k0, v] of Object.entries(overrides)) {
    const k = k0.toLowerCase();
    if (k === 'julia_version') continue;
    if (typeof v !== 'string') throw new Error(`julia_io: platform tag ${JSON.stringify(k0)} must be a string, not ${typeof v}`);
    if (k === '' || NOT_TAGS.has(k)) throw new Error(`julia_io: ${JSON.stringify(k0)} is not a platform tag name`);
    for (const [what, x] of [['name', k], ['value', v.toLowerCase()]])
      if ([...TAG_NONOS].some((c) => x.includes(c)))
        throw new Error(`julia_io: invalid character in platform tag ${what} ${JSON.stringify(what === 'name' ? k0 : v)} (BinaryPlatforms refuses any of ${TAG_NONOS})`);
    const i = tags.findIndex(([q]) => q === k);
    if (i >= 0) tags[i][1] = v; else tags.push([k, v]);
  }
  return tags;
}

// ---------------------------------------------------------------------------------------
export function makeJuliaIO(opts = {}) {
  const network = opts.network !== false;
  const requestImpl = opts.request || ((u, o) => (u.protocol === 'https:' ? https : http).request(u, o));
  // (lower only, for tests: the ABI's bound is HIGH_WATER)
  const highWater = opts.highWater === undefined ? HIGH_WATER : opts.highWater;
  if (!Number.isInteger(highWater) || highWater < 2 * MAX_CHUNK || highWater > HIGH_WATER)
    throw new Error(`julia_io: highWater must be an integer in [${2 * MAX_CHUNK}, ${HIGH_WATER}], not ${opts.highWater}`);
  const maxDecompressed = opts.maxDecompressed || 1024 * 1024 * 1024;
  const checkPath = makeCheckPath(opts.preopens || []);
  const platform = mergePlatform(opts.detectedPlatform || detectPlatform(), opts.platformTags || {});
  let memory = opts.memory || null;

  const handles = new Map(); // id -> entry (open handles only)
  let nextHandle = 1; // ids are never reused
  let lastError = ''; // errmsg(-1)
  let inPoll = false;
  let waker = null; // resolves the suspended poll
  const stats = { maxQueued: 0, maxOpen: 0, started: 0 };

  // ---- memory: views are recreated on every access (ABI §1) ----
  function mem() {
    if (!memory) throw new JuliaIOAssertion('memory not bound (call bindMemory)');
    return new Uint8Array(memory.buffer);
  }
  function view() { mem(); return new DataView(memory.buffer); }
  function checkRange(off, len, align = 1) {
    off >>>= 0; len >>>= 0;
    if (off % align) throw new GuestError(E.INVAL, `offset ${off} is not ${align}-byte aligned`);
    if (off + len > mem().byteLength) throw new GuestError(E.INVAL, `range [${off}, ${off + len}) outside linear memory`);
    return [off, len];
  }
  function readBytes(off, len, align = 1) {
    [off, len] = checkRange(off, len, align);
    return mem().slice(off, off + len); // copy: inputs never alias linear memory
  }
  function readPath(off, len) {
    const b = readBytes(off, len);
    try { return utf8dec.decode(b); } catch { throw new GuestError(E.ILSEQ, 'path is not valid UTF-8'); }
  }

  // ---- bookkeeping ----
  function notify() { if (waker) { const w = waker; waker = null; w(); } }
  function newHandle(entry) {
    const h = nextHandle++;
    entry.id = h;
    handles.set(h, entry);
    stats.started++;
    if (handles.size > stats.maxOpen) stats.maxOpen = handles.size;
    return h;
  }
  function get(h) { return handles.get(h | 0); }
  function guard(name) {
    if (inPoll) throw new JuliaIOAssertion(`${name} called while poll is suspended (two promising calls in flight on one instance)`);
  }
  // Wraps an import: assertion -> rethrow; GuestError/other JS errors -> errno via `fail`.
  function wrap(name, f, fail) {
    return (...args) => {
      guard(name);
      try { return f(...args); }
      catch (e) {
        if (e instanceof JuliaIOAssertion) throw e;
        return fail(e, args[0]);
      }
    };
  }
  // record the message (on the handle when the import has one, else for errmsg(-1))
  function fault(e, h) {
    const m = describe(e);
    const x = h !== undefined && get(h);
    if (x) x.errmsg = m; else lastError = m;
    return errnoOf(e);
  }
  const neg = (e) => -fault(e);
  const negH = (e, h) => -fault(e, h);
  const negH64 = (e, h) => BigInt(-fault(e, h));

  // ---- http state (ABI §4.1) ----
  // An error that arrives after body bytes takes effect once they are read.
  const failed = (x) => x.error && x.queued === 0;
  function isReady(x) {
    if (x.kind === 'timer') return x.fired;
    if (x.kind === 'proc') return procReady(x); // (L8 git-host, ABI §4c)
    if (failed(x)) return !x.errorDelivered;
    if (x.head && !x.headTaken) return true;
    if (x.queued > 0) return true;
    return x.eof && !x.eofDelivered;
  }
  // may become ready without guest action (a paused body has bytes queued: it is ready)
  function isPending(x) {
    if (x.kind === 'timer') return !x.fired;
    if (x.kind === 'proc') return procPending(x); // (L8 git-host, ABI §4c)
    return !x.error && !x.eof && (!x.head || !x.paused);
  }

  function httpFail(x, e) {
    if (x.error || x.closed) return;
    x.error = { errno: errnoOf(e), msg: describe(e) };
    x.errmsg = x.error.msg;
    stop(x);
    notify();
  }
  // release the transport (request, response, socket) of a handle
  function stop(x) {
    try { x.abort.abort(); } catch {}
    try { if (x.res) x.res.destroy(); } catch {}
    try { if (x.req) x.req.destroy(); } catch {}
  }
  // Runs `f` as an event handler of the handle `x`: any exception fails the handle (EIO)
  // instead of escaping to the event loop (ABI §5.1).
  const guarded = (x, f) => (...a) => { try { f(...a); } catch (e) { httpFail(x, e); } };

  // The transport is node:http(s), not fetch: like libcurl (native Downloads.request) it
  // returns the body bytes as sent (no Content-Encoding decoding) and the header names as
  // sent. Redirects are followed here, hop by hop.
  function hop(x, url, method, headers) {
    return new Promise((resolve, reject) => {
      const u = new URL(url);
      // (a raw header list is sent as is: Node adds no Host header to it)
      const all = headers.some(([k]) => k.toLowerCase() === 'host') ? headers : [['Host', u.host], ...headers];
      const flat = all.flatMap(([k, v]) => [k, v]);
      const req = requestImpl(u, { method, headers: flat, signal: x.abort.signal, agent: false });
      x.req = req;
      req.on('response', resolve);
      req.on('error', reject);
      // a protocol upgrade (HTTP 101) is not supported: fail, release the socket
      req.on('upgrade', (res, socket) => {
        try { socket.destroy(); } catch {}
        reject(new GuestError(E.PROTO, `unsupported protocol upgrade (HTTP ${res.statusCode}${res.headers.upgrade ? ' to ' + res.headers.upgrade : ''}): ${url}`));
      });
      // closed without a response (after a response, the promise is settled: no effect)
      req.on('close', () => reject(new GuestError(E.CONNRESET, `connection closed before a response: ${url}`)));
      req.end();
    });
  }
  // URL userinfo to bytes as libcurl's curl_easy_unescape: %XX is the byte, anything else
  // (including a malformed escape) its UTF-8 bytes; the bytes need not be UTF-8
  function unescapeBytes(str) {
    const out = [];
    for (let i = 0; i < str.length; i++) {
      if (str[i] === '%' && /^[0-9a-fA-F]{2}$/.test(str.slice(i + 1, i + 3))) { out.push(parseInt(str.slice(i + 1, i + 3), 16)); i += 2; }
      else for (const b of Buffer.from(str[i], 'utf8')) out.push(b);
    }
    return Buffer.from(out);
  }
  const SENSITIVE = new Set(['authorization', 'cookie', 'proxy-authorization']);
  const origin = (u) => { const v = new URL(u); return `${v.protocol}//${v.host}`; };

  async function runRequest(x, spec) {
    let url = spec.url;
    let method = spec.method;
    let headers = spec.headers;
    // credentials in the URL: Basic authorization, as libcurl, unless one is given; the URL
    // requested carries none. It is an Authorization header: dropped across origins, below.
    const u0 = new URL(url);
    if (u0.username || u0.password) {
      if (!headers.some(([k]) => k.toLowerCase() === 'authorization')) {
        const cred = Buffer.concat([unescapeBytes(u0.username), Buffer.from(':'), unescapeBytes(u0.password)]);
        headers = [...headers, ['Authorization', 'Basic ' + cred.toString('base64')]];
      }
      u0.username = ''; u0.password = '';
      url = u0.href;
    }
    const follow = (spec.flags & 1) !== 0;
    for (let n = 0; ; n++) {
      const res = await hop(x, url, method, headers);
      x.res = res;
      if (x.closed || x.error) { res.destroy(); return; }
      const loc = res.headers.location;
      if (follow && [301, 302, 303, 307, 308].includes(res.statusCode) && loc !== undefined) {
        res.destroy();
        if (n >= MAX_REDIRECTS) throw new GuestError(E.LOOP, `too many redirects (> ${MAX_REDIRECTS}) starting at ${spec.url}`);
        const next = new URL(loc, url);
        if (next.protocol !== 'http:' && next.protocol !== 'https:') throw new GuestError(E.NOTSUP, `redirect to unsupported URL scheme ${next.protocol}: ${next.href}`);
        // credentials do not follow a redirect to another origin (scheme, host or port), as libcurl
        if (origin(next.href) !== origin(url)) headers = headers.filter(([k]) => !SENSITIVE.has(k.toLowerCase()));
        url = next.href;
        if (res.statusCode === 303 && method !== 'HEAD') method = 'GET';
        continue;
      }
      const raw = res.rawHeaders, hs = [];
      for (let i = 0; i + 1 < raw.length; i += 2) hs.push([raw[i], raw[i + 1]]);
      x.head = { status: res.statusCode, url, headers: hs };
      res.on('error', guarded(x, (e) => httpFail(x, e)));
      res.on('aborted', guarded(x, () => httpFail(x, new GuestError(E.CONNRESET, `connection closed before the end of the body: ${url}`))));
      res.on('data', guarded(x, (chunk) => {
        if (x.closed || x.error) return;
        if (chunk.length > MAX_CHUNK) throw new GuestError(E.IO, `transport delivered a ${chunk.length}-byte chunk (> ${MAX_CHUNK})`);
        x.chunks.push(chunk);
        x.queued += chunk.length;
        if (x.queued > stats.maxQueued) stats.maxQueued = x.queued;
        if (x.queued > highWater - MAX_CHUNK) { res.pause(); x.paused = true; }
        notify();
      }));
      res.on('end', guarded(x, () => { if (!x.error) { x.eof = true; notify(); } }));
      notify();
      return;
    }
  }

  function http_start(spec_off, spec_len) {
    const spec = decodeSpec(readBytes(spec_off, spec_len, 4));
    if (spec.flags & ~1) throw new GuestError(E.INVAL, `http_start: unknown flags 0x${(spec.flags >>> 0).toString(16)}`);
    if (spec.method !== 'GET' && spec.method !== 'HEAD') throw new GuestError(E.NOTSUP, `http_start: method ${spec.method} not supported (v1: GET, HEAD)`);
    let u;
    try { u = new URL(spec.url); } catch { throw new GuestError(E.INVAL, `http_start: invalid URL ${JSON.stringify(spec.url)}`); }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new GuestError(E.NOTSUP, `http_start: unsupported URL scheme ${u.protocol}`);
    if (!network) throw new GuestError(E.NOTCAPABLE, `http_start: network access is disabled (${spec.url})`);
    const x = {
      kind: 'http', url: spec.url, abort: new AbortController(), head: null, headTaken: false,
      chunks: [], queued: 0, eof: false, eofDelivered: false, error: null, errorDelivered: false,
      errmsg: '', req: null, res: null, paused: false, closed: false,
    };
    const h = newHandle(x);
    runRequest(x, spec).catch((e) => httpFail(x, e));
    return h;
  }

  function http_head(h, out_off, out_cap) {
    const x = get(h);
    if (!x || x.kind !== 'http') return -E.BADF;
    out_off >>>= 0; out_cap >>>= 0;
    if (out_cap < 4) throw new GuestError(E.INVAL, `http_head: cap ${out_cap} < 4`);
    checkRange(out_off, 4, 4);
    if (failed(x)) { x.errorDelivered = true; return -x.error.errno; }
    if (!x.head) return -E.AGAIN;
    const rec = encodeHead(x.head);
    if (rec.length > out_cap) {
      view().setUint32(out_off, rec.length, true);
      x.errmsg = `http_head: record needs ${rec.length} bytes, capacity ${out_cap}`;
      return -E.NOBUFS;
    }
    checkRange(out_off, rec.length);
    mem().set(rec, out_off);
    x.headTaken = true;
    return rec.length;
  }

  function read(h, off, len) {
    const x = get(h);
    if (!x || (x.kind !== 'http' && x.kind !== 'pipe')) return BigInt(-E.BADF); // (pipe: L8 git-host, ABI §4c)
    [off, len] = checkRange(off, len);
    if (len === 0) throw new GuestError(E.INVAL, 'read: len must be positive (0 is reserved for EOF)');
    if (x.queued > 0) {
      const m = mem();
      let n = 0;
      while (n < len && x.chunks.length) {
        const c = x.chunks[0];
        const k = Math.min(c.length, len - n);
        m.set(c.subarray(0, k), off + n);
        n += k;
        // (a copy of the rest: no view keeps a larger buffer alive)
        if (k === c.length) x.chunks.shift(); else x.chunks[0] = Buffer.from(c.subarray(k));
      }
      x.queued -= n;
      if (x.paused && x.queued <= highWater - MAX_CHUNK && x.res && !x.error) { x.paused = false; x.res.resume(); }
      return BigInt(n);
    }
    if (x.error) { x.errorDelivered = true; return BigInt(-x.error.errno); }
    if (x.eof) { x.eofDelivered = true; return 0n; }
    return BigInt(-E.AGAIN);
  }

  // ---- timers ----
  function timer_start(ns) {
    ns = BigInt.asIntN(64, BigInt(ns));
    if (ns < 0n) throw new GuestError(E.INVAL, `timer_start: negative duration ${ns}`);
    const x = { kind: 'timer', fired: false, cancelled: false, t: null, errmsg: '', closed: false };
    const deadline = performance.now() + Number(ns) / 1e6;
    const arm = () => {
      const ms = deadline - performance.now();
      if (ms <= 0) { x.t = null; x.fired = true; notify(); return; }
      x.t = setTimeout(arm, Math.min(Math.ceil(ms), 0x7fffffff));
    };
    const h = newHandle(x);
    arm();
    return h;
  }

  // ---- poll (the only suspending import) ----
  function readyOf(interest, cap) {
    const out = [];
    for (const h of interest) {
      if (out.length >= cap) break;
      const x = handles.get(h);
      if (!x || isReady(x)) out.push(h); // unknown/closed: ready (next call gives -EBADF)
    }
    return out;
  }
  const anyPending = (interest) => interest.some((h) => { const x = handles.get(h); return x && isPending(x); });
  function writeReady(list, off) {
    const dv = view();
    for (let i = 0; i < list.length; i++) dv.setInt32(off + 4 * i, list[i], true);
    return list.length;
  }

  function poll(interest_off, n_interest, timeout_ns, out_off, cap) {
    guard('poll');
    try {
      n_interest |= 0; cap |= 0; out_off >>>= 0;
      timeout_ns = BigInt.asIntN(64, BigInt(timeout_ns));
      if (n_interest < 1 || n_interest > 1024) throw new GuestError(E.INVAL, `poll: n_interest ${n_interest} not in 1..1024`);
      if (cap < 1) throw new GuestError(E.INVAL, `poll: cap ${cap} < 1`);
      if (timeout_ns < -1n) throw new GuestError(E.INVAL, `poll: bad timeout ${timeout_ns}`);
      const ib = readBytes(interest_off, 4 * n_interest, 4);
      const idv = new DataView(ib.buffer);
      const interest = Array.from({ length: n_interest }, (_, i) => idv.getInt32(4 * i, true));
      checkRange(out_off, 4 * cap, 4);
      const ready = readyOf(interest, cap);
      if (ready.length || timeout_ns === 0n) return writeReady(ready, out_off);
      if (timeout_ns === -1n && !anyPending(interest))
        throw new GuestError(E.INVAL, 'poll: waiting indefinitely, but no handle of the interest set can become ready');
      return suspend(interest, timeout_ns, out_off, cap);
    } catch (e) {
      if (e instanceof JuliaIOAssertion) throw e;
      return neg(e);
    }
  }

  async function suspend(interest, timeout_ns, out_off, cap) {
    inPoll = true;
    let timer = null, timedOut = false;
    try {
      if (timeout_ns > 0n)
        timer = setTimeout(() => { timedOut = true; notify(); }, Math.min(Math.ceil(Number(timeout_ns) / 1e6), 0x7fffffff));
      for (;;) {
        await new Promise((r) => { waker = r; });
        waker = null;
        const ready = readyOf(interest, cap);
        if (ready.length || timedOut) return writeReady(ready, out_off);
        if (timeout_ns === -1n && !anyPending(interest)) {
          lastError = 'poll: no handle of the interest set can become ready any more';
          return -E.INVAL;
        }
      }
    } catch (e) {
      if (e instanceof JuliaIOAssertion) throw e;
      return neg(e);
    } finally {
      if (timer) clearTimeout(timer);
      inPoll = false;
      waker = null;
    }
  }

  // ---- errmsg / cancel / close ----
  function errmsg(h, out_off, cap) {
    let m;
    if ((h | 0) === -1) m = lastError;
    else { const x = get(h); if (!x) return -E.BADF; m = x.errmsg || ''; }
    cap >>>= 0;
    if (cap < 4) throw new GuestError(E.INVAL, `errmsg: cap ${cap} < 4`);
    let b = utf8enc.encode(m);
    if (b.length > cap) b = b.subarray(0, cap);
    checkRange(out_off, b.length);
    mem().set(b, out_off >>> 0);
    return b.length;
  }

  function cancel(h) {
    const x = get(h);
    if (!x) return -E.BADF;
    if (x.kind === 'timer') {
      if (!x.fired) { clearTimeout(x.t); x.t = null; x.fired = true; x.cancelled = true; x.errmsg = 'timer cancelled'; notify(); }
      return 0;
    }
    if (x.kind === 'proc') return procCancel(x); // (L8 git-host, ABI §4c)
    if (!x.error && !x.eof) { // a non-terminal state (ABI §4.1)
      x.chunks = []; x.queued = 0;
      x.error = { errno: E.CANCELED, msg: `request cancelled: ${x.url}` };
      x.errmsg = x.error.msg;
      stop(x);
      notify();
    }
    return 0;
  }

  function close(h) {
    h |= 0;
    const x = handles.get(h);
    if (!x) return -E.BADF;
    if (x.kind === 'timer') { if (x.t) clearTimeout(x.t); }
    else if (x.kind === 'proc') procClose(x); // (L8 git-host, ABI §4c)
    else {
      stop(x);
      x.chunks = []; x.queued = 0;
    }
    x.closed = true;
    handles.delete(h);
    notify();
    return 0;
  }

  // ---- decompress (synchronous in S1) ----
  // zlib/zstd error codes -> WASI errno; anything unrecognised is an unexpected failure (EIO)
  function codecErrno(e) {
    if (e.code === 'ERR_BUFFER_TOO_LARGE') return E.FBIG;
    if (e.code === 'Z_BUF_ERROR') return E.IO; // truncated input
    if (e.code === 'Z_MEM_ERROR' || e.code === 'ZSTD_error_memory_allocation') return E.NOMEM;
    if (e.code === 'Z_DATA_ERROR' || e.code === 'Z_NEED_DICT' || (typeof e.code === 'string' && e.code.startsWith('ZSTD_error_'))) return E.ILSEQ;
    return E.IO;
  }
  // a new regular file, never through an existing name (no symlink or hard link is followed)
  function writeNew(file, data) {
    const C = fs.constants;
    const fd = fs.openSync(file, C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_NOFOLLOW, 0o666);
    try {
      for (let off = 0; off < data.length;) off += fs.writeSync(fd, data, off, data.length - off);
    } finally { fs.closeSync(fd); }
  }

  function decompress(src_off, src_len, dst_off, dst_len) {
    // the destination first: its stale partial file is removed whatever fails afterwards
    const dst = checkPath(readPath(dst_off, dst_len), { follow: false });
    const partial = checkPath(dst + '.partial', { follow: false });
    const srcPath = readPath(src_off, src_len);
    const what = `decompress ${srcPath}`;
    // a stale partial file (of an earlier failure; possibly a link): removed by name
    try { fs.rmSync(partial, { force: true }); }
    catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot remove stale ${partial}: ${describe(e)}`); }
    let created = false;
    try {
      const src = checkPath(srcPath, { follow: true });
      let data;
      try { data = fs.readFileSync(src); }
      catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot read: ${describe(e)}`); }
      let out;
      const zopts = { maxOutputLength: maxDecompressed };
      try {
        if (data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b) out = zlib.gunzipSync(data, zopts);
        else if (data.length >= 4 && data[0] === 0x28 && data[1] === 0xb5 && data[2] === 0x2f && data[3] === 0xfd) out = zlib.zstdDecompressSync(data, zopts);
        else throw new GuestError(E.ILSEQ, `${what}: unknown format (neither gzip nor zstd magic)`);
      } catch (e) {
        if (e instanceof GuestError) throw e;
        throw new GuestError(codecErrno(e), `${what}: ${describe(e)}`);
      }
      data = null;
      try {
        created = true;
        writeNew(partial, out);
        fs.renameSync(partial, dst);
        created = false;
      } catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot write ${dst}: ${describe(e)}`); }
    } catch (e) {
      if (created) {
        try { fs.rmSync(partial, { force: true }); }
        catch (r) { throw new GuestError(errnoOf(e), `${describe(e)}; additionally failed to remove ${partial}: ${describe(r)}`); }
      }
      throw e;
    }
    return 0;
  }

  // ---- host_platform (synchronous) ----
  function host_platform(out_off, cap) {
    out_off >>>= 0; cap >>>= 0;
    if (cap < 4) throw new GuestError(E.INVAL, `host_platform: cap ${cap} < 4`);
    checkRange(out_off, 4, 4);
    for (const k of ['arch', 'os'])
      if (!platform.some(([q]) => q === k)) throw new GuestError(E.NOTSUP, `host_platform: this host's ${k} is not one Julia knows (${k === 'arch' ? process.arch : process.platform}); configure it`);
    const rec = encodeRecord([['u32', platform.length], ...platform.flatMap(([k, v]) => [['str', k], ['str', v]])]);
    if (rec.length > cap) { view().setUint32(out_off, rec.length, true); lastError = `host_platform: record needs ${rec.length} bytes, capacity ${cap}`; return -E.NOBUFS; }
    checkRange(out_off, rec.length);
    mem().set(rec, out_off);
    return rec.length;
  }

  // ===== BEGIN L1 wcg-sync section: path_mode / path_chmod / path_symlink (owned by lane L1) =====
  // Paths are validated with `checkPath` (ABI §4 path validation). Host errors become WASI
  // errnos (`errnoOf`), returned negated (path_mode) or as a status (the others).

  // the preopened directories themselves (lexically normalised): inspecting one is allowed
  // whether or not the last component is followed (checkPath, not following, looks at its
  // parent, which is out of reach)
  const preopenRoots = new Set((opts.preopens || []).map((d) => path.resolve(d)));
  // the POSIX st_mode (type and permission bits) of the path, of the link itself unless
  // `follow`; a path ending with a separator must be a directory (as stat(2))
  function path_mode(path_off, path_len, follow) {
    const raw = readPath(path_off, path_len);
    const isRoot = path.isAbsolute(raw) && !raw.includes('\0') && preopenRoots.has(path.resolve(raw));
    const p = isRoot ? path.resolve(raw) : checkPath(raw, { follow: follow !== 0 });
    let mode;
    try { mode = (follow !== 0 ? fs.statSync(p) : fs.lstatSync(p)).mode; }
    catch (e) { throw new GuestError(errnoOf(e), `path_mode ${p}: ${describe(e)}`); }
    if (raw.length > 1 && raw.endsWith('/') && (mode & 0o170000) !== 0o040000) {
      // (a link to a directory, with a trailing separator, is followed by stat(2); a path it
      // may not follow keeps its error: ENOTDIR only for what is not a directory)
      const q = checkPath(raw, { follow: true });
      let st;
      try { st = fs.statSync(q); }
      catch (e) { throw new GuestError(errnoOf(e), `path_mode ${q}: ${describe(e)}`); }
      if (!st.isDirectory()) throw new GuestError(E.NOTDIR, `path_mode ${raw}: not a directory`);
      return st.mode;
    }
    return mode;
  }
  // chmod(2) of the path (following links, as chmod does)
  function path_chmod(path_off, path_len, mode) {
    const p = checkPath(readPath(path_off, path_len), { follow: true });
    try { fs.chmodSync(p, mode & 0o7777); return 0; }
    catch (e) { throw new GuestError(errnoOf(e), `path_chmod ${p}: ${describe(e)}`); }
  }
  // symlink(2): the link `link` (validated, its last component not followed) to `target`,
  // raw bytes never validated nor resolved (any string, as natively; ABI v3)
  function path_symlink(target_off, target_len, link_off, link_len) {
    const target = Buffer.from(readBytes(target_off, target_len));
    if (target.includes(0)) throw new GuestError(E.INVAL, 'path_symlink: target contains a NUL byte');
    const link = checkPath(readPath(link_off, link_len), { follow: false });
    try { fs.symlinkSync(target, link); return 0; }
    catch (e) { throw new GuestError(errnoOf(e), `path_symlink ${link}: ${describe(e)}`); }
  }
  // ===== END L1 wcg-sync section =====


  // ===== BEGIN L8 git-host section: processes (ABI §4c: spawn / proc_status / proc_pipe / proc_kill; owned by lane L8) =====
  // Kinds: 'proc' (a child), 'pipe' (a readable child stdout/stderr: an HTTP-body-like entry, read
  // by `read`). The child's stdin is null or inherited. opts.spawn = { allow: { name: '/abs/path' } |
  // true (tests), testEscapes?: bool }; absent: process creation is disabled (ENOTCAPABLE). The
  // allowlist restricts which programs start, not what they do: a spawned program is trusted host
  // code with the runner's rights (ABI §4c A.5).
  const spawnPolicy = opts.spawn || null;
  // production profile (ABI §4c A.6): every mapped executable is an absolute path, checked here
  // (native lookup only with the test profile, allow: true)
  if (spawnPolicy && spawnPolicy.allow !== true) {
    const allow = spawnPolicy.allow;
    if (allow === null || typeof allow !== 'object') throw new TypeError('julia_io: spawn.allow must be true (tests) or a map name -> absolute path');
    for (const [k, v] of Object.entries(allow)) {
      if (typeof v !== 'string' || !path.isAbsolute(v)) throw new TypeError(`julia_io: spawn.allow.${k} must be an absolute path, got ${JSON.stringify(v)}`);
    }
  }
  const SIG = os.constants.signals;
  const PIPE_CHUNK_MAX = 64 * 1024;           // libuv reads pipes in chunks of at most 64 KiB
  const MAX_ARGC = 4096, MAX_ENVC = 65536, NSTDIO = 3, FLAG_DETACH = 1;
  const live = new Map();                     // non-detached child -> promise settled at its exit or failed start
  const endpoints = new Map();                // every parent pipe endpoint -> promise settled when its stream has closed (ABI §4c A.4)
  let disposing = null;                       // the shared promise of dispose()
  let disposed = false;
  const PROC_ERRNO = { EPIPE: 64, E2BIG: 1, EAGAIN: 6, ENOEXEC: 45, ENFILE: 41, EMFILE: 33, ENOSYS: 52,
    ESRCH: 71, ENOENT: 44, EACCES: 2, EPERM: 63, ENOTDIR: 54, ELOOP: 32, ENAMETOOLONG: 37, ENOMEM: 48,
    ETXTBSY: 74, ECANCELED: 11, EBUSY: 10 };
  const procErrno = (e) => (e && PROC_ERRNO[e.code] !== undefined ? PROC_ERRNO[e.code] : errnoOf(e));
  const exactUtf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }); // (a leading U+FEFF is kept)

  function decodeSpawnSpec(b) {
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const bad = (why) => { throw new GuestError(E.INVAL, `spawn: ${why}`); };
    let p = 0;
    const u32 = () => { if (p + 4 > b.length) bad('truncated record'); const v = dv.getUint32(p, true); p += 4; return v; };
    const str = (what) => {
      const n = u32(); if (p + n > b.length) bad('truncated record');
      const raw = b.subarray(p, p + n); p += n;
      if (raw.includes(0)) bad(`NUL byte in ${what}`);
      try { return exactUtf8.decode(raw); } catch { bad(`${what} is not valid UTF-8`); }
    };
    const argc = u32();
    if (argc < 1 || argc > MAX_ARGC) bad(`argc ${argc} not in 1..${MAX_ARGC}`);
    const argv = Array.from({ length: argc }, () => str('argv'));
    if (argv[0] === '') bad('empty program name');
    const envc = u32();
    let env = null;
    if (envc === 0xffffffff) {
      if (!(spawnPolicy && spawnPolicy.testEscapes)) bad('envc 0xFFFFFFFF (the host environment) is test-only');
    } else {
      if (envc > MAX_ENVC) bad(`envc ${envc} > ${MAX_ENVC}`);
      env = Object.create(null); // (no inherited setters: `__proto__` is an ordinary name)
      for (let k = 0; k < envc; k++) {
        const kv = str('env'); const q = kv.indexOf('=');
        if (q < 1) bad(`env entry without NAME=: ${JSON.stringify(kv)}`);
        const name = kv.slice(0, q);
        if (Object.prototype.hasOwnProperty.call(env, name)) bad(`duplicate env name ${name}`);
        env[name] = kv.slice(q + 1);
      }
    }
    const dir = str('dir');
    if (dir === '' && !(spawnPolicy && spawnPolicy.testEscapes)) bad('empty dir (the host cwd) is test-only');
    const flags = u32();
    if (flags & ~FLAG_DETACH) bad(`reserved flag bits 0x${(flags & ~FLAG_DETACH).toString(16)}`);
    const nstdio = u32();
    if (nstdio !== NSTDIO) bad(`nstdio ${nstdio} (exactly ${NSTDIO}: fds 0-2)`);
    const stdio = [];
    for (let fd = 0; fd < nstdio; fd++) {
      const kind = u32(); const pth = str('stdio path');
      if (kind > 2) bad(`stdio kind ${kind} for fd ${fd}`);
      if (pth !== '') bad(`stdio path given for kind ${kind}, fd ${fd}`);
      if (kind === 2 && fd === 0) bad('fd 0: kind 2 (pipe) is for fds 1-2');
      stdio.push({ kind, path: pth });
    }
    if (p !== b.length) bad('trailing bytes in record');
    return { argv, env, dir, flags, stdio };
  }
  // the executable of argv[0] under the policy (null: not allowed)
  function allowedProgram(argv0) {
    if (spawnPolicy.allow === true) return argv0;
    const name = path.basename(argv0);
    const allow = spawnPolicy.allow || {};
    return Object.prototype.hasOwnProperty.call(allow, name) ? allow[name] : null;
  }
  // a readable child pipe, read from spawn on (bounded; ABI §4c A.2)
  function newReadPipe(x, fd, st) {
    const y = { kind: 'pipe', url: `fd ${fd} of ${x.prog}`, head: true, headTaken: true, chunks: [], queued: 0,
                eof: false, error: null, paused: false, res: st, abort: { abort() {} }, errmsg: '', closed: false };
    st.on('data', (c) => {
      if (y.closed) return;
      if (c.length > PIPE_CHUNK_MAX) {
        y.error = { errno: E.IO, msg: `${y.url}: a ${c.length}-byte chunk (> ${PIPE_CHUNK_MAX})` }; y.errmsg = y.error.msg;
        st.destroy(); notify(); return;
      }
      // never past the bound: a chunk that does not fit goes back to the stream's own buffer (Node
      // also resumes child stdio by itself at the exit, flushStdio)
      if (y.queued + c.length > highWater) { y.paused = true; st.pause(); st.unshift(c); return; }
      y.chunks.push(c); y.queued += c.length;
      if (y.queued > stats.maxQueued) stats.maxQueued = y.queued;
      if (y.queued > highWater - PIPE_CHUNK_MAX) { y.paused = true; st.pause(); }
      notify();
    });
    st.on('end', () => { if (!y.error) y.eof = true; notify(); });
    st.on('error', (e) => { if (!y.error) { y.error = { errno: procErrno(e), msg: describe(e) }; y.errmsg = y.error.msg; } notify(); });
    let closed;
    endpoints.set(y, new Promise((r) => { closed = r; }));
    st.on('close', () => {
      endpoints.delete(y); closed();
      // a stream closed without EOF or an error (and not by us): a terminal EIO, never pending forever
      if (!y.eof && !y.error && !y.closed) { y.error = { errno: E.IO, msg: `${y.url}: closed before its end` }; y.errmsg = y.error.msg; }
      notify();
    });
    return y;
  }
  function procReady(x) {
    if (x.kind === 'proc')
      return (x.state !== 'starting' && !x.startDelivered) || ((x.state === 'exited' || x.state === 'failed') && !x.statusDelivered);
    return false;
  }
  function procPending(x) {
    return x.state === 'starting' || x.state === 'running';
  }
  function procCancel(x) {
    throw new GuestError(E.NOTSUP, 'cancel: not defined for process handles (use proc_kill)');
  }
  // close: the child keeps running; its untaken pipes are destroyed
  function procClose(x) {
    for (const y of x.pipes.values()) destroyPipe(y);
    x.pipes.clear();
  }
  function destroyPipe(y) {
    y.closed = true;
    try { y.res.destroy(); } catch {}
    y.chunks = []; y.queued = 0;
  }

  function spawn_(spec_off, spec_len) {
    if (!spawnPolicy || disposed) throw new GuestError(E.NOTCAPABLE, `spawn: process creation is ${disposed ? 'shut down' : 'not enabled for this module'}`);
    // preflight: parse, authorize, validate paths; nothing is acquired before it completes
    const sp = decodeSpawnSpec(readBytes(spec_off, spec_len, 4));
    if (process.platform === 'win32') throw new GuestError(E.NOTSUP, 'spawn: only the POSIX host profile (Linux, macOS) is implemented');
    if (sp.flags & FLAG_DETACH) throw new GuestError(E.NOTSUP, 'spawn: detach is not supported by this host');
    if (process.permission) throw new GuestError(E.NOTSUP, 'spawn: the Node permission model may alter the child environment');
    const file = allowedProgram(sp.argv[0]);
    if (file === null) throw new GuestError(E.NOTCAPABLE, `spawn: program ${JSON.stringify(sp.argv[0])} is not allowed`);
    const cwd = sp.dir === '' ? undefined : checkPath(sp.dir);
    // the actual child environment is exactly the list: Node adds NODE_V8_COVERAGE unless the
    // env has the name as an own property (an undefined value is then left out)
    if (sp.env !== null && !Object.prototype.hasOwnProperty.call(sp.env, 'NODE_V8_COVERAGE')) sp.env.NODE_V8_COVERAGE = undefined;
    let child;
    try {
      const stdio = sp.stdio.map((s) => ['ignore', 'inherit', 'pipe'][s.kind]);
      child = cpSpawn(file, sp.argv.slice(1), { cwd, env: sp.env === null ? process.env : sp.env, stdio, argv0: sp.argv[0], windowsHide: true });
    } catch (e) {
      throw new GuestError(procErrno(e), `spawn ${JSON.stringify(sp.argv[0])}: ${describe(e)}`);
    }
    const x = { kind: 'proc', prog: JSON.stringify(sp.argv[0]), state: 'starting', startDelivered: false, statusDelivered: false,
                exitcode: 0, termsignal: 0, errmsg: '', closed: false, child, pipes: new Map(), killError: null };
    let settle;
    live.set(child, new Promise((r) => { settle = r; }));
    const finished = () => { if (live.delete(child)) settle(); };
    child.on('close', finished); // (also after a failed start, which has no 'exit')
    child.on('spawn', () => { if (x.state === 'starting') x.state = 'running'; notify(); });
    child.on('error', (e) => {
      if (x.state === 'starting') { x.state = 'failed'; x.error = { errno: procErrno(e), msg: describe(e) }; x.errmsg = x.error.msg; finished(); }
      else x.killError = e; // (Node reports a failed kill, other than ESRCH, this way)
      notify();
    });
    child.on('exit', (code, sig) => {
      finished();
      if (x.state !== 'failed') { x.state = 'exited'; x.exitcode = code === null ? 0 : code; x.termsignal = sig ? (SIG[sig] || 0) : 0; }
      notify();
    });
    sp.stdio.forEach((s, i) => {
      if (s.kind !== 2) return;
      x.pipes.set(i, newReadPipe(x, i, child.stdio[i]));
    });
    return newHandle(x);
  }
  function proc_pipe(h, fd) {
    const x = get(h);
    if (!x || x.kind !== 'proc') return -E.BADF;
    const y = x.pipes.get(fd);
    if (!y) throw new GuestError(E.INVAL, `proc_pipe: fd ${fd} is not a pipe, or was taken`);
    x.pipes.delete(fd);
    return newHandle(y);
  }
  function proc_status(h, out_off, cap) {
    const x = get(h);
    if (!x || x.kind !== 'proc') return -E.BADF;
    if (cap < 12) throw new GuestError(E.INVAL, 'proc_status: out_cap < 12');
    [out_off] = checkRange(out_off, 12, 4); // (a record: 4-byte aligned; checked in every state)
    if (x.state === 'starting') return -E.AGAIN;
    const dv = view();
    if (x.state === 'failed') { x.startDelivered = x.statusDelivered = true; dv.setUint32(out_off, x.error.errno, true); return 4; }
    x.startDelivered = true;
    if (x.state === 'running') return 0;
    dv.setBigInt64(out_off, BigInt(x.exitcode), true);
    dv.setInt32(out_off + 8, x.termsignal, true);
    x.statusDelivered = true;
    return 12;
  }
  function proc_kill(h, signum) {
    const x = get(h);
    if (!x || x.kind !== 'proc') return E.BADF;
    if (signum !== 0 && !Object.values(SIG).includes(signum)) return E.INVAL;
    if (x.state !== 'running') return PROC_ERRNO.ESRCH;
    x.killError = null;
    if (x.child.kill(signum)) return 0;
    const e = x.killError; x.killError = null;
    return e ? procErrno(e) : PROC_ERRNO.ESRCH;
  }
  // host shutdown (the runner's outer `finally`, ABI §4c A.4)
  function dispose({ graceMs = 2000 } = {}) {
    if (disposing) return disposing;
    disposed = true;
    const waits = [];
    for (const [c, done] of live) {
      if (c.pid !== undefined && c.exitCode === null && c.signalCode === null) {
        try { c.kill('SIGTERM'); } catch {}
        const t = setTimeout(() => { try { c.kill('SIGKILL'); } catch {} }, graceMs);
        t.unref();
        done.then(() => clearTimeout(t));
      }
      waits.push(done);
    }
    for (const x of handles.values()) if (x.kind === 'proc') x.pipes.clear();
    for (const [y, closed] of [...endpoints]) { destroyPipe(y); waits.push(closed); } // (taken and untaken)
    // timers and HTTP requests left open (with tasks, ABI §4d: an abandoned task's `finally`
    // never runs): released, so nothing keeps the command alive
    for (const [h, x] of handles) {
      if (x.kind === 'timer') { if (x.t) clearTimeout(x.t); x.t = null; }
      else if (x.kind === 'http') { stop(x); x.chunks = []; x.queued = 0; }
      else continue;
      x.closed = true;
      handles.delete(h);
    }
    disposing = Promise.all(waits).then(() => undefined);
    return disposing;
  }
  function procStats() {
    let queued = 0;
    for (const x of handles.values()) if (x.kind === 'proc') for (const y of x.pipes.values()) queued += y.queued;
    return { queued, liveChildren: live.size, endpoints: endpoints.size };
  }
  // ===== END L8 git-host section =====

  const julia_io = {
    http_start: wrap('http_start', http_start, neg),
    http_head: wrap('http_head', http_head, negH),
    read: wrap('read', read, negH64),
    timer_start: wrap('timer_start', timer_start, neg),
    poll: new WebAssembly.Suspending(poll),
    errmsg: wrap('errmsg', errmsg, neg),
    cancel: wrap('cancel', cancel, negH),
    close: wrap('close', close, negH),
    decompress: wrap('decompress', decompress, (e) => fault(e)),
    host_platform: wrap('host_platform', host_platform, neg),
    path_mode: wrap('path_mode', path_mode, neg),
    path_chmod: wrap('path_chmod', path_chmod, (e) => fault(e)),
    path_symlink: wrap('path_symlink', path_symlink, (e) => fault(e)), // (L1, ABI v3 additive)
    // (L8 git-host, ABI §4c: processes)
    spawn: wrap('spawn', spawn_, neg),
    proc_status: wrap('proc_status', proc_status, negH),
    proc_pipe: wrap('proc_pipe', proc_pipe, negH),
    proc_kill: wrap('proc_kill', proc_kill, (e) => fault(e)),
  };

  return {
    imports: { julia_io },
    checkPath,
    dispose, // (L8 git-host, ABI §4c A.4: the runner calls it in its outer `finally`)
    platform: () => platform.map(([k, v]) => [k, v]),
    bindMemory(m) {
      if (!(m instanceof WebAssembly.Memory)) throw new Error('julia_io: bindMemory needs the exported WebAssembly.Memory');
      memory = m;
    },
    // Introspection for tests and runner diagnostics.
    stats() {
      let queued = 0;
      for (const x of handles.values()) if (x.kind === 'http' || x.kind === 'pipe') queued += x.queued; // (pipe: L8)
      const ps = procStats(); // (L8 git-host: untaken pipes, live children)
      return { open: handles.size, queued: queued + ps.queued, liveChildren: ps.liveChildren, endpoints: ps.endpoints, ...stats };
    },
    handleState(h) {
      const x = get(h);
      if (!x) return null;
      return x.kind === 'timer' ? { kind: 'timer', fired: x.fired, cancelled: x.cancelled, ready: isReady(x) }
        : { kind: 'http', head: !!x.head, queued: x.queued, eof: x.eof, error: x.error, paused: x.paused, ready: isReady(x) };
    },
  };
}

// Check the module's ABI version (ABI §6 step 5); throws with a message on mismatch.
export function checkAbiVersion(instance) {
  const v = instance.exports.pkgwasm_abi_version;
  if (typeof v !== 'function') throw new Error('julia_io: module exports no pkgwasm_abi_version');
  const got = v();
  if (got !== ABI_VERSION) throw new Error(`julia_io: module ABI version ${got} != adapter ABI version ${ABI_VERSION}`);
}
