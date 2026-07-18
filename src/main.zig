//! wazmrt CLI — decode a WebAssembly binary and print a summary of its
//! sections. A thin front-end over the `wazmrt` library module.

const std = @import("std");
const Io = std.Io;

const wazmrt = @import("wazmrt");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.print("wazmrt {s}\nusage: {s} <module.wasm>\n", .{
            wazmrt.version,
            if (args.len > 0) args[0] else "wazmrt",
        });
        return;
    }

    // `wazmrt pin <file> [--db <path>]` — hash a module for the pin DB (Phase 5).
    if (std.mem.eql(u8, args[1], "pin")) return pinSubcommand(arena, io, out, args[2..]);

    const path = args[1];
    var bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };

    // .wast script mode: parse + run the assertions, print a pass/fail summary.
    if (std.mem.endsWith(u8, path, ".wast")) {
        const s = wazmrt.wast.runScript(arena, bytes) catch |e| {
            try out.print("error: cannot run '{s}': {s}\n", .{ path, @errorName(e) });
            return;
        };
        try out.print("{s}: {d} passed, {d} failed, {d} skipped\n", .{ path, s.passed, s.failed, s.skipped });
        if (s.first_failure) |f| try out.print("  first failure: {s}\n", .{f});
        return;
    }

    // .wat text: assemble to a binary, then treat it like a .wasm.
    if (std.mem.endsWith(u8, path, ".wat")) {
        bytes = wazmrt.wat.assemble(arena, bytes) catch |e| {
            try out.print("error: cannot assemble '{s}': {s}\n", .{ path, @errorName(e) });
            return;
        };
    }

    var module = wazmrt.decode(arena, bytes) catch |e| {
        try out.print("error: cannot decode '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };
    defer module.deinit();

    // Pin verification (Phase 5) gates *execution*: before we run anything, the
    // in-memory `bytes` (exactly what we execute — TOCTOU-safe) are hashed and
    // checked against the root-owned pin DB per the enforcement policy. The
    // summarize path below never executes, so it is never gated.
    const will_execute = (args.len >= 3 and findExport(&module, args[2]) != null) or
        findExport(&module, "_start") != null;
    if (will_execute and !(try verifyGate(arena, io, out, bytes, path, args[2..]))) return;

    // Run mode: `wazmrt <module.wasm> <export> [args...]` — invoke and print.
    // A trailing arg only selects an export if it actually names one; otherwise
    // it belongs to the WASI command below (`--dir …`, guest argv, …).
    if (args.len >= 3 and findExport(&module, args[2]) != null) {
        try runFunction(arena, out, &module, args[2], args[3..]);
        return;
    }

    // WASI command: `wazmrt <module.wasm> [--dir <host>[:<guest>]]... [args...]`
    // runs `_start` with the `wasi_snapshot_preview1` host imports wired up.
    if (findExport(&module, "_start")) |start_index| {
        const code = runWasi(arena, io, out, &module, path, start_index, args[2..]) catch |e| {
            if (e != AlreadyReported) try out.print("trap: {s}\n", .{@errorName(e)});
            return;
        };
        if (code != 0) try out.print("(exit {d})\n", .{code});
        return;
    }

    try out.print("{s}: valid wasm v{d}, {d} section(s)\n", .{ path, module.version, module.sections.len });
    for (module.sections) |s| {
        try out.print("  - {s} (payload {d} bytes @ 0x{x})\n", .{ @tagName(s.id), s.size, s.offset });
    }

    var code_bytes: usize = 0;
    for (module.code) |c| code_bytes += c.body.len;
    try out.print("  types={d} imports={d} functions={d} exports={d} code={d} ({d} body bytes)\n", .{
        module.comp_types.len, module.imports.len, module.functions.len,
        module.exports.len,    module.code.len,    code_bytes,
    });
    for (module.imports) |i| {
        try out.print("  import {s}.{s} : {s}\n", .{ i.module, i.name, @tagName(i.type.kind()) });
    }
    for (module.exports) |e| {
        try out.print("  export {s} : {s} #{d}\n", .{ e.name, @tagName(e.type.kind()), e.index });
    }

    // Decode each function body into the instruction IR (opcode.decodeBody).
    var ok: usize = 0;
    for (module.code, 0..) |c, i| {
        const instrs = wazmrt.opcode.decodeBody(arena, c.body) catch |e| {
            try out.print("  fn[{d}]: body decode FAILED — {s}\n", .{ i, @errorName(e) });
            continue;
        };
        ok += 1;
        try out.print("  fn[{d}]: {d} instr, {d} locals\n", .{ i, instrs.len, c.localCount() });
    }
    if (module.code.len != 0) {
        try out.print("  bodies decoded: {d}/{d}\n", .{ ok, module.code.len });
    }

    wazmrt.validate(arena, &module) catch |e| {
        try out.print("  validation: FAILED — {s}\n", .{@errorName(e)});
        return;
    };
    try out.print("  validation: OK\n", .{});
}

// ===== Phase 5 — pin verification (see cmem/security-model.md, roadmap.md §5) =====

/// `wazmrt pin <file> [--db <path>]` — SHA-256 a module and emit its pin line.
/// Prints `<hex>  <file>` (redirect/append into a root-owned pin DB); with
/// `--db <path>` also appends it there. Meant to be run with privilege by an
/// installer — the runtime only ever *reads* the DB.
fn pinSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !void {
    var file: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--db") and i + 1 < rest.len) {
            db_path = rest[i + 1];
            i += 1;
        } else if (file == null and !std.mem.startsWith(u8, rest[i], "--")) {
            file = rest[i];
        }
    }
    if (file == null) {
        try out.print("usage: wazmrt pin <file> [--db <path>]\n", .{});
        return;
    }
    const bytes = Io.Dir.cwd().readFileAlloc(io, file.?, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ file.?, @errorName(e) });
        return;
    };
    const hex = wazmrt.pin.hashHex(bytes);
    try out.print("{s}  {s}\n", .{ &hex, file.? });
    if (db_path) |p| {
        appendPinLine(arena, io, p, &hex, file.?) catch |e| {
            try out.print("error: cannot append to pin DB '{s}': {s}\n", .{ p, @errorName(e) });
            return;
        };
        try out.print("pinned to {s}\n", .{p});
    }
}

