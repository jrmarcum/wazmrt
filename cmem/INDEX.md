# cmem — Portable Project Memory for wazmrt

This folder is the **authoritative, portable project memory** for `wazmrt`. It lives inside the
project tree, so it travels with the project (USB drive, clones) and is **committed to git** — unlike
a machine-local `CLAUDE.md`.

**Format:** plain Markdown — one focused topic file per domain, so any single concern can be reviewed
and revised without wading through one giant file. Keep files small and single-topic.

## Policy (durable — set by the project owner 2026-07-02)

- **`cmem/` is the single home for ALL project memory.** When the owner (or anyone) says "**update the
  project memory**," that means: fold the latest decisions, found bugs, design changes, and current
  state into the matching `cmem/` topic file(s) — then add/refresh its one-line pointer in the Files
  table below. Convert relative dates to absolute; update existing entries rather than duplicating.
- **`README.md` is NOT project memory.** It is the public, user-facing document — a concise guide to
  *using* wazmrt (what it is, install, CLI/C-ABI usage, examples). Keep internal decision logs and bug
  post-mortems out of it; those live here.
- **`third_party/LICENSES.md` is the compliance source of truth**, not memory. `cmem/licensing.md`
  records the *why* and the strategy; the ledger of actually-reused code lives in
  `third_party/LICENSES.md`. Keep them consistent.

### The "update the project memory" trigger (binding on every agent)

When the owner says **"update the project memory"** (or a clear synonym — "update memory", "record
this", "remember this for the project"), the required action is BOTH of:

1. **Revise all relevant `cmem/` files** — fold in the latest decisions/bugs/design changes/state;
   refresh the one-line pointer in the Files table; convert relative dates to absolute; update existing
   entries instead of duplicating.
2. **Sync `README.md` where, and only where, the change is user-relevant** — install/usage, CLI/C-ABI
   surface, examples, status — so the README matches the new reality without absorbing internal detail.

### The "evaluate a reference project" trigger (binding on every agent)

Before incorporating or adapting code from any of the reference runtimes (see `reference-projects.md`),
complete the **Adoption Checklist** in `third_party/LICENSES.md` (benefit-vs-drawback + license
compliance), add a Component Ledger entry there, and update `reference-projects.md` status. "Looking at"
a project is free; "copying/porting from" it always requires the ledger entry.

## Files

| File | What it holds |
| --- | --- |
| [overview.md](overview.md) | What wazmrt is, repo layout, the key source files, mental model |
| [vision.md](vision.md) | The goal — a blazingly-fast, smallest-binary wasm runtime, itself wasm-compilable, embeddable in any language via the `universalWasmLoader-*` loaders |
| [architecture.md](architecture.md) | The decode → validate → instantiate → execute pipeline; module layout; the libc-free core; C ABI + freestanding-wasm build targets |
| [licensing.md](licensing.md) | **License = `MIT OR Apache-2.0`** (dual, ecosystem-standard; chosen 2026-07-02). Why dual, one-way compatibility with the Apache reference projects, and the compliance workflow. Ledger lives in `third_party/LICENSES.md` |
| [reference-projects.md](reference-projects.md) | The 9 candidate runtimes, their verified licenses, and per-project evaluation status (Evaluating until adopted) |
| [design-decisions.md](design-decisions.md) | Load-bearing invariants that must not be silently reverted — libc-free core (`smp_allocator`), opaque C handles + stable ABI, arena-owned decode, **interpreter architecture = Option A** (switch over a pre-decoded IR), Zig-0.16 API notes, and Windows build gotchas |
| [testing.md](testing.md) | Unit tests + the external conformance corpora: **`wasm_mod`** (module functions + `.test.json` expected outputs — the first execution target) and **`wasm_wasi`** (WASI programs). Decode-coverage snapshot + the opcode-expansion priorities it implies |
| [text-toolchain.md](text-toolchain.md) | **Decision (2026-07-02): build a native WAT assembler + WAST runner** for the standard `.wast` format (incl. the spec testsuite). `sexpr.zig` + `wat.zig` DONE (WAT→binary incl. control flow + memory/data); **next: `wast.zig`** (assertion runner). Why it's large (242/257 testsuite files use text modules) + staged plan |
| [roadmap.md](roadmap.md) | Current status + next increments. **Done:** decode, validate, execute (int/float/memory, runs the `wasm_mod` corpus), WAT assembler. **In progress:** `wast.zig`. Remaining: `call_indirect`/host imports, grow the C ABI, loader integration |

## Related files outside cmem

- `README.md` — the public, user-facing doc (install, CLI/C-ABI usage, examples). NOT project memory.
- `third_party/LICENSES.md` — the compliance ledger + adoption checklist + verified SPDX inventory.
- `LICENSE-MIT` / `LICENSE-APACHE` / `NOTICE` — the dual license texts and attribution notice.
