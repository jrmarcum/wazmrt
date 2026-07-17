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

> **Scope of the sandbox.** Containment is enforced two ways: **lexically** (a
> guest cannot name a path outside its preopens) and **through the filesystem**
> — path resolution walks one component at a time through directory handles
> (RESOLVE_BENEATH in userspace). **Symlinks are followed** like a real
> filesystem, but a symlink whose target leaves the preopen cannot escape: `..`
> can never rise above the preopen (there is no handle there), absolute targets
> re-base to the preopen root, and a symlink-expansion budget bounds cycles.
> Security is a property of the construction, not of checking target strings.
> One documented residual: a narrow TOCTOU on the final component of `path_open`,
> tied to a Zig std bug on Windows (`cmem/known-issues.md` #17/#18). Creating a
> symlink (`path_symlink`) needs OS privilege on Windows, so it is POSIX-only on
> the write side; *following* host-placed symlinks works everywhere.

Implemented: stdout/stderr/stdin, args/environ, clocks, `poll_oneoff` (clock
sleep), `random_get`, `proc_exit`, and the filesystem (`path_open`, `fd_read`/
`fd_write`/`fd_seek`/`fd_tell`/`fd_pread`/`fd_pwrite`/`fd_sync`, `fd_readdir`,
`*_filestat_get`/`*_filestat_set_times`, `fd_allocate`, create/unlink/rename,
`path_symlink`/`path_readlink`, `path_link`). Not implemented: sockets — those
return `ENOTSUP` rather than trapping, so a module still instantiates and fails
gracefully. Note `path_link`/`path_symlink` need OS support/privilege that is
absent on unprivileged Windows (they return `ENOTSUP` there; both work on POSIX).

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

> **Every function `wasm.h` declares is implemented** — all 319, checked at
> link time on every build (`tests/c_abi_symbols.c` references them all, so a
> missing one breaks our build rather than yours). That includes the pieces
> embedders reach for and runtimes often skip: `wasm_ref_t` and the
> `wasm_ref_as_*` casts, `wasm_table_get`/`set`/`grow`, `host_info` with
> finalizers, trap backtraces (`wasm_trap_origin` / `wasm_trap_trace` /
> `wasm_frame_*`), `wasm_foreign_t`, and module serialize/deserialize/share.
>
> **Object lifetimes are refcounted**, so the usual C-API footguns are not
> footguns here: an instance keeps its module alive, an export handle keeps its
> instance alive, a copy keeps the object alive until the last handle goes, and
> deleting a vector frees each element exactly once — so you can delete a module
> right after `wasm_instance_new`, per the standard. The C entry points are
> tested under an allocator that fails on double-free or leak, including a
> randomized lifecycle fuzz.
>
> Two semantics worth knowing: `wasm_*_copy` on a *reference* (module, instance,
> func, trap, …) returns another handle to the same object — `wasm_*_same` on it
> is true — while a copy of a *type* object is a real deep clone.
> `wasm_module_serialize` returns the original binary: wazmrt interprets a
> decoded IR, so there is no AOT artifact, and `wasm_module_deserialize` simply
> re-decodes. Exception-handling tags exist as type objects only — no module can
> produce one, since EH is deferred.

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
