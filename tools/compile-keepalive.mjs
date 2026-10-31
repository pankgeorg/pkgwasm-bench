// Node 24.22.1 can leave WebAssembly.compile unsettled and exit early with
// --no-wasm-lazy-compilation. Keep the event loop alive only while it is pending.
// Use on BOTH sides of the corresponding paired comparison.
const compile = WebAssembly.compile;
WebAssembly.compile = function (...args) {
  const keep = setInterval(() => {}, 1000);
  try {
    return Reflect.apply(compile, this, args).finally(() => clearInterval(keep));
  } catch (error) {
    clearInterval(keep);
    throw error;
  }
};
