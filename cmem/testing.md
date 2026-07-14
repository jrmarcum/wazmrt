# Testing

## Unit tests (in-repo)

`zig build test` runs the `test` blocks across the core modules (15 as of 2026-07-02: Reader, Module,
opcode). The C ABI is verified separately from C via `tests/c_smoke.c` compiled with `zig cc` (see
`design-decisions.md` → "Verified working"). Hand-built byte fixtures live inline in the tests.

## External conformance corpora (owner-designated 2026-07-02)

The designated real-world test inputs live in the sibling **wasmtk** project under
`…/wasmExamples/wasmtk/tests/`. They are **outside this repo** (not copied in) — reference by path.
Reorganized layout confirmed by the owner **2026-07-02**:

```text
wasmtk/tests/
├── module/                              # wasm module functions
│   ├── wasm_mod/                        # 12 .wasm + 11 .test.json — FIRST EXECUTION TARGET
│   ├── bindgen_fixtures/                # bindgen fixtures
│   └── wasm_wast/
│       ├── testsuite-main/              # ⭐ official WebAssembly spec testsuite: 257 .wast files
│       ├── ArtOfWebAssembly_tests/      # "Art of WebAssembly" .wat, by chapter
│       └── wasm-wat-samples-main/       # assorted .wat samples
└── wasi/                                # WASI programs
    ├── wasm_wasi/                       # ~336 .wasm (+ .wat/.wit/.ts) TS→WASI programs
    ├── wasm_wasi_bundle/                # multi-module bundle fixtures (imports/chains)
    └── wasm_wasi_dync/                  # dynamic (demoN.wasm/.wat/.wit/.ts)
```

### `module/wasm_mod` — the first execution target

~12 small modules that export plain functions (adder, factorial, evenOrOdd, isLeapYear, sieve, `fib`
in wat/rs/ts/zig). Each `<name>.wasm` has a sibling **`<name>.test.json`** — a ready-made execution
conformance harness:

```json
{ "add": [ { "args": [10, 20], "expected": 30, "desc": "basic sum" }, … ],
  "fib": [ { "args": [10],     "expected": 55, "desc": "fib(10)" }, … ] }
```

Shape: `{ "<export>": [ { "args": [...], "expected": <value>, "desc": "..." }, … ] }`. Harness = load
the `.wasm`, call the named export with `args`, compare to `expected`. All 12 decode + validate today
(below); wiring the harness is gated only on finishing the integer→float/memory execution slices.

### `module/wasm_wast/testsuite-main` — the conformance gold standard (future)

The **official WebAssembly spec testsuite** (257 `.wast` files: `address.wast`, `align.wast`,
`i32.wast`, `call.wast`, `br_table.wast`, …). `.wast` is the spec *script* format — modules plus
assertions (`assert_return`, `assert_trap`, `assert_invalid`, `assert_malformed`). Using it requires a
**`.wast` script parser** (a distinct tool to build) but it is THE bar a serious runtime is measured
against — every implemented feature should eventually be gated on the relevant `.wast` files.
`ArtOfWebAssembly_tests` and `wasm-wat-samples-main` are additional `.wat` corpora for lighter coverage.

### `wasi/wasm_wasi*` — WASI execution (later)

TS→WASI programs (optimizer-heavy; exercise far more of the instruction/section space than `wasm_mod`),
plus multi-module `wasm_wasi_bundle` and dynamic `wasm_wasi_dync`. The target for **WASI execution**
once the runtime has memory + host imports + the WASI surface.

## Decode-coverage snapshot (2026-07-02, after the opcode/IR decoder)

Run `wazmrt <file.wasm>` — the CLI now decodes each function body via `opcode.decodeBody` and prints
`bodies decoded: X/Y` (or `fn[i]: body decode FAILED — <error>`).

- **`wasm_mod`: 12/12 modules decode 100%.** The whole module-function corpus is within the core-MVP
  instruction set we support today. Ready to wire to execution.
- **`wasm_wasi`: partial**, and every failure sits at a **documented boundary, not a bug**:
  - `UnsupportedOpcode` — bodies use the `0xFC` prefix (bulk-memory `memory.copy`/`fill`) and/or
    exception opcodes; outside our current `0x00`–`0xC4` set.
  - `InvalidSectionId` — the module carries a **tag section (id 13)** from the exception-handling
    proposal (wasmtk emits `try`/`catch`); our decoder caps section ids at 12.

## Validation-coverage snapshot (2026-07-02, `validate.zig`)

The CLI now also type-checks each module (`validation: OK` / `FAILED — <error>`).

