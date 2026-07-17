//! wazmrt interpreter microbenchmark (build in ReleaseFast — see `zig build bench`).
//!
//! Measures the two regimes the vision cares about (`cmem/vision.md`):
//!   - **cold path** — decode + instantiate + one call, the per-run cost a
//!     short-lived program pays (where wazmrt aims to beat Deno/V8's
//!     process-start + JIT-compile).
//!   - **steady state** — a hot loop inside one instance, the interpreter's raw
//!     dispatch throughput (where a JIT like V8 wins; informs Option A -> B).
//!
//! In-process only. The cross-process cold-start-vs-Deno numbers are recorded
//! in `cmem/testing.md`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const wazmrt = @import("wazmrt");

const compute_wat =
    \\(module (func (export "sum") (param $n i32) (result i32)
    \\  (local $i i32) (local $acc i32)
    \\  (block $done (loop $loop
    \\    (br_if $done (i32.gt_s (local.get $i) (local.get $n)))
    \\    (local.set $acc (i32.add (local.get $acc) (local.get $i)))
    \\    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    \\    (br $loop)))
    \\  (local.get $acc)))
;

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds; // monotonic (excludes suspend)
}

/// `bench hash <file.wasm>` — what would signature/pin verification cost at
/// cold start? (`cmem/security-model.md`: verifying a module means hashing every
/// byte on every run, and cold start is the metric `vision.md` competes on.)
///
/// Measures the three size-dependent phases against a **real** module. Note the
/// default bench module is 70 bytes — a pipeline-overhead microbenchmark, not a
/// script — so this must be run against real guests to mean anything.
fn benchHash(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| {
        std.debug.print("cannot read '{s}': {t}\n", .{ path, e });
        return;
    };
    defer a.free(bytes);

    // Enough iterations to swamp timer granularity, scaled to file size.
    const iters: usize = if (bytes.len < 4096) 100_000 else if (bytes.len < 256 << 10) 2_000 else 200;
    const fiters: f64 = @floatFromInt(iters);

    const accel = comptime builtin.cpu.hasAll(.x86, &.{ .sha, .avx2 });
    std.debug.print("\n{s} — {d} bytes, {d} iters (sha256 hw-accel: {})\n", .{ path, bytes.len, iters, accel });

    // 1. SHA-256 over the bytes we already hold (no I/O — the file is read once
    //    regardless, so verification is a pure CPU pass over memory we have).
    var sink: u8 = 0;
    var t0 = nowNs(io);
    for (0..iters) |_| {
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
        sink ^= out[0];
    }
    const hash_ns: f64 = @floatFromInt(nowNs(io) - t0);
    std.mem.doNotOptimizeAway(&sink);

    // 2. Decode — indexes sections and copies bodies out; it does NOT parse
    //    instructions (that happens at instantiate), so it is memcpy-bound.
    t0 = nowNs(io);
    for (0..iters) |_| {
        var m = wazmrt.decode(a, bytes) catch |e| {
            std.debug.print("  decode FAILED: {t}\n", .{e});
            return;
        };
        m.deinit();
    }
    const decode_ns: f64 = @floatFromInt(nowNs(io) - t0);

    // 3. Decode + instantiate — **the real script cold-start path**. `runWasi`
    //    does not validate, and instantiate is where every instruction is
    //    actually decoded (`decodeBody` + control-flow precompute), so this is
    //    the honest denominator. Imports are backed with trap-on-call stubs:
    //    instantiation cost depends on how many there are, not what they do.
    var inst_ok = true;
    t0 = nowNs(io);
    for (0..iters) |_| {
        var m = wazmrt.decode(a, bytes) catch unreachable;
        defer m.deinit();
        var nfuncs: usize = 0;
        for (m.imports) |imp| {
            if (imp.type == .func) nfuncs += 1;
        }
        const funcs = a.alloc(wazmrt.interp.Instance.HostFunc, nfuncs) catch unreachable;
        defer a.free(funcs);
        for (funcs) |*f| f.* = .{ .native_env = .{ .ctx = &stub_ctx, .call = stubCall } };
        var inst = wazmrt.Instance.initWithImports(a, &m, .{ .funcs = funcs }) catch |e| {
            std.debug.print("  instantiate FAILED: {t}\n", .{e});
            inst_ok = false;
            break;
        };
        inst.deinit();
    }
    const di_ns: f64 = @floatFromInt(nowNs(io) - t0);

    // 4. Validate — NOT on the script path (`runWasi` skips it); reported so the
    //    cost is known if we ever verify-before-run.
    var val_ok = true;
    t0 = nowNs(io);
    for (0..iters) |_| {
        var m = wazmrt.decode(a, bytes) catch unreachable;
        defer m.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        wazmrt.validate(arena.allocator(), &m) catch {
            val_ok = false;
        };
    }
    const dv_ns: f64 = @floatFromInt(nowNs(io) - t0);

    // 5. Ed25519 verify over the whole module — the actual *signature* check
    //    (the pin case is just the hash above). verify() hashes internally, so
    //    this already includes the size-dependent pass; measured end to end.
    const Ed = std.crypto.sign.Ed25519;
    const kp = Ed.KeyPair.generate(io);
    const sig = kp.sign(bytes, null) catch unreachable;
    var sig_ok = true;
    t0 = nowNs(io);
    for (0..iters) |_| {
        sig.verify(bytes, kp.public_key) catch {
            sig_ok = false;
        };
    }
    const sig_ns: f64 = @floatFromInt(nowNs(io) - t0);
    if (!sig_ok) std.debug.print("  ed25519 verify FAILED\n", .{});

    const per_hash = hash_ns / fiters;
    const total_bytes = @as(f64, @floatFromInt(bytes.len)) * fiters;
    const mbps = total_bytes / hash_ns * 1000.0; // bytes/ns -> MB/s

    std.debug.print("  sha256             {d:9.2} us   ({d:.0} MB/s)\n", .{ per_hash / 1000.0, mbps });
    std.debug.print("  ed25519 verify     {d:9.2} us   (signature check, hash included)\n", .{sig_ns / fiters / 1000.0});
    std.debug.print("  decode             {d:9.2} us\n", .{decode_ns / fiters / 1000.0});
    std.debug.print("  decode+instantiate {d:9.2} us   <- the real cold-start path\n", .{di_ns / fiters / 1000.0});
    std.debug.print("  (validate          {d:9.2} us   not on the script path{s})\n", .{
        dv_ns / fiters / 1000.0,
        if (val_ok) "" else " — VALIDATION FAILED, time is meaningless",
    });
    if (inst_ok) std.debug.print("  ==> hashing adds {d:.1}% to cold start\n", .{per_hash / (di_ns / fiters) * 100.0});
}

