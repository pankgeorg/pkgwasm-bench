import fs from 'node:fs';
import v8 from 'node:v8';
const m=await WebAssembly.compile(fs.readFileSync(process.argv[2]));
console.log('same_process_structured_clone_module='+(structuredClone(m) instanceof WebAssembly.Module));
try {const s=v8.serialize(m);console.log('serialized_bytes='+s.length);console.log('deserialized_module='+(v8.deserialize(s) instanceof WebAssembly.Module));}catch(e){console.log('cross_process_cache_unavailable='+e.message);}
