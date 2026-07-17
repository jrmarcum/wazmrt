# Architecture

## The runtime pipeline

The standard wasm-runtime stages. Only the first is implemented today; each later stage hangs off the
`Module` type.

```text
bytes ──► DECODE ──► VALIDATE ──► INSTANTIATE ──► EXECUTE
          (done)     (done)       (done*)         (done* — see below)
```
*core-MVP + reference types + multi-table + reference-type table ops all run; imported *functions* and
`register`/module-linking are the main remaining execution slices.

- **DECODE** (`Module.decode`) — validate the 8-byte header (`\0asm` magic + version 1), index the
  top-level sections, and decode the type / import / function / table / memory / global / export / code
  sections. Every import and export is resolved to its full `Extern` type (func→signature,
  table/memory→limits, global→content+mutability) by building per-kind index spaces (imported entries
  first, then defined). Each defined function's `Code` (declared locals + raw instruction bytes,
  incl. the terminating `end`) is captured — instructions are **not** parsed here (that happens with
  validation/execution, which pick the internal representation). **Owned via an internal arena** and
  names/bodies are copied in, so the module survives the input buffer being freed (required by
  wasm-c-api, where the caller deletes the byte vector after `wasm_module_new`). Decode **rejects
  malformed binaries**: spec-correct LEB128 (over-long / integer-too-large → `LebOverflow`), reserved
  global-mutability / limits-flag bytes (`MalformedFlag`), undefined value-type bytes (`BadValType`),
  invalid custom-section names, and a data-count section that disagrees with the data segments
  (`DataCountMismatch`). The function/code count-match remains a *validation* rule (checked there). The
  `{id, offset, size}` section extents are retained as metadata only.
- **VALIDATE** (`validate.zig`) — done. The spec's Appendix algorithm (abstract value stack + control
  frames + a `unknown` bottom for polymorphic/unreachable code) over the `opcode.zig` IR: function/code
  count match, local/global/func/type/table index bounds, structured control flow, and operand-stack
  typing. Plus module-level checks: **global-init and element-offset const-exprs** (constant opcode set,
  correct type, `global.get` only of a prior immutable global), **element func indices**, untyped
  `select` (rejects reference operands) vs typed `select_t` (1-type annotation), `call_indirect`
  (table exists + funcref-typed), `if`-without-`else` (params == results), `ref.is_null` (needs a
  reference), and **load/store** (alignment ≤ natural, memory must exist). **Verified:** thousands of
  positive-conformance assertions pass and the negative `assert_invalid`/`assert_malformed` suites now
  run with ~zero over-acceptance — see `testing.md`.
- **INSTANTIATE / EXECUTE** (`interp.zig`) — first slice done. `Instance.init` prepares each defined
  function (decodes body → IR once, precomputes matching `end`/`else` for every `block`/`loop`/`if`).
  `Instance.invoke(name, args)` runs the switch interpreter (Option A): untyped `u64` value slots, a
  per-call label stack, a branch that carries block/loop arity and resets the stack. **Implemented:**
  i32/i64 **and f32/f64** arithmetic/comparison/bitwise, all conversions (incl. trapping float→int,
  IEEE `min`/`max`/`nearest`, reinterpret), locals, **globals** (init const-exprs evaluated — imported
  host values + extended-const `add`/`sub`/`mul`), `drop`/`select` + typed `select`, structured control
  flow with multi-value/type-index block types, direct `call` and **`call_indirect` over multiple
  tables**, **reference types** (`ref.null`/`ref.is_null`/`ref.func`, funcref/externref values), the
  **reference-type table ops** (`table.get`/`.set`/`.size`/`.grow`/`.fill`; tables are `[]Value` slots
  so funcref + externref share one representation), **linear memory** (allocate min pages + active
  data-segment init; load/store all widths, `memory.size`/`grow`), element segments (func-index +
  const-expr forms), **imported functions** (`HostFunc`: a cross-module `wasm` call runs in the
  exporting instance, or a `native` host fn), and traps (`unreachable`, div-by-zero, overflow,
  call-depth, invalid-float→int, out-of-bounds memory/table, uninitialized/mismatched indirect call).
  **Deferred (trap / unbuilt):** imported *tables/memories*, bulk table ops (`table.init`/`.copy`/
  `elem.drop`), passive element segments. **Verified on real modules:** `Instance.invoke` runs the whole `wasm_mod` corpus
  to its `.test.json` expected values (`fib(20)=6765`, `fac(7)=5040`, `sieve(30)=10` via memory) — the
  CLI gained a run mode `wazmrt <file.wasm> <export> [args…]`.

