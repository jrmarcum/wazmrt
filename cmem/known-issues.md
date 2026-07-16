# Known Issues — deferred fixes + their surfacing conditions

Findings from the **2026-07-09 code audit** ("look for code issues") that were **reported but not
fixed** — each is safe *today* but will bite a specific future integration. The point of this file is
the **"Surfaces when"** field: before starting one of those integrations, grep this file for the
milestone and fix the listed items first.

The audit's *fixed* items are in git (commit `d1fae13` — table-export index, instantiation-path leaks,
`parseGlobal` OOB, `table.size/grow` `@intCast` panic, dead `ExportNotFunction`, stale doc comments).
This file tracks only what's left.

Line numbers are hints (they drift) — the function/construct name is the durable anchor.

## #22 — C ABI lifecycle fuzz — **DONE 2026-07-16.** Found 2 more real bugs.

Built the randomized lifecycle fuzz the owner scheduled as the first item for 2026-07-16. The process —
studying the object model to build a faithful generator, then running it — turned up **two more real
memory-safety bugs**, both now fixed:

- **Module use-after-free (found by studying the model, before a line of fuzzer ran).**
  `interp.Instance` stores `&m.inner` and dereferences it on every call, but the wasm-c-api contract
  lets the embedder delete the module right after `wasm_instance_new`. So delete-module-then-call was a
  **segfault**. Fix: the C-ABI `Instance` now holds a handle on its `Module` (`retain` on new, release
  on delete) — invariant 5 in `design-decisions.md`. This is the #21-bug-2 pattern (a stored pointer
  with no owned handle) for a second object; worth remembering the *class*, not just the instance.
- **`wasm_trap_delete` ignored the refcount (found by the fuzzer, on seed 1).** #20 added
  `wasm_trap_copy` (which `retain`s) but the pre-existing `wasm_trap_delete` freed unconditionally, so
  `trap_copy` then `delete` was a **double free**. The seeded sweep caught it immediately: a trap gets
  copied (rc=2), one delete frees it while a handle remains, and a later `new` reuses the address. Fix:
  `wasm_trap_delete` calls `release` first — invariant 6, and all eight deleters were audited.

**The fuzz itself** (`fuzzStep` + `runFuzzSequence` + two tests in `src/wasm_c_api.zig`):
- A live-handle **pool** of *owned* handles only; a weighted op generator does
  new/copy/delete/host_info/cast/table-get/vec-transfer. **Ownership is respected, not papered over:**
  borrowed views (`as_ref`, `X_as_extern`) are used transiently and never deleted (deleting one is a
  contract violation, not a bug to report); handing objects to an extern vec removes them from the pool
  because the vec now owns them.
- **One driver, two decision sources** via a tiny `decider` interface: `RandDecider` (a seeded
  `std.Random`) runs **400 seeds × 250 ops in `zig build test`** — deterministic, a failure prints its
  seed; `SmithDecider` (`std.testing.Smith`) runs the *same* ops **coverage-guided under
  `zig build test --fuzz`**. Single-sourced so the fuzzer and the CI sweep can never diverge.
- **The allocator is the oracle** (the comptime `alloc` is `std.testing.allocator` under test): it
  asserts almost no expected values, only correct *lifetimes* — any leak / double-free / UAF fails.
- **Verified it actually fails** (a gate nobody has seen fail is decoration): reintroducing the trap
  bug, the module UAF, and #21-bug-4 each made the fuzz go red.

**Original problem statement, kept for the reasoning:**

**What:** #21 made C ABI memory safety *testable* — `wasm_c_api.zig`'s tests run the C entry points
under `std.testing.allocator`, which fails on double-free and leaks. But every one of those tests is a
sequence **a human chose**. Each encodes a bug that already shipped. Nothing explores the orderings
nobody imagined, which is precisely where the next double-free lives: the four #21 bugs were all
"obvious" *after* a test happened to hit them, and three of them shipped anyway.