/// Append one `<hex>  <label>` line to a pin DB, rewriting the whole (small)
/// file. If the parent directory is missing the write fails — that is the
/// installer's job to create, and a clear error beats silently succeeding.
fn appendPinLine(arena: std.mem.Allocator, io: Io, path: []const u8, hex: []const u8, label: []const u8) !void {
    const prev: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, prev);
    if (prev.len > 0 and prev[prev.len - 1] != '\n') try buf.append(arena, '\n');
    try buf.appendSlice(arena, hex);
    try buf.appendSlice(arena, "  ");
    try buf.appendSlice(arena, label);
    try buf.append(arena, '\n');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

fn defaultPinsPath() []const u8 {
    return if (@import("builtin").os.tag == .windows)
        "C:\\ProgramData\\wazmrt\\pins"
    else
        "/etc/wazmrt/pins";
}

/// The wazmrt-flag region: args after the module path up to `--` (guest argv).
/// Verify flags must sit here so a guest arg that happens to read `--no-verify`
/// is never mistaken for one of ours.
fn flagRegion(rest: []const []const u8) []const []const u8 {
    for (rest, 0..) |a, i| if (std.mem.eql(u8, a, "--")) return rest[0..i];
    return rest;
}
fn hasFlag(rest: []const []const u8, name: []const u8) bool {
    for (flagRegion(rest)) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}
fn flagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
    const region = flagRegion(rest);
    var i: usize = 0;
    while (i + 1 < region.len) : (i += 1)
        if (std.mem.eql(u8, region[i], name)) return region[i + 1];
    return null;
}

