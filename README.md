# wazmrt

A Zig-based WebAssembly runtime aimed at being **blazingly fast** and the
**smallest possible binary** — and itself compilable to wasm, so it can be
embedded into any language via the `universalWasmLoader-*` loaders
(jvm, c, go, dotnet, dart, rs, py, v, zig, js).

Built by studying the best and fastest parts of the leading wasm runtimes and
adopting — with full attribution — only what earns its place. See
[`third_party/LICENSES.md`](third_party/LICENSES.md) for the evaluation and
compliance process, and for the ledger of any reused code.

> **Status:** early but running. wazmrt decodes, validates, and **executes**
> WebAssembly — integer/float arithmetic, control flow, `call`/`call_indirect`
> (multi-table), linear memory, globals, reference types, the reference-type
> table ops, **bulk table ops** (`table.init`/`table.copy`/`elem.drop`), element
> segments (active/passive/declarative), **imported functions, tables, memories,
> and globals** with cross-module `register` linking and full import type-checking,
> the **function-references proposal** (typed function refs, `call_ref`,
> `ref.as_non_null`, `br_on_null`, non-null refs with local-initialization
> checking), and **WasmGC** — `i31` references (`ref.i31`, `i31.get_s`/`_u`),
> **struct and array** heap objects (`struct.new`/`get`/`set`, `array.new`/
> `new_fixed`/`get`/`set`/`len`, `ref.eq`, packed `i8`/`i16` fields), casts
> (`ref.test`/`ref.cast`, `br_on_cast`/`br_on_cast_fail`), **concrete
> `(ref $t)` references** (self-referential structs, exact-type params), and
> declared subtyping (`(sub $super …)`) over the `any`/`eq`/`i31`/`struct`/
> `array` reference hierarchy — and runs a corpus of real modules to their
> expected values
> (`fib(20)=6765`, `sieve(30)=10`, …). It ships a native **WAT text assembler**
> (`.wat` → wasm) and a **WAST script runner** (`wazmrt file.wast`) that runs the
> official WebAssembly spec testsuite (positive assertions plus
> `assert_invalid`/`assert_malformed`/`assert_trap`/`assert_unlinkable`) — e.g.
> `table_init` 729/0, `table_copy` 1649/0, `imports` 137, `call_ref` 30, `start`
> 11/0. It runs a module's **start function** at instantiation, embeds through
> the **standard wasm-c-api** (instantiate/call, host-function imports,
> global/memory/table objects — loadable over FFI, see below), and runs **WASI
> preview 1** command modules — including real LLVM-compiled `wasm32-wasi`
> programs: stdout/stderr, args/environ, clocks, `poll_oneoff` (sleep), stdin,
> random, `proc_exit`, and a **sandboxed filesystem** rooted at the directories
> you preopen with `--dir` (sockets deferred). Coming next: CLI ergonomics
> (`--env`), broader compiled-program conformance, plus multi-memory and
> exception-handling tags as needed. Requires Zig 0.16.

## Build

```
zig build                          # CLI + C-ABI static library (+ headers)
zig build run -- <file.wasm>       # summarize, or run _start (WASI command)
zig build run -- <file.wat>        # assemble .wat, then the same
zig build run -- <file.wasm> <export> [args…]   # run an exported function
zig build test                     # unit tests
zig build wasm                     # build the runtime itself as a wasm module
zig build dll                      # C-ABI shared library (for FFI: Deno, ctypes, …)
zig build c-smoke                  # build + run the C example (needs no external deps)
zig build ffi-demo                 # build the DLL + run examples/deno_ffi.mjs (needs deno)
zig build bench                    # interpreter microbenchmark (ReleaseFast)
```

The runtime loads over FFI from any host language: `zig build dll` produces a
libc-free `wazmrt.dll`, and [`examples/deno_ffi.mjs`](examples/deno_ffi.mjs)
`Deno.dlopen`s it and drives the standard wasm-c-api to instantiate and call a
module — no wasmtime, no JS engine in the path.

## Running WASI programs

Compile a program to `wasm32-wasi` with any toolchain and run it:

```
zig build-exe examples/hello_compiled.zig -target wasm32-wasi -O ReleaseSmall -femit-bin=hello.wasm
wazmrt hello.wasm                       # prints via ordinary std stdout
```

A module exporting `_start` runs as a WASI command. Anything after the module
path is passed through as the guest's `argv`, except the preopen flags:

```
wazmrt files.wasm --dir ./data:/data -- app args…
```

`--dir <host>[:<guest>]` **preopens** a host directory and is the guest's *only*
route to the filesystem: with no `--dir`, a guest has no reachable files at all,
and with one it can reach that directory and nothing above it. The guest sees it
under `<guest>` (defaulting to the host path). wazmrt resolves guest paths itself
and refuses absolute paths, `..` escapes, and NT/device prefixes — an interior
`..` that stays inside is fine. See [`examples/wasi_files.zig`](examples/wasi_files.zig).

