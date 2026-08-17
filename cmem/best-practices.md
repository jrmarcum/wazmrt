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

**A conformance number says nothing about a surface the corpus does not reach — and "it reaches it"
is itself a claim that can be silently false.** The same R1 defect sat in the shipped C ABI's
`define_instance` path, which the `.wast` suite never touches. Worse, R4 recorded "core
accept-invalid is ZERO" **truthfully**, and R5 made the corpus able to drive the text front-end for
the first time; 88 more appeared in core files immediately. Ask what the number does not cover, and
then ask what the *runner* cannot currently execute. — R1/R5, `known-issues.md`

**Re-measure before quoting any number.** Sizes, pass counts and timings in these files go stale
silently, and a stale number is worse than none because it reads as current. The shipped artifacts
roughly doubled in a month while "smallest binary" was a stated goal. — `design-decisions.md`,
`testing.md`

**Pass counts over a corpus you cannot fully run are UPPER BOUNDS, not measurements.** Skips are not
passes. 2,412 assertions are still skipped in the spec suite; any headline figure that ignores them is
overstated. — `testing.md`

**An item whose symptom is a SKIP cannot be sized from the failure column at all.** R5 was filed at
"~23" and was **1,291** — an unimplemented command form produces no failures, only skips, and the
runner reports a skip total with no per-reason breakdown. R8 was 176 of the same skip, filed as a
separate item because it landed in a different column. Size a runner gap by grepping the corpus for
the form, not by reading the report. — R5, `roadmap.md`

**Rank remaining work by ASSERTIONS UNBLOCKED, not by failures closed.** The R-list has re-learned
this three times: R3 was ~10 failures and freed 225, R5 was "~23" and freed 978, and R10 stands at 13
failures suppressing ~420. A file reading `0 passed, 1 failed, 161 skipped` is the highest-value
target in the suite and looks like the lowest. — R3/R5/R10, `roadmap.md`

**Judge a conformance pass by what it RUNS, not by the failure total.** R5 took failures 143 → 216
and that was the point: passes 61,429 → 62,333, skips 2,407 → 1,429. A number that only ever goes
down can be improved by running less. Check that no file LOST passes (join the per-file counts) —
that is the regression test; the total is not. — R5, `testing.md`

**When a predicate and its wiring are separate, invert the WIRING.** R5's literal-syntax test called
`validIntLit`/`validFloatLit` directly, so disabling their call sites left it green while the
assembler accepted `0xff__ffff` again. A test of a rule is not a test that the rule is consulted. —
R5, `testing.md`

**`std.fmt.parseInt`/`parseFloat` are not a spec's literal grammar.** They are close enough to look
right and differ exactly where the spec is strict — Zig takes `_` in positions wasm forbids and
accepts a leading-point float. Worse, the permissive path SILENTLY TRUNCATED: `i32.const
0x100000000` compiled to `0`. When a format defines its own lexical syntax, write it. — R5,
`known-issues.md`

**Read the SKIP column in the same row as the failure count.** A build failure takes every assertion
that targets that module into skips, so a small failure count can hide a total blackout:
`array_fill.wast` read `0 passed, 1 failed, 29 skipped` — one failure, and the whole file unrun. R3
was triaged at ~10 failures, scored 16, and freed **225 suppressed assertions**. Failures fell 36
while real runs rose 225 — the second number is the size of the item. — R3, `roadmap.md`

**Run one `zig build` at a time on this box, and expect `error: Unexpected` to mean the environment,
not the code.** Chained builds race the cache lock; a `D:` cache dir fails outright (use
`--cache-dir`/`--global-cache-dir` on `C:`). — Windows gotchas, `design-decisions.md`

**`D:` is exFAT.** It has no symlinks, so `zig build test-security` cannot pass from this repo's own
cwd — that is what the step's "run from an NTFS cwd" note means. Verify from a `C:` cwd before reading
those failures as a regression. — R1, `roadmap.md`

## 2. Investigating a defect

**Before debugging a toolchain failure, prove it is yours: build the UNMODIFIED commit.** `zig build`
started dying with a bare `error: Unexpected` — no step, no file, nothing that `--verbose` or
`--summary all` would expand. Stashing the one edited file and rebuilding HEAD, a commit that had
been green hours earlier, reproduced it exactly. That single check reclassified the whole
investigation from "what did I break" to "what broke around me". **A one-command falsification is
worth more than any amount of reading the diff you already believe in.**

**Two unrelated tools reporting corruption in one directory is a STORAGE finding, not two bugs — but
"storage" is three layers, and naming the wrong one sends the fix to the wrong place.** Same
incident: zig's `.zig-cache` was unreadable (`zig build --help` failed until it was moved aside)
*and* git warned `unable to find all commit-graph files`. Two independent caches, one directory,
same hour. Copying the tree to the other drive and watching `zig build test` exit 0 confirmed it was
environmental. ⚠️ **Both caches were REGENERABLE, so clearing them felt like a fix and was not** — it
moved the symptom without touching the cause.

⚠️ **Then the cause was misnamed TWICE, and both errors are instructive:**

1. **"Failing hardware."** Drawn from six `disk`/event-51 "error detected on device … during a
   paging operation" entries — **without checking their timestamps.** All six were a single burst
   from a week earlier; **zero** coincided with the failures. `Get-PhysicalDisk` reported the disk
   `Healthy`. **An event log entry is evidence of something that happened, not of something that is
   happening — read the clock before drawing the arrow.**
