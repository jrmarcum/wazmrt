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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = std.heap.smp_allocator;

    const bin = try wazmrt.wat.assemble(a, compute_wat);
    defer a.free(bin);

    // `bench <path>` just writes the compute module's .wasm (for cross-process
    // timing against Deno/V8) and exits.
    const args = try init.minimal.args.toSlice(a);
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
