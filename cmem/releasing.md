# Releasing & Versioning

How wazmrt is versioned. **Set by the owner 2026-08-19**, together with the four review tracks in
[`roadmap.md`](roadmap.md). This file is the authority on the number; `roadmap.md` is the authority on
what earns it.

---

## 🔖 THE VERSION IS `1.0.1` — Track H shipped 2026-08-19. It was SET to `1.0.0` before the first track, on purpose

wazmrt was `0.1.0` from 2026-07-02 until today, which had stopped being true long before it was changed.
What `1.0.0` asserts is **complete on wazmrt's own terms**, and every clause of that is already measured,
not aspirational:

| claim | evidence, as of 2026-08-18 |
| --- | --- |
| every in-scope proposal implemented | Tracks F, P, D, L, A all complete; memory64 was the last unimplemented one, 2026-07-27 |
| conformance at its ceiling | **284 files · 63,934 passed · 0 failed · 0 skipped · 0 unrun**, and the baseline file is **EMPTY** |
| the suite is green | 758/758 unit · `test-safe` 758/758 · `test-security` 3/3 · `features` all four combinations |
| the artifacts are pinned | exe 990,208 · lib 1,053,320 · dll 900,608 — all three EXACT against `tools/size-ceilings.txt` |
| self-owned, zero dependencies | `third_party/` holds no code, `.dependencies` is empty, binaries import only `ntdll`/`KERNEL32` |
| the C ABI is stable | `abi_version() == 2`, header and library pinned together by a test |

🎯 **Why before the tracks and not after them.** A hardening pass, a bug hunt, an optimization review and
a security review are all **reviews of finished code**. Their value comes from the code under them being
done — `design-decisions.md` states the rule directly (*"prove the concept BEFORE hardening"*), and a
review of code that is still moving audits something that will not ship. Numbering these reviews `0.x`
would say the runtime is incomplete when every gate says it is not; numbering them `1.0.x` says exactly
what is happening — **a complete runtime being made harder, smaller, faster and more defensible.**

⚠️ **This is not a claim that nothing is left.** SD-1 and SD-2 are open and holding for upstream, and the
Bake Off is a compare task that can never be "done". Neither is a gap in wazmrt; see `INDEX.md`.

---

## 📐 THE CADENCE — every component is a SINGLE DIGIT (owner, 2026-08-19)

**One rule, applied to all three components: a component never exceeds `9`.** It rolls over into the one
to its left, exactly like a decimal odometer.

- **Normal release: `+0.0.1`.** One shipped, gated piece of work — in practice one track — per bump.
- **`x.y.9` ends a minor line.** The release after `1.0.9` is **`1.1.0`**, never `1.0.10`.
- **`x.9.9` ends a major line.** The release after `1.9.9` is **`2.0.0`**, never `1.10.0`.
- **A breaking change takes the next MAJOR immediately**, from wherever the ladder stands: at `1.0.3` a
  breaking change ships as **`2.0.0`**, not `1.0.4`. Minor and patch reset to `0` and the digits they
  would have used are forfeited. **Breaking-ness overrules position on the ladder** — it is the one thing
  that can skip digits.

**A consequence worth knowing before planning a release train: a major line holds exactly 100 releases**
(10 minor lines × 10 patches). At one bump per track that is a lot of runway, but it is finite, and the
odometer rule means it cannot be extended by widening a component.

### The ladder from here

| version | what earns it |
| --- | --- |
| **`1.0.0`** | ✅ set 2026-08-19 — the state in the table above |
| **`1.0.1`** | ✅ **Track H** — hardening (shipped 2026-08-19) |
| **`1.0.2`** | **Track B** — bug hunt + code hygiene |
| **`1.0.3`** | **Track O** — optimization review |
| **`1.0.4`** | **Track S** — security review |
| `1.0.5` … `1.0.9` | whatever follows; the release after `1.0.9` is `1.1.0` |

### What counts as BREAKING — the only thing that jumps the ladder

The major bump is reserved for changes an existing consumer cannot absorb without editing code. For
wazmrt that surface is concrete and small; `universalWasmLoader-*`, wasmtk and rsxtk are the consumers.

1. **The C ABI in `include/wazmrt.h`** — a removed or renamed export, a changed signature, a changed
   struct/enum layout, or a changed ownership rule for a handle. ⚠️ **This also bumps `abi_version`**
   (currently `2`), which is a **separate number**: a `2.0.0` library does not imply ABI 2, and the two
   have already diverged — ABI 2 shipped while the library still said `0.1.0`.
