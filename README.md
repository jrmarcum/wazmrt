# wazmrt

A Zig-based WebAssembly runtime aimed at being **blazingly fast** and the
**smallest possible binary** — and itself compilable to wasm, so it can be
embedded into any language via the `universalWasmLoader-*` loaders
(jvm, c, go, dotnet, dart, rs, py, v, zig, js).

Built by studying the best and fastest parts of the leading wasm runtimes and
adopting — with full attribution — only what earns its place. See
[`third_party/LICENSES.md`](third_party/LICENSES.md) for the evaluation and
compliance process, and for the ledger of any reused code.

> **Status:** early but running. wazmrt decodes, validates, and **executes**
> WebAssembly — integer/float arithmetic, control flow, `call`/`call_indirect`
> (multi-table), linear memory, globals, reference types, the reference-type
> table ops, **bulk table ops** (`table.init`/`table.copy`/`elem.drop`), element
> segments (active/passive/declarative), **imported functions, tables, memories,
> and globals** with cross-module `register` linking and full import type-checking,
> the **function-references proposal** (typed function refs, `call_ref`,
> `ref.as_non_null`, `br_on_null`, non-null refs with local-initialization
> checking), and **WasmGC** — `i31` references (`ref.i31`, `i31.get_s`/`_u`),
> **struct and array** heap objects (`struct.new`/`get`/`set`, `array.new`/
> `new_fixed`/`get`/`set`/`len`, `ref.eq`, packed `i8`/`i16` fields), casts
> (`ref.test`/`ref.cast`, `br_on_cast`/`br_on_cast_fail`), **concrete
> `(ref $t)` references** (self-referential structs, exact-type params), and
> declared subtyping (`(sub $super …)`) over the `any`/`eq`/`i31`/`struct`/
> `array` reference hierarchy, with types compared **structurally across module
> boundaries** when linking (so two modules that separately declare the same
> recursive type link, and two that merely reuse a type index do not)
> — and runs a corpus of real modules to their expected values
> (`fib(20)=6765`, `sieve(30)=10`, …). It ships a native **WAT text assembler**
> (`.wat` → wasm) and a **WAST script runner** (`wazmrt file.wast`) that runs the
> official WebAssembly spec testsuite (positive assertions plus
> `assert_invalid`/`assert_malformed`/`assert_trap`/`assert_unlinkable`) — e.g.
> `table_init` 729/0, `table_copy` 1649/0, `imports` 128/0, `call_ref` 31/0,
> `start` 10/0. It runs a module's **start function** at instantiation, embeds
> through a
> small **native C ABI** (instantiate/call, host functions with a caller handle,
> `.wat` straight from text, WASI, resource ceilings — loadable over FFI, see
> below), and runs **WASI
> preview 1** command modules — including real LLVM-compiled `wasm32-wasi`
> programs: stdout/stderr, args/environ, clocks, `poll_oneoff` (sleep), stdin,
> random, `proc_exit`, and a **sandboxed filesystem** rooted at the directories
> you preopen with `--dir`/`--ro-dir`, environment passed with `--env`
> (sockets deferred). It runs stock Zig-, C-, and Rust-compiled `wasm32-wasi`
> binaries, checked by a build-graph conformance gate (`zig build wasi-gate`),
> and can gate execution on a root-owned **pin database** of approved SHA-256
> hashes, or verify an **Ed25519 signature** against an embedded root key (both
> opt-in; see *Verifying modules* below). It also implements **exception
> handling** (both the `exnref` proposal and the legacy `try`/`catch` encoding),
> **multiple memories**, **memory64** (i64 memory addresses), **threads/atomics**
> (the whole `0xFE` family plus `shared` memories), and the **complete SIMD
> (v128)** instruction set — every fixed-width op plus the relaxed-SIMD
> extensions. Requires Zig 0.16.

## Build

