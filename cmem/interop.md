# interop.md — the **wasmrt ⇄ wazmrt swappability contract**

**CONTRACT VERSION: 10 — wazmrt LEADS (owner, 2026-08-19).** wazmrt is finishing its hardening stage and **its copy is the latest**; wasmrt mirrors from it and **does not originate version numbers** until wasmrt reaches the same stage. 📎 **This copy also carries a wasmrt ANNEX** — the measured findings in §2.1m — **offered for fold-in by wazmrt, deliberately NOT numbered as a version** · opened 2026-08-19 (owner) · last change 2026-08-19 · **this file must be kept IDENTICAL
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
| `--dir <host>[<sep>guest]` | separator `:` | separator `::` | ⚠️⚠️ **DIVERGENT AND LIVE — see below** |
| `--ro-dir` | same separator issue | same | ⚠️⚠️ as above |
| **flag POSITION** relative to the module path | flags come **AFTER** the path — 🆕 **and a wazmrt flag written where only the guest sees it now WARNS** (H7, 2026-08-19); nothing after an explicit `--` is examined | flags come **BEFORE** the path | ⚠⚠ **DIVERGENT AND LIVE — MEASURED 2026-08-19 (F3).** wasmrt silently passes a trailing `--dir` to the GUEST, so the sandbox is never granted and nothing warns. |
| `--allow-symlink` | ✅ | ✅ | ✅ **AGREED** (both added 2026-08-10) |
| `--env KEY=VALUE` | ✅ | ❌ absent | ⚠️ **wasmrt must add** |
| `--max-memory <size>` | ✅ | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (the ceiling exists) |
| `--max-table-elems <count>` | ✅ | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (the ceiling exists) |
| `--features <list>` | ✅ | ❌ absent at the CLI | ⚠️ **wasmrt must expose** (gating exists in the C ABI) |
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

### 2.3 Exit codes

| behaviour | status |
| --- | --- |
| a WASI guest's `proc_exit(n)` becomes the process exit status (`n & 0xff`) | ✅ **AGREED** — verified in both, 2026-08-19 |
| success → 0, host-side failure (bad args, unreadable file, invalid module, refused by policy) → non-zero | ✅ **AGREED** |
| **specific non-zero codes per failure kind** | ⬜ **UNVERIFIED** — neither has been compared; a script that branches on a specific code is not yet portable |

### 2.4 Flag-parsing rules that are part of the contract

- **`-h`/`--help` and `-v`/`--version` are recognised as the FIRST argument only**, so a `--help` inside
  a guest's argv is never the host's. ✅ AGREED.
- ⚠️ **Verification flags are recognised only in the LEADING RUN of host flags.** Scanning "everything
  before `--`" is **not** sufficient: the common WASI form has no `--` at all
  (`… prog.wasm install --yes`), so the guest's own arguments get searched and a `--yes` meant for the
  guest **silently disables verification**. wazmrt paid for this; wasmrt must not re-buy it.

---

## 3. The security-check contract

### 3.1 What gets hashed — the TOCTOU rule

| rule | status |
| --- | --- |
| hash the **in-memory bytes about to execute**; never re-read by path | ✅ **AGREED** — `bytes-hashed == bytes-run` by construction |
| a `.wat` input hashes the **assembled** bytes, not the source text | ✅ **AGREED** |
| a `.wast` script hashes the **script bytes** — every module it can run is contained in them | ✅ **AGREED** |
| the file is read **once**; no path is reopened after load | ✅ **AGREED** in behaviour · ⚠️ **wasmrt is making it a compiler-checked type** (`Loaded { bytes, digest }`), wazmrt passes a slice — an implementation difference, not a contract difference |

⚠️⚠️ **`.wast` MUST BE GATED.** A script instantiates and invokes the modules it contains — including
`(module binary "…")` raw payloads. wazmrt shipped this bypass: `wazmrt payload.wast` ran unpinned,
unsigned wasm **even under a root-owned `# mode: enforce`**. **Any wasm can be wrapped in a `.wast`, and
the attacker chooses the extension, so the bypass needs no privilege.**

### 3.2 When the gate runs