2. **The Zig public surface** — `src/root.zig`'s exported decls changing incompatibly.
3. **A CLI contract change** — a removed flag or subcommand, or one whose meaning changes under an
   unchanged spelling. Adding a flag is not breaking.
4. **A behavioural change a consumer could be relying on** — a module wazmrt used to accept and now
   refuses, or a different default feature set. ⚠️ Note the asymmetry: *accepting more* is additive;
   **accepting less is breaking**, even when the refusal is the correct behaviour. Track F's enforcement
   work was exactly this shape, and a tightening found by Track S will be too.

**Not breaking:** a bug fix that turns wrong output into right output, a newly accepted proposal, a new C
export, a size or speed change, or anything visible only in the test suite.

---

## 🔢 WHERE THE NUMBER LIVES — four places, and only a grep keeps them honest

`root.version` is the single source of truth *in code*; the rest are copies that nothing checks.

| place | what it is |
| --- | --- |
| `src/root.zig` | `pub const version: [:0]const u8` — **the one truth**; the C ABI returns `root.version.ptr` |
| `build.zig.zon` | `.version` — the package manifest, a hand-kept copy |
| `include/wazmrt.h` | the `/* e.g. "1.0.1" */` example on `wazmrt_version_string` — cosmetic, but embedders read it |
| `cmem/overview.md` | the tree diagram's `v1.0.1` annotation |

⚠️ **No test asserts these agree.** `capi_smoke.c` *prints* the version and only pins `abi_version`
against the header, so the bump is a grep every time:

```
grep -rn '<old version>' src include build.zig.zon cmem
```

*(Adding a pinning test is a legitimate Track B finding — the same "a rule nobody has watched fail is not
enforcement" argument that turned the ABI version into a real gate.)*

---

## ✅ PER-RELEASE CHECKLIST (binding)

Every gate below already exists as a build step; this list adds no machinery, it only says which gates a
version bump requires. ⚠️ **Run from an NTFS cwd with `ZIG_LOCAL_CACHE_DIR` on NTFS** — a `D:` cache is
poisoned after exactly one build, and a `D:` cwd costs 4 unit tests and 2 of the 3 security tests
(`INDEX.md`).

1. **The track's own gate passes**, as written for that track in `roadmap.md`.
2. **`zig build test`, `zig build test-safe` and `zig build test-shipped`** — all three, and **diff the
   OUTPUT counts** against the pre-change baseline. An exit code of 0 does not prove no test was
   dropped. 🆕 **`test-shipped` (added Track H, 2026-08-19) runs the suite under `ReleaseSmall`** — the
   config that is actually distributed, with Zig's safety checks **off**. `test-safe` asks whether any
   input reaches a bad cast or index; `test-shipped` asks whether the **shipped** build behaves the
   same, and a miscompile or optimizer-exposed UB appears there and nowhere else.
3. **`zig build test-security`** — 3/3. A **skip here is a failure**, which is what the NTFS cwd buys.
4. **`zig build conformance -Dtestsuite=… -Dbaseline=…`** — and read **four** numbers: passed, failed,
   skipped, **and the count of files with failures or errors**. 🔒 **The baseline file is EMPTY and stays
   empty.** A line added there to make a release green is the failure mode that file invites.
5. **`zig build features`** — all four `-Dwat`/`-Dwasi` combinations compile.
6. **`zig build size -Doptimize=ReleaseSmall`** — all three ceilings EXACT. A release that moves a byte
   says so, with the reason, in the commit that moves it (`tools/size-ceilings.txt`).
7. **`zig build capi-smoke`** — the ABI-2 symbol and smoke gate.
8. **The shipped binary is STANDALONE** — copy `wazmrt.exe` to an empty directory, run it with a reduced
   `PATH`, and confirm it prints the new version; its imports must be only `ntdll`/`KERNEL32`. ⚠️ Not a
   formality: wasmrt's CLI silently needed a toolchain DLL for weeks while every dev-box test passed.
9. **Bump the four places**, then grep for the old string.
10. **Sync `cmem/` in the same commit** — `roadmap.md` (track → ✅), `testing.md` (the score), this file's
    ladder, and `INDEX.md`'s STATE AT PAUSE. A doc pass scheduled "after the release" is a doc pass that
    does not happen.

## What this project deliberately does NOT have

No `CHANGELOG.md`, no root `ROADMAP.md`, and no publish step — wazmrt is not on a registry and its
consumers build from source. `README.md` is the only public-facing doc and it carries **no version
string** (checked 2026-08-19), which is why it is absent from the four-places table. If wazmrt is ever
published, the release process grows a publish step and this section is where it goes.
