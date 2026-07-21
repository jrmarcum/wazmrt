# Known Issues — deferred fixes + their surfacing conditions

Findings from the **2026-07-09 code audit** ("look for code issues") that were **reported but not
fixed** — each is safe *today* but will bite a specific future integration. The point of this file is
the **"Surfaces when"** field: before starting one of those integrations, grep this file for the
milestone and fix the listed items first.

The audit's *fixed* items are in git (commit `d1fae13` — table-export index, instantiation-path leaks,
`parseGlobal` OOB, `table.size/grow` `@intCast` panic, dead `ExportNotFunction`, stale doc comments).
This file tracks only what's left.

Line numbers are hints (they drift) — the function/construct name is the durable anchor.

## Code audit 2026-07-19 ("look for code issues") — 8 fixed, a few deferred

**FIXED in git (`d0dddc5`)** — 3 parallel auditors (security / SIMD / sweep): **decodeSimd lane-bounds guard**
(out-of-range extract/replace/load_lane/store_lane lane → was an OOB read, and an OOB **stack write** for
replace/load_lane, since the CLI run path does NOT re-validate); **`sub_sat_u` unsigned-wide underflow**
(→ 255/panic instead of 0); **`i64x2.all_true`/`bitmask`** (0xc3/0xc4 missing from `execSimd` → trapped);
**demote/promote opcodes swapped** vs spec (0x5e/0x5f — interop break with external binaries);
**`f32x4/f64x2.nearest`** (validated but unimplemented → trapped); **WAT `memory.size`/`memory.grow`**
(no `.mem_index` emit arm); **`sign.findSignature` `payload_end - p` underflow** guard; dead `wStubBadf`
removed. +2 regression test blocks.

**#24 — `--pins`/`--verify` could weaken a root-owned enforce — RESOLVED 2026-07-19**
`verifyGate` now reads the **root-owned default path FIRST**; if it mandates `# mode: enforce`, `--pins`
is ignored and `--verify` downgrades are skipped — both the pin set and the policy come from root, so no
runtime flag can weaken it. When the default DB does **not** enforce (dev/unmanaged machines), `--pins`/
`--verify` work as before. Owner chose "root enforce is absolute" (2026-07-19). E2E-verified: root-enforce
+ legit-pinned runs; root-enforce + `--pins attacker.pins` → **denied** (flag ignored); `--no-verify` still
refused; root-`warn` + `--pins` still honored; bare build still runs everything.

**Run-path memory-safety hardening — DONE 2026-07-19** (second "look for code issues" pass)

Reaffirms the standing goal: *"maintaining memory safety is a massive project goal"* / *"never introduce
exploitable holes."* The CLI **run path** (`runFunction`/`runWasi`) does **not** validate the module before
executing — only the inspect path does. So the interpreter trusted immediates and stack values a malicious
module controls. Owner chose **"harden the interpreter"** (vs. validate-before-run). Fixes, all in
`src/interp.zig`:

- **`checkStaticIndices`** — a load-time pass run once per function body in `initWithImports` (zero
  per-execution cost). Bounds-checks every *static* index immediate against its module index space:
  local, global, table, elem, data, `table.init`/`table.copy`, `call_indirect` (table + type),
  `memory.init` data, struct/array `gc_type` (with struct-vs-array kind), `gc_field` (type **and** field
  index — the field is bounded vs the STATIC type), `gc_type_n`, `tag`, and `block_type` type index.
  Rejects with `UndefinedLocal`/`UndefinedGlobal`/`NoTable`/`UndefinedElement`/`UndefinedData`/
  `UndefinedType`/`GcOutOfBounds` before the hot loop ever runs. *Gotcha fixed during dev:* `array.len`
  carries `imm = .none` (not `.gc_type`) — reading `.gc_type` for it was a wrong-union panic; excluded.
- **`gcObject`** (the critical one) — bounds-checks the *dynamic* GC ref before indexing `gc_heap`. Was an
  **arbitrary-write primitive** via `struct.set`/`array.set` with a bogus/i31 ref → `GcOutOfBounds`.
- **`throw_ref`** — bounds-checks the exnref against `exn_store` before indexing.
- **`branch`** (now `Error!usize`) + **`rethrow`** — bounds-check the label depth (`n < labels.len`)
  before indexing the label stack; label depth is control-flow-relative so it can't be a static count →
  checked at its cold use site. Traps `UndefinedLabel`. Covers `br`/`br_if`/`br_table`/`br_on_*`/
  try_table catch-branch and legacy `rethrow`.
- **Stack-underflow bases** (`struct.new`/`array.new_fixed`/`throw`) — `len - N` used `std.math.sub` so a
  too-short stack traps `StackUnderflow` instead of a *wild* OOB read. (Plain `pop()` remains
  `pop().?` — panics-clean on empty, the interp's accepted stack-*height* baseline; these three were worse
  because the wild base reads far away.)
- **Core#6 `has_v128` gate** — the drop/select 2-slot width annotation was gated only on this function's
  params/locals/simd-ops, missing a v128 arriving via `global.get` of a v128 global or a call **returning**
  v128 → drop/select mis-sized on a *valid* module (stack desync). Now OR'd with a module-level
  `module_has_v128` (any v128 global or any signature with v128 in results).

All guards are cross-target-safe (`std.math.cast`, not `u64 >= usize`) so the freestanding wasm32 build
still compiles. 4 regression tests in `interp.zig` (`test "hardening: …"`) prove each malicious module
**traps** (not OOB): `local.get`/`global.get` OOB rejected at load; `br 5` traps at run; `struct.set` via
an i31 ref → `GcOutOfBounds`. Verified in **ReleaseFast** (shipped mode) via CLI: `add.wasm` runs (30);
`local.get 9` module → `error: instantiate: UndefinedLocal` (clean, no crash). WASI gate untouched
(`main.zig` unchanged; the pin/verify path is orthogonal to execution).

### Run-path hardening, 2nd pass — the stack-HEIGHT class — DONE 2026-07-19 (3rd "look for code issues")

A follow-up 3-auditor pass found that the *stack-height* underflow the 1st pass only fixed for three
opcodes (`struct.new`/`array.new_fixed`/`throw`) **survived in many more sites of the identical
`vstack.items[items.len - N ..]` wild-base pattern** — and one was worse than anything the 1st pass
touched. Lesson: the run path assumes a validated operand stack for *height*, and every `items.len - N`
used as a slice/index base is a wild-pointer hazard on the unvalidated CLI path. All fixed in `interp.zig`
via a `Frame.stackBase(n)` helper (`std.math.sub … catch error.StackUnderflow`) + a `peek()` helper:

- **CRITICAL — the call opcodes (`call`/`call_indirect`/`call_ref`).** `args = items[items.len - np ..]`
  underflowed to a wild base; `callFunction` then did `@memcpy(locals[0..args.len], args)` with **no
  `args.len` check** — an unbounded out-of-bounds **WRITE** into the small `locals` buffer (arbitrary
  memory corruption). Trigger: `(func (call 0))` calling a `(param i32)` function with an empty stack.
- **HIGH — `branch` arity + block/loop/if/try_table entry `stack_base`.** `from = items.len - arity` and
  `stack_base = items.len - params` underflowed → wild read/write on `br`/block-entry with too few
  operands.
- **MEDIUM — the call epilogue** (`@memcpy(res, items[items.len - n ..])`) and **`local.tee`** — OOB
  reads on an under-producing function / short stack.
- **LOW — `ref.cast`/`br_on_cast`/`br_on_cast_fail` peeks** (`items[items.len - 1]` on an empty stack).
- **`@intCast` of attacker-controlled ref/func values** — `call_indirect`/`call_ref` cast a `u64` funcref
  to `u32` (native ReleaseFast UB for a value ≥ 2³²) and `refMatches`/`definedFuncType` cast to `usize`
  (wasm32 UB); all switched to `std.math.cast(… ) orelse trap`.
- **`precomputeControlFlow` (load-time)** — a bare `else`/`catch`/`delegate` with no matching opener
  underflowed the precompute control stack → OOB. Now `error.UnbalancedControl` at instantiation.

+5 regression tests (`test "hardening: …"`): the call wild-write, epilogue under-produce, branch-arity,
and bare-`else` cases all trap `StackUnderflow`/`UnbalancedControl`. Also fixed **`opcode.zig` raw byte
`0xDA`** — it decoded to `memory_fill` carrying the wrong `Imm` union (`.mem_reserved` vs the real
`.mem_index` from the `0xFC 0x0B` path), a latent wrong-union read (was defanged only by `memBytes`'
downstream bounds check); the raw byte is now rejected `UnsupportedOpcode`. All targets (native
Debug/ReleaseFast + freestanding wasm32) build; 372→380 printed tests.

**DEFERRED from the 3rd pass (real but lower severity, not yet fixed):**
- **`wat.zig` — MEDIUM, memory-safety on the *host*.** The WAT assembler assumes well-formed s-expression
  shape: unchecked `items[N]` indexing + `.asList().?`/`.asAtom().?`/`.string` wrong-union unwraps
  throughout (`assembleModule`/`parseFunc`/`parseGlobal`/`parseTable`/`parseInstr`). Malformed `.wat`
  (e.g. `(module (export "x"))` — missing the index target) → OOB read / wild-union deref / null-unwrap,
  which is UB in the shipped ReleaseFast build. Reached **before** any verify gate via `wazmrt <file.wat>`,
  `wazmrt sign <in.wat>`, and `wazmrt pin <dir>` (assembles every `.wat` found).
  **FIXED 2026-07-19** (owner chose shape-checked accessors): added `wantList`/`wantAtom`/`wantStr`/`nth`/
  `fieldStr`/`strAt` helpers to `wat.zig` and routed **every** parser-derived access through them — all
  `.asList().?`/`.asAtom().?`/`.string` wrong-union derefs (35 sites) and the ungated `items[N]`/`target[N]`/
  `desc[N]`/`body[N]`/`[1]`-after-unwrap indexes across the module/import/export/tag/memory/type/func/global
  parsers now return `error.BadModuleField`. A `test "assembler rejects malformed forms …"` runs 8 malformed
  inputs; verified in ReleaseFast via CLI (`wazmrt evil.wat` → `error: cannot assemble … : BadModuleField`,
  no crash). *(Discovered while testing: a bare `(tag)` is a VALID empty tag `()→()`, not malformed — the
  old code crashed on it; the fix makes it assemble.)*
- **`sexpr.zig` parseList/parseValue — LOW (DoS). FIXED 2026-07-19.** Added a `max_depth = 1024` nesting cap
  (`Parser.depth` + check in `parseList`) → `error.NestingTooDeep`; a `((((…`-bomb no longer overflows the
  host stack. Regression test with 5000-deep parens.
- **`Module.zig`/`opcode.zig` alloc-before-read OOM amplification — LOW (clean fail). FIXED 2026-07-19.**
  Added `Reader.readVecLen()` (reads a vec count and rejects `> remaining()`, since each element needs ≥1
  byte) and applied it at every pre-alloc count read: import/export/function/tag/element/data/code sections,
  valtype/local/funcvec/exprvec/GC-field vectors (`Module.zig`), and `try_table`/`br_table`/`select_types`
  (`opcode.zig`). Byte-vec/name readers were already safe (`readBytes` precedes their alloc). A tiny module
  can no longer force a huge alloc *attempt*.
- **STILL DEFERRED (strictness / impractical, not memory-safety):** `opcode.zig` other raw internal-tag
  leniency (`0xE3–0xE5`, `0xED`, `0xF0–0xF2`, etc.) — accepted as non-standard single-byte encodings, but
  they land on the *correct* union, so over-acceptance only. **`Module.zig:1023`/`opcode.zig:766`**
  `@intCast` of a byte offset truncates for a >4 GiB module (impractical; only a wrong trap-backtrace offset).

### Run-path hardening, 3rd pass — verifying the 2nd pass's own refactor — DONE 2026-07-20 (4th "check for code issues")

A follow-up 3-auditor pass reviewed the code the 2nd/3rd passes *changed* (the sed-driven `wat.zig` accessor
refactor, the `Frame.stackBase`/`peek` interp refactor, `readVecLen`, and the CLI `-h`/`-v`). It found the
hardening was mostly sound but had **left holes of its own kind** — the sed and the underflow-guard both
closed one variant and missed a sibling:

- **`interp.zig` `branch` — HIGH, OOB WRITE.** The 2nd pass guarded the branch **source** base
  (`from = stackBase(arity)` ⇒ `arity ≤ items.len`) but not the **destination**:
  `copyForwards(dst = items[label.stack_base..][0..arity], …)` needs the stronger
  `stack_base + arity ≤ items.len`. `label.stack_base` is the *absolute* height recorded at block entry;
  on the unvalidated path a block can reach its `br` with fewer than `arity` operands above that base
  (`from < stack_base`), so the destination re-slice writes past the value stack — an amplifiable OOB
  **write** (K-result block ⇒ ~K slots). Trigger: `(func (result i32) (i32.const 7) (block (result i32)
  (br 0)))`. Fixed: `if (from < label.stack_base) return error.StackUnderflow;` (on a VALID module
  `from == stack_base`, so it never fires). Covers `br`/`br_if`/`br_table`/`br_on_*` + the try_table catch
  branch. +1 regression test.
- **`interp.zig` EH unwind — LOW.** `throwException` (try_table + legacy catch) and `rethrow` shrink the
  value stack to a caught label's `stack_base` without checking it's ≤ the current height; if the body
  popped below the base, `shrinkRetainingCapacity` *grows* `items.len` (its assert is compiled out in
  ReleaseFast), resurrecting stale slots as live values. Not an OOB write (within capacity; a bogus
  resurrected ref is caught by `gcObject`), but now traps `StackUnderflow` at all three sites.