```
zig build                          # CLI + C-ABI static library (+ headers)
zig build run -- <file.wasm>       # summarize, or run _start (WASI command)
zig build run -- <file.wat>        # assemble .wat, then the same
zig build run -- <file.wasm> <export> [args…]   # run an exported function
zig build test                     # unit tests
zig build test-safe                # the same suite under ReleaseSafe (optimized, safety checks kept)
zig build wasi-gate                # compile Zig+C wasm32-wasi programs, run them, assert output
                                   #   add -Drust-gate=true to also cross-check a rustc build
zig build conformance -Dtestsuite=<dir>   # run a WebAssembly spec-testsuite checkout (.wast)
                                   #   -Dbaseline=<file>        gate on regressions, not zero failures
                                   #   -Dwrite-baseline=true    generate that baseline from today's run
zig build wasm                     # build the runtime itself as a wasm module
zig build dll                      # C-ABI shared library (for FFI: Deno, ctypes, …)
zig build capi-smoke               # build + run the C example (needs no external deps)
zig build ffi-demo                 # build the DLL + run examples/deno_ffi_capi.mjs (needs deno)
zig build size -Doptimize=ReleaseSmall   # fail if a shipped artifact grew past its ceiling
zig build bench                    # interpreter microbenchmark (ReleaseFast)
```

Run `wazmrt --help` (`-h`) for the full list of run modes, WASI/verification
flags, and subcommands, or `wazmrt --version` (`-v`) for the version and whether
this build embeds a signature trust anchor.

The spec testsuite is not vendored — clone it and point the step at it
(`git clone https://github.com/WebAssembly/testsuite`); with no `-Dtestsuite` the
step just prints usage. Upstream has known failures against wazmrt today, so
generate a baseline once (`-Dbaseline=conf.txt -Dwrite-baseline=true`) and then
pass `-Dbaseline=conf.txt`: the step fails on **regressions**, and reports a file
that improved so you can re-generate. If `zig build` ever fails with a bare `error: Unexpected`
before doing any work, the local `.zig-cache` is corrupt — `rm -rf .zig-cache`.

The runtime loads over FFI from any host language: `zig build dll` produces a
libc-free `wazmrt.dll`, and
[`examples/deno_ffi_capi.mjs`](examples/deno_ffi_capi.mjs) `Deno.dlopen`s it,
assembles a `.wat`, and serves the guest's import from a JavaScript callback that
reads guest memory — no wasmtime, no JS engine executing the wasm.

## Running WASI programs

Compile a program to `wasm32-wasi` with any toolchain and run it:

```
zig build-exe examples/hello_compiled.zig -target wasm32-wasi -O ReleaseSmall -femit-bin=hello.wasm
wazmrt hello.wasm                       # prints via ordinary std stdout
```

A module exporting `_start` runs as a WASI command. Anything after the module
path is passed through as the guest's `argv`, except the preopen flags:

```
wazmrt files.wasm --dir ./data:/data --ro-dir ./assets:/assets --env LANG=C -- app args…
```

`--dir <host>[:<guest>]` **preopens** a host directory and is the guest's *only*
route to the filesystem: with no `--dir`, a guest has no reachable files at all,
and with one it can reach that directory and nothing above it. The guest sees it
under `<guest>` (defaulting to the host path). wazmrt resolves guest paths itself
and refuses absolute paths, `..` escapes, and NT/device prefixes — an interior
`..` that stays inside is fine. See [`examples/wasi_files.zig`](examples/wasi_files.zig).

`--ro-dir` preopens a directory **read-only**: it hands out every read right but
no mutating one (write, create, delete, rename, link, truncate, set-times). Because
`path_open` can only ever *narrow* an fd's rights against the directory it came
from, the read-only-ness propagates to the whole subtree — nothing opened under a
`--ro-dir` preopen can write either. `--env KEY=VAL` (repeatable) sets one
environment variable visible to the guest; the guest's environment is otherwise
empty. All preopen/`--env` flags are consumed by wazmrt; everything after `--`
(or the first non-flag) is the guest's `argv`.

