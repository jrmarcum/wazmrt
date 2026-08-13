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
- **INSTANTIATE / EXECUTE** (`interp.zig`) — first slice done. `Instance.instantiate` /
  `instantiateWithImports` prepare each defined function (decode body → IR once, precompute matching
  `end`/`else` for every `block`/`loop`/`if`). ⚠️ **They take a DESTINATION POINTER and do not return
  an `Instance`** (renamed from `init`/`initWithImports` in R2, 2026-08-13): an instance's address is
  part of its identity — every `funcref` it creates names it, and element segments create funcrefs
  before instantiation returns — so it cannot be built somewhere else and moved. Instantiation splits
  into `allocate` (§4.5.4) and `applyActiveSegments` (§4.5.5); an instance whose segment init traps
  stays alive, adopted by its `Store`, because entries it already wrote into an imported table must
  keep working. **Reference values live in an `interp.Store`** shared by every linked instance — see
  `known-issues.md` → "Reference identity across a link".
  `Instance.invoke(name, args)` runs the switch interpreter (Option A): untyped `u64` value slots, a
  per-call label stack, a branch that carries block/loop arity and resets the stack. **Implemented:**
  i32/i64 **and f32/f64** arithmetic/comparison/bitwise, all conversions (incl. trapping float→int,
  IEEE `min`/`max`/`nearest`, reinterpret), locals, **globals** (init const-exprs evaluated — imported
  host values + extended-const `add`/`sub`/`mul`), `drop`/`select` + typed `select`, structured control
  flow with multi-value/type-index block types, direct `call` and **`call_indirect` over multiple
  tables**, **reference types** (`ref.null`/`ref.is_null`/`ref.func`, funcref/externref values), the
  **reference-type table ops** (`table.get`/`.set`/`.size`/`.grow`/`.fill`; tables are `[]Value` slots
  so funcref + externref share one representation — ⚠️ a funcref slot holds
  `(store_slot+1)<<32 | func_index`, **not** a bare function index, so a table shared across a link
  means the same thing to every sharer), **linear memory** (allocate min pages + active
  data-segment init; load/store all widths, `memory.size`/`grow`), element segments (func-index +
  const-expr forms), **imported functions** (`HostFunc`: a cross-module `wasm` call runs in the
  exporting instance, or a `native` host fn), and traps (`unreachable`, div-by-zero, overflow,
  call-depth, invalid-float→int, out-of-bounds memory/table, uninitialized/mismatched indirect call).
  **(All since built — this bullet describes the 2026-07 MVP core; imported tables/memories, bulk
  table/memory ops, passive elements/data, GC, multi-memory, memory64, threads/atomics, SIMD, and exception
  handling are ALL done — see `roadmap.md`/`overview.md` for the current proposal set.)** **Verified on real modules:** `Instance.invoke` runs the whole `wasm_mod` corpus
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
   installs `wazmrt.lib`/`.a` + both headers (`wasm.h`, `wazmrt.h`) + the attribution files that must
   ship with them (`LICENSE.wasm-c-api`, `NOTICE`). Opaque handles; `smp_allocator`
   (no libc). This is what the `universalWasmLoader-*` ports link. Verified from C by `tests/c_smoke.c`.
3. **Freestanding wasm** (`wasm_entry.zig`) — `zig build wasm`, `ReleaseSmall`, `entry = .disabled`,
   `rdynamic = true`, `std.heap.wasm_allocator`. Proves the runtime compiles to wasm and gives web
   loaders a module to instantiate.

## Build graph (`build.zig`)

- `mod` = `addModule("wazmrt", root.zig)` — imported by the CLI and reused as the test root.
- `exe` = CLI, imports `mod`; installed by default; `run` step.
- `cabi` = `addLibrary(.static, wasm_c_api.zig)` + `installHeader(wasm.h)` + `installHeader(wazmrt.h)`;
  installed by default. **Does NOT link libc** (deliberate — see `design-decisions.md`). Since
  2026-08-10 the install step also copies **`LICENSE.wasm-c-api`** (the vendored header's Apache-2.0
  text) and **`NOTICE`** into `zig-out/include/`, via `b.getInstallStep().dependOn(addInstallFile(…))`
  so they ship even when only the library is built — `wasm.h` is Apache-2.0 only and §4(a) binds on
  distribution, not on the repo. Ship `zig-out/include/` **whole**; see `licensing.md` + `overview.md`.
- `wasm_exe` = `addExecutable(wasm_entry.zig)` for `wasm32-freestanding`, under the `wasm` step only.
- `mod_tests` = `addTest(mod)` under the `test` step; `cabi_tests` = `addTest(wasm_c_api.zig)` (re-runs
  the core tests + the C-ABI tests under `std.testing.allocator`), also under `test`.
- `wasi-gate` step = compiles real `wasm32-wasi` guests and runs them through `exe` asserting stdout:
  a Zig guest (`hello_compiled.zig`, built by the build graph) + a C guest (`c_hello.c` via `zig cc`),
  both always-on; a Rust guest (`rust_hello.rs` via `rustc`) behind `-Drust-gate=true`. The
  compiled-program conformance gate — see `testing.md` and the invariant in `design-decisions.md`.

## C ABI contract — the native `wazmrt.h` (ABI 2)

