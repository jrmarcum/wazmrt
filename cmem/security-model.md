# Security Model — threat model, trust chain, and the secure-by-default base

> ## ⚠️ STATUS: DESIGN ONLY — NONE OF THE AUTHENTICITY WORK EXISTS (2026-07-16)
>
> **wazmrt does not verify signatures today.** It will run any `.wasm` you hand it. Everything in the
> "Authenticity" and "Keystore" sections below is a *design under consideration*, recorded from the
> 2026-07-16 owner design conversation so it survives the session — **not a description of the
> runtime.** Only the "What holds today" section describes shipped behavior.
>
> **Phase 4.3 is paused pending the owner's decision here** (owner, 2026-07-16: *"I need to think about
> this before proceeding further. This is a base that I think we need to get right and create a secure
> by default base."*). Do not resume 4.3 without checking back.

## The vision this serves

**wasm as scripts; wazmrt as the base runtime.** One wazmrt install per machine; `.wasm` files are the
distributable unit, the way shell scripts are on Linux. Dispatch is host-side — either busybox-style
symlinks (`mytool -> wazmrt`, dispatch on `argv[0]`) or Linux `binfmt_misc` registering the `\0asm`
magic so `./mytool.wasm` is directly executable (the true shebang analogue; symlinks are the portable
option since Windows has no binfmt_misc).

**Clarification that resolves a live confusion:** *that* symlink is **host-side dispatch** — created by a
privileged installer, followed by the OS/shell, living outside any preopen. It is **not** the
guest-visible symlink of #17/`path_symlink`. **The vision does not require `path_symlink` at all.** The
two are unrelated layers; do not let the 4.3 symlink decision block this work, or vice versa.

## Two orthogonal properties — you need both

