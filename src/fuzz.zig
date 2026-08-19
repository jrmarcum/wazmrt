//! Malformed-input fuzz targets.
//!
//! These feed *mutated* bytes to the untrusted-input entry points — the binary
//! decoder, the instantiation path, and the WAT text assembler — and assert they
//! only ever ERROR, never index out of bounds / overflow / crash. Under
//! `zig build test` each target runs one short `Smith` input (near-free); under
//! `zig build test --fuzz` the coverage-guided fuzzer explores the input space.
//! They run on `std.testing.allocator`, so a leak or double-free is also caught,
//! and are most valuable under a safety-checked build (`zig build test` = Debug,
//! or `zig build test-safe` = ReleaseSafe) where an OOB/overflow panics instead
//! of being silent UB.
//!
//! **Mutation, not generation.** Inputs are derived by corrupting *valid* seed
//! modules, because bytes generated from scratch never get past the front door:
//! measured on 2026-07-20, purely random bytes (even with the wasm magic
//! prefixed) produced **0 successful decodes in 20 000 inputs**, and
//! `wat.assemble` rejected every one at `error.NotAModule` before the assembler
//! ran. The old sweep therefore exercised only the first few bytes of the
//! decoder and `sexpr.parseAll` — it still found a real hang there, but
//! `Instance.init`, `checkStaticIndices`, the control-flow precompute, segment
//! initialization and the whole ~3 400-line assembler were never reached.
//!
//! The sweep now **asserts its own coverage** (see the end of the deterministic
//! sweep test), so it fails the build rather than silently degrading to
//! exercising nothing again. Measured over its 4 000 iterations: 519 inputs
//! decoded, 387 instantiated, 142 assembled — against 0/0/0 before.
//!
//! The seeds are assembled from WAT text by wazmrt's own assembler rather than
//! vendored as binaries, so the corpus needs no fixture files and stays honest
//! about what the current assembler accepts.
//!
//! ▶️ **Instruction EXECUTION is fuzzed too, since Track H5 (2026-08-19).**
//! `_start` and every exported function are invoked on the mutated module under
//! a small iteration budget.
//!
//! ⚠️ **This paragraph used to say the opposite**, and the reason it gave was
//! real: *"the interpreter has no instruction/fuel limit, so a fuzzed infinite
//! loop (`(loop br 0)`) would hang the fuzzer."* **H3 removed that reason** — a
//! runaway guest now traps `IterationLimitExceeded` — so the exclusion became a
//! workaround for a limitation that no longer existed. 🎓 *A refusal outlives
//! its cause silently; the note that explains one is the thing to re-read when
//! the cause is removed.*
//!
//! 🎯 **Why the interpreter is the most valuable target here:** it is where the
//! guest-controlled `@intCast`s, slice indices and arithmetic live, and in the
//! SHIPPED `ReleaseSmall` build every one of those safety checks is compiled
//! out. Mutated modules under a checked build reach sites no hand-written test
//! enumerates — which is why this supplements, rather than replaces, the crafted
//! `test "hardening: …"` cases in `interp.zig`.

const std = @import("std");
const Module = @import("Module.zig");
const wat = @import("wat.zig");
const interp = @import("interp.zig");

/// Valid, import-free modules covering the decoder/instantiation surface worth
/// corrupting: functions and code, memory + an active data segment, a table +
/// an element segment, globals, control flow, and multi-value returns.
///
/// Import-free matters — `Instance.init` supplies no imports, so a module with
/// any import stops at `MissingImport` before the interesting work.
const seed_wat = [_][]const u8{
    "(module)",
    "(module (func (export \"f\") (result i32) i32.const 42))",
    "(module (memory 1) (data (i32.const 0) \"hello\") (func (export \"f\") (result i32) (i32.load (i32.const 0))))",
    "(module (global $g (mut i32) (i32.const 7)) (func (export \"f\") (result i32) global.get $g))",
    "(module (table 4 funcref) (func $a (result i32) i32.const 1) (elem (i32.const 0) $a) (func (export \"f\") (result i32) call $a))",
    "(module (func (export \"f\") (param i32) (result i32) (block (result i32) (loop (result i32) (br_if 1 (local.get 0)) (i32.const 3)))))",
    "(module (func (export \"f\") (result i32 i32) (i32.const 1) (i32.const 2)))",
    "(module (memory 1) (func (export \"f\") (result i32) (memory.grow (i32.const 1))))",
    // ▶️ Track H5: two seeds that NEVER TERMINATE, one of each shape. They make
    // the sweep's dependency on the iteration budget explicit and permanent —
    // every run now invokes a guaranteed-runaway function and must come back.
    // ⚠️ Delete the budget and this file hangs instead of failing, which is the
    // loudest possible way to keep H3 and H5 tied together.
    "(module (func (export \"spin\") (loop (br 0))))",
    "(module (func $t (export \"tailspin\") (return_call $t)))",
};

