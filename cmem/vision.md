# Vision

**A blazingly-fast, smallest-binary WebAssembly runtime that can itself be compiled to wasm and
imported into any programming language.**

## The two axes

1. **Fast + tiny as a native runtime.** On **size**, the peers are the small interpreters (wasm3, WAMR
   "fast interpreter") — not the JIT/AOT runtimes, which are a different weight class (their bulk is a
   Cranelift/LLVM backend). Zig + `ReleaseSmall`, a libc-free core, and zero-copy decoding are the size
   levers. On **speed**, the concrete target is beating wasmtk's Deno/V8 execution — see the
   Performance target section below (a different goal from raw JIT throughput).
2. **Itself compilable to wasm.** The runtime builds for `wasm32-freestanding` (`zig build wasm`), so
   wazmrt can run *inside* another wasm host — a runtime-in-a-runtime — which is what makes the
   universal-loader story work uniformly across languages.

## Performance target (owner, 2026-07-02)

The concrete speed goal is **not** "beat a Cranelift JIT." It is:

- **Minimum goal: run wasm faster than `wasmtk` currently does** — and wasmtk executes its wasm through
  **Deno → V8's wasm engine** (Liftoff baseline JIT → TurboFan optimizing JIT).
- **Stretch goal: match wasmer / wasmtime** (native JITs).

**Key insight — you don't beat V8 by out-executing it; you beat what it costs *around* execution.**
Per run, wasmtk pays: Deno start + V8 init + wasm JIT-compile + **JS↔wasm marshalling** (bindgen) +
execution. Three ways wazmrt wins, two of them structural:

1. **No process / JIT-warmup tax.** Native wazmrt starts in ~1 ms and compiles nothing (just decode);
   Deno+V8+Liftoff is tens-to->100 ms *every run*. For short-lived programs (all compiler-test outputs),
   a native interpreter wins wall-clock decisively despite slower per-instruction speed.
2. **No JS↔wasm boundary.** wazmrt touches linear memory directly — zero marshalling. If bindgen
   marshalling is the bottleneck (it often is for wasmtk), we win without beating V8's raw execution.
3. **Raw hot-loop throughput** — the *only* regime where a pure interpreter loses to TurboFan.

**Hard constraint:** this win exists only for the **native** build. Running wazmrt *inside* wasm-on-V8
(the compile-to-wasm / loader mode) is strictly slower than V8 running that wasm directly — an
interpreter interpreting. Compile-to-wasm mode is for **portability/embedding, not speed**; the
speed-vs-Deno win requires the native runtime. Don't conflate the two deployment targets.

**Feasibility:** minimum goal is highly achievable *by architecture* (startup + boundary elimination),
likely already true for short programs. Secondary goal (compute-bound parity with native JITs) is hard
for a pure interpreter — **Option B (the wasmi-style register machine)** is the first lever (the IR is a
clean seam for it); full JIT parity would require our own codegen, which trades against the
smallest-binary + compiles-to-wasm goals. **Decide Option A→B (or beyond) with benchmark data, not
now.** The measurement: native wazmrt vs Deno/V8 on wasmtk's own outputs, timing **cold-start
wall-clock and steady-state throughput separately** so we know which regime wasmtk lives in. See the
`design-decisions.md` interpreter-architecture entry and `roadmap.md` size/speed-baseline item.

**First measurement (2026-07-14) — thesis confirmed.** `zig build bench` + a cross-process run (see
`testing.md`): native wazmrt beats Deno/V8 on **cold-start wall-clock — 2.4× on a trivial call, 1.5× on
`sum(1e6)`** (Deno pays ~110 ms of V8 init + wasm JIT-compile + JS marshalling every run; wazmrt's own
work is sub-µs to tens-of-ms). Steady-state interpreter throughput is ~264 Mops/s — a JIT wins that
regime, so the win is exactly where the vision predicted: **short-lived / native-FFI programs (wasmtk's
compiler-test outputs), not sustained hot loops.** Option A stays; A→B waits for a real compute-bound
workload. First datapoint on one dev box, not a tuned benchmark.

## Integration goal — wazmrt as wasmtk's wasm execution backend (owner, 2026-07-02)

