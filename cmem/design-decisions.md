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
- **The WASI sandbox is a security boundary, and `Io.Dir` does not enforce it (2026-07-16).** Two
  independent things escape a preopen, both on us: (1) *naming* — an absolute path or escaping `..`
  bypasses the `*at` dir handle (`resolve_beneath` is a silent no-op off FreeBSD), handled lexically by
  `resolve`; (2) *symlinks* — `follow_symlinks = false` only guards the final `openat` component, so an
  intermediate symlink is followed out. **Rule: never resolve a guest path as one string handed to
  `Io.Dir`.** The resolver `walkFull` (4.3, "secure full traversal") is RESOLVE_BENEATH in userspace: a
  **stack of open dir handles**, bottom = preopen, walked one component at a time — each opened
  no-follow through the held handle (TOCTOU-safe), symlinks **followed** but expanded through the same
  loop, `..` popping the stack **but never below the preopen** (no handle above it exists → up-escape
  impossible), absolute targets **re-based to the preopen root**, a `symlink_max` budget → ELOOP.
  **Security is a property of the construction, not of checking target strings** — which is essential
  now that `path_symlink` lets the *guest author* the links. A path op that resolves the full path in
  one `Io.Dir` call, or that trusts a lexical `..` check once symlinks are in play, is the bug; both
  have bitten. Full argument + spec in `cmem/security-model.md`; the resolver is `walkFull` in
  `src/wasi.zig`. **Mandatory when touching it: re-run the adversarial fuzz** (`src/wasi.zig`,
  "symlink resolver fuzz" — canary-outside oracle).
- **Exceptions unwind as a Zig error, caught at each `call` site (2026-07-17, Phase 6).** A `throw`
  builds an `Exception{tag, values}` and calls `Frame.throwException`, which searches *this* frame's
  label stack innermost-out for a `try_table` whose catch matches (tag, or `catch_all`); on a match it
  resets the value stack to the try_table's base, pushes the payload (plus a boxed `exnref` for the
  `_ref` variants), and `branch`es to the clause's label. If no handler in this frame matches, it stashes
  the exception on `Instance.pending_exn` and returns **`error.UncaughtException`** — which each `call`
  arm intercepts via `Frame.onCallError`, re-running the same search in the *caller's* try_tables. This
  reuses the existing recursive-call + `errdefer` unwinding rather than a separate exception stack. **Two
  things to preserve:** (1) on a successful call-site catch, reset `trap_len`/`trap_depth` (the unwinding
  frames recorded a would-be trace that must not leak into a later real trap); (2) `exn_store` and
  `pending_exn` are cleared per invocation — `exnref` payloads are invocation-arena memory and must never
  outlive the call.
- **Legacy `try`/`catch` runs its handler INSIDE the try; try_table branches OUT (2026-07-17, Phase 6.3).**
  wasmtk's corpus turned up files from older LLVM that emit the *legacy* EH encoding
  (`try`/`catch`/`catch_all`/`rethrow`, 0x06/0x07/0x19/0x09), so it's supported for compat (decode +
  execute only — no assembler, and the CLI run path doesn't validate, so no validator either). The key
  behavioral difference from try_table: a matching **legacy catch keeps the try's label on the stack**
  and jumps to an inline handler pc, so `rethrow N`/`br` inside the handler still see the try; a
  try_table catch *branches out* and pops it. Handlers are precomputed per `try` into `FuncBody.try_info`
  (a normally-completing body/handler skips to `end` via `end_of[catch_pc]`). `rethrow N` re-raises the
  try-N caught exception from **outside** that try (pop to try-N, then unwind). Both encodings share the
  one `throwException` search and `error.UncaughtException` propagation.
