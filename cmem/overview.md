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
│   ├── main.zig           # CLI: summarize a .wasm, or run `wazmrt <file> <export> [args…]`; pin/keygen/sign subcommands; -h/--help + -v/--version
│   ├── types.zig          # Format constants, SectionId, DecodeError set
│   ├── Reader.zig         # Zero-copy cursor: bounds-checked reads + LEB128/SLEB (file-as-struct)
│   ├── Module.zig         # Decoded module: sections + resolved imports/exports + code (file-as-struct)
│   ├── opcode.zig         # Shared opcode table (Op/Imm/Instr) + byte-code → IR decodeBody
│   ├── validate.zig       # Spec type-checking validator over the IR (value + control-frame stacks)
│   ├── interp.zig         # Instance + switch interpreter over the IR (u64 slots, label stack)
│   ├── sexpr.zig          # S-expression lexer/parser for .wat/.wast (text toolchain front-end)
│   ├── wat.zig            # WAT text → wasm binary assembler (reuses opcode.zig in reverse)
│   ├── wast.zig           # WAST script runner (assert_return/assert_trap/invoke) — runs the spec testsuite
│   ├── capi.zig           # The native wazmrt.h C ABI, ABI 2 (smp_allocator, no libc)
│   ├── features.zig       # Per-proposal gating: which proposals a module may use
│   ├── wasm_entry.zig     # Freestanding wasm32 export surface (wasm_allocator)
│   ├── pin.zig            # Pin verification (Phase 5): SHA-256, content-addressed DB, decide() matrix
│   └── sign.zig           # Ed25519 signature verify (authenticity): "signature" custom section + embedded root key
├── tests/
│   └── c_smoke.c          # C smoke test exercising the wasm-c-api surface (zig cc)
├── third_party/
│   └── LICENSES.md        # Compliance ledger (EMPTY — nothing vendored) + adoption checklist
├── LICENSE-MIT · LICENSE-APACHE · NOTICE
└── README.md              # Public, user-facing doc
```

## Key source files

The pipeline, in order: **decode → validate → execute**, with a text front-end (**assemble**).

| File | Role |
| --- | --- |
| `src/Reader.zig` | Allocation-free cursor: bounds-checked reads, fixed-LE u32, **spec-correct** unsigned + signed LEB (rejects over-long / integer-too-large), `skipLeb`, float-bit reads. The decoder core. |
| `src/Module.zig` | The decoded module + `decode()`: header, all core sections, resolved import/export extern types, function bodies, globals/memories/data. Validates custom-section names + data-count consistency; rejects reserved flag/valtype bytes. Arena-owned. |
| `src/opcode.zig` | The **shared instruction authority** — `Op` table, `Imm`/`Instr` IR, `decodeBody`. Used by validate, the interpreter, *and* the assembler (in reverse). |
| `src/validate.zig` | Spec type-checking validator over the IR (value + control-frame stacks) + module-level checks: global-init/element const-exprs, `select`/`if`/`call_indirect`/alignment/memory-presence. |
| `src/interp.zig` | `Instance` + `Store` + the switch interpreter (untyped `u64` slots, label stack). **`Store` owns the instances a linked group shares**, so a `funcref` (`(slot+1)<<32 | func_index`) and a tag identity mean the same thing to all of them; imported globals/memories/tables are BORROWED cells; instantiation takes a destination pointer (`instantiate`/`instantiateWithImports`) because an instance’s address is part of its identity — see `design-decisions.md`. Runs int/float/memory (**multi-memory** + **complete SIMD (v128)**: two u64 slots per v128, the **entire `0xFD` set** incl. relaxed ops via `@Vector` — `memories: []*Memory`, load/store/`memory.*` select by index), **threads/atomics** (the whole `0xFE` family — atomic load/store/rmw/cmpxchg/fence/wait/notify, single-threaded semantics, `shared` memories), **memory64** (i64 addresses via `popAddr`, overflow-safe u64 bounds, i64 `memory.size`/`grow`; the address type is per-memory), `call_indirect` over multiple tables, reference types + table ops, element segments (incl. GC constant expressions in global/element inits), **imported functions** (`HostFunc`), **full WasmGC** (i31/struct/array heap, casts, subtyping), bulk memory/table ops, and **exception handling** — both the exnref form (`throw`/`throw_ref`/`try_table`, unwinding via `error.UncaughtException` + call-site catch) **and the legacy `try`/`catch`/`catch_all`/`rethrow`** form (inline handlers, Phase 6.3); carries the **trap backtrace** (`errdefer`-recorded frames). |
| `src/sexpr.zig` / `src/wat.zig` / `src/wast.zig` | Text toolchain: S-expression parser → WAT→wasm-binary assembler (`wat.zig` maps names→`Op` via `stringToEnum`) → WAST script runner (`wast.zig`, drives an `Instance`, compares — **runs the official spec testsuite**). |
| `src/wasi.zig` | **WASI preview 1** as native host imports: stdio/args/environ/clocks/`poll_oneoff`/random/`proc_exit` + the **sandboxed filesystem** (`--dir`/read-only `--ro-dir` preopens, host-fd table, and the security-critical handle-stack path resolver `walkFull` — follows symlinks, escape impossible by construction; see `security-model.md`). Read-only-ness rides the rights model: `path_open` only narrows an fd's rights against its parent, so a `--ro-dir`'s no-write mask propagates to the whole subtree. |
| `src/capi.zig` | The **native `wazmrt.h` C ABI (ABI 2)** — all 77 declared functions defined, link-gated by `tests/wazmrt_abi_symbols.c`. Engine/store/linker, caller-based host callbacks, `.wat` input, WASI, resource ceilings, proposal gating. **Value handles instead of refcounted objects**, which is what removes the `#20`/`#21`/`#22` bug class rather than re-policing it. Replaced `src/wasm_c_api.zig` (deleted 2026-08-11). |
| `src/features.zig` | Per-proposal gating. Maps every `opcode.Op` to the proposal it belongs to and refuses a module that uses a disabled one, inspecting **types as well as code**. ⚠️ Its comptime `Op`-count assertion is load-bearing: an unclassified new opcode would silently pass every gate. |
| `src/root.zig` | Library surface (`@import("wazmrt")`). Re-exports `types`/`Reader`/`Module`/`opcode`/`validate`/`interp`/`Instance`/`sexpr`/`wat`/`wast`/`wasi`/`pin`/`sign`/`decode`/`version`/`abi_version`. |

