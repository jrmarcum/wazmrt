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

/// A baseline entry: how many assertion failures this file is *known* to have
/// (or that it is known to fail the runner outright).
const Expected = struct { runner_error: bool, failures: usize };

/// What a file actually did this run — kept so `-Dwrite-baseline=true` can emit
/// a fresh baseline and so the summary can name regressions.
const Observed = struct { path: []const u8, runner_error: bool, failures: usize };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const dir_path = if (args.len > 1) args[1] else "";
    const baseline_path = if (args.len > 2) args[2] else "";
    const write_baseline = args.len > 3 and std.mem.eql(u8, args[3], "write");
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

    // Expected-failure baseline. Without one this step can only gate on ZERO
    // failures, which the upstream testsuite has never satisfied here (see the
    // snapshot in cmem/testing.md: linking 37, return_call_ref 9, …) — so it
    // would fail forever and gate nothing. With a baseline it gates on
    // *regressions*, which is what a CI step is actually for.
    var baseline: std.StringHashMapUnmanaged(Expected) = .empty;
    if (baseline_path.len != 0) {
        if (Io.Dir.cwd().readFileAlloc(io, baseline_path, arena, .limited(4 << 20))) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const tok = line[0..sp];
                const path = std.mem.trim(u8, line[sp + 1 ..], " \t");
                const exp: Expected = if (std.mem.eql(u8, tok, "error"))
                    .{ .runner_error = true, .failures = 0 }
                else
                    .{ .runner_error = false, .failures = std.fmt.parseInt(usize, tok, 10) catch continue };
                try baseline.put(arena, try arena.dupe(u8, path), exp);
            }
        } else |e| if (!write_baseline) {
            try out.print("conformance: cannot read baseline '{s}': {s}\n", .{ baseline_path, @errorName(e) });
            return error.CannotOpenBaseline;
        }
    }

    // Collected for `-Dwrite-baseline=true` and for the regression verdict.
    var observed: std.ArrayList(Observed) = .empty;
    var regressions: usize = 0;
    var improvements: usize = 0;

    var total_pass: usize = 0;
    var total_fail: usize = 0;
    var total_skip: usize = 0;
    var files: usize = 0;
    var bad_files: usize = 0;

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (true) {
        // Per-*file* errors are already handled gracefully below; a directory
        // iteration error used to propagate and abandon the entire run, so one
        // unreadable subdirectory would discard every result gathered so far.
        // Count it like a bad file and stop walking, keeping what we have.
        const maybe = walker.next(io) catch |e| {
            try out.print("  ! directory walk stopped: {s}\n", .{@errorName(e)});
            bad_files += 1;
            regressions += 1;
            break;
        };
        const ent = maybe orelse break;
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.basename, ".wast")) continue;
        files += 1;

        // A fresh arena per file so memory doesn't accumulate across a testsuite
        // of thousands of scripts. `ent.path`/`.basename` are invalidated by the
        // next `walker.next`, so everything using them stays inside this iteration.
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const a = file_arena.allocator();

        // `ent.path` is invalidated by the next `walker.next`, so anything kept
        // past this iteration is duped into the outer arena.
        const exp: Expected = baseline.get(ent.path) orelse .{ .runner_error = false, .failures = 0 };

        const bytes = ent.dir.readFileAlloc(io, ent.basename, a, .limited(64 << 20)) catch |e| {
            try out.print("  ! {s}: read failed ({s})\n", .{ ent.path, @errorName(e) });
            bad_files += 1;
            regressions += 1; // an unreadable file is never an acceptable baseline
            continue;
        };
        const s = wazmrt.wast.runScript(a, bytes) catch |e| {
            try observed.append(arena, .{ .path = try arena.dupe(u8, ent.path), .runner_error = true, .failures = 0 });
            bad_files += 1;
            if (exp.runner_error) {
                try out.print("  ~ {s}: runner error ({s}) — known, in baseline\n", .{ ent.path, @errorName(e) });
            } else {
                try out.print("  ! {s}: runner error ({s}) — NOT in baseline\n", .{ ent.path, @errorName(e) });
                regressions += 1;
            }
            continue;
        };
        total_pass += s.passed;
        total_fail += s.failed;
        total_skip += s.skipped;
        if (s.failed != 0 or exp.failures != 0 or exp.runner_error)
            try observed.append(arena, .{ .path = try arena.dupe(u8, ent.path), .runner_error = false, .failures = s.failed });

        if (s.failed > exp.failures or (exp.runner_error and s.failed != 0)) {
            bad_files += 1;
            regressions += 1;
            try out.print("  FAIL {s}: {d} passed, {d} failed (baseline {d}), {d} skipped", .{ ent.path, s.passed, s.failed, exp.failures, s.skipped });
            if (s.first_failure) |ff| try out.print(" — first: {s}", .{ff});
            try out.print("\n", .{});
        } else if (s.failed < exp.failures or (exp.runner_error and s.failed == 0)) {
            improvements += 1;
            try out.print("  improved {s}: {d} failed (baseline {d}) — update the baseline\n", .{ ent.path, s.failed, exp.failures });
        } else if (s.failed != 0) {
            try out.print("  ~ {s}: {d} failed — known, in baseline\n", .{ ent.path, s.failed });
        }
    }

    try out.print(
        "\nconformance: {d} files — {d} passed, {d} failed, {d} skipped ({d} file(s) with failures/errors)\n",
        .{ files, total_pass, total_fail, total_skip, bad_files },
    );

    if (write_baseline) {
        // Emit a baseline capturing exactly today's results, so adopting one is
        // a single command rather than hand-transcribing failure counts.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena,
            \\# wazmrt conformance baseline — EXPECTED failures per .wast file.
            \\# Generated by `zig build conformance -Dtestsuite=<dir> -Dwrite-baseline=true`.
            \\# The step fails only when a file does WORSE than its line here, so this
            \\# gates against regressions rather than against a zero that upstream has
            \\# never reached. A file that improves is reported, not failed — re-generate
            \\# to lock the improvement in. `error <path>` = the runner cannot parse it.
            \\
        );
        for (observed.items) |o| {
            if (o.runner_error) {
                try buf.appendSlice(arena, "error ");
                try buf.appendSlice(arena, o.path);
            } else {
                try buf.print(arena, "{d} {s}", .{ o.failures, o.path });
            }
            try buf.append(arena, '\n');
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = buf.items }) catch |e| {
            try out.print("conformance: cannot write baseline '{s}': {s}\n", .{ baseline_path, @errorName(e) });
            return error.CannotWriteBaseline;
        };
        try out.print("conformance: wrote baseline '{s}' ({d} entries)\n", .{ baseline_path, observed.items.len });
        try out.flush();
        return;
    }

    if (baseline_path.len == 0) {
        // No baseline: the only sound verdict is the strict one. Say so, because
        // upstream will not pass it and a silent forever-red step teaches people
        // to ignore it.
        if (total_fail != 0 or bad_files != 0) {
            try out.print(
                "conformance: no baseline given, so this gates on ZERO failures. " ++
                    "Upstream has known failures here — generate a baseline with " ++
                    "-Dbaseline=<file> -Dwrite-baseline=true, then pass -Dbaseline=<file> to gate on regressions.\n",
                .{},
            );
            try out.flush();
            return error.ConformanceFailed;
        }
    } else {
        try out.print("conformance: {d} regression(s), {d} improvement(s) vs baseline '{s}'\n", .{ regressions, improvements, baseline_path });
        try out.flush();
        if (regressions != 0) return error.ConformanceRegressed;
    }
    try out.flush();
}
