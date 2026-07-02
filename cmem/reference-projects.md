# Reference Projects

The nine candidate runtimes named at project inception. We **study** them freely and **adopt**
selectively — every adoption gated by the Adoption Checklist + a Component Ledger entry in
`third_party/LICENSES.md`. Licenses were **verified against each upstream `LICENSE` file on
2026-07-02** (not the GitHub badge — see `licensing.md`).

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

**Nothing incorporated yet (2026-07-02).** wazmrt's current code is 100% original. When code is first
adapted from one of these, move its row to **Adopted**, add the Component Ledger entry in
`third_party/LICENSES.md`, copy the upstream `LICENSE`/`NOTICE` into `third_party/<component>/`, and add
change-notes + SPDX headers to the adapting source (all per the Adoption Checklist).

## Notes on what likely earns its place first

- The **interpreter core** is the highest-leverage study target: wasm3 (threading/dispatch), wasmi
  (register machine), WAMR-fast-interp (footprint) are the leading small-and-fast designs.
- The **C embedding API** shape (wasmtime/wasmer C API, WAMR) informs how `wazmrt.h` should grow as we
  add instantiate/call.
- Prefer borrowing **ideas/designs** (no ledger entry needed) over **copying code** (always a ledger
  entry). Reimplementing a technique in Zig from understanding is cleaner for both licensing and fit.
