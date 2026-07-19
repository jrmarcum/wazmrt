# Security Model — threat model, trust chain, and the secure-by-default base

> ## ⚠️ STATUS: AUTHENTICITY is now BUILT (verify side); the SANDBOX was already BUILT
>
> **The authenticity path is now BUILT** (updated 2026-07-18): **pin verification** (Phase 5 —
> `src/pin.zig`, root-owned SHA-256 allow-list) and **Ed25519 signatures** — verify (`src/sign.zig`),
> publisher CLI (`wazmrt keygen`/`sign`), and build-time trust anchor (`-Droot-key=<hex>`). The CLI
> **denies unsigned modules by default when *armed*** (a root key is embedded **or** a pin DB is present);
> a **bare** build (no key, no DB) still runs any `.wasm` (byte-identical to before). `--no-verify`
> overrides on the user's own machine, but a root `# mode: enforce` is absolute. Verification is
> **CLI-only** — the C-ABI/embedder run path is intentionally ungated. **Still design (not built):** the
> companion **keystore** project (`wasm-keys.json` — decided, see below) and its wazmrt-side reader; and
> optional HSM key custody. **No key rotation** (rejected).
>
> **The authority/sandbox side was already built:** everything in "What holds today" (no exec, preopens,
> rights) and the "DONE — WASI symlink traversal" section (`walkFull`, `path_symlink`/`path_readlink`,
> adversarial-fuzzed). **The orchestrator-invariant section is advice, enforceable only by the embedder.**
>
> The resolved authenticity decisions (trust anchor = embedded key; format = roll-our-own Ed25519) and
> what remains open (publisher side, default policy) are at the bottom of the file.

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
| **Authenticity** | Is this the code I approved? | Ed25519 signature / pin, vs a trust anchor | **BUILT** (Phase 5 + `sign.zig`, 2026-07-18) |
| **Authority** | What may it touch once running? | Preopens + rights (the sandbox) | **Built** (#17, Phase 3) |

They do not substitute for each other. **A validly-signed module is *authentic*, not *harmless*** — it
still gets exactly the authority `--dir` hands it. A sandboxed module is contained but may be malicious
code you never approved. Ship both or the story has a hole.

### Authority scales with granted capabilities; authenticity is constant (2026-07-18)

A subtle but load-bearing consequence, worth stating because the two wazmrt run paths differ:

- **A wasm module has zero ambient authority.** Core wasm cannot make a syscall — its *only* channel to
  the outside world is the **imports** the host wires at instantiation. No import for a thing ⇒ the module
  physically cannot do that thing (capability-security by construction).
- **`wazmrt <module> <export> [args]`** (a plain exported-function call) wires **no imports**
  (`runFunction` → `Instance.init` = `initWithImports(..., .{})`). The function computes over its own
  linear memory and returns a value; it **cannot read or write files** — a module that imports a file
  function either fails to instantiate (`MissingImport`) or traps (`UnsupportedImportCall`) at the call.
- **`wazmrt <module.wasm>`** (a WASI `_start` command) wires the `wasi_snapshot_preview1` imports —
  *those imports are the file access*, gated by the preopen/rights sandbox.

So the **authority/sandbox** measures (preopens, rights, symlink containment) are only relevant on the
path that *grants* I/O (WASI). A bare function call is already maximally sandboxed — there is no capability
to contain. But **authenticity applies to *both* paths equally**, and `verifyGate` already gates both
(`will_execute` = an export invocation **or** `_start`): a tampered *pure-compute* module is still
dangerous — a crypto routine returning a weak key, a validator that always says "valid", a pricing
function with a backdoor never touch a file, yet you trust their *return value*. **Rule: authority is
conditional on granted capabilities (zero for a bare function ⇒ no sandbox needed); authenticity is
unconditional.** (Caveat: an **embedder** via the C-ABI/FFI chooses its own imports — if it grants file
access it must sandbox that itself; the embedder run path is intentionally ungated for both properties.)

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

## DECIDED 2026-07-16 — three rejected mechanisms, and why

> These were proposed, reasoned through, and **rejected with cause** in the owner design conversation.
> The *why-not* is the valuable part — each looks appealing on first contact, so record the refutation
> or it gets re-proposed in six months. All three converge on one invariant:

> ### 🔑 **Integrity is anchored by ownership or a signature — never by secrecy.**
> Arrived at independently from three directions (keystore, encryption, machine-binding). Corollary:
> **any scheme requiring a secret on the user's machine is broken** — by open source if we publish, by
> `strings`/debugger/memory-dump if we don't. The signature scheme needs no secret on the user's
> machine at all, which is exactly why it survives.

### 1. Pin database: **verified-install (root-owned), NOT trust-on-first-use**

**Proposed:** wazmrt SHA-256s a `.wasm` on first run, stores the hash in "a file only accessible by
wazmrt," and halts + warns if it ever differs. (This is TOFU — the SSH `known_hosts` model. Real
pattern, and its genuine advantage is **zero infrastructure**: no PKI, no publisher, no key
distribution, works for self-built modules. Signature schemes often die of key-management friction.)

