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
| `nop`/`select`/`local_tee`/`fac`/`stack` | module build fails → asserts skipped |

- **`skipped`** = commands the MVP runner doesn't handle (`assert_invalid`/`assert_malformed`,
  `register`, `get`), *plus* asserts whose module failed to build.
- **The `0 passed` files are single module-build failures**, not many distinct bugs: those modules
  contain a function using a **deferred construct** — **multi-value block types / results**
  (`(result i64 i64)`, `(loop (param i64 i64) (result i32) …)`), **typed `select`** (`0x1c`), or
  `table`/`elem`. Since a module assembles all-or-nothing, one advanced function skips the rest.
- **The 2 float failures** are NaN-payload/propagation edge cases (e.g. a signaling-NaN result where
  Zig's native op yields a different NaN bit pattern than the exact-bits assertion expects).

**Takeaway:** thousands of official spec assertions pass; every gap is a *named, deferred feature*, not
a core correctness bug. Next breadth to unlock more files: **multi-value block types**, typed `select`,
then `table`/`call_indirect`.

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
