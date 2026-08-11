// Deno FFI demo for the ABI-2 surface (`include/wazmrt.h`) — the "native FFI -> the C-ABI
// shared library" path, which is how wasmtk would embed wazmrt without going through V8.
//
//   zig build capi-dll
//   deno run --allow-ffi --allow-env examples/deno_ffi_capi.mjs
//
// It does the two things the old wasm-c-api demo could not, and they are the two that decide
// whether this ABI is useful to a loader:
//
//   1. Runs a `.wat` DIRECTLY — no wat2wasm, no temp file, no build step.
//   2. Backs a guest import with a JavaScript callback that READS GUEST MEMORY through the
//      caller handle. Essentially every real loader import needs exactly this, and it is the
//      thing wasm-c-api structurally could not do.

const dllPath = Deno.env.get("WAZMRT_CAPI_DLL") ??
  new URL("../zig-out/bin/wazmrt_capi.dll", import.meta.url).pathname.replace(/^\//, "");

// ---------------------------------------------------------------------------------------
// Value handles over FFI
// ---------------------------------------------------------------------------------------
// `wazmrt_instance_t` and friends are `struct { uint64_t id; }` passed BY VALUE. A struct whose
// sole member is a 64-bit integer is passed in a register exactly like that integer on both
// SysV-x64 and Win64, so it is declared here as a plain "u64". That is the property which makes
// value handles pleasant over FFI: nothing has to model a C struct, and there is no pointer to
// keep alive. Out-parameters are 8-byte buffers.

const lib = Deno.dlopen(dllPath, {
  wazmrt_abi_version:        { parameters: [], result: "u32" },
  wazmrt_version_string:     { parameters: [], result: "pointer" },
  wazmrt_engine_new:         { parameters: [], result: "pointer" },
  wazmrt_engine_delete:      { parameters: ["pointer"], result: "void" },
  wazmrt_store_new:          { parameters: ["pointer"], result: "pointer" },
  wazmrt_store_delete:       { parameters: ["pointer"], result: "void" },
  wazmrt_linker_new:         { parameters: ["pointer"], result: "pointer" },
  wazmrt_linker_delete:      { parameters: ["pointer"], result: "void" },
  wazmrt_functype_new:       { parameters: ["pointer", "usize", "pointer", "usize"], result: "pointer" },
  wazmrt_functype_delete:    { parameters: ["pointer"], result: "void" },
  wazmrt_linker_define_func: { parameters: ["pointer", "pointer", "pointer", "pointer", "pointer", "pointer", "pointer"], result: "pointer" },
  wazmrt_module_new_wat:     { parameters: ["pointer", "pointer", "usize", "pointer"], result: "pointer" },
  wazmrt_module_delete:      { parameters: ["pointer"], result: "void" },
  wazmrt_linker_instantiate: { parameters: ["pointer", "pointer", "pointer", "pointer", "pointer"], result: "pointer" },
  wazmrt_instance_get_func:  { parameters: ["pointer", "u64", "pointer", "pointer"], result: "bool" },
  wazmrt_instance_get_memory:{ parameters: ["pointer", "u64", "pointer", "pointer"], result: "bool" },
  wazmrt_memory_write:       { parameters: ["pointer", "u64", "u64", "pointer", "usize"], result: "bool" },
  wazmrt_func_call:          { parameters: ["pointer", "u64", "pointer", "usize", "pointer", "usize", "pointer"], result: "pointer" },
  wazmrt_caller_read:        { parameters: ["pointer", "u64", "pointer", "usize"], result: "bool" },
  wazmrt_error_message:      { parameters: ["pointer"], result: "pointer" },
  wazmrt_error_delete:       { parameters: ["pointer"], result: "void" },
  wazmrt_trap_message:       { parameters: ["pointer"], result: "pointer" },
});
const S = lib.symbols;

const enc = new TextEncoder();
const cstr = (s) => enc.encode(s + "\0");
const ptr = (b) => Deno.UnsafePointer.of(b);
const cstring = (p) => (p === null ? null : new Deno.UnsafePointerView(p).getCString());

// `wazmrt_val_t` is { int kind; union { ... uint8_t v128[16]; } of; } — 4 bytes of kind, 4 of
// padding, then a 16-byte union at offset 8, so 24 bytes with 8-byte alignment.
const VAL_SIZE = 24;
const VAL_OF = 8;
const WAZMRT_I32 = 0;

function fail(msg) {
  console.error(`FAIL: ${msg}`);
  Deno.exit(1);
}

function checkErr(errPtr, what) {
  if (errPtr === null) return;
  fail(`${what}: ${cstring(S.wazmrt_error_message(errPtr))}`);
}

// ---------------------------------------------------------------------------------------

const version = cstring(S.wazmrt_version_string());
console.log(`wazmrt ${version} (ABI ${S.wazmrt_abi_version()}) via Deno FFI`);

const engine = S.wazmrt_engine_new();
if (engine === null) fail("engine_new");
const store = S.wazmrt_store_new(engine);
const linker = S.wazmrt_linker_new(engine);

// --- the host import: read 4 bytes of GUEST memory and hand them back --------------------
const callback = new Deno.UnsafeCallback(
  {
    parameters: ["pointer", "pointer", "pointer", "usize", "pointer", "usize"],
    result: "pointer",
  },
  (_env, caller, args, nargs, results, nresults) => {
    if (nargs !== 1n || nresults !== 1n) return null;
    const offset = new Deno.UnsafePointerView(args).getInt32(VAL_OF);
    const buf = new Uint8Array(4);
    if (!S.wazmrt_caller_read(caller, BigInt(offset), ptr(buf), 4n)) {
      return null; // a real loader would return a trap here
    }
    const word = new DataView(buf.buffer).getUint32(0, true);
    // Write the result into the engine-provided buffer: kind first, then the payload at the
    // union's offset. The engine zeroed this before the call, so a callback that writes nothing
    // yields a defined value rather than stack garbage.
    const out = new Uint8Array(VAL_SIZE);
    const dv = new DataView(out.buffer);
    dv.setInt32(0, WAZMRT_I32, true);
    dv.setInt32(VAL_OF, word | 0, true);
    new Uint8Array(Deno.UnsafePointerView.getArrayBuffer(results, VAL_SIZE)).set(out);
    return null;
  },
);

const kindI32 = new Int32Array([WAZMRT_I32]);
const ft = S.wazmrt_functype_new(ptr(kindI32), 1n, ptr(kindI32), 1n);
checkErr(
  S.wazmrt_linker_define_func(
    linker, ptr(cstr("env")), ptr(cstr("peek")), ft, callback.pointer, null, null,
  ),
  "linker_define_func",
);

// --- the module, as TEXT ------------------------------------------------------------------
const wat = `(module
  (import "env" "peek" (func $peek (param i32) (result i32)))
  (memory (export "mem") 1)
  (func (export "run") (result i32) i32.const 4 call $peek))`;
const watBytes = enc.encode(wat);

const modOut = new Uint8Array(8);
checkErr(S.wazmrt_module_new_wat(engine, ptr(watBytes), BigInt(watBytes.length), ptr(modOut)), "module_new_wat");
const module = Deno.UnsafePointer.create(new DataView(modOut.buffer).getBigUint64(0, true));
console.log("  ok  ran the .wat directly — no wat2wasm, no temp file");

const instOut = new Uint8Array(8);
const trapOut = new Uint8Array(8);
checkErr(S.wazmrt_linker_instantiate(linker, store, module, ptr(instOut), ptr(trapOut)), "linker_instantiate");
const instance = new DataView(instOut.buffer).getBigUint64(0, true);

// --- plant a value where the guest will ask the host to look -------------------------------
const memOut = new Uint8Array(8);
if (!S.wazmrt_instance_get_memory(store, instance, ptr(cstr("mem")), ptr(memOut))) fail("get_memory");
const memory = new DataView(memOut.buffer).getBigUint64(0, true);

const planted = new Uint8Array(4);
new DataView(planted.buffer).setUint32(0, 0xdeadbeef, true);
if (!S.wazmrt_memory_write(store, memory, 4n, ptr(planted), 4n)) fail("memory_write");

// --- call it -------------------------------------------------------------------------------
const funcOut = new Uint8Array(8);
if (!S.wazmrt_instance_get_func(store, instance, ptr(cstr("run")), ptr(funcOut))) fail("get_func");
const func = new DataView(funcOut.buffer).getBigUint64(0, true);

const results = new Uint8Array(VAL_SIZE);
checkErr(S.wazmrt_func_call(store, func, null, 0n, ptr(results), 1n, ptr(trapOut)), "func_call");
const trapPtr = Deno.UnsafePointer.create(new DataView(trapOut.buffer).getBigUint64(0, true));
if (trapPtr !== null) fail(`trapped: ${cstring(S.wazmrt_trap_message(trapPtr))}`);

const answer = new DataView(results.buffer).getUint32(VAL_OF, true);
console.log(`  ok  host callback read guest memory: 0x${answer.toString(16)}`);

S.wazmrt_module_delete(module);
S.wazmrt_linker_delete(linker);
S.wazmrt_store_delete(store);
S.wazmrt_engine_delete(engine);
callback.close();
lib.close();

if (answer !== 0xdeadbeef) fail(`expected 0xdeadbeef, got 0x${answer.toString(16)}`);
console.log("OK");
