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

**The 2026-07-09 audit ledger is FULLY cleared (2026-07-13): every item #1–#16 is resolved.** No open
correctness/soundness/dead-code/spec-strictness items remain. The real frontiers are now new *features*,
not ledger debt: growing the wasm-c-api past introspection (instance/func/call), and WASI. (WAST-runner
invoke-by-module-name landed `9745ecb` — `linking.wast` 29 → 100.) Larger out-of-scope proposals surfaced
by the suite (now the main sources of remaining `.wast` failures): **typed/GC references** (`(ref null
$t)`), **multi-memory** (`start0`), and exception-handling **tags** (`imports`).

## Grouped by the integration that trips them

- **`register` / multi-module linking + imported functions** (host imports → WASI): #1 **DONE — all
  three stages** (2026-07-13). Stage 1 imported funcs + register; stage 2 imported tables/memories via
  shared `Memory`/`Table` objects; stage 3 link-time import type-checking + `assert_unlinkable`. #4
  (non-spectest imported global → 0) **also resolved** by stage 3. Only #10 (global index order, LOW)
  remains in this group. `imports.wast` 26 → **132**.
- **`assert_invalid` / `assert_malformed` support in the WAST runner**: #2, #6, #7, #8 — **all DONE**.
  These were *soundness / spec-strictness* gaps; the runner now executes the negative tests.
- **Start-function support**: #3 **DONE** (`07dd244`).
- **Host externref values** (embedding API passes real externrefs): #9 **DONE** (`994ee23`) — externrefs
  are boxed to non-sentinel handles.
- **Arbitrary / hand-written WAT** (beyond the testsuite's shape): #10 **DONE** (`3a50f75`, import-after-
  def rejected); #12 (const-expr section ordering) **DONE** (`e500a51`); #8 (`align=` non-power-of-two)
  **DONE** (`00bceb4`); #11 (defined-table inline `(export …)`) **DONE** (`ff3de4a`).
- **Test fidelity, always-on**: #5 (`assert_trap`) **DONE**.
- **Dead code / duplication**: #13 **DONE** (`78647f6`).

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

### #8 — `align=` non-power-of-two silently `@ctz`'d — **RESOLVED (`00bceb4`, 2026-07-13)**
`emitMemArg` now rejects a zero or non-power-of-two `align=` with `error.BadImmediate` before the
`@ctz` (§6.5.8), instead of encoding a bogus log2 (`align=3` → 0, `align=0` → 32). No conformance delta
(the testsuite's `align=0`/`align=7` cases arrive via `(module quote …)`, still `BadCommand`); verified
directly + new `expectInvalid` unit cases. Over-natural alignment was already a validation error.

### #9 — externref/`null_ref` sentinel collision — **RESOLVED (`994ee23`, 2026-07-13)**
The value stack is untyped `u64` with `null_ref = maxInt(u64)`; a host externref payload could equal it
and be misread as null. The WAST runner is the sole minter of externref values (`(ref.extern N)` is a
runner literal, not an instruction), so the fix is contained there: it interns each payload into a
per-run pool and represents an externref as its pool *index* (a small integer, never the sentinel).
Equal payloads intern to the same value, so an externref round-trips and compares equal. `parseConst`/
`matches` became Runner methods; funcref values still use their index directly. New wast.zig unit test
proves `(ref.extern 0xFFFFFFFFFFFFFFFF)` is non-null and round-trips.

### #10 — import-after-definition mis-indexing — **RESOLVED (`3a50f75`, 2026-07-13)**
The assembler built func/table/global name→index maps in textual order, but the binary places imports
first; a def-before-import module (malformed per §6.6.13, and the testsuite has `assert_malformed`
"import after function/global/table" for it) was silently mis-indexed. `assembleModule` now tracks
whether any func/table/memory/global definition has been seen and rejects a later import (top-level or
inline) with `error.ImportAfterDefinition` (small `fieldIsImport`/`isDefKind` classifiers). **Enforce,
not reorder** — reordering would wrongly accept the malformed cases. No conformance delta (the
testsuite's cases arrive via `(module quote …)`, still `BadCommand`); new wat.zig unit test + verified
valid imports-first resolves correctly.

### #11 — inline `(table (export …) …)` on a *defined* table — **RESOLVED (`ff3de4a`, 2026-07-13)**
`parseTable` now skips and registers leading inline `(export "x")*` forms (kind 1, current table index)
after the optional `$id`, mirroring `parseGlobal`; the imported-table case was already done (`07dd244`).
No-op for tables without an inline export, so every core file is byte-identical; modules using the form
previously failed to assemble (no passing assertion to lose) and now build: `imports` 137/31 → **137/17**
(14 fewer build failures), `linking` 19/84 → **29/108** (+10 passes), `elem` 52/15 → **52/26** (passes
stable; the new failures are newly-run assertions hitting *other* gaps — typed refs / value-literal
parsing). New wat.zig unit test.

### #12 — const-expr sections encoded after the type section — **RESOLVED (`e500a51`, 2026-07-13)**
The type section (1) was emitted before the global (6), element (9), and data (11) sections, which
encode const-exprs against the same live `sigs` list — safe only because const-exprs can't intern a
signature. Extracted `encodeGlobalSection`/`encodeElementSection`/`encodeDataSection` and call them right
after the function bodies are pre-encoded (before the type section), so any interned signature lands in
section 1 by construction. Pure reordering — output byte-identical, full regression sweep unchanged.

### #13 — Dead code / duplication — **RESOLVED (`78647f6`, 2026-07-13)**
- `validate.zig`'s `funcTypeOf` was a byte-for-byte duplicate of `Module.funcType` — deleted, the four
  callers now use `module.funcType`. Also changed `Module.funcType` to a `*const Module` receiver so it
  no longer copies the whole Module struct by value per call.
- `main.zig`'s `runFunction` re-resolved the export `invoke` resolves again — added
  `Instance.invokeIndex(func_index, args)` (invoke delegates to it) and main calls it with the index it
  already has.
- **Stale/kept:** `Imm.select_types`' payload IS read now (the validator checks the annotation, #2), so
  it is not dead; `Imm.mem_reserved`'s byte is retained deliberately (documents the reserved wire byte,
  leaves room to validate it must be 0).

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
