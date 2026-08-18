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

### 🎯 REVISED conformance list (2026-08-12) — the 275, now **104**; EVERY CORE FILE IS CLEAN

Successor to the T-list above, and built differently: every item below is grouped **by cause**, from a
run with `-Dfailures=600` so all 275 failures were read, not just each file's first. The T-list was
grouped by first-failure text and mislabelled three of its five items.

⚠️ **The per-item counts below are as-triaged (275 total) and are NOT live. THE WHOLE R-LIST IS
CLOSED, AND SO IS EVERYTHING AFTER IT.** R1–R5, R7, R9 and R10 are done, R6 was closed by R3 and R8
by R5, the singleton batch took the remainder, and the bottom-type lattice took the last of it —
corpus is **104 failures / 62,889 passing / 951 skipped** (measured 2026-08-14).

🏁 **THE WHOLE CORPUS IS AT ZERO FAILURES — every core file AND every proposal file.** Corpus **0 failures / 63,934 passing / ZERO skipped** (2026-08-18). The baseline holds ONE line: `annotations.wast`, a runner-lex gap on untargeted custom-annotations. ✅ **TRACK D (custom-descriptors) IS COMPLETE — D1–D5 all ship**, and TRACK P before it. ✅ **The last two — baseline group 4, the first entries that were wazmrt DEFECTS rather than untargeted proposals — were closed the same day the group was created:** EXACT function imports end to end (descriptor kind `0x20`, `(exact <typeuse>)` in the text, link-time type EQUALITY, and the linker resolving an export through import chains to its DEFINING instance), and `(ref …)` taking exactly one heap type. Deliberate deviations remain ZERO. ⚠️ D2/D3/D4 each dropped the pass and grand-total columns for correct reasons; see testing.md before reading that as a regression. *(Superseded: 4 / 63,391 / 497; 16 / 63,315 / 578; 53 / 63,344 / 515.)* The 8 era-pinned `proposals/threads` assertions CLOSED via F3+F4, and the skip total fell 965 → 673 via the skip-scoring split; both same day. *(Superseded: 89 failures / 62,890 passing / 965 skipped.)* ⚠️ **14 of the previously-reported 104 were a SCORING BUG** — a bare `(module …)` build failure never consulted `isOurLimitation`, so our own gaps were counted as defects here while scoring as skips everywhere else. `delegate` was one of them, never a deviation; `anyfunc`, the last real one, was closed 2026-08-17. *(Superseded:)* 90 failures / 62,889 passing; 89 non-defects + ONE deliberate deviation; LIVE SPLIT: 102 by design + 2 recorded deliberate
deviations** — `anyfunc` (`obsolete-keywords.wast`, the pre-standard spelling of `funcref`, kept
because two real `.wat` inputs use it) and `delegate` (`legacy/try_delegate.wast`, refused loudly
because no oracle exists to route it). ✅ **BOTH ARE CLOSED: `anyfunc` on 2026-08-17, and `delegate` SHIPPED 2026-08-18 (Track L) — deliberate deviations are ZERO.** *(Historically: `delegate` became SD-3 in `known-issues.md`'s STANDING
DELTAS section, carrying a reopen condition this line never did — and that condition is what closed it: pricing SD-3 prompted a re-test, the condition had been met all along, and the instruction shipped.)*
**There are no undiagnosed failures left**, which changes what
this list is for: it is now a record, not a work queue. ⚠️ *(Updated 2026-08-18: the work this sentence pointed at — "Track 3's residual and the PROPOSED Tracks F / P / D" — is gone. **F, P and D all shipped**, and Track 3 was reclassified as the **BAKE OFF, a COMPARE task rather than a fix task**. The only FIX task left in this file is **Track A**, custom-annotations.)* *(Corrected 2026-08-17: this
line also named "the OPEN C-ABI externref hole" and Track 2c. **Both are CLOSED** — references cross
the C ABI as checked handles since 2026-08-14 (`known-issues.md`), and Track 2c landed the same day.
`-Dgc=false`-style PER-PROPOSAL comptime gating was never part of 2c and is still open.)*

Every count below is history; re-measure before trusting any of them (`-Dfailures=600`, and read
**all three** totals — see the lattice entry on why the per-file FAIL diff alone missed a regression).

⚠️ **"By design" has TWO flavours and they are not the same claim.** 94 are *untargeted
proposals* (`custom-descriptors`, `custom-page-sizes`, `wide-arithmetic`) — refused honestly because
wazmrt does not implement them. The other 8 are the opposite: `proposals/threads` is a snapshot
pinned to a spec **before** multi-memory and multi-table, and it fails because wazmrt implements
those proposals and therefore *accepts* modules the snapshot calls invalid. **A proposal directory
asserts the rules of its own era, not today's** — so a failure there can mean the runtime is ahead of
the file, and reading it as a defect costs real work (it cost R7 two days as an "actionable 8").

⚠️ **R9 WAS FILED AT 85 AND MEASURED 71 — the standing "counts are stale" warning has now fired in
the LOW direction too.** Every previous correction (R1 25→38, R2 35→44, R3 10→16, R5 23→1,291) was an
UNDERCOUNT, which quietly trained the habit of reading the warning as "expect worse". R10 had closed
some of R9's members as a side effect and nobody re-measured. **Stale is stale in both directions;
the instruction is to re-measure, not to pad.**

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

**SPLIT AS OF 2026-08-14 — NOT LIVE, AND "final" WAS WRONG TWICE OVER: 104 failures = 102 by design + 2 recorded deliberate deviations**  — `anyfunc` and `delegate`. *(Both claims fell: 14 of the 104 were a scoring bug and `delegate` was one of them, so it was never a deviation; `anyfunc` was then closed 2026-08-17. Live figure is 81 failures, ZERO deviations — see the top of this file. **A snapshot labelled "final" is still a snapshot.**)* Formerly legacy EH **2**,
core singletons **18**. R10's residue is now half closed: `id` 5 went with R9 (the quoted-`$"…"`
identifier form, forced into scope — see below), leaving `ref_null` 27 skipped behind its unbuildable
first module, which needs the bottom-type lattice change.

**The actionable items, most valuable first:**

