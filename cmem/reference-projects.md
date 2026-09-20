# Reference Projects

## 🔎 AUDITED 2026-09-20 — **six of the nine were never used for anything, and the compliance file no longer lists them**

**Measured, not recalled:** every project name searched across the whole repository with word
boundaries, excluding the two files that merely list them, each hit classified by where it lives.

| verdict | projects |
| --- | --- |
| **Behavioural reference in shipped code** (no code adapted) | **wasmtime** — diagnostic shape, a default recursion limit, a byte collision it named first. `src/interp.zig:473`: *"arrived at independently here and confirmed against"* |
| **Bake-off competitors only** (binary executed, source never read) | **wasmer**, **wazero** (and wasmtime) |
| **Formerly adopted, removed** | **wasm-c-api** — the vendored `wasm.h`, 2026-07-02 → 2026-08-11 |
| ⬜ **No occurrence anywhere in the tree** | **wasm3**, **WAMR**, **wasmi**, **wain**, **wai**, **rust-wasm** — and three of those six appear nowhere in the repository at all |

📌 **`third_party/LICENSES.md` now lists only the first three groups.** A row in a compliance file
is a claim that a licence was relevant to something we did; for the six it never was. **This file
keeps all nine**, because *why* a candidate was named is research worth keeping — the two documents
have different jobs, and conflating them is what let an inventory of intentions read as an
inventory of obligations for two months.