/// Read one line from stdin; true iff it starts with y/Y. EOF/error → false
/// (default No), so a closed or redirected stdin can never mean "yes".
fn promptYesNo(io: Io) bool {
    var buf: [64]u8 = undefined;
    var r: Io.File.Reader = .init(.stdin(), io, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len > 0 and (t[0] == 'y' or t[0] == 'Y');
}

/// The execution gate. Returns true to proceed, false to abort (already
/// reported). The root-owned pin DB carries both the approved digests and the
/// enforcement `# mode:` — so the policy inherits the DB file's ownership.
/// `bytes` is the in-memory buffer we are about to execute (TOCTOU-safe).
fn verifyGate(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    bytes: []const u8,
    path: []const u8,
    rest: []const []const u8,
) !bool {
    const db_path = flagValue(rest, "--pins") orelse defaultPinsPath();
    const db_text: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, db_path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null, // no DB ⇒ no policy ⇒ dev default (off)
        else => {
            try out.print("error: cannot read pin DB '{s}': {s}\n", .{ db_path, @errorName(e) });
            return false;
        },
    };

    var policy: wazmrt.pin.Mode = .off;
    var db: wazmrt.pin.Db = .empty;
    if (db_text) |text| {
        if (wazmrt.pin.modeFromDb(text)) |m| policy = m;
        db = wazmrt.pin.Db.parse(arena, text) catch |e| {
            // A corrupt/truncated DB fails CLOSED — never silently "not listed".
            try out.print("error: pin DB '{s}' is corrupt ({s}); refusing to run\n", .{ db_path, @errorName(e) });
            return false;
        };
    }
    // A dev `--verify <mode>` flag may only RAISE strictness above the policy,
    // never lower it — a user argument cannot weaken a root-owned enforce.
    if (flagValue(rest, "--verify")) |mv|
        if (wazmrt.pin.modeFromStr(mv)) |m| {
            policy = wazmrt.pin.stricter(policy, m);
        };

    // Hash the in-memory bytes we are about to execute (TOCTOU-safe), then let
    // the pure decision function pick the action from the security matrix.
    const digest = wazmrt.pin.hash(bytes);
    const pinned = db.contains(digest);
    const opt_out = hasFlag(rest, "--no-verify") or hasFlag(rest, "--yes");
    const tty = Io.File.stdin().isTty(io) catch false;
    const hex = wazmrt.pin.toHex(digest);

    switch (wazmrt.pin.decide(policy, pinned, opt_out, tty)) {
        .run => {
            // Note when we ran something the policy would otherwise stop.
            if (policy == .warn and !pinned)
                try out.print("warning: running unverified module {s} (sha256 {s}) — --no-verify\n", .{ path, &hex });
            return true;
        },
        .deny => {
            const why = if (policy == .enforce) "policy=enforce" else "unpinned; no TTY to confirm — pass --no-verify to allow";
            try out.print("refusing to run unverified module: {s}\n  sha256 {s}\n  (not in pin DB {s}; {s})\n", .{ path, &hex, db_path, why });
            return false;
        },
        .prompt => {
            try out.print("module is unverified (not pinned): {s}\n  sha256 {s}\nproceed? [y/N] ", .{ path, &hex });
            try out.flush();
            if (promptYesNo(io)) return true;
            try out.print("aborted.\n", .{});
            return false;
        },
    }
}

/// Report a trap with the location it actually happened at, innermost frame
/// first, naming each frame from the module's name section when it has one.
///
/// Without this a trap is just `trap: Unreachable`, which says nothing about
/// where — the gap that made the Phase 3 `bitcast_invalid` hunt cost hours
/// (`cmem/known-issues.md` #19). A 2-instruction body trapping at +0 is the
/// signature of a wasm-ld stub, and the name says which import it stubbed.
fn printTrap(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    inst: *const wazmrt.interp.Instance,
    e: anyerror,
) !void {
    try out.print("trap: {s}\n", .{@errorName(e)});
    const frames = inst.trapFrames();
    if (frames.len == 0) return; // never reached wasm code (bad arity, say)

    for (frames, 0..) |f, i| {
        const lead = if (i == 0) "at" else "by";
        // Prefer a real byte offset: it lines up with `wasm-objdump` output,
        // where an IR index means nothing outside this runtime.
        const off = inst.frameOffset(arena, f);
        if (module.funcName(f.func_index)) |n|
            try out.print("  {s} fn[{d}] <{s}> +{d}\n", .{ lead, f.func_index, n, offOr(off, f) })
        else
            try out.print("  {s} fn[{d}] +{d}\n", .{ lead, f.func_index, offOr(off, f) });
    }
    if (inst.trapTruncated())
        try out.print("  ... {d} more frame(s)\n", .{inst.trap_depth - frames.len});
    if (module.func_names == null)
        try out.print("  (no name section: rebuild the guest unstripped for symbols)\n", .{});
}