**Text front-end (a separate producer, not a pipeline stage):** `sexpr.zig` (S-expression parser) +
`wat.zig` (WAT text → wasm binary, reuses `opcode.zig` in reverse) + `wast.zig` (WAST script runner:
`assert_return`/`assert_trap`/`invoke`). `wat.zig` output re-enters DECODE; `wast.zig` orchestrates
the whole pipeline and **runs the official spec testsuite** (`wazmrt <file.wast>`). See
`text-toolchain.md`, `testing.md`.

## Module layout & responsibilities

| Unit | Responsibility |
| --- | --- |
| `types.zig` | `magic`, `supported_version`, `SectionId`, `ValType` (binary opcodes), `ExternKind`, `DecodeError`. Dependency-free so it compiles for every target. |
| `Reader.zig` | Allocation-free cursor (file-as-`@This()` struct): `readByte`/`readBytes`/`readU32Le`, spec-correct unsigned + signed LEB (`readVarU32`/`readVarI32`/`readVarI64` reject over-long / integer-too-large), `skipLeb`, float-bit reads. Bounds-checked. |
| `Module.zig` | `decode(gpa, bytes) → Module`; arena-owned; `FuncType`/`Limits`/`TableType`/`MemoryType`/`GlobalType`/`Extern`, `Import`/`Export` (resolved `Extern`), `Local`/`Code`, `func_types`/`functions`/`code`/`globals`/`memories`/`data`/`sections`; `funcType`/`importedFuncCount`/`section` helpers. |
| `opcode.zig` | The shared instruction authority: `Op` enum (core-MVP 0x00–0xC4 + `table.get`/`.set` 0x25/26 + reference types 0xD0–D2 + `0xFC` table ops via internal tags/`fcSubOpcode`), `Imm`/`Instr`, `immediateKind`, `decodeBody`. |
| `validate.zig` | `validate(gpa, module)`: spec Appendix type-check over the IR (value + control-frame stacks) + module-level const-expr / element / select / alignment / memory-presence checks. |
| `interp.zig` | `Instance` (init/deinit/invoke), the switch interpreter (`Frame`, `execNumeric`/`execFloat`/`execMemory`), `Value` (u64) helpers. |
| `sexpr.zig` / `wat.zig` / `wast.zig` | Text toolchain: S-expression parser / WAT-text assembler / WAST script runner (runs the spec testsuite). |
| `wasi.zig` | WASI preview 1 (`wasi_snapshot_preview1`) as native `HostFunc`s over the interpreter's memory (no interp changes): stdio, args/environ, clocks, `poll_oneoff`, random, `proc_exit`, and the **sandboxed filesystem** — `--dir` preopens, a host-fd table, and the security-critical **handle-stack path resolver** `walkFull` that follows symlinks while keeping escape impossible by construction (see `cmem/security-model.md`). The CLI wires it for `_start` command modules. |
| `root.zig` | Public surface; re-exports the pipeline modules + `decode`/`validate`/`interp`/`Instance`/`sexpr`/`wat`/`wast`/`wasi`/`version`/`abi_version`. libc-free. |

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
/* values */               wasm_val_t + wasm_val_vec_new[_empty|_uninitialized]/_copy/_delete,
                           wasm_val_delete/copy
/* instances */            wasm_instance_new(store, module, &imports, &trap) -> own wasm_instance_t*,
                           wasm_instance_exports -> own wasm_extern_vec_t*, wasm_instance_delete
/* externs / funcs */      wasm_extern_kind/type, wasm_extern_as_func[_const],
                           wasm_func_as_extern[_const], wasm_func_type/param_arity/result_arity,
                           wasm_func_call(func, &args, &results) -> own wasm_trap_t* | NULL,
                           wasm_extern_vec_* / wasm_func_delete
/* host funcs (imports) */ wasm_func_new[_with_env], wasm_functype_new,
                           wasm_valtype_vec_new[_empty|_uninitialized]/_copy/_delete
