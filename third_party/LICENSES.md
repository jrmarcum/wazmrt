# Third-Party Licenses & Attribution

wazmrt is licensed **`MIT OR Apache-2.0`**. That covers *our own* original code.
Any code we incorporate or adapt from another project stays under **its own
original license**, and every such use is recorded in the [Component
Ledger](#component-ledger) below. This file is the single source of truth for
license compliance.

> **Rule of thumb:** you may *look at* any project freely. Before you *copy or
> adapt* even a few lines, complete the [Adoption Checklist](#adoption-checklist)
> and add a ledger entry. "I reimplemented the idea from scratch without looking
> at their code" is fine and needs no entry; "I ported their function" always
> needs one.

---

## 📋 THE BOTTOM LINE (audited 2026-09-20) — **wazmrt carries NO third-party licence obligation**

✅ **Nothing third-party is vendored, adapted, or distributed.** `third_party/` contains this file
and no code; the Component Ledger is empty; a clean build produces `wazmrt.exe`, `wazmrt.lib`,
`wazmrt.h` and `wazmrt.dll`, all of them ours. **No NOTICE has to travel with the artifact and no
upstream LICENSE has to be copied anywhere.**

The audit below cut the reference inventory from nine projects to three, and the reason each of the
three survives is worth stating precisely, because **two of the relationships look like licence
events and are not**:

| what we did | is it a licence event? |
| --- | --- |
| **Ran a competitor's binary** in `tools/bakeoff.mjs` (wasmtime, wasmer, wazero) | ❌ **No.** Executing an installed program copies nothing into this tree and distributes nothing. It is the same act as a user running it. |
| **Matched observable BEHAVIOUR** — wasmtime's diagnostic layout, its default recursion limit | ❌ **No.** An error-message shape reached by reading another tool's *output* is an interface, not copied expression. ⚠️ And the standard this project holds itself to is stricter than the law requires: `src/interp.zig:473` records the shape as *"arrived at independently here and confirmed against"* — confirmation after the fact, not derivation. |
| **Vendored a header** (`wasm-c-api`'s `wasm.h`, 2026-07-02 → 2026-08-11) | ✅ **Yes — and it ended.** The obligation existed while the file did, was satisfied while it did, and terminated when the file was deleted. It is the only one this project has ever had. |
| **Copied or ported source** from any of the nine candidate runtimes | ❌ **Never happened.** No occurrence of six of them anywhere in the tree; the other three only as competitors or as behaviour to match. |

🔒 **What would change this:** adapting even a few lines from any project — at which point the
[Adoption Checklist](#adoption-checklist) and a [Component Ledger](#component-ledger) entry are
mandatory *before* the code lands, not after.

---

## License obligations at a glance

All reference projects are **permissive** (no copyleft). Compatibility is
one-way: MIT/ISC code can flow into an Apache-2.0-governed distribution, but
Apache-2.0 code cannot be relabeled as MIT. Because wazmrt is dual `MIT OR
Apache-2.0`, incorporated Apache-2.0 code keeps its Apache terms for those files
— a downstream user who chooses "MIT" for wazmrt still complies with Apache-2.0
for the incorporated portions. That is normal and expected.

| License | To reuse code you MUST | Patent grant | Notes |
|---|---|---|---|
| **MIT** | Preserve the copyright + permission notice in source; reproduce it in binary distributions' docs. | No | Simplest. |
| **ISC** | Same as MIT (functionally identical, shorter). | No | Treat like MIT. |
| **Apache-2.0** | Preserve notices; include the license; **propagate the NOTICE file**; **mark your changes** in modified files (§4). | **Yes** (§3) | Heaviest obligations. |
| **Apache-2.0 WITH LLVM-exception** | Same as Apache-2.0, **except** the attribution requirement is waived for portions embedded into compiled/object output. | Yes | Strictly more permissive than plain Apache-2.0. |

**Practical rules for this repo:**
1. Copy the upstream `LICENSE` file into `third_party/<component>/LICENSE`.
2. If the upstream ships a `NOTICE` file (Apache projects), copy it too, and
   ensure our top-level `NOTICE` references it.
3. In any source file where we adapt Apache-2.0 code, add a header change-note:
   `// Adapted from <project> (<SPDX>); modified by wazmrt — see third_party/LICENSES.md`.
4. Keep an SPDX tag at the top of files that contain third-party code, e.g.
   `// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception`.

---

## Adoption Checklist

Run this **before** incorporating code from any project. It satisfies both the
project's evaluation goal (is it worth it?) and the compliance goal (are we
allowed, and did we document it?).

- [ ] **Benefit vs. drawback** documented: what it buys us (speed, binary size,
      correctness) vs. cost (complexity, deps, maintenance, portability to wasm).
- [ ] **License identified** and confirmed against the upstream `LICENSE` file
      (not just the README badge — see wasmtime, whose badge omits the LLVM
      exception).
- [ ] **Compatible** with `MIT OR Apache-2.0` distribution (all reference
      projects are; re-verify for anything new).
- [ ] Upstream `LICENSE`/`NOTICE` copied into `third_party/<component>/`.
- [ ] **Ledger entry added** below with source, commit/version, files, and the
      obligation actions taken.
- [ ] Change-notes + SPDX headers added to the adapting source files.
- [ ] `NOTICE` updated if an Apache-2.0 component was added.

---

## Component Ledger

**EMPTY as of 2026-08-11 — wazmrt vendors nothing.** `third_party/` contains this file and no
code, so there is no third-party licence to satisfy, no NOTICE to propagate, and nothing that has
to travel with the artifact. `zig-out/include/` is a single file: our own `wazmrt.h`.

Newest first. Copy the template below for each adopted component.

### ~~wasm-c-api (standard `wasm.h`)~~ — REMOVED 2026-08-11

Vendored 2026-07-02, removed 2026-08-11 when the C ABI was replaced by the native `wazmrt.h`
(ABI 2). `third_party/wasm-c-api/` and `src/wasm_c_api.zig` are both gone. Kept as a struck-through
entry rather than deleted, because the reasoning is worth more than the row:

- **What it was:** `include/wasm.h` from https://github.com/WebAssembly/wasm-c-api, commit
  `9d6b93764ac96cdd9db51081c363e09d2d488b4d`, `Apache-2.0`, vendored verbatim.
- **Why it went:** the benefit line in this very ledger — *"loaders bind once to a familiar
  ABI"* — was **falsified**. The `universalWasmLoader-*` consumers use wasmtime's *other* C API
  (`wasmtime_*` store/context/linker), and wasm-c-api's host callback cannot reach the caller's
  memory, which is what nearly every loader import needs. The ABI could not do the job it was
  chosen for. Full account in `cmem/vision.md`.
- **What it cost while it was here:** 319 declared functions in the project's largest file, and
  every C-ABI audit finding this project has ever had (**#20, #21, #22**).
- **What its removal bought:** wazmrt is now **100% self-owned** — the whole reason `zig-out/`
  had to carry `LICENSE.wasm-c-api` and `NOTICE` a day earlier evaporates, because there is no
  longer anything third-party in the distribution.

🎓 **The checklist lesson, which outlives the component: a "Benefit" line asserting what another
project does is a HYPOTHESIS. Open that project's source and grep for it before ticking the box.**
The loader header sat in a sibling repo for the entire life of this entry.

<!--
### <component-name>
- **Source:** https://github.com/<org>/<repo>
- **Version / commit:** <tag or 40-char SHA — pin it>
- **License (SPDX):** <e.g. Apache-2.0 WITH LLVM-exception>
- **License file:** third_party/<component>/LICENSE
- **What we reused:** <specific functions/files/algorithm>
- **Where it lives in wazmrt:** <path(s)>
- **Modifications:** <summary of changes, or "verbatim">
- **Obligations satisfied:** [x] license copied  [x] NOTICE propagated (if Apache)
  [x] change-notes in source  [x] SPDX headers
- **Benefit / drawback note:** <one line on why it earned its place>
-->

---

## Reference project inventory

🔎 **AUDITED 2026-09-20 and cut from nine rows to three.** The table used to list every runtime
named at project inception, all marked *"Evaluating"* — a status that described an intention from
2026-07-02 and, by the time anyone read it, nothing at all. **Six of the nine had no occurrence
anywhere in the tree**, so the inventory was claiming a relationship with projects this codebase
has never touched. What is left is what the tree can evidence.

🔒 **The method, because the answer had to be measured and not remembered:** every project name
was searched across the whole repository with word boundaries, excluding the two files that merely
*list* them (this one and `cmem/reference-projects.md`), and each hit was classified by **where it
lives** — shipped code, tooling, or memory prose.

| Project | License (SPDX) | What the relationship ACTUALLY is |
|---|---|---|
| [wasmtime](https://github.com/bytecodealliance/wasmtime) | `Apache-2.0 WITH LLVM-exception` | **Behavioural reference, no code.** Its *observable* behaviour is matched deliberately: diagnostic shape (`src/main.zig`, `src/capi.zig` — *"matched byte-for-byte against wasmtime 47 so the two tools can be compared"*), a default recursion limit (`src/validate.zig`), and a byte-collision it named first (`src/Module.zig`). ⚠️ `src/interp.zig:473` states the standard explicitly: *"The shape is wasmtime's, **arrived at independently here** and confirmed against."* Also a bake-off competitor. |
| [wasmer](https://github.com/wasmerio/wasmer) | `MIT` | **Bake-off competitor only** — `tools/bakeoff.mjs` invokes the installed binary. No source consulted, nothing in `src/`. |
| [wazero](https://github.com/tetratelabs/wazero) | `Apache-2.0` | **Bake-off competitor only** — same as wasmer. |
| [wasm-c-api](https://github.com/WebAssembly/wasm-c-api) (the C API standard) | `Apache-2.0` | **Formerly adopted, REMOVED 2026-08-11.** The one real adoption this project ever had; see the struck-through ledger entry above. Remaining mentions in `src/` are historical notes and deliberate contrasts (*"differs from the wasm-c-api ordering"*), not code. |

### Removed from this inventory 2026-09-20 — never used for anything

**wasm3 · wasm-micro-runtime (WAMR) · wasmi · wain · wai · rust-wasm**

Zero occurrences in `src/`, `include/`, `tools/`, `tests/`, `examples/`, `bench/` or `build.zig`.
Three (`wain`, `wai`, `rust-wasm`) had **no occurrence anywhere in the repository at all**; the
other three appear only in memory prose *about* which candidates might be studied.

📌 **Removed rather than re-labelled because a row in a licence file is a claim.** Listing a
project here implies its licence was relevant to something we did, and for these six it never was.
*An inventory of intentions is indistinguishable, to a reader, from an inventory of obligations.*
The candidates themselves are not forgotten — `cmem/reference-projects.md` keeps the list and why
each was named — but that is a research note, and this is a compliance document.

> **Trademarks:** permissive licenses grant no trademark rights. Do not use the
> "Wasmtime", "Wasmer", "wazero", etc. names to brand wazmrt or imply
> endorsement — attribution in this file is not branding.