- **`wat.zig` — 4 more raw-index holes the sed refactor MISSED** (malformed `.wat`, reachable pre-gate via
  `wazmrt file.wat`/`sign`/`pin <dir>`; each a wild `Sexpr`-union read → deref of a garbage `[]const u8`):
  (1) `parseGlobal` `gt[0]`/`gt[gt.len-1]` on an empty type list — the **sibling `parseImport` GOT this
  exact guard in the refactor but `parseGlobal` was left out** (`(global ())`); (2) the memory-limits
  fall-through `else` `parseIndex(items[mi])` — its `items[mi+1]` twin was guarded, this one wasn't
  (`(memory)`); (3) `parseElem` active-table `(wantList(items[i]))[1]` — the `.asList()` was wrapped but
  the `[1]` left raw (`(elem (table))`); (4) folded-`if` `then_form[1..]`/`ef[1..]` on an empty form
  (`(if () ())`). All now `error.BadModuleField`/`BadImmediate`; +4 test cases.
- **`main.zig` CLI `-h`/`-v` — CLEAN.** No verify-gate bypass (help/version `return` before any read/decode/
  execute), no OOB arg indexing (`args.len < 2` guard + short-circuit/slice access), guest argv still can't
  inject verify flags (`flagRegion` truncates at `--`), help text matches real flags. Only note: a file
  literally named `-h`/`-v`/`--help`/`--version` in cwd is shadowed (standard flags-vs-files tradeoff).

Lesson reinforced: a mechanical (sed) or single-variant fix closes the case it targets and leaves its
mirror — always sweep for the *sibling* pattern (source vs dest, twin index, guarded-here-not-there).
198 distinct tests; native Debug/ReleaseFast + wasm32 all build.

### Un-swept-surface audit — DONE 2026-07-20 (5th "check for code issues")

Prior passes intensely covered the run path + assembler; this pass aimed 3 auditors at files **untouched
this session**: `wast.zig`, `wasm_c_api.zig`, and `wasi.zig`/`validate.zig`/`sign.zig`/`pin.zig`.

- **`wast.zig` (the `.wast` runner, reachable via `wazmrt file.wast`) — 9 shape-safety holes, FIXED.** It
  shares the `sexpr` front-end with `wat.zig` but was **not** touched by the assembler hardening — the
  *sibling file* — so it kept the same unchecked pattern: every `assert_*` handler indexed `form[1]`/
  `form[2..]` unchecked, and `runAction`/`parseConst`/`matches`/`register` indexed `list[0]`/`list[i]`/
  `list[1]` and deref'd `.string` (wrong-union) on parsed input. Added `nth`/`asStr` accessors + `form.len`
  guards → `error.BadCommand`/`BadValue`; `@intCast(ref.func idx)` → `@bitCast` (a negative index is
  bogus-not-UB). +1 test (12 malformed shapes). Valid `.wast` unaffected (inline conformance tests pass).
