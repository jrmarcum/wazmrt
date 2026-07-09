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
const DataSeg = struct { offset: i64, bytes: []const u8 };
/// A function type (for the type section): params → results.
const Sig = struct { params: []const V, results: []const V };

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
    var datas: List(DataSeg) = .empty;
    var mem_min: ?u32 = null;
    var mem_max: ?u32 = null;

    // Pass 1: collect definitions and resolve function indices (MVP: no imports).
    const start: usize = if (module.len > 1 and isId(module[1])) 2 else 1; // skip optional module $name
    for (module[start..]) |field| {
        const kw = field.keyword() orelse return error.BadModuleField;
        const items = field.asList().?;
        if (std.mem.eql(u8, kw, "func")) {
            const f = try parseFunc(a, items);
            const idx: u32 = @intCast(funcs.items.len);
            for (f.exports.items) |name| try exports.append(a, .{ .name = name, .kind = 0, .index = idx });
            try funcs.append(a, f);
            try func_names.append(a, f.name);
        } else if (std.mem.eql(u8, kw, "export")) {
            // (export "name" (func|memory $id|N))
            const name = items[1].string;
            const target = items[2].asList().?;
            const tkw = target[0].asAtom().?;
            const kind: u8 = if (std.mem.eql(u8, tkw, "memory")) 2 else 0;
            const idx: u32 = if (kind == 2) 0 else try resolveByName(func_names.items, target[1]);
            try exports.append(a, .{ .name = name, .kind = kind, .index = idx });
        } else if (std.mem.eql(u8, kw, "memory")) {
            var mi: usize = 1;
            if (mi < items.len and isId(items[mi])) mi += 1; // optional $name
            while (mi < items.len and items[mi].keyword() != null) : (mi += 1) {
                if (std.mem.eql(u8, items[mi].keyword().?, "export"))
                    try exports.append(a, .{ .name = items[mi].asList().?[1].string, .kind = 2, .index = 0 });
            }
            mem_min = try parseIndex(items[mi]);
            if (mi + 1 < items.len) mem_max = try parseIndex(items[mi + 1]);
        } else if (std.mem.eql(u8, kw, "data")) {
            // (data offset-expr "bytes"…)  — active, memory 0
            var bytes: List(u8) = .empty;
            for (items[2..]) |it| {
                if (it.asAtom() == null) switch (it) {
                    .string => |sbytes| try bytes.appendSlice(a, sbytes),
                    else => {},
                };
            }
            try datas.append(a, .{ .offset = try extractI32Const(items[1]), .bytes = bytes.items });
        } else {
            // Ignore other fields for now (type/global/table/start/elem…).
        }
    }

    // Intern function signatures, then pre-encode bodies (which may intern more
    // signatures for multi-value block types), so the type section — emitted
    // first but computed last — includes them all.
    var sigs: List(Sig) = .empty;
    var func_type: List(u32) = .empty;
    for (funcs.items) |f| try func_type.append(a, try internSig(a, &sigs, f.params.items, f.results.items));

    var bodies: List([]const u8) = .empty;
    for (funcs.items) |f| try bodies.append(a, try encodeBody(a, f, func_names.items, &sigs));

    var out: List(u8) = .empty;
    try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }); // header

    // Type section (1) — complete (function sigs + multi-value block-type sigs)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, sigs.items.len);
        for (sigs.items) |sig| {
            try s.append(a, 0x60);
            try valTypeVec(a, &s, sig.params);
            try valTypeVec(a, &s, sig.results);
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
    // Memory section (5)
    if (mem_min) |mn| {
        var s: List(u8) = .empty;
        try uleb(a, &s, 1);
        if (mem_max) |mx| {
            try s.append(a, 0x01);
            try uleb(a, &s, mn);
            try uleb(a, &s, mx);
        } else {
            try s.append(a, 0x00);
            try uleb(a, &s, mn);
        }
        try emitSection(a, &out, 5, s.items);
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
    // Code section (10) — pre-encoded bodies
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, bodies.items.len);
        for (bodies.items) |body| {
            try uleb(a, &s, body.len);
            try s.appendSlice(a, body);
        }
        try emitSection(a, &out, 10, s.items);
    }
    // Data section (11)
    if (datas.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, datas.items.len);
        for (datas.items) |seg| {
            try s.append(a, 0x00); // active, memory 0
            try s.append(a, @intFromEnum(Op.i32_const)); // offset const-expr
            try sleb(a, &s, seg.offset);
            try s.append(a, @intFromEnum(Op.end));
            try uleb(a, &s, seg.bytes.len);
            try s.appendSlice(a, seg.bytes);
        }
        try emitSection(a, &out, 11, s.items);
    }

    return out.items;
}

