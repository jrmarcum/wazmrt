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

## 📊 CURRENT spec-testsuite score (measured 2026-08-13, after R1–R5)

**284 files — 62,333 assertions passed / 216 failed / 1,429 skipped.** This is the number to quote;
every snapshot below it is older and kept as history.

⚠️ **The failed count ROSE from 143 at R4 and that is an improvement.** R5 implemented
`(module quote …)`, which had been suppressing 978 assertions; 904 of them pass, 73 fail. Passing
went 61,429 → 62,333 and skipped 2,407 → 1,429. **Quote all three numbers or none** — the failure
count alone can be improved by running less, which is exactly the state R5 found.

Reproduce exactly:

```
zig build conformance -Doptimize=ReleaseFast -Dfailures=600 \
  -Dtestsuite=<wasmtk>/tests/module/wasm_wast/testsuite-main
```

- **`-Dfailures=600` is not optional for triage.** With the default (1) each file reports only its
  first failure, and *that text names a symptom* — it mislabelled three of the T-list's five items.
- **Failure messages carry the source LINE** of the `.wast` command that produced them (`L342: …`),
  added 2026-08-13 via `sexpr.parseAllWithLines`. Before that, matching 35 failures back to their
  assertions was hand work.
- **216 is not 216 defects: 98 are BY DESIGN** (`custom-descriptors` 84, `custom-page-sizes` 12,
  `wide-arithmetic` 2 — proposals wazmrt does not target, refused honestly) and **118 actionable**,
  itemised as the R-list in `roadmap.md`: **R9** 85 (text-front-end accept-invalid), **R7** 18
  (threads), **R10** 13, legacy EH 2. R1–R5 are done; R6 was closed by R3 and R8 by R5.
- 🔴 **The item to do next is R10, and it is not close: 13 failures suppressing ~420 assertions.**
  Nine core files fail on their FIRST module and take the rest of the file into `NoTarget` —
  `br_table.wast` alone is 161 unrun assertions, and one cause is a single missing `exn` entry in
  the assembler's `abstractHeapCode`. **Rank remaining work by assertions unblocked, not by failures
  closed**; this list has now re-learned that at R3, R5 and R10.
- ⚠️ **"ACCEPT-INVALID IN CORE SPEC FILES IS ZERO" (recorded at R4) IS NO LONGER TRUE, and it was
  true when written.** R4 closed every accept-invalid the corpus could *see*. R5 implemented
  `(module quote …)`, the corpus gained sight of the TEXT front-end, and 88 more appeared in core
  files — the same class, one layer up. **A conformance number says nothing about a surface the
  corpus does not reach, and "the corpus reaches it" is itself a claim that can silently be false.**
  The guard is still one grep — `grep "should be rejected"` over a `-Dfailures=600` run — but read it
  next to the skip count, or it only measures the part of the runtime the runner can currently drive.
- ⚠️ **1,429 SKIPPED IS NOT 1,429 PASSED**, and the largest pool is core spec: `br_table.wast` alone
  has **161** unrun assertions. Any headline figure that ignores skips is an upper bound.
- ⚠️ **READ THE SKIP COLUMN WHEN TRIAGING, NOT JUST THE FAILURE COLUMN.** R3 was triaged at ~10
  failures and scored 16 — but a module that fails to build sends every assertion targeting it into
  `NoTarget`, so those 16 were suppressing **225 assertions**. `array_fill.wast` read
  `0 passed, 1 failed, 29 skipped`: one failure, and *nothing in the file ever ran*. Failures fell
  36 while real runs rose 225. **A single-digit failure count next to a double-digit skip count is a
  blackout, not a small defect.**
- ⚠️⚠️ **AND AN ITEM WHOSE SYMPTOM IS A SKIP WILL BE UNDERCOUNTED BY ANY AMOUNT.** R5 was filed at
  "~23" from the failure column; the real figure was **1,291**, because an unimplemented command form
  produces no failures at all — only skips, which were never itemised per reason. R8 was a *subset*
  of it (176 of the same skip) and was filed as a separate item because it was counted in a different
  column. **The runner reports a skip TOTAL with no breakdown; that is why both numbers were wrong.**
  Until it reports reasons, `grep -c "(module quote" <corpus>` and its siblings are the only way to
  size a runner gap.
- ⚠️ **Run `zig build size -Doptimize=ReleaseSmall` in the same session.** Nothing invokes it
  automatically and the ceilings drifted 22–25 KB between 2026-08-11 and 2026-08-13 because of that.
  ⚠️ **And run `zig build dll -Doptimize=ReleaseSmall` too** — plain `zig build` does not produce the
  DLL, so the gate grades whatever stale one is in `zig-out`. R3's first run showed the DLL at
  *exactly* its ceiling; the file was two builds old. **An exactly-zero delta is a timestamp check
  waiting to happen.**

**Unit tests: 593** (`zig build test --summary all`, 2026-08-13 after R5) — 589 pass / 4 skip from
this repo's own `D:` cwd, **593/593 from an NTFS cwd**, which is the number to quote. R3 added 7,
R4 4 and R5 3; each core test raises the printed total by two because the C-ABI target re-runs the
core suite.

⚠️ **R5's inversion check caught a test that tested the RULE but not that the rule is CONSULTED.**
The literal-syntax test called `validIntLit`/`validFloatLit` directly, so disabling their *call
sites* left it green while the assembler happily took `0xff__ffff` again. The fix was to assert the
same cases through `assemble`. **When a predicate and its wiring are separate, invert the wiring, not
just the predicate** — otherwise the test proves the function works and nothing about the product.

⚠️ **R4 also had to CHANGE seven existing tests, and that is the interesting part.** Four hand-built
EH fixtures in `interp.zig` and two WAT tests encoded the try_table catch-label off-by-one, and the
`C.refs` test asserted outright that the start function declares a `ref.func`. They passed for years
because the code they tested made the same mistake. **When a fix breaks existing tests, decide which
of the two encodes the rule — check the spec and the external corpus, not the test count.** Here the
corpus settled it in both directions: the five target files went clean and nothing else regressed.

⚠️ **Three of R3's tests were confirmed to FAIL before being kept** — the rule that a new test which
has never failed has not been shown to test anything. Each inversion was applied to the *implementation*
and the specific test watched to fail: the byte-width scaling removed from `array.new_data` (caught),
`array.copy`'s memmove reduced to a forward copy (caught, "expected 3, found 1"), and the
packed-storage comparison disabled in `array.copy` validation (caught — the module then validated
clean). The GC array ops are covered in-repo rather than only by the corpus because the `.wast` suite
lives on removable media and cannot gate a commit.

**Windows/this box:** run one `zig build` at a time, and pass `--cache-dir`/`--global-cache-dir` on
`C:` — a `D:` cache fails with `error: Unexpected`. `zig build test-security` must be run from an
NTFS cwd (`D:` is exFAT, no symlinks).

## Spec-testsuite conformance — first REAL measurement (2026-07-21, 13th pass)