2. **"Antivirus"** (the owner's hypothesis, and worth testing rather than accepting). Refuted:
   Defender is *stopped* on that machine, `Get-MpPreference` fails `0x800106ba`, the active agent is
   Datto EDR, and a probe build produced **no AV events at all**.

**The actual cause was one query away the whole time:** `Get-Volume -DriveLetter D` →
`HealthStatus: Warning`, `OperationalStatus: Full Repair Needed`. A damaged **exFAT filesystem on a
USB flash drive** — physical disk fine, volume not. **Identify the LAYER (physical disk → volume →
OS → application) before naming a cause; each one has its own health query, and the cheapest of them
was never run.**

🔻 **And this project's OWN memory already recorded the relevant fact** — `known-issues.md` and
`roadmap.md` both say "`D:` is exFAT" and explain the `test-security` "run from an NTFS cwd" note.
It was even visible in the `INDEX.md` row being read that same session. **Search cmem for the
environment before diagnosing the environment.** Two wrong causes shipped in four commit messages
because a five-second grep came after the conclusion instead of before it.

When a build tool's error text has no step and no path, suspect the environment before the
source — but then find out WHICH environment. — `anyfunc` closure, 2026-08-17

🚨 **AND THEN THE FILESYSTEM DIAGNOSIS ABOVE WAS WRONG TOO — it was the THIRD of four, and the
most convincing.** The volume genuinely reported `Full Repair Needed`; the repair genuinely fixed
it (`Get-Volume D` → `Healthy`/`OK`); **and the build failed exactly as before.**

**FINDING A REAL DEFECT AT A LAYER IS NOT EVIDENCE THAT IT CAUSES YOUR SYMPTOM.** This is the rule
the whole four-diagnosis sequence was paying for, and the first three all violated it in the same
way: each found something genuinely wrong (stale event-51 entries, a plausible AV agent, a damaged
volume) and stopped there, because *a confirmed defect feels like an answer*. The event log was
real, the filesystem damage was real, the repair was worth doing. None of them was the cause.

**What finally worked was varying ONE THING AT A TIME instead of reasoning about which layer looked
guiltiest:** a minimal `zig init` project built fine on D: (so not exFAT-inherent), a minimal DLL
project built fine (so not the DLL step), the real repo built once and then failed on the *second,
byte-identical* invocation (so not the source), and the same build with its cache on NTFS worked
indefinitely (so: the cache location). **A `.zig-cache` on that exFAT volume survives exactly one
build and is then poisoned.** Fix: `ZIG_LOCAL_CACHE_DIR` on an NTFS path — one environment variable,
replacing a "copy the whole tree to C:" workaround that had been accepted as the cost of doing
business.

⚠️ **The corollary, which reverses a rule stated 25 lines above: "clearing the cache felt like a fix
and was not" was itself backwards.** Clearing the cache *is* the fix — for one build. The cache
LOCATION is the fix for all of them. **A workaround that works exactly once is a clue about
frequency, not a failed fix; ask what makes the second attempt different.** — the D: build blocker,
`INDEX.md` (2026-08-17, fourth and final diagnosis)

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

**When a rule is off by a CONSTANT, look for failures in both directions.** R4's catch-label
off-by-one was filed as an accept-invalid item; the same one-frame error was also rejecting valid
modules in the same file. An item framed as "things we wrongly accept" will not make you look for the
things you wrongly reject — check both before believing the framing. — R4, `roadmap.md`

**A test that encodes the same misreading as the code is not evidence — it is the misreading,
restated.** R4's `C.refs` rule was wrong in the code, in the comment above it, and in a unit test
asserting the wrong case valid under a heading that miscounted the positions. When a fix breaks
existing tests, decide which of the two encodes the rule by checking the spec and the external
corpus, never by which one is older. — R4, `testing.md`

**A negative assertion satisfied by the WRONG error is a false pass.** R4's `if (result (ref 1))`
case was already "rejected" — with `StackUnderflow`, from an unrelated malformation — so it scored
green while testing nothing. Same family as counting our own limitations as passes. — R4,
`known-issues.md`

**A failure's cause count is not known until it PASSES.** Fixing one defect twice exposed the next
one inside the same failure: `linking.wast` L410 went from `result mismatch 0x4` to `trap
UndefinedFunc` when funcref identity was fixed — the wrong answer had been hiding a segment-ordering
bug — and closing a pure harness gap turned `instance.wast` from 0/8 into 10/2, where the 2 were a
real tag-identity defect. Re-triage after every step, never only at the start. — R2, `roadmap.md`

**A check that makes the same mistake as the thing it checks is not a check.** `call_indirect`
dispatched through the reader's function index space *and* read the callee's type from the reader's
module, so the type check agreed with the wrong function and let the call through. Ask what the
verifier and the verified have in common before trusting a green check. — R2, `roadmap.md`

**An entity reached across a link has an IDENTITY, and its index is not it.** Three times now, in
three subsystems: R1's types (rec-group position, not module-local index), R2's funcrefs (instance +
index, not index), R2's tags (a shared identity, not each importer's own slot). Whenever a thing can
be imported, ask what makes two of them the same thing. — R1/R2, `roadmap.md`

**A guard covers the cases its author was debugging, not the cases that match its reason.** The
raw-internal-tag guard rejected `0xd7..0xfa` and left `0xc5..0xcc` — tags that already existed when it
landed — so a raw `0xC5` byte, not a wasm opcode at all, decoded *and executed* as
`i32.trunc_sat_f32_s`. When you write a guard, enumerate everything with the property, not everything
in the bug you are on. — R3, `roadmap.md`

**A second copy of a lookup table is a second place to be incomplete.** The assembler's `isRefType`
listed `funcref`/`externref` while `shorthandRefType` next door held all ten heads, so
`(elem $e i31ref …)` was read as a list of function names. Deduplicating it closed R6 outright.
Before adding a membership test, grep for the table that already answers it. — R3, `roadmap.md`

**The type the stack shows you is not the type the memory has.** A packed `i8` element and a plain
`i32` element both project `i32` onto the operand stack, so `array.copy` comparing `unpacked()` forms
called `(array i8)` and `(array i32)` compatible and would copy between different element widths.
Compare storage, not projection. — R3, `roadmap.md`

**When one instruction's operands are in different UNITS, the bound is the product, not the sum.**
`array.new_data` takes a byte offset and an element count, so the check is `offset + size × width`;
the unscaled form would read 36 bytes past a 12-byte segment. Ask what each operand counts before
writing the bounds check. — R3, `roadmap.md`

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