**The integration ABI is `include/wazmrt.h`: 77 functions, implemented by `src/capi.zig`.** It is
wasmtime-*shaped* under our own names — not the standard wasm-c-api, and not wasmtime's symbols.

⚡ **REPLACED 2026-08-11.** wazmrt shipped the vendored wasm-c-api (`wasm.h`, 319 declared functions,
`src/wasm_c_api.zig`) from 2026-07-02 until then. It was deleted outright, and with it
`third_party/wasm-c-api/`. The reasoning is in `vision.md` (the falsified payoff) and
`design-decisions.md`; the short version is that it could not do the intended consumer's core job and
concentrated every C-ABI audit finding this project has ever had.

### The three things that define this surface

1. **Value handles, not refcounted objects.** `wazmrt_instance_t`/`_func_t`/`_memory_t`/`_global_t` are
   `struct { uint64_t id; }` encoding `(store_id << 32) | (slot + 1)`. The host never frees one.
   Validity is decided by LOOKUP in the owning store, so a handle from another store, from a deleted
   store, or an all-zero one a caller forgot to fill in, is *rejected* rather than naming someone
   else's resource. Slot 0 is never used precisely so a zeroed handle is invalid by construction.
   ⚠️ **This is the fix for the #20/#21/#22 class.** There is no count to get wrong and no ownership
   transfer, so the double-free / use-after-free / uninitialised-refcount family cannot be expressed.
   Opaque pointers (engine/store/module/linker/trap/error) remain ordinary C: one owner, one `_delete`.
2. **Caller-based host callbacks.** `wazmrt_caller_read`/`_write`/`_memory_size` read and write GUEST
   memory from inside a callback. wasm-c-api structurally could not, which is the load-bearing reason
   it was replaced.
3. **`.wat` as a first-class input.** `wazmrt_module_new_wat` assembles, decodes and validates text
   in-process; `wazmrt_wat_to_wasm` hands back the binary to cache. No other embeddable runtime offers
   this. ⚠️ The saving is a PIPELINE (no converter process, no temp file), not decode time.

### Contract rules

- **Errors and traps are different channels.** A function returning `wazmrt_error_t*` returns NULL on
  success; a guest trap arrives through a separate `wazmrt_trap_t**` out-param. A call can return no
  error and still have trapped — check both.
- **Host/guest signatures are cross-checked at link time.** Two declarations exist (the module's and
  the linker's), so they are compared rather than trusted; a mismatch fails instantiation naming the
  import. Guest-to-guest imports via `define_instance` are checked the same way.
- **Concurrency comes from multiple engines.** An engine carries a single-threaded `std.Io` and
  everything reachable from it is single-threaded. An async/threaded host gives each concurrent
  context its own engine; they share nothing.
- **All five resource ceilings are enforced** (memory, table elements, GC objects, exception boxes,
  call depth), re-checked by the interpreter at run time rather than only at instantiation.
- **Per-proposal gating is real** (`src/features.zig`): a disabled proposal makes a module INVALID at
  `wazmrt_module_new` *and* `wazmrt_module_validate`. Gating inspects types as well as code, because a
  module can need a proposal without executing one of its instructions.
- **Deliberately absent, and additive later without moving `WAZMRT_ABI_VERSION`:** tables, multi-value
  returns, host-side imported memories/tables. No surveyed consumer needs them and an unused symbol is
  pure size. `wazmrt_caller_get_memory` exists but always returns false — a durable memory handle must
  be tagged against a live store and the store is mid-borrow during a callback; use `caller_read`.
- **Bump `root.abi_version`** on any breaking change. It is **2**; version 1 was the wasm-c-api
  surface, and nothing from it survives, so a v1 consumer fails to LINK rather than mislinking.
- **The link-time completeness gate is `tests/wazmrt_abi_symbols.c`**, GENERATED from the header, so it
  cannot drift by typo. A symbol declared but not defined breaks our build, not an embedder's.

<!--
RETIRED 2026-08-11 — the wasm-c-api surface this section used to document. Kept only as a marker that
it existed; the implementation, the vendored header, its tests and its Deno demo are all deleted. Do
not restore this list; see the git history if the detail is ever needed.

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
`_grow` (need a `wasm_ref_t` funcref/externref object model); ~~a *shared mutable* imported global (the
interpreter value-copies imported globals rather than sharing a pointer, so post-instantiation
`wasm_global_set` on the host global doesn't reach the instance)~~ — ⚠️ **the interpreter limitation
behind that one is GONE as of 2026-08-13 (R2): `Instance.Global` is a shared cell and imported
globals are borrowed, so the ABI-2 `define_instance` path now shares mutable globals for real**;
type `_copy` constructors; module
sharable-ref extras. An undefined symbol in a static lib only errors if a consumer references it, so
partial implementation is honest and safe.

**Conventions (from the standard):** opaque `struct wasm_*_t*` handles; `own`/delete ownership; vectors
are `{ size_t size; T* data; }` the caller owns. **Windows:** consumers compile with `-DLIBWASM_STATIC`
(we ship a static lib; otherwise `wasm.h` marks symbols `__declspec(dllimport)`). Bump `wazmrt_abi_version`
on any wazmrt-extension break.
-->

⚠️ **`-DLIBWASM_STATIC` is no longer needed.** It was a wasm-c-api requirement; `wazmrt.h` declares
nothing `__declspec(dllimport)`, so a consumer compiles the same way against the static library or
the DLL.
