# interop.md — the **wasmrt ⇄ wazmrt swappability contract**

**CONTRACT VERSION: 20 — wazmrt LEADS (owner, 2026-08-19).** wazmrt is finishing its hardening stage and **its copy is the latest**; wasmrt mirrors from it and **does not originate version numbers** until wasmrt reaches the same stage. ✅ **THE 2026-09-19 OWNER DECISIONS ARE FOLDED IN AND NUMBERED HERE** — **§2.4a as v11**, **§2.5 as v12**, wasmrt's **§2.3m annex as v13** (the §2.3 Z1 row, and row 3 promoted to ✅ AGREED), 🔒 **the owner's NO-"LOOKS LIKE" clarification as v14 (§2.4a-i)**, and 🔒 **the owner's same-day NARROWING of §2.4a as v15** (after the module path a single-dash token is the guest's). ⚠️ **v14 puts §2.2's `--dir` drive-letter fallback in tension and needs an owner ruling (§5 #10).** 🆕 **v16 adds §2.4b: a flag with a REQUIRED position, written where it cannot apply, is an error** — and wazmrt has **shipped** it. 🆕 **v17–v20 fold in wasmrt's T9e + T9i (2026-09-19):** **v17** Z4, `.wat` pin digests are not portable and the cause is the `name` section · **v18** the pin DB path is DECIDED (§3.3), closing §5 #1 · **v19** §3.7a is CLOSED, verified by running both, closing §5 #5 · **v20** §2.1/§2.2 convergence — wasmrt's column is green and wazmrt's halves are what remain. ⚠️⚠️ **v20 also carries a NEW wazmrt defect this pass found by running: `--dir .:/` — the example wazmrt's own `--help` prints — DOES NOT WORK**, and the cause is the drive-letter heuristic already flagged at §5 #10. 🚨 **v15 exists because §1c happened again while this very pass was running** — both sessions edited their own copies within the same hour; see the v15 change-log row. 📎 **The annexes themselves (§2.1m, §2.3m) stay where they are** — they are the measured *evidence*, and folding never means deleting the measurement that bought the row. ⏳ **wasmrt's copy is therefore at 10 and BEHIND — PENDING MIRROR**, which §1a says the owner directs and wasmrt makes in its own tree · opened 2026-08-19 (owner) · last change 2026-09-19 · **this file must be kept IDENTICAL
in both repos**, each side editing ONLY its own copy (§1a) (`wasmrt/cmem/interop.md` and `wazmrt/cmem/interop.md`).

> *"I think this may require a common memory md file in both projects to confer with each other on from
> this point further so that both projects are on the same end track."* — owner, 2026-08-19

This is the **only** document either project may treat as binding on the other. Everything else in
either `cmem/` is that project's own memory, and 🔒 **the oracle is still retired**: neither runtime is
authoritative over the other's design, and reading a competitor's implementation for guidance remains
off-limits. What lives here is a **contract about observable behaviour**, agreed by the owner, that both
must satisfy so a deployment can swap one binary for the other.

---

## 0. Scope — what "swappable" means

🔒 **Defined by the owner, 2026-08-19:** *"If our CLI options are the same they are swappable. If our
security checks are the same they are also swappable."*

**IN scope — must match:**

1. **CLI options** — run modes, flag names, argument shapes, defaults, exit codes.
2. **Security checks** — the pin/verification mechanism and its on-disk artifacts, the WASI sandbox
   rights model, and the resource ceilings.

**OUT of scope — deliberately NOT aligned:**

- **The C ABI.** `wasmrt_*` and `wazmrt_*` symbol prefixes are a recorded deliberate decision in both
  projects. An **operator** swaps the binary and the pin DB; an **embedder** links one or the other and
  is not expected to relink blind.
- **Internal design** — data models, IR, allocation strategy, crate/module layout.
- **Performance and size.** These are what the two are *competing on*; aligning them would defeat the
  purpose. A contract row must never be justified by "the other one is faster".
- **Conformance internals** — each project's own test harness, scoring and baselines.
- **Output text** — wording, layout and summaries, **with the ONE exception the owner made on
  2026-09-19: §2.5.** A validity claim a human reads must match the verdict. That is a
  correctness property, not a matter of style, so it is in scope. Everything else a command prints
  remains out of scope.

---

## 1. The change protocol — read this before editing

🤝 **The one-word order is "coordinate" (owner, 2026-08-19), and it is a BINDING TRIGGER in both
projects' `INDEX.md`.** Saying it means: run the procedure below and in that trigger — read this file
first, byte-compare the two copies, verify rows by **running** both rather than reading either, record
status + date + evidence, and bump the CONTRACT VERSION **in your own copy**. ⚠️ **It also binds in the
inverse direction, which is the half that gets skipped: coordinate BEFORE shipping a change to a
contract surface** — any CLI option, any security check, any resource ceiling, any exit code — **not
after**.

#### 🗓️ The coordination CADENCE and who holds the pen (owner, 2026-08-19)

> *"The wazmrt project is toward the end of the hardening phase. Theirs is the latest version. We will
> coordinate with them until this project also reaches that stage. Then both projects will cross
> coordinate at the end of each additional stage."*

**Two regimes, and which one applies depends on whether the projects are level.**

| regime | when | who originates | wasmrt's job |
| --- | --- | --- | --- |
| **A — wazmrt LEADS** | now, and until wasmrt finishes **hardening** (T9 → `1.0.1`) | **wazmrt only** | **mirror from them**, contribute findings as an **annex**, never originate a version number |
| **B — CROSS-COORDINATE** | once both have finished hardening | either, symmetrically | coordinate **at the end of each stage**, not continuously |

⚠️ **Regime A is not deference about design — it is about the PEN.** wazmrt is ahead by stage, so it
holds the contract's version sequence. wasmrt still measures, still objects, and still reports
divergences; it simply does not bump the number. **A finding is contributed as an annex and folded in
by whoever holds the pen** — which is how §2.1m's five measured findings are carried today.

⚠️⚠️ **Regime B is a GATE AT A STAGE BOUNDARY, not a background activity.** The stages are the `1.0.x`
ladder — clear-out, hardening, bug hunt, optimization, security review. **Coordinate at the end of
each**, so the contract is reconciled against code that has stopped moving. Coordinating mid-stage is
what produced **three mid-edit collisions in a single session on 2026-08-19**, each one two agents
writing the same file at the same moment.

🎓 **The lesson that cadence encodes, and it is the one this file kept re-learning the hard way: a
CONTRACT VERSION is a PIN, not a LOCK.** It makes drift *detectable*; it does nothing to prevent a
simultaneous write. **The fix is not a better marker — it is not writing at the same time.** One pen
while the projects are uneven, and a scheduled boundary once they are level.

**Where wasmrt is against that ladder:** `1.0.0` (the conformance clear-out, T13) is not started;
hardening is `1.0.1` and carries `pin`/T9e and the iteration budget/T9i. **So regime A holds for at
least the next two stages.**

### 1a. 🔒🔒 THE EDITING BOUNDARY — **ABSOLUTE** (owner, 2026-08-19)

> *"Let's place a note to not edit the other's md file unless specifically directed by me. This is just
> a coordination effort. Each project needs to edit their own files. This is important for tracking and
> integrity."* — owner

🚫 **NEITHER PROJECT WRITES ANYTHING INTO THE OTHER'S TREE. NOT THEIR `cmem/`, NOT THEIR SOURCE, NOT
THEIR TESTS — AND NOT THEIR COPY OF THIS FILE.** The only exception is an **explicit, specific
direction from the owner**, given for that edit. There is no standing permission, and `coordinate` does
**not** grant one — ⚠️ **`coordinate` is an order to CONFER, never a licence to WRITE.**

**This supersedes the earlier rule that made this file the one thing either side could write into the
other's tree.** It was wrong, and it was wrong in a way that had already caused damage twice in one
day: a blind copy destroyed a section of in-flight work, and the reconciliation destroyed another
(change-log rows 3b and 4). 🎓 **The reason is integrity of the record, not politeness — each repo's
history must show only what that repo's own agent did.** A commit in wasmrt authored by whoever was
working in wazmrt makes the history a bad witness, and *the history is the thing both projects fall
back on when a claim is disputed.*

### So how does a change reach both copies?

**By the owner, not by an agent.** The proposing side does all of this **in its own copy only**:

1. Write the change, bump the **CONTRACT VERSION**, and add a change-log row.
2. Mark the affected rows and the change-log entry **⏳ PENDING MIRROR** — meaning *agreed on this
   side, not yet carried across.*
3. **Tell the owner explicitly** that the sibling's copy is behind, and at which version.
4. The owner directs the other project to mirror it — and **that project makes the edit in its own
   tree**, which is what keeps its history honest.

⚠️ **A VERSION MISMATCH IS THEREFORE NORMAL NOW, AND IT MEANS SOMETHING PRECISE.** §1's drift rule
still holds — *a mismatch means the contract is unknown* — but the resolution is **never** "copy over
it". It is: **read both, report the delta and its direction to the owner, and wait to be directed.**
The mismatch is the coordination signal working, not a fault to be cleaned up unilaterally.

⚠️ **Reading the sibling's tree remains fine and is required by `coordinate`** — read their `cmem/`,
their in-flight uncommitted work, their source; run their binary. 🔒 **Read freely, write never.**
*(This does not reopen the retired oracle: reading their code for DESIGN GUIDANCE is still off-limits.
Reading it to check a CONTRACT ROW is what this file is for.)*


1. **Neither project edits this file unilaterally.** A change is *proposed* in one repo — **in that
   repo's own copy only** — with a **CONTRACT VERSION** bump, and must be agreed and mirrored before
   either ships behaviour that depends on it. ⚠️ **The proposing agent does NOT carry it across**; the
   owner directs the other project, which makes the edit in its own tree (see the editing boundary
   above). *Superseded the original wording, which told one agent to "land the identical file in both
   repos" — that instruction is what produced two destructive overwrites on 2026-08-19.*
2. **Every row carries a status and a date.** ✅ AGREED (with the evidence that verified it) ·
   ⚠️ DIVERGENT (with the agreed resolution) · ⬜ UNVERIFIED (nobody has checked; **do not quote it**).
3. **Every accepted divergence carries a REOPEN CONDITION.** *An entry that loses its condition has
   become an excuse* — and a condition that is never re-tested is an excuse more slowly, so **re-test it
   whenever the entry is priced.**
4. **A row is verified by RUNNING both, not by reading either.** *When a claim will leave this repo,
   verify it against the artifact, not against something that talks about the artifact.*

⚠️⚠️ **THE DRIFT HAZARD, NAMED UP FRONT.** This file exists **twice**, and *a list written out a second
time is a list that will drift* — the projects have already been bitten by exactly this shape (a feature
list spelled three times; a header advertising a switch that was not there). Two repos cannot share one
file, so the pin is the **CONTRACT VERSION** plus rule 1. **The gate:** when both trees are present, a
check compares the two copies byte-for-byte and fails on any difference. Until that check exists, treat
a version mismatch between the copies as **the contract being unknown**, not as "close enough".


### 1b. What `coordinate` obliges, in order — ✅ **§0.5 RESTORED HERE (wazmrt, 2026-08-19)**

🚩 **This discharges the flag in change-log row 3b.** wasmrt's `cp` destroyed wazmrt's in-flight §0.5
before it reached either copy, and wazmrt's session context was the only place it survived. ⚠️ **It is
NOT restored as a verbatim §0.5, and that is deliberate:** three of its four parts have since been
re-expressed *better* — the order's definition in §1 above, and the editing boundary in §1a, which the
owner has since made **absolute** and which is therefore stronger than the version §0.5 was
introducing. **Re-pasting the section would leave two definitions of one order in one file, which is
precisely the "a list written out a second time is a list that will drift" failure this file exists to
prevent.** What follows is the part that was genuinely lost: the ordered checklist, and the clause
about invoking the order late.

1. **Byte-compare the two copies of this file** (§4 check 1). A mismatch means **the contract is
   unknown** — but see §1a: resolve it by **reporting**, never by writing to the other tree.