🚨 **A SYNTHETIC INTERNAL TAG PLACED IN A REAL ENCODING SPACE WILL EVENTUALLY MEAN SOMETHING ELSE —
and if you EMIT it, the damage leaves the process.** wazmrt gave its twelve non-null abstract
reference types synthetic valtype bytes in "an otherwise-unused range", and `emitValType` wrote
them out raw, so `(ref i31)` assembled to the single byte `0x62`. The spec has no one-byte
non-null shorthand; it is `0x64 heaptype`. Every such module wazmrt produced was invalid to every
other runtime — and by 2026 `0x62` had become the custom-descriptors `Exact` prefix, so wasmtime
rejected our output with **"unexpected exact type"**. **Reserve internal tags OUTSIDE the format's
space, or convert at the boundary; "currently unused" is a statement about today's spec.**
⚠️ **And the reason it survived nine months: the defect was ASYMMETRIC, so nothing we own could
see it.** Our decoder accepted both the standard form and our own tags, so we round-tripped our
output and read everyone else's; **the entire conformance corpus is blind by construction** — the
run before and after the fix is byte-identical. **When a bug can only be seen by a third party,
the test has to BE a third party** (here: hand-build the bytes, hand them to wasmtime) **or assert
the bytes directly. A round-trip proves agreement with yourself.** — emit-invalid, `known-issues.md`

**Two consumers agreeing is not corroboration when they share the mistake — and there can be THREE.**
R4's `try_table` catch label was resolved one frame too deep by the assembler, the validator *and*
the interpreter, identically, so every round trip was self-consistent and the whole corpus was green.
No test could have found it; only the spec rule did. Count the implementations of a rule before
trusting that they check each other. — R4, `roadmap.md`

**A workaround in the producer for a gap in the consumer does not stay cosmetic.** `readBlockType`
could not decode a concrete-ref block type, so the assembler interned a function signature instead —
which MANUFACTURED a type-section entry and made `(block (result (ref 1)))` valid in a module with
one type. Fix the gap; don't route around it. — R4, `known-issues.md`

**An encoding chosen to make EXECUTION agree can erase the distinction VALIDATION runs on.** A table
initializer was lowered to an equivalent element segment — identical table state, and no longer
distinguishable from a table that declares no starting value, which is exactly what the
defaultability rule tests. Ask what the encoding you picked throws away, not just what it preserves.
— R4, `roadmap.md`

**A tag added to one of two readers works in half the positions.** `exnref_nn` reached `types.zig`
and `readBlockType` but not `Module.readValType`, so `(ref exn)` round-tripped as a block type and
was `BadValType` everywhere else. When a type gains an encoding, grep for every reader of that
encoding. — R4, `known-issues.md`

**When a LANGUAGE KEYWORD forces you to rename one member of a set, check the whole set — the
renamed one is the one that breaks, and its siblings working is what hides it.** `Op.catch_` carries
its underscore only because `catch` is a Zig keyword, so `stringToEnum` could not find it by its
wasm spelling while `catch_all` resolved normally. A stray `catch_all` therefore reached the
validator and was rejected with a real verdict; a stray `catch` came back `UnknownInstr` and scored
as our own gap — **two spellings of one clause graded differently for the identical malformation.**
It was invisible for as long as it existed because the sibling worked. *(Same family as the
`@"unreachable"`/`@"if"` counting rule in §4, and the sharper form of it: a keyword workaround
changes BEHAVIOUR, not just greppability.)* — skip-scoring split, `testing.md`

**Three spellings of one list, and the two written by hand were the two that were wrong.**
`features.Feature` (the engine), `capi.Feature` (the C ABI) and `wazmrt_feature_t` (the shipped
header) all enumerate the same proposals. `capi.Feature` stopped at `exceptions = 13` with
`valid()` hardcoding `<= 13`, while the header *declared* `WAZMRT_FEATURE_TAIL_CALL = 14` — so
`set_feature(TAIL_CALL, false)` returned false and did nothing, while `all_features(false)`, which
counts with `features.count`, disabled it. **The header advertised a switch that was not there.**
Two fixes, and take both: **derive the bound instead of restating it** (`< features.count`), and
**pin the duplicates with a comptime check that compares NAMES AND VALUES, not just lengths** — two
lists of equal length can still disagree, and a value mismatch makes `@enumFromInt` gate a
*different* proposal than the caller selected. — F3, `roadmap.md`

**An error name that conflates "your input is bad" with "we are incomplete" cannot be scored
correctly by ANY caller.** `UnknownInstr` meant both "this mnemonic exists in no wasm proposal"
(a verdict we are entitled to give) and "this is from a proposal we do not target" (our gap, which
must not count as a pass), so the conformance runner had to treat every instance as our gap — and
292 correct rejections across CORE files were banked as skips. The distinction was knowable only at
the point of failure, never upstream. **Make the split where the information is, not in the code
that has to score it.** ⚠️ And note the asymmetry when you do: an omission from the
"we-are-incomplete" list is a FALSE PASS, not a missed one, so the list must be over-inclusive and
its guard is that the untargeted-proposal directories never gain passes. — skip-scoring split,
`testing.md`

**Fixing only the consumer rejects valid input.** Finality was thrown away by the decoder *and*
mis-emitted by the assembler; repairing the validator alone turned a silent accept into a loud reject
on modules that were fine. Check whether the mirror half exists before shipping either. —
`known-issues.md`

## 4. Tests and gates

**When you start REFUSING something, check which bucket the refusal lands in.** Closing the
`anyfunc` deviation looked like deleting one map entry. But `isRefType` also special-cased
`anyfunc`; dropping it there too would have sent `(table 4 anyfunc)` down the func-index path, where
`anyfunc` parses as a function NAME and fails as `UnknownIdentifier` — which `wast.zig` banks as OUR
limitation. The spec deviation would have reappeared as a SKIP and the baseline would have gone
green for the wrong reason. So `isRefType` still answers true, on purpose, to route the input to the
one function that knows why it is rejected. **A scoring system that sorts by error type turns "which
error do I return" into a correctness question** — and the new test pins all three syntactic
positions precisely because only one of them is what the spec file happens to use.
— `anyfunc` closure, 2026-08-17

**Price a compatibility affordance by what actually depends on it, not by its rationale.** `anyfunc`
was kept for two years of arguments about "real inputs that use it". The two files were in an
optional corpus that no `zig build` step gates — one grep, and the trade went from contested to
obvious. **Find the gate before you weigh the cost.** — `anyfunc` closure, 2026-08-17

**A gate that cannot pass is not a gate — and a gate that cannot fail is not one either.** Both
directions have bitten: `zig build conformance` once failed unconditionally (`design-decisions.md`),
while a feature-gating draft was wrong in the FALSE-POSITIVE direction and a symbol gate was
"demonstrated" by testing the wrong mechanism (`known-issues.md`).

**A new test that has never failed has not been shown to test anything.** Invert its assertion, watch
it fail, restore it. R1's `define_instance` test was confirmed this way; the path it covers had only a
symbol-existence entry before. — R1, `known-issues.md`