| | item | failures | why it matters |
| --- | --- | --- | --- |
| **R1** 🔴 | **Cross-module type identity** | 25 | ✅ **FIXED 2026-08-12 — and it was 38, not 25.** See below. |
| **R2** 🔴 | **elem / linking / instance** | 42 → 35 | ✅ **FIXED 2026-08-13 — five causes, and 44 failures, not 35.** All five files CLEAN. See below. |
| **R3** 🟠 | **GC array bulk ops MISSING** | ~10 → **16** | ✅ **FIXED 2026-08-13 — SIX ops missing, not four, and the cost was in SKIPS, not failures.** See below. |
| **R4** 🟠 | **Accept-invalid in core files** | ~15 → **12** | ✅ **FIXED 2026-08-13 — five causes, and two of them ALSO caused false rejects.** Core accept-invalid is now **0**. See below. |
| **R5** 🟡 | **Runner gaps, not wazmrt defects** | 41 → ~23 → **1,291** | ✅ **FIXED 2026-08-13 — and the item was undercounted by 50×.** `(module quote …)` alone was suppressing **1,291 assertions**. See below. |
| **R6** 🟡 | GC type remainder + `i31` | 20 → 8 → **0** | ✅ **CLOSED 2026-08-13, and R3 closed it without aiming at it.** R1 took `type-subtyping`/`type-rec`; the last 8 were `i31.wast`, and they were not an i31 defect at all — the file uses `(elem $e i31ref …)` and the assembler's `isRefType` listed only `funcref`/`externref`, so the whole segment was misread as func indices. One shorthand-table fix, `i31.wast` 8 → 0. |
| **R7** 🟡 | threads | 18 → 15 → **7 real** | ✅ **FIXED 2026-08-14 — and NOT ONE of it was a threads defect.** Three causes, all outside the proposal; the other 8 are by design. See below. *(Original entry: )* `proposals/threads/imports.wast` 13, `memory.wast` 5 (R5 unblocked 3 more). Mostly shared-memory import matching, plus **12 accept-invalids** — the only ones left outside core and the untargeted proposals, so R4's safety argument applies here. ⚠️ **R1 did NOT touch it** despite being "adjacent": those 13 are limits/`shared`-flag matching, not type identity. |
| **R8** ⚠️ | **UTF-8 name validation is UNVERIFIED** | 0 failures | ✅ **CLOSED 2026-08-13 by R5 — it was the runner's gap, and the answer was "all 176 pass".** `utf8-invalid-encoding.wast` was 0/0/**176 skipped** because every assertion in it is an `assert_malformed (module quote …)`, and the runner could not build a quoted module. Implementing that form ran all 176 and they pass: UTF-8 name validation was genuinely correct, and had simply never been checked. **The question the item asked — "is the skip the runner's gap or ours?" — was the right one, and R5 answers it.** |
| **R10** 🔴 | **first-module failures that BLACK OUT whole files** | 13 failures / ~420 skips | ✅ **FIXED 2026-08-13 — 416 assertions unblocked for +1.5 KB, the best ratio of the series.** Six causes; see below. Residue: `ref_null` 27 + `id` 5, both diagnosed. *(Original entry: )* **Opened 2026-08-13 (R5's residue). Highest value left, by a wide margin.** Nine core files fail on their FIRST module and take the whole file into `NoTarget`: `br_table.wast` **161 skipped** (a `TypeMismatch` on `(block (drop (i32.ctz (br_table 0 0 …))))` — br_table in a polymorphic position), `ref_test` **66**, `simd_lane` **51**, `ref_cast` **40**, `ref_null` **32** (`(ref.null exn)` — `abstractHeapCode` has no `exn` entry, a ONE-LINE gap), `br_on_cast`/`br_on_cast_fail` **25 each**, `extern` **16** (`extern.convert_any`/`any.convert_extern` have no mnemonic in the assembler although the decoder and interpreter both implement them — the producer/consumer pair again), `id` (exotic and quoted `$"…"` identifiers). ⚠️ **13 failures, ~420 assertions suppressed** — the R3/R5 shape for the third time: **a single-digit failure count next to a triple-digit skip count is a blackout.** |
| **R9** 🟠 | **accept-invalid in the TEXT front end** | 85 → **71** | ✅ **FIXED 2026-08-14 — 70 of 71 closed, nine causes, and the item was OVER-counted for the first time in the series.** The one left is `anyfunc`, a deliberate recorded deviation (see below). *(Original entry: )* 🆕 **Opened 2026-08-13; this is R5's output.** The class R4 closed for the binary decoder, on the surface the corpus could not reach until `(module quote …)` ran. Groups: **35** type-use ordering (`(if (type $sig) (result i32) (param i32) …)` in `func`/`call_indirect`/`return_call_indirect`), **15** token separation (`(data"a")` needs whitespace between a keyword and a string — `token.wast`), **8** SIMD lane rules, and ~27 spread over `table`/`memory`/`type`/`global`/`id`/`start`/`struct`/`block`/`if`/`loop`/`obsolete-keywords`. Same safety argument as R4: `wasm_module_validate` is a shipped C-ABI entry point. |

**Recommended order: ~~R1~~ → ~~R2~~ → ~~R3~~ → ~~R4~~ → ~~R5~~ → ~~R10~~ → ~~R9~~ → R7.** ~~R6
closed by R3~~, ~~R8 closed by R5~~.

**The R-list is CLOSED.** The singleton batch below took the remainder from 18 to 4.

### ✅ THE SINGLETON BATCH IS DONE (2026-08-14) — 22 failures, six causes, +136 bytes

**Corpus 126 → 106 failures, 62,839 → 62,861 passing, 988 → 978 skipped.** Nine more files clean:
`br_on_cast`, `br_on_cast_fail`, `extern`, `ref_cast`, `ref_test`, `imports4`, `table_grow`,
`global`, `table64`, `call_indirect64`, `return_call_ref`. **The 18 "core singletons" were not 18
causes — they were six**, which is why the previous entry's advice to "triage one by one" was worth
following rather than acting on the count.

| | cause | closed | what it was |
| --- | --- | --- | --- |
| **S1** 🔴 | **a host `externref` and a GC HEAP INDEX were the same value space** | **12** | A host reference was a bare small integer; `any.convert_extern` is identity; `refMatches` then read it as `gc_heap[i]`. `br_on_cast … (ref null struct)` on `any.convert_extern (ref.extern 0)` succeeded and handed back an unrelated object's FIELD. **A reference-forgery primitive reachable from ordinary spec input.** Fixed with `interp.host_tag` (bit 62), disjoint from `i31_tag` (63) and `null_ref`. Also closed 4 in `custom-descriptors`, which the triage had counted as by-design. |
| **L1** 🟠 | **an import matched a memory/table's DECLARED minimum, not its live size** | **4** | §7.2's `mem_type`/`table_type` read the minimum off the instance, so a `(memory 1)` grown to 2 pages satisfies an `(import … (memory 2))`. Refusing it also stopped that module registering, so the next two failed as `UnresolvedImport` behind it — **one cause wearing four failure messages, two of them about a different module.** |
| C3 | **tail-call results required EQUALITY, not subtyping** | 1 | §3.3.8 wants `[t2*] <: [t2'*]`. All three forms used `valTypesEqual`, which is reject-VALID for every widening return — `return_call_ref.wast`'s "More typing" module is built entirely from that idiom. |
| C4 | **the table index type was consumed in only one of the two table forms** | 1 | `(table $t i64 funcref (elem …))` read `i64` as a shape, failed `isRefType`, then asked `parseU64("funcref")`. And once it assembled, the abbreviation's IMPLICIT offset was still `i32.const 0` against a 64-bit table. **The same guard-around-one-form shape as `call_indirect`'s table index and the flat `br_table`, for the third time.** |
| C5 | **element EXPRESSIONS were bounded by the imported-global count** | 1 | §3.5.13 validates elem segments under the full context `C`; only `global*` uses the restricted `C'`. The segment OFFSET already used the full bound — **only the element expressions kept the old restriction**, so `(elem … (global.get $gf))` for a defined `$gf` was rejected. |
| C6 | harness: no `spectest.shared_memory` (R7), no `spectest.table64`, no `ref.host` argument form | 3 | Runner gaps, not runtime defects — the R5/R8 shape again. |

⚠️ **S1 IS ONLY HALF SWEPT, AND THE OTHER HALF IS THE SHIPPED C ABI.** `capi.zig` still does
`.externref => slots[0] = v.of.ref`, a raw pass-through, and `wazmrt.h` invites it (*"opaque to the
host: pass it back unchanged"*). A host handle of `2` still internalizes to GC object #2. **This is
the R1 shape for the third time** — a defect in both the interpreter and the C ABI, with the corpus
able to see only the interpreter half. The fix is to BOX host externrefs (intern in, unbox out, as
`internExtern` already does), which changes what a `wazmrt_val_t` externref *is* and must keep a
guest-produced reference round-tripping — **an owner decision on a shipped ABI**, filed in
`known-issues.md` rather than taken here. Do not read "S1 closed 12 failures" as "the class is
closed".

**LIVE after this batch: 106 failures = 102 by design + 4 actionable** —
`ref_null` 1 (+27 skipped), `legacy/try_catch` 1, `legacy/try_delegate` 1 (`delegate` is
deliberately refused, recorded), `obsolete-keywords` 1 (`anyfunc`, deliberate).

### ✅ THE LATTICE IS DONE (2026-08-14) — and EVERY CORE SPEC FILE IS AT ZERO

**Corpus 106 → 104 failures, 62,861 → 62,889 passing, 978 → 951 skipped.** `ref_null.wast` and
`legacy/try_catch.wast` both clean. **104 = 102 by design + 2 recorded deliberate deviations
(`anyfunc`, `delegate`). There are no undiagnosed failures left.**

The bottom-type change landed as one piece, as planned: `nofunc`/`noextern`/`noexn` became their own
`RefHeap` variants with `top()`/`sub()` arms; `nullfuncref`/`nullexternref`/`nullexnref` (+ their
non-null twins) became their own `ValType`s; `readValType` and `readHeapTypeRef` stopped folding them
onto their family heads; `subtypeOf`'s concrete-target arm became hierarchy-keyed; and the
assembler's shorthand table and `heapTypeToValType` were corrected to match. **27 of the 28
assertions it bought were SKIPS**, behind a first module that would not build — the ordering rule
paying off one more time.

⚠️ **`subtypeOf`'s concrete-target arm had been `sub.refHeap() == .none` — flat, for EVERY concrete
target.** With `nofunc` folded onto `funcref` that was self-consistent and wrong twice: a
`nullfuncref` could not reach a `(ref null $funcType)`, and a `nullref` — an *any*-family value —
would have satisfied a concrete FUNC type if anything had ever asked. **A bottom belongs to exactly
one hierarchy**, and the fix keys both halves (`RefHeap.sub` and this arm) off `top()` so they cannot
drift.

⚠️ **The legacy-EH item cost two corpus passes before it was right, and the mistake is instructive.**
`(try (do) (catch_all) (catch_all))` is malformed (at most one `catch_all`, last) — a one-flag fix.
But I also filtered `catch_all` out of `lookupOp`, on the belief that `(func (catch_all))` "assembled
AND validated". **It does not: it assembles and then fails validation with `MismatchedCatch`.** I had
read the CLI's `valid wasm v1, 4 section(s)` header — which reports STRUCTURE — as the verdict, three
lines above the actual `validation: FAILED`. The filter was therefore unnecessary, and it broke the
legal FLAT spelling where `catch_all` genuinely is a mnemonic in the instruction stream. Two things
to keep: **an audit finding is a hypothesis until the tool's actual verdict line is read**, and **a
clause rule belongs in the validator, which both the text and the binary path reach — a
producer-side filter covers one path and can break a legal spelling on it.**

⚠️ **The corpus caught it and the per-file FAIL diff did NOT.** Passes went 62,888 → 62,887 while
skips went 951 → 953, and no file entered or left the failure list, because a file that turns passes
into skips is invisible there. Only the TOTALS showed it. **Read all three numbers on every run** —
this is the concrete instance the "quote all three or none" rule exists for.

*(Historical note, superseded: the item was scoped here as )* **the last real conformance item: the
BOTTOM-TYPE LATTICE.** `ref_null.wast` is 1
failure hiding **27 skipped assertions** — the largest single pool left, and the ordering rule says
rank by those. `nullfuncref`/`nullexternref`/`nullexnref` are folded onto
`funcref`/`externref`/`exnref`, which loses their bottom-ness, so
`(func (result (ref null $t)) (global.get $nullfunc))` is a `TypeMismatch`. The change is wide and
must be done as one piece: three new `RefHeap` variants with `top()`/`sub()` arms, six new `ValType`
variants (nullable + non-null), `refHeap`/`valType`/`refHead` mappings, `subtypeOf`'s
concrete-target arm (`nofunc <: (ref null $t)` for any func type `$t`), `shorthandRefType` in the
assembler, and `refMatches` in the interpreter — where `headMatches` already returns `false` for
`.nofunc`/`.noextern` on the VALUE path and must keep doing so, because only null inhabits them.
⚠️ **Half-applying a subtyping rule is how accept-invalid holes ship** (R2's C3 stacked three
defects behind one retracted finding); do it in one pass with the corpus as the arbiter.

### ✅ R7 IS DONE (2026-08-14) — and NOT ONE of its 15 was a threads defect

**Corpus 133 → 126 failures, 62,825 → 62,839 passing, 998 → 988 skipped.**
`proposals/threads/imports.wast` **91 passed / 13 failed / 10 skipped → 105 / 6 / 0** — every skip
in the file unblocked. No other file moved in any direction. The 8 that remain are **by design**.

⚠️ **THE ITEM WAS NAMED AFTER ITS DIRECTORY AND TRIAGED AS IF THE DIRECTORY WERE THE CAUSE.** R7 was
"threads", so its entry said *"mostly shared-memory import matching, plus 12 accept-invalids"*. Both
halves were wrong, and the atomics/threads implementation had **no defect at all**:

| | cause | count | what it actually was |
| --- | --- | --- | --- |
| A1 | **the pre-bulk-memory `(data 0 <offset> …)` spelling** | 4 | The memuse used to be a bare `memidx`, not `(memory x)`. Unrecognised, the `0` fell through to the byte loop (which keeps only strings, and silently dropped it) — and the OFFSET went with it, so **an ACTIVE segment in the source assembled as a PASSIVE one**. `(i32.load (i32.const 10))` read 0 instead of the data. Not a rejection: a silently different module. |
| A2 | **the pre-reference-types `(elem 0 <offset> …)` spelling** | 2 | Same shape for tables, but loud: `resolveByName` was handed the offset LIST as a function name → `BadImmediate`, killing two whole modules. |
| A3 | **the runner had no `spectest.shared_memory` export** | 1 (+10 skips) | A HARNESS gap. **Shared-memory import matching was already correct** — `limitsFit` has compared the `shared` flag since memory64 — so the item's stated cause was code that had been right for weeks. There was simply nothing to import. |

⚠️ **8 of the 15 are BY DESIGN and had been counted as actionable for two days.** The
`proposals/threads` directory is a snapshot pinned to a spec *before multi-memory and multi-table*,
so it asserts `(module (memory 0) (memory 0))` and
`(module (table 10 funcref) (table 10 funcref))` are invalid — five "multiple memories" and three
"multiple tables". wazmrt implements **both** proposals (multi-memory since Phase 7, multi-table
since reference types), so accepting those modules is correct and refusing them would be a
regression. Decisive check: **the assertions appear nowhere in the main testsuite** — `exports.wast`
only carries them as commented-out `;; No multiple memories yet.` notes.

⚠️ **A1 and A2 are the same legacy grammar, and only one of them failed loudly.** That is the whole
reason A1 sat unnoticed while A2 was visible: a dropped token in a *list of strings* changes the
segment's MODE and nothing complains, while the same dropped token in a *list of indices* reaches a
resolver that errors. The data-segment byte loop's `else => {}` is now `else => return
error.BadModuleField` — **the silent arm is what made the missing memuse invisible, not the missing
memuse itself.**

**Recognising the legacy forms is a deliberate, bounded leniency** — the `anyfunc` trade again, and
gated so it cannot loosen anything else: a bare index counts as a memuse/tableuse **only when an
offset form immediately follows it**. An offset is always a list and data bytes are always strings,
so no modern spelling can collide, and a passive `(elem 0 $f)` — where the next item is a func id,
not an offset — is untouched. Recorded in `known-issues.md` beside `anyfunc`.

**Second consecutive OVER-count** (R9 85→71, R7 18→15→7 real). See the warning at the top of this
list: stale is stale in both directions.

### ✅ R9 IS DONE (2026-08-14) — 70 of 71 closed, nine causes, +3,584 bytes

**Corpus 207 → 133 failures, 62,737 → 62,825 passing, 1,013 → 998 skipped.** No file gained a
failure; fourteen went entirely clean — `block`, `call_indirect`, `func`, `id`, `if`, `loop`,
`memory`, `return_call_indirect`, `simd_lane`, `start`, `struct`, `table`, `token`, `type` — and
`global` 4 → 1, `proposals/threads/memory` 5 → 2. **Accept-invalid in core spec files is back to
ZERO** except the one deliberate deviation below — *and since 2026-08-17 that exception is gone too:
`anyfunc` is refused, so the zero is now unconditional.*

*(The totals move by −1 overall, and that is arithmetic, not a lost assertion: a `(module …)` command
that FAILS to build scores a failure, while one that succeeds scores nothing. `id.wast`'s first
module now builds, so it stopped being counted at all.)*

| | cause | count | what it was |
| --- | --- | --- | --- |
| C1 | **A type use was parsed in ANY order and any repetition** | **22** | §6.6.5 is `('(' 'type' x ')')? param* result*`, and §6.6.13 puts `local*` after all three. Five sites each had their own loop with no ordering at all, so `(func (result i32) (param i32) …)` assembled into an ordinary `[i32] -> [i32]` function. Now one `typeUseRank` + `typeUseOrder` pair, shared. |
| C2 | **An inline signature beside `(type x)` was IGNORED, not checked** | **3** | §6.6.5 makes the inline form a *check* on `C.types[x]`. `(func (type $sig) (result i32) …)` with `$sig = [i32] -> [i32]` bound to `$sig` while its own text declared `[] -> [i32]` — a function with a parameter its source denied. |
| C3 | **`(param $x …)` accepted where no local context exists** | **6** | An id binds a local, so it is legal only in a `func`, a `(type (func …))` and a tag. A block type and a `call_indirect` type use have none. Plus `(result $x i32)`, which is never legal anywhere. |
| C4 | **No index space checked its identifiers for uniqueness** | **16** | §6.6.13. func/global/memory/table/local/struct-field, each silently keeping the last binding. |
| C5 | **A string abutting another token lexed as two tokens** | **14** | §6.2.1 `reserved ::= (idchar \| string)+` — `(data"a")` is ONE reserved token, and no production accepts `reserved`. |
| C6 | **A SIMD lane index went through the signed literal grammar** | **7** | `laneidx ::= u8`, a nat. `(i32x4.replace_lane +3 …)` assembled as lane 3. |
| C7 | **`(start …)` could be written twice** | **1** | The second overwrote the first, so the module ran a start function its own source did not name first. |
| C8 | **A bare `$` was an identifier** | **1** | `id ::= '$' idchar+ \| '$' string` — both alternatives require content. |
| C9 | **`$"…"` quoted identifiers did not lex** | (R10 residue) | Forced into scope by C5 — see below. Closed `id.wast` entirely (0/2/5 → clean). |

⚠️ **C2's rule already existed — for tags only, and had done since 2026-07-27.** `resolveTagSig`
carried the exact comparison, with a comment citing the typeuse rule, while `func`,
`call_indirect`, `return_call_indirect` and block types all ignored their inline forms. **This is
R10's C1 again at one remove** (`extern.convert_any` implemented for const-exprs but not for
function bodies): *a rule implemented for one of the places it applies reads, from the code, as
implemented.* The fix was to lift the tag's private check into a shared `checkInlineTypeUse` and
call it from all five sites — the same move as R3's `isRefType`/`shorthandRefType` merge.

⚠️ **C4 is checked ONCE PER SPACE after parsing, not at each append site, and that is the whole
point.** Every wasm index space is filled from two places — an import and a definition — and
§6.6.13's rule spans both, so `(import "" "" (memory $foo 1))` next to `(memory $foo 1)` is the
duplicate that a per-site check structurally cannot see. Six of the sixteen assertions are exactly
that pair. **When a rule is about a namespace, check the namespace, not the writers.**

⚠️ **C5 BROKE THE HARNESS, because the harness and the modules share one lexer.** Making a string
abutting an idchar a `reserved` token turned `id.wast` from a scored file into a whole-file *runner
error*: the `.wast` script itself contains `$"007"`, which under the new rule is `$` + string with no
separator. So the fix for R9's token-separation group forced implementing `$"…"` quoted identifiers
— R10's residue, filed as a separate item — in the same pass, and with it §6.2.1's `stringchar` rule
(a RAW control byte in a string literal is malformed; `\t` is how that byte is spelled). Quoted ids
normalise to `$` ++ the decoded bytes, so `(br $"007")` finds `block $007` with no change to any
name lookup. **A stricter rule in a shared front end is also a stricter rule for everything that
reads the tests.**

⚠️ **A grammar rule drawn against the FOLDED syntax broke two modules in the FLAT one.** Rejecting a
`(param …)`/`(result …)`/`(local …)` after a function's body starts is right — but in flat syntax
`block`, `loop`, `if`, `select` and `call_indirect` are bare *atoms* and their type use is a
SIBLING, not a child. Worse, it chains: `select (result i32) (result)` and
`call_indirect (type $proc) (param) (result)` are both in the corpus. The first cut ("must follow an
atom") cost `select.wast` and `stack.wast` a module each; the rule is now "carry the permission
forward". **A text-format rule has two spellings to satisfy, and the flat one is where the
sibling-vs-child distinction is visible at all.**

⚠️ **`anyfunc` is the ONE R9 assertion deliberately left failing** (`obsolete-keywords.wast` L40).
It is the pre-standard spelling of `funcref`, accepted on purpose since 2026-07-21 and recorded in
`known-issues.md`; two real `.wat` files in the wasmtk corpus
(`ArtOfWebAssembly_tests/Chapter3/table_export.wat`, `table_test.wat`) use it, so removing it would
break input the project actually runs. Reversing a recorded compatibility decision is the owner's
call, not a conformance-pass side effect. **Left failing and labelled, not quietly "fixed".**

⚠️ **`annotations.wast` still errors out as a whole file** — it did before R9 too
(`UnexpectedChar` → now `ReservedToken`), so it is not a regression, but the error moved. The file
is the custom-annotations proposal (`(@a …)` with deliberately exotic tokens) and is untargeted.

**Verification, and one trap worth keeping.** All eight new checks were confirmed by inverting the
implementation and watching the specific test fail. ⚠️ **Two of the eight inversions produced no
failing test because they did not COMPILE** — commenting out a check left a parameter unused, which
Zig rejects, and a build that never ran looks identical to an inversion that no test caught. **An
inversion has to be checked for compiling before its silence means anything.** (A third near-miss:
the "which tests failed" grep missed a test whose *name* contains an apostrophe.)

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

### ✅ TRACK 3 — FIRST MEASUREMENT (2026-08-14): 5.3× on end-to-end invocation, and the fairness rule did not change it

`zig build bakeoff -Dcorpus=<dir> [-Dreps=N]` (`tools/bakeoff.mjs`, driven by deno like `ffi-demo`).
12 invocations from wasmtk's `wasm_mod` corpus × 9 reps, ReleaseFast, x86_64-windows:

| runtime | configuration | median ms | min ms | vs wazmrt |
| --- | --- | --- | --- | --- |
| **wazmrt** | interpreter | **6.77** | **5.61** | — |
| wasmtime | `-C compiler=winch` (fast start) | 36.63 | 33.22 | 5.41× |
| wasmtime | `-O opt-level=0` (fast start) | 36.27 | 32.47 | 5.36× |
| wasmtime | default `opt-level=2` (slowest start) | 35.92 | 33.72 | 5.31× |
| wasmer | default (cranelift) | 36.69 | 33.61 | 5.42× |

🎯 **THE BINDING FAIRNESS RULE WAS APPLIED IN FULL AND THE CONCLUSION SURVIVED IT.** wasmtime's three
configurations land within **2% of each other** (35.92 / 36.27 / 36.63), so on modules this size the
startup cost is *runtime and process initialisation, not Cranelift compile time*. That is what makes
the number quotable: it is not the "beat a runtime in its slowest configuration" claim the rule
exists to forbid. **Fast-start wasmtime is still 5.4× slower here.**

⚠️ **State exactly what this measures, every time.** End-to-end PROCESS wall-clock —
`spawn → read → decode → validate → instantiate → call → print → exit` — which is what one
invocation costs in the dev-loop regime Decision 2 targets. It is **not** in-process decode timing
and **not** steady-state throughput; a JIT wins hot loops and this table cannot see that (the
2026-07-14 bench already recorded exactly that shape). The defensible claim stays *"wasmtime-class
module compatibility, at a fraction of the footprint, faster on anything not precompiled."*

⚠️ **THAT CAVEAT WAS A PREDICTION AND IT IS NOW MEASURED FALSE — see the `start`-mode entry below.**
The text here used to say the 55–6,225-byte corpus understated the advantage, and that "on a large
module the fast-start configurations should separate from the default and the absolute gap should
widen". Run against a **1.97 MB** module: nothing moves. Kept as written, struck through by the
measurement, because a prediction that was recorded and then refuted is more useful than one quietly
deleted.

⚠️ **A benchmark that mis-invokes a competitor reports that competitor as BROKEN.** The first run
disqualified wasmer on `add(100, -1)`: the harness omitted the `--` separator, so `-1` parsed as a
flag. It looked exactly like a wrong answer. **Check a disqualification against a hand-run before
believing it** — the same discipline as an audit finding being a hypothesis. Verifying every result
is still right: a benchmark that does not check its output is measuring the wrong thing.

**wazero is absent from the INVOKE table on purpose**: its CLI runs `_start` only and cannot invoke a
named export. That is why `start` mode exists — see below, where it competes.

### ✅ TRACK 3, SECOND CUT (2026-08-14) — `start` mode, a 210× size ladder, and a prediction refuted

`zig build bakeoff -Dmode=start -Dcorpus=<dir>` runs WASI `_start` programs. It brings **wazero** in
(its CLI can do nothing else) and **wasmrt**, the sibling competing for the same slot, and it is
where LARGE modules live. No oracle is privileged: every runtime must produce the same stdout and a
disagreement is *reported, not adjudicated*.

| runtime | median ms | vs wazmrt |
| --- | --- | --- |
| **wazmrt** (Zig, interpreter) | **34.11** | — |
| **wasmrt** (Rust, interpreter) | 35.79 | **1.05×** |
| wazero (Go, compiler) | 68.56 | 2.01× |
| wasmtime `-C compiler=winch` | 82.59 | 2.42× |
| wasmtime default `opt-level=2` | 82.46 | 2.42× |
| wasmtime `-O opt-level=0` | 84.34 | 2.47× |
| wasmer | 86.43 | 2.53× |

⚠️ **THE SIZE LADDER REFUTES THE PREDICTION THIS ROADMAP MADE.** The first cut said the small corpus
understated the advantage and that a large module would separate the fast-start configs from the
default. Measured across **9 KB → 1.97 MB, a 210× range**:

| module | bytes | wazmrt | wt:winch | wt:O0 | wt:default | wazero |
| --- | --- | --- | --- | --- | --- | --- |
| string-formatting | 9,391 | 34.1 | 80.9 | 80.3 | 85.9 | 58.6 |
| Phase38Combined | 11,147 | 37.0 | 85.1 | 82.2 | 82.5 | 58.1 |
| fib-rs-opt | 44,838 | 33.4 | 78.7 | 84.3 | 80.7 | 68.6 |
| **fib-rs-test** | **1,968,591** | **32.4** | **82.6** | **84.7** | **79.5** | **73.6** |

**Nothing moves.** Cranelift compiles 2 MB inside the noise; the cost is fixed startup for everyone.
So the honest claim is *narrower and more robust* than predicted: the advantage is **flat in module
size up to 2 MB**, not growing with it. **A recorded prediction that the measurement refutes is worth
more than one quietly deleted** — the earlier text is struck in place above.

⚠️ **AND THE RATIO IS LOAD-DEPENDENT; THE DIFFERENCE IS NOT.** The first cut measured 5.3× on a quiet
machine; these runs, on a loaded one, give 2.4×. Both are honest — but when a fixed per-process cost
is shared by every entrant, inflating it compresses the *ratio* while leaving the *absolute gap*
roughly intact (~29 ms then, ~48 ms here). **Quote the difference, or quote the ratio with the load
conditions attached.**

⚠️ **wasmrt TIES wazmrt** — 1.05× here, 1.02× in invoke mode. The two candidates for the runtime slot
are equivalent on startup, so **startup is not the differentiator between them**; footprint is
(wazmrt's DLL is 2.5× smaller, and 269 KB with Track 2c's flags). Worth knowing before any further
startup work is justified on competitive grounds.

⚠️ **A DIFFERENTIAL FINDING, and it is wasmtime that is alone.** On
`27_string-formatting.wasm` the runtimes disagree by exactly one byte: the guest's source is
`console.log(true); console.log(123);` and the correct output has a newline between them.

| implementation | bytes | |
| --- | --- | --- |
| wazmrt (Zig) · wasmrt (Rust) · wazero (Go) · wasmer (Rust) · **V8** (node `node:wasi`) | 223 | `true\n123` |
| **wasmtime 47.0.3** | **222** | `true123` |

**Five independent implementations across four languages agree, including V8** — the reference
engine, and the one **wasmtk actually runs on**. ⚠️ **The cause is NOT traced**, so this is a
reproducible observation, not a diagnosis: something about that guest's `fd_write` sequence is
handled differently by wasmtime. Worth checking into wasmtk (whose
`dync_cross_runtime_tests.ts` runs output through wasmtime/wasmer/wazero — if it compares stdout
exactly, it should already see this) and into wasmrt. **The differential check found this on its
first run, which is the argument for having no privileged oracle.**

### ⚠️ THE SPAWN FLOOR (2026-08-14) — the CLI benchmark is ~90% process spawn, and that reframes the claim

Measured on the same loaded box, 25 reps, median:

| | wazmrt | wasmtime |
| --- | --- | --- |
| `--version` — **no wasm work at all** | **30.32 ms** | **76.47 ms** |
| the 1.97 MB module, end to end | 33.26 ms | 85.83 ms |
| **⇒ all wasm work (decode+validate+instantiate+run)** | **~2.9 ms** | **~9.4 ms** |

🎯 **The end-to-end advantage is mostly "a smaller binary loads faster", not "a faster engine".**
Spawning wazmrt costs 30 ms before a byte of wasm is touched; the entire wasm pipeline on a 2 MB
module is under 3 ms. Both facts are real, and the *first* is what a dev loop actually experiences —
but they are **different claims**, and the CLI benchmark cannot separate them. It is also why the
size ladder is flat: the variable part is ~3 ms inside a ~33 ms measurement.

This does not weaken the position — it relocates it. The project's thesis has always been that
**footprint is the differentiator**, and this is that thesis showing up in the startup number rather
than a separate advantage. It does mean the honest phrasing is *"a wazmrt invocation costs ~2.5× less
end to end, most of it because the binary is a fraction of the size"* — not *"the engine decodes
2.5× faster"*, which is a claim this measurement never made and which someone would check.

⚠️ **Measure the floor before attributing a difference.** Two runtimes differed by ~50 ms and it
would have been natural to bank that as engine speed; ~46 ms of it is there before either engine
starts.

**This is exactly what the remaining BAKE OFF is for (a COMPARE task, not a fix task).**

### ✅ TRACK 3 IS COMPLETE (2026-08-14) — the engine pipeline, spawn excluded: **20–55×**

`zig build phases -Dmodules=<a,b,c>` (`tools/phases.mjs`). wazmrt measured **in-process** via the
bench binary; wasmtime's `compile` measured with **its own spawn floor subtracted**, floor and work
sampled alternately so drift hits both equally. Bytes → ready to execute, ms:

| module | bytes | **wazmrt** | wt:winch | wt:O0 | wt:default | ratio |
| --- | --- | --- | --- | --- | --- | --- |
| string-formatting | 9,391 | **0.16** | 9.10 | 10.68 | 10.87 | **55×** |
| fib-rs-opt | 44,838 | **0.49** | 11.83 | 18.75 | 19.63 | **24×** |
| fib-rs-test | 1,968,591 | **0.72** | 14.54 | 21.68 | 22.06 | **20×** |

wazmrt's own split (µs, in-process):

| module | decode | validate | +instantiate |
| --- | --- | --- | --- |
| string-formatting | 6.52 | 158.11 | 217.63 |
| fib-rs-opt | 5.74 | 487.09 | 760.37 |
| fib-rs-test | **37.83** | **681.86** | 1110.74 |

🎯 **THE END-TO-END BENCHMARK UNDERSTATED THE ENGINE DIFFERENCE BY ROUGHLY 10×.** The CLI said 2.4×;
the engines differ by 20–55×. A ~30 ms spawn floor did not merely add noise — **it hid the entire
effect**, because it dwarfed a quantity that is under 1 ms on our side. *A benchmark whose floor is
larger than its signal measures the floor.*

⚠️ **And it reverses the "nothing moves with size" finding, correctly.** The end-to-end ladder was
flat and the fast-start configs looked identical to the default; at engine level they are not —
winch is **34% faster than default** on the 1.97 MB module (14.54 vs 22.06), and every runtime scales
with size. The flatness was the floor, not the engines. **The same measurement can be right about
what it measures and wrong about what you conclude.**

⚠️ **Decode is nearly free; VALIDATION is our bytes→ready cost.** 37.8 µs to decode 1.97 MB against
681.9 µs to validate it — validation is ~95% of the pipeline. That is where any future startup work
belongs, and it is not where anyone would have guessed from the name "decode → validate →
instantiate".

**What the ratio does and does not license.** The two sides produce different things: wasmtime emits
native code, wazmrt a validated IR to interpret. The number says how fast each reaches something
runnable, and it is only meaningful beside the trade — **wasmtime pays this once and wins in a hot
loop**. wasmtime's figure also includes writing the `.cwasm`, so it over-states its compute a little.
The tool prints both caveats under every table it produces, for the same reason the bake-off prints
its scope.

*(Superseded — the scope this was planned from:)*

### 📋 the original plan — the BAKE OFF`s last compare item: the in-process breakdown

**The question it answers, which nothing else can:** of wazmrt's ~2.9 ms of wasm work on a 2 MB
module, how much is decode, how much validate, how much instantiate — and how does each compare to
wasmtime doing the same? The CLI harness cannot tell you, because ~90% of what it times is spawn.

**Shape.** Two harnesses reporting the same three phases in one process, N reps, medians:

| side | how | why |
| --- | --- | --- |
| wazmrt | extend `zig build bench` — `Module.decode` / `validate` / `instantiate` are already separate calls | no new dependency; the phases exist as functions already |
| wasmtime | a small Rust bin using the `wasmtime` crate: `Module::from_binary` (decode+compile) then `Instance::new` | cargo is already a project dependency via wasmrt; the C SDK would have to be fetched per triplet |
| wasmrt | its own crate, same three phases | it TIES wazmrt end to end, so the interesting comparison is where the ~3 ms goes |

⚠️ **The phases do not line up, and pretending they do is the trap.** wasmtime's `Module::new`
*compiles*; wazmrt's `decode` builds an IR and `validate` type-checks. There is no honest
phase-by-phase row — the comparable quantity is **total time from bytes to a callable instance**,
with each runtime's internal split reported *beside* it rather than aligned against it. Say that in
the output, the way the current harness states its scope.

⚠️ **Report the floor with the result**, per the entry above. An in-process number without the
process-spawn context invites exactly the misattribution this section documents.

**Estimated size:** small on the wazmrt side (the calls are already separate); the Rust harness is a
~50-line `main.rs` plus a `Cargo.toml`. The judgement call worth making deliberately is whether a
cargo build belongs in this repo's `zig build` graph at all, or whether the Rust side lives in
`bench/` as an opt-in step like `-Drust-gate`.

### ✅ TRACK 2c IS DONE (2026-08-14) — the embed artifact is optional-weight now

**`-Dwat=false` / `-Dwasi=false` compile the WAT assembler / the WASI host out of the EMBED
artifacts.** Measured ReleaseSmall:

| configuration | static lib | DLL | vs full |
| --- | --- | --- | --- |
| default (wat + wasi) | 1,022,520 | **882,688** | — |
| `-Dwat=false` | 840,962 | 738,816 | −16.3% |
| `-Dwasi=false` | 502,178 | 419,840 | −52.4% |
| both off | 319,916 | **275,456** | **−68.8%** |

🎯 **862 KB → 269 KB for an embedder that needs neither** — within ~47 KB of the 227 KB the DLL
measured *before* the wasm-c-api replacement. **That closes the question Track 1 opened.** The
"IT GOT BIGGER, NOT SMALLER" entry above was right that the growth was WAT + WASI + `Io`; it is now
optional rather than structural, and the strongest card in the consumer survey — *"replacing
megabytes of per-triplet vendored SDK with a 222 KB self-owned library"* — is back within reach.

⚠️ **WASI is the bigger half by 3×, and the roadmap named `-Dwat=false` FIRST.** `wasi.zig` drags in
`std.Io`, file handling and `Io.Threaded`; the assembler is mostly its own code. **Rank size levers
by measurement, not by which one is easier to picture** — the same rule as ranking conformance items
by assertions unblocked.

**With both features on the artifacts are BYTE-IDENTICAL**, so the gate costs nothing when unused.
The freestanding wasm build is unchanged (37,382) in all four configurations: `wasm_entry.zig` never
referenced either module, so both were already dead-stripped there.

**How it is built, and the two things that matter:**

1. **Two config modules, not one.** `-Dwat`/`-Dwasi` feed `embed_cfg`, used by the C-ABI static lib,
   the DLL and the freestanding wasm; the CLI, tests and conformance runner take `full_cfg`, which
   is hard-wired to both-on. ⚠️ A single global option would have silently descoped the CLI, and
   **`.wat` is not being descoped** (owner, 2026-08-11) — running text is a stated CLI capability.
2. **A disabled feature is REJECTED LOUDLY.** `wazmrt_module_new_wat`, `wazmrt_wat_to_wasm` and
   `wazmrt_linker_define_wasi` return a real error naming the build flag
   (*"this build has the WAT text assembler compiled out (-Dwat=false); rebuild with -Dwat=true"*),
   never a NULL module or a no-op linker. The embedder cannot see our build options, so
   "unsupported" alone would send them looking in the wrong place.

**New gate: `zig build features`** compiles the C ABI in all four combinations. A comptime gate rots
the moment someone adds an ungated `root.wasi.…` reference, and the default build cannot notice
because the flag is only false in a configuration nothing else compiles. ⚠️ **It earned its keep
immediately**: `-Dwasi=false` did not compile until six use sites in `capi.zig` were guarded — and
the guards had to be `if (comptime root.enable_wasi)`, because a run-time-only check leaves
`initWasi` REFERENCED and the whole host linked in, gating nothing.

⚠️ **The size gate had a hole this exposed, now closed.** `zig-out` carries no record of the FLAGS
that produced what is in it, so `zig build size` after a gated `dll` build graded the small artifact
against the full build's ceiling and printed **607,232 bytes UNDER** — a false win, and one that
reads as an invitation to lower the ceiling and mis-record the real size permanently. `size_gate.zig`
now takes the feature string and refuses anything but `wat,wasi`, the same shape as its existing
ReleaseSmall check. **A gate that measures "whatever is on disk" needs to know what produced it.**

### What is left after Track 1 (2026-08-11)
- 📊 **THE BAKE OFF (formerly "Track 3") — RECLASSIFIED 2026-08-18: this is a COMPARE task, not a
  FIX task, and it does not belong in the "what is left to fix" queue.** Owner's call, and the
  distinction is one this file did not previously have a word for:

  > **A FIX TASK changes wazmrt. A COMPARE TASK measures it against something else.** A compare
  > task can never be "done" — rivals ship new versions, corpora grow — so tracking it beside real
  > work makes the fix queue look permanently non-empty. It is scheduled when a NUMBER is wanted,
  > not when a gap is found.

  ⚠️ **And it is the one item that structurally CANNOT be self-contained.** wazmrt ships with zero
  external dependencies — binaries import only `ntdll`/`KERNEL32`, `third_party/` holds no code,
  `build.zig.zon` has an empty `.dependencies`, and every correctness gate (`test`, `test-safe`,
  `test-security`, `features`, `size`, `capi-smoke`) needs nothing but Zig. **A bake-off needs
  rivals by definition**: deno to drive it, plus wasmtime / wasmer / wazero / wasmrt binaries.
  Its residuals would deepen that rather than reduce it — "rsxtk's corpus" is a different tree
  entirely, and the in-process breakdown needs a harness written inside the *Rust* projects.

  **State, re-measured 2026-08-18 rather than copied:** the harness exists and works
  (`tools/bakeoff.mjs`, `tools/phases.mjs`). ⚠️ **The old residual line said "still open: wasmrt as
  a fourth entrant" and that is STALE — the entrant is already wired** (`bakeoff.mjs`, and the
  sibling binary was built 2026-08-14). What is genuinely absent is only that **no recorded
  measurement includes a `wasmrt` row**; the published table is wazmrt / wasmtime ×3 / wasmer.
  Anyone wanting that row runs one command and needs nothing new.

  🎓 **Sixth stale scope line found in one day, and the same species as the other five** — a
  statement about scope that no gate prints and nothing fails a build over. See the rules in
  `best-practices.md` §5.
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

## ✅ CLOSED — "the last 89" (scoped 2026-08-17, owner asked for "no holes left open")

> 🏁 **ALL 89 ARE CLOSED, same day.** Tracks **P** (custom-page-sizes) and **D** (custom-descriptors,
> D1–D5) both shipped, F3+F4 cleared the era-pinned 8, and the final pass closed the last two
> defects. **The corpus is at 0 failures / 63,934 passing / ZERO skipped across all 284 files.**
>
> ✅ **AND TRACK F CLOSED IT COMPLETELY ON 2026-08-18 — there is no open work left in this
> section.** F1r, F5-CLI and F5 shipped, and the track found TWO GATES THAT DID NOT EXIST on the
> way: `custom_descriptors` was knowingly partial (instructions gated, its three type-level
> formers not), and **`custom_page_sizes` had no `Feature` member at all** — Track P landed the
> proposal and nothing could refuse it. Read the Track F entry below. *(The corpus then went to **63,870 passed / 0 failed / ZERO SKIPPED** the same day — the skip-closing pass, wide-arithmetic and Track L followed. **There is no open track and no outstanding corpus gap.**)*
>
> ⚠️ **The recommended order was F → P → D and the work went P → D → (F).** That was the owner's
> call and it cost nothing, because the premise for "F first" turned out to be false: F's security
> argument had already been closed on 2026-08-11 (see the correction below). **The ordering
> rationale was written from the argument, not from the code — the same root cause as the two
> mis-stated statuses this file already records.**
>
> *(The framing below is preserved as written, because its ranking argument is the instructive part.)*

**Read this framing before costing the work, because the security argument is NOT uniform across
the 89 and treating it as uniform would rank the tracks wrong.**

- ⚠️ **The 81 untargeted-proposal assertions are NOT a security hole today.** wazmrt REFUSES those
  modules. Refusal is the safe direction — a module that will not run cannot do harm. **Implementing
  them ADDS attack surface rather than closing a gap.** That is a legitimate thing to want (it is
  completeness, and it is the stated goal), but the honest security framing is *"we choose to
  support more language, and the risk now lives in our implementation of it"* — which is why every
  increment below carries an explicit soundness checkpoint instead of an assertion count alone.
- ⚠️ **The 8 threads assertions are not accept-invalid in the dangerous sense either** — wazmrt is
  correct and the file is old. **But a real security gap hides behind them:** there is no way to run
  wazmrt with a RESTRICTED feature set. `validate()` takes no features, so an embedder who wants
  "MVP + bulk-memory only" — a smaller accepted language, a smaller TCB, less of our own code
  reachable by untrusted input — cannot have it. **That is the genuine "hole", and Track F closes
  it.** The 8 assertions are a side effect of the fix, not its purpose.
- 🎯 **Therefore: F before D.** Track F is the one that makes Track D's new attack surface OPTIONAL.
  Landing descriptors first would mean every embedder carries them with no way to decline.

**Recommended order: F → P → D.** F is the security item; P is small and proves the limits plumbing;
D is the largest feature since GC.

### ✅ Track F — feature ENFORCEMENT. **COMPLETE 2026-08-18 (F1r, F5-CLI, F5 + two missing gates).**

🚨 **CORRECTED 2026-08-17 — F1, F2a AND F2b ARE ALREADY SHIPPED. The blocker statement below was
FALSE when written, and this file contradicted itself two sections up:** the change-series table
marks step **2e-b — "per-instance ceilings + real per-proposal gating (`src/features.zig`)" ✅**,
landed 2026-08-11. It was scoped again on 2026-08-17 as if it did not exist. Verified in the code,
not assumed:

| scoped as missing | actual state |
| --- | --- |
| "an embedder cannot restrict the feature set" | `wazmrt_config_set_feature` / `get_feature` / `all_features` — **in the shipped ABI-2 header** |
| "nothing enforces anything" | hard rejection in **both** module entry points (`wazmrt_module_new`, `wazmrt_module_validate`), naming the feature |
| F2a — module-level enforcement | `firstViolation` gates types, memories, tables, globals, tags, imports |
| F2b — per-INSTRUCTION enforcement | `firstViolation` decodes every body and gates per instruction, **including the relaxed-SIMD sub-opcode split** |
| coverage may rot | compiler-enforced `Op`-count pin (**254** as of D4) — a new opcode fails the build |
| — | 4 passing gating tests, incl. **NO false positives on a plain MVP module with everything off** |

⚠️ **So the security framing at the top of this section is wrong too: the embedder hole is CLOSED.**
"An embedder who wants MVP + bulk-memory only cannot have it" — they can, and could since
2026-08-11. Track F is therefore **not** the security work; it is conformance work plus a CLI gap.

🎓 **The lesson, and it is the inverse of the memory64/GC-P3 pair: those recorded work as DONE that
was not, this recorded work as TODO that already was.** Same root cause — a status line written
from an argument rather than from the code. **Before scoping a track, grep for the thing you are
about to build.** *(Original blocker text, preserved as the record:)* ~~`validate(gpa, *const
Module)` takes no feature set; `features.zig`'s `require(fs, …)` walk only computes the first
feature a module needs, for `zig build features` to report. Nothing enforces anything, so features
today are DESCRIPTIVE.~~ *(The walk is not merely computed — it is wired as a rejection.)*

**What genuinely remained in Track F — ✅ ALL OF IT SHIPPED 2026-08-18.**

> 🏁 **TRACK F IS COMPLETE.** Gates: corpus **63,934 passed / 0 failed / ZERO skipped** (F itself was skip-neutral at 63,732/0/144;
> 0 regressions), unit **750** (719 + 31, from an NTFS cwd — Track F 15, the skip-closing pass 10, wide-arithmetic 6), `test-safe` **750/750 — and the CLI is
> now IN that gate**, `test-security` 3/3, `zig build features` green across
> all four `-Dwat`/`-Dwasi` combinations, size gate EXACT at exe 984,576 / lib 1,047,720 / dll
> 900,608 (+5,632 / +1,198 / **0** — the whole exe delta is the CLI flag, which no embedder
> carries).
>
> 🎓 **THE LESSON OF THE WHOLE TRACK, AND IT IS NOT ABOUT FEATURES: TWO OF THE FOUR ITEMS WERE
> HOLES NOBODY HAD SCOPED, AND BOTH WERE FOUND THE SAME WAY — BY GREPPING FOR THE GATE INSTEAD OF
> READING THE ROADMAP.** The written scope was F1r + F5-CLI + F5. What the code said was that
> `custom_descriptors` gated instructions and not its own type syntax (this file DID record that,
> in F's favour), and that **`custom_page_sizes` had no `Feature` member at all**. The second one
> was in nobody's notes: Track P shipped custom-page-sizes end to end — decoder, validator, every
> bounds check, its own security checkpoint — and added no way to refuse it. ⚠️ **A proposal that
> ships without a bit in `features.Feature` is not "enabled by default"; it is UNREFUSABLE**, and
> `wazmrt_config_all_features(cfg, false)` — every switch the enum offers, off — still accepted a
> byte-paged memory. *This is the same rule this file already states as "before scoping a track,
> grep for the thing you are about to build", applied in the other direction: **also grep for the
> gate you are about to claim exists.***

- ✅ **F1r — DONE. The gate moved INSIDE `validateWith`.** `validateWith(gpa, module, era)` now
  runs `features.firstViolation` at its top and returns `error.DisabledProposal`, with the feature
  itself in `lastFailureSite().disabled_proposal` (a Zig error set carries no payload — the same
  reason `FailureSite` exists). `validate` still delegates with `.{}`, whose `Set.all()`
  short-circuits the walk, so the default path costs nothing and no existing caller can start
  seeing the new error. `capi.zig` and `wast.Runner.validateEra` each collapsed from two calls to
  one.
  🔒 **It closed a SHIPPED DEFECT that the two-step could not see, and this is the part worth
  re-reading.** `capi.zig` gated with the engine's feature set and then validated with
  `root.validate` — *i.e. with every feature on*. So the embedder's set chose which proposals were
  ADMISSIBLE while the all-features rules chose what they MEANT: with `custom_descriptors` off,
  `br_on_cast` was still typed by the relaxed custom-descriptors rule. No gating test could catch
  it, because the instruction exists either way and was never refused. **An enforcement arm that
  runs BESIDE the thing it constrains, rather than inside it, enforces only what its caller
  remembered to ask for** — and the caller here remembered the half that has a test.
- ✅ **The `custom_descriptors` type pass — DONE.** `firstViolation` gained a type-section walk:
  `(exact $t)` in composite types, **struct fields and array elements** (the `.@"struct"`/`.array`
  arms required `.gc` for the KIND and never looked at the contents), table element types, global
  types, an **exact func import** (descriptor kind `0x20` — a link-time rule with neither an
  instruction nor a value type of its own), the `(descriptor $d)`/`(describes $s)` links, and the
  exactness carried in **instruction immediates** (`ref.null` / `ref.test` / `ref.cast` /
  `br_on_cast` / typed `select` / block types).
  ⚠️ **That last one is the one a scoping note would have missed.** The six D3/D4 opcodes were
  already gated; what the proposal ALSO adds is an `exact` prefix on heap types that pre-existing
  GC instructions carry. **Refusing the opcodes a proposal adds is not the same as refusing the
  proposal.** `requireValType` asks for the FAMILY first and the `exact` former second, so an
  embedder who turned off GC is told `gc` and not `custom_descriptors`.
- ✅ **`custom_page_sizes = 17` — NEW, and it is the hole above.** Gates any memory in the index
  space, **imports included**, whose `page_size_log2 != 16`. Layered on nothing (it extends core
  memories). The two comptime pins did their job: adding the member broke the build until
  `capi.Feature` and `wazmrt.h` matched it name-for-name.
- ✅ **F5-CLI — DONE. `wazmrt --features <list> <module>`.**
  - **It sits BEFORE the module path, the only wazmrt flag that does, and the reason is written at
    the parse site.** Every other flag trails the path inside `flagRegion`'s leading run — and that
    position cannot work here, because in run mode the export name must be `args[2]`
    (`wazmrt add.wasm add 2 3`) and everything after it belongs to the guest. Moving the export
    selector to after a flag region would silently change which mode
    `wazmrt prog.wasm --dir .:/ add 2 3` picks for a module exporting both `add` and `_start`. A
    leading flag occupies a position that was previously just an error.
  - 🔒 **Deliberately NOT in `flagRegion`'s lists**: a guest argv reading `--features mvp` must
    never narrow the language wazmrt accepts — the reasoning that put `--no-verify` there.
  - 🔒 **It reaches `.wast` too, via `wast.runScriptWith`.** A `.wast` instantiates and invokes the
    modules it contains, so a restriction covering `.wasm` and not `.wast` is sidestepped by
    wrapping the module in a script — **the identical bypass this path already closed once for the
    verify gate, and the attacker picks the extension.** The two sets INTERSECT: `--features` can
    only ever take features away, so a snapshot already judged by an older era stays there. Same
    shape as `--verify`, which raises strictness and never lowers it.
  - **Grammar, and the one place it refuses rather than decides:** comma-separated names, optional
    `all`/`mvp`/`none` seed, `name` adds and `-name` removes. An unseeded list takes the only seed
    its shape can mean — bare names imply `mvp`, signed names imply `all` — and **mixing signs with
    no seed is an ERROR**, because both readings of `gc,-simd` are defensible and picking one would
    be a precedence rule nobody reviewed. An unknown name is refused, never skipped: silently
    ignoring an item leaves the user believing they restricted something.
  - **Names come from `@tagName`, not from a list in `main.zig`.** The CLI would have been the
    FOURTH hand-written spelling of `features.Feature` — and the two that were hand-written
    (`capi.Feature`, `wazmrt.h`) are exactly the two that drifted and shipped a switch that did
    nothing. Deriving them makes the drift unrepresentable rather than merely pinned.
  - Applies on **every** path that validates, the summarize path included: `wazmrt --features mvp
    mod.wasm` printing "validation: OK" for a module the next invocation refuses would be worse
    than not having the flag.
- 🐛 **FOUND AND FIXED INSIDE F5-CLI — a stack smash in the flag parser's own first draft, and it
  is the most instructive thing in the track.** `parseFeatures` buffered its items into
  `[features.count * 2]` so the seed could be applied underneath them, and never bounded the index.
  **Every item has to be a VALID proposal name to be stored — which is exactly what made it look
  safe — but nothing stops a caller repeating one**, so `--features simd,simd,…` past 36 entries
  wrote off the end of a stack array. Under `zig build test` that is a panic; in the SHIPPED
  ReleaseSmall CLI it is a stack write reachable from the command line, in the one binary that
  parses untrusted argv.
  **Fix:** two passes over the string instead of one pass plus a buffer — pass 1 validates every
  item and settles the seed, pass 2 applies. There is no array left, so there is no bound to
  exceed, and the exe came out **512 bytes SMALLER**.
  🎓 **Three rules, and the last one is the reason this is written up rather than just fixed:**
  **(1) A buffer sized from a TYPE is not sized from the INPUT** — `features.count` bounds how many
  DISTINCT proposals exist, not how many items a user may type. **(2) "Every element is validated"
  is not "the count is bounded"** — validation constrained what could be written and said nothing
  about how much. **(3) The gate that would have caught it existed and did not cover this file.**
  `zig build test-safe`'s stated purpose is "a memory-safety bug that only manifests in an
  optimized build", and `main.zig` was not in it, because until this track the CLI had no test
  target at all. It is in it now. ⚠️ **When a front end starts parsing untrusted input, adding it
  to `test` is half the job — it belongs in the memory-safety gate too.**
- ✅ **F5 — DONE.** The C-ABI setter already existed. What F5 actually needed was the composition
  rule with Track 2c's comptime gating, **and a test target for the CLI at all**:
  - **The rule, stated once:** `-Dwat`/`-Dwasi` gate FRONT ENDS; a feature set gates the wasm
    LANGUAGE; **a runtime feature set can only ever be a SUBSET of what was compiled in.** It holds
    vacuously today — no proposal is compile-time removable — so it is *asserted* rather than
    assumed: a `comptime` block in `capi.zig` requires the default `Set` to grant the whole enum,
    and `zig build features` compiles that file in all four combinations, which is the only place a
    build-dependent feature set would first appear. Inversion-checked: flipping it reddens all four.
  - 🆕 **`main.zig` now has a test target (`cli_tests` in `build.zig`), and it never had one.**
    `root.zig` does not import it, so nothing in the CLI was reachable from `mod_tests` — the same
    gap this repo already records the previous C ABI dying of (#21's double free shipped that way).
    It stopped being merely untidy the moment `--features` put a **policy parser** in the front
    end: a security control whose parser is only ever exercised by hand is a control nobody
    checked. 5 tests, covering seed inference, the refusal of mixed signs, the refusal (not the
    skipping) of unknown names, enum-derived name coverage, and the subset rule.

⚠️ **Every arm was inversion-tested** — commented out, watched a named test fail, restored, and the
build confirmed to still SUCCEED first (the R9 rule). Seven arms, seven distinct failures.

*(The original scoping notes for F1r / F5-CLI / F5 follow, preserved because their reasoning is the
instructive part — including the two that were already stale in F's favour when written.)*


> 🆕 **UPDATED 2026-08-17 after Tracks D3/D4 — TWO of the notes below are now stale, both in F's
> favour. Read this before costing F1r.**
>
> **(a) F1r's "~84 call sites" is no longer true — the threading is DONE.** D4 needed an era-aware
> validator for a different reason (custom-descriptors RETYPES `br_on_cast`, so the same module is
> `assert_invalid` in the core suite and valid in the proposal snapshot) and added
> **`validate.validateWith(gpa, module, era: features.Set)`**, with `validate(gpa, module)`
> delegating to it as `.{}` (all features). The feature set already reaches `FuncValidator.era`.
> **F1r's remaining work is therefore not plumbing — it is deciding whether `firstViolation` should
> move INSIDE `validateWith`**, which is a policy question about one call, not 84 edits. The
> `.wast` runner is already the proof it works: `Runner.validateEra` calls `firstViolation` then
> `validateWith(self.features)`.
>
> **(b) There is a NEW, partially-enforced feature and it is F's to finish.**
> `features.Feature.custom_descriptors` (added by D4) gates the six D3/D4 **instructions** and the
> `br_on_cast` typing rule — but **NOT the type-level formers** `(exact $t)`, `(descriptor $d)`,
> `(describes $s)`, because `features.check` walks instructions and those live in the TYPE SECTION.
> A module that uses only the type syntax is still accepted with the bit off. The code says so at
> the enum and in `wazmrt.h`. ⚠️ **This is the first feature bit in the file that is knowingly
> partial** — closing it needs a type-section pass in `firstViolation`, which is F-shaped work and
> would also be the natural home for gating `exact` refs.
>
> ⚠️ **And one genuinely new hazard for F5's CLI surface:** `custom_descriptors` is the first
> feature whose ABSENCE changes the typing of an instruction that exists either way. A CLI
> `--features` that turns it off must therefore change what `br_on_cast` ACCEPTS, not merely which
> instructions are permitted. Any test for F5 that only checks "instruction refused" will miss it.

- **F1r — the gate sits BESIDE `validate`, not inside it.** Every caller performs the two-step
  (`firstViolation` then `validate`) by hand, and only `capi.zig` does. ⚠️ **This is the "THREE OF
  THE FOUR do X" shape** `design-decisions.md` names: a future entry point that calls `validate`
  alone inherits no gate and nothing fails. Folding the check into `validate` — or into the existing
  `will_execute` guard, where the run-path validation decision already lives — is the durable fix.
  ~~`validate(gpa, module)` → `validate(gpa, module, fs)` is ~84 call sites, not the ~15 estimated
  here (62 are `wat.zig` tests).~~ 🆕 **SUPERSEDED 2026-08-17 (D4): the 84 sites are ZERO.**
  `validateWith(gpa, module, era)` exists and `validate` delegates to it with the all-features
  default, so the parameter never had to reach the call sites at all — **an overload plus a
  delegating wrapper cost one function, not eighty-four edits.** ⚠️ The estimate was not wrong when
  written; it assumed the only shape was changing the existing signature. **Before costing a
  threading job, check whether a wrapper makes the callers irrelevant.**
  ⚠️ **Zig FORCES F1 and an enforcement arm to land together** — an
  unused parameter is a compile error, which is also why R9's inversions must be checked for a
  successful build. *(D4 hit this twice more; it is now three passes running.)*
- **F5-CLI — the CLI never gates at all.** `main.zig` has no `--features` and never calls
  `firstViolation`, so the C-ABI embedder can restrict the accepted language and a CLI user cannot.
  This is the real remaining half of F5; the **C-ABI setter it asks for already exists**.
- ✅ **F3 — DONE 2026-08-17. `features.Feature.multi_table`.** Gates on `module.tables.len > 1` —
  the whole INDEX SPACE, imports first, which is what covers all three spellings the spec asserts
  on (import+import, import+defined, defined+defined); counting only *defined* tables would have
  passed two of the three. Layered on `reference_types` in `Set.incoherent`. ⚠️ **It deliberately
  departs from the spec's proposal grouping** — multiple tables shipped *inside* reference-types —
  and is documented as such at the enum, in `wazmrt.h`, and in a test that asserts a ONE-table
  module still loads with the flag off (gating on `reference_types` instead would have refused most
  of `imports.wast`, the very file this exists to fix).
- ✅ **F4 — DONE 2026-08-17. `wast.featuresForPath`,** an opt-in directory → feature-set table.
  `proposals/threads/` → everything minus `multi_memory` minus `multi_table`; anything unlisted runs
  unrestricted, because the failure mode of guessing is judging some other file by the wrong
  language. `runScript` gained a required `path: ?[]const u8` (no default — *a defaulted policy is a
  policy nobody reviewed*); the ~45 inline-source tests pass `null` explicitly.
  🔑 **Both the positive path (`instantiateBinary`) and the negative one (`tryBuild`) now go through
  ONE `Runner.validateEra`** — a runner whose `assert_invalid` path gates while its `(module …)`
  path does not would call one module both valid and invalid inside a single file. That is
  `capi.zig`'s stated rule, and it applies here identically.
  **Result: the 8 closed, and the feared regression did not happen — 62,890 → 62,898 passed,
  89 → 81 failed, 965 → 965 SKIPPED.** The skip column is the one that mattered: *a file that trades
  passes for skips is invisible in a failure diff*, so all three totals were read, per the rule.
  Baseline group 2 is now empty. *(Those are F3+F4's own deltas. The skip total then fell 965 → 673
  later the same day via the skip-scoring split — a separate change; see `testing.md`.)*
  🎓 **And the lesson these 8 actually taught: a well-argued baseline entry is still an entry.**
  They carried the best reasoning in that file — "the runtime is ahead of the file", which is TRUE —
  and the argument justified the score so well that nobody asked whether the RUNNER could simply be
  told which era to judge by. **An explanation for a failure is not the same as a decision to keep
  it.** Re-read baseline group 1 with that in mind.
- 🐛 **Found while doing F3 — a shipped C-ABI defect, fixed here.** `capi.Feature` stopped at
  `exceptions = 13` and `valid()` hardcoded `<= 13`, while `features.zig` had `tail_call = 14` and
  `wazmrt.h` **declared** `WAZMRT_FEATURE_TAIL_CALL = 14`. So `wazmrt_config_set_feature(TAIL_CALL,
  false)` returned false and did nothing, while `wazmrt_config_all_features(false)` — which counts
  with `features.count` — *did* disable it: **the header advertised a switch that silently was not
  there, and the two spellings written by hand were the two that were wrong.** Now `valid()` derives
  its bound from `features.count`, and a **comptime pin compares `capi.Feature` against
  `features.Feature` name-by-name and value-by-value** (both arms verified to fire). The test loops
  over the enum rather than naming members — a hand-written list would have had the same blind spot
  as the code it checks.
- **F5 — surface the set.** CLI `--features=…`, and a C-ABI setter on the engine/store. ⚠️ **Must
  compose with Track 2c's COMPTIME gating** (`-Dwat` / `-Dwasi`): a runtime feature set can only
  ever be a SUBSET of what was compiled in, and that precedence rule needs one statement and one
  test. Extend `zig build features` to cover the combinations, as it already does for the build
  flags — it earned its keep once by catching six ungated `capi.zig` sites.

⚠️ **Every enforcement arm needs an inversion test** — comment the check out, watch a test fail,
restore. **And assert the BUILD SUCCEEDED before reading an inversion's silence**: two of R9's eight
inversions reported no failing test because commenting the check out left a Zig parameter unused.

### ✅ Track A — custom-annotations. **SHIPPED 2026-08-18. THE BASELINE IS EMPTY AND EVERY FILE RUNS**

> 🏁 **284 files, 63,934 passed, 0 failed, 0 skipped, and ZERO files with failures OR ERRORS.**
> `annotations.wast` 71 unrun commands → **64 passed / 0 failed / 0 skipped**.
> `tools/conformance-baseline.txt` now holds no entries at all: the `-Dbaseline` gate means what it
> says with nothing subtracted. +1,536 exe / +1,170 lib / **+0 dll**.
>
> **A3 DECIDED — NO feature bit for custom-annotations, and the reason is recorded rather than
> omitted** (Track P shipped without one and that is exactly how it became unrefusable): an
> annotation is *discarded at the lexer*, so there is no behaviour to refuse, nothing reaches the
> validator or the interpreter, and no attacker gains anything from one being present.
> ⚠️ **The reopen condition, so this does not become the next unrefusable proposal: if annotations
> ever carry meaning to any consumer — a name section, a tooling hint, anything read rather than
> dropped — they need a bit that day.** Until then the honest statement is "there is nothing to
> gate", not "we forgot".
>
> 🔑 **THE RULE THAT COST THE MOST WAS THE ONE HALF THE FILE TESTS.** 32 of the 64 malformed
> assertions are the character class, and three plausible readings each pass most of the file and
> fail a different corner: not "idchars" (`,[]{}` are valid inside an annotation and none is an
> idchar), not "non-control" and not "valid UTF-8" (`Heiße Würstchen` and an emoji are asserted
> MALFORMED though both are well-formed Unicode). The answer is **printable ASCII plus tab/nl/CR**.
> The first implementation used the non-control reading and scored 52/64 — **every one of the 12
> failures in that single corner.** When half a file tests one rule, take the rule from the
> failures rather than from the plausible-sounding version of it.
>
> 🎓 **AND AN INVERSION LIED — third session running for this rule.** Disabling the
> empty-annotation-id check left `start` an unused local, which is a COMPILE error, so the run
> produced no failures and the arm read as untested. **Assert the build succeeded before believing
> an inversion's silence.** Re-inverted as `… and false` so the local stays live; it then fails its
> named test, as do the other three arms.
>
> ⚠️ **SCOPE LIMIT, RECORDED RATHER THAN SMUGGLED IN:** the character class is enforced INSIDE
> ANNOTATIONS ONLY. The same §6.2.1 rule holds for source text at large and wazmrt does not check
> it there — `parseAtom` consumes any non-delimiter byte. Widening it would touch every `.wat` in
> existence, so it is a separate decision with its own blast radius; the regression test asserts
> the current behaviour deliberately so nobody "fixes" it by accident.
>
> *(The scope as written before the work is preserved below — it was accurate, including that this
> would be the highest-blast-radius track. `sexpr.zig` underlies both `wat.zig` and `wast.zig`, so
> unlike Track L — whose changed paths were unreachable — this one is on every text input there is.
> Guarded by a dedicated regression test that re-asserts what a relaxed lexer would reopen,
> **including the lone-`;` case: `(module) ; x`, twelve bytes, once hung the CLI at 10.4 GB RSS.**)*

#### The original scope, preserved

### 🎯 Track A — custom-annotations. **SCOPED 2026-08-18 (the scope that led to the go-ahead)**

`annotations.wast` is the only line left in `tools/conformance-baseline.txt`, and it is a **runner
error, not a failure**: the file dies at `parseAll` with `ReservedToken`, so all 71 of its commands
go unrun. That is why it has never appeared in the failure column and why its size has never been
priced.

**What is actually in the file — measured, not estimated:**

| | count | note |
| --- | --- | --- |
| `(module …)` with valid annotations | **7** | must be ACCEPTED — annotations carry no semantics |
| `assert_malformed` | **64** | 32 "illegal character", 7 "empty annotation id", 4 "unclosed annotation", 4 "unexpected token", 2 "unclosed string", 2 "empty identifier", 2 "unknown operator", 1 other |

**The proposal in one line:** `(@id …)` is a syntactic element a conforming implementation
**ignores**. So "implementing custom-annotations" means *lexing and discarding* them — there is no
new instruction, no new type, no ABI surface, and nothing to execute.

#### Where it actually breaks, and it is narrower than it looks

`@` is already an `idchar`, so `(@a)` **lexes today** — it parses as a one-atom list and then dies
in `wat.zig` as `BadModuleField`. The lexer only fails on what appears INSIDE an annotation:

```
(module (@a))            → BadModuleField   (parses; rejected later)
(module (@"a"))          → ReservedToken    (atom `@` abutting a string)
(module (@a , ; ] [))    → UnexpectedChar   (`;` is a comment-starter)
(module (@a x")"y))      → ReservedToken    (atom-string-atom with no separator)
```

🔑 **So the trigger is exact: a list whose first atom starts with `@`.** Everything after it, up to
the matching `)`, is opaque. That narrowness is the whole reason this is tractable.

#### The work

- **A1 — `sexpr.zig`: annotation mode.** On opening a list whose leading atom begins `@`, consume
  to the matching `)` in a mode where the RESERVED-TOKEN and UNEXPECTED-CHAR rules are relaxed and
  everything else still applies. The corpus pins exactly which rules survive, and it is not "all"
  or "none":
  - **Parens must still balance** — `(@a (@(@(@(@)))))` is valid, and 4 assertions are "unclosed
    annotation" (EOF inside one).
  - **Strings are still strings** — `(@a ")" "(" x")"y)` is valid, so a paren inside a string must
    not count; 2 assertions are "unclosed string".
  - **Block comments still nest** — `(@a (;bla;) (; ) ;)` is valid.
  - **The character class still applies** — 32 assertions are "illegal character" for raw control
    bytes, and `\09`/`\0a`/`\0d` (tab/nl/cr) are explicitly ALLOWED. ⚠️ **This is the rule most
    likely to be dropped by an implementation that treats annotation contents as "skip to the
    closing paren"**, and it is half the file.
  - **`(@)` with no id is malformed** ("empty annotation id", 7 assertions) — *but only at
    annotation position*: `(@a … (@) …)` is valid, because inside an annotation it is just tokens.
    **That asymmetry is the single subtlest rule in the track.**
- **A2 — the parser drops them.** Annotations may appear anywhere a token may, so they must vanish
  before `wat.zig`/`wast.zig` ever see them. Dropping at the `sexpr` layer means neither consumer
  needs to know they exist.
- **A3 — a `custom_annotations` feature bit?** ⚠️ **Decide explicitly and write the answer down** —
  Track P shipped a proposal with no gate and that is exactly how it became unrefusable. The
  argument for "no bit": annotations are *ignored*, so there is no behaviour to refuse and nothing
  an attacker gains. The argument for one: the same was true of custom-page-sizes' page field until
  it wasn't. **Whichever way, this must be a recorded decision rather than an omission.**
- **A4 — remove the baseline entry.** `tools/conformance-baseline.txt` drops to zero lines, and the
  `-Dbaseline` gate then means "no regressions from a clean sheet".

#### Risk — and it is the highest-blast-radius track left

🚨 **`sexpr.zig` is the foundation of BOTH `wat.zig` and `wast.zig`.** Every one of the 284 corpus
files, every `.wat` the CLI assembles, and every unit test that assembles text goes through this
lexer. Track L could not regress anything because its changed paths were unreachable; **this one is
the opposite — its changed paths are on every text input there is.**

Mitigations, in the order they matter:
1. **The trigger is a single condition** (`(` followed by an atom starting `@`). Nothing outside an
   annotation should reach the new code, and that is testable directly: assemble the whole corpus
   before and after and diff all three totals.
2. **`ReservedToken` and `UnexpectedChar` must keep firing outside annotations.** `sexpr.zig`'s own
   tests already pin `(func $"a"x)` and the lone-`;` hang (a 12-byte input that once took the CLI to
   10 GB RSS) — **run those inversions deliberately; the `;` case is the one a relaxed lexer would
   silently reopen.**
3. The fuzz target (`src/fuzz.zig`) already drives `wat.assemble` on mutated input and asserts its
   own coverage. **Extend its seeds with annotated modules** before trusting the change.

**Cost:** larger than Track L and smaller than wide-arithmetic — one file, no ABI, no execution
semantics, but the fiddliest rule set in the repo and the widest blast radius. **The 64 malformed
assertions are the specification; write them as the test list first and implement against it.**

### ✅ Track L — legacy `delegate`. **SHIPPED 2026-08-18. The corpus is at ZERO SKIPS and ZERO FAILURES**

> 🏁 **DONE, and the scope below was accurate: ~512 bytes, no ABI surface, four inversion-tested
> arms.** `legacy/try_delegate.wast` 2\/0\/24 → **25\/0\/0**; `legacy/rethrow.wast` 14\/0\/1 → **15\/0\/0**;
> corpus **63,870 passed \/ 0 failed \/ 0 skipped**. SD-3 is retired.
>
> 🔒 **The predicted risk R1 was the one that mattered and it was checked BEFORE the interpreter
> was touched, which is why it cost nothing.** The blanket validator refusal was masking a missing
> rule: the assembler accepts a bare `(func (delegate 0))`, which the spec calls malformed. The
> `.delegate` arm now requires its frame to be a `try_legacy`, the same rule `.catch_` carries.
> **A blanket refusal can hide a missing rule; deleting it is what reveals the rule was never
> written.** R2 (two passing assertions that must stay rejected) was measured and did not fire.
>
> *(The scope as written before the work is preserved below — it was the basis for the go-ahead.)*

> ⚠️ **DO NOT START THIS WITHOUT THE OWNER'S CALL.** It reverses a Standing Delta (SD-3), and this
> repo's own precedent is explicit: *"reversing it is an owner decision, not a conformance-pass side
> effect"* (`anyfunc`, R9). The work below is scoped so the decision can be priced, not so it can be
> started quietly.

**The whole of the corpus's remaining 25 skips is ONE instruction.** Legacy `try` / `catch` /
`catch_all` / `rethrow` are fully implemented and pass — `legacy/rethrow.wast` is 14 passed / 0
failed / 1 skipped. Only `delegate` is refused, and:

| file | passed | skipped | why |
| --- | --- | --- | --- |
| `legacy/try_delegate.wast` | 2 | **24** | its ONE module uses `delegate` → won't build → 20 assertions cascade to `NoTarget`, 3 negatives unjudgeable |
| `legacy/rethrow.wast` | 14 | **1** | one `assert_invalid` whose module contains a `delegate` |

🔑 **23 of the 24 are a cascade off a single unbuildable module** — the same shape wide-arithmetic
had. Judge the size by the MODULE count (one), not the skip count.

#### The premise changed: there IS an oracle, and it is in this tree

SD-3's stated reason was "no reference implementation to check the label arithmetic against". **wabt
implements it** — `wabt-ts/upstream/src/interp/interp.cc` (unwind) and `binary-reader-interp.cc`
(resolution) — and wabt is the canonical tooling for precisely the legacy encoding wasmtime and V8
dropped. The rule, read off it rather than inferred:

> `delegate d` resumes the handler search at label depth **`d + 1`** — one outside the delegating
> try itself — and scans OUTWARD for the nearest enclosing **legacy `try`**, skipping blocks and
> loops. If none remains, the exception propagates to the caller.

That accounts for every case in the file, including `delegate-to-block` (the intervening `block` is
skipped because it is not a try) and `delegate-to-caller-trivial` (no enclosing try → caller).

#### The work, by layer. Three of the four already exist in part.

- **L1 — assembler (`wat.zig`, ~2321).** One `return error.UnsupportedInstr` to remove, plus emitting
  `Op.delegate` with the resolved label. **The label machinery is already shared** — the doc comment
  at the legacy-`try` parser says a `$label`/`rethrow`/`delegate` operand already resolves against
  the same depth stack. Must also accept the FLAT form (`try_ bt … delegate l`, where `delegate`
  replaces `end`), which the parser already anticipates.
  ⚠️ **Four `assert_malformed`s constrain the grammar and are cheap to satisfy but easy to miss**:
  a bare `(delegate 0)` with no try, a `delegate` *after* a `catch` or `catch_all`, and `(delegate)`
  with no operand must all be malformed.
- **L2 — validator (`validate.zig`, ~1109).** Replace the `return error.UnsupportedOpcode` with the
  real rule: `delegate` CLOSES the try in place of `end`, and its label must resolve **in the scope
  outside the try** (the `+1`). `try_delegate.wast` pins the boundary: `(func (try (do)
  (delegate 1)))` is `assert_invalid` "unknown label", because depth 0 is the function level and
  there is nothing beyond it.
- **L3 — interpreter (`interp.zig`) — THE ONLY REAL WORK.** The plumbing already exists:
  `precomputeControlFlow` records `LegacyTry.delegate: ?u32` per try (~2254), and `throwException`
  currently bails on it (`if (lt.delegate != null) return error.UnsupportedInstruction`, ~2515).
  What is missing is the outward scan above.
  ⚠️ **wabt's shape is NOT wazmrt's and must not be transliterated.** wabt keeps a flat handler
  vector with byte offsets and jumps by index (`handlers.rend() - delegate_handler_index - 1`);
  wazmrt walks a control-label stack. **Port the RULE, not the loop** — the same caution R2's
  entity model needed.
  🔒 **Keep the unvalidated-run-path defence.** The current bail is also the guard that stops a
  hand-crafted binary from mis-routing; whatever replaces it must trap loudly on an out-of-range
  delegate depth rather than index off the end of the label stack, exactly as the `hardening` tests
  require elsewhere.
- **L4 — tests.** The corpus's **20 positive assertions are the behavioural oracle** and are the
  point of the exercise: `delegate-skip` (a middle handler must NOT run), `delegate-to-block`,
  `delegate-to-catch`, `delegate-to-caller-{trivial,skipping}`, `delegate-merge`. ⚠️ **Add a
  by-construction wrong-answer test anyway**: an off-by-one in the `+1` still catches *an*
  exception, just the wrong handler's — a wrong answer that every arity and type check accepts, the
  same shape as D1's exactness bug and wide-arithmetic's `(lo, hi)`. Nest three trys with
  distinguishable results so each possible off-by-one produces a different number.
  🆕 **And a differential run against wabt is now possible** — that is what the oracle buys, and it
  is worth more than the 25.
- **L5 — the record.** Inverting the two existing tests that assert the REFUSAL (`validate.zig`'s
  "validator rejects legacy try/delegate", and the assembler's) — they are correct today and must be
  replaced, not deleted, with tests for the new behaviour. And SD-3 itself has to be retired.

**Cost:** small — one instruction, machinery in place, ~8 lines of specification. **Size:** expect
under 1 KB; no new types, no new sections, one interpreter loop.

#### The argument AGAINST doing it, stated fairly

- It adds an instruction wazmrt can **mis-route**, in exchange for a legacy encoding the two largest
  runtimes have dropped. A refusal cannot produce a wrong answer; a routing bug can — and the
  failure mode is "the wrong `catch` runs", which is silent.
- No real guest has asked for it. Every toolchain still emitting legacy EH is old LLVM.
- 🔑 **The 25 are not evidence for doing it.** They are the *price* of the refusal, and the whole
  point of naming a Standing Delta is that a skip count is not by itself an argument. **Conformance
  numbers are the reason to be honest about the cost, not the reason to change the decision.**

#### The argument FOR

- The premise the refusal was written on is no longer true: the arithmetic can be checked.
- wazmrt already implements the *hard* parts of legacy EH (`try`/`catch`/`catch_all`/`rethrow` all
  execute correctly). `delegate` is the last member of a family that is otherwise complete — and a
  proposal implemented "except one instruction" is the shape this repo has been bitten by three
  times (memory64/table64, `return_call_ref`, GC-P3's six array ops).
- It would take the corpus to **zero skips as well as zero failures**, which no baseline entry
  except `annotations.wast` would then remain against.

### ✅ Track P — custom-page-sizes. **SHIPPED 2026-08-17; its GATE landed 2026-08-18 (Track F)**

> ⚠️ **CORRECTED 2026-08-18 — this header was unmarked while the section above it said P had
> shipped. That is the fourth instance of the one failure this file keeps recording: a status
> written from the scoping argument rather than from the code.** P1–P4 all landed on 2026-08-17.
>
> 🚨 **AND THE SCOPE ITSELF WAS SHORT ONE ITEM. P shipped with NO `features.Feature` member**, so
> nothing could refuse a byte-paged memory — `wazmrt_config_all_features(cfg, false)`, every switch
> the enum offers turned off, still accepted `(memory 1 (pagesize 1))`. Track F added
> `custom_page_sizes = 17`. **Note what the P4 checklist below did and did not ask for:** it
> enumerated every hardcoded `65536`, demanded a byte-granularity out-of-bounds test, and named its
> own security item — a careful list, and none of it asks whether the proposal can be TURNED OFF.
> **A proposal that ships without a bit in `features.Feature` is not "enabled by default"; it is
> unrefusable.** Add "does it have a gate, and is that gate tested?" to the deliverables of every
> future proposal track — it is the one question a per-proposal checklist cannot ask itself.

A memory declares its own page size — `(memory 1 (pagesize 1))`, byte-granular instead of the fixed
64 KiB. Already recognised and refused by name (`UnsupportedProposal`), so the parse site exists.

- **P1** — the page size in the limits flag byte (encoded as log2), decoder + the existing `wat.zig`
  `(pagesize N)` site.
- **P2** — validation of the field itself; limits arithmetic must not overflow.
- **P3** — instantiate, **every bounds check**, `memory.grow`, `memory.size`. 🔒 **THIS IS THE
  SECURITY ITEM IN TRACK P.** `memory.size` returns PAGES, `memory.grow` takes PAGES, and every
  bounds check compares against `pages × page_size`. **A single site left holding the hardcoded
  65536 is a memory-safety hole, not a conformance miss.** Deliverable: enumerate every use of that
  constant and convert or justify each one, in the commit message.
- **P4** — memory64 interaction: `page_size × page_count` must not overflow the 64-bit index space.
  wazmrt has been bitten here before; the overflow-safe memory64 bounds work is the precedent.
- **Verify** beyond the 2 assertions: a 1-byte-page memory must reject an out-of-bounds access at
  BYTE granularity. The assertions alone would not catch a bounds check that silently kept 64 KiB.

### ✅ Track D — custom-descriptors. **COMPLETE 2026-08-17 (D1–D5).** The largest feature since GC

Descriptors make a struct type's runtime description a first-class value, which in turn makes casts
EXACT. It extends GC, which wazmrt ships — an extension of a shipped proposal, not a new subsystem.
**D1 gates everything else; do not reorder.**

- ✅ **D1 — DONE 2026-08-17.** `(exact $t)` in text and binary, with subtyping enforced. Closed
  **26 failures and 89 skips = 115 assertions**; `exact-casts.wast` 0/3/108 → clean, `exact.wast`
  17 failures → 2.
  **Representation:** `exact_bit` at bit 27, taken from the index field (31/30/29-28 were all
  spoken for), halving the index range to ~134M — so the decoder now enforces `max_concrete_index`
  explicitly, because that bound and the declared-type-count bound are no longer the same
  constraint and `concreteRef` MASKS (an over-range index truncates to a smaller VALID one).
  `flagBits` carries the bit, without which `(ref (exact $t))` and `(ref $t)` compare equal
  wherever identity is asked. `concreteRefEx` is a separate constructor, not a fourth parameter:
  all 31 existing call sites mean "inexact", and inexact is not a policy — it is what a plain
  `(ref $t)` MEANS. **Rules:** an exact SUPER admits only an exact sub of the same type; an exact
  SUB satisfies an inexact super normally.
  🔒 **THE LESSON, and it is the one D3/D4 should be planned around: the by-construction
  wrong-answer test found live type confusion AFTER the score said the work was done.** With
  `subtypeOf` and `headMatches` both carrying correct exactness arms, and conformance reporting
  0 regressions / 7 improvements, `ref.test (ref (exact $super))` **still answered 1 for a
  subtype** — the four `ref.test`/`ref.cast` sub-opcodes read their target through a path that
  dropped the `0x62` prefix. The corpus could not see it because those files were already failing
  for other reasons. **An assertion count would have shipped D1 with a soundness hole in it.**
  ⚠️ Also worth knowing before D2: mid-change this showed **18 LOST passes that were not a
  regression** — those `assert_invalid`s had been passing because we could not PARSE `exact`
  (`BadValType` is not on `isOurLimitation`, so a parse gap scored as a correct rejection).
  Implementing half a feature exposed them as false passes. *(Original scoping below.)*
- **D1 — the `(exact $t)` reference-type former. THE HARD ONE.** ⚠️ Exact refs change **SUBTYPING**,
  not just parsing: `(ref (exact $t))` is **NOT** satisfied by a subtype of `$t`. So `subtypeOf`,
  `refMatches`, `headMatches` and the `TypeRegistry` canonicaliser all change together.
  🔒 **SOUNDNESS CHECKPOINT — the strongest security argument in this whole scope.** A `refMatches`
  that answers "yes" to a subtype where the spec demands exact is **type confusion**: the guest gets
  a value of a type it proved it did not have. That is the same shape as BOTH soundness defects
  already found on this branch (the host-externref/GC-index collision, and cross-instance GC object
  substitution). **Every cast arm needs a targeted WRONG-ANSWER test, not an assertion count** — the
  cross-instance defect passed the whole corpus before it was found by construction, not by score.
  Carries `exact.wast` (17), `exact-func-import` (5), `exact-casts` (3), `array_new_exact` (1).
- ✅ **D2 — DONE 2026-08-17.** `(descriptor $d)` / `(describes $s)` in text and binary, their
  validation rules, and the links folded into **all three** type-identity keys. Closed
  **37 failures**: `descriptors.wast` 21 → 0, `binary-descriptors.wast` 2 → 0, and 14 more across
  the four instruction files that had been mis-assembling.
  **Grammar, confirmed against wasmtime 47.0.3 (see below):** `0x4c <typeidx>` = describes,
  `0x4d <typeidx>` = descriptor, **describes FIRST**, both after the `0x50`/`0x4f` wrapper and its
  supertype vector. The reconnaissance below had the two bytes right and **the ORDER backwards** —
  `binary-descriptors.wast`'s third module is a `4c 00 4d 02` chain and its fourth asserts
  `4d … 4c …` malformed. Order and multiplicity are enforced **by construction**: at most one of
  each is read, so a repeat or a swap leaves a byte where the composite tag must be and
  `decodeCompType` refuses it. No second grammar table to drift.
  **Validation:** `checkDescriptorLinks` (same rec group, mutual, both structs, `describes` points
  strictly BACKWARDS) + `descriptorsMatch` in `declaredSubtypeOk`. ⚠️ **The subtyping rule is
  ASYMMETRIC and that is the whole of it** — `descriptor` is one-directional (a super with one
  forces one on every sub, a super without one imposes nothing), `describes` is biconditional.
  🔒 **Three keys, not one.** The reconnaissance named `interp.groupKey`; there are **three**
  places type identity is decided and all three had the trap — `Module.canonicalizeTypes`
  (module-local), `interp.groupKey` (store-wide), `typematch.eqMember` (cross-module, i.e. what an
  IMPORT goes through). Each has a by-construction test with a control arm proving the key still
  interns equal things equal. *A checklist that names one site is a checklist for one site.*
  🎓 **Two lessons worth carrying into D3:**
  **(1) The three totals moved 63,344/53/515 → 63,315/16/578 — passes DOWN 29, total DOWN 3.**
  The lost passes were FALSE: those modules assembled with the descriptor clause silently dropped,
  so their assertions ran against a module the file did not write. Now they assemble correctly and
  are refused at the D3/D4 instruction they use → skips. **And the total is not conserved**, which
  is new: a module that fails to build contributes ONE failure, one that builds contributes
  nothing, so three modules that started building took three countable assertions out of the corpus.
  Expect this again at D3.
  **(2) An independent oracle exists for the ENCODING even though no local runtime implements the
  proposal.** `wasmtime 47.0.3` fed our exact bytes answers *"custom descriptors proposal must be
  enabled to use descriptor and describes (at offset 0xb)"* — it parsed the form, named it, and
  pointed at the right byte. That is the emit-invalid lesson satisfied by something other than our
  own decoder. Use it for D3/D4's encodings too.
  🐛 **Found while doing D2, fixed here:** `(type $a (struct) <anything>)` silently DROPPED
  everything after the composite type — the parser took the element at that position and ignored
  the rest, so `(type $a (struct) (descriptor $b))` would have assembled as a bare struct with the
  descriptor gone. Same silent-drop shape as the `(func (parm i32))` bug the field parsers already
  guard, one level up.
  🔒 **Also added, out of D2's stated scope and deliberately:** `struct.new`/`struct.new_default`
  now REFUSE a type that declares a descriptor. `struct.new_desc` is D3, so nothing can build one
  of these values yet — which is exactly why the plain forms must refuse rather than mint a value
  whose own type promises a description it does not carry. Half a feature is where the unsoundness
  lives; 2 of `struct_new_desc.wast`'s assertions fell out of it.
  ⚠️ **Inversion results, and one of them is a trap for a later reader:** 16 arms caught
  individually. The rec-group check and the struct check in `checkDescriptorLinks` each report
  **NOT CAUGHT alone and caught as a PAIR** — they mirror each other, and once one is deleted the
  mutual-link check routes the case to the other half. They are not dead code; the doc comment
  there says so. Two inversions also failed to COMPILE first (an unused capture, an unused local
  `fn`) — the `best-practices` rule about reading a build failure before reading silence, twice.
  *(Original reconnaissance below, kept because its one wrong call is the instructive part.)*
- **D2 — the reconnaissance (2026-08-17), superseded by the entry above.**
  **Binary grammar, read off `binary-descriptors.wast`:** `0x4d <typeidx>` = descriptor,
  `0x4c <typeidx>` = describes. Both sit **between** the optional `0x50`/`0x4f` sub-type wrapper
  and the composite type — e.g. `4d 01 5f 00`. A repeated clause is malformed; that file asserts
  *"cannot have multiple descriptor clauses"* explicitly.
  **Text syntax:** `(descriptor $d)` / `(describes $s)`, including qualified names (`$A.desc`).
  **Where the code goes:** `Module.decodeSubType` parses both clauses, and `Module` needs
  `descriptors`/`describes` arrays parallel to the existing `supertypes`/`finals`; `wat.zig`
  parses and emits them in the position the decoder expects — ⚠️ **assert the BYTES, do not
  round-trip** (see the emit-invalid entry in `known-issues.md`); `interp.zig`'s `groupKey`
  (≈line 484) must fold the descriptor links into the structural key.
  🔒 **`groupKey` is the load-bearing one and the trap is the same shape as D1's:** a descriptor
  link missing from the key makes two structurally-identical-but-differently-described types
  canonicalise together — a cross-module WRONG ANSWER that will not show up as a failure, exactly
  as D1's dropped `0x62` did not. **It needs a targeted cross-module test, not an assertion
  count.** Worth 23 assertions (`descriptors.wast` 21 + `binary-descriptors` 2).
  *(Original scoping below.)*
- **D2 — `(descriptor $d)` / `(describes $s)` on struct types.** Type-section syntax + binary form.
  ⚠️ **Rec-group interning must include the descriptor links in the structural key** — otherwise two
  structurally-identical-but-differently-described types canonicalise together, which is a
  cross-module wrong answer of exactly the kind the store-wide `TypeRegistry` was built to fix.
  `TypeRegistry.groupKey` / `appendField` change here. Carries `descriptors.wast` (21),
  `binary-descriptors` (2).
- ✅ **D3 — DONE 2026-08-17.** `struct.new_desc` / `struct.new_default_desc` / `ref.get_desc`
  (`0xFB 0x20`/`0x21`/`0x22`). `struct_new_desc.wast` and `ref_get_desc.wast` both **0 failed /
  0 skipped**. ⚠️ **It is TWO allocators, not one** — the scoping line above said
  "`struct.new_desc` (8)" and the file exercises `struct.new_default_desc` equally.
  🔒 **The descriptor is stored as a `Value` on `HeapObject`, and that answered the roadmap's
  warning for free:** a `Value` already names the owning instance via its store slot, so
  cross-instance `ref.get_desc` resolves through the store with no extra code. The
  by-construction test is two INSTANCES OF ONE DEFINITION — identical type indices, so a
  type-index representation passes every type check and still hands back the wrong object.
  🔒 **The other soundness hinge is `ref.get_desc`'s exactness, and it PROPAGATES.** The result is
  `(ref (exact $d))` only when the operand was exactly `$t`; an operand exact in a SUBTYPE carries
  a different descriptor, so claiming exactness for it is type confusion. The spec states it as
  "only exact inputs of the inspected type produce exact outputs" and asserts the exact-subtype
  case invalid separately from the inexact one — two arms, both tested.
  **Opcodes confirmed independently:** wasmtime 47.0.3 answers *"custom descriptors operations
  support is not enabled"* for all three, and *"unknown 0xfb subopcode"* for a made-up one — so
  that is recognition, not a blanket message. Only `0x22` was pinned by the corpus; the other two
  appear in TEXT modules only, so a wrong sub-opcode would have round-tripped through our own
  decoder perfectly and been rejected everywhere else.
  ⚠️ **FOUR defects fixed here were NOT custom-descriptors, and three were SHIPPED.** D3's corpus
  was simply the first thing to reach them:
  **(1)** `Module.skipValType` — the type-section kind PRE-SCAN — consumed the `exact` former and
  left its type index in the stream. **One exact value type hid it**; two turned a valid module
  into `BadType`.
  **(2) No imported global could have a REFERENCE type at all.** `parseImport` unwrapped every
  list global type as `(mut T)` and parsed its last element, so `(ref null func)` reached
  `parseValType` as the bare atom `func`. Reference-types, function-references and GC alike, since
  the reference-types proposal shipped.
  **(3)** the const-expr `ref.null` read ONE BYTE where a heap type is an `s33` — so any type
  index ≥ 128 desynced the initializer stream.
  **(4) 🔒 `refMatches`'s cross-instance arm ignored `rt.exact` entirely**, so
  `ref.test (ref (exact $t))` on an object owned by ANOTHER INSTANCE answered 1 for a subtype.
  That is D1's type confusion in the one path D1's tests could not reach — **the third time this
  codebase has found a defect by asking "and what about across instances?"**. Fixed in
  `canonMatches`, which both the GC and funcref arms now share.
  🐛 Also fixed: a funcref's dynamic type was read off the IMPORTING module, so every concrete
  cast on an imported or foreign funcref failed — the plain inexact `ref.test (ref $f)` included.
  An import may legally name a SUPERTYPE, so the type must come from the DEFINITION;
  `definingFunc` now walks the import chain (re-exports stack, so one hop is not enough).
  ⚠️ **Tag space: `Op` has ONE unassigned byte left.** D3 took `0x1d`/`0x1e`/`0x27`, the last
  three. **D4 needs three more, so it must widen `Op` to `enum(u16)` and move every internal tag
  above `0xff` FIRST** — after which no raw byte can name one and `decodeBody`'s guard collapses.
  Doing it inside D3 would have made this entry's size delta unattributable. *(A byte-range guard
  for the three new tags was added and then REMOVED: an inversion showed it caught nothing,
  because the immediate-kind switch already refuses every `.gc_type` byte. The comment justifying
  it — "a kind real ops have" — was simply false. A redundant guard teaches the next reader the
  wrong rule.)*
- ✅ **D5 — DONE 2026-08-17, with D3.** `array_new_exact.wast` 1 → 0. It is not an instruction at
  all: it asserts that **every GC allocation produces an EXACT reference**, which is one argument
  per allocator once `struct.new`'s result is exact — and D3 needed that anyway, because
  `(global (ref (exact $d)) (struct.new $d))` appears throughout `struct_new_desc.wast`.
- ✅ **D4 — DONE 2026-08-17. TRACK D IS COMPLETE.** `ref.cast_desc_eq` (`0xFB 0x23`, null variant
  `0x24`) and `br_on_cast_desc_eq`/`_fail` (`0x25`/`0x26`). All three files **0 failed / 0
  skipped**, and `br_on_cast.wast`/`br_on_cast_fail.wast` closed with them.
  **It was carried as TWO failures and was worth 353 SKIPS.** The instruction to rank it by skips
  was right; sixth instance of R3/R5/P.
  🔒 **The load-bearing rule is IDENTITY, not type equality.** `$b1` and `$b2`, two allocations of
  one descriptor type, answer every type-level question identically — canonical id, subtype chain,
  exactness. An implementation that compared TYPES would satisfy every shape assertion in
  `ref_cast_desc_eq.wast` and still be `ref.cast` wearing a different name. Written by
  construction, with the cross-instance variant on top.
  ⚠️ **The null descriptor traps FIRST — before the value's own null-ness, and even when the
  target is nullable.** Get the order wrong and a trap becomes a successful cast to null.
  🆕 **D4 had to add a `custom_descriptors` FEATURE, and the reason is new to this project: the
  proposal RETYPES AN EXISTING INSTRUCTION.** `br_on_cast` requires a downcast (`rt2 <: rt1`) in
  the merged spec and only a shared top type under custom-descriptors — so `br_on_cast 0 eqref
  anyref` is `assert_invalid` in the CORE `br_on_cast.wast` and a VALID module in the proposal's
  copy of the same file. No single answer satisfies both. `wast.featuresForPath` now judges each
  by its era, which is F4's machinery used **in the other direction for the first time**: this is
  the one entry that is opt-IN by directory, because the era that LACKS the proposal is the merged
  spec, i.e. every other file. The bit is threaded into validation through a new `validateWith`,
  and reaches `capi.Feature` and `wazmrt.h` under their comptime pin.
  ⚠️ **Partially enforced, and the code says so:** the bit gates the six D3/D4 INSTRUCTIONS and
  the `br_on_cast` rule, but NOT the type-level formers (`(exact $t)`, `(descriptor $d)`,
  `(describes $s)`) — `features.check` walks instructions and those live in the type section.
  Closing that needs a type-section pass, which belongs with F5.
  🔧 **The `Op` → `enum(u16)` widening happened here, as D3 said it must.** Only the NEW tags moved
  above `0xff` (`0x100`+); the pre-existing ones keep their byte values because `immediateKind` and
  `simpleSig` switch on those literals. That is enough to close the class: `@enumFromInt(b0)` on a
  wire byte can no longer name a new tag, so `decodeBody`'s raw-byte guard is now FROZEN — it lists
  the pre-widening tags and nothing added later can need an entry. Five sites went through a new
  `opcode.wireByte(op) ?u8` instead of a bare `@intFromEnum`, which turns "this op has a one-byte
  encoding" into a checked question rather than a silent truncation.
  ⚠️ **Inversion note worth keeping:** `descEqMatches`'s type check reports as caught by nothing,
  and that is correct rather than a missing test — for a VALIDATED module the identity check
  subsumes it (a descriptor object belongs to exactly one described object). It stays as defence
  for the UNVALIDATED run path, same standing as the `hardening` tests, and the code says so.
  Two other inversions were silent until the tests were sharpened: the branch DIRECTION is only
  visible in the carried TYPE (a block typed `anyref` accepts either shape), and a forgotten
  descriptor pop is invisible when the block ends in a stack-polymorphic `return`.
- **Still open, and NOT part of Track D** — the two remaining corpus failures, now baseline
  group 4 ("diagnosed gaps in shipped functionality", a group that did not exist before):
  `exact-func-import.wast` (1) — LINK-TIME import matching reads the DECLARED import type where
  D3 taught the RUN-time path to read the defining one; the linker needs `interp.definingFunc`'s
  walk. `exact.wast` (1) — `(ref exact 0)` without parens around the former must be malformed and
  the assembler takes it. Both cheap, both diagnosed.

**Cost:** expect the largest ceiling raises on the roadmap since the GC batches — D1 alone is
comparable to the bottom-type lattice (+1 KB for 9 variants) or larger, and it touches decoder,
validator and interpreter, so the DLL moves too. Budget a raise per increment; do not batch them,
because a batched raise cannot be attributed.

**Cross-track verification:** the differential harness in `tests/differential/` already exists and
should be pointed at every D increment. ⚠️ **There is no privileged oracle** — when wazmrt and a
reference disagree, that is a question, not a verdict; the open wasmtime 222-vs-223-byte differential
is the standing reminder.

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
> below. ⚠️ *(This line read "Legacy `try`\/`catch`\/`delegate` stays out of scope" — **all of legacy EH is now implemented**: `try`\/`catch`\/`catch_all`\/`rethrow` in Phase 6.3, `delegate` on 2026-08-18.)*
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

- **SUPERSEDED 2026-08-17 — promoted to Track F** at the top of this file after the owner asked for
  "no holes left open". Kept here because the DIAGNOSIS below is the part worth re-reading; Track F
  is the plan built on it. Per-directory feature policy in the `.wast` runner is the only
  way to clear the last 8 baseline entries (`proposals/threads`, 6 in `imports.wast` + 2 in
  `memory.wast`). Those files assert `(module (memory 0) (memory 0))` and
  `(module (table 10 funcref) (table 10 funcref))` are INVALID, because that snapshot predates
  multi-memory and multi-table. wazmrt implements both, so it accepts them — **the runtime is ahead
  of the file**, and refusing them would be the regression. A spec proposal directory is meant to be
  run with THAT PROPOSAL'S feature set, so the honest fix is to run `proposals/threads/` with
  `multi_memory` and multi-table off.
  ⚠️ **The blocker is that `features` is DESCRIPTIVE, not ENFORCING.** `validate()` takes
  `(gpa, *const Module)` and no feature set; `features.zig`'s `require(fs, …)` walk only *computes*
  which proposal a module needs, for `zig build features`. So the work is (a) thread a
  `features.Set` through `validate` and its ~15 callers, (b) add enforcement arms — including a
  multi-table rule, which has no `Feature` today (multiple tables arrived with `reference_types`,
  but gating on that would also disable the `funcref` these files legitimately use, so it needs its
  own flag), (c) a directory→feature-set table in `wast.zig`. **Not worth it for 8 assertions
  alone** — but it is the correct mechanism the moment a second proposal directory is targeted, and
  it would make `zig build features` and the validator share one source of truth.
  ⚠️ **REJECTED cheap alternative:** special-casing "under `proposals/threads/`, refuse >1
  memory/table" directly in the runner. ~15 lines, and it turns the number green — but it creates a
  SECOND place where "what is enabled" is decided, which is the exact one-call-site divergence that
  produced the 14 mis-scored failures found on 2026-08-14. **Don't fix a scoring problem by adding a
  second scorer.**
- Interpreter shape: **DECIDED 2026-07-02 — Option A** (switch over a pre-decoded IR); see
  `design-decisions.md`. Open sub-question: whether/when to add the Option B register-rewriting pass —
  decide empirically against size+speed once basic execution works and there's a benchmark.
- Optional `-Dlibc` build flag if an embedder wants wazmrt to share the host `malloc` (default stays
  libc-free — see `design-decisions.md`).
- WASI support scope (study wasmtime/wazero) — deferred until core execution exists.
