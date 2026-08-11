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
work is sub-µs to tens-of-ms). *(Cold-start number corrected 2026-07-16: a **real ~46 KB guest**
decode+instantiates in **~4.4 ms**, not the ~0.8 µs the 70-byte toy shows — still ~25× under Deno, so
the thesis holds; `testing.md`.)* Steady-state interpreter throughput is ~264 Mops/s — a JIT wins that
regime, so the win is exactly where the vision predicted: **short-lived / native-FFI programs (wasmtk's
compiler-test outputs), not sustained hot loops.** Option A stays; A→B waits for a real compute-bound
workload. First datapoint on one dev box, not a tuned benchmark.

### 🎯 The consumer's regime, established 2026-08-11 — and what it deprioritises

**wazmrt and `wasmrt` are in competition for the runtime slot in wasmtk and rsxtk** (owner). Surveying
the consumers settled which regime actually pays:

- **rsxtk is a DEVELOPMENT environment — many short runs, not few long ones**, and the owner has
  **dropped `.cwasm` as its primary path** (machine-specific, not a cross-platform standard) in favour
  of plain **`.wasm`**, with `.cwasm` left as an end-user option. So wasmtime pays a **full Cranelift
  compile on every run** — and rsxtk sets `OptLevel::Speed`, its slowest-starting configuration.
  *(An earlier read of rsxtk's AOT cache had concluded the opposite; that path is no longer the default,
  so the cold-start thesis holds for this consumer.)*
- **Therefore `decode → validate → instantiate` is promoted to a first-class metric** — measured and
  optimized alongside steady-state Mops/s, not instead of it.
  ⚠️ **OWNER CORRECTION 2026-08-11: an earlier draft deprioritised the A → A.5 → B perf ladder. That is
  OVERRULED — neither execution optimization nor `.wat` support is descoped in wazmrt.** The dev-loop
  observation justifies *promoting* startup; it does not justify demoting throughput, and the earlier
  text overreached. **Reconciliation: the Track 2a size gate is the referee — every optimization pays
  its way in measured bytes-per-percent, and none is rejected on a prior assumption about which regime
  matters.** A.5 is the first lever because it is largely a decode-time transformation, so its size cost
  is small and measurable.

⚠️ **Benchmark fairness rule (binding).** Any "faster than wasmtime" measurement must include wasmtime
configured to **start fast** (`OptLevel::None`, or the Winch baseline compiler), not only
`OptLevel::Speed`. Beating a runtime in its slowest-starting configuration proves nothing, and shipping
that number would repeat the falsified-payoff error one section below — a claim that dies the moment
someone checks. **The defensible claim: *"wasmtime-class module compatibility, at a fraction of the
footprint, faster on anything not precompiled."*** Unqualified "faster than wasmtime" dies to one
hot-loop benchmark.

**The structural asymmetry, named rather than wished away:** for **wasmtk** (Deno/TS) both runtimes sit
behind FFI, so it is a fair fight and wazmrt's embed footprint wins it (**222 KB vs 554 KB**, measured
2026-08-11). For **rsxtk** (Rust), `wasmrt` is a **native crate** — zero FFI, zero `unsafe`, no DLL to
ship — an advantage wazmrt cannot erase from behind a C boundary. Sizes and the full program:
`roadmap.md` → CURRENT PROGRAM.

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

⚠️⚠️ **CORRECTED 2026-08-11 — "the remaining work is WASI + the benchmark" is FALSE, and the same class
of error as the falsified payoff below: a claim about someone else's code, made without reading it.**
A survey of wasmtk's actual source found:

- **wasmtk executes ALL wasm through `WebAssembly.instantiate` — V8's built-in engine.** Hits in
  `src/utils.ts` (×2), `src/wast.ts`, and — the load-bearing one — **`src/bindgen.ts`, which *generates*
  `WebAssembly.instantiate` into every emitted `.bindings.ts`**.
- **There is no native-runtime FFI path in wasmtk.** The single `Deno.dlopen` in the whole project is in
  `main.ts` and calls **`kernel32.SetConsoleOutputCP`** to fix Windows console encoding. Nothing else.
- **wazmrt appears nowhere in wasmtk's source or its `cmem/`.**

**What IS true:** the *mechanism* is proven — `wazmrt.dll` + `Deno.dlopen` + a real call works, in
wazmrt's own `examples/deno_ffi.mjs`. **What is NOT true:** that anything on the wasmtk side uses it.
**So "which runtime gets into wasmtk" is a competition for a slot that does not exist yet** — neither
wazmrt nor wasmrt is in wasmtk; V8 is.

