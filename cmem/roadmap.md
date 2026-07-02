# Roadmap

## Status (2026-07-02) — project inception

**Done:**
- **Licensing baseline** (git `888b87e`): dual `MIT OR Apache-2.0` (`LICENSE-MIT` + `LICENSE-APACHE`),
  `NOTICE`, and the compliance scaffold `third_party/LICENSES.md` (obligations table + Adoption
  Checklist + Component Ledger + verified SPDX inventory). README license section + SPDX + contribution
  clause. See `licensing.md`, `reference-projects.md`.
- **First runtime vertical slice**: Zig 0.16 project reshaped from `zig init` into a runtime skeleton.
  `Reader` (zero-copy + LEB128) + `Module` (header validate + section index). 7 unit tests passing.
- **Three build surfaces wired**: native CLI, C-ABI static lib + `include/wazmrt.h`, freestanding-wasm
  build. All build/test/run verified (see `design-decisions.md`).
- **cmem/ project memory** established (this folder), mirroring the wasmtk setup.

**Not started:** any reference-project code adoption (100% original so far); validation; instantiation;
execution.

## Next increments (rough order)

1. **Decode the type + function + code sections** into real structures (function signatures, code
   bodies), extending `Module`. Add fixtures from real `.wat`→`.wasm` outputs.
2. **Validation** — type-check per the spec (study wasmi/wain/wazero validator structure).
3. **Instantiation** — memories, tables, globals, imports/exports wiring.
4. **Execution** — the interpreter core. This is the key perf/size battleground; mine wasm3
   (threading/dispatch), wasmi (register machine), WAMR-fast-interp (footprint). First real Adoption
   Checklist + Component Ledger decisions likely happen here.
5. **Grow the C ABI** (`wazmrt.h`) with instantiate + call-export, informed by wasmtime/wasmer/WAMR C
   API shapes. Keep the handle opaque; bump `abi_version` on breaks.
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