**Why it's the priority:** the guard is only as good as its coverage, and the C ABI is the one place a
mistake is a *heap-corruption primitive* rather than a wrong answer (`design-decisions.md`). Hand-written
lifecycle tests are a floor, not a ceiling. This is cheap insurance on the surface that just grew from
~140 to 319 functions in one day (#20) — i.e. the coverage gap widened sharply and hasn't been probed.

**Shape:** a randomized/fuzz driver over object-lifecycle operation sequences —
`new` / `copy` / `same` / `as_ref` / `ref_as_*` / `set_host_info` / `delete` / vec `new`/`copy`/`delete`
across module, instance, func, global, memory, table, trap, foreign — run under `std.testing.allocator`
so any double-free, leak, or use-after-free fails the run. Prefer a **deterministic seeded PRNG** with
the seed printed, so a failure is reproducible from the log; consider `std.testing.fuzz` for
coverage-guided input. The oracle is the allocator, not an expected value — no need to model correct
results, only correct *lifetimes*. Worth asserting refcount invariants directly too (`rc == 1` after
`copy`+`delete`; `same(copy(x), x)`; a downcast of the wrong type is null).

**Watch for:** operations that are legitimately *not* safe to fuzz blindly — deleting a borrowed
`wasm_extern_as_func` handle is a contract violation, not a bug, so the generator must respect
`own`/borrowed. Encode that distinction rather than papering over the crashes it produces.

**Surfaces when:** it already has — we just can't see it. Absence of a failing test here is currently
absence of evidence.

**Anchor:** the test block at the bottom of `src/wasm_c_api.zig`; `cabi_tests` in `build.zig`.

## #21 — C ABI memory safety: 4 exploitable bugs, found and fixed — **DONE 2026-07-15**

Raised by the owner immediately after #20 landed: *"We do not want to create memory unsafe issues…
memory safety is a massive project goal"* / *"We do not ever want to introduce exploitable holes."*
The audit that followed found **four real bugs**, three of them shipped in #20 hours earlier. All are
fixed, and — more importantly — the reason none were caught is fixed.

**The bugs** (all in `src/wasm_c_api.zig`):
1. **Double free.** `wasm_extern_vec_copy` aliased element pointers while `wasm_extern_vec_delete`
   destroyed them outright, so `copy(&b,&a); delete(&a); delete(&b);` — a sequence the header invites —
   freed each `Ref` twice. Heap-corruption primitive. Fixed: copies take a real handle (retain, or
   duplicate for export handles, which are cheap views); vec_delete routes through `refDelete`.
2. **Use-after-free, no misuse required.** A `Ref` stores `*Instance` and dereferences it on every call,
   but never owned it: `exports(); instance_delete(); func_call();` read freed memory. Fixed: a `Ref`
   that names an instance retains it (`refRetainInstance`), released in `destroyRef`.
3. **Uninitialized refcount.** `wasm_instance_new` / `wasm_trap_new` assigned fields one at a time onto
   `alloc.create` memory, so `hdr.rc` was garbage — freeable at any moment, or never. Only a
   whole-struct literal picks up defaults. Fixed, plus a test asserting `rc == 1` for every ref-able
   constructor, which catches the whole class.
4. **Leak + unrun finalizer.** `wasm_extern_vec_delete` destroyed standalone `Ref`s directly, skipping
   their functype/host_global/finalizer. Fixed by the same routing as (1).
Also hardened `release` to drive `rc` to 0 rather than leave it at 1, so a double delete can't run a
host-info finalizer twice.

**Why nothing caught them — the actual finding.** `root.zig` doesn't import `wasm_c_api.zig` (the
dependency runs the other way), so **`zig build test` could not reach the C ABI at all**: it had zero
Zig tests and no way to have any. And `tests/c_smoke.c` runs on the real allocator, where a double free
silently corrupts the freelist and the test **still prints OK** — it did exactly that when run against
the bug. A C repro of the double free printed `deleted b -- no crash?` and exited 0.

**The fix for the class:** `alloc` in `wasm_c_api.zig` is now
`if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator` (comptime — release builds
unaffected), and `build.zig` has a `cabi_tests` target on the `test` step. The C entry points now run
under an allocator that **fails the build** on double-free or leak. That is what turned all four bugs
from invisible into a red test in one run. **Anything that hands ownership across the boundary needs a
test there** — see the invariants in `design-decisions.md`.

**Surfaces when:** never again, ideally — but the guard is only as good as its coverage. New C ABI
surface without a lifecycle test in `wasm_c_api.zig` is unguarded.

## #20 — `wasm.h` declared 180 functions we didn't define — **DONE 2026-07-15**

**Was:** `third_party/wasm-c-api/include/wasm.h` is the standard header, installed verbatim next to our
library, and **180 of the functions it declares had no definition**. An embedder calling one got an
undefined-symbol link error (static lib) or a failed `dlsym`/`Deno.dlopen` (the DLL path — our actual
integration story, `vision.md`). Not "a missing feature": we advertised an API we didn't have.

**Now: 0 undefined — every function `wasm.h` declares is defined**, and
**`tests/c_abi_symbols.c` keeps it that way**. It takes the address of all 319 declared functions and
links into `zig build c-smoke`, so dropping one fails *our* build. Verified the gate actually fails by
un-exporting `wasm_table_grow` and watching c-smoke die on `undefined symbol: wasm_table_grow` — a gate
that can't fail is decoration. **Regenerate it after vendoring a new `wasm.h`** (command below); the
list must come from the *preprocessed* header, since `WASM_DECLARE_OWN/_VEC/_TYPE` generate most of the
API and a source grep misses them — which is exactly how this hid for months.

**What landed, and the one decision worth knowing:**
- **The ref object model.** `RefHeader` (tag + refcount + host_info) embeds in the 9 ref-able types;
  upcasts hand out `&obj.hdr`, downcasts recover it with `@fieldParentPtr` — no layout assumption,
  no allocation (the upcast is borrowed, so it *cannot* allocate). **`wasm_X_copy` refcounts rather
  than clones**, because `wasm_X_same(copy(x), x)` must be true: these are references. That also makes
  copy meaningful for an `Instance`/`Module`, which can't be deep-copied sensibly.
- **Type objects are the opposite** — values, so their `copy` really clones, and a vec copy must clone
  each element or two vecs free the same pointers.
- **`wasm_table_get`/`set`/`grow`** — deferred for months on "needs `wasm_ref_t`"; that blocker is gone,
  so they're implemented.
- **`wasm_module_serialize`** returns the original binary and `deserialize` re-decodes it. wazmrt
  interprets a decoded IR — there is no AOT artifact to emit, and a round-trip through the original
  bytes is honest and correct. **Cost: `wasm_module_new` now keeps a copy of the binary** (the decoder
  otherwise lets the input go). Paid only on the C ABI path, not the CLI.
