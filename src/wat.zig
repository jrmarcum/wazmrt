//! WAT text → wasm binary assembler (the reverse of `Module.decode`).
//!
//! Parses a `(module …)` S-expression (via `sexpr.zig`) and encodes it to a
//! WebAssembly binary that the decoder/validator/interpreter consume. It reuses
//! `opcode.zig` as the single instruction authority: instruction names map to
//! `Op` via `stringToEnum` (dots → underscores), and each operand is encoded per
//! `opcode.immediateKind`.
//!
//! **Scope today (MVP):** `(func …)` with named/anonymous params/results/locals,
//! inline and top-level `(export …)`, and the non-control instruction set
//! (numeric/comparison/const/`local.*`/`global.*`/`drop`/`select`), in both
//! folded `(i32.add (local.get 0) (local.get 1))` and flat forms. Memory/global/
//! data sections and structured control flow (`block`/`loop`/`if`, `br*`,
//! `call_indirect`) are the next assembler increments.

const std = @import("std");
const sexpr = @import("sexpr.zig");
const opcode = @import("opcode.zig");
const types = @import("types.zig");

const V = types.ValType;
const Op = opcode.Op;
const Sexpr = sexpr.Sexpr;
const List = std.ArrayList;

pub const Error = sexpr.Error || error{
    NotAModule,
    BadModuleField,
    BadValType,
    UnknownInstr,
    UnknownIdentifier,
    BadImmediate,
    UnsupportedInstr,
} || std.mem.Allocator.Error;

const Func = struct {
    name: ?[]const u8 = null,
    params: List(V) = .empty,
    results: List(V) = .empty,
    locals: List(V) = .empty,
    /// Names of params then locals, index-aligned (null = anonymous).
    local_names: List(?[]const u8) = .empty,
    /// Inline export names (`(func (export "x") …)`).
    exports: List([]const u8) = .empty,
    /// Body instruction forms (everything after the param/result/local headers).
    body: []const Sexpr = &.{},
};

const ExportDef = struct { name: []const u8, kind: u8, index: u32 };

/// Assemble the first `(module …)` form found in `src`.
pub fn assemble(a: std.mem.Allocator, src: []const u8) Error![]const u8 {
    for (try sexpr.parseAll(a, src)) |form| {
        if (form.keyword()) |kw| {
            if (std.mem.eql(u8, kw, "module")) return assembleModule(a, form.asList().?);
        }
    }
    return error.NotAModule;
}

/// Assemble a parsed `(module …)` form (`module[0]` is the `module` keyword).
pub fn assembleModule(a: std.mem.Allocator, module: []const Sexpr) Error![]const u8 {
    var funcs: List(Func) = .empty;
    var func_names: List(?[]const u8) = .empty;
    var exports: List(ExportDef) = .empty;

    // Pass 1: collect definitions and resolve function indices (MVP: no imports).
    for (module[1..]) |field| {
        const kw = field.keyword() orelse return error.BadModuleField;
        const items = field.asList().?;
        if (std.mem.eql(u8, kw, "func")) {
            const f = try parseFunc(a, items);
            const idx: u32 = @intCast(funcs.items.len);
            for (f.exports.items) |name| try exports.append(a, .{ .name = name, .kind = 0, .index = idx });
            try funcs.append(a, f);
            try func_names.append(a, f.name);
        } else if (std.mem.eql(u8, kw, "export")) {
            // (export "name" (func $id|N))
            const name = items[1].string;
            const target = items[2].asList().?; // (func $id)
            const idx = try resolveByName(func_names.items, target[1]);
            try exports.append(a, .{ .name = name, .kind = 0, .index = idx });
        } else {
            // Ignore unsupported fields for now (type/memory/global/data/…).
        }
    }

    // Type section: dedup signatures; record each func's type index.
    var sigs: List(Func) = .empty; // reuse Func just for its params/results slices
    var func_type: List(u32) = .empty;
    for (funcs.items) |f| try func_type.append(a, try internSig(a, &sigs, f));

    var out: List(u8) = .empty;
    try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }); // header

    // Type section (1)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, sigs.items.len);
        for (sigs.items) |sig| {
            try s.append(a, 0x60);
            try valTypeVec(a, &s, sig.params.items);
            try valTypeVec(a, &s, sig.results.items);
        }
        try emitSection(a, &out, 1, s.items);
    }
    // Function section (3)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, func_type.items.len);
        for (func_type.items) |ti| try uleb(a, &s, ti);
        try emitSection(a, &out, 3, s.items);
    }
    // Export section (7)
    if (exports.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, exports.items.len);
        for (exports.items) |e| {
            try nameBytes(a, &s, e.name);
            try s.append(a, e.kind);
            try uleb(a, &s, e.index);
        }
        try emitSection(a, &out, 7, s.items);
    }
    // Code section (10)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, funcs.items.len);
        for (funcs.items) |f| {
            const body = try encodeBody(a, f, func_names.items);
            try uleb(a, &s, body.len);
            try s.appendSlice(a, body);
        }
        try emitSection(a, &out, 10, s.items);
    }

    return out.items;
}

