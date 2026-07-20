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
//! Instruction *execution* (`invoke` / `_start`) is intentionally NOT fuzzed
//! here: the interpreter has no instruction/fuel limit, so a fuzzed infinite
//! loop (`(loop br 0)`) would hang the fuzzer. The execution path's memory
//! safety is covered instead by the crafted `test "hardening: …"` cases in
//! `interp.zig`. `Instance.init` runs no guest instructions (the start function
//! is a separate `runStart` call), so instantiation is bounded and safe to fuzz.

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
    assembled: usize = 0,
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
    var inst = interp.Instance.init(gpa, &m) catch return;
    inst.deinit(); // before m.deinit() (defer): the instance borrows the module
    r.instantiated += 1;
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

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bins = try seedBinaries(a);

    var r: Reached = .{};
    // Use the fuzzer's bytes as the corruption, applied over a seed, so the
    // coverage-guided engine steers real modules rather than random noise.
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

    // Text side: splice the fuzzer's bytes into a seed's WAT source.
    const src = seed_wat[n % seed_wat.len];
    const text = try a.alloc(u8, src.len + n);
    @memcpy(text[0..src.len], src);
    @memcpy(text[src.len..], buf[0..n]);
    tryAssemble(std.testing.allocator, text, &r);
}

test "fuzz: malformed bytes never crash decode / instantiate / assemble" {
    try std.testing.fuzz({}, fuzzOne, .{});
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
        tryDecodeAndInstantiate(std.testing.allocator, bin, &r);

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
        tryAssemble(std.testing.allocator, text, &r);
    }

    // Coverage assertions — the point of this rewrite. Without these the targets
    // can silently degrade to exercising nothing, which is precisely what the
    // previous version did for months while appearing to fuzz three subsystems.
    // The thresholds are deliberately loose (any regression to ~0 trips them)
    // so ordinary mutation-rate drift does not cause flakes.
    try std.testing.expect(r.decoded > 100); // decoder accepted mutated modules
    try std.testing.expect(r.instantiated > 100); // …and instantiation ran
    try std.testing.expect(r.assembled > 10); // assembler ran to completion
}