- **The run path is unvalidated, so the interpreter self-defends — HARDEN, don't validate-before-run
  (owner, 2026-07-19).** The CLI run path (`runFunction`/`runWasi`) executes a module **without type-
  validating it first** (only the inspect path validates). Since wazmrt ships ReleaseFast/ReleaseSmall,
  an unchecked OOB is real UB, so the interpreter must **trap, never index out of bounds**, on any
  malformed/malicious module. Owner chose **harden the interpreter** over running the validator on the run
  path (which would regress legacy-EH modules the validator doesn't cover, and cost startup). Mechanism:
  `checkStaticIndices` bounds-checks every *static* index immediate ONCE at instantiation; *dynamic* values
  are checked at their cold use sites. **The recurring trap is the stack-HEIGHT wild-base pattern:** any
  `vstack.items[items.len - N ..]` used as a slice/index base underflows to a wild pointer on a short
  stack — the call opcodes made it an unbounded `@memcpy` **write** into `locals`. **Rule: never compute a
  value-stack base as a raw `items.len - N`; go through `Frame.stackBase(n)` / `peek()`** (they trap
  `StackUnderflow`). GC/exn refs go through `gcObject`/`throw_ref` bounds checks; branch/rethrow label
  depth is checked in `branch`. Two audit passes (2026-07-19) closed the class; full ledger in
  `known-issues.md` ("Run-path memory-safety hardening").
- **The WAT assembler never derefs parser output unchecked — shape-checked accessors (owner, 2026-07-19).**
  `sexpr.parseAll` only balances parens/strings; it does NOT validate shape, so malformed `.wat` (reached
  before any verify gate via `wazmrt file.wat` / `sign` / `pin <dir>`) must yield `error.BadModuleField`,
  never a raw `items[N]` OOB or a wrong-union `.?`/`.string` deref (UB in ReleaseFast). **Rule: every
  parser-derived access in `wat.zig` goes through `wantList`/`wantAtom`/`wantStr`/`nth`/`fieldStr`/`strAt`
  — no bare `items[N]`, no `.asList().?`/`.asAtom().?`/`.string`.** `sexpr.zig` also caps nesting depth
  (`max_depth = 1024` → `NestingTooDeep`) and `Reader.readVecLen()` rejects a vec count > remaining bytes
  (OOM-amplification guard) at every pre-alloc site.
- **Every tokenizer loop must make progress (2026-07-20, 10th pass).** A depth cap catches runaway
  *recursion*; it cannot catch a loop that simply never advances `pos`. `sexpr.parseAtom` treated `;` as a
  terminator and returned an **empty** atom without consuming it, so `parseAll`/`parseList` appended empty
  atoms forever — `(module) ; x`, **12 bytes**, hung the CLI at 10.4 GB. **Rule: `parseValue` rejects any
  character that starts no value and that `skipTrivia` does not consume (`error.UnexpectedChar`), and
  `parseAtom` returning zero bytes is itself an error** — so adding a delimiter to `parseAtom` later cannot
  silently reintroduce the class. Note the trivia asymmetry that caused it: `;;` and `(;` were handled, the
  single-character case fell between them.
- **A host import's declared signature is untrusted input (2026-07-20, 10th pass).** WASI functions are
  bound by **name** (`main.zig` → `wasi.hostFunc(imp.name)`) while the *module* decides the declared arity,
  and `interp.callFunction` sizes the `args` slice from that declaration — so
  `(import "wasi_snapshot_preview1" "fd_write" (func))` made `argU32(args, 0..3)` read past the value
  stack (**segfault from a 4-line `.wat`**). `checkStaticIndices` cannot see this: no index immediate is
  involved. **Rule: every entry in `wasi.callFor`'s map carries its preview-1 parameter count and is wrapped
  in `guardArity`; a short call traps (`HostTrap`) rather than returning a plausible errno.** Do not
  "simplify" the arity column away.
- **The run path must re-check what only the validator checked (2026-07-20, 10th pass).** `Module.decode`
  enforces no section-order and no duplicate-section rules, so decoder-accepted modules can be internally
  inconsistent: a repeated `function` section leaves `func_space` and `module.functions` disagreeing
  (→ `funcType(fi).?` segfaulted from **31 bytes**), and the function/code section counts can differ
  (→ a multi-object `for` over unequal-length slices, which in ReleaseFast iterates the *first* length and
  reads `Module.Code` structs OOB). Only `validate.zig` compared these, and the CLI run path never
  validates. **Rule: any cross-section consistency property you rely on at run time must be re-checked
  there (`CountMismatch` in `initWithImports`, `orelse` on `funcType`) — never inherited from the
  validator.** Corollary for multi-object `for`: unequal lengths are *illegal behavior*, unchecked in
  ReleaseFast — guard the lengths before the loop whenever the slices come from separate sections.
- **Linear memory is page-allocator memory obtained via `rawAlloc` — never `Allocator.alloc` (owner,
  2026-07-20).** Guest memory must be **zero** and must cost address space rather than RSS. Both follow from
  taking fresh OS mappings (`PageAllocator` → `NtAllocateVirtualMemory`/`mmap`, no free-list, OS-guaranteed
  zero-fill) **and bypassing `std.mem.Allocator`'s poison**: `allocBytesWithAlignment` does
  `if (runtime_safety) @memset(byte_slice, undefined)`, i.e. fills with `0xAA` in Debug/ReleaseSafe. Using
  the plain `alloc` measured **1029 MB RSS for a 1 GiB declaration with the guest reading `0xAAAAAAAA`** —
  a build-mode-dependent wrong answer. **Rule: guest-visible buffers go through
  `allocGuestMemory`/`freeGuestMemory`/`growGuestMemory`; never `gpa.alloc` + assume zero, and never add an
  eager `@memset` "for safety" — it reintroduces the 4 GB cost.** Pinned by
  `test "hardening: guest linear memory is zero-initialized, in every build mode"`.
- **A linear-memory budget, enforced at instantiation AND at `memory.grow` (owner, 2026-07-20).** Lazy pages
  bound RSS but not address space, so `Imports.max_memory_bytes` (default `default_max_memory_bytes` =
  **1 GiB**, CLI `--max-memory`) is summed over **all** of an instance's memories and re-checked by
  `memory.grow` — otherwise a small declared minimum simply grows past the ceiling. Grow reports refusal as
  `-1` (spec-correct), instantiation as `error.MemoryLimitExceeded`.
- **Hot-loop guards are `@branchHint(.cold)` + benchmarked (2026-07-20).** Making `Frame.pop` safe cost
  **−12%** (250 → 220 Mops/s) until the underflow arm was marked `@branchHint(.cold)`, which restored
  parity (244–250) — `.?` is fast precisely because it lets the optimizer delete the check, so any real
  check must be hinted. A per-instruction `if (underflowed)` in the dispatch loop cost **−13% even hinted**,
  which is why that check sits at the **loop exit**, not inside it (safe because `pop` substitutes a defined
  `0` and every consumer is independently bounds-checked; `return` also exits via `pc = ir.len`, and
  call/branch/epilogue already trap via `stackBase`/`peek`). **Rule: never add an unhinted branch to
  `Frame.run`'s loop, and re-run `zig build bench` when you touch `pop`/`push`/dispatch.** Same lesson as
  `noinline recordTrap` (#19).
- **The validator's two resource caps are a PRODUCT, not two independent limits (2026-07-20).** Every
  `pushCtrl` `dupe`s the whole local-init vector, so peak cost is `max_ctrl_depth × max_locals`. Raising
  either one alone silently reinstates the amplification this fixed (a 512 KB module took **767 MB**);
  2²⁰ locals × 1024 frames would still be ~1 GB. Current values — **1024 × 50 000 ≈ 51 MB** — were chosen
  together, and `max_ctrl_depth = 1024` also matches `sexpr.zig`'s parser cap so nothing reachable from
  `.wat`/`.wast` text can exceed it. **Rule: change one only by re-checking the product.** The same
  `max_locals` is enforced on the **run path** (`interp` exports it from `validate`), where the old
  `usize` accumulation would have *wrapped* on the wasm32 build.
- **Bound a loop by something that cannot reject valid input (2026-07-20).** `array_new_fixed`'s `n` is an
  unvalidated `u32`, and in *unreachable* code `popExpect` returns `.unknown` rather than underflowing, so
  the loop could spin ~4×10⁹ times. It is bounded by the **body's instruction count** rather than a chosen
  constant, because every operand must have been produced by at least one instruction — so the bound is
  provably ≥ any valid `n`. **Prefer a derived bound over a magic number whenever one exists**; a constant
  here would have been a guess that could reject a legitimate module.
- **`ValType.nullable()` returns a TYPE, not a bool — do not "fix" the element/table check (2026-07-20).**
  `validate.zig`'s active-element check is `elem.elem_type.nullable() != tet.nullable()`, which compares
  heap types with nullability normalized away — correct. A 10th-pass audit reported it as accept-invalid
  on the assumption that `nullable()` was a predicate; **verified false** (an `externref` segment against a
  `funcref` table is rejected `TypeMismatch`). A comment sits at the site. *General rule this earned: an
  audit finding is a hypothesis. Confirm the mechanism before changing security-relevant code — this one
  came with a plausible write-up and died on a two-minute check.*
- **A gate that cannot pass is not a gate (2026-07-20).** `zig build conformance` originally failed unless
  the upstream testsuite produced **zero** failures, which it never has here (see `testing.md`'s snapshot),
  so it would have been permanently red and therefore ignored. It now takes `-Dbaseline=<file>` (expected
  failures per file, `-Dwrite-baseline=true` to generate) and fails only on **regressions**, reporting
  improvements so the baseline gets re-generated. **Rule: when adding a CI step over a corpus we do not
  fully pass, gate on the delta, and make the no-baseline path explain itself rather than silently fail.**
- **The fuzz targets must not swallow the failure they exist to find (2026-07-20).** They `catch`
  `error.OutOfMemory` — a malformed input legitimately producing one is not a bug — which made
  allocation-amplification, the very class `Reader.readVecLen`/the memory budget/the table cap exist to
  prevent, **invisible by construction**. The sweep runs under a 64 MB `Budget` allocator and asserts it
  was never exceeded *and* that live bytes return to 0. **Rule: if a target catches an error class, add an
  independent oracle for it**, or that class is untested no matter how many inputs run.
- **Guard the property, not a proxy for it (2026-07-21).** `Op` values `0xd7..0xfa` are *internal tags*
  for ops whose real encoding is `0xFB`/`0xFC` + a sub-opcode, so a **raw** byte in that range is not a
  valid single-byte opcode. The original guard rejected by *immediate kind*, which is only a proxy: it
  could never catch a tag whose kind is also reachable from a genuine single-byte op (`0xe3–0xe5` →
  `.table`, `0xed`/`0xf0–0xf2` → `.none`), so it was silently partial for months. The check is now the
  **byte range**, which is the property that actually holds. **Rule: when rejecting an encoding, test the
  encoding.** (`0xd0–0xd6` are real ops and `0xfb–0xfd` are prefixes consumed earlier — both outside the
  range, so the boundary is exact.)
- **Offsets that only label diagnostics saturate, never `@intCast` (2026-07-21).** `Module.body_offset`
  and `opcode`'s per-instruction offset list are `u32` fed from `usize`. A >4 GiB module made both casts
  out-of-range — UB in ReleaseFast — and while the CLI's 64 MB read cap makes that unreachable there, the
  **C ABI takes arbitrary embedder bytes**. They now clamp: these values only name a line in a trap
  backtrace, so a wrong number is cosmetic where the cast was undefined. **Rule: a `usize → u32` narrowing
  on module-derived data is either checked or saturating — never a bare `@intCast`.**
- **`validate` is a promise to embedders, not just a dev convenience (2026-07-21).** The CLI run path
  deliberately skips validation and the interpreter self-defends — but `wasm_module_validate` is a C-ABI
  entry point, so "the validator accepted it" has to mean something. Three gaps closed on that basis:
  `br_on_non_null` was reject-**valid** (hard-coded `funcref`/`externref`, rejecting every GC/typed-ref
  label); SIMD memory ops and `memory.size`/`grow` had **no memory check at all**; and the scalar path
  checked only `memories.len == 0`, never the memarg's memory index (multi-memory). All now go through
  `requireMemory(index)`. **Rule: a memory-touching op validates the memory it names, not merely that some
  memory exists.**
- **Which `0xFD` sub-opcodes touch memory lives next to `decodeSimd` (2026-07-21).** The `Simd` immediate
  always carries a defaulted `mem` field, so its presence cannot distinguish a load from a splat.
  `opcode.simdIsMemoryOp` is deliberately adjacent to the decode switch that *is* the authority, so the
  two ranges cannot drift apart silently.
- **A masked index must be range-checked before masking (2026-07-21).** `ValType.concreteRef` packs the
  type index into 28 bits, so an index above `max_concrete_index` **truncates to a small, possibly valid
  index** — type confusion, not merely a wrong number. The binary decoder was already safe (it bounds `ti`
  by the declared type count first); the text assembler was not. **Rule: every path that builds a concrete
  ref checks the width first** — the mask is a storage detail, never an input filter.
- **Guest array offsets go through `Wasi.arrayOffset` (2026-07-21).** `base + i * stride` in **u32** wraps,
  and a wrapped (small) offset then *passes* the bounds check it should have failed — inverting the
  widen-then-check discipline. The helper does the arithmetic in u64 and requires the **whole element** to
  fit, so callers may still form `iov + 4` in u32 safely. **Rule: never index a guest array with u32
  arithmetic.** With this, the class opened in the 6th pass (`fd_write`/`seek`) and continued in the 10th
  (`writeStringVec`) is closed across the file.
- **Anything that outlives a call and stores a `*Instance` must RETAIN it (2026-07-21).** Trap frames
  were the last borrower: a `wasm_trap_t` outlives the call that produced it and `wasm_frame_instance`
  hands the pointer back, so `wasm_instance_delete` right after catching a trap left every frame dangling.
  One retain covers the frame array; `wasm_trap_delete` releases it. **Corollary for tests:** the first
  regression test compared `wasm_frame_instance(...)` to the original pointer, which **passes against
  freed memory** — a lifetime test must *dereference*, not compare. Verified by removing the retain and
  watching the test crash.
- **Float `min`/`max` use the hand-written `fmin`/`fmax`, NEVER `@min`/`@max` (2026-07-21).** Zig's
  builtins are **minNum/maxNum** — "if one operand is NaN, return the other" — and leave ±0 unordered.
  wasm requires NaN propagation and `min(+0,−0) = −0` / `max(+0,−0) = +0`. The scalar path always used the
  correct helpers; the **SIMD** path used the builtins, so `f32x4.min(nan, 1.0)` returned `1.0` and the
  same source compiled with and without autovectorisation gave different answers. **Rule: any new
  float min/max — scalar, SIMD, or relaxed — routes through `fmin`/`fmax` unless the op's spec explicitly
  wants the asymmetric form (`pmin`/`pmax`, and the relaxed `0x10d–0x110` arms, which correctly keep
  `@select`).**
- **Guest linear memory has exactly ONE owner: the `interp` page-allocator helpers (2026-07-21).**
  `allocGuestMemory`/`growGuestMemory`/`freeGuestMemory` are `pub` for this reason. `memObj()` in the C ABI
  can hand back either a host memory or an **instance** memory, so any site that frees or grows
  `Memory.bytes` with a different allocator is cross-allocator corruption — which is exactly what the
  lazy-pages change left behind in `wasm_memory_new`/`grow`/`destroyRef` until it was caught.
  **Rule: `Memory.bytes` is never touched by `alloc`.** *Meta-lesson: changing who owns an allocation is
  not local — sweep every file that frees or grows it, not just the one you edited.*
- **`zig build test-safe` is the memory-safety gate (2026-07-20).** The suite under **ReleaseSafe** —
  optimizer on, safety checks kept — so out-of-range `@intCast`, OOB, and null-unwrap panic loudly instead
  of being silent UB in the shipped ReleaseFast/ReleaseSmall builds. **Run it alongside `zig build test`
  after any memory-safety change**; a Debug-only pass does not prove the shipped build safe.
- **Pin verification hashes the bytes it runs, and the gate has no path to re-open (2026-07-17,
  Phase 5).** `verifyGate` (in `main.zig`) receives the **in-memory module buffer** and hashes *that*;
  it is handed the path only for messages and never re-reads the file. So the verified bytes provably
  *are* the executed bytes — the check→use swap window (TOCTOU) is closed by construction, not by
  discipline a refactor could lose. **Rule: never add a second read of the module by path near the
  verify/run seam** — if you need the bytes, thread the existing buffer through. The enforcement
  *policy* lives in the **root-owned** pin DB (`# mode:` directive), so authority comes from the file's
  ownership; a user's `--no-verify`/`--verify` can only *raise* strictness (`pin.stricter`) and is
  refused under a root `enforce`. **Deny-unsigned-when-armed (owner decision, 2026-07-18):** the pure
  decision is now `pin.decide(explicit: ?Mode, pinned, opt_out, tty, armed)`. `armed` = a root key is
  embedded **or** a pin DB is present (`verifyGate` computes it) — a *real deployment*. When armed and
  there is no explicit `# mode:`, an unsigned/unpinned module is **denied**, but `--no-verify` overrides
  (the user owns their machine); an explicit root `# mode: enforce` is **absolute** (opt-out ignored). A
  **bare** build (no key, no DB) is *not armed* → runs everything, so dev/tests/`wasi-gate` are
  unaffected. **The gate is CLI-only** — the C-ABI/embedder run path has none, the intended permissive
  default for wasmtk/rsxtk/FFI. **No key rotation** (owner rejected it — one embedded key; rebuild to
  change). Keep the CLI a thin shell over `decide`. **Signatures are BUILT** (`src/sign.zig` + `wazmrt
  keygen`/`sign`, 2026-07-18): the CLI
  `verifyGate` runs the Ed25519 signature check *before* the pin fallback (authenticated ⇒ no pin
  needed; tampered-by-our-key ⇒ refused always); the publisher tools (`wazmrt keygen`/`sign`) generate a
  keypair and sign modules. The trust anchor is embedded via **`-Droot-key=<hex>`** (empty ⇒ inert;
  malformed ⇒ build error). **Build-plumbing invariant:** only `main.zig` reads the key, so
  `build_options` is imported by the **CLI module alone** — never wire it into `sign.zig`/`root.zig`, or
  every one of the ~8 targets that compile them (cabi/dll/wasm/bench/tests) would have to provide it. Only
  optional private-key custody hardening (HSM) stays design-only — see `security-model.md`.
- **Read-only preopens ride the rights model, not a write-path check (2026-07-17, `--ro-dir`).** A
  `--ro-dir` preopen is just a dir fd whose rights omit `rights.write_mask` (write/create/delete/
  rename/link/truncate/set-times/allocate). It stays enforced for the *whole subtree* because
  `path_open` **only ever narrows**: `new_inheriting = want_inheriting & dir.inheriting`. A guest can
  never widen by reopening, so there is no per-syscall "is this dir read-only?" branch to forget —
  the containment is the intersection arithmetic. **Rule: express new authority restrictions as rights
  the fd doesn't carry, not as checks at each mutating call.** `rights.read_only`/`allRights` in
  `src/wasi.zig`; invariant unit-tested ("read-only preopen rights can never yield a writable child fd").
- **Conformance is gated on real compiled guests, not just hand-written `.wat` (2026-07-17,
  `zig build wasi-gate`).** The gate compiles actual `wasm32-wasi` programs and runs them through the
  wazmrt CLI asserting exact stdout, so a decode/instantiate/WASI-surface regression fails the build.
  **Zig + C (via `zig cc`) run always** — both ship with the Zig toolchain, so the gate stays hermetic;
  **Rust is opt-in (`-Drust-gate=true`)** because it needs an external rustc, but a third independent
  compiler is the strongest cross-toolchain signal. **Rule: a conformance gate that can't fail is
  decoration** — verified by feeding a wrong expected string (→ exit 1). Guests live in `examples/`
  (`hello_compiled.zig`, `c_hello.c`, `rust_hello.rs`); wiring is `expectStdOutEqual` in `build.zig`.
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
  - **Deferred (until browser-standard):** **WASI preview 2/3** (component-model based) — pulled in as
    the real corpus (`wasm_wasi`) demands. Typed/GC reference *value types* are already *accepted* (P1)
    so such modules build. (**SIMD is no longer deferred — COMPLETE 2026-07-18**, see below.)
  - **SIMD (v128) — IN SCOPE; COMPLETE 2026-07-18 (Phase 8).** Owner chose **two u64 slots per
    v128** (not widening `Value` to u128 — that would 2x memory for every value in every program, against
    the small/fast vision; not boxing — that grows unbounded in SIMD loops). So a v128 occupies 2 stack
    slots. `slotWidth(vt)` (v128=2, else 1) threads through **locals** (`FuncBody.local_map`/`local_w`,
    `num_local_slots`), **block/branch arity**, **call arg/result counts**, and the `invoke` arg check —
    all now in *slots*. A module with no v128 keeps all widths at 1, so the non-SIMD path is byte-for-byte
    unchanged (verified: full suite green). The `0xFD` family is one `Op.simd` tag carrying `imm.simd.sub`
    (a u8 `Op` can't hold 236 ops); `execSimd` runs ~100 ops via Zig `@Vector`. **The drop/select-v128
    width gap is CLOSED via the validator (2026-07-17):** `drop`/untyped-`select` carry no operand type,
    so the interp couldn't tell a 2-slot v128 from a 1-slot scalar. Rather than duplicate type inference,
    the **validator** (which already tracks the full type stack, control flow, and unreachable) now
    type-checks SIMD (`simdSig`, total) and records each `drop`/`select` operand's slot width;
    `validate.dropSelectWidths` returns it. The interp runs this **only for v128 functions** (a SIMD op
    or v128 param/local — the common path pays nothing) and pops the right slots. **Tolerant:** on a
    validation error it keeps the widths captured before it — an error can only be at/after an
    unsupported op, which the interp traps on before any later drop/select runs, so those widths are
    never used. Bonus: v128 modules now get real SIMD validation. **SIMD is now FULLY complete
    (2026-07-18):** the entire 0xFD set — common ops, rare ops (extmul/dot/pairwise/q15/lane load-store),
    and all 20 relaxed ops — executes; the WAT assembler authors every op; v128 globals work (parallel
    `global_hi` array + `Imports.globals_hi` for imported v128 globals, `evalConstV128` handles both
    `v128.const` and `global.get`). The one representable-but-unsupported case, **v128 in a GC struct/array
    field** (would need a 2-slot object model), **fails loud** by owner's choice. No known v128 gaps. Full
    list in `roadmap.md` Phase 8.
  - **Multi-memory — IN SCOPE; BUILT 2026-07-17 (Phase 7).** A module may have >1 linear memory;
    load/store/`memory.*` select by index. The runtime holds `Instance.memories: []*Memory` (imported
    lead, then defined); a load/store memarg's **alignment bit 6** flags an explicit memory index that
    follows. `memory0()` keeps single-memory consumers (WASI host, C ABI) working. Decode + execute done
    (validator stays permissive — memidx bounds are a runtime check; the CLI run path doesn't validate).
    The WAT assembler is single-memory-only (deferred) — see `roadmap.md` Phase 7.
  - **Exception handling — IN SCOPE; CORE BUILT 2026-07-17 (Phase 6).** The standardized **exnref**
    proposal (`try_table`/`throw`/`throw_ref` + `tag` section, `exnref` heap type) — decode + validate +
    execute all done (see the EH invariant above and `roadmap.md` §6). Only the WAT assembler + `.wast`
    conformance remain (deferred §6.1). The **legacy** `try`/`catch`/`catch_all`/`delegate`/`rethrow`
    form (older LLVM) is a distinct encoding and stays out of scope.

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