A guest's linear memory is capped at **1 GiB** by default — a module declares its
own memory size, and a few bytes can ask for gigabytes. Raise or lower it with
`--max-memory <size>` (`512M`, `2G`, or a plain byte count); a module that asks
for more is refused with `MemoryLimitExceeded`. Memory within the cap costs
address space rather than RAM — it is committed by the OS as the guest touches
it, so declaring a large memory is cheap until it is used.

Table storage is not lazy, so a table's entries are allocated up front. A defined
table is capped at **128 Mi entries** by default (raise or lower with
`--max-table-elems <count>`, e.g. `1M` or `100000`); a module declaring or growing
past the cap is refused with `TableLimitExceeded` rather than allocating tens of
gigabytes from a few bytes of source.

Guests using the GC proposal have a second ceiling: wazmrt allocates GC objects
without collecting them (they live until the instance is dropped), so a module
is limited to **16 Mi live objects** and one that allocates past that traps with
`GcHeapExhausted` rather than consuming the host's memory. Exceptions boxed by
`catch_ref` are bounded the same way, per call.

Guest recursion is limited to **512 nested calls**, after which the call traps
with `CallStackExhausted`. wazmrt interprets a guest `call` by recursing on the
host stack, so this bound is what keeps a runaway or deeply recursive module from
overflowing it; the limit is deliberately the same in every build so a program
cannot run in one and trap in another.