- **`wasm_mod`: 12/12 validate OK** — including the compiler-generated `fib-rs`/`fib-ts`/`fib-zig`.
- **`wasm_wasi`: every fully-decoding module validates.** The only `validation: FAILED` cases are
  `UnsupportedOpcode` on modules with a *partial* decode (one body uses a `0xFC` op) — i.e. the
  validator re-decodes the IR and hits the same boundary. **No module that fully decodes fails
  validation**, which is strong evidence the type-checker is correct across real, deeply-nested
  control flow (not just the simple `wasm_mod` set).

## Spec-testsuite conformance snapshot (2026-07-02, `wast.zig` MVP)

Run a `.wast` file directly: `wazmrt <file.wast>` → `N passed, N failed, N skipped`. Against
`module/wasm_wast/testsuite-main` (the official suite):

| File | Result |
| --- | --- |
| `i32.wast` | **374 passed, 0 failed** (85 skipped) |
| `i64.wast` | **384 passed, 0 failed** (31 skipped) |
| `int_exprs.wast` | **89 passed, 0 failed, 0 skipped** |
| `address.wast` | **255 passed, 0 failed** (memory addressing) |
| `f32.wast` / `f64.wast` | **2498 passed, 2 failed** each (NaN-payload edge cases) |
| `nop.wast` | **83 passed, 0 failed** (4 skipped) |
| `block.wast` | **52 passed, 0 failed** (170 skipped) |
| `if.wast` | **124 passed, 0 failed** (116 skipped) |
| `loop.wast` | **77 passed, 0 failed** (42 skipped) |
| `call_indirect.wast` | **132 passed, 0 failed** (37 skipped) |
| `fac.wast` | **6 passed, 0 failed** (1 skipped) |
| `select.wast` | **124 passed, 0 failed** (30 skipped) |
| `local_tee.wast` | **55 passed, 0 failed** (42 skipped) |
| `global.wast` | **62 passed, 1 failed** (53 skipped — 1 module needs `register`/linking) |
| `table_get.wast` | **9 passed, 0 failed** (5 skipped) |
| `table_set.wast` | **18 passed, 0 failed** (7 skipped) |
| `table_size.wast` | **36 passed, 0 failed** (2 skipped) |
| `table_grow.wast` | **38 passed, 3 failed** (12 skipped — 3 need `register`/imported tables) |
| `table_fill.wast` | **35 passed, 0 failed** (9 skipped) |

- **`skipped`** = commands the MVP runner doesn't handle (`assert_invalid`/`assert_malformed`,
  `register`, `get`), *plus* asserts whose module failed to build.
- **The `0 passed` files are single module-build failures**, not many distinct bugs: those modules
  contain a function using a **deferred construct** — **multi-value block types / results**
  (`(result i64 i64)`, `(loop (param i64 i64) (result i32) …)`), **typed `select`** (`0x1c`), or
  `table`/`elem`. Since a module assembles all-or-nothing, one advanced function skips the rest.
- **The 2 float failures** are NaN-payload/propagation edge cases (e.g. a signaling-NaN result where
  Zig's native op yields a different NaN bit pattern than the exact-bits assertion expects).

**Takeaway:** thousands of official spec assertions pass; every gap is a *named, deferred feature*, not
a core correctness bug.

**Update 2026-07-02 — multi-value + typed `select` landed:** `fac` now passes (0→6). The remaining
`0 passed` control-flow files (`block`/`nop`/`if`/`loop`/`local_tee`/`select`/`stack`) are blocked on
**`call_indirect`** (they use `(call_indirect (type $t) …)`) — the next feature. i32/i64/int_exprs/
address/f32/f64 unchanged.

**Update 2026-07-09 — `call_indirect` + tables + globals + type-ref block types landed:** the
control-flow files jumped from 0 → **nop 83 / block 52 / if 124 / loop 77 / call_indirect 120**, all
with **0 failed**. This increment added, end to end: `call_indirect` (table lookup + runtime
type-check), `table`/`elem` (incl. the inline `(table funcref (elem …))` abbreviation and skipping
declarative `(elem declare …)` segments), **globals** (`(global (mut? t) init)` + `global.get`/`.set`,
with the interp now *evaluating* global init const-exprs instead of zero-filling), and **type-index
block types** (`(block (type $t) …)`). Also fixed a latent interp panic: `memory.size`/`memory.grow`
read `imm.mem` (a memarg) but carry a `mem_reserved` immediate — now handled before the memarg read.
Remaining `call_indirect` failure (1) and all of `select.wast` need **reference types** (`ref.func`,
`ref.null`, funcref/externref values) — the next feature. i32/i64/int_exprs/address unchanged (no
regressions).

**Update 2026-07-09 — reference types landed:** `select.wast` jumped 0 → **124 passed, 0 failed**.
Added `ref.null`/`ref.is_null`/`ref.func` (`0xD0`–`0xD2`) end to end, `(ref null? func|extern)` value
types in the assembler, and reference value literals in the WAST runner (`(ref.null …)`,
`(ref.extern N)`, `(ref.func)` = any-non-null / with-index = exact). Null references use a
`maxInt(u64)` sentinel on the value stack; a funcref value is its function index. Also made
`call_indirect` skip an optional explicit table id (`call_indirect $t (type …)`) — consumed but not
encoded (single-table). **Remaining gaps are now two distinct features, not reference types:**
`call_indirect.wast`'s last failure and `local_tee.wast` need **multi-table** support (multiple
`(table …)` + per-table element segments — today all elements collapse onto table 0) and **NaN-payload
float literals** (`nan:0x…`/`inf`) in the WAT assembler, respectively. Numeric suites unchanged.

