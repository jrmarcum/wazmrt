# Roadmap

## Status (2026-07-02) — runtime executes; text toolchain in progress

The full pipeline runs end-to-end: **decode → validate → execute** (int/float/memory), verified on the
real `module/wasm_mod` corpus against its `.test.json` values. A native **WAT text assembler** is done;
the **WAST script runner** (`wast.zig`) is next.

**Done:**
- **Runtime pipeline** — `Module.decode` (all core sections + resolved import/export types + bodies) →
  `opcode.zig` IR → `validate.zig` (spec type-check) → `interp.zig` (switch interpreter: i32/i64/f32/f64
  arithmetic, control flow, `call`, linear memory + data init, traps). Runs `fib(20)=6765`,
  `fac(7)=5040`, `sieve(30)=10`, etc. — all match `.test.json`.
- **Text toolchain** — `sexpr.zig` + `wat.zig` (WAT→wasm binary) + **`wast.zig` (WAST runner)**. Runs
  the **official spec testsuite** via `wazmrt <file.wast>`, both positive *and* negative conformance
  (`assert_invalid`/`assert_malformed`/`assert_exhaustion`; `assert_trap` gated on a real trap).
  Reference types, multi-table, imported globals, extended-const, reference-type table ops, element
  init expressions, and **imported functions + `register`/module-linking** all land; the
  validator/decoder correctly reject invalid/malformed modules (2026-07-09 post-audit).
  Representative: i32 **459/0**, i64 **415/0**, block **222/0**, if **240/0**, call_indirect **169/0**,
  select **154/0**, func **171/0**, align **140/0**, custom **8/0**, binary-leb128 **58/1**, elem
  **38/28**, func_ptrs **32/0**, table_copy **120**, table_init **67**, global 108/2 (see `testing.md`).
  **65 unit tests.** Remaining gaps: imported **tables/memories** (`imports.wast` 26/56), bulk table ops
  (`table.init`/`.copy`/`elem.drop`), passive element segments.
- **Licensing baseline** (git `888b87e`): dual `MIT OR Apache-2.0` (`LICENSE-MIT` + `LICENSE-APACHE`),
  `NOTICE`, and the compliance scaffold `third_party/LICENSES.md` (obligations table + Adoption
  Checklist + Component Ledger + verified SPDX inventory). README license section + SPDX + contribution
  clause. See `licensing.md`, `reference-projects.md`.
- **First runtime vertical slice**: Zig 0.16 project reshaped from `zig init` into a runtime skeleton.
  `Reader` (zero-copy + LEB128) + `Module` (header validate + section index). 7 unit tests passing.
- **Three build surfaces wired**: native CLI, C-ABI static lib, freestanding-wasm build. All
  build/test/run verified (see `design-decisions.md`).
- **C ABI = the standard wasm-c-api** (decision + slices, 2026-07-02): vendored `wasm.h` (Apache-2.0,
  first ledger entry); implemented `config`/`engine`/`store` + byte vecs + `wasm_module_new`/`_validate`/
  `_delete`, **plus `wasm_module_imports`/`exports` and the full type-object system** (valtype/functype/
  externtype/global/table/memory/importtype/exporttype) in `src/wasm_c_api.zig`; extension header
  `include/wazmrt.h`. **Verified from C** via `tests/c_smoke.c` (zig cc) — enumerates a module's import
  (`env.add`) and export (`run`, params=2 results=1). Retired the ad-hoc `wazmrt_module_*` ABI.
- **cmem/ project memory** established (this folder), mirroring the wasmtk setup.

