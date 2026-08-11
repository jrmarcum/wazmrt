//! size_gate.zig — fail the build when a shipped artifact grows past its recorded ceiling.
//!
//! `ReleaseSmall` is a first-class project goal (see `cmem/roadmap.md` → CURRENT PROGRAM), and a goal
//! with no gate is a preference: between 2026-07-14 and 2026-08-11 the C-ABI DLL grew **+75%** and the
//! static library **+122%** with nobody noticing, because the only size numbers on record were a
//! month-old measurement in a memory file.
//!
//! This is the same shape as `zig build test-security` — a step whose whole purpose is that it CAN go
//! red. Ceilings are exact (no headroom), so growth must be accompanied by raising the number in the
//! same commit, which puts every increase in the log with a reason.
//!
//! Usage: `size_gate <ceilings-file> <dir> [dir...]`
//! Artifacts are looked up by base name in the given directories. A name listed in the ceilings file
//! but absent from all of them is **skipped, not failed** — `zig build dll` is a separate step, so the
//! shared library is legitimately missing from a plain `zig build`. But if NOTHING is found the gate
//! fails: a gate that checks nothing is not a gate.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        try out.print("usage: size_gate <ceilings-file> <optimize-mode> <dir> [dir...]\n", .{});
        return error.BadUsage;
    }
    const ceilings_path = args[1];
    const mode = args[2];
    const dirs = args[3..];

    // Ceilings describe the SHIPPING build. A Debug artifact is ~4x that, so without this check the
    // gate would go red for a meaningless reason and hand out the wrong advice ("raise the ceiling"),
    // which is how a gate gets waved through — the exact habit it exists to prevent.
    if (!std.mem.eql(u8, mode, "ReleaseSmall")) {
        try out.print("\n  size gate: built {s}, but the ceilings describe ReleaseSmall.\n", .{mode});
        try out.print("  Re-run as: zig build size -Doptimize=ReleaseSmall\n\n", .{});
        return error.WrongOptimizeMode;
    }

    const text = Io.Dir.cwd().readFileAlloc(io, ceilings_path, arena, .limited(1 << 20)) catch |e| {
        try out.print("size gate: cannot read ceilings file '{s}': {s}\n", .{ ceilings_path, @errorName(e) });
        return error.NoCeilingsFile;
    };

    var over: usize = 0;
    var checked: usize = 0;
    var skipped: usize = 0;

    try out.print("\n  Size gate ({s})\n", .{ceilings_path});
    try out.print("  {s:<14} {s:>10} {s:>10} {s:>10}\n", .{ "artifact", "actual", "ceiling", "delta" });

    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const num = fields.next() orelse {
            try out.print("size gate: malformed line (no ceiling): '{s}'\n", .{line});
            return error.MalformedCeilings;
        };
        const ceiling = std.fmt.parseInt(u64, num, 10) catch {
            try out.print("size gate: malformed ceiling '{s}' for '{s}'\n", .{ num, name });
            return error.MalformedCeilings;
        };

        const actual = sizeOf(io, arena, dirs, name) orelse {
            skipped += 1;
            try out.print("  {s:<14} {s:>10}   (not built — skipped)\n", .{ name, "-" });
            continue;
        };
        checked += 1;

        // Signed, because a SHRINK is news this gate should also surface: it says to lower the ceiling
        // and lock the win in, rather than leaving slack for the next regression to hide in.
        const delta = @as(i64, @intCast(actual)) - @as(i64, @intCast(ceiling));
        const mark = if (actual > ceiling) "OVER" else if (delta < 0) "under" else "ok";
        // Sign written by hand: Zig 0.16's format placeholders have no `+` flag, and a bare `{d}`
        // would render a growth of 0 and a growth of 900 identically undecorated.
        var delta_buf: [24]u8 = undefined;
        const delta_str = std.fmt.bufPrint(&delta_buf, "{s}{d}", .{ if (delta > 0) "+" else "", delta }) catch "?";
        try out.print("  {s:<14} {d:>10} {d:>10} {s:>10}  {s}\n", .{ name, actual, ceiling, delta_str, mark });
        if (actual > ceiling) over += 1;
    }

    if (checked == 0) {
        try out.print("\n  size gate: NO artifact was found — a gate that checks nothing is not a gate.\n", .{});
        try out.print("  Build first: `zig build -Doptimize=ReleaseSmall` (and `dll` for the shared library).\n\n", .{});
        return error.NothingMeasured;
    }
    if (over > 0) {
        try out.print("\n  {d} artifact(s) OVER ceiling.\n", .{over});
        try out.print("  If the growth is intended, raise the number in {s} IN THE SAME COMMIT and say\n", .{ceilings_path});
        try out.print("  what bought the bytes. If it is not, find what did before moving on.\n\n", .{});
        return error.SizeOverCeiling;
    }

    try out.print("\n  OK — {d} checked, {d} skipped, none over ceiling.\n\n", .{ checked, skipped });
}

/// Size of `name` in the first of `dirs` that has it, or null if none does.
///
/// Reads the file rather than stat-ing it: the artifacts are ~1 MB total, this runs once per `zig
/// build size`, and it makes existence and readability the same check.
fn sizeOf(io: Io, arena: std.mem.Allocator, dirs: []const [:0]const u8, name: []const u8) ?u64 {
    for (dirs) |d| {
        const path = std.fs.path.join(arena, &.{ d, name }) catch continue;
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20)) catch continue;
        return bytes.len;
    }
    return null;
}