2. **Read the sibling's in-flight work** — its `cmem/roadmap.md`, `cmem/INDEX.md` and **uncommitted**
   changes — for anything touching §2 (CLI options) or §3 (security checks). ⚠️ **The sibling may
   already have written a task that cites a contract row THAT DOES NOT EXIST YET; that is a cue to
   write the row, not a discrepancy to report.** *(Not hypothetical: wasmrt's T9i cited "§3.7/§3.7a,
   CONTRACT VERSION 2" while this file was still at version 1 and had no such row.)*
3. **Diff what this project has shipped or is about to ship against every in-scope row**, and
   ⚠️ **verify by RUNNING both binaries on the SAME BYTES** (rule 4) — never by reading either
   implementation.
4. **Record the change in your OWN copy**, bump the CONTRACT VERSION, mark it ⏳ PENDING MIRROR, and
   **tell the owner the sibling is behind and at which version** (§1a).
5. **Report divergences with a reopen/close condition**, and record **where each side tracks the
   work**, so the two task lists can find each other.

⚠️ **`coordinate` is also the right response to discovering you have ALREADY diverged.** The order was
created the day wazmrt shipped an execution bound while this file still said neither project had one.
**Invoking it late is far better than not invoking it** — the drift is cheap to create and expensive to
find, and the correction is recorded rather than tidied away.

### 1c. 🚦 TWO SESSIONS ON ONE FILE IS A KNOWN FAILURE MODE (raised by wasmrt, 2026-08-19)

**wasmrt's diagnosis, and it is exactly right:** *"a version is a pin, not a lock — it makes drift
detectable, it does nothing to prevent a simultaneous write."* Both collisions on 2026-08-19 happened
because two sessions were editing this contract at the same moment; the CONTRACT VERSION told us
afterwards, which is not the same as preventing it.

**§1a removes the cross-tree half of that risk by construction** — neither side can now write into the
other's copy at all, so a simultaneous write can no longer destroy the other project's work. ⚠️ **What
it does NOT remove is two sessions editing the SAME copy** (two agents in one repo), where last-write
still wins and nothing detects it.

🚦 **Recommended to the owner, as wasmrt proposed: run coordination in ONE session at a time.** The
cheap discipline that makes the residual risk near-zero: when a `coordinate` pass is in flight in one
repo, do not run one in the other until it has reported.
---

### 1d. 🗓️ COORDINATION CADENCE — at the END of each track (owner, 2026-08-19)

🔒 **Decided by the owner.** Cross-project coordination runs **at the end of each track**, not
continuously and not mid-track.

| phase | what happens |
| --- | --- |
| **during a track** | build and gate normally; **do not** open a coordination pass. If the work touches an in-scope surface (§0), note it and carry it to the end-of-track pass |
| **end of a track** | run `coordinate` in full (§1b): compare copies, read the sibling's in-flight work, diff every in-scope row, **verify by running both on the same bytes**, record in your own copy, report to the owner |
| **then** | **pause and wait for the sibling to reach the same point.** The project that is ahead holds |

**Why end-of-track and not continuous:** a track is the unit that produces a *finished, gated* change,
and §1 rule 4 says a row is verified by **running both** — which needs something built and green to run.
Coordinating mid-track compares one settled implementation against one that is still moving, which
produces rows that have to be re-verified anyway.

⚠️ **This does NOT weaken the "coordinate BEFORE shipping a contract surface" rule in §1.** The two fit
together: *decide* a contract-surface change before building it, then *verify and record* it at the end
of the track. **H3 violated the first half** — it was built while §3.7 still said neither project had a
bound — and the end-of-track pass is what caught it. **Both halves are needed; neither replaces the
other.**

🎯 **Current application (2026-08-19):** wazmrt finishes **Track H**, then **holds**. wasmrt coordinates
up to that same point. Cross-coordination resumes when both are at a track boundary. ⚠️ **While wazmrt
holds, its `1.0.1` is not "late" — waiting is the plan**, and a version that sits still because the
sibling is catching up is the cadence working, not a stall.

## 2. The CLI contract

🔒 **SETTLED 2026-08-19 (owner) — RESTORED 2026-08-19 after a concurrent-edit collision dropped it.**
**The two executables keep their own names — `wasmrt` and `wazmrt` — and that is the ONLY permitted
difference. Everything after the program name must be in sync.**

> *"The program will each be named separately wasmrt/wazmrt. That does not change. It is the CLI options
> that need to be in sync."*

**So there is nothing to decide about who adopts whose spelling — both adopt both.** The working test of
this whole section: **take any invocation, change only the program name, and it must do the same thing
under the other runtime.** That is what makes the tables below a specification rather than a survey, and
it is why §2.1's run modes are in scope alongside §2.2's flags — a command line is not portable if only
its flags are.

### 2.1 Run modes

wazmrt dispatches on the file extension and on whether an export was named; wasmrt uses explicit
subcommands. **The agreed target is ADDITIVE: each accepts the other's spelling, and neither loses the
form it already ships.**

| capability | wazmrt spelling | wasmrt spelling | status |
| --- | --- | --- | --- |
| summarize + validate, no execution | `wazmrt <module>` | `wasmrt <file>` | ✅ **AGREED on behaviour + exit code (both `rc=0`, neither executes) — ⚠️ MEASURED 2026-08-19, the OUTPUT TEXT differs.** *(The row read "already identical", which was written from reading and is false as stated.)* |
| call an exported function | `wazmrt <module> <export> [args…]` | `wasmrt run <file> <fn> [args…]` | ⚠️⚠️ **MEASURED — and the two gaps fail in OPPOSITE directions. See F1.** |
| run a WASI `_start` command | `wazmrt <module> [flags] [-- argv]` | `wasmrt wasi [flags] <file> […]` | ⚠️ **each must accept both** |
| run a `.wast` spec script | `wazmrt <script.wast>` | `wasmrt wast <file\|dir>… [-v]` | ⚠️ **each must accept both** |
| assemble `.wat` → `.wasm` | *(absent)* | `wasmrt wat <file.wat> [-o out]` | ⚠️ **wazmrt must grow it** |
| pin a module for the DB | `wazmrt pin <file\|dir> [--db <path>]` | *(absent — `pin` is a stub)* | ⚠️ **wasmrt must grow it** |
| keypair / signing tools | `wazmrt keygen`, `wazmrt sign` | *(design-only)* | ⬜ **deferred** — reopen when either ships signatures |
| `-h`/`--help`, `-v`/`--version` | **first argument only** | **first argument only** | ✅ **AGREED** |

⚠️⚠️ **ALIGNING THE RUN MODES CHANGES WHAT A BARE PATH DOES, AND IT IS A SECURITY-POSTURE CHANGE.**
wazmrt's `will_execute` predicate is *"an export was named **or** the module exports `_start`"*, so
`wazmrt prog.wasm` **runs** a WASI command — while `wasmrt prog.wasm` today **summarizes** it. Adopting
the predicate means the most casual invocation there is starts **executing** code where it previously
only inspected it. 🔒 **The verification gate must land before, or with, that change — never after.**


#### ✅ 2.1z — **wasmrt's COLUMN IS GREEN (T9e, 2026-09-19); wazmrt's halves are what remain** · v20

✅ **Verified by running wasmrt's committed code** (built from `51254b9cf` into the pen-holder's own
scratch target dir, so nothing was written to wasmrt's tree — §1a):

| capability | verified |
| --- | --- |
| `wasmrt <module> <export> [args…]` | ✅ `valid.wasm add 2 3` → **`5`**, rc 0 |
| `wasmrt <script.wast>` by extension | ✅ `1 passed, 0 failed, 0 skipped`, rc 0 |
| `wasmrt pin <file>` | ✅ prints the digest line, rc 0 |
| `--dir` with **both** separators | ✅ rc 0 for `.:/` and `.::/` |
| `--features` both vocabularies | ✅ `bulk_memory` **and** `bulk-memory-operations` both accepted |

🎯 **F1 IS CLOSED.** `wasmrt valid.wasm add 2 3` now returns **5**. Earlier in this same session the
pen-holder measured it printing a summary and exiting 0 with the export silently ignored; T9e fixed it,
and Z1 with it. *The finding and its fix are hours apart, which is the cadence working.*

⏳ **Outstanding on wazmrt's side — measured, not assumed:**

| # | item | wazmrt today |
| --- | --- | --- |
| **the subcommand spellings** | `run`, `wasi`, `wast`, `wat` | ⚠️ all four → `error: cannot read 'run': FileNotFound` — the path-guess again, though these are not flag-shaped so v14 does not reach them |
| **`::`** | the preferred separator | ⚠️ unsupported — **and `.:/` is broken too, §2.2z** |
| **the hyphenated feature vocabulary** | `bulk-memory-operations` | ⚠️ `error: --features: unknown proposal` — wazmrt accepts only `bulk_memory` |
| **Z1 / Z2 / Z3** | §2.3, §2.4a, §2.5 | ⚠️ open — Track B-b |
| **Z4** | the `name` section | ⚠️ open — §3.1m |

⚠️ **RECORDED DIVERGENCE, and the pen-holder is NOT making it a contract row: `multi_table`.** wazmrt
models it as a proposal layered on `reference_types`; wasmrt does not model it separately (its
`reference-types` carries it), and **recognises the name, warns, and continues** — so wazmrt command
lines still run. Measured: `wazmrt --features all,-multi_table` → rc 0, restriction applied;
`wasmrt --features all,-multi_table` → rc 0 with *"`multi_table` is not a separate proposal"*.
🎯 **Why it stays an observation:** §0 puts *internal design* out of scope, and which proposals an engine
models separately is exactly that. ⚠️ **What IS in scope is the observable consequence, so it is stated
here rather than left implicit: the same `--features` line does not gate the same thing on both
runtimes.** A deployment that relies on `-multi_table` to exclude a capability gets that exclusion on
wazmrt and **a warning and no exclusion** on wasmrt. 🔒 **REOPEN as a contract row the moment either
side ships a module that one accepts and the other refuses on this basis** — that is the day it stops
being a modelling difference and becomes a swappability break.

#### 🔬 2.1m — FIRST MEASURED RUN of §4 check 5 (wasmrt session, 2026-08-19)

**Method:** `wasmrt 0.9.0 (abi 1)` release build vs `wazmrt 1.0.0 (abi 2)`, same box, same module
(a two-line `.wat` exporting `add`). ⚠️ **Exit codes were re-measured after the first attempt read
`$?` through a pipe and reported `head`'s status instead of the binary's** — *know what your
measurement tool omits* (`best-practices.md` §1.5).

**F1 — ⚠️⚠️ The two "call an export" gaps fail in OPPOSITE directions, and wasmrt's is the dangerous
one.**

| invocation | wasmrt | wazmrt |
| --- | --- | --- |
| `<prog> add.wat add 2 3` *(positional)* | **`rc=0`, prints the module SUMMARY — the export and both arguments are silently ignored, and it exits SUCCESS** | ✅ `rc=0`, prints `5` |
| `<prog> run add.wat add 2 3` *(subcommand)* | ✅ `rc=0`, prints `5` | ❌ `rc=1`, `error: cannot read 'run': FileNotFound` |

**Same missing capability; opposite consequence.** A wazmrt-shaped command run under wasmrt **does not
fail — it succeeds at the wrong thing**, which is the silent-wrong-output class this project ranks
worst. The mirror case is loud: wazmrt returns `rc=1` and says why. 🎓 *Which direction to err in is a
property of the consequence, not a house style* — so **wasmrt's half of this row is the higher
priority of the two**, even though the tables above give them equal weight.

**F2 — the "summarize" row was marked ✅ AGREED and the output text is not identical.**
`wasmrt` prints `<path>: WebAssembly module (version 1)` plus a multi-line section breakdown;
`wazmrt` prints `<path>: valid wasm v1, 4 section(s)`. **Behaviour and exit code do agree** (both
`rc=0`, neither executes). §0 puts run modes, flag names, argument shapes, defaults and exit codes in
scope — **not output text** — so this is **out of scope and recorded anyway**, because the row claimed
"already identical" and that sentence was written from reading, not running.

**F3 — 🆕 FLAG POSITION differs, and the contract does not have a row for it.** The flag tables list
names and argument shapes but never say *where the flags go*:

| invocation | result |
| --- | --- |
| `wazmrt <module> --dir <spec>` *(its documented order)* | ✅ `rc=0` |
| `wazmrt --dir <spec> <module>` *(wasmrt's order)* | ❌ `rc=1`, `error: cannot read '--dir': FileNotFound` |
| `wasmrt wasi --dir <spec> <module>` *(its order)* | ✅ preopen parsed |
| `wasmrt wasi <module> --dir <spec>` *(wazmrt's order)* | ⚠️⚠️ **no error — `--dir <spec>` is passed to the GUEST as argv, so the sandbox is never granted** |

⚠️⚠️ **The last row is a second silent failure, and it is a security one.** wazmrt's flags follow the
module path; wasmrt's precede it. A wazmrt user's muscle memory under wasmrt produces a run with **no
preopen at all** and **no warning** — the guest simply gets `BADF` on every path call, which looks like
a guest bug rather than a missing grant. **Position is part of an argument shape and belongs in §2.2 as
its own row.**

**F4 — 🔻 A CORRECTION: the single-colon `--dir` claim in §2.2 was wrong, and it was wrong because it
was written from READING the code.** The text asserted *"it does not error; it preopens the wrong
thing."* **Measured:** `wasmrt wasi --dir <host>:/s <module>` → `rc=1`,
`wasmrt: cannot preopen <host>:/s: errno 29`. **It fails loudly.** The separator divergence is real and
still needs the both-accept-both fix, but its consequence is a **clean failure**, not a silent
mis-preopen. *(Third read-not-verify error recorded across the two projects in two days — this one is
wasmrt's, and it had been carried in this contract as a ⚠️⚠️ since v1.)*

**F5 — `-v` output shape differs**: wasmrt prints one line (`wasmrt 0.9.0 (abi 1)`), wazmrt prints two
(adding `signature trust anchor: none …`). Out of scope as text; recorded because a script that parses
`--version` sees a different shape. *(The ABI numbers differ — 1 vs 2 — which is §0-out-of-scope by
design.)*

**What check 5 has NOT covered yet:** the `.wast` row, `--ro-dir`, `--allow-symlink`, `--env`, the
ceiling flags, `--` as an end-of-flags marker, and the whole of §2.3's per-failure exit codes. Those
rows stay ⬜ **UNVERIFIED** and **may not be quoted as agreed.**

### 2.2 Flags

| flag | wazmrt | wasmrt | status |
| --- | --- | --- | --- |
| `--dir <host>[<sep>guest]` | separator `:` — ⚠️⚠️ **and `--dir .:/` DOES NOT WORK; see §2.2z (v20)** | ✅ **BOTH `:` and `::`** (2026-09-19), never mistaking a drive letter | ⚠️⚠️ **DIVERGENT AND LIVE — and the direction REVERSED: wasmrt now accepts both, wazmrt accepts neither of the documented forms** |
| `--ro-dir` | same separator issue | same | ⚠️⚠️ as above |
| **flag POSITION** relative to the module path | flags come **AFTER** the path — 🆕 **and a wazmrt flag written where only the guest sees it now WARNS** (H7, 2026-08-19); nothing after an explicit `--` is examined | flags come **BEFORE** the path | ⚠⚠ **DIVERGENT AND LIVE — MEASURED 2026-08-19 (F3).** wasmrt silently passes a trailing `--dir` to the GUEST, so the sandbox is never granted and nothing warns. |
| `--allow-symlink` | ✅ | ✅ | ✅ **AGREED** (both added 2026-08-10) |
| `--env KEY=VALUE` | ✅ | ❌ absent | ⚠️ **wasmrt must add** |
| `--max-memory <size>` | ✅ | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (the ceiling exists) |
| `--max-table-elems <count>` | ✅ | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (the ceiling exists) |
| `--features <list>` | ✅ — 🆕 **and it PRECEDES the module path, the only wazmrt flag that does; written after it is now an ERROR** (§2.4b, v16) | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (gating exists in the C ABI) — **and must adopt §2.4b's position rule when it does** |
| `--max-iterations <count>` | ✅ (2026-08-19) | ❌ absent — **and so is the ceiling** | ⚠️⚠️ **DIVERGENT AND LIVE — see §3.7** |
| `--` ends host flags, rest is guest argv | ✅ | ❌ (preopens must precede the path) | ⚠️ **wasmrt must add** |
| `--pins <path>` | ✅ | ❌ | ⚠️ **wasmrt must add** (with `pin`) |
| `--verify off\|warn\|enforce` | ✅ | ❌ | ⚠️ **wasmrt must add** (with `pin`) |
| `--no-verify`, `--yes` | ✅ | ❌ | ⚠️ **wasmrt must add** (with `pin`) |

⚠️ **THE `--dir` SEPARATOR IS A SWAPPABILITY BREAK THAT IS LIVE TODAY**, and it has nothing to do with
verification. `--dir .:/` is a working wazmrt invocation; on wasmrt the single colon is not the
separator. Each side has a real reason: a single `:` is ambiguous with a Windows drive letter
(`--dir C:\data:/data`), which is why wasmrt chose `::`.

🔻 **CORRECTED 2026-08-19 (F4), and the correction is folded in here by the pen-holder rather than left
in the annex** — because a refuted claim that stays in the table is what the next reader quotes. This
paragraph asserted *"it does not error; it preopens the wrong thing"* and **that was wrong**. Measured:
`wasmrt wasi --dir <host>:/s <module>` → `rc=1`, `wasmrt: cannot preopen <host>:/s: errno 29`. **It
fails LOUDLY.** The divergence is real and still needs the both-accept-both fix below, but its
consequence is a **clean failure**, not a silent mis-preopen — so it is downgraded from ⚠️⚠️ to ⚠️.
🎓 *The claim had been carried since v1 and was written from READING the code.* It is the **third**
read-not-verify error across the two projects in two days, and it is precisely why §1 rule 4 says a row
is verified by RUNNING both.

**AGREED RESOLUTION: both accept both.** Prefer `::`; fall back to a single `:` when the spec contains
no `::` **and** the split is not a drive letter. Converging on one spelling would break existing
invocations of the other, which is the opposite of swappable.

⚠⚠ **THIS ROW IS IN TENSION WITH v14 (§2.4a-i) AS OF 2026-09-19, AND IS FLAGGED RATHER THAN CHANGED.**
*"the split is not a drive letter"* is a **resemblance rule about a flag's VALUE** — the parser looks
at `C:\data:/data` and decides which colon the user meant. The owner's v14 instruction (*"no 'looks
like' built in"*) is written about options; this is the same mechanism one level down, and
🎓 **it is the single place in this contract where a heuristic is not just tolerated but AGREED.**
⚠️ **It is left standing until the owner rules — §5 #10.** Repealing an agreed row by implication is
exactly the unilateral move §1 forbids, and the alternatives are not free either: requiring `::`
everywhere breaks existing wazmrt invocations, and erroring on every ambiguous `:` breaks
`--dir .:/`, which is the form the docs use.

#### ⚠️⚠️ 2.2z — **`--dir .:/` DOES NOT WORK ON wazmrt, and it is the example wazmrt's own `--help` prints** (found by the pen-holder, 2026-09-19, v20)

**Measured, then confirmed in the source.** `wazmrt prog.wasm --dir .:/` →
`error: --dir '.:/': FileNotFound`. The spec was never split; the whole string was taken as the host
path. `--dir .::/` fails too (`--dir '.:'`). **wazmrt accepts NEITHER documented separator form.**

**The cause, from `src/main.zig`:** the split takes the **last** `:` **only when its index is > 1** —

```zig
if (std.mem.lastIndexOfScalar(u8, spec, ':')) |i|
    if (i > 1) .{ spec[0..i], spec[i + 1 ..] } else .{ spec, spec }
```

`i > 1` is the **Windows drive-letter guard**: it stops `C:\tmp` being split into `C` + `\tmp`. But in
`.:/` the colon is at index **1**, so a one-character *relative* host path is indistinguishable from a
drive letter and is silently not split. `--dir ./:/` works, because the colon moves to index 2.

| invocation | wazmrt | wasmrt |
| --- | --- | --- |
| `--dir .` | ✅ rc 0 | ✅ rc 0 |
| `--dir .:/` **(wazmrt's own help example)** | ⚠️⚠️ **rc 1, FileNotFound** | ✅ rc 0 |
| `--dir .::/` | ⚠️⚠️ **rc 1, FileNotFound** | ✅ rc 0 |
| `--dir ./:/` | ✅ rc 0 | ✅ rc 0 |

🎓 **THREE THINGS THIS IS, and they are worth separating.**
1. **A live defect**, not a divergence: wazmrt's documented invocation fails against wazmrt.
2. **A refuted contract claim.** §2.2 has said since v1 that *"`--dir .:/` is a working wazmrt
   invocation"*, and it was **written from reading, never run** — the *fourth* read-not-verify error
   across the two projects, and the second one found in this file's own text.
3. 🔒 **§5 #10 made concrete.** This IS the "looks like a drive letter" heuristic the owner's v14
   no-"looks like" rule put in tension, and here it **gives a wrong answer on ordinary input**. The
   decision is still the owner's — but it is no longer a hypothetical cost. ⚠️ **A fix that only adds
   `::` would leave this defect standing**, since `.:/` fails for a reason that has nothing to do with
   which separator is preferred.

⏳ **wazmrt's half is now two things, not one:** accept `::`, **and** stop mis-guarding a one-character
relative host path. Tracked at Track B → B-b.

### 2.3 Exit codes

| behaviour | status |
| --- | --- |
| a WASI guest's `proc_exit(n)` becomes the process exit status (`n & 0xff`) | ✅ **AGREED** — verified in both, 2026-08-19 |
| success → 0, host-side failure (bad args, unreadable file, invalid module, refused by policy) → non-zero | ✅ **AGREED** |
| **specific non-zero codes per failure kind** | ✅ **AGREED (v13, 2026-09-19) — every host-side failure and every guest TRAP → `1` on both; `proc_exit(n)` → `n & 0xff`.** Measured twice by running both binaries: wasmrt's 18-row matrix (§2.3m) and the pen-holder's own 12-case re-run on the same bytes before folding — unreadable file, bad magic, unassemblable `.wat`, invalid module (summarize **and** call-an-export), wrong arity, unparseable argument literal, missing arguments, no arguments, and a trap: **`1` on both, in every one.** 🎓 **The row closes with no per-kind table, because neither implementation distinguishes kinds** — the portable contract is the success/failure split plus `proc_exit`, and writing a table of codes nobody emits would have been a list that drifts. Closes §5 decision #4. ⚠️ **REOPEN** the moment either side introduces a second non-zero code — that is the day scripts stop being portable across the swap. |
| 🆕 **naming an export the module does not have is a failure** — non-zero, with a message naming it; never a silent fall-back to summarizing (Z1, §2.3m) | ✅ **FOLDED IN AS CONTRACT VERSION 13 by the pen-holder (wazmrt, regime A), 2026-09-19.** 🔒 Owner decision, recorded by wasmrt; owner: *"pass all three issues to the wazmrt team"*. ⚠️⚠️ **THE ROW BINDS BOTH SIDES, and on the day it was folded in NEITHER was fully clean** — recorded that way deliberately, because a row written as "they must adopt" is a row its author stops testing. It is a case of row 2 (a bad argument), stated separately because wazmrt breaks it: `wazmrt m.wasm nosuch` prints the summary and exits **0**. wasmrt's `run` already complies (rc 1, *"no exported function `nosuch`"*). ⚠️ **wasmrt's bare-path form still has F1** (`wasmrt m.wasm f` summarizes, rc 0). That is the same class on wasmrt's side, and it stays open under §2.1. |

#### 🔬 2.3m — §2.3 MEASURED by running both binaries (wasmrt session, 2026-09-19) — 📎 ANNEX, ✅ **ACCEPTED AND FOLDED IN as v13** (wazmrt, pen-holder, 2026-09-19); kept in place as the measured evidence

*A wasmrt contribution under regime A: **not a version**, rows above deliberately left as the pen-holder wrote
them — ✅ **and the pen-holder has since folded them in as v13**, after re-running all of it (§2.5h-a). Triggered by the owner's `coordinate` on the one item wasmrt had logged as needing it: "`wasmrt <file>`
exits 0 on an invalid module".*

**Method.** Both copies of this file byte-compared first: **IDENTICAL at v10** (neither changed since
2026-08-19). Binaries: `wasmrt 0.9.0 (abi 1)` at `3c49845dd`, and `wazmrt 1.0.1 (abi 2)` from
`zig-out/bin`, built 2026-08-19 13:02. Its only later source commit is H7 (13:05), and the binary
**already carries H7** (verified: `wazmrt m.wasm x --dir .` prints H7's warning). Nothing was built or
written in the wazmrt tree. Fixtures come from `wasm-tools parse`, which does not validate, so an ill-typed
module really reaches each validator. `rc` is read from the process, not through a pipe (§2.1m's lesson).

**Row 2 ("host-side failure → non-zero", ✅ AGREED) — wasmrt was in breach three times; wazmrt in none:**

| | invocation | wasmrt before | wazmrt | wasmrt after |
| --- | --- | --- | --- | --- |
| **W1** | summarize an INVALID module (`.wasm` or `.wat`) | **0** | 1 | 1 |
| **W2** | no arguments at all | **0** (printed the version) | 1 (usage) | 1 (usage) |
| **W3** | `.wast` with a FAILED assertion / an UNPARSEABLE script / an UNREADABLE file | **0 / 0 / 0** | 1 / 1 / 1 | 1 / 1 / 1 |

✅ **Fixed on wasmrt's side**, pinned by `crates/wasmrt/tests/cli_exit_codes.rs`, which is mutation-verified.
This needs **no contract change**: it moves wasmrt ONTO a row both copies already carry. After the fix, an
18-row matrix agrees on success vs failure in every row. It covers summarize, call-an-export and WASI
`_start`, across valid, invalid, malformed, missing, trapping and `.wat` inputs. 🎓 *W1 is also why §2.1's
summarize row read "AGREED on exit code": it was measured on a VALID module only.* Skips in a `.wast` run do
**not** fail it on wasmrt: they are reported separately.

**Row 3 ("specific non-zero codes per failure kind", ⬜) — MEASURED, and the two already agree.**
Every host-side failure kind we exercised returns exactly **1** on both runtimes: unreadable file, bad
magic, unassemblable `.wat`, invalid module on every path, wrong arity, unparseable argument literal,
missing arguments, and usage. So does a guest **trap**. `proc_exit(n)` returns `n` on both (row 1).
📎 **Proposed for the pen-holder:** promote row 3 to *"✅ AGREED: every host-side failure and every trap
→ 1; `proc_exit(n)` → `n & 0xff`"*. That also closes **§5 decision #4** without a per-kind table. A script
cannot tell a trap from a refusal by code alone on either runtime, and nothing measured suggests it needs to.

**Observations for wazmrt.** Neither runtime is the oracle, so these are recorded, not diagnosed, and
fixing them is wazmrt's call in wazmrt's tree:

* **Z1 — the MIRROR of F1.** `wazmrt valid.wasm nosuch`, naming an export the module does not have,
  prints the summary and exits **0**. The name is silently ignored. wasmrt's `run` exits 1 with *"no
  exported function `nosuch`"*. Same class as F1 (an argument dropped, the run reported as success),
  on the other side.
* **Z2 — unknown flags have no row, and the two diverge.** `wazmrt m.wasm --bogus` exits **0** (the flag
  goes to the guest). wasmrt refuses an unknown option in either position: rc 1, *"use `--` to pass it
  to the guest"*. ⚠️ **Not a simple fix on either side.** wazmrt's flags-after-path form cannot tell a
  mistyped host flag from a guest argument without `--`, and §2.4 already records why that is dangerous
  (`… install --yes`). ✅ **DECIDED by the owner the same day → §2.4a**, which resolves the tension by
  *position* and, after the path, by *dash count* (v15): an unknown `--flag` errors, a `-flag` is the guest's.
* **Z3 — output text, out of scope (§0), recorded anyway.** wazmrt's summary header reads *"valid wasm
  v1, N section(s)"* for a module whose last line reports `validation: FAILED`. The exit code is right
  (1); the first line a human reads is not.

**§2.1m's "not covered yet" list, updated:** §2.3's per-failure exit codes and the `.wast` row's exit
behaviour are now covered. wazmrt also accepts `.wat` on its summarize and call paths (measured), so the
§2.1 "assemble" row concerns only the `wat` subcommand.

### 2.4 Flag-parsing rules that are part of the contract

- **`-h`/`--help` and `-v`/`--version` are recognised as the FIRST argument only**, so a `--help` inside
  a guest's argv is never the host's. ✅ AGREED.
- ⚠️ **Verification flags are recognised only in the LEADING RUN of host flags.** Scanning "everything
  before `--`" is **not** sufficient: the common WASI form has no `--` at all
  (`… prog.wasm install --yes`), so the guest's own arguments get searched and a `--yes` meant for the
  guest **silently disables verification**. wazmrt paid for this; wasmrt must not re-buy it.

### 2.4a Unknown flags — **an error, `unknown flag`** · 🔒 **OWNER DECISION 2026-09-19** · ✅ **CONTRACT VERSION 11 — FOLDED IN AND NUMBERED by the pen-holder (wazmrt, regime A), 2026-09-19**

> Owner, 2026-09-19: *"I do want an 'unknown flag' rule in the contract that throws an 'unknown flag' error."*

**The rule.** A flag-shaped argument (one beginning with `-`, other than `-` alone and the `--` marker)
that appears in a **host-flag position** and is not a flag that command recognises **stops the run
before anything executes**:

* stderr contains the words **`unknown flag`** and names the argument;
* the exit status is **1** (§2.3).

**Host-flag positions** (checked):
1. the **first argument**, apart from `-h`/`--help`/`-v`/`--version` (§2.4);
2. **anything before the module path**;
3. the **leading run of flags immediately after the module path**, which is wazmrt's flag position —
   🆕 **for a `--flag` only** (v15). Both runtimes accept flags there under §2.2;
4. **every argument** of a command that has no guest argv: summarize, `.wast`, and `wat`.

**Guest positions** (never examined — the guest's argv, verbatim):
* everything after an explicit **`--`**;
* everything after the **first non-flag argument** that follows the module path. That is the export
  name and its arguments (so `-1` stays a value), or a WASI program's argv (so `prog.wasm install --yes`
  is unaffected);
* 🆕 **a SINGLE-DASH token in position 3** — the run immediately after the module path, in a mode that
  has guest argv. It is the guest's and needs no `--`: `prog.wasm -la` runs. **(v15)**

🆕 **Why position 3 splits by dash count** (owner, 2026-09-19, narrowing the rule the same day it was
written): **every host flag that can appear after the module path is double-dash** — `--dir`,
`--ro-dir`, `--env`, `--max-*`, `--pins`, `--verify`, `--no-verify`, `--yes`, `--features`,
`--allow-symlink`. The single-dash names (`-h`, `-v`) are first-argument-only (§2.4), and the
subcommand flags (`wast -v`, `wat -o`) belong to modes with **no guest argv**. So a single-dash token
there **cannot be a host flag**, there is nothing to disambiguate, and demanding `--` would only make
`prog.wasm -la` longer. A `--flag` in that position genuinely could be either, so an unknown one errors.

⚠️ **What that costs, recorded rather than smoothed over.** A mistyped host flag with one dash —
`-dir /tmp` for `--dir /tmp` — reaches the guest silently, so the preopen is never granted and nothing
says so. 🔒 **The owner considered a "looks like a host flag" warning for exactly this case and refused
it** — *"I do not want the 'looks like' part. If it is not a proper cli option throw the error"* (as
recorded in wasmrt's copy), and to this session the same day: *"We should have no 'looks like' built in
so that it interprets a cli."* A token is judged by its POSITION and by whether the command knows it,
**never by resembling a flag name**. 🎓 **A near-miss list is itself a thing that would drift between
the two runtimes** — which is this file's oldest lesson applied to a helpfulness feature.

⚠️ **The other consequence, which stands:** a guest's own `--help` directly after the path is an
unknown flag — `prog.wasm -- --help` is the spelling. That is the rule doing its job, since `--dirr`
must not slip past silently. The CLI help says so on wasmrt.

**H7 is unchanged and complementary.** A **known** host flag stranded in a guest position still only
*warns* (it may be the guest's own); an **unknown** `--flag` in a host position *errors*.

| | wazmrt (measured 2026-09-19, 1.0.1) | wasmrt | status |
| --- | --- | --- | --- |
| first argument / before the path (**either dash form**) | rc 1, but reported as *"cannot read '--bogus': FileNotFound"* | ✅ `unknown flag` | ⚠⚠ **wazmrt: NOT merely the wording — a v14 breach.** The parser decided the flag *looked like* a path. Right code, and a message that sends the user to the filesystem to debug a typo'd flag |
| leading run after the path, **`--flag`** | **rc 0 — handed to the guest** | ✅ `unknown flag` | ⚠⚠ **wazmrt must adopt** |
| leading run after the path, **`-flag`**, in a mode that **HAS guest argv** (`_start` present) (v15) | rc 0 — the guest's | rc 0 — the guest's | ✅ **AGREED — both measured correct 2026-09-19** (`wazmrt start.wasm -la`, `wasmrt wasi start.wasm -la`). 🎓 The narrowing *removed* work from wazmrt: its existing behaviour here was right, and pre-narrowing v11 would have made us break it |
| ⚠️ leading run after the path, **`-flag`**, in a mode with **NO guest argv** (summarize, `.wast`, `wat`) | **rc 0 — ignored** (`wazmrt valid.wasm -la`) | ✅ rc 1, `unknown flag` | ⚠⚠ **wazmrt must adopt — the v15 carve-out does NOT reach here.** Position 4 is *every* argument, both dash forms; the dash-count split is scoped to **modes that have guest argv**, because that is the only place there is a guest to hand it to |
| `.wast` script flags | **rc 0 — ignored** | ✅ `unknown flag` | ⚠️⚠️ **wazmrt must adopt** |
| guest positions (after `--`, after the first guest arg) | untouched | untouched | ✅ **AGREED** |

wasmrt is pinned by `crates/wasmrt/tests/cli_unknown_flag.rs` (mutation-verified). Before the rule,
**both** runtimes silently ignored an unknown flag in at least one host position.

#### 2.4a-i 🔒🔒 **NO "LOOKS LIKE" — an argument is a RECOGNISED option or it is an ERROR** · **OWNER DECISION 2026-09-19** · ✅ **CONTRACT VERSION 14**

> Owner, 2026-09-19: *"improper cli options should throw an error. We should have no 'looks like' built
> in so that it interprets a cli. If it is a valid cli option run it, if not throw and error."*

🎯 **This is the GENERAL rule that §2.4a is one instance of, and it is stronger than §2.4a alone.**
§2.4a says an unrecognised flag in a host position errors. **v14 says the host parser may not
RESEMBLANCE-MATCH anything, ever.** Within a host-flag position an argument is compared against the set
of options that command accepts: **exact match → run it; anything else → `unknown flag`, rc 1.** There
is no third branch, and in particular these are all now **forbidden**:

| forbidden | what it looks like in practice | why it is forbidden |
| --- | --- | --- |
| **guessing a flag is a PATH** | ⚠️ wazmrt today: `wazmrt --bogus m.wasm` → *"cannot read '--bogus': FileNotFound"* | the exit code is right and **the message sends the user to look at the filesystem for a typo in their flag.** This is the purest case of the rule: the parser decided what the argument *resembled* |
| **fuzzy / "did you mean"** matching | `--dirr` → silently treated as `--dir`, or corrected | a near-miss that RUNS is the silent-wrong-output class with a helpful face on it. ⚠️ **Printing a suggestion is not the same as acting on one** — the error may name near spellings, it may not adopt one |
| **prefix / abbreviation** matching | `--max` accepted for `--max-memory` | today's unambiguous abbreviation becomes ambiguous the moment a flag is added, so it silently changes meaning across versions |
| **"probably the guest's"** inference in a **host** position | ignoring an unknown flag after the path because it might be argv | this is Z2 exactly, and it is what §2.4a already killed |
| **inferring a flag from its VALUE's shape** | treating `-1` as a flag, or a flag as a value, based on what it resembles | §2.4a settles this **by position**, and position is grammar — see below |
| **a "did you mean a host flag?" warning** on a near-miss | warning that `-dir /tmp` looks like `--dir /tmp` before passing it to the guest | 🔒 **the owner considered exactly this case and REFUSED it** (v15). It is the most tempting form of the rule to break, because the thing it would catch is real |

⚠⚠ **WHAT v14 DOES *NOT* TOUCH, and the distinction is the load-bearing one: GRAMMAR IS NOT
RESEMBLANCE.** The host/guest boundary in §2.4a is fixed by the **shape of the command line** — an
explicit `--`, the first non-flag argument after the module path, and 🆕 **the DASH COUNT of a token in
position 3** (v15) — **not by judging what an argument looks like.** 🎯 **Dash count is the clearest
case of the distinction:** *"a single dash after the path is the guest's"* is a fact about the shape of
the line that holds for every possible token; *"`-dir` looks like `--dir`"* is a guess about one. The
first is decidable and stable, the second is a list that drifts. A WASI guest's argv is not "a cli option wazmrt failed to recognise"; it is **not
addressed to wazmrt at all**, and the grammar says so before any matching happens. 🔒 **This is not a
loophole in v14, it is the reason v14 is implementable:** a rule that made every argument on the line
either a valid host option or an error would make `prog.wasm install --yes` impossible to write, and
§2.4 records what that costs — a guest's own `--yes` **silently disabling verification**, a trap this
project has already paid for once.

⚠️ **TWO THINGS v14 PUTS IN TENSION, BOTH FLAGGED FOR THE OWNER RATHER THAN DECIDED HERE:**

1. ⚠⚠ **§2.2's agreed `--dir` separator fallback is itself a "looks like" rule** — *"fall back to a
   single `:` when the spec contains no `::` **and the split is not a drive letter**"*. Deciding
   whether `C:` is a drive letter or a host path is **exactly** the resemblance-matching v14 forbids,
   and it is not a flag NAME but a flag VALUE. **§5 #10.** *(It was agreed before v14 existed; it is
   raised, not overridden — the pen-holder does not get to repeal an agreed row by implication.)*
2. **H7's WARN.** A *known* host flag stranded in a **guest** position warns rather than errors,
   because it may genuinely be the guest's. Under v14 that is grammar, not resemblance, so it stands as
   written — but it is the nearest neighbour to the rule and the owner may want it to error. **§5 #11.**

**Status — MEASURED 2026-09-19 by running both, on flag NAMES:**

| probe | wazmrt 1.0.1 | wasmrt 0.9.0 |
| --- | --- | --- |
| **prefix / abbreviation** — `--max-mem` for `--max-memory`, `--vers` for `--version`, `--outp` for `--output` | — | ✅ `unknown flag`, rc 1 — **not accepted** |
| **near-miss spelling** — `--dirr` | — | ✅ `unknown flag`, rc 1 — **named, not adopted** |
| **flag-shaped argument in a host position** — `--bogus`, `-Dbogus` | ⚠⚠ *"cannot read '-Dbogus': FileNotFound"* — **guessed it was a path, in both probes** | ✅ `unknown flag`, rc 1 |

✅ **wasmrt COMPLIES on flag names** — four probes, no abbreviation and no fuzzy adoption; it names the
argument and stops. ⚠⚠ **wazmrt is in breach** (the path-guess, reproduced on a second spelling, plus
all of §2.4a). ⬜ **Neither side's flag-VALUE parsing has been swept for resemblance rules** — that is
a different surface from the names measured here, and §2.2's drive-letter fallback is a known instance
of it sitting in this contract as **AGREED** (§5 #10). Tracked for wazmrt at Track B-b.

### 2.4b 🆕 A flag with a REQUIRED POSITION, written where it cannot apply, is an **ERROR** · 🔒 **OWNER DECISION 2026-09-19** · ✅ **CONTRACT VERSION 16**

> Owner, 2026-09-19: *"If the `--features <list>` has to go before the module, we need to identify
> that in the invocation and help sections for sure, and we need an error thrown when it is in the
> wrong location."*

**The rule.** Where a command accepts a flag **only** in one position, that flag appearing in a
**different host-flag position** stops the run: stderr names the flag **and the position it requires**,
and the exit status is **1**. It is never ignored, and never merely warned about. ⚠️ **Guest positions
stay untouched** (§2.4a as narrowed by v15) — after `--`, or after the first non-flag argument, the
token is the guest's.

🎯 **It also binds the HELP, which is half of what the owner asked for.** A flag with a required
position must state that position in the usage/invocation section, not only in its own entry further
down. *A constraint documented only where the reader already knows to look is not documented.*

**Today the only such flag is wazmrt's `--features`,** which must precede the module path. 🔒 The
reason it cannot simply be accepted in both places is recorded at its parse site and is a real one: in
run mode the export name must be `args[2]`, so a trailing flag region would silently change which mode
`wazmrt prog.wasm --dir .:/ add 2 3` selects for a module exporting both `add` and `_start`. Nor may it
be read from the trailing region at all — a guest's own `--features mvp` must never narrow the
language wazmrt accepts, the same reasoning that keeps `--no-verify` out of there.

| | wazmrt **before** (1.0.1 as shipped) | wazmrt **after** (this change) | wasmrt |
| --- | --- | --- | --- |
| `--features` before the path | ✅ applies | ✅ applies | — **no `--features` at the CLI yet** (§2.2) |
| `m.wasm --features mvp` | ⚠️⚠️ **rc 0 — ran under the FULL feature set, in SILENCE** | ✅ rc 1, names the required position | — |
| `m.wasm --features=mvp` | ⚠️⚠️ **rc 0 — same** | ✅ rc 1 | — |
| `m.wasm --dir . --features mvp` | ⚠️⚠️ **rc 0 — same** | ✅ rc 1 | — |
| `m.wasm -- --features mvp` | rc 0 — the guest's | ✅ rc 0 — unchanged | — |
| `m.wasm guestarg --features mvp` | not warned by H7 | ✅ unchanged (guest position) | — |

⚠️⚠️ **THE DEFECT THIS FOUND IS WORSE THAN THE MISSING ERROR, and it is why this is a contract row
rather than a help-text fix.** `--features` is the one wazmrt flag whose entire job is to **REFUSE**
modules — a smaller trusted computing base. Written after the path it was **silently dropped**, so a
user who asked for `mvp` got every proposal enabled, with **no error, no warning, and a successful exit
status**. 🎓 **That is the fail-OPEN direction on a security control**, the same shape as H2's ignored
GC ceiling and as §2.4's `install --yes` trap. **H7 did not catch it**: H7 warns for names in
`flagRegion`'s lists, and `--features` is deliberately absent from them, so it fell between the two
mechanisms that exist to prevent exactly this. 🎓 *A rule that names the things it guards will not
guard the thing it does not name.*

✅ **Shipped in wazmrt** — `misplacedFeaturesFlag` in `src/main.zig`, pinned by two tests (one for the
rule, one proving its walk matches `flagRegion`'s), **inversion-proven**: stubbing the detector to
`return null` fails the first test, and the suite is green restored (767 tests, 4 skipped for the known
exFAT symlink cases). ⚠️ **wasmrt is not in breach** — it has no `--features` at the CLI at all (§2.2
already records that as *"wasmrt must expose"*). **This row binds it when it adds one.**

### 2.5 A validity claim in the output must match the verdict (Z3) · 🔒 **OWNER DECISION 2026-09-19** · ✅ **CONTRACT VERSION 12 — FOLDED IN AND NUMBERED by the pen-holder (wazmrt, regime A), 2026-09-19**

> Owner, 2026-09-19: *"we also need a contract item for Z3"*.

**The rule.** No line a command prints may describe a module as **valid** unless it validated. The
exit status (§2.3), any verdict line, and any header or summary wording must **agree**. A summary that
prints before validation finishes must use neutral wording ("WebAssembly module", "wasm v1", section
counts), never "valid". **Only validity claims are in scope** (§0); the rest of the output text is not.

| | wazmrt (measured 2026-09-19, 1.0.1) | wasmrt | status |
| --- | --- | --- | --- |
| summary of an INVALID module | ⚠️ header `…: valid wasm v1, 4 section(s)`, then `validation: FAILED …`, rc 1 | header `…: WebAssembly module (version 1)`, then `validation FAILED: …`, rc 1 | ⚠️ **wazmrt must adopt** (the header) |

wasmrt is pinned by `cli_exit_codes.rs::the_summary_never_calls_an_invalid_module_valid`. That test
**fails when wazmrt's header wording is injected into wasmrt's summary** (mutation-verified), so it
checks exactly this.

### 📬 2.5h — HANDOFF TO wazmrt (owner-directed, 2026-09-19)

Owner: *"lets pass all three issues to the wazmrt team."* Passed **through this file**, because §1a
forbids writing into wazmrt's tree. For wazmrt's own session to adopt in wazmrt's own commit:

| # | issue | contract item | wazmrt action | verify by running |
| --- | --- | --- | --- | --- |
| **Z1** | an unmatched export name is silently ignored (rc 0) | §2.3, new row | fail with rc 1 and name the export, when the argument can only be an export name | `wazmrt m.wasm nosuch` → rc 1 |
| **Z2** | unknown flags are ignored or misreported | **§2.4a** (owner decision, **as narrowed by v15**) | `unknown flag`, rc 1, in every host-flag position — but after the module path **only for a `--flag`**: a single-dash token there is the guest's, and no "looks like" guessing anywhere (v14) | `wazmrt m.wasm --bogus`, `wazmrt --bogus m.wasm` and `wazmrt s.wast --bogus` → `unknown flag`, rc 1; `wazmrt m.wasm -- --bogus` **and `wazmrt m.wasm -la`** → untouched |
| **Z3** | the summary header says "valid" for an invalid module | **§2.5** (owner decision) | neutral header wording until validation has passed | `wazmrt invalid.wasm` → no line claims validity; rc 1 |

⚠️ **Z1 needs care on wazmrt's side.** Its bare path runs `_start` when the module exports one, so a
following word may be guest argv rather than an export name. The failure applies when the word **can
only be** an export name: the module has no `_start`, or the word is in the export position of an
explicit call form. How wazmrt draws that line is its design call; the observable requirement is only
*"never silently succeed at something other than what was asked"*.

#### ✅ 2.5h-a — THE HANDOFF IS ACCEPTED, AND ALL THREE RE-MEASURED BEFORE ACCEPTING (wazmrt, pen-holder, 2026-09-19)

⚠️ **The pen-holder did not fold these in on the strength of the annex.** §1 rule 4 says a row is
verified by **running both**, and that applies to a row arriving from the sibling exactly as it applies
to one this side wrote. All three were re-run here, on the same bytes, before any of them was numbered:

| # | invocation | wazmrt 1.0.1 (re-measured) | wasmrt 0.9.0 (re-measured) | verdict |
| --- | --- | --- | --- | --- |
| **Z1** | `wazmrt valid.wasm nosuch` | **rc 0**, prints the summary; `nosuch` silently dropped | `run`: **rc 1**, *"no exported function `nosuch`"* | ⚠️ **confirmed — wazmrt in breach** |
| **Z2** | after the path (`m.wasm --bogus`) | **rc 0** — handed to the guest | **rc 1**, `unknown flag` | ⚠⚠ **confirmed** |
| **Z2** | before the path (`--bogus m.wasm`) | rc 1, but *"cannot read '--bogus': FileNotFound"* | **rc 1**, `unknown flag` | ⚠️ **confirmed — right code, wrong reason** |
| **Z2** | `.wast` (`s.wast --bogus`) | **rc 0** — ignored | **rc 1**, `unknown flag` | ⚠⚠ **confirmed** |
| **Z2** | guest position (`m.wasm -- --bogus`) | untouched, rc 0 | untouched | ✅ **agreed — the carve-out works** |
| **Z3** | `wazmrt invalid.wasm` | header `invalid.wasm: valid wasm v1, 5 section(s)`, then `validation: FAILED …`, rc 1 | `invalid.wasm: WebAssembly module (version 1)`, then `validation FAILED: …`, rc 1 | ⚠️ **confirmed — wazmrt in breach** |

🔎 **And one thing the re-run adds, which is why re-running mattered: `wazmrt invalid.wasm bad` — the
CALL form on an invalid module — already exits 1.** Z1 is therefore **not** a general "wazmrt ignores the
export name" defect; it is specific to the **export-name lookup on a module that validates**. The word is
dropped only on the path where everything else succeeded, which is the narrowest and most deceiving
version of the bug: *the run that silently does the wrong thing is the one where nothing else went wrong.*

⚠️ **F1 IS STILL LIVE ON wasmrt, and the pen-holder verified it rather than taking the note on trust.**
`wasmrt valid.wasm nosuch` → **rc 0**, summarizes, drops the name — identical in shape to Z1. wasmrt's own
copy says so (§2.3, §2.1) and this is not a counter-charge; it is the reason the §2.3 row above is worded
as binding on **both** sides. 🎓 **wasmrt's compliance is via its `run` subcommand; its bare-path form is
in breach of the row it authored.** *A project is least likely to run a new check against the form it did
not have in mind when it wrote the check.*

🆕 **v15 RE-MEASURED THE SAME DAY (the narrowing arrived mid-pass), and it MOVED the line in both
directions:**

| invocation | mode | wazmrt | wasmrt | v15 requires |
| --- | --- | --- | --- | --- |
| `start.wasm -la` (`_start` present) | **has** guest argv | rc 0 — guest's | rc 0 — guest's | ✅ **both correct** — `-la` runs, no `--` needed |
| `start.wasm --bogus` | **has** guest argv | **rc 0** | rc 1, `unknown flag` | ⚠⚠ **wazmrt in breach** |
| `valid.wasm -la` (no `_start`) | **no** guest argv | **rc 0** | rc 1, `unknown flag` | ⚠⚠ **wazmrt in breach** — the carve-out does not apply |

🎯 **The middle and last rows are the whole point of measuring after a narrowing rather than assuming
it shrank the work.** v15 genuinely removed one obligation from wazmrt (`-la` with `_start`: already
right). ⚠️ **It removed nothing in a mode with no guest argv** — there, *every* argument is a host
position under §2.4a item 4, both dash forms, and wazmrt ignores single-dash tokens there today.
🎓 **An implementer reading only v15's headline — "after the path, one dash is the guest's" — would
apply it in summarize mode and ship a second Z2.**

📍 **Where wazmrt tracks the work: `cmem/roadmap.md` → Track B → B-b.** ⚠️ **Nothing is adopted in
wazmrt's code by this fold-in — deliberately.** §1d puts adoption at a track, and §1's other half
("coordinate BEFORE shipping a contract surface") is what this pass **is**: the rule is decided and
numbered first, then built. Adopting it inside a coordination pass would invert exactly the order that
§1d exists to enforce.

---

## 3. The security-check contract

### 3.1 What gets hashed — the TOCTOU rule

| rule | status |
| --- | --- |
| hash the **in-memory bytes about to execute**; never re-read by path | ✅ **AGREED** — `bytes-hashed == bytes-run` by construction |
| a `.wat` input hashes the **assembled** bytes, not the source text | ✅ **AGREED** on the rule — ⚠️⚠️ **but the two assemblers do not emit the same bytes, so `.wat` DIGESTS ARE NOT PORTABLE (Z4, v17). MEASURED and INDEPENDENTLY REPRODUCED 2026-09-19 — see §3.1m.** `.wasm` digests are portable. |
| a `.wast` script hashes the **script bytes** — every module it can run is contained in them | ✅ **AGREED** |
| the file is read **once**; no path is reopened after load | ✅ **AGREED** in behaviour · ⚠️ **wasmrt is making it a compiler-checked type** (`Loaded { bytes, digest }`), wazmrt passes a slice — an implementation difference, not a contract difference |

⚠️⚠️ **`.wast` MUST BE GATED.** A script instantiates and invokes the modules it contains — including
`(module binary "…")` raw payloads. wazmrt shipped this bypass: `wazmrt payload.wast` ran unpinned,
unsigned wasm **even under a root-owned `# mode: enforce`**. **Any wasm can be wrapped in a `.wast`, and
the attacker chooses the extension, so the bypass needs no privilege.**

#### 🔬 3.1m — `.wat` DIGESTS DIVERGE, and the cause is the `name` section · 📎 wasmrt annex, ✅ **ACCEPTED AND FOLDED IN as v17** (wazmrt, pen-holder, 2026-09-19)

**§3a decision 2 said to make the `.wat` agreement a TEST rather than an assumption. Run, it fails.**
Both runtimes' `pin` hashes the assembled bytes, so the digests compare directly — one command per file.

| corpus | wasmrt's run (535 files) | 🔬 **the pen-holder's own re-run (959 files, whole `wasmtk` tree)** |
| --- | --- | --- |
| agree | **2** | **2** |
| differ | **529** | **952** |
| one/both refuse | 4 | 5 |

✅ **THE DIAGNOSIS IS CONFIRMED BYTE-FOR-BYTE, not taken on trust.** On `wasmtk/src/wasm/mathlib.wat`:

| artifact | SHA-256 |
| --- | --- |
| wasmrt's assembled output | `8fc0e0c4…` — **equals `wasmrt pin`** |
| the same, `wasm-tools strip --all` | `821a3b51…` — **equals `wazmrt pin`, exactly** |

`wasm-tools objdump` shows the difference is **one section**: `custom "name"`, 2020 bytes. Types,
functions, globals, exports and code are byte-identical, at identical offsets. **wasmrt emits a `name`
section built from the text's identifiers (as wasm-tools and wasmtime do); wazmrt emits none.**

🎯 **The mechanism is confirmed by the exceptions, which is the strongest evidence in the run.** The
**only two files out of 959 whose digests agree are the only two containing zero `$identifiers`** — no
identifiers, so wasmrt has no names to emit, so no `name` section, so the digests match. *The rule and
its exceptions have the same single cause.*

🔒 **Consequence for an operator: only `.wasm` pins are portable.** A `.wat` pinned under one runtime is
**refused** under the other. That fails **CLOSED** — a denial, never a silent run — so it is an
operational break, not a security hole. ⚠️ Until Z4 lands, an installer that pins `.wat` must pin **per
runtime**, and that limitation belongs in the deployment docs rather than being discovered.

📬 **Z4 is wazmrt's to fix, and the ask is the right one:** emit the `name` section from the identifiers
the text carries. 🔒 It also matches the owner's standing direction **not to discard information the
source carries** — the `.wat` text *has* the names, and dropping them is a lossy assemble.
⚠️ **Note what Z4 is NOT:** it is not "match wasmrt's bytes". It is "stop throwing the names away". The
digests converging is the *test* that it worked, not the goal. **Tracked at Track B → B-b.**

### 3.2 When the gate runs

| rule | status |
| --- | --- |
| the gate runs on a `will_execute` predicate; a pure **summarize/inspect** path is never gated | ✅ **AGREED** |
| the gate runs **BEFORE validation** — authorization first, so an unauthorized module is refused as *unauthorized* rather than parsed and reported on | ✅ **AGREED** |

### 3.3 The pin DB — a SHARED ON-DISK ARTIFACT

| item | agreed value |
| --- | --- |
| **location** | ✅ **DECIDED (owner, 2026-09-19) — v18. THE SHARED DEPLOYMENT PATH:** `/etc/wasmtk/pins` · `C:\ProgramData\wasmtk\pins`, named for the deployment both runtimes ship inside, **with each runtime's own path kept as a FALLBACK**, and — 🔒 **the part that carries the safety** — **a loud warning when a runtime finds no DB where its sibling would have found one**, instead of quietly computing `armed = false`. ✅ Implemented in wasmrt (T9e), as a pure function with a mutation-verified test. ⏳ **wazmrt to adopt the same order and the same warning** — Track B-b. Today wazmrt reads `C:\ProgramData\wazmrt\pins` only |
| ownership | **root-owned, read-only to the user, plaintext.** Integrity from **ownership, not secrecy** |
| format | one lowercase-hex SHA-256 per line; blank lines and `#` lines ignored; whitespace-separated text after the hash is a human label and is ignored |
| addressing | **content-addressed — no paths in the DB**, so moving or renaming an approved file does not re-open a hole |
| policy directive | `# mode: off\|warn\|enforce` — the policy inherits the DB file's **ownership** |
| pinning time | at **install** time, with privilege — a verified install, **not** TOFU |
| no encryption | a category error: encryption gives confidentiality; what is needed is integrity |
| no machine-binding | the attacker **is** the user |

✅ **RESOLVED 2026-09-19 by the owner — v18, and this closes §5 decision #1, the row this file has
called its most dangerous since v1.** Shared path, per-runtime fallback, and the anti-silent-disarm
warning. wasmrt reads `/etc/wasmtk/pins`, then `/etc/wasmrt/pins`, and **if neither exists while
`/etc/wazmrt/pins` does, it says so** rather than treating the deployment as unarmed.

🎯 **The warning is the load-bearing half, and it is worth being explicit about why.** A shared path
alone would still fail silently the moment a deployment is part-migrated: the binary swaps, the DB is
at the sibling's old path, nothing is found, and `armed = false` is a *perfectly ordinary* state with no
error attached to it. **The failure mode is not "no DB" — it is "no DB, and no reason to think that is
wrong."** Detecting the sibling's DB is the only cheap signal that distinguishes *"this host has no pin
policy"* from *"this host has one and I am not reading it."*

⏳ **wazmrt's half, and it is not just a path constant:** the lookup order, and the warning, and a test
that the warning fires. ⚠️ **Adopting only the shared path would be the dangerous partial fix** — it
closes the case where both runtimes are new and leaves the migration window, which is the window an
operator is actually in while swapping binaries.

*The row as it stood:* ⚠️⚠️ **THE PATH IS THE MOST DANGEROUS UNRESOLVED ROW IN THIS FILE.** If each runtime reads its own path,
**swapping the binary finds no DB, computes `armed = false`, and silently runs everything** — a security
downgrade with **no error message**, which is the worst defect class either project tracks.

**RECOMMENDED (owner decision pending): one shared path named for the deployment** —
`/etc/wasmtk/pins` and `C:\ProgramData\wasmtk\pins`, since `wasmtk` is what both are being included in.
Each may keep its own legacy path as a fallback. 🔒 **Whatever is chosen, a swap must not be able to
disarm silently:** if a runtime finds no DB where its sibling would have found one, that is worth saying
out loud rather than treating as "unarmed".

### 3.4 The `decide()` matrix — this must match exactly

Inputs: `explicit` (the DB's `# mode:`, or none) · `pinned` · `opt_out` (`--no-verify`/`--yes`) ·
`tty` · `armed`.

| # | condition | action |
| --- | --- | --- |
| 1 | `pinned` | **Run** — the DB approved it |
| 2 | `explicit = off` | **Run** |
| 3 | `explicit = enforce` | **Deny — ABSOLUTELY.** `opt_out` and `tty` are ignored: authority comes from the root-owned policy, never from a runtime argument |
| 4 | `explicit = warn`, `opt_out` | **Run** (with a warning printed) |
| 5 | `explicit = warn`, no `opt_out`, `tty` | **Prompt** |
| 6 | `explicit = warn`, no `opt_out`, no `tty` | **Deny** |
| 7 | no `explicit`, **not armed** | **Run** — nothing to verify against |
| 8 | no `explicit`, armed, `opt_out` | **Run** (with a warning printed) |
| 9 | no `explicit`, armed, no `opt_out` | **Deny** |

**Armed** = a root key is embedded **or** a pin DB is present. A bare build with neither runs
everything, so "costs nothing when unarmed" is structural rather than promised.

**`--verify` may only RAISE strictness** above the DB-declared policy, never lower it. **Under a
root-owned `# mode: enforce`, both `--pins` and `--verify` are ignored** — the pin set *and* the policy
come from root.

### 3.5 Fail-closed rules — both bought by defects, both binding

| rule | why |
| --- | --- |
| a present `# mode:` with an **unrecognised value** means **`enforce`**, not "no policy" | a typo (`# mode: enfroce`), odd capitalisation or a trailing comment must not silently degrade to a state `--no-verify` can then override. **A root-intended enforce must never be downgradable by a misspelling.** |
| a DB content line whose first token is **not a valid 64-hex digest** is an **error**, not a skipped line | a truncated or mangled DB must fail **loud**; silently dropping approvals makes a pinned module look "not in the list" — which reads as an attack and hides a corrupt file |
| `--verify <typo>` is an **error**, not a default | same reasoning as the `# mode:` rule, at the other input |
| an override that *would* have blocked **prints a warning** | never silently unverified |

### 3.6 The WASI sandbox rights model

| property | agreed value | status |
| --- | --- | --- |
| `PATH_SYMLINK` exists as a right | **bit 24** | ✅ **AGREED** (wazmrt had **no such right at all** until 2026-08-10 — the gap that started this table) |
| `PATH_SYMLINK` is in the **write mask** | yes, so `--ro-dir` strips it | ✅ **AGREED** |
| `--dir` grants | `ALL & !PATH_SYMLINK` — **symlink CREATION denied by default** | ✅ **AGREED** (owner, 2026-08-10) |
| `--ro-dir` grants | `ALL & !WRITE_MASK` | ✅ **AGREED** |
| `--allow-symlink` | opts creation back in, for installer-shaped work | ✅ **AGREED** |
| following a **pre-existing** link | allowed — the grant governs **creation**, not traversal | ✅ **AGREED** |
| an escaping link target | refused **at creation**, independently of the follow-time check | ✅ **AGREED** |
| no `--dir` at all | every path call is `BADF`; **there is no implicit cwd** | ✅ **AGREED** |
| the full `oflags`/`fdflags` sets, and which right each `path_*` handler demands | ⬜ **UNVERIFIED** — this is the T12x row-by-row diff, still to be run |

### 3.7 Resource ceilings

| ceiling | default | status |
| --- | --- | --- |
| max linear memory | **`1 << 30`** (1 GiB) | ✅ **AGREED** — verified in both, 2026-08-19 |
| max table elements | **`1 << 27`** (128 M) | ✅ **AGREED** — verified in both, 2026-08-19 |
| max call depth | **512** | ✅ **AGREED** — verified in both, 2026-08-19 |
| an execution bound (non-termination) | **`1 << 30` iterations** per top-level call | ⚠️⚠️ **DIVERGENT AND LIVE — wazmrt shipped it 2026-08-19, wasmrt has nothing. See §3.7a.** |

### 3.7a The execution bound — ✅ **CLOSED 2026-09-19 (v19): BOTH runtimes implement it, verified by running both. The UNIT matters more than the number**

🔒 **Owner decision, 2026-08-19** (this resolves §5 decision #3): *"We do not want an infinite loop on
purpose or by accident by the user. We need an internal check mechanism if this occurs and an error
message to the user with a break on occurrence."*

⚠️ **PROCESS NOTE, RECORDED RATHER THAN TIDIED AWAY: wazmrt shipped this BEFORE the contract carried
it, which §1 rule 1 forbids** (*"a change is proposed in one repo and lands in both … before either
ships behaviour that depends on it"*). The behaviour was built in wazmrt's Track H3 while this row
still read *"neither has one"*. Nothing about the design is retracted — the owner asked for it — but
the ordering was wrong, and this row is the correction, not the announcement.

**Verified by RUNNING both on the SAME BYTES** (§1 rule 4), 2026-08-19 — one `.wasm` assembled by
wasmrt's own `wasmrt wat`, containing `(loop (br 0))` and `(func $f (return_call $f))`:

| runtime | `spin` (loop) | `tailspin` (tail call) |
| --- | --- | --- |
| **wazmrt** | traps `IterationLimitExceeded`, exit 1 | traps `IterationLimitExceeded`, exit 1 |
| **wasmrt** | ⚠️ **hung** (killed at 10 s) | ⚠️ **hung** (killed at 10 s) |

**So a module that returns an error under one runtime hangs the host under the other. That is the
swappability break §5 decision #3 predicted, and it is live today.**

✅ **CLOSED 2026-09-19 — wasmrt landed the bound in T9i, and the pen-holder VERIFIED IT BY RUNNING
BOTH rather than accepting the report** (§1 rule 4). One `.wasm` containing `(loop (br 0))` and
`(func $f (return_call $f))`, both runtimes, same bytes, `--max-iterations 1000000`:

| | `spin` (back-edge) | `tailspin` (tail call) |
| --- | --- | --- |
| **wazmrt** | ✅ `trap: IterationLimitExceeded`, rc 1 | ✅ `trap: IterationLimitExceeded`, rc 1 |
| **wasmrt** | ✅ `trap: iteration limit exceeded`, rc 1 | ✅ `trap: iteration limit exceeded`, rc 1 |

**Both message rows are met on both sides** — each names the ceiling that was hit and how to raise it,
and neither claims to have detected an infinite loop. **The differential table that opened this section
— wazmrt trapping, wasmrt hanging — is now green in every cell.** §5 decision #5 closes.

🔬 **wasmrt re-measured the default on its own corpus rather than adopting the number on trust**, which
is exactly what this section asked for: green at `1<<20`; at `1<<19` `return_call.wast` and
`return_call_ref.wast` fail; at `1<<18` `return_call_indirect` joins them; 36 failures at `1<<14`.
✅ **Same shape as wazmrt's descent** — the heaviest legitimate workload is the million-hop chain in both
— so the two engines agree about where the floor is, and `1<<30` is ~1000x the measured peak on both.
🎓 *Two independent measurements landing on the same shape is what makes `1<<30` a measured default
rather than a shared guess.*

⚠️ **THE C ABI TAKES `0` AS "LEAVE THE DEFAULT", NOT "UNLIMITED" — and the asymmetry with the CLI is
deliberate on wasmrt's side.** A library embedder must not remove the bound by passing zero, which is
what every other ceiling setter already means; a person at their own terminal may, via
`--max-iterations 0`. 📌 **RECOMMENDED for wazmrt where it exposes the bound through its own C API** —
this is an ABI-surface convention rather than a CLI row, and §0 keeps the C ABI out of scope, so it is
recorded as a **strong recommendation, not a binding row**. ⚠️ **If wazmrt chooses the other
convention, that is permitted and must be DOCUMENTED**, because an embedder porting between the two C
APIs would otherwise disarm a ceiling by writing the same zero.

🎓 **A LESSON FROM VERIFYING THIS, and it sharpens §4 checks 6 and 7.** The pen-holder's first run put
`--max-iterations` **after the export name** — a guest position — so it never applied; the run then
exited **rc 1** anyway, from an argument-count error. ⚠️⚠️ **An `rc != 0` assertion would have recorded
that as the bound working.** H7's warning is the only reason it was caught. **So a differential check on
the bound must assert the TRAP, not merely a non-zero exit** — and must place the flag in a host
position, which differs between the two CLIs. *The check that only reads the exit code passes for the
wrong reason, which is worse than failing.*

#### The agreed design — what wasmrt must implement to close it

| item | agreed value | why it is in the contract |
| --- | --- | --- |
| **the unit — ONE ITERATION** | **one loop back-edge, OR one tail-call hop** | 🎯 **THIS IS THE ROW THAT MATTERS.** Two runtimes with "a limit of `1<<30`" that COUNT DIFFERENT THINGS are not swappable: a module finishing just under the ceiling on one traps on the other. Aligning the number while leaving the unit unstated would look like agreement and behave like divergence. **Counting instructions instead of back-edges is a contract breach even at the same number.** |
| **default** | **`1 << 30`** (1,073,741,824) | measured, not chosen — see below |
| **scope of the budget** | **per top-level invocation**, refilled on entry | so a long-running host loop calling many short guest functions is never starved |
| **re-entry** | a host callback calling back in **inherits the remainder**; it does NOT refill | a guest that can refill its budget by bouncing through a host function does not have a budget |
| **what happens** | a **trap** — an ordinary trap on the runtime's normal trap path | not an abort, not a process exit |
| **CLI flag** | `--max-iterations <count>`, in the **leading run of host flags** (§2.4) | position is part of the flag contract, not a detail |
| **`0` at the CLI** | **unlimited** | |
| **the message** | must state the **ceiling that was hit** and **how to raise it** | |
| **what it must NOT claim** | it bounds non-termination; it does **not** detect an infinite loop | a legitimately long-running module trips the same trap, and its owner needs to be told to raise the ceiling — not told a falsehood about their program |
| **a count, NOT a clock** | binding | a wall-clock deadline makes the same module trap on a slow machine and pass on a fast one — the two runtimes would then disagree *by machine*, which is unswappable by construction. It also cannot be enforced without a thread and a clock, which the freestanding target does not have. |

⚠️ **Why the tail-call tick is called out separately: a back-edge counter alone looks complete and is
not.** A local `return_call` reuses the interpreter's native frame *by design*, so it makes no backward
branch and grows no call depth — the call-depth ceiling cannot see it either. `(func $f (return_call
$f))` runs forever under a back-edge-only design. **Both runtimes recurse natively for `call` and both
implement tail calls, so this applies to both.** ⚠️ It is also the tick whose absence is invisible to an
obvious test: delete it and the loop test still passes.

**The default is measured, and the method transfers** — run the spec corpus at descending budgets until
it breaks. wazmrt's result (284 files): green at `1<<20`; at `1<<18` **only** `return_call`,
`return_call_indirect`, `return_call_ref` fail; at `1<<14`, 36 failures across 8 files. The heaviest
legitimate workload in the suite is `return_call.wast`'s **million-hop chain**, which fits under `1<<20`
with under 5% to spare — so `1<<30` is ~1000x the measured peak. ⚠️ **wasmrt should re-run this against
its own corpus rather than adopting the number on trust**; if its peak differs materially, that is a
finding about one of the two engines and belongs in §4 as an observation.

⚠️ **Keep the new error OUT of the "is this a spec trap?" predicate** in the `.wast` runner (wazmrt:
`isRuntimeTrap`). An engine resource cap must not satisfy an `assert_trap` meant for real trapping
behaviour — and excluding it has a second payoff: **the conformance corpus becomes a live gate on the
ceiling**, failing loudly when the budget is set too low instead of banking the timeout as the expected
trap. That is what made the measurement above possible.

**REOPEN / CLOSE CONDITION:** this row becomes ✅ AGREED when wasmrt ships the bound with the same unit
and default, and the differential table above is re-run with both trapping. **Until then a deployment
that swaps wasmrt in loses the protection silently** — there is no error, the workload simply never
returns. *(Same failure shape as the pin-DB path risk in §3.3: a swap that disarms without saying so.)*

#### Where each side tracks the work

| project | item | state |
| --- | --- | --- |
| **wazmrt** | Track **H3** (hardening, ships as `1.0.1`) | ✅ **built 2026-08-19** — `--max-iterations`, `IterationLimitExceeded`, 4 tests covering both shapes + the no-false-positive and refill directions; corpus descent measured; cost exe +1,024 B / lib +512 B / **dll +0** |
| **wasmrt** | **T9i** (ships as `1.0.1`) | ✅ decided, `[ ]` not yet built — owner: *"3 has already been decided in the wazmrt project, just follow their lead"* |

✅ **The two designs were written independently and agree** — `u64::MAX` filled at refill for
"unlimited", the two `0` conventions, the trap excluded from the `.wast` runner's spec-trap predicate,
the refill/re-entry rule, and the message wording. That agreement is *evidence the contract is
specific enough to build from*, which is the only thing this file is for.

⚠️ **wasmrt's plan caught a real gap on wazmrt's side, which is this file working as intended.** T9i
requires **A/B/A throughput benchmarking** around the change, because wasmrt has a recorded case
(T9a#7) of threading state through the same interpreter loop costing **3.6%**. wazmrt had measured only
SIZE (+1,024 B exe, +512 B lib, **+0 dll**).

✅ **wazmrt has since run it, and the cost is real: ~3% on a tight loop.** A/B/A on the steady bench
(`sum(1e6)` ×50, ReleaseFast), removing and restoring both tick sites: **34.29 → 33.45 → 34.62
ns/loop-iter** (233 → 239 → 231 Mops/s). A-to-A spread is ~1%, so the ~3% A-vs-B gap is above this
box's noise but close enough to it that **B is a single sample and deserves a repeat**. The tick sits
in the hottest loop in the program and the bench is dominated by back-edges, so this is close to a
worst case rather than a typical one.

📌 **Recorded for wasmrt's planning, NOT as a contract row — §0 puts performance explicitly out of
scope**, and no row may be justified by what the other one measured. **Expect a few percent; it is not
a defect.** ⚠️ **But one performance response WOULD be a contract change:** amortizing the tick to
every *N*th back-edge alters the **granularity of the unit**, so the same ceiling would stop meaning
the same thing on both sides. Neither project may do that unilaterally.

---

## 4. The differential checks that keep this honest

⚠️ *Two implementations of one spec are a free differential oracle; not using them against each other is
the waste.* These checks are the contract's only real enforcement — a row marked ✅ that nothing re-runs
decays exactly like any other claim.

| # | check | catches |
| --- | --- | --- |
| 1 | **byte-compare the two copies of this file** | the drift hazard in §1 — the one failure that makes every other row meaningless |
| 2 | **assemble the shared `.wat` corpus with both, diff the SHA-256 of the outputs** | ⚠️ a pinned `.wat` that validates under one runtime and is refused by the other. **Not hypothetical** — wasmrt has four recorded defects where its emitter produced a different module than the text described. If the assemblers disagree, **only `.wasm` digests are portable** and that must be documented, not discovered |
| 3 | **run the same pin DB + the same module under both**, across all nine `decide()` rows | a policy that is honoured *differently*, which is worse than not being honoured |
| 4 | **row-by-row diff of the WASI rights tables** (§3.6) | the original finding that opened this file: a right present in one and absent in the other, where the read-only test passes trivially because the right is not in the mask |
| 5 | **the same CLI invocation under both**, for every row of §2 | the `--dir` separator class — a flag that does not error and does the wrong thing |
| 6 | ⚠️ **UPDATED v19 — assert the TRAP, not merely a non-zero exit, and place the flag in each CLI's own host position.** The pen-holder's first run of this check put `--max-iterations` after the export name, where it was guest argv and never applied; the run exited **1** anyway from an argument-count error, so an `rc != 0` assertion would have recorded the bound as working. · **run a non-terminating module under both, under a timeout** — one `.wasm` containing `(loop (br 0))` **and** `(func $f (return_call $f))`, both shapes, both runtimes, low `--max-iterations` | §3.7a. ⚠️ **Must be run under a timeout and must assert the EXIT, not the output**: the failing side produces no output at all, so a check that greps stdout passes vacuously against a hung process. The two shapes are separate cases on purpose — a back-edge-only implementation passes the first and hangs on the second |
| 7 | **the same module at a budget just under and just over its true cost**, both runtimes | that both count the SAME UNIT (§3.7a). Equal defaults with different units disagree only near the ceiling, which is exactly where nobody looks |
| 8 | 🆕 **an unknown flag in EVERY host-flag position under both** — first argument, before the path, the leading run after the path, and a `.wast`/`wat` invocation — **and in the guest positions, asserting it is UNTOUCHED** (§2.4a, v11, **as narrowed by v15**) | ⚠️ the Z2 class: a mistyped host flag that vanishes into the guest's argv. **The negative half is the load-bearing half** — a check that only asserts the error will be "fixed" by a parser that errors on the guest's own `-la`, which v15 explicitly permits and `prog.wasm install --yes` explicitly forbids. 🆕 **Run the dash-count cases in BOTH mode families** (`_start` present and absent): the single-dash carve-out applies only where there is guest argv, so a check that uses one module shape will bless the wrong behaviour in the other |
| 9 | 🆕 **summarize an INVALID module under both and grep EVERY output line for a validity claim** (§2.5, v12) | ⚠️ the Z3 class. **Assert on the whole output, not the exit code** — the exit code was already right on both sides when Z3 was found, so a check that reads only `rc` passes vacuously against the exact defect it is named for |
| 11 | 🆕 **a position-restricted flag written in the WRONG host position, under both** — and, separately, in a guest position asserting it is untouched (§2.4b, v16) | ⚠️ the silent-drop class on a flag that RESTRICTS. **Assert the exit status, not the message**: the failure mode being guarded is a **successful** run that ignored the flag, so a check that greps stderr for wording passes vacuously against a build that dropped the flag and said nothing |
| 10 | 🆕 **name an export the module does not have, under both, on every call form** (§2.3 Z1 row, v13) | ⚠️ the Z1/F1 class, and it is **live on both sides today** — wazmrt's bare path and wasmrt's bare path both exit 0. **Every call form** is deliberate: wasmrt's `run` passes this and its bare path fails it, so a one-form check would have reported the project compliant |

⚠️ **A disagreement found by any of these is recorded as an OBSERVATION until its cause is traced.**
Neither runtime is the oracle, so "the other one does X" is not a diagnosis.

---

## 5. Owner decisions this file is waiting on

| # | decision | why it blocks |
| --- | --- | --- |
| ~~1~~ | ~~**The shared pin DB path** (§3.3)~~ | ✅ **DECIDED by the owner 2026-09-19 and FOLDED IN AS v18** — the shared `wasmtk` path, per-runtime fallback, **and a loud warning when a runtime finds no DB where its sibling would have found one.** 🎓 *This file's most dangerous row since v1, and what closed it was not the path but the warning.* ✅ wasmrt implements it (T9e, mutation-verified); ⏳ **wazmrt to adopt the order AND the warning** — Track B-b. ⚠️ **REOPEN if either side ships the path without the warning**, which is the partial fix that leaves the migration window open |
| 2 | **Who accepts whose CLI spelling, and by when** (§2.1) | the additive plan needs both halves; `wasmrt wat` and `wazmrt pin` each exist on one side only |
| ~~3~~ | ~~**Fuel / execution bound** (§3.7)~~ | ✅ **DECIDED by the owner 2026-08-19** — a bound is wanted, with an error message and a break. Design agreed in **§3.7a**. ⚠️ **The decision is closed; the DIVERGENCE is open**: wazmrt ships it, wasmrt does not, and the predicted failure ("a workload that completes under one hangs under the other") is **verified live**, not hypothetical |
| ~~5~~ | ~~**When does wasmrt land the execution bound** (§3.7a)~~ | ✅ **CLOSED 2026-09-19 — wasmrt shipped it (T9i), FOLDED IN AS v19**, and the pen-holder re-verified by running both on the same bytes: all four cells trap, `rc 1`, both messages naming the ceiling and how to raise it. Defaults independently re-measured on each corpus to the same shape. ⚠️ **REOPEN if either side amortizes the tick to every *N*th back-edge** — that changes the UNIT's granularity, and the ceiling stops meaning the same thing on both sides |
| 6 | **Attribution of commit `7ce0dcd2` in the wasmrt repo** | wasmrt reports it committed **wazmrt's** §3.7a rewrite into its tree as if it were its own, before the collision was noticed. ⚠️ **wazmrt cannot fix this — §1a forbids writing to that tree**, and rewriting another repo's history is not an agent's call anyway. It is exactly the tracking-integrity problem the boundary was added to prevent, and it is now **behind** the rule rather than in front of it. Options: leave it with the collision documented in row 3b, or have the wasmrt session amend/annotate it **in its own tree** |
| 7 | **Whether coordination should run in ONE session at a time** (§1c) | §1a removes the cross-tree risk by construction, but two sessions editing the *same* copy still resolve last-write-wins with nothing to detect it. wasmrt proposed the discipline; it costs nothing and closes the residual gap |
| ~~4~~ | ~~**Exit-code table** (§2.3)~~ | ✅ **CLOSED 2026-09-19 by MEASUREMENT rather than by a decision — v13.** Both runtimes already return `1` for every host-side failure kind and every trap (§2.3m, plus the pen-holder's own re-run); §2.3 row 3 is now ✅ AGREED and no table is needed. 🎓 *The decision had been waiting on the owner for a month for want of somebody running twelve commands.* ⚠️ **REOPEN if either side ever emits a second non-zero code.** |
| ~~8~~ | ~~**Unknown flags**~~ (§2.4a) | ✅ **DECIDED by the owner 2026-09-19** and ✅ **FOLDED IN AS v11** by the pen-holder the same day: an error saying `unknown flag`, rc 1, in every host-flag position. wasmrt complies (re-verified by running it); **wazmrt to adopt — tracked at Track B-b.** |
| 10 | 🆕 **Does v14's "no looks like" reach flag VALUES — specifically §2.2's `--dir` drive-letter fallback?** (§2.2, §2.4a-i) | ⚠⚠ **The one AGREED row in this contract that is built on a heuristic**, and v14 forbids heuristics. Raised by the pen-holder on the day v14 was folded in; **not overridden**, because repealing an agreed row by implication is the unilateral move §1 forbids. **The options all cost something:** require `::` everywhere → breaks existing wazmrt invocations; error on every ambiguous `:` → breaks `--dir .:/`, the form the docs use; keep the heuristic → v14 has a documented exception on its first day. ⚠️ **Until it is ruled, `--dir` stays as agreed** |
| 11 | 🆕 **Should H7's WARN become an ERROR?** (§2.2 position row, §2.4a-i) | a *known* host flag in a *guest* position warns today, because it may genuinely be the guest's. v14 does not reach it — the host/guest split is **grammar, not resemblance** — but it is the rule's nearest neighbour. ⚠️ **Erroring would break `prog.wasm install --yes`**, which §2.4 says must reach the guest untouched, so this is a real trade and not a tightening |
| ~~9~~ | ~~**Truthful validity claims in output (Z3)**~~ (§2.5) | ✅ **DECIDED by the owner 2026-09-19** and ✅ **FOLDED IN AS v12** by the pen-holder the same day: in scope as the one output-text exception (§0). wasmrt complies (re-verified); **wazmrt to adopt — tracked at Track B-b.** |

---

## 6. Change log

| version | date | change |
| --- | --- | --- |
| **20** ⏳ | 2026-09-19 | ✅ **§2.1/§2.2 — wasmrt's COLUMN IS GREEN (T9e); wazmrt's halves are what remain.** Verified by building wasmrt's committed code into the pen-holder's own scratch target (nothing written to their tree, §1a) and running it: bare `<module> <export>` returns **5**, `.wast` by extension, `pin <file>`, **both `--dir` separators**, and **both feature vocabularies**. 🎯 **F1 IS CLOSED** — measured live earlier in this same session, fixed hours later. ⏳ **Outstanding on wazmrt:** the four subcommand spellings (all → `cannot read 'run'`), `::`, the hyphenated feature vocabulary (`bulk-memory-operations` → `unknown proposal`), and Z1–Z4. ⚠️⚠️ **NEW DEFECT FOUND BY THIS PASS — §2.2z: `--dir .:/` DOES NOT WORK ON wazmrt, and it is the example wazmrt's own `--help` prints.** The split guard is `i > 1` (a Windows drive-letter guard), so a **one-character relative host path** is indistinguishable from a drive letter and is never split; `./:/` works, `.:/` does not. 🎓 **Three things at once:** a live defect, a §2.2 claim carried since v1 that was **written from reading and never run** (the fourth such error across the two projects), and 🔒 **§5 #10 made concrete** — the "looks like a drive letter" heuristic giving a wrong answer on ordinary input. ⚠️ **Adding `::` alone would not fix it.** 📌 **`multi_table` recorded as an OBSERVATION, not a row** — §0 puts engine modelling out of scope — but the observable consequence is stated: the same `--features` line does not gate the same thing on both. **REOPEN** when one accepts a module the other refuses on that basis. |
| **19** ⏳ | 2026-09-19 | ✅ **§3.7a IS CLOSED — wasmrt implements the execution bound (T9i), and this closes §5 decision #5.** Re-verified by the pen-holder by RUNNING both on the same bytes at `--max-iterations 1000000`: `(loop (br 0))` and `(func $f (return_call $f))` **both trap on both runtimes**, rc 1, each message naming the ceiling and how to raise it. The differential table that opened the section — wazmrt trapping, wasmrt hanging — is green in every cell. 🔬 **wasmrt re-measured the default on its own corpus** rather than adopting it: green at `1<<20`, `return_call`/`return_call_ref` failing at `1<<19`, 36 failures at `1<<14` — **the same shape as wazmrt's descent**, so `1<<30` is a measured default on both rather than a shared guess. ⚠️ **The C ABI takes `0` as "leave the default", not "unlimited"** — an embedder must not disarm a ceiling with a zero, while a person at a terminal may. **Recommended, not binding** (§0 keeps the C ABI out of scope); if wazmrt picks the other convention it must be **documented**. 🎓 **A lesson that sharpens §4 check 6:** the pen-holder's first run put the flag in a guest position, it never applied, and the run exited **1** from an argument-count error — **an `rc != 0` assertion would have called that the bound working.** Assert the trap. |
| **18** ⏳ | 2026-09-19 | 🔒 **OWNER: THE PIN DB PATH IS DECIDED — §3.3, and §5 decision #1 CLOSES.** `/etc/wasmtk/pins` · `C:\ProgramData\wasmtk\pins`, named for the deployment both runtimes ship inside, **each runtime's own path kept as a fallback**, and 🔒 **a loud warning when a runtime finds no DB where its sibling would have found one** instead of quietly computing `armed = false`. ✅ wasmrt implements exactly that (T9e) as a pure function with a mutation-verified test. 🎓 **This was the most dangerous unresolved row in the file since v1, and what closes it is the WARNING, not the path.** A shared path alone still fails silently during a part-migrated deployment — the binary swaps, the DB sits at the sibling's old path, and `armed = false` is an ordinary state with no error attached. *The failure mode was never "no DB"; it was "no DB, and no reason to think that is wrong."* ⏳ **wazmrt to adopt the order AND the warning AND a test that the warning fires** — ⚠️ **adopting only the path is the dangerous partial fix**, closing the both-new case and leaving the migration window, which is the window an operator is actually in. Track B-b. |
| **17** ⏳ | 2026-09-19 | ⚠️⚠️ **Z4 — `.wat` PIN DIGESTS ARE NOT PORTABLE BETWEEN THE TWO RUNTIMES, and it is wazmrt's to fix.** §3a said to make the `.wat` agreement a **test** rather than an assumption; run, it fails. wasmrt measured 2 agree / 529 differ over 535 files; 🔬 **the pen-holder re-ran it over the whole 959-file `wasmtk` tree and got the same shape: 2 agree, 952 differ.** ✅ **The diagnosis is confirmed byte-for-byte, not taken on trust:** wasmrt's assembled `mathlib.wat` hashes to its own pin digest, and the same bytes under `wasm-tools strip --all` hash to **wazmrt's pin digest exactly**; `objdump` shows the sole difference is a 2020-byte `custom "name"` section. 🎯 **The exceptions prove the mechanism — the only two files of 959 that agree are the only two with zero `$identifiers`**, so there are no names to emit and no section to differ by. 🔒 **It fails CLOSED** (a `.wat` pinned under one runtime is *refused* under the other), so it is an operational break, not a hole — **but only `.wasm` pins are portable until it is fixed**, and an installer pinning `.wat` must pin per runtime. 📬 **The ask: emit the `name` section from the identifiers the text carries**, as wasm-tools and wasmtime do — 🔒 which also matches the owner's standing direction **not to discard information the source carries**. ⚠️ **Z4 is not "match wasmrt's bytes"; it is "stop throwing the names away"** — the digests converging is the test, not the goal. Track B-b. |
| **16** ⏳ | 2026-09-19 | 🔒 **OWNER: A FLAG WITH A REQUIRED POSITION, WRITTEN WHERE IT CANNOT APPLY, IS AN ERROR — §2.4b.** *"we need an error thrown when it is in the wrong location."* The flag must also state its position in the **usage/invocation** section, not only in its own entry — *a constraint documented only where the reader already knows to look is not documented.* ⚠️⚠️ **Found a live fail-OPEN defect in wazmrt, which is why this is a contract row and not a help-text fix:** `wazmrt m.wasm --features mvp` exited **0** having run under the **FULL feature set**, silently. `--features` is the one flag whose entire job is to REFUSE modules, so a user asking for a smaller trusted computing base got everything enabled with no error, no warning and a success status. 🎓 **It fell between the two mechanisms built to prevent exactly this:** `flagRegion` deliberately excludes `--features` (so a guest's own `--features mvp` can never narrow the language), and H7 warns only for names in those same lists — *a rule that names the things it guards will not guard the thing it does not name.* ✅ **Shipped in wazmrt** (`misplacedFeaturesFlag`), two tests, inversion-proven, suite green at 767. ✅ **wasmrt is not in breach** — it has no CLI `--features` yet; the row binds it when it adds one. 🆕 **§4 gains check 11**, written to assert the **exit status** rather than the message, because the fault being guarded is a *successful* run that ignored the flag. |
| **15** ⏳ | 2026-09-19 | 🔒 **OWNER NARROWS §2.4a THE SAME DAY IT WAS WRITTEN — after the module path, a SINGLE DASH is the guest's.** Position 3 now splits by **dash count**: an unknown **`--flag`** errors; a **`-flag`** is guest argv and needs no `--`, so `prog.wasm -la` runs. 🎯 **The reasoning is a closed enumeration, not a preference:** *every* host flag legal after the path is double-dash (`--dir`, `--ro-dir`, `--env`, `--max-*`, `--pins`, `--verify`, `--no-verify`, `--yes`, `--features`, `--allow-symlink`); the single-dash names `-h`/`-v` are first-argument-only (§2.4); and the subcommand flags (`wast -v`, `wat -o`) live in modes with **no guest argv**. So a single-dash token there **cannot be a host flag** — nothing to disambiguate. ⚠️ **The cost is recorded, not smoothed over:** a mistyped `-dir /tmp` now reaches the guest silently. 🔒 **The owner was offered a "looks like a host flag" warning for precisely that case and refused it**, which is the same decision as v14 arriving from the other direction — *a near-miss list is itself a thing that would drift between two runtimes.* ✅ **The narrowing REMOVES work from wazmrt rather than adding it:** passing `-la` to the guest is what wazmrt already does, and pre-narrowing v11 would have had us break it. 🚨 **§1c HAPPENED AGAIN, DURING THIS PASS, AND IT IS THE REASON THIS ROW IS SEPARATE FROM v11.** wasmrt's session recorded the narrowing in its copy while this session was folding the **pre-narrowing** text in as v11 — two sessions, one hour, each correctly editing only its own copy (§1a held; nothing was destroyed this time). 🎓 **§1a fixed the destructive half of the collision and did nothing about the wasted half**, which is what §1c predicted and what §5 #7 proposes to close. v11 is left standing and amended here rather than rewritten: **their copy already records that wazmrt folded in the wide text as v11**, so editing v11 in place would make the two histories disagree about what happened. |
| **14** ⏳ | 2026-09-19 | 🔒🔒 **OWNER: NO "LOOKS LIKE" — §2.4a-i.** *"improper cli options should throw an error. We should have no 'looks like' built in so that it interprets a cli. If it is a valid cli option run it, if not throw and error."* **The general rule that v11/§2.4a is one instance of.** In a host-flag position an argument is **exact-matched or rejected**: no path-guessing, no fuzzy/"did you mean" adoption, no prefix abbreviation, no "probably the guest's" inference. 🎯 **Its first casualty is a message, not a behaviour:** wazmrt's `--bogus m.wasm` already exits 1, but says *"cannot read '--bogus': FileNotFound"* — **right code, and it sends the user to the filesystem to debug a typo'd flag.** v11 had logged that as "the wording"; v14 makes it a breach of a rule. ⚠⚠ **GRAMMAR IS NOT RESEMBLANCE, and that distinction is what makes v14 implementable** — the host/guest boundary (`--`, and the first non-flag argument after the path) is fixed by the shape of the line, not by judging arguments, so a guest's argv is not "an option wazmrt failed to recognise". Without that carve-out `prog.wasm install --yes` could not be written, and §2.4 records what that costs. ⚠️ **TWO TENSIONS RAISED, NEITHER DECIDED HERE:** §5 **#10** — §2.2's `--dir` drive-letter fallback is itself a resemblance rule, **the one heuristic this contract has AGREED to**, and it is a flag *value* rather than a flag *name*; §5 **#11** — whether H7's warn should become an error. 🎓 *The pen-holder does not get to repeal an agreed row by implication, and a new general rule is exactly the moment that temptation arrives.* |
| **13** ⏳ | 2026-09-19 | 📎→📒 **wasmrt's §2.3m ANNEX FOLDED IN by the pen-holder (wazmrt, regime A).** Two rows change. 🆕 **§2.3 gains the Z1 row** — naming an export the module does not have is a **failure**, never a silent fall-back to summarizing — and it is written as binding on **BOTH** sides, because on the day it was folded in **neither was clean**: `wazmrt m.wasm nosuch` → rc 0, and so does `wasmrt m.wasm nosuch` (**F1**, re-verified here, still live; wasmrt's compliance is via its `run` subcommand only). ✅ **§2.3 row 3 promoted ⬜ → AGREED**: every host-side failure and every trap → `1` on both, `proc_exit(n)` → `n & 0xff`, measured twice — wasmrt's 18-row matrix and the pen-holder's own 12-case re-run on the same bytes. **That closes §5 decision #4 with no per-kind table**, because neither implementation distinguishes kinds. 🆕 **§4 gains checks 8, 9 and 10**, one per new rule, each written so the *vacuous* pass is impossible: check 9 greps the output because the exit code was already right when Z3 was found, and check 10 runs every call form because a one-form check would have called wasmrt compliant. 🔎 **The re-run also narrowed Z1**: `wazmrt invalid.wasm bad` already exits 1, so the dropped export name is specific to a module that **validates** — the run where nothing else went wrong is the one that silently does the wrong thing. |
| **12** ⏳ | 2026-09-19 | 🔒 **OWNER DECISION FOLDED IN AND NUMBERED — §2.5, a validity claim in the output must match the verdict (Z3).** Owner: *"we also need a contract item for Z3"*. No line a command prints may call a module **valid** unless it validated; a summary printed before validation finishes must use neutral wording. ⚠️ **This carves the ONE exception into §0's "output text is out of scope"**, and the carve-out is the load-bearing part: *a validity claim is not style, it is a verdict a human reads*, and §0 would otherwise have made Z3 unfixable by construction. Everything else a command prints stays out of scope. **wasmrt complies** (`invalid.wasm: WebAssembly module (version 1)`), pinned by `cli_exit_codes.rs::the_summary_never_calls_an_invalid_module_valid`, mutation-verified against wazmrt's own header wording. ⚠️ **wazmrt is in breach and its exit code is RIGHT** — `invalid.wasm: valid wasm v1, 5 section(s)` … `validation: FAILED`, rc 1 — which is precisely why this needed a row: **every gate wazmrt owns was already green on it.** Tracked at Track B-b. |
| **11** ⏳ | 2026-09-19 | 🔒 **OWNER DECISION FOLDED IN AND NUMBERED — §2.4a, the unknown-flag rule.** Owner: *"I do want an 'unknown flag' rule in the contract that throws an 'unknown flag' error."* A flag-shaped argument in a **host-flag position** that the command does not recognise stops the run: stderr says **`unknown flag`** and names it, rc **1**. 🎯 **It resolves Z2's tension by POSITION, which is the whole design** — host positions (first argument, before the path, the leading run after the path, and every argument of a command with no guest argv) **error**; guest positions (after `--`, and after the first non-flag argument following the path) are **never examined**, so `prog.wasm install --yes` is untouched and §2.4's fail-open trap stays shut. ⚠⚠ **SUPERSEDED IN PART BY v15, the same day:** this row's rule put a guest's own `-la` directly after the path into a **host** position (`-- -la` required). **The owner narrowed that within the hour** — a single-dash token there is the guest's and runs as written. The row stands as the record of what was folded in; **§2.4a's text is the narrowed rule.** **Complementary to H7, not a replacement** — a *known* host flag stranded in a guest position still only **warns** (it may be the guest's own); an *unknown* one in a host position **errors**. wasmrt complies in all four host positions (re-verified by running it), pinned by `cli_unknown_flag.rs`. ⚠⚠ **wazmrt is in breach in three of four**: rc 0 after the path, rc 0 in `.wast`, and rc 1 for the wrong reason (*"cannot read '--bogus'"*) before it. Tracked at Track B-b. |
| **owner decisions** 🔒 | 2026-09-19 | *(Recorded by wasmrt; NOT a version number. Regime A: the pen-holder numbers them on fold-in.)* **§2.4a unknown-flag rule** and **§2.5 truthful validity claims** decided by the owner. **§2.3 gains a Z1 row.** **§0** carves §2.5 out of "output text is out of scope". **§2.5h hands Z1–Z3 to wazmrt** (owner: *"pass all three issues to the wazmrt team"*). wasmrt already complies with all three, pinned by `cli_unknown_flag.rs` and `cli_exit_codes.rs`. |
| **annex** 📎 | 2026-09-19 | *(wasmrt contribution, NOT a version — offered for fold-in.)* 🔬 **§2.3 MEASURED by running both (§2.3m).** Copies byte-identical at v10 beforehand. **Row 2: wasmrt was in breach three times** (summarize of an invalid module, no arguments, `wast` on failures), all exiting 0 where wazmrt exits 1. **Fixed on wasmrt's side with no contract change**, pinned by `cli_exit_codes.rs`; an 18-row matrix now agrees throughout. **Row 3: both already use 1 for every host failure and every trap** → proposed promotion to ✅ AGREED, which closes §5 #4. **For wazmrt:** Z1, an unmatched export name is silently ignored with rc 0 (F1's mirror); Z2, unknown flags have no row and diverge (🚦 owner/pen-holder); Z3, the header says "valid" for an invalid module (text, out of scope). |
| **annex** 📎 | 2026-08-19 | *(wasmrt contribution, NOT a version — wazmrt leads and holds the pen; offered for fold-in.)* |
| *(annex detail)* | 2026-08-19 | 🔬 **§4 CHECK 5 RUN FOR THE FIRST TIME — the CLI rows verified by RUNNING both binaries, not by reading either** (§2.1m). wasmrt 0.9.0 vs wazmrt 1.0.0, same box. **Five findings.** ⚠⚠ **F1: the two “call an export” gaps fail in OPPOSITE directions** — `wasmrt add.wat add 2 3` exits **0** printing a summary and silently ignoring the export and its arguments, while `wazmrt run …` exits **1** and says why; same missing capability, and wasmrt's half is the silent-wrong-output one, so it outranks the other. **F2: the “summarize” row was marked ✅ AGREED and the output text is NOT identical** (behaviour and exit code do agree) — the word “identical” had been written from reading. 🆕 **F3: FLAG POSITION differs and had no row at all** — wazmrt's flags follow the module path, wasmrt's precede it, and ⚠⚠ **a trailing `--dir` under wasmrt is passed to the GUEST, so the sandbox is silently never granted.** 🔻 **F4: a CORRECTION — §2.2’s claim that a single-colon `--dir` “does not error, it preopens the wrong thing” is FALSE; measured, it fails loudly** (`errno 29`, rc=1). That claim had been carried as ⚠⚠ since v1 and was written from reading the code. **F5: `-v` output shape differs** (1 line vs 2). ⚠ Everything check 5 did not reach — the `.wast` row, `--ro-dir`, `--allow-symlink`, `--env`, the ceiling flags, `--`, and all of §2.3’s per-failure exit codes — stays ⬜ UNVERIFIED and **may not be quoted as agreed.** |
| **10** | 2026-08-19 | 🆕 **wazmrt WARNS on a misplaced flag (§2.2 position row) — H7, and F3 is what found it.** wazmrt recognises host flags only in the LEADING run after the module path; the inverse of that protection had never been asked, so a flag written after a guest argument was **silently donated to the guest and never applied**. Fail-closed for `--no-verify`/`--dir`, ⚠️ **fail-OPEN for `--verify`, `--pins` and every `--max-*`** — a user asks for a restriction, gets no error, and runs without it. Now warns (never refuses: a guest may legitimately take `--dir` as its own argument), and **nothing after an explicit `--` is examined**. Zero bytes. 🎓 Demonstrated with `--max-iterations`, a flag wazmrt had added HOURS earlier in the same track — *a change's own new surface is the one place the audit that produced it will not look.* |
| **9** | 2026-08-19 | 🔻 **F4 FOLDED IN by the pen-holder (wazmrt, regime A).** §2.2's `--dir` paragraph still asserted *"it does not error; it preopens the wrong thing"* — the claim F4 measured and REFUTED (`rc=1`, `cannot preopen …: errno 29`). Corrected in place and downgraded ⚠️⚠️ → ⚠️: the divergence is real, its consequence is a **clean failure**, not a silent mis-preopen. 🎓 **A refuted claim left in the table is what the next reader quotes** — an annex records the finding, the table is what gets believed, so folding is the pen-holder's actual job. Third read-not-verify error across the two projects in two days, and the reason rule 4 exists. |
| **8** ⏳ | 2026-08-19 | 🗓️ **COORDINATION CADENCE (owner) — §1d: coordinate at the END of each track**, not continuously and not mid-track; then the project that is ahead **holds** until the sibling reaches the same boundary. Rationale: rule 4 verifies a row by RUNNING both, which needs something built and green — coordinating mid-track compares a settled implementation against a moving one. ⚠️ Does **not** weaken "coordinate BEFORE shipping a contract surface": *decide* before building, *verify and record* at the end of the track. Current application: wazmrt finishes **Track H**, then holds for wasmrt. |
| **7** ⏳ | 2026-08-19 | ✅ **ROW 3b's 🚩 IS DISCHARGED — §0.5 restored, from wazmrt's session context, the only place it survived.** ⚠️ **Restored as §1b, NOT as a verbatim §0.5:** three of its four parts had since been re-expressed better (the order in §1; the editing boundary in §1a, which the owner has since made ABSOLUTE and is stronger than what §0.5 introduced), so re-pasting it would have left two definitions of one order in one file — the exact drift this file exists to prevent. What was genuinely lost and is now back: **the ordered checklist** (including *"the sibling may cite a contract row that does not exist yet — that is a cue to WRITE the row"*, which is literally what T9i did), and *"`coordinate` is also the right response to discovering you have already diverged."* Adds **§1c** on wasmrt's diagnosis — *a version is a pin, not a lock* — plus owner rows 6 (the `7ce0dcd2` attribution, which wazmrt cannot fix without breaching §1a) and 7 (one coordination session at a time). |
| **6** ⏳ | 2026-08-19 | 🔒🔒 **THE EDITING BOUNDARY IS NOW ABSOLUTE (owner) — §1a.** *"Not to edit the other's md file unless specifically directed by me … each project needs to edit their own files … important for tracking and integrity."* **Neither project writes ANYTHING into the other's tree — including this file** — without a specific owner direction. `coordinate` is an order to CONFER, never a licence to WRITE. Supersedes the earlier "this file is the one thing you may write there" rule, which caused two destructive overwrites in one day (rows 3b, 4). Rule 1 rewritten: propose in your OWN copy, bump the version, mark ⏳ **PENDING MIRROR**, and TELL THE OWNER the sibling is behind — the owner directs the other project, which makes the edit in its own tree. A version mismatch is now a normal coordination signal, resolved by reporting, **never** by copying over it. ⚠️ **This row is itself pending mirror: wasmrt's copy is at 5.** |
| **5** | 2026-08-19 | wazmrt ran the **A/B/A throughput** measurement wasmrt's T9i plan called for (§3.7a): the tick costs **~3% on a tight loop** — 34.29 → 33.45 → 34.62 ns/loop-iter, A-to-A spread ~1%, B a single sample. Recorded for wasmrt's planning, **not** as a contract row (§0 puts performance out of scope). ⚠️ Names the one performance response that WOULD be a contract change: amortizing the tick to every *N*th back-edge alters the UNIT's granularity, so the ceiling would stop meaning the same thing on both sides. |
| **4** | 2026-08-19 | 🔒 **The EDITING BOUNDARY added to §1** (reconstructed from row 3’s description, since the §0.5 it named was destroyed): this file is the only thing either project may write into the other’s tree, and ⚠⚠ **read the other copy before overwriting it** — it starts untracked in both repos, so a blind copy is unrecoverable. §2’s owner ruling restored. The duplicate row-3 entries reconciled into 3 + 3b. |
| **3b** | 2026-08-19 | ⚠️⚠️ **A CONCURRENT-EDIT COLLISION, recorded rather than tidied away — the drift hazard §1 predicts, arriving on day one.** Both projects edited this file at once. wazmrt's §3.7a rewrite (better than what it replaced: it had *built* the feature and found that **the UNIT matters more than the number**) landed in wasmrt's tree mid-session and was committed there without being noticed; in the other direction, wasmrt `cp`-ed its copy over wazmrt's **untracked** working copy without checking it first, destroying wazmrt's in-flight **§0.5** — which row 3 below still references and which is **NOT PRESENT in either copy**. 🚩 **wazmrt must restore §0.5 from its own context; nobody else has it.** Restored here: the §2 owner ruling, dropped in the same collision. **Two lessons, both already in the rulebooks:** *a version is a pin, not a lock — it makes drift detectable, it does not prevent a simultaneous write*, and **check before you overwrite**, which is exactly the editing boundary row 3 was adding. ✅ **The 🚩 IS DISCHARGED — §0.5 was restored from wazmrt's session context as §1b; see row 7.** |
| **3** | 2026-08-19 | 🔑 **`coordinate` — the one-word binding order (§0.5), owner.** One word from the owner now obliges the full cross-project protocol: byte-compare both copies, read the sibling's **uncommitted** in-flight work, diff shipped behaviour against every in-scope row, **verify by RUNNING both on the same bytes**, land changes in both copies with a version bump, and report divergences with reopen conditions. Carries **the editing boundary** — this file is the only thing either project may write into the other's tree, and the sibling's own `cmem/` stays theirs. |
| **2** | 2026-08-19 | **The execution bound (§3.7a).** Owner decided a bound is wanted; §5 decision #3 closes. wazmrt shipped `--max-iterations` + `IterationLimitExceeded` (default `1<<30`) in its Track H3 — ⚠️ **before this file carried it, which §1 rule 1 forbids; recorded as a process breach rather than tidied away.** New rows: the flag in §2.2; the agreed design in §3.7a, whose load-bearing clause is **the UNIT** (one loop back-edge **or** one tail-call hop) — equal defaults with different units are not swappable; differential checks 6 and 7. **Verified by running both on the same wasmrt-assembled bytes: wazmrt traps on both shapes, wasmrt hangs on both.** Status ⚠️ DIVERGENT AND LIVE until wasmrt lands it. |
| **1** | 2026-08-19 | Opened. Scope set by the owner (CLI options + security checks; C ABI explicitly out). Recorded: the `--dir` separator break and the bare-path-executes consequence, both live today; the pin DB path risk; the nine-row `decide()` matrix; the ceiling defaults, verified equal in both; the WASI rights rows already agreed. |
