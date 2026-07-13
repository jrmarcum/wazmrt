# Known Issues — deferred fixes + their surfacing conditions

Findings from the **2026-07-09 code audit** ("look for code issues") that were **reported but not
fixed** — each is safe *today* but will bite a specific future integration. The point of this file is
the **"Surfaces when"** field: before starting one of those integrations, grep this file for the
milestone and fix the listed items first.

The audit's *fixed* items are in git (commit `d1fae13` — table-export index, instantiation-path leaks,
`parseGlobal` OOB, `table.size/grow` `@intCast` panic, dead `ExportNotFunction`, stale doc comments).
This file tracks only what's left.

Line numbers are hints (they drift) — the function/construct name is the durable anchor.

## RESOLVED 2026-07-09 (second pass — commit `645874c`)

Adding `assert_invalid`/`assert_malformed`/`assert_exhaustion` to the WAST runner made the
soundness gaps observable, so they were fixed together:
- **#5 DONE** — `assert_trap` now accepts only a genuine runtime trap (`isRuntimeTrap`).
- **#7 DONE** — const-expr `global.get` restricted to a prior *immutable* global.
- **#2a/#2b/#2c/#2d DONE** — untyped `select` rejects ref operands; `select_t` needs a 1-type
  annotation; load/store require a memory + alignment ≤ natural; `if`-without-`else` needs
  params == results. Also added: global-init const-expr validation, element-segment validation,
  and `call_indirect` table-exists + funcref-typed checks.
- **#6 PARTIAL** — reserved global-mutability / limits-flag bytes now rejected (`MalformedFlag`);
  the invalid *valtype* byte (non-exhaustive `ValType` `@enumFromInt`) is still accepted.
- **#1 PARTIAL** — top-level `(import … (global …))` is now assembled; func/table/memory imports
  error honestly instead of being dropped (still need real host imports).
- **#8 DONE** — `align=` over-natural is now a validation error (the assembler still doesn't reject a
  non-power-of-two `align=` literal, but no test exercises that path).

Third pass (commit `c535de0`):
- **#2e DONE** — `ref.is_null` rejects a non-reference operand.
- **#6 DONE** — the decoder validates value-type bytes (`readValType` / `ValType.isValid`) in func
  types, table element types, global content, and locals (reserved mutability/limits bytes were
  already rejected). The `select_types` / `ref.null` heaptype immediates in `opcode.zig` are still
  unvalidated, but those are instruction-level, not module structure.
- **#2f NOT A BUG** — investigated and closed: the `pop_vals`/`push_vals` chain already cross-checks
  `br_table` label *value types* (not just arity) even in polymorphic code. Verified empirically —
  different-typed labels are rejected, same-typed accepted. No change needed.

Still open: #9, #10, #11 (defined-table inline export only), #12, #13, plus #16 (rest, LOW). **#1 (all 3
stages), #3, #4, #5, #14, #15 are resolved** (see below). Next tractable wins: invoke-by-module-name in
the WAST runner (blocks more of `linking.wast`), #11's defined-table inline export, then the LOW items.
Larger out-of-scope boundaries surfaced by the suite: the **multi-memory** proposal (`start0`) and
exception-handling **tags** (`imports` "test" module).

## Grouped by the integration that trips them

- **`register` / multi-module linking + imported functions** (host imports → WASI): #1 **DONE — all
  three stages** (2026-07-13). Stage 1 imported funcs + register; stage 2 imported tables/memories via
  shared `Memory`/`Table` objects; stage 3 link-time import type-checking + `assert_unlinkable`. #4
  (non-spectest imported global → 0) **also resolved** by stage 3. Only #10 (global index order, LOW)
  remains in this group. `imports.wast` 26 → **132**.
- **`assert_invalid` / `assert_malformed` support in the WAST runner**: #2 (validator
  over-acceptance, all sub-items), #7 (const-expr `global.get` strictness), #6 (invalid valtype byte),
  #8 (`align=` non-power-of-two). These are *soundness / spec-strictness* gaps — invisible until the
  runner actually executes the negative tests (today they're counted as `skipped`).
- **Start-function support**: #3 **DONE** (`07dd244`).
- **Host externref values** (embedding API passes real externrefs): #9 (`null_ref` collision).
- **Arbitrary / hand-written WAT** (beyond the testsuite's shape): #11 (inline `(table (export …))` on a
  *defined* table — the imported-table case is done), #12 (`align=` malformed), #10 (import-after-def
  ordering).
- **Any future extended-const op that interns a signature**: #13 (type-section ordering, latent).
- **Test fidelity, always-on**: #5 (`assert_trap` accepts any error — silently green-washes producer
  bugs *now*).