**Score: 57 827 passed / 752 failed / 4 507 skipped, over 258 files** (upstream `WebAssembly/spec`,
`test/core` incl. `simd/`). Reproduce with:

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/WebAssembly/spec.git
cd spec && git sparse-checkout set test/core
zig build conformance -Doptimize=ReleaseFast -Dtestsuite=<spec>/test/core
# gate on regressions instead of zero failures:
zig build conformance -Dtestsuite=<dir> -Dbaseline=<file> -Dwrite-baseline=true
```

**Run it. That is the whole lesson of the 13th pass.** Twelve audit passes had reviewed this code without
ever executing the upstream oracle; doing so surfaced a guest-controlled **stack overflow**, missing
**UTF-8 name validation**, and **hex-float literals truncated instead of rounded in the assembler** —
within minutes, all in files the suite has always contained. See known-issues, 13th pass.

Two harness facts worth keeping:

- **SIMD had never actually run.** A v128 is *two* result slots, so every SIMD assertion failed as
  `arity 2 != expected 1` until the runner learned `v128.const` (all six shapes, arguments and
  expectations, lane-wise float matching for per-lane `nan:canonical`/`nan:arithmetic`). That one gap hid
  ~24 k assertions — and is the recorded reason the `f32x4.min`/`max` NaN bug survived eleven passes.
- **`ReleaseFast` for conformance runs.** Debug frames are large enough that deep-recursion tests used to
  segfault the runner; the depth cap is now safe in every mode, but Release is still much faster here.

The reported assembler-feature gaps were then closed across two batches (see known-issues, "Assembler
gaps" and "Open items 1–7"): inline `(export …)` on a tag, forward-referenced exports,
`(export "mem" (memory $name))`, flat `br_table`, data-segment names, the discarded memory-index
immediate, `anyfunc`, named struct fields, legacy folded `try`/`catch`, **GC const-exprs**,
**multi-memory text**, and **the whole atomics family**. **Score after the memory64 batch (Item 3,
2026-07-27): 59,705 passed / 394 failed** over the 258 core files (up from 58,639 — the overflow-safe
memory64 bounds lifted base-suite edge cases), plus the **threads `atomic.wast` suite at 302/0**, the
**multi-memory dir at 764/4** (the 4 are pre-existing table/import-limits edges), and the **memory64 dir**:
address64/align64/memory_trap64/memory_grow64/memory_redundancy64 at 100%, memory64.wast 59/1 (the 1 is a
`module definition` module-linking harness command, out of scope). Real-world `.wat` corpus assembly
468 → ~490/493; the ~2 that remain are two genuinely-malformed top-level `ArtOfWebAssembly` files (stray
line-number digits — the Chapter2 copies assemble fine). **With memory64, every wasm proposal wazmrt
targets is implemented.** **Oracle note:** proposals with a live reference implementation (GC,
multi-memory, atomics, memory64) are cross-checked against **wasmtime** (`-W gc=y` / `-W multi-memory=y` /
`-W threads=y` / `-W memory64=y`); the threads, multi-memory, and memory64 `.wast` suites are cloned
separately (`WebAssembly/threads`, `WebAssembly/memory64`), not vendored.

## Spec-testsuite conformance snapshot (2026-07-02, `wast.zig` MVP) — SUPERSEDED by the run above

> ⚠ **These pass counts are UPPER BOUNDS, not measurements.** Every snapshot below was taken while
> `assertRejected` counted **any** error as a pass — so any `assert_invalid`/`assert_malformed` module
> wazmrt could not *build* (an unimplemented command form, an unknown mnemonic) scored as a pass rather
> than a skip. Fixed 2026-07-21 (`isOurLimitation`); see known-issues, 11th pass. The note further down
> that align.wast's cases "arrive via `(module quote …)`, still `BadCommand`" describes exactly the
> inflation. **Re-run the corpus before quoting any number here.**
>
> *Lesson: a harness that treats "we couldn't run it" as "it passed" reports the shape of its own gaps as
> success — and the more gaps it has, the better it scores.*

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
`maxInt(u64)` sentinel on the value stack; a funcref value is its function index (⚠️ **SUPERSEDED 2026-08-13, R2: a funcref is `(store_slot+1)<<32 | func_index`** — the bare index named a different function in every other instance). Also made
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
**62 passed, 1 failed**. `Instance.initWithImports` (⚠️ renamed `instantiateWithImports` 2026-08-13) fills imported-global slots from host-supplied
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
(`null_ref` = uninitialized; a funcref is its function index — ⚠️ **SUPERSEDED 2026-08-13, R2: it names an instance too**; an externref is its host value). The
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

## Cold-start reality check + verification cost (2026-07-16, `zig build bench -- hash <file>`)

Measured for the `security-model.md` "does hashing every module hurt cold start?" question — and it
surfaced a framing correction worth keeping.

**Verification is negligible.** On a real 46 KB compiled guest (`hc2.wasm`):

| | time | vs instantiate | vs ~72 ms process floor |
| --- | --- | --- | --- |
| SHA-256 (pin) | 21 µs | 0.5% | 0.03% |
| Ed25519 verify (signature) | 105 µs | 2.4% | 0.15% |
| decode + instantiate | ~4.4 ms | — | 6% |

SHA-256 runs ~2.2 GB/s (SHA-NI). No extra I/O — the file is read to decode it anyway. A 1.1 MB module
still hashes in 0.5 ms. **⇒ verify-on-every-run is not a cold-start concern; pin the whole file.**

**The framing correction:** the "**~0.8–0.9 µs cold start**" we've quoted since 2026-07-14 is the
**70-byte toy compute module** — a pipeline-overhead microbenchmark, not a script. A **real** compiled
guest's decode+instantiate is **~4.4 ms** — roughly **5000× higher** — and it is nearly flat from 46 KB
to 1.1 MB (4.4 → 4.8 ms), so instantiate cost tracks **function count / instruction count**, not file
size. Still ~25× faster than Deno's ~110 ms, so the vision thesis holds — but **quote ~4.4 ms as a real
script's cold start, not 0.8 µs.** (Separate observation, not chased here: instantiate eagerly
`decodeBody`s *every* function even ones never called — a candidate lazy-decode optimization, out of
scope for the security question.)

## Performance gate — native wazmrt vs Deno/V8 (2026-07-14, first measurement)

The vision's central question (`vision.md`): does native wazmrt beat Deno/V8 on **cold-start wall-clock**
for short-lived programs, accepting it loses steady-state hot-loop throughput to V8's JIT? **Yes,
measured.** (Windows dev box; ReleaseFast; PowerShell `Measure-Command`, 40 runs each — process-spawn
floor included, which both pay.)

- **In-process microbench** (`zig build bench`, ReleaseFast):
  - **cold** decode + instantiate + call: **~0.93 µs/run** — **⚠️ this is the 70-byte toy module.** A
    real ~46 KB compiled guest is **~4.4 ms** (see the "Cold-start reality check" section above,
    2026-07-16). Both still beat Deno's ~110 ms; quote the toy number only as "runtime pipeline
    overhead," never as a real script's cold start.
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
  `sum(1e6)`). Numbers are a first datapoint, not a tuned benchmark — rerun on the target hardware
  before acting on Option A→B.

### ReleaseSmall vs ReleaseFast (2026-07-14) — ship the *distributed* artifacts as ReleaseSmall

Measured the trade because the `universalWasmLoader-*` ports link the C-ABI lib/dll, and "smallest binary"
is a vision goal. **The size win is large; the runtime cost is negligible — and the metric wazmrt wins on
(cold-start) is unaffected.**

| Artifact / metric | ReleaseFast | ReleaseSmall | Δ |
| --- | --- | --- | --- |
| C-ABI static lib (`.lib`) | 1015 KB | **123 KB** | **−88%** |
| C-ABI shared lib (`.dll`) | 311 KB | **130 KB** | **−58%** |
| CLI exe | 1166 KB | **699 KB** | **−40%** |
| steady-state (`sum(1e6)`) | ~260 Mops/s | ~247 Mops/s | ~5% slower |
| cold decode+instantiate (in-proc) | 0.76 µs/run | 1.30 µs/run | +0.5 µs (sub-2 µs) |
| **cross-process cold-start** (vs Deno) | 87.4 ms/run | 86.7 ms/run | **no change** |

Cross-process cold-start is **spawn-floor bound**, so ReleaseSmall keeps the full 2.4×/1.5×-vs-Deno
advantage; the only cost (~5% steady throughput) lands in the hot-loop regime wazmrt already cedes to
V8. **Decision:** build the shipped `.lib`/`.dll` (and the freestanding wasm — already ReleaseSmall) with
**ReleaseSmall**; reserve ReleaseFast for a specifically compute-bound embedder. See
`design-decisions.md`. (Caveat: single machine; sizes + steady-state are solid, the µs/ms cold numbers
are ±10% noisy.)

## Reading the test count (updated 2026-07-27)

`zig build test --summary all` prints **493 total (489 pass, 4 skip)** as of 2026-07-27. The count grew
across the session's work: memory64 (Item 3), the post-memory64 audit, the deferred-item cleanup
(multi-memory SIMD text, canonical index-type ordering), tag imports (the last assembler gap), the
assembler audit (flat-form SIMD regression, tag ordering, doubled index type), and the four noted-LOW fixes
(table budget, C-ABI saturating casts, s33 reader, tag typeuse check). The `cabi_tests` target's root is
`wasm_c_api.zig`, which imports `root.zig`, so it compiles and **re-runs the core module's tests too**, on
top of the standalone `mod_tests` run — so the printed total roughly doubles each new core test. **Don't
quote the printed number as a distinct-test count; quote the per-target numbers from `--summary all`.**
Green under **Debug AND ReleaseSafe**; `zig build c-smoke` 319/319.

**📊 FULL wasmtk CORPUS RUN, 2026-08-11 — 1,315 files, and it supersedes every corpus figure below.**

Run against the `ReleaseSmall` CLI. Two corpora, two different questions.

**A. WASI corpora + go_fixtures — 888 files (450 `.wasm` + 438 `.wat`)**

| outcome | count |
| --- | --- |
| ran correctly | **852** |
| library modules, no `_start` → summarized | 26 |
| ran, no output (by design) | 4 |
| traps | 6 |

**Zero hangs, zero crashes, zero decode/validation errors.** The 6 traps are 3 programs × 2 formats
(`13_SecureMatrixManagerIntegration`, `15_Trap-On-Error`, `15_panic`) and are CORRECT: **wasmtime
produces identical output and the identical exit code** on all three. ✅ **`.wat` and `.wasm` agree on
every single file**, which independently exercises the assembler against the binary decoder across 438
text files.

**B. `tests/module/` — 427 files.** 142 modules decode+validate clean (`wasm_mod` 21/21,
`bindgen_fixtures` 14/14, ArtOfWebAssembly ch.1–11, wasm-wat-samples incl. GC/memory64/reference-types).
The one "failure", `wasi-read-file/readfile.wat`, is correct sandbox behaviour — run without `--dir`, so
`fd_prestat_get` fails. **284 `.wast` scripts: 60,568 assertions passed / 525 failed / 3,038 skipped;
199 of 284 completely clean.** Triage of the 164 proposal-dir failures → **102 by design, 62 defects**;
the fix list is at the top of `known-issues.md`.

⚠️ **3,038 SKIPPED IS NOT 3,038 PASSED.** `wast.zig` increments `skipped` for unhandled command forms
and cascades a skip to every assertion depending on a module that failed to build. `utf8-invalid-
encoding.wast` is **0 passed / 0 failed / 176 skipped** — UTF-8 name validation is *entirely
unverified* by this corpus, though the 13th pass records it as fixed. Quote the skip count whenever
quoting the pass count.

🛠️ **Method notes for whoever re-runs this — both cost a full re-run to discover:**
- **`Start-Process -PassThru` does not retain the handle needed for `ExitCode`**, which reads back as
  `$null`, so every process scores as a failure. The first run reported **888/888 FAIL** while the
  captured output plainly showed `Hello, World!`. Use `System.Diagnostics.Process` directly, and read
  both pipes with `ReadToEndAsync` or a guest that fills the pipe buffer deadlocks and looks like a hang.
- **`exit 0` does NOT mean "ran".** wazmrt summarizes a module with no `_start` and exits 0, so an
  exit-code-only harness scores non-runs as passes — 26 of them here. Classify on output, not status.
- **A `.ps1` must be ASCII-only**: PowerShell 5.1 reads it as ANSI without a BOM, so a UTF-8 em-dash in
  a comment corrupts the parse.

**Update 2026-08-11 — ABI-2 COMPLETE; the counts below are superseded.**

- **From an NTFS cwd: `zig build test` = 510/510, `test-safe` = 510/510, `test-security` = 3/3, all
  ZERO skips.** From the D: (exFAT) repo the same runs report 4 skips.
- **TWO test binaries: `mod_tests` and `capi_tests`** (`src/capi.zig`). It was briefly three —
  `cabi_tests` died with `src/wasm_c_api.zig` on 2026-08-11. ⚠️ **That is why the printed total FELL
  from 763 to 510 without losing a single distinct test**: each binary imports `root.zig` and re-runs
  the core suite, so the printed number is a multiple of the real one. **Never quote the printed
  number as a distinct-test count.**
- **`zig build c-smoke` is now `zig build capi-smoke`**, and its link-time symbol gate is
  `tests/wazmrt_abi_symbols.c` — **generated from the header**, so it cannot drift by typo.
  `zig build ffi-demo` now runs `examples/deno_ffi_capi.mjs`.
- **New gate: `zig build size -Doptimize=ReleaseSmall`** — fails the build when a shipped artifact
  exceeds `tools/size-ceilings.txt`. Ceilings are EXACT, so growth must raise the number in the same
  commit and say what bought the bytes. Same shape as `test-security`: its entire value is that it CAN
  go red, and it did — it caught the ABI-2 flip growing the DLL 227 KB → 845 KB.
- ⚙️ **HOW to run from NTFS when the repo lives on the exFAT drive** — `zig build` roots itself where
  the repo is, so pointing it across the drive is the whole trick:
  ```
  cd C:\some\ntfs\dir
  zig build --build-file D:\…\wazmrt\build.zig test-security --cache-dir C:\…\zigcache --global-cache-dir C:\…\zigcache\g
  ```
  ⚠️ **Quote NTFS numbers.** A "6 skipped" result is not evidence about the sandbox — it is evidence
  about the filesystem the harness happened to run on. Owner, 2026-08-11: *"if skipped tests are
  symlink related they have to be run on the hard drive not the thumb drive to be checked correctly."*

**Update 2026-08-10 — green under all FOUR modes, and the 4 skips are not neutral.**

- ✅ **489/493 in Debug, ReleaseSafe, ReleaseFast AND ReleaseSmall.** The line above only ever claimed
  the first two, so the other two were *unverified* rather than failing — a gap in the **record**, now
  closed. Re-run all four whenever this number is quoted: ReleaseFast/ReleaseSmall remove the safety
  checks, so they are exactly where a latent index or cast bug would surface.
- ⚠️⚠️ **CORRECTED 2026-08-10: the 4 skips are an exFAT artifact, NOT a privilege problem — and NOT a code property.** From an **NTFS** working directory the suite is **493/493 with ZERO skips** and `zig build test-security` is **3/3 green**, so the sandbox-escape properties ARE verified. The earlier diagnosis here ("needs Developer Mode or elevation") was wrong: Developer Mode is already enabled on this machine. The real cause is that `std.testing.tmpDir` creates its scratch under `.zig-cache/tmp` **relative to the CWD**, and the **D: drive is exFAT**, which has no reparse points — so `FSCTL_SET_REPARSE_POINT` returns `INVALID_DEVICE_REQUEST`, not access-denied. **Run the suite from an NTFS cwd and the "489/493, 4 skipped" figure — carried in the freeze record since 2026-07-27 — becomes 493/493.** Same root cause as the `zig build` "error: Unexpected" on D: and cargo's hard-link warnings: exFAT lacks hard links and reparse points. Detail on what the skip does NOT mean:** Both
  live in `src/wasi.zig` — `symlink traversal: in-sandbox links follow, escaping links refused
  (#17/4.3)` and `symlink resolver fuzz: no adversarial topology reaches outside the preopen` — once per
  test binary, hence four. Each bails with `error.SkipZigTest` when the host refuses to create a
  symlink, and Windows refuses without **Developer Mode or elevation** (`New-Item -ItemType
  SymbolicLink` → *"Administrator privilege required"*).

  The skip is honest — with no link there is nothing to traverse — but the effect is that **the escape
  properties are unverified in that environment**, which is the wrong thing to find during a security
  review rather than before it. Partial cover exists: the absolute-target canary case is exercised on
  Windows by `examples/wasi_symlink_traversal.zig`.

  ✅ **`zig build test-security` (added 2026-08-10) removes the ambiguity.** It runs ONLY the
  sandbox-boundary tests with `WAZMRT_SECURITY_STRICT=1`, under which they **FAIL instead of skipping**
  — so an unverified sandbox is red, not green. On this box it reports **`1 pass, 2 fail`**; grant
  symlink privilege and it should go green. The default `zig build test` is deliberately unchanged
  (489/493 in all four modes), so ordinary development on an unprivileged box stays friendly while the
  security property gets a gate that CAN fail. ⚠️ The step's `.filters` list must be kept in step with
  any new escape/traversal test, or the gate silently stops covering it.

  **Before any security review: enable Developer Mode, re-run, confirm all four become passes.** If one
  then *fails*, that is a real finding the skip was hiding. **"489/493, 4 skipped" should never be
  quoted unqualified** — the port's `scripts/wazmrt-baseline.txt` now carries the same caveat.

  ⚠️ **Do NOT read the skip as "the escape was refused, so it passed."** That reading is natural — these
  *are* negative tests, and inside them `refused(openErrno(…))` genuinely means "failing to open is the
  success condition". But the skip fires **during fixture setup**, at
  `pre.symLink(…) catch { return error.SkipZigTest; }`, **before a single assertion runs**. Nothing was
  refused by wazmrt; the *host* refused the test harness a symlink, and the resolver was never invoked.

  Two facts settle it:
  - The very first assertion expects **`errno.success`** — an in-sandbox link must be *followed*. So
    "refusal = pass" is not even true of the whole test; a skip would also be claiming that
    in-sandbox traversal works, which was equally untested.
  - `SkipZigTest` is returned before `Wasi.init`, so no wasi call is made at all.

  **A skip here means zero of the three properties were checked** — not that they held. Same lesson as
  the port's `assert_unlinkable`, which was skipped for an obsolete reason and turned out to be
  insuring a real defect for two stages.

**Build note (this machine, 2026-08-10):** `zig build` from the `D:` drive fails with `error:
Unexpected` — a Zig cache/filesystem interaction, not a code problem. Build with
`--cache-dir C:\…\zigcache --global-cache-dir C:\…\zigcache\g`. The port's `check-wazmrt.sh` already
retries with a throwaway cache and reports the oracle green.

**Session conformance snapshot (2026-07-27):** full main testsuite (`WebAssembly/testsuite`, 288 files)
**60,670 passed / 568 failed**; memory64 dir **601/1** (the 1 = the out-of-scope `module definition`
module-linking command); SIMD suite **24,956/0**. Every wasm proposal wazmrt targets is implemented and the
WAT assembler has no remaining gaps (`tag` imports closed).

*(Historical: was 419 printed / 216 distinct after the 10th audit pass on 2026-07-20; each subsequent
feature/fix added regression tests, and because both targets run them, each moves the printed total by 2.)*

The four 10th-pass additions are worth knowing individually — each pins a property that is invisible in a
normal run: **`guest linear memory is zero-initialized, in every build mode`** (catches a regression to
`Allocator.alloc`, whose safety-build poison would hand the guest `0xAA` and touch every page — it is
meaningful *because* the suite runs in Debug), **`a memory minimum past the budget is refused, not
allocated`**, **`popping an empty operand stack traps instead of unwrapping null`**, and **`random_get
returns real entropy, not zeros or a predictable stream`** (non-zero output, an advancing stream, and two
instances not agreeing — confirmed non-vacuous by temporarily reseeding deterministically and watching it
fail).

**The 2026-07-21 closeout additions (5 tests):** `opcode.zig` **`rejects raw internal-tag bytes that are
not real single-byte opcodes`** (the tags the old kind-based guard structurally could not catch, the range
endpoints, and that the real ops just below the boundary still decode); `validate.zig`
**`memory-touching ops require an in-range memory`** and **`br_on_non_null accepts any reference label
type`** — both written with the newly-accepted *and* still-rejected cases so the fixes cannot drift into
over-acceptance; `wasm_c_api.zig` **`a trap keeps its instance alive after the embedder deletes it`**; and
the split-out `fuzz` text target.

**Read the trap-lifetime test before writing another lifetime test.** Its first version compared
`wasm_frame_instance(origin)` against the original pointer — which **passes against freed memory**, since
comparing a stored pointer never dereferences it. It was made real by calling `wasm_instance_exports`
*through* the frame's instance, then verified by deleting the retain and confirming a crash (exit 3).
A lifetime test must dereference, not compare.

**SIMD HAS NEVER BEEN RUN AGAINST UPSTREAM CONFORMANCE (recorded 2026-07-21).** The spec-testsuite
snapshot in this file lists i32, call_indirect, func, table_init/copy, elem, data, imports, linking,
start, the function-references files, global and f32/f64 — but **no `simd_*.wast`**. That gap hid a real
wrong-answer bug for eleven audit passes: `f32x4.min(nan, 1.0)` returned `1.0` because the SIMD path used
Zig's `@min` (minNum) instead of the NaN-propagating `fmin` the scalar path uses. Every SIMD unit test
used **finite operands**, which is exactly the region where the two agree — so a large, growing suite had
a precisely-shaped hole. **Running `simd_*.wast` through `zig build conformance` is the single highest-value
testing gap open.** *General lesson: unit tests written alongside an implementation tend to exercise the
cases the implementer was thinking about; the spec suite exists to test the ones they weren't.*

The 5th-audit malformed-input tests: `wast.zig` `runner rejects malformed commands …` (12
shapes) and a C-ABI import-memory-lifetime test (delete an imported memory after instantiation, then
`i32.load` → 42) join the existing `wat.zig` malformed-`.wat` case (11 shapes + paren bomb) and the **10**
`interp.zig` `test "hardening: …"` blocks (the `call` wild-write, epilogue under-produce, branch-arity,
branch-**destination** OOB-write, bare-`else`) — see known-issues "Run-path hardening" + "Un-swept-surface
audit".

## Malformed-input fuzz + the two new build steps (`src/fuzz.zig`, 2026-07-20)

**`zig build test-safe`** — the whole suite compiled **ReleaseSafe**: optimizer on, safety checks kept
(bounds, integer overflow, out-of-range `@intCast`, `.?` on null, reaching `unreachable`). This is the step
that turns the shipped build's *silent UB* into a loud panic, so run it alongside `zig build test` after any
memory-safety change. Currently **389/393**, same as Debug.

**`zig build conformance -Dtestsuite=<dir>`** — walks a spec-testsuite checkout, runs each `.wast` through
the in-process runner, fails the build on any assertion failure. Corpus is not vendored; with no
`-Dtestsuite` the runner prints guidance and exits 0. **Caveat: it cannot pass on an upstream checkout
today** — the snapshots in this file record known upstream failures (linking 100/**37**, return_call_ref
38/**9**, call_ref 30/**1**, global 109/**1**, f32/f64 2498/**2**), so as written it gates against *zero*
failures rather than against regressions. Needs a baseline/allow-list (expected-failures file or
`-Dmax-failures=N`) before it can serve as CI. **BASELINE ADDED 2026-07-20:** `-Dbaseline=<file>` holds the
expected failure count per `.wast` (`error <path>` for files the runner cannot parse), and
`-Dwrite-baseline=true` generates one. The step then fails only on **regressions**, reports improvements
(prompting a re-generate), and with no baseline explains why it is strict rather than silently staying red.
Verified on a synthetic corpus across all five paths: no-baseline → fail; write → generate; check → pass;
a new failure → fail; a fixed failure → pass + "improved".

**`src/fuzz.zig`** — feeds arbitrary bytes to the binary decoder + instantiation and to the WAT assembler,
asserting they only ever *error*. Two test blocks: a `std.testing.fuzz` target (coverage-guided under
`zig build test --fuzz`) and a fixed-seed 20 000-input sweep that runs every `zig build test`. Runs on
`std.testing.allocator`, so leaks/double-frees are caught too. It earned its keep immediately: **it is what
surfaced the `sexpr.zig` lone-`;` hang** (see known-issues, 10th pass).

**Coverage — REBUILT 2026-07-20 (mutation, not generation).** The original targets generated bytes from
scratch and measured **0 successful decodes in 20 000 inputs**, with `wat.assemble` rejecting every one at
`error.NotAModule` before the assembler ran — so `Instance.init`, `checkStaticIndices`, the control-flow
precompute, segment init and the whole ~3 400-line assembler were **never reached**, despite the doc
comment's claim. (It still earned its keep: that narrow reach is what found the `sexpr` lone-`;` hang.)

Now inputs are **corrupted copies of valid seed modules**. `seed_wat` holds 8 small import-free modules —
functions/code, memory + active data segment, table + element segment, globals, control flow, multi-value,
`memory.grow` — assembled to binaries by wazmrt's own assembler at test time, so the corpus needs no fixture
files. Import-free matters: `Instance.init` supplies no imports, so any import stops at `MissingImport`
before the interesting work. The binary side applies 1–2 edits (usually still decodes → instantiation and
the load-time index checks run) with an occasional 16-edit burst (usually doesn't → decoder rejection
paths); the text side splices delimiters and truncations into valid `.wat`.

Measured over the sweep's 4 000 iterations: **519 decoded, 387 instantiated, 142 assembled** — against
**0 / 0 / 0** before.

**The sweep now asserts its own coverage** (`decoded > 100`, `instantiated > 100`, `assembled > 10`), which
is the real fix: without it the targets can silently degrade to exercising nothing, which is exactly what
happened for months. Thresholds are deliberately far below the actuals so mutation-rate drift can't flake.
A companion test (`the seed corpus assembles, decodes and instantiates`) guards the corpus itself, so a WAT
syntax drift fails loudly instead of quietly emptying the fuzzer.

Deep runs on the rebuilt targets: **400 000 iterations under Debug and 400 000 under ReleaseSafe, different
seed, ~19 s each — no crashes.** That is real evidence the earlier hardening holds, and evidence the old
targets structurally could not have produced.

**Allocation amplification is now detected (2026-07-20).** The targets `catch` `error.OutOfMemory` — a
malformed input legitimately producing one is not a bug — which made the entire amplification class
*invisible by construction*, i.e. exactly what `Reader.readVecLen`, the linear-memory budget and the
`(table N …)` cap exist to prevent. The sweep now runs under a **64 MB `Budget` allocator** and asserts it
was never exceeded (no ≤8 KB input should need that much after every cap in the pipeline) **and** that
`live` returns to **0** — a leak check independent of the testing allocator's. Both hold.

**Still open:** the two targets share one `--fuzz` corpus, so an input good for the decoder is noise for
the assembler. `instantiationTooBig()` skips modules whose mutated `(memory N)` names a huge minimum, so
the sweep doesn't spend its time reserving address space.

## Authenticity — Ed25519 signatures (`src/sign.zig` + CLI, 2026-07-18)

8 tests. `signModule` signs a module and appends a `"signature"` custom section; `verify(bytes, root_key)`
returns one of four verdicts. Coverage: sign→verify **authenticated**; a body byte flipped after signing →
**tampered** (both an empty header-only module and a real wat-assembled one); signed by a different key
than the root → **foreign**; no section → **unsigned**; our magic but wrong length → **tampered**
(malformed); a foreign-named custom section is ignored → **unsigned**; plus `rootKeyFromHex` (empty→null,
64 hex→key). Tamper tests must corrupt a **body** byte (before the appended section, `< bin.len`) — a byte
inside the section instead breaks section-recognition and reads as `.unsigned`, not `.tampered`.

**Publisher CLI + `-Droot-key`** (no unit tests — thin Io/file wrappers, like `pinSubcommand`; the crypto
is covered above). The trust anchor is embedded at build time via **`zig build -Droot-key=<64 hex>`**
(empty ⇒ verification inert; a malformed value is a **build error** via `sign.rootKeyFromHex`'s
`@compileError`). `build_options` is imported only by the CLI module (`main.zig`), so `sign.zig` — compiled
into every target through `root.zig` — stays plumbing-free. **E2E-verified through the real binary, no
source edits:** `wazmrt keygen` → `wazmrt sign` → `zig build -Droot-key=<printed pubkey>` → the signed
module **authenticates and runs (42)**, a tampered-but-decodable one is **refused**, and an unsigned one
falls through to the pin path; the **default build** (no `-Droot-key`) runs everything (inert).

**Flaky-build gotcha:** `zig build`/`zig build test`/`wasi-gate` intermittently abort with a bare
`error: Unexpected end` (no file/line). It's a **stale `.zig-cache`** artifact of this Zig fork, *not* a
source error — it reproduces with all changes stashed and clears after `rm -rf .zig-cache`. If a build
fails that way, wipe the cache and re-run; don't go hunting for a code cause. Two core tests skip on an unprivileged Windows box (the #17 real-symlink test and the
traversal example gate — see below), so you'll usually see `2 skip` per run (`4` total).

## Exception-handling tests — `src/interp.zig` (2026-07-17, Phase 6)

6 tests that **build module binaries by hand** (no assembler yet — see `roadmap.md` §6.1) so they
exercise the tag-section decode, the validator's `try_table`/`throw` typing, and the interpreter's
unwinding directly (decode → validate → invoke). A tiny helper frames the section/body lengths so only
the opcodes are hand-written. Coverage: `catch` carrying a payload, `catch_all`, an **uncaught** throw
(→ `error.UncaughtException`), an exception thrown in a **callee** and caught in the caller's `try_table`
(cross-frame unwind via the `call`-site catch), `catch_ref` materializing a non-null `exnref`, and
`throw_ref` rethrowing a caught `exnref` to an outer `catch_all`. **Gotcha for future hand-built tests:**
`i32.const` is *signed* LEB128 — a single byte ≥ 0x40 decodes negative (`0x63` → −29, not 99), so keep
hand-encoded constants < 64 or emit a proper multi-byte SLEB.

**Phase 6.1 (WAT/​`.wast` round-trips):** 5 tests in `wat.zig` assemble EH *text* → binary → run
(folded + flat `try_table`, `throw`/`throw_ref`, `catch`/`catch_all`/`catch_ref`, and a `(catch $e $out)`
resolving by name to an enclosing block); 1 test in `wast.zig` runs a `.wast` script asserting a caught
exception returns a value **and** `assert_trap` fires on an uncaught one. Also CLI-verified
(`wazmrt eh.wat run`, `wazmrt eh.wast`).

**Phase 6.2 (tag imports):** 1 test in `interp.zig` imports a tag from `env`, throws + catches it by
index 0, proving imported tags lead the tag index space.

**Phase 6.3 (legacy EH):** 4 hand-built binary tests in `interp.zig` — `try`/`catch` binding a payload,
a non-throwing try skipping its handler, `catch_all`, and `rethrow` from an inner catch reaching an
outer one. They use the non-validating `instantiate` helper (the validator does not model legacy try).

**Phase 7 (multi-memory):** 3 hand-built binary tests in `interp.zig` — a store to memory 1 leaving
memory 0 untouched (index routing via the memarg bit-6 flag), `memory.copy` between two memories, and
`memory.size` selecting by index. Non-validating `instantiate`; the WAT assembler is single-memory-only.

**Phase 8 (SIMD):** 5 exec tests in `interp.zig` — a v128 held in a **local** (2 slots) through
`i32x4.add` + `extract_lane`; splat→store→load→extract; `f32x4.mul`; `i32x4.eq` (all-ones mask); and
`i32x4.max_s` — plus a `v128.const` decode test in `opcode.zig`. ~100 ops implemented (splat/lane/
shuffle/swizzle, comparisons, bitwise, int+float arith, shifts, min/max, any/all_true, bitmask).
The **drop/select-v128 width fix** adds 3 tests (drop a v128 and still read the value below it; `select`
and `select_t` of two v128s pick the whole vector) — each would return the wrong scalar if drop/select
popped one slot.

**WAT-SIMD assembler (2026-07-18):** 4 round-trip tests in `wat.zig` assemble v128 *text* → binary →
run: folded `i32x4.splat`+`add`+`extract_lane`; `v128.const i32x4`; flat-form `f32x4.add`; and a combined
test covering `v128.store`/`v128.load` with `offset=`/`align=` memargs, `i8x16.shuffle` (16-byte immediate),
and a signed `i8x16.const` lane (`-1` → `extract_lane_u` = 255). The assembler adds a ~130-entry
name→sub-opcode table (`lookupSimd`) intercepted in both `emitFoldedOne`/`emitFlatOne`, immediate parsing
for `v128.const` (all 6 shapes), lane index, shuffle bytes, and memarg.

**Rare-SIMD completion (2026-07-18):** 2 more round-trip tests in `wat.zig` cover the last common-SIMD
gaps: `extmul` (low/high, i16x8/i32x4/i64x2), `i32x4.dot_i16x8_s`, `extadd_pairwise`, `i16x8.q15mulr_sat_s`,
`i64x2` comparisons (eq/ne/lt_s/gt_s/le_s/ge_s), and the memory family — `load8x8`/`load16x4`/`load32x2`
widening loads, `loadN_splat`, `load32/64_zero`, and `loadN_lane`/`storeN_lane` (memarg **plus** a lane
immediate — a new `.mem_lane` assembler shape; per-op **natural-alignment defaults** via `simdNaturalAlign`,
or an omitted-`align=` `load8_splat` would be rejected as over-aligned). Also fixed a **latent validator
bug**: the unary ops `extend`/`convert`/`trunc_sat`/`promote`/`demote`/`extadd_pairwise` were hitting the
binary `else` default in `simdSig`, which would mis-count v128 operands for `drop`/`select` width tracking.

**Relaxed-SIMD + GC-field close-out (2026-07-18):** 1 round-trip test in `wat.zig` covers relaxed ops
(sub-opcodes ≥ `0x100`, decoded via the `readVarU32` sub): `relaxed_madd`/`nmadd` (double-rounding `a*b+c`),
`relaxed_laneselect` (full bitselect), `relaxed_swizzle`, `relaxed_min`/`max`, `relaxed_trunc` (saturating),
`relaxed_q15mulr_s`, and both `relaxed_dot` forms — each picking one of the two spec-permitted behaviors.
The **v128 GC-field** gap (a v128 struct field / array element can't fit the flat one-`Value`-per-field
object model) is closed by **failing loud**: `fieldIsV128` guards all struct/array `new`/`get`/`set` ops →
`error.UnsupportedInstruction` instead of silently dropping the high 64 bits. 1 test asserts the trap
(struct + array).

**Imported-v128-global const-expr (2026-07-18) — last v128 loose end closed.** A defined v128 global may
init from `global.get` of an imported (or preceding) v128 global; `evalConstV128` now handles `global.get`
(0x23) in addition to `v128.const`, reading both 64-bit halves from `globals`/`global_hi`. The host import
ABI gained `Imports.globals_hi` (defaulted `&.{}` — a missing/short entry means high = 0, correct for every
non-v128 global), and imported globals now fill both halves. 1 test: an imported `v128` global (i32x4
{10,20,30,40}) copied into a defined global, reading lane 0 from the low half and lane 3 from the high.
**SIMD is now fully complete** — every 0xFD op decodes, validates, and either executes or traps cleanly;
nothing silently corrupts, and there are no known v128 gaps.

## wasmtk WASI corpus — real-world conformance snapshot (re-measured 2026-07-27)

Not in the repo (sibling `../wasmtk/tests/wasi`, compiled `wasm32-wasi` programs from a mix of source
languages), so it's a *manual* check, not a CI gate. Ran each through the release CLI (stdin=/dev/null).

**Re-measured 2026-07-27 (the "run the full spectrum" pass):**
- **`wasm_wasi` (336 files): 333 run cleanly + 3 correctly trap on an uncaught exception + 0 hangs.** The
  3 traps (`13_SecureMatrixManagerIntegration`, `15_Trap-On-Error`, `15_panic`) were cross-checked against
  **wasmtime**, which traps identically at the same function indices ("thrown Wasm exception"). Zero decode
  errors, zero host crashes, zero disagreements with wasmtime.
- **`wasm_wasi_bundle` (61 files across 19 dirs): 61/61 clean.**
- **`wasm_wasi_dync` (3 files): 3/3 clean — output byte-identical to wasmtime.** *(Earlier these imported
  wasmtk's custom dynamic-runtime host `env.__host_call`/`__host_print` and were out of scope — wasmtime
  refused them too; the owner regenerated them 2026-07-27 as self-contained WASI modules and all three now
  run correctly under both engines.)*

**Net: every one of the 400 runnable files behaves correctly — 397 run cleanly + 3 correctly trap on a
deliberate uncaught exception (identical to wasmtime). wazmrt runs the whole wasmtk WASI suite.**

**This pass found and fixed one REAL bug** (`d51c004`): `15_LexicalShadowing_Stress.wasm` **infinite-looped**
(1.86 billion identical "Inner Catch:" lines) — a legacy `try`/`catch` control-flow bug where a raw `throw`
inside a catch handler re-matched the SAME handler instead of propagating to the enclosing try (the
re-throw idiom `catch (e) { … throw e; }`). See `known-issues.md`. *Method note: guest programs legitimately
print "error"/"invalid"/"trap" strings, so the first classification pass had 6 false positives — always
separate wazmrt's engine output (exit code + `trap:`/decode errors) from guest stdout/stderr, and confirm
the trap/hang cases against wasmtime.*

*(Prior 2026-07-17 snapshot after Phase 6.1/6.2/6.3: 331 run, 2 `_start`-less library modules, 3 traps —
superseded; the corpus has since grown and the one legacy-EH hang above was a later addition, now fixed.)*

## Pin verification tests — `src/pin.zig` (2026-07-17, Phase 5)

7 unit tests over the **pure** pin logic (no I/O), so the security matrix is deterministic in CI:
known SHA-256 vectors (empty/"abc"); `parseHex` round-trip + case-insensitivity + reject; `Db.parse`
(comments/labels/blanks, `contains`, and **loud-on-corruption** — a mangled content line is
`error.InvalidPinLine`, so a truncated DB fails closed, not silently short); `modeFromStr`; `stricter`
(never lowers); `modeFromDb` (`# mode:` directive); and **`decide` — the full precedence matrix**, now
`decide(explicit: ?Mode, pinned, opt_out, tty, armed)` (2026-07-18 deny-by-default work): pinned → run;
explicit `# mode: off` → run, `enforce` → deny **absolutely** (opt-out/TTY ignored), `warn` → opt-out
runs / TTY prompts / non-TTY denies; **no explicit mode + `armed` → deny an unsigned/unpinned module but
`--no-verify` overrides (no prompt)**; no explicit mode + **not armed** → run. The CLI (`verifyGate`) is a
thin shell over `decide`, computing `armed = embedded_root_key != null or db_present`. **End-to-end
verified manually** (not yet a build-graph gate): bare/no-DB runs; a **present DB arms deny** (unpinned
refused, `--no-verify` overrides with a warning, pinned runs); `# mode: enforce` + `--no-verify` **STILL
refuses**; a **keyed build** (`-Droot-key`) denies an unsigned module and authenticates a signed one;
corrupt DB fails closed. `wazmrt pin` assembles a `.wat` first so its hash matches the run-time binary,
and **`wazmrt pin <dir>`** (2026-07-18) recursively pins every `.wasm`/`.wat` under a directory (skips
non-modules, sorts, one `--db` write) — CLI-verified: 3-module bundle incl. a nested subdir, `readme.txt`
skipped, empty-dir and missing-path messages. (Pin subcommand has no unit tests — a thin Io/file wrapper,
like `keygen`/`sign`; the core `hash`/`Db`/`decide` logic is covered above.)

## Compiled-program conformance gate — `zig build wasi-gate` (2026-07-17, Phase 4.4)

Separate from `zig build test`. Compiles REAL `wasm32-wasi` programs with independent toolchains and
runs each through the wazmrt CLI, asserting exact stdout — a regression in decode/instantiate/the WASI
host surface fails the build, not a manual check. **Zig (`examples/hello_compiled.zig`) + C via `zig cc`
(`examples/c_hello.c`) run always** (both ship with the Zig toolchain, so the gate is hermetic by
default). **Rust (`examples/rust_hello.rs`) is opt-in via `-Drust-gate=true`** (needs a rustc with the
`wasm32-wasip1` target) — a genuinely different compiler, the strongest cross-toolchain signal. All
three verified running byte-for-byte on wazmrt. The gate is wired in `build.zig` via `expectStdOutEqual`
and **can fail** — confirmed by feeding it a wrong expected string (→ exit 1). Note: on Windows,
`.zig-cache` intermittently corrupts (`error: Unexpected`) when several `zig build` runs fire
back-to-back or when build output is piped to `head`/`grep` (SIGPIPE); `rm -rf .zig-cache` and run gates
one at a time from a clean cache to get a clean signal.

## WASI 4.3 leftovers — timestamps, allocate, hard link (2026-07-16)

The `NOTSUP`-stub ops implemented in 4.3's safe batch. Unit tests in `src/wasi.zig` cover the pure
logic (`timeSet` flag translation incl. the value+NOW-together → EINVAL rejection; `poll_oneoff`
reporting EBADF for a closed-fd subscription). End-to-end via **`examples/wasi_leftovers.zig`**
(`wazmrt lo.wasm --dir <writable>:/data`): `fd_filestat_set_times` / `path_filestat_set_times` set mtime
(read back within 1s granularity), `fd_allocate` extends-never-shrinks, `path_link` round-trips content
through the new name.

- **`path_link` skips on Windows** (prints `skip path_link (ENOTSUP — Windows std gap)`): Zig std's
  `dirHardLink` is `error.OperationUnsupported` on Windows (#23). It works on POSIX. The wazmrt logic is
  still exercised (it reaches `hardLink`).
- **`path_filestat_set_times` had to route through an opened handle** — the path-form
  `Io.Dir.setTimestamps` is a `@panic("TODO")` on Windows that would crash the host (#23). Watch for
  this pattern when adding path-based metadata ops.
- **`poll_oneoff` is not a stub for files:** a regular file / stdio never blocks, so "ready" is the
  correct answer, not a placeholder. Real readiness polling would only matter for pipes/sockets, which
  wazmrt doesn't have.

## WASI symlink traversal — secure full traversal (#17/4.3, 2026-07-16)

The resolver (`walkFull`) **follows** symlinks (wasmtime parity) while keeping escape impossible by
construction. Testing needs **real symlinks**, which is platform-specific:

- **Two POSIX-CI unit tests** (`src/wasi.zig`), both create symlinks via `Io.Dir.symLink` at runtime and
  **skip on unprivileged Windows** (Zig std's Windows symlink uses raw `FSCTL_SET_REPARSE_POINT`, needs
  `SeCreateSymbolicLinkPrivilege`, *not* the unprivileged `CreateSymbolicLinkW` path — so `symLink`
  fails there → `error.SkipZigTest`, never a vacuous pass):
  - *"symlink traversal: in-sandbox links follow, escaping links refused"* — an in-sandbox link is
    followed (opens); `../outside` links are refused.
  - *"symlink resolver fuzz"* — **the mandated adversarial test.** Plants a random symlink graph
    (in-sandbox, `..`-escapes, absolute-to-root, chains, cycles), hammers 2000 random guest paths, and
    asserts a **canary file outside the preopen is never read** (the oracle is the canary, not a value).
    A broken `..`-pop or absolute-rebase would read the canary → `error.SandboxEscaped`.
- **Windows manual check** (`examples/wasi_symlink_traversal.zig`, 5/5): git-bash makes unprivileged
  native symlinks with `MSYS=winsymlinks:nativestrict` (+ Developer Mode). Verifies in-sandbox followed,
  escape refused, absolute-target-can't-reach-host-file, cycle→ELOOP, and `path_readlink`.
- **Gotcha that cost time:** plain `ln -s` in git-bash makes a **copy**, not a symlink (so an "escape"
  through it is a false alarm — reading an in-sandbox copy). Force native links with
  `MSYS=winsymlinks:nativestrict`; confirm real by changing the outside target and seeing the inside
  reflect it. `Io.Dir.statFile(.follow_symlinks=false).kind` reports `sym_link` only for real reparse
  points, and on Windows a symlink to `/x` is rebased by git-bash to its *install root* — a test artifact,
  not a resolver behavior.

## The C ABI lifecycle fuzz (#22, 2026-07-16)

A randomized driver over object-lifecycle sequences — the follow-up to #21's example-based tests, which
each only cover an ordering a human chose. Building it found **two more real bugs** (a module UAF and a
`wasm_trap_delete` double-free; see `known-issues.md` #22).

- **`fuzzStep`** does new/copy/delete/host_info/cast/table-get/vec-transfer against a pool of *owned*
  handles. Borrowed views are exercised transiently, never deleted; vec transfer removes handles from
  the pool. **The allocator is the oracle** — it checks lifetimes, not values.
- **Two entry points, one driver** (a `decider` interface): the deterministic sweep runs **400 seeds ×
  250 ops in `zig build test`** (a failure prints its seed to reproduce); the coverage-guided one runs
  the same ops under **`zig build test --fuzz`** via `std.testing.Smith`. Extend `FuzzKind`/`fuzzBuild`
  when adding a ref-able type — that is the part that finds unimagined orderings.
- **Proven to fail on real bugs**: reintroducing the trap-delete bug, the module UAF, and #21-bug-4
  each turned the fuzz red (segfault / leak under the testing allocator). A gate that has only ever
  passed is decoration — this one has been watched to fail.

## The C ABI: memory-safety tests (2026-07-15) — read this before touching `wasm_c_api.zig`

**`zig build test` could not reach the C ABI for its entire life.** `root.zig` doesn't import
`wasm_c_api.zig` (the dependency runs the other way), so tests in it were unreachable from `mod_tests`
— the file had none and couldn't have. `build.zig` now has a **`cabi_tests`** target on the `test` step.

**`alloc` in `wasm_c_api.zig` is `std.testing.allocator` under test** (comptime-selected; release is
unaffected). That is the whole point: it **fails the build on double-free and leaks**.

**Why `tests/c_smoke.c` cannot substitute.** It runs on the real allocator, where a double free silently
corrupts the freelist and the test **still prints OK** — it did, against a live double free. A standalone
C repro printed `deleted b -- no crash?` and exited 0. **"It didn't crash" is not evidence of safety**;
on a C boundary it is barely evidence of anything. Use the C test for *behavior*, the Zig tests for
*lifetime*.

The lifecycle tests each encode one bug that actually shipped (see `known-issues.md` #21):
- copy an extern vec, delete both → each `Ref` freed exactly once (was a double free)
- a standalone host func in a vec → freed once *with its functype* (was a leak + unrun finalizer)
- an export handle keeps its instance alive → `exports(); instance_delete(); call()` (was a UAF, and
  needs no misuse)
- refcounted copy outlives the first handle; host-info finalizer runs exactly once, on the last handle
- **every ref-able object starts with `rc == 1`** — guards the class where `alloc.create` +
  field-by-field assignment leaves `hdr` garbage. **Any new ref-able constructor must be added there.**

One of these tests caught a use-after-free *in the test itself* (a name outliving the vec that owned
it), which is a fair advertisement for the allocator.

## The C ABI: the link-time completeness gate (2026-07-15)

`wasm.h` declared **180 functions we never defined** — a link error for any embedder following the
header, invisible to us because every C-ABI test only called what we'd already implemented. **Now 0**,
and a gate keeps it there.

- **`tests/c_abi_symbols.c` is the gate.** It takes the address of all **319** declared functions and
  links into `zig build c-smoke`: drop a symbol and *our* build fails. `c_smoke.c` prints
  `abi_symbols: 319 declared, all defined`.
- **The gate was itself verified**, by un-exporting `wasm_table_grow` and confirming c-smoke dies with
  `undefined symbol: wasm_table_grow`. A gate nobody has watched fail is decoration — check this when
  you change it.
- **Regenerate after vendoring a new `wasm.h`** — command in `known-issues.md` #20. The one trick that
  makes it work: **preprocess** the header (`zig cc -E`) before extracting names, because
  `WASM_DECLARE_OWN`/`_VEC`/`_TYPE` generate most of the API and a source grep finds a fraction. That
  is precisely why the hole hid for months.
- **Functional coverage, not just linkage** (`c_smoke.c`): linking proves the symbol exists, not that
  it works. So the smoke test also checks the semantics that are easy to get subtly wrong —
  `wasm_module_copy` is `same` as its original (references refcount, they don't clone), `host_info`
  round-trips through both the object and its `wasm_ref_t`, a downcast to the *wrong* type returns null,
  a type-object copy is a genuine deep clone (`content` pointers differ), a wrong-kind
  `externtype_as_*` returns null, and serialize → deserialize yields a module that still has its
  exports.
- **The trap surface** is covered too: `c_smoke.c` deliberately traps and walks
  `wasm_trap_origin`/`wasm_trap_trace`/`wasm_frame_*`, asserting `trapmod[module_offset]` is the real
  `unreachable` byte. Before that, `wasm_trap_message` was only reached on a "FAIL:" path that never
  fired — the whole trap surface was untested.

## Trap diagnostics — Phase 4.1 (2026-07-15)

- **+4 unit tests (110 total).** `interp`: a trap records innermost-frame-first with exact pc (a
  nop/`unreachable` body called from a nop/`call` body — deliberately the same shape as the wasm-ld
  stub this exists for); and a self-recursive trap at depth 41 truncates at `max_trap_frames = 16`
  while `trap_depth` still reports 41, with a following shallower trap reporting 3 — i.e. the trace
  resets per `invokeIndex` rather than accreting. `Module`: `funcName` resolves names, returns null for
  an index gap and past-the-end, and a **truncated name section degrades to "no names" instead of
  erroring** (it must not fail the report that is already reporting a failure).
- **Real-guest check:** the exact `minsafe.wasm` from the Phase 3 hunt now prints the answer that took
  hours to find (see "The `bitcast_invalid` trap" below), and the stripped `min.wasm` prints
  `at fn[49] +0` + the rebuild-unstripped hint.
- **Perf, and the trap it set (read this before touching `Frame.run`).** The finished change is
  **faster than the baseline it started from**: steady **286–288** vs **260–262** Mops/s, cold **0.86**
  vs **0.90** us/run (same box, same session, `git stash` A/B/A).
  Getting there was not smooth, and the shape of the mistake is the lesson:
  1. First cut measured **224** — a reproducible **14% regression**, from a change that touched *no*
     hot code. Two runs at 1787ms; not noise.
  2. First hypothesis (a new `FuncBody` field shifting `end_of`/`else_of`, which `br_if` reads every
     iteration) was **plausible and wrong** — moving the field off `FuncBody` changed nothing.
  3. Bisecting the diff by file (`git stash push <paths>`) localized it to `interp.zig`, then to a
     single call *on the error path*: `Frame.run`'s `errdefer` expands at every `try` in a ~200-arm
     switch, so a slightly bigger `recordTrap` inlined into hundreds of landing pads and evicted the
     loop from i-cache. **`noinline` fixed it and beat the old baseline by 10%** — 4.1 had been
     inlining it too.
  **Takeaways:** a hot-path regression can originate on an error path; bisect, don't theorize; and
  always A/B against a **same-session** baseline — the ~264 Mops/s recorded 2026-07-14 is not
  comparable across days, and run-to-run spread here is ~8%.

## WASI Phase 3 — the sandboxed filesystem (2026-07-15)

- **+3 unit tests (106 total).** The load-bearing one is **`resolve` contains guest paths inside the
  preopen**: a table of accepted+normalized paths (`./a`, `d/./e//f`, `d/../e`, `d\e`, `.`) and a table
  of rejected escapes (`..`, `../etc/passwd`, `a/../../b`, `/etc/passwd`, `\Windows\x`, `C:\x`, `C:x`,
  `\\?\C:\x`, embedded NUL, empty). Also: `path_open` rejects an escaping path with **ENOTCAPABLE**
  *with `io` set to `undefined`* — so if the rejection were ever not purely lexical, the test would
  crash rather than pass; and `fd_prestat_get`/`fd_prestat_dir_name` enumerate preopens and EBADF at
  the first non-preopen (which is how wasi-libc knows to stop).
- **Compiled-program gate** (`examples/wasi_files.zig`, `-target wasm32-wasi`):
  `wazmrt files.wasm --dir <tmp>:/data` → **16/16 `ok`**, covering prestat, `path_open` O_CREAT,
  `fd_write`/`fd_read` round-trip, `fd_seek`, `path_filestat_get` (type+size), `path_create_directory`,
  `fd_readdir`, four refused escapes, an allowed interior `..`, and cleanup (`path_remove_directory`,
  `path_unlink_file`, unlinked-file-is-gone). The guest cleans up after itself, so the preopen dir is
  empty afterward — check that, since leftovers mean a delete silently failed.

### The `bitcast_invalid` trap (cost hours; recognize it instantly next time)

**Symptom:** a compiled guest traps `Unreachable` with no output and no failing WASI call.
**Cause:** the guest declared `extern "wasi_snapshot_preview1" fn fd_write(...) i32` while `std.os.wasi`
declares the same import returning `errno_t` (`enum(u16)`). One import, two signatures — wasm-ld can't
reconcile them, so it points the call at a generated stub named
`.Lfd_write|wasi_snapshot_preview1_bitcast_invalid` whose entire body is `unreachable`. **No warning at
compile time.** It only fires if that code path runs, which is why trivial guests seemed fine and
`--dir` (which makes std's `Preopens.init` run) appeared to "break" things.
**Tell:** since Phase 4.1 the runtime just tells you — the trap names the frame:
```
trap: Unreachable
  at fn[31] <.Lfd_write|wasi_snapshot_preview1_bitcast_invalid> +0
  by fn[30] <min.main> +22
```
`+0` of a stub is the giveaway even on a stripped build (`at fn[49] +0` with no name). If the guest is
stripped and you need the symbol, rebuild it `-O ReleaseSafe`/`Debug` — names come from the wasm name
section, which ReleaseSmall drops.
**Rule: examples must call WASI through `std.os.wasi`, never hand-rolled `extern`s.**

### The `openFile(.follow_symlinks = false)` host crash (a real Zig 0.16 std bug)

`Io.Dir.openFile` on Windows opens the handle **ASYNCHRONOUS** when `follow_symlinks = false` but still
returns `.flags = .{ .nonblocking = false }` (`Threaded.zig:5033`). The first `readPositional` then
takes the synchronous path and hits `.PENDING => unreachable` **inside std — crashing the host, not the
guest**. `createFile` is unconditionally `SYNCHRONOUS_NONALERT`, which is why only the open-existing
path crashed and `path_open` with `O_CREAT` looked fine. **Workaround in `wPathOpen`:** implement
O_NOFOLLOW ourselves (`statFile(.follow_symlinks=false)`, return `ELOOP` on a symlink) and then always
open with follow — same semantics, no async handle. Recheck when upgrading Zig.

## WASI Phase 2 — clocks, poll_oneoff (sleep), stdin (2026-07-14)

- **+2 unit tests (103 total)**: `fd_read` scatters stdin across two iovecs (4+3 of "abcdefg"), reports
  the exhausted reader as EOF (0 bytes, still SUCCESS), and EBADFs a non-stdin fd; `poll_oneoff` reports
  an fd subscription ready immediately (echoing userdata, error=0, type) and rejects 0 subscriptions.
- **Compiled-program gate** (`examples/wasi_clock_stdin.zig`, `-target wasm32-wasi`):
  `echo "hello stdin!" | wazmrt p2.wasm` → `clock_res_get works` / `poll_oneoff clock sleep works`
  (the guest asserts ≥15 ms actually elapsed around a 20 ms clock subscription) / `stdin echo: hello
  stdin!`. With `< /dev/null` it prints `stdin: EOF`.
- All surfaces green (`test`/`build`/`wasm`/`c-smoke`); the Phase 1 and hand-written WASI examples
  still pass.

## Bulk memory + saturating truncation — the `0xFC` completion (Phase 1, 2026-07-14)

**Milestone: a real LLVM-compiled `wasm32-wasi` program runs and prints in wazmrt.**

- **+3 unit tests (101 total)**: saturating truncation (in-range truncation, NaN→0, ±inf→min/max,
  unsigned negatives→0 — all where the trapping form errors); bulk memory (`memory.fill`,
  `memory.copy` incl. an **overlapping** move behaving like memmove, `memory.init` from a passive
  segment, and `data.drop` making a segment read as empty → OOB); OOB `fill`/`copy` trap.
- **Compiled-program gate**: `examples/hello_compiled.zig` built with
  `zig build-exe -target wasm32-wasi -O ReleaseSmall` and run by `wazmrt hello.wasm` prints
  `Hello from a compiled WASI program!` / `bulk-memory memcpy works` / `saturating truncation works` —
  real compiled code whose `@memcpy` lowers to `memory.copy` and whose float→int lowers to
  `i32.trunc_sat_f64_s`, calling wazmrt's WASI `fd_write`.
- ~~**Guest-side finding:** Zig 0.16's `Io`-model file writer never issues `fd_write(1)` for stdout —
  a guest toolchain gap.~~ **RETRACTED 2026-07-15 — this finding was wrong.** See "The
  `bitcast_invalid` trap" below; the example's own `extern` declaration was the cause. Pure `std.Io`
  stdout works under wazmrt.
- All surfaces green (`test`/`build`/`wasm`/`c-smoke`).

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