/// The frame's byte offset within its function, falling back to the IR index
/// when the body can't be re-decoded (a host frame, or OOM). Both are "+N" after
/// a function name; the byte offset is the one an external tool can use.
fn offOr(off: ?wazmrt.interp.Instance.Offsets, f: wazmrt.interp.TrapFrame) usize {
    return if (off) |o| o.func else f.pc;
}

/// `runWasi` already reported the trap in full; the caller must not print again.
const AlreadyReported = error.AlreadyReported;

/// Function index of the exported function `name`, or null.
fn findExport(module: *const wazmrt.Module, name: []const u8) ?u32 {
    for (module.exports) |e| {
        if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) return e.index;
    }
    return null;
}

/// Run a WASI command module: wire the `wasi_snapshot_preview1` host imports,
/// instantiate, and invoke `_start`. Returns the process exit code (0 unless
/// `proc_exit` set one). `wasi_args` become argv[1..]; argv[0] is the path.
fn runWasi(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    path: []const u8,
    start_index: u32,
    wasi_args: []const [:0]const u8,
) !u32 {
    const interp = wazmrt.interp;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_w = &stderr_file_writer.interface;
    defer err_w.flush() catch {};

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    const seed: u64 = @intCast(@max(Io.Timestamp.now(io, .awake).nanoseconds, 0));
    var wasi = wazmrt.wasi.Wasi.init(arena, io, out, err_w, seed);
    defer wasi.deinit();
    wasi.stdin = &stdin_file_reader.interface;

    // wazmrt flags precede the guest's own argv. Each takes a value:
    //   --dir <host>[:<guest>]      read-write preopen (the guest's only files)
    //   --ro-dir <host>[:<guest>]   read-only preopen (no write/create/delete)
    //   --env KEY=VAL               one environment variable for the guest
    //   --                          end of wazmrt flags; the rest is guest argv
    var environ: std.ArrayList([]const u8) = .empty;
    var rest = wasi_args;
    flags: while (rest.len >= 1) {
        const flag = rest[0];
        const ro = std.mem.eql(u8, flag, "--ro-dir");
        if ((std.mem.eql(u8, flag, "--dir") or ro) and rest.len >= 2) {
            const spec = rest[1];
            // Split on the LAST ':' so a Windows host path (`C:\tmp`) still parses.
            const host, const guest = if (std.mem.lastIndexOfScalar(u8, spec, ':')) |i|
                if (i > 1) .{ spec[0..i], spec[i + 1 ..] } else .{ spec, spec }
            else
                .{ spec, spec };
            const rmask = if (ro) wazmrt.wasi.readOnlyRights else wazmrt.wasi.allRights;
            _ = wasi.addPreopen(host, guest, rmask) catch |e| {
                try out.print("error: {s} '{s}': {s}\n", .{ flag, host, @errorName(e) });
                return 1;
            };
            rest = rest[2..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--env") and rest.len >= 2) {
            // WASI environ entries are `KEY=VALUE`; pass through verbatim.
            try environ.append(arena, try arena.dupe(u8, rest[1]));
            rest = rest[2..];
            continue :flags;
        }
        // Pin-verification flags are handled by `verifyGate` before we get here;
        // consume them so they never reach the guest's argv (see verifyGate).
        if ((std.mem.eql(u8, flag, "--verify") or std.mem.eql(u8, flag, "--pins")) and rest.len >= 2) {
            rest = rest[2..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--no-verify") or std.mem.eql(u8, flag, "--yes")) {
            rest = rest[1..];
            continue :flags;
        }
        // An explicit `--` ends our flags; everything after it is the guest's.
        if (std.mem.eql(u8, flag, "--")) rest = rest[1..];
        break :flags;
    }
    wasi.environ = environ.items;

    // argv: the module path, then the guest's own args (the preopen flags are
    // ours, not the guest's).
    const argv = try arena.alloc([]const u8, 1 + rest.len);
    argv[0] = path;
    for (rest, argv[1..]) |src, *dst| dst.* = src;
    wasi.args = argv;

    // Back every imported function: `wasi_snapshot_preview1.*` from WASI, any
    // other import with a trap-on-call stub.
    var funcs: std.ArrayList(interp.Instance.HostFunc) = .empty;
    for (module.imports) |imp| {
        if (imp.type != .func) continue;
        if (std.mem.eql(u8, imp.module, "wasi_snapshot_preview1"))
            try funcs.append(arena, wasi.hostFunc(imp.name))
        else
            try funcs.append(arena, .{ .native_env = .{ .ctx = &wasi, .call = unresolvedImport } });
    }

    var inst = try interp.Instance.initWithImports(arena, module, .{ .funcs = funcs.items });
    defer inst.deinit();
    wasi.memory = inst.memory0(); // module memory now exists

    _ = inst.invokeIndex(start_index, &.{}) catch |e| {
        // `proc_exit` unwinds via HostTrap with the code recorded — a clean exit.
        if (e == error.HostTrap and wasi.exit_code != null) return wasi.exit_code.?;
        try printTrap(arena, out, module, &inst, e);
        return AlreadyReported;
    };
    return wasi.exit_code orelse 0;
}

fn unresolvedImport(ctx: *anyopaque, args: []const wazmrt.interp.Value, results: []wazmrt.interp.Value) bool {
    _ = ctx;
    _ = args;
    _ = results;
    return false; // -> error.HostTrap
}

/// Instantiate `module`, invoke exported function `name` with `arg_strings`
/// (parsed per the function's parameter types), and print the results.
fn runFunction(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    name: []const u8,
    arg_strings: []const [:0]const u8,
) !void {
    const interp = wazmrt.interp;

    // Resolve the export to a function index + signature.
    var func_index: ?u32 = null;
    for (module.exports) |e| {
        if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) func_index = e.index;
    }
    const fi = func_index orelse {
        try out.print("error: no exported function '{s}'\n", .{name});
        return;
    };
    const ft = module.funcType(fi).?;
    if (arg_strings.len != ft.params.len) {
        try out.print("error: '{s}' takes {d} arg(s), got {d}\n", .{ name, ft.params.len, arg_strings.len });
        return;
    }

    // Parse each argument according to its declared parameter type.
    const call_args = try arena.alloc(interp.Value, ft.params.len);
    for (arg_strings, ft.params, call_args) |s, pt, *dst| {
        dst.* = switch (pt) {
            .i32 => interp.i32Value(@truncate(try std.fmt.parseInt(i64, s, 0))),
            .i64 => interp.i64Value(try std.fmt.parseInt(i64, s, 0)),
            .f32 => interp.f32Value(@floatCast(try std.fmt.parseFloat(f64, s))),
            .f64 => interp.f64Value(try std.fmt.parseFloat(f64, s)),
            else => {
                try out.print("error: unsupported parameter type {s}\n", .{@tagName(pt)});
                return;
            },
        };
    }

    var inst = interp.Instance.init(arena, module) catch |e| {
        try out.print("error: instantiate: {s}\n", .{@errorName(e)});
        return;
    };
    defer inst.deinit();

    inst.runStart() catch |e| {
        try out.print("trap: start: ", .{});
        try printTrap(arena, out, module, &inst, e);
        return;
    };

    const results = inst.invokeIndex(fi, call_args) catch |e| {
        try printTrap(arena, out, module, &inst, e);
        return;
    };

    for (results, ft.results, 0..) |res, rt, i| {
        if (i != 0) try out.print(" ", .{});
        switch (rt) {
            .i32 => try out.print("{d}", .{interp.asI32(res)}),
            .i64 => try out.print("{d}", .{interp.asI64(res)}),
            .f32 => try out.print("{d}", .{interp.asF32(res)}),
            .f64 => try out.print("{d}", .{interp.asF64(res)}),
            else => try out.print("0x{x}", .{res}),
        }
    }
    try out.print("\n", .{});
}