- **`wasm_c_api.zig` (embedder C ABI) — import-extern USE-AFTER-FREE (HIGH), FIXED.** The Instance wrapper
  retained a handle on its Module (#20/#21/#22) but **not on the backed import externs** — the exact
  lifetime mirror. A func import stored the `*Ref` as trampoline ctx; memory/table imports borrowed the
  Ref-owned `*Memory`/`*Table`; none retained. The canonical callback.c pattern (delete the import externs
  right after `wasm_instance_new`) freed them while the running instance still borrowed them → UAF on the
  next call / any guest memory access. Fix: store `import_refs` on the wrapper, `retain` each in
  `wasm_instance_new`, `refDelete` each in `wasm_instance_delete` (symmetric with the module handle);
  globals are copied by value. Also **MEDIUM**: `wasm_table_get` `@intCast(u64→u32)` on an externref slot
  (host pointer > u32) → ReleaseFast UB → now `std.math.cast → null` (funcref-only contract); **LOW**:
  `wasm_func_call` null-`data` deref on a `size>0` vec; `wasm_importtype_new`/`wasm_exporttype_new` leaked
  moved-in args on null/OOM early-returns. +1 regression test (import a host memory, delete it, then
  `i32.load` → 42; the #22 fuzz only ever used the import-free `add` module).
- **`pin.zig` `modeFromDb` — MEDIUM security, FIXED.** A present `# mode:` with an unrecognized value
  (typo `enfroce`, casing `Enforce`, inline comment `enforce # prod`, empty) returned `null` =
  indistinguishable from "no directive", so `verifyGate` saw no enforce and `--no-verify` could override
  the armed default-deny — silently downgrading the **absolute** root enforce (#24). Now fails **closed**
  → `.enforce` (strictest), matching the hash lines' `InvalidPinLine` posture. +4 test cases.

**CLEAN (examined, no real defect):** `sign.zig` (`findSignature`/`verify` bounds-safe, can't wrongly
authenticate), `wasi.zig` sandbox core (`resolve`/`walkFull` escape-resistant, rights only narrow, no
fd-pointer-across-realloc), `validate.zig` (no accept-invalid / OOB), `pin.zig` apart from `modeFromDb`.

**DEFERRED LOWs from the 5th pass** (not memory-safety / not run-path):
- **`validate.zig array_new_fixed` (`:744`) + locals expansion (`:191`) — inspect-path CPU/OOM DoS.** A huge
  `array.new_fixed n` (up to 2³²) in **unreachable** code makes the validator's `popExpect` loop spin ~4e9
  times (`popVal` returns `.unknown`, never underflows); likewise a huge `local` run-length drives a
  multi-GB append. Only on the **inspect** path (`wazmrt <module>` summary), never the run path (which
  self-defends in `interp`, not the validator) — so CPU/memory exhaustion inspecting a hostile module, not
  a safety/execution issue. **Fix if wanted:** cap the count (mirror `readVecLen`).
- **`validate.zig br_on_non_null` (`:815`) — reject-valid (conformance).** Hard-codes the label's last type
  to `funcref`/`externref`, wrongly rejecting a valid GC/typed-ref label (`i31ref`/`anyref`/`(ref $t)`/…).
  Inspect-path only, no safety impact. Fix: accept any last-type reference the popped ref subtypes.
- **`wasi.zig` (`:748`/`:823`/`:1557…`) — hardening.** `gatherIovecs`/`fd_read`/`poll_oneoff` form a guest-
  controlled byte offset in **u32** before the (correct, widening) `readU32`/`slice` bounds check. Contained
  today (the pre-alloc size check / the subsequent fault check bound the reachable index below overflow), so
  **not exploitable** — but deviates from the file's widen-then-check discipline. Compute those offsets in
  `u64`.
- **`wasm_c_api.zig` trap frames (`makeTrapFrom`) — LOW.** A `Trap`'s snapshotted frames store a borrowed
  `*Instance` without retaining it; `wasm_frame_instance` after `wasm_instance_delete` hands back a dangling
  pointer. It's a *borrowed* accessor (header doesn't mark it `own`), so arguably caller error — the one
  spot departing from the "a stored `*Instance` owns a handle" discipline. Retain in the frame + release in
  `wasm_trap_delete` if airtight is wanted.

### Integer-overflow-UB sweep — DONE 2026-07-20 (6th "check for code issues", memory-safety-only)

Targeted pass ("fix any memory-unsafe issues"): 3 auditors re-checked the C-ABI import-ref lifecycle
(commit `c6ff764e`), the `wasi.zig` guest-memory paths, and the `interp.zig` exec/instantiation memory ops.
Two of the three came back **clean** (see below); `wasi.zig` had a real class the earlier "contained-u32-
offset" note missed — **unchecked `@intCast`/`+` narrowings of 64-bit byte counts → ReleaseFast integer UB**
on the *shipped native* target. All FIXED:

- **`wasi.zig` `fd_write`/`fd_read`/`fd_pread`/`fd_pwrite`** — the `nwritten`/`nread` value is `@intCast(total)`
  → `u32`, but `total` is a `u64` sum of (possibly **overlapping**) iovec lengths / a file byte count, which
  can exceed `u32` (trigger: a 64 MiB memory + 64 overlapping 64 MiB iovecs → `total = 2³²`; or a >4 GiB
  file). Now `std.math.cast(u32, …) orelse errno.fbig`. The paired `f.offset = at + total` / `+= total`
  (u64 add) → `std.math.add … catch errno.fbig`.
- **`wasi.zig` `fd_seek`** — `f.offset = @intCast(target)` (i128→u64) was guarded only for `target < 0`; a
  `CUR` seek with `delta = i64.max` **compounds** `f.offset` past `u64` → `@intCast` UB. Added the upper
  guard → `errno.inval`.
- **`interp.zig` memory alloc + `memoryGrow`** — `min * page_size` / `(old_pages+delta) * page_size` are fine
  on 64-bit (`2³² × 2¹⁶` fits `u64`) but overflow on the **wasm32** build (`usize = u32`), and `memoryGrow`'s
  `limit` didn't clamp an unvalidated `m.max` to the architectural 2¹⁶-page cap. Now `std.math.mul(usize, …)
  catch OOM/-1` and `limit = @min(m.max orelse 65536, 65536)`. Harmless on 64-bit (allocation of an oversized
  memory just fails); closes the wasm32 UB and is spec-correct (memory ≤ 2¹⁶ pages).

These trigger only at multi-GB scale or on wasm32, so a native Debug unit test would need impractical huge
allocations — verified by code review (a checked cast replaces each unchecked one), the clean full suite, and
all three targets building. **CLEAN this pass:** the C-ABI `c6ff764e` retain/release is balanced (no
`vec_owned`/export-handle ref enters `import_refs`; error paths leak-free; delete ordering correct; no
`destroyRef` recursion), and the `interp.zig` data/element-segment init, bulk `memory.*`/`table.*`, load/store
EA, GC-heap/`exn_store` lifecycle, and SIMD lane indexing are all overflow-safe (`@as(u64,x)+n>len` form,
arena-backed `.fields`, by-value label/exn capture).

### `@intCast` census — DONE 2026-07-20 (7th "check for code issues", memory-safety-only)

A systematic sweep of **every `@intCast` in `src/`** (classify each: comptime-safe / bounds-checked-before /
attacker-controlled-unchecked) plus a deep-arithmetic re-audit of `validate.zig` + `sign.zig`. Found and
FIXED two attacker-reachable `@intCast`-out-of-range UB (ReleaseFast illegal behavior):

- **`wat.zig` SIMD lane/shuffle** (`emitSimd` `.lane`/`.shuffle`/`.mem_lane`, 3 sites) — a `.wat`-parsed lane
  or shuffle index was `@intCast(u32→u8)` with **no mask or bound**, so `(i32x4.extract_lane 999)` /
  `(i8x16.shuffle 999 …)` (reachable via `wazmrt file.wat`/`sign`/`pin <dir>`) was cast-out-of-range UB. Now
  `std.math.cast(u8, …) orelse error.BadImmediate` (an index in `[laneCount,255]` still flows to the
  decoder's lane-bounds check; the `i8x16.const` case at `parseV128Const` already masked with `& 0xff`, and
  the other const shapes use `@truncate` — all safe). +2 test cases.
- **`interp.zig` try_table catch** (`throwException`, `:1106`) — `branch(@intCast(d + c.label))` where
  `c.label` is an unvalidated `u32` catch-clause label and `d` the try depth: a `c.label` near `u32max` made
  `d + c.label` overflow (add-overflow on wasm32; cast-out-of-range on 64-bit) **before** `branch`'s own
  bounds check. Now `std.math.cast(u32, @as(u64,d)+c.label) orelse error.UndefinedLabel` (verified by
  review; a hand-built try_table with a `u32max` label is impractical to encode for a unit test).

**CLEAN (verified):** `validate.zig` (deep arithmetic re-audit — `n_imported_globals` can't underflow;
`popVal`/`popCtrl`/`labelTypesAt` guard the frame stack; `dropSelectWidths` `w[pc]` in-bounds since both
passes `decodeBody` the same bytes deterministically; all type/index immediates flow through bounds-checking
accessors); `sign.zig` (`findSignature`/`canonicalVerify`/`readUleb` bounds hold adversarially — no
start>end excluded range, no over-shift). `Module.zig`/`opcode.zig` `@intCast` all guarded or the logged
>4 GiB truncation; `wasi.zig` remaining casts are widening (`u64→i96` nanoseconds), host-bounded (argv), or
impractical (4-billion fds); `wast.zig`/`wasm_c_api.zig` casts are widening or page/entry-count-bounded.

### Latent-class census — DONE 2026-07-20 (8th "check for code issues", memory-safety-only) — NO NEW ISSUES

After 7 fix-heavy passes the explicit-bounds/`@intCast` surface was saturated, so this pass censused the
memory-unsafety *classes* the prior passes hadn't systematically swept. **All clean — nothing to fix:**

- **`std.debug.assert`-as-guard — ABSENT.** Zero `std.debug.assert`/`assert(` in `src/` (an assert guarding a
  bounds op would be a no-op in ReleaseFast — the class simply doesn't exist here).
- **Pointer/slice held across an ArrayList/HashMap mutation (use-after-realloc) — CLEAN tree-wide** (agent
  sweep). There are **zero** `getPtr`/`getOrPut`/`addOne`/`getLast` calls and no `&list.items[i]` captures in
  the tree; the two `for (…) |*x|` captures (`wat.zig:406` mutates only *other* lists; the interp call-arg
  slices `vstack.items[base..]` are `@memcpy`'d into the callee's fresh `locals` before the callee runs and
  the caller only grows `vstack` *after* the call returns) are safe. Re-confirmed with fresh reasoning:
  `gc_heap`/`exn_store`/`vstack`/`labels` (arena-backed `.fields`, by-value `exn`, build-then-append order),
  the WASI `fds` table (`ResolvedPath.dir` is an `Io.Dir` *value*, no `*FdEntry` held across `put()`), and the
  `sigs`/`ctx.out` assembler lists.
- **`unreachable`/`orelse unreachable` — none reachable on attacker input.** Every non-test site is dead by
  construction (the interp load/store `else` and `instr.imm.mem` access are gated by the main-loop op-dispatch;
  `wat.zig`'s `switch (kind∈0..3)` / `emitRefCast` op switches are exhaustive over what's dispatched) or a
  caller-guaranteed type invariant (`types.zig refHeap`'s `else`s can't fire — concrete-ref kind bits are only
  ever 0/1/2, and all callers guard `isRef` first: `wasm_c_api.zig:354` `if (!v.isRef()) return 0;`,
  `validate.zig` `isSubtype` guards its operands).
- **Residual wrong-union `.?` / pointer casts — none on untrusted input.** The only `.asList().?` outside the
  hardened `wat.zig`/`wast.zig` are in `sexpr.zig` *tests*; every `@ptrCast(@alignCast(ctx))` in `wasi.zig`
  casts the **wazmrt-supplied** host-func context (`&wasi`), never guest data; the C-ABI `@ptrCast`/
  `@fieldParentPtr` were verified in the 6th pass.
- **Byte-copy primitives (`@memcpy`/`@memset`/`copyForwards`/`copyBackwards`) — CLEAN** (added 2026-07-20).
  `@memcpy` is UB on unequal lengths or overlap; every site uses `dst[..][0..n]`/`src[..][0..n]` (equal `n`,
  bounds-checked `x+n>len` first) with distinct buffers, or the overlap-safe `copy{Forwards,Backwards}` for a
  same-buffer `memory.copy`/`table.copy`. `callFunction`'s `@memcpy(locals[0..args.len], args)` can't OOB-slice
  because `args.len = typeSlots(callee params) ≤ num_local_slots = locals.len`. `@memset` always fills a whole
  slice. `sign.zig`'s copies into `loc.key`/`loc.sig` are guarded by `content.len == 104`.

Conclusion: no new memory-unsafe issue this pass. The run path, decode, assembler, `.wast` runner, C ABI,
WASI, validator, and crypto have each now been swept for memory safety multiple times from complementary
angles (bounds/OOB, `@intCast` overflow, lifecycle/UAF, use-after-realloc, `unreachable`/assert). Remaining
open items are the previously-logged **non-memory-safety** LOWs (validator inspect-path DoS, `br_on_non_null`
reject-valid, C-ABI trap-frame borrowed instance).

**Low-priority notes (safe today):**
- `wasi.zig Wasi.init` — `w.fds.appendSlice(...) catch {}` swallows OOM registering the 3 stdio fds (init
  then reports success with no stdio). Near-impossible; propagate for cleanliness someday.
- `Module.zig skipConstExpr` — the byte-level const-expr skipper's `else => {}` would misread a `0xFB` GC
  const-op *immediate* (e.g. `struct.new $t`) as opcodes; the "operand can't be mistaken for the
  terminator" doc claim is overstated. Not triggerable (interp rejects GC const-exprs anyway; Reader is
  bounds-checked). **Surfaces when:** GC const-expr support is added.
- `wat.zig naturalAlign` and `validate.zig naturalAlignLog2` are byte-identical duplicated helpers (both
  live). Could share; no correctness issue.

### Untrusted-input DoS + name-bound-import class — DONE 2026-07-20 (10th "check for code issues") — 10 FIXED

The first pass in a while to find **crashes reachable from a handful of bytes**. The prior nine passes had
saturated the *explicit-index* surface; this one's finds all sit in classes those sweeps structurally could
not see: a **parser that fails to advance** (no index involved), **imports bound by name without checking the
declared type**, and **two parallel arrays the decoder never cross-checks**. Four auditors (interp/opcode ·
new uncommitted work · wat/sexpr/Module/Reader · wasi/c-api/main/pin/sign/validate), each finding traced to a
concrete input and re-verified against the rebuilt CLI.

**The one that matters most — `sexpr.zig` lone `;` → infinite loop. CRITICAL.**
`skipTrivia` consumes `;;` and `(;` but **not** a bare `;`; `parseAtom` treats `;` as a terminator, so it
returns an **empty** atom **without advancing `pos`**, and `parseAll`/`parseList` append empty atoms forever.
`(module) ; x` — **12 bytes** — hung the shipped CLI at **10.4 GB RSS in 12 s**. Reachable pre-gate from
`wazmrt file.wat`, `file.wast`, `sign`, and `pin <dir>` (which assembles every `.wat` it walks). Fixed:
`parseValue` rejects a lone `;` → `error.UnexpectedChar`, **plus** a zero-progress guard (`at.len == 0`) so no
future `parseAtom` delimiter can reintroduce the class. *Lesson: the `NestingTooDeep` fix (3rd pass) hardened
this same file against a `((((`-bomb — but a depth cap only sees recursion, not a loop that never advances.
`;;` and `(;` were handled; the single-char case fell between them.*

**`wasi.zig` — host imports bound by NAME only, declared arity never checked. HIGH (host segfault).**
`main.zig` wires `wasi.hostFunc(imp.name)`; `interp.callFunction` sizes the `args` slice from the **module's**
declaration. So `(import "wasi_snapshot_preview1" "fd_write" (func))` — zero params — made every
`argU32(args, 0..3)` read past the end of the value stack. **Verified: exit 139 from a 4-line `.wat`.** Also
reproduced via `path_open`/`poll_oneoff`/`fd_seek`/`random_get`/`args_get`; a *partly*-short arity doesn't
crash but silently leaks one stack slot into guest-visible results (`fd_seek`'s `delta`/`whence`). Fixed with
a comptime `guardArity(f, n)` wrapper on every entry in `callFor`'s map, `n` = the preview-1 parameter count;
short call → `false` → `error.HostTrap` (hard abort, per the project rule), never a silent errno. Arities were
cross-checked against the highest index each implementation actually reads, so none can be under-declared.

**`main.zig:767` — `module.funcType(fi).?` on an export index the decoder never cross-checks. HIGH (segfault).**
`Module.decode` enforces no section-order/no-duplicate rules: a **second** `function` section *appends* to
`func_space` but *replaces* `module.functions`, so an export index the decoder accepted can be out of range for
`funcType`. The run path never validates, so it reached a null unwrap → **exit 139 from a 31-byte module**
(verified). Fixed: `orelse` → a named error. *Note this fires before `Instance.init`, so the CountMismatch
guard below does not cover it.*

**`interp.zig initWithImports` — `for (module.functions, module.code, bodies)` with unequal lengths. HIGH.**
Zig requires equal lengths; unequal is illegal behavior, and in **ReleaseFast** it iterates the *first*
object's length — reading `Module.Code` structs past the end of the code slice and handing their garbage
`body` ptr/len straight to `decodeBody`. Only `validate.zig:62` compared the two section counts, and the CLI
run path never validates. Fixed: `error.CountMismatch` at the top of `initWithImports`. (Left `Module.decode`
alone deliberately — rejecting there would reclassify an *invalid* module as *malformed* and could move
`assert_invalid`/`assert_malformed` conformance results.)

**`interp.zig checkStaticIndices` — `try_table`'s block type was never bounds-checked. HIGH.**
The `.block_type` arm covers `block`/`loop`/`if`/legacy `try`, but `try_table` carries its block type *inside*
the `.try_table` immediate, so it fell to `else => {}`. `blockArity` then `.?`-unwrapped a null `funcSig` and
iterated a garbage slice, whose length became the label arity that `branch` copies with. Fixed: a `.try_table`
arm mirroring the `.block_type` one. **The sibling-of-a-fixed-site pattern again** — exactly what the 4th pass
warned about.

**`wat.zig parseTable` — two unguarded `items[i]`. HIGH (wrong-union deref in ReleaseFast).**
`(module (table))`, `(table $t)`, `(table (export "x"))` leave `i == items.len` at the `isRefType(items[i])`
probe; `(table 1)` / `(table 1 2)` run out at the element-type read after min/max (the *max* probe was
guarded, its twin was not). The sibling paths had all been hardened in the 3rd/4th passes — `parseTable` is
the mirror the sweep missed, **for the third pass running**. Fixed via `nth`.

**`wasm_c_api.zig wasm_ref_copy` — use-after-free + double-free. HIGH.**
`RefApi.copy` (the typed `wasm_X_copy`) *duplicates* a `vec_owned` export handle because
`wasm_extern_vec_delete` calls `destroyRef` unconditionally, ignoring the refcount. `wasm_ref_copy` — the base
`wasm_ref_t` copy the header declares — was a plain `retain`, so
`wasm_ref_copy(wasm_extern_as_ref(exports.data[0]))` then `wasm_extern_vec_delete` then `wasm_ref_delete`
released into freed heap and could destroy it twice. All header-sanctioned calls, no misuse. Fixed by applying
the same dup rule. *Why #22's fuzzer missed it: it only ever obtains refs from `wasm_table_get`, never from
`wasm_extern_as_ref` + `wasm_ref_copy`.*

**`wasm_c_api.zig hostTrampoline` — uninitialized heap disclosed to the guest. MEDIUM.**
`resvec` comes from `wasm_val_vec_new_uninitialized` and **every** slot is read back, but `wasm_instance_new`
never checks the host functype against the import it backs — so a callback declaring fewer results (or leaving
a slot unwritten) handed the guest raw host heap. Fixed: zero the vec first, plus null-`data` guards on both
vecs (OOM would have dereferenced null).

**`wasm_c_api.zig freeExternType` — `wasm_tagtype_delete` was a silent no-op. MEDIUM (unbounded leak).**
`EXTERN_TAG` fell into `else => {}` while `wasm_tagtype_new`/`copyExternType` both allocate a TagType **and**
an owned FuncType with two valtype vecs. The only `wasm_X_new` in the file with no working destructor. Fixed.

**`main.zig flagRegion` — guest argv could disable signature verification. MEDIUM (security).**
The doc comment already stated the rule ("a guest arg that happens to read `--no-verify` is never mistaken for
one of ours") but the code only truncated at an explicit `--`. The common WASI form has no `--`
(`wazmrt prog.wasm install --yes`), so the **guest's own arguments** were scanned and `--yes`/`--no-verify`
anywhere in them set `opt_out` → `pin.decide(...)` returned `.run`. Bounded by root `# mode: enforce`, so it
failed open only in armed-default and `warn` modes — i.e. the ordinary deployment. Fixed: `flagRegion` now
consumes only the **leading run of recognized wazmrt flags**, mirroring exactly what `runWasi` consumes.

**DEFERRED — owner decisions, deliberately not taken unilaterally:**
- ~~**Eager memory commit — a 38-byte module costs 4 GB.**~~ **FIXED 2026-07-20** (owner chose *lazy pages +
  a cap*, default 1 GiB with `--max-memory`) — see "Linear memory: lazy pages + a budget" below.
- ~~**`random_get` is not a CSPRNG.**~~ **FIXED 2026-07-20** — `std.Random.DefaultCsprng` (ChaCha) seeded
  lazily from **`io.randomSecure`**; `Wasi.init` no longer takes a seed. `randomSecure` (not `io.random`,
  which falls back to "a less secure mechanism" and is `noRandom` = **all zeros** on an `Io` without
  randomness); entropy failure → **`EIO`**, never weak bytes. Seeding through `Io` rather than
  `std.crypto.random` kept the freestanding-wasm target building; lazy seeding kept cold-start at
  1.11 µs/run. Details in `security-model.md`.
- ~~**`.wast` bypasses `verifyGate` entirely.**~~ **FIXED 2026-07-20** — `verifyGate` now runs on the script
  bytes before `runScript`. Hashing the *script* is the right granularity: every module it executes is
  contained in those bytes, so authorizing the script authorizes exactly what it can run. E2E-verified:
  unpinned `.wast` under enforce → refused; `wazmrt pin <f>.wast` → runs; bare build (no DB) → unchanged.
  *Lesson: the gate was attached to the "module" path, not to **every path that executes** — when adding an
  input form to `main.zig`, ask "does this execute?", not "is this a module?".* See `security-model.md`.
- Still-open LOWs from earlier passes, re-confirmed: `validate.zig` inspect-path DoS (`array_new_fixed`,
  locals expansion, **plus** a newly-measured `pushCtrl` `dupe(bool, local_init)` per control frame — a 512 KB
  module drove **767 MB** peak, ~1500× amplification), `br_on_non_null` reject-valid, C-ABI trap-frame borrowed
  `*Instance`, `wasi.zig` u32-before-widening offsets (add `writeStringVec` to that site list), `keygen`
  writing the Ed25519 seed with default (world-readable) permissions, `--verify <bad>` silently ignored,
  `wasm_instance_new` import-loop `host_funcs` OOM leak, `wat.zig` `(table N …)` unbounded `alloc(Sexpr, min)`
  (clean OOM fail). *(`Frame.pop`'s unguarded `vstack.pop().?` was on this list; **FIXED 2026-07-20** — see
  "Operand-stack underflow" below.)*

**Verification:** `zig build test` **389/393 (4 skipped)** and `zig build test-safe` (ReleaseSafe — where
out-of-range `@intCast`/OOB/null-unwrap panic instead of being silent UB) **389/393**, both matching the
pre-change baseline; `c-smoke` OK (319/319 symbols); `wasi-gate` exit 0; every reproducer re-run against the
rebuilt CLI; `examples/*.wat` and a comment-heavy `.wat` still assemble (the `;` fix does not touch `;;`/`(;`).

**Environment note (not a code defect):** the repo's local `.zig-cache` was corrupt — *every* `zig build`
invocation, including `zig build --help`, failed with a bare `error: Unexpected`. It looks exactly like a
build break. `rm -rf .zig-cache` clears it; this pass worked around it with `ZIG_LOCAL_CACHE_DIR`.

### Linear memory: lazy pages + a budget — DONE 2026-07-20 (10th-pass deferred item #1)

**Was:** `Instance.init` allocated *and eagerly zero-filled* every declared memory minimum, so a **38-byte**
module declaring `(memory 65535)` cost **4054 MB RSS / 2.85 s**, and multi-memory multiplied it. **Owner
chose "lazy pages + a cap"** (1 GiB default, `--max-memory` to change).

**Now:** linear memory comes from `std.heap.page_allocator` instead of the instance allocator. Fresh OS
mappings are **demand-zero** (`NtAllocateVirtualMemory(.COMMIT)` / `mmap(MAP_ANONYMOUS)`; `PageAllocator`
goes straight to those and back with **no free-list**, verified in std source), so a declared minimum costs
*address space*, not resident memory, and needs no `@memset`. A per-instance budget
(`Imports.max_memory_bytes`, default `default_max_memory_bytes` = 1 GiB) is summed across **all** memories
and enforced again in `memory.grow` (which reports failure as `-1`, per spec, not a trap).

Measured: 4 GiB declaration **2.85 s / 4054 MB → 0.05 s / ~0 MB** (`MemoryLimitExceeded`); a 1 GiB
declaration (at the cap) instantiates in **0.15 s at ~0 MB RSS** and the guest reads **0**; `hello_wasi`
unchanged.

**The trap that nearly shipped — `std.mem.Allocator.alloc` poisons.** The first version used
`memory_allocator.alloc`, and the 1 GiB probe came back **1029 MB RSS with the guest reading
`0xAAAAAAAA`**. `std.mem.Allocator.allocBytesWithAlignment` does `if (runtime_safety) @memset(byte_slice,
undefined)` — so under Debug/ReleaseSafe every allocation is filled with `0xAA`. That both touched every
page (destroying the laziness) **and** made the guest observe `0xAA` where the spec requires zero — a
wrong answer *that differs by build mode*, which is the worst kind to ship. Fixed by going through
`rawAlloc`/`rawFree`/`rawRemap` (`allocGuestMemory`/`freeGuestMemory`/`growGuestMemory`), which skip the
poison. **`test "hardening: guest linear memory is zero-initialized, in every build mode"` pins it, and is
meaningful precisely because the suite runs in Debug.** *Lesson: "the allocator returns zeroed pages" is
false for `Allocator.alloc` under safety — measure the bytes the guest actually sees, don't reason about
it.*

### Operand-stack underflow: `Frame.pop` — DONE 2026-07-20 (10th-pass deferred item #4)

**Was:** `fn pop` was `self.vstack.pop().?`. `(func (export "f") drop)` consumes an operand it never
produced, so on the unvalidated run path this reached a **null unwrap** — panic in Debug/ReleaseSafe,
**undefined behaviour in the shipped ReleaseFast build** (the optimizer may assume the stack is non-empty).

**Now:** underflow yields a *defined* `0` and sets `Frame.underflowed`, which the end of `run`'s dispatch
loop turns into `error.StackUnderflow`. Converting `pop` to `Error!Value` was rejected: **237 pop-family
call sites** in the hot loop.

**Why deferring the trap to the end of the loop is safe:** the substituted `0` cannot escape the sandbox —
every consumer of a popped value (memory addresses, table/GC/element indices, branch depths) is
independently bounds-checked, so the interim value is *wrong, never unsafe*. The end-of-loop check catches
both exits (falling off the last instruction, and `return`, which sets `pc = ir.len`); the other ways
control leaves a frame — call arguments, `branch`, the epilogue — already trap via `stackBase`/`peek`.

**Perf — measured, and the reason for the shape (`zig build bench`, ReleaseFast):**

| variant | steady-state |
| --- | --- |
| baseline (`.?`, UB) | 248–252 Mops/s |
| flag, no `@branchHint` | 218–226 Mops/s (**−12%**) |
| flag + `@branchHint(.cold)` | **244–250 Mops/s (parity)** |
| + per-instruction check (hinted) | 212–216 Mops/s (−13%) |

Two non-obvious results: `.?` is *fast* because it lets the optimizer elide the length check entirely, so
any real check costs — but **`@branchHint(.cold)` on the underflow arm recovers all of it**. And a
per-instruction `if (underflowed)` in the dispatch loop costs ~13% *even hinted*, which is why the check
lives at the loop exit, not inside it. **Rule: when adding a guard to the interpreter's hot loop, mark the
failure arm `@branchHint(.cold)` and benchmark — this is the same lesson as the `noinline recordTrap` result
in #19.**

### Deferred-item cleanup — DONE 2026-07-20 (closing the 10th pass's "still open" list)

**Resource caps (`validate.zig` + `interp.zig`).** Three amplifiers a tiny module could trigger:
- **Control nesting** — every `pushCtrl` `dupe`s the whole local-init vector, so cost is depth × locals: a
  512 KB module (2 000 locals, 262 144 nested blocks) drove **767 MB** peak. Now `max_ctrl_depth = 1024`
  → `NestingTooDeep` (also matching `sexpr.zig`'s parser cap, so nothing reachable from text can exceed it).
- **Locals** — the run-length form lets a few bytes ask for billions; the old loop appended one at a time.
  Now summed in u64 and capped at `max_locals = 50 000` (wasmtime's own default). **The two caps must be
  read together: the snapshot cost is their PRODUCT**, so a generous locals cap silently reinstates the
  amplification (2²⁰ × 1024 would still be ~1 GB); 50 000 × 1024 bounds it at ~51 MB.
- **The run path had the same hole** — `interp` expanded locals with no cap, and `local_count` is `usize`,
  which on the **wasm32 build is 32 bits and would wrap**. Now summed in u64 against the same
  `validate.max_locals` (exported for this) → `error.TooManyLocals`.
- **`array_new_fixed`** — `n` is an unvalidated u32 and in *unreachable* code `popExpect` returns
  `.unknown` instead of underflowing, so the loop could spin ~4e9 times. Bounded by the body's instruction
  count, which **cannot reject a valid module** (every operand needs ≥1 instruction to produce it).

**`wat.zig` `(table N reftype initexpr)`** synthesized `N` `Sexpr` copies — `(table 4000000000 …)`, 48
bytes, asked for ~96 GB. Capped at 2²⁰ → `BadImmediate` (0.095 s, was a 96 GB alloc attempt).

**`wasi.zig`:**
- **`path_symlink` now refuses a lexically escaping relative target** (`../../x`) at *creation*, not just
  absolute ones — `security-model.md` requires this so the guest cannot plant a landmine for the next
  privileged reader (host `tar`, `cp -L`, the next pipeline stage). `escapesRelative` tracks depth, so an
  in-sandbox `a/../b` is still allowed. **Does not affect `examples/wasi_symlink_traversal.zig`**, which
  plants its links externally via `ln -s` and tests *following*, not creation.
- **`writeStringVec`** (`args_get`/`environ_get`) formed guest offsets in u32 before the widening bounds
  check — the 4th site of the logged class. Now computed in u64 and narrowed only after checking.

**`wasm_c_api.zig` `wasm_instance_new`** leaked the `host_funcs` buffer on the import loop's
`catch return null` paths. Fixed with a plain `defer host_funcs.deinit(alloc)` — sound because
`toOwnedSlice` empties the list on success — and the two now-redundant explicit `deinit`s on the later
error paths were removed (they would have been double-deinits).

**`main.zig` `--verify <garbage>` now fails closed** instead of being silently ignored. It can only *raise*
strictness, so ignoring a typo silently dropped the user's intended extra strictness — the opposite posture
to `modeFromDb`'s 5th-pass fix. **`keygen` writes the Ed25519 private seed 0600** on POSIX (was 0644 after
umask — world-readable, for the one file in the project that must not be). Windows has no mode bit here, so
the file inherits the directory ACL; the honest mitigation there stays the documented one (HSM / don't put
the key on a shared path).

**A 10th-pass finding that was WRONG — recorded so it is not "fixed" again.** The audit reported
`validate.zig`'s active-element/table check as accept-invalid, claiming
`elem.elem_type.nullable() != tet.nullable()` compared two booleans. **`ValType.nullable()` returns the
*nullable form of the type*, not a predicate** — so the line already compared heap types with nullability
normalized away, which is correct. Verified empirically: an `externref` segment against a `funcref` table
is rejected `TypeMismatch`. A comment at the site now says so. *Lesson: an audit finding is a hypothesis;
this one survived a plausible-sounding write-up and died on a two-minute check.*

**Conformance gate is now usable.** `zig build conformance` gated on **zero** failures, which upstream has
never satisfied here (this file's own snapshot records linking 37, return_call_ref 9, …) — a forever-red
step gates nothing and teaches people to ignore it. Added `-Dbaseline=<file>` (expected failures per file;
`error <path>` for files the runner cannot parse) and `-Dwrite-baseline=true` to generate one. It now fails
only on **regressions**, reports improvements, and with no baseline explains why it is strict and how to
adopt one. All five paths verified on a synthetic corpus: no-baseline → fail; write → generate; check →
pass; a new failure → fail; a fixed failure → pass + "improved".

**Fuzz targets now detect allocation amplification.** They `catch` `OutOfMemory` (a malformed input
legitimately producing one is not a bug), which made the whole amplification class — the very thing
`readVecLen`, the memory budget and the table cap exist to prevent — **invisible by construction**. The
sweep now runs under a 64 MB `Budget` allocator and asserts it was never exceeded, and that `live` returns
to **0** (a leak check independent of the testing allocator's). Both hold today.

**Verification:** `test` and `test-safe` now print **407 (403 pass, 4 skip)** = **209 distinct** (198 core
+ 11 C-ABI), up from 403/207 — the resource-cap regression test and the symlink-escape test, plus the
budget/live assertions folded into the existing sweep. `c-smoke` 319/319, `wasi-gate` + freestanding `wasm`
green, steady-state ~240 Mops/s.

### Cleanup batch (items 9–13 of the remaining list) — DONE 2026-07-21

Owner sequenced the leftovers 9–13 → 1–3 → 4–6, deferring **#8** (the Zig 0.16 Windows `Io` bug) since
only an upstream fix can close it. This is the first batch.

- **`opcode.zig` raw internal-tag leniency — now REJECTED.** `0xd7..0xfa` are wazmrt's internal `Op` tags
  for ops whose real wire form is `0xFB`/`0xFC` + a LEB sub-opcode, so a **raw** byte in that range is not
  a valid single-byte opcode — yet it was accepted and executed as, e.g., `table.grow`. The pre-existing
  guard rejected by *immediate kind*, which structurally could only catch tags whose kind is unreachable
  from a genuine single-byte op; it could never catch `0xe3–0xe5` (`.table`) or `0xed`/`0xf0–0xf2`
  (`.none`), whose kinds are legitimately reachable. Replaced with the property that actually holds — a
  **byte-range check** (`0xd0–0xd6` are real ops; `0xfb–0xfd` are prefixes consumed earlier; both sit
  outside the range). +1 test covering the previously-uncatchable tags, the range endpoints, and that the
  real ops just below the boundary still decode. *Lesson: the earlier fix guarded a proxy for the property
  (kind) instead of the property itself (encoding), so it was silently partial.*
- **Duplicated align helpers consolidated.** `wat.zig naturalAlign` and `validate.zig naturalAlignLog2`
  were byte-identical, and the `wat.zig` name was **wrong** — it returns a log2 exponent, not a byte count.
  Now one `opcode.naturalAlignLog2` (both files already import `opcode`), which is also the right home:
  the assembler defaults a missing `align=` from it and the validator rejects `align=` above it.
- **`@intCast` of a byte offset → saturating.** `Module.body_offset` and `opcode`'s per-instruction offset
  list are `u32` fed from `usize`; a >4 GiB module made both casts out-of-range — illegal behaviour in
  ReleaseFast. Unreachable via the CLI (64 MB read cap) but the **C ABI takes arbitrary embedder bytes**.
  Now `std.math.cast(...) orelse maxInt(u32)`: these offsets only label trap backtraces, so clamping is
  cosmetic where the cast was UB.
- **`tools/conformance.zig` no longer abandons a run on one bad directory.** `try walker.next(io)`
  propagated, discarding every result gathered so far; per-*file* errors were already handled. Now counted
  like a bad file, and the walk stops keeping what it has.
- **The two fuzz targets are split.** They shared one `std.testing.fuzz` call and therefore one coverage
  corpus — an input interesting to the binary decoder is noise to the text assembler, so roughly half the
  guided budget was spent on inputs that could not improve the target being fed. Now `fuzzBinary` and
  `fuzzText`, two corpora.

**Verification:** `test`/`test-safe` **411 printed (407 pass, 4 skip) = 211 distinct** (200 core + 11
C-ABI) — +2 this batch: the internal-tag rejection test and the split-out text fuzz target. `c-smoke`
319/319, `wasi-gate` + freestanding `wasm` green, and the conformance baseline flow re-checked end to end.

### Validator correctness batch (items 1–3) — DONE 2026-07-21

All three were **`validate.zig` not meaning what an embedder would assume it means**. None is a
memory-safety issue — the interpreter self-defends on the run path — but `wasm_module_validate` is the
gate a C-ABI embedder calls, so "the validator accepts it" has to be worth something.

- **`br_on_non_null` was reject-VALID.** It hard-coded the label's last type to `funcref`/`externref`,
  so every valid GC/typed-ref label (`i31ref`, `anyref`, `eqref`, `structref`, `arrayref`, a concrete
  `(ref $t)`) was rejected. Spec is
  `br_on_non_null l : [t* (ref null ht)] → [t*]` where `C.labels[l] = [t* (ref ht)]` — the last type must
  be a **reference**, any reference. Now `isRef()` plus a `subtypeOf` check that the operand is the
  nullable form of what the label expects (`.unknown` in unreachable code matches anything). Verified:
  `funcref` still OK, `i31ref`/`anyref` now OK, a non-reference label still `TypeMismatch`.
- **SIMD memory ops and `memory.size`/`memory.grow` had NO memory check.** The `.simd` arm never looked at
  memories at all, and `memory.size`/`grow` fell through to `simpleSig` — so both validated in a module
  with **no linear memory**. Added `requireMemory(index)`, which also fixes the multi-memory half the
  scalar path was missing: it only tested `memories.len == 0`, so `(i32.load (memory 7))` in a one-memory
  module passed. Which `0xFD` sub-opcodes touch memory now lives in `opcode.simdIsMemoryOp`, deliberately
  beside `decodeSimd` (whose switch is the authority) so the two cannot drift — the `Simd` immediate
  always carries a defaulted `mem` field, so its presence could not have distinguished them.
- **`ValType.concreteRef` silently truncated the type index to 28 bits.** Worse than "wrong output" as
  originally logged: an index just above the mask truncates to a small **valid** one, which is type
  confusion rather than a wrong number. The binary decoder was already safe (`readHeapTypeRef` bounds `ti`
  by the declared type count first); the **text** path had no bound, so `(ref 4294967295)` became
  `(ref 0x0fffffff)`. Added `ValType.max_concrete_index` and a check at the assembler boundary →
  `BadImmediate`.

**Verification:** `test`/`test-safe` **415 printed (411 pass, 4 skip) = 213 distinct** (202 core + 11
C-ABI) — +2 tests, each with both the newly-accepted and still-rejected cases so the fixes can't drift
into over-acceptance. `c-smoke` 319/319, `wasi-gate` (real compiled guests) + freestanding `wasm` green.

### Hardening batch (items 4–6) — DONE 2026-07-21 — the remaining list is now CLOSED

- **`wasi.zig` u32-before-widening offsets — the last three sites.** `gatherIovecs`, `fd_read`'s stdin
  path and `poll_oneoff` (×3) all computed `base + i * stride` in **u32**, which wraps — and a wrapped
  (small) offset then *passes* the bounds check it should have failed. Now one
  `Wasi.arrayOffset(base, i, stride)` doing the arithmetic in u64. It deliberately requires the **whole
  element** to fit, so callers can still form `iov + 4` for the length field in u32 without wrapping.
  This closes the class the 6th pass opened (`fd_write`/`seek`) and the 10th continued
  (`writeStringVec`) — the whole file is now widen-then-check.
- **C-ABI trap frames now OWN their instance.** A `wasm_trap_t` outlives the call that produced it and
  `wasm_frame_instance` hands the stored pointer back, but the frames only *borrowed* it — so
  `wasm_instance_delete` right after catching a trap (an ordinary embedder sequence) left every frame
  dangling. This was the one site departing from the file's "a stored `*Instance` owns a handle" rule.
  One `retain` covers the whole frame array (all frames name the same instance); `wasm_trap_delete`
  releases it.
  *Test-quality note worth keeping:* the first version of the regression test compared
  `wasm_frame_instance(origin)` to the original pointer — which **passes against freed memory**, because
  it never dereferences. Made non-vacuous by calling `wasm_instance_exports` *through* the frame's
  instance; verified by removing the retain and watching it crash (exit 3). **A lifetime test that only
  compares pointer values tests nothing.**
- **`Wasi.init` no longer swallows OOM** registering fds 0–2. It returned a `Wasi` that reported success
  while having **no stdio at all**, so every `fd_write(1)` would be `EBADF` — a host allocation failure
  disguised as a guest bug. Now `error{OutOfMemory}!Wasi`; three callers gained a `try`.

**Verification:** `test`/`test-safe` **416 printed (412 pass, 4 skip) = 214 distinct** (202 core + 11
C-ABI + the new trap-lifetime test). `c-smoke` 319/319, `wasi-gate` + freestanding `wasm` green.

**The remaining-issues list from the 10th pass is now closed** except two items that cannot be closed
here: **#8** (upstream Zig `Io` bug — only an upstream fix helps; it is also what holds #17's
final-component `path_open` TOCTOU open) and `Module.zig skipConstExpr`'s GC-immediate gap, which stays
latent until GC const-exprs are implemented.

### 11th pass — 2026-07-21 — NEW LENSES, and the first wrong-ANSWER bug

The memory-safety lens was exhausted (the 10th pass's list had just been closed), so this pass used four
lenses the prior eleven had never applied: stale comments, dead code, fall-throughs/swallowed errors, and
**silently-wrong execution**. That last one is the point: *every* prior pass hunted crashes; none had ever
asked whether the interpreter returns the **right value**.

**THE FIND — `interp.zig simdFloatBin`: `fNxM.min`/`max` returned the wrong number. HIGH.**
They used Zig's `@min`/`@max`, which are **minNum/maxNum** ("if one operand is NaN, return the other") and
leave the ±0 case unordered. wasm requires the lane-wise application of the same NaN-propagating
`fmin`/`fmax` the **scalar** ops use. Measured before → after:
`f32x4.min(nan,1.0)` **1.0 → NaN**; `f32x4.max(nan,1.0)` **1.0 → NaN**; `f32x4.min(+0,−0)` **+0 → −0**;
`f32x4.max(−0,+0)` **−0 → +0**. The scalar path was correct throughout, so **identical source compiled
with and without autovectorisation produced different results**. Fixed with a per-lane escape hatch
through the existing `fmin`/`fmax` (the shape `simdFloatUn(.nearest)` already used). `pmin`/`pmax` keep
`@select` — asymmetric NaN handling *is* their spec.
**Why eleven passes missed it: no `simd_*.wast` has ever been run** (see this file's snapshot list — i32,
func, f32/f64, … but no SIMD), **and every SIMD unit test used finite operands — exactly the region where
`@min` and `fmin` agree.** A test suite can be large and still have a shaped hole.

**A regression I introduced, caught by this pass.** The lazy-pages change moved guest linear memory to the
page allocator, but `wasm_memory_new`/`wasm_memory_grow`/`destroyRef` still used `alloc` (smp_allocator) —
and `memObj()` returns **instance** memories, so `wasm_memory_grow` did a **cross-allocator realloc** on
interp-owned pages. Fixed by exporting `allocGuestMemory`/`growGuestMemory`/`freeGuestMemory` and using
them for every `Memory.bytes`. *Lesson: changing who owns an allocation must sweep every other file that
frees or grows it — the C ABI was not in scope when the allocator changed, and nothing linked the two.*

**`interp.zig initWithImports` — `errdefer memories[imported_memories..built]` with `built = 0`** formed
`memories[1..0]` (start > end) when the *import* branch failed. A one-line `.wat` with an unbacked memory
import panicked in Debug, unchecked in ReleaseFast. `built` now starts at `imported_memories`.

**C-ABI `valToSlot`/`slotToVal`/`slotToValKind` — null inverted BOTH ways.** `ref.null` is the sentinel
`maxInt(u64)`, not 0, so punning the slot to a pointer meant a guest `ref.null` arrived **non-NULL** (the
embedder's null check failed) and a host **NULL became slot 0 = funcref #0** (so `ref.is_null` answered
false and `call_ref` would call function 0 instead of trapping). The *table* path always did this
correctly (`refFromTableValue`); only the `wasm_val_t` path punned. **Residual, deliberately asserted in
the test rather than hidden:** a non-null funcref slot is a function *index* punned as a pointer, so
**index 0 still collides with NULL**. Fixing that means routing `wasm_val_t` refs through the same
`wasm_ref_t` object model — an ownership decision, not a local patch.

**Comments that actively mislead (category 1) — a rich seam.** `interp.zig`'s header claimed imported
functions "still trap — host-function calls are the next execution slice" (false since WASI shipped);
`types.zig` listed SIMD and EH as remaining decode gaps; `wat.zig` listed `start`/imports/`table.init` as
"Deferred"; and **`Module.supertypes` was documented "unused by the current slice" while `isSubtype`'s
chain walk depends on it** — dead-code bait discovered *while a dead-code audit was running against the
same file*. Also re-homed three doc comments the earlier `naturalAlign` consolidation stranded on the
wrong functions (`valTypesEqual`, `imm0`, `simdNaturalAlign`) — the sibling pattern again, one per file.

**Verification:** `test`/`test-safe` **419 printed (415 pass, 4 skip) = 216 distinct**; `c-smoke` 319/319,
`wasi-gate` + freestanding `wasm` green.

**Process note (cost real time):** an auditor's cleanup ran `git checkout` on the working tree mid-pass and
**reverted uncommitted fixes**. Nothing committed was lost. **When fanning out agents that may build or
test, commit before and between batches** — do not leave verified work uncommitted while agents run.

**BACKLOG — reported by this pass, NOT yet verified or fixed.** The fall-through and dead-code sweeps
returned ~40 further findings. One that was checked **did not reproduce** (a claimed unclosed-block
infinite loop: the repro exited cleanly, `validation: FAILED — ControlUnderflow`), which is why the rest
are recorded as *claims* pending individual verification rather than as defects. Highest-value to check
first: `wast.zig assertRejected` counting **any** error as a pass for `assert_invalid`/`assert_malformed`
(if true it inflates the conformance numbers recorded in `testing.md`); a missing imported **global**
silently reading 0 while memories/tables correctly `MissingImport`; several `wat.zig` silent drops
(unknown module field, unknown `(type (func …))` part, unrecognised memarg atom, `(export … (memory $x))`
always index 0, multi-memory collapsing onto memory 0) — the assembler emitting **wrong bytes** is the
canonical failure the protocol names; `readHeapTypeRef` decoding an undefined heap type as `externref`;
an undefined `0xFD` sub-opcode decoding *and validating*; `i8x16.shuffle` lane indices ≥ 32 accepted;
`refMatches` folding `exn`/`nofunc`/`noextern` into the wrong hierarchy (`ref.test (ref nofunc)` on a
funcref answering 1 where the spec says 0); WASI `clock_time_get` treating every clockid as monotonic;
`errnoFor` mapping `NotLink` to EIO instead of EINVAL; and the CLI exiting **0** on every failure path
including a verify-gate refusal.

## #23 — Zig 0.16 Windows `Io` filesystem gaps found in WASI 4.3 (2026-07-16)

Two more std holes on Windows, same family as #18 (which is the first). Both hit during 4.3; recheck all
three on every Zig upgrade.

**(a) `Io.Dir.setTimestamps` is `@panic("TODO implement dirSetTimestamps windows")`** (`Threaded.zig:8989`)
— the path form. A `path_filestat_set_times` call would **crash the host**. **WORKED AROUND:**
`wPathFilestatSetTimes` opens the file and uses the **fd-based** `File.setTimestamps`, which *is*
implemented on Windows (`NtSetInformationFile(FileBasicInformation)`). Opening with follow is safe — we
refuse a symlink final first — and dodges #18's openFile-nofollow crash too. When std implements the
path form, this can go back to a direct `Dir.setTimestamps`. Verified working via
`examples/wasi_leftovers.zig`.

**(b) `Io.Dir.hardLink` is `return error.OperationUnsupported`** on Windows (`Threaded.zig:9509`) — std
simply doesn't do hard links there. So **`path_link` returns ENOTSUP on Windows**; it works on POSIX
(std implements it). **DEFERRED, not worked around:** unlike (a) there is *no* existing `Io` function
that creates a hard link on Windows, so the fix is raw `NtSetInformationFile(FileLinkInformationEx)` with
WTF-16 + NT-path handling — a bigger, error-prone Windows-specific lift, out of proportion to path_link's
demand right now. The wazmrt logic (resolve both ends through the walk, refuse a symlink source) *is*
exercised — it reaches `hardLink` and returns its errno — so only the std backend is missing.
`examples/wasi_leftovers.zig` treats ENOTSUP as a skip. **If a real guest needs Windows hard links,**
implement the NT call in `wPathLink`.

**Anchor:** `wPathFilestatSetTimes` (workaround) and `wPathLink` (deferred), `src/wasi.zig`.

## #22 — C ABI lifecycle fuzz — **DONE 2026-07-16.** Found 2 more real bugs.

Built the randomized lifecycle fuzz the owner scheduled as the first item for 2026-07-16. The process —
studying the object model to build a faithful generator, then running it — turned up **two more real
memory-safety bugs**, both now fixed:

- **Module use-after-free (found by studying the model, before a line of fuzzer ran).**
  `interp.Instance` stores `&m.inner` and dereferences it on every call, but the wasm-c-api contract
  lets the embedder delete the module right after `wasm_instance_new`. So delete-module-then-call was a
  **segfault**. Fix: the C-ABI `Instance` now holds a handle on its `Module` (`retain` on new, release
  on delete) — invariant 5 in `design-decisions.md`. This is the #21-bug-2 pattern (a stored pointer
  with no owned handle) for a second object; worth remembering the *class*, not just the instance.
- **`wasm_trap_delete` ignored the refcount (found by the fuzzer, on seed 1).** #20 added
  `wasm_trap_copy` (which `retain`s) but the pre-existing `wasm_trap_delete` freed unconditionally, so
  `trap_copy` then `delete` was a **double free**. The seeded sweep caught it immediately: a trap gets
  copied (rc=2), one delete frees it while a handle remains, and a later `new` reuses the address. Fix:
  `wasm_trap_delete` calls `release` first — invariant 6, and all eight deleters were audited.

**The fuzz itself** (`fuzzStep` + `runFuzzSequence` + two tests in `src/wasm_c_api.zig`):
- A live-handle **pool** of *owned* handles only; a weighted op generator does
  new/copy/delete/host_info/cast/table-get/vec-transfer. **Ownership is respected, not papered over:**
  borrowed views (`as_ref`, `X_as_extern`) are used transiently and never deleted (deleting one is a
  contract violation, not a bug to report); handing objects to an extern vec removes them from the pool
  because the vec now owns them.
- **One driver, two decision sources** via a tiny `decider` interface: `RandDecider` (a seeded
  `std.Random`) runs **400 seeds × 250 ops in `zig build test`** — deterministic, a failure prints its
  seed; `SmithDecider` (`std.testing.Smith`) runs the *same* ops **coverage-guided under
  `zig build test --fuzz`**. Single-sourced so the fuzzer and the CI sweep can never diverge.
- **The allocator is the oracle** (the comptime `alloc` is `std.testing.allocator` under test): it
  asserts almost no expected values, only correct *lifetimes* — any leak / double-free / UAF fails.
- **Verified it actually fails** (a gate nobody has seen fail is decoration): reintroducing the trap
  bug, the module UAF, and #21-bug-4 each made the fuzz go red.

**Original problem statement, kept for the reasoning:**

**What:** #21 made C ABI memory safety *testable* — `wasm_c_api.zig`'s tests run the C entry points
under `std.testing.allocator`, which fails on double-free and leaks. But every one of those tests is a
sequence **a human chose**. Each encodes a bug that already shipped. Nothing explores the orderings
nobody imagined, which is precisely where the next double-free lives: the four #21 bugs were all
"obvious" *after* a test happened to hit them, and three of them shipped anyway.

**Why it's the priority:** the guard is only as good as its coverage, and the C ABI is the one place a
mistake is a *heap-corruption primitive* rather than a wrong answer (`design-decisions.md`). Hand-written
lifecycle tests are a floor, not a ceiling. This is cheap insurance on the surface that just grew from
~140 to 319 functions in one day (#20) — i.e. the coverage gap widened sharply and hasn't been probed.

**Shape:** a randomized/fuzz driver over object-lifecycle operation sequences —
`new` / `copy` / `same` / `as_ref` / `ref_as_*` / `set_host_info` / `delete` / vec `new`/`copy`/`delete`
across module, instance, func, global, memory, table, trap, foreign — run under `std.testing.allocator`
so any double-free, leak, or use-after-free fails the run. Prefer a **deterministic seeded PRNG** with
the seed printed, so a failure is reproducible from the log; consider `std.testing.fuzz` for
coverage-guided input. The oracle is the allocator, not an expected value — no need to model correct
results, only correct *lifetimes*. Worth asserting refcount invariants directly too (`rc == 1` after
`copy`+`delete`; `same(copy(x), x)`; a downcast of the wrong type is null).

**Watch for:** operations that are legitimately *not* safe to fuzz blindly — deleting a borrowed
`wasm_extern_as_func` handle is a contract violation, not a bug, so the generator must respect
`own`/borrowed. Encode that distinction rather than papering over the crashes it produces.

**Surfaces when:** it already has — we just can't see it. Absence of a failing test here is currently
absence of evidence.

**Anchor:** the test block at the bottom of `src/wasm_c_api.zig`; `cabi_tests` in `build.zig`.

## #21 — C ABI memory safety: 4 exploitable bugs, found and fixed — **DONE 2026-07-15**

Raised by the owner immediately after #20 landed: *"We do not want to create memory unsafe issues…
memory safety is a massive project goal"* / *"We do not ever want to introduce exploitable holes."*
The audit that followed found **four real bugs**, three of them shipped in #20 hours earlier. All are
fixed, and — more importantly — the reason none were caught is fixed.

**The bugs** (all in `src/wasm_c_api.zig`):
1. **Double free.** `wasm_extern_vec_copy` aliased element pointers while `wasm_extern_vec_delete`
   destroyed them outright, so `copy(&b,&a); delete(&a); delete(&b);` — a sequence the header invites —
   freed each `Ref` twice. Heap-corruption primitive. Fixed: copies take a real handle (retain, or
   duplicate for export handles, which are cheap views); vec_delete routes through `refDelete`.
2. **Use-after-free, no misuse required.** A `Ref` stores `*Instance` and dereferences it on every call,
   but never owned it: `exports(); instance_delete(); func_call();` read freed memory. Fixed: a `Ref`
   that names an instance retains it (`refRetainInstance`), released in `destroyRef`.
3. **Uninitialized refcount.** `wasm_instance_new` / `wasm_trap_new` assigned fields one at a time onto
   `alloc.create` memory, so `hdr.rc` was garbage — freeable at any moment, or never. Only a
   whole-struct literal picks up defaults. Fixed, plus a test asserting `rc == 1` for every ref-able
   constructor, which catches the whole class.
4. **Leak + unrun finalizer.** `wasm_extern_vec_delete` destroyed standalone `Ref`s directly, skipping
   their functype/host_global/finalizer. Fixed by the same routing as (1).
Also hardened `release` to drive `rc` to 0 rather than leave it at 1, so a double delete can't run a
host-info finalizer twice.

**Why nothing caught them — the actual finding.** `root.zig` doesn't import `wasm_c_api.zig` (the
dependency runs the other way), so **`zig build test` could not reach the C ABI at all**: it had zero
Zig tests and no way to have any. And `tests/c_smoke.c` runs on the real allocator, where a double free
silently corrupts the freelist and the test **still prints OK** — it did exactly that when run against
the bug. A C repro of the double free printed `deleted b -- no crash?` and exited 0.

**The fix for the class:** `alloc` in `wasm_c_api.zig` is now
`if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator` (comptime — release builds
unaffected), and `build.zig` has a `cabi_tests` target on the `test` step. The C entry points now run
under an allocator that **fails the build** on double-free or leak. That is what turned all four bugs
from invisible into a red test in one run. **Anything that hands ownership across the boundary needs a
test there** — see the invariants in `design-decisions.md`.

**Surfaces when:** never again, ideally — but the guard is only as good as its coverage. New C ABI
surface without a lifecycle test in `wasm_c_api.zig` is unguarded.

## #20 — `wasm.h` declared 180 functions we didn't define — **DONE 2026-07-15**

**Was:** `third_party/wasm-c-api/include/wasm.h` is the standard header, installed verbatim next to our
library, and **180 of the functions it declares had no definition**. An embedder calling one got an
undefined-symbol link error (static lib) or a failed `dlsym`/`Deno.dlopen` (the DLL path — our actual
integration story, `vision.md`). Not "a missing feature": we advertised an API we didn't have.

**Now: 0 undefined — every function `wasm.h` declares is defined**, and
**`tests/c_abi_symbols.c` keeps it that way**. It takes the address of all 319 declared functions and
links into `zig build c-smoke`, so dropping one fails *our* build. Verified the gate actually fails by
un-exporting `wasm_table_grow` and watching c-smoke die on `undefined symbol: wasm_table_grow` — a gate
that can't fail is decoration. **Regenerate it after vendoring a new `wasm.h`** (command below); the
list must come from the *preprocessed* header, since `WASM_DECLARE_OWN/_VEC/_TYPE` generate most of the
API and a source grep misses them — which is exactly how this hid for months.

**What landed, and the one decision worth knowing:**
- **The ref object model.** `RefHeader` (tag + refcount + host_info) embeds in the 9 ref-able types;
  upcasts hand out `&obj.hdr`, downcasts recover it with `@fieldParentPtr` — no layout assumption,
  no allocation (the upcast is borrowed, so it *cannot* allocate). **`wasm_X_copy` refcounts rather
  than clones**, because `wasm_X_same(copy(x), x)` must be true: these are references. That also makes
  copy meaningful for an `Instance`/`Module`, which can't be deep-copied sensibly.
- **Type objects are the opposite** — values, so their `copy` really clones, and a vec copy must clone
  each element or two vecs free the same pointers.
- **`wasm_table_get`/`set`/`grow`** — deferred for months on "needs `wasm_ref_t`"; that blocker is gone,
  so they're implemented.
- **`wasm_module_serialize`** returns the original binary and `deserialize` re-decodes it. wazmrt
  interprets a decoded IR — there is no AOT artifact to emit, and a round-trip through the original
  bytes is honest and correct. **Cost: `wasm_module_new` now keeps a copy of the binary** (the decoder
  otherwise lets the input go). Paid only on the C ABI path, not the CLI.
- **`wasm_tagtype_t`** exists as a C-ABI type object; exception handling itself runs in the interpreter
  (both encodings), but throwing/catching stays inside a module — the C boundary only sees the tag type.
- ~86 ref functions and ~40 vec functions are **comptime-generated** from a table. That's the point:
  in that much near-identical bulk, a copy-paste slip (a `global` body under a `memory` name) compiles
  fine and stays invisible until an embedder hits it.

**Regenerate the gate after vendoring a new `wasm.h`:**
```sh
zig build                                   # produces zig-out/{lib,include}
printf '#include "wasm.h"\n' > pp.c
zig cc -target x86_64-windows-gnu -E pp.c -I zig-out/include -o pp.i   # expand the macros
grep -oE "\bwasm_[a-z0-9_]+[ ]*\(" pp.i | tr -d ' (' | sort -u > declared.txt
# then rebuild tests/c_abi_symbols.c from declared.txt (see its header comment)
```

**Left deliberately:** nothing in the header. `wasm_table_get` returns funcrefs only (an externref
table slot has no `wasm_ref_t` to hand back yet — it would need boxing at the host boundary); it
reports null rather than inventing a handle. Semantics, not a link break.

---

### Original report (kept for the "surfaces when" reasoning)

**Found how (reproducible — re-run this after any C ABI change):**
```sh
zig build                                   # produces zig-out/{lib,include}
printf '#include "wasm.h"\n' > pp.c
zig cc -target x86_64-windows-gnu -E pp.c -I zig-out/include -o pp.i   # expand the macros
grep -oE "\bwasm_[a-z0-9_]+[ ]*\(" pp.i | tr -d ' (' | sort -u > declared.txt
{ echo '#include "wasm.h"'; echo 'void *refs[] = {';
  while read n; do echo "  (void*)&$n,"; done < declared.txt;
  echo '}; int main(void){ return refs[0]==0; }'; } > audit.c
zig cc -target x86_64-windows-gnu audit.c -I zig-out/include -L zig-out/lib -lwazmrt -o audit.exe 2>&1 \
  | grep -oE "undefined symbol: [a-z_]+" | sort -u
```
Macro-generated declarations (`WASM_DECLARE_OWN`/`_VEC`/`_TYPE`) are why the header must be
**preprocessed** — grepping the raw header misses most of them, which is how this stayed invisible.

**Was 180; now 167** — Phase 4.1 defined the 13-symbol frame/trap-trace family (#19). The rest fall in
systematic families, mostly mechanical:
- `wasm_*_copy` / `wasm_*_same` / `wasm_*_get_host_info` / `wasm_*_set_host_info[_with_finalizer]` —
  the boilerplate every object type declares (~110 of the 167).
- `wasm_ref_as_*` / `wasm_*_as_ref` casts + `wasm_ref_delete`/`copy`/`same` — needs a real `wasm_ref_t`
  (already noted as deferred: it's what blocks `wasm_table_get`/`set`/`grow`, also on this list).
- `wasm_foreign_*`, `wasm_tagtype_*`, `wasm_module_serialize`/`deserialize`/`share`/`obtain`,
  `wasm_*type_new` constructors, `wasm_*_vec_copy`.

**Severity:** latent but real, and it fails at *link/load* time — the embedder can't work around it.
The reason it hasn't bitten: our own C client (`tests/c_smoke.c`) and `examples/deno_ffi.mjs` only use
what we implement, so nothing ever asked for the rest.

**Surfaces when:** any embedder written against the standard header rather than against our subset —
`universalWasmLoader-*`, wasmtk-via-FFI, or anyone porting wasmtime/wasmer code (`vision.md` makes all
three explicit goals). Four options were on the table: implement the mechanical families; `wasm_ref_t`
first; trim the header; or document the subset. **Resolution (owner's call, 2026-07-15): implement all
of it** — "a big hole we don't need to fall into" — done above, ahead of 4.2.

**The durable fix for the *class*:** make the audit a build step so a declared-but-undefined symbol
fails CI instead of an embedder's link. **Done** — `tests/c_abi_symbols.c`. That was the real lesson:
the gap existed since the C ABI landed and no test could see it, because every test only called what
we'd implemented.

**Anchor:** `src/wasm_c_api.zig` (all `export fn`s); `third_party/wasm-c-api/include/wasm.h`;
`tests/c_abi_symbols.c` (the gate).

## #19 — Traps carry no location: `trap: Unreachable` and nothing else — **DONE 2026-07-15 (Phase 4.1)**

**Was:** every trap surfaced as a bare `trap: <ErrorName>` — no function, no name, no pc. That gap is
what turned the Phase 3 `bitcast_invalid` diagnosis into hours.

**Now:** traps report a named backtrace, innermost frame first. The exact binary from that hunt:

```
trap: Unreachable
  at fn[31] <.Lfd_write|wasi_snapshot_preview1_bitcast_invalid> +0
  by fn[30] <min.main> +22
  by fn[33] <start.startWasi> +2151
```

**How:** `Frame` carries `func_index`; `Frame.run` has `errdefer self.inst.recordTrap(func_index, pc)`
— **`errdefer` emits code on the error path only**, so the dispatch loop is untouched and the trace
builds itself innermost-first as the error unwinds, with no plumbing through call sites. Frames land in
a **fixed `[16]TrapFrame` on `Instance`**: recording a trap must not allocate (we may be unwinding an
OOM) and must not fail. `trap_depth` keeps the true depth, so a truncated backtrace says so. Reset per
`invokeIndex`, so it always describes the latest failed call. Read via `trapFrames()`/`trapTruncated()`.
Names come from `Module.funcName` — decode keeps only the name section's function-name subsection
(§7.4.2), copied, and scans it **lazily**: a module that never traps pays one `dupe`. A malformed name
section degrades to "no names", never an error — it must not fail the report that is already reporting
a failure.

**Also through the C ABI (added 2026-07-15, same phase).** `wasm.h` *declares* `wasm_trap_origin`,
`wasm_trap_trace` and the whole `wasm_frame_*` family — we defined none of them, so an embedder
following the header got a **link error**. That was mis-recorded here first as "the trace isn't
surfaced yet," i.e. a missing nicety; it was a broken promise in a header we ship. Now implemented
(13 symbols) and covered by `tests/c_smoke.c`, which deliberately traps and walks the backtrace. Byte
offsets are real: the C test asserts `trapmod[module_offset]` is the actual `unreachable` byte, so a
plausible-looking-but-wrong offset fails the build. The broader header gap is **#20**.

**Verified:** 6 unit tests (111 total) — innermost-first ordering with exact pc; deep recursion
truncating at 16 with `trap_depth = 41`; reset between invokes; name lookup incl. gaps/past-the-end and
a truncated section; and byte offsets on a body where pc and offset *diverge* (a multi-byte LEB pushes
`unreachable` to pc 2 / byte 4), so an IR index couldn't pass by coincidence. Plus the real guest and
the C client.

**Performance — the interesting part.** The first cut regressed steady-state **14%** (262 → 224
Mops/s, reproducible). The cause was not what it looked like: nothing on the hot path changed. The
`errdefer` in `Frame.run` expands at every `try` in a ~200-arm switch, so a slightly bigger
`recordTrap` inlined into hundreds of landing pads and pushed the loop out of i-cache. `noinline` on
`recordTrap` fixed it *and* beat the baseline — **288 Mops/s, +10% over HEAD** — because 4.1 had been
inlining it too. Cold-start likewise ended up *better* (0.86 vs 0.90 us/run) once offsets went lazy.
Both are now invariants in `design-decisions.md`. **Lesson: a hot-path regression can come from an
error path.** Bisect against a same-session baseline; do not trust a recorded number from another day.

**Anchor:** `Frame.run`'s `errdefer` + `Instance.recordTrap`/`trapFrames`/`frameOffset`
(`src/interp.zig`); `Module.funcName`/`findFuncNameSubsection` + `Code.body_offset` (`src/Module.zig`);
`opcode.decodeBodyTracked`; `printTrap` (`src/main.zig`); `makeTrapFrom` + the `wasm_frame_*` exports
(`src/wasm_c_api.zig`).

## #18 — Zig 0.16 std bug: `openFile(.follow_symlinks=false)` on Windows crashes the host — WORKED AROUND, but now **security-relevant** (2026-07-15, updated 2026-07-16)

**What (std's bug, not ours):** `Io.Dir.openFile` opens the handle **ASYNCHRONOUS** when
`follow_symlinks = false` but still returns `.flags = .{ .nonblocking = false }`
(`Threaded.zig:5033` — the only conditional `.IO =` in the file). The first `readPositional` then takes
the synchronous branch and hits `.PENDING => unreachable` **inside std**, killing the *host* process,
not the guest. `createFile` is unconditionally `SYNCHRONOUS_NONALERT`, which is why only the
open-an-existing-file path crashed and `path_open` with `O_CREAT` looked healthy.

**Our workaround:** `wPathOpen` never calls `openFile(.follow_symlinks=false)`. The resolver `walkFull`
resolves the final component to a real (non-symlink) name — an unfollowed symlink final yields
`final_is_symlink`, which `wPathOpen` turns into ELOOP — and then it opens *with* follow, safe because
a non-symlink can't be followed anywhere. Same observable semantics, no async handle.

**⚠️ This is why #17 has a residual, so #18 must be fixed to fully close #17.** Because we can't open
no-follow, there is a **resolve-then-open TOCTOU window on `path_open`'s final component**: an attacker
with write access *inside* the preopen could swap the just-resolved name for a symlink before the follow
open, and we'd follow it out. Narrow (needs in-sandbox write + a race) and it does **not** affect the
per-component walk (which opens each component no-follow through a held handle — no such window) — but
it is the one path where a real `openFile(.follow_symlinks=false)` would let us open no-follow
atomically. **The correct close is upstream: fix this std bug (or a real `openat2(RESOLVE_BENEATH)` in
`Io`), then `wPathOpen` opens no-follow directly.** Until then the residual stands, documented in the
`src/wasi.zig` module doc and #17.

**Contained (crash-wise):** the other two `.IO = .ASYNCHRONOUS` sites are `dirReadLinkWindows` (an
internal reparse-point handle we never read from; `path_readlink` is `NOTSUP` here) and `openSocketAfd`
(sockets, which correctly set `nonblocking = true`). No other file path can reach the mismatch.

**Surfaces when:** **upgrading Zig** (recheck: does the workaround still hold?) *and* whenever the #17
final-component TOCTOU matters (untrusted guest with in-sandbox write). If std fixes it: in `wPathOpen`,
open the resolved final with a direct `openFile(.follow_symlinks=false)` instead of follow, which closes
#17's residual for free. Re-run `examples/wasi_files.zig` ("fd_read round-trips the contents" is the
crash check) and `examples/wasi_symlink_traversal.zig` (the containment check).

**Anchor:** the `openFile` call in `wPathOpen` (the `else`/non-create branch), `src/wasi.zig`.

## #17 — WASI sandbox symlink containment — **DONE 2026-07-16, then UPGRADED to full traversal same day**

**UPDATE 2026-07-16 (4.3, owner chose full traversal):** the no-traversal fix below was replaced by
**secure full symlink traversal** — the handle-stack resolver `walkFull` (RESOLVE_BENEATH in userspace).
In-sandbox symlinks are now **followed** (wasmtime parity, for compiled C/Rust guests) while escapes are
still impossible — **secure by construction, not by refusing to follow**:
- a stack of open dir handles, bottom = preopen; `..` pops but never below it (no handle above the
  preopen exists → up-escape impossible);
- a symlink's target is expanded through the same loop; an **absolute** target resets to the preopen
  root (not host root);
- every open is one component, no-follow, through a held handle (TOCTOU-safe); `symlink_max` → `ELOOP`.

`path_symlink`/`path_readlink` implemented (create validates: absolute targets refused at creation as
defence-in-depth). **Verified**: `examples/wasi_symlink_traversal.zig` (5/5 on Windows with real
symlinks — in-sandbox followed, escape refused, absolute-can't-reach-host, cycle→ELOOP, readlink) + two
POSIX-CI unit tests incl. an **adversarial fuzz** (random symlink topologies, canary-outside oracle,
2000 iters — assert the canary is never read). Design + full argument in `cmem/security-model.md`.
`path_symlink` is POSIX-only on the creation side (Windows needs privilege, #17/#23); *following*
host-placed symlinks works on Windows. The residual below (final-component TOCTOU, #18) is unchanged.

**Original no-traversal fix (2026-07-16 morning, SUPERSEDED the same afternoon by full traversal above —
kept only as the record of the first design; `walkTo`/`finalIsSymlink` no longer exist):**

**Was:** `wasi.resolve()` is lexical — it stops a guest *naming* a path outside its preopen, but not a
**symlink stored inside the preopen whose target is outside it**. `follow_symlinks = false` only guards
the final `openat` component, so an intermediate symlink (`dirlink/secret.txt` where `dirlink ->` an
outside dir) was followed straight out. **Proven** with a real NTFS symlink: the pre-fix build printed
`ESCAPED via intermediate dir symlink`, reading a file outside the preopen.

**Now: filesystem-level containment via a handle-based component walk** (`walkTo` + `finalIsSymlink` in
`src/wasi.zig`). Two layers:
1. lexical `resolve` (unchanged) — absolute / escaping-`..` / NT-device / NUL rejected up front;
2. **descend one component at a time**, opening each relative to the previous *handle* (TOCTOU-safe —
   the handle pins the inode; we never re-walk a path string) with `follow_symlinks = false`, and a
   post-open `stat` rejects anything that isn't a real directory. On POSIX, `openat(O_NOFOLLOW)` on a
   symlink fails outright (ELOOP); on Windows it can open the reparse point, which the post-open stat
   then catches (`kind == .sym_link`). A **final-component** symlink is refused by any op that would
   follow it (`path_open`, `path_filestat_get` with `SYMLINK_FOLLOW`).

**Policy: no symlink is ever traversed.** A guest can't create one (`path_symlink` unimplemented), so
every symlink in a preopen is host-placed — the attack — and refusing it is the safe default.
In-sandbox symlink traversal is unsupported; relax to target-revalidation only if a real guest needs it
(that's why `path_symlink`/`path_readlink` sit behind this at 4.3 — they'd change this policy).

**Residual (documented, narrow):** a TOCTOU window on the *final* component of `path_open` only — we
stat it no-follow then open with follow, because `openFile(.follow_symlinks = false)` crashes the host
on Windows (std bug #18). A swap in that window needs write access *inside* the sandbox and a race; the
intermediate walk (the actual reported hole) has no such window. Closing it fully needs #18 fixed
upstream, or a real `openat2(RESOLVE_BENEATH)` in `Io`.

**Verified:** before/after with a real symlink via `examples/wasi_symlink_traversal.zig` (pre-fix ESCAPED,
post-fix all-refused, in-sandbox file still readable); a unit test in `src/wasi.zig` that plants a real
symlink and drives the path ops (runs on POSIX CI, **skips on unprivileged Windows** — Zig std's Windows
symlink uses raw `FSCTL_SET_REPARSE_POINT`, which needs `SeCreateSymbolicLinkPrivilege`); Phase 3 file
gate still 16/16 (no over-restriction).

**Anchor:** `walkFull`/`resolveArg` + the module doc in `src/wasi.zig`;
`examples/wasi_symlink_traversal.zig`.

## RESOLVED 2026-07-09 (second pass — commit `645874c`)

Adding `assert_invalid`/`assert_malformed`/`assert_exhaustion` to the WAST runner made the
soundness gaps observable, so they were fixed together:
- **#5 DONE** — `assert_trap` now accepts only a genuine runtime trap (`isRuntimeTrap`).
- **#7 DONE** — const-expr `global.get` restricted to a prior *immutable* global.
- **#2a/#2b/#2c/#2d DONE** — untyped `select` rejects ref operands; `select_t` needs a 1-type
  annotation; load/store require a memory + alignment ≤ natural; `if`-without-`else` needs
  params == results. Also added: global-init const-expr validation, element-segment validation,
  and `call_indirect` table-exists + funcref-typed checks.
- **#6 PARTIAL** — reserved global-mutability / limits-flag bytes now rejected (`MalformedFlag`);
  the invalid *valtype* byte (non-exhaustive `ValType` `@enumFromInt`) is still accepted.
- **#1 PARTIAL** — top-level `(import … (global …))` is now assembled; func/table/memory imports
  error honestly instead of being dropped (still need real host imports).
- **#8 DONE** — `align=` over-natural is now a validation error (the assembler still doesn't reject a
  non-power-of-two `align=` literal, but no test exercises that path).

Third pass (commit `c535de0`):
- **#2e DONE** — `ref.is_null` rejects a non-reference operand.
- **#6 DONE** — the decoder validates value-type bytes (`readValType` / `ValType.isValid`) in func
  types, table element types, global content, and locals (reserved mutability/limits bytes were
  already rejected). The `select_types` / `ref.null` heaptype immediates in `opcode.zig` are still
  unvalidated, but those are instruction-level, not module structure.
- **#2f NOT A BUG** — investigated and closed: the `pop_vals`/`push_vals` chain already cross-checks
  `br_table` label *value types* (not just arity) even in polymorphic code. Verified empirically —
  different-typed labels are rejected, same-typed accepted. No change needed.

**The 2026-07-09 audit ledger is FULLY cleared (2026-07-13): every item #1–#16 is resolved.** No open
correctness/soundness/dead-code/spec-strictness items remain. The real frontiers are now new *features*,
not ledger debt: growing the wasm-c-api past introspection (instance/func/call), and **WASI preview 1**
(in scope; preview 2/3 deferred until browser-standard, mirroring wasmtk). Since cleared: WAST-runner
invoke-by-module-name (`9745ecb`, `linking.wast` 29 → 100) and the **function-references proposal**
(P1/P2/P2.5 — typed-ref value types, `call_ref`/`ref.as_non_null`/`br_on_null`, non-null refs +
local-init; ~+130 ref-file passes, `func` 171/0). Remaining frontier proposals (the main sources of the
rest of the `.wast` failures): **full GC (WasmGC — the NEXT major increment per the owner, ahead of the
C-ABI/benchmark work)** — i31/struct/array heap objects, `ref.test`/`ref.cast`; then **multi-memory**
(`start0`) and exception-handling **tags** (`imports`), pulled in as the corpus demands. A residual limitation: concrete typed refs (`(ref null $t)`)
collapse to `funcref` in the untyped-slot model, so a general funcref passed where a specific `(ref $t)`
is expected isn't caught (`local_tee` 96/1).

## Grouped by the integration that trips them

- **`register` / multi-module linking + imported functions** (host imports → WASI): #1 **DONE — all
  three stages** (2026-07-13). Stage 1 imported funcs + register; stage 2 imported tables/memories via
  shared `Memory`/`Table` objects; stage 3 link-time import type-checking + `assert_unlinkable`. #4
  (non-spectest imported global → 0) **also resolved** by stage 3. Only #10 (global index order, LOW)
  remains in this group. `imports.wast` 26 → **132**.
- **`assert_invalid` / `assert_malformed` support in the WAST runner**: #2, #6, #7, #8 — **all DONE**.
  These were *soundness / spec-strictness* gaps; the runner now executes the negative tests.
- **Start-function support**: #3 **DONE** (`07dd244`).
- **Host externref values** (embedding API passes real externrefs): #9 **DONE** (`994ee23`) — externrefs
  are boxed to non-sentinel handles.
- **Arbitrary / hand-written WAT** (beyond the testsuite's shape): #10 **DONE** (`3a50f75`, import-after-
  def rejected); #12 (const-expr section ordering) **DONE** (`e500a51`); #8 (`align=` non-power-of-two)
  **DONE** (`00bceb4`); #11 (defined-table inline `(export …)`) **DONE** (`ff3de4a`).
- **Test fidelity, always-on**: #5 (`assert_trap`) **DONE**.
- **Dead code / duplication**: #13 **DONE** (`78647f6`).

---

## The list

### #1 — Host imports / `register` — **DONE, all three stages (2026-07-13)**
- **Stage 1 (`bcf3a11`)** — imported **functions** + **`register`**: `Instance.HostFunc`
  (`wasm{instance,func_index}` | `native fn`) dispatched from `callFunction`; the WAST runner keeps a
  module registry; the assembler emits the import section for top-level/inline func imports.
  `func_ptrs` 29/2 → 32/0.
- **Stage 2 (`78c6b2b`)** — imported **tables & memories** as shared objects. Linear memory and tables
  became `*Memory{bytes,max}` / `*Table{entries,max}`: a defined one is owned/freed by its instance, an
  imported one (low indices) borrows a host-supplied object and is left alone at deinit. `memory.grow` /
  `table.grow` mutate the shared object in place so importers observe the new size. The runner backs
  `spectest.memory` (1 page, max 2) and `spectest.table` (10 funcref, max 20); the assembler emits
  `(import … (table|memory …))` (kinds 0x01/0x02) with imports taking the low indices. `data` 31 → 34/0,
  `elem` 47 → 52.
- **Stage 3 (`1d6d9f2`)** — link-time **import type-checking** + `assert_unlinkable`: funcs by exact
  signature, globals by content+mutability, tables/memories by element type + limits subtyping
  (`limitsFit`). Unknown name → `UnresolvedImport`; type mismatch → `IncompatibleImportType`;
  `assert_unlinkable` passes iff building fails with such a link error. `imports.wast` 44 → **132/32/7**.
**Remaining imports/linking failures are separate feature gaps** — invoke-by-module-name (the runner's
`invoke` only targets the current module), inline `(table (export …) …)` (#11), tag imports, memory64 —
and `(start …)` (#3, still dropped). `linking.wast`/`memory.wast` complete only under ReleaseFast (debug
is too slow on their large grow tests), 19/84 and 66/13.

### #2 — Validator over-acceptance (soundness) — **RESOLVED (2a–2e `645874c` 2026-07-09; 2f `bfe663e` 2026-07-19)**
`src/validate.zig` — several rules accepted invalid modules (never a wrong-output risk — execution traps
safely). **All closed** (verified in code 2026-07-19): 2a untyped `select` rejects ref operands
(`:537`); 2b `select_t` checks its annotation; 2c load/store require a memory section (`:606/612/840`,
`MissingMemory`); 2d `if` params/results; 2e `ref.is_null` rejects non-refs; **2f `br_table` now compares
label value types (not just arity)** — `subtypeOf` both ways, safe in stack-polymorphic code. Original
sub-item detail kept below for history.
- **2a** untyped `select` (0x1b) accepts reference-typed operands (spec: numeric/vector only). `step`
  `.select, .select_t` (~264).
- **2b** `select_t` (0x1c) ignores its `select_types` immediate — never checks operands against the
  annotation, and for polymorphic (`unknown`) operands pushes `t1`/`t2` instead of the annotated type.
- **2c** load/store validated without requiring a memory section (and alignment never checked). A
  module with `i32.load` but no memory **passes validation**, then traps at runtime with `NoMemory`.
  When fixing, account for *imported* memory (`module.memories.len` includes imports).
- **2d** `if` with params but no `else` doesn't enforce `params == results`.
- **2e** `ref.is_null` pops any operand, not just a reference type.
- **2f** `br_table` cross-label check is arity-only; in stack-polymorphic (post-`unreachable`) code,
  labels with equal arity but different value types aren't rejected.
**Surfaces when:** the WAST runner implements `assert_invalid` (today those commands are `skipped`, so
the gaps are invisible). **Fix:** tighten each rule; verify against the `*.wast` `assert_invalid`
blocks once the runner supports them (and re-baseline — stricter validation could reject a module that
currently builds if the check is wrong).

### #3 — Start function — **DONE (`07dd244`, 2026-07-13)**
Implemented end to end: `Module.decode` reads the start section (id 8) into `start: ?u32`; `validate`
checks the start func exists and has type `[] → []` (`UndefinedFunc` / `InvalidStartFunction`);
`interp.Instance.runStart()` runs it (no args) right after instantiation — called by the WAST runner and
CLI, so a trap during start fails instantiation; the assembler emits `(start $f|N)` as section 8. Also
added the `(memory (data "…"))` abbreviation and inline `(memory (import …))` / `(table (import …))`
imports (the memory export-skip loop had silently mis-parsed an inline import as a *defined* memory).
`start.wast` 0 → **11/0/0**, `imports` 132 → 137, `memory` 66 → 69. **Out of scope:** `start0.wast`'s
3 fails are the **multi-memory** proposal (memory-indexed loads `i32.load8_u $n` on a >1 memory space).

### #4 — Non-`spectest` imported global silently defaults to 0 — **RESOLVED (`1d6d9f2`, #1 stage 3)**
`resolveGlobalImport` now resolves a global import to a registered module's exported global (its live
value from the exporting instance) or a known `spectest` global, and errors (`UnresolvedImport` /
`IncompatibleImportType`) instead of defaulting to 0. The type is checked (content + mutability) too.

### #5 — `assert_trap` fidelity — **RESOLVED (`645874c`, extended `c0c7de2`)**
`src/wast.zig` `assertTrap` now accepts only a genuine runtime trap (`isRuntimeTrap` — an
assemble/decode/`UnsupportedInstr` error no longer green-washes as a trap). The `c0c7de2` pass added the
`assert_trap (module …)` form: it builds the inner module in isolation and requires an
instantiation-time runtime trap (e.g. an out-of-bounds active data/element segment). Matching the
expected trap *text* is still not done (LOW — no test depends on it).

### #6 — Invalid value-type bytes decode silently — **RESOLVED (module `3321921`; instruction immediates `bfe663e` 2026-07-19)**
Module-structure valtypes validated (`Module.readValType`); the last piece — the `select_t` immediate,
which read each type via a raw `@enumFromInt` — now rejects an unknown byte (`opcode.zig`). `ref.null`
already used the validating `readHeapType`. Original detail below.
### #6 (original) — Invalid value-type bytes decode silently — MED/LOW
`src/Module.zig` (`readValTypes`, `readTableType`, `readGlobalType`, `decodeLocals`) and `src/opcode.zig`
(`select_types`, `ref_type`) use `@enumFromInt(byte)` into the **non-exhaustive** `types.ValType`, so a
garbage byte becomes an out-of-range enum with no `error.BadValType` (contrast `ExternKind`/`SectionId`,
which *do* guard). **Surfaces when:** `assert_malformed` support, or any untrusted/fuzzed binary input.
**Fix:** validate the byte against the known valtypes on decode.

### #7 — const-expr `global.get` more permissive than spec — **RESOLVED (`645874c`, 2026-07-09)**
Restricted to a prior *immutable* global. Original detail below.
### #7 (original) — const-expr `global.get` more permissive than spec — LOW
`src/interp.zig` — `evalConstExpr` allows `global.get` of any *prior* global; §3.3.7 restricts
const-expr `global.get` to *imported* globals. Bounds-checked, so no crash/wrong-value — a strictness
gap only. **Surfaces when:** `assert_invalid` support.

### #8 — `align=` non-power-of-two silently `@ctz`'d — **RESOLVED (`00bceb4`, 2026-07-13)**
`emitMemArg` now rejects a zero or non-power-of-two `align=` with `error.BadImmediate` before the
`@ctz` (§6.5.8), instead of encoding a bogus log2 (`align=3` → 0, `align=0` → 32). No conformance delta
(the testsuite's `align=0`/`align=7` cases arrive via `(module quote …)`, still `BadCommand`); verified
directly + new `expectInvalid` unit cases. Over-natural alignment was already a validation error.

### #9 — externref/`null_ref` sentinel collision — **RESOLVED (`994ee23`, 2026-07-13)**
The value stack is untyped `u64` with `null_ref = maxInt(u64)`; a host externref payload could equal it
and be misread as null. The WAST runner is the sole minter of externref values (`(ref.extern N)` is a
runner literal, not an instruction), so the fix is contained there: it interns each payload into a
per-run pool and represents an externref as its pool *index* (a small integer, never the sentinel).
Equal payloads intern to the same value, so an externref round-trips and compares equal. `parseConst`/
`matches` became Runner methods; funcref values still use their index directly. New wast.zig unit test
proves `(ref.extern 0xFFFFFFFFFFFFFFFF)` is non-null and round-trips.

### #10 — import-after-definition mis-indexing — **RESOLVED (`3a50f75`, 2026-07-13)**
The assembler built func/table/global name→index maps in textual order, but the binary places imports
first; a def-before-import module (malformed per §6.6.13, and the testsuite has `assert_malformed`
"import after function/global/table" for it) was silently mis-indexed. `assembleModule` now tracks
whether any func/table/memory/global definition has been seen and rejects a later import (top-level or
inline) with `error.ImportAfterDefinition` (small `fieldIsImport`/`isDefKind` classifiers). **Enforce,
not reorder** — reordering would wrongly accept the malformed cases. No conformance delta (the
testsuite's cases arrive via `(module quote …)`, still `BadCommand`); new wat.zig unit test + verified
valid imports-first resolves correctly.

### #11 — inline `(table (export …) …)` on a *defined* table — **RESOLVED (`ff3de4a`, 2026-07-13)**
`parseTable` now skips and registers leading inline `(export "x")*` forms (kind 1, current table index)
after the optional `$id`, mirroring `parseGlobal`; the imported-table case was already done (`07dd244`).
No-op for tables without an inline export, so every core file is byte-identical; modules using the form
previously failed to assemble (no passing assertion to lose) and now build: `imports` 137/31 → **137/17**
(14 fewer build failures), `linking` 19/84 → **29/108** (+10 passes), `elem` 52/15 → **52/26** (passes
stable; the new failures are newly-run assertions hitting *other* gaps — typed refs / value-literal
parsing). New wat.zig unit test.

### #12 — const-expr sections encoded after the type section — **RESOLVED (`e500a51`, 2026-07-13)**
The type section (1) was emitted before the global (6), element (9), and data (11) sections, which
encode const-exprs against the same live `sigs` list — safe only because const-exprs can't intern a
signature. Extracted `encodeGlobalSection`/`encodeElementSection`/`encodeDataSection` and call them right
after the function bodies are pre-encoded (before the type section), so any interned signature lands in
section 1 by construction. Pure reordering — output byte-identical, full regression sweep unchanged.

### #13 — Dead code / duplication — **RESOLVED (`78647f6`, 2026-07-13)**
- `validate.zig`'s `funcTypeOf` was a byte-for-byte duplicate of `Module.funcType` — deleted, the four
  callers now use `module.funcType`. Also changed `Module.funcType` to a `*const Module` receiver so it
  no longer copies the whole Module struct by value per call.
- `main.zig`'s `runFunction` re-resolved the export `invoke` resolves again — added
  `Instance.invokeIndex(func_index, args)` (invoke delegates to it) and main calls it with the index it
  already has.
- **Stale/kept:** `Imm.select_types`' payload IS read now (the validator checks the annotation, #2), so
  it is not dead; `Imm.mem_reserved`'s byte is retained deliberately (documents the reserved wire byte,
  leaves room to validate it must be 0).

## Discovered 2026-07-09 (while adding assert_invalid support)

### #14 — `func.wast` returns a wrong result (`got 0x2a` = 42) — **RESOLVED 2026-07-09 (`0409f37`)**
Root cause: a function declaring its signature via `(type $t)` (not inline `(param …)`) never added the
type's params to the assembler's local name/index space, so a declared `(local $x)` resolved to the
param's index. `(func (type $sig) (local $var i32) (local.get $var))` returned the param (42) instead
of the uninitialized local (0). Fixed in `assembleModule`: prepend anonymous local names for the
type's params (bounds-checked against `sigs`). `func.wast` 169/2 → **171/0**.

### #15 — Element init expressions + bulk table ops + data offsets — **DONE 2026-07-13**
Landed in four passes:
- **Element init expressions (`82d0213`, `4ffa2e8`)** — the const-expr element form
  (`(elem … funcref (ref.func $f) (ref.null func) …)`, incl. `(item …)`), all 8 segment flag variants,
  and const-expr offsets, across assemble/decode/validate/instantiate. `elem.wast` 3/54 → 38/28.
- **Bulk table ops (`b256a86`)** — `table.init`/`table.copy`/`elem.drop` (`0xFC` 0x0c/0x0e/0x0d) end to
  end, plus runtime passive-element storage (each segment evaluated to `[]Value` with an `elem_dropped`
  flag; active/declarative dropped after init, passive kept). `table_init` 67 → **729/0/0**, `table_copy`
  120 → **1649/0/0**. Assembler tracks element-segment names (`elem_names`) and a shared
  `emitBulkTableImm` handles the text→binary operand-order swap (`table.init tableidx? elemidx` encoded
  elem-then-table).
- **Table initializer expressions (`6087eac`)** — inline const-expr table elems
  (`(table reftype (elem (ref.func $f) …))`) and `(table N reftype initexpr)`, the latter lowered to an
  active elem of N copies at offset 0 (observably identical; the 0x40 binary form isn't needed for
  execution assertions). `table.wast` 15 → 17, `global.wast` 108 → 109.
- **Const-expr data offsets (`c0c7de2`)** — `(data $id? (memory idx)? offset? "bytes"…)`; the offset is
  any leading list (`(offset …)` / folded `(i32.const N)` / `(global.get $g)`), absent → passive.
  Offsets emit through the shared const-expr path; added active-data-offset validation (memory presence
  + i32 offset). `assert_trap (module …)` now requires a genuine instantiation-time trap. `data.wast`
  12 → **31**, `elem.wast` → **47**.
Two bugs fixed en route: (1) the generalized data assembler mis-parsed non-`i32.const` offsets as
*passive* (offset silently dropped) — any leading list is now the offset so the validator can reject
bad ones; (2) const-expr `global.get` scope — active-segment **offsets** (data + element) may reference
any immutable global, but ref-producing element exprs / table initializers stay imported-globals-only
(matches data.wast:89 valid *and* global.wast:674 `"unknown global"`). **Remaining `data`/`elem`
failures are all imported memories/tables → #1 stage 2, not #15.**

### #16 — Decoder is lenient on malformed binaries — **LEB PART DONE (`10aca3b`); rest LOW**
**Done:** the LEB128 readers (`readVarU32`/`readVarI32`/`readVarI64`) are now spec-correct — accept
valid encodings up to the max width, reject over-long AND "integer too large" (final-byte overflow/sign
bits). This also fixed a real bug rejecting *valid* 10-byte `i64.const` modules (`skipConstExpr` skipped
i64 operands with a 5-byte cap). `binary-leb128.wast` 36/25 → **56/3**. New `skipLeb(max_bytes)` for
width-aware operand skipping.
**Part 2 done (`3321921`):** custom-section names are now validated (an empty/nameless or over-long-name
custom section is rejected, §5.5.3), and the **data-count section** (id 12) is decoded and checked
against the data-segment count (`DataCountMismatch`, §5.5.16). `custom.wast` 5/3 → **8/0**;
`binary-leb128.wast` → **58/1**. **Malformed-binary over-acceptance is now ~zero** across the
negative-conformance files.
**Malformed-binary leniency: DONE.** #6's instruction-immediate valtype check (`select_t`) was the last
piece — closed `bfe663e` (2026-07-19). **Only residual is feature gaps, NOT leniency:** `binary-leb128`
(1) and `names.wast` (1) fail with `UnsupportedInstr`/`UnsupportedOpcode` — *valid* modules using an
op/instruction the assembler/decoder doesn't support yet (the opposite of over-acceptance).