## Build targets (see architecture.md)

- `zig build`      → native CLI `wazmrt` + C-ABI static lib `wazmrt` + installs **`include/wazmrt.h`, and nothing else** (2026-08-11: nothing third-party ships, so no licence has to travel with it)
- `zig build test` → runs the unit tests (**565 as of 2026-08-13** — 510 at 2026-08-11, the rest from R1/R2 regression tests; ZERO skips from an NTFS cwd, 4 skipped from this repo’s own `D:` cwd because exFAT has no symlinks; green under Debug AND ReleaseSafe; see `testing.md`)
- `zig build capi-smoke` → compiles + runs `tests/capi_smoke.c` against the C ABI, with the generated link-time symbol gate (was `c-smoke` before 2026-08-11)
- `zig build size -Doptimize=ReleaseSmall` → fails the build if a shipped artifact grew past `tools/size-ceilings.txt`. **Live 2026-08-13: exe 939,008 / static lib 999,296 / dll 864,768.** ⚠️ Nothing invokes this automatically and the ceilings drifted 22–25 KB unnoticed between 2026-08-11 and 2026-08-13 — **run it before any commit touching `src/`**, and measure the static lib from a PLAIN `zig build` (`zig build dll` overwrites `wazmrt.lib` with the DLL import library)
- `zig build -Droot-key=<64 hex>` → embeds the Ed25519 signature trust anchor (empty ⇒ verification inert)
- `zig build wasi-gate` → compiles real `wasm32-wasi` guests (Zig + C via `zig cc`; Rust with `-Drust-gate=true`) and runs them through wazmrt asserting stdout
- `zig build wasm` → builds the runtime itself as a freestanding `wasm32` module
- `zig build run -- <file.wasm> [export args…]` → summarize a module, or invoke an export and print results

## 📦 Distribution manifest — exactly which files a user needs (2026-08-10)

**Measured on a clean `PATH`**, not read off `build.zig`: the binary was copied to an empty directory
and run with `PATH=C:\Windows\system32;C:\Windows`. That is the only way to tell a real dependency from
one the dev box happens to satisfy.

| you are shipping | files a user needs | do NOT ship |
| --- | --- | --- |
| **the CLI** | `zig-out/bin/wazmrt.exe` — **one file** | `wazmrt.pdb` |
| **the C ABI, dynamic** | `zig-out/bin/wazmrt.dll` + `include/wazmrt.h` | `wazmrt.pdb` |
| **the C ABI, static** | `zig-out/lib/wazmrt.lib` + `include/wazmrt.h` | — |
| **the wasm build** | `zig-out/bin/wazmrt.wasm` | — |

✅ **wazmrt is standalone by construction.** `wazmrt.exe` and `wazmrt.dll` import **only `ntdll` and
`KERNEL32`** — no libc, no toolchain runtime, nothing from the Zig install. That falls out of the
libc-free design, and it is worth re-checking rather than assuming after any build-system change.

⚠️ **`wazmrt.pdb` is 3.6 MB of debug symbols and the largest file in `zig-out/bin`** — easy to sweep up
with a wildcard copy, and it carries source paths and symbol names.

⚡ **CORRECTED 2026-08-11 — `zig-out/include/` is ONE file again.** For one day it was four: the
vendored `wasm.h` plus `LICENSE.wasm-c-api` and `NOTICE`, because that header was **Apache-2.0** and
§4(a) obliges us to hand recipients the licence *when we distribute it*. Deleting the vendored header
deleted the obligation with it — **wazmrt vendors nothing, so nothing third-party ships and no licence
has to travel with the artifact.**

