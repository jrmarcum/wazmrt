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
│   ├── main.zig           # CLI front-end (decode a .wasm, print a section summary)
│   ├── types.zig          # Format constants, SectionId, DecodeError set
│   ├── Reader.zig         # Zero-copy cursor: bounds-checked reads + LEB128 (file-as-struct)
│   ├── Module.zig         # Decoded module: header validate + section index (file-as-struct)
│   ├── c_api.zig          # extern "C" ABI surface (opaque handle; smp_allocator, no libc)
│   └── wasm_entry.zig     # Freestanding wasm32 export surface (wasm_allocator)
├── third_party/
│   └── LICENSES.md        # Compliance ledger + adoption checklist + SPDX inventory
├── LICENSE-MIT · LICENSE-APACHE · NOTICE
└── README.md              # Public, user-facing doc
```

## Key source files

| File | Role |
| --- | --- |
| `src/Module.zig` | The decoded-module type + `decode()`. Today: header validation + top-level section index. Future decode/validate/instantiate/execute hang off this type. |
| `src/Reader.zig` | The fast, allocation-free core: bounds-checked byte reads, fixed-LE u32, unsigned LEB128. Everything decoder-side builds on it. |
| `src/c_api.zig` | The stable C ABI (`wazmrt_module_decode`/`_section_count`/`_free`, `wazmrt_abi_version`, `wazmrt_version_string`). Opaque `void*` handle so internals can evolve. |
| `src/root.zig` | What library consumers import (`@import("wazmrt")`). Re-exports `types`, `Reader`, `Module`, `decode`, `version`, `abi_version`. |

## Build targets (see architecture.md)

- `zig build`      → native CLI `wazmrt` + C-ABI static lib `wazmrt` + installs `wazmrt.h`
- `zig build test` → runs the unit tests (7 passing as of 2026-07-02)
- `zig build wasm` → builds the runtime itself as a freestanding `wasm32` module
- `zig build run -- <module.wasm>` → decode-and-summarize a wasm file

## Mental model

- **Zero-copy decode.** `Reader` borrows slices of the input; `Module` stores only section `{id,
  offset, size}` extents, not eager copies — so the source bytes can be freed after decode.
- **Libc-free core.** `root.zig` and its deps pull in no libc, so the same code targets native *and*
  `wasm32-freestanding`. The C-ABI lib uses `std.heap.smp_allocator` (not `c_allocator`). See
  `design-decisions.md` for why (smaller binary + no MSVC requirement on Windows).
- **First vertical slice only.** Today the pipeline validates the header (`\0asm`, version 1) and
  indexes sections. Validation, instantiation, and execution are the next increments (`roadmap.md`).
