# Design Decisions & Invariants

Load-bearing choices and gotchas that must not be silently reverted. Dated; newest context wins.

## Invariants

- **MEMORY SAFETY IS A PROJECT GOAL, AND `wasm_c_api.zig` IS WHERE IT IS AT RISK (owner, 2026-07-15:
  "we do not ever want to introduce exploitable holes").** It is the only file that hands raw ownership
  across a C boundary, so a mistake there is a *heap-corruption primitive*, not a wrong answer. Six
  rules, each of which has already been violated once and cost a real bug:
  1. **Every `Ref` free goes through `refDelete`/`destroyRef`.** Never `alloc.destroy` a `Ref` directly:
     it skips the refcount (→ double free) and the object's own cleanup (→ leaked functype/host_global,
     unrun finalizer). `wasm_extern_vec_delete` did exactly this.
  2. **Nothing aliases a `Ref` without taking a handle.** A copy retains, or duplicates an export
     handle; it never just repeats the pointer. `wasm_extern_vec_copy` did, making
     `copy; delete; delete` — which the header invites — a double free.
  3. **A `Ref` that names an `Instance` owns a handle on it** (`refRetainInstance`). It dereferences it
     on every call, so without this, `exports(); instance_delete(); func_call()` — an *ordinary* embedder
     sequence, no misuse — read freed memory.
  4. **Construct ref-able objects with a whole-struct literal.** `alloc.create` returns uninitialized
     memory, and field-by-field assignment leaves `hdr` — hence `rc` — garbage, i.e. freeable at any
     moment. `wasm_instance_new` and `wasm_trap_new` both did this.
  5. **An `Instance` owns a handle on its `Module`.** `interp.Instance` stores `&m.inner` and
     dereferences it on every call, but the wasm-c-api contract lets the embedder delete the module
     right after `wasm_instance_new`. So the instance retains the module and releases it on delete;
     without it, delete-module-then-call was a segfault (found 2026-07-16 while building the #22 fuzz).
  6. **Every `wasm_X_delete` for a refcounted type calls `release` first** — do not free unconditionally.
     `wasm_X_copy` bumps the count, so an unconditional free double-frees the moment an object is copied.
     `wasm_trap_delete` shipped in #20 without this (it predated refcounting and was never updated); the
     #22 fuzzer found it on seed 1. Audit all eight (`module`/`instance`/`trap`/`foreign` + the four
     extern kinds via `refDelete`) whenever a new ref-able type is added.
  **These are enforced by tests, not vigilance:** the C ABI's tests run the C entry points under
  `std.testing.allocator`, which fails on double-free and leaks. `zig build test` reaches them via a
  dedicated `cabi_tests` target — `root.zig` does not import `wasm_c_api.zig` (the dependency runs the
  other way), so for the C ABI's whole life its tests were *unreachable* and it had none.
  **`tests/c_smoke.c` cannot substitute:** on the real allocator a double free silently corrupts the
  freelist and the test still prints `OK`. It did. "It didn't crash" is not evidence of safety.
  **Beyond the hand-written lifecycle tests, a randomized fuzz (`fuzzStep` + the two `lifecycle fuzz`
  tests, #22) drives arbitrary new/copy/delete/cast/vec orderings under the same allocator** — 400
  seeds in `zig build test`, coverage-guided under `zig build test --fuzz`. It found rule 6 on its
  first seed. When adding a ref-able type or op, extend the fuzz's `FuzzKind`/`fuzzBuild`, not just the
  example-based tests — the fuzz is the part that finds the ordering nobody thought of.
- **`Instance.recordTrap` must stay `noinline` (2026-07-15).** `Frame.run`'s `errdefer` expands at
  *every* `try` in a ~200-arm dispatch switch, so whatever it calls is duplicated across hundreds of
  landing pads. Letting `recordTrap` inline bloats `Frame.run` and evicts the interpreter loop from
  i-cache: **~14% steady-state, measured twice** (224 → 288 Mops/s just from adding `noinline`). It is
  correctness-neutral and performance-load-bearing, which is exactly the kind of thing a later "clean
  up the redundant noinline" pass would delete. Don't. Same reasoning applies to anything else the
  `errdefer` ever calls. **The general rule: on an error path reached from a huge hot function, prefer
  an out-of-line call — code size on the error path is a hot-path cost.**
- **Trap byte offsets are resolved on demand, never tracked during execution (2026-07-15).**
  `TrapFrame` carries `{func_index, pc}` only; `Instance.frameOffset` re-decodes that one body to map
  pc → byte offset when a trap is *reported*. Tracking offsets at instantiate cost **~7% cold-start**
  (0.86 → 0.96 us/run) plus 4 bytes per instruction for every module, to serve a path most modules
  never take. Cold-start is the metric the vision competes on (`vision.md`); traps are rare and already
  slow. If a future change wants offsets available mid-execution, weigh it against cold-start first.
- **Libc-free core (2026-07-02).** `root.zig` and its deps link no libc, so the same code targets
  native *and* `wasm32-freestanding`. The C-ABI lib uses `std.heap.smp_allocator`; the wasm entry uses
  `std.heap.wasm_allocator`; **never `std.heap.c_allocator`** (that pulls in libc). `build.zig` must
  **not** call `cabi.linkLibC()`. Rationale: smallest binary, no toolchain requirement for embedders,
  one allocator strategy across targets. If a future feature genuinely needs libc, add it as an opt-in
  `-Dlibc` build flag — never the default. See "Windows gotchas" for why this also unbroke the build.

- **Distributed artifacts ship as `ReleaseSmall` (measured 2026-07-14).** The C-ABI `.lib`/`.dll` (what
  the `universalWasmLoader-*` ports link) and the freestanding wasm build should be built `ReleaseSmall`,
  not `ReleaseFast`. Benchmark data (`testing.md`): `ReleaseSmall` shrinks the static lib **−88%**
  (1015→123 KB) and the DLL **−58%** (311→130 KB) for only ~5% steady-state throughput and +0.5 µs
  instantiate — and the metric wazmrt actually wins on, **cross-process cold-start, is unchanged** (it's
  OS-spawn-floor bound, not size bound). The ~5% cost lands only in sustained hot loops, the regime
  wazmrt already cedes to a JIT. Reserve `ReleaseFast` for a specifically compute-bound embedder.
  Aligns with the "smallest binary" goal at ~no cost to the win.

- **Integration ABI = the standard wasm-c-api (2026-07-02).** The C ABI **is** the vendored standard
  `wasm.h` (Apache-2.0, `third_party/wasm-c-api/`); `include/wazmrt.h` is only a thin extension. Do NOT
  reinvent module/engine/store signatures — implement the standard ones (`src/wasm_c_api.zig`).
  Opaque `struct wasm_*_t*` handles; internal layout is free to change. Implement the standard
  incrementally; leave unbacked functions undefined (a static-lib symbol only errors if referenced).
  **Bump `root.abi_version`** on any wazmrt-extension break. Every `universalWasmLoader-*` port checks
  `wazmrt_abi_version()`. Windows consumers compile with `-DLIBWASM_STATIC` (static lib). The retired
  ad-hoc `wazmrt_module_decode/_section_count/_free` ABI was replaced by the standard `wasm_module_*`.

- **Zero-copy decode (2026-07-02).** `Reader` borrows slices; `Module` stores only section
  `{id, offset, size}` extents — no eager payload copies. Consequence: a decoded `Module` must remain
  valid after the input buffer is freed (it does — it copies nothing out of the input except the extent
  integers). Keep it that way; if a future stage needs payload bytes, copy explicitly and document it.

- **Version string single-sourced (2026-07-02).** `root.version` (`"0.1.0"`) is the one truth; keep it
  in sync with `build.zig.zon` `.version`. The C ABI returns `root.version.ptr`.

- **Interpreter architecture = switch-dispatched, IR-ready (owner, 2026-07-02).** wazmrt is an
  **interpreter**, not a JIT/AOT — a native codegen backend violates "smallest binary" and can't run on
  the `wasm32-freestanding` self-compile target. Among interpreters we chose **Option A: a
  switch-dispatched interpreter over a pre-decoded instruction IR**, over B (register-machine rewriting,
  modern wasmi) and C (tail-call threading, wasm3). Rationale: smallest + most portable + fastest to
  *correct*, and it unblocks the loaders soonest. Load-bearing sub-rules:
  - **One shared opcode table / instruction decoder** used by validation, IR-building, and execution —
    they must never drift. Define it once (likely `src/opcode.zig` + an `Instr` type).
  - **Untyped `u64` value-stack slots** (validation proves types; no per-value tag) — smaller/faster,
    as in wasm3/wasmi.
  - **Keep the IR a clean seam.** Do NOT bake stack-machine assumptions so deep that Option B (a
    register-rewriting pass over the same validated input) becomes a rewrite. wasmi shipped stack-based
    first, then evolved to a register machine — that is the intended path *if* benchmarks demand it.
    Correct → measure → optimize; don't pay register-allocator complexity before execution exists.
  - **Reference study when optimizing:** B → wasmi (`Apache-2.0 OR MIT`), C → wasm3 (`MIT`); both
    ledger-friendly. No code adopted yet — architecture chosen at idea-level.

- **Optimization tiers above Option A (speculative; owner idea 2026-07-02).** The perf ladder, in
  increasing effort and *decreasing* alignment with the size/wasm goals. All hang off the clean IR seam;
  decide with the size/speed benchmark (`vision.md`), not now.
  - **A.5 — partial evaluation + superinstructions (goal-aligned, the owner's idea).** On the pre-decoded
    IR: constant-fold / pre-evaluate **acyclic** regions ("not recursively bound" = no loop back-edge or
    recursion cycle — those stay for runtime), and **fuse common opcode sequences into superinstructions**
    to cut per-instruction dispatch. Stays tiny *and* compiles-to-wasm (still an interpretable IR — unlike
    a JIT); targets the beat-Deno/V8 startup + non-hot regime. **Nuances:** keep the *execution* IR flat
    even if the *analysis* uses a tree/CFG (a full AST-walking interpreter is usually slower — cache +
    dispatch); and wasmtk's producer already runs binaryen `-Oz`, so classic const-folding yields little,
    but `-Oz` trades speed for size, so the real wins are dispatch reduction, stack-traffic elimination,
    and specialization. **Complementary to Option B, not either/or.**
  - **B — register machine (wasmi-style).** Eliminates operand-stack traffic; can combine with A.5.
  - **JIT — native codegen (top tier, "later").** Fastest, but **breaks smallest-binary + compiles-to-wasm**
    (a JIT can't emit native from inside wasm). Reserve for a **native-only high-performance mode**,
    offered alongside the interpreter (mirrors the wasmtime-as-optional-backend framing in `vision.md`).
    Exotic middle for the compile-to-wasm mode: emit specialized *wasm* for hot regions and let the host
    engine JIT it — very speculative.

- **Proposal scope (owner, 2026-07-13; GC-priority note 2026-07-13).** Track the core spec + the
  proposals that are (or are becoming) browser-standard; defer the rest until they are, mirroring wasmtk.
  - **In scope / done:** MVP, reference types, multi-table, bulk table ops, extended-const, and the
    **function-references proposal** (typed refs, `call_ref`, non-null refs + local-init — DONE
    2026-07-13).
  - **In scope / IN PROGRESS — full GC (P3).** **WasmGC** (i31/struct/array heap objects, `struct.new`/
    `array.new`/field access, `ref.test`/`ref.cast`/`br_on_cast`, subtyping, rec groups) is
    browser-standard (Chrome/Firefox 2023), so it is in scope. **Owner directive (2026-07-13): P3 is the
    next major increment and comes BEFORE growing the wasm-c-api (instance/func/call) and the Deno/V8
    benchmark.** It needs a GC heap + object model + RTTs — a size cost accepted despite the
    smallest-binary lean (likely gated to a native/opt-in build). Build it in tested parts (the wasmtk
    way): i31 first, then struct/array, then the cast/test ops. **WASI preview 1** follows.
    - **i31 slice DONE 2026-07-14** (first tested part, git `0f1e0c2`). The WasmGC `any` internal
      hierarchy is now modeled as *distinct* `ValType`s (`anyref`/`eqref`/`i31ref`/`structref`/
      `arrayref`/`nullref` + non-null `*_nn` synthetic tags) instead of collapsing to `externref` — so
      `refHeap()` + `RefHeap.sub()` in `types.zig` drive real GC subtyping (i31/struct/array <: eq <:
      any; `none` bottom; func/extern disjoint), and `validate.subtypeOf` combines heap-subtype with
      nullability. **`i31` is unboxed** — the 31-bit payload lives directly in the interpreter's `u64`
      value slot (range `0..2^31-1`, so it can never alias the `null_ref = maxInt(u64)` sentinel).
      Ops `ref.i31`/`i31.get_s`/`i31.get_u` decode under the **`0xFB` prefix** (internal `Op` tags via
      `gcSubOpcode`, mirroring the `0xFC` table-op scheme), assemble+run, `i31.get` on null traps.
      *Cleanup (git `7cba25f`):* a nullable-ref local now defaults to `null_ref`, not `0`
      (`FuncBody.local_defaults`, memcpy'd at entry) — fixed the pre-existing `@memset(locals, 0)` gap.
    - **struct/array slice DONE 2026-07-14** (git `bec0cf7` type-space refactor 2a + the runtime 2b).
      - **2a — type space is now a composite-type table.** `Module.func_types` (`[]FuncType`) →
        `comp_types` (`[]CompType` = func | struct(`[]FieldType`) | array(`FieldType`)) + `supertypes`
        (kept for later cast). Accessors `funcSig`/`structFields`/`arrayField` gate by kind so a struct
        type in a func position (`call_indirect`/`call_ref`/block type) *errors* (`error.BadType`),
        never reads a bogus signature. `decodeTypeSection` decodes the full GC type grammar: rec groups
        (`0x4e`), sub types (`0x50`/`0x4f`, ≤1 supertype), struct (`0x5f`)/array (`0x5e`)/func (`0x60`)
        comptypes, packed `i8`/`i16` storage. A **cheap kind pre-scan** runs first so a `(ref $t)` field
        collapses to the right family even when `$t` forward-references a later type in the same rec
        group (`Reader.peekByte` added).
      - **2b — heap + ops.** `Instance.gc_heap: ArrayList([]Value)` — one field/element slice per object,
        **arena-backed, no collector** (leak-until-instance-dies; size cost accepted, likely opt-in
        later). A struct/array **reference value is the object's heap index** (small, never aliases
        `null_ref`). Ops (all `0xFB`-prefixed except `ref.eq`=`0xd3`): `struct.new`/`new_default`/
        `get`/`get_s`/`get_u`/`set`, `array.new`/`new_default`/`new_fixed`/`get`/`get_s`/`get_u`/`set`/
        `len`, `ref.eq`. Packed fields store masked (`packField`) and widen on read (`unpackField`:
        `_s` sign-extends, `_u` zero-extends). Null access traps `NullReference`; OOB field/index traps
        the new `error.GcOutOfBounds` (a runtime backstop for the collapse gap below).
      - **Concrete `(ref $t)` value types DONE 2026-07-14 — the collapse limitation is resolved.**
        `ValType` widened from `enum(u8)` to `enum(u32)`: numeric/abstract types keep their single byte
        (< 0x100); a **concrete typed reference is encoded in the high bits** — bit 31 concrete, bit 30
        nullable, bits 28–29 the family (func/struct/array), bits 0–27 the type index — so `ValType`
        stays a single comparable scalar (no tagged-union rewrite). `(ref $t)` now flows through
        params/results/fields/locals/globals/table-elems with its exact type; `struct.new`/`array.new`/
        `ref.func`/`ref.cast`/`ref.null $t` (and the const-expr forms) **produce concrete refs**, and
        `validate.subtypeOf` takes the module: concrete↔concrete uses `Module.isSubtype` (the collapsed
        heads alone would wrongly accept any two structs), concrete↔abstract uses the family head, and
        an abstract sub satisfies a concrete sup only when it is bottom `none`. Binary emission centralizes
        in `wat.emitValType` (`0x64`/`0x63` + `s33`); **`ref.null`'s immediate became a heap type**
        (`s33`, so `ref.null $t` is typed `(ref null $t)` — decoder/validator/`skipConstExpr`/assembler
        all updated). The assembler's concrete-ref *kind* bits are a **placeholder** — it only emits the
        index; the decoder re-derives the family via its kind pre-scan (a two-pass type pre-pass collects
        all names first so a `(ref $t)` field can forward-reference). Imported-func `ref.func` still falls
        back to the abstract `funcref` head (no type index kept). The runtime is untyped, so this is a
        pure **validation-precision + assembler-expressiveness** gain over the already-correct interp.
    - **ref.test / ref.cast slice DONE 2026-07-14.** Adds runtime type identity to GC:
      - **Heap objects carry an RTT.** `Instance.HeapObject = { type_index: u32, fields: []Value }` — so
        a reference knows its actual composite type at runtime. `ref.test`/`ref.cast` (`0xFB` 0x14–0x17,
        target heap type as an `s33`) return i32 / pass-through-or-trap (`error.CastFailure`).
      - **i31 is now tagged.** A `ref.i31` result sets **bit 63** (`i31_tag`) so within the `any`
        hierarchy a value is unambiguously **null** (`== null_ref`, checked first), **i31** (bit 63
        set), or a **heap-object index** (bit 63 clear). `i31.get_*` mask the low 31 bits (tag ignored);
        `ref.eq` compares tagged slots directly. This is the key enabler — an untyped `u64` slot
        otherwise can't tell an i31 from a struct index.
      - **Runtime dispatch on the *target's* top hierarchy.** Validation guarantees the operand shares
        the target's hierarchy, so `refMatches` reads the value as i31/heap-index for an `any` target, a
        func index for a `func` target, an extern handle for `extern`. Abstract targets use
        `RefHeap.sub`; concrete `$t` targets use `Module.isSubtype` over the declared supertype chain.
      - **Declared subtyping is emitted end-to-end (2026-07-14).** The WAT assembler now parses
        `(type $t (sub final? $super? <comptype>))`, captures the supertype, and emits the sub form
        (`0x50` + a one-element supertype vector + the comptype); the decoder records it in
        `Module.supertypes` and `ref.test`/`ref.cast`/`br_on_cast` walk it via `Module.isSubtype`
        (transitively). Finality isn't tracked (unused), and the validator does **not** check
        field-width compatibility between a subtype and its supertype (a valid module lays them out
        compatibly — field 0 aligns — and the runtime bounds-checks accesses). Concrete `(ref $t)`
        *value types* still collapse to their head (the remaining limitation); cast *targets* and now
        supertypes carry the concrete index.
    - **br_on_cast / br_on_cast_fail slice DONE 2026-07-14 — WasmGC op coverage is now complete.**
      `0xFB` 0x18/0x19; immediate = a flags byte (bit 0 src-nullable, bit 1 dst-nullable) + label +
      src & dst heap types (`s33`). `br_on_cast $l src dst` branches to `$l` (delivering the ref as
      `dst`) when the ref casts to `dst`, else falls through with the ref as `src`; `br_on_cast_fail`
      is the mirror (branch on miss carrying `src`, fall through as `dst`). The runtime just re-uses
      `refMatches` + `branch()` — the `u64` value is unchanged, only its static type differs (a
      validation concern), so the exec cases *peek* the ref and branch/advance. Validation checks
      `dst <: src` and that the label's last type accepts the carried ref. Also completed the
      block-type decoder for the non-null synthetic tags (`readBlockType` gained anyref_nn…nullref_nn),
      needed for `(block (result (ref i31)) …)` around a cast-branch.
  - **Deferred (until browser-standard):** **WASI preview 2/3** (component-model based), **multi-memory**,
    exception-handling **tags**, **SIMD** — pulled in as the real corpus (`wasm_wasi`) demands. Typed/GC
    reference *value types* are already *accepted* (P1) so such modules build.

## Zig 0.16 API notes (this project targets 0.16.0)

The 0.16 stdlib differs from older docs — verified against the installed stdlib this session:

- **`main` signature:** `pub fn main(init: std.process.Init) !void`. Arena via
  `init.arena.allocator()`, args via `init.minimal.args.toSlice(arena)`, io via `init.io`.
- **New `Io` model:** file read is `std.Io.Dir.cwd().readFileAlloc(io, sub_path, gpa, limit)` where
  `limit` is `std.Io.Limit` (`.limited(n)` / `.unlimited`). Stdout via
  `Io.File.Writer = .init(.stdout(), io, &buf)` then `&writer.interface` (`.print`, `.flush`).
- **`std.ArrayList` is unmanaged:** initialize with `.empty`; methods take the allocator —
  `list.append(allocator, x)`, `list.toOwnedSlice(allocator)`, `list.deinit(allocator)`.
- **`addLibrary`** replaces `addStaticLibrary`/`addSharedLibrary`:
  `b.addLibrary(.{ .name, .linkage = .static, .root_module })`.
- **`build.zig.zon`** requires a `.fingerprint` (generated by `zig init`; never hand-change) and
  `.name` as an enum literal (`.wazmrt`).

## Windows build gotchas (this is the dev machine — win32, D: drive, Zig 0.16 via scoop)

- **Linking libc without MSVC → `error: Unexpected`.** On this box (no MSVC toolchain), any artifact
  that links libc makes the build system eagerly resolve the native libc install and fail with a bare
  `error: Unexpected`. This was the original cause of the build breakage; fixed by going libc-free
  (see invariant above). Symptom is misleading — it looks like a compiler/cache crash, not a link
  error.

- **`.zig-cache` corruption cascade.** A failed `zig build` on Windows can leave `.zig-cache` in a
  state where **every subsequent `zig build` (even `--help`) prints `error: Unexpected`**. Fix: delete
  `.zig-cache` (and `zig-out`) and rebuild. Each step then succeeds in isolation.

- **Cache-lock race when chaining builds.** Running several `zig build <step>` invocations back-to-back
  in one shell command → the first succeeds, the rest fail with `error: Unexpected` and re-corrupt the
  cache. **Run one `zig build` at a time.** Every step (`build`, `test`, `wasm`, `run`) passes cleanly
  on its own; this is a harness/timing artifact, not a code defect.

- **Git "dubious ownership" on D:.** `git` refuses the repo until
  `git config --global --add safe.directory D:/Programs/_ProgramExamples/Example_Programs/wasmExamples/wazmrt`
  (already applied this session).

- **PowerShell `2>&1` mangles native stderr.** Zig's stderr wraps into PowerShell ErrorRecords. To read
  real Zig output, redirect via `cmd /c "... 1> file 2>&1"` and read the file, or rely on captured
  stderr — don't pipe `2>&1` through PowerShell.

## Verified working (2026-07-02)

- `zig build` (5/5 steps), `zig build test` (7/7 tests), `zig build wasm` (3/3).
- CLI end-to-end: `wazmrt empty.wasm` → `valid wasm v1, 1 section(s)` / `custom (payload 1 bytes @ 0xa)`.
- **Validation over real modules:** all 12 `wasm_mod` modules and every fully-decoding `wasm_wasi`
  module pass `validate.zig` (see `testing.md`).
- **Execution (integer + float + memory):** `interp.zig` runs `add`/`if-else`/`call`/`br`, `f64.add`,
  `i32.trunc_f64_s`, memory store/load + data-segment init, and traps (div-by-zero, NaN→int). **On real
  corpus modules** (via CLI `wazmrt <file> <export> [args…]`): `fib(20)=6765`, `fac(7)=5040`,
  `sieve(30)=10` (memory), `isLeapYear`/`isOdd` — all match their `.test.json`.
- **Text toolchain:** `sexpr.zig` + `wat.zig` (WAT→wasm binary — funcs, control flow, memory/data,
  memarg, **multi-value block types + typed `select`**) + `wast.zig` (WAST runner, runs the spec
  testsuite). **48 unit tests total.**
- **C ABI end-to-end from C** (`tests/c_smoke.c`): built a static lib + compiled/linked the C client
  with `zig cc -target x86_64-windows-gnu -DLIBWASM_STATIC` (mingw libc, no MSVC), ran it →
  `validate(good): true`, `module_new: ok`, `validate(bad): false`, `abi_version: 1`, `version: 0.1.0`.
  Note the gnu target: the C client needs a libc, and zig's bundled mingw provides one without MSVC.