**Remaining:** imported **tables/memories** across modules (host imports stage 2/3 → WASI; gates
`imports.wast` — and now the *only* blocker for the rest of `data.wast`/`elem.wast`); `(start …)`;
growing the wasm-c-api past introspection; first `universalWasmLoader-*` integration. Still **100%
original runtime code** — no reference-project code adopted yet (only the vendored `wasm.h`).
`call_indirect` + tables + globals + type-ref block types + **reference types** + **multi-table** +
NaN-payload float literals + **imported globals** + extended-const + **reference-type table ops** +
**negative-conformance + validator/decoder strictness** + **element init expressions** + **imported
functions + `register`** (host imports stage 1) **DONE 2026-07-09**. **Bulk table ops
(`table.init`/`.copy`/`elem.drop`) + passive element segments + table initializer expressions +
const-expr/passive data segments DONE 2026-07-13** (`table_init` 729/0, `table_copy` 1649/0, `data`
12→31; #15 fully closed). See `known-issues.md` for the post-audit fix ledger.

## Next increments (rough order)

1. ~~Decode the type/function/import/export sections~~ **DONE 2026-07-02** (also table/memory/global +
   full `Extern` resolution; exposed via C `wasm_module_imports/exports` + the wasm-c-api type-object
   system). ~~Decode the code section~~ **DONE 2026-07-02** (locals + raw body bytes per defined
   function, arena-owned; instructions not yet parsed).
2. **Validation** — **DONE 2026-07-02.** `src/opcode.zig` (core-MVP `Op` enum 0x00–0xC4, `Imm`/`Instr`,
   `decodeBody`; ref-type / `0xFC` / `0xFD` / multi-byte block-types → `UnsupportedOpcode`) + the
   type-checking validator `src/validate.zig` (spec Appendix algorithm: value stack + control frames +
   `unknown` bottom; count match, index bounds, control flow, operand-stack typing). 8 unit tests;
   **all 12 `wasm_mod` validate; every fully-decoding `wasm_wasi` validates** (see `testing.md`).
   **Opcode-expansion priority (from real corpus data): `0xFC` bulk-memory first, then exception
   handling (tag section id 13 + try/catch), then SIMD** — what `wasm_wasi` needs beyond core MVP.
3. **Instantiation** — memories, tables, globals, imports/exports wiring; grow the C ABI to
   `wasm_instance_new` + `wasm_func_call`.
4. **Execution** — **integer + float + memory slices DONE 2026-07-02** (`interp.zig`): switch
   interpreter over the IR (Option A), untyped `u64` slots, per-call label stack + precomputed branch
   targets. i32/i64 **and f32/f64** arithmetic/comparison/bitwise + all conversions, locals, globals,
   `drop`/`select`, structured control flow, direct `call`, **linear memory** (min-page alloc + active
   data-segment init, load/store all widths, `memory.size`/`grow`), and traps — 9 unit tests.
   **VERIFIED end-to-end on real modules:** the CLI gained `wazmrt <file.wasm> <export> [args…]` and
   runs the whole `module/wasm_mod` corpus to its `.test.json` values (`fib(20)=6765`, `fac(7)=5040`,
   `isLeapYear`, `isOdd`, `sieve(30)=10` via memory). **`call_indirect` + tables + globals +
   reference types DONE 2026-07-09** (type-checked indirect dispatch; global-init const-expr eval;
   `ref.null`/`ref.is_null`/`ref.func` + funcref/externref values; multi-table dispatch). **Remaining
   execution slices:** (a) `table.get`/`.set` + passive elements, (b) **host imports** (needed for
   WASI). Keep the IR a clean seam so a register-machine pass (Option B, wasmi) can be layered later
   if benchmarks demand it.
5. **Text toolchain — WAT assembler + WAST runner** (IN PROGRESS, owner-chosen 2026-07-02; the
   `.test.json` harness was dropped in favor of the standard `.wast` format). `sexpr.zig` DONE;
   **`wat.zig` DONE** (WAT→binary: funcs/exports, folded+flat, structured control flow + labels +
   blocktypes, memarg, memory + data sections — all assemble→run verified). Next: `wast.zig`
   (assertion runner), then run `module/wasm_wast/testsuite-main` as the standing conformance gate.
   global/table/elem, multi-value block types, and `call_indirect` all **DONE** (2026-07-02/07-09);
   deferred: reference-type instructions, imports. See `text-toolchain.md`.
6. **Grow the wasm-c-api implementation** as the runtime gains ability: `wasm_module_imports/exports`
   → then instance/func/trap/call at instantiation+execution. The standard signatures are already
   declared in the vendored `wasm.h`; we just implement more of them. Extend `tests/c_smoke.c` alongside.
6. **First `universalWasmLoader-*` integration** — prove the C-ABI static lib and/or the wasm build
   load from at least one host language end-to-end.
7. **Size/speed baseline** — the real perf gate (see `vision.md` → Performance target). Benchmark
   **native wazmrt vs Deno/V8** on wasmtk's own outputs, timing **cold-start wall-clock** and
   **steady-state throughput** separately (which regime does wasmtk live in?). Also size + startup vs
   wasm3 / WAMR-fast-interp. This data decides whether/when to move Option A → B (register machine).
   Baseline sizes today (`ReleaseSmall`): CLI exe ~611 KB (mostly Zig std + OS glue), C-ABI lib ~34 KB,
   freestanding wasm ~13 KB (lib/wasm are the decode/validate subset — execution not yet exported).

## Parking lot / open questions

- Interpreter shape: **DECIDED 2026-07-02 — Option A** (switch over a pre-decoded IR); see
  `design-decisions.md`. Open sub-question: whether/when to add the Option B register-rewriting pass —
  decide empirically against size+speed once basic execution works and there's a benchmark.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
