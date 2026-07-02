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

*No third-party code incorporated yet.* Add one entry per adopted component,
newest first. Copy the template.

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

Evaluation candidates named at project inception. Status is **Evaluating** until
code is actually adopted (then it also gets a Component Ledger entry above).
Verified against each upstream `LICENSE` file on 2026-07-02.

| Project | License (SPDX) | Status |
|---|---|---|
| [wasm-micro-runtime (WAMR)](https://github.com/bytecodealliance/wasm-micro-runtime) | `Apache-2.0 WITH LLVM-exception` | Evaluating |
| [wasm3](https://github.com/wasm3/wasm3) | `MIT` | Evaluating |
| [wasmtime](https://github.com/bytecodealliance/wasmtime) | `Apache-2.0 WITH LLVM-exception` | Evaluating |
| [wasmer](https://github.com/wasmerio/wasmer) | `MIT` | Evaluating |
| [wai](https://github.com/k-nasa/wai) | `MIT` | Evaluating |
| [wasmi](https://github.com/wasmi-labs/wasmi) | `Apache-2.0 OR MIT` | Evaluating |
| [rust-wasm](https://github.com/yblein/rust-wasm) | `ISC` | Evaluating |
| [wain](https://github.com/rhysd/wain) | `MIT` | Evaluating |
| [wazero](https://github.com/tetratelabs/wazero) | `Apache-2.0` | Evaluating |

> **Trademarks:** permissive licenses grant no trademark rights. Do not use the
> "Wasmtime", "Wasmer", "wazero", etc. names to brand wazmrt or imply
> endorsement — attribution in this file is not branding.
