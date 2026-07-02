# Licensing

## Decision (2026-07-02): dual **`MIT OR Apache-2.0`**

The project's own code is licensed under **either** MIT (`LICENSE-MIT`) **or** Apache-2.0
(`LICENSE-APACHE`), at the consumer's option. SPDX: `MIT OR Apache-2.0`.

Chosen by the owner over the alternatives (Apache-2.0-only; keep MIT-only) because:

- It is the **WebAssembly/Rust/Zig ecosystem standard** (Rust std, wasmi, most Bytecode Alliance libs).
- It gives **downstream `universalWasmLoader-*` consumers, in any language, their choice** of terms.
- It stays **compatible with incorporating code from every reference runtime** — all permissive: MIT,
  ISC, Apache-2.0, and Apache-2.0 WITH LLVM-exception.
- Apache-2.0's explicit **patent grant** remains available to anyone who wants it; MIT simplicity too.

The previous MIT-only `LICENSE` was replaced (git `888b87e`).

## The compliance rule that drove the choice

License compatibility is **one-way**: MIT/ISC code can flow into an Apache-2.0-governed distribution,
but Apache-2.0 code (wazero, wasmtime, WAMR) **cannot** be relabeled MIT — its patent grant, NOTICE,
and change-statement obligations must be preserved. So:

- Our **original** code is offered as `MIT OR Apache-2.0`.
- **Incorporated** third-party code keeps **its own** license. A downstream user who picks "MIT" for
  wazmrt still complies with, e.g., Apache-2.0 for any incorporated Apache-2.0 files. This is normal
  and expected — the dual choice covers our contributions, not the vendored code.

## Files

- `LICENSE-MIT`, `LICENSE-APACHE` — the two license texts (Apache is the canonical verbatim text).
- `NOTICE` — attribution + a statement that incorporated Apache-2.0 code retains its NOTICE and gets
  change-notes (§4 obligations).
- `third_party/LICENSES.md` — **the operational source of truth**: the obligations-at-a-glance table,
  the Adoption Checklist (run before any reuse), the Component Ledger (one entry per adopted
  component), and the verified SPDX inventory. `reference-projects.md` mirrors the inventory with
  evaluation status.
- `README.md` — user-facing license section + `SPDX-License-Identifier: MIT OR Apache-2.0` + the
  standard dual-license inbound-contribution clause.

## Contribution terms

Inbound = outbound: contributions are dual-licensed `MIT OR Apache-2.0` unless explicitly stated
otherwise (stated in `README.md`).

## Gotcha worth remembering

**Verify licenses against the upstream `LICENSE` file, not the GitHub badge.** wasmtime's badge reads
"Apache-2.0" but its actual license is **Apache-2.0 WITH LLVM-exception** (confirmed from the raw
file). The Adoption Checklist enforces this.