---

## The list

### #1 — Host imports / `register` — **DONE, all three stages (2026-07-13)**
- **Stage 1 (`bcf3a11`)** — imported **functions** + **`register`**: `Instance.HostFunc`
  (`wasm{instance,func_index}` | `native fn`) dispatched from `callFunction`; the WAST runner keeps a
  module registry; the assembler emits the import section for top-level/inline func imports.
  `func_ptrs` 29/2 → 32/0.
- **Stage 2 (`78c6b2b`)** — imported **tables & memories** as shared objects. Linear memory and tables
  became `*Memory{bytes,max}` / `*Table{entries,max}`: a defined one is owned/freed by its instance, an
  imported one (low indices) borrows a host-supplied object and is left alone at deinit. `memory.grow` /
  `table.grow` mutate the shared object in place so importers observe the new size. The runner backs
  `spectest.memory` (1 page, max 2) and `spectest.table` (10 funcref, max 20); the assembler emits
  `(import … (table|memory …))` (kinds 0x01/0x02) with imports taking the low indices. `data` 31 → 34/0,
  `elem` 47 → 52.
- **Stage 3 (`1d6d9f2`)** — link-time **import type-checking** + `assert_unlinkable`: funcs by exact
  signature, globals by content+mutability, tables/memories by element type + limits subtyping
  (`limitsFit`). Unknown name → `UnresolvedImport`; type mismatch → `IncompatibleImportType`;
  `assert_unlinkable` passes iff building fails with such a link error. `imports.wast` 44 → **132/32/7**.
**Remaining imports/linking failures are separate feature gaps** — invoke-by-module-name (the runner's
`invoke` only targets the current module), inline `(table (export …) …)` (#11), tag imports, memory64 —
and `(start …)` (#3, still dropped). `linking.wast`/`memory.wast` complete only under ReleaseFast (debug
is too slow on their large grow tests), 19/84 and 66/13.

### #2 — Validator over-acceptance (soundness) — MED
`src/validate.zig` — several rules accept invalid modules. Not a wrong-output risk (execution traps
safely); purely "should have been rejected at validation."
- **2a** untyped `select` (0x1b) accepts reference-typed operands (spec: numeric/vector only). `step`
  `.select, .select_t` (~264).
- **2b** `select_t` (0x1c) ignores its `select_types` immediate — never checks operands against the
  annotation, and for polymorphic (`unknown`) operands pushes `t1`/`t2` instead of the annotated type.
- **2c** load/store validated without requiring a memory section (and alignment never checked). A
  module with `i32.load` but no memory **passes validation**, then traps at runtime with `NoMemory`.
  When fixing, account for *imported* memory (`module.memories.len` includes imports).
- **2d** `if` with params but no `else` doesn't enforce `params == results`.
- **2e** `ref.is_null` pops any operand, not just a reference type.
- **2f** `br_table` cross-label check is arity-only; in stack-polymorphic (post-`unreachable`) code,
  labels with equal arity but different value types aren't rejected.
**Surfaces when:** the WAST runner implements `assert_invalid` (today those commands are `skipped`, so
the gaps are invisible). **Fix:** tighten each rule; verify against the `*.wast` `assert_invalid`
blocks once the runner supports them (and re-baseline — stricter validation could reject a module that
currently builds if the check is wrong).

### #3 — Start function — **DONE (`07dd244`, 2026-07-13)**
Implemented end to end: `Module.decode` reads the start section (id 8) into `start: ?u32`; `validate`
checks the start func exists and has type `[] → []` (`UndefinedFunc` / `InvalidStartFunction`);
`interp.Instance.runStart()` runs it (no args) right after instantiation — called by the WAST runner and
CLI, so a trap during start fails instantiation; the assembler emits `(start $f|N)` as section 8. Also
added the `(memory (data "…"))` abbreviation and inline `(memory (import …))` / `(table (import …))`
imports (the memory export-skip loop had silently mis-parsed an inline import as a *defined* memory).
`start.wast` 0 → **11/0/0**, `imports` 132 → 137, `memory` 66 → 69. **Out of scope:** `start0.wast`'s
3 fails are the **multi-memory** proposal (memory-indexed loads `i32.load8_u $n` on a >1 memory space).

### #4 — Non-`spectest` imported global silently defaults to 0 — **RESOLVED (`1d6d9f2`, #1 stage 3)**
`resolveGlobalImport` now resolves a global import to a registered module's exported global (its live
value from the exporting instance) or a known `spectest` global, and errors (`UnresolvedImport` /
`IncompatibleImportType`) instead of defaulting to 0. The type is checked (content + mutability) too.