The concrete productization target: **wasmtk runs its wasm through native wazmrt instead of Deno/V8**,
as a speed boost for wasmtk and its users. wasmtk is the ideal first real consumer (it already produces
the wasm and the test corpora).

**Critical routing nuance:** the speedup only materializes if wasmtk calls the **native** wazmrt —
i.e. **Deno FFI → the C-ABI shared/static library** (`dlopen` the native runtime, per the Performance
target's native-build constraint). It must **not** go through `universalWasmLoader-js`, which runs
wazmrt-as-wasm on V8 (interpreter-on-JIT — slower than V8 running the wasm directly). So the wasmtk
integration path is a **native FFI binding**, not the wasm/JS loader.

Prerequisites before this is possible: execution complete (incl. `call_indirect`), **host imports +
WASI** (wasmtk's `wasi/` corpus needs it), and the C ABI grown to expose instantiate + call. Validate
with the size/speed benchmark first (`roadmap.md`). "We'll see if it's achieved as wazmrt develops."

**The native-FFI path is now proven end-to-end (2026-07-14).** `zig build dll` builds the C ABI as a
libc-free shared library (`wazmrt.dll`), and `examples/deno_ffi.mjs` (run by `zig build ffi-demo`) has
**Deno `Deno.dlopen` it and drive the standard wasm-c-api** — decode → instantiate → call an exported
function — with no wasmtime and no JS-loader in the path. This is exactly the "Deno FFI → the C-ABI
shared library" routing above; the remaining work for the wasmtk speedup is WASI + the benchmark, not
the binding mechanism.

## Candidate direction — wazmrt as the universalWasmLoader native backend (speculative, 2026-07-02)

**Not decided; gated on wazmrt proving useful in wasmtk first.** The idea: replace the per-platform
engine patchwork the `universalWasmLoader-*` ports use today (wasmtime for C/Rust/Py/.NET, wazero for
Go, Chicory for JVM, host `WebAssembly` for web) with **one native wazmrt behind each language's FFI**.

Benefits:

- **Consistency** — one runtime, one WASI, one bug list across every native port (the actual point of a
  "universal" loader).
- **No heavy dependency** — wasmtime is megabytes + a Rust toolchain; wazmrt is a few hundred KB,
  dependency-free, and self-owned.
- **Low-friction swap** — wasmtime also implements wasm-c-api, so ports already on its C API are close
  to drop-in against wazmrt's C ABI (a payoff of the wasm-c-api decision).
- **Licensing freedom** — a structural win, not a preference. wazmrt is **`MIT OR Apache-2.0`** and
  100% team-owned; wasmtime is `Apache-2.0 WITH LLVM-exception`. Dropping the wasmtime dependency means
  a loader carries **no external-runtime license/NOTICE to propagate** and can license itself freely
  (e.g. plain MIT). The whole stack (engine + loaders + producer) stays under one permissive,
  self-chosen license.
- **A self-consistent, ownable stack:** wazmrt = engine, `universalWasmLoader-*` = FFI bindings,
  wasmtk = producer + first consumer.

Scoping caveats (so this doesn't bite):

- **Browsers can't FFI native.** `-js` (real browser) and `-dart-web` keep the host `WebAssembly`
  engine; wazmrt replaces the **native/server tier** only (server-side Deno/Node *can* FFI).
- **Default lightweight backend, not a hard replacement.** wazmrt (interpreter) wins on consistency,
  size, startup, licensing, and short programs; for **heavy compute it will need wasmtime's JIT** for
  process speed (owner-agreed). So offer wazmrt as the default zero-dependency backend **with wasmtime
  kept as an optional high-performance backend** — not rip-and-replace.

Sequencing: prove in wasmtk (native FFI) → earn trust via spec-testsuite conformance → propagate to the
native loader ports. Prerequisites as in "Integration goal" (execution + `call_indirect`, host
imports/WASI, C ABI instantiate+call).

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

The runtime **decodes, validates, and executes** wasm (int/float/memory), and a native **text
toolchain** (WAT assembler + WAST runner) runs the **official spec testsuite** (thousands of assertions
pass — see `testing.md`). C-ABI + freestanding-wasm build targets in place. Still 100% original runtime
code (only `wasm.h` vendored). Not yet done: `call_indirect`/host imports/WASI, multi-value, the
size/speed baseline vs Deno/V8. See `roadmap.md`.