/// Extract the constant from a data-segment offset form: `(i32.const N)` or
/// `(offset (i32.const N))`.
fn extractI32Const(form: Sexpr) Error!i64 {
    const list = form.asList() orelse return error.BadImmediate;
    const kw = list[0].asAtom() orelse return error.BadImmediate;
    if (std.mem.eql(u8, kw, "offset")) return extractI32Const(list[1]);
    if (std.mem.eql(u8, kw, "i32.const")) return parseWatI32(list[1]);
    return error.UnsupportedInstr;
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
    /// Shared type section — multi-value block types intern their signatures here.
    sigs: *List(Sig),
    /// Control-flow label stack (innermost last), for resolving `br $name` to a
    /// relative depth.
    labels: List(?[]const u8) = .empty,
};

fn encodeBody(a: std.mem.Allocator, f: Func, func_names: []const ?[]const u8, sigs: *List(Sig)) Error![]const u8 {
    var body: List(u8) = .empty;
    // Locals vector: one (count=1, type) group per declared local.
    try uleb(a, &body, f.locals.items.len);
    for (f.locals.items) |t| {
        try uleb(a, &body, 1);
        try body.append(a, @intFromEnum(t));
    }
    var ctx: Ctx = .{ .a = a, .out = &body, .local_names = f.local_names.items, .func_names = func_names, .sigs = sigs };
    try emitSeq(&ctx, f.body);
    try body.append(a, @intFromEnum(Op.end)); // implicit function end
    return body.items;
}

/// Emit a sequence of instruction forms (folded lists and/or flat atoms).
fn emitSeq(ctx: *Ctx, items: []const Sexpr) Error!void {
    var i: usize = 0;
    while (i < items.len) i = try emitOne(ctx, items, i);
}

/// Emit one instruction (flat or folded) starting at `items[i]`; return the
/// index of the next instruction.
fn emitOne(ctx: *Ctx, items: []const Sexpr, i: usize) Error!usize {
    return switch (items[i]) {
        .list => |l| emitFoldedOne(ctx, l, i),
        .atom => |name| emitFlatOne(ctx, items, i, name),
        .string => error.UnknownInstr,
    };
}

fn emitExpr(ctx: *Ctx, s: Sexpr) Error!void {
    var one = [_]Sexpr{s};
    _ = try emitOne(ctx, &one, 0);
}

fn emitFoldedOne(ctx: *Ctx, l: []const Sexpr, i: usize) Error!usize {
    const kw = l[0].asAtom() orelse return error.UnknownInstr;
    const op = lookupOp(kw) orelse return error.UnknownInstr;
    switch (op) {
        .block, .loop => try emitFoldedBlock(ctx, op, l),
        .@"if" => try emitFoldedIf(ctx, l),
        .select => try emitFoldedSelect(ctx, l),
        else => try emitFoldedPlain(ctx, op, l),
    }
    return i + 1;
}

/// `(select (result t)* operand*)` — a `(result …)` annotation means typed select.
fn emitFoldedSelect(ctx: *Ctx, l: []const Sexpr) Error!void {
    var j: usize = 1;
    var tys: List(V) = .empty;
    while (j < l.len and eqKw(l[j], "result")) : (j += 1) try parseDecls(ctx.a, l[j].asList().?, &tys, null);
    while (j < l.len) j = try emitOne(ctx, l, j); // operands
    try emitSelect(ctx, tys.items);
}

fn emitSelect(ctx: *Ctx, tys: []const V) Error!void {
    if (tys.len == 0) {
        try ctx.out.append(ctx.a, @intFromEnum(Op.select));
    } else {
        try ctx.out.append(ctx.a, @intFromEnum(Op.select_t));
        try uleb(ctx.a, ctx.out, tys.len);
        for (tys) |t| try ctx.out.append(ctx.a, @intFromEnum(t));
    }
}

fn eqKw(s: Sexpr, kw: []const u8) bool {
    return if (s.keyword()) |k| std.mem.eql(u8, k, kw) else false;
}