- **`wasm_tagtype_t`** exists as a type object though EH is deferred: the header declares it and it's
  pure data. No module can produce one.
- ~86 ref functions and ~40 vec functions are **comptime-generated** from a table. That's the point:
  in that much near-identical bulk, a copy-paste slip (a `global` body under a `memory` name) compiles
  fine and stays invisible until an embedder hits it.

**Regenerate the gate after vendoring a new `wasm.h`:**
```sh
zig build                                   # produces zig-out/{lib,include}
printf '#include "wasm.h"\n' > pp.c
zig cc -target x86_64-windows-gnu -E pp.c -I zig-out/include -o pp.i   # expand the macros
grep -oE "\bwasm_[a-z0-9_]+[ ]*\(" pp.i | tr -d ' (' | sort -u > declared.txt
# then rebuild tests/c_abi_symbols.c from declared.txt (see its header comment)
```

**Left deliberately:** nothing in the header. `wasm_table_get` returns funcrefs only (an externref
table slot has no `wasm_ref_t` to hand back yet — it would need boxing at the host boundary); it
reports null rather than inventing a handle. Semantics, not a link break.

---

### Original report (kept for the "surfaces when" reasoning)

**Found how (reproducible — re-run this after any C ABI change):**
```sh
zig build                                   # produces zig-out/{lib,include}
printf '#include "wasm.h"\n' > pp.c
zig cc -target x86_64-windows-gnu -E pp.c -I zig-out/include -o pp.i   # expand the macros
grep -oE "\bwasm_[a-z0-9_]+[ ]*\(" pp.i | tr -d ' (' | sort -u > declared.txt
{ echo '#include "wasm.h"'; echo 'void *refs[] = {';
  while read n; do echo "  (void*)&$n,"; done < declared.txt;
  echo '}; int main(void){ return refs[0]==0; }'; } > audit.c
zig cc -target x86_64-windows-gnu audit.c -I zig-out/include -L zig-out/lib -lwazmrt -o audit.exe 2>&1 \
  | grep -oE "undefined symbol: [a-z_]+" | sort -u
```
Macro-generated declarations (`WASM_DECLARE_OWN`/`_VEC`/`_TYPE`) are why the header must be
**preprocessed** — grepping the raw header misses most of them, which is how this stayed invisible.

