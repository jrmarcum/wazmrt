# Roadmap

## 🏁 CURRENT PROGRAM (owner, 2026-08-11) — smallest + fastest-starting, and self-owned

**The competitive frame, stated by the owner:** `wasmrt` (the Rust port) and `wazmrt` are **in
competition** for which becomes the wasm runtime inside **wasmtk** and **rsxtk**. The target is *"the
fastest smallest version we can distribute that performs as a general wasm runtime"* — **`ReleaseSmall`
is a goal, as much as security is.** Compatibility means running the **same modules wasmtime runs**
(spec + proposal parity). ⚠️ **The component model is explicitly OUT of scope — wazmrt is a RUNTIME, not
a loader.** Canonical-ABI marshalling belongs to the `universalWasmLoader-*` layer (see wasmrt's
`cmem/loaders.md`), and rsxtk uses none of it (its `component-model` Cargo feature is enabled but
**never called** — dead weight in the consumer).

### Decision 1 — DELETE the wasm-c-api surface outright (owner, 2026-08-11)

Not an opt-in compat build, not a deprecation: **full delete**, replaced by a native `wazmrt.h`. See the
decision entry in `design-decisions.md`. This is what makes `third_party/` **empty** and wazmrt **100%
self-owned** — the vision's own words are *"dependency-free, **and self-owned**"*, and only the vendored
header stood between us and the second half. Reusing `wasmrt`'s lessons is explicitly sanctioned by the
owner and raises **no third-party question at all** — it is the same owner's `MIT OR Apache-2.0` code.

### Decision 2 — the consumer regime is the DEV LOOP, on un-precompiled `.wasm` (owner, 2026-08-11)

rsxtk has **dropped `.cwasm` as its primary path**: the format is machine-specific and *not a
cross-platform standard*, so **`.wasm` is the chosen end product** and `.cwasm` becomes an end-user
option. ⚠️ **This reverses the analysis of 2026-08-11 morning**, which had found rsxtk's AOT cache
(`build_and_cache_script` → `Module::deserialize_file`) neutralising wazmrt's cold-start advantage. With
`.wasm` as the default, **wasmtime pays a full Cranelift compile on every single run** — and rsxtk
configures `OptLevel::Speed`, the *slowest-starting* setting. A development environment runs **many
short runs, not few long ones**, so a small fast-starting interpreter is the right shape by design.

**🎯 The prioritisation this dictates — `decode → validate → instantiate` is now a FIRST-CLASS metric**,
alongside steady-state Mops/s rather than instead of it.

⚠️ **OWNER CORRECTION, 2026-08-11 — an earlier draft of this section deprioritised the A → A.5 → B perf
ladder and that is OVERRULED. Do not descope it, and do not descope running `.wat` files either.**
Both stay fully in scope. The reasoning that led to the deprioritisation (a dev-loop consumer pays
startup far more often than hot-loop throughput) is *sound as far as it goes* and is why startup gets
promoted — but it is not a reason to stop optimizing execution, and the earlier text overreached from
"startup matters more than we treated it" to "throughput matters less than it does".

**How the two goals are reconciled — the size gate is the referee.** Speed and `ReleaseSmall` genuinely
pull against each other, so the rule is *not* to pick a winner in advance: **every optimization must pay
its way in measured bytes** against the Track 2a size ceiling. A.5 (partial evaluation +
superinstructions) is the first lever precisely because it is largely a *decode-time* transformation —
it can buy throughput at modest, and measurable, size cost. Option B (register machine) is the bigger
bet and gets measured the same way. **Reject an optimization on measured bytes-per-percent, never on a
prior assumption about which regime matters.**

⚠️ **Fairness rule for any benchmark (binding): compare against wasmtime configured for FAST START**
(`OptLevel::None`, or the Winch baseline compiler), **not only `OptLevel::Speed`.** Beating a runtime in
its slowest-starting configuration proves nothing, and publishing that number is the same error as the
falsified wasm-c-api payoff — a claim that dies on first contact with someone who checks.

### Measured baseline (2026-08-11, `ReleaseSmall`, dev box) — and a size regression nobody caught

| Artifact | 2026-08-11 | recorded 2026-07-14 | drift |
| --- | --- | --- | --- |
| C-ABI **DLL** | **227,328 B** (222 KB) | 130 KB | **+75%** |
| C-ABI **static lib** | **279,444 B** (273 KB) | 123 KB | **+122%** |
| **CLI exe** | **911,360 B** (890 KB) | — | — |

**The artifacts roughly DOUBLED in a month while "smallest binary" was a stated goal, because nothing
re-measured them** after memory64, threads/atomics, full SIMD, GC const-exprs and the hardening landed.
*Lesson, and it is the same one as the licence gap: a goal with no gate is a preference.*

**Security-vs-size, measured not argued:** the same DLL built `ReleaseSafe` is **1,238,016 B — 5.4×**
the `ReleaseSmall` build. A 990 KB tax is unpayable when size is first-class, so **ship `ReleaseSmall`**
— and accept the consequence explicitly: `ReleaseSmall` **disables Zig's runtime safety checks**, so
wazmrt's *own* hardening (13 audit passes, `test-safe`, the Budget-allocator fuzz, `test-security`)
**is** the memory-safety floor. Those gates are product requirements now, not hygiene.

**First head-to-head (same box, both size-tuned):** C-ABI shared library — **wazmrt 222 KB vs wasmrt
554 KB (2.5× smaller)**; CLI — wazmrt 890 KB vs wasmrt 684 KB. Not feature-parity-verified; the Rust
`.a` is not comparable (metadata + bitcode). **The embed footprint is wazmrt's strongest card**, and it
is measured *before* deleting the 176-export wasm-c-api surface.

### The structural asymmetry — name it, don't wish it away

| Consumer | fair fight? | favoured | why |
| --- | --- | --- | --- |
| **wasmtk** (Deno/TS) | **yes** | **wazmrt** | both sit behind FFI; wazmrt's DLL is 2.5× smaller |
| **rsxtk** (Rust) | **no** | **wasmrt** | native crate — zero FFI, zero `unsafe`, no DLL to ship |

**rsxtk needs only ~15 runtime operations** (`Engine`/`Config`, `Linker` + WASI-p1, `Module::new`,
`Store`, instantiate, func-by-name, untyped `Val` call, `_start` + `I32Exit`, imports/exports
introspection, `preopened_dir`/args/env) — a smaller surface than the loaders' 38 or `wasmrt.h`'s 74, so
either runtime can serve it technically. **Its WAT comes from the `wat` crate, not the runtime**, so
wazmrt's WAT assembler is CLI weight, never embed weight. **And the pitch to rsxtk vs wasmtime is not
raw speed — it is dropping Cranelift**: binary size, build time, no machine-keyed artifacts, no `unsafe
deserialize_file`.

### ⚠️ THE SLOT IS EMPTY — surveyed 2026-08-11, and it reframes the whole competition

Every consumer was read, not assumed (the lesson from the falsified payoff). **Neither wazmrt nor
wasmrt is in ANY of them yet. All are still on wasmtime or V8.**