/* globals */              wasm_global_new/type/get/set/delete, extern<->global casts
/* memories */             wasm_memory_new/type/data/data_size/size/grow/delete,
                           extern<->memory casts
/* tables */               wasm_table_new/type/size/delete, extern<->table casts
                           (get/set/grow need a wasm_ref_t model — a later slice)
/* traps */                wasm_trap_new/message/delete
/* wazmrt extension */     wazmrt_abi_version(void), wazmrt_version_string(void)
```

The type objects use the wasm-c-api "is-a externtype" convention: each concrete type is an `extern
struct` whose first field is the extern kind, so `wasm_*type_as_externtype` / `wasm_externtype_as_*type`
are pointer casts and `wasm_externtype_kind` reads the first byte. Every import/export is resolved by
the decoder to its full `Extern` type (see below), so the returned vectors are complete.

**Runtime objects (instantiate + call, DONE 2026-07-14).** `wasm_instance_t` wraps the interpreter's
`Instance`; `wasm_extern_t` and `wasm_func_t` share one internal `Ref` (either an instance-export handle
= kind + instance + func index, or a standalone host func from `wasm_func_new` = callback + owned
functype copy) so `wasm_extern_as_func` is a checked pointer cast. `wasm_val_t` crosses the boundary; the
interpreter's untyped `u64` slots convert per the (validated) signature — numeric kinds fully, refs as
pass-through host pointers. `wasm_func_call` runs `Instance.invokeIndex`; a runtime trap returns a
`wasm_trap_t` carrying the error name.

**Host-function imports (DONE 2026-07-14).** `wasm_func_new[_with_env]` + `wasm_functype_new` +
`wasm_valtype_vec_*` let an embedder supply a C callback for a module's func import.
`wasm_instance_new` maps each func import (in `wasm_module_imports` order) to an `interp.HostFunc`: a
new `native_env` variant carrying a context + a `hostTrampoline` that converts the `u64` args to
`wasm_val_t` (typed by the host func's signature), invokes the callback, converts results back, and
turns a returned `wasm_trap_t` into `error.HostTrap`. An unbacked func import wires a trap-on-call
stub. The C `Instance` wrapper owns the `HostFunc` slice (interp borrows it); the embedder keeps the
host funcs alive until after `wasm_instance_delete`. **Verified from C** (`zig build c-smoke`):
`run(40,2)` whose body is `call $env.add` returns 42 through the host callback.

**Global / table / memory runtime objects (DONE 2026-07-14).** The internal `Ref` now backs these too —
either an instance-export handle (`instance` + `index` locate the object in `inst.globals`/`inst.memory`/
`inst.tables`) or a standalone host object from `wasm_*_new` (`host_global`/`host_memory`/`host_table`).
`wasm_instance_new` maps every import kind: func → host trampoline, **global → value copied in, memory/
table → borrowed shared object** (`interp.Imports.globals`/`memories`/`tables`). Globals: `_get`/`_set`
(mutability-checked) read/write the live slot. Memory: `_data`/`_data_size`/`_size`/`_grow` on the shared
`Instance.Memory` — growing an *exported* memory reallocs the interp's shared bytes, so the running module
observes it. **Verified from C** (`zig build c-smoke`): read/write an exported global, `store` into memory
then read it back via `wasm_memory_data`, and `wasm_memory_grow`. **Deferred:** `wasm_table_get`/`_set`/
`_grow` (need a `wasm_ref_t` funcref/externref object model); a *shared mutable* imported global (the
interpreter value-copies imported globals rather than sharing a pointer, so post-instantiation
`wasm_global_set` on the host global doesn't reach the instance); type `_copy` constructors; module
sharable-ref extras. An undefined symbol in a static lib only errors if a consumer references it, so
partial implementation is honest and safe.

**Conventions (from the standard):** opaque `struct wasm_*_t*` handles; `own`/delete ownership; vectors
are `{ size_t size; T* data; }` the caller owns. **Windows:** consumers compile with `-DLIBWASM_STATIC`
(we ship a static lib; otherwise `wasm.h` marks symbols `__declspec(dllimport)`). Bump `wazmrt_abi_version`
on any wazmrt-extension break.
