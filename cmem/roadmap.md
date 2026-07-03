# Roadmap

## Status (2026-07-02) — project inception

**Done:**
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

**Not started:** any reference-project code adoption (100% original so far); validation; instantiation;
execution.

## Next increments (rough order)

1. ~~Decode the type/function/import/export sections~~ **DONE 2026-07-02** (also table/memory/global +
   full `Extern` resolution; exposed via C `wasm_module_imports/exports` + the wasm-c-api type-object
   system). ~~Decode the code section~~ **DONE 2026-07-02** (locals + raw body bytes per defined
   function, arena-owned; instructions not yet parsed).
2. **Validation** (in progress). ~~Shared opcode table + `Instr` IR + byte-code decoder~~ **DONE
   2026-07-02** (`src/opcode.zig`: core-MVP `Op` enum 0x00–0xC4, `Imm`/`Instr`, `decodeBody`; ref-type
   / `0xFC` / `0xFD` / multi-byte block-types → `UnsupportedOpcode`; 4 tests). **Remaining:** the
   type-checking validator over the IR — function/code count match (deferred from decode), index bounds
   (local/global/func/type/label), structured control-flow + operand-stack typing (the meaty part;
   study wasmi/wain/wazero validator structure). Then expand the opcode set (ref-types, `0xFC`
   bulk-memory, eventually SIMD).
3. **Instantiation** — memories, tables, globals, imports/exports wiring; grow the C ABI to
   `wasm_instance_new` + `wasm_func_call`.
4. **Execution** — `while … switch(op)` interpreter over the `Instr` IR (Option A), untyped `u64`
   value-stack slots; call/locals/globals/memory. The key perf/size battleground: keep the IR a clean
   seam so a register-machine pass (Option B, wasmi) can be layered later if benchmarks demand it.
   First real Adoption Checklist + Component Ledger decisions likely happen here.
5. **Grow the wasm-c-api implementation** as the runtime gains ability: `wasm_module_imports/exports`
   (once the import/export sections decode) → then instance/func/trap/call at instantiation+execution.
   The standard signatures are already declared in the vendored `wasm.h`; we just implement more of
   them. Extend `tests/c_smoke.c` alongside each addition.
6. **First `universalWasmLoader-*` integration** — prove the C-ABI static lib and/or the wasm build
   load from at least one host language end-to-end.
7. **Size/speed baseline** — measure `ReleaseSmall` binary size + a decode/exec microbench vs the
   reference interpreters; set targets.

## Parking lot / open questions

- Interpreter shape: **DECIDED 2026-07-02 — Option A** (switch over a pre-decoded IR); see
  `design-decisions.md`. Open sub-question: whether/when to add the Option B register-rewriting pass —
  decide empirically against size+speed once basic execution works and there's a benchmark.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
