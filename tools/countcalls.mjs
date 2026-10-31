// Host-call counter, preloaded with `node --import ./tools/countcalls.mjs ...` (instrumented
// runs only, never timed ones): wraps every function import passed to WebAssembly.instantiate
// and writes {"<ns>.<name>": [calls, total ms]} to $COUNT_CALLS_FILE at exit.
import fs from 'node:fs';
const out = process.env.COUNT_CALLS_FILE;
const counts = new Map();
const orig = WebAssembly.instantiate;
WebAssembly.instantiate = function (m, imports, ...rest) {
  const wrapped = {};
  for (const [ns, obj] of Object.entries(imports ?? {})) {
    wrapped[ns] = {};
    for (const [name, v] of Object.entries(obj)) {
      if (typeof v !== 'function') { wrapped[ns][name] = v; continue; }
      const key = `${ns}.${name}`;
      const c = [0, 0];
      counts.set(key, c);
      wrapped[ns][name] = function (...a) {
        c[0]++;
        const t = performance.now();
        try { return v.apply(this, a); } finally { c[1] += performance.now() - t; }
      };
    }
  }
  return orig.call(this, m, wrapped, ...rest);
};
process.on('exit', () => {
  if (!out) return;
  const o = {};
  for (const [k, [n, ms]] of counts) if (n > 0) o[k] = [n, Math.round(ms * 10) / 10];
  fs.writeFileSync(out, JSON.stringify(o, null, 0) + '\n');
});
