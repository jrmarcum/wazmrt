# Best Practices — the method rules, extracted from what went wrong

Every rule below was paid for. Each one is followed by the incident that produced it and the file
where that incident is written up in full.

**This file holds METHOD, not findings.** The post-mortems stay where they are — `known-issues.md` for
defects, `roadmap.md` for programme state, `design-decisions.md` for the decisions themselves. What
lives here is the transferable part: *how to work on this codebase so the same class does not recur.*
When a new pass produces a lesson that would apply to a completely different subsystem, add it here
**and** leave the detail in its home file.

⚠️ **Read this before starting a conformance pass, an audit, or any change to a producer/consumer
pair.** Most entries exist because someone competent did the obvious thing.

---

## 1. Verifying a change

**Diff the OUTPUT, not the exit code.** A build that still exits 0 while silently dropping passes is a
regression. Re-run the affected `.wast` files and compare `N passed / N failed` against the pre-change
baseline. — the standing rule in the "look for code issues" trigger, `INDEX.md`

**A win in the target files is not evidence the change is right — diff the WHOLE per-file summary.**
R1's type-matcher memo was keyed on two rec-group start indices, so one link's verdict was served to an
unrelated later link and 32 import assertions flipped. Every file R1 was aimed at improved anyway; it
surfaced only because `imports.wast` regressed 5 → 21 in the full diff. — R1, `roadmap.md`

**A conformance number says nothing about a surface the corpus does not reach.** The same R1 defect sat
in the shipped C ABI's `define_instance` path, which the `.wast` suite never touches — the corpus read
237 identically before and after the fix. Ask what the number does *not* cover before treating it as
coverage. — R1, `known-issues.md`

**Re-measure before quoting any number.** Sizes, pass counts and timings in these files go stale
silently, and a stale number is worse than none because it reads as current. The shipped artifacts
roughly doubled in a month while "smallest binary" was a stated goal. — `design-decisions.md`,
`testing.md`

**Pass counts over a corpus you cannot fully run are UPPER BOUNDS, not measurements.** Skips are not
passes. 2,649 assertions are still skipped in the spec suite; any headline figure that ignores them is
overstated. — `testing.md`

**Run one `zig build` at a time on this box, and expect `error: Unexpected` to mean the environment,
not the code.** Chained builds race the cache lock; a `D:` cache dir fails outright (use
`--cache-dir`/`--global-cache-dir` on `C:`). — Windows gotchas, `design-decisions.md`

**`D:` is exFAT.** It has no symlinks, so `zig build test-security` cannot pass from this repo's own
cwd — that is what the step's "run from an NTFS cwd" note means. Verify from a `C:` cwd before reading
those failures as a regression. — R1, `roadmap.md`

## 2. Investigating a defect

**A defect classified by its error message can be a shadow of a defect three layers up.** T5 was filed
as "oversized limits refused at the wrong stage"; it was not a defect at all, but a symptom of the WAT
assembler dropping `(pagesize …)` four layers away. — T-list, `roadmap.md`

**Triage by first-failure text mislabels.** The T-list grouped 164 failures by each file's first
failure and got three of its five items wrong — location, existence, and subject. Run with
`-Dfailures=600` and read *every* failure before grouping. — T-list, `roadmap.md`

**An estimate built from error messages undercounts.** R1 was triaged at 25 from the failures whose
message named a type mismatch; it was 38, because the same root cause was also producing validation
errors, silent accept-invalids and two wrong encodings. — R1, `roadmap.md`

**When a proposal-directory file fails, diff it against its main-suite original before believing the
label.** `binary.wast` and `proposals/custom-descriptors/binary.wast` differ by one byte and carried
the same 25 failures — grouping by directory made a core-decoder hole look like a proposal gap. — T1,
`known-issues.md`

**Split the file when one file shows a double-digit failure count.** 25 distinct decoder defects looked
like one until `binary.wast` was split into 127 one-form files. That splitter is worth rebuilding every
time. — T1, `known-issues.md`