**The real blocker is wasmtk-side work, and it is bigger than a binding:** replacing
`WebAssembly.instantiate` in `utils.ts`/`wast.ts` *and* in the bindgen **codegen**, turning every host
import into a `Deno.UnsafeCallback` (a JS↔native hop per call — note that this partly re-introduces the
very boundary cost this vision claims to eliminate, and must be measured, not assumed), and reading
guest memory through `Deno.UnsafePointerView` instead of `instance.exports.memory.buffer`. The owner
owns both projects, so this is a scheduling decision — but it is **wasmtk's** scope, not wazmrt's, and
no amount of wazmrt-side ABI work substitutes for it.

**Cheapest real foothold, do this first:** `wasmtk/tests/dync_cross_runtime_tests.ts` already runs
wasmtk's output through external runtimes for portability — `RUNTIMES = ["wasmtime", "wasmer",
"wazero"]`. **wazmrt is not in that list.** Adding it costs almost nothing and puts wazmrt in front of
wasmtk's own corpus as a peer of the runtimes it means to replace. wazmrt already runs **all 400
runnable files of the wasmtk WASI corpus** (`testing.md`), so the parity claim is evidence-backed
*today* — it simply is not wired into wasmtk's gates.

## Candidate direction — wazmrt as the universalWasmLoader native backend (speculative, 2026-07-02)

**Not decided; gated on wazmrt proving useful in wasmtk first.** The idea: replace the per-platform
engine patchwork the `universalWasmLoader-*` ports use today (wasmtime for C/Rust/Py/.NET, wazero for
Go, Chicory for JVM, host `WebAssembly` for web) with **one native wazmrt behind each language's FFI**.

Benefits:

- **Consistency** — one runtime, one WASI, one bug list across every native port (the actual point of a
  "universal" loader).
- **No heavy dependency** — wasmtime is megabytes + a Rust toolchain; wazmrt is a few hundred KB,
  dependency-free, and self-owned.
- ~~**Low-friction swap** — wasmtime also implements wasm-c-api, so ports already on its C API are
  close to drop-in against wazmrt's C ABI (a payoff of the wasm-c-api decision).~~
  ⚠️⚠️ **FALSIFIED 2026-08-10 (owner: "somehow that intent slipped"). This payoff never existed, and it
  is where the wasm-c-api decision drifted from the actual goal.**

  The claim assumed the loaders were "already on wasmtime's C API", meaning wasm-c-api. They are not.
  wasmtime ships **two** C surfaces: the standard `wasm.h`, and its own richer `wasmtime.h`. A survey of
  the real loader source (`universalWasmLoader-c/universal_wasm_loader.h`, recorded in wasmrt's
  `cmem/loaders.md`) found it uses wasmtime's **`wasmtime_*` store/context/linker/typed-val model — NOT
  the wasm-c-api instance/func model.** "Close to drop-in" was a hypothesis about someone else's code
  that nobody had read.

  Worse than unhelpful: **wasm-c-api structurally cannot serve the loaders' core need.** Its host-func
  callback receives **no handle to the caller's memory**, and essentially every loader host import must
  read guest memory inside a callback. wasmrt's `loaders.md` calls this "the load-bearing gap over
  wazmrt's shape"; the port closed it at T8 by adopting wasmtime's **caller-based** callback model
  (`wasmrt_caller_*`).

  **What it cost:** `src/wasm_c_api.zig` — 319 declared functions, 174 exports, this project's largest
  file and, by its own design-decisions entry, "the one file that hands raw ownership across a C
  boundary — memory-safety-critical". Audit findings **#20** (180 undefined symbols), **#21** (double
  free, use-after-free, uninitialised refcount, leak) and **#22** (two more, from the lifecycle fuzz)
  were *all* in it. The Rust port replaced the whole surface with ~74 functions and value handles.

  **In fairness, what the decision DID deliver:** a genuinely standard ABI, third-party interop with any
  wasm-c-api consumer, and the proven Deno-FFI path below. Those are real. The error was narrower and
  specific — claiming a payoff *for the intended consumer* without reading that consumer's code.

  🎓 **The lesson (now in `wasmrt/cmem/best-practices.md`): a stated benefit is a hypothesis about
  someone ELSE's code — go read theirs.** The universal loaders were always meant to be the layer that
  standardises imports across languages; the runtime beneath them only ever had to serve **them**.

  ✅ **RESOLVED 2026-08-11 — the ABI was replaced, not merely annotated.** `src/wasm_c_api.zig` and
  `third_party/wasm-c-api/` are deleted; the C ABI is now the native `include/wazmrt.h` (ABI 2, 77
  functions) whose shape came from the *actual* loader survey, and which does the two things
  wasm-c-api could not: host callbacks reach the caller's memory, and `.wat` is accepted directly.
  **wazmrt is 100% self-owned as a result** — nothing third-party ships, which is the second half of
  "dependency-free, and self-owned" above. ⚠️ It also cost size (DLL 227 KB → 845 KB, because WAT +
  WASI + `Io` now live in the embed artifact), which is recorded rather than smoothed over. Full
  account: `roadmap.md` → TRACK 1 IS COMPLETE.
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