| rule | status |
| --- | --- |
| the gate runs on a `will_execute` predicate; a pure **summarize/inspect** path is never gated | ✅ **AGREED** |
| the gate runs **BEFORE validation** — authorization first, so an unauthorized module is refused as *unauthorized* rather than parsed and reported on | ✅ **AGREED** |

### 3.3 The pin DB — a SHARED ON-DISK ARTIFACT

| item | agreed value |
| --- | --- |
| **location** | ⚠️ **DECISION NEEDED — see below.** Today: `/etc/wazmrt/pins` · `C:\ProgramData\wazmrt\pins` |
| ownership | **root-owned, read-only to the user, plaintext.** Integrity from **ownership, not secrecy** |
| format | one lowercase-hex SHA-256 per line; blank lines and `#` lines ignored; whitespace-separated text after the hash is a human label and is ignored |
| addressing | **content-addressed — no paths in the DB**, so moving or renaming an approved file does not re-open a hole |
| policy directive | `# mode: off\|warn\|enforce` — the policy inherits the DB file's **ownership** |
| pinning time | at **install** time, with privilege — a verified install, **not** TOFU |
| no encryption | a category error: encryption gives confidentiality; what is needed is integrity |
| no machine-binding | the attacker **is** the user |

⚠️⚠️ **THE PATH IS THE MOST DANGEROUS UNRESOLVED ROW IN THIS FILE.** If each runtime reads its own path,
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

### 3.7a The execution bound — ⚠️ **DIVERGENT AND LIVE, and the UNIT matters more than the number**

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
| 6 | **run a non-terminating module under both, under a timeout** — one `.wasm` containing `(loop (br 0))` **and** `(func $f (return_call $f))`, both shapes, both runtimes, low `--max-iterations` | §3.7a. ⚠️ **Must be run under a timeout and must assert the EXIT, not the output**: the failing side produces no output at all, so a check that greps stdout passes vacuously against a hung process. The two shapes are separate cases on purpose — a back-edge-only implementation passes the first and hangs on the second |
| 7 | **the same module at a budget just under and just over its true cost**, both runtimes | that both count the SAME UNIT (§3.7a). Equal defaults with different units disagree only near the ceiling, which is exactly where nobody looks |

⚠️ **A disagreement found by any of these is recorded as an OBSERVATION until its cause is traced.**
Neither runtime is the oracle, so "the other one does X" is not a diagnosis.

---

## 5. Owner decisions this file is waiting on

| # | decision | why it blocks |
| --- | --- | --- |
| 1 | **The shared pin DB path** (§3.3) | until it is decided, a swap can silently disarm verification |
| 2 | **Who accepts whose CLI spelling, and by when** (§2.1) | the additive plan needs both halves; `wasmrt wat` and `wazmrt pin` each exist on one side only |
| ~~3~~ | ~~**Fuel / execution bound** (§3.7)~~ | ✅ **DECIDED by the owner 2026-08-19** — a bound is wanted, with an error message and a break. Design agreed in **§3.7a**. ⚠️ **The decision is closed; the DIVERGENCE is open**: wazmrt ships it, wasmrt does not, and the predicted failure ("a workload that completes under one hangs under the other") is **verified live**, not hypothetical |
| 5 | **When does wasmrt land the execution bound** (§3.7a) | until it does, swapping wasmrt in **silently removes** the protection — no error, the workload just never returns |
| 6 | **Attribution of commit `7ce0dcd2` in the wasmrt repo** | wasmrt reports it committed **wazmrt's** §3.7a rewrite into its tree as if it were its own, before the collision was noticed. ⚠️ **wazmrt cannot fix this — §1a forbids writing to that tree**, and rewriting another repo's history is not an agent's call anyway. It is exactly the tracking-integrity problem the boundary was added to prevent, and it is now **behind** the rule rather than in front of it. Options: leave it with the collision documented in row 3b, or have the wasmrt session amend/annotate it **in its own tree** |
| 7 | **Whether coordination should run in ONE session at a time** (§1c) | §1a removes the cross-tree risk by construction, but two sessions editing the *same* copy still resolve last-write-wins with nothing to detect it. wasmrt proposed the discipline; it costs nothing and closes the residual gap |
| 4 | **Exit-code table** (§2.3) | only needed if scripts are expected to branch on specific codes |

---

## 6. Change log

| version | date | change |
| --- | --- | --- |
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