**Update 2026-07-09 — multi-table + NaN-payload float literals landed:** `call_indirect.wast` 120/1 →
**132/0** and `local_tee.wast` 0 → **55/0**. The interp now holds an array of tables (one funcref table
per module table); `call_indirect` dispatches through `imm.table`, and element segments apply to their
`table_index`. The assembler tracks table names, resolves `call_indirect $t`'s explicit table operand
(gated so a *following* flat instruction like `call_indirect select` isn't mistaken for a table id —
the id must be followed by a `(type …)`/`(param …)`/`(result …)` annotation), and emits per-table
element flags (`0x02` + tableidx + elemkind for non-zero tables). `floatBits` now parses
`nan:canonical`/`nan:arithmetic`/`nan:0x<payload>` (plain `nan`/`inf` already went through
`std.fmt.parseFloat`). **Verified against HEAD: no regressions** — `global`/`table`/`func`/`br_table`
fail identically before and after (pre-existing feature gaps: `table.get`/`.set`, passive/imported
element segments, imported globals — the next features), while `elem`/`stack` improved. Numeric suites
unchanged.

**Update 2026-07-09 — imported globals + extended-const init expressions:** `global.wast` 0 →
**62 passed, 1 failed**. `Instance.initWithImports` fills imported-global slots from host-supplied
values (imports occupy the head of the global index space); the WAST runner backs the standard
`spectest` globals (`global_i32`/`i64` = 666, `global_f32`/`f64` = 666.6); the assembler parses
`(global (import "m" "n") type)` and emits an **import section (2)**; `ref.null`/`ref.func` are accepted
in const-init exprs; and `evalConstExpr` became a small stack machine so **compound (extended-const)
inits** like `(i32.add (i32.mul (i32.const 20) (i32.const 2)) (i32.const 2))` evaluate correctly
(previously only the first instruction was read → wrong value). The lone remaining `global.wast` failure
is one module needing `register`/module-linking + `table.get` + element-init-expressions. **No
regressions** (HEAD-baselined: `data` 0/13 and `memory`'s slowness are pre-existing).

**Update 2026-07-09 — `table.get`/`table.set` + externref tables:** `table_get.wast` 0 → **9/0**,
`table_set.wast` 0 → **18/0**. Added `table.get`/`table.set` (`0x25`/`0x26`) across
opcode/interp/validator (typed by the table's element type), and refactored interp tables from `[]u32`
(funcref indices) to `[]Value` slots so **funcref and externref tables share one representation**
(`null_ref` = uninitialized; a funcref is its function index; an externref is its host value). The
assembler parses `externref`/`(ref …)` table element types + emits the correct element byte, and emits
`table.get`/`.set` (optional explicit table id, default 0). No regressions.

**Update 2026-07-09 — `0xFC` table ops (`table.size`/`.grow`/`.fill`):** `table_size.wast` 0 → **36/0**,
`table_grow.wast` 0 → **38/3**, `table_fill.wast` 0 → **35/0**. The decoder now intercepts the `0xFC`
prefix and maps the LEB sub-opcode to internal `Op` tags (`table_grow`/`_size`/`_fill`, byte values in
an unused range — the wire form is `0xFC`+subop, see `fcSubOpcode`); the assembler emits FC-aware
opcodes via `emitOpcode`. The interp tracks per-table max and `table.grow` reallocs the entries
(refusing past max → -1). `table_grow.wast`'s 3 failures need imported tables + `register`
(module-linking). No regressions. **Next:** passive/declarative element segments + `table.init`/`.copy`
+ `elem.drop`, and `register`/imported functions (host imports / WASI) — which together unblock
`table_copy.wast` (1650 skipped) and `table_init.wast` (730 skipped).

**Update 2026-07-09 — `assert_invalid`/`assert_malformed`/`assert_exhaustion` + validator strictness
(commit `645874c`):** the runner now *executes* the negative-conformance commands (previously all
`skipped`), and `assert_trap` accepts only a genuine runtime trap. This converted **thousands** of
skips into real pass/fail AND forced the validator to correctly reject invalid modules. Representative
before → after (all now **0 skipped** unless noted): i32 374 → **459/0**, i64 384 → **415/0**, block 52
→ **222/0**, if 124 → **240/0**, loop 77 → **119/0**, call_indirect 132 → **169/0**, select 124 →
**154/0**, local_tee 55 → **97/0**, nop 83 → **87/0**, align 96/44 → **140/0**, load **96/0**, store
**67/0**, call **90/0**, br **96/0**, return **83/0**, func 94 → **169/2**, global 62/1 → **108/2**.
Validator additions: global-init const-expr checking, untyped-`select` ref rejection + typed-`select`
arity, `call_indirect` table-exists/funcref, `if`-without-`else` params==results, element-segment
validation, load/store alignment ≤ natural + memory-presence; decoder rejects reserved
mutability/limits bytes. **No regressions** (zero `assert_trap` flipped — verified no "non-trap error"
failures). Remaining fails are pre-existing feature gaps (host imports for `imports.wast`, LEB/custom
malformed edges, table/element init exprs) + the pre-existing `func.wast` result-mismatch bug — all in
`known-issues.md` (#14–#16).

**Update 2026-07-09 — follow-ups (`0409f37`, `c535de0`, `10aca3b`, `3321921`):** cleared most of the
newly-exposed gaps. `func.wast` **171/0** (fixed #14 — `(type $t)` functions mis-indexed their locals).
`ref.is_null` requires a reference; decoder rejects undefined valtype bytes (#2e/#6). **Decoder
hardening (#16):** spec-correct LEB128 (`binary-leb128.wast` 36/25 → **58/1**), custom-section-name +
data-count validation (`custom.wast` 5/3 → **8/0**). Malformed-binary over-acceptance is now ~zero.
`#2f` (`br_table` polymorphic) was investigated and found **not a bug** (the pop/push chain already
cross-checks label types). Remaining testsuite fails are feature gaps — **host imports** (`imports.wast`
24/58, `func_ptrs`, `table_copy`/`table_init` = thousands skipped) and table/element **init
expressions** (#15) — not correctness holes. **63 unit tests.**

**Update 2026-07-09 — element init expressions (#15) + host imports stage 1 (#1):** `elem.wast` 3/54 →
**38/28** (element const-expr form + all 8 segment flag variants + const-expr offsets; commits
`82d0213`/`4ffa2e8`). **Imported functions + `register`/module-linking** (`bcf3a11`): the runner keeps a
module registry, cross-module calls run in the exporting instance, `spectest` funcs are native no-ops —
`func_ptrs` 29/2 → **32/0**, `table_copy` 0 → **120**, `table_init` 0 → **67**. Remaining fails are
`table.copy`/`.init`/`elem.drop` (bulk table ops), passive elements, and imported **tables/memories**
(`imports.wast` 26/56). **65 unit tests.** No regressions across the numeric/control/reference suites.

**Update 2026-07-13 — #15 finished: bulk table ops + table-init exprs + const-expr data offsets**
(commits `b256a86`, `6087eac`, `c0c7de2`). **Bulk table ops** — `table.init`/`table.copy`/`elem.drop`
end to end + runtime passive-element storage (segments evaluated to `[]Value` with an `elem_dropped`
flag): `table_init.wast` 67 → **729/0/0**, `table_copy.wast` 120 → **1649/0/0**. **Table initializer
expressions** — inline const-expr table elems + `(table N reftype initexpr)` (lowered to an active elem
of N copies): `table.wast` 15 → **17**. **Const-expr data offsets** — `(data (memory idx)? offset?
"bytes"…)` with any-leading-list offset (`(offset …)`/folded `(i32.const)`/`(global.get)`), passive
segments, active-data-offset validation (memory presence + i32); `assert_trap (module …)` now requires
a real instantiation-time trap: `data.wast` 12 → **31**, `elem.wast` 38 → **47**, `global.wast` 108 →
**109/1**. Two bugs fixed: the generalized data assembler had mis-parsed non-`i32.const` offsets as
passive (offset dropped); and const-expr `global.get` scope was split — active-segment **offsets** may
reference any immutable global, but ref-producing element exprs / table initializers stay
imported-globals-only (satisfies data.wast:89 valid *and* global.wast:674 `"unknown global"`).
**No core regressions** (HEAD-baselined: i32 459, i64 415, call_indirect 169, func 171, block 222,
if 240, align 140, address 256, const 320/56, table_get/set/fill/size, unreached-invalid 121 all
identical). **All remaining `data`/`elem` failures are imported memories/tables → #1 stage 2.**

**Update 2026-07-13 — host imports #1 stages 2 & 3 (imported tables/memories + link type-checking)**
(commits `78c6b2b`, `1d6d9f2`). **Stage 2:** linear memory and tables became shared objects
(`*Memory`/`*Table`) so an imported one borrows the exporter's storage and observes its `grow`; the
runner backs `spectest.memory`/`spectest.table`; the assembler emits `(import … (table|memory …))`.
`data.wast` 31 → **34/0/0** (fully passing), `elem.wast` 47 → **52**. **Stage 3:** the runner
type-checks every import at link time (funcs by signature, globals by content+mutability, tables/
memories by element type + limits subtyping) and executes `assert_unlinkable` — an unknown name or type
mismatch is a link error. `imports.wast` 26 → **132/32/7** (the 93 previously-skipped `assert_unlinkable`
now run). Fixed #4 (non-spectest imported global no longer defaults to 0). Verified: cross-module shared
memory read, imported-memory grow visibility, imported-table `call_indirect`. **No core regressions**
(full HEAD-baselined sweep identical). `linking.wast` (19/84) and `memory.wast` (66/13) complete only
under ReleaseFast — debug is too slow on their large grow tests (pre-existing). Remaining imports/linking
gaps are separate features: invoke-by-module-name, inline `(table (export …) …)` (#11), tags, memory64,
`(start …)` (#3).

**Update 2026-07-13 — start function (#3) + inline abbreviations** (`07dd244`). Start section decoded
+ validated (`[] → []`, else "unknown function"/"start function") + run at instantiation (a trap fails
instantiation). Also: `(memory (data "…"))` abbreviation and inline `(memory|table (import …))` imports.
`start.wast` 0 → **11/0/0**, `imports` 132 → **137**, `memory` 66 → **69** (ReleaseFast), `table` 17/10
→ 17/9. **No core regressions** (i32 459, i64 415, table_init 729, table_copy 1649, call_indirect 169,
func 171, global 109/1, … all HEAD-identical). `start0.wast` (3/3) needs multi-memory (out of scope).

**Update 2026-07-13 — audit ledger closeout (#9/#10/#12/#13)** (`994ee23`/`3a50f75`/`e500a51`/`78647f6`).
Robustness/cleanup fixes with no conformance delta (all HEAD-identical): #9 boxes host externrefs so no
payload collides with `null_ref` (+2 new unit tests: externref-sentinel round-trip, import-after-def
rejection); #10 rejects import-after-definition (`error.ImportAfterDefinition`) instead of silently
mis-indexing; #12 pre-encodes the const-expr sections before the type section (byte-identical output);
#13 removes the `funcTypeOf` duplicate + a redundant export re-resolution; #8 (`00bceb4`) rejects a
zero/non-power-of-two `align=`; #11 (`ff3de4a`) assembles inline `(export …)` on a defined table
(`imports` 137/31 → 137/17, `linking` 19/84 → 29/108 with +10 passes, `elem` 52/15 → 52/26 — passes
stable, new failures are newly-run assertions hitting typed-ref gaps). **68 unit tests. The 2026-07-09
audit ledger is now FULLY cleared — every item #1–#16 resolved.** Remaining `.wast` gaps are new
proposals (typed/GC refs, multi-memory, EH tags), not ledger debt.

**Update 2026-07-13 — invoke-by-module-name** (`9745ecb`). The WAST runner tracks each `(module $M …)`
by name and resolves `(invoke $M …)` / `(get $M …)` / `(register "x" $M)` to that module (else the
current one); `(get …)` reads an exported global; a missing target → `NoTarget` → the assertion skips.
`linking.wast` 29/108 → **100/37** (+71 passes — named invokes were the blocker for most of it),
`elem.wast` 52/26 → **63/17** (+11). No core regressions; passes strictly up. **70 unit tests.**

**Update 2026-07-13 — typed/GC references, function-references tier (P1/P2/P2.5;** `87ac6a7`, `7ebfd1e`,
`446b61b`**).** Built in three tested increments (the "wasmtk way"):
- **P1 value-type acceptance** — the decoder + assembler accept every typed/GC reference *value-type*
  form (`(ref null? func|extern|$t|any|eq|i31|struct|array|exn)`, `anyref`/`eqref`/`i31ref`/… ) and
  collapse them to the runtime's two opaque ref slots. `ref_null` 0 → **32/0**, `ref_is_null` 2 → 18.
- **P2 function-references execution** — `call_ref`/`return_call_ref` (dispatch through a typed func
  ref; null traps), `ref.as_non_null`, `br_on_null`/`br_on_non_null`. `call_ref` 4 → **30/1**,
  `return_call_ref` 0 → **34→38**. Also fixed a latent bug: `ref.func $f` in a global-init/offset
  const-expr couldn't resolve (empty `func_names` in `emitConstExpr`).
- **P2.5 non-null refs + local-init** — distinct `funcref_nn`/`externref_nn` value types + subtyping
  (`(ref t) <: (ref null t)`) + local-initialization tracking (a non-defaultable local must be set
  before use; block/if snapshot+restore). `local_init` 5 → **8/0**, `func` 170/1 → **171/0**,
  `ref_as_non_null` 4 → **5/0**. Full git-stash A/B confirmed **zero regressions**.
Net ~**+130 passes** across the ref files from near-zero. The **function-references proposal is
essentially complete**; full **GC** (i31/struct/array heap objects, `ref.test`/`ref.cast`) is the **NEXT
major increment (P3, per the owner — ahead of the C-ABI/benchmark work)**; see `roadmap.md`.
The lone pre-existing `local_tee` 96/1 / `unreached-valid` 9/1 are concrete-type-collapse limitations
(`(ref null $t)` is indistinguishable from `funcref` in our untyped-slot model), not regressions.

### full GC — P3, i31 slice (2026-07-14)

First tested part of WasmGC. The official spec `i31.wast` corpus isn't present in this tree (the
`module/` conformance folder lives on removable media), so this slice is gated by **in-repo unit tests +
a hand-written `i31.wast`** run through the CLI. Results:

- **+5 unit tests → 77 total** (in `wat.zig`): `ref.i31`→`i31.get_s`/`_u` round-trip (incl. 31-bit sign
  wrap of `-1` and bit-30), `i31ref` non-null vs `ref.null i31`, `i31.get` on null **traps**
  (`NullReference`), `(ref i31)` up-casts into `anyref`/`eqref` slots (subtyping), and validator
  **rejections** (i31.get on a funcref; ref.i31 on a ref; `anyref` super not accepted where i31 wanted).
- **Hand-written `i31.wast`: 11/0** via `wazmrt <file.wast>` (assert_return + assert_trap for null i31).
- **No regressions** — `zig build test` green; `zig build` (CLI + C lib) and `zig build wasm`
  (freestanding) both build. The `any` hierarchy is now distinct value types with real subtyping; i31 is
  unboxed in the `u64` slot (no heap yet). See `design-decisions.md` for the representation.

### full GC — P3, struct/array slice (2026-07-14)

Second tested part (git `bec0cf7` type-space refactor 2a + the runtime 2b). Same gating as i31 — in-repo
unit tests + a hand-written `.wast` (the official GC corpus isn't in this tree). Results:

- **2a fixtures (+2)**: a hand-built binary with a struct (`(mut i32)`, `i64`) + a packed-`i8` array
  decodes to `comp_types`; a rec group whose struct field forward-refs a later struct collapses the
  `(ref 1)` to `structref` (the kind pre-scan).
- **2b (+7 unit tests)**: struct new/get/set (numeric); packed-`i8` `get_s`/`get_u` extension; array
  new/get/set/len; `array.new_fixed`; `ref.eq` identity (same/distinct/null); null-access + OOB **traps**
  (`NullReference` / `GcOutOfBounds`); a struct field holding a nested `arrayref` read back through the
  struct. **87 unit tests total.**
- **`gc_struct_array.wast`: 11/0** via the CLI (`assert_return` for struct/array/packed/`ref.eq` +
  `assert_trap` for null and out-of-bounds; `GcOutOfBounds` added to the runner's trap set).
- **No regressions**; `zig build test`/`build`/`wasm` all green. **Assembler limitation:** struct/array
  field and local types use the abstract heads (`structref`/`arrayref`/…), not concrete `(ref $t)` —
  see `design-decisions.md`.

### full GC — P3, ref.test / ref.cast slice (2026-07-14)

Adds runtime type identity (heap objects gain an RTT; i31 values are tagged bit 63 so the `any`
hierarchy is runtime-distinguishable). Same gating — unit tests + a hand-written `.wast`.

- **+3 unit tests (90 total)**: `ref.test` distinguishing struct/array/i31/eq in an `anyref` slot;
  `ref.test` nullability (`(ref null struct)` vs `(ref struct)` on null) + a concrete `(ref $t)` target;
  `ref.cast` success (downcast then `struct.get`), failure **trap** (`CastFailure`), and null (nullable
  cast accepts null, non-null cast of null traps).
- **`gc_cast.wast`: 11/0** via the CLI (`assert_return` for test/cast + `assert_trap` for cast failures;
  `CastFailure` added to the runner's trap set).
- **No regressions**; all three build surfaces green. Concrete subtyping is exact type-index match for
  assembled modules (the assembler emits no `(sub …)` supertypes yet).

### full GC — P3, br_on_cast / br_on_cast_fail slice (2026-07-14) — GC ops complete

The cast-branches, fusing test + cast + branch. Completes WasmGC op coverage.

- **+1 unit test (92 total)**: `hits` (br_on_cast: i31 → branch → `i31.get_s` = 7; struct → fall-through
  → -1) and `misses` (br_on_cast_fail: i31 → fall-through → 100; struct → branch → 200) over an `anyref`
  built as either an i31 or a struct.
- **`gc_br_cast.wast`: 4/0** via the CLI.
- Fixed `readBlockType` to decode the non-null synthetic tags (`(block (result (ref i31)) …)` around a
  cast-branch). **No regressions**; all three build surfaces green.

### full GC — P3, assembler `(sub $super …)` supertype emission (2026-07-14)

Closes the declared-subtyping loop: the assembler emits the sub form, the decoder records the supertype,
and casts walk it. **+1 unit test (93 total)** + **`gc_subtype.wast` 5/0** — `$sub`/`$sub2` extend
`$base`; `ref.test (ref $base)` on a `$sub`/`$sub2` object → 1 (transitive), on a `$base` for `(ref $sub)`
→ 0; `ref.cast` up then `struct.get $base 0` reads the shared field (42); downcasting a plain `$base` to
`(ref $sub)` traps. All build surfaces green.

### full GC — P3, concrete `(ref $t)` value types (2026-07-14) — collapse limitation resolved

`ValType` widened to `enum(u32)` (concrete refs in the high bits); `(ref $t)` now carries its exact type
through params/fields/locals/globals; producers (`struct.new`/`array.new`/`ref.func`/`ref.cast`/
`ref.null $t`) push concrete refs; `subtypeOf` uses `Module.isSubtype` for concrete↔concrete. This was
the largest single change — it briefly broke the P1/P2 ref tests (producers pushing abstract heads into
concrete slots) until the producers were made concrete-aware and `ref.null` took a heap-type immediate.

- **+2 unit tests (95 total)** + the updated rec-group decode fixture (now asserts a concrete ref, not a
  collapsed `structref_nn`): a `(ref $pt)` param **accepts** `struct.new $pt` but validation **rejects**
  `struct.new $qt` (different concrete type — previously slipped through); a self-referential
  `(ref null $node)` field traverses a linked list (10+20=30).
- **`gc_concrete.wast`: 2/0** via the CLI — a 3-node concrete linked list (sum 60) + `call_ref` through a
  concrete `(ref $ii)` global. All four prior GC `.wast` scripts still pass (11/11/4/5). All build
  surfaces green.

### C ABI — instantiate + call from C (2026-07-14)

`tests/c_smoke.c` now exercises the runtime-object surface, not just introspection, and runs
automatically via **`zig build c-smoke`** (builds `wasm_c_api.zig` as a static lib + compiles/links/runs
the C client, all cross-compiled to `x86_64-windows-gnu` so the C side gets a libc without MSVC — the
native target can't link libc on this box; the wazmrt lib stays libc-free). The test: engine/store,
decode + import/export introspection (unchanged), then **instantiate a no-import `add` module → get
exports → `wasm_extern_as_func` → `wasm_func_call(40, 2)` → `42`**, plus the bad-magic reject. It also
covers **host-function imports**: build a `wasm_functype_new` + `wasm_func_new(host_add)`, pass it in the
imports vec to `wasm_instance_new`, and call a `run` whose body is `call $env.add` → `run(40,2)=42`
through the C callback. It also covers **exported global + memory** objects: a module exporting a
`(mut i32)` global, a memory, and a `store` func — from C, `wasm_global_get`→7, `wasm_global_set`→99,
call `store(0, 0x12345678)`, read it back via `wasm_memory_data`, and `wasm_memory_grow` (1→2 pages).
Prints `OK`, exit 0. Gotcha caught while writing it: a code-section entry must start with the
**locals-count byte** (`00` for none) before the instructions, else the decoder reads an opcode as a
local type (`BadValType`).

### C ABI — host FFI over the shared library (2026-07-14)

`zig build dll` builds the C ABI as a **shared library** (`zig-out/bin/wazmrt.dll`, libc-free).
`zig build ffi-demo` then runs `examples/deno_ffi.mjs`, which has **Deno `Deno.dlopen` the DLL** and call
the standard wasm-c-api by symbol (engine/store → `wasm_byte_vec_new` → `wasm_module_new` →
`wasm_instance_new` → `wasm_instance_exports` → `wasm_extern_as_func` → `wasm_func_call`) to run
`(func (export "answer") (result i32) (i32.const 42))` → prints `answer() = 42`, `OK`. The demo does the
`wasm_val_vec`/`wasm_extern_vec` struct plumbing with `DataView` + `Deno.UnsafePointer`, so it exercises
the real ABI layout, not a convenience shim. Requires `deno` on PATH (2.x; FFI is stable).

## Performance gate — native wazmrt vs Deno/V8 (2026-07-14, first measurement)

The vision's central question (`vision.md`): does native wazmrt beat Deno/V8 on **cold-start wall-clock**
for short-lived programs, accepting it loses steady-state hot-loop throughput to V8's JIT? **Yes,
measured.** (Windows dev box; ReleaseFast; PowerShell `Measure-Command`, 40 runs each — process-spawn
floor included, which both pay.)

- **In-process microbench** (`zig build bench`, ReleaseFast):
  - **cold** decode + instantiate + call: **~0.93 µs/run** — the runtime's own per-run cost is negligible.
  - **steady** `sum(1e6)` hot loop: **~30 ns/loop-iter, ~264 Mops/s** (switch interpreter; a JIT is
    ~10–50× faster here — the Option A→B trigger if a compute-bound workload appears).
- **Cross-process cold-start** (`wazmrt.exe file.wasm export …` vs `deno run harness.js file.wasm`):
  - trivial `answer()`: **wazmrt 78 ms/run vs Deno/V8 191 ms/run → 2.4× faster**.
  - compute `sum(1e6)`: **wazmrt 135 ms/run vs Deno/V8 199 ms/run → 1.5× faster**.
- **Reading it:** wazmrt's real work is sub-µs (trivial) to tens-of-ms (1e6 loop); the per-run wall-clock
  is dominated by the OS spawn floor (~78 ms, shared with Deno) plus, for Deno, ~110 ms of V8
  init + wasm JIT-compile + JS marshalling *every run*. So wazmrt wins the short-lived / compute-light
  regime — exactly wasmtk's compiler-test outputs. V8 only overtakes once a sustained hot loop is large
  enough that the interpreter's per-iteration cost exceeds Deno's ~110 ms startup tax (well beyond
  `sum(1e6)`). **Binary size** (ReleaseFast): CLI exe ~1.13 MB (mostly Zig std + OS glue). Numbers are a
  first datapoint, not a tuned benchmark — rerun on the target hardware before acting on Option A→B.

## WASI preview 1 — first slice (2026-07-14)

`src/wasi.zig` (core `wasi_snapshot_preview1`). WASI is wired as native host imports (no interpreter
changes), so it's tested two ways:

- **+3 unit tests (98 total)**: `fd_write` gathers iovecs from memory to the target stream (and reports
  EBADF for a bad fd); `proc_exit` records the code and traps; `args_sizes_get`/`args_get` round-trip
  `argv` (pointer array + NUL-terminated strings) into linear memory.
- **CLI end-to-end**: `wazmrt examples/hello_wasi.wat` (the CLI assembles the `.wat`, sees `_start`,
  wires WASI, runs it) → prints `hello from wasi`, exit 0. `proc_exit(7)` → the CLI reports `(exit 7)`.
  A non-WASI module (no `_start`) still prints the section summary (no regression).

## What this tells the roadmap

1. **First execution milestone = the `module/wasm_mod` corpus + its `.test.json` files** — fully
   decode + validate today, small, with expected outputs. Wire the interpreter harness against these
   once the float/memory execution slices land.
2. **Conformance gold standard = `module/wasm_wast/testsuite-main`** (the official spec `.wast` suite).
   Building a `.wast` script parser (module + `assert_return`/`assert_trap`/`assert_invalid`) is a
   distinct, high-value tool; every implemented feature should eventually gate on the relevant `.wast`
   files. This is the real measure of correctness beyond the hand-picked corpora.
3. **Opcode-set expansion priority (from real data):** `0xFC` bulk-memory first (common in optimized
   output), then the exception-handling surface (tag section id 13 + `try`/`catch`/`throw`) to unlock
   more of `wasm_wasi`. SIMD (`0xFD`) later.