var stub_ctx: u8 = 0;
fn stubCall(ctx: *anyopaque, args: []const wazmrt.interp.Value, results: []wazmrt.interp.Value) bool {
    _ = ctx;
    _ = args;
    _ = results;
    return false; // never called during instantiation
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = std.heap.smp_allocator;

    const bin = try wazmrt.wat.assemble(a, compute_wat);
    defer a.free(bin);

    const args = try init.minimal.args.toSlice(a);

    // `bench hash <file.wasm>...` — the signature/pin cold-start question.
    if (args.len >= 3 and std.mem.eql(u8, args[1], "hash")) {
        for (args[2..]) |p| try benchHash(io, a, p);
        return;
    }

    // `bench <path>` just writes the compute module's .wasm (for cross-process
    // timing against Deno/V8) and exits.
    if (args.len >= 2) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = bin });
        std.debug.print("wrote {s} ({d} bytes)\n", .{ args[1], bin.len });
        return;
    }

    std.debug.print("wazmrt bench (ReleaseFast) — compute module {d} bytes\n", .{bin.len});

    // --- Steady state: one instance, call sum(N) repeatedly ---------------
    {
        var module = try wazmrt.decode(a, bin);
        defer module.deinit();
        var inst = try wazmrt.Instance.init(a, &module);
        defer inst.deinit();

        const n: i32 = 1_000_000;
        const reps: u64 = 50;
        // Each loop iteration executes ~8 instructions (compare, add, 2
        // local.set, a local.get, br_if, br) — a fair proxy for dispatch cost.
        const ops_per_iter: u64 = 8;

        a.free(try inst.invoke("sum", &.{wazmrt.interp.i32Value(n)})); // warm up

        const start = nowNs(io);
        var acc: u64 = 0;
        for (0..reps) |_| {
            const res = try inst.invoke("sum", &.{wazmrt.interp.i32Value(n)});
            acc +%= @as(u32, @bitCast(wazmrt.interp.asI32(res[0])));
            a.free(res);
        }
        const ns: u64 = @intCast(nowNs(io) - start);
        const loop_iters = @as(u64, @intCast(n)) * reps;
        const ns_per_iter = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(loop_iters));
        const mops = @as(f64, @floatFromInt(loop_iters * ops_per_iter)) / (@as(f64, @floatFromInt(ns)) / 1000.0);
        std.debug.print(
            "steady : sum(1e6) x{d} in {d:.1} ms  ->  {d:.2} ns/loop-iter  (~{d:.0} Mops/s)\n",
            .{ reps, @as(f64, @floatFromInt(ns)) / 1e6, ns_per_iter, mops },
        );
        std.mem.doNotOptimizeAway(acc);
    }

    // --- Cold path: decode + instantiate + one trivial call, per run ------
    {
        const reps: u64 = 20_000;
        const start = nowNs(io);
        for (0..reps) |_| {
            var module = try wazmrt.decode(a, bin);
            var inst = try wazmrt.Instance.init(a, &module);
            a.free(try inst.invoke("sum", &.{wazmrt.interp.i32Value(0)}));
            inst.deinit();
            module.deinit();
        }
        const ns: u64 = @intCast(nowNs(io) - start);
        const us_per_run = (@as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(reps))) / 1000.0;
        std.debug.print(
            "cold   : decode+instantiate+call x{d}  ->  {d:.2} us/run\n",
            .{ reps, us_per_run },
        );
    }
}