**Was 180; now 167** — Phase 4.1 defined the 13-symbol frame/trap-trace family (#19). The rest fall in
systematic families, mostly mechanical:
- `wasm_*_copy` / `wasm_*_same` / `wasm_*_get_host_info` / `wasm_*_set_host_info[_with_finalizer]` —
  the boilerplate every object type declares (~110 of the 167).
- `wasm_ref_as_*` / `wasm_*_as_ref` casts + `wasm_ref_delete`/`copy`/`same` — needs a real `wasm_ref_t`
  (already noted as deferred: it's what blocks `wasm_table_get`/`set`/`grow`, also on this list).
- `wasm_foreign_*`, `wasm_tagtype_*`, `wasm_module_serialize`/`deserialize`/`share`/`obtain`,
  `wasm_*type_new` constructors, `wasm_*_vec_copy`.

**Severity:** latent but real, and it fails at *link/load* time — the embedder can't work around it.
The reason it hasn't bitten: our own C client (`tests/c_smoke.c`) and `examples/deno_ffi.mjs` only use
what we implement, so nothing ever asked for the rest.

**Surfaces when:** any embedder written against the standard header rather than against our subset —
`universalWasmLoader-*`, wasmtk-via-FFI, or anyone porting wasmtime/wasmer code (`vision.md` makes all
three explicit goals). Four options were on the table: implement the mechanical families; `wasm_ref_t`
first; trim the header; or document the subset. **Resolution (owner's call, 2026-07-15): implement all
of it** — "a big hole we don't need to fall into" — done above, ahead of 4.2.

**The durable fix for the *class*:** make the audit a build step so a declared-but-undefined symbol
fails CI instead of an embedder's link. **Done** — `tests/c_abi_symbols.c`. That was the real lesson:
the gap existed since the C ABI landed and no test could see it, because every test only called what
we'd implemented.

**Anchor:** `src/wasm_c_api.zig` (all `export fn`s); `third_party/wasm-c-api/include/wasm.h`;
`tests/c_abi_symbols.c` (the gate).

## #19 — Traps carry no location: `trap: Unreachable` and nothing else — **DONE 2026-07-15 (Phase 4.1)**

**Was:** every trap surfaced as a bare `trap: <ErrorName>` — no function, no name, no pc. That gap is
what turned the Phase 3 `bitcast_invalid` diagnosis into hours.

**Now:** traps report a named backtrace, innermost frame first. The exact binary from that hunt:

```
trap: Unreachable
  at fn[31] <.Lfd_write|wasi_snapshot_preview1_bitcast_invalid> +0
  by fn[30] <min.main> +22
  by fn[33] <start.startWasi> +2151
```

**How:** `Frame` carries `func_index`; `Frame.run` has `errdefer self.inst.recordTrap(func_index, pc)`
— **`errdefer` emits code on the error path only**, so the dispatch loop is untouched and the trace
builds itself innermost-first as the error unwinds, with no plumbing through call sites. Frames land in
a **fixed `[16]TrapFrame` on `Instance`**: recording a trap must not allocate (we may be unwinding an
OOM) and must not fail. `trap_depth` keeps the true depth, so a truncated backtrace says so. Reset per
`invokeIndex`, so it always describes the latest failed call. Read via `trapFrames()`/`trapTruncated()`.
Names come from `Module.funcName` — decode keeps only the name section's function-name subsection
(§7.4.2), copied, and scans it **lazily**: a module that never traps pays one `dupe`. A malformed name
section degrades to "no names", never an error — it must not fail the report that is already reporting
a failure.

**Also through the C ABI (added 2026-07-15, same phase).** `wasm.h` *declares* `wasm_trap_origin`,
`wasm_trap_trace` and the whole `wasm_frame_*` family — we defined none of them, so an embedder
following the header got a **link error**. That was mis-recorded here first as "the trace isn't
surfaced yet," i.e. a missing nicety; it was a broken promise in a header we ship. Now implemented
(13 symbols) and covered by `tests/c_smoke.c`, which deliberately traps and walks the backtrace. Byte
offsets are real: the C test asserts `trapmod[module_offset]` is the actual `unreachable` byte, so a
plausible-looking-but-wrong offset fails the build. The broader header gap is **#20**.

**Verified:** 6 unit tests (111 total) — innermost-first ordering with exact pc; deep recursion
truncating at 16 with `trap_depth = 41`; reset between invokes; name lookup incl. gaps/past-the-end and
a truncated section; and byte offsets on a body where pc and offset *diverge* (a multi-byte LEB pushes
`unreachable` to pc 2 / byte 4), so an IR index couldn't pass by coincidence. Plus the real guest and
the C client.

**Performance — the interesting part.** The first cut regressed steady-state **14%** (262 → 224
Mops/s, reproducible). The cause was not what it looked like: nothing on the hot path changed. The
`errdefer` in `Frame.run` expands at every `try` in a ~200-arm switch, so a slightly bigger
`recordTrap` inlined into hundreds of landing pads and pushed the loop out of i-cache. `noinline` on
`recordTrap` fixed it *and* beat the baseline — **288 Mops/s, +10% over HEAD** — because 4.1 had been
inlining it too. Cold-start likewise ended up *better* (0.86 vs 0.90 us/run) once offsets went lazy.
Both are now invariants in `design-decisions.md`. **Lesson: a hot-path regression can come from an
error path.** Bisect against a same-session baseline; do not trust a recorded number from another day.

**Anchor:** `Frame.run`'s `errdefer` + `Instance.recordTrap`/`trapFrames`/`frameOffset`
(`src/interp.zig`); `Module.funcName`/`findFuncNameSubsection` + `Code.body_offset` (`src/Module.zig`);
`opcode.decodeBodyTracked`; `printTrap` (`src/main.zig`); `makeTrapFrom` + the `wasm_frame_*` exports
(`src/wasm_c_api.zig`).

## #18 — Zig 0.16 std bug: `openFile(.follow_symlinks=false)` on Windows crashes the host — WORKED AROUND (2026-07-15)

**What (std's bug, not ours):** `Io.Dir.openFile` opens the handle **ASYNCHRONOUS** when
`follow_symlinks = false` but still returns `.flags = .{ .nonblocking = false }`
(`Threaded.zig:5033` — the only conditional `.IO =` in the file). The first `readPositional` then takes
the synchronous branch and hits `.PENDING => unreachable` **inside std**, killing the *host* process,
not the guest. `createFile` is unconditionally `SYNCHRONOUS_NONALERT`, which is why only the
open-an-existing-file path crashed and `path_open` with `O_CREAT` looked healthy.

**Our workaround:** `wPathOpen` implements O_NOFOLLOW itself — `statFile(.follow_symlinks=false)`, return
`ELOOP` if the final component is a symlink — then always opens *with* follow, since no link remains to
follow. Same observable semantics, no async handle. Minor TOCTOU between the stat and the open;
acceptable versus crashing.

**Contained:** the other two `.IO = .ASYNCHRONOUS` sites are `dirReadLinkWindows` (an internal
reparse-point handle we never read from; `path_readlink` is `NOTSUP` here) and `openSocketAfd` (sockets,
which correctly set `nonblocking = true`). No other file path can reach the mismatch.

**Surfaces when:** **upgrading Zig.** If std fixes it, drop the pre-stat and pass `.follow_symlinks`
straight through; if std changes shape around it, recheck before assuming the workaround still holds.
Re-run `examples/wasi_files.zig` — "fd_read round-trips the contents" is the check that fails.

**Anchor:** the `if (!follow)` pre-stat in `wPathOpen`, `src/wasi.zig`.

## #17 — WASI sandbox: a symlink out of a preopen was followed — **DONE 2026-07-16**

**Was:** `wasi.resolve()` is lexical — it stops a guest *naming* a path outside its preopen, but not a
**symlink stored inside the preopen whose target is outside it**. `follow_symlinks = false` only guards
the final `openat` component, so an intermediate symlink (`dirlink/secret.txt` where `dirlink ->` an
outside dir) was followed straight out. **Proven** with a real NTFS symlink: the pre-fix build printed
`ESCAPED via intermediate dir symlink`, reading a file outside the preopen.

**Now: filesystem-level containment via a handle-based component walk** (`walkTo` + `finalIsSymlink` in
`src/wasi.zig`). Two layers:
1. lexical `resolve` (unchanged) — absolute / escaping-`..` / NT-device / NUL rejected up front;
2. **descend one component at a time**, opening each relative to the previous *handle* (TOCTOU-safe —
   the handle pins the inode; we never re-walk a path string) with `follow_symlinks = false`, and a
   post-open `stat` rejects anything that isn't a real directory. On POSIX, `openat(O_NOFOLLOW)` on a
   symlink fails outright (ELOOP); on Windows it can open the reparse point, which the post-open stat
   then catches (`kind == .sym_link`). A **final-component** symlink is refused by any op that would
   follow it (`path_open`, `path_filestat_get` with `SYMLINK_FOLLOW`).

**Policy: no symlink is ever traversed.** A guest can't create one (`path_symlink` unimplemented), so
every symlink in a preopen is host-placed — the attack — and refusing it is the safe default.
In-sandbox symlink traversal is unsupported; relax to target-revalidation only if a real guest needs it
(that's why `path_symlink`/`path_readlink` sit behind this at 4.3 — they'd change this policy).

**Residual (documented, narrow):** a TOCTOU window on the *final* component of `path_open` only — we
stat it no-follow then open with follow, because `openFile(.follow_symlinks = false)` crashes the host
on Windows (std bug #18). A swap in that window needs write access *inside* the sandbox and a race; the
intermediate walk (the actual reported hole) has no such window. Closing it fully needs #18 fixed
upstream, or a real `openat2(RESOLVE_BENEATH)` in `Io`.

**Verified:** before/after with a real symlink via `examples/wasi_symlink_escape.zig` (pre-fix ESCAPED,
post-fix all-refused, in-sandbox file still readable); a unit test in `src/wasi.zig` that plants a real
symlink and drives the path ops (runs on POSIX CI, **skips on unprivileged Windows** — Zig std's Windows
symlink uses raw `FSCTL_SET_REPARSE_POINT`, which needs `SeCreateSymbolicLinkPrivilege`); Phase 3 file
gate still 16/16 (no over-restriction).

**Anchor:** `walkTo`/`finalIsSymlink`/`resolveArg` + the module doc in `src/wasi.zig`;
`examples/wasi_symlink_escape.zig`.

## RESOLVED 2026-07-09 (second pass — commit `645874c`)

Adding `assert_invalid`/`assert_malformed`/`assert_exhaustion` to the WAST runner made the
soundness gaps observable, so they were fixed together:
- **#5 DONE** — `assert_trap` now accepts only a genuine runtime trap (`isRuntimeTrap`).
- **#7 DONE** — const-expr `global.get` restricted to a prior *immutable* global.
- **#2a/#2b/#2c/#2d DONE** — untyped `select` rejects ref operands; `select_t` needs a 1-type
  annotation; load/store require a memory + alignment ≤ natural; `if`-without-`else` needs
  params == results. Also added: global-init const-expr validation, element-segment validation,
  and `call_indirect` table-exists + funcref-typed checks.
- **#6 PARTIAL** — reserved global-mutability / limits-flag bytes now rejected (`MalformedFlag`);
  the invalid *valtype* byte (non-exhaustive `ValType` `@enumFromInt`) is still accepted.
- **#1 PARTIAL** — top-level `(import … (global …))` is now assembled; func/table/memory imports
  error honestly instead of being dropped (still need real host imports).
- **#8 DONE** — `align=` over-natural is now a validation error (the assembler still doesn't reject a
  non-power-of-two `align=` literal, but no test exercises that path).

Third pass (commit `c535de0`):
- **#2e DONE** — `ref.is_null` rejects a non-reference operand.
- **#6 DONE** — the decoder validates value-type bytes (`readValType` / `ValType.isValid`) in func
  types, table element types, global content, and locals (reserved mutability/limits bytes were
  already rejected). The `select_types` / `ref.null` heaptype immediates in `opcode.zig` are still
  unvalidated, but those are instruction-level, not module structure.
- **#2f NOT A BUG** — investigated and closed: the `pop_vals`/`push_vals` chain already cross-checks
  `br_table` label *value types* (not just arity) even in polymorphic code. Verified empirically —
  different-typed labels are rejected, same-typed accepted. No change needed.

**The 2026-07-09 audit ledger is FULLY cleared (2026-07-13): every item #1–#16 is resolved.** No open
correctness/soundness/dead-code/spec-strictness items remain. The real frontiers are now new *features*,
not ledger debt: growing the wasm-c-api past introspection (instance/func/call), and **WASI preview 1**
(in scope; preview 2/3 deferred until browser-standard, mirroring wasmtk). Since cleared: WAST-runner
invoke-by-module-name (`9745ecb`, `linking.wast` 29 → 100) and the **function-references proposal**
(P1/P2/P2.5 — typed-ref value types, `call_ref`/`ref.as_non_null`/`br_on_null`, non-null refs +
local-init; ~+130 ref-file passes, `func` 171/0). Remaining frontier proposals (the main sources of the
rest of the `.wast` failures): **full GC (WasmGC — the NEXT major increment per the owner, ahead of the
C-ABI/benchmark work)** — i31/struct/array heap objects, `ref.test`/`ref.cast`; then **multi-memory**
(`start0`) and exception-handling **tags** (`imports`), pulled in as the corpus demands. A residual limitation: concrete typed refs (`(ref null $t)`)
collapse to `funcref` in the untyped-slot model, so a general funcref passed where a specific `(ref $t)`
is expected isn't caught (`local_tee` 96/1).

## Grouped by the integration that trips them

- **`register` / multi-module linking + imported functions** (host imports → WASI): #1 **DONE — all
  three stages** (2026-07-13). Stage 1 imported funcs + register; stage 2 imported tables/memories via
  shared `Memory`/`Table` objects; stage 3 link-time import type-checking + `assert_unlinkable`. #4
  (non-spectest imported global → 0) **also resolved** by stage 3. Only #10 (global index order, LOW)
  remains in this group. `imports.wast` 26 → **132**.
- **`assert_invalid` / `assert_malformed` support in the WAST runner**: #2, #6, #7, #8 — **all DONE**.
  These were *soundness / spec-strictness* gaps; the runner now executes the negative tests.
- **Start-function support**: #3 **DONE** (`07dd244`).
- **Host externref values** (embedding API passes real externrefs): #9 **DONE** (`994ee23`) — externrefs
  are boxed to non-sentinel handles.
- **Arbitrary / hand-written WAT** (beyond the testsuite's shape): #10 **DONE** (`3a50f75`, import-after-
  def rejected); #12 (const-expr section ordering) **DONE** (`e500a51`); #8 (`align=` non-power-of-two)
  **DONE** (`00bceb4`); #11 (defined-table inline `(export …)`) **DONE** (`ff3de4a`).
- **Test fidelity, always-on**: #5 (`assert_trap`) **DONE**.
- **Dead code / duplication**: #13 **DONE** (`78647f6`).

---

## The list

### #1 — Host imports / `register` — **DONE, all three stages (2026-07-13)**
- **Stage 1 (`bcf3a11`)** — imported **functions** + **`register`**: `Instance.HostFunc`
  (`wasm{instance,func_index}` | `native fn`) dispatched from `callFunction`; the WAST runner keeps a
  module registry; the assembler emits the import section for top-level/inline func imports.
  `func_ptrs` 29/2 → 32/0.
- **Stage 2 (`78c6b2b`)** — imported **tables & memories** as shared objects. Linear memory and tables
  became `*Memory{bytes,max}` / `*Table{entries,max}`: a defined one is owned/freed by its instance, an
  imported one (low indices) borrows a host-supplied object and is left alone at deinit. `memory.grow` /
  `table.grow` mutate the shared object in place so importers observe the new size. The runner backs
  `spectest.memory` (1 page, max 2) and `spectest.table` (10 funcref, max 20); the assembler emits
  `(import … (table|memory …))` (kinds 0x01/0x02) with imports taking the low indices. `data` 31 → 34/0,
  `elem` 47 → 52.
- **Stage 3 (`1d6d9f2`)** — link-time **import type-checking** + `assert_unlinkable`: funcs by exact
  signature, globals by content+mutability, tables/memories by element type + limits subtyping
  (`limitsFit`). Unknown name → `UnresolvedImport`; type mismatch → `IncompatibleImportType`;
  `assert_unlinkable` passes iff building fails with such a link error. `imports.wast` 44 → **132/32/7**.
**Remaining imports/linking failures are separate feature gaps** — invoke-by-module-name (the runner's
`invoke` only targets the current module), inline `(table (export …) …)` (#11), tag imports, memory64 —
and `(start …)` (#3, still dropped). `linking.wast`/`memory.wast` complete only under ReleaseFast (debug
is too slow on their large grow tests), 19/84 and 66/13.

### #2 — Validator over-acceptance (soundness) — MED
`src/validate.zig` — several rules accept invalid modules. Not a wrong-output risk (execution traps
safely); purely "should have been rejected at validation."
- **2a** untyped `select` (0x1b) accepts reference-typed operands (spec: numeric/vector only). `step`
  `.select, .select_t` (~264).
- **2b** `select_t` (0x1c) ignores its `select_types` immediate — never checks operands against the
  annotation, and for polymorphic (`unknown`) operands pushes `t1`/`t2` instead of the annotated type.
- **2c** load/store validated without requiring a memory section (and alignment never checked). A
  module with `i32.load` but no memory **passes validation**, then traps at runtime with `NoMemory`.
  When fixing, account for *imported* memory (`module.memories.len` includes imports).
- **2d** `if` with params but no `else` doesn't enforce `params == results`.
- **2e** `ref.is_null` pops any operand, not just a reference type.
- **2f** `br_table` cross-label check is arity-only; in stack-polymorphic (post-`unreachable`) code,
  labels with equal arity but different value types aren't rejected.
**Surfaces when:** the WAST runner implements `assert_invalid` (today those commands are `skipped`, so
the gaps are invisible). **Fix:** tighten each rule; verify against the `*.wast` `assert_invalid`
blocks once the runner supports them (and re-baseline — stricter validation could reject a module that
currently builds if the check is wrong).

### #3 — Start function — **DONE (`07dd244`, 2026-07-13)**
Implemented end to end: `Module.decode` reads the start section (id 8) into `start: ?u32`; `validate`
checks the start func exists and has type `[] → []` (`UndefinedFunc` / `InvalidStartFunction`);
`interp.Instance.runStart()` runs it (no args) right after instantiation — called by the WAST runner and
CLI, so a trap during start fails instantiation; the assembler emits `(start $f|N)` as section 8. Also
added the `(memory (data "…"))` abbreviation and inline `(memory (import …))` / `(table (import …))`
imports (the memory export-skip loop had silently mis-parsed an inline import as a *defined* memory).
`start.wast` 0 → **11/0/0**, `imports` 132 → 137, `memory` 66 → 69. **Out of scope:** `start0.wast`'s
3 fails are the **multi-memory** proposal (memory-indexed loads `i32.load8_u $n` on a >1 memory space).

### #4 — Non-`spectest` imported global silently defaults to 0 — **RESOLVED (`1d6d9f2`, #1 stage 3)**
`resolveGlobalImport` now resolves a global import to a registered module's exported global (its live
value from the exporting instance) or a known `spectest` global, and errors (`UnresolvedImport` /
`IncompatibleImportType`) instead of defaulting to 0. The type is checked (content + mutability) too.

### #5 — `assert_trap` fidelity — **RESOLVED (`645874c`, extended `c0c7de2`)**
`src/wast.zig` `assertTrap` now accepts only a genuine runtime trap (`isRuntimeTrap` — an
assemble/decode/`UnsupportedInstr` error no longer green-washes as a trap). The `c0c7de2` pass added the
`assert_trap (module …)` form: it builds the inner module in isolation and requires an
instantiation-time runtime trap (e.g. an out-of-bounds active data/element segment). Matching the
expected trap *text* is still not done (LOW — no test depends on it).

### #6 — Invalid value-type bytes decode silently — MED/LOW
`src/Module.zig` (`readValTypes`, `readTableType`, `readGlobalType`, `decodeLocals`) and `src/opcode.zig`
(`select_types`, `ref_type`) use `@enumFromInt(byte)` into the **non-exhaustive** `types.ValType`, so a
garbage byte becomes an out-of-range enum with no `error.BadValType` (contrast `ExternKind`/`SectionId`,
which *do* guard). **Surfaces when:** `assert_malformed` support, or any untrusted/fuzzed binary input.
**Fix:** validate the byte against the known valtypes on decode.

### #7 — const-expr `global.get` more permissive than spec — LOW
`src/interp.zig` — `evalConstExpr` allows `global.get` of any *prior* global; §3.3.7 restricts
const-expr `global.get` to *imported* globals. Bounds-checked, so no crash/wrong-value — a strictness
gap only. **Surfaces when:** `assert_invalid` support.

### #8 — `align=` non-power-of-two silently `@ctz`'d — **RESOLVED (`00bceb4`, 2026-07-13)**
`emitMemArg` now rejects a zero or non-power-of-two `align=` with `error.BadImmediate` before the
`@ctz` (§6.5.8), instead of encoding a bogus log2 (`align=3` → 0, `align=0` → 32). No conformance delta
(the testsuite's `align=0`/`align=7` cases arrive via `(module quote …)`, still `BadCommand`); verified
directly + new `expectInvalid` unit cases. Over-natural alignment was already a validation error.

### #9 — externref/`null_ref` sentinel collision — **RESOLVED (`994ee23`, 2026-07-13)**
The value stack is untyped `u64` with `null_ref = maxInt(u64)`; a host externref payload could equal it
and be misread as null. The WAST runner is the sole minter of externref values (`(ref.extern N)` is a
runner literal, not an instruction), so the fix is contained there: it interns each payload into a
per-run pool and represents an externref as its pool *index* (a small integer, never the sentinel).
Equal payloads intern to the same value, so an externref round-trips and compares equal. `parseConst`/
`matches` became Runner methods; funcref values still use their index directly. New wast.zig unit test
proves `(ref.extern 0xFFFFFFFFFFFFFFFF)` is non-null and round-trips.

### #10 — import-after-definition mis-indexing — **RESOLVED (`3a50f75`, 2026-07-13)**
The assembler built func/table/global name→index maps in textual order, but the binary places imports
first; a def-before-import module (malformed per §6.6.13, and the testsuite has `assert_malformed`
"import after function/global/table" for it) was silently mis-indexed. `assembleModule` now tracks
whether any func/table/memory/global definition has been seen and rejects a later import (top-level or
inline) with `error.ImportAfterDefinition` (small `fieldIsImport`/`isDefKind` classifiers). **Enforce,
not reorder** — reordering would wrongly accept the malformed cases. No conformance delta (the
testsuite's cases arrive via `(module quote …)`, still `BadCommand`); new wat.zig unit test + verified
valid imports-first resolves correctly.

### #11 — inline `(table (export …) …)` on a *defined* table — **RESOLVED (`ff3de4a`, 2026-07-13)**
`parseTable` now skips and registers leading inline `(export "x")*` forms (kind 1, current table index)
after the optional `$id`, mirroring `parseGlobal`; the imported-table case was already done (`07dd244`).
No-op for tables without an inline export, so every core file is byte-identical; modules using the form
previously failed to assemble (no passing assertion to lose) and now build: `imports` 137/31 → **137/17**
(14 fewer build failures), `linking` 19/84 → **29/108** (+10 passes), `elem` 52/15 → **52/26** (passes
stable; the new failures are newly-run assertions hitting *other* gaps — typed refs / value-literal
parsing). New wat.zig unit test.

### #12 — const-expr sections encoded after the type section — **RESOLVED (`e500a51`, 2026-07-13)**
The type section (1) was emitted before the global (6), element (9), and data (11) sections, which
encode const-exprs against the same live `sigs` list — safe only because const-exprs can't intern a
signature. Extracted `encodeGlobalSection`/`encodeElementSection`/`encodeDataSection` and call them right
after the function bodies are pre-encoded (before the type section), so any interned signature lands in
section 1 by construction. Pure reordering — output byte-identical, full regression sweep unchanged.

### #13 — Dead code / duplication — **RESOLVED (`78647f6`, 2026-07-13)**
- `validate.zig`'s `funcTypeOf` was a byte-for-byte duplicate of `Module.funcType` — deleted, the four
  callers now use `module.funcType`. Also changed `Module.funcType` to a `*const Module` receiver so it
  no longer copies the whole Module struct by value per call.
- `main.zig`'s `runFunction` re-resolved the export `invoke` resolves again — added
  `Instance.invokeIndex(func_index, args)` (invoke delegates to it) and main calls it with the index it
  already has.
- **Stale/kept:** `Imm.select_types`' payload IS read now (the validator checks the annotation, #2), so
  it is not dead; `Imm.mem_reserved`'s byte is retained deliberately (documents the reserved wire byte,
  leaves room to validate it must be 0).

## Discovered 2026-07-09 (while adding assert_invalid support)

### #14 — `func.wast` returns a wrong result (`got 0x2a` = 42) — **RESOLVED 2026-07-09 (`0409f37`)**
Root cause: a function declaring its signature via `(type $t)` (not inline `(param …)`) never added the
type's params to the assembler's local name/index space, so a declared `(local $x)` resolved to the
param's index. `(func (type $sig) (local $var i32) (local.get $var))` returned the param (42) instead
of the uninitialized local (0). Fixed in `assembleModule`: prepend anonymous local names for the
type's params (bounds-checked against `sigs`). `func.wast` 169/2 → **171/0**.

### #15 — Element init expressions + bulk table ops + data offsets — **DONE 2026-07-13**
Landed in four passes:
- **Element init expressions (`82d0213`, `4ffa2e8`)** — the const-expr element form
  (`(elem … funcref (ref.func $f) (ref.null func) …)`, incl. `(item …)`), all 8 segment flag variants,
  and const-expr offsets, across assemble/decode/validate/instantiate. `elem.wast` 3/54 → 38/28.
- **Bulk table ops (`b256a86`)** — `table.init`/`table.copy`/`elem.drop` (`0xFC` 0x0c/0x0e/0x0d) end to
  end, plus runtime passive-element storage (each segment evaluated to `[]Value` with an `elem_dropped`
  flag; active/declarative dropped after init, passive kept). `table_init` 67 → **729/0/0**, `table_copy`
  120 → **1649/0/0**. Assembler tracks element-segment names (`elem_names`) and a shared
  `emitBulkTableImm` handles the text→binary operand-order swap (`table.init tableidx? elemidx` encoded
  elem-then-table).
- **Table initializer expressions (`6087eac`)** — inline const-expr table elems
  (`(table reftype (elem (ref.func $f) …))`) and `(table N reftype initexpr)`, the latter lowered to an
  active elem of N copies at offset 0 (observably identical; the 0x40 binary form isn't needed for
  execution assertions). `table.wast` 15 → 17, `global.wast` 108 → 109.
- **Const-expr data offsets (`c0c7de2`)** — `(data $id? (memory idx)? offset? "bytes"…)`; the offset is
  any leading list (`(offset …)` / folded `(i32.const N)` / `(global.get $g)`), absent → passive.
  Offsets emit through the shared const-expr path; added active-data-offset validation (memory presence
  + i32 offset). `assert_trap (module …)` now requires a genuine instantiation-time trap. `data.wast`
  12 → **31**, `elem.wast` → **47**.
Two bugs fixed en route: (1) the generalized data assembler mis-parsed non-`i32.const` offsets as
*passive* (offset silently dropped) — any leading list is now the offset so the validator can reject
bad ones; (2) const-expr `global.get` scope — active-segment **offsets** (data + element) may reference
any immutable global, but ref-producing element exprs / table initializers stay imported-globals-only
(matches data.wast:89 valid *and* global.wast:674 `"unknown global"`). **Remaining `data`/`elem`
failures are all imported memories/tables → #1 stage 2, not #15.**

### #16 — Decoder is lenient on malformed binaries — **LEB PART DONE (`10aca3b`); rest LOW**
**Done:** the LEB128 readers (`readVarU32`/`readVarI32`/`readVarI64`) are now spec-correct — accept
valid encodings up to the max width, reject over-long AND "integer too large" (final-byte overflow/sign
bits). This also fixed a real bug rejecting *valid* 10-byte `i64.const` modules (`skipConstExpr` skipped
i64 operands with a 5-byte cap). `binary-leb128.wast` 36/25 → **56/3**. New `skipLeb(max_bytes)` for
width-aware operand skipping.
**Part 2 done (`3321921`):** custom-section names are now validated (an empty/nameless or over-long-name
custom section is rejected, §5.5.3), and the **data-count section** (id 12) is decoded and checked
against the data-segment count (`DataCountMismatch`, §5.5.16). `custom.wast` 5/3 → **8/0**;
`binary-leb128.wast` → **58/1**. **Malformed-binary over-acceptance is now ~zero** across the
negative-conformance files.
**Still open (feature gaps, NOT malformed-handling):** `binary-leb128` (1) and `names.wast` (1) fail
with `UnsupportedInstr`/`UnsupportedOpcode` — valid modules using an op/instruction the
assembler/decoder doesn't support yet, unrelated to #16. #6's valtype-byte check for *instruction
immediates* (`select_types`/`ref.null` heaptype in `opcode.zig`) also remains, but is instruction-level,
not module structure.