🔒 **FOR A SOUNDNESS RULE, WRITE THE WRONG ANSWER DOWN — the score cannot tell you the rule is
enforced, only that the files you looked at got better.** D1 had correct exactness arms in BOTH
`subtypeOf` and `headMatches`, and conformance reported 0 regressions and 7 improvements — and
`ref.test (ref (exact $super))` still answered **1** for a subtype, because the four cast
sub-opcodes read their target through a path that dropped the `exact` prefix. The corpus was blind
because those files were already failing for other reasons. **An assertion count would have shipped
type confusion.** Third time on this branch a soundness defect passed the whole corpus and was
found only by constructing the case: the host-externref/GC-index collision and the cross-instance
object substitution were the other two. **The test to write is not "does the feature work" but
"does the thing that must NOT match, not match" — plus its neighbours, so a blanket refusal cannot
pass for the right answer.** — D1, `roadmap.md`

**Implementing half a feature turns its false passes into visible failures — that is progress, not
regression.** Mid-D1 the count showed 18 LOST passes. None was real: those `assert_invalid`
assertions had been passing because the syntax could not be PARSED (`BadValType` is not on
`isOurLimitation`, so a parse gap scored as a correct rejection), and they only became honest once
the semantic half landed. **Before treating a pass-count drop as a regression, ask what those
assertions were passing ON.** — D1, `roadmap.md`

**When a test fails after your change, ask whether its EXAMPLE still demonstrates its PROPERTY
before you touch either.** R5's green-washing regression test failed on the skip-scoring split, and
it was right to: its example was `some.bogus.instruction`, chosen to stand for "a mnemonic our
assembler doesn't know" — which was never an instance of "our limitation" at all. **The property
was correct, the example had silently stopped matching it.** That example has now moved twice
(it began as `(module quote …)` itself, until R5 implemented that form) while the property never
changed once. The three outcomes are genuinely different and it is worth deciding which you are in:
the code is wrong, the property is wrong, or **the example drifted** — and the third is the one that
looks like the first. ⚠️ Fix it by keeping the property and re-picking the example, then **pin the
inverse case beside it**, so the pair can only pass if the distinction is actually being drawn.
— skip-scoring split, `wast.zig`

**Zig forces an unused parameter to be a compile error, so plumbing and its first consumer must land
in one commit** — which is also why an inversion test must assert the BUILD SUCCEEDED before reading
its silence (two of R9's eight reported no failing test because commenting the check out left a
parameter unused). Useful in the other direction too: it means a "thread this value through" step
cannot be landed as dead scaffolding. — F1/F4, `roadmap.md`

**A goal with no gate is a preference.** "Smallest binary" was a stated goal for a month with nothing
measuring it, and the artifacts doubled. — `design-decisions.md`

**A gate only gates the commits that RUN it — a gate with no trigger is a preference too.** The size
gate was built to stop silent drift, works correctly, and drift accrued anyway: by R2 the ceilings
were over by +22 KB exe / +24 KB lib / +19 KB dll, none of it R2's, left by commits that never
invoked `zig build size`. **Attribute an overshoot before paying for it** — measure the parent commit
in a worktree rather than assuming the growth is yours. R3 did exactly that and the answer came back
the other way: all of its +6 KB / +8 KB / +7 KB was its own. Both answers are only worth having
because the measurement was made. — R2/R3, `tools/size-ceilings.txt`

**A size gate reads whatever is in `zig-out`, including yesterday's artifact.** R3's first run showed
the DLL at *exactly* its ceiling — because `zig build` does not build the DLL, and the file on disk
was two builds old. A number that matches the ceiling to the byte is evidence of a stale file, not of
a change that cost nothing. Build every artifact you are about to report. — R3,
`tools/size-ceilings.txt`

**A gate's number must be REPRODUCIBLE IN THE CONFIGURATION IT WAS RECORDED IN — "what produced it"
includes WHERE.** `wazmrt.lib` measures 1,029,730 / 1,029,738 / 1,029,882 / 1,029,922 for one
unchanged commit, depending only on the source tree's path and the local cache path: the static
archive is unpadded and embeds object/source paths, while the `.exe` and `.dll` absorb the same
difference inside PE alignment and look perfectly stable. A clean HEAD read **+152 OVER** its
ceiling and nearly bought a bogus ceiling raise attributing bytes to a change that did not cause
them. **Before charging a sub-KB delta to your change, re-measure the parent in the same
configuration** — and treat a gate that reads "whatever is on disk" as needing to know the build
location too, not just the flags and the freshness. *(Third hole of this family, after the
stale-artifact trap above and the `-Dwat=false` false win in `tools/size-ceilings.txt`.)* — D:
build-blocker investigation, `tools/size-ceilings.txt`

**Guard the property, not a proxy for it.** — `design-decisions.md`

**A cache key must name everything the answer depends on.** — R1, `roadmap.md`

**Never green-wash our own gaps.** An unimplemented command form is *not* evidence a module is
invalid. `assert_invalid`, `assert_trap` and `assert_unlinkable` each need the "this is our
limitation" arm, or the conformance numbers count our holes as passes. — `wast.zig`
`isOurLimitation`, `known-issues.md`

⚠️ **REFINED 2026-08-17 — this rule used to say "or an unknown mnemonic", and that half was
costing 292 correct answers.** Conservatism is right when an error is genuinely ambiguous and wrong
when it only *looks* ambiguous: a mnemonic that exists in no wasm proposal is a malformation, and
refusing it is a verdict we are entitled to give. **Being conservative is not free — it is a claim
about our own ignorance, and that claim can be checked.** Check it before paying for it. (The
mechanism belongs upstream, at the point where the difference is known — see §3.)

**A well-argued entry in a baseline is still an entry.** The 8 era-pinned `proposals/threads`
failures carried the best reasoning in `conformance-baseline.txt` — *"that directory predates
multi-memory and multi-table, so the runtime is ahead of the file"*, which is **true** — and the
argument was so satisfying that nobody asked whether the RUNNER could simply be told which era to
judge by. It could, in about 40 lines. **An explanation for a failure is not a decision to keep
it**, and the better the explanation, the longer it will sit there unexamined. Re-read your
justified entries periodically, precisely because they are the ones nothing prompts you to revisit.
— F4, `roadmap.md`