/// Corrupt `buf` in place with `n` single-byte edits, never touching the 8-byte
/// wasm header — a mangled magic/version is rejected immediately and would put
/// us back to fuzzing nothing.
fn mutate(rand: std.Random, buf: []u8, n: usize) void {
    if (buf.len <= 8) return;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const i = 8 + rand.uintLessThan(usize, buf.len - 8);
        switch (rand.uintLessThan(u8, 3)) {
            0 => buf[i] = rand.int(u8), // arbitrary byte
            1 => buf[i] ^= @as(u8, 1) << rand.int(u3), // bit flip
            else => buf[i] +%= 1, // ±1 — lengths and indices just off the end
        }
    }
}

/// Outcome counters, so the targets can prove they still reach what they claim.
const Reached = struct {
    decoded: usize = 0,
    instantiated: usize = 0,
    /// Guest functions actually RUN to a result or a trap (Track H5, 2026-08-19).
    executed: usize = 0,
    assembled: usize = 0,
};

/// An allocator that refuses to exceed a live-bytes budget, and remembers that
/// it refused.
///
/// The targets `catch` `error.OutOfMemory` (a malformed input legitimately
/// producing one is not a bug), which used to make allocation-amplification
/// **invisible by construction** — the class `Reader.readVecLen`, the linear
/// memory budget and the `(table N …)` cap all exist to prevent. Running under a
/// budget turns it into an oracle instead: after every cap in the pipeline, a
/// ≤8 KB input has no business allocating tens of MB, so a refusal means a gap.
const Budget = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    limit: usize,
    exceeded: bool = false,

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (self.live + len > self.limit) {
            self.exceeded = true;
            return null;
        }
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len and self.live + (new_len - buf.len) > self.limit) {
            self.exceeded = true;
            return false;
        }
        if (!self.child.rawResize(buf, a, new_len, ra)) return false;
        self.live = self.live + new_len - buf.len;
        return true;
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len and self.live + (new_len - buf.len) > self.limit) {
            self.exceeded = true;
            return null;
        }
        const p = self.child.rawRemap(buf, a, new_len, ra) orelse return null;
        self.live = self.live + new_len - buf.len;
        return p;
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
        self.live -= buf.len;
    }
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

/// Decode bytes as a wasm binary; if they decode, instantiate with no imports.
/// Exercises the bounded front half of the pipeline: LEB/section decoding,
/// `checkStaticIndices`, control-flow precompute, active data/element-segment
/// initialization, memory/table/global allocation, and const-expr offset
/// evaluation — none of which run guest instructions.
fn tryDecodeAndInstantiate(gpa: std.mem.Allocator, input: []const u8, r: *Reached) void {
    var m = Module.decode(gpa, input) catch return; // malformed → clean error
    defer m.deinit();
    r.decoded += 1;
    if (instantiationTooBig(&m)) return;
    var inst: interp.Instance = undefined;
    inst.instantiate(gpa, &m) catch return;
    defer inst.deinit(); // before m.deinit() (defer): the instance borrows the module
    r.instantiated += 1;
    execute(gpa, &m, &inst, r);
}

/// Iteration budget for a fuzzed invocation. Small on purpose: the point is that
/// a mutated module which loops forever **returns** instead of hanging the
/// fuzzer, and any real value here is arbitrary — 10k back-edges is far more
/// than the seeds need and completes instantly.
const fuzz_max_iterations: u64 = 10_000;

