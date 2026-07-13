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
> segments (active/passive/declarative), and **imported functions** with
> cross-module `register` linking — and runs a corpus of real modules to their
> expected values (`fib(20)=6765`, `sieve(30)=10`, …). It ships a native **WAT
> text assembler** (`.wat` → wasm) and a **WAST script runner** (`wazmrt
> file.wast`) that runs the official WebAssembly spec testsuite (positive
> assertions plus `assert_invalid`/`assert_malformed`/`assert_trap`) — e.g.
> `table_init` 729/0, `table_copy` 1649/0. **Imported tables/memories and WASI**
> are the main features still in progress. Requires Zig 0.16.

## Build

```
zig build                          # CLI + C-ABI static library (+ headers)
zig build run -- <file.wasm>       # summarize a module's sections/exports
zig build run -- <file.wasm> <export> [args…]   # run an exported function
zig build test                     # unit tests
zig build wasm                     # build the runtime itself as a wasm module
```

## Embedding (C ABI)

wazmrt implements the **standard [WebAssembly C API](https://github.com/WebAssembly/wasm-c-api)**
(`wasm.h`), so it embeds exactly like wasmtime or wasmer — the
`universalWasmLoader-*` ports bind to the same ABI. `zig build` installs both
`wasm.h` and the small `wazmrt.h` extension header alongside the static library.

```c
#include "wazmrt.h"   /* pulls in <wasm.h> */

wasm_engine_t *engine = wasm_engine_new();
wasm_store_t  *store  = wasm_store_new(engine);

wasm_byte_vec_t binary;                     /* your .wasm bytes */
wasm_byte_vec_new_uninitialized(&binary, len);
memcpy(binary.data, bytes, len);

if (wasm_module_validate(store, &binary)) {
    wasm_module_t *module = wasm_module_new(store, &binary);
    /* ... */
    wasm_module_delete(module);
}
wasm_byte_vec_delete(&binary);
wasm_store_delete(store);
wasm_engine_delete(engine);
```

Implemented today: engine/store/config lifecycle, byte vectors, module
`new`/`validate`/`delete`, and **import/export introspection**
(`wasm_module_imports`/`exports` + the `valtype`/`functype`/`externtype`/
`importtype`/`exporttype` object system). Instance/function/call follow as
execution lands.
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