**`git checkout <file>` to undo a probe discards EVERYTHING uncommitted in that file.** A one-line
measurement probe was reverted that way mid-D4 and it took the entire uncommitted D4 validation work
with it — silently, because the command succeeds either way. It surfaced minutes later as a
per-file conformance drop that read like a real regression, and cost a bisect to trace back to the
undo rather than to the code. **Undo a probe the way you made it (edit the line back), or commit
before probing.** A destructive command whose blast radius is "the file" is the wrong tool when your
intent is "the line". — D4, `roadmap.md`

**A harness that RECONSTRUCTS paths does not judge by the same rules as the real run.** The per-file
conformance harness copied each `.wast` into its own scratch directory to isolate it — which
stripped the `proposals/custom-descriptors` path segment that `wast.featuresForPath` keys the
proposal ERA on. Every descriptor file was then judged without the feature and reported ~120 skips,
which looked exactly like the implementation had broken. The full run had been correct throughout.
**When behaviour depends on a path, a harness that rewrites paths is not a smaller version of the
real run — it is a different run.** Reproduce the path structure, or use the real one. — D4,
`roadmap.md`

**A block typed at the TOP type accepts either branch shape, so a direction bug passes every
execution test.** `br_on_cast_desc_eq` and its `_fail` twin carry different types to the label — the
destination on a match, the source-minus-destination on a miss — but every test wrote
`(block (result anyref) …)`, which accepts both. Swapping which spelling fires on a match failed
nothing. **Type the block at the DISTINGUISHING type** (`(ref $a)` here) when the property under
test is which branch is taken. — D4, `roadmap.md`

**A stack-polymorphic `return` swallows a leftover operand, hiding a missing pop.** The same
`br_on_cast_desc_eq` tests all ended their block with `return`, so forgetting to consume the
descriptor operand — which makes the validator pop the DESCRIPTOR as the ref, leaving the real value
stranded — type-checked cleanly. **Balance the stack exactly when the property under test is operand
consumption**, or the polymorphic tail absorbs the bug. — D4, `roadmap.md`

**A proposal can RETYPE an instruction that already exists, not only add new ones — and an era model
built for "this snapshot LACKS feature X" cannot express that.** custom-descriptors relaxes
`br_on_cast`'s `rt2 <: rt1` requirement, so the identical module is `assert_invalid` in the core
testsuite and VALID in the proposal snapshot. Every prior era entry restricted a directory relative
to the merged spec; this one had to be **opt-IN by directory**, because the era that LACKS the
proposal is the merged spec — i.e. every other file. **Before assuming a proposal is additive, look
for an existing instruction whose typing it changes**; the corpus states it plainly by shipping the
same module twice with opposite verdicts. — D4, `roadmap.md`

**`git branch -d` checks against the branch's UPSTREAM, not against `main`.** A branch whose commits
reached the remote via a *different* branch is fully merged and still trips the guard — its message
says so exactly ("not merged to `refs/remotes/origin/X`, even though it is merged to HEAD") and is
easy to misread as "this has unmerged work". Reaching for `-D` skips the check entirely, which is
the wrong lesson to learn from a false alarm. **Delete the remote ref first**, so the fallback
comparison against `HEAD` becomes the meaningful one and the guard still protects you. — the
post-Track-D branch cleanup

## 5. Recording what you found

**"Update the project memory" means AUDIT for stale live claims, not edit the files you happened to
touch.** After a session that revised six `cmem` files, an audit found six stale claims still
standing — including **the `## 📊 CURRENT spec-testsuite score` heading in `testing.md`, the single
line most likely to be quoted, in a file that had just been edited twice.** The edits had gone to
the paragraphs the work reminded me of; the headline was never grepped for. ⚠️ Two numbers were
stale in BOTH directions and disagreed with each other — `INDEX.md` claimed 631 unit tests and
`overview.md` claimed 603, while the real figure measured **633**. **When two files disagree, do not
pick the newer one — measure.** The audit that works is a grep for the OLD VALUES
(`grep -rn "62,889\|90 fail\|953,344\|631/631" cmem/ README.md`), then classify every hit as live
(fix) or dated history (leave, and mark it superseded if it claims to be current). ⚠️ **Watch for
"final" and "the number to quote"** — both appeared on figures that were superseded within days, and
a superseded block that still says "the number to quote" is worse than no marker at all.
— memory audit, 2026-08-17

**A REFUSAL is not a hole — rank security work by what the gap PERMITS, not by the size of the
failing number.** Asked to close "the last 89 for security reasons", the honest split ran the other
way from the count: the 81 untargeted-proposal assertions are modules wazmrt *rejects*, and a module
that will not run cannot do harm, so implementing those proposals **adds** attack surface rather than
removing it. **A conformance total counts disagreements, not exposure; they are different axes and a
big number on one says nothing about the other.** Say so when scoping, then build what was asked.
— Tracks F/P/D scoping, 2026-08-17

🚨 **BEFORE SCOPING A TRACK, GREP FOR THE THING YOU ARE ABOUT TO BUILD.** The paragraph above
originally continued *"the real gap is that `validate()` takes no feature set, so no embedder can
run a restricted subset of the language"* — and **that was false when written.** Per-proposal
gating had shipped six days earlier: `wazmrt_config_set_feature` in the header, hard rejection in
both C-ABI module entry points, module structure *and* per-instruction coverage, a comptime
coverage pin, four passing tests. **The same file contradicted itself two sections up**, where its
own change-series table marks that step ✅. Track F was scoped as ~5 items of security work and was
~70% already built; the security argument for its *ordering* evaporated with it.

🎓 **This is the exact inverse of the memory64 and GC-P3 entries below — those recorded work as DONE
that was not; this recorded work as TODO that already was — and the root cause is identical: a
status line written from an ARGUMENT rather than from the code.** The argument was even a good one.
Both directions cost real time, and both are prevented by the same five-second habit: open the
file and grep before you write down what is missing. — Track F correction, `roadmap.md`

