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

## ⚡ Status 2026-08-11 — **wazmrt vendors NOTHING; the Component Ledger is EMPTY**

`third_party/` contains `LICENSES.md` and no code. There is no third-party licence to satisfy, no
NOTICE to propagate, and nothing that has to travel with the artifact: `zig-out/include/` is a single
file, our own `wazmrt.h`.

The one component ever vendored — the standard `wasm.h` (`Apache-2.0`) — went when the C ABI was
replaced by the native `wazmrt.h`. **So wazmrt is now `MIT OR Apache-2.0` end to end, with no
incorporated code under any other terms**, which is the "self-owned" half of the vision's
*"dependency-free, and self-owned"*.

⚠️ **Everything below stays anyway.** The obligations, the Adoption Checklist and the distribution
rule describe what applies the moment something IS incorporated again. Deleting the machinery because
it is currently unused is exactly how the next vendored file arrives unrecorded.

## The distribution rule (2026-08-10) — ⚠️ **a compliant repository is not a compliant distribution**

Apache-2.0 §4(a) binds on **distribution**: recipients must get a copy of the license. The obligation
attaches to *the thing you hand someone*, not to the source tree it was built from. wazmrt satisfied it
in the repo (`third_party/wasm-c-api/LICENSE` + `NOTICE` + the ledger entry) while `zig-out/include/` —
the directory an embedder actually copies — carried `wasm.h` **alone**, and whoever copies it never sees
`third_party/`.

`build.zig` now installs, beside the two headers:

```
zig-out/include/LICENSE.wasm-c-api   the Apache-2.0 text (11.1 KiB)
zig-out/include/NOTICE               wazmrt's attribution notices (1.3 KiB)
```

- **Named for the header it covers, deliberately.** wazmrt's own code is `MIT OR Apache-2.0`; the
  vendored header is **Apache-2.0 only**. A bare `LICENSE` in an include directory invites conflating
  the two — which is how attribution quietly goes missing.
- Upstream wasm-c-api ships no NOTICE of its own, so §4(d) has nothing extra to propagate *from it*;
  wazmrt's own `NOTICE` carries the attribution and now travels with the headers.
- **The rule to apply next time: when vendoring anything, ask where the artifact goes, not where the
  file sits.** If a vendored file ends up in `zig-out/`, its license must too. Found only because the
  owner asked whether `wasm.h` was reference-only — it is not: wazmrt vendors it, implements all 174
  `wasm_*` exports against it, and ships it.

See `cmem/overview.md` for the resulting distribution manifest (ship `zig-out/include/` **whole**), and
`third_party/LICENSES.md` for the ledger checkbox that records it.

## Files

- `LICENSE-MIT`, `LICENSE-APACHE` — the two license texts (Apache is the canonical verbatim text).
- `NOTICE` — attribution + a statement that incorporated Apache-2.0 code retains its NOTICE and gets
  change-notes (§4 obligations). **Also installed to `zig-out/include/NOTICE`** by `build.zig`.
- `zig-out/include/LICENSE.wasm-c-api` — build output, not a source file: the vendored header's
  Apache-2.0 text, shipped so the distribution is compliant on its own (see the rule above).
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