// --- Function parsing ------------------------------------------------------

fn parseFunc(a: std.mem.Allocator, form: []const Sexpr) Error!Func {
    var f: Func = .{};
    var i: usize = 1;
    if (i < form.len and isId(form[i])) {
        f.name = form[i].atom;
        i += 1;
    }
    while (i < form.len) : (i += 1) {
        const kw = form[i].keyword() orelse break; // start of the body
        const list = form[i].asList().?;
        if (std.mem.eql(u8, kw, "export")) {
            try f.exports.append(a, list[1].string);
        } else if (std.mem.eql(u8, kw, "param")) {
            try parseDecls(a, list, &f.params, &f.local_names);
        } else if (std.mem.eql(u8, kw, "result")) {
            try parseDecls(a, list, &f.results, null);
        } else if (std.mem.eql(u8, kw, "local")) {
            try parseDecls(a, list, &f.locals, &f.local_names);
        } else break; // body starts (e.g. a folded instruction)
    }
    f.body = form[i..];
    return f;
}

/// Parse a `(param …)` / `(result …)` / `(local …)` group. Handles the named
/// single form `(param $x i32)` and the anonymous multi form `(param i32 i32)`.
fn parseDecls(a: std.mem.Allocator, list: []const Sexpr, out_types: *List(V), out_names: ?*List(?[]const u8)) Error!void {
    if (list.len >= 3 and isId(list[1])) {
        try out_types.append(a, try parseValType(list[2]));
        if (out_names) |n| try n.append(a, list[1].atom);
    } else {
        for (list[1..]) |t| {
            try out_types.append(a, try parseValType(t));
            if (out_names) |n| try n.append(a, null);
        }
    }
}

/// True if the S-expression is an identifier atom (`$name`).
fn isId(s: Sexpr) bool {
    const atom = s.asAtom() orelse return false;
    return atom.len != 0 and atom[0] == '$';
}

fn parseValType(s: Sexpr) Error!V {
    const atom = s.asAtom() orelse return error.BadValType;
    return stringToValType(atom) orelse error.BadValType;
}

fn stringToValType(atom: []const u8) ?V {
    const map = .{
        .{ "i32", V.i32 }, .{ "i64", V.i64 }, .{ "f32", V.f32 }, .{ "f64", V.f64 },
        .{ "v128", V.v128 }, .{ "funcref", V.funcref }, .{ "externref", V.externref },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, atom, m[0])) return m[1];
    }
    return null;
}

// --- Instruction encoding --------------------------------------------------

const Ctx = struct {
    a: std.mem.Allocator,
    out: *List(u8),
    local_names: []const ?[]const u8,
    func_names: []const ?[]const u8,
};

fn encodeBody(a: std.mem.Allocator, f: Func, func_names: []const ?[]const u8) Error![]const u8 {
    var body: List(u8) = .empty;
    // Locals vector: one (count=1, type) group per declared local.
    try uleb(a, &body, f.locals.items.len);
    for (f.locals.items) |t| {
        try uleb(a, &body, 1);
        try body.append(a, @intFromEnum(t));
    }
    var ctx: Ctx = .{ .a = a, .out = &body, .local_names = f.local_names.items, .func_names = func_names };
    try emitSeq(&ctx, f.body);
    try body.append(a, @intFromEnum(Op.end)); // implicit function end
    return body.items;
}

