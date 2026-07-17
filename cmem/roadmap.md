# Roadmap

## Status (2026-07-02) — runtime executes; text toolchain in progress

The full pipeline runs end-to-end: **decode → validate → execute** (int/float/memory), verified on the
real `module/wasm_mod` corpus against its `.test.json` values. A native **WAT text assembler** is done;
the **WAST script runner** (`wast.zig`) is next.

**Done:**
- **Runtime pipeline** — `Module.decode` (all core sections + resolved import/export types + bodies) →
  `opcode.zig` IR → `validate.zig` (spec type-check) → `interp.zig` (switch interpreter: i32/i64/f32/f64
  arithmetic, control flow, `call`, linear memory + data init, traps). Runs `fib(20)=6765`,
  `fac(7)=5040`, `sieve(30)=10`, etc. — all match `.test.json`.
- **Text toolchain** — `sexpr.zig` + `wat.zig` (WAT→wasm binary) + **`wast.zig` (WAST runner)**. Runs
  the **official spec testsuite** via `wazmrt <file.wast>`, both positive *and* negative conformance
  (`assert_invalid`/`assert_malformed`/`assert_exhaustion`; `assert_trap` gated on a real trap).
  Reference types, multi-table, imported globals, extended-const, reference-type table ops, element
  init expressions, and **imported functions + `register`/module-linking** all land; the
  validator/decoder correctly reject invalid/malformed modules (2026-07-09 post-audit).
  Representative: i32 **459/0**, i64 **415/0**, block **222/0**, if **240/0**, call_indirect **169/0**,
  select **154/0**, func **171/0**, align **140/0**, custom **8/0**, binary-leb128 **58/1**, elem
  **38/28**, func_ptrs **32/0**, table_copy **120**, table_init **67**, global 108/2 (see `testing.md`).
  **65 unit tests.** Remaining gaps: imported **tables/memories** (`imports.wast` 26/56), bulk table ops
  (`table.init`/`.copy`/`elem.drop`), passive element segments.
- **Licensing baseline** (git `888b87e`): dual `MIT OR Apache-2.0` (`LICENSE-MIT` + `LICENSE-APACHE`),
  `NOTICE`, and the compliance scaffold `third_party/LICENSES.md` (obligations table + Adoption
  Checklist + Component Ledger + verified SPDX inventory). README license section + SPDX + contribution
  clause. See `licensing.md`, `reference-projects.md`.
- **First runtime vertical slice**: Zig 0.16 project reshaped from `zig init` into a runtime skeleton.
  `Reader` (zero-copy + LEB128) + `Module` (header validate + section index). 7 unit tests passing.
- **Three build surfaces wired**: native CLI, C-ABI static lib, freestanding-wasm build. All
  build/test/run verified (see `design-decisions.md`).
- **C ABI = the standard wasm-c-api** (decision + slices, 2026-07-02): vendored `wasm.h` (Apache-2.0,
  first ledger entry); implemented `config`/`engine`/`store` + byte vecs + `wasm_module_new`/`_validate`/
  `_delete`, **plus `wasm_module_imports`/`exports` and the full type-object system** (valtype/functype/
  externtype/global/table/memory/importtype/exporttype) in `src/wasm_c_api.zig`; extension header
  `include/wazmrt.h`. **Verified from C** via `tests/c_smoke.c` (zig cc) — enumerates a module's import
  (`env.add`) and export (`run`, params=2 results=1). Retired the ad-hoc `wazmrt_module_*` ABI.
- **cmem/ project memory** established (this folder), mirroring the wasmtk setup.

**Remaining (in owner-set order):** **(1) full GC — P3, IN PROGRESS** (WasmGC: i31 → struct/array →
`ref.test`/`ref.cast`/`br_on_cast`; browser-standard, so in scope; owner directive 2026-07-13 puts it
*ahead* of the C-ABI/benchmark work — build in tested parts). **i31 slice DONE 2026-07-14** (`0f1e0c2`):
distinct `any`-hierarchy value types with real subtyping (`types.RefHeap.sub`), unboxed i31 in the `u64`
slot, `ref.i31`/`i31.get_s`/`i31.get_u` under `0xFB`. **struct/array slice DONE 2026-07-14** (`bec0cf7`
type-space refactor + runtime): `Module.func_types`→`comp_types` composite-type table (func/struct/
array + rec/sub/packed decode with a forward-ref kind pre-scan); an arena-backed GC heap
(`Instance.gc_heap`, no collector yet); `struct.new`/`new_default`/`get`(`_s`/`_u`)/`set`, `array.new`/
`new_default`/`new_fixed`/`get`(`_s`/`_u`)/`set`/`len`, `ref.eq`; WAT assembler parses `(type (struct/
array/field …))`. **`ref.test`/`ref.cast` slice DONE 2026-07-14**: heap objects carry an RTT
(`HeapObject.type_index`), i31 values are tagged (bit 63) so the `any` hierarchy is runtime-
distinguishable, `ref.test`/`ref.cast` dispatch on the target's hierarchy (abstract via `RefHeap.sub`,
concrete via `Module.isSubtype`); `CastFailure` traps. **`br_on_cast`/`br_on_cast_fail` slice DONE
2026-07-14** (`0xFB` 0x18/0x19; peek-ref + `refMatches` + `branch()`; validation checks `dst <: src`
and the label carry type; block-type decoder extended for non-null tags). **WasmGC op coverage is now
complete** (i31, struct, array, `ref.eq`, `ref.test`/`ref.cast`, `br_on_cast`/`br_on_cast_fail`).
**Assembler `(sub $super …)` supertype emission DONE 2026-07-14** — declared subtyping round-trips.
**Concrete `(ref $t)` value types DONE 2026-07-14** — `ValType` widened to `enum(u32)` (concrete refs in
the high bits); `(ref $t)` flows with its exact type through params/fields/locals/globals; producers push
concrete refs; `subtypeOf` uses `Module.isSubtype` for concrete↔concrete; `ref.null` takes a heap type.
The **collapse limitation is resolved** (see `design-decisions.md`). **P3 / full GC is COMPLETE** — every
WasmGC op + the full type system + concrete refs + declared subtyping, all tested. 95 unit tests +
`gc_struct_array.wast` 11/0 + `gc_cast.wast` 11/0 + `gc_br_cast.wast` 4/0 + `gc_subtype.wast` 5/0 +
`gc_concrete.wast` 2/0. **(2) wasm-c-api — instantiate + call slice DONE 2026-07-14**: `wasm_val_t` +
val/extern vecs, `wasm_instance_new`/`exports`/`delete`, `wasm_extern_*`/`wasm_func_*` (shared `Ref`;
`as_func`, `param_arity`/`result_arity`, `wasm_func_call`), `wasm_trap_new`/`message`/`delete`. A C
consumer now decodes → instantiates → gets exports → **calls an exported function and reads the result**
end-to-end (`tests/c_smoke.c`, run by `zig build c-smoke`: `add(40,2)=42`). **Host-function import wiring
DONE 2026-07-14**: `wasm_func_new[_with_env]` + `wasm_functype_new` + `wasm_valtype_vec_*`; a new interp
`HostFunc.native_env` variant + a C `hostTrampoline` bridge a module's func import to a C callback
(`error.HostTrap` on a returned trap). Verified: a module whose body is `call $env.add` returns
`run(40,2)=42` through a host callback. **Global/table/memory runtime objects DONE 2026-07-14**:
`wasm_global_new`/`get`/`set`/`type`, `wasm_memory_new`/`data`/`size`/`grow`/`type`, `wasm_table_new`/
`type`/`size`, all extern↔object casts, and import wiring for globals (value-copy) / memories+tables
(shared object). Verified from C: read/write an exported global, `store` into an exported memory then
read it back via `wasm_memory_data`, and `wasm_memory_grow`.

