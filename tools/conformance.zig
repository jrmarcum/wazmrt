//! Spec-conformance runner: walk a WebAssembly spec-testsuite checkout (a
//! directory of `.wast` files), run each through wazmrt's in-process `.wast`
//! runner, aggregate pass/fail/skip totals, and exit non-zero if any assertion
//! fails. Invoked by `zig build conformance -Dtestsuite=<dir>`.
//!
//! The corpus is intentionally not vendored (it is large and lives upstream — see
//! cmem/testing.md); clone it and point the step at it:
//!   git clone https://github.com/WebAssembly/testsuite
//!   zig build conformance -Dtestsuite=path/to/testsuite

const std = @import("std");
const Io = std.Io;
const wazmrt = @import("wazmrt");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const dir_path = if (args.len > 1) args[1] else "";
    if (dir_path.len == 0) {
        try out.print(
            \\conformance: no testsuite directory given.
            \\  Clone the WebAssembly spec testsuite and point this step at it:
            \\    git clone https://github.com/WebAssembly/testsuite
            \\    zig build conformance -Dtestsuite=path/to/testsuite
            \\
        , .{});
        return;
    }

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        try out.print("conformance: cannot open '{s}': {s}\n", .{ dir_path, @errorName(e) });
        return error.CannotOpenTestsuite;
    };
    defer dir.close(io);

    var total_pass: usize = 0;
    var total_fail: usize = 0;
    var total_skip: usize = 0;
    var files: usize = 0;
    var bad_files: usize = 0;

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.basename, ".wast")) continue;
        files += 1;

        // A fresh arena per file so memory doesn't accumulate across a testsuite
        // of thousands of scripts. `ent.path`/`.basename` are invalidated by the
        // next `walker.next`, so everything using them stays inside this iteration.
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const a = file_arena.allocator();

        const bytes = ent.dir.readFileAlloc(io, ent.basename, a, .limited(64 << 20)) catch |e| {
            try out.print("  ! {s}: read failed ({s})\n", .{ ent.path, @errorName(e) });
            bad_files += 1;
            continue;
        };
        const s = wazmrt.wast.runScript(a, bytes) catch |e| {
            try out.print("  ! {s}: runner error ({s})\n", .{ ent.path, @errorName(e) });
            bad_files += 1;
            continue;
        };
        total_pass += s.passed;
        total_fail += s.failed;
        total_skip += s.skipped;
        if (s.failed != 0) {
            bad_files += 1;
            try out.print("  FAIL {s}: {d} passed, {d} failed, {d} skipped", .{ ent.path, s.passed, s.failed, s.skipped });
            if (s.first_failure) |ff| try out.print(" — first: {s}", .{ff});
            try out.print("\n", .{});
        }
    }

    try out.print(
        "\nconformance: {d} files — {d} passed, {d} failed, {d} skipped ({d} file(s) with failures/errors)\n",
        .{ files, total_pass, total_fail, total_skip, bad_files },
    );
    try out.flush();
    if (total_fail != 0 or bad_files != 0) return error.ConformanceFailed;
}
