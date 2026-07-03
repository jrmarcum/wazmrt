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
2. **Validation** — parse instruction bytes + type-check per the spec: function/code count match,
   index bounds, operand-stack typing (study wasmi/wain/wazero validator structure). This is where the
   instruction opcode table gets defined, shared with execution.
3. **Instantiation** — memories, tables, globals, imports/exports wiring.
4. **Execution** — the interpreter core. This is the key perf/size battleground; mine wasm3
   (threading/dispatch), wasmi (register machine), WAMR-fast-interp (footprint). First real Adoption
   Checklist + Component Ledger decisions likely happen here.
5. **Grow the wasm-c-api implementation** as the runtime gains ability: `wasm_module_imports/exports`
   (once the import/export sections decode) → then instance/func/trap/call at instantiation+execution.
   The standard signatures are already declared in the vendored `wasm.h`; we just implement more of
   them. Extend `tests/c_smoke.c` alongside each addition.
6. **First `universalWasmLoader-*` integration** — prove the C-ABI static lib and/or the wasm build
   load from at least one host language end-to-end.
7. **Size/speed baseline** — measure `ReleaseSmall` binary size + a decode/exec microbench vs the
   reference interpreters; set targets.

## Parking lot / open questions

- Interpreter shape: threaded (wasm3-style) vs register-machine (wasmi-style) vs bytecode rewrite —
  decide empirically against size+speed once basic execution works.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
