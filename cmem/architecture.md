# Architecture

## The runtime pipeline

The standard wasm-runtime stages. Only the first is implemented today; each later stage hangs off the
`Module` type.

```text
bytes ──► DECODE ──► VALIDATE ──► INSTANTIATE ──► EXECUTE
          (done)     (next)       (later)         (later)
```

- **DECODE** (`Module.decode`) — validate the 8-byte header (`\0asm` magic + version 1), then walk the
  top-level sections recording each `{id, offset, size}` without eagerly parsing payloads. Zero-copy:
  the returned `Module` only borrows section extents, so the input buffer may be freed afterward.
- **VALIDATE** (next) — decode the type/function/code sections and type-check per the spec.
- **INSTANTIATE / EXECUTE** (later) — memories/tables/globals + an interpreter (the design space to
  mine from wasm3 / WAMR-fast-interp / wasmi; see `reference-projects.md`).

## Module layout & responsibilities

| Unit | Responsibility |
| --- | --- |
| `types.zig` | `magic`, `supported_version`, `SectionId` (non-exhaustive enum, `.max`), `DecodeError`. Dependency-free so it compiles for every target. |
| `Reader.zig` | Zero-copy cursor (file-as-`@This()` struct): `readByte`, `readBytes`, `readU32Le`, `readVarU32` (unsigned LEB128). Bounds-checked, allocation-free. |
| `Module.zig` | `decode(allocator, bytes) → Module`; owns a `[]Section`; `deinit`; `section(id)` lookup. `Error = DecodeError || Allocator.Error`. |
| `root.zig` | Public surface. Re-exports the above + `decode`, `version`, `abi_version`. libc-free. |

## Three consumption surfaces (one core)

The core (`root.zig`) is compiled into three artifacts by `build.zig`:

1. **Native CLI** (`main.zig`) — `zig build` / `zig build run`. Uses the Zig-0.16 `std.process.Init`
   entry + new `Io` API (`Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64<<20))`,
   `Io.File.Writer`). See `design-decisions.md` for the 0.16 API notes.
2. **C-ABI static library** (`c_api.zig` + `include/wazmrt.h`) — `zig build` installs `wazmrt.lib`/`.a`
   and the header. Opaque `void*` handle; `smp_allocator` (no libc). This is what most
   `universalWasmLoader-*` ports link.
3. **Freestanding wasm** (`wasm_entry.zig`) — `zig build wasm`, `ReleaseSmall`, `entry = .disabled`,
   `rdynamic = true`, `std.heap.wasm_allocator`. Proves the runtime compiles to wasm and gives web
   loaders a module to instantiate.

## Build graph (`build.zig`)

- `mod` = `addModule("wazmrt", root.zig)` — imported by the CLI and reused as the test root.
- `exe` = CLI, imports `mod`; installed by default; `run` step.
- `cabi` = `addLibrary(.static, c_api.zig)` + `installHeader(include/wazmrt.h)`; installed by default.
  **Does NOT link libc** (deliberate — see `design-decisions.md`).
- `wasm_exe` = `addExecutable(wasm_entry.zig)` for `wasm32-freestanding`, under the `wasm` step only.
- `mod_tests` = `addTest(mod)` under the `test` step.

## C ABI contract (`include/wazmrt.h`)

```c
uint32_t     wazmrt_abi_version(void);                 /* == root.abi_version, currently 1 */
const char  *wazmrt_version_string(void);              /* static, NUL-terminated */
int          wazmrt_module_decode(const uint8_t*, size_t, wazmrt_module** out);  /* wazmrt_status */
size_t       wazmrt_module_section_count(wazmrt_module*);
void         wazmrt_module_free(wazmrt_module*);
```

`wazmrt_status`: `OK=0`, `ERR_NULL=-1`, `ERR_OOM=-2`, `ERR_DECODE=-3`. Handle is opaque; only the
functions + status codes are stable. Bump `abi_version` on any breaking change.
