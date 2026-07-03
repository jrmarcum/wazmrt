# Testing

## Unit tests (in-repo)

`zig build test` runs the `test` blocks across the core modules (15 as of 2026-07-02: Reader, Module,
opcode). The C ABI is verified separately from C via `tests/c_smoke.c` compiled with `zig cc` (see
`design-decisions.md` → "Verified working"). Hand-built byte fixtures live inline in the tests.

## External conformance corpora (owner-designated 2026-07-02)

Two folders in the sibling **wasmtk** project are the designated real-world test inputs. They are
**outside this repo** (not copied in) — reference them by path.

### Module functions → `…/wasmExamples/wasmtk/tests/wasm_mod`

~12 small modules that export plain functions (adder, factorial, evenOrOdd, isLeapYear, sieve, and
`fib` in wat / rs / ts / zig). Each `<name>.wasm` has a sibling **`<name>.test.json`** giving the
expected results — a ready-made execution conformance harness:

```json
{ "add":  [ { "args": [10, 20], "expected": 30, "desc": "basic sum" }, … ],
  "fib":  [ { "args": [10],     "expected": 55, "desc": "fib(10)" }, … ] }
```

Shape: `{ "<exportName>": [ { "args": [...], "expected": <value>, "desc": "..." }, … ] }`. Once
execution lands, the harness is: load the `.wasm`, call the named export with `args`, compare to
`expected`. **This is the first execution target.** Also present per module: `.wat` (readable form)
and the original `.ts`/`.rs`/`.zig` source.

### WASI programs → `…/wasmExamples/wasmtk/tests/wasm_wasi`

1377 entries — larger TS→WASI programs compiled by wasmtk (each with `.wasm` + `.wat` + `.wit` +
`.ts`). The target for **WASI execution** later (needs the WASI import surface). Big, optimizer-heavy
modules — they exercise far more of the instruction/section space than `wasm_mod`.

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

## What this tells the roadmap

1. **First execution milestone = the `wasm_mod` corpus + its `.test.json` files** — fully decodable now,
   small, with expected outputs. Build the interpreter against these.
2. **Opcode-set expansion priority (from real data):** `0xFC` bulk-memory first (common in optimized
   output), then the exception-handling surface (tag section id 13 + `try`/`catch`/`throw`) to unlock
   more of `wasm_wasi`. SIMD (`0xFD`) later.
