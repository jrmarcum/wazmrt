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
            try out.print("trap: {s}\n", .{@errorName(e)});
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

    // `--dir <host>[:<guest>]` preopens: the guest can reach these and nothing
    // else. Everything after them is argv for the guest.
    var rest = wasi_args;
    while (rest.len >= 2 and std.mem.eql(u8, rest[0], "--dir")) {
        const spec = rest[1];
        // Split on the LAST ':' so a Windows host path (`C:\tmp`) still parses.
        const host, const guest = if (std.mem.lastIndexOfScalar(u8, spec, ':')) |i|
            if (i > 1) .{ spec[0..i], spec[i + 1 ..] } else .{ spec, spec }
        else
            .{ spec, spec };
        _ = wasi.addPreopen(host, guest) catch |e| {
            try out.print("error: --dir '{s}': {s}\n", .{ host, @errorName(e) });
            return 1;
        };
        rest = rest[2..];
    }
    // An explicit `--` ends our flags; everything after it is the guest's.
    if (rest.len >= 1 and std.mem.eql(u8, rest[0], "--")) rest = rest[1..];

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
    wasi.memory = inst.memory; // module memory now exists

    _ = inst.invokeIndex(start_index, &.{}) catch |e| {
        // `proc_exit` unwinds via HostTrap with the code recorded — a clean exit.
        if (e == error.HostTrap and wasi.exit_code != null) return wasi.exit_code.?;
        return e;
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
        try out.print("trap: start: {s}\n", .{@errorName(e)});
        return;
    };

    const results = inst.invokeIndex(fi, call_args) catch |e| {
        try out.print("trap: {s}\n", .{@errorName(e)});
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