/// A plain folded instruction: `(op imm* operand*)` — operands emitted first.
fn emitFoldedPlain(ctx: *Ctx, op: Op, l: []const Sexpr) Error!void {
    var i: usize = 1;
    const imm_start = i;
    while (i < l.len and l[i].asAtom() != null) i += 1;
    const immediates = l[imm_start..i];
    while (i < l.len) i = try emitOne(ctx, l, i); // operand sub-expressions
    try emitInstr(ctx, op, immediates);
}

/// `(block|loop $label? blocktype? instr*)`
fn emitFoldedBlock(ctx: *Ctx, op: Op, l: []const Sexpr) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(op));
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    try emitBlockTypeSig(ctx, try parseBlockTypeSig(ctx, l, &j));
    try ctx.labels.append(ctx.a, label);
    try emitSeq(ctx, l[j..]);
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// `(if $label? blocktype? cond? (then instr*) (else instr*)?)`
fn emitFoldedIf(ctx: *Ctx, l: []const Sexpr) Error!void {
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    const bt = try parseBlockTypeSig(ctx, l, &j);

    // An optional folded condition precedes `(then …)`; emit it first.
    if (j < l.len) {
        if (l[j].keyword()) |kw| {
            if (!std.mem.eql(u8, kw, "then") and !std.mem.eql(u8, kw, "else")) {
                try emitExpr(ctx, l[j]);
                j += 1;
            }
        }
    }
    if (j >= l.len) return error.BadImmediate;
    const then_form = l[j].asList() orelse return error.BadImmediate;
    j += 1;
    const else_form: ?[]const Sexpr = if (j < l.len) l[j].asList() else null;

    try ctx.out.append(ctx.a, @intFromEnum(Op.@"if"));
    try emitBlockTypeSig(ctx, bt);
    try ctx.labels.append(ctx.a, label);
    try emitSeq(ctx, then_form[1..]);
    if (else_form) |ef| {
        try ctx.out.append(ctx.a, @intFromEnum(Op.@"else"));
        try emitSeq(ctx, ef[1..]);
    }
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// A flat instruction at `items[i]` (`name` is its atom); return the next index.
fn emitFlatOne(ctx: *Ctx, items: []const Sexpr, i: usize, name: []const u8) Error!usize {
    const op = lookupOp(name) orelse return error.UnknownInstr;
    switch (op) {
        .block, .loop, .@"if" => {
            try ctx.out.append(ctx.a, @intFromEnum(op));
            var j = i + 1;
            const label = parseOptLabel(items, &j);
            try emitBlockTypeSig(ctx, try parseBlockTypeSig(ctx, items, &j));
            try ctx.labels.append(ctx.a, label);
            return j;
        },
        .@"else" => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.@"else"));
            return i + 1;
        },
        .end => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.end));
            if (ctx.labels.items.len != 0) _ = ctx.labels.pop();
            return i + 1;
        },
        .br_table => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.br_table));
            var j = i + 1;
            var labels: List(Sexpr) = .empty;
            while (j < items.len and items[j].asAtom() != null) : (j += 1) {
                try labels.append(ctx.a, items[j]);
            }
            try emitBrTable(ctx, labels.items);
            return j;
        },
        .select => {
            var j = i + 1;
            var tys: List(V) = .empty;
            while (j < items.len and eqKw(items[j], "result")) : (j += 1) try parseDecls(ctx.a, items[j].asList().?, &tys, null);
            try emitSelect(ctx, tys.items);
            return j;
        },
        else => {
            var buf: [4]Sexpr = undefined;
            var n: usize = 0;
            var j = i + 1;
            if (opcode.immediateKind(op) == .mem) {
                while (j < items.len and n < buf.len) : (j += 1) {
                    const atom = items[j].asAtom() orelse break;
                    if (!std.mem.startsWith(u8, atom, "offset=") and !std.mem.startsWith(u8, atom, "align=")) break;
                    buf[n] = items[j];
                    n += 1;
                }
            } else {
                for (0..flatImmCount(op)) |_| {
                    if (j >= items.len) return error.BadImmediate;
                    buf[n] = items[j];
                    n += 1;
                    j += 1;
                }
            }
            try emitInstr(ctx, op, buf[0..n]);
            return j;
        },
    }
}

fn parseOptLabel(l: []const Sexpr, j: *usize) ?[]const u8 {
    if (j.* < l.len) {
        if (l[j.*].asAtom()) |atom| {
            if (atom.len != 0 and atom[0] == '$') {
                j.* += 1;
                return atom;
            }
        }
    }
    return null;
}