**The C ABI is now COMPLETE against the header (2026-07-15, `known-issues.md` #20).** Every one of the
**319** functions `wasm.h` declares is defined — it had been **180 short**, a link error for any
embedder following the header, invisible because our own tests only called what we implement.
`tests/c_abi_symbols.c` references them all and links into `c-smoke`, so a dropped symbol now fails our
build. Landed with it: the `wasm_ref_t` object model (refcounted `copy`, `same`, `host_info` +
finalizers, checked casts), **`wasm_table_get`/`set`/`grow`** — the long-deferred item, unblocked the
moment `wasm_ref_t` existed — type-object constructors/copies, `wasm_foreign_t`, `wasm_tagtype_t`
(type object only; EH stays deferred), and module serialize/deserialize/share. **Still deferred:**
shared-mutable imported globals; and `wasm_table_get` hands back funcrefs only (an externref slot has
no `wasm_ref_t` to return without boxing at the host boundary — it reports null rather than inventing
one). **First host-FFI integration DONE
2026-07-14**: `zig build dll` builds the C-ABI as a **shared library** (`wazmrt.dll`, libc-free), and
`examples/deno_ffi.mjs` (run by `zig build ffi-demo`) has **Deno `Deno.dlopen` the DLL and drive the
standard wasm-c-api** (decode → instantiate → call) → `answer()=42`. This validates the vision's
"native FFI → the C-ABI shared library" path (the `universalWasmLoader-*` ports themselves are WIT/
component-model + wasmtime-based, so they're a separate, larger effort). **(3) Deno/V8 benchmark — first
measurement DONE 2026-07-14** (`zig build bench` + a documented cross-process run; see `testing.md`):
native wazmrt beats Deno/V8 on **cold-start wall-clock — 2.4× on a trivial call, 1.5× on `sum(1e6)`** —
because Deno pays ~110 ms of V8 init + JIT + JS marshalling every run while wazmrt's own work is
sub-µs to tens-of-ms. Steady-state hot-loop throughput ~264 Mops/s (a JIT wins that regime — the
Option A→B trigger). **The vision's core thesis is confirmed: win short-lived / native FFI, lose
sustained hot loops.**
**(3)** the Deno/V8 benchmark. **(4) WASI preview 1 — first slice DONE 2026-07-14** (preview 2/3 deferred
until browser-standard, per wasmtk): `src/wasi.zig` implements the core `wasi_snapshot_preview1` host
imports — `fd_write` (stdout/stderr), `fd_read`/`fd_close`/`fd_seek`/`fd_fdstat_get`/`fd_prestat_get`,
`args_sizes_get`/`args_get`, `environ_sizes_get`/`environ_get`, `clock_time_get`, `random_get`,
`sched_yield`, `proc_exit` — with a `NOTSUP` stub for the rest, so a command module instantiates and
runs. No interpreter changes: WASI is just native host imports (`HostFunc.native_env`) whose `memory`
pointer is filled in post-instantiation. The **CLI runs command modules**: `wazmrt <file>` (or `.wat`,
now assembled by the CLI) sees the exported `_start`, wires WASI, and runs it; `proc_exit` unwinds via
`HostTrap` carrying the exit code. Verified end-to-end: `examples/hello_wasi.wat` → `hello from wasi`,
exit 0; +3 unit tests (98 total). **Deferred:** the filesystem (`path_open`, preopened dirs), stdin
(`fd_read` reports EOF), sockets, `poll_oneoff`. **The function-references proposal is complete** (typed-ref value types, `call_ref`/
`return_call_ref`/`ref.as_non_null`/`br_on_null`, non-null refs + local-init tracking, P1/P2/P2.5
2026-07-13 — ~+130 ref-file passes). (The WAST runner's invoke-by-module-name landed `9745ecb` —
`linking.wast` 29 → 100.) **Start function (#3) DONE 2026-07-13; the 2026-07-09
audit ledger is now FULLY cleared — every item #1–#16 resolved** (externref boxing #9, import-after-def
rejection #10, const-expr section ordering #12, dead-code cleanup #13, non-power-of-two `align=` #8,
defined-table inline export #11). Still **100% original runtime code** — no
reference-project code adopted yet (only the vendored `wasm.h`). `call_indirect` + tables + globals +
type-ref block types + **reference types** + **multi-table** + NaN-payload float literals + **imported
globals** + extended-const + **reference-type table ops** + **negative-conformance + validator/decoder
strictness** + **element init expressions** + **imported functions + `register`** (host imports stage 1)
**DONE 2026-07-09**. **Bulk table ops + passive elements + table initializer expressions +
const-expr/passive data segments DONE 2026-07-13** (#15 closed). **Host imports #1 COMPLETE — imported
tables/memories via shared objects (stage 2) + link-time import type-checking + `assert_unlinkable`
(stage 3), 2026-07-13** (`data` 12→34, `elem` 38→52, `imports` 26→137). **Start function (#3) + inline
memory-data / memory-table imports DONE 2026-07-13** (`start` 0→11). See `known-issues.md` for the fix
ledger.

## Track — run a fully compiled WASI program (planned 2026-07-14)

**Recon finding (evidence-based, the key insight).** Compiled a real Zig `wasm32-wasi` hello-world
(`zig build-exe -target wasm32-wasi -O ReleaseSmall`, 46 KB) and ran it in wazmrt. Result:
- **It instantiated fine** — every `wasi_snapshot_preview1` import resolved. A hello-world imports the
  *entire* WASI surface (`path_open`, `fd_readdir`, `poll_oneoff`, `fd_pread`, `path_*`, …, ~40 funcs)
  but only **calls** a handful (environ init, `fd_write`, `proc_exit`). The unimplemented ones fell
  through to the `NOTSUP` stub and were never called — the stub design handles this exactly.
- **It then trapped `UnsupportedOpcode`.** So **the blocker to running a compiled program is the
  INTERPRETER, not WASI.** wazmrt's `0xFC` decode only covers table ops (`0x0c–0x11`); LLVM/Zig emit
  `0xFC 0x08–0x0b` (**bulk memory**: `memory.copy`/`fill`/`init`, `data.drop`) and `0xFC 0x00–0x07`
  (**saturating float→int**) **by default** — both unimplemented.
- **Critical path:** `run a compiled stdout program = [interpreter: 0xFC 0x00–0x0b] + [only the WASI
  funcs it CALLS (mostly already have)]`. File-touching programs additionally need the WASI filesystem.

**Phase 1 — finish the `0xFC` prefix. DONE 2026-07-14 — MILESTONE HIT: a real LLVM-compiled program
runs and prints.** Decoded + executed + validated `0xFC 0x00–0x07` (saturating truncation: NaN→0,
±inf/out-of-range→min/max, never traps — `truncSatS`/`truncSatU`) and `0xFC 0x08–0x0b` (`memory.init`
copies from a passive segment, `data.drop` marks consumed, `memory.copy` = bounds-checked memmove
(overlap-safe), `memory.fill` = memset). `Instance.data_dropped` mirrors `elem_dropped` (active segments
start dropped per §4.5.4). Assembler + validator + 3 unit tests (101 total).
**`examples/hello_compiled.zig` → `zig build-exe -target wasm32-wasi` → `wazmrt hello.wasm` prints:**
`Hello from a compiled WASI program!` / `bulk-memory memcpy works` / `saturating truncation works` —
i.e. real compiled code exercising `memory.copy` (`@memcpy`) and `trunc_sat` drives wazmrt's WASI
`fd_write`.

> **RETRACTED 2026-07-15 (during Phase 3).** Phase 1 recorded a "guest-side gotcha": that Zig 0.16's
> `Io`-model file writer never issues `fd_write(1)` for stdout, called a *guest toolchain gap*. **That
> was wrong, and the diagnosis was mine, not the toolchain's.** The real cause: the example declared
> its own `extern "wasi_snapshot_preview1" fn fd_write(...) i32` while std declares the same import
> returning `errno_t` (`enum(u16)`). wasm-ld cannot reconcile two signatures for one import, so it
> silently redirects the call to a `.Lfd_write|wasi_snapshot_preview1_bitcast_invalid` stub whose whole
> body is `unreachable` — the guest traps with no diagnostic. Pure `std.Io` stdout works fine under
> wazmrt (`examples/hello_compiled.zig` now proves it). See `cmem/testing.md` for the trap signature
> and how to recognize it.

**Phase 2 — WASI core for stdout/args/env/compute programs. DONE 2026-07-14.** `clock_res_get` (via
`Io.Clock.resolution`); **`poll_oneoff`** — clock subscriptions sleep until the earliest deadline (this
is what a guest `sleep()` compiles to; relative + `ABSTIME` flag both handled via `Io.sleep`), and
fd_read/fd_write subscriptions on stdio report ready immediately (real fd-readiness polling defers with
the filesystem work); real **stdin** `fd_read` (fd 0 ← process stdin, scatter into iovecs, short
read/EOF → 0; other fds EBADF) wired from the CLI via an `Io.File.Reader`; `proc_raise` → trap.
Verified end-to-end by a compiled program (`examples/wasi_clock_stdin.zig`): `clock_res_get works` /
`poll_oneoff clock sleep works` (asserts ≥15 ms actually elapsed) / `stdin echo: hello stdin!`, plus the
EOF path. +2 unit tests (103 total). **wazmrt now runs the whole compute + stdout + args + clock + stdin
class — wasmtk's compiler-test-output regime (`vision.md`).**

**Phase 3 — WASI filesystem. DONE 2026-07-15.** `--dir <host>[:<guest>]` preopens a host dir as fd 3+
(`fd_prestat_get`/`_dir_name` enumerate; the CLI splits on the *last* `:` so `C:\tmp:/data` parses). A
**host-fd table** (`FdEntry` = stdio | dir | file, with rights + its own offset; lowest-free-fd reuse
on close). `path_open` honoring oflags/rights/fdflags, with the new fd's rights **intersected with the
dir fd's inheriting rights** — a guest can never widen its capability by reopening. Real
`fd_read`/`write`/`seek`/`tell`/`close`/`sync`/`datasync`/`pread`/`pwrite` (WASI fds carry their own
offset and we use the **positional** calls, so we never depend on the host handle's position);
`fd_fdstat_get`/`set_flags`, `fd_filestat_get`/`set_size`, `fd_readdir`, `fd_renumber`,
`path_filestat_get`, `path_create_directory`/`unlink_file`/`remove_directory`/`rename`. Rides the
libc-free Zig-0.16 `Io.Dir`/`Io.File` API. Verified by a compiled guest (`examples/wasi_files.zig`,
16/16 checks) + 3 unit tests (**106**).

**The sandbox is ours to enforce, and that is the headline.** `Io.Dir`'s `resolve_beneath` is a silent
no-op on Windows and Linux (it only maps to a FreeBSD `O.RESOLVE_BENEATH`), so an `*at`-style dir
handle is **not** a security boundary: an absolute path bypasses the handle entirely, and Windows
resolves `..` *lexically against the process cwd* before the syscall sees it. `wasi.resolve()` therefore
rejects absolute paths, escaping `..`, NT/device prefixes, and embedded NUL up front and hands `Io.Dir`
only a normalized `..`-free relative path. **Known gap (see `known-issues.md`):** a symlink *inside* a
preopen pointing outside it is still followed — containment is lexical; closing it needs per-component
resolution the `Io` API doesn't expose.

**Phase 3 leftovers** (deliberate, low demand): `path_symlink`/`path_readlink`/`path_link`,
`fd_filestat_set_times`/`path_filestat_set_times`, `fd_allocate`, `fd_advise` (returns success —
advisory), and real fd-readiness in `poll_oneoff`. All still resolve to the `NOTSUP` stub.

**Phase 4 — ergonomics + conformance. ORDERED BY THE OWNER — treat the sequence as binding rather than
re-deriving it.** The order was set 2026-07-15 and then twice amended by the owner as the day's work
surfaced things worth doing first (#20, then #22). None of the inserted items *block* the conformance
work at the end; they were scheduled ahead of it deliberately.

**4.0 — `known-issues.md` #22, the C ABI lifecycle fuzz. DONE 2026-07-16.** A randomized driver over
object-lifecycle sequences (new/copy/delete/host_info/cast/table-get/vec-transfer) under
`std.testing.allocator` so any double-free / leak / UAF fails the run — 400 seeds in `zig build test`,
coverage-guided under `zig build test --fuzz`, one driver behind both. **Building it found two more
real bugs**: a module use-after-free (`interp.Instance` stored `&m.inner` with no owned handle; the
embedder deleting the module then calling was a segfault — fixed by having the instance retain the
module) and a `wasm_trap_delete` double-free (it froze unconditionally, ignoring the refcount
`wasm_trap_copy` bumps — the fuzz caught it on seed 1, fixed with `release`). Verified the fuzz fails on
each reintroduced bug. +3 C-ABI tests (121 distinct). Invariants 5–6 in `design-decisions.md`.

**4.2 — `known-issues.md` #17, make the WASI sandbox real. DONE 2026-07-16 (then upgraded to full
traversal in 4.3, below).** Containment was *lexical*: a symlink inside a preopen pointing outside it was
followed straight out (`follow_symlinks=false` only guards the final `openat` component). First fixed
with a handle-based no-traversal walk; **then 4.3 replaced it with the secure handle-stack resolver
`walkFull`** that *follows* in-sandbox symlinks while keeping escape impossible by construction (`..`
can't rise above the preopen; absolute targets re-base to the preopen root; per-component no-follow
opens; `symlink_max`→ELOOP). No `openat2(RESOLVE_BENEATH)` needed — the walk gets there portably.
**Verified with real NTFS symlinks** (`examples/wasi_symlink_traversal.zig`, 5/5) + POSIX-CI unit tests
incl. an adversarial fuzz + Phase 3 gate still 16/16. One documented residual: a narrow
final-component `path_open` TOCTOU tied to std bug #18. See #17.

> ### ✅ 4.3 (2026-07-16). ✅ 4.4 + Phase 5 (2026-07-17). ✅ Phase 6 — exception handling CORE
> COMPLETE (2026-07-17: decode + validate + execute for the exnref proposal). ⇢ START HERE next:
> **Phase 6.1 — WAT assembler + `.wast` conformance for EH** (the one deferred piece; §6 below), then
> the next frontier (SIMD / multi-memory / the signature path).
>
> **Phase 6 delivered (DONE 2026-07-17):** the standardized **exnref** proposal end to end —
> `exnref` value type + `exn` heap type (`types.zig`/`opcode.zig`), the **tag section** (id 13,
> `Module.tags` + `tagType`), the IR ops `throw`/`throw_ref`/`try_table` with a `Catch`-clause immediate
> (`opcode.zig`), validation (try_table control frame + `checkCatch` label typing, `throw`/`throw_ref`,
> `UndefinedTag`/`InvalidTag`), and execution: an `Exception{tag,values}` unwinds via
> `error.UncaughtException` with each `call` site catching in its own try_tables (`Frame.onCallError` →
> `throwException` searches the label stack innermost-out); `exnref` values box into `Instance.exn_store`.
> 6 hand-built binary tests cover catch / catch_all / catch_ref / throw_ref / cross-frame catch / uncaught
> (→ trap). **Deferred to 6.1:** the WAT assembler + spec `.wast` conformance (the assembler needs
> `(tag …)` + try_table/catch label-name resolution — a separate chunk). Legacy `try`/`catch`/`delegate`
> stays out of scope.
>
> **Phase 5 delivered (DONE 2026-07-17):** `src/pin.zig` (pure logic — SHA-256, content-addressed
> plaintext pin-DB parse, `# mode:` policy directive, `stricter`, and the pure `decide()` matrix) +
> the CLI in `main.zig`: `wazmrt pin <file> [--db <path>]`, and `verifyGate` gating execution — it
> hashes the **in-memory bytes it is about to run** (TOCTOU-safe: `verifyGate` receives the buffer, has
> no path to re-open), checks the root-owned DB, and applies the policy. Flags: `--pins <path>`,
> `--verify <mode>` (raise-only), `--no-verify`/`--yes` (**refused under `enforce`** — the precedence
> rule). Default `off`. 7 new unit tests incl. the full enforcement/precedence matrix; verified
> end-to-end (off runs; enforce+pin runs; enforce+wrong/absent refuses; warn+no-tty refuses;
> warn+`--no-verify` runs; enforce+`--no-verify` STILL refuses; corrupt DB fails closed). **Still
> DESIGN-ONLY: the signature path** (embedded key, Ed25519, `try`-less) — needs the open owner decisions
> (trust anchor, signature format, revocation) in `security-model.md`.
>
> **The C ABI is NOT remaining work** — #20 (all 319 `wasm.h` fns) / #21 (mem-safety) / #22 (fuzz) are
> DONE and 4.4 added a C conformance guest. Only two narrow, demand-driven residuals stay deferred:
> shared-mutable imported globals, and externref table slots via `wasm_table_get`. Don't treat C as a
> phase.
>
> **4.4 delivered (all DONE 2026-07-17):**
> - **`--env KEY=VAL`** (repeatable) — sets one guest env var; guest environ otherwise empty. `main.zig`.
> - **`--ro-dir <host>[:<guest>]`** — read-only preopen. `wasi.zig` gained `rights.write_mask` /
>   `rights.read_only` and public `allRights`/`readOnlyRights`; `addPreopen` takes `dir_rights: u64`.
>   Because `path_open` only ever *narrows* an fd's rights against its parent dir fd, read-only-ness
>   propagates to the whole subtree. Unit-tested (rights-mask + narrowing invariant, POSIX-CI).
> - **`zig build wasi-gate`** — compiles REAL `wasm32-wasi` guests and runs them through the wazmrt CLI,
>   asserting exact stdout. **Zig + C (`zig cc`) always-on** (both ship with the Zig toolchain);
>   **Rust opt-in via `-Drust-gate=true`** (needs rustc w/ wasm32-wasip1). Guests:
>   `examples/hello_compiled.zig`, `examples/c_hello.c`, `examples/rust_hello.rs`. Verified wazmrt runs
>   all three compilers' output byte-for-byte. The gate *can fail* (wrong output → exit 1, confirmed).
>

## Phase 5 — Secure base: pin verification (✅ COMPLETE 2026-07-17 — all 6 increments below built)

The **buildable slice of the authenticity design** (`security-model.md`), chosen next because its
mechanism is fully **DECIDED** and it needs **none** of the still-open *signature* decisions (trust
anchor, signature format, revocation). It delivers the unsigned-module path end to end: an install-time
root-owned pin + a pre-run SHA-256 check.

**Decided mechanism — do NOT re-derive (security-model.md §1):**
- Pin DB is **root-owned, read-only to the user, plaintext**. Integrity from *ownership*, not secrecy.
- Pinning is done **at install time, with privilege** — verified install, **NOT TOFU**. wazmrt (as the
  user) only ever *reads* the DB; user-level malware can't rewrite it.
- **Signed → verify signature; unsigned → check the pin.** This phase builds the **pin** half only.
- **TOCTOU discipline (aligned with owner 2026-07-17):** read the file **once** into memory, hash *those*
  bytes, execute *those* bytes — never hash-by-path then re-open. It is not caching/perf: the buffer is
  freed at exit like any decode buffer; it exists so the verified bytes provably *are* the run bytes,
  closing the check→use swap window. It falls out of how the runtime already loads a module (zero/negative
  cost). In the root-owned-script deployment ownership already shuts the window; the single-read keeps the
  guarantee sound even when a user runs `wazmrt ./downloaded.wasm` from a writable dir.
- Cold-start cost **measured negligible** — SHA-256 ~21 µs (~0.5% of instantiate).

**Increments (each with tests):**
1. **Pin DB format** — minimal plaintext, auditable (`cat`/diff-able). Micro-decision: **content-addressed**
   (just the set of approved SHA-256s — path-independent, simplest) vs `sha256␠identifier` lines. Lean
   content-addressed.
2. **`wazmrt pin <file>`** subcommand — hashes the module and writes/appends the DB; meant to be run with
   privilege by an installer. Document the root-owned DB location per-OS.
3. **Runtime verify** — before instantiating a `_start` command module, SHA-256 the **in-memory** bytes,
   look them up in the pin DB, gate execution. **Reuse the single buffer the loader already reads**
   (TOCTOU-safe by construction).
4. **Enforcement policy = a knob, default OFF for now** — `default-deny-unsigned` is still an *open* owner
   decision, so ship the check behind an explicit mode (e.g. `--verify`, or "DB present ⇒ enforce"),
   erroring clearly on mismatch / absent pin. **Do NOT make deny-the-default until the owner settles it.**
5. **Unverified-module handling — interactive consent, not a bare skip flag (owner refinement,
   2026-07-17).** When a module isn't in the pin DB, behaviour is governed by the root-owned policy:
   - **`off`** (dev default) → run, optional one-line "unverified" notice. **No prompt** — prompting on
     every run trains dismissal (the "warning users always dismiss" anti-pattern, `security-model.md`).
   - **`warn`** → **interactive TTY: prompt** "module X is unverified (not pinned) — proceed? [y/N]",
     **default No** on EOF / non-interactive. **No TTY** (script, pipe, cron, `binfmt`/`argv[0]` dispatch
     — the vision's own deployment) → **deny**, unless an explicit non-interactive opt-out is present.
   - **`enforce`** (hardened) → **hard deny, no prompt** — a locked-down system doesn't negotiate and has
     no TTY to negotiate with.

   **Two things this must NOT pretend to be:** (a) the prompt is **UX consent, not a security boundary** —
   `echo y | wazmrt evil.wasm` / `yes |` answers it for an attacker, so it only helps an honest human; the
   real boundary stays the root-owned policy. (b) it can't be the *only* mechanism — the unattended
   deployments have no keyboard, so keep a **non-interactive opt-out** (`--yes` / `--no-verify` or
   `WAZMRT_ASSUME_YES`) for scripts, itself **subordinate to the policy** (honored under `off`/`warn`,
   **refused under `enforce`** — authority from ownership, not from a runtime argument). Record the prompt
   text, the TTY/EOF→No rule, and the opt-out precedence in `main.zig` help and `security-model.md`.
6. **`bytes-hashed == bytes-run` test** — assert the verified buffer is the executed buffer, so a future
   refactor can't silently reintroduce a hash-by-path TOCTOU.

**Open, and NOT blocking this slice** (they belong to the *signature* path): trust anchor, signature
format, revocation. **Touches this slice:** default policy (deferred to the knob above), DB
location/ownership convention per-OS. All tracked in `security-model.md` "Open decisions".

## Phase 6 — Exception handling (CORE ✅ COMPLETE 2026-07-17; §6.1 WAT/​.wast conformance deferred)

**Scope decision first:** target the **standardized exnref proposal** (`try_table` + `throw`/`throw_ref`,
`tag` section id 13, `exnref` heap type) — it shipped cross-browser (Chrome/Firefox 2024) so it clears
the project's browser-standard bar (`design-decisions.md` proposal-scope). The **legacy** form
(`try`/`catch`/`catch_all`/`delegate`/`rethrow`, older LLVM/Emscripten) is a *distinct* encoding; treat
it as a later compat add-on only if a real corpus module needs it, not part of this phase.

**Why it fits cleanly:** EH extends seams that already exist — a new section (like tags are just typed
function-signatures), new opcodes in the `opcode.zig` IR, new control-frame kinds in `validate.zig`, and
a new unwind path in `interp.zig` that can reuse the label/frame stack the trap backtrace (#19) already
walks.

**Increments (each with unit tests + a `.wast` slice; keep the IR seam clean):**
1. **Decode** — tag section (id 13): each tag = an attribute byte + a type index (the exception
   signature). Store on `Module` alongside functions. Add `exnref` to the heap-type/valtype decoders.
2. **IR** — add `throw {tag}`, `throw_ref`, and `try_table {blocktype, catch[]}` to `opcode.zig`
   (`Op`/`Imm`/`decodeBody`), where each catch clause is `{kind: catch|catch_ref|catch_all|catch_all_ref,
   tag?, label}`. Mirror in the assembler (`wat.zig`) for `.wast` coverage.
3. **Validate** — `try_table` pushes a control frame carrying its catch table; `throw` checks operands
   against the tag's params; `throw_ref` consumes an `exnref`; catch-clause target labels must accept
   the tag's params (+ `exnref` for the `_ref` variants). `exnref` typing + null rules.
4. **Execute** — represent a thrown exception as `{tag, values}`; `throw` unwinds the frame/label stack
   to the nearest enclosing `try_table` whose catch matches (by tag, or `catch_all`), pushing the values
   (and an `exnref` for `_ref`); `throw_ref` re-throws a caught `exnref`; unmatched at the top frame →
   the existing trap path. Reuse the `errdefer`/frame machinery from #19 where it fits (mind the
   `noinline recordTrap` invariant — the unwind is an error-ish path off the hot switch).
5. **Conformance** — run the spec `exception-handling` `.wast` files through `wast.zig`; add a compiled
   guest to `wasi-gate` only if a stock toolchain emits exnref by default (C++ `-fwasm-exceptions` via
   wasi-sdk does; Zig/Rust panics are traps, so probably a `.wat`/`.wast`-only gate).

**Open sub-question for the owner (surface before coding step 4):** do we want the legacy try/catch
encoding at all, or exnref-only for now? Plan assumes exnref-only.

> 4.3 delivered (all DONE 2026-07-16): the safe leftovers (`fd`/`path_filestat_set_times`, `fd_allocate`,
> `path_link`, `poll_oneoff` EBADF fix) **and** — owner chose full traversal — `path_symlink`/
> `path_readlink` with the secure **handle-stack resolver** (`walkFull`): in-sandbox symlinks followed,
> escapes impossible by construction, adversarial-fuzzed. See `security-model.md` (DONE) and #17.
>
> Three findings from the pause conversation, retained for the record:
> 1. **The vision's symlink is host-side dispatch** (`argv[0]`/`binfmt_misc`), **not** the guest-visible
>    symlink of #17 — **the vision does not need `path_symlink`.** The two were being conflated.
> 2. **If `path_symlink` is ever built, targets must be validated at *creation*** (refuse escaping
>    targets) — a persisted link is a landmine for whoever follows it next with more authority. This is
>    *different from and stronger than* the traversal policy, and holds even if no-follow is kept.
> 3. **`--ro-dir` (read-only preopens)** looks like the highest security-value-per-effort item available
>    and is on no list. It may deserve to jump the queue.
>
> **4.3 progress:** the safe, no-policy items are **DONE 2026-07-16** — `fd_filestat_set_times`,
> `path_filestat_set_times` (via an opened handle, dodging a std `dirSetTimestamps` panic — #23),
> `fd_allocate` (extend-not-shrink via `setLength`), `path_link` (POSIX-only; Windows std has no hard
> links — #23), and a `poll_oneoff` correctness fix (a subscription on a closed fd reports EBADF, not a
> false "ready"; note **files/stdio being always-ready is *correct* per POSIX, not a stub** — only
> pipes/sockets, which we don't have, would need real polling). +3 unit tests, `examples/wasi_leftovers.zig`
> gate. **`path_symlink` / `path_readlink` DONE 2026-07-16 — owner chose FULL traversal (wasmtime
> parity).** The lexical/no-follow walk was replaced by the secure handle-stack resolver `walkFull`
> (RESOLVE_BENEATH in userspace): in-sandbox symlinks are **followed**, escapes are impossible **by
> construction** (`..` can't rise above the preopen; absolute targets re-base to the preopen root;
> per-component no-follow opens through held handles; `symlink_max`→ELOOP). `path_symlink` validates
> targets at creation (absolute refused). Verified 5/5 on Windows with real symlinks
> (`examples/wasi_symlink_traversal.zig`) + POSIX-CI unit tests incl. an **adversarial fuzz**
> (random topologies, canary oracle). Design in `cmem/security-model.md` (marked DONE). Creation is
> POSIX-only (Windows privilege, #17/#23); following works everywhere. **4.3 COMPLETE.** Then **4.4** —
> the Phase 4 items proper (`--env`, the `zig build`-driven compiled gate, C/Rust/Zig conformance).

**4.1 — `known-issues.md` #19: trap diagnostics. DONE 2026-07-15.** Traps now report a named
backtrace, innermost frame first — on the exact binary from the Phase 3 hunt:
`at fn[31] <.Lfd_write|wasi_snapshot_preview1_bitcast_invalid> +0` / `by fn[30] <min.main> +22` / … —
and hint to rebuild unstripped when a module carries no names. `Frame` carries `func_index`; `Frame.run`
records via **`errdefer`**, which emits code on the error path only, so the dispatch loop is untouched
and the trace assembles itself innermost-first as the error unwinds. Frames land in a fixed
`[16]TrapFrame` on `Instance` — recording a trap must not allocate (we may be unwinding an OOM) or fail
— with `trap_depth` keeping the true depth so truncation is visible, reset per `invokeIndex`. Names are
decoded **lazily** from a kept copy of the name section's function-name subsection; a malformed one
degrades to "no names" rather than erroring on the path already reporting an error.

**4.1 also fixed a latent C ABI break it exposed.** `wasm.h` declares `wasm_trap_origin`,
`wasm_trap_trace` and the `wasm_frame_*` family; we defined none of them, so an embedder following the
header got a **link error** — not the "trace isn't surfaced yet" nicety this was first recorded as.
Now implemented and guarded by `tests/c_smoke.c`, which deliberately traps and walks the backtrace
(asserting the reported `module_offset` really lands on the `unreachable` byte). Auditing the whole
header turned up **180** declared-but-undefined symbols, now 167 → **`known-issues.md` #20**, which
also carries the reproducible audit command. Byte offsets are resolved **lazily** by re-decoding one
body (`Instance.frameOffset`) — tracking them per instruction cost ~7% cold-start for a path most
modules never take.

+6 unit tests (**111**). **Ended up faster than the baseline**: steady **286–288** vs **260–262**
Mops/s, cold **0.86** vs **0.90** us/run. The route there is the durable lesson: the first cut
regressed **14%** from an *error-path* change, because `Frame.run`'s `errdefer` expands at every `try`
in a ~200-arm switch and inlining `recordTrap` there evicted the loop from i-cache. `noinline` fixed it
and beat the old baseline — 4.1 had been inlining it too. Both facts are now invariants in
`design-decisions.md`; the bisect method is in `testing.md`.

**4.1½ — `known-issues.md` #20 + #21: the C ABI. DONE 2026-07-15, inserted by the owner** ahead of
#17 ("Definitely #20 first. It seems like a big hole at the moment, that we don't need to fall into").
4.1 exposed that `wasm.h` declared **180 functions we never defined** — a link error for any embedder
following the header. All 319 are now defined and gated at link time (`tests/c_abi_symbols.c`). The
owner then flagged memory safety as a project goal, and the audit that followed found **four real
bugs** — a double free, a use-after-free needing no misuse, an uninitialized refcount, and a leak —
three of them shipped hours earlier. Fixed, with the deeper problem fixed too: the C ABI was
**unreachable from `zig build test`** and `c_smoke.c` runs on an allocator where a double free prints
`OK`. See #20/#21, and the memory-safety invariants in `design-decisions.md`. +7 C-ABI lifecycle tests
(**118 distinct**; `zig build test` prints 229 — see `testing.md` on reading the count).
**#22 (fuzz the lifecycle) is the follow-up, and the owner made it the first item for 2026-07-16.**

**4.2 — `known-issues.md` #17: close the symlink hole (make the sandbox real, not lexical).**
*Budget for this: it is the biggest item in Phase 4, not a cleanup.* `resolve()` stops a guest *naming*
a path outside a preopen, but a symlink stored *inside* one still gets followed out. Correct
containment needs **per-component** resolution, and **Zig 0.16's `Io` exposes no way to do it**:
`resolve_beneath` is a silent no-op off FreeBSD, and there is no `openat2(RESOLVE_BENEATH)` and no
O_PATH walk. So expect to go **below `Io` to raw platform syscalls** (Linux `openat2` with
`RESOLVE_BENEATH`/`RESOLVE_NO_SYMLINKS`; Windows: walk components with
`statFile(.follow_symlinks=false)` and re-validate each target, or open with `OPEN_REPARSE_POINT` per
component) — with a portable fallback. Watch TOCTOU: validate-then-open on a live filesystem races, so
prefer resolving *through held handles* rather than re-walking by path. The existing `if (!follow)`
pre-stat in `wPathOpen` is the natural hook. **Done means:** a test where a symlink inside the preopen
targets outside it is refused with `ENOTCAPABLE`/`ELOOP` — add it to `examples/wasi_files.zig`
alongside the four existing refused escapes. Only after this may the README stop hedging the sandbox.

**4.3 — the Phase 3 leftovers** (listed above): `path_symlink`/`path_readlink`/`path_link`,
`fd_filestat_set_times`/`path_filestat_set_times`, `fd_allocate`, real fd-readiness in `poll_oneoff`.
These are the likeliest things 4.4 trips over, since wasi-libc and Rust's std touch more API surface
than our Zig guests do. Note **4.2 changes what `path_symlink`/`path_readlink` must do** — implementing
them before the sandbox is real would mean writing them twice, which is part of why they sit after it.

**4.4 — the Phase 4 items proper. ✅ COMPLETE 2026-07-17.** ~~CLI `--dir`~~ (Phase 3) /
~~`--env KEY=VAL`~~ / ~~`--ro-dir`~~ / ~~`-- <guest args>`~~ all done. The reproducible
`zig build wasi-gate` gate compiles real `wasm32-wasi` programs and runs them in wazmrt asserting exact
stdout — **Zig + C via `zig cc` always-on** (both ship with Zig), **Rust opt-in `-Drust-gate=true`**.
Verified wazmrt runs all three compilers' output. The remaining long tail (fill in more
actually-called functions as specific guests demand them) is demand-driven, not a blocker.

**Not scheduled: `known-issues.md` #18** (the Zig std `openFile(.follow_symlinks=false)` host crash).
It is worked around and contained — it is **trigger-based, not ordered**: recheck it on **every Zig
upgrade**, whenever that happens. 4.2 will touch the same `wPathOpen` hook, so re-read #18 before
changing that code.

## Next increments (rough order)

1. ~~Decode the type/function/import/export sections~~ **DONE 2026-07-02** (also table/memory/global +
   full `Extern` resolution; exposed via C `wasm_module_imports/exports` + the wasm-c-api type-object
   system). ~~Decode the code section~~ **DONE 2026-07-02** (locals + raw body bytes per defined
   function, arena-owned; instructions not yet parsed).
2. **Validation** — **DONE 2026-07-02.** `src/opcode.zig` (core-MVP `Op` enum 0x00–0xC4, `Imm`/`Instr`,
   `decodeBody`; ref-type / `0xFC` / `0xFD` / multi-byte block-types → `UnsupportedOpcode`) + the
   type-checking validator `src/validate.zig` (spec Appendix algorithm: value stack + control frames +
   `unknown` bottom; count match, index bounds, control flow, operand-stack typing). 8 unit tests;
   **all 12 `wasm_mod` validate; every fully-decoding `wasm_wasi` validates** (see `testing.md`).
   **Opcode-expansion priority (from real corpus data): `0xFC` bulk-memory first, then exception
   handling (tag section id 13 + try/catch), then SIMD** — what `wasm_wasi` needs beyond core MVP.
3. **Instantiation** — memories, tables, globals, imports/exports wiring; grow the C ABI to
   `wasm_instance_new` + `wasm_func_call`.
4. **Execution** — **integer + float + memory slices DONE 2026-07-02** (`interp.zig`): switch
   interpreter over the IR (Option A), untyped `u64` slots, per-call label stack + precomputed branch
   targets. i32/i64 **and f32/f64** arithmetic/comparison/bitwise + all conversions, locals, globals,
   `drop`/`select`, structured control flow, direct `call`, **linear memory** (min-page alloc + active
   data-segment init, load/store all widths, `memory.size`/`grow`), and traps — 9 unit tests.
   **VERIFIED end-to-end on real modules:** the CLI gained `wazmrt <file.wasm> <export> [args…]` and
   runs the whole `module/wasm_mod` corpus to its `.test.json` values (`fib(20)=6765`, `fac(7)=5040`,
   `isLeapYear`, `isOdd`, `sieve(30)=10` via memory). **`call_indirect` + tables + globals +
   reference types DONE 2026-07-09** (type-checked indirect dispatch; global-init const-expr eval;
   `ref.null`/`ref.is_null`/`ref.func` + funcref/externref values; multi-table dispatch). **Remaining
   execution slices:** (a) `table.get`/`.set` + passive elements, (b) **host imports** (needed for
   WASI). Keep the IR a clean seam so a register-machine pass (Option B, wasmi) can be layered later
   if benchmarks demand it.
5. **Text toolchain — WAT assembler + WAST runner** (IN PROGRESS, owner-chosen 2026-07-02; the
   `.test.json` harness was dropped in favor of the standard `.wast` format). `sexpr.zig` DONE;
   **`wat.zig` DONE** (WAT→binary: funcs/exports, folded+flat, structured control flow + labels +
   blocktypes, memarg, memory + data sections — all assemble→run verified). Next: `wast.zig`
   (assertion runner), then run `module/wasm_wast/testsuite-main` as the standing conformance gate.
   global/table/elem, multi-value block types, and `call_indirect` all **DONE** (2026-07-02/07-09);
   deferred: reference-type instructions, imports. See `text-toolchain.md`.
6. **Grow the wasm-c-api implementation** as the runtime gains ability: `wasm_module_imports/exports`
   → then instance/func/trap/call at instantiation+execution. The standard signatures are already
   declared in the vendored `wasm.h`; we just implement more of them. Extend `tests/c_smoke.c` alongside.
6. **First `universalWasmLoader-*` integration** — prove the C-ABI static lib and/or the wasm build
   load from at least one host language end-to-end.
7. **Size/speed baseline** — the real perf gate (see `vision.md` → Performance target). Benchmark
   **native wazmrt vs Deno/V8** on wasmtk's own outputs, timing **cold-start wall-clock** and
   **steady-state throughput** separately (which regime does wasmtk live in?). Also size + startup vs
   wasm3 / WAMR-fast-interp. This data decides whether/when to move Option A → B (register machine).
   Baseline sizes today (`ReleaseSmall`): CLI exe ~611 KB (mostly Zig std + OS glue), C-ABI lib ~34 KB,
   freestanding wasm ~13 KB (lib/wasm are the decode/validate subset — execution not yet exported).

## Parking lot / open questions

- Interpreter shape: **DECIDED 2026-07-02 — Option A** (switch over a pre-decoded IR); see
  `design-decisions.md`. Open sub-question: whether/when to add the Option B register-rewriting pass —
  decide empirically against size+speed once basic execution works and there's a benchmark.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