**When you implement a feature the project has already been burned by, name the prior bug in the
plan, not in the postmortem.** Track D's scope carries the two soundness defects this branch already
found (host-externref/GC-index collision; cross-instance GC object substitution) as explicit
checkpoints on D1 and D3, because descriptors re-create the exact conditions for both: a cast that
admits a subtype where the spec demands exact is type confusion, and a descriptor stored as a type
INDEX rather than an ENTITY is the same cross-instance bug a third time. ⚠️ **The cross-instance
defect passed the entire corpus before it was found by construction** — so those checkpoints demand
targeted wrong-answer tests, not an assertion count. **A green suite is evidence about the tests, not
about the code.** — Tracks F/P/D scoping, 2026-08-17

**A finding can be well-argued, land a real check, and still be INVENTING a requirement.** R10 deleted
a `br_table` cross-label subtype check whose reasoning was sound — `popVals` genuinely cannot catch a
mismatch on a polymorphic stack — and whose conclusion was wrong, because on a polymorphic stack
there is nothing to catch. Its comment claimed it "never rejects a valid subtyped `br_table`"; it
rejected the case the spec suite names `meet-bottom` and blacked out 161 assertions. **When the
corpus trips over a check you added, suspect the check** — and go to the spec's algorithm, not to the
finding's argument. — R10, `roadmap.md`

**A feature implemented for ONE of its two contexts reads as implemented.** `extern.convert_any` /
`any.convert_extern` existed in the constant-expression evaluator and nowhere else, so a function
BODY using one was `UnknownInstr` — five spec files open with such a module. When an instruction is
valid in both const-exprs and bodies, check both. — R10, `known-issues.md`

**Two encodings of one type must land on one value type, and the FAMILY is the part that bites.**
`nullexnref` was modelled as `nullref` (the any-family bottom) while `(ref.null noexn)` decoded to the
exn head, so a global declaring one and initialising with the other was a `TypeMismatch` against
itself. The disagreement is invisible until both spellings meet. — R10, `roadmap.md`

**Record findings that were WRONG, so they are not "fixed" again.** At least two audit findings have
been retracted after being verified false, and one carries an inline `Don't "fix" it again` comment at
the site. A retraction is as valuable as a finding. — `testing.md`, `roadmap.md`, `validate.zig`

**A retraction re-checks the REASONING; it does not re-check the REQUIREMENT.** The elem/table type
comparison in `validate.zig` carried exactly such a `Don't "fix" it again` note. The retraction was
right — the audit's claim about `ValType.nullable()` was false — and the rule was still wrong:
§3.5.11 wants subtyping, not nullability-erased equality. When a retraction says "the argument was
bad", that is not the same as "the code is correct"; go back to the spec, not to the argument. — R2,
`roadmap.md`

**Say which claims are live and which are as-triaged.** The R-list's per-item counts were accurate when
written and stale the moment R1 landed; they now say so explicitly rather than reading as current. —
`roadmap.md`

**Stale is stale in BOTH directions.** Five consecutive items were undercounts (R1 25→38, R2 35→44,
R3 10→16, R5 23→1,291), which trained "as-triaged" to read as "expect worse". R9 was filed at 85 and
measured 71, because R10 had closed some of its members as a side effect. The instruction is
re-measure, not pad. — R9, `roadmap.md`

**An inversion that does not COMPILE is indistinguishable from an inversion nothing caught.** Two of
R9's eight test inversions reported no failing test because commenting out the check left a function
parameter unused — a hard error in Zig — so the build never ran, and the "which tests failed" grep
matched nothing either way. Assert the build succeeded before reading an inversion's silence. — R9,
`testing.md`

**An inversion that catches NOTHING has three causes, and they need three different responses.**
Tracks D2–D4 hit all three, and telling them apart takes an argument, not a rerun:
1. **The arm is genuinely redundant** → *delete it.* D3 added a byte-range guard for three new
   opcode tags whose stated reason — "their immediate kind is one real ops also have" — was simply
   false; the kind switch already refused every `.gc_type` byte. **A redundant guard carrying a
   false justification is worse than no guard: it teaches the next reader the wrong rule.**
2. **The arm has a MIRROR that catches the case instead** → *keep both, and say so.* D2's rec-group
   and struct checks in `checkDescriptorLinks` each reported "not caught" alone and were caught as a
   PAIR — delete either on the strength of a green suite and the module is accepted the moment its
   mirror is touched.
3. **The arm defends a path the tests cannot reach** → *keep it and write down why.* D4's
   `descEqMatches` type check is subsumed by the descriptor-identity check for any VALIDATED module
   (a descriptor object belongs to exactly one described object), but it is real defence on the
   UNVALIDATED run path, where a hand-built module can pair any value with any descriptor.

⚠️ **The failure mode is treating all three as case 1.** "No test caught it" is a question, not a
verdict — the same shape as *finding a real defect at a layer is not evidence it causes your
symptom* (§2). — D2/D3/D4, `roadmap.md`

**A rule about a NAMESPACE belongs on the namespace, not on the writers.** Every wasm index space is
filled from two places — an import and a definition — and the uniqueness rule spans both, so a
per-append-site check structurally cannot see `(import "" "" (memory $foo 1))` beside
`(memory $foo 1)`. One pass over each finished space caught all sixteen. — R9, `wat.zig`

**When a front end is shared with the test harness, tightening it tightens the harness.** R9's
`reserved`-token rule was correct for modules and turned an entire `.wast` file into a runner error,
because the script and the modules inside it go through one lexer. Budget for that: the fix pulled a
separately-filed item into the same pass. — R9, `text-toolchain.md`

**A DOC COMMENT'S SUBJECT IS NOT THE FIELD'S NAME — READ THE STRUCT, NOT THE PROSE ABOVE IT.**
Advice sent to the wasmrt team named `Pools.type_canon` as their store-wide type registry. No such
field exists: the registry is `Pools.types`, and `Module::type_canon` is a per-Module `Vec<u32>` that
cannot answer a cross-module question — the very thing the reported bug was about. The name was
lifted from the first line of `TypeRegistry`'s doc comment, which *contrasts itself against*
`type_canon`. **Advice with a wrong mechanism is worse than no advice**, because the recipient has to
disprove it. — the GC report, `wasmrt/cmem/known-issues.md`

⚠️ **THAT WAS THE THIRD READ-NOT-VERIFY ERROR IN ONE SESSION**, and the pattern is the lesson: a CLI's
`valid wasm v1` header read as a verdict; a benchmark's missing `--` read as a competitor's defect;
a comment's subject read as a field name. **Each was cheap to check and expensive to propagate.**
When a claim will leave this repo — a commit message, a cross-project report, a number in a README —
verify it against the artifact, not against something that talks about the artifact.