/// Emit a sequence of instruction forms (folded lists and/or flat atoms).
fn emitSeq(ctx: *Ctx, items: []const Sexpr) Error!void {
    var i: usize = 0;
    while (i < items.len) {
        switch (items[i]) {
            .list => |l| {
                try emitFolded(ctx, l);
                i += 1;
            },
            .atom => |name| {
                const op = lookupOp(name) orelse return error.UnknownInstr;
                i += 1;
                // Consume this instruction's flat immediate atoms.
                var imm: [3]Sexpr = undefined;
                var n: usize = 0;
                for (0..flatImmCount(op)) |_| {
                    if (i >= items.len) return error.BadImmediate;
                    imm[n] = items[i];
                    n += 1;
                    i += 1;
                }
                try emitInstr(ctx, op, imm[0..n]);
            },
            .string => return error.UnknownInstr,
        }
    }
}

/// Emit a folded instruction: `(op imm* operand*)` — operands emitted first.
fn emitFolded(ctx: *Ctx, list: []const Sexpr) Error!void {
    const name = list[0].asAtom() orelse return error.UnknownInstr;
    const op = lookupOp(name) orelse return error.UnknownInstr;
    var i: usize = 1;
    const imm_start = i;
    while (i < list.len and list[i].asAtom() != null) i += 1;
    const immediates = list[imm_start..i];
    // Operand sub-expressions are emitted before the instruction.
    while (i < list.len) : (i += 1) {
        const operand = list[i].asList() orelse return error.UnknownInstr;
        try emitFolded(ctx, operand);
    }
    try emitInstr(ctx, op, immediates);
}

fn emitInstr(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(op));
    switch (opcode.immediateKind(op)) {
        .none => {},
        .local => try uleb(ctx.a, ctx.out, try resolveLocal(ctx, try imm0(immediates))),
        .global => try uleb(ctx.a, ctx.out, try parseIndex(try imm0(immediates))),
        .func => try uleb(ctx.a, ctx.out, try resolveFunc(ctx, try imm0(immediates))),
        .i32c => try sleb(ctx.a, ctx.out, try parseWatI32(try imm0(immediates))),
        .i64c => try sleb(ctx.a, ctx.out, try parseWatI64(try imm0(immediates))),
        .f32c => try floatBits(ctx, u32, try imm0(immediates)),
        .f64c => try floatBits(ctx, u64, try imm0(immediates)),
        .mem_reserved => try ctx.out.append(ctx.a, 0x00),
        else => return error.UnsupportedInstr, // mem, block_type, br_table, call_indirect, label
    }
}

fn imm0(immediates: []const Sexpr) Error!Sexpr {
    if (immediates.len == 0) return error.BadImmediate;
    return immediates[0];
}

/// How many flat immediate atoms an opcode consumes (MVP-supported kinds).
fn flatImmCount(op: Op) usize {
    return switch (opcode.immediateKind(op)) {
        .local, .global, .func, .i32c, .i64c, .f32c, .f64c => 1,
        else => 0,
    };
}

fn lookupOp(name: []const u8) ?Op {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '.') '_' else c;
    return std.meta.stringToEnum(Op, buf[0..name.len]);
}

