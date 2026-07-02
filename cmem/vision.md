# Vision

**A blazingly-fast, smallest-binary WebAssembly runtime that can itself be compiled to wasm and
imported into any programming language.**

## The two axes

1. **Fast + tiny as a native runtime.** Beat or match the small-footprint interpreters (wasm3, WAMR
   "fast interpreter") on binary size and startup, while staying correct. Zig + `ReleaseSmall`, a
   libc-free core, and zero-copy decoding are the levers.
2. **Itself compilable to wasm.** The runtime builds for `wasm32-freestanding` (`zig build wasm`), so
   wazmrt can run *inside* another wasm host — a runtime-in-a-runtime — which is what makes the
   universal-loader story work uniformly across languages.

## Distribution — the `universalWasmLoader-*` family

wazmrt is meant to be embedded from any language via a matching loader repo:

`https://github.com/jrmarcum/universalWasmLoader-<lang>` for
`<lang> ∈ { jvm, c, go, dotnet, dart, rs, py, v, zig, js }`.

The **C ABI** (`include/wazmrt.h`) is the universal contract each loader binds to:

- Native/FFI hosts (c, rs, go, py, dart-native, v, zig, jvm, dotnet) link the C-ABI **static library**
  and call `wazmrt_module_decode` / `_section_count` / `_free`, checking `wazmrt_abi_version()`.
- Web/wasm hosts (js, dart-web) can instead load the **freestanding wasm** build and call its exports.

Stability rule: the exported C symbols and `wazmrt_status` values are contractual; the handle is
opaque (`void*`) so internal layout can change without breaking any loader. Bump `abi_version` on any
breaking change.

## Guiding decisions

- **Study the field, adopt selectively, attribute always.** Nine reference runtimes span MIT, ISC, and
  Apache-2.0 (± LLVM-exception). Each reuse is gated by a benefit-vs-drawback evaluation and a
  compliance ledger entry (`reference-projects.md`, `third_party/LICENSES.md`).
- **Dual `MIT OR Apache-2.0`** so every downstream consumer, in any language, picks the license that
  fits their project — and so we can incorporate from all the permissive reference runtimes
  (`licensing.md`).
- **Libc-free by default** — smallest binary, no toolchain requirement for embedders, and the same
  allocator strategy works native and on freestanding wasm.

## Status (2026-07-02)

Project inception. Licensing baseline (dual license + compliance scaffold) committed; first vertical
slice of the runtime (header validation + section indexing) building and tested; C-ABI and
freestanding-wasm build targets in place. No reference-project code incorporated yet. See `roadmap.md`.