**SCORE THE SAME ERROR THE SAME WAY ON EVERY PATH.** `isOurLimitation` decided that a gap of ours is
a SKIP, not a pass — but the bare `(module …)` arm never called it, so the identical error was a skip
on an assertion path and a *defect* on that one. 14 of a reported 104 "failures" were that
inconsistency. **A classification rule that one call site does not consult is a rule with an
exception nobody wrote down.** — the scoring fix, `wast.zig`

**"BY DESIGN" IS NOT "PASS", AND IT IS NOT "FAIL" EITHER.** A module we cannot build because we do
not implement its proposal proves nothing about correctness — calling it a pass is the green-washing
`isOurLimitation` exists to prevent — but calling it a failure overstates the defect count by an
order of magnitude. It is a refusal, and it belongs in an EXPLAINED baseline that gates on
regressions. ⚠️ **A baseline is only honest if every line carries a reason**; otherwise it is a way to
make a red number green, and adding a line to pass the build is the failure mode it invites. —
`tools/conformance-baseline.txt`

**A BENCHMARK WHOSE FLOOR IS LARGER THAN ITS SIGNAL MEASURES THE FLOOR.** The end-to-end CLI harness
put wazmrt 2.4× ahead of wasmtime. With process spawn excluded, the engines differ by **20–55×**. A
~30 ms floor did not add noise to a sub-millisecond quantity — it *hid the entire effect*, and it
also flattened a real size dependence into "nothing moves". **The same measurement can be right about
what it measures and wrong about what you conclude from it.** Take the floor out before reading a
difference as a property of the thing you care about. — Track 3, `roadmap.md`

**MEASURE THE FLOOR BEFORE ATTRIBUTING A DIFFERENCE.** wazmrt beat wasmtime by ~50 ms end to end, and
banking that as engine speed would have been natural. `--version` — no wasm work at all — costs
30 ms vs 76 ms, so ~46 ms of the gap exists before either engine starts; the whole wasm pipeline on a
2 MB module is under 3 ms. The advantage is real and is mostly *binary load time*. A benchmark that
does not measure its own floor cannot tell you which component it measured. — Track 3, `roadmap.md`

**A RECORDED PREDICTION THAT THE MEASUREMENT REFUTES IS WORTH MORE THAN ONE QUIETLY DELETED.** The
roadmap predicted a large module would widen wazmrt's startup lead over Cranelift. A 210× size ladder
(9 KB → 1.97 MB) showed the opposite: nothing moves, so the advantage is FLAT in module size, not
growing. The narrower claim is the more robust one. The struck text stays in place beside the
measurement. — Track 3, `roadmap.md`

**A RATIO CAN BE LOAD-DEPENDENT WHILE THE DIFFERENCE IS NOT.** The same benchmark gave 5.3× on a
quiet machine and 2.4× on a loaded one, because a fixed per-process cost shared by every entrant
inflates both sides and compresses the ratio — while the absolute gap stayed ~29–48 ms. Quote the
difference, or quote the ratio with the load conditions attached. — Track 3, `roadmap.md`

**A DIFFERENTIAL CHECK WITH NO PRIVILEGED ORACLE FINDS THINGS A GOLDEN FILE CANNOT.** The bake-off's
`start` mode requires every runtime to agree rather than trusting one, and found a one-byte
disagreement on its first run: five implementations including V8 against wasmtime 47.0.3. ⚠️ And the
discipline continues past the finding — **the cause was not traced, so it is recorded as an
observation, not a diagnosis**. — `tests/differential/README.md`

**SEQUENTIAL A/B ON A LOADED MACHINE IS NOT A MEASUREMENT — INTERLEAVE, OR DO NOT COMPARE.** The
type registry appeared to cost +40% startup (6.88 → 9.60 ms median) against a baseline taken an hour
earlier. Three repeats with **no code change** then climbed 9.60 → 10.65 → 11.49 → 12.90: the box was
degrading under sustained build load, not the code. An interleaved A/B of two binaries in one
session — 60 alternating pairs — put the real delta at **+0.01 ms median**, i.e. nothing. The false
reading was about to reverse a correct design decision. **The absolute numbers drifted 2×; only the
interleaved difference was meaningful.** — the type registry, `size-ceilings.txt`

**WHEN AN INVARIANT IS WRITTEN DOWN, ENUMERATE EVERY VALUE KIND IT GOVERNS IN THE SAME PASS.** R2
established "a reference value names an ENTITY, not an index" and converted `funcref` only. GC heap
references kept the old encoding and had the identical cross-instance defect, found a day later —
same shape, same blind check reading the same wrong table. The value space had five kinds; three
were made safe one at a time, each after its own incident. **The generalisation is the same one as
"THREE OF THE FOUR do X": write the table, then fix the row.** — the GC entity fix,
`design-decisions.md`

**A BENCHMARK THAT MIS-INVOKES A COMPETITOR REPORTS THAT COMPETITOR AS BROKEN.** The bake-off's first
run disqualified wasmer for a wrong answer; the cause was a missing `--` in the harness, so a
negative argument parsed as a flag. It was indistinguishable from a real defect. Check a
disqualification against a hand-run before believing it — an audit finding is a hypothesis, and so is
a benchmark's verdict on someone else's tool. — Track 3, `bakeoff.mjs`

**APPLYING A FAIRNESS RULE IS WHAT MAKES A NUMBER QUOTABLE.** wasmtime was measured in both
fast-start configurations as well as its default; all three landed within 2%, so the 5.4× result is
not the "beat a runtime in its slowest setting" claim the rule exists to forbid. Had the rule been
skipped, the same number would have been worthless the moment anyone checked — the exact fate of the
falsified wasm-c-api payoff. **A constraint that survives its own test strengthens the claim.** —
Track 3, `roadmap.md`

**SAY WHICH REGIME A PERFORMANCE NUMBER BELONGS TO, IN THE SAME BREATH.** End-to-end process
wall-clock, in-process decode time and steady-state throughput are three different claims, and a
runtime can win one while losing another (a JIT wins hot loops; this project wins invocations). The
bake-off prints its own scope next to its table for that reason. — Track 3, `bakeoff.mjs`