**Stop reasoning about the code and run the oracle.** Twelve passes *reviewed* against the spec; the
thirteenth ran the official testsuite and found what review had not. — 13th pass, `known-issues.md` /
`testing.md`

**A grep for the names you expect finds the code you expected to exist, not the code that is there.**
Searching `capi.zig` for `funcTypeEq|matchExtern|TypeMismatch` returned nothing, and "the C ABI does no
import type checking at all" was nearly written into memory. It checks — inline, unnamed, with raw
`!=`. — R1, `known-issues.md`

**A feature can be present, tested, and green while failing at exactly the thing it is for.**
`return_call_ref` shipped as call-then-return: every shallow assertion passed, and the one property the
proposal exists to provide — unbounded depth — was absent. Test the *purpose*, not the surface. — T4,
`roadmap.md`

## 3. Producer/consumer pairs — the recurring blind spot

**Our assembler is not an oracle for our decoder.** `wat.zig` drops something, `Module.zig` does not
require it, the round trip looks clean, and the module we assembled is not the module we were given.
**Four occurrences in two days**: the data-count section, the `0x50` sub-type wrapper, flattened rec
groups, and element-segment types. — `known-issues.md`

**A decoder rule with no matching emitter rule is a bug that hides itself.** Any conformance failure
reaching the WAT path must be checked at BOTH ends before the runtime is suspected. — `known-issues.md`

**Fixing only the consumer rejects valid input.** Finality was thrown away by the decoder *and*
mis-emitted by the assembler; repairing the validator alone turned a silent accept into a loud reject
on modules that were fine. Check whether the mirror half exists before shipping either. —
`known-issues.md`

## 4. Tests and gates

**A gate that cannot pass is not a gate — and a gate that cannot fail is not one either.** Both
directions have bitten: `zig build conformance` once failed unconditionally (`design-decisions.md`),
while a feature-gating draft was wrong in the FALSE-POSITIVE direction and a symbol gate was
"demonstrated" by testing the wrong mechanism (`known-issues.md`).

**A new test that has never failed has not been shown to test anything.** Invert its assertion, watch
it fail, restore it. R1's `define_instance` test was confirmed this way; the path it covers had only a
symbol-existence entry before. — R1, `known-issues.md`

**A goal with no gate is a preference.** "Smallest binary" was a stated goal for a month with nothing
measuring it, and the artifacts doubled. — `design-decisions.md`

**Guard the property, not a proxy for it.** — `design-decisions.md`

**A cache key must name everything the answer depends on.** — R1, `roadmap.md`

**Never green-wash our own gaps.** An unimplemented command form or an unknown mnemonic is *not*
evidence a module is invalid. `assert_invalid`, `assert_trap` and `assert_unlinkable` each need the
"this is our limitation" arm, or the conformance numbers count our holes as passes. — `wast.zig`
`isOurLimitation`, `known-issues.md`

## 5. Recording what you found

**Record findings that were WRONG, so they are not "fixed" again.** At least two audit findings have
been retracted after being verified false, and one carries an inline `Don't "fix" it again` comment at
the site. A retraction is as valuable as a finding. — `testing.md`, `roadmap.md`, `validate.zig`

**Say which claims are live and which are as-triaged.** The R-list's per-item counts were accurate when
written and stale the moment R1 landed; they now say so explicitly rather than reading as current. —
`roadmap.md`

**A stated BENEFIT is a hypothesis about someone else's code** — verify it against the code, not the
docs, before adopting anything. — `design-decisions.md`, the adoption checklist in
`third_party/LICENSES.md`

**Prefer a hard abort to a silent stub.** Unhandled input that emits a placeholder instead of erroring
is the worst failure mode in this codebase's taxonomy — and a disabled proposal must be rejected
loudly, never silently ignored. — the audit trigger, `INDEX.md`