> **Scope of the sandbox.** Containment is *lexical*: a guest cannot name a path
> outside its preopens. A **symlink inside a preopen that points outside it is
> still followed**, so do not treat this as a boundary against a hostile module —
> it is meant for running your own programs against your own directories. Details
> and the fix path: `cmem/known-issues.md` (#17).

Implemented: stdout/stderr/stdin, args/environ, clocks, `poll_oneoff` (clock
sleep), `random_get`, `proc_exit`, and the filesystem (`path_open`, `fd_read`/
`fd_write`/`fd_seek`/`fd_tell`/`fd_pread`/`fd_pwrite`/`fd_sync`, `fd_readdir`,
`*_filestat_get`, create/unlink/rename). Not implemented: sockets, symlink ops,
and `*_filestat_set_times` — these return `ENOTSUP` rather than trapping, so a
module still instantiates and fails gracefully.

> **Writing a WASI guest in Zig:** call the imports via `std.os.wasi`, not your
> own `extern "wasi_snapshot_preview1"` declarations. If your signature differs
> from std's, wasm-ld silently redirects the call to a trapping stub and the
> program dies with no diagnostic — see the note in
> [`examples/wasi_files.zig`](examples/wasi_files.zig).

## Embedding (C ABI)

wazmrt implements the **standard [WebAssembly C API](https://github.com/WebAssembly/wasm-c-api)**
(`wasm.h`), so it embeds like wasmtime or wasmer — the `universalWasmLoader-*`
ports bind to the same ABI. `zig build` installs both `wasm.h` and the small
`wazmrt.h` extension header alongside the static library.

> **Supported subset.** `wasm.h` is the upstream header, and wazmrt implements
> the part an embedder actually drives: engine/store, module decode + validate +
> introspection, instantiate, `wasm_func_call`, host-function imports, global /
> memory / table objects, traps *including the `wasm_trap_origin` /
> `wasm_trap_trace` / `wasm_frame_*` backtrace*, and the vector/type machinery
> behind those. Not yet implemented — and therefore a **link error** if you call
> them: the `wasm_*_copy` / `_same` / `*_host_info` boilerplate, `wasm_ref_t` and
> the `wasm_ref_as_*` casts (which also gate `wasm_table_get`/`set`/`grow`),
> `wasm_foreign_*`, `wasm_tagtype_*`, and module serialize/deserialize/share.
> Tracked with a reproducible audit in `cmem/known-issues.md` (#20) — tell us
> which you need.

```c
#include "wazmrt.h"   /* pulls in <wasm.h> */

wasm_engine_t *engine = wasm_engine_new();
wasm_store_t  *store  = wasm_store_new(engine);

wasm_byte_vec_t binary;                     /* your .wasm bytes */
wasm_byte_vec_new_uninitialized(&binary, len);
memcpy(binary.data, bytes, len);

wasm_module_t *module = wasm_module_new(store, &binary);

/* Instantiate and call an exported function. */
wasm_trap_t *trap = NULL;
wasm_extern_vec_t no_imports; wasm_extern_vec_new_empty(&no_imports);
wasm_instance_t *inst = wasm_instance_new(store, module, &no_imports, &trap);

wasm_extern_vec_t exports; wasm_instance_exports(inst, &exports);
wasm_func_t *add = wasm_extern_as_func(exports.data[0]);

wasm_val_t a[2] = { {.kind=WASM_I32,.of={.i32=40}}, {.kind=WASM_I32,.of={.i32=2}} };
wasm_val_vec_t args, results;
wasm_val_vec_new(&args, 2, a);
wasm_val_vec_new_uninitialized(&results, 1);
wasm_func_call(add, &args, &results);        /* -> results.data[0].of.i32 == 42 */
```

Implemented today: engine/store/config lifecycle, byte vectors, module
`new`/`validate`/`delete`, **import/export introspection**
(`wasm_module_imports`/`exports` + the `valtype`/`functype`/`externtype`/
`importtype`/`exporttype` object system), **instantiate + call**
(`wasm_instance_new`/`exports`, `wasm_extern_as_func`, `wasm_func_call`,
`wasm_val_t`, `wasm_trap_*`), **host-function imports**
(`wasm_func_new`/`wasm_functype_new` — supply a C callback for a module's
imported function), and **global/table/memory objects** (`wasm_global_get`/
`set`, `wasm_memory_data`/`size`/`grow`, `wasm_table_size`, `wasm_*_new` for
imports). `zig build c-smoke` builds and runs the C example.
On Windows, compile consumers with `-DLIBWASM_STATIC` (wazmrt ships a static
library). See [`tests/c_smoke.c`](tests/c_smoke.c) for a complete example.

## License

Licensed under either of, at your option:

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

```
SPDX-License-Identifier: MIT OR Apache-2.0
```

This dual license is the WebAssembly/Rust ecosystem standard. It lets consumers
in any language pick whichever license fits their project, and it is compatible
with incorporating code from every reference runtime (all permissive: MIT, ISC,
Apache-2.0, and Apache-2.0 WITH LLVM-exception). Third-party code we incorporate
stays under its own license and is tracked in
[`third_party/LICENSES.md`](third_party/LICENSES.md).

### Contributing

Unless you explicitly state otherwise, any contribution you intentionally submit
for inclusion in the work, as defined in the Apache-2.0 license, shall be
dual-licensed as above (`MIT OR Apache-2.0`), without any additional terms or
conditions.