fn resolveLocal(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (ctx.local_names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn resolveFunc(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') return resolveByName(ctx.func_names, s);
    return parseIndex(s);
}

fn resolveByName(names: []const ?[]const u8, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn parseIndex(s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    return std.fmt.parseInt(u32, atom, 0) catch error.BadImmediate;
}

fn parseWatI32(s: Sexpr) Error!i64 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    const v = std.fmt.parseInt(i64, atom, 0) catch (std.fmt.parseInt(u32, atom, 0) catch return error.BadImmediate);
    return @as(i32, @truncate(v)); // sign-extended back to i64 for SLEB
}

fn parseWatI64(s: Sexpr) Error!i64 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    return std.fmt.parseInt(i64, atom, 0) catch {
        const u = std.fmt.parseInt(u64, atom, 0) catch return error.BadImmediate;
        return @bitCast(u);
    };
}

fn floatBits(ctx: *Ctx, comptime U: type, s: Sexpr) Error!void {
    const atom = s.asAtom() orelse return error.BadImmediate;
    const F = if (U == u32) f32 else f64;
    const f = std.fmt.parseFloat(F, atom) catch return error.BadImmediate;
    var b: [@sizeOf(U)]u8 = undefined;
    std.mem.writeInt(U, &b, @bitCast(f), .little);
    try ctx.out.appendSlice(ctx.a, &b);
}

// --- Section / LEB helpers -------------------------------------------------

fn internSig(a: std.mem.Allocator, sigs: *List(Func), f: Func) Error!u32 {
    for (sigs.items, 0..) |sig, i| {
        if (slicesEqual(sig.params.items, f.params.items) and slicesEqual(sig.results.items, f.results.items))
            return @intCast(i);
    }
    try sigs.append(a, f);
    return @intCast(sigs.items.len - 1);
}

fn slicesEqual(x: []const V, y: []const V) bool {
    return std.mem.eql(V, x, y);
}

fn valTypeVec(a: std.mem.Allocator, out: *List(u8), vts: []const V) Error!void {
    try uleb(a, out, vts.len);
    for (vts) |v| try out.append(a, @intFromEnum(v));
}

fn nameBytes(a: std.mem.Allocator, out: *List(u8), name: []const u8) Error!void {
    try uleb(a, out, name.len);
    try out.appendSlice(a, name);
}

fn emitSection(a: std.mem.Allocator, out: *List(u8), id: u8, payload: []const u8) Error!void {
    try out.append(a, id);
    try uleb(a, out, payload.len);
    try out.appendSlice(a, payload);
}

fn uleb(a: std.mem.Allocator, out: *List(u8), value: usize) Error!void {
    var v: u64 = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try out.append(a, byte);
        if (v == 0) break;
    }
}

fn sleb(a: std.mem.Allocator, out: *List(u8), value: i64) Error!void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7; // arithmetic shift
        const sign = byte & 0x40;
        if ((v == 0 and sign == 0) or (v == -1 and sign != 0)) {
            try out.append(a, byte);
            break;
        }
        byte |= 0x80;
        try out.append(a, byte);
    }
}

// --- Tests -----------------------------------------------------------------

const Module = @import("Module.zig");
const interp = @import("interp.zig");

fn assembleAndRun(src: []const u8, name: []const u8, args: []const interp.Value) !interp.Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a, src);
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    const r = try inst.invoke(name, args);
    return r[0];
}

test "assembles and runs a folded add" {
    const v = try assembleAndRun(
        \\(module (func (export "add") (param $x i32) (param $y i32) (result i32)
        \\  (i32.add (local.get $x) (local.get $y))))
    , "add", &.{ interp.i32Value(10), interp.i32Value(20) });
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(v));
}

test "assembles flat instruction form" {
    const v = try assembleAndRun(
        \\(module (func (export "f") (param i32 i32) (result i32)
        \\  local.get 0 local.get 1 i32.mul))
    , "f", &.{ interp.i32Value(6), interp.i32Value(7) });
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(v));
}

test "assembles a nested folded expression with a const" {
    const v = try assembleAndRun(
        \\(module (func (export "g") (param $x i32) (result i32)
        \\  (i32.sub (i32.mul (local.get $x) (i32.const 3)) (i32.const 1))))
    , "g", &.{interp.i32Value(10)});
    try std.testing.expectEqual(@as(i32, 29), interp.asI32(v));
}

test "top-level export and a two-function module" {
    const v = try assembleAndRun(
        \\(module
        \\  (func $dbl (param $x i32) (result i32) (i32.add (local.get $x) (local.get $x)))
        \\  (func $quad (param $x i32) (result i32) (call $dbl (call $dbl (local.get $x))))
        \\  (export "quad" (func $quad)))
    , "quad", &.{interp.i32Value(5)});
    try std.testing.expectEqual(@as(i32, 20), interp.asI32(v));
}
