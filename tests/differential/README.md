# Differential findings — cross-runtime output disagreements

Found by `zig build bakeoff -Dmode=start`, whose `start` mode privileges no oracle: every runtime
must produce the same stdout, and a disagreement is **reported, not adjudicated**. It found the one
below on its first run.

`v8_wasi_oracle.mjs` runs a WASI `_start` module under **V8** via node's built-in `node:wasi`, with
no network dependency. V8 matters more than a majority vote here: it is the reference engine, and it
is what **wasmtk** actually runs wasm on.

    node tests/differential/v8_wasi_oracle.mjs <module.wasm>

## OPEN — wasmtime 47.0.3 emits one byte less than five other implementations

Module: `wasmtk/tests/wasi/wasm_wasi/27_string-formatting.wasm`
Guest source: `console.log(true); console.log(123);` — so a newline belongs between them.

| implementation | bytes | at the disagreement |
| --- | --- | --- |
| wazmrt (Zig) | 223 | `true\n123` |
| wasmrt (Rust) | 223 | `true\n123` |
| wazero (Go) | 223 | `true\n123` |
| wasmer (Rust) | 223 | `true\n123` |
| **V8** (node `node:wasi`) | 223 | `true\n123` |
| **wasmtime 47.0.3** | **222** | `true123` |

Everything else in the 223-byte output is byte-identical; only the newline between `true` and `123`
differs.

⚠️ **THE CAUSE IS NOT TRACED.** This is a reproducible observation, not a diagnosis — something
about that guest's `fd_write` sequence is handled differently by wasmtime, and naming a defect
before tracing it would be exactly the overreach `cmem/best-practices.md` warns about. To settle it,
trace the guest's `fd_write` calls (iovec count and lengths) around that point and compare what each
runtime writes.

**To check elsewhere:** wasmtk's `dync_cross_runtime_tests.ts` already runs its output through
wasmtime / wasmer / wazero. If it compares stdout exactly, it should be seeing this too; if it does
not, that is worth knowing about the test rather than about the runtimes.