| | Question | Mechanism | Status |
| --- | --- | --- | --- |
| **Authenticity** | Is this the code I approved? | Signature verified against a trust anchor | **Not built** (this doc) |
| **Authority** | What may it touch once running? | Preopens + rights (the sandbox) | **Built** (#17, Phase 3) |

They do not substitute for each other. **A validly-signed module is *authentic*, not *harmless*** — it
still gets exactly the authority `--dir` hands it. A sandboxed module is contained but may be malicious
code you never approved. Ship both or the story has a hole.

## What holds today (shipped, verified)

- **A guest cannot execute anything.** Verified against the full WASI preview-1 surface (45 functions):
  there is **no `proc_exec`, no `spawn`, no `fork`, no `system`**. `proc_exit` terminates *self*. This is
  absent from the *specification*, not a wazmrt choice.
- **A guest cannot reach a non-WASI import.** `main.zig` backs `wasi_snapshot_preview1.*` from our table
  (unknown names → `NOTSUP` stub) and **every other module's imports with `unresolvedImport` → HostTrap**.
  A module declaring `extern "env" fn spawn(...)` traps on call; it does not get a mystery host function.
- **The preopen is the entire filesystem authority.** No `--dir` → zero reachable files.
- **Rights only narrow** — `path_open` intersects with the dir fd's inheriting rights; a guest cannot
  widen by reopening.
- **Symlink containment** (#17) — no symlink is traversed; a guest cannot be redirected out of a preopen.
- **Sockets are not implemented** (`sock_*` → `NOTSUP`).

**Therefore the only way a guest introduces code to the machine is: it writes a file, and something
*else* with real privilege executes it.** The wasm side is inert throughout. Privilege is always
supplied by the host, the shell, the orchestrator, or the user.

## Authenticity design (NOT BUILT)

### The principle: self-validation is impossible

**A file cannot validate itself.** If the validator is inside the artifact, an attacker who modifies the
artifact modifies (or deletes) the validator — there is no fixed point. An embedded **hash** cannot cover
itself, and even arranged cleverly the attacker simply *recomputes* it after tampering. A hash gives
**integrity against accidental corruption**, never **authenticity against a malicious editor**.

> **The signature may live inside the file. The trust anchor MUST live outside it.**

Asymmetric crypto is the whole answer: the `.wasm` carries a signature; the **verifier** holds the
trusted public key; an attacker may edit the wasm freely but cannot forge a signature without the private
key. This is exactly how Authenticode / JAR signing / signed packages work.

### Where the signature goes

A **wasm custom section** (e.g. `"signature"`) — arbitrary named sections that don't affect execution and
are ignored by runtimes that don't know them. We already parse custom sections (that's how #19 reads the
`name` section for trap symbols), so the decoder work is small.

- Sign a canonical hash of **every byte except the signature section**.
- Verify **before instantiating**; default-deny on absent/invalid.
- A module signed this way still runs in any other runtime (they ignore the section) — **no portability
  cost**.

**Prior art exists** (module-signing tooling using exactly this custom-section approach). **Unverified —
confirm the current state/format before leaning on it.** Adopting an existing implementation triggers the
**Adoption Checklist** in `third_party/LICENSES.md` per the project's own rule.

### Why this beats the thing it models

**Interpreters are the hole in OS code integrity.** IMA/Authenticode verify `/bin/bash` or
`powershell.exe` — the **script is just data** to an already-verified binary, so none of that machinery
covers it. (This is why WDAC needs PowerShell Constrained Language Mode and AppLocker needs separate
*script* rules.) Bash scripts get **no run-time integrity check at all**; package managers verify at
*install*, never at *run*.

wazmrt can close that gap because it *is* the interpreter:

> **OS verifies wazmrt → wazmrt verifies every script.**

"Wasm as scripts, except every script is signature-verified before a single instruction executes" is a
strictly better story than shell scripting. It is the pitch.

## The keystore (NOT BUILT)

Three reframes that shrink the problem:

1. **Tamper-*proof* needs hardware; tamper-*resistant* is what everyone ships.** Every chain terminates in
   something trusted for **non-cryptographic** reasons — firmware, silicon, physical possession. There is
   no software-only bottom turtle. "Unforgeable keystore" is an infinite chase.
2. **The keystore is not the weak link — the verifier is.** Anyone who can rewrite the keyring can rewrite
   `wazmrt.exe`, and that is the *easier* attack: don't forge a signature, just patch
   `if (!verify(...))` into `return ok`. **The keystore's integrity can never exceed the verifier's.**
   Hardening one without the other defends nothing.
3. **A verification keystore holds no secrets.** It holds **public** keys. The only property required is
   **integrity/authenticity of a public value** — *not* secrecy. No vault, HSM, or Secure Enclave is
   needed to verify. (The **private** key needs an HSM/YubiKey/KMS, but that lives with the *publisher*,
   on the signing side, and never touches the user's machine. Opposite requirements — do not conflate.)

### Which points to the architecture

**Embed the root public key in the wazmrt binary at build time.** Then *"how do I protect the keystore?"*
collapses into *"how do I protect wazmrt?"* — a problem with mature OS-native answers you must solve
anyway:

- **Windows** — Authenticode-sign wazmrt; enforce with **WDAC/AppLocker** (signed, optionally UEFI-locked
  policy).
- **Linux** — **IMA appraisal** or **fs-verity**, keys in `.builtin_trusted_keys` (compiled into the
  kernel image, which Secure Boot verifies — changing the anchor means rebuilding and re-signing the
  kernel).
- **macOS** — codesign + notarization; Gatekeeper enforces.

**Rotation without rebuilding:** the embedded root key signs a *keyring file*. The file may live anywhere
and rotate freely because its authenticity comes from the **signature**, not from file permissions. This
is Secure Boot's `PK → KEK → db` hierarchy and is the right shape here.

**Keyring as its own project** (owner's lean, 2026-07-16): good — small and auditable. **Make it a
library + a signed data file, not a daemon.** A verification *service* means wazmrt must authenticate the
daemon: a new link in the chain, guarding something that had no secrets. Signing *services* make sense
(isolating a private key); verification services mostly don't.

## Threat model — state the boundary honestly

| Attacker | What stops them |
| --- | --- |
| **Unprivileged** — malicious wasm, compromised build stage, user-level malware | **Filesystem permissions alone.** Root-owned artifacts. This is literally all apt/rpm do (`/etc/apt/trusted.gpg.d/` is root-owned). **This is most of the realistic threat.** |
| **Privileged (root/Admin)** | **Nothing, in software.** They patch the verifier. Goal shifts from *prevent* to *detect*: measured boot, TPM PCR sealing, audit. |
| **Offline** (has the disk) | Full-disk encryption; Secure Boot. |
| **Persistent across reboot** | TPM-sealed to PCRs — if the boot chain changes, the TPM won't unseal. Genuine tamper-*evidence*. |

**Realistic goal: make the unprivileged and remote attacker impossible, and the privileged attacker
detectable.** That is what every shipping system actually achieves. **Document that root defeats this** —
a system claiming otherwise is lying, and users make bad decisions on that basis.

## Orchestrator invariants — NOT enforceable by the runtime

From the multi-stage-pipeline analysis (2026-07-16). wazmrt cannot enforce any of these; an embedder
running stages must. **A runtime whose safe usage is undocumented gets used unsafely** — this section is
the deliverable that prevents that.

- **If the orchestrator takes instructions from the sandbox, the guest *is* the orchestrator.** Not via a
  bug — by design. The authority boundary only means something if the orchestrator's decisions are not
  derived from sandbox contents.
- **Authority laundering is the top pipeline risk.** Stage 1 (contained, `--dir ./work:/data`) writes a
  `.cmd`/`.ps1` containing `wazmrt stage2.wasm --dir C:\:/`. The orchestrator runs it. **A contained
  stage promoted an uncontained one, purely by authorship** — privilege escalation with no bug anywhere
  in wazmrt. Stages must be **fixed**, and authority assigned by the orchestrator; never read the next
  command/path/`--dir` out of a preopen.
- **Inter-stage communication must be data the orchestrator validates, not code it executes.**
- **Windows: `cmd.exe` resolves commands from the current directory before PATH.** A guest with write
  access to a directory the orchestrator later `cd`s into needs only to *create* `git.cmd` / `node.cmd` /
  `python.bat` — the next `git status` runs the guest's file. **Creation alone is the attack**; nothing
  is modified, nothing looks tampered with. **Never grant write access to a directory you will later
  execute from, that is on PATH, or that the orchestrator `cd`s into.**
- **A shared writable preopen is a shared mutable medium** — stage 1 authors stage 2's inputs. Compromise
  stage 1 and you own stage 2's view of the world with no escape required. Prefer **separate preopens per
  stage**; pass data by copying, not by sharing a writable dir.
- **Treat a preopen as tainted output.** Don't follow links out of it or execute artifacts from it
  unvalidated.
- **Symlinks are landmines for whoever follows them next.** A link persisted in a preopen is a stored
  request cashed later by something with *more* authority (the host, `tar`, a later stage, the user).
  wazmrt refusing to follow it does **not** disarm it. **⇒ If `path_symlink` is ever implemented, its
  target must be validated at *creation* and escaping targets refused** — a stronger and *different*
  requirement than the traversal policy, and the one that protects the user's machine. This holds **even
  if no-follow traversal is kept.**

## Proposed secure-by-default posture (for the owner's decision)

1. Embed a root public key in wazmrt — **one artifact to protect**.
2. OS enforces wazmrt's integrity (Authenticode+WDAC / IMA+Secure Boot).
3. Optional signed keyring file, anchored to the embedded root, for rotation/revocation.
4. **Default-deny unsigned `.wasm`**, explicit `--unsigned`/dev-mode opt-out. *If unsigned is the default,
   nobody signs.*
5. **`--ro-dir` (read-only preopens)** — surfaced three times in the design conversation as the highest
   security-value-per-effort item on the table, and it is **not currently on any roadmap list**. The
   rights machinery already exists; exposing it at the CLI makes least-authority pipelines expressible
   and converts most of the orchestrator risks above from "trust the author" to "structurally
   impossible."
6. TPM sealing only to defeat offline/persistent attackers — bolt-on, not foundational.

## Open decisions (owner is thinking — 2026-07-16)

- Trust anchor: embedded-in-binary (recommended) vs OS keystore vs signed keyring file vs a hybrid.
- Signature format: adopt existing prior art (→ Adoption Checklist) vs roll our own.
- Default policy: deny-unsigned out of the box, or opt-in?
- Scope: is the keyring genuinely a separate project (owner's lean), and where is the boundary?
- Does `--ro-dir` jump the queue ahead of the rest of 4.3?
- Revocation/rotation story — the boring part everyone skips.