**RANK SIZE LEVERS BY MEASUREMENT, NOT BY WHICH ONE IS EASIER TO PICTURE.** Track 2c was written up
naming `-Dwat=false` first for months; measured, WASI is the bigger half by 3× (−52% vs −16% of the
DLL), because `wasi.zig` drags in `std.Io` and `Io.Threaded` while the assembler is mostly its own
code. Same rule as ranking conformance items by assertions unblocked rather than failures closed. —
Track 2c, `roadmap.md`

**A COMPTIME GATE ROTS IN THE CONFIGURATION NOTHING COMPILES.** The default build cannot notice an
ungated `root.wasi.…` reference, because the flag is only false somewhere nobody builds. `zig build
features` compiles all four combinations for that reason, and caught six unguarded sites the first
time it ran. And the guard has to be `if (comptime …)`: a run-time-only check leaves the gated code
REFERENCED, so it links in and the flag gates nothing. — Track 2c, `build.zig`

**A GATE THAT MEASURES "WHATEVER IS ON DISK" NEEDS TO KNOW WHAT PRODUCED IT.** `zig-out` has no
record of build flags, so the size gate graded a feature-stripped DLL against the full build's
ceiling and reported it 607 KB *under* — a false win that invites lowering the ceiling and
mis-recording the real size for good. The gate now takes the feature string and refuses anything but
the full configuration, exactly as it already did for the optimize mode. — Track 2c, `size_gate.zig`

**A BOTTOM TYPE IS NOT ITS TOP, and folding it there is self-consistent right up to the moment
something asks.** `nullfuncref` was folded onto `funcref` on the reasoning that "only null inhabits
it, so the distinction is unobservable". It is observable exactly where it matters: a bottom sits
below its hierarchy's CONCRETE types, and the fold removes that. The companion check —
`subtypeOf`'s concrete-target arm — was a flat `== .none`, which *with* the fold in place was
consistent and wrong in two directions at once. **Two rules that must agree should key off one
shared function** (here `top()`), never off two hand-written lists. — the lattice, `roadmap.md`

**A FAILURE DIFF CANNOT SEE A PASS THAT BECAME A SKIP.** A per-file comparison of the failure list
showed nothing while two passes silently turned into skips; only the three totals caught it. Read
passed/failed/skipped together on every run — "quote all three or none" is a DETECTION rule, not
just a reporting one. — the lattice, `testing.md`

**READ THE TOOL'S VERDICT LINE, NOT THE HEADER ABOVE IT.** `wazmrt <module>` prints
`valid wasm v1, N section(s)` — a statement about STRUCTURE — and then, several lines later,
`validation: FAILED …`. Mistaking the first for the second produced a "fix" for a non-existent
accept-invalid, which then broke a legal spelling. *An audit finding is a hypothesis* — and so is
your reading of your own tool's output. — the lattice, `roadmap.md`

**A CLAUSE RULE BELONGS IN THE VALIDATOR, NOT THE PRODUCER.** The validator is reached by both the
text and the binary path; a filter in the assembler covers one of them and can break a legal
spelling on it (`catch_all` is genuinely a mnemonic in flat legacy `try … catch_all … end`). — the
lattice, `wat.zig`

**TWO KINDS OF VALUE MUST NOT SHARE ONE ENCODING SPACE — and the one that bites is the one an
outsider chooses.** A host `externref` was a bare small integer and so was a GC heap index;
`any.convert_extern` is identity, so `ref.cast` read a host reference as `gc_heap[i]` and
`struct.get` returned its fields. The runtime already tagged i31 (bit 63) and biased funcrefs by one
"so slot 0 is not the integer 0 (which a host could plausibly hand us)" — the same reasoning,
applied to two of three spaces. **When you tag one value kind to keep it distinct, enumerate all of
them.** — S1, `interp.zig`

**A remainder that looks like an unstructured tail is usually a handful of causes.** The 18 "core
singletons" left after the R-list were SIX, and two of them accounted for 16. Triage before
believing a count, and before deciding an item is not worth a pass. — the singleton batch,
`roadmap.md`

**One cause wears several failure messages, and some of them name a different subject.** L1's
declared-vs-live import limit produced two `IncompatibleImportType` failures and two
`UnresolvedImport` failures — the latter on *later modules* that could not link because the module
that would have exported to them never registered. A failure list is not a cause list. — the
singleton batch, `roadmap.md`

**An item named after a directory gets triaged as if the directory were the cause.** R7 was called
"threads" and its entry blamed shared-memory import matching. Zero of its fifteen failures were a
threads defect: the matching had been correct since memory64, the runner just had no
`spectest.shared_memory` to import, and the rest were two legacy TEXT spellings and eight assertions
that are by design. Read the failures, not the folder name. — R7, `roadmap.md`

**A proposal directory asserts the rules of ITS OWN ERA, so a failure there can mean the runtime is
ahead of the file.** `proposals/threads` is pinned to a spec before multi-memory and multi-table and
therefore fails on wazmrt *accepting* modules it calls invalid. Eight such assertions were carried as
actionable. The decisive check is whether the main suite makes the same assertion — it does not. —
R7, `testing.md`

**A dropped token in a list of STRINGS is silent; the same token in a list of INDICES is loud.** The
identical legacy grammar gap hit `(data 0 …)` and `(elem 0 …)`. The elem one errored at a resolver
and was obvious; the data one changed the segment's MODE — active in the source, passive in the
binary — and nothing complained. The silent `else => {}` arm is what hid it, not the missing rule. —
R7, `wat.zig`

**A rule implemented for one of the places it applies reads, from the code, as implemented.** R10
found `extern.convert_any` living only in const-exprs; R9 found the same shape one level up — the
"an inline signature must match its `(type $x)`" check existed for tags alone, since 2026-07-27,
while funcs, block types and both `call_indirect` forms silently ignored theirs. Grep for the
sibling contexts before believing a rule is in force. — R9/R10, `roadmap.md`

**A stated BENEFIT is a hypothesis about someone else's code** — verify it against the code, not the
docs, before adopting anything. — `design-decisions.md`, the adoption checklist in
`third_party/LICENSES.md`

**Prefer a hard abort to a silent stub.** Unhandled input that emits a placeholder instead of erroring
is the worst failure mode in this codebase's taxonomy — and a disabled proposal must be rejected
loudly, never silently ignored. — the audit trigger, `INDEX.md`