| Consumer | Runs wasm today via | Native-runtime hook |
| --- | --- | --- |
| **wasmtk** (Deno/TS) | **`WebAssembly.instantiate` — V8**, incl. inside the **bindgen codegen** | **none** — its only `Deno.dlopen` calls `kernel32.SetConsoleOutputCP` |
| **rsxtk** (Rust) | wasmtime 40.0.1 + Cranelift | native crate (wasmrt's, by language) |
| **universalWasmLoader-c/-v/-zig** | **wasmtime C API v45.0.2**, vendored per triplet | `universal_wasm_loader.h` |
| **-go/-jvm/-py/-dotnet** | wazero / Chicory / wasmtime-py / Wasmtime-NuGet | FFI over the C header |
| **-js/-dart** | host `WebAssembly` | wasm-in-wasm (heaviest, last) |

**So the fight is not wazmrt vs wasmrt over an occupied seat — it is both of them vs *wasmtime*, over a
seat nobody holds.** That is a better position than it sounds, and it changes what wins:

1. **API shape is the port cost.** The C loader uses `wasmtime_store/context/module/instance/memory/
   linker`, and `uwl__import_trampoline` reads guest memory via **`wasmtime_caller_export_get(caller,
   "memory")` + `wasmtime_memory_data`** — the caller-in-callback pattern wasm-c-api structurally cannot
   serve. **This is direct confirmation of the falsification** *and* of the fix: `wasmrt.h`'s shape is
   derived from exactly these calls, so **matching it makes wazmrt a near-mechanical port for the
   loaders AND A/B-swappable against wasmrt.** Do not invent a third shape.
2. **Distribution is the real selling point, not speed.** The loaders today **fetch a prebuilt wasmtime
   C API SDK per platform triplet from GitHub releases** (`scripts/fetch-wasmtime.sh`, sha512-pinned in
   the vcpkg port, *no* upstream vcpkg port exists, static-linked at v45.0.2). Replacing megabytes of
   per-triplet vendored SDK with a **222 KB self-owned library** removes an entire supply-chain and
   build-system burden. **This is where wazmrt wins on merit today** — before any benchmark.
3. **Licensing freedom becomes REAL here** (unlike the falsified drop-in claim): wasmtime is
   `Apache-2.0 WITH LLVM-exception`; post-delete wazmrt is `MIT OR Apache-2.0`, 100% self-owned, with
   **nothing to propagate** into a loader's distribution.

**🥇 Cheapest real foothold — do this before any ABI work.** `wasmtk/tests/dync_cross_runtime_tests.ts`
already runs wasmtk's output through `RUNTIMES = ["wasmtime", "wasmer", "wazero"]` for portability.
**wazmrt is not in that list**, though it already runs **all 400 runnable files of the wasmtk WASI
corpus** (`testing.md`). Adding it costs near-nothing and puts wazmrt in front of a consumer's own gates
as a peer of the runtimes it means to replace. **Evidence in someone else's test suite beats a claim in
ours.**

⚠️ **And the honest counterweight for wasmtk:** getting in there is **wasmtk-side work bigger than a
binding** — replacing `WebAssembly.instantiate` in `utils.ts`/`wast.ts` *and* in the **bindgen codegen**,
turning every host import into a `Deno.UnsafeCallback` (a JS↔native hop per call, which **partly
re-introduces the boundary cost the vision claims to remove — measure it, do not assume it**), and
reading guest memory via `Deno.UnsafePointerView`. No amount of wazmrt-side ABI work substitutes for it.

### 🎯 Spec-conformance fix list (2026-08-11) — ✅ CLOSED 2026-08-12. Details in `known-issues.md`

From the full `tests/module/` run. ⚠️ **Every HIGH item is wazmrt being TOO PERMISSIVE** — the
opposite of the failure mode most of the audit passes hunted, and in a corner nobody had run before.

**Every row below is RESOLVED — nothing here needs work.** T5 is marked "not a defect", which means
*investigated and found not to exist*, not *left undone*: its two files pass and its class has zero
instances corpus-wide. (An earlier revision used a bare ❌ for that, which reads as "failed". Say it
in words.)

| | defect | assertions | outcome |
| --- | --- | --- | --- |
| **T1** 🔴 | **Accept-invalid** — malformed modules ACCEPTED | 43 → **68** | ✅ FIXED 2026-08-12 |
| **T2** 🔴 | A custom-page-size module accepted **then mis-executed** — `memory.grow` → −1 | 12 | ✅ RESOLVED — dissolved by T1 |
| **T3** 🟠 | **legacy `rethrow`** — a stale workaround + an accept-invalid | 3 | ✅ FIXED 2026-08-12 |
| **T4** 🟠 | ~~a legacy `try`/`catch` encoding not decoded~~ — actually the **tail-call proposal** | 2 | ✅ IMPLEMENTED 2026-08-12 |
| **T5** 🟡 | oversized limits refused at the wrong STAGE (decode, not link) | 2 | ✅ RESOLVED — **was not a defect**; see below |

**T1 was bigger than the triage said, and the guess about its cause was wrong.** Corpus
**525 → 455 failures**, 86 → 82 files, zero regressions. Details in `known-issues.md`; the headline is
that the *main* `testsuite-main/binary.wast` carried **the same 25 failures** as the
`custom-descriptors` copy, so this was a **core-spec** defect that the proposal-dir framing hid. The
suspected cause (a reserved limits-flag bit) was **not** it — `readLimits` already rejected `flag >
0x07`. Four separate gaps, each hiding the next:
section **order/uniqueness** unchecked (16) · section **size** unchecked (7) · **data-count section
required** unenforced (2) · the **WAT assembler silently dropping trailing `(memory …)` forms** (18).

⚠️ **T5 was never a defect — strike it.** All four assertions in `memory_max.wast` use `(pagesize …)`.
The "wrong stage" was wazmrt *dropping* the pagesize and building `(memory 0xFFFF_FFFF (pagesize 1))`
as a **default**-page-size memory, which legitimately overflows → `InvalidLimits` at decode. It was a
symptom of T1's fourth gap, and both files went clean when that was fixed. **A defect classified by
its error message can be a shadow of a defect three layers up.**

⚠️ **THREE OF THE FIVE ITEMS WERE MISLABELLED** — T1's location (core spec, not a proposal dir), T5's
existence (a symptom of T1), and T4's subject (tail calls, not EH). The triage classified 164 failures
by each file's **first-failure text**, and that text names a symptom. Corpus **525 → 452 failures**.

**The whole list is closed.** T1/T3 fixed, T2/T5 dissolved, T4 implemented (the tail-call proposal —
`return_call`/`return_call_indirect`, opcodes `0x12`/`0x13`, plus `return_call_ref` rebuilt as a REAL
tail call). Session total: **525 → 275 corpus failures**, 60,568 → 61,115 passing, zero regressions at
any step.

⚠️ **`return_call_ref` is the cautionary tale of the whole series.** It was recorded as shipped with
function-references, and it passed every shallow assertion — but it was implemented as
call-then-return, so the one property the proposal exists to provide (unbounded depth) was absent.
**A feature can be present, tested, and green while failing at exactly the thing it is for.** Same
family as the memory64 "COMPLETE" claim above.

### 🎯 REVISED conformance list (2026-08-12) — the 275, now **207** after R1–R5 + R10

Successor to the T-list above, and built differently: every item below is grouped **by cause**, from a
run with `-Dfailures=600` so all 275 failures were read, not just each file's first. The T-list was
grouped by first-failure text and mislabelled three of its five items.

⚠️ **The per-item counts below are as-triaged (275 total) and are NOT live.** R1–R5 and R10 are done, R6 was
closed by R3 and R8 by R5 — corpus is **207 failures / 62,737 passing / 1,013 skipped** (measured
2026-08-13, after R10). **LIVE SPLIT: 98 by design + 109 actionable** (R9 85, R7 18, R10 residue 32
 is in the skip column not the failure one, legacy EH 2, misc 4). Every count below is high;
re-measure before trusting any of them
(`-Dfailures=600`, diff the per-file summary against the previous run).

⚠️ **THE FAILURE COUNT WENT UP AT R5 AND THAT IS THE PASS WORKING.** 143 → 216 while passes went
61,429 → 62,333 and skips 2,407 → 1,429: R5 implemented `(module quote …)`, so 978 assertions that
had never executed started to, and 904 of them pass. **Judge a conformance pass by what it RUNS, not
by the failure total** — and check that no file lost passes (join the per-file counts; R5 did, and
none had). A pass that only ever drives the red number down is a pass that can be gamed by skipping
more.

**Of the current 216, by design** — proposals wazmrt does not target, refused honestly. They
are not defects and there is nothing to fix unless the scope changes:

| | area | failures (live, after R5) | note |
| --- | --- | --- | --- |
| — | `custom-descriptors` | 90 → 88 → 82 → **84** | untargeted proposal; exact refs + descriptors. R5 unblocked more of it than it fixed, hence the rise |
| — | `custom-page-sizes` | **12** | untargeted; refused as `UnsupportedProposal` (scored as SKIPS, not passes) |
| — | `wide-arithmetic` | **2** | untargeted; was miscounted as actionable until R3 |

⚠️ **`wide-arithmetic` 2 was counted as ACTIONABLE and is not** — it is an untargeted proposal like
the two above, so the "101 by design / 92 actionable" split written on 2026-08-12 was off by two in
both directions. Corrected here rather than propagated.

**LIVE SPLIT after R10 (2026-08-13): 207 failures = 98 by design + 109 actionable** — R9 **85**,
R7 **18**, legacy EH **2**, misc **4**. R10's residue (32) now sits in the SKIP column, not the
failure one: `ref_null` 27 and `id` 5 are files whose first module still will not build.

**The actionable items, most valuable first:**

| | item | failures | why it matters |
| --- | --- | --- | --- |
| **R1** 🔴 | **Cross-module type identity** | 25 | ✅ **FIXED 2026-08-12 — and it was 38, not 25.** See below. |
| **R2** 🔴 | **elem / linking / instance** | 42 → 35 | ✅ **FIXED 2026-08-13 — five causes, and 44 failures, not 35.** All five files CLEAN. See below. |
| **R3** 🟠 | **GC array bulk ops MISSING** | ~10 → **16** | ✅ **FIXED 2026-08-13 — SIX ops missing, not four, and the cost was in SKIPS, not failures.** See below. |
| **R4** 🟠 | **Accept-invalid in core files** | ~15 → **12** | ✅ **FIXED 2026-08-13 — five causes, and two of them ALSO caused false rejects.** Core accept-invalid is now **0**. See below. |
| **R5** 🟡 | **Runner gaps, not wazmrt defects** | 41 → ~23 → **1,291** | ✅ **FIXED 2026-08-13 — and the item was undercounted by 50×.** `(module quote …)` alone was suppressing **1,291 assertions**. See below. |
| **R6** 🟡 | GC type remainder + `i31` | 20 → 8 → **0** | ✅ **CLOSED 2026-08-13, and R3 closed it without aiming at it.** R1 took `type-subtyping`/`type-rec`; the last 8 were `i31.wast`, and they were not an i31 defect at all — the file uses `(elem $e i31ref …)` and the assembler's `isRefType` listed only `funcref`/`externref`, so the whole segment was misread as func indices. One shorthand-table fix, `i31.wast` 8 → 0. |
| **R7** 🟡 | threads | 15 → **18** | `proposals/threads/imports.wast` 13, `memory.wast` 5 (R5 unblocked 3 more). Mostly shared-memory import matching, plus **12 accept-invalids** — the only ones left outside core and the untargeted proposals, so R4's safety argument applies here. ⚠️ **R1 did NOT touch it** despite being "adjacent": those 13 are limits/`shared`-flag matching, not type identity. |
| **R8** ⚠️ | **UTF-8 name validation is UNVERIFIED** | 0 failures | ✅ **CLOSED 2026-08-13 by R5 — it was the runner's gap, and the answer was "all 176 pass".** `utf8-invalid-encoding.wast` was 0/0/**176 skipped** because every assertion in it is an `assert_malformed (module quote …)`, and the runner could not build a quoted module. Implementing that form ran all 176 and they pass: UTF-8 name validation was genuinely correct, and had simply never been checked. **The question the item asked — "is the skip the runner's gap or ours?" — was the right one, and R5 answers it.** |
| **R10** 🔴 | **first-module failures that BLACK OUT whole files** | 13 failures / ~420 skips | ✅ **FIXED 2026-08-13 — 416 assertions unblocked for +1.5 KB, the best ratio of the series.** Six causes; see below. Residue: `ref_null` 27 + `id` 5, both diagnosed. *(Original entry: )* **Opened 2026-08-13 (R5's residue). Highest value left, by a wide margin.** Nine core files fail on their FIRST module and take the whole file into `NoTarget`: `br_table.wast` **161 skipped** (a `TypeMismatch` on `(block (drop (i32.ctz (br_table 0 0 …))))` — br_table in a polymorphic position), `ref_test` **66**, `simd_lane` **51**, `ref_cast` **40**, `ref_null` **32** (`(ref.null exn)` — `abstractHeapCode` has no `exn` entry, a ONE-LINE gap), `br_on_cast`/`br_on_cast_fail` **25 each**, `extern` **16** (`extern.convert_any`/`any.convert_extern` have no mnemonic in the assembler although the decoder and interpreter both implement them — the producer/consumer pair again), `id` (exotic and quoted `$"…"` identifiers). ⚠️ **13 failures, ~420 assertions suppressed** — the R3/R5 shape for the third time: **a single-digit failure count next to a triple-digit skip count is a blackout.** |
| **R9** 🟠 | **NEW — accept-invalid in the TEXT front end** | **85** | 🆕 **Opened 2026-08-13; this is R5's output.** The class R4 closed for the binary decoder, on the surface the corpus could not reach until `(module quote …)` ran. Groups: **35** type-use ordering (`(if (type $sig) (result i32) (param i32) …)` in `func`/`call_indirect`/`return_call_indirect`), **15** token separation (`(data"a")` needs whitespace between a keyword and a string — `token.wast`), **8** SIMD lane rules, and ~27 spread over `table`/`memory`/`type`/`global`/`id`/`start`/`struct`/`block`/`if`/`loop`/`obsolete-keywords`. Same safety argument as R4: `wasm_module_validate` is a shipped C-ABI entry point. |

**Recommended order: ~~R1~~ → ~~R2~~ → ~~R3~~ → ~~R4~~ → ~~R5~~ → R10 → R9 → R7.** ~~R6 closed by
R3~~, ~~R8 closed by R5~~.

**Recommended order after R10: R9 → R7.** R9 is 85 real defects but they are 85 separate refusals to
write; R7 is 18 and self-contained. **The ordering rule this list keeps re-learning: rank by
assertions unblocked, not by failures closed** — R10 proved it again, closing 416 for +1.5 KB.

### ✅ R10 IS DONE (2026-08-13) — 416 assertions unblocked, six causes, +1,536 bytes

**Corpus 216 → 207 failures, 62,333 → 62,737 passing, 1,429 → 1,013 skipped.** No file lost a pass.
The failure count barely moved and 404 more assertions PASS — which is the whole point of the item:
these were files nobody could run, not files that were failing.

| | cause | unblocked | what it was |
| --- | --- | --- | --- |
| C1 | **`extern.convert_any` / `any.convert_extern` existed only in const-exprs** | **172** | `validateConstExpr` and `evalConstExpr` implemented them; there was no `Op`, so a FUNCTION BODY using one was `UnknownInstr`. Opened `ref_test`, `ref_cast`, `br_on_cast`, `br_on_cast_fail`, `extern`. **A feature implemented for one of its two contexts reads as implemented.** |
| C2 | **`br_table` carried a cross-label rule the spec does not have** | **161** | A "#2f" audit finding added a pairwise subtype check between each label and the default. §3.3.5.9 wants one `[t*]` that is a subtype of every label; after `unreachable` the stack supplies ⊥, so pairwise-incompatible labels are jointly satisfiable. `br_table.wast` names the case `meet-bottom`. **Deleted, not narrowed** — the pops already catch real mismatches in reachable code. |
| C3 | **`popVals` + `pushVals` is not `push_opds(pop_opds(…))`** | (with C2) | The probe substituted CONCRETE types for the ⊥ it popped, so checking label 0 poisoned label 1's check. Now `popPushVals` puts back exactly what it took. |
| C4 | **flat `else $l` / `end $l` unconsumed** | **5** | §6.5.2's label repetition. The id was assembled as the next instruction → `UnknownInstr` naming a label, killing `stack.wast`. Now consumed *and checked*, which is the only reason the form exists. |
| C5 | **`br_on_non_null` popped the label's types wholesale** | **33** | The label's last type is `(ref ht)`; the operand is `(ref null ht)`. Popping `lt` asked the stack for the non-null form and rejected the canonical idiom. Two files. |
| C6 | **`br_on_cast_fail` carried `src`, not `src \ dst`** | **25** | With a nullable dst a null takes the fall-through, so the branch value is non-null. The subtraction was already written eleven lines below for br_on_cast's fall-through — **the same rule applied to one of the two paths that need it.** |

⚠️ **Two of the six were rules we INVENTED, not rules we missed.** C2's cross-label check came from an
audit finding whose reasoning was sound — `popVals` genuinely cannot catch a mismatch on a
polymorphic stack — and whose conclusion was wrong, because on a polymorphic stack there is nothing
to catch. Its comment even claimed it "never rejects a valid subtyped `br_table`". **A finding can be
well-argued, land a real check, and still be inventing a requirement**; the corpus is the arbiter, and
it had been telling us so from behind a `NoTarget` cascade for months. The unit test that encoded the
invented rule had to be inverted along with the code.

⚠️ **`nullexnref` was modelled as `nullref` (the ANY-family bottom) and R10 made that
load-bearing.** Once `(ref.null noexn)` decoded to the exn head, the two spellings of one type
disagreed and `(global $nullexn nullexnref (ref.null noexn))` was a `TypeMismatch` against itself.
Fixed by mapping `0x74` into the exn family. **Two encodings of one type must land on one value type;
picking the wrong FAMILY only shows up when both spellings meet.**

**R10's residue (32 assertions), diagnosed and left:**
- `ref_null.wast` **27** — `(func (result (ref null $t)) (global.get $nullfunc))` where `$nullfunc`
  is `nullfuncref`. We fold `nullfuncref`/`nullexternref` onto `funcref`/`externref`, which loses
  their BOTTOM-ness, so they cannot flow into a concrete `(ref null $t)`. The real fix is distinct
  bottom types in `types.zig` plus `subtypeOf` support — a lattice change with wide blast radius,
  and its own item rather than an R10 footnote.
- `id.wast` **5** — exotic identifiers (`$!?@#a$%^&*b-+_.:9'`|/\<=>~`) and quoted `$"…"` ids, a
  lexer gap in `sexpr.zig`.

### ✅ R5 IS DONE (2026-08-13) — 978 suppressed assertions unblocked, and the item was 50× bigger than filed

**Corpus 143 → 216 failures, 61,429 → 62,333 passing, 2,407 → 1,429 skipped.** No file lost a single
pass — verified by joining the per-file pass counts, not by reading the totals. The failure count
went UP and that is the pass working: 978 assertions that had never executed now do, 904 of them
passing.

⚠️ **The item said "~23". It was 1,291.** R5 was filed as "`(module quote …)` and 21 `NoTarget`
cascades", triaged from the FAILURE column. But an unimplemented command form does not produce
failures — it produces **skips**, and skips were never itemised. One `return error.BadCommand` in
`moduleBinary` was suppressing **1,291 assertions, more than half of every skip in the suite**,
because a quoted module is how the spec tests anything about *text*: malformed literals, bad tokens,
invalid names. **An item triaged from the failure column will always undercount a defect whose
symptom is a skip** — R3 hit the same shape at a tenth the scale.

⚠️ **R8 was a subset of R5 and nobody noticed.** `utf8-invalid-encoding.wast` is 176
`assert_malformed (module quote …)` assertions — every one skipped for the same single reason. R8
was filed separately, as "an unverified security-relevant check", and its own text asked exactly the
right question: *is the skip the runner's gap or ours?* It was the runner's. All 176 now run and
pass. **Two items with one cause, filed apart because one was counted in failures and the other in
skips.**

**What R5 revealed is bigger than what it fixed.** Running those 1,291 assertions surfaced **215
accept-invalid failures in the WAT assembler** — the same class R4 had just closed for the binary
decoder, in a surface the corpus had never been able to reach. Two causes accounted for ~146 and are
fixed here because they are one theme, *lenient literals*:

| | cause | count | what it was |
| --- | --- | --- | --- |
| C1 | **`std.fmt.parseInt`/`parseFloat` used as the wasm literal grammar** | ~70 | Zig accepts `_` where wasm forbids it (`0x_100`, `0x00_`, `0xff__ffff`) and takes a leading-point float (`.0`, `.0e0`). Replaced by `validIntLit`/`validFloatLit` over §6.3.1. |
| C2 | **out-of-range constants silently TRUNCATED** | ~76 | `i32.const 0x100000000` became `0`; `v128.const i8x16 0x100` became sixteen zero bytes; `f32.const 0x1p128` became `+inf`. Each is a **wrong value compiled from source that looked fine**, not merely a missed assertion. Each `v128` lane is now bounded by its own width. |

Two smaller ones went with them: a bare `-nan` lost its sign bit (the sign was applied only on the
`nan:…` path, and NaN sign is observable through `reinterpret`/`copysign`), and
`(f32.const nan:arithmetic)` assembled — those two spellings are result MATCHERS for an assertion,
never values in a module.

⚠️ **R4's "core accept-invalid is ZERO" is now FALSE, and it was true when written.** R4 closed every
accept-invalid the corpus could *see*; R5 gave the corpus eyes for the text front-end and 88 more
appeared in core files. This is the cleanest instance yet of the standing rule: **a conformance
number says nothing about a surface the corpus does not reach** — and "the corpus reaches it" is
itself a property that can silently be false.

**R9 — the remainder, for whoever takes it next.** 88 core accept-invalids, grouped:
`func`/`call_indirect`/`return_call_indirect` **35** (the `(type $sig) (result …) (param …)` ordering
rule in a type use), `token.wast` **15** (token separation — `(data"a")` needs whitespace between a
keyword and a string), `simd_lane` **8**, and ~30 spread over `table`/`memory`/`type`/`global`/
`id`/`start`/`struct`/`block`/`if`/`loop`/`obsolete-keywords`. Plus 20 `custom-descriptors` and 12
threads, which belong to the untargeted proposal and R7 respectively.

### ✅ R4 IS DONE (2026-08-13) — 157 → 143, and core accept-invalid is now ZERO

**Corpus 157 → 143 failures, 61,412 → 61,429 passing, 2,412 → 2,407 skipped**, zero regressions in
the full per-file diff. Five core files went entirely clean — `table.wast`, `ref.wast`,
`ref_func.wast`, `tag.wast`, `try_table.wast`. **Every accept-invalid in a core spec file is closed**;
the 29 that remain are 20 in `custom-descriptors` (untargeted) and 9 in `proposals/threads`, which is
R7's.

The 12 triaged failures were **five causes**, and the item's framing — "modules we wrongly accept" —
was only half the story: **two of the five ALSO caused false rejects**, so the same off-by-one was
simultaneously letting invalid modules in and keeping valid ones out.

| | cause | count | what it actually was |
| --- | --- | --- | --- |
| C1 | **a non-defaultable table element type with no initializer** | 5 | `(table 0 (ref func))` has no starting value for its slots and is invalid at ANY length; the rule was unchecked, and the `0x40`-form initializer that exempts a table from it was never validated either |
| C2 | **`try_table` catch labels resolved one frame too deep** | 3 | +1 false reject — see below |
| C3 | **a block type naming an out-of-range type index** | 2 | the assembler INTERNED the signature, manufacturing the very index that made it valid |
| C4 | **an imported tag's result type unchecked** | 1 | the loop walked `module.tags`, the DEFINED half of the space |
| C5 | **the start function treated as declaring a `ref.func`** | 1 | §3.5.1 erases `start` when building `C.refs`; the code, the comment above it, and the test all said otherwise |

⚠️ **C2 is the headline, and it is the producer/consumer rule generalised: THREE implementations
agreed with each other.** A `try_table` catch clause's label indexes the *enclosing* scope — the EH
proposal checks the catches in `C` and only the body in `C, labels [t2*]`. `wat.zig` pushed the
try_table's own label before resolving catch targets, `validate.zig` resolved them after
`pushCtrl`, and `interp.zig` branched to `d + c.label`. All three were off by exactly one frame, in
the same direction, so every round trip was self-consistent and the corpus was green. It took
reading the spec rule to see it — no test could, because the three parties that would have to
disagree never did. **Two consumers agreeing is not corroboration when they share the mistake.**

⚠️ **And it failed in both directions at once.** `(func (result exnref) (try_table (catch 0 0))
(unreachable))` was ACCEPTED (label 0 is really the function block `[exnref]`, which a plain `catch`
delivering `[]` cannot satisfy), while `(func (result exnref) (try_table (catch_ref $e 0)) …)` was
REJECTED (the same label fits `catch_ref` exactly). One off-by-one, an accept-invalid and a false
reject, in the same file. **When a rule is off by a constant, look for failures in both directions
before believing the item's framing.**

⚠️ **C1 and C3 were both workarounds in the ASSEMBLER, and both stopped being cosmetic.**
- `(table N reftype initexpr)` was lowered to a synthetic active element segment of N copies, on the
  recorded reasoning that the resulting table state is observably identical and the distinct `0x40`
  encoding "is not required for the execution assertions". The state is identical; the MODULE is not
  — a table with an explicit initializer and a table with an element segment differ in exactly the
  property validation needs, so `(table 0 (ref func))` became indistinguishable from a legal one.
- A block type with a single concrete-ref result was emitted as an interned type index, because
  `readBlockType` could not decode the canonical multi-byte valtype `0x63/0x64 ht`. Interning
  *creates a type-section entry*, so `(block (result (ref 1)))` in a one-type module made index 1
  exist — as the block's own signature, self-referentially — and validated clean.

**An encoding chosen to make execution agree can erase the distinction validation runs on**, and **a
workaround in the producer for a gap in the consumer does not stay cosmetic**. Both are fixed at both
ends; `readBlockType` now decodes the canonical form and `BlockType` grew a `.ref` variant.

⚠️ **C5's wrong rule was written down three times.** The code set `refs` from the start function, the
comment above it listed "or the start function" among the declaring positions, and the unit test
asserted `(module (func $f) (start $f) … (ref.func $f))` valid under the heading "each of the four
declaring positions". There are three. **A test that encodes the same misreading as the code is not
evidence — it is the misreading, restated.**

⚠️ **Two more defects surfaced inside the R4 files after the five landed**, both false rejects:
`exnref_nn` was defined in `types.zig` and taught to `readBlockType` but never to `Module.readValType`
(so `(ref exn)` worked as a block type and was `BadValType` everywhere else), and `checkCatch`
compared the materialized exception reference as the *nullable* `exnref` when `catch_ref` produces a
non-null `(ref exn)`. Fixing the first only changed the error message of the second — **a failure's
cause count is not known until it passes**, for the third pass running.

**Size: R4 came out SMALLER** — −512 exe / −116 lib / −512 dll — because deleting the two workarounds
cost more than the five rules add. The N-copies table lowering is gone, and with it the
`max_table_init_copies` cap that existed only to bound its allocation amplification. **Removing a
workaround can pay for the rule that made it unnecessary.**

### ✅ R3 IS DONE (2026-08-13) — 193 → 157, and **225 skipped assertions became real runs**

**Corpus 193 → 157 failures, 61,187 → 61,412 passing, 2,637 → 2,412 skipped**, zero regressions in
the full per-file diff. All seven target files are CLEAN: `array.wast`, `array_copy.wast`,
`array_fill.wast`, `array_init_data.wast`, `array_init_elem.wast`, `array_new_data.wast`,
`array_new_elem.wast` — together **20 passed / 16 failed / 197 skipped → 215 passed / 0 failed /
2 skipped**.

⚠️ **The item named four ops. SIX were missing.** `array.new_data`, `array.new_elem`,
`array.init_data`, `array.init_elem` — *and* `array.fill` and `array.copy`, which the triage never
mentioned because it read failure messages and every one of those files died on its *first*
instruction. `array_fill.wast` and `array_copy.wast` each reported exactly **1 failure** while
running **zero** assertions. **An estimate built from error messages undercounts** — third time.

⚠️ **THE REAL COST WAS NEVER IN THE FAILURE COLUMN.** R3 was triaged at ~10 failures and scored 16,
which reads as a small item. It was not: a module that fails to build takes *every assertion that
targets it* into `NoTarget` skips, so the six missing ops were suppressing **197 assertions in the
target files and 225 corpus-wide**. Failures went down 36; *runs* went up 225. **When triaging by
failure count, read the SKIP column in the same row** — a file at `0 passed, 1 failed, 34 skipped`
is a total blackout wearing the badge of a single defect.

**What each op needed, and where the work actually was:**

| | layer | what was missing |
| --- | --- | --- |
| C1 | `opcode.zig` | six `Op` tags + three new `Imm` shapes (`gc_data`, `gc_elem`, `gc_array_copy`) and their `0xFB` sub-opcodes `0x09/0x0a/0x10/0x11/0x12/0x13` |
| C2 | `wat.zig` | the mnemonics — **this is where every `.wast` actually died**, at `UnknownInstr`, before the decoder was ever reached |
| C3 | `validate.zig` | element-type rules (a data segment cannot initialise a *reference* element), mutability for the four writing forms, `elem_type <: t'` by subtyping, and the data-count requirement |
| C4 | `interp.zig` | little-endian element decode at the element's own byte width, and memmove semantics for `array.copy` |
| C5 | `features.zig` | the `.gc` classification — caught automatically by the coverage pin, which failed the build until all six were classified |

⚠️ **The two operands of `array.new_data` are in DIFFERENT UNITS** — the offset counts *bytes* into
the segment, the size counts *elements* — so the bound is `offset + size × width`. Getting this
wrong is not a conformance nicety: with 12 bytes of segment, `array.new_data` for 12 `i32`s would
read 48 bytes, i.e. **36 bytes past the segment**, and the arms are on the unvalidated path too.
The in-repo test asserts the trap in both the scaled and off-by-one-byte directions.

⚠️ **`array.copy` can name the SAME array twice, so it is `memmove`, not `memcpy`.** Every
non-overlapping case passes with a forward copy; only a backward overlap exposes it, and it smears
one element across the range when it does. A test that only copies between two distinct arrays would
have shipped this.

⚠️ **`array.copy`'s type check cannot go through `unpacked()`.** A packed `i8` element and a plain
`i32` element both project `i32` onto the operand stack, so comparing the *unpacked* forms calls
`(array i8)` and `(array i32)` compatible — and then copies raw bytes between arrays of different
element widths. The storage forms must be compared first. Same family as R2's C3: **the type the
stack shows you is not the type the memory has.**

⚠️ **Two defects surfaced INSIDE the R3 files that were not R3** — the "a failure's cause count is
not known until it passes" rule again, twice in one item:

1. **`isRefType` in the assembler listed only `funcref`/`externref`**, so `(elem $e i31ref …)` fell
   through to the *func-index* form and read `i31ref` as a function name → `BadImmediate`. It now
   defers to `shorthandRefType`, the table the cast ops already use. This closed **R6 entirely**
   (`i31.wast` 8 → 0) plus `br_on_cast`/`br_on_cast_fail` 5 → 2 in core and 6 → 3 under
   `custom-descriptors`. **A second copy of a lookup table is a second place to be incomplete.**
2. **`call_indirect $t` with no type annotation would not assemble.** The table index was consumed
   only when a `(type …)`/`(param …)`/`(result …)` followed it, but the type use is *optional* and
   absent means `[] -> []`, so `(call_indirect $t (i32.const 0))` left `$t` for the operand loop,
   which tried to assemble a table name as an instruction → `UnknownInstr`. Identical shape to the
   flat `br_table` fix: a guard tightened around one form, excluding a sibling that is equally
   legal. `isIndexAtom` is the right predicate in both.

⚠️ **A raw `0xC5` byte decoded and EXECUTED as `i32.trunc_sat_f32_s`** — found while looking for
free `Op` values, not by a test. `0xc5..0xcc` are internal tags for the saturating-truncation ops
(wire form `0xFC` + sub-opcode); the guard that rejects raw internal-tag bytes covered `0xd7..0xfa`
only, and `immediateKind` classifies `0x45...0xcc` as `.none`, so eight non-opcodes were accepted as
real instructions. The guard is now two ranges — `0xc5..0xcf` **and** `0xd7..0xfa`, because
`0xd0..0xd6` are genuine single-byte ops sitting between them. **A guard written against the tags
that existed when it landed does not cover the tags that already existed elsewhere**; the fix that
introduced it stopped at the range it was debugging.

**Size:** +6,144 exe / +8,258 lib / **+7,168 dll**, and unlike R2 *all* of it is R3's — the pre-R3
commit was measured in a worktree first and sat at (exe, dll) or just under (lib) its ceiling. The
DLL moves for the first time in three entries because these are decoder/validator/interpreter arms
the C ABI genuinely reaches, where R2's linking work was not.

### ✅ R2 IS DONE (2026-08-13) — 237 → 193, five causes, and it was 44 failures, not 35

**Corpus 237 → 193 failures, 61,152 → 61,187 passing, 2,649 → 2,637 skipped** (12 assertions that
were suppressed now actually run), zero regressions at any of the five steps. **All five target files
are CLEAN**: `elem.wast`, `linking.wast`, `linking0.wast`, `linking3.wast`, `instance.wast`. R2 also
took failures out of `try_table` (6→4), `legacy/try_catch` (1→0), `tag` (1→0), `table` (7→6),
`table64` (2→1), `memory`, `memory64` and `custom-descriptors/exact-func-import` (7→5).

**The 35 triaged split into FIVE causes, only two of which the item name suggested:**

| | cause | count | what it actually was |
| --- | --- | --- | --- |
| C1 | **a funcref was a bare function index** | 17 | resolved against whatever instance was *executing*, so any funcref crossing a boundary re-bound to a different function |
| C2 | **an imported global was copied by value** | 1 | a `(mut i32)` import was a snapshot; the exporter's writes were invisible |
| C3 | **the §5.5.6 typed-table form did not decode** | 8 | `0x40 0x00 tt expr`; plus elem/table types compared by family instead of subtyping |
| C4 | **`(module definition)`/`(module instance)` unimplemented** | 8 | a HARNESS gap, not a wazmrt defect — and it was hiding a real one (tag identity) |
| C5 | **data segments applied before element segments** | 1 | §4.5.5 order is elements first; plus a failed instance was discarded, killing its funcrefs |

⚠️ **C1 is the headline and it was a soundness-shaped defect, not just a conformance one.** A funcref
value was the function's index, and `call_indirect` looked that index up in *the reading instance's*
module. Put a funcref in a shared table — which is the entire point of an imported table — and the
reader dispatches to whatever sits at that index in ITS module. `interp.zig` even carried a comment
describing the symptom ("the importer chooses the function indices, and the *owning* module
reinterprets them") as an acceptable consequence of a rejected module, rather than as the general
defect it was. Reference values now live in an `interp.Store` shared by everything linked together.

⚠️ **The type check did not protect the call, because it was wrong in the same direction.**
`checkIndirectType` read the callee's type from the reader's module too — so the wrong function's
type came from the wrong module, agreed with itself, and the call proceeded. **A check that makes the
same mistake as the thing it checks is not a check.** Cross-instance `call_indirect` now compares
through `typematch`, the same way R1 made imports compare.

⚠️ **Fixing one defect exposed the next in the same failure — twice.** `linking.wast` L410/L423 went
from `result mismatch 0x4` to `trap UndefinedFunc` when C1 landed: the wrong answer had been *hiding*
C5. And C4 — a pure harness gap — turned instance.wast from 0/8 into 10/2, where the 2 were a genuine
tag-identity defect (an exception thrown with one import of a tag was not caught by a handler naming
another import of the same tag). **A failure's cause count is not known until it passes.**

⚠️ **A retraction that re-checks the reasoning has not re-checked the requirement.** C3's elem/table
type comparison was raised by a 10th-pass audit, retracted as false, and marked `Don't "fix" it
again` at the site. The retraction was right that `ValType.nullable()` is not a predicate — and the
RULE was still wrong: §3.5.11 wants subtyping, and family-equality accepted a nullable `funcref`
segment into a `(ref func)` table. Switching to real subtyping then rejected four valid modules,
because the decoder recorded elem forms 0–3 as `funcref` when §5.5.12 gives them `(ref func)`. Three
defects stacked behind one retracted finding.

⚠️ **A gate only gates the commits that RUN it.** `zig build size` failed on all three artifacts —
but measuring against a worktree at the pre-R2 commit showed most of the overshoot was already there,
left by the R1 commits of 2026-08-12. R2's true share is +5,120 exe / +1,068 lib / **+0 dll**. The
gate works; nothing invoked it. See `tools/size-ceilings.txt`.

**Structural changes worth knowing before touching this code:**

- **`Instance.init`/`initWithImports` are GONE**, replaced by
  `instantiate`/`instantiateWithImports` taking a DESTINATION POINTER. An instance's address is part
  of its identity now — element segments create funcrefs naming `self` before instantiation returns —
  so it cannot be built and then moved. The compiler finds every call site; a comment would not.
- **`interp.Store`** holds the instances a group of linked modules share. Slots are tombstoned on
  `deinit`, never reused, so a stale funcref (or an arbitrary integer from the C ABI) is a clean
  `UndefinedFunc`, never a dangling pointer. Linking across two stores is `error.CrossStoreLink`.
- **`Instance.Global`** is a shared cell, like `Memory` and `Table` already were; `global_hi` folded
  into it. **The C ABI shared this defect and the corpus could not see it** — `define_instance`
  copied a published instance's global at link time, commented as "a snapshot, which is what the ABI
  can carry". It binds the cell now. Same shape as R1's `define_instance` finding.
- **Instantiation is `allocate` (§4.5.4) + `applyActiveSegments` (§4.5.5)**, so an instance whose
  segment init traps stays ALIVE (the store adopts it) and the entries it already wrote into an
  imported table keep working. The first cut kept the allocation errdefers in scope and double-freed;
  the existing "a rejected module cannot leave entries in another module's table" test caught it.
- **`.wast` failures now carry the source LINE** (`sexpr.parseAllWithLines`). Triaging 35 failures by
  re-deriving which assertion each one was is exactly the hand work that mislabelled three of five
  items on the 2026-08-11 list.

### ✅ R1 IS DONE (2026-08-12) — 275 → 237, in four verified steps

**38 failures, not the 25 estimated**, and the estimate was low for a structural reason worth keeping:
the triage counted the failures whose MESSAGE named a type mismatch. The same root cause was also
producing `TypeMismatch` at validation, `assert_invalid` acceptances, and — twice — a silently wrong
*encoding*. Corpus **275 → 237**, 61,115 → 61,152 passing, **6 fewer SKIPS** (assertions that now
actually run), zero regressions at any step. Clean files: `type-equivalence`, `type-subtyping`,
`type-rec`, `imports`. `linking` 12 → 11, `elem` 16 → 14, `tag` 3 → 1, `i31` 9 → 8, `table` 8 → 7.

New **`src/typematch.zig`** compares types structurally across modules under *iso*-recursive rules
(§3.3.10): the unit of identity is the rec group, and two types match only at the same position in
equivalent groups. `Module` now keeps `rec_start`/`rec_len` and the type index of every function and
tag, because `Extern.func` keeps only the expanded signature — **and a signature is not an identity**.

⚠️ **The bug was wrong in BOTH directions, and the accept side is the dangerous one.** Comparing
module-local indices rejected valid links (two modules holding one type at different indices) *and*
accepted invalid ones — `(ref $A)` at index 0 in one module and an unrelated `(ref $B)` at index 0 in
another compared EQUAL, so the importer received values of a type it never agreed to. **Type confusion
across a module boundary, reached by ordinary linking.** A defect that only ever showed up as
"conformance failure" was also a soundness hole.

**What the four steps actually found — three of them were not "type comparison" at all:**

| | defect | why it was invisible |
| --- | --- | --- |
| 1 | link matching compared expanded signatures | the stated R1 item |
| 2 | `call_indirect` compared signatures, not index subtyping | `(sub (func))` and `(sub final (func))` have identical params and results and are DIFFERENT types, so a final type answered a call naming the extensible one |
| 3 | the WAT assembler **dropped element-segment types** | two of the eight elem encodings have `funcref` baked in and carry no type byte; the assembler picked them by shape, so any other element type vanished and the table rejected its own initializer |
| 4 | inline function types were identified with rec-group MEMBERS | §6.6.12 allows only a singleton, final, no-supertype type; `internSig` matched on params/results alone |

⚠️ **A cache key must name everything the answer depends on.** The matcher's memo was first keyed on
the two rec-group start indices — a statement about *no particular modules* — so one link's verdict was
served to an unrelated later link. It flipped 32 import assertions and was caught only because
`imports.wast` regressed 5 → 21; every file R1 was aimed at had improved either way. **A win in the
target files is not evidence the change is right.**

⚠️ **The 4th step was in the SHIPPED C ABI, and the corpus could never have found it.** `capi.zig`'s
`define_instance` (one guest module's import bound to another's export) carried the same raw-`!=`
signature comparison, in the path an *embedder* uses, with **no behavioural test** — only a
symbol-existence entry. The `.wast` suite does not exercise the C ABI, so the corpus read 237 both
before and after. **A conformance number says nothing about a surface the corpus does not reach.**
`typematch` is now exported from `root.zig` so any future linker is pointed at it.

⚠️ **`zig build test-security` cannot pass from this repo's own cwd.** `D:` is **exFAT**, which has no
symlinks, and the sandbox-escape tests plant symlink fixtures under the cwd's `.zig-cache/tmp`. That is
what the step's "run from an NTFS cwd" note means. Verified by running the same test binary from a `C:`
cwd — 3/3 OK. Do not read those two failures as a regression; do not "fix" them in `wasi.zig`.

⚠️ **2,637 assertions are still SKIPPED and that is not a pass.** (2,655 before R1 → 2,649 after it
→ 2,637 after R2; both times the recovered assertions were ones no longer suppressed by a module that
failed to build — R2's 12 came from implementing `(module definition)`/`(module instance)`.) The largest pools: `br_table.wast`
**161**, `custom-descriptors/exact-casts` 108, `wide-arithmetic` 107, `br_on_cast_desc_eq*` 101 each.
`br_table.wast` is core spec and worth a look on its own — 161 unrun assertions in a control-flow
instruction is a bigger blind spot than most of the failures above.

### What is left after Track 1 (2026-08-11)

- **Track 2c — comptime feature gating (`-Dwat=false` / `-Dwasi=false`).** Promoted from optional to
  necessary by the measured growth above. ⚠️ `.wat` is NOT being descoped (owner, 2026-08-11) — the
  CLI keeps assembling text unconditionally; the question is only whether an *embedder* who never
  assembles text must carry the assembler.
- **Track 3 — the bake-off harness.** wazmrt vs wasmrt vs wasmtime, on wasmtk's and rsxtk's real
  corpora, **with wasmtime in a FAST-START configuration** (`OptLevel::None`/Winch), never only
  `OptLevel::Speed`.
- **wasmtk branch `test/cross-runtime-wazmrt-wasmrt`** (`72cf256ffad`) — the 5-runtime portability gate,
  deliberately unmerged pending the runtime decision.

### The three tracks

1. **ABI replacement.** Match `wasmrt.h`'s 74-function shape *exactly* (semantics + spelling modulo the
   prefix) + a small alias header, so wasmtk can A/B the two engines by swapping a DLL — a bake-off
   needs that. Adopt wasmrt's **value handles + `is_valid`**, which *structurally* delete the
   `#20`/`#21`/`#22` bug class (no refcount, no raw ownership transfer to get wrong); caller-based
   callbacks; name-based linker; per-module WASI. Do **not** re-derive the four designs wasmrt's
   `loaders.md` records as not surviving contact with the code. Then delete `src/wasm_c_api.zig`,
   `tests/c_abi_symbols.c`, `third_party/wasm-c-api/`, both install-file steps and the ledger entry.
2. **Size program.** (a) **A size gate that FAILS the build** past a recorded ceiling — the
   `test-security` pattern applied to bytes, and the only thing that stops another silent doubling.
   (b) Delete the C ABI, measure the delta. (c) **Comptime proposal gating** (`-Dgc=false`, …) so an
   embedder compiles out what its guests never use — biggest lever, biggest work; ⚠️ a disabled proposal
   must be **rejected loudly**, never silently ignored (the canonical fall-through failure mode).
   (d) Keep CLI-only surface out of the *embed* artifact. ⚠️ **This is NOT a descope of `.wat`** — owner,
   2026-08-11: running `.wat` files stays fully in scope. The CLI keeps assembling `.wat`/`.wast`
   unconditionally (it is a stated capability: *"a `<module>` is a `.wasm` binary **or a `.wat` text
   file**"*); the only question is whether an *embedder* who never assembles text should have to carry
   the assembler, which is an **opt-out build flag**, never a removal.
3. **Bake-off harness.** wazmrt vs wasmrt vs wasmtime on wasmtk's + rsxtk's real corpora: DLL size,
   **decode+validate+instantiate**, cold-start wall-clock, steady-state, conformance score, security
   posture — with wasmtime in a **fast-start** configuration. Include a proposal-parity check against
   wasmtime's supported list (verify tail-calls and relaxed-SIMD first; `return_call_ref` sits at 38/9
   in the last snapshot). Also unmeasured: rsxtk's own binary size and Cranelift's share of it.

### ✅ TRACK 1 IS COMPLETE (2026-08-11) — shipped in 18 commits, every step verified before the next

`src/wasm_c_api.zig`, `third_party/wasm-c-api/`, `tests/c_smoke.c`, `tests/c_abi_symbols.c` and
`examples/deno_ffi.mjs` are **deleted**. The C ABI is `include/wazmrt.h` (ABI 2, 77 functions) over
`src/capi.zig`. A clean `zig build` produces **three files**: `wazmrt.exe`, `wazmrt.lib`,
`include/wazmrt.h`. **`third_party/` holds no code and the Component Ledger is EMPTY — wazmrt is 100%
self-owned.**

**Three outcomes worth carrying forward:**

1. ⚠️ **IT GOT BIGGER, NOT SMALLER — the premise of the plan was wrong.** DLL **227 KB → 845 KB**, static
   lib **279 KB → 974 KB**. Not waste: the embed artifact now carries the WAT assembler, WASI and an
   `Io`, none of which the old surface had. The size gate refused the build and the ceilings were raised
   deliberately, in the same commit, with the reason — which is the workflow the gate was built for two
   days earlier. **This is what makes Track 2c (`-Dwat=false` / `-Dwasi=false`) necessary rather than
   nice: every FFI consumer currently pays for both.**
2. ✅ **The bug class is gone by construction, not by vigilance.** Value handles carry their store's
   identity and are validated by lookup, so the double-free / use-after-free / uninitialised-refcount
   family that produced `#20`, `#21` and `#22` cannot be expressed. Six hand-enforced rules became zero.
3. 🎓 **Two gates earned their keep by FAILING.** The size gate caught the growth above. The symbol gate,
   generated from the header, found four declared-but-undefined functions the moment it existed —
   including two I had already listed and two I had not.

**Deliberately absent from the ABI, additive later without moving `WAZMRT_ABI_VERSION`:** tables,
multi-value returns, host-side imported memories/tables. `wazmrt_caller_get_memory` exists but always
returns false (a durable memory handle needs a live store; the store is mid-borrow during a callback —
use `wazmrt_caller_read`).

### 📋 The agreed change series (owner-approved 2026-08-11) — build new, prove, then delete

**Sequencing principle: the new surface is built ALONGSIDE the old, proven, and only then is the old
deleted.** No step leaves a broken intermediate, and the two coexist long enough to *measure* what the
deletion buys. ⚠️ `src/wasm_c_api.zig` is the root module of **five** build-graph sites (`cabi` static,
`dll`, `cabi_gnu` for c-smoke, `cabi_tests`, `cabi_tests_safe`) — nothing flips until the replacement
satisfies all five.

| # | Change | Gate | |
| --- | --- | --- | --- |
| 0 | **Size gate FIRST** — `zig build size` + checked-in ceilings | green at today's bytes | ✅ |
| 1 | `include/wazmrt.h` v2 — the full surface, header only | compiles standalone | ✅ |
| 2a–2e | `src/capi.zig` — lifecycle → memory/globals → **linker + caller-based host funcs** → WASI config → caps | `test` + `test-safe` | ✅ |
| 2e-b | per-instance ceilings + **real per-proposal gating** (`src/features.zig`) | gating tests | ✅ |
| 3 | `tests/wazmrt_abi_symbols.c` + `tests/capi_smoke.c` | link-time completeness gate | ✅ |
| 4 | port the Deno demo → `examples/deno_ffi_capi.mjs` | `ffi-demo` | ✅ |
| 5 | flip the default; **`abi_version` → 2**; trap-frame names | all green + measured delta | ✅ |
| 6 | **delete** old surface + `third_party/wasm-c-api/` | `zig-out/include` = 1 file | ✅ |
| 7 | memory + README sync | — | ✅ |

**Owner decisions, 2026-08-11:**

1. **`abi_version` → 2.** The surface changes wholesale; a consumer checking `wazmrt_abi_version()` must
   not read the new library as compatible with the old.
2. **`.wat` IS exposed through the C ABI** — `wazmrt_module_new_wat()` (run text directly) plus
   `wazmrt_wat_to_wasm()` (assemble + cache). Owner's rationale: *"our built-in wat to wasm will allow
   running the wat directly instead of running through the wasmtk normal processes, which will save time
   at runtime."* ✅ Real and a genuine differentiator — **no other embeddable runtime offers it**, and it
   removes a whole toolchain round-trip (no separate converter process, no temp file) from the consumer.
   ⚠️ **Be precise about WHERE the saving is: it is pipeline elimination, not faster execution.** Parsing
   text costs *more* per module than decoding a binary, so for a module run repeatedly, caching the
   assembled `.wasm` still wins. The win is for the edit-run loop, which is exactly this consumer's
   regime.
3. **Ship the `wasmrt_*` compatibility alias header** (~30 lines of `#define`), so a consumer can A/B
   wazmrt against wasmrt by rebuilding rather than rewriting.
4. **KEEP CURRENT FUNCTIONALITY — v128 crosses the boundary, it is not refused.** Reverses the
   scoping proposal to reject SIMD at the C ABI. ⚠️ **Fix the root cause rather than reproducing the
   workaround:** the old surface's v128 damage (slot-vs-index conflation; half a vector punned as a
   pointer, 13th pass) traces to `wasm.h` having **no v128 valkind**, forcing a two-slot hack. Our own
   header has no such constraint — give `wazmrt_val_t` a **proper 16-byte v128 variant**.
5. Interim artifact step name: **`zig build capi`** (owner: no preference). Both libraries cannot install
   as `wazmrt.lib`, so the new one lives under its own step until step 5.

⚠️ **Decisions 3 and 4 interact — record the trade.** With `.wat` and v128 added, wazmrt's surface is a
**superset** of `wasmrt.h`, so the alias header can only cover the common core; the extras are
wazmrt-only and a consumer using them is no longer trivially swappable. That is an accepted cost of
keeping current functionality, **not** an oversight — do not later "simplify" the extras away to restore
symmetry.

**The defensible claim** — the one that survives someone checking: **"wasmtime-class module
compatibility, at a fraction of the footprint, faster on anything not precompiled."** An unqualified
"faster than wasmtime" dies to one hot-loop benchmark.

## Status (2026-07-27) — every targeted wasm proposal implemented (memory64 was the last)

*(Sections below are dated as written. The **2026-07-27** state supersedes all earlier test counts and
open-item lists; the fine-grained audit ledger lives in `known-issues.md`.)*

> ⚠️ **CORRECTION (2026-08-12): "COMPLETE" below was false for 16 days.** memory64 has two halves and
> only the memory one was built — `readTableType` carried a literal `// tables are 32-bit` and refused
> `is64` outright, so **table64 did not exist**: ~78 corpus failures behind a completeness claim in the
> authoritative memory. Implemented 2026-08-12 (see below). **The lesson is about the claim, not the
> code:** it was written from the memory-side test files passing, and no one asked what else the
> proposal contained. *A proposal is done when its spec files pass, not when the feature you had in
> mind works.*

**Latest (2026-07-27) — memory64 (Item 3), the last unimplemented proposal, is COMPLETE.** A memory
declared `i64` now uses 64-bit addresses, and its `memory.size`/`grow` operate in i64 — implemented end
to end and cross-checked value-by-value against **wasmtime** (`-W memory64=y`). The address *type* is
per-memory: every memory instruction consults the target memory's index type (a new `memAddrTy` helper in
`validate.zig`). `Module.zig` parses the 64-bit limits flag (bit 2) and widens page counts to u64 (up to
2^48 pages); `interp.zig` pops i64 addresses (`popAddr`/`popMemU64`) and uses overflow-safe u64 bounds
(`memRange`) for load/store/bulk-ops/atomics plus i64 size/grow; `wat.zig` assembles `(memory i64 …)`
(declarations + imports), u64 limits, the 64-bit section flag, and i64 offsets for the inline
`(memory i64 (data …))` form; `Reader.zig` gained `readVarU64`. The overflow-safe bounds also fixed
base-suite edge cases: **core spec suite 58.6k → 59,705 passing / 394 failed.** memory64 spec files
(address64/align64/memory_trap64/memory_grow64/memory_redundancy64) pass 100%; memory64.wast is 59/1 (the
1 is a `module definition` module-linking harness command, out of scope). **475 local tests green under
Debug AND ReleaseSafe; c-smoke 319/319. With this, every wasm proposal wazmrt targets is implemented** —
only #8 (upstream Zig) and out-of-scope harness command forms remain.

**Then (2026-07-27, same day) — a "look for code issues" audit + the deferred-item cleanup.** Four
parallel investigators over the fresh memory64 code found two real gaps at the memory64×{u64-offset, SIMD}
intersections (which no single-feature test exercises) + two minor finds, all fixed (`f478f79`): the
memarg **offset was decoded as u32** (memory64 widens it to u64 — a valid `offset=0x1_0000_0000` was
rejected at decode, and the assembler already emitted u64, a round-trip break), **SIMD v128 memory ops
were memory64-blind** (i32 address hard-coded in validator + interp), a dead `max_atomic_sub` const, and a
wrapping `\u{…}` escape. Then all four audit-**deferred** items were closed (`e276d09`), all `wat.zig`:
**multi-memory SIMD text** (`v128.load8_lane $m …` → SIMD suite 24,956/0), the **canonical index-type
ordering** (`(memory (export "m") i64 1)`), a **de-duplicated limits parser** (`parseMemLimits`), and
**`uleb` widened to u64**. Full main testsuite 60,310 → **60,668 passed**; 483 local tests green. **Then the
last assembler gap — `tag` imports (the text form; they already worked at the binary/runtime level since
Phase 6.2) — was closed (`49e5284`):** both `(import … (tag …))` and inline `(tag (import …) …)` emit,
verified by executing both forms (→ 42) and cross-checked vs wasmtime `wast`. **The WAT assembler now has
NO remaining known gaps** — every construct across every proposal wazmrt targets has text-assembly support.
485 local tests green (Debug + ReleaseSafe); c-smoke 319/319; full main testsuite 60,670 passed.

**Then (2026-07-27, continued) — an assembler audit, the four noted-LOW fixes, and an s33 sweep.** A
"look for code issues" pass over the fresh assembler code found a **flat-form SIMD memory-op regression**
(the multi-memory memidx change greedily ate the next flat instruction — HIGH, false-rejection), a
**defined-tag-before-imported-tag mis-index** (`isDefKind` omitted `tag` — MEDIUM), and a doubled index
type (LOW), all fixed (`436196e`). Then the four items that pass had *noted but deferred* were all closed
(`bc39e89`): a **table-entry budget** (`max_table_elems`/`--max-table-elems`/`TableLimitExceeded`,
mirroring the linear-memory budget — a `(table 0xffffffff funcref)` no longer demands ~32 GiB), **C-ABI
saturating** u64→u32 memory casts, a strict **`Reader.readVarS33`** for block/heap types (≤5 bytes, in
range), and a **tag typeuse consistency check** (`resolveTagSig`). A follow-up audit then verified those
four correct (readVarS33 traced bit-by-bit, no miscompile) and swept the strict s33 reader into the **three
remaining decoder s33 sites** (`937739c`). **After all this: every wasm proposal implemented, the WAT
assembler has no gaps, and there are no open LOW *defects* — only by-design limits + the upstream-Zig class
(see `known-issues.md` "Remaining LOW items").** **491 local tests green under Debug AND ReleaseSafe;
c-smoke 319/319; full main testsuite 60,670 / memory64 601/1 / SIMD 24,956/0.**

**Then (2026-07-27, continued) — ran the full wasmtk WASI corpus and fixed a legacy-EH bug.** Ran all
400 runnable files (`wasm_wasi` 336 + `wasm_wasi_bundle` 61 + `wasm_wasi_dync` 3 — the dync trio initially
imported wasmtk's custom dynamic-runtime host and was out of scope, then the owner regenerated them
self-contained and they run identically to wasmtime). One real bug (`d51c004`): `15_LexicalShadowing_Stress.wasm`
**infinite-looped** — a raw `throw` inside a legacy `catch` handler re-matched the same handler instead of
propagating to the enclosing try (`throwException` now skips a legacy try whose handler is executing).
**Result: `wasm_wasi` 333 clean + 3 correct uncaught-exception traps (identical to wasmtime) + 0 hangs;
`wasm_wasi_bundle` 61/61 clean; `wasm_wasi_dync` 3/3 clean (output byte-identical to wasmtime, after the
owner regenerated them self-contained on 2026-07-27).** **Every one of the 400 runnable WASI files now
behaves correctly — wazmrt runs the whole wasmtk WASI suite.** +1 regression test; **493 local tests green
(Debug + ReleaseSafe).**

**Latest (2026-07-22) — the "open items 1–7" batch.** After the 13th pass the remaining list was walked
end to end (see `known-issues.md` for the per-item detail). Six real fixes, each verified by executing the
result and, where a live reference implementation exists, cross-checked against **wasmtime**:
**import-order preservation**; **`delegate` uniformly refused** (validator + runtime, closing the
"validates yet mis-runs" gap); **GC constant expressions** (`struct.new`/`array.new*`/`ref.i31` in const
exprs — which also closed the old `skipConstExpr` gap — plus abstract GC ref matchers in the `.wast`
runner); **multi-memory TEXT assembly** (the runtime had it since Phase 7; the assembler now emits the
bit-6 memarg form, per-op memory indices, `shared`, and `(data (memory $m) …)`, plus a `.wast`-runner
memory-import-linking fix); and **threads/ATOMICS** — the whole `0xFE` family (~66 ops) from scratch
across decoder/validator/interp/assembler, single-threaded semantics, **the entire threads `atomic.wast`
suite passing 302/0**. (Item 7's two "failing" corpus files were confirmed malformed source, not a bug.)
**Core spec suite 57.9k → 58.6k passing; 469 local tests green under Debug AND ReleaseSafe.** memory64
(Item 3) was the last item; it was completed 2026-07-27 (see the Latest section above) — **every targeted
proposal is now implemented**.

**Prior (2026-07-21).** Three audit passes (11th–13th) plus an assembler-gap batch. The **13th pass
finally RAN the official `WebAssembly/spec` testsuite** for the first time — twelve passes had *reviewed*
the code without ever *executing* the upstream oracle — and within minutes it surfaced a guest-controlled
stack overflow, missing UTF-8 name validation, and hex-float literals truncated (not rounded) by the
assembler. **Score: 57.8k assertions passing across 258 spec files;** SIMD alone went from 848 pass /
23,985 fail to 24,951 / 2 once the `.wast` runner learned v128 (a v128 is two result slots, so every SIMD
assertion had been failing as an arity mismatch and *none had ever run*). Parallel audit agents then found
an element-segment confinement break (a rejected module installing entries in another module's imported
table), v128 slot-vs-index conflation in both the C ABI and the CLI, an OOM swallowed into a silently
wrong answer, `nearest` returning a signaling NaN, and more. An **assembler-gap batch** followed: inline
`(export …)` on a tag, forward-referenced exports, `(export "mem" (memory $name))`, data-segment names,
flat `br_table`, `anyfunc`, the discarded memory-index immediate, **named struct fields**
(`struct.get $T $field`), and **legacy folded `try`/`catch`** reaching both the assembler and the
validator — real-world `.wat` corpus assembly 468→489/493. **What remains is a small, honest set:** #8
(upstream Zig), `skipConstExpr`'s GC/SIMD-immediate gap (behind a validator that rejects GC/SIMD
const-exprs anyway), runtime `delegate` routing (no oracle exists — kept loudly rejected), multi-memory
*text* (runtime supports it; assembler defers it), and memory64 (a whole proposal). **All of these except
#8 have since been closed — multi-memory text (2026-07-22) and memory64 (2026-07-27) were the last two.**

Everything through the **authenticity path** is built (see the dated sections below): decode → validate →
execute, full text toolchain, reference types / GC / function-references, WASI preview 1 + sandbox,
exception handling (both encodings), multi-memory, **complete SIMD**, and **Ed25519 signatures + pin
verification** (`keygen`/`sign`/`-Droot-key`, deny-unsigned-when-armed). Earlier (2026-07-19), three
**memory-safety hardening passes** (from repeated "look for code issues" audits — full ledger in
`known-issues.md`): (1) the CLI **run path doesn't validate before executing**, so the interpreter now
self-defends — `checkStaticIndices` at load + cold-site bounds checks (`gcObject`/`throw_ref`/`branch`);
(2) the **stack-HEIGHT wild-base class** — call opcodes were an unbounded `@memcpy` **write** into locals
(CRITICAL) — closed via a `Frame.stackBase`/`peek` helper across calls/branch/block-entry/epilogue/
`local.tee`; (3) the **WAT assembler + decoder** hardened against malformed input (shape-checked
accessors → `BadModuleField`; `sexpr` depth cap; `Reader.readVecLen` kills OOM amplification). Owner
decisions: **harden the interpreter** (not validate-before-run); **shape-checked accessors** for wat.zig.
Also added CLI **`-h`/`--help`** (full option/subcommand descriptions) and **`-v`/`--version`**. 197
distinct unit tests; native Debug/ReleaseFast + freestanding wasm32 all build.

**Update 2026-07-20 — passes 4–10.** Passes 4–9 were increasingly clean censuses of the *explicit-index*
surface (integer-overflow UB, `@intCast`, use-after-realloc, `unreachable`, byte-copy primitives), ending
with two no-new-issue passes. The **10th pass then found 10 issues including two segfaults and a
12-byte hang**, because its finds were in classes an index sweep structurally cannot see: a parser that
**fails to advance** (`sexpr.zig`'s lone `;` — `(module) ; x` hung the CLI at 10.4 GB), **imports bound by
name with the declared arity unchecked** (a 4-line `.wat` segfaulted the WASI path), and **cross-section
properties only the validator checked** while the run path skips validation (a 31-byte module segfaulted
via `funcType(fi).?`). Also a C-ABI `wasm_ref_copy` use-after-free/double-free and a verification bypass
where `flagRegion` scanned *guest* argv. Then the three items held back for an owner decision were taken
too: **linear memory = lazy OS pages + a 1 GiB budget** (`--max-memory`; 4 GiB declaration 2.85 s/4054 MB →
0.05 s/~0 MB), **`Frame.pop` operand-stack underflow** (defined `0` + a flag trapped at loop exit;
`@branchHint(.cold)` is what keeps it free — see design-decisions), and **`random_get` is now a real CSPRNG**
(ChaCha seeded from `io.randomSecure`, `EIO` rather than weak bytes). At that point 206 distinct tests,
green under Debug *and* ReleaseSafe, with `c-smoke`, `wasi-gate` and the freestanding `wasm` target passing
and steady-state back at ~263 Mops/s. Then the last two audit items: **`.wast` no longer bypasses
`verifyGate`** (it executed before the gate, so any wasm wrapped in a `.wast` ran unpinned under a root
enforce), and **the fuzz targets were rebuilt to mutation-not-generation** — they had been reaching
essentially nothing (0 decodes in 20 000 inputs), now 519 decoded / 387 instantiated / 142 assembled per
sweep, with the sweep **asserting its own coverage** so it cannot silently degrade again; 800 k deep-run
iterations across Debug and ReleaseSafe found no crashes — 207 distinct tests at that checkpoint.
Finally the whole still-open list was closed the same day: `validate.zig` resource caps (nesting + locals,
whose **product** is the real bound) applied on the run path too, `array_new_fixed` bounded by instruction
count, the `(table N …)` copy cap, `path_symlink` refusing escaping targets at creation, `writeStringVec`
u64 offsets, the `host_funcs` OOM leak, `--verify` failing closed, `keygen` writing the key 0600, a
**conformance baseline** (`-Dbaseline` / `-Dwrite-baseline`) so that step gates on regressions instead of a
zero upstream never reached, and a **`Budget` allocator** making allocation amplification visible to the
fuzzer. **209 distinct tests** (407 printed), green under Debug and ReleaseSafe. One reported finding —
"accept-invalid element type" — turned out to be **wrong** and is recorded as such at the site.
**2026-07-21 — cleanup batch (owner sequenced the leftovers 9–13 → 1–3 → 4–6, deferring the Zig `Io` bug
to upstream):** `opcode.zig` raw internal-tag bytes now rejected (the old guard tested a *proxy* — immediate
kind — so it was silently partial), duplicated align helpers consolidated, trap-backtrace offsets saturate
instead of `@intCast`, `conformance` survives an unreadable directory, and the fuzz targets no longer share
a coverage corpus. **211 distinct tests** (411 printed).
**Validator-correctness batch (items 1–3) — DONE 2026-07-21:** `br_on_non_null` no longer rejects valid
GC/typed-ref labels; SIMD memory ops and `memory.size`/`grow` now require an in-range memory (as does the
scalar path, which never bounded the memarg's memory index); and `concreteRef`'s 28-bit mask no longer
truncates a large type index into a small valid one. **213 distinct tests** (415 printed).
**Hardening batch (items 4–6) — DONE 2026-07-21, closing the remaining list:** the last three
u32-before-widening guest-array offsets now go through `Wasi.arrayOffset` (u64 arithmetic, whole-element
fit), C-ABI trap frames **retain** their instance instead of borrowing it, and `Wasi.init` propagates OOM
instead of returning a `Wasi` with no stdio. **214 distinct tests** (416 printed).

**11th pass — 2026-07-21 — new lenses, first wrong-ANSWER bug.** With the memory-safety list closed, this
pass used lenses never applied before (stale comments, dead code, fall-throughs, and **silently-wrong
execution**). It found that **`fNxM.min`/`max` returned the wrong number** — Zig's `@min`/`@max` are
minNum/maxNum, not the NaN-propagating `fmin`/`fmax` the scalar path uses, so `f32x4.min(nan,1.0)` gave
`1.0` and autovectorised code disagreed with scalar code. Also: a **cross-allocator realloc of guest
memory** (collateral from the lazy-pages change), an `errdefer` slice with start > end, and **null
inverted both ways** in the C-ABI val path. **216 distinct tests** (419 printed).
**Highest-value testing gap now open: no `simd_*.wast` has ever been run** — that absence is what hid the
min/max bug for eleven passes.

**The ~40-item backlog was then verified and cleared in batches A–E (2026-07-21):** interp/decoder
(missing imported global read 0; `ref.test (ref nofunc)` answered 1 where the spec says 0, and the matching
`ref.cast` succeeded where it must trap; undefined heap type decoded as `externref`; undefined `0xFD` sub
decoded *and validated*; `shuffle` lanes ≥ 32 accepted), **five assembler silent-drops** that emitted
modules not matching their source, **five WASI syscalls** reporting ESUCCESS for work they didn't do, four
**C-ABI** faults (an exported *tag* was callable as a function), and the **CLI exiting 0 on every failure
including a verify-gate refusal**. One claim did not reproduce and is recorded as not-a-defect.

**The 10th pass's remaining-issues list is closed.** Only two items survive, neither closable here:
**#8** (upstream Zig `Io` bug — also what holds #17's final-component `path_open` TOCTOU open; recheck on
every Zig upgrade) and `skipConstExpr`'s GC-immediate gap, latent until GC const-exprs are implemented.
Known scope gaps remain as scope, not defects: legacy EH has no assembler/validator support, and the C ABI
still defers shared-mutable imported globals + externref table slots via `wasm_table_get`.
*Standing lesson from this sequence: a run of clean passes means the current lens is exhausted, not that
the code is clean — change the lens.*

## Status (2026-07-02) — runtime executes; text toolchain in progress

The full pipeline runs end-to-end: **decode → validate → execute** (int/float/memory), verified on the
real `module/wasm_mod` corpus against its `.test.json` values. A native **WAT text assembler** is done;
the **WAST script runner** (`wast.zig`) is next.

**Done:**
- **Runtime pipeline** — `Module.decode` (all core sections + resolved import/export types + bodies) →
  `opcode.zig` IR → `validate.zig` (spec type-check) → `interp.zig` (switch interpreter: i32/i64/f32/f64
  arithmetic, control flow, `call`, linear memory + data init, traps). Runs `fib(20)=6765`,
  `fac(7)=5040`, `sieve(30)=10`, etc. — all match `.test.json`.
- **Text toolchain** — `sexpr.zig` + `wat.zig` (WAT→wasm binary) + **`wast.zig` (WAST runner)**. Runs
  the **official spec testsuite** via `wazmrt <file.wast>`, both positive *and* negative conformance
  (`assert_invalid`/`assert_malformed`/`assert_exhaustion`; `assert_trap` gated on a real trap).
  Reference types, multi-table, imported globals, extended-const, reference-type table ops, element
  init expressions, and **imported functions + `register`/module-linking** all land; the
  validator/decoder correctly reject invalid/malformed modules (2026-07-09 post-audit).
  Representative: i32 **459/0**, i64 **415/0**, block **222/0**, if **240/0**, call_indirect **169/0**,
  select **154/0**, func **171/0**, align **140/0**, custom **8/0**, binary-leb128 **58/1**, elem
  **38/28**, func_ptrs **32/0**, table_copy **120**, table_init **67**, global 108/2 (see `testing.md`).
  **65 unit tests.** Remaining gaps: imported **tables/memories** (`imports.wast` 26/56), bulk table ops
  (`table.init`/`.copy`/`elem.drop`), passive element segments.
- **Licensing baseline** (git `888b87e`): dual `MIT OR Apache-2.0` (`LICENSE-MIT` + `LICENSE-APACHE`),
  `NOTICE`, and the compliance scaffold `third_party/LICENSES.md` (obligations table + Adoption
  Checklist + Component Ledger + verified SPDX inventory). README license section + SPDX + contribution
  clause. See `licensing.md`, `reference-projects.md`.
- **First runtime vertical slice**: Zig 0.16 project reshaped from `zig init` into a runtime skeleton.
  `Reader` (zero-copy + LEB128) + `Module` (header validate + section index). 7 unit tests passing.
- **Three build surfaces wired**: native CLI, C-ABI static lib, freestanding-wasm build. All
  build/test/run verified (see `design-decisions.md`).
- **C ABI = the standard wasm-c-api** (decision + slices, 2026-07-02): vendored `wasm.h` (Apache-2.0,
  first ledger entry); implemented `config`/`engine`/`store` + byte vecs + `wasm_module_new`/`_validate`/
  `_delete`, **plus `wasm_module_imports`/`exports` and the full type-object system** (valtype/functype/
  externtype/global/table/memory/importtype/exporttype) in `src/wasm_c_api.zig`; extension header
  `include/wazmrt.h`. **Verified from C** via `tests/c_smoke.c` (zig cc) — enumerates a module's import
  (`env.add`) and export (`run`, params=2 results=1). Retired the ad-hoc `wazmrt_module_*` ABI.
- **cmem/ project memory** established (this folder), mirroring the wasmtk setup.

**Remaining (in owner-set order):** **(1) full GC — P3, IN PROGRESS** (WasmGC: i31 → struct/array →
`ref.test`/`ref.cast`/`br_on_cast`; browser-standard, so in scope; owner directive 2026-07-13 puts it
*ahead* of the C-ABI/benchmark work — build in tested parts). **i31 slice DONE 2026-07-14** (`0f1e0c2`):
distinct `any`-hierarchy value types with real subtyping (`types.RefHeap.sub`), unboxed i31 in the `u64`
slot, `ref.i31`/`i31.get_s`/`i31.get_u` under `0xFB`. **struct/array slice DONE 2026-07-14** (`bec0cf7`
type-space refactor + runtime): `Module.func_types`→`comp_types` composite-type table (func/struct/
array + rec/sub/packed decode with a forward-ref kind pre-scan); an arena-backed GC heap
(`Instance.gc_heap`, no collector yet); `struct.new`/`new_default`/`get`(`_s`/`_u`)/`set`, `array.new`/
`new_default`/`new_fixed`/`get`(`_s`/`_u`)/`set`/`len`, `ref.eq`; WAT assembler parses `(type (struct/
array/field …))`. **`ref.test`/`ref.cast` slice DONE 2026-07-14**: heap objects carry an RTT
(`HeapObject.type_index`), i31 values are tagged (bit 63) so the `any` hierarchy is runtime-
distinguishable, `ref.test`/`ref.cast` dispatch on the target's hierarchy (abstract via `RefHeap.sub`,
concrete via `Module.isSubtype`); `CastFailure` traps. **`br_on_cast`/`br_on_cast_fail` slice DONE
2026-07-14** (`0xFB` 0x18/0x19; peek-ref + `refMatches` + `branch()`; validation checks `dst <: src`
and the label carry type; block-type decoder extended for non-null tags). **WasmGC op coverage is now
complete** (i31, struct, array, `ref.eq`, `ref.test`/`ref.cast`, `br_on_cast`/`br_on_cast_fail`).
**Assembler `(sub $super …)` supertype emission DONE 2026-07-14** — declared subtyping round-trips.
**Concrete `(ref $t)` value types DONE 2026-07-14** — `ValType` widened to `enum(u32)` (concrete refs in
the high bits); `(ref $t)` flows with its exact type through params/fields/locals/globals; producers push
concrete refs; `subtypeOf` uses `Module.isSubtype` for concrete↔concrete; `ref.null` takes a heap type.
The **collapse limitation is resolved** (see `design-decisions.md`). **P3 / full GC is COMPLETE** — every
WasmGC op + the full type system + concrete refs + declared subtyping, all tested. 95 unit tests +
`gc_struct_array.wast` 11/0 + `gc_cast.wast` 11/0 + `gc_br_cast.wast` 4/0 + `gc_subtype.wast` 5/0 +
`gc_concrete.wast` 2/0. **(2) wasm-c-api — instantiate + call slice DONE 2026-07-14**: `wasm_val_t` +
val/extern vecs, `wasm_instance_new`/`exports`/`delete`, `wasm_extern_*`/`wasm_func_*` (shared `Ref`;
`as_func`, `param_arity`/`result_arity`, `wasm_func_call`), `wasm_trap_new`/`message`/`delete`. A C
consumer now decodes → instantiates → gets exports → **calls an exported function and reads the result**
end-to-end (`tests/c_smoke.c`, run by `zig build c-smoke`: `add(40,2)=42`). **Host-function import wiring
DONE 2026-07-14**: `wasm_func_new[_with_env]` + `wasm_functype_new` + `wasm_valtype_vec_*`; a new interp
`HostFunc.native_env` variant + a C `hostTrampoline` bridge a module's func import to a C callback
(`error.HostTrap` on a returned trap). Verified: a module whose body is `call $env.add` returns
`run(40,2)=42` through a host callback. **Global/table/memory runtime objects DONE 2026-07-14**:
`wasm_global_new`/`get`/`set`/`type`, `wasm_memory_new`/`data`/`size`/`grow`/`type`, `wasm_table_new`/
`type`/`size`, all extern↔object casts, and import wiring for globals (value-copy) / memories+tables
(shared object). Verified from C: read/write an exported global, `store` into an exported memory then
read it back via `wasm_memory_data`, and `wasm_memory_grow`.

**The C ABI is now COMPLETE against the header (2026-07-15, `known-issues.md` #20).** Every one of the
**319** functions `wasm.h` declares is defined — it had been **180 short**, a link error for any
embedder following the header, invisible because our own tests only called what we implement.
`tests/c_abi_symbols.c` references them all and links into `c-smoke`, so a dropped symbol now fails our
build. Landed with it: the `wasm_ref_t` object model (refcounted `copy`, `same`, `host_info` +
finalizers, checked casts), **`wasm_table_get`/`set`/`grow`** — the long-deferred item, unblocked the
moment `wasm_ref_t` existed — type-object constructors/copies, `wasm_foreign_t`, `wasm_tagtype_t`
(type object only; EH stays deferred), and module serialize/deserialize/share. **Still deferred:**
shared-mutable imported globals; and `wasm_table_get` hands back funcrefs only (an externref slot has
no `wasm_ref_t` to return without boxing at the host boundary — it reports null rather than inventing
one). **First host-FFI integration DONE
2026-07-14**: `zig build dll` builds the C-ABI as a **shared library** (`wazmrt.dll`, libc-free), and
`examples/deno_ffi.mjs` (run by `zig build ffi-demo`) has **Deno `Deno.dlopen` the DLL and drive the
standard wasm-c-api** (decode → instantiate → call) → `answer()=42`. This validates the vision's
"native FFI → the C-ABI shared library" path (the `universalWasmLoader-*` ports themselves are WIT/
component-model + wasmtime-based, so they're a separate, larger effort). **(3) Deno/V8 benchmark — first
measurement DONE 2026-07-14** (`zig build bench` + a documented cross-process run; see `testing.md`):
native wazmrt beats Deno/V8 on **cold-start wall-clock — 2.4× on a trivial call, 1.5× on `sum(1e6)`** —
because Deno pays ~110 ms of V8 init + JIT + JS marshalling every run while wazmrt's own work is
sub-µs to tens-of-ms. Steady-state hot-loop throughput ~264 Mops/s (a JIT wins that regime — the
Option A→B trigger). **The vision's core thesis is confirmed: win short-lived / native FFI, lose
sustained hot loops.**
**(3)** the Deno/V8 benchmark. **(4) WASI preview 1 — first slice DONE 2026-07-14** (preview 2/3 deferred
until browser-standard, per wasmtk): `src/wasi.zig` implements the core `wasi_snapshot_preview1` host
imports — `fd_write` (stdout/stderr), `fd_read`/`fd_close`/`fd_seek`/`fd_fdstat_get`/`fd_prestat_get`,
`args_sizes_get`/`args_get`, `environ_sizes_get`/`environ_get`, `clock_time_get`, `random_get`,
`sched_yield`, `proc_exit` — with a `NOTSUP` stub for the rest, so a command module instantiates and
runs. No interpreter changes: WASI is just native host imports (`HostFunc.native_env`) whose `memory`
pointer is filled in post-instantiation. The **CLI runs command modules**: `wazmrt <file>` (or `.wat`,
now assembled by the CLI) sees the exported `_start`, wires WASI, and runs it; `proc_exit` unwinds via
`HostTrap` carrying the exit code. Verified end-to-end: `examples/hello_wasi.wat` → `hello from wasi`,
exit 0; +3 unit tests (98 total). **Deferred:** the filesystem (`path_open`, preopened dirs), stdin
(`fd_read` reports EOF), sockets, `poll_oneoff`. **The function-references proposal is complete** (typed-ref value types, `call_ref`/
`return_call_ref`/`ref.as_non_null`/`br_on_null`, non-null refs + local-init tracking, P1/P2/P2.5
2026-07-13 — ~+130 ref-file passes). (The WAST runner's invoke-by-module-name landed `9745ecb` —
`linking.wast` 29 → 100.) **Start function (#3) DONE 2026-07-13; the 2026-07-09
audit ledger is now FULLY cleared — every item #1–#16 resolved** (externref boxing #9, import-after-def
rejection #10, const-expr section ordering #12, dead-code cleanup #13, non-power-of-two `align=` #8,
defined-table inline export #11). Still **100% original runtime code** — no
reference-project code adopted yet (only the vendored `wasm.h`). `call_indirect` + tables + globals +
type-ref block types + **reference types** + **multi-table** + NaN-payload float literals + **imported
globals** + extended-const + **reference-type table ops** + **negative-conformance + validator/decoder
strictness** + **element init expressions** + **imported functions + `register`** (host imports stage 1)
**DONE 2026-07-09**. **Bulk table ops + passive elements + table initializer expressions +
const-expr/passive data segments DONE 2026-07-13** (#15 closed). **Host imports #1 COMPLETE — imported
tables/memories via shared objects (stage 2) + link-time import type-checking + `assert_unlinkable`
(stage 3), 2026-07-13** (`data` 12→34, `elem` 38→52, `imports` 26→137). **Start function (#3) + inline
memory-data / memory-table imports DONE 2026-07-13** (`start` 0→11). See `known-issues.md` for the fix
ledger.

## Track — run a fully compiled WASI program (planned 2026-07-14)

**Recon finding (evidence-based, the key insight).** Compiled a real Zig `wasm32-wasi` hello-world
(`zig build-exe -target wasm32-wasi -O ReleaseSmall`, 46 KB) and ran it in wazmrt. Result:
- **It instantiated fine** — every `wasi_snapshot_preview1` import resolved. A hello-world imports the
  *entire* WASI surface (`path_open`, `fd_readdir`, `poll_oneoff`, `fd_pread`, `path_*`, …, ~40 funcs)
  but only **calls** a handful (environ init, `fd_write`, `proc_exit`). The unimplemented ones fell
  through to the `NOTSUP` stub and were never called — the stub design handles this exactly.
- **It then trapped `UnsupportedOpcode`.** So **the blocker to running a compiled program is the
  INTERPRETER, not WASI.** wazmrt's `0xFC` decode only covers table ops (`0x0c–0x11`); LLVM/Zig emit
  `0xFC 0x08–0x0b` (**bulk memory**: `memory.copy`/`fill`/`init`, `data.drop`) and `0xFC 0x00–0x07`
  (**saturating float→int**) **by default** — both unimplemented.
- **Critical path:** `run a compiled stdout program = [interpreter: 0xFC 0x00–0x0b] + [only the WASI
  funcs it CALLS (mostly already have)]`. File-touching programs additionally need the WASI filesystem.

**Phase 1 — finish the `0xFC` prefix. DONE 2026-07-14 — MILESTONE HIT: a real LLVM-compiled program
runs and prints.** Decoded + executed + validated `0xFC 0x00–0x07` (saturating truncation: NaN→0,
±inf/out-of-range→min/max, never traps — `truncSatS`/`truncSatU`) and `0xFC 0x08–0x0b` (`memory.init`
copies from a passive segment, `data.drop` marks consumed, `memory.copy` = bounds-checked memmove
(overlap-safe), `memory.fill` = memset). `Instance.data_dropped` mirrors `elem_dropped` (active segments
start dropped per §4.5.4). Assembler + validator + 3 unit tests (101 total).
**`examples/hello_compiled.zig` → `zig build-exe -target wasm32-wasi` → `wazmrt hello.wasm` prints:**
`Hello from a compiled WASI program!` / `bulk-memory memcpy works` / `saturating truncation works` —
i.e. real compiled code exercising `memory.copy` (`@memcpy`) and `trunc_sat` drives wazmrt's WASI
`fd_write`.

> **RETRACTED 2026-07-15 (during Phase 3).** Phase 1 recorded a "guest-side gotcha": that Zig 0.16's
> `Io`-model file writer never issues `fd_write(1)` for stdout, called a *guest toolchain gap*. **That
> was wrong, and the diagnosis was mine, not the toolchain's.** The real cause: the example declared
> its own `extern "wasi_snapshot_preview1" fn fd_write(...) i32` while std declares the same import
> returning `errno_t` (`enum(u16)`). wasm-ld cannot reconcile two signatures for one import, so it
> silently redirects the call to a `.Lfd_write|wasi_snapshot_preview1_bitcast_invalid` stub whose whole
> body is `unreachable` — the guest traps with no diagnostic. Pure `std.Io` stdout works fine under
> wazmrt (`examples/hello_compiled.zig` now proves it). See `cmem/testing.md` for the trap signature
> and how to recognize it.

**Phase 2 — WASI core for stdout/args/env/compute programs. DONE 2026-07-14.** `clock_res_get` (via
`Io.Clock.resolution`); **`poll_oneoff`** — clock subscriptions sleep until the earliest deadline (this
is what a guest `sleep()` compiles to; relative + `ABSTIME` flag both handled via `Io.sleep`), and
fd_read/fd_write subscriptions on stdio report ready immediately (real fd-readiness polling defers with
the filesystem work); real **stdin** `fd_read` (fd 0 ← process stdin, scatter into iovecs, short
read/EOF → 0; other fds EBADF) wired from the CLI via an `Io.File.Reader`; `proc_raise` → trap.
Verified end-to-end by a compiled program (`examples/wasi_clock_stdin.zig`): `clock_res_get works` /
`poll_oneoff clock sleep works` (asserts ≥15 ms actually elapsed) / `stdin echo: hello stdin!`, plus the
EOF path. +2 unit tests (103 total). **wazmrt now runs the whole compute + stdout + args + clock + stdin
class — wasmtk's compiler-test-output regime (`vision.md`).**

**Phase 3 — WASI filesystem. DONE 2026-07-15.** `--dir <host>[:<guest>]` preopens a host dir as fd 3+
(`fd_prestat_get`/`_dir_name` enumerate; the CLI splits on the *last* `:` so `C:\tmp:/data` parses). A
**host-fd table** (`FdEntry` = stdio | dir | file, with rights + its own offset; lowest-free-fd reuse
on close). `path_open` honoring oflags/rights/fdflags, with the new fd's rights **intersected with the
dir fd's inheriting rights** — a guest can never widen its capability by reopening. Real
`fd_read`/`write`/`seek`/`tell`/`close`/`sync`/`datasync`/`pread`/`pwrite` (WASI fds carry their own
offset and we use the **positional** calls, so we never depend on the host handle's position);
`fd_fdstat_get`/`set_flags`, `fd_filestat_get`/`set_size`, `fd_readdir`, `fd_renumber`,
`path_filestat_get`, `path_create_directory`/`unlink_file`/`remove_directory`/`rename`. Rides the
libc-free Zig-0.16 `Io.Dir`/`Io.File` API. Verified by a compiled guest (`examples/wasi_files.zig`,
16/16 checks) + 3 unit tests (**106**).

**The sandbox is ours to enforce, and that is the headline.** `Io.Dir`'s `resolve_beneath` is a silent
no-op on Windows and Linux (it only maps to a FreeBSD `O.RESOLVE_BENEATH`), so an `*at`-style dir
handle is **not** a security boundary: an absolute path bypasses the handle entirely, and Windows
resolves `..` *lexically against the process cwd* before the syscall sees it. `wasi.resolve()` therefore
rejects absolute paths, escaping `..`, NT/device prefixes, and embedded NUL up front and hands `Io.Dir`
only a normalized `..`-free relative path. **Known gap (see `known-issues.md`):** a symlink *inside* a
preopen pointing outside it is still followed — containment is lexical; closing it needs per-component
resolution the `Io` API doesn't expose.

**Phase 3 leftovers** (deliberate, low demand): `path_symlink`/`path_readlink`/`path_link`,
`fd_filestat_set_times`/`path_filestat_set_times`, `fd_allocate`, `fd_advise` (returns success —
advisory), and real fd-readiness in `poll_oneoff`. All still resolve to the `NOTSUP` stub.

**Phase 4 — ergonomics + conformance. ORDERED BY THE OWNER — treat the sequence as binding rather than
re-deriving it.** The order was set 2026-07-15 and then twice amended by the owner as the day's work
surfaced things worth doing first (#20, then #22). None of the inserted items *block* the conformance
work at the end; they were scheduled ahead of it deliberately.

**4.0 — `known-issues.md` #22, the C ABI lifecycle fuzz. DONE 2026-07-16.** A randomized driver over
object-lifecycle sequences (new/copy/delete/host_info/cast/table-get/vec-transfer) under
`std.testing.allocator` so any double-free / leak / UAF fails the run — 400 seeds in `zig build test`,
coverage-guided under `zig build test --fuzz`, one driver behind both. **Building it found two more
real bugs**: a module use-after-free (`interp.Instance` stored `&m.inner` with no owned handle; the
embedder deleting the module then calling was a segfault — fixed by having the instance retain the
module) and a `wasm_trap_delete` double-free (it froze unconditionally, ignoring the refcount
`wasm_trap_copy` bumps — the fuzz caught it on seed 1, fixed with `release`). Verified the fuzz fails on
each reintroduced bug. +3 C-ABI tests (121 distinct). Invariants 5–6 in `design-decisions.md`.

**4.2 — `known-issues.md` #17, make the WASI sandbox real. DONE 2026-07-16 (then upgraded to full
traversal in 4.3, below).** Containment was *lexical*: a symlink inside a preopen pointing outside it was
followed straight out (`follow_symlinks=false` only guards the final `openat` component). First fixed
with a handle-based no-traversal walk; **then 4.3 replaced it with the secure handle-stack resolver
`walkFull`** that *follows* in-sandbox symlinks while keeping escape impossible by construction (`..`
can't rise above the preopen; absolute targets re-base to the preopen root; per-component no-follow
opens; `symlink_max`→ELOOP). No `openat2(RESOLVE_BENEATH)` needed — the walk gets there portably.
**Verified with real NTFS symlinks** (`examples/wasi_symlink_traversal.zig`, 5/5) + POSIX-CI unit tests
incl. an adversarial fuzz + Phase 3 gate still 16/16. One documented residual: a narrow
final-component `path_open` TOCTOU tied to std bug #18. See #17.

> ### ✅ 4.3 (2026-07-16). ✅ 4.4 + Phase 5 (2026-07-17). ✅ Phase 6 exception handling — core +
> **6.1 (WAT/`.wast`) + 6.2 (tag imports) + 6.3 (legacy EH) COMPLETE (2026-07-17)**. Both EH encodings
> run. ✅ **Phase 7 — multi-memory COMPLETE (2026-07-17)**. ✅ **Phase 8 — SIMD COMPLETE (2026-07-18)**:
> the two-slot v128 model + **the full 0xFD set** (splat/lane/shuffle/
> swizzle, comparisons, bitwise, int+float arith, shifts, any/all_true, bitmask, saturating add/sub,
> **drop/select-v128 silent-corruption gap is CLOSED** — the validator now type-checks SIMD (`simdSig`)
> and annotates each `drop`/`select` operand slot width; the interp runs it per-v128-function
> (`dropSelectWidths`, tolerant) and pops the right slots. avgr, popcnt, extend/narrow, int<->float
> convert + trunc_sat, promote/demote are in too. ✅ **WAT assembler for v128 DONE (2026-07-18)** — a
> ~130-entry `lookupSimd` name→sub-opcode table intercepted in `emitFoldedOne`/`emitFlatOne`, plus
> immediate parsing for `v128.const` (all 6 shapes), lane index, `i8x16.shuffle` bytes, and load/store
> memargs; 4 round-trip tests. `.wat`/`.wast` can now author SIMD. ✅ **Rare-SIMD ops DONE (2026-07-18)**
> — extmul (all 3 widths, low/high), `i32x4.dot_i16x8_s`, extadd_pairwise, `i16x8.q15mulr_sat_s`, i64x2
> comparisons, and the whole memory family (widening loadMxN, loadN_splat, load32/64_zero, loadN_lane/
> storeN_lane with a new `.mem_lane` assembler shape + per-op natural-align defaults). Also fixed a latent
> `simdSig` bug (unary extend/convert/trunc_sat/promote/demote were typed binary → drop/select mis-count).
> ✅ **Relaxed-SIMD DONE (2026-07-18)** — all 20 relaxed ops (`0x100`–`0x113`; madd/nmadd, laneselect,
> swizzle, min/max, trunc, q15mulr, both dot forms), each taking one spec-permitted behavior. ✅ **v128
> GC-fields close-out (2026-07-18)** — a v128 struct field / array element can't fit the flat
> one-`Value`-per-field object model, so `fieldIsV128` guards all struct/array new/get/set and **fails
> loud** (owner-chosen over an invasive slot-width object-model rewrite; no toolchain emits it). ✅
> **Imported-v128-global const-expr DONE (2026-07-18)** — `evalConstV128` handles `global.get` of an
> imported/preceding v128 global, and the host import ABI gained `Imports.globals_hi` so imported v128
> globals carry both 64-bit halves. **SIMD is now FULLY complete**: every 0xFD op decodes, validates, and
> either executes or traps cleanly — nothing silently corrupts, and there are **no known v128 gaps**.
> Next: pivot to the **signature path**.
>
> **Phase 8 — SIMD, foundational slice (2026-07-17).** Owner chose the **two-u64-slots** representation
> for the 128-bit `v128` (no memory penalty for non-SIMD; correct; more work than widening). The
> **foundation is the value**: `slotWidth()` (v128=2, else 1); `FuncBody.local_map`/`local_w` +
> `num_local_slots` (a v128 local is 2 slots); `blockArity`/branch, call arg/result counts, and the
> `invoke` arg check all in **slots**; `local.get/set/tee` copy the right slot count. **Non-SIMD is
> byte-identical** (all widths 1) — full suite + wasi-gate green. Ops: all 236 `0xFD` sub-opcodes
> **decode** (one `Op.simd` tag + `imm.simd.sub`; `decodeSimd` covers every immediate shape); a subset
> **executes** — `v128.const`, `v128.load`/`store`, `i32x4`/`i8x16`/`f32x4` splat, `i32x4`/`f32x4`
> extract/replace_lane, `i8x16`/`i32x4` add/sub/mul, `f32x4` add/mul (via Zig `@Vector`); the rest trap
> `UnsupportedInstruction`. 4 tests incl. a v128 held in a local. **KNOWN GAPS (document, don't hide):**
> (1) `drop`/untyped `select` of a v128 are **not width-aware** — they'd mis-count slots and corrupt the
> stack; the interp can't tell a v128 from an i32 there without type info (fix: a validator/decode type
> pass annotating widths). (2) v128 **globals**/GC-fields unsupported (loud `UnsupportedInstruction` for
> globals). (3) no **validator** SIMD sigs and no **WAT assembler** for v128 (`.wat` can't author SIMD;
> binaries run). The corpus has no SIMD today so the gaps aren't live, but they must be closed before
> claiming full SIMD.
>
> **Phase 7 — multi-memory (2026-07-17):** a module may have >1 linear memory; every load/store/
> `memory.*` selects one by index. `Instance.memory: ?*Memory` → `memories: []*Memory` +
> `imported_memories` (borrowed lead the space; `memory0()` accessor keeps WASI/C-ABI single-memory
> consumers working). Decode: the memarg alignment's **bit 6** flags an explicit memidx that follows
> (`MemArg.memory`); `memory.size`/`grow`/`fill`/`copy`/`init` carry memidx(s) (`mem_index`/`mem_copy`/
> `mem_init` immediates); active data segments already had a memidx (flag 2). Cross-memory `memory.copy`
> handles distinct buffers (no overlap) vs same-index (directional). 3 hand-built binary tests (index
> routing, cross-mem copy, `memory.size` by index); single-memory path unaffected (spec testsuite + all
> tests green). **Deferred (low-value): the WAT assembler for multi-memory** — it assumes a single
> memory throughout (spec-testsuite-critical), so text authoring of >1 memory is out; binaries run.
>
> **6.3 — legacy EH (2026-07-17):** the older `try`/`catch`/`catch_all`/`rethrow`/`delegate` encoding
> (0x06/0x07/0x19/0x09/0x18) that older LLVM emits — decode + execute (no assembler, no validator; the
> CLI run path doesn't validate). Inline handlers precomputed per `try` (`FuncBody.try_info`); a
> matching legacy catch runs INSIDE the try (label stays for `rethrow`/`br`), unlike a try_table catch
> which branches out. `rethrow N` re-raises the try-N caught exception from OUTSIDE that try. 4 hand-built
> binary tests. **wasmtk WASI corpus: 313 → 331 run** (the last 10 legacy-EH files now run); 2 library
> modules (no `_start`), 3 correctly trap (deliberate uncaught `throw`), **0 decode errors, 0 unexpected
> traps.** Deferred (low-value): the WAT assembler + validator for legacy `try` — toolchains emit binary,
> and the `.wat` are just decompiled views.
>
> **6.2 — tag imports (2026-07-17):** ran the **wasmtk WASI corpus** (`../wasmtk/tests/wasi/wasm_wasi`,
> 336 files) as a real-world conformance check. 21 failed to decode with `UnknownExternKind` — they
> import an exception tag (`(import "env" "__exn_tag" (tag …))`, extern kind `0x04`), which Phase 6 had
> deferred. Fixed: `ExternKind.tag`, tag imports/exports decode into a `tag_space`, imported tags lead
> the tag index space (`tagType`). **Result: 336 → 321 run fully, 2 library modules (no `_start`), 3
> correctly trap** (`15_panic`/`15_Trap-On-Error`/`13_Secure…` — they `throw` with no handler, an
> uncaught exception, which correctly traps with a backtrace), **and 10 use the LEGACY EH encoding**
> (`try`/`catch`/`rethrow` — 0x06/0x07/0x09), which we scoped out. Supporting legacy EH is the only way
> to run those 10; it's a real chunk — **owner decision** whether it's worth it.
>
> **Phase 6 delivered (DONE 2026-07-17):** the standardized **exnref** proposal end to end —
> `exnref` value type + `exn` heap type (`types.zig`/`opcode.zig`), the **tag section** (id 13,
> `Module.tags` + `tagType`), the IR ops `throw`/`throw_ref`/`try_table` with a `Catch`-clause immediate
> (`opcode.zig`), validation (try_table control frame + `checkCatch` label typing, `throw`/`throw_ref`,
> `UndefinedTag`/`InvalidTag`), and execution: an `Exception{tag,values}` unwinds via
> `error.UncaughtException` with each `call` site catching in its own try_tables (`Frame.onCallError` →
> `throwException` searches the label stack innermost-out); `exnref` values box into `Instance.exn_store`.
> 6 hand-built binary tests cover catch / catch_all / catch_ref / throw_ref / cross-frame catch / uncaught
> (→ trap). **6.1 (also DONE 2026-07-17):** the WAT assembler + `.wast` runner — see the §6 detail
> below. Legacy `try`/`catch`/`delegate` stays out of scope.
>
> **Phase 5 delivered (DONE 2026-07-17):** `src/pin.zig` (pure logic — SHA-256, content-addressed
> plaintext pin-DB parse, `# mode:` policy directive, `stricter`, and the pure `decide()` matrix) +
> the CLI in `main.zig`: `wazmrt pin <file> [--db <path>]`, and `verifyGate` gating execution — it
> hashes the **in-memory bytes it is about to run** (TOCTOU-safe: `verifyGate` receives the buffer, has
> no path to re-open), checks the root-owned DB, and applies the policy. Flags: `--pins <path>`,
> `--verify <mode>` (raise-only), `--no-verify`/`--yes` (**refused under `enforce`** — the precedence
> rule). Default `off`. 7 new unit tests incl. the full enforcement/precedence matrix; verified
> end-to-end (off runs; enforce+pin runs; enforce+wrong/absent refuses; warn+no-tty refuses;
> warn+`--no-verify` runs; enforce+`--no-verify` STILL refuses; corrupt DB fails closed).
>
> ✅ **Signature VERIFY mechanism BUILT (2026-07-18, `src/sign.zig`).** Owner decisions locked: trust
> anchor = **embedded root key** (`-Droot-key` → `sign.rootKeyFromHex`), format = **roll-our-own minimal** Ed25519
> over a `"signature"` custom section (governance-checked: wasmsign2 is an individual PoC / WASM-CG
> tool-convention, not Bytecode Alliance). `verify()` returns unsigned/authenticated/foreign/tampered via
> **streaming Ed25519** (Zig stdlib, no third-party crypto, no alloc); the CLI gate runs the signature
> check before the pin fallback (authenticated ⇒ no pin needed; tampered-by-our-key ⇒ refused always).
> **Inert until a build embeds a key** (default `null` ⇒ byte-identical to pin-only), same default-OFF
> discipline as Phase 5. 7 unit tests + manual real-binary e2e.
>
> ✅ **Signing CLI BUILT (2026-07-18).** `wazmrt keygen [--out <name>]` (Ed25519 keypair, entropy from the
> `Io`; private seed → `<name>.key`, public key printed to embed) and `wazmrt sign <in> <out> --key
> <keyfile>` (assembles `.wat`, appends the `"signature"` section). Thin CLI over the tested `signModule`
> + `pin.toHex`/`parseHex`; whole loop keygen→sign→embed→verify proven through the real binary. ⇢
> ✅ **Release key injection BUILT (2026-07-18).** `zig build -Droot-key=<64 hex>` embeds the trust anchor
> (empty ⇒ inert; malformed ⇒ build error). `build_options` is imported only by `main.zig`, so `sign.zig`
> (compiled into ~8 targets via `root.zig`) stays plumbing-free — no cross-target threading. Full loop
> keygen → sign → `-Droot-key` → verify proven through the real binary, no source edits.
>
> ✅ **Default policy DECIDED + BUILT (2026-07-18, owner).** CLI **denies unsigned** when verification is
> **armed** (root key embedded OR pin DB present); a bare build stays permissive. `--no-verify` overrides
> on the user's own machine, but a root-owned `# mode: enforce` is **absolute**. Signature-authenticated OR
> pinned ⇒ run. The **embedder path (wasmtk/rsxtk/C-ABI FFI) has no gate** — intended default: run.
> Custody = publish-SHA-256-and-pin (signatures and pins both count). **No key rotation** (rejected as a
> bad option). Implemented as `pin.decide(explicit, pinned, opt_out, tty, armed)` + `verifyGate`; also
> fixed `wazmrt pin` to assemble `.wat` before hashing.
>
> ✅ **Trusted-keys DB / companion keystore — SHELVED, NOT being built (2026-07-18).** Decided in the
> morning, then reversed the same day after a package-manager verification survey (deep-research, 21
> sources): a multi-key keystore is **redundant for the chosen single-publisher / package-managed model**.
> The store is the **root-owned pin DB** (installer records each `.wasm`'s SHA-256 — the Homebrew/Scoop/
> RPM-metadata model) **plus the single embedded `-Droot-key`** (Nix's one-trusted-key model). No
> `wasm-keys.json`, no reader, no ownership-check code. **The wazmrt authenticity path is feature-complete**
> (pin + signature verify + `keygen`/`sign` + `-Droot-key` + deny-when-armed). ✅ **Bulk `wazmrt pin <dir>`
> BUILT (2026-07-18)** — recursively pins every `.wasm`/`.wat` under a directory (assembles `.wat`; skips
> non-modules; sorted; one `--db` write), so a packager pins a whole bundle in one step. ⇢ Optional only:
> publisher private-key custody (HSM). See `security-model.md`.
>
> **The C ABI is NOT remaining work** — #20 (all 319 `wasm.h` fns) / #21 (mem-safety) / #22 (fuzz) are
> DONE and 4.4 added a C conformance guest. Only two narrow, demand-driven residuals stay deferred:
> shared-mutable imported globals, and externref table slots via `wasm_table_get`. Don't treat C as a
> phase.
>
> **4.4 delivered (all DONE 2026-07-17):**
> - **`--env KEY=VAL`** (repeatable) — sets one guest env var; guest environ otherwise empty. `main.zig`.
> - **`--ro-dir <host>[:<guest>]`** — read-only preopen. `wasi.zig` gained `rights.write_mask` /
>   `rights.read_only` and public `allRights`/`readOnlyRights`; `addPreopen` takes `dir_rights: u64`.
>   Because `path_open` only ever *narrows* an fd's rights against its parent dir fd, read-only-ness
>   propagates to the whole subtree. Unit-tested (rights-mask + narrowing invariant, POSIX-CI).
> - **`zig build wasi-gate`** — compiles REAL `wasm32-wasi` guests and runs them through the wazmrt CLI,
>   asserting exact stdout. **Zig + C (`zig cc`) always-on** (both ship with the Zig toolchain);
>   **Rust opt-in via `-Drust-gate=true`** (needs rustc w/ wasm32-wasip1). Guests:
>   `examples/hello_compiled.zig`, `examples/c_hello.c`, `examples/rust_hello.rs`. Verified wazmrt runs
>   all three compilers' output byte-for-byte. The gate *can fail* (wrong output → exit 1, confirmed).
>

## Phase 5 — Secure base: pin verification (✅ COMPLETE 2026-07-17 — all 6 increments below built)

The **buildable slice of the authenticity design** (`security-model.md`), chosen next because its
mechanism is fully **DECIDED** and it needs **none** of the still-open *signature* decisions (trust
anchor, signature format, revocation). It delivers the unsigned-module path end to end: an install-time
root-owned pin + a pre-run SHA-256 check.

**Decided mechanism — do NOT re-derive (security-model.md §1):**
- Pin DB is **root-owned, read-only to the user, plaintext**. Integrity from *ownership*, not secrecy.
- Pinning is done **at install time, with privilege** — verified install, **NOT TOFU**. wazmrt (as the
  user) only ever *reads* the DB; user-level malware can't rewrite it.
- **Signed → verify signature; unsigned → check the pin.** This phase builds the **pin** half only.
- **TOCTOU discipline (aligned with owner 2026-07-17):** read the file **once** into memory, hash *those*
  bytes, execute *those* bytes — never hash-by-path then re-open. It is not caching/perf: the buffer is
  freed at exit like any decode buffer; it exists so the verified bytes provably *are* the run bytes,
  closing the check→use swap window. It falls out of how the runtime already loads a module (zero/negative
  cost). In the root-owned-script deployment ownership already shuts the window; the single-read keeps the
  guarantee sound even when a user runs `wazmrt ./downloaded.wasm` from a writable dir.
- Cold-start cost **measured negligible** — SHA-256 ~21 µs (~0.5% of instantiate).

**Increments (each with tests):**
1. **Pin DB format** — minimal plaintext, auditable (`cat`/diff-able). Micro-decision: **content-addressed**
   (just the set of approved SHA-256s — path-independent, simplest) vs `sha256␠identifier` lines. Lean
   content-addressed.
2. **`wazmrt pin <file>`** subcommand — hashes the module and writes/appends the DB; meant to be run with
   privilege by an installer. Document the root-owned DB location per-OS.
3. **Runtime verify** — before instantiating a `_start` command module, SHA-256 the **in-memory** bytes,
   look them up in the pin DB, gate execution. **Reuse the single buffer the loader already reads**
   (TOCTOU-safe by construction).
4. **Enforcement policy = a knob, default OFF for now** — `default-deny-unsigned` is still an *open* owner
   decision, so ship the check behind an explicit mode (e.g. `--verify`, or "DB present ⇒ enforce"),
   erroring clearly on mismatch / absent pin. **Do NOT make deny-the-default until the owner settles it.**
5. **Unverified-module handling — interactive consent, not a bare skip flag (owner refinement,
   2026-07-17).** When a module isn't in the pin DB, behaviour is governed by the root-owned policy:
   - **`off`** (dev default) → run, optional one-line "unverified" notice. **No prompt** — prompting on
     every run trains dismissal (the "warning users always dismiss" anti-pattern, `security-model.md`).
   - **`warn`** → **interactive TTY: prompt** "module X is unverified (not pinned) — proceed? [y/N]",
     **default No** on EOF / non-interactive. **No TTY** (script, pipe, cron, `binfmt`/`argv[0]` dispatch
     — the vision's own deployment) → **deny**, unless an explicit non-interactive opt-out is present.
   - **`enforce`** (hardened) → **hard deny, no prompt** — a locked-down system doesn't negotiate and has
     no TTY to negotiate with.

   **Two things this must NOT pretend to be:** (a) the prompt is **UX consent, not a security boundary** —
   `echo y | wazmrt evil.wasm` / `yes |` answers it for an attacker, so it only helps an honest human; the
   real boundary stays the root-owned policy. (b) it can't be the *only* mechanism — the unattended
   deployments have no keyboard, so keep a **non-interactive opt-out** (`--yes` / `--no-verify` or
   `WAZMRT_ASSUME_YES`) for scripts, itself **subordinate to the policy** (honored under `off`/`warn`,
   **refused under `enforce`** — authority from ownership, not from a runtime argument). Record the prompt
   text, the TTY/EOF→No rule, and the opt-out precedence in `main.zig` help and `security-model.md`.
6. **`bytes-hashed == bytes-run` test** — assert the verified buffer is the executed buffer, so a future
   refactor can't silently reintroduce a hash-by-path TOCTOU.

**Open, and NOT blocking this slice** (they belong to the *signature* path): trust anchor, signature
format, revocation. **Touches this slice:** default policy (deferred to the knob above), DB
location/ownership convention per-OS. All tracked in `security-model.md` "Open decisions".

## Phase 6 — Exception handling (✅ COMPLETE 2026-07-17 — core + 6.1 WAT assembler + `.wast`)

**6.1 delivered (2026-07-17):** the WAT assembler now emits the tag section and assembles
`throw $e` / `throw_ref` / `try_table` with catch clauses (`catch`/`catch_ref`/`catch_all`/
`catch_all_ref`), folded *and* flat forms, with `$tag`/`$label` name resolution (the try_table's own
label is pushed before its catches resolve, so `(catch $e 0)` targets the try_table). `exnref`/`(ref
exn)` parse as value types (fixed a latent bug: the valtype table had mapped `exnref` → `externref`).
The `.wast` runner counts an uncaught exception as a trap (`isRuntimeTrap` += `UncaughtException`). 6
round-trip tests (5 in `wat.zig`, 1 `.wast` in `wast.zig`) + CLI-verified end to end. Running the
*official* `exception-handling` `.wast` corpus is gated only on that corpus being present in-tree (it
isn't — the spec corpora live on removable media, like the others).

**Scope decision first:** target the **standardized exnref proposal** (`try_table` + `throw`/`throw_ref`,
`tag` section id 13, `exnref` heap type) — it shipped cross-browser (Chrome/Firefox 2024) so it clears
the project's browser-standard bar (`design-decisions.md` proposal-scope). The **legacy** form
(`try`/`catch`/`catch_all`/`delegate`/`rethrow`, older LLVM/Emscripten) is a *distinct* encoding; treat
it as a later compat add-on only if a real corpus module needs it, not part of this phase.

**Why it fits cleanly:** EH extends seams that already exist — a new section (like tags are just typed
function-signatures), new opcodes in the `opcode.zig` IR, new control-frame kinds in `validate.zig`, and
a new unwind path in `interp.zig` that can reuse the label/frame stack the trap backtrace (#19) already
walks.

**Increments (each with unit tests + a `.wast` slice; keep the IR seam clean):**
1. **Decode** — tag section (id 13): each tag = an attribute byte + a type index (the exception
   signature). Store on `Module` alongside functions. Add `exnref` to the heap-type/valtype decoders.
2. **IR** — add `throw {tag}`, `throw_ref`, and `try_table {blocktype, catch[]}` to `opcode.zig`
   (`Op`/`Imm`/`decodeBody`), where each catch clause is `{kind: catch|catch_ref|catch_all|catch_all_ref,
   tag?, label}`. Mirror in the assembler (`wat.zig`) for `.wast` coverage.
3. **Validate** — `try_table` pushes a control frame carrying its catch table; `throw` checks operands
   against the tag's params; `throw_ref` consumes an `exnref`; catch-clause target labels must accept
   the tag's params (+ `exnref` for the `_ref` variants). `exnref` typing + null rules.
4. **Execute** — represent a thrown exception as `{tag, values}`; `throw` unwinds the frame/label stack
   to the nearest enclosing `try_table` whose catch matches (by tag, or `catch_all`), pushing the values
   (and an `exnref` for `_ref`); `throw_ref` re-throws a caught `exnref`; unmatched at the top frame →
   the existing trap path. Reuse the `errdefer`/frame machinery from #19 where it fits (mind the
   `noinline recordTrap` invariant — the unwind is an error-ish path off the hot switch).
5. **Conformance** — run the spec `exception-handling` `.wast` files through `wast.zig`; add a compiled
   guest to `wasi-gate` only if a stock toolchain emits exnref by default (C++ `-fwasm-exceptions` via
   wasi-sdk does; Zig/Rust panics are traps, so probably a `.wat`/`.wast`-only gate).

**Open sub-question for the owner (surface before coding step 4):** do we want the legacy try/catch
encoding at all, or exnref-only for now? Plan assumes exnref-only.

> 4.3 delivered (all DONE 2026-07-16): the safe leftovers (`fd`/`path_filestat_set_times`, `fd_allocate`,
> `path_link`, `poll_oneoff` EBADF fix) **and** — owner chose full traversal — `path_symlink`/
> `path_readlink` with the secure **handle-stack resolver** (`walkFull`): in-sandbox symlinks followed,
> escapes impossible by construction, adversarial-fuzzed. See `security-model.md` (DONE) and #17.
>
> Three findings from the pause conversation, retained for the record:
> 1. **The vision's symlink is host-side dispatch** (`argv[0]`/`binfmt_misc`), **not** the guest-visible
>    symlink of #17 — **the vision does not need `path_symlink`.** The two were being conflated.
> 2. **If `path_symlink` is ever built, targets must be validated at *creation*** (refuse escaping
>    targets) — a persisted link is a landmine for whoever follows it next with more authority. This is
>    *different from and stronger than* the traversal policy, and holds even if no-follow is kept.
> 3. **`--ro-dir` (read-only preopens)** looks like the highest security-value-per-effort item available
>    and is on no list. It may deserve to jump the queue.
>
> **4.3 progress:** the safe, no-policy items are **DONE 2026-07-16** — `fd_filestat_set_times`,
> `path_filestat_set_times` (via an opened handle, dodging a std `dirSetTimestamps` panic — #23),
> `fd_allocate` (extend-not-shrink via `setLength`), `path_link` (POSIX-only; Windows std has no hard
> links — #23), and a `poll_oneoff` correctness fix (a subscription on a closed fd reports EBADF, not a
> false "ready"; note **files/stdio being always-ready is *correct* per POSIX, not a stub** — only
> pipes/sockets, which we don't have, would need real polling). +3 unit tests, `examples/wasi_leftovers.zig`
> gate. **`path_symlink` / `path_readlink` DONE 2026-07-16 — owner chose FULL traversal (wasmtime
> parity).** The lexical/no-follow walk was replaced by the secure handle-stack resolver `walkFull`
> (RESOLVE_BENEATH in userspace): in-sandbox symlinks are **followed**, escapes are impossible **by
> construction** (`..` can't rise above the preopen; absolute targets re-base to the preopen root;
> per-component no-follow opens through held handles; `symlink_max`→ELOOP). `path_symlink` validates
> targets at creation (absolute refused). Verified 5/5 on Windows with real symlinks
> (`examples/wasi_symlink_traversal.zig`) + POSIX-CI unit tests incl. an **adversarial fuzz**
> (random topologies, canary oracle). Design in `cmem/security-model.md` (marked DONE). Creation is
> POSIX-only (Windows privilege, #17/#23); following works everywhere. **4.3 COMPLETE.** Then **4.4** —
> the Phase 4 items proper (`--env`, the `zig build`-driven compiled gate, C/Rust/Zig conformance).

**4.1 — `known-issues.md` #19: trap diagnostics. DONE 2026-07-15.** Traps now report a named
backtrace, innermost frame first — on the exact binary from the Phase 3 hunt:
`at fn[31] <.Lfd_write|wasi_snapshot_preview1_bitcast_invalid> +0` / `by fn[30] <min.main> +22` / … —
and hint to rebuild unstripped when a module carries no names. `Frame` carries `func_index`; `Frame.run`
records via **`errdefer`**, which emits code on the error path only, so the dispatch loop is untouched
and the trace assembles itself innermost-first as the error unwinds. Frames land in a fixed
`[16]TrapFrame` on `Instance` — recording a trap must not allocate (we may be unwinding an OOM) or fail
— with `trap_depth` keeping the true depth so truncation is visible, reset per `invokeIndex`. Names are
decoded **lazily** from a kept copy of the name section's function-name subsection; a malformed one
degrades to "no names" rather than erroring on the path already reporting an error.

**4.1 also fixed a latent C ABI break it exposed.** `wasm.h` declares `wasm_trap_origin`,
`wasm_trap_trace` and the `wasm_frame_*` family; we defined none of them, so an embedder following the
header got a **link error** — not the "trace isn't surfaced yet" nicety this was first recorded as.
Now implemented and guarded by `tests/c_smoke.c`, which deliberately traps and walks the backtrace
(asserting the reported `module_offset` really lands on the `unreachable` byte). Auditing the whole
header turned up **180** declared-but-undefined symbols, now 167 → **`known-issues.md` #20**, which
also carries the reproducible audit command. Byte offsets are resolved **lazily** by re-decoding one
body (`Instance.frameOffset`) — tracking them per instruction cost ~7% cold-start for a path most
modules never take.

+6 unit tests (**111**). **Ended up faster than the baseline**: steady **286–288** vs **260–262**
Mops/s, cold **0.86** vs **0.90** us/run. The route there is the durable lesson: the first cut
regressed **14%** from an *error-path* change, because `Frame.run`'s `errdefer` expands at every `try`
in a ~200-arm switch and inlining `recordTrap` there evicted the loop from i-cache. `noinline` fixed it
and beat the old baseline — 4.1 had been inlining it too. Both facts are now invariants in
`design-decisions.md`; the bisect method is in `testing.md`.

**4.1½ — `known-issues.md` #20 + #21: the C ABI. DONE 2026-07-15, inserted by the owner** ahead of
#17 ("Definitely #20 first. It seems like a big hole at the moment, that we don't need to fall into").
4.1 exposed that `wasm.h` declared **180 functions we never defined** — a link error for any embedder
following the header. All 319 are now defined and gated at link time (`tests/c_abi_symbols.c`). The
owner then flagged memory safety as a project goal, and the audit that followed found **four real
bugs** — a double free, a use-after-free needing no misuse, an uninitialized refcount, and a leak —
three of them shipped hours earlier. Fixed, with the deeper problem fixed too: the C ABI was
**unreachable from `zig build test`** and `c_smoke.c` runs on an allocator where a double free prints
`OK`. See #20/#21, and the memory-safety invariants in `design-decisions.md`. +7 C-ABI lifecycle tests
(**118 distinct**; `zig build test` prints 229 — see `testing.md` on reading the count).
**#22 (fuzz the lifecycle) is the follow-up, and the owner made it the first item for 2026-07-16.**

**4.2 — `known-issues.md` #17: close the symlink hole (make the sandbox real, not lexical).**
*Budget for this: it is the biggest item in Phase 4, not a cleanup.* `resolve()` stops a guest *naming*
a path outside a preopen, but a symlink stored *inside* one still gets followed out. Correct
containment needs **per-component** resolution, and **Zig 0.16's `Io` exposes no way to do it**:
`resolve_beneath` is a silent no-op off FreeBSD, and there is no `openat2(RESOLVE_BENEATH)` and no
O_PATH walk. So expect to go **below `Io` to raw platform syscalls** (Linux `openat2` with
`RESOLVE_BENEATH`/`RESOLVE_NO_SYMLINKS`; Windows: walk components with
`statFile(.follow_symlinks=false)` and re-validate each target, or open with `OPEN_REPARSE_POINT` per
component) — with a portable fallback. Watch TOCTOU: validate-then-open on a live filesystem races, so
prefer resolving *through held handles* rather than re-walking by path. The existing `if (!follow)`
pre-stat in `wPathOpen` is the natural hook. **Done means:** a test where a symlink inside the preopen
targets outside it is refused with `ENOTCAPABLE`/`ELOOP` — add it to `examples/wasi_files.zig`
alongside the four existing refused escapes. Only after this may the README stop hedging the sandbox.

**4.3 — the Phase 3 leftovers** (listed above): `path_symlink`/`path_readlink`/`path_link`,
`fd_filestat_set_times`/`path_filestat_set_times`, `fd_allocate`, real fd-readiness in `poll_oneoff`.
These are the likeliest things 4.4 trips over, since wasi-libc and Rust's std touch more API surface
than our Zig guests do. Note **4.2 changes what `path_symlink`/`path_readlink` must do** — implementing
them before the sandbox is real would mean writing them twice, which is part of why they sit after it.

**4.4 — the Phase 4 items proper. ✅ COMPLETE 2026-07-17.** ~~CLI `--dir`~~ (Phase 3) /
~~`--env KEY=VAL`~~ / ~~`--ro-dir`~~ / ~~`-- <guest args>`~~ all done. The reproducible
`zig build wasi-gate` gate compiles real `wasm32-wasi` programs and runs them in wazmrt asserting exact
stdout — **Zig + C via `zig cc` always-on** (both ship with Zig), **Rust opt-in `-Drust-gate=true`**.
Verified wazmrt runs all three compilers' output. The remaining long tail (fill in more
actually-called functions as specific guests demand them) is demand-driven, not a blocker.

**Not scheduled: `known-issues.md` #18** (the Zig std `openFile(.follow_symlinks=false)` host crash).
It is worked around and contained — it is **trigger-based, not ordered**: recheck it on **every Zig
upgrade**, whenever that happens. 4.2 will touch the same `wPathOpen` hook, so re-read #18 before
changing that code.

## Next increments (rough order)

1. ~~Decode the type/function/import/export sections~~ **DONE 2026-07-02** (also table/memory/global +
   full `Extern` resolution; exposed via C `wasm_module_imports/exports` + the wasm-c-api type-object
   system). ~~Decode the code section~~ **DONE 2026-07-02** (locals + raw body bytes per defined
   function, arena-owned; instructions not yet parsed).
2. **Validation** — **DONE 2026-07-02.** `src/opcode.zig` (core-MVP `Op` enum 0x00–0xC4, `Imm`/`Instr`,
   `decodeBody`; ref-type / `0xFC` / `0xFD` / multi-byte block-types → `UnsupportedOpcode`) + the
   type-checking validator `src/validate.zig` (spec Appendix algorithm: value stack + control frames +
   `unknown` bottom; count match, index bounds, control flow, operand-stack typing). 8 unit tests;
   **all 12 `wasm_mod` validate; every fully-decoding `wasm_wasi` validates** (see `testing.md`).
   **Opcode-expansion priority (from real corpus data): `0xFC` bulk-memory first, then exception
   handling (tag section id 13 + try/catch), then SIMD** — what `wasm_wasi` needs beyond core MVP.
3. **Instantiation** — memories, tables, globals, imports/exports wiring; grow the C ABI to
   `wasm_instance_new` + `wasm_func_call`.
4. **Execution** — **integer + float + memory slices DONE 2026-07-02** (`interp.zig`): switch
   interpreter over the IR (Option A), untyped `u64` slots, per-call label stack + precomputed branch
   targets. i32/i64 **and f32/f64** arithmetic/comparison/bitwise + all conversions, locals, globals,
   `drop`/`select`, structured control flow, direct `call`, **linear memory** (min-page alloc + active
   data-segment init, load/store all widths, `memory.size`/`grow`), and traps — 9 unit tests.
   **VERIFIED end-to-end on real modules:** the CLI gained `wazmrt <file.wasm> <export> [args…]` and
   runs the whole `module/wasm_mod` corpus to its `.test.json` values (`fib(20)=6765`, `fac(7)=5040`,
   `isLeapYear`, `isOdd`, `sieve(30)=10` via memory). **`call_indirect` + tables + globals +
   reference types DONE 2026-07-09** (type-checked indirect dispatch; global-init const-expr eval;
   `ref.null`/`ref.is_null`/`ref.func` + funcref/externref values; multi-table dispatch). **Remaining
   execution slices:** (a) `table.get`/`.set` + passive elements, (b) **host imports** (needed for
   WASI). Keep the IR a clean seam so a register-machine pass (Option B, wasmi) can be layered later
   if benchmarks demand it.
5. **Text toolchain — WAT assembler + WAST runner** (IN PROGRESS, owner-chosen 2026-07-02; the
   `.test.json` harness was dropped in favor of the standard `.wast` format). `sexpr.zig` DONE;
   **`wat.zig` DONE** (WAT→binary: funcs/exports, folded+flat, structured control flow + labels +
   blocktypes, memarg, memory + data sections — all assemble→run verified). Next: `wast.zig`
   (assertion runner), then run `module/wasm_wast/testsuite-main` as the standing conformance gate.
   global/table/elem, multi-value block types, and `call_indirect` all **DONE** (2026-07-02/07-09);
   deferred: reference-type instructions, imports. See `text-toolchain.md`.
6. **Grow the wasm-c-api implementation** as the runtime gains ability: `wasm_module_imports/exports`
   → then instance/func/trap/call at instantiation+execution. The standard signatures are already
   declared in the vendored `wasm.h`; we just implement more of them. Extend `tests/c_smoke.c` alongside.
6. **First `universalWasmLoader-*` integration** — prove the C-ABI static lib and/or the wasm build
   load from at least one host language end-to-end.
7. **Size/speed baseline** — the real perf gate (see `vision.md` → Performance target). Benchmark
   **native wazmrt vs Deno/V8** on wasmtk's own outputs, timing **cold-start wall-clock** and
   **steady-state throughput** separately (which regime does wasmtk live in?). Also size + startup vs
   wasm3 / WAMR-fast-interp. This data decides whether/when to move Option A → B (register machine).
   Baseline sizes today (`ReleaseSmall`): CLI exe ~611 KB (mostly Zig std + OS glue), C-ABI lib ~34 KB,
   freestanding wasm ~13 KB (lib/wasm are the decode/validate subset — execution not yet exported).

## Parking lot / open questions

- Interpreter shape: **DECIDED 2026-07-02 — Option A** (switch over a pre-decoded IR); see
  `design-decisions.md`. Open sub-question: whether/when to add the Option B register-rewriting pass —
  decide empirically against size+speed once basic execution works and there's a benchmark.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