### #5 — `assert_trap` fidelity — **RESOLVED (`645874c`, extended `c0c7de2`)**
`src/wast.zig` `assertTrap` now accepts only a genuine runtime trap (`isRuntimeTrap` — an
assemble/decode/`UnsupportedInstr` error no longer green-washes as a trap). The `c0c7de2` pass added the
`assert_trap (module …)` form: it builds the inner module in isolation and requires an
instantiation-time runtime trap (e.g. an out-of-bounds active data/element segment). Matching the
expected trap *text* is still not done (LOW — no test depends on it).

### #6 — Invalid value-type bytes decode silently — MED/LOW
`src/Module.zig` (`readValTypes`, `readTableType`, `readGlobalType`, `decodeLocals`) and `src/opcode.zig`
(`select_types`, `ref_type`) use `@enumFromInt(byte)` into the **non-exhaustive** `types.ValType`, so a
garbage byte becomes an out-of-range enum with no `error.BadValType` (contrast `ExternKind`/`SectionId`,
which *do* guard). **Surfaces when:** `assert_malformed` support, or any untrusted/fuzzed binary input.
**Fix:** validate the byte against the known valtypes on decode.

### #7 — const-expr `global.get` more permissive than spec — LOW
`src/interp.zig` — `evalConstExpr` allows `global.get` of any *prior* global; §3.3.7 restricts
const-expr `global.get` to *imported* globals. Bounds-checked, so no crash/wrong-value — a strictness
gap only. **Surfaces when:** `assert_invalid` support.

### #8 — `align=` non-power-of-two silently `@ctz`'d — LOW
`src/wat.zig` — `emitMemArg` (~911): `align_log2 = @ctz(bytes)` with no power-of-two check, so
`align=3` encodes `@ctz(3)=0` instead of erroring. **Surfaces when:** malformed hand-written WAT or
`assert_malformed`. **Fix:** reject non-power-of-two alignment.

### #9 — externref value can collide with the `null_ref` sentinel — LOW (by design today)
`src/interp.zig` — `null_ref = maxInt(u64)` doubles as "uninitialized table entry" and the `ref.null`
value. A host externref whose payload is exactly `2^64-1` is misclassified by `ref.is_null` and the
`call_indirect` uninitialized-element check. Funcrefs (function indices) can never hit this.
**Surfaces when:** a real host passes externref values through the embedding API (none exist yet).
**Fix:** represent refs as a tagged pair, or reserve the sentinel out of the host-value space.

### #10 — Global index space assigned in textual order (no imports-first enforcement) — LOW
`src/wat.zig` — `parseGlobal` assigns `global_names` indices in textual order; the binary always places
imported globals (import section) before defined globals (global section). If a *defined* global
textually precedes an *imported* one, textual index ≠ binary index and every `$name`→index resolution
/ global export is off. Well-formed WAT requires imports first, so defensible. (Same structural
assumption for the func index space, but wat emits no function imports yet.) **Surfaces when:** #1's
func imports land, or hand-written WAT violates imports-first ordering. **Fix:** enforce or reorder
(imports first) when building the index spaces.

### #11 — inline `(table (export …) …)` on a *defined* table — LOW (PARTIAL, fails loud)
`src/wat.zig` — the `(table …)` module-field branch now handles inline `(export …)` on an *imported*
table (the `07dd244` inline-import path), but a **defined** table with an inline export
(`(table (export "t") 1 funcref)`) still falls through to `parseTable`, whose `(export …)` list hits
`parseIndex` → `error.BadImmediate`. Errors out (not wrong bytes). **Fix:** thread the leading inline
`(export …)` forms parsed in the branch into `parseTable` (or handle the whole defined-table case in the
branch, mirroring the import path). `table.wast` still has a few of these.

### #12 — Latent: global-init const-exprs encoded after the type section — LOW
`src/wat.zig` — the global section (with `emitConstExpr`) is emitted *after* the type section, but with
a live `sigs` pointer. Safe today because valid const-exprs never intern a signature. **Surfaces when:**
a future extended-const construct interns a new sig during global-init encoding → the already-written
type section is stale. **Fix:** pre-encode global inits before emitting the type section (mirror the
function-body path, which interns first).

### #13 — Dead code / duplication (not bugs) — LOW
- `src/validate.zig` `funcTypeOf` (~339) duplicates `Module.funcType`; could delegate.
- `src/opcode.zig` `Imm.select_types` / `Imm.mem_reserved` payloads are decoded but never *read* (the
  tags are needed to skip bytes; persisting the values is wasted).
- `src/main.zig` `runFunction` re-resolves the export that `Instance.invoke` resolves again.
Harmless; clean up opportunistically.