**Why it fails as stated — `"a file only accessible by wazmrt"` does not exist.** OS access control is
per-**user**, not per-**program**. wazmrt runs *as the user*; any file it can write, user-level malware
can write. There is no "this program only" ACL on Windows, Linux, or macOS. So the DB is **exactly as
tamperable as the `.wasm` it protects** — malware updates `tool.wasm` and `hashes.db` together, two
lines of extra work. It's *worse* than the keystore case: a TOFU DB **must stay writable** (it records
new entries), so it can't even be locked down. Getting a genuinely program-private file needs a service
account, setuid (a vulnerability class of its own), or MAC labelling — all heavier than just signing.

**Other TOFU gaps:**
- **Continuity ≠ authenticity.** It answers "changed since I first saw it?", never "is this what the
  publisher intended?" If the file was already malicious at first sight, **TOFU faithfully protects the
  malware from tampering.** First use is unauthenticated (SSH's known weakness).
- **Updates are indistinguishable from attacks** → every legitimate update trips the alarm → users learn
  to click through. That's the `REMOTE HOST IDENTIFICATION HAS CHANGED` → `rm known_hosts` reflex. **A
  warning users always dismiss is worse than none — it teaches dismissal.**
- **Doesn't scale to distribution.** 1000 machines = 1000 independent, blind first-uses. A signature
  verifies on all of them having never seen the file.
- **TOCTOU** — hash the bytes you *execute*: read once into memory, hash *those bytes*, run *those
  bytes*. Never hash by path and re-open.

**DECISION — move the pinning to install time and give the DB to root.** The **privileged installer**
hashes the module and writes the DB ("first use" done once, *with authority*); the DB is **root-owned,
read-only to the user**; wazmrt (as the user) only ever *reads* it. Now user-level malware cannot rewrite
the pin. This is **not TOFU — it's verified install**, i.e. exactly the apt/rpm model: verify at install
with privilege, rely on ownership afterward. It defeats the unprivileged attacker — the realistic
threat — with nothing but ownership. **The distinction that makes it work is *who* pins and *who* owns
the DB.** Lazy user-side pinning is weak; privileged install-time pinning is strong. It also fits the
vision's shape (system-wide wazmrt + scripts in a root-owned directory).

**Layers with signatures — complementary, not competing.** Their weaknesses are each other's strengths:

| | Answers | First sight | Infrastructure |
| --- | --- | --- | --- |
| **Signature** | "From someone I trust?" | ✅ works | needs PKI |
| **Pin** | "Changed since approved?" | ❌ blind | none |

⇒ **Signed module → verify signature. Unsigned module → check the root-owned pin.** Authenticity where
available, continuity where not, and local dev modules still work.

**Cold-start cost — MEASURED 2026-07-16, and it is a non-issue** (`zig build bench -- hash <file>`).
Verification is negligible against what wazmrt already does at cold start. On a real 46 KB compiled
guest (`hc2.wasm`):

| step | time | note |
| --- | --- | --- |
| **SHA-256** (pin check) | **21 µs** | 0.5% of instantiate; ~2.2 GB/s, SHA-NI hardware-accelerated |
| **Ed25519 verify** (signature check) | **105 µs** | 2.4% of instantiate; hash included |
| decode + **instantiate** | **~4.4 ms** | the real cold-start path — dwarfs both |

And instantiate itself sits under a **~72 ms process-startup floor** (measured end-to-end), so a pin
check is **<0.03%** of a real `wazmrt file.wasm` invocation, a signature check <0.15%. Even a 1.1 MB
module hashes in 0.5 ms. **No extra I/O either** — the file is read to decode it regardless; hashing is a
CPU pass over bytes already in memory. The only case where hashing looks large by *percentage* is a
70-byte toy (7–10% of a 0.8 µs instantiate) — 70 **nanoseconds** absolute, i.e. noise.
**Conclusion: verify-on-every-run does not threaten the cold-start metric. Pin the whole thing; no need
to restrict to the system script dir for perf reasons.** Full numbers in `cmem/testing.md`.

### 2. **No encryption of the pin DB**

**Proposed:** encrypt the DB at install so an attacker can't change it; wazmrt holds the key. (Owner then
spotted the flaw themselves: wazmrt is open source, so the key is discoverable — *"so why encrypt to
start with?"*)

**Why — category error: encryption gives confidentiality; we need integrity.** It doesn't even achieve
the stated goal. An attacker who can *write* the DB needs no key:
- **delete it** → wazmrt re-pins, and the malicious file becomes the trusted baseline;
- **corrupt it** → DoS or re-pin;
- **roll it back** — swap in an older encrypted copy. **Encryption offers zero defense against replay**,
  and they never decrypt a byte;
- **transplant** an encrypted DB from another machine.

**And nothing is secret anyway** — it's a SHA-256 of a *public* file; the attacker computes it in a
millisecond from the file they already have. Encrypting a value the attacker can derive, to prevent a
modification encryption doesn't prevent.

**The open-source objection is right but sharper than framed: closed source wouldn't save it either** —
`strings`, a debugger, or a memory dump gets the key, because the key must be *in* the binary to be
used. **Kerckhoffs's principle**: security lives in the key, not the design's obscurity. **A symmetric
key shipped to the attacker is not a key; it's obfuscation.** Every DRM scheme relearns this.

**⇒ This is the argument FOR the signature path, not against it.** Asymmetric crypto is the only
construction that survives *the attacker holding your verifier, your source, and your binary* — literally
what public-key crypto was invented for. The private key never ships; the public key ships to everyone,
embedded in an open-source binary. **A public key being public is not a weakness; it's the name of the
thing.** An attacker reading our source learns the verification key and gains nothing.

**DECISION — the pin DB is plaintext.** Auditable (`cat`/diff it, paste it in a bug report), root-owned,
read-only. **Integrity from ownership; zero crypto beyond the hash itself.** The question was never "how
do we encrypt this?" but **"who owns this file?"** — which is how `root:root 0755` has protected every
binary in `/usr/bin` for thirty years.

### 3. **No machine-binding / machine-derived secret**

**Proposed:** mix in information that exists only on the user's machine, that only the user can access,
to shrink the attack surface further.

**Why — the attacker *is* the user.** The OS security principal is the **account**, not the human.
"Only the user has access" and "malware running as the user has access" are **the same sentence** to the
OS. Anything our programs can read, theirs can read.

| Candidate | Why it doesn't help |
| --- | --- |
| MachineGuid, `/etc/machine-id`, IOPlatformUUID | Machine-unique but **readable by every process** — an identifier, not a secret. Obscurity. |
| Disk serial / CPU ID / MAC | Same; often spoofable too. |
| Windows **DPAPI** | Tied to the *user account* — same-user malware just calls `CryptUnprotectData`. |
| Linux kernel keyring | Per-user session keyring. Same. |
| **TPM** | Protects a key from **extraction**, not from **use**. Malware doesn't need the key — it asks the TPM to perform the operation. |

Each defends a *different* attacker (another user, a stolen disk) — **none defends against the one that
matters here.**

**The one real exception: human physical presence** (YubiKey/FIDO touch, biometric, typed passphrase) —
genuinely separates *the human* from *code running as the human*. But the UX cost disqualifies it for a
script runner (nobody taps a token per script run), and at install time **root already provides the
boundary**, so it'd be redundant. *(Aside: macOS Keychain ACLs can bind an item to a specific code-signed
app — the only true "program-private" mechanism anywhere. macOS-only, rests on code-signing enforcement,
doesn't generalize to the Windows/Linux base.)*

**DECISION — no machine-binding. Ownership already solved it.** The DB is root-owned; user-level malware
already cannot write it. Mixing a machine secret into a file the attacker *cannot modify* defends against
nothing new. **Defense-in-depth that addresses no threat is negative value** — complexity to maintain,
new failure modes, and confidence we haven't earned.

**Where hardware genuinely earns its place** (a *different* threat, already in the table below): **TPM-seal
to PCRs** → defeats the **offline** attacker (stolen disk) and detects boot-chain tampering; **Secure
Boot** → anchors the chain in firmware. Bolt-ons for when offline/persistence enters the threat model —
not foundations.

## DONE 2026-07-16 — WASI symlink traversal: FULL support, secure-by-construction

**IMPLEMENTED** as designed below — `walkFull` in `src/wasi.zig`, `path_symlink`/`path_readlink`, +
adversarial fuzz. Verified 5/5 on Windows with real symlinks (`examples/wasi_symlink_traversal.zig`) and
by POSIX-CI unit tests. The spec below *is* what was built.

**Owner chose full traversal (wasmtime/cap-std parity)** for `path_symlink`/`path_readlink` + in-sandbox
symlink following, over the cheaper no-traversal option. This is **conformance-only** — the product
vision uses host-side dispatch, not guest symlinks (see "The vision") — but full fidelity was chosen so
compiled C/Rust guests behave normally.

**This reopens the exact escape surface #17 closed, with an adversarial twist: the guest can now
*author* the symlinks.** So the resolver must be secure against attacker-chosen link topologies, not
just host-placed ones. **The mandated design is a handle-stack walk (RESOLVE_BENEATH in userspace) —
secure *by construction*, not by lexical re-validation**, because lexical `..` math becomes unsound once
targets can inject `..` and absolute paths:

> ### The handle-stack resolver (implementation spec)
> State: a stack of **open directory handles**, `dirs[0]` = the preopen (borrowed, **never popped or
> closed**). A work queue of path components. A **symlink budget** (→ `ELOOP` at 0).
> Per component `c` relative to `dirs.last()`:
> - `.` / empty → skip. `..` → **pop the stack, but never below `dirs[0]`** (at root, `..` stays root).
>   *This is why up-escape is impossible: there is no handle above the preopen to reach.*
> - lstat `c` no-follow. If it's a **symlink** and we should follow it here (not a no-follow final):
>   readlink it, spend one budget, and **push the target's components onto the FRONT of the queue**. If
>   the target is **absolute, reset the stack to `[preopen]`** and strip the prefix — *an absolute target
>   means the preopen root, never the host root.* Relative targets resolve from the current top.
> - Real directory (intermediate) → `openDir` no-follow, **push** the handle.
> - Final real component → return `(dirs.last(), name)`. `FileNotFound` on the final is OK for create ops.
> **Every open is a single component, no-follow, relative to a held handle** → TOCTOU-safe; the handle
> pins the inode, and a swapped-in symlink is caught by the next lstat. **Targets go through the same
> machinery** — no bypass channel.
>
> Ops pass **`follow_final`**: `path_open`/`*_filestat_get` with `SYMLINK_FOLLOW` = true; `path_unlink`,
> `path_readlink`, and the no-`SYMLINK_FOLLOW` stats = false (operate on the link itself).
>
> **Creation (`path_symlink`) also validates:** the *link's location* is contained by the walk like any
> path; the *target string* is stored as the guest gives it (a relative target is resolved only when
> later followed, through this same secure resolver, so a "malicious" target simply fails to escape at
> follow time). **Still refuse an obviously-escaping absolute/`..` target at creation too** — defence in
> depth, and it stops planting a landmine for a *less careful* future reader (the orchestrator-invariant
> concern).
>
> **Security properties, by construction:** (1) `..` can't rise above the preopen — no handle exists
> there; (2) absolute targets reset to the preopen, not host root; (3) all opens no-follow single-component
> through handles — TOCTOU-safe, no intermediate-symlink surprise; (4) budget → ELOOP; (5) one code path,
> no bypass. **Mandatory: adversarial fuzz** (the #22 pattern) where the *guest authors* symlink
> topologies and tries to escape — assert it never reads outside the preopen.

**Windows caveat:** creating a symlink needs privilege there (Zig std uses raw `FSCTL_SET_REPARSE_POINT`,
#17/#23), so `path_symlink` is effectively POSIX-only; *following* host-placed symlinks still works on
Windows. Tests run on POSIX CI, skip on unprivileged Windows.

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

## Proposed secure-by-default posture

**Settled 2026-07-16** (see "DECIDED" above for the reasoning):

1. **Verified install, not TOFU** — the privileged installer pins; the DB is **root-owned, read-only,
   plaintext**. Integrity from ownership.
2. **No encryption, no machine-binding** — both rejected with cause; they solve confidentiality/obscurity,
   not integrity.
3. **Signed → verify signature; unsigned → check the pin.** The two layers are complementary.

**Still proposed, pending the owner's decision:**

4. Embed a root **public** key in wazmrt — **one artifact to protect**. (Public keys are meant to be
   public; open source is a non-issue for this and *fatal* for every alternative.)
5. OS enforces wazmrt's integrity (Authenticode+WDAC / IMA+Secure Boot).
6. Optional signed keyring file, anchored to the embedded root, for rotation/revocation.
7. **Default-deny unsigned `.wasm`**, explicit dev-mode opt-out. *If unsigned is the default, nobody
   signs.* **Owner refinement 2026-07-17 — prefer interactive consent over a bare skip flag.** When a
   module is unverified, the root-owned policy decides: **`off`** runs (one-line notice, no prompt —
   prompting every run trains the dismissal reflex, see §1 TOFU); **`warn`** on an interactive TTY
   **prompts** "unverified — proceed? [y/N]" (default No, and No on EOF/non-tty); **`enforce`** hard-denies
   with no prompt. **Two honest limits, both recorded:** (a) the prompt is **UX consent, not a security
   boundary** — `yes | wazmrt evil.wasm` answers it, so it only helps an honest human; the boundary stays
   the root-owned policy. (b) unattended deployments (`binfmt`/`argv[0]`, cron, CI) have **no TTY**, so a
   **non-interactive opt-out** (`--yes`/`--no-verify` / `WAZMRT_ASSUME_YES`) is still needed for scripts —
   **subordinate to the policy** (honored under `off`/`warn`, **refused under `enforce`**). Same invariant
   as everything else: *authority comes from ownership, not from a runtime argument.* Built in Phase 5 —
   see `roadmap.md` §5 increment 5.
8. **`--ro-dir` (read-only preopens)** — surfaced three times in the design conversation as the highest
   security-value-per-effort item on the table. **BUILT in Phase 4.4 (2026-07-17).** It exposes the
   existing rights machinery at the CLI: a `--ro-dir` preopen omits `rights.write_mask`, and because
   `path_open` only ever narrows an fd's rights against its parent, read-only-ness propagates to the
   whole subtree — least-authority pipelines are now expressible, converting most of the orchestrator
   risks above from "trust the author" to "structurally impossible." See `design-decisions.md`.
9. TPM sealing only to defeat offline/persistent attackers — bolt-on, not foundational.

## Open decisions (owner is thinking — 2026-07-16)

**Settled, do not re-litigate** (reasoning in "DECIDED" above): pin mechanism (verified-install,
root-owned) · no encryption · no machine-binding.

**BUILT (Phase 5, 2026-07-17): the pin path.** Install-time root-owned plaintext pin DB + pre-run SHA-256
check, read-once so the verified bytes *are* the run bytes (TOCTOU-safe). The "default policy" question it
originally deferred is now settled — deny-unsigned when armed (see above).

**RESOLVED 2026-07-18 (owner) — and the verify mechanism is BUILT (`src/sign.zig`):**

- Trust anchor: **embedded-in-binary root key**, set at build time via **`-Droot-key=<hex>`**
  (`sign.rootKeyFromHex`; empty ⇒ inert). Plus the **ownership-trusted `wasm-keys.json`** keys DB (see
  above) that augments it. **No rotation** — the signed-keyring / PK→KEK→db idea is **rejected**, not
  deferred.
- Signature format: **roll our own minimal** — an Ed25519 signature over the canonical bytes, in a
  `"signature"` custom section (`magic ++ algo ++ pubkey ++ sig`). Chosen after confirming the prior-art
  `wasmsign2` format is **not** a Bytecode Alliance item: it's an individual's PoC under the independent
  `wasm-signatures` org, and its spec lives in the W3C WASM-CG `tool-conventions` repo (`Signatures.md`) —
  neutral, but PoC-grade and heavier than we need. Our format is shaped so a tool-conventions-compatible
  layer can be added later if interop is ever wanted (no Adoption Checklist incurred).

**What's built:** `verify(bytes, root_key) → {unsigned, authenticated, foreign, tampered}` (streaming
Ed25519 over every byte except the signature section, no alloc); `signModule` (library signing helper);
the CLI `verifyGate` runs the signature check **before** the pin fallback — a module signed by the trusted
root is authenticated and needs no pin; a module signed *by our key* whose bytes don't match is refused
**always**; unsigned/foreign fall through to the pin path. **Inert until a build embeds a root key** (no
`-Droot-key` ⇒ `sign.rootKeyFromHex("")` = null ⇒ byte-identical to the pin-only path). When armed, the
unsigned case is denied by default (see "default policy" above).

**Publisher signing CLI — BUILT 2026-07-18 (`src/main.zig`):**

- `wazmrt keygen [--out <name>]` — generate an Ed25519 keypair (entropy from the `Io`); writes the
  private **seed** as hex to `<name>.key` (KEEP SECRET) and prints the public key hex to embed.
- `wazmrt sign <in.wasm|.wat> <out.wasm> --key <keyfile>` — sign a module (assembles `.wat` first);
  writes the original bytes + a `"signature"` custom section. Reuses `pin.toHex`/`parseHex` for the
  32-byte hex; the key seed round-trips via `Ed25519.KeyPair.generateDeterministic`.
- **Verified through the real binary:** keygen → sign → embed the printed key → an authenticated run
  (42) and a refused tampered run. Same "thin CLI over a tested library function" shape as `wazmrt pin`.

**Release-time key injection — BUILT 2026-07-18.** `zig build -Droot-key=<64 hex>` embeds the trust
anchor; empty (the default) ⇒ verification inert; a malformed value is a **build error**
(`sign.rootKeyFromHex`'s `@compileError`). The threading problem (sign.zig is compiled into ~8 targets via
`root.zig`) is sidestepped: **only `main.zig` reads the key**, so `build_options` is imported by the CLI
module alone and `sign.zig` stays plumbing-free. The whole loop — keygen → sign → `-Droot-key` → verify —
is proven through the real binary with no source edits.

### DECIDED 2026-07-18 (owner) — default policy + custody, and NO rotation

- **No key rotation.** The keyring / PK→KEK→db rotation idea is **rejected** ("a bad option"). There is one
  embedded root key; changing it means rebuilding + re-signing wazmrt (the anchor's integrity == the
  verifier's, so that is acceptable and simpler than a rotation layer to attack).
- **Custody = publish-and-pin.** The publisher publishes a **SHA-256** of the module; the operator
  validates it and saves it to the (root-owned) **pin DB** for verification before use. Signatures and
  pins are *both* "approved" paths — a module runs if signature-authenticated **or** pinned. This keeps
  the private-signing-key custody problem light (HSM optional; the hash path needs no signing key at all).
- **CLI default = deny unsigned — BUILT.** When verification is **armed** — a root key is embedded
  (`-Droot-key`) **or** a pin DB is present — the wazmrt CLI **denies** a module that is neither
  signature-authenticated nor pinned. A **bare** build (no key, no DB) stays permissive (nothing to verify
  against), so dev/tests/`wasi-gate` are unaffected. Implemented in `pin.decide(explicit, pinned, opt_out,
  tty, armed)` + `verifyGate`.
- **User may override; root enforce is absolute.** The armed default-deny is overridable by `--no-verify`
  (the user owns their machine — the ownership principle), *but* a root-owned pin DB with `# mode: enforce`
  denies **absolutely** (opt-out ignored). Signature-authenticated modules always run.
- **Embedder path (wasmtk / rsxtk / C-ABI FFI) = run.** The gate lives only in the CLI (`verifyGate`); the
  C-ABI instantiate/run path has **no gate**, which is the intended default for embedders — they drive the
  runtime and expect to run what they load. (An embedder that wants verification can call `sign.verify` /
  the pin API itself.)
- Fixed in passing: **`wazmrt pin` now assembles a `.wat` before hashing**, so a pinned `.wat` matches the
  *binary* the gate hashes at run time (previously it hashed the source text → never matched).

### The trusted-keys database + companion keystore project — SUPERSEDED 2026-07-18 (NOT being built)

> **Status: shelved.** These decisions were locked on the morning of 2026-07-18, but the package-manager
> survey later that day (see the next subsection) showed a multi-key keystore is redundant for the chosen
> **single-publisher / package-managed** model. The design below is kept as a **reference in case
> wazmrt ever goes multi-publisher** — it is not on the build path. The store is the root-owned pin DB
> plus the single embedded `-Droot-key`.

A **companion project** (separate from wazmrt) generates Ed25519 keypairs and registers the **public**
keys in a database that wazmrt reads as its trust anchors. Decisions that *would* apply if it were built:

- **File:** `wasm-keys.json` — **JSON** (multi-field key records fit JSON far better than the line-based
  `pins` format; `std.json`, no new dep). Stays **plaintext** (integrity, not secrecy) and the reader must
  **fail closed** (malformed/unparseable → trust no keys → deny when armed, never "empty ⇒ allow").
- **Location:** `<wazmrt-dir>/security/wasm-keys.json` — a `security/` directory **next to the executable**
  (portable; travels with the binary). Trust is anchored by an **ownership check**, not the path: wazmrt
  trusts the file **only if it is owned by root/admin and not writable by the invoking user**; a
  user-writable keys file is ignored (it is forgeable, so it provides zero authenticity — the same TOFU
  reasoning that put `pins` at `/etc/wazmrt/`). This keeps "authority from ownership" while allowing a
  portable location. (Impl note: POSIX = `stat` st_uid/perms; Windows ACL check is the harder part.)
- **Contents:** **public keys only** — a list of trusted verification keys. wazmrt authenticates a module
  whose `"signature"` section verifies under **any** key in the DB, so publishers can be added **without
  rebuilding wazmrt**. It **augments** the embedded `-Droot-key` (which stays as an optional
  always-trusted fallback / bootstrap). The existing line-based **`pins` hash DB is untouched** — pins and
  keys are complementary "approved" paths (custody = publish-a-SHA-256-and-pin **or** sign-with-a-trusted-
  key). **No rotation** — the DB is static and ownership-trusted, not a signed keyring.

**Schema (the contract the companion tool writes and wazmrt reads):**

```json
{
  "version": 1,
  "keys": [
    { "id": "acme-prod",           // short human/owner identifier (logged on verify)
      "alg": "ed25519",            // only ed25519 today
      "public_key": "<64 hex>",    // 32-byte Ed25519 public key, lowercase hex
      "label": "ACME release key", // free-text description
      "added": "2026-07-18" }      // ISO date (auditability; optional)
  ]
}
```

wazmrt-side work (would have been a later increment — **NOT being built**, see the SUPERSEDED note above):
load + ownership-check `wasm-keys.json`; gather trusted keys (`-Droot-key` ∪ DB); a `"signature"` section
authenticated iff its key is in the trusted set **and** the Ed25519 signature verifies. Today's single-key
`sign.verify` + `-Droot-key` is the shipped design.

### Package-manager verification survey (2026-07-18) — and whether we even need a keys store

Researched (deep-research: 21 sources, 24 adversarially-confirmed claims) how the major package managers
verify installed files, to decide whether wazmrt needs a separate keys store or can lean on the field's
per-file verification.

| Tool | Mechanism | Trust anchor | Granularity / addressing | Dir as opaque blob? |
| --- | --- | --- | --- | --- |
| **RPM/dnf** | Signature (GPG) over repo metadata `repomd.xml`; per-package SHA-256 inside it; + per-package GPG sig | GPG keyring (imported) | per-package + signed hash-index | No |
| **pacman** | Signature (GPG) — detached `.sig` per package | `pacman-key` keyring, master-key WoT | per-package | No |
| **Flatpak/OSTree** | Signature over the OSTree **commit** (Merkle root) | GPG / ed25519 keys | content-addressed **Merkle DAG** | No (Merkle root) |
| **Snap** | Signature (Ed25519) — assertion chain; `snap-revision` holds SHA3-384 of the `.snap` | Canonical root/brand keys | whole squashfs artifact | Artifact, not dir |
| **Nix** | Signature (Ed25519) over each store path's `.narinfo` | `trusted-public-keys` (Ed25519, often **one** key) | content-addressed; NAR = canonical serialization | No (canonical NAR) |
| **Homebrew** | Checksum (SHA-256) in the Ruby formula | git/GitHub over HTTPS (**no keys store**) | per-file, flat git-tracked manifest | No |
| **Scoop** | Checksum (SHA-256) in the JSON manifest | git/GitHub over HTTPS (**no keys store**) | per-file, flat git-tracked JSON manifest | No |

**Two archetypes:** (a) **signed manifest/index of hashes** (RPM `repomd`, pacman, Snap, Homebrew, Scoop);
(b) **content-addressed + signed root** (Nix NAR/`.narinfo`, Flatpak OSTree commit). **Universal finding:
NONE checksum a raw directory as an opaque blob** — the whole-tree ones hash a *canonical serialization*
or a *Merkle root*, always under a signature. The unit is per-file/per-artifact, with the *list/root*
authenticated as a whole by a signature **or** a trusted git-over-HTTPS channel. **Bundle implication:** a
signed manifest of per-module hashes (rpm/homebrew/scoop) **or** sign each module (nix). Our root-owned pin
DB *is* that manifest; **directory hashing has no precedent — avoid it.** Sources: `ostreedev.github.io`,
`nixos.org/manual/nix`, `snapcraft.io/docs`, `docs.brew.sh`, ScoopInstaller wiki, `pulpproject.org`.

**Do we even need `wasm-keys.json`? Three tiers — pick by distribution model (OPEN):**

1. **Pin DB only, no keys store** — depend on the package manager's per-file verification; the installer
   records each `.wasm`'s SHA-256 into the root-owned pin DB (the Homebrew/Scoop/RPM-metadata model — those
   have **no per-user keys store at all**). Simplest; trust = ownership + the package manager's own chain.
2. **Pin DB + the single embedded `-Droot-key`** — per-module signatures against **one** key (this *is*
   Nix's tiny `trusted-public-keys`, usually one key). Lets *our own* signed modules run anywhere without a
   pin, no separate store.
3. **`wasm-keys.json` multi-key store** — trust **multiple independent publishers'** keys, added without
   rebuilding wazmrt.

**DECIDED 2026-07-18 (owner): single-publisher / package-managed → tiers 1–2.** The store is the
**root-owned pin DB** (the installer records each `.wasm`'s SHA-256 from the verified package — the
Homebrew/Scoop/RPM-metadata model), plus the **single embedded `-Droot-key`** for our own signed modules
that run without a pin (Nix's one-trusted-key model). **`wasm-keys.json` / the companion keystore project
is NOT being built** — tier 3 is redundant for single-publisher distribution. The schema above stays only
as a reference *if* a multi-publisher need ever arises. **Consequence: the wazmrt authenticity path is
feature-complete** — pin verify + signature verify + `keygen`/`sign` + `-Droot-key` + deny-when-armed —
with **no keystore reader to build**. The install side (running `wazmrt pin` per module) is the packager's
job, not wazmrt code.

**Still open** (all OPTIONAL — the authenticity path is otherwise feature-complete):

- Private-key custody hardening for the (single) publisher (HSM/YubiKey/KMS — the local `.key` file is the
  MVP; the design never wanted a private key on a *user's* machine, only the publisher's).
- ~~Install-side ergonomics: a bulk `wazmrt pin <dir>`~~ — **BUILT 2026-07-18.** `wazmrt pin` now accepts
  a **directory** and recursively pins every `.wasm`/`.wat` under it (assembling `.wat` first so the hash
  matches the run-time binary; non-module files skipped; sorted, appended to `--db` in one write). Lets a
  packager pin a whole bundle in one step — the per-module install-time pinning the survey recommends.
- (The Windows ownership/ACL check is **no longer needed** — it was for the shelved keys file.)

**Resolved with data 2026-07-16:** ~~cold-start cost of hashing on every run~~ — **measured, negligible**
(SHA-256 0.5% of instantiate, Ed25519 2.4%, both <0.15% of the process-startup floor). See the pin
section above and `testing.md`.
- ~~Default policy: deny-unsigned out of the box, or opt-in?~~ — **RESOLVED 2026-07-18: deny-unsigned when
  *armed* (key embedded or pin DB present); bare build permissive. See "default policy" above.**
- ~~Scope: is the keyring genuinely a separate project?~~ — **RESOLVED 2026-07-18: moot — the keystore is
  NOT being built. Owner chose single-publisher / package-managed, so the store is the pin DB + one
  embedded `-Droot-key` (tiers 1–2); the multi-key `wasm-keys.json` (tier 3) is redundant. See the
  SUPERSEDED note and the tiering above.**
- ~~Does `--ro-dir` jump the queue ahead of the rest of 4.3?~~ — **resolved: built in 4.4 (2026-07-17).**
- ~~Revocation/rotation story~~ — **RESOLVED 2026-07-18: NO rotation (owner rejected it). One embedded
  key + an ownership-trusted static keys DB; rebuild to change the anchor.**
