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

### The "look for code issues" trigger (binding on every agent)

When the owner says **"look for code issues"** (or a synonym — "code audit", "audit the code", "hunt
for bugs"), perform a **COMPREHENSIVE audit across BOTH tested AND untested code paths**. The goal is to
catch issues that **won't surface in today's tests but will bite a future change**. Look for all four
categories:

1. **Workarounds / temporary hacks** — is each still needed, or now stale? (e.g. cache-clean races,
   leniency comments, `TODO`/`FIXME`, "for now" shortcuts.) Flag stale ones for removal.
2. **Dead code** — unused methods/fields/helpers, duplicates, orphaned exports. **Verify each with
   grep** before calling it dead (a symbol may be reached via `root.zig` re-export, the C ABI, or a
   test-only path).
3. **Bugs** — silently-wrong codegen, inverted logic, type-inference gaps, scanner/LEB off-by-ones,
   union-field access on the wrong active tag, stack-order mistakes, missing bounds checks.
4. **Fall-throughs (the worst failure mode)** — unhandled input that emits a stub/placeholder (a
   comment + a bare `0` / empty slice / `.none`) **instead of erroring**. Prefer converting
   silent-wrong to a **hard abort** (`error.Unsupported*` / a `diagnostics`-style failure), and guard
   genuinely-speculative probes so they fail loud, not silent. In this codebase the canonical example is
   an assembler/decoder path that should return `error.UnknownInstr` / `error.UnsupportedOpcode` rather
   than emit wrong bytes.

**Method:** for large files, **fan out parallel read-only investigators per category** (use the Agent
tool / `Explore`), then consolidate. Report each finding as `file:line` + a one-line description +
severity. **Fix the safe ones** and **keep the full suite green — diff the OUTPUT, not just exit codes**
(`zig build test` *and* re-run the affected `.wast` conformance files via `wazmrt <file.wast>`, comparing
`N passed / N failed` against the pre-change baseline; a build that still exits 0 while silently dropping
passes is a regression). Surface anything risky or ambiguous rather than fixing blind.

## Files

| File | What it holds |
| --- | --- |
| [overview.md](overview.md) | What wazmrt is, repo layout, the key source files, mental model |
| [vision.md](vision.md) | The goal — a blazingly-fast, smallest-binary wasm runtime, itself wasm-compilable, embeddable via the `universalWasmLoader-*` loaders. **Performance target: beat wasmtk's Deno/V8 execution** (win on startup + boundary, not JIT hot-loops; native build only). **Integration goal:** wasmtk runs wasm via native wazmrt (Deno FFI, not wasm-on-V8). **Candidate direction:** wazmrt as the loaders' native backend (consistency + no-dep + licensing freedom; wasmtime optional for heavy compute) |
| [architecture.md](architecture.md) | The decode → validate → instantiate → execute pipeline; module layout; the libc-free core; C ABI + freestanding-wasm build targets |
| [licensing.md](licensing.md) | **License = `MIT OR Apache-2.0`** (dual, ecosystem-standard; chosen 2026-07-02). Why dual, one-way compatibility with the Apache reference projects, and the compliance workflow. Ledger lives in `third_party/LICENSES.md` |
| [reference-projects.md](reference-projects.md) | The 9 candidate runtimes, their verified licenses, and per-project evaluation status (Evaluating until adopted) |
| [design-decisions.md](design-decisions.md) | Load-bearing invariants that must not be silently reverted — libc-free core (`smp_allocator`), opaque C handles + stable ABI, arena-owned decode, **interpreter architecture = Option A** (switch over a pre-decoded IR) + the **perf ladder A → A.5 partial-eval/superinstructions → B register machine → JIT**, the **proposal-scope decision** (core + function-references + WASI preview 1 in; WASI 2/3, full GC, multi-memory, EH tags, SIMD deferred until browser-standard), Zig-0.16 API notes, and Windows build gotchas |
| [testing.md](testing.md) | Unit tests (**77**) + the external conformance corpora (`wasm_mod`, `wasm_wast/testsuite-main`, `wasm_wasi`; the `module/` corpus is on removable media — not in this tree). **Spec-testsuite snapshot** — positive *and* negative conformance run: i32 459/0, call_indirect 169/0, func 171/0, **table_init 729/0, table_copy 1649/0**, elem 63, data 34/0, **imports 137, linking 100/37, start 11/0**, and the **function-references** files (`ref_null` 32/0, `ref_is_null` 18/0, `call_ref` 30/1, `return_call_ref` 38/9, `ref_as_non_null` 5/0, `local_init` 8/0), global 109/1 (f32/f64 2498/2). **GC P3 — i31 slice (2026-07-14):** +5 unit tests + hand-written `i31.wast` 11/0. **2026-07-13:** #15 + host imports #1 + start (#3) + audit-ledger closeout + invoke-by-module-name + **function-references (P1/P2/P2.5)** |
| [text-toolchain.md](text-toolchain.md) | **Native WAT assembler + WAST runner** for the standard `.wast` format. `sexpr.zig` + `wat.zig` + `wast.zig` all DONE — **runs the official spec testsuite** (positive + `assert_invalid`/`assert_malformed`/`assert_exhaustion`; `assert_trap` gated on a real trap; `(register …)` cross-module imports). Assembler covers multi-value/type-index block types, `call_indirect` + multi-table, element segments (all forms + const-expr offsets), globals, reference types, reference-type table ops, **imported functions**. Next: imported tables/memories, bulk table ops |
| [known-issues.md](known-issues.md) | **Audit-finding ledger + the integration that surfaces each** (2026-07-09 audit + post-audit fixes). **FULLY cleared 2026-07-13** — every item #1–#16 DONE. No open correctness/soundness/dead-code items. Next = invoke-by-module-name, then new features (C ABI, WASI); remaining `.wast` gaps are new proposals (typed/GC refs, multi-memory, EH tags). Out-of-scope: multi-memory, EH tags. Records which fixes shipped in which commit |
| [roadmap.md](roadmap.md) | Current status + next increments. **Done:** decode, validate, execute (int/float/memory, runs the `wasm_mod` corpus + spec testsuite incl. negative conformance), full text toolchain, **reference types + multi-table + imported globals + extended-const + reference-type table ops + validator/decoder strictness + element init expressions + imported functions/`register` (2026-07-09)**, **bulk table ops + passive elements + table-init exprs + const-expr/passive data segments (#15 closed) + host imports #1 complete + start function #3 + audit-ledger closeout + invoke-by-module-name + **function-references proposal (typed refs, call_ref, non-null + local-init; P1/P2/P2.5)** (2026-07-13)**. **In progress (owner order): (1) full GC — P3** (WasmGC: i31 → struct/array → ref.test/cast) — **i31 slice DONE 2026-07-14** (distinct `any`-hierarchy value types + real subtyping, unboxed i31 under the `0xFB` prefix; struct/array next), then **(2)** grow the C ABI (instance/func/call), **(3)** the Deno/V8 benchmark, **(4)** WASI preview 1 |

## Related files outside cmem

- `README.md` — the public, user-facing doc (install, CLI/C-ABI usage, examples). NOT project memory.
- `third_party/LICENSES.md` — the compliance ledger + adoption checklist + verified SPDX inventory.
- `LICENSE-MIT` / `LICENSE-APACHE` / `NOTICE` — the dual license texts and attribution notice.
