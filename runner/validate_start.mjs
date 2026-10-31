// A conservative proof for the compiler's image initializer and its direct callees.
// Indirect/reference calls and instructions outside this decoded subset are rejected. Inspect the
// exact bytes that WebAssembly.compile validated; never search raw instruction bytes
// (constants and indices can themselves contain opcode values).
export function validateStart(bytes, mod) {
  let p = 8, end = bytes.length;
  const fail = (why) => { throw new Error(`start function called import or has an unverified initializer: ${why} (ABI §6.2)`); };
  const failImport = (imp) => { throw new Error(`start function called import ${imp.module}.${imp.name} (ABI §6.2)`); };
  const byte = () => { if (p >= end) fail('truncated instruction'); return bytes[p++]; };
  const unsigned = () => {
    let n = 0, mul = 1;
    for (let i = 0; i < 5; i++, mul *= 128) {
      const b = byte(); n += (b & 127) * mul;
      if (!(b & 128)) return n;
    }
    fail('oversized integer');
  };
  const signed = (max = 5) => {
    let n = 0, mul = 1;
    for (let i = 0; i < max; i++, mul *= 128) {
      const b = byte(); n += (b & 127) * mul;
      if (!(b & 128)) return b & 64 ? n - 128 * mul : n;
    }
    fail('oversized signed integer');
  };
  const skip = (n) => { if (n > end - p) fail('truncated immediate'); p += n; };
  const heapType = () => {
    const t = signed();
    if (t < 0 && (t < -23 || t > -12)) fail(`unknown heap type ${t}`);
  };
  const atomicValueType = (t) => (t >= 0x7b && t <= 0x7f) || (t >= 0x69 && t <= 0x74);
  const valueType = () => {
    const t = byte();
    if (t === 0x63 || t === 0x64) heapType();
    else if (!atomicValueType(t)) fail(`unknown value type ${t}`);
  };
  const blockType = () => {
    const t = bytes[p];
    if (t === 0x40) byte();
    else if (t === 0x63 || t === 0x64 || atomicValueType(t)) valueType();
    else if (signed() < 0) fail('unknown block type');
  };
  let start = null, code = null;
  while (p < end) {
    const id = byte(), size = unsigned(), next = p + size;
    if (next > end) fail('truncated section');
    if (id === 8) start = unsigned();
    if (id === 10) code = [p, next];
    p = next;
  }
  if (start === null) return;
  const imports = WebAssembly.Module.imports(mod).filter((i) => i.kind === 'function');
  if (start < imports.length) failImport(imports[start]);
  if (code === null) fail('missing start body');
  [p, end] = code;
  const count = unsigned(), bodies = [];
  for (let i = 0; i < count; i++) {
    const size = unsigned(), next = p + size;
    if (next > end) fail('truncated body');
    bodies.push([p, next]);
    p = next;
  }
  const pending = [start], seen = new Set();
  while (pending.length) {
    const index = pending.pop();
    if (seen.has(index)) continue;
    seen.add(index);
    if (index < imports.length) failImport(imports[index]);
    const body = bodies[index - imports.length];
    if (!body) fail('missing function body');
    [p, end] = body;
    const locals = unsigned();
    for (let i = 0; i < locals; i++) { unsigned(); valueType(); }
    while (p < end) {
      const op = byte();
      if (op === 0x00 || op === 0x01 || op === 0x05 || op === 0x0b || op === 0x0f ||
          op === 0x0a || op === 0x19 || op === 0x1a || op === 0x1b || (op >= 0x45 && op <= 0xc4) ||
          op === 0xd1 || op === 0xd3 || op === 0xd4) continue;
      if ((op >= 0x02 && op <= 0x04) || op === 0x06) { blockType(); continue; }
      if (op === 0x07 || op === 0x08 || op === 0x09 || op === 0x18 || op === 0x0c || op === 0x0d || (op >= 0x20 && op <= 0x24) ||
          op === 0xd2 || op === 0xd5 || op === 0xd6) { unsigned(); continue; }
      if (op === 0x10 || op === 0x12) { pending.push(unsigned()); continue; }
      if (op === 0x0e) {
        const n = unsigned(); for (let i = 0; i <= n; i++) unsigned();
        continue;
      }
      if (op === 0x1f) {
        blockType();
        const n = unsigned();
        for (let i = 0; i < n; i++) {
          const kind = byte();
          if (kind <= 1) unsigned();
          unsigned();
        }
        continue;
      }
      if (op === 0x1c) {
        const n = unsigned(); for (let i = 0; i < n; i++) valueType();
        continue;
      }
      if (op === 0x41) { signed(); continue; }
      if (op === 0xd0) { heapType(); continue; }
      if (op === 0x42) { signed(10); continue; }
      if (op === 0x43 || op === 0x44) { skip(op === 0x43 ? 4 : 8); continue; }
      if (op === 0xfb) {
        const sub = unsigned();
        if ([0, 1, 6, 7, 11, 12, 13, 14, 16].includes(sub)) unsigned();
        else if ([2, 3, 4, 5, 8, 9, 10, 17, 18, 19].includes(sub)) { unsigned(); unsigned(); }
        else if (sub >= 20 && sub <= 23) heapType();
        else if (![15, 26, 27, 28, 29, 30].includes(sub)) fail(`GC opcode ${sub}`);
        continue;
      }
      fail(`opcode 0x${op.toString(16)}`);
    }
  }
}
