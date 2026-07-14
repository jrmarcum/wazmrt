# Text Toolchain — WAT Assembler + WAST Runner

## Decision (owner, 2026-07-02): build it natively, in full

To use the **standard `.wast` conformance format** (the owner is converting the
`.test.json` fixtures to `.wast`, and the goal is the official spec testsuite at
`module/wasm_wast/testsuite-main`), wazmrt gets a **native WAT text assembler +
WAST script runner** — no external dependency (`wat2wasm`/`wasm-tools`/`wast2json`
are absent; only Binaryen `wasm-as` is present and it can't run `.wast` scripts).

**Why this is a large subsystem:** the official testsuite is **257 `.wast` files,
242 of which use inline *text* modules** (folded WAT S-expressions like
`(func (export "add") (param $x i32) (i32.add (local.get $x) (local.get $y)))`).
Only 15 use `(module binary "…")`. So running the suite requires a real
`wat2wasm` (~1–2k lines): tokenize → parse → resolve identifiers → flatten folded
instructions → auto-generate the type section → encode to binary. The encoder
reuses `opcode.zig` in reverse (instruction name → `Op`).

## Architecture

```text
.wast text ─► sexpr ─► wast runner ──► (per module) wat assembler ─► wasm binary
                          │                                              │
                          │                                    Module.decode ─► validate ─► Instance
                          └── assert_return / assert_trap / invoke ◄── run & compare
```

- **`src/sexpr.zig`** — S-expression lexer + parser (shared front-end). Atoms,
  strings (decoded to bytes, so `(module binary "\00asm…")` yields real bytes),
  lists; line `;;` + nestable block `(; ;)` comments. **DONE 2026-07-02** (4 tests).
- **`src/wat.zig`** (DONE 2026-07-02) — WAT text → wasm binary. `(func …)` with
  named/anonymous `(param)`/`(result)`/`(local)`, inline + top-level `(export …)`,
  identifier→index resolution (locals/funcs), **folded + flat** instruction forms, a
  dedup'd type section, the instruction encoder (name→`Op` via `stringToEnum`, operands
  per `opcode.immediateKind`), **structured control flow** (`block`/`loop`/`if`/`else`/`end`
  with a label stack for `br`/`br_if`/`br_table` name→depth, single-result blocktypes),
  **memarg** (`offset=`/`align=`), and the **memory + data** sections. **Verified:**
  assemble→decode→validate→run for add, mul, nested const, two-func `call`, if/else,
  a named-label loop `sum(5)=15`, flat block+br, memory store/load, and a data segment.
  **Multi-value block types + typed `select` DONE 2026-07-02** (type-index blocktypes interned into
  the type section; `select_t` 0x1c). **`call_indirect` + `table`/`elem` + `global` + `(type $t)`
  block-type references DONE 2026-07-09.** **Reference types (`ref.null`/`ref.is_null`/`ref.func`,
  `(ref null? func|extern)` value types) + multi-table (per-table `elem`, `call_indirect $t`) +
  NaN-payload float literals (`nan:canonical`/`nan:arithmetic`/`nan:0x…`) DONE 2026-07-09.**
  **Bulk table ops + data-segment generalization DONE 2026-07-13** (`table.init`/`table.copy`/`elem.drop`
  with element-segment names; inline const-expr table elems + `(table N reftype initexpr)`; passive +
  `(memory idx)`-prefixed + const-expr-offset `(data …)`). **Imported tables/memories DONE 2026-07-13**
  (`(import … (table|memory …))` → import section kinds 0x01/0x02; imports take the low indices).
  **Start section (`(start $f|N)`), `(memory (data …))`, and inline `(memory|table (import …))` DONE
  2026-07-13.** **Deferred in wat.zig:** inline `(table (export …) …)` on a *defined* table (#11), tag
  imports, multi-memory.
- **`src/wast.zig`** (DONE 2026-07-02, extended 2026-07-09) — WAST script runner: `(module …)` text +
  `(module binary …)`, `assert_return`, **`assert_trap` (genuine runtime traps only — `isRuntimeTrap`),
  `assert_exhaustion`, `assert_invalid`/`assert_malformed` (the inner module must be rejected)**,
  `invoke`; value literals incl. `nan:canonical`/`nan:arithmetic` + references; drives an `Instance` and
  compares (NaN-aware). CLI `.wast` mode. **Passes thousands of positive + negative official-testsuite
  assertions** (see `testing.md`). Handles `(register "name" $id?)` + cross-module imports, **module
  `$name` tracking so `(invoke $M …)` / `(get $M …)` / `(register "x" $M)` target a named (non-current)
  module** (`9745ecb`), and the `(get …)` action (reads an exported global). Deferred: `(module quote …)`.

## Staged plan

1. ~~S-expression lexer/parser (`sexpr.zig`)~~ **DONE 2026-07-02.**
2. ~~WAT assembler MVP~~ **DONE 2026-07-02** (`wat.zig`): func/param/result/local/export,
   folded + flat, non-control instructions.
3. ~~WAT assembler breadth~~ **DONE 2026-07-02**: control flow (block/loop/if/else/end +
   labels + single-result blocktypes, `br`/`br_if`/`br_table`), memarg, memory + data
   sections. Deferred: `global`/`table`/`elem`, multi-value block types, `call_indirect`.
4. ~~WAST runner (`wast.zig`)~~ **MVP DONE 2026-07-02** — `(module …)` (text + `binary`),
   `assert_return`/`assert_trap`/`invoke`, value literals incl. `nan:canonical`/`nan:arithmetic`;
   drives an `Instance`, compares (NaN-aware). CLI `.wast` mode. **Runs the official testsuite:**
   `i32` 374/0, `i64` 384/0, `int_exprs` 89/0, `address` 255/0, `f32`/`f64` 2498/2 (see `testing.md`).
   Deferred: `assert_invalid`/`assert_malformed`, `register`/multi-module, `get`, `(module quote …)`.
5. ~~Multi-value block types/results + typed `select`~~ **DONE 2026-07-02** (decoder type-index
   blocktypes + `select_t` 0x1c; interp/validator; assembler interns block-type sigs into the type
   section + emits typed select). Fixed `fac` (0→6).
6. ~~`call_indirect` + `table`/`elem` + `global` + type-ref block types~~ **DONE 2026-07-09**
   (decoder/validator already handled call_indirect; added interp table + type-checked indirect
   dispatch, global-init const-expr evaluation, and assembler support for all four). Control-flow
   files jumped 0 → nop 83 / block 52 / if 124 / loop 77 / call_indirect 120, **0 failed**. Also fixed
   a latent `memory.size`/`memory.grow` interp panic (`imm.mem` vs `mem_reserved`). **Next: reference
   types** (`ref.func`/`ref.null`, funcref/externref values) — the blocker for `select.wast` and the
   last `call_indirect` assert. This is the standing conformance gate (`testing.md`).
7. ~~Reference types~~ **DONE 2026-07-09** (`ref.null`/`ref.is_null`/`ref.func` `0xD0`–`0xD2` across
   opcode/interp/validator; `(ref null? func|extern)` value types + heaptype immediates in the
   assembler; `(ref.null …)`/`(ref.extern N)`/`(ref.func)` value literals in the WAST runner). Null =
   `maxInt(u64)` stack sentinel; a funcref is its function index. `select.wast` 0 → **124/0**.
8. ~~Multi-table + NaN-payload float literals~~ **DONE 2026-07-09**. Interp holds an array of funcref
   tables; `call_indirect` uses `imm.table`; element segments apply to their `table_index`. Assembler
   tracks table names, resolves `call_indirect $t` (gated on a following `(type …)` annotation so a
   flat `call_indirect select` isn't misread), emits per-table element flags (`0x02`). `floatBits`
   parses `nan:canonical`/`nan:arithmetic`/`nan:0x<payload>`. `call_indirect.wast` 120/1 → **132/0**,
   `local_tee.wast` 0 → **55/0**; no regressions (HEAD-baselined).
9. ~~Imported globals + extended-const init expressions~~ **DONE 2026-07-09**. `Instance.initWithImports`
   fills imported-global slots from host values (imports head the global index space); the WAST runner
   backs the standard `spectest` globals; the assembler parses `(global (import "m" "n") type)` and
   emits an import section (2); `ref.null`/`ref.func` work in const-inits; and `evalConstExpr` is now a
   small stack machine so compound extended-const inits (`i32.add`/`sub`/`mul` etc.) evaluate correctly.
   `global.wast` 0 → **62/1** (lone failure needs `register`/linking).
10. ~~Reference-type table ops~~ **DONE 2026-07-09**. `table.get`/`.set` (`0x25`/`0x26`) +
    `table.size`/`.grow`/`.fill` (`0xFC` prefix, decoded via internal `Op` tags + `fcSubOpcode`,
    emitted via `emitOpcode`). Interp tables became `[]Value` slots (funcref + externref share one
    representation) with per-table max so `table.grow` reallocs. Assembler parses `externref`/`(ref …)`
    table element types. `table_get` 9/0, `table_set` 18/0, `table_size` 36/0, `table_grow` 38/3,
    `table_fill` 35/0. **Next:** passive/declarative element segments + `table.init`/`.copy` +
    `elem.drop`, `register`/multi-module linking, imported functions/tables/memories (→ host imports /
    WASI). Standing conformance gate (`testing.md`).
11. ~~Negative conformance + validator/decoder strictness~~ **DONE 2026-07-09** (post-audit; commits
    `645874c`/`0409f37`/`c535de0`/`10aca3b`/`3321921`). Runner executes `assert_invalid`/
    `assert_malformed`/`assert_exhaustion` and gates `assert_trap` on a real runtime trap. Validator
    rejects invalid modules (const-exprs, elements, `select`/`if`/`call_indirect`/`ref.is_null`,
    alignment ≤ natural + memory-presence). Decoder rejects malformed binaries (spec-correct LEB128,
    custom-section names, data-count consistency, reserved flag/valtype bytes). Fixed the `(type $t)`
    function local-indexing bug (`func.wast` 171/0). Thousands of skips → pass/fail; malformed
    over-acceptance ~zero. **Next:** `register`/linking + imported functions (host imports / WASI), then
    table/element init expressions. See `known-issues.md` for the remaining ledger.
12. ~~Element init expressions~~ **DONE 2026-07-09** (`82d0213`/`4ffa2e8`). Element const-expr form
    (`(elem … funcref (ref.func $f) (ref.null func) …)`, `(item …)` wrapper) + all 8 segment flag
    variants (active/passive/declarative × func-index/expr) + const-expr offsets, across
    decode/interp/validate/assemble. `elem.wast` 3/54 → **38/28**.
13. ~~Host imports stage 1: imported functions + `register`~~ **DONE 2026-07-09** (`bcf3a11`).
    `Instance.HostFunc` (cross-module `wasm` call or `native` fn) dispatched from `callFunction`; the
    runner keeps a module registry + `(register "name")`, wiring imported funcs to a registered export
    or a `spectest` native and imported globals to values; the assembler emits the import section for
    top-level/inline func imports (imports take the low func indices). `func_ptrs` 32/0, `table_copy`
    0 → **120**, `table_init` 0 → **67**. **Next:** imported tables/memories, bulk table ops
    (`table.init`/`.copy`/`elem.drop`), passive elements. See `known-issues.md` #1.
14. ~~Bulk table ops + table-init exprs + const-expr data offsets~~ **DONE 2026-07-13** (`b256a86`,
    `6087eac`, `c0c7de2`; closes #15). `table.init`/`table.copy`/`elem.drop` (`0xFC` 0x0c/0x0e/0x0d) end
    to end + runtime passive-element storage (`elem_values`/`elem_dropped`): `table_init` 67 →
    **729/0/0**, `table_copy` 120 → **1649/0/0**. Assembler gained element-segment names (`elem_names`)
    + a shared `emitBulkTableImm` (handles the `table.init tableidx? elemidx` → elem-then-table wire
    swap). Inline const-expr table elems + `(table N reftype initexpr)` (lowered to an active elem of N
    copies). Data segments generalized: `(data $id? (memory idx)? offset? "bytes"…)`, any-leading-list
    offset, passive form, and active-data-offset validation; `assert_trap (module …)` requires a real
    instantiation trap. `data` 12 → **31**, `elem` 38 → **47**, `global` 108 → **109**. Const-expr
    `global.get` scope split: active-segment offsets allow any immutable global, ref-producing element
    exprs / table inits stay imported-only. **Next:** imported tables/memories (#1 stage 2) — the only
    remaining `data`/`elem` blocker.
15. ~~Host imports stages 2/3 + start (#3) + audit-ledger closeout + invoke-by-module-name~~ **DONE
    2026-07-13** (`78c6b2b`/`1d6d9f2`/`07dd244`/`9745ecb` + the #8–#13 fixes). Imported tables/memories
    (shared objects), link-time import type-checking + `assert_unlinkable`, the start section, and the
    WAST runner's `(invoke $M …)`/`(get …)`/`(register "x" $M)` by module name (`linking` 29 → 100).
16. ~~Function-references proposal (typed refs)~~ **DONE 2026-07-13** (P1 `87ac6a7`, P2 `7ebfd1e`, P2.5
    `446b61b`). Assembler + decoder accept all typed/GC reference *value-type* forms (`(ref null? ht)`,
    `anyref`/`eqref`/`i31ref`/…, collapsing to two opaque ref slots), with distinct non-null variants
    (`funcref_nn`/`externref_nn`, synthetic bytes 0x67/0x68). `call_ref`/`return_call_ref` (immediate is
    a *type* index), `ref.as_non_null`, `br_on_null`/`br_on_non_null`. Validator adds ref subtyping
    (`(ref t) <: (ref null t)`) and local-init tracking. Fixed a latent bug: `ref.func $f` in a
    global-init/offset const-expr (threaded `func_names` into `emitConstExpr`). ~+130 ref-file passes.
    **Deferred:** full **GC** (i31/struct/array heap objects, `ref.test`/`ref.cast`) — heap-requiring.

## Notes / invariants

- **Reuse, don't duplicate, the opcode table.** The assembler builds a
  name→`Op` map from `opcode.zig`; the encoder must stay in lockstep with the
  decoder (same authority).
- **Self-contained.** No external assembler at build or test time (matches the
  libc-free / no-deps ethos).
- Coverage tracks the interpreter: instructions the interpreter can't yet run
  (call_indirect, ref-types, SIMD, bulk-memory) can still be *assembled/decoded*,
  but their `.wast` assertions will trap until the matching execution slice lands.