/// ▶️ **EXECUTE the mutated module — added by Track H5, 2026-08-19.**
///
/// This is the half `fuzz.zig` refused to do until the iteration budget existed:
/// the module doc used to say *"instruction execution is intentionally NOT
/// fuzzed here: the interpreter has no instruction/fuel limit, so a fuzzed
/// infinite loop would hang the fuzzer."* ✅ **H3 removed that reason** — a
/// runaway now traps `IterationLimitExceeded`, so the interpreter is fuzzable.
///
/// 🎯 **Why this is worth more than the crafted `hardening:` cases it
/// supplements:** the interpreter is where the guest-controlled `@intCast`s,
/// slice indices and arithmetic live, and in the SHIPPED `ReleaseSmall` build
/// every one of those checks is compiled out. Running mutated modules under a
/// safety-checked build (`zig build test` / `test-safe`) is the mechanical way
/// to reach sites no hand-written test enumerates.
///
/// Every error is expected and ignored — a trap, a budget exhaustion, or a
/// refusal are all correct outcomes. **The only failure this can report is a
/// crash, a panic, or a leak**, which is exactly the contract of this file.
fn execute(gpa: std.mem.Allocator, m: *const Module, inst: *interp.Instance, r: *Reached) void {
    // ⚠️ Bound the run BEFORE anything executes. Without this the first mutated
    // `(loop (br 0))` hangs the sweep — the exact failure this target was
    // blocked on for a month.
    inst.max_iterations = fuzz_max_iterations;

    // A mutated module may have grown a start function; `instantiate` does not
    // run it, so this is a distinct entry point and worth its own call.
    inst.runStart() catch {};

    for (m.exports) |e| {
        if (e.type.kind() != .func) continue;
        const ft = m.funcType(e.index) orelse continue;
        var slots: u32 = 0;
        for (ft.params) |p| slots += interp.slotWidth(p);
        // Zeroed arguments: a null ref, a 0 integer and a +0.0 float are all the
        // zero bit pattern, so one buffer serves every signature.
        const args = gpa.alloc(interp.Value, slots) catch return;
        defer gpa.free(args);
        @memset(args, 0);
        const res = inst.invokeIndex(e.index, args) catch continue;
        gpa.free(res);
        r.executed += 1;
    }
}

/// True if instantiating `m` would eagerly reserve an unreasonable amount of
/// memory. Linear memory is lazily committed and budget-capped in `interp`, but
/// a mutated `(memory N)` can still name a huge minimum, and reserving gigabytes
/// of address space thousands of times would dominate the sweep's runtime.
fn instantiationTooBig(m: *const Module) bool {
    const max_pages = 64; // 4 MiB of linear memory, summed over all memories
    const max_table_elems = 1 << 16;
    var pages: u64 = 0;
    for (m.memories) |mem| pages += mem.limits.min;
    if (pages > max_pages) return true;
    var elems: u64 = 0;
    for (m.tables) |t| elems += t.limits.min;
    return elems > max_table_elems;
}

/// Assemble text as `.wat` — the s-expression parser and the assembler must
/// reject malformed text with an error, never index a parsed form out of bounds
/// or deref a wrong union.
fn tryAssemble(gpa: std.mem.Allocator, input: []const u8, r: *Reached) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    if (wat.assemble(arena.allocator(), input)) |_| {
        r.assembled += 1;
    } else |_| {}
}

/// Assemble every seed once. Returns arena-owned binaries.
fn seedBinaries(a: std.mem.Allocator) ![]const []const u8 {
    const out = try a.alloc([]const u8, seed_wat.len);
    for (seed_wat, out) |src, *dst| dst.* = try wat.assemble(a, src);
    return out;
}

test "fuzz: the seed corpus assembles, decodes and instantiates" {
    // Guards the corpus itself. If a seed stops assembling — a WAT syntax drift,
    // say — the mutation targets below would silently fall back to fuzzing
    // nothing, which is exactly the failure this file is recovering from.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bins = try seedBinaries(arena.allocator());
    var r: Reached = .{};
    for (bins) |b| tryDecodeAndInstantiate(std.testing.allocator, b, &r);
    try std.testing.expectEqual(seed_wat.len, r.decoded);
    try std.testing.expectEqual(seed_wat.len, r.instantiated);
}

// The binary and text targets are kept SEPARATE. They previously shared one
// `std.testing.fuzz` call, which means one shared coverage corpus: an input that
// is interesting to the binary decoder is noise to the text assembler and vice
// versa, so the guided fuzzer spends roughly half its budget on inputs that
// cannot improve coverage for the target it is feeding. Two targets, two
// corpora.

/// Binary target: use the fuzzer's bytes as the *corruption* applied over a
/// valid seed module, so the coverage-guided engine steers real modules rather
/// than random noise (which never decodes — see the file header).
fn fuzzBinary(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bins = try seedBinaries(a);

    var r: Reached = .{};
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const base = bins[n % bins.len];
    const copy = try a.alloc(u8, base.len);
    @memcpy(copy, base);
    for (buf[0..n], 0..) |b, i| {
        if (copy.len <= 8) break;
        copy[8 + (i % (copy.len - 8))] ^= b;
    }
    tryDecodeAndInstantiate(std.testing.allocator, copy, &r);
}