/// Parse a block type — consecutive `(param …)` / `(result …)` forms → a `Sig`.
fn parseBlockTypeSig(ctx: *Ctx, l: []const Sexpr, j: *usize) Error!Sig {
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j.* < l.len) {
        const kw = l[j.*].keyword() orelse break;
        if (std.mem.eql(u8, kw, "param")) {
            try parseDecls(ctx.a, l[j.*].asList().?, &params, null);
        } else if (std.mem.eql(u8, kw, "result")) {
            try parseDecls(ctx.a, l[j.*].asList().?, &results, null);
        } else break; // `(type …)` block-type references are deferred
        j.* += 1;
    }
    return .{ .params = params.items, .results = results.items };
}

/// Emit a block type: empty → `0x40`; a single result → the value-type byte;
/// anything with params or multiple results → a type index (interned).
fn emitBlockTypeSig(ctx: *Ctx, sig: Sig) Error!void {
    if (sig.params.len == 0 and sig.results.len == 0) {
        try ctx.out.append(ctx.a, 0x40);
    } else if (sig.params.len == 0 and sig.results.len == 1) {
        try ctx.out.append(ctx.a, @intFromEnum(sig.results[0]));
    } else {
        try sleb(ctx.a, ctx.out, try internSig(ctx.a, ctx.sigs, sig.params, sig.results));
    }
}

fn emitBrTable(ctx: *Ctx, labels: []const Sexpr) Error!void {
    if (labels.len == 0) return error.BadImmediate; // needs at least a default
    try uleb(ctx.a, ctx.out, labels.len - 1);
    for (labels[0 .. labels.len - 1]) |lab| try uleb(ctx.a, ctx.out, try resolveLabel(ctx, lab));
    try uleb(ctx.a, ctx.out, try resolveLabel(ctx, labels[labels.len - 1]));
}

fn emitInstr(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(op));
    switch (opcode.immediateKind(op)) {
        .none => {},
        .local => try uleb(ctx.a, ctx.out, try resolveLocal(ctx, try imm0(immediates))),
        .global => try uleb(ctx.a, ctx.out, try parseIndex(try imm0(immediates))),
        .func => try uleb(ctx.a, ctx.out, try resolveFunc(ctx, try imm0(immediates))),
        .label => try uleb(ctx.a, ctx.out, try resolveLabel(ctx, try imm0(immediates))),
        .i32c => try sleb(ctx.a, ctx.out, try parseWatI32(try imm0(immediates))),
        .i64c => try sleb(ctx.a, ctx.out, try parseWatI64(try imm0(immediates))),
        .f32c => try floatBits(ctx, u32, try imm0(immediates)),
        .f64c => try floatBits(ctx, u64, try imm0(immediates)),
        .mem => try emitMemArg(ctx, op, immediates),
        .mem_reserved => try ctx.out.append(ctx.a, 0x00),
        .br_table => try emitBrTable(ctx, immediates),
        else => return error.UnsupportedInstr, // block_type (handled structurally), call_indirect
    }
}