## Discovered 2026-07-09 (while adding assert_invalid support)

### #14 — `func.wast` returns a wrong result (`got 0x2a` = 42) — **RESOLVED 2026-07-09 (`0409f37`)**
Root cause: a function declaring its signature via `(type $t)` (not inline `(param …)`) never added the
type's params to the assembler's local name/index space, so a declared `(local $x)` resolved to the
param's index. `(func (type $sig) (local $var i32) (local.get $var))` returned the param (42) instead
of the uninitialized local (0). Fixed in `assembleModule`: prepend anonymous local names for the
type's params (bounds-checked against `sigs`). `func.wast` 169/2 → **171/0**.

### #15 — Element init expressions + bulk table ops + data offsets — **DONE 2026-07-13**
Landed in four passes:
- **Element init expressions (`82d0213`, `4ffa2e8`)** — the const-expr element form
  (`(elem … funcref (ref.func $f) (ref.null func) …)`, incl. `(item …)`), all 8 segment flag variants,
  and const-expr offsets, across assemble/decode/validate/instantiate. `elem.wast` 3/54 → 38/28.
- **Bulk table ops (`b256a86`)** — `table.init`/`table.copy`/`elem.drop` (`0xFC` 0x0c/0x0e/0x0d) end to
  end, plus runtime passive-element storage (each segment evaluated to `[]Value` with an `elem_dropped`
  flag; active/declarative dropped after init, passive kept). `table_init` 67 → **729/0/0**, `table_copy`
  120 → **1649/0/0**. Assembler tracks element-segment names (`elem_names`) and a shared
  `emitBulkTableImm` handles the text→binary operand-order swap (`table.init tableidx? elemidx` encoded
  elem-then-table).
- **Table initializer expressions (`6087eac`)** — inline const-expr table elems
  (`(table reftype (elem (ref.func $f) …))`) and `(table N reftype initexpr)`, the latter lowered to an
  active elem of N copies at offset 0 (observably identical; the 0x40 binary form isn't needed for
  execution assertions). `table.wast` 15 → 17, `global.wast` 108 → 109.
- **Const-expr data offsets (`c0c7de2`)** — `(data $id? (memory idx)? offset? "bytes"…)`; the offset is
  any leading list (`(offset …)` / folded `(i32.const N)` / `(global.get $g)`), absent → passive.
  Offsets emit through the shared const-expr path; added active-data-offset validation (memory presence
  + i32 offset). `assert_trap (module …)` now requires a genuine instantiation-time trap. `data.wast`
  12 → **31**, `elem.wast` → **47**.
Two bugs fixed en route: (1) the generalized data assembler mis-parsed non-`i32.const` offsets as
*passive* (offset silently dropped) — any leading list is now the offset so the validator can reject
bad ones; (2) const-expr `global.get` scope — active-segment **offsets** (data + element) may reference
any immutable global, but ref-producing element exprs / table initializers stay imported-globals-only
(matches data.wast:89 valid *and* global.wast:674 `"unknown global"`). **Remaining `data`/`elem`
failures are all imported memories/tables → #1 stage 2, not #15.**

### #16 — Decoder is lenient on malformed binaries — **LEB PART DONE (`10aca3b`); rest LOW**
**Done:** the LEB128 readers (`readVarU32`/`readVarI32`/`readVarI64`) are now spec-correct — accept
valid encodings up to the max width, reject over-long AND "integer too large" (final-byte overflow/sign
bits). This also fixed a real bug rejecting *valid* 10-byte `i64.const` modules (`skipConstExpr` skipped
i64 operands with a 5-byte cap). `binary-leb128.wast` 36/25 → **56/3**. New `skipLeb(max_bytes)` for
width-aware operand skipping.
**Part 2 done (`3321921`):** custom-section names are now validated (an empty/nameless or over-long-name
custom section is rejected, §5.5.3), and the **data-count section** (id 12) is decoded and checked
against the data-segment count (`DataCountMismatch`, §5.5.16). `custom.wast` 5/3 → **8/0**;
`binary-leb128.wast` → **58/1**. **Malformed-binary over-acceptance is now ~zero** across the
negative-conformance files.
**Still open (feature gaps, NOT malformed-handling):** `binary-leb128` (1) and `names.wast` (1) fail
with `UnsupportedInstr`/`UnsupportedOpcode` — valid modules using an op/instruction the
assembler/decoder doesn't support yet, unrelated to #16. #6's valtype-byte check for *instruction
immediates* (`select_types`/`ref.null` heaptype in `opcode.zig`) also remains, but is instruction-level,
not module structure.
