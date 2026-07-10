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

Still open: #1, #3, #4, #9, #10, #11, #12, #13, plus the "Discovered 2026-07-09" items below (#15,
#16). #14 is resolved (see below).

## Grouped by the integration that trips them

- **`register` / multi-module linking + imported functions** (host imports → WASI): #1 (top-level
  `(import …)` dropped), #4 (non-spectest imported global → 0), #10 (global index order). This is the
  big one — `table_copy.wast` (1650 skipped), `table_init.wast` (730), and most linking tests use
  top-level func imports and `register`.
- **`assert_invalid` / `assert_malformed` support in the WAST runner**: #2 (validator
  over-acceptance, all sub-items), #7 (const-expr `global.get` strictness), #6 (invalid valtype byte),
  #8 (`align=` non-power-of-two). These are *soundness / spec-strictness* gaps — invisible until the
  runner actually executes the negative tests (today they're counted as `skipped`).
- **Start-function support**: #3 (assembler drops `(start …)`, decoder ignores the start section).
- **Host externref values** (embedding API passes real externrefs): #9 (`null_ref` collision).
- **Arbitrary / hand-written WAT** (beyond the testsuite's shape): #11 (inline `(table (export …))`),
  #12 (`align=` malformed), #10 (import-after-def ordering).
- **Any future extended-const op that interns a signature**: #13 (type-section ordering, latent).
- **Test fidelity, always-on**: #5 (`assert_trap` accepts any error — silently green-washes producer
  bugs *now*).

---

## The list

### #1 — Assembler silently drops top-level `(import …)` and `(start …)` — HIGH (fall-through)
`src/wat.zig` — `assembleModule` Pass-1 `else {}` (~line 143). Any module field the assembler doesn't
handle is dropped with no error. Two that matter: a top-level `(import "m" "n" (func …))` is dropped,
which **shifts every defined function index** (defined funcs are expected to follow imports) → a
wrong-but-decodable module; and `(start $f)` produces a binary with no start section.
**Surfaces when:** imported functions + `register`/module-linking lands (host imports / WASI); or a
start-function module is assembled. **Fix:** handle top-level `(import … (global …))` (route to the
existing imported-global path), add func/table/memory imports when those land, emit a start section,
and `return error.BadModuleField` for genuinely-unknown keywords (excluding `type`, handled in the
pre-pass). NOTE: a blanket error here regresses `global.wast` (its top-level import-global module is
currently neutral) — so *handle*, don't just reject.

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

### #3 — Decoder records but never acts on the start section — MED
`src/Module.zig` — decode section switch `else {}` (~199) ignores `SectionId.start` (and
`data_count`). Benign for `custom`/`data_count`; for `start` it means the start function never runs.
**Surfaces when:** start-function support is added (pairs with #1's assembler side).

### #4 — Non-`spectest` imported global silently defaults to 0 — MED (test infra)
`src/wast.zig` — `resolveImports` `spectestGlobal(…) orelse 0` (~92). A module importing a global from
any module other than `spectest` gets a silent 0, so an `assert_return` reading it can spuriously
pass/fail. **Surfaces when:** `register`/multi-module linking lands (a prior module exports a global a
later module imports). **Fix:** resolve imports against registered modules, not just the `spectest`
stub.

### #5 — `assert_trap` counts ANY error as the expected trap — MED (test fidelity, ACTIVE NOW)
`src/wast.zig` — `assertTrap` `else |_| { passed += 1 }` (~158). No check of trap kind/message: an
assembler bug, a decode error, or `error.UnsupportedInstruction` from the interpreter all count as a
passing trap. This **green-washes real producer/decoder bugs today** — the one deferred item that hurts
right now, because it undermines the conformance signal the audit relies on. **Fix:** at minimum
distinguish "runtime trap" from "build/decode/assemble error"; ideally match the expected trap text.

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

### #11 — `parseTable` ignores an inline `(export …)` — LOW (missing feature, fails loud)
`src/wat.zig` — `parseTable` (~334) doesn't handle `(table (export "t") 1 funcref)`; the `(export …)`
list falls into `parseIndex` → `error.BadImmediate`. Errors out (not wrong bytes). **Surfaces when:**
a module uses the inline table-export form (`table.wast` does). **Fix:** parse leading inline
`(export …)` in `parseTable` like `parseGlobal` already does.

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

### #15 — Table & element *initializer expressions* not assembled — LOW (feature)
`(table $t N funcref (global.get $g))` (per-table init expr) and `(elem (table $t) (offset) funcref
(ref.func $f) …)` (element *expression* form, vs the plain func-index list) are parsed loosely by
`parseTable`/`parseElem`, which drop the trailing const-exprs. Consequence: invalid init exprs aren't
validated (global.wast's last over-acceptance) and the linking-heavy `elem` forms don't assemble.
**Surfaces when:** the reference-types element/table-init-expression tests, and the `register` module in
`global.wast`. **Fix:** parse the init/element expressions and run them through `validateConstExpr`.

### #16 — Decoder is lenient on malformed binaries — LOW/MED (hardening)
Several `assert_malformed (module binary …)` cases are accepted: a custom/section length that overruns
the input ("length out of bounds"), and various `binary-leb128.wast` over-long / overflowing LEB
encodings. The decoder trusts declared lengths and doesn't fully bound-check. **Surfaces when:**
`assert_malformed` on hand-crafted binaries, or any untrusted/fuzzed input. **Fix:** validate section
lengths against remaining input; tighten LEB overflow/canonical-length checks. (Pairs with #6's
valtype-byte check.)
