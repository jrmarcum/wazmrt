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
  the type section; `select_t` 0x1c). **Deferred in wat.zig:** `global`/`table`/`start`/`elem`
  sections, `(type $t)` block-type references, `call_indirect`.
- **`src/wast.zig`** (MVP DONE 2026-07-02) — WAST script runner: `(module …)` text +
  `(module binary …)`, `assert_return`, `assert_trap`, `invoke`; value literals incl.
  `nan:canonical`/`nan:arithmetic`; drives an `Instance` and compares (NaN-aware). CLI
  `.wast` mode. **Passes thousands of official-testsuite assertions** (see `testing.md`).
  Deferred: `assert_invalid`/`assert_malformed`, `register`/multi-module, `get`, `(module quote …)`.

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
   section + emits typed select). Fixed `fac` (0→6). **Next: `call_indirect` + tables** — the blocker
   for `block`/`nop`/`if`/`loop` (they use `(call_indirect (type $t) …)`). This is the standing
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
