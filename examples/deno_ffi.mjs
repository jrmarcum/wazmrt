// Deno FFI demo: load wazmrt's C-ABI shared library and run a wasm module
// end-to-end through the *standard* wasm-c-api — the vision's
// "native FFI -> the C-ABI shared library" path.
//
//   zig build dll
//   deno run --allow-ffi --allow-env examples/deno_ffi.mjs
//
// It instantiates `(func (export "answer") (result i32) (i32.const 42))`,
// calls the export, and checks the result is 42.

const dllPath = Deno.env.get("WAZMRT_DLL") ??
  new URL("../zig-out/bin/wazmrt.dll", import.meta.url).pathname.replace(/^\//, "");

const lib = Deno.dlopen(dllPath, {
  wasm_engine_new:       { parameters: [], result: "pointer" },
  wasm_store_new:        { parameters: ["pointer"], result: "pointer" },
  wasm_byte_vec_new:     { parameters: ["pointer", "usize", "pointer"], result: "void" },
  wasm_module_new:       { parameters: ["pointer", "pointer"], result: "pointer" },
  wasm_instance_new:     { parameters: ["pointer", "pointer", "pointer", "pointer"], result: "pointer" },
  wasm_instance_exports: { parameters: ["pointer", "pointer"], result: "void" },
  wasm_extern_as_func:   { parameters: ["pointer"], result: "pointer" },
  wasm_func_call:        { parameters: ["pointer", "pointer", "pointer"], result: "pointer" },
  wazmrt_version_string: { parameters: [], result: "pointer" },
});
const S = lib.symbols;

// (module (func (export "answer") (result i32) (i32.const 42)))
const mod = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,             // type () -> i32
  0x03, 0x02, 0x01, 0x00,                               // func 0 : type 0
  0x07, 0x0a, 0x01, 0x06, 0x61, 0x6e, 0x73, 0x77, 0x65, 0x72, 0x00, 0x00, // export "answer"
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,       // code: i32.const 42
]);

const ptrOf = (u8) => Deno.UnsafePointer.of(u8);
const ptrVal = (u8) => Deno.UnsafePointer.value(ptrOf(u8)); // bigint address

const engine = S.wasm_engine_new();
const store = S.wasm_store_new(engine);

// wasm_byte_vec_t binary = { size, data }; wasm_byte_vec_new copies `mod` in.
const binary = new Uint8Array(16);
S.wasm_byte_vec_new(ptrOf(binary), BigInt(mod.length), ptrOf(mod));

const module = S.wasm_module_new(store, ptrOf(binary));
if (module === null) throw new Error("wasm_module_new failed");

const imports = new Uint8Array(16); // empty wasm_extern_vec_t
const trapOut = new Uint8Array(8);
const instance = S.wasm_instance_new(store, module, ptrOf(imports), ptrOf(trapOut));
if (instance === null) throw new Error("wasm_instance_new failed");

// wasm_extern_vec_t exports = { size, data }; data -> array of wasm_extern_t*.
const exportsVec = new Uint8Array(16);
S.wasm_instance_exports(instance, ptrOf(exportsVec));
const exView = new DataView(exportsVec.buffer);
const exCount = exView.getBigUint64(0, true);
const exData = Deno.UnsafePointer.create(exView.getBigUint64(8, true));
if (exCount < 1n) throw new Error("no exports");
const firstExtern = Deno.UnsafePointer.create(new Deno.UnsafePointerView(exData).getBigUint64(0));

const func = S.wasm_extern_as_func(firstExtern);
if (func === null) throw new Error("export is not a function");

// args: empty val_vec. results: a 1-element val_vec pointing at a 16-byte val.
const args = new Uint8Array(16);
const valBuf = new Uint8Array(16);
const results = new Uint8Array(16);
const rView = new DataView(results.buffer);
rView.setBigUint64(0, 1n, true);              // size = 1
rView.setBigUint64(8, ptrVal(valBuf), true);  // data -> valBuf

const trap = S.wasm_func_call(func, ptrOf(args), ptrOf(results));
if (trap !== null) throw new Error("call trapped");

const answer = new DataView(valBuf.buffer).getInt32(8, true); // wasm_val_t.of.i32
const version = new Deno.UnsafePointerView(S.wazmrt_version_string()).getCString();

console.log(`wazmrt ${version} via Deno FFI: answer() = ${answer}`);
if (answer !== 42) {
  console.error(`FAIL: expected 42, got ${answer}`);
  Deno.exit(1);
}
console.log("OK");