fn resolveLabel(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        var k = ctx.labels.items.len;
        while (k > 0) {
            k -= 1;
            if (ctx.labels.items[k]) |nm| {
                if (std.mem.eql(u8, nm, atom)) return @intCast(ctx.labels.items.len - 1 - k);
            }
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn emitMemArg(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    var offset: u64 = 0;
    var align_log2: u32 = naturalAlign(op);
    for (immediates) |imm| {
        const atom = imm.asAtom() orelse continue;
        if (std.mem.startsWith(u8, atom, "offset=")) {
            offset = std.fmt.parseInt(u64, atom[7..], 0) catch return error.BadImmediate;
        } else if (std.mem.startsWith(u8, atom, "align=")) {
            const bytes = std.fmt.parseInt(u32, atom[6..], 0) catch return error.BadImmediate;
            align_log2 = @ctz(bytes);
        }
    }
    try uleb(ctx.a, ctx.out, align_log2);
    try uleb(ctx.a, ctx.out, offset);
}

/// Natural alignment (log2 of the access size) for a load/store opcode.
fn naturalAlign(op: Op) u32 {
    return switch (op) {
        .i32_load8_s, .i32_load8_u, .i64_load8_s, .i64_load8_u, .i32_store8, .i64_store8 => 0,
        .i32_load16_s, .i32_load16_u, .i64_load16_s, .i64_load16_u, .i32_store16, .i64_store16 => 1,
        .i32_load, .f32_load, .i32_store, .f32_store, .i64_load32_s, .i64_load32_u, .i64_store32 => 2,
        .i64_load, .f64_load, .i64_store, .f64_store => 3,
        else => 0,
    };
}

fn imm0(immediates: []const Sexpr) Error!Sexpr {
    if (immediates.len == 0) return error.BadImmediate;
    return immediates[0];
}

/// How many flat immediate atoms an opcode consumes (MVP-supported kinds).
fn flatImmCount(op: Op) usize {
    return switch (opcode.immediateKind(op)) {
        .local, .global, .func, .label, .i32c, .i64c, .f32c, .f64c => 1,
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

fn internSig(a: std.mem.Allocator, sigs: *List(Sig), params: []const V, results: []const V) Error!u32 {
    for (sigs.items, 0..) |sig, i| {
        if (std.mem.eql(V, sig.params, params) and std.mem.eql(V, sig.results, results)) return @intCast(i);
    }
    try sigs.append(a, .{ .params = params, .results = results });
    return @intCast(sigs.items.len - 1);
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

test "assembles a folded if/else" {
    const src =
        \\(module (func (export "sel") (param $c i32) (result i32)
        \\  (if (result i32) (local.get $c) (then (i32.const 111)) (else (i32.const 222)))))
    ;
    try std.testing.expectEqual(@as(i32, 111), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 222), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(0)})));
}

test "assembles a loop with named labels (sum 1..n)" {
    const src =
        \\(module (func (export "sum") (param $n i32) (result i32) (local $acc i32)
        \\  (block $done
        \\    (loop $lp
        \\      (br_if $done (i32.eqz (local.get $n)))
        \\      (local.set $acc (i32.add (local.get $acc) (local.get $n)))
        \\      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        \\      (br $lp)))
        \\  (local.get $acc)))
    ;
    try std.testing.expectEqual(@as(i32, 15), interp.asI32(try assembleAndRun(src, "sum", &.{interp.i32Value(5)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "sum", &.{interp.i32Value(0)})));
}

test "assembles flat block + br + end" {
    const src =
        \\(module (func (export "b") (result i32)
        \\  block (result i32)
        \\    i32.const 42
        \\    br 0
        \\  end))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "b", &.{})));
}

test "assembles memory + store/load (memarg)" {
    const src =
        \\(module (memory 1)
        \\  (func (export "rt") (param $x i32) (result i32)
        \\    (i32.store (i32.const 0) (local.get $x))
        \\    (i32.load (i32.const 0))))
    ;
    const v = try assembleAndRun(src, "rt", &.{interp.i32Value(0x12345678)});
    try std.testing.expectEqual(@as(u32, 0x12345678), @as(u32, @bitCast(interp.asI32(v))));
}

test "assembles an active data segment" {
    const src =
        \\(module (memory 1)
        \\  (data (i32.const 0) "\ef\be\ad\de")
        \\  (func (export "get") (result i32) (i32.load (i32.const 0))))
    ;
    const v = try assembleAndRun(src, "get", &.{});
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), @as(u32, @bitCast(interp.asI32(v))));
}

test "assembles a typed select" {
    const src =
        \\(module (func (export "sel") (param i32 i32 i32) (result i32)
        \\  (select (result i32) (local.get 0) (local.get 1) (local.get 2))))
    ;
    try std.testing.expectEqual(@as(i32, 10), interp.asI32(try assembleAndRun(src, "sel", &.{ interp.i32Value(10), interp.i32Value(20), interp.i32Value(1) })));
    try std.testing.expectEqual(@as(i32, 20), interp.asI32(try assembleAndRun(src, "sel", &.{ interp.i32Value(10), interp.i32Value(20), interp.i32Value(0) })));
}

test "assembles a multi-value block type" {
    // (block (param i32) (result i32) …) — a block that consumes and produces a value.
    const src =
        \\(module (func (export "mv") (param i32) (result i32)
        \\  (local.get 0)
        \\  (block (param i32) (result i32) (i32.add (i32.const 1)))))
    ;
    try std.testing.expectEqual(@as(i32, 6), interp.asI32(try assembleAndRun(src, "mv", &.{interp.i32Value(5)})));
}

test "assembles multi-value function results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module (func (export "swap") (param i32 i32) (result i32 i32)
        \\  (local.get 1) (local.get 0)))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    const r = try inst.invoke("swap", &.{ interp.i32Value(3), interp.i32Value(7) });
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(r[0]));
    try std.testing.expectEqual(@as(i32, 3), interp.asI32(r[1]));
}
