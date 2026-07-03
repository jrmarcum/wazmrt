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
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };

    var module = wazmrt.decode(arena, bytes) catch |e| {
        try out.print("error: cannot decode '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };
    defer module.deinit();

    // Run mode: `wazmrt <module.wasm> <export> [args...]` — invoke and print.
    if (args.len >= 3) {
        try runFunction(arena, out, &module, args[2], args[3..]);
        return;
    }

    try out.print("{s}: valid wasm v{d}, {d} section(s)\n", .{ path, module.version, module.sections.len });
    for (module.sections) |s| {
        try out.print("  - {s} (payload {d} bytes @ 0x{x})\n", .{ @tagName(s.id), s.size, s.offset });
    }

    var code_bytes: usize = 0;
    for (module.code) |c| code_bytes += c.body.len;
    try out.print("  types={d} imports={d} functions={d} exports={d} code={d} ({d} body bytes)\n", .{
        module.func_types.len, module.imports.len, module.functions.len,
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

    const results = inst.invoke(name, call_args) catch |e| {
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
