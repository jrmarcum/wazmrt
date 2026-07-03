# Overview

`wazmrt` is a **Zig-based WebAssembly runtime** aimed at being **blazingly fast** and the **smallest
possible binary**, and itself **compilable to `wasm32-freestanding`** so it can be embedded *inside*
another wasm host. It is consumed from any language via the `universalWasmLoader-*` loaders (see
`vision.md`).

It is being built by studying the best/fastest parts of the leading wasm runtimes (see
`reference-projects.md`) and adopting — with full attribution (`third_party/LICENSES.md`) — only what
earns its place.

## Repo layout

```text
wazmrt/
├── build.zig              # Build graph: CLI exe, C-ABI static lib, wasm target, tests
├── build.zig.zon          # Package manifest (name .wazmrt, v0.1.0, min zig 0.16.0)
├── cmem/                  # Portable project memory (this folder)
├── include/
│   └── wazmrt.h           # C ABI header — the contract for universalWasmLoader-*
├── src/
│   ├── root.zig           # Public library surface (pub re-exports; wasm-friendly, libc-free)
│   ├── main.zig           # CLI: summarize a .wasm, or run mode `wazmrt <file> <export> [args…]`
│   ├── types.zig          # Format constants, SectionId, DecodeError set
│   ├── Reader.zig         # Zero-copy cursor: bounds-checked reads + LEB128/SLEB (file-as-struct)
│   ├── Module.zig         # Decoded module: sections + resolved imports/exports + code (file-as-struct)
│   ├── opcode.zig         # Shared opcode table (Op/Imm/Instr) + byte-code → IR decodeBody
│   ├── validate.zig       # Spec type-checking validator over the IR (value + control-frame stacks)
│   ├── interp.zig         # Instance + switch interpreter over the IR (u64 slots, label stack)
│   ├── sexpr.zig          # S-expression lexer/parser for .wat/.wast (text toolchain front-end)
│   ├── wat.zig            # WAT text → wasm binary assembler (reuses opcode.zig in reverse)
│   ├── wasm_c_api.zig     # Implements the standard wasm-c-api (smp_allocator, no libc)
│   └── wasm_entry.zig     # Freestanding wasm32 export surface (wasm_allocator)
├── tests/
│   └── c_smoke.c          # C smoke test exercising the wasm-c-api surface (zig cc)
├── third_party/
│   ├── LICENSES.md        # Compliance ledger + adoption checklist + SPDX inventory
│   └── wasm-c-api/        # Vendored standard wasm.h (Apache-2.0) + its LICENSE
├── LICENSE-MIT · LICENSE-APACHE · NOTICE
└── README.md              # Public, user-facing doc
```

## Key source files

The pipeline, in order: **decode → validate → execute**, with a text front-end (**assemble**).

| File | Role |
| --- | --- |
| `src/Reader.zig` | Allocation-free cursor: bounds-checked reads, fixed-LE u32, unsigned + signed LEB, float-bit reads. The decoder core. |
| `src/Module.zig` | The decoded module + `decode()`: header, all core sections, resolved import/export extern types, function bodies, globals/memories/data. Arena-owned. |
| `src/opcode.zig` | The **shared instruction authority** — `Op` table, `Imm`/`Instr` IR, `decodeBody`. Used by validate, the interpreter, *and* the assembler (in reverse). |
| `src/validate.zig` | Spec type-checking validator over the IR (value + control-frame stacks). |
| `src/interp.zig` | `Instance` + the switch interpreter (untyped `u64` slots, label stack). Runs int/float/memory. |
| `src/sexpr.zig` + `src/wat.zig` | Text toolchain: S-expression parser + WAT→wasm-binary assembler (`wat.zig` maps names→`Op` via `stringToEnum`). |
| `src/wasm_c_api.zig` | The **standard wasm-c-api** integration ABI every `universalWasmLoader-*` port binds to (+ the `wazmrt_*` extension handshake). |
| `src/root.zig` | Library surface (`@import("wazmrt")`). Re-exports `types`/`Reader`/`Module`/`opcode`/`validate`/`interp`/`Instance`/`sexpr`/`wat`/`decode`/`version`/`abi_version`. |

## Build targets (see architecture.md)

- `zig build`      → native CLI `wazmrt` + C-ABI static lib `wazmrt` + installs `wasm.h` + `wazmrt.h`
- `zig build test` → runs the unit tests (**41 passing** as of 2026-07-02)
- `zig build wasm` → builds the runtime itself as a freestanding `wasm32` module
- `zig build run -- <file.wasm> [export args…]` → summarize a module, or invoke an export and print results

## Mental model

- **Zero-copy decode.** `Reader` borrows slices of the input; `Module` stores only section `{id,
  offset, size}` extents, not eager copies — so the source bytes can be freed after decode.
- **Libc-free core.** `root.zig` and its deps pull in no libc, so the same code targets native *and*
  `wasm32-freestanding`. The C-ABI lib uses `std.heap.smp_allocator` (not `c_allocator`). See
  `design-decisions.md` for why (smaller binary + no MSVC requirement on Windows).
- **Decode + validate + execute all work.** The pipeline decodes all core sections → the `opcode.zig`
  IR, type-checks it (`validate.zig`), and a switch interpreter (`interp.zig`) runs it — integer/float
  arithmetic, control flow, `call`, and **linear memory** end-to-end. The whole `module/wasm_mod` corpus
  runs to its `.test.json` values (CLI run mode). `call_indirect` + host imports are the remaining
  execution slices (`roadmap.md`).
- **Text toolchain (in progress).** `sexpr.zig` + `wat.zig` assemble WAT text → wasm binary
  (funcs/exports, folded+flat instrs, control flow, memory/data). Next: `wast.zig`, the `.wast` script
  runner, to run the spec testsuite as the conformance gate (`text-toolchain.md`, `testing.md`).