⚠️⚠️ **AND AN OPEN CONTRADICTION THIS AUDIT SURFACED — FOR THE OWNER, NOT FOR AN AGENT.**
The table below has a **"What to mine it for"** column and the sentence *"we study them freely"*.
🔒 **`interop.md` §1 says the opposite:** *"the oracle is still retired … reading a competitor's
implementation for guidance remains off-limits."* Both are current, both are binding-sounding, and
they cannot both be followed. The narrow reading is that the retirement is about the **sibling
`wasmrt`** specifically (§1's subject); the broad reading is the words as written, which would
forbid the entire "mine it for" column below. 🚫 **Not resolved here** — an agent does not narrow an
owner's rule by picking the reading that lets it do more work. ⬜ **It has cost nothing so far**,
because the audit shows no source of any of the nine has actually been consulted.

---

The nine candidate runtimes named at project inception. Licenses were **verified against each
upstream `LICENSE` file on 2026-07-02** (not the GitHub badge — see `licensing.md`). Every adoption
is gated by the Adoption Checklist + a Component Ledger entry in `third_party/LICENSES.md`.

| Project | License (SPDX) | Lang | What to mine it for | Status |
| --- | --- | --- | --- | --- |
| [wasm3](https://github.com/wasm3/wasm3) | `MIT` | C | Tiny, fast **interpreter** design (M3 "meta machine" / tail-call threading); smallest-binary tricks | Evaluating |
| [wasm-micro-runtime (WAMR)](https://github.com/bytecodealliance/wasm-micro-runtime) | `Apache-2.0 WITH LLVM-exception` | C | "Fast interpreter", AOT/JIT options, tiny footprint config, embedding API shape | Evaluating |
| [wasmtime](https://github.com/bytecodealliance/wasmtime) | `Apache-2.0 WITH LLVM-exception` | Rust | Spec-correct reference behavior, Cranelift codegen ideas, WASI, C API design | Evaluating |
| [wasmer](https://github.com/wasmerio/wasmer) | `MIT` | Rust | Multi-backend engine architecture, C API / embedding ergonomics | Evaluating |
| [wasmi](https://github.com/wasmi-labs/wasmi) | `Apache-2.0 OR MIT` | Rust | Register-machine **interpreter** design, validation structure (dual-licensed → cleanest to borrow from) | Evaluating |
| [wazero](https://github.com/tetratelabs/wazero) | `Apache-2.0` | Go | Zero-dependency design, optimizing interpreter + compiler, clean decoder/validator structure | Evaluating |
| [wain](https://github.com/rhysd/wain) | `MIT` | Rust | Small, readable spec-interpreter; decoder/validator clarity | Evaluating |
| [wai](https://github.com/k-nasa/wai) | `MIT` | Rust | Minimal interpreter reference | Evaluating |
| [rust-wasm](https://github.com/yblein/rust-wasm) | `ISC` | Rust | Minimal interpreter reference (ISC ≈ MIT) | Evaluating |

**License families present:** MIT (wasm3, wasmer, wain, wai), ISC (rust-wasm), Apache-2.0 (wazero),
Apache-2.0 WITH LLVM-exception (WAMR, wasmtime), and dual Apache-2.0-OR-MIT (wasmi). All permissive;
all compatible with our dual `MIT OR Apache-2.0` distribution. See `licensing.md`.

## Adoption status

⚡ **REVERSED 2026-08-11 — THE ONLY ADOPTION WAS UNDONE. NOTHING IS VENDORED; THE LEDGER IS EMPTY.**
The vendored `wasm.h` was deleted along with `src/wasm_c_api.zig`, and the C ABI is now the native
`include/wazmrt.h` (ABI 2). The nine runtimes below remain **Evaluating** — so wazmrt has adapted no
third-party code from anything, and is `MIT OR Apache-2.0` end to end.

🎓 **The adoption-checklist lesson this bought, which is the reason to keep reading the entry below:**
the ledger's own "Benefit" line — *"loaders bind once to a familiar ABI"* — was a claim about someone
else's code that nobody verified. It was false; the loaders use wasmtime's `wasmtime_*` API. **A
Benefit line is a HYPOTHESIS until you open that project's source and grep for it.** Full account in
`vision.md`; the replacement in `architecture.md`.

**First adoption 2026-07-02 — the C API standard (SINCE UNDONE, see above).** The owner chose to **mirror the wasm-c-api standard
`wasm.h`** as wazmrt's integration ABI (so `universalWasmLoader-*` and any wasm-c-api consumer bind
identically to how they'd bind wasmtime/wasmer). The canonical header (`WebAssembly/wasm-c-api`,
Apache-2.0) is vendored **verbatim** at `third_party/wasm-c-api/include/wasm.h`, pinned to commit
`9d6b9376`, with the first Component Ledger entry in `third_party/LICENSES.md`. Note: wasm-c-api was not
one of the original nine runtimes — it is the *standard* they implement.

The nine runtimes above remain **Evaluating** — no interpreter/decoder code adapted from them yet
(wazmrt's runtime code is still 100% original). When code is first adapted from one, move its row to
**Adopted**, add the ledger entry, copy the upstream `LICENSE`/`NOTICE` into `third_party/<component>/`,
and add change-notes + SPDX headers to the adapting source (per the Adoption Checklist).

✅ **CONFIRMED BY MEASUREMENT 2026-09-20, not by assertion.** *"Still 100% original"* had been a
claim carried forward since 2026-07-02 in a file that nobody re-checked — the same shape as the
ceilings that were copied forward from a stale artifact. It is now verified: the audit at the top
of this file found **no source of any of the nine consulted anywhere in the tree**, and the only
shipped mentions of any of them are wasmtime's observable BEHAVIOUR being matched, one of which
says in the code that it was arrived at independently. 🎓 *A status column is a dated claim like
any other; "Evaluating" for two months meant "nobody asked".*

## ~~C ABI decision (2026-07-02): mirror the wasm-c-api standard~~ — REVERSED 2026-08-11

- **Integration ABI = the vendored standard `wasm.h`** (every loader binds to it).
- **`include/wazmrt.h` = a small extension header** (version/ABI handshake + wazmrt-specifics), the
  wasmtime `wasm.h` + `wasmtime.h` pattern.
- **`src/wasm_c_api.zig` implements a growing subset.** "Minimal now" applies *within* the standard:
  back `config`/`engine`/`store` + `byte_vec` + `wasm_module_new`/`_validate`/`_delete` first; leave
  instance/func/trap/call declared-but-unimplemented until instantiation/execution exist (undefined
  symbols in a static lib only error if referenced).
- **Windows note:** the vendored header uses `__declspec(dllimport)` unless `LIBWASM_STATIC` is defined;
  since wazmrt ships a **static** lib, consumers compile with `-DLIBWASM_STATIC`.

## Notes on what likely earns its place first

- The **interpreter core** is the highest-leverage study target: wasm3 (threading/dispatch), wasmi
  (register machine), WAMR-fast-interp (footprint) are the leading small-and-fast designs.
- The **C embedding API** shape (wasmtime/wasmer C API, WAMR) informs how `wazmrt.h` should grow as we
  add instantiate/call.
- Prefer borrowing **ideas/designs** (no ledger entry needed) over **copying code** (always a ledger
  entry). Reimplementing a technique in Zig from understanding is cleaner for both licensing and fit.
