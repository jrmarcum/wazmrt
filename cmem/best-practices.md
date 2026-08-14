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

**Guard the property, not a proxy for it.** — `design-decisions.md`

**A cache key must name everything the answer depends on.** — R1, `roadmap.md`

**Never green-wash our own gaps.** An unimplemented command form or an unknown mnemonic is *not*
evidence a module is invalid. `assert_invalid`, `assert_trap` and `assert_unlinkable` each need the
"this is our limitation" arm, or the conformance numbers count our holes as passes. — `wast.zig`
`isOurLimitation`, `known-issues.md`

## 5. Recording what you found

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

**A rule about a NAMESPACE belongs on the namespace, not on the writers.** Every wasm index space is
filled from two places — an import and a definition — and the uniqueness rule spans both, so a
per-append-site check structurally cannot see `(import "" "" (memory $foo 1))` beside
`(memory $foo 1)`. One pass over each finished space caught all sixteen. — R9, `wat.zig`

**When a front end is shared with the test harness, tightening it tightens the harness.** R9's
`reserved`-token rule was correct for modules and turned an entire `.wast` file into a runner error,
because the script and the modules inside it go through one lexer. Budget for that: the fix pulled a
separately-filed item into the same pass. — R9, `text-toolchain.md`

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