> **Scope of the sandbox.** Containment is enforced two ways: **lexically** (a
> guest cannot name a path outside its preopens) and **through the filesystem**
> — path resolution walks one component at a time through directory handles
> (RESOLVE_BENEATH in userspace). **Symlinks are followed** like a real
> filesystem, but a symlink whose target leaves the preopen cannot escape: `..`
> can never rise above the preopen (there is no handle there), absolute targets
> re-base to the preopen root, and a symlink-expansion budget bounds cycles.
> Security is a property of the construction, not of checking target strings.
> One documented residual: a narrow TOCTOU on the final component of `path_open`,
> tied to a Zig std bug on Windows (`cmem/known-issues.md` #17/#18). Creating a
> symlink (`path_symlink`) needs OS privilege on Windows, so it is POSIX-only on
> the write side; *following* host-placed symlinks works everywhere. A guest also
> cannot **create** a link whose target obviously escapes (absolute, or climbing
> above its own directory) — `ENOTCAPABLE`. wazmrt would contain it anyway; the
> point is not to leave a trap for whatever reads that directory next.

### Verifying modules (pin database + signatures)

wazmrt can gate execution on a **pin database** — a plaintext, content-addressed
list of approved SHA-256 hashes. Register a module's hash:

```
wazmrt pin app.wasm                     # prints:  <sha256>  app.wasm
wazmrt pin app.wasm --db /etc/wazmrt/pins   # …and appends it to the DB
wazmrt pin ./bundle --db /etc/wazmrt/pins   # pin every .wasm/.wat under a dir (recursive)
```

The **directory** form pins a whole application bundle in one step — it walks the
tree, hashes each `.wasm`/`.wat` (assembling `.wat` first so the hash matches the
binary that runs), and appends them all. A `.wat` is assembled before hashing;
non-module files are skipped.

The database is meant to be **root-owned and read-only to the user** (created at
install time, with privilege); wazmrt only ever reads it. Its first line may set
the enforcement policy — `# mode: off | warn | enforce`:

- **`off`** (default when there is no DB) — run everything, no check.
- **`warn`** — an unpinned module prompts `proceed? [y/N]` on an interactive
  terminal (default No); with no terminal it is refused unless `--no-verify` is
  passed.
- **`enforce`** — an unpinned module is **refused**, full stop.

Before running, wazmrt hashes the exact in-memory bytes it is about to execute
(so the verified bytes *are* the executed bytes — no swap-after-check race) and
looks them up. This covers **every** form that executes, including `.wast`
scripts — a `.wast` runs the modules it contains, so it is gated as a unit and
`wazmrt pin script.wast` is what authorizes it. `--pins <path>` overrides the DB location and `--verify <mode>`
can *raise* strictness — **but only when the root-owned default DB does not
`enforce`.** If it does, both flags are ignored and `--no-verify` is refused: a
runtime argument can never weaken a root-mandated `enforce`, so the policy holds
even against an unprivileged user on a shared machine.

**Deny-by-default when armed.** Once verification is *armed* — a root key is
embedded (see below) **or** a pin DB is present — the CLI **refuses** a module
that is neither signature-verified nor pinned. A plain build with no key and no
DB stays permissive (nothing to verify against), so development is unaffected.
You can override an armed default-deny with `--no-verify` on your own machine,
but a root-owned `# mode: enforce` is absolute. Verification is **CLI-only**:
running a module through an embedder (wasmtk / rsxtk / the C-ABI over FFI) has no
gate — the embedder decides — which is the expected behavior for those. (`wazmrt
pin` assembles a `.wat` first, so a pinned `.wat` matches the binary that runs.)

**Signature verification.** A build can embed a trusted **Ed25519 root public
key**; wazmrt then authenticates a module carrying a `"signature"` custom section
(the signature covers every other byte) before running it — a module signed by
the trusted key needs no pin, and one signed by that key whose bytes don't match
is refused outright. Generate a key and sign modules with:

```
wazmrt keygen --out mykey          # writes mykey.key (private, KEEP SECRET);
                                   #   prints the public key to embed
wazmrt sign app.wasm app.signed.wasm --key mykey.key   # appends the signature
```

`sign` accepts `.wat` too (it assembles first), and the signed module still runs
in any other runtime (they ignore the custom section). Embed the trust anchor at
build time — the public key `sign` printed — to turn verification on:

```
zig build -Droot-key=<64-hex-char public key>
```

The default build embeds **no** key, so verification is **inert** (wazmrt runs
any module) until you build with `-Droot-key`; an empty value keeps it inert and
a malformed one is a build error. `keygen` writes the `.key` file `0600` on
POSIX; Windows has no equivalent mode bit, so it inherits the directory's ACL —
keep it off shared paths there. A local `.key` file is fine for testing; a real
publisher keeps the private key in an HSM/YubiKey/KMS. Design + rationale:
[`cmem/security-model.md`](cmem/security-model.md).

Implemented: stdout/stderr/stdin, args/environ, clocks, `poll_oneoff` (clock
sleep), `random_get`, `proc_exit`, and the filesystem (`path_open`, `fd_read`/
`fd_write`/`fd_seek`/`fd_tell`/`fd_pread`/`fd_pwrite`/`fd_sync`, `fd_readdir`,
`*_filestat_get`/`*_filestat_set_times`, `fd_allocate`, create/unlink/rename,
`path_symlink`/`path_readlink`, `path_link`). `random_get` is a real CSPRNG
(ChaCha seeded from OS entropy), so a guest's `getrandom()` is safe for key
material; if the host offers no entropy source it returns `EIO` rather than weak
bytes. Not implemented: sockets — those
return `ENOTSUP` rather than trapping, so a module still instantiates and fails
gracefully. Note `path_link`/`path_symlink` need OS support/privilege that is
absent on unprivileged Windows (they return `ENOTSUP` there; both work on POSIX).

> **Writing a WASI guest in Zig:** call the imports via `std.os.wasi`, not your
> own `extern "wasi_snapshot_preview1"` declarations. If your signature differs
> from std's, wasm-ld silently redirects the call to a trapping stub and the
> program dies with no diagnostic — see the note in
> [`examples/wasi_files.zig`](examples/wasi_files.zig).

## Embedding (C ABI)

wazmrt exposes a small, wasmtime-*shaped* C ABI of its own — 77 functions in
[`include/wazmrt.h`](include/wazmrt.h). `zig build` installs the static library
plus that one header, and **nothing else**: wazmrt vendors no third-party code,
so there is no licence or NOTICE that has to travel with the artifact.

> **Two things this ABI does that the standard wasm-c-api cannot.**
>
> **It runs `.wat` directly.** `wazmrt_module_new_wat()` assembles, decodes and
> validates text in-process — no `wat2wasm`, no temp file, no build step. (Use
> `wazmrt_wat_to_wasm()` if you would rather cache the binary; parsing text costs
> more per module than decoding one, so the win is the edit-run loop.)
>
> **Host callbacks get a caller handle.** `wazmrt_caller_read`/`_write` read and
> write *guest* memory from inside the callback, which is what essentially every
> real host import needs.

> **Handles, and why there are no lifetime footguns.** Engines, stores, modules,
> linkers, traps and errors are owned pointers with exactly one `_delete`.
> Instances, functions, memories and globals are **value handles** — small
> copyable structs you never free. Each carries the identity of its store, so a
> handle from the wrong store, or one left over from a deleted store, is
> *rejected* rather than silently naming someone else's resource. You may delete
> a module while instances made from it are still running.
>
> Every function this header declares is defined, checked at link time on every
> build by `tests/wazmrt_abi_symbols.c` — a symbol we promise but do not define
> breaks *our* build rather than yours.

```c
#include "wazmrt.h"

wazmrt_engine_t *engine = wazmrt_engine_new();
wazmrt_store_t  *store  = wazmrt_store_new(engine);
wazmrt_linker_t *linker = wazmrt_linker_new(engine);

/* Text or binary — your choice. */
const char *wat = "(module (func (export \"add\") (param i32 i32) (result i32)"
                  "  local.get 0 local.get 1 i32.add))";
wazmrt_module_t *module = NULL;
wazmrt_error_t *err = wazmrt_module_new_wat(engine, wat, strlen(wat), &module);
if (err) { fprintf(stderr, "%s\n", wazmrt_error_message(err)); wazmrt_error_delete(err); }

wazmrt_instance_t inst;
wazmrt_trap_t *trap = NULL;
wazmrt_linker_instantiate(linker, store, module, &inst, &trap);

wazmrt_func_t add;
wazmrt_instance_get_func(store, inst, "add", &add);

wazmrt_val_t args[2] = { {.kind=WAZMRT_I32,.of={.i32=40}},
                         {.kind=WAZMRT_I32,.of={.i32=2}} };
wazmrt_val_t result;
wazmrt_func_call(store, add, args, 2, &result, 1, &trap);
/* result.of.i32 == 42 */
```

An error and a trap are different answers: a call can return no error and still
have trapped, so check both. Beyond the above the ABI covers WASI preview 1
(`wazmrt_linker_define_wasi` with preopens, args, env and the `proc_exit` code),
host functions, raw linear-memory access, exported globals, trap backtraces with
function names, and per-engine resource ceilings and proposal restrictions.

**Concurrency comes from multiple engines.** An engine and everything reachable
from it is single-threaded; if your host uses async/await, tasks or threads, give
each concurrent context its own `wazmrt_engine_t`. They are cheap and fully
independent.

`zig build capi-smoke` builds and runs the C example; see
[`tests/capi_smoke.c`](tests/capi_smoke.c) for a complete one, and
[`examples/deno_ffi_capi.mjs`](examples/deno_ffi_capi.mjs) for the same thing
over FFI from a host language.

## License

Licensed under either of, at your option:

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

```
SPDX-License-Identifier: MIT OR Apache-2.0
```

This dual license is the WebAssembly/Rust ecosystem standard. It lets consumers
in any language pick whichever license fits their project, and it is compatible
with incorporating code from every reference runtime (all permissive: MIT, ISC,
Apache-2.0, and Apache-2.0 WITH LLVM-exception). Third-party code we incorporate
stays under its own license and is tracked in
[`third_party/LICENSES.md`](third_party/LICENSES.md).

### Contributing

Unless you explicitly state otherwise, any contribution you intentionally submit
for inclusion in the work, as defined in the Apache-2.0 license, shall be
dual-licensed as above (`MIT OR Apache-2.0`), without any additional terms or
conditions.
