# Architecture

## The runtime pipeline

The standard wasm-runtime stages. Only the first is implemented today; each later stage hangs off the
`Module` type.

```text
bytes ──► DECODE ──► VALIDATE ──► INSTANTIATE ──► EXECUTE
          (done)     (done)       (next)          (next)
```

- **DECODE** (`Module.decode`) — validate the 8-byte header (`\0asm` magic + version 1), index the
  top-level sections, and decode the type / import / function / table / memory / global / export / code
  sections. Every import and export is resolved to its full `Extern` type (func→signature,
  table/memory→limits, global→content+mutability) by building per-kind index spaces (imported entries
  first, then defined). Each defined function's `Code` (declared locals + raw instruction bytes,
  incl. the terminating `end`) is captured — instructions are **not** parsed here (that happens with
  validation/execution, which pick the internal representation). **Owned via an internal arena** and
  names/bodies are copied in, so the module survives the input buffer being freed (required by
  wasm-c-api, where the caller deletes the byte vector after `wasm_module_new`). Decode is **lenient**:
  the function/code count-match is a validation rule, not enforced here. The `{id, offset, size}`
  section extents are retained as metadata only.
- **VALIDATE** (`validate.zig`) — done. The spec's Appendix algorithm (abstract value stack + control
  frames + a `unknown` bottom for polymorphic/unreachable code) over the `opcode.zig` IR: function/code
  count match, local/global/func/type index bounds, structured control flow, and operand-stack typing.
  Scope = core-MVP; memory presence + load/store alignment not yet enforced (documented leniency).
  **Verified:** all 12 `wasm_mod` modules validate; across `wasm_wasi`, every fully-decoding module
  validates (failures are only the `UnsupportedOpcode` decode boundary) — see `testing.md`.
- **INSTANTIATE / EXECUTE** (next) — the switch interpreter over the IR (Option A).
- **INSTANTIATE / EXECUTE** (later) — memories/tables/globals + an interpreter (the design space to
  mine from wasm3 / WAMR-fast-interp / wasmi; see `reference-projects.md`).

## Module layout & responsibilities

| Unit | Responsibility |
| --- | --- |
| `types.zig` | `magic`, `supported_version`, `SectionId`, `ValType` (binary opcodes), `ExternKind` (binary order), `DecodeError`. Dependency-free so it compiles for every target. |
| `Reader.zig` | Zero-copy cursor (file-as-`@This()` struct): `readByte`, `readBytes`, `readU32Le`, `readVarU32` (unsigned LEB128). Bounds-checked, allocation-free. |
| `Module.zig` | `decode(gpa, bytes) → Module`; arena-owned; `FuncType`/`Limits`/`TableType`/`MemoryType`/`GlobalType`/`Extern`, `Import`/`Export` (resolved `Extern` type), `Local`/`Code` (locals + raw body), `func_types`, `functions`, `code`, `sections`; `deinit`; `section(id)`. `Error = DecodeError || Allocator.Error`. |
| `root.zig` | Public surface. Re-exports the above + `decode`, `version`, `abi_version`. libc-free. |

## Three consumption surfaces (one core)

The core (`root.zig`) is compiled into three artifacts by `build.zig`:

1. **Native CLI** (`main.zig`) — `zig build` / `zig build run`. Uses the Zig-0.16 `std.process.Init`
   entry + new `Io` API (`Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64<<20))`,
   `Io.File.Writer`). See `design-decisions.md` for the 0.16 API notes.
2. **C-ABI static library** (`wasm_c_api.zig`) — implements the **standard wasm-c-api**. `zig build`
   installs `wazmrt.lib`/`.a` + both headers (`wasm.h`, `wazmrt.h`). Opaque handles; `smp_allocator`
   (no libc). This is what the `universalWasmLoader-*` ports link. Verified from C by `tests/c_smoke.c`.
3. **Freestanding wasm** (`wasm_entry.zig`) — `zig build wasm`, `ReleaseSmall`, `entry = .disabled`,
   `rdynamic = true`, `std.heap.wasm_allocator`. Proves the runtime compiles to wasm and gives web
   loaders a module to instantiate.

## Build graph (`build.zig`)

- `mod` = `addModule("wazmrt", root.zig)` — imported by the CLI and reused as the test root.
- `exe` = CLI, imports `mod`; installed by default; `run` step.
- `cabi` = `addLibrary(.static, wasm_c_api.zig)` + `installHeader(wasm.h)` + `installHeader(wazmrt.h)`;
  installed by default. **Does NOT link libc** (deliberate — see `design-decisions.md`).
- `wasm_exe` = `addExecutable(wasm_entry.zig)` for `wasm32-freestanding`, under the `wasm` step only.
- `mod_tests` = `addTest(mod)` under the `test` step.

## C ABI contract — the standard wasm-c-api

The integration ABI **is** the standard `wasm.h` (vendored, Apache-2.0, at
`third_party/wasm-c-api/include/wasm.h`; ledger in `third_party/LICENSES.md`). `include/wazmrt.h` is a
thin *extension* header (the wasmtime `wasm.h` + `wasmtime.h` pattern) that `#include`s `wasm.h` and
adds only the wazmrt handshake.

**Implemented today** (`src/wasm_c_api.zig`) — the subset the runtime can back:

```c
/* lifecycle */            wasm_config_new/delete, wasm_engine_new[_with_config]/delete,
                           wasm_store_new/delete
/* byte vectors */         wasm_byte_vec_new[_empty|_uninitialized], _copy, _delete
/* modules */              wasm_module_new(store, &binary)   -> own wasm_module_t* | NULL
                           wasm_module_validate(store, &binary) -> bool
                           wasm_module_delete
/* introspection */        wasm_module_imports/exports -> own importtype/exporttype vec
                           + the type-object system: valtype, functype, externtype,
                           globaltype/tabletype/memorytype, importtype, exporttype
                           (kind, as_* casts, params/results, name/module/type, *_vec_delete)
/* wazmrt extension */     wazmrt_abi_version(void), wazmrt_version_string(void)
```

The type objects use the wasm-c-api "is-a externtype" convention: each concrete type is an `extern
struct` whose first field is the extern kind, so `wasm_*type_as_externtype` / `wasm_externtype_as_*type`
are pointer casts and `wasm_externtype_kind` reads the first byte. Every import/export is resolved by
the decoder to its full `Extern` type (see below), so the returned vectors are complete.

**Declared-but-deferred** (in `wasm.h`, unimplemented until instantiation/execution): instance, func,
global, table, memory *runtime objects*, trap, val/ref, type `_copy`/`_new` constructors, and the
module sharable-ref extras. An undefined symbol in a static lib only errors if a consumer references
it, so partial implementation is honest and safe.

**Conventions (from the standard):** opaque `struct wasm_*_t*` handles; `own`/delete ownership; vectors
are `{ size_t size; T* data; }` the caller owns. **Windows:** consumers compile with `-DLIBWASM_STATIC`
(we ship a static lib; otherwise `wasm.h` marks symbols `__declspec(dllimport)`). Bump `wazmrt_abi_version`
on any wazmrt-extension break.