⚠️ **Keep the rule even though the case is gone** (`licensing.md`): a compliant repository is not a
compliant distribution. The next vendored file will need its licence in the OUTPUT tree, not just the
source tree, and named for the component it covers.

⚠️ **A compliant repository is not a compliant distribution.** Whoever copies `zig-out/include` never
sees `third_party/`, so the licence has to be in the output. The file is named for the header it
covers: wazmrt's own code is `MIT OR Apache-2.0`, the vendored header is **Apache-2.0 only**, and
conflating the two is how attribution quietly goes missing.

**How to re-verify** (before any release, per binary):

```
objdump -p zig-out/bin/wazmrt.exe | grep "DLL Name"
```

Anything that is not `ntdll`, `KERNEL32`, `api-ms-win-*` or `bcrypt*` is a file you are also shipping,
whether you meant to or not. Then copy the binary somewhere empty and run it with `PATH` cut back to
the system directories. **"It runs here" is not evidence that it ships** — the Rust port silently
needed a *toolchain* DLL (`libunwind.dll`) while every dev-box test passed, and died with a bare
**exit 127** on a clean machine.

## Mental model

- **Zero-copy decode.** `Reader` borrows slices of the input; `Module` stores only section `{id,
  offset, size}` extents, not eager copies — so the source bytes can be freed after decode.
- **Libc-free core.** `root.zig` and its deps pull in no libc, so the same code targets native *and*
  `wasm32-freestanding`. The C-ABI lib uses `std.heap.smp_allocator` (not `c_allocator`). See
  `design-decisions.md` for why (smaller binary + no MSVC requirement on Windows).
- **Decode + validate + execute all work.** The pipeline decodes all core sections → the `opcode.zig`
  IR, type-checks it (`validate.zig`), and a switch interpreter (`interp.zig`) runs it — integer/float
  arithmetic, control flow, `call`/`call_indirect` (multi-table), **linear memory**, globals, reference
  types, and the reference-type table ops end-to-end. The whole `module/wasm_mod` corpus runs to its
  `.test.json` values (CLI run mode). **Imported functions + `register`/module-linking work** (a module
  registry; cross-module calls run in the exporting instance, `spectest` host funcs are native no-ops).
  The **validator rejects invalid modules properly** (global init const-exprs, element segments,
  typed/untyped `select`, `if`-without-`else`, alignment ≤ natural, memory presence) and the **decoder
  rejects malformed binaries** (spec-correct LEB128 bounds, custom-section names, data-count
  consistency, reserved flag/valtype bytes). Imported tables/memories, bulk table/memory ops, the
  **function-references** proposal, **full WasmGC** (i31/struct/array, casts, subtyping, concrete
  refs), and **exception handling** (both the exnref `throw`/`throw_ref`/`try_table` form and the legacy
  `try`/`catch`/`catch_all`/`rethrow` form), **multi-memory** (decode+execute AND text assembly),
  **threads/atomics** (the whole `0xFE` family + `shared` memories), **GC constant expressions**, and
  **memory64** (i64 addresses, per-memory index type, i64 size/grow — decode+validate+execute+assemble)
  are all done. **Phases 1–8 complete** — WASI, CLI ergonomics + conformance, pin verification, exception
  handling, **multi-memory (Phase 7)**, **complete SIMD/v128 (Phase 8)**, and the **Ed25519 signature**
  path (`keygen`/`sign`/`--root-key`, deny-unsigned-when-armed). **The runtime runs the official spec
  testsuite** (59.7k assertions passing) plus the threads `atomic.wast` suite (302/0) and the memory64 dir
  (100% on address64/align64/memory_trap64/memory_grow64/memory_redundancy64), and assembles ~490 of a
  real-world `.wat` corpus. **Every wasm proposal wazmrt targets is now implemented** (memory64, completed
  2026-07-27, was the last); what remains is one upstream Zig limitation and out-of-scope `.wast`
  module-linking harness commands — see `known-issues.md` and `roadmap.md`.
- **Text toolchain (working).** `sexpr.zig` + `wat.zig` (WAT→wasm binary) + `wast.zig` (WAST script
  runner) — `wazmrt <file.wast>` **runs the official spec testsuite** (thousands of assertions pass; see
  `testing.md`). The runner executes `assert_return`/`assert_trap`/`assert_exhaustion` *and*
  `assert_invalid`/`assert_malformed` (negative conformance), with `assert_trap` gated on a genuine
  runtime trap, and handles `(register "name")` for cross-module imports. The assembler covers control
  flow + multi-value/type-index block types, `call_indirect` + multi-table, element segments (func-index
  + const-expr forms, all 8 flag variants, const-expr offsets), globals (imported + extended-const),
  **imported functions**, reference types + reference-type table ops, GC composite types, bulk ops, and
  **exception handling** (tag section + `throw`/`throw_ref`/`try_table`+catch, Phase 6.1).
