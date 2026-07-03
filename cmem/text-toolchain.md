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
- **`src/wat.zig`** (MVP DONE 2026-07-02) — WAT text → wasm binary. Today: `(func …)`
  with named/anonymous `(param)`/`(result)`/`(local)`, inline + top-level `(export …)`,
  identifier→index resolution (locals/funcs), **folded + flat** instruction forms, a
  dedup'd type section, and the non-control instruction encoder (name→`Op` via
  `stringToEnum`, operands per `opcode.immediateKind`). **Verified:** assemble→decode→
  validate→run for folded add, flat mul, nested const expr, and a two-func `call` module.
  **Next in wat.zig:** structured control flow (`block`/`loop`/`if`, `br*`, blocktypes),
  memory/data/global sections + memarg, `call_indirect`.
- **`src/wast.zig`** (after) — WAST script runner: `(module …)`, `assert_return`,
  `assert_trap`, `assert_invalid`, `assert_malformed`, `invoke`, `register`;
  value literals (`(i32.const N)`, `(f64.const nan:canonical)` …); drives an
  `Instance` and compares results (with NaN semantics).

## Staged plan

1. ~~S-expression lexer/parser (`sexpr.zig`)~~ **DONE 2026-07-02.**
2. ~~WAT assembler MVP~~ **DONE 2026-07-02** (`wat.zig`): func/param/result/local/export,
   folded + flat, non-control instructions; assemble→decode→validate→run verified.
3. **WAT assembler breadth (next)** — structured control flow (block/loop/if text forms +
   blocktypes, `br`/`br_if`/`br_table`), memory/data/global sections, memarg
   (`offset=`/`align=`), `call_indirect`. This unlocks most of the arithmetic testsuite.
4. **WAST runner** — assertions + value literals; run the owner's converted
   `.wast` and the 15 binary testsuite files.
5. Run the text-module testsuite (`i32.wast`, `i64.wast`, …); expand coverage
   until a meaningful share of `testsuite-main` passes. This becomes the standing
   conformance gate (`testing.md`).

## Notes / invariants

- **Reuse, don't duplicate, the opcode table.** The assembler builds a
  name→`Op` map from `opcode.zig`; the encoder must stay in lockstep with the
  decoder (same authority).
- **Self-contained.** No external assembler at build or test time (matches the
  libc-free / no-deps ethos).
- Coverage tracks the interpreter: instructions the interpreter can't yet run
  (call_indirect, ref-types, SIMD, bulk-memory) can still be *assembled/decoded*,
  but their `.wast` assertions will trap until the matching execution slice lands.