/// Text target: splice the fuzzer's bytes into a valid seed's WAT source, so a
/// top-level `(module …)` survives and the assembler is actually reached.
fn fuzzText(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r: Reached = .{};
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const src = seed_wat[n % seed_wat.len];
    const text = try a.alloc(u8, src.len + n);
    @memcpy(text[0..src.len], src);
    @memcpy(text[src.len..], buf[0..n]);
    tryAssemble(std.testing.allocator, text, &r);
}

test "fuzz: malformed bytes never crash decode / instantiate" {
    try std.testing.fuzz({}, fuzzBinary, .{});
}

test "fuzz: malformed text never crashes the assembler" {
    try std.testing.fuzz({}, fuzzText, .{});
}

test "fuzz: deterministic mutation sweep (runs every `zig build test`)" {
    // The `--fuzz` target above costs the normal run almost nothing (one input),
    // so this fixed-seed sweep is what actually exercises the targets in CI: a
    // panic (OOB / overflow / out-of-range @intCast) in a safety-checked build
    // (Debug, or `zig build test-safe`) fails here and reproduces from the seed
    // plus the reported iteration index.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bins = try seedBinaries(a);

    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rand = prng.random();
    var r: Reached = .{};

    // Every input here is ≤8 KB, and the pipeline caps allocation at each stage
    // (`readVecLen`, the linear-memory budget, `max_locals`, the table-init cap),
    // so nothing should need anywhere near 64 MB live. Exceeding it means an
    // amplification path with no cap — which the `catch`-and-ignore of
    // `OutOfMemory` would otherwise hide completely.
    var budget = Budget{ .child = std.testing.allocator, .limit = 64 << 20 };
    const ga = budget.allocator();

    var buf: [8192]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        errdefer std.debug.print("fuzz: failing iteration {d}\n", .{i});

        // --- binary side: corrupt a valid module ---
        const base = bins[rand.uintLessThan(usize, bins.len)];
        @memcpy(buf[0..base.len], base);
        const bin = buf[0..base.len];
        // Mostly 1-2 edits (which usually still decode, so instantiation and the
        // load-time index checks are reached), sometimes a burst (which usually
        // does not, exercising the decoder's rejection paths).
        mutate(rand, bin, 1 + rand.uintLessThan(usize, if (i % 4 == 0) 16 else 2));
        tryDecodeAndInstantiate(ga, bin, &r);

        // --- text side: corrupt a valid .wat ---
        const src = seed_wat[rand.uintLessThan(usize, seed_wat.len)];
        @memcpy(buf[0..src.len], src);
        var text = buf[0..src.len];
        var k: usize = 1 + rand.uintLessThan(usize, 3);
        while (k > 0) : (k -= 1) {
            const at = rand.uintLessThan(usize, text.len);
            switch (rand.uintLessThan(u8, 4)) {
                0 => text[at] = rand.int(u8),
                1 => text[at] = "()\";".*[rand.uintLessThan(usize, 4)], // delimiters
                2 => text = text[0..at], // truncate mid-form
                else => text[at] ^= @as(u8, 1) << rand.int(u3),
            }
            if (text.len == 0) break;
        }
        tryAssemble(ga, text, &r);
    }

    // Coverage assertions — the point of this rewrite. Without these the targets
    // can silently degrade to exercising nothing, which is precisely what the
    // previous version did for months while appearing to fuzz three subsystems.
    // The thresholds are deliberately loose (any regression to ~0 trips them)
    // so ordinary mutation-rate drift does not cause flakes.
    // No ≤8 KB input should have needed 64 MB live. A refusal means an
    // allocation path with no cap — the class the `catch`-and-ignore of
    // `OutOfMemory` would otherwise hide entirely.
    try std.testing.expect(!budget.exceeded);
    // And nothing may be left allocated once every arena/instance is torn down.
    try std.testing.expectEqual(@as(usize, 0), budget.live);

    try std.testing.expect(r.decoded > 100); // decoder accepted mutated modules
    try std.testing.expect(r.instantiated > 100); // …and instantiation ran
    try std.testing.expect(r.assembled > 10); // assembler ran to completion
    // ▶️ …and guest code actually RAN (Track H5). ⚠️ This assertion is the whole
    // reason the target cannot silently degrade back to fuzzing only the front
    // half: without it, an `execute` that returned early on every input — or a
    // future change that stopped calling it — would leave every other number
    // here unchanged and the suite green.
    try std.testing.expect(r.executed > 100);
}
