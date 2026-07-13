//! WAT text → wasm binary assembler (the reverse of `Module.decode`).
//!
//! Parses a `(module …)` S-expression (via `sexpr.zig`) and encodes it to a
//! WebAssembly binary that the decoder/validator/interpreter consume. It reuses
//! `opcode.zig` as the single instruction authority: instruction names map to
//! `Op` via `stringToEnum` (dots → underscores), and each operand is encoded per
//! `opcode.immediateKind`.
//!
//! **Scope today:** `(func …)` with named/anonymous params/results/locals, inline
//! and top-level `(export …)`, the full non-control instruction set, structured
//! control flow (`block`/`loop`/`if`, `br*`) with single-result/multi-value/
//! type-index block types, memory + data, tables (funcref/externref) + `elem` +
//! `call_indirect`, the reference-type table ops (`table.get`/`.set`/`.size`/
//! `.grow`/`.fill`), globals (`(global (mut? t) init)`, incl. imported globals +
//! extended-const inits, `global.get`/`.set`), and reference types
//! (`ref.null`/`ref.is_null`/`ref.func`, `(ref null? func|extern)`) — in both
//! folded `(i32.add (local.get 0) (local.get 1))` and flat forms. Deferred:
//! `start`, imported functions/tables/memories, `table.init`/`.copy`.

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
    /// `(type $t)` reference, if the function declares its type by index.
    type_ref: ?Sexpr = null,
    /// Inline import (`(func $id (import "m" "n") typeuse)`) — no body.
    import: ?struct { module: []const u8, name: []const u8 } = null,
    /// Body instruction forms (everything after the param/result/local headers).
    body: []const Sexpr = &.{},
};

/// An imported function (top-level `(import "m" "n" (func …))` or inline
/// `(func (import "m" "n") …)`); its type is `type_ref` or the inline sig.
const ImportedFunc = struct { module: []const u8, name: []const u8, type_ref: ?Sexpr, params: []const V, results: []const V };

const ExportDef = struct { name: []const u8, kind: u8, index: u32 };
/// A parsed data segment: `offset_form == null` is passive; otherwise active
/// (at `mem_index`, always 0 — the single supported memory) with that offset
/// const-expr. `offset_form` may be `(offset …)`, a folded `(i32.const …)`, or
/// `(global.get …)`.
const DataSeg = struct { mem_index: u32, offset_form: ?Sexpr, bytes: []const u8 };
/// A function type (for the type section): params → results.
const Sig = struct { params: []const V, results: []const V };
const TableDef = struct { min: u32, max: ?u32, elem: V = .funcref };
/// An element segment. `funcs` (func-index form) OR `exprs` (const-expr form) —
/// exactly one is non-empty. `offset` applies only to active segments.
const ElemDef = struct {
    mode: enum { active, passive, declarative },
    table_index: u32,
    /// Offset const-expr form for active segments (null → implicit `i32.const 0`).
    offset_form: ?Sexpr,
    elem_type: V,
    expr_form: bool,
    funcs: []const Sexpr,
    exprs: []const Sexpr,
};
/// A defined global: its value type, mutability, and (unencoded) init
/// const-expr — a *sequence* of instruction forms (usually one folded expr, but
/// a malformed module may list several, which validation then rejects on arity).
const GlobalDef = struct { valtype: V, mutable: bool, init: []const Sexpr };
/// An imported global (`(global (import "m" "n") type)`).
const ImportedGlobal = struct { module: []const u8, name: []const u8, valtype: V, mutable: bool };
const ImportedTable = struct { module: []const u8, name: []const u8, min: u32, max: ?u32, elem: V };
const ImportedMemory = struct { module: []const u8, name: []const u8, min: u32, max: ?u32 };

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
    var tables: List(TableDef) = .empty;
    var table_names: List(?[]const u8) = .empty;
    var elems: List(ElemDef) = .empty;
    var elem_names: List(?[]const u8) = .empty;
    var sigs: List(Sig) = .empty;
    var type_names: List(?[]const u8) = .empty;
    var globals: List(GlobalDef) = .empty;
    var global_imports: List(ImportedGlobal) = .empty;
    var table_imports: List(ImportedTable) = .empty;
    var mem_imports: List(ImportedMemory) = .empty;
    var global_names: List(?[]const u8) = .empty;
    var func_imports: List(ImportedFunc) = .empty;
    var mem_min: ?u32 = null;
    var mem_max: ?u32 = null;
    var start_ref: ?Sexpr = null;

    const start: usize = if (module.len > 1 and isId(module[1])) 2 else 1; // skip optional module $name

    // Pre-pass: `(type …)` definitions occupy the first type indices, in order.
    for (module[start..]) |field| {
        if (std.mem.eql(u8, field.keyword() orelse continue, "type"))
            try parseTypeDef(a, field.asList().?, &sigs, &type_names);
    }

    // Pass 1: collect the remaining definitions (MVP: no imports).
    for (module[start..]) |field| {
        const kw = field.keyword() orelse return error.BadModuleField;
        const items = field.asList().?;
        if (std.mem.eql(u8, kw, "func")) {
            const f = try parseFunc(a, items);
            const idx: u32 = @intCast(func_names.items.len); // func-space index (imports first)
            for (f.exports.items) |name| try exports.append(a, .{ .name = name, .kind = 0, .index = idx });
            if (f.import) |m| {
                try func_imports.append(a, .{ .module = m.module, .name = m.name, .type_ref = f.type_ref, .params = f.params.items, .results = f.results.items });
            } else {
                try funcs.append(a, f);
            }
            try func_names.append(a, f.name);
        } else if (std.mem.eql(u8, kw, "export")) {
            // (export "name" (func|table|memory|global $id|N))
            const name = items[1].string;
            const target = items[2].asList().?;
            const tkw = target[0].asAtom().?;
            const kind: u8 = if (std.mem.eql(u8, tkw, "func")) 0 else if (std.mem.eql(u8, tkw, "table")) 1 else if (std.mem.eql(u8, tkw, "memory")) 2 else if (std.mem.eql(u8, tkw, "global")) 3 else return error.BadModuleField;
            const idx: u32 = switch (kind) {
                0 => try resolveByName(func_names.items, target[1]),
                1 => try resolveByName(table_names.items, target[1]),
                2 => 0, // single memory
                3 => try resolveByName(global_names.items, target[1]),
                else => unreachable,
            };
            try exports.append(a, .{ .name = name, .kind = kind, .index = idx });
        } else if (std.mem.eql(u8, kw, "global")) {
            try parseGlobal(a, items, &globals, &global_imports, &global_names, &exports);
        } else if (std.mem.eql(u8, kw, "memory")) {
            var mi: usize = 1;
            if (mi < items.len and isId(items[mi])) mi += 1; // optional $name
            while (mi < items.len and eqKw(items[mi], "export")) : (mi += 1)
                try exports.append(a, .{ .name = items[mi].asList().?[1].string, .kind = 2, .index = 0 });
            if (mi < items.len and eqKw(items[mi], "import")) {
                // (memory (export …)* (import "m" "n") min max?)
                const imp = items[mi].asList().?;
                mi += 1;
                const mmin = try parseIndex(items[mi]);
                const mmax: ?u32 = if (mi + 1 < items.len) try parseIndex(items[mi + 1]) else null;
                try mem_imports.append(a, .{ .module = imp[1].string, .name = imp[2].string, .min = mmin, .max = mmax });
            } else if (mi < items.len and eqKw(items[mi], "data")) {
                // (memory (data "…")) — size the memory to the bytes and append an
                // active data segment at offset 0.
                var bytes: List(u8) = .empty;
                for (items[mi].asList().?[1..]) |it| switch (it) {
                    .string => |sbytes| try bytes.appendSlice(a, sbytes),
                    else => {},
                };
                const pages: u32 = @intCast((bytes.items.len + 65535) / 65536);
                mem_min = pages;
                mem_max = pages;
                const off = try a.alloc(Sexpr, 2);
                off[0] = .{ .atom = "i32.const" };
                off[1] = .{ .atom = "0" };
                try datas.append(a, .{ .mem_index = 0, .offset_form = .{ .list = off }, .bytes = bytes.items });
            } else {
                mem_min = try parseIndex(items[mi]);
                if (mi + 1 < items.len) mem_max = try parseIndex(items[mi + 1]);
            }
        } else if (std.mem.eql(u8, kw, "data")) {
            // (data $id? (memory idx)? offset-expr? "bytes"…) — active when an
            // offset is present, else passive. Only memory 0 is supported, so a
            // `(memory …)` prefix is parsed but folds to index 0.
            var di: usize = 1;
            if (di < items.len and isId(items[di])) di += 1; // $id
            if (di < items.len) if (items[di].asList()) |l| {
                if (l.len >= 1 and eqAtom(l[0], "memory")) di += 1; // (memory idx) — single memory
            };
            // The offset is any leading list (`(offset …)` or a folded const-expr
            // like `(i32.const N)` / `(global.get $g)` — even a malformed one, so
            // the validator can reject it); data bytes are always strings. Absent
            // → passive.
            var offset_form: ?Sexpr = null;
            if (di < items.len and items[di].asList() != null) {
                offset_form = items[di];
                di += 1;
            }
            var bytes: List(u8) = .empty;
            for (items[di..]) |it| switch (it) {
                .string => |sbytes| try bytes.appendSlice(a, sbytes),
                else => {},
            };
            try datas.append(a, .{ .mem_index = 0, .offset_form = offset_form, .bytes = bytes.items });
        } else if (std.mem.eql(u8, kw, "table")) {
            // Inline import `(table $id? (export …)* (import "m" "n") min max? reftype)`
            // is handled here; a defined table goes to `parseTable`.
            var ti: usize = 1;
            var tname: ?[]const u8 = null;
            if (ti < items.len and isId(items[ti])) {
                tname = items[ti].atom;
                ti += 1;
            }
            const exp_start = ti;
            while (ti < items.len and eqKw(items[ti], "export")) ti += 1;
            if (ti < items.len and eqKw(items[ti], "import")) {
                const imp = items[ti].asList().?;
                const tidx: u32 = @intCast(table_names.items.len);
                for (items[exp_start..ti]) |ex|
                    try exports.append(a, .{ .name = ex.asList().?[1].string, .kind = 1, .index = tidx });
                ti += 1;
                const tmin = try parseIndex(items[ti]);
                ti += 1;
                var tmax: ?u32 = null;
                if (ti < items.len and !isRefType(items[ti])) {
                    tmax = try parseIndex(items[ti]);
                    ti += 1;
                }
                try table_imports.append(a, .{ .module = imp[1].string, .name = imp[2].string, .min = tmin, .max = tmax, .elem = try parseValType(items[ti]) });
                try table_names.append(a, tname);
            } else {
                try parseTable(a, items, &tables, &table_names, &elems, &elem_names);
            }
        } else if (std.mem.eql(u8, kw, "elem")) {
            try parseElem(a, items, &elems, &elem_names, table_names.items);
        } else if (std.mem.eql(u8, kw, "import")) {
            // (import "m" "n" (func …) | (global …)) — func + global imports.
            const desc = items[3].asList() orelse return error.BadModuleField;
            const dkw = desc[0].asAtom() orelse return error.BadModuleField;
            if (std.mem.eql(u8, dkw, "func")) {
                const f = try parseFunc(a, desc); // reuse: parses $id + typeuse
                try func_imports.append(a, .{ .module = items[1].string, .name = items[2].string, .type_ref = f.type_ref, .params = f.params.items, .results = f.results.items });
                try func_names.append(a, f.name);
            } else if (std.mem.eql(u8, dkw, "table")) {
                // (import "m" "n" (table $id? min max? reftype)) — imported tables
                // take the low table indices (before any defined table).
                var ti: usize = 1;
                var tname: ?[]const u8 = null;
                if (ti < desc.len and isId(desc[ti])) {
                    tname = desc[ti].atom;
                    ti += 1;
                }
                const tmin = try parseIndex(desc[ti]);
                ti += 1;
                var tmax: ?u32 = null;
                if (ti < desc.len and !isRefType(desc[ti])) {
                    tmax = try parseIndex(desc[ti]);
                    ti += 1;
                }
                try table_imports.append(a, .{ .module = items[1].string, .name = items[2].string, .min = tmin, .max = tmax, .elem = try parseValType(desc[ti]) });
                try table_names.append(a, tname);
            } else if (std.mem.eql(u8, dkw, "memory")) {
                // (import "m" "n" (memory $id? min max?)) — the single memory 0.
                var mi2: usize = 1;
                if (mi2 < desc.len and isId(desc[mi2])) mi2 += 1;
                const mmin = try parseIndex(desc[mi2]);
                mi2 += 1;
                const mmax: ?u32 = if (mi2 < desc.len) try parseIndex(desc[mi2]) else null;
                try mem_imports.append(a, .{ .module = items[1].string, .name = items[2].string, .min = mmin, .max = mmax });
            } else {
                try parseImport(a, items, &global_imports, &global_names); // global
            }
        } else if (std.mem.eql(u8, kw, "start")) {
            // (start $f | N) — resolve after the func index space is complete.
            if (items.len < 2) return error.BadModuleField;
            start_ref = items[1];
        } else {
            // `type` handled in the pre-pass.
        }
    }

    // Function type indices (`(type $t)` reference, else intern the inline sig),
    // then pre-encode bodies (which may intern block-type sigs / resolve
    // call_indirect type refs), so the type section is complete before emit.
    // Imported-function type indices (for the import section).
    var func_import_type: List(u32) = .empty;
    for (func_imports.items) |fi| {
        const ti = if (fi.type_ref) |tr| try resolveType(type_names.items, tr) else try internSig(a, &sigs, fi.params, fi.results);
        try func_import_type.append(a, ti);
    }

    var func_type: List(u32) = .empty;
    for (funcs.items) |*f| {
        const ti = if (f.type_ref) |tr| try resolveType(type_names.items, tr) else try internSig(a, &sigs, f.params.items, f.results.items);
        try func_type.append(a, ti);
        // A `(type $t)` reference supplies the params; when they aren't *also*
        // written inline, they still occupy the low local indices, so prepend
        // anonymous names to keep declared-local indices correct.
        if (f.type_ref != null and f.params.items.len == 0 and ti < sigs.items.len) {
            const params = sigs.items[ti].params;
            if (params.len != 0) {
                var names: List(?[]const u8) = .empty;
                for (params) |_| try names.append(a, null);
                try names.appendSlice(a, f.local_names.items);
                f.local_names = names;
            }
        }
    }

    var bodies: List([]const u8) = .empty;
    for (funcs.items) |f| try bodies.append(a, try encodeBody(a, f, func_names.items, &sigs, type_names.items, global_names.items, table_names.items, elem_names.items));

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
    // Import section (2) — imported functions, tables, memories, globals.
    const n_imports = func_imports.items.len + table_imports.items.len + mem_imports.items.len + global_imports.items.len;
    if (n_imports != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, n_imports);
        for (func_imports.items, func_import_type.items) |fi, ti| {
            try nameBytes(a, &s, fi.module);
            try nameBytes(a, &s, fi.name);
            try s.append(a, 0x00); // func import
            try uleb(a, &s, ti); // type index
        }
        for (table_imports.items) |t| {
            try nameBytes(a, &s, t.module);
            try nameBytes(a, &s, t.name);
            try s.append(a, 0x01); // table import
            try s.append(a, @intFromEnum(t.elem)); // element reftype
            try emitLimits(a, &s, t.min, t.max);
        }
        for (mem_imports.items) |m| {
            try nameBytes(a, &s, m.module);
            try nameBytes(a, &s, m.name);
            try s.append(a, 0x02); // memory import
            try emitLimits(a, &s, m.min, m.max);
        }
        for (global_imports.items) |g| {
            try nameBytes(a, &s, g.module);
            try nameBytes(a, &s, g.name);
            try s.append(a, 0x03); // global import
            try s.append(a, @intFromEnum(g.valtype));
            try s.append(a, if (g.mutable) 0x01 else 0x00);
        }
        try emitSection(a, &out, 2, s.items);
    }
    // Function section (3)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, func_type.items.len);
        for (func_type.items) |ti| try uleb(a, &s, ti);
        try emitSection(a, &out, 3, s.items);
    }
    // Table section (4)
    if (tables.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, tables.items.len);
        for (tables.items) |t| {
            try s.append(a, @intFromEnum(t.elem)); // element reftype (funcref / externref)
            try emitLimits(a, &s, t.min, t.max);
        }
        try emitSection(a, &out, 4, s.items);
    }
    // Memory section (5) — a *defined* memory only (an imported one lives in the
    // import section).
    if (mem_min) |mn| {
        var s: List(u8) = .empty;
        try uleb(a, &s, 1);
        try emitLimits(a, &s, mn, mem_max);
        try emitSection(a, &out, 5, s.items);
    }
    // Global section (6)
    if (globals.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, globals.items.len);
        for (globals.items) |g| {
            try s.append(a, @intFromEnum(g.valtype));
            try s.append(a, if (g.mutable) 0x01 else 0x00);
            try emitConstExpr(a, &s, &sigs, type_names.items, global_names.items, g.init);
        }
        try emitSection(a, &out, 6, s.items);
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
    // Start section (8) — the funcidx to run at instantiation.
    if (start_ref) |ref| {
        var s: List(u8) = .empty;
        try uleb(a, &s, try resolveByName(func_names.items, ref));
        try emitSection(a, &out, 8, s.items);
    }
    // Element section (9) — all 8 flag variants (active/passive/declarative ×
    // func-index/const-expr forms).
    if (elems.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, elems.items.len);
        for (elems.items) |e| {
            // flag bits: bit0 = passive/declarative, bit1 = declarative-or-explicit-table,
            // bit2 = const-expr form.
            const explicit_table = e.mode == .active and e.table_index != 0;
            var flag: u8 = 0;
            switch (e.mode) {
                .active => flag |= if (explicit_table) 0b010 else 0,
                .passive => flag |= 0b001,
                .declarative => flag |= 0b011,
            }
            if (e.expr_form) flag |= 0b100;
            try s.append(a, flag);
            if (explicit_table) try uleb(a, &s, e.table_index);
            if (e.mode == .active) try emitOffsetExpr(a, &s, &sigs, type_names.items, global_names.items, e.offset_form);
            // The leading kind byte: elemkind (0x00) for non-flag-0 func-index
            // variants, reftype for non-flag-4 const-expr variants.
            if (!e.expr_form and flag != 0) {
                try s.append(a, 0x00); // elemkind funcref
            } else if (e.expr_form and flag != 4) {
                try s.append(a, @intFromEnum(e.elem_type)); // reftype
            }
            if (e.expr_form) {
                try uleb(a, &s, e.exprs.len);
                for (e.exprs) |ex| try emitElementExpr(a, &s, &sigs, type_names.items, global_names.items, func_names.items, ex);
            } else {
                try uleb(a, &s, e.funcs.len);
                for (e.funcs) |ref| try uleb(a, &s, try resolveByName(func_names.items, ref));
            }
        }
        try emitSection(a, &out, 9, s.items);
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
            if (seg.offset_form == null) {
                try s.append(a, 0x01); // passive
            } else {
                try s.append(a, 0x00); // active, memory 0
                try emitOffsetExpr(a, &s, &sigs, type_names.items, global_names.items, seg.offset_form);
            }
            try uleb(a, &s, seg.bytes.len);
            try s.appendSlice(a, seg.bytes);
        }
        try emitSection(a, &out, 11, s.items);
    }

    return out.items;
}

// --- Module-field parsing --------------------------------------------------

/// `(type $name? (func (param …)(result …)))` — append the signature + name.
fn parseTypeDef(a: std.mem.Allocator, items: []const Sexpr, sigs: *List(Sig), type_names: *List(?[]const u8)) Error!void {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1;
    }
    const func_form = items[i].asList() orelse return error.BadModuleField;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    for (func_form[1..]) |part| {
        const kw = part.keyword() orelse continue;
        if (std.mem.eql(u8, kw, "param")) try parseDecls(a, part.asList().?, &params, null);
        if (std.mem.eql(u8, kw, "result")) try parseDecls(a, part.asList().?, &results, null);
    }
    try sigs.append(a, .{ .params = params.items, .results = results.items });
    try type_names.append(a, name);
}

/// `(table $name? reftype (elem …))` or `(table $name? <min> <max>? reftype)`,
/// where reftype is `funcref` / `externref` / `(ref null? …)`.
fn parseTable(a: std.mem.Allocator, items: []const Sexpr, tables: *List(TableDef), table_names: *List(?[]const u8), elems: *List(ElemDef), elem_names: *List(?[]const u8)) Error!void {
    const table_index: u32 = @intCast(tables.items.len);
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1;
    }
    try table_names.append(a, name);
    if (isRefType(items[i])) {
        // (table reftype (elem …))
        const et = try parseValType(items[i]);
        i += 1;
        if (i < items.len and eqKw(items[i], "elem")) {
            // Inline active elem at offset 0. Items are either bare func indices
            // (`(elem $f $g)`) or const-expr forms (`(elem (ref.func $f) …)`).
            const inner = items[i].asList().?[1..];
            const count: u32 = @intCast(inner.len);
            try tables.append(a, .{ .min = count, .max = count, .elem = et });
            if (inner.len != 0 and inner[0].asList() != null) {
                try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = inner });
            } else {
                try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = .funcref, .expr_form = false, .funcs = inner, .exprs = &.{} });
            }
            try elem_names.append(a, null);
        } else {
            try tables.append(a, .{ .min = 0, .max = null, .elem = et });
        }
    } else {
        const min = try parseIndex(items[i]);
        i += 1;
        var max: ?u32 = null;
        if (i < items.len and !isRefType(items[i])) {
            max = try parseIndex(items[i]);
            i += 1;
        }
        const et = try parseValType(items[i]);
        i += 1;
        try tables.append(a, .{ .min = min, .max = max, .elem = et });
        // Table initializer expression `(table N reftype initexpr)`: fill all N
        // slots with the value. We synthesize an active elem of N copies at
        // offset 0 — observably identical table state (a distinct 0x40 binary
        // encoding is not required for the execution assertions).
        if (i < items.len and items[i].asList() != null) {
            const init_expr = items[i];
            const copies = try a.alloc(Sexpr, min);
            for (copies) |*c| c.* = init_expr;
            try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = copies });
            try elem_names.append(a, null);
        }
    }
}

/// True if the form is a reference type: `funcref` / `externref` / `(ref …)`.
fn isRefType(s: Sexpr) bool {
    if (s.asList()) |l| return l.len >= 1 and eqAtom(l[0], "ref");
    return eqAtom(s, "funcref") or eqAtom(s, "externref");
}

/// `(elem $id? mode? tableuse? offset? kind item*)` — active / passive /
/// declarative, in either the func-index (`func $f …`) or const-expr
/// (`funcref (ref.func $f) …`) form.
fn parseElem(a: std.mem.Allocator, items: []const Sexpr, elems: *List(ElemDef), elem_names: *List(?[]const u8), table_names: []const ?[]const u8) Error!void {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1; // segment $id
    }
    try elem_names.append(a, name);
    var mode: @FieldType(ElemDef, "mode") = .passive;
    var table_index: u32 = 0;
    var offset_form: ?Sexpr = null;
    if (i < items.len and eqAtom(items[i], "declare")) {
        mode = .declarative;
        i += 1;
    } else {
        if (i < items.len and eqKw(items[i], "table")) {
            mode = .active;
            table_index = try resolveByName(table_names, items[i].asList().?[1]);
            i += 1;
        }
        if (i < items.len and isOffsetForm(items[i])) {
            mode = .active;
            offset_form = items[i];
            i += 1;
        }
    }
    // Kind: `func` (func-index form) or a reference type (const-expr form). An
    // absent kind keyword is the abbreviated func-index form.
    if (i < items.len and eqAtom(items[i], "func")) {
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = .funcref, .expr_form = false, .funcs = items[i + 1 ..], .exprs = &.{} });
    } else if (i < items.len and isRefType(items[i])) {
        const et = try parseValType(items[i]);
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = items[i + 1 ..] });
    } else {
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = .funcref, .expr_form = false, .funcs = items[i..], .exprs = &.{} });
    }
}

/// True if the form is an element-segment offset (`(offset …)` or a folded
/// const-expr like `(i32.const N)` / `(global.get $g)`) — distinct from a
/// `(ref …)` reftype and from a `(ref.func …)` element expression.
fn isOffsetForm(s: Sexpr) bool {
    const l = s.asList() orelse return false;
    const kw = l[0].asAtom() orelse return false;
    return std.mem.eql(u8, kw, "offset") or std.mem.eql(u8, kw, "i32.const") or std.mem.eql(u8, kw, "global.get");
}

/// `(global $name? (export "x")* (import "m" "n")? (mut? valtype) init-expr?)`.
fn parseGlobal(a: std.mem.Allocator, items: []const Sexpr, globals: *List(GlobalDef), global_imports: *List(ImportedGlobal), global_names: *List(?[]const u8), exports: *List(ExportDef)) Error!void {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1;
    }
    // The global-space index this entry will occupy (imports precede definitions).
    const idx: u32 = @intCast(global_names.items.len);
    while (i < items.len and eqKw(items[i], "export")) : (i += 1)
        try exports.append(a, .{ .name = items[i].asList().?[1].string, .kind = 3, .index = idx });
    // Optional inline import: `(import "module" "name")`.
    var imp: ?struct { module: []const u8, name: []const u8 } = null;
    if (i < items.len and eqKw(items[i], "import")) {
        const l = items[i].asList().?;
        imp = .{ .module = l[1].string, .name = l[2].string };
        i += 1;
    }
    // Global type: `valtype` or `(mut valtype)`.
    if (i >= items.len) return error.BadModuleField;
    var mutable = false;
    var valtype: V = undefined;
    if (items[i].asList()) |gt| {
        mutable = eqAtom(gt[0], "mut");
        valtype = try parseValType(gt[gt.len - 1]);
    } else {
        valtype = try parseValType(items[i]);
    }
    i += 1;
    if (imp) |m| {
        try global_imports.append(a, .{ .module = m.module, .name = m.name, .valtype = valtype, .mutable = mutable });
    } else {
        // The init is every remaining form (an empty sequence — a missing init —
        // encodes to a bare `end`, which validation rejects on arity).
        try globals.append(a, .{ .valtype = valtype, .mutable = mutable, .init = items[i..] });
    }
    try global_names.append(a, name);
}

/// Top-level `(import "m" "n" (global $id? (mut? valtype)))`. Only global imports
/// are assembled today; a func/table/memory import errors (honest, not silent).
fn parseImport(a: std.mem.Allocator, items: []const Sexpr, global_imports: *List(ImportedGlobal), global_names: *List(?[]const u8)) Error!void {
    const module = items[1].string;
    const name = items[2].string;
    const desc = items[3].asList() orelse return error.BadModuleField;
    const dkw = desc[0].asAtom() orelse return error.BadModuleField;
    if (!std.mem.eql(u8, dkw, "global")) return error.UnsupportedInstr; // func/table/memory imports
    var di: usize = 1;
    var gname: ?[]const u8 = null;
    if (di < desc.len and isId(desc[di])) {
        gname = desc[di].atom;
        di += 1;
    }
    var mutable = false;
    var valtype: V = undefined;
    if (desc[di].asList()) |gt| {
        mutable = eqAtom(gt[0], "mut");
        valtype = try parseValType(gt[gt.len - 1]);
    } else {
        valtype = try parseValType(desc[di]);
    }
    try global_imports.append(a, .{ .module = module, .name = name, .valtype = valtype, .mutable = mutable });
    try global_names.append(a, gname);
}

/// Emit an active segment's offset const-expr + `end`. Unwraps `(offset …)`,
/// accepts a folded const-expr (`(i32.const N)` / `(global.get $g)`), and emits
/// an implicit `i32.const 0` when no offset form is present.
fn emitOffsetExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, form: ?Sexpr) Error!void {
    if (form) |f| {
        if (f.asList()) |l| {
            if (l.len != 0 and eqAtom(l[0], "offset")) return emitConstExpr(a, out, sigs, type_names, global_names, l[1..]);
        }
        return emitConstExpr(a, out, sigs, type_names, global_names, &[_]Sexpr{f});
    }
    try out.append(a, @intFromEnum(Op.i32_const));
    try sleb(a, out, 0);
    try out.append(a, @intFromEnum(Op.end));
}

/// Emit one element-segment const-expr + `end`. Accepts a folded expr form
/// (`(ref.func $f)`) or an `(item …)` wrapper around an instruction sequence.
fn emitElementExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8, form: Sexpr) Error!void {
    var ctx: Ctx = .{ .a = a, .out = out, .local_names = &.{}, .func_names = func_names, .sigs = sigs, .type_names = type_names, .global_names = global_names };
    if (form.asList()) |l| {
        if (l.len != 0 and eqAtom(l[0], "item")) {
            try emitSeq(&ctx, l[1..]); // (item <instr seq>)
            try out.append(a, @intFromEnum(Op.end));
            return;
        }
    }
    try emitExpr(&ctx, form);
    try out.append(a, @intFromEnum(Op.end));
}

/// Emit a constant init expression (a sequence of instruction forms) + `end`.
fn emitConstExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, exprs: []const Sexpr) Error!void {
    var ctx: Ctx = .{ .a = a, .out = out, .local_names = &.{}, .func_names = &.{}, .sigs = sigs, .type_names = type_names, .global_names = global_names };
    try emitSeq(&ctx, exprs);
    try out.append(a, @intFromEnum(Op.end));
}

fn resolveType(type_names: []const ?[]const u8, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (type_names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn eqAtom(s: Sexpr, atom: []const u8) bool {
    return if (s.asAtom()) |a| std.mem.eql(u8, a, atom) else false;
}

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
        } else if (std.mem.eql(u8, kw, "import")) {
            f.import = .{ .module = list[1].string, .name = list[2].string }; // (import "m" "n")
        } else if (std.mem.eql(u8, kw, "type")) {
            f.type_ref = list[1]; // (type $t)
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
    // Reference type spelled as a list: `(ref null? func|extern)`.
    if (s.asList()) |l| {
        if (l.len >= 2 and eqAtom(l[0], "ref")) return heapTypeToValType(l[l.len - 1]);
        return error.BadValType;
    }
    const atom = s.asAtom() orelse return error.BadValType;
    return stringToValType(atom) orelse error.BadValType;
}

/// A heap type (`func` / `extern`, or the `funcref` / `externref` aliases) → the
/// corresponding reference value type.
fn heapTypeToValType(s: Sexpr) Error!V {
    const atom = s.asAtom() orelse return error.BadValType;
    if (std.mem.eql(u8, atom, "func") or std.mem.eql(u8, atom, "funcref")) return .funcref;
    if (std.mem.eql(u8, atom, "extern") or std.mem.eql(u8, atom, "externref")) return .externref;
    return error.BadValType;
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
    /// Named type definitions (index-aligned with the type section), for
    /// resolving `(type $t)` in `call_indirect` and type-index block types.
    type_names: []const ?[]const u8,
    /// Global names (index-aligned with the global index space), for resolving
    /// `global.get $g` / `global.set $g`.
    global_names: []const ?[]const u8,
    /// Table names (index-aligned with the table index space), for resolving the
    /// explicit table operand of `call_indirect $t`.
    table_names: []const ?[]const u8 = &.{},
    /// Element-segment names (index-aligned with the element index space), for
    /// resolving `$e` in `table.init` / `elem.drop`.
    elem_names: []const ?[]const u8 = &.{},
    /// Control-flow label stack (innermost last), for resolving `br $name` to a
    /// relative depth.
    labels: List(?[]const u8) = .empty,
};

fn encodeBody(a: std.mem.Allocator, f: Func, func_names: []const ?[]const u8, sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, table_names: []const ?[]const u8, elem_names: []const ?[]const u8) Error![]const u8 {
    var body: List(u8) = .empty;
    // Locals vector: one (count=1, type) group per declared local.
    try uleb(a, &body, f.locals.items.len);
    for (f.locals.items) |t| {
        try uleb(a, &body, 1);
        try body.append(a, @intFromEnum(t));
    }
    var ctx: Ctx = .{ .a = a, .out = &body, .local_names = f.local_names.items, .func_names = func_names, .sigs = sigs, .type_names = type_names, .global_names = global_names, .table_names = table_names, .elem_names = elem_names };
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
        .call_indirect => {
            const ann = try parseCallIndirectType(ctx, l, 1);
            var j = ann.next;
            while (j < l.len) j = try emitOne(ctx, l, j); // operands
            try emitCallIndirect(ctx, ann.idx, ann.table);
        },
        else => try emitFoldedPlain(ctx, op, l),
    }
    return i + 1;
}

/// Parse a `call_indirect` type annotation (`(type $t)` and/or inline
/// `(param)(result)`) from `items[start..]`; return its type index + next index.
fn parseCallIndirectType(ctx: *Ctx, items: []const Sexpr, start: usize) Error!struct { idx: u32, table: u32, next: usize } {
    var j = start;
    // Optional explicit table index/id — only when an atom is *followed by* a
    // `(type …)`/`(param …)`/`(result …)` annotation (`call_indirect $t (type …)`).
    // Otherwise a bare atom is the next instruction (e.g. flat `call_indirect select`).
    var table: u32 = 0;
    if (j + 1 < items.len and items[j].asAtom() != null and isTypeUse(items[j + 1])) {
        table = try resolveByName(ctx.table_names, items[j]);
        j += 1;
    }
    var type_ref: ?Sexpr = null;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j < items.len and items[j].keyword() != null) : (j += 1) {
        const kw = items[j].keyword().?;
        if (std.mem.eql(u8, kw, "type")) type_ref = items[j].asList().?[1] else if (std.mem.eql(u8, kw, "param")) try parseDecls(ctx.a, items[j].asList().?, &params, null) else if (std.mem.eql(u8, kw, "result")) try parseDecls(ctx.a, items[j].asList().?, &results, null) else break;
    }
    const idx = if (type_ref) |tr| try resolveType(ctx.type_names, tr) else try internSig(ctx.a, ctx.sigs, params.items, results.items);
    return .{ .idx = idx, .table = table, .next = j };
}

/// True if the form is a `call_indirect` type annotation: `(type …)` /
/// `(param …)` / `(result …)`.
fn isTypeUse(s: Sexpr) bool {
    const kw = s.keyword() orelse return false;
    return std.mem.eql(u8, kw, "type") or std.mem.eql(u8, kw, "param") or std.mem.eql(u8, kw, "result");
}

fn emitCallIndirect(ctx: *Ctx, type_index: u32, table: u32) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(Op.call_indirect));
    try uleb(ctx.a, ctx.out, type_index);
    try uleb(ctx.a, ctx.out, table);
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
        .call_indirect => {
            const ann = try parseCallIndirectType(ctx, items, i + 1);
            try emitCallIndirect(ctx, ann.idx, ann.table);
            return ann.next;
        },
        .table_get, .table_set, .table_grow, .table_size, .table_fill => {
            try emitOpcode(ctx, op);
            // Optional explicit table index/id; a `$name` or numeric atom (a
            // following instruction is never either), else default table 0.
            var j = i + 1;
            var t: u32 = 0;
            if (j < items.len) if (items[j].asAtom()) |atom| {
                if (atom.len != 0 and (atom[0] == '$' or std.ascii.isDigit(atom[0]))) {
                    t = try resolveByName(ctx.table_names, items[j]);
                    j += 1;
                }
            };
            try uleb(ctx.a, ctx.out, t);
            return j;
        },
        .table_init, .elem_drop, .table_copy => {
            // Consume the leading index atoms (0–2), then the bulk-op immediate
            // encoder (shared with the folded path) resolves + emits them.
            var idxs: [2]Sexpr = undefined;
            var n: usize = 0;
            var j = i + 1;
            while (j < items.len and n < 2 and isIndexAtom(items[j])) : (j += 1) {
                idxs[n] = items[j];
                n += 1;
            }
            try emitOpcode(ctx, op);
            try emitBulkTableImm(ctx, op, idxs[0..n]);
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

/// True if the s-expr is an index atom — a `$name` or a numeric literal — as
/// opposed to a folded operand list or a following instruction keyword.
fn isIndexAtom(s: Sexpr) bool {
    const atom = s.asAtom() orelse return false;
    return atom.len != 0 and (atom[0] == '$' or std.ascii.isDigit(atom[0]));
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

/// A parsed block type: either a `(type $t)` reference (`type_ref`) or an inline
/// `(param …)(result …)` signature.
const BlockTy = struct { type_ref: ?u32 = null, sig: Sig = .{ .params = &.{}, .results = &.{} } };

/// Parse a block type — a `(type $t)` reference and/or consecutive
/// `(param …)` / `(result …)` forms.
fn parseBlockTypeSig(ctx: *Ctx, l: []const Sexpr, j: *usize) Error!BlockTy {
    var type_ref: ?u32 = null;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j.* < l.len) {
        const kw = l[j.*].keyword() orelse break;
        if (std.mem.eql(u8, kw, "type")) {
            type_ref = try resolveType(ctx.type_names, l[j.*].asList().?[1]);
        } else if (std.mem.eql(u8, kw, "param")) {
            try parseDecls(ctx.a, l[j.*].asList().?, &params, null);
        } else if (std.mem.eql(u8, kw, "result")) {
            try parseDecls(ctx.a, l[j.*].asList().?, &results, null);
        } else break;
        j.* += 1;
    }
    return .{ .type_ref = type_ref, .sig = .{ .params = params.items, .results = results.items } };
}

/// Emit a block type: an explicit `(type $t)` reference → its type index; empty →
/// `0x40`; a single result → the value-type byte; params or multiple results →
/// an interned type index.
fn emitBlockTypeSig(ctx: *Ctx, bt: BlockTy) Error!void {
    if (bt.type_ref) |ti| {
        try sleb(ctx.a, ctx.out, ti);
        return;
    }
    const sig = bt.sig;
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

/// Emit an opcode's bytes: a `0xFC`-prefixed pair for table ops, else the single
/// enum byte.
fn emitOpcode(ctx: *Ctx, op: Op) Error!void {
    if (opcode.fcSubOpcode(op)) |sub| {
        try ctx.out.append(ctx.a, 0xfc);
        try uleb(ctx.a, ctx.out, sub);
    } else {
        try ctx.out.append(ctx.a, @intFromEnum(op));
    }
}

/// Emit the immediate operands of a bulk table op from its leading index atoms
/// (`idxs`, 0–2 of them). Text operand order differs from binary: `table.init`
/// is written `tableidx? elemidx` but encoded elem-then-table; `table.copy` is
/// `dst? src?` in both. Shared by the flat and folded emit paths.
fn emitBulkTableImm(ctx: *Ctx, op: Op, idxs: []const Sexpr) Error!void {
    switch (op) {
        .table_init => {
            if (idxs.len == 0) return error.BadImmediate;
            const table: u32 = if (idxs.len >= 2) try resolveByName(ctx.table_names, idxs[0]) else 0;
            const elem: u32 = try resolveByName(ctx.elem_names, idxs[idxs.len - 1]);
            try uleb(ctx.a, ctx.out, elem);
            try uleb(ctx.a, ctx.out, table);
        },
        .elem_drop => {
            if (idxs.len == 0) return error.BadImmediate;
            try uleb(ctx.a, ctx.out, try resolveByName(ctx.elem_names, idxs[0]));
        },
        .table_copy => {
            const dst: u32 = if (idxs.len >= 1) try resolveByName(ctx.table_names, idxs[0]) else 0;
            const src: u32 = if (idxs.len >= 2) try resolveByName(ctx.table_names, idxs[1]) else 0;
            try uleb(ctx.a, ctx.out, dst);
            try uleb(ctx.a, ctx.out, src);
        },
        else => unreachable,
    }
}

fn emitInstr(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    try emitOpcode(ctx, op);
    switch (opcode.immediateKind(op)) {
        .none => {},
        .local => try uleb(ctx.a, ctx.out, try resolveLocal(ctx, try imm0(immediates))),
        .global => try uleb(ctx.a, ctx.out, try resolveByName(ctx.global_names, try imm0(immediates))),
        .table => try uleb(ctx.a, ctx.out, if (immediates.len == 0) 0 else try resolveByName(ctx.table_names, immediates[0])),
        .func => try uleb(ctx.a, ctx.out, try resolveFunc(ctx, try imm0(immediates))),
        .label => try uleb(ctx.a, ctx.out, try resolveLabel(ctx, try imm0(immediates))),
        .i32c => try sleb(ctx.a, ctx.out, try parseWatI32(try imm0(immediates))),
        .i64c => try sleb(ctx.a, ctx.out, try parseWatI64(try imm0(immediates))),
        .f32c => try floatBits(ctx, u32, try imm0(immediates)),
        .f64c => try floatBits(ctx, u64, try imm0(immediates)),
        .mem => try emitMemArg(ctx, op, immediates),
        .mem_reserved => try ctx.out.append(ctx.a, 0x00),
        .ref_type => try ctx.out.append(ctx.a, @intFromEnum(try heapTypeToValType(try imm0(immediates)))),
        .br_table => try emitBrTable(ctx, immediates),
        .table_init, .elem, .table_copy => try emitBulkTableImm(ctx, op, immediates),
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
        .local, .global, .func, .label, .i32c, .i64c, .f32c, .f64c, .ref_type => 1,
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
    const bits = floatLitBits(U, F, atom) orelse return error.BadImmediate;
    var b: [@sizeOf(U)]u8 = undefined;
    std.mem.writeInt(U, &b, bits, .little);
    try ctx.out.appendSlice(ctx.a, &b);
}

/// Parse a WAT float literal to its bit pattern. `std.fmt.parseFloat` handles
/// ordinary values plus plain `inf`/`nan`; this adds the wasm `nan:canonical` /
/// `nan:arithmetic` / `nan:0x<payload>` forms. Returns null on a malformed literal.
fn floatLitBits(comptime U: type, comptime F: type, lit: []const u8) ?U {
    if (std.mem.indexOfScalar(u8, lit, ':')) |c| {
        const canonical: U = if (F == f32) 0x7fc00000 else 0x7ff8000000000000;
        const sign_bit: U = @as(U, 1) << (@bitSizeOf(F) - 1);
        const mant_mask: U = (@as(U, 1) << std.math.floatMantissaBits(F)) - 1;
        var bits: U = canonical;
        const tail = lit[c + 1 ..];
        if (!std.mem.eql(u8, tail, "canonical") and !std.mem.eql(u8, tail, "arithmetic")) {
            const payload = std.fmt.parseInt(U, tail, 0) catch return null;
            bits = (canonical & ~mant_mask) | (payload & mant_mask);
        }
        if (lit.len != 0 and lit[0] == '-') bits |= sign_bit;
        return bits;
    }
    const f = std.fmt.parseFloat(F, lit) catch return null;
    return @bitCast(f);
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

/// Emit a `limits` (§5.3.7): flag byte (0x01 if a max is present) then min[, max].
fn emitLimits(a: std.mem.Allocator, out: *List(u8), min: u32, max: ?u32) Error!void {
    if (max) |mx| {
        try out.append(a, 0x01);
        try uleb(a, out, min);
        try uleb(a, out, mx);
    } else {
        try out.append(a, 0x00);
        try uleb(a, out, min);
    }
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
const validate = @import("validate.zig").validate;

/// Assemble + decode + validate `src`, asserting the module is REJECTED (at any
/// stage). Fails the test only if the module is wrongly accepted.
fn expectInvalid(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = assemble(a, src) catch return; // rejected at assembly is fine
    var m = Module.decode(a, bin) catch return; // rejected at decode is fine
    if (validate(a, &m)) |_| return error.TestExpectedRejection else |_| {}
}

test "validation rejects invalid modules" {
    // Non-constant global init, wrong-typed init, forward global.get.
    try expectInvalid("(module (global i32 (i32.ctz (i32.const 0))))");
    try expectInvalid("(module (global i32 (f32.const 0)))");
    try expectInvalid("(module (global i32 (global.get 0)))");
    // Untyped select on reference operands.
    try expectInvalid("(module (func (param funcref funcref i32) (drop (select (local.get 0) (local.get 1) (local.get 2)))))");
    // call_indirect with no table.
    try expectInvalid("(module (type (func)) (func (call_indirect (type 0) (i32.const 0))))");
    // Over-aligned load (align=2 on load8).
    try expectInvalid("(module (memory 0) (func (drop (i32.load8_u align=2 (i32.const 0)))))");
    // Load with no memory at all.
    try expectInvalid("(module (func (drop (i32.load (i32.const 0)))))");
    // ref.is_null on a non-reference operand.
    try expectInvalid("(module (func (drop (ref.is_null (i32.const 0)))))");
}

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

test "assembles and runs call_indirect through a table" {
    const src =
        \\(module
        \\  (type $binop (func (param i32 i32) (result i32)))
        \\  (func $add (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1)))
        \\  (func $sub (param i32 i32) (result i32) (i32.sub (local.get 0) (local.get 1)))
        \\  (table funcref (elem $add $sub))
        \\  (func (export "apply") (param i32 i32 i32) (result i32)
        \\    (call_indirect (type $binop) (local.get 1) (local.get 2) (local.get 0))))
    ;
    // apply(sel, a, b): sel picks table[sel]; 0=add, 1=sub.
    try std.testing.expectEqual(@as(i32, 13), interp.asI32(try assembleAndRun(src, "apply", &.{ interp.i32Value(0), interp.i32Value(10), interp.i32Value(3) })));
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "apply", &.{ interp.i32Value(1), interp.i32Value(10), interp.i32Value(3) })));
    // Out-of-bounds table index traps.
    try std.testing.expectError(error.TableOutOfBounds, assembleAndRun(src, "apply", &.{ interp.i32Value(5), interp.i32Value(10), interp.i32Value(3) }));
}

test "assembles a mutable global (init expr + get/set)" {
    const src =
        \\(module
        \\  (global $g (mut i32) (i32.const 10))
        \\  (func (export "bump") (result i32)
        \\    (global.set $g (i32.add (global.get $g) (i32.const 5)))
        \\    (global.get $g)))
    ;
    // Init expr evaluated to 10, then +5 → 15.
    try std.testing.expectEqual(@as(i32, 15), interp.asI32(try assembleAndRun(src, "bump", &.{})));
}

test "assembles a type-reference block type" {
    const src =
        \\(module
        \\  (type $sig (func (result i32)))
        \\  (func (export "b") (result i32)
        \\    (block (type $sig) (i32.const 42))))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "b", &.{})));
}

test "exports the correct table index (not hardcoded 0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (func $a) (func $b)
        \\  (table $t0 funcref (elem $a))
        \\  (table $t1 funcref (elem $b))
        \\  (export "t1" (table $t1)))
    );
    const m = try Module.decode(a, bin);
    var found = false;
    for (m.exports) |e| {
        if (std.mem.eql(u8, e.name, "t1")) {
            try std.testing.expectEqual(@as(u32, 1), e.index); // $t1 is table index 1, not 0
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "table.size / table.grow / table.fill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (table $t 1 5 externref)
        \\  (func (export "size") (result i32) (table.size $t))
        \\  (func (export "grow") (param i32 externref) (result i32) (table.grow $t (local.get 1) (local.get 0)))
        \\  (func (export "fill") (param i32 externref i32) (table.fill $t (local.get 0) (local.get 1) (local.get 2)))
        \\  (func (export "get") (param i32) (result externref) (table.get $t (local.get 0))))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    try std.testing.expectEqual(@as(i32, 1), interp.asI32((try inst.invoke("size", &.{}))[0]));
    // grow by 2 (init 99) → returns old size 1; size now 3.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32((try inst.invoke("grow", &.{ interp.i32Value(2), interp.i64Value(99) }))[0]));
    try std.testing.expectEqual(@as(i32, 3), interp.asI32((try inst.invoke("size", &.{}))[0]));
    // grow past max (5) → -1, size unchanged.
    try std.testing.expectEqual(@as(i32, -1), interp.asI32((try inst.invoke("grow", &.{ interp.i32Value(10), interp.i64Value(0) }))[0]));
    // fill [0..2) = 77; read one back.
    _ = try inst.invoke("fill", &.{ interp.i32Value(0), interp.i64Value(77), interp.i32Value(2) });
    try std.testing.expectEqual(@as(i64, 77), interp.asI64((try inst.invoke("get", &.{interp.i32Value(1)}))[0]));
    // The grow-initialized region held 99.
    try std.testing.expectEqual(@as(i64, 99), interp.asI64((try inst.invoke("get", &.{interp.i32Value(2)}))[0]));
}

test "table.get / table.set on an externref table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (table $t 3 externref)
        \\  (func (export "set") (param i32 externref) (table.set $t (local.get 0) (local.get 1)))
        \\  (func (export "get") (param i32) (result externref) (table.get $t (local.get 0))))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    _ = try inst.invoke("set", &.{ interp.i32Value(1), interp.i64Value(42) });
    try std.testing.expectEqual(@as(i64, 42), interp.asI64((try inst.invoke("get", &.{interp.i32Value(1)}))[0]));
    // Slot 0 was never set → null reference sentinel.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try inst.invoke("get", &.{interp.i32Value(0)}))[0]);
}

test "evaluates a compound (extended-const) global init" {
    const src =
        \\(module
        \\  (global $g i32 (i32.add (i32.mul (i32.const 20) (i32.const 2)) (i32.const 2)))
        \\  (func (export "get") (result i32) (global.get $g)))
    ;
    // 20*2 + 2 = 42.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "get", &.{})));
}

test "reads an imported global from the host value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (global (import "env" "x") i32)
        \\  (global $y i32 (i32.add (global.get 0) (i32.const 1)))
        \\  (func (export "get-x") (result i32) (global.get 0))
        \\  (func (export "get-y") (result i32) (global.get $y)))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.initWithImports(a, &m, .{ .globals = &.{interp.i32Value(777)} });
    try std.testing.expectEqual(@as(i32, 777), interp.asI32((try inst.invoke("get-x", &.{}))[0]));
    // A defined global's init may read the imported one: 777 + 1.
    try std.testing.expectEqual(@as(i32, 778), interp.asI32((try inst.invoke("get-y", &.{}))[0]));
}

fn hostAdd(args: []const interp.Value, results: []interp.Value) void {
    results[0] = interp.i32Value(interp.asI32(args[0]) +% interp.asI32(args[1]));
}

test "calls an imported (host) function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (import "env" "add" (func $add (param i32 i32) (result i32)))
        \\  (func (export "call-add") (param i32 i32) (result i32)
        \\    (call $add (local.get 0) (local.get 1))))
    );
    var m = try Module.decode(a, bin);
    const imports: interp.Instance.Imports = .{ .funcs = &.{.{ .native = hostAdd }} };
    var inst = try interp.Instance.initWithImports(a, &m, imports);
    // The imported func occupies index 0; call-add dispatches to the host adder.
    try std.testing.expectEqual(@as(i32, 7), interp.asI32((try inst.invoke("call-add", &.{ interp.i32Value(3), interp.i32Value(4) }))[0]));
}

test "active element-expression segment (ref.func / ref.null)" {
    const src =
        \\(module
        \\  (type $v (func (result i32)))
        \\  (func $a (result i32) (i32.const 7))
        \\  (func $b (result i32) (i32.const 9))
        \\  (table 3 funcref)
        \\  (elem (i32.const 0) funcref (ref.func $a) (ref.null func) (ref.func $b))
        \\  (func (export "call") (param i32) (result i32) (call_indirect (type $v) (local.get 0))))
    ;
    // slot 0 → $a (7), slot 2 → $b (9), slot 1 → null (traps).
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "call", &.{interp.i32Value(0)})));
    try std.testing.expectEqual(@as(i32, 9), interp.asI32(try assembleAndRun(src, "call", &.{interp.i32Value(2)})));
    try std.testing.expectError(error.UninitializedElement, assembleAndRun(src, "call", &.{interp.i32Value(1)}));
}

test "dispatches call_indirect through distinct named tables" {
    const src =
        \\(module
        \\  (type $s (func (result i32)))
        \\  (func $a (result i32) (i32.const 1))
        \\  (func $b (result i32) (i32.const 2))
        \\  (table $t0 funcref (elem $a))
        \\  (table $t1 funcref (elem $b))
        \\  (func (export "via0") (result i32) (call_indirect $t0 (type $s) (i32.const 0)))
        \\  (func (export "via1") (result i32) (call_indirect $t1 (type $s) (i32.const 0))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "via0", &.{})));
    try std.testing.expectEqual(@as(i32, 2), interp.asI32(try assembleAndRun(src, "via1", &.{})));
}

test "assembles reference types (ref.null / ref.func / ref.is_null)" {
    const src =
        \\(module
        \\  (func $f)
        \\  (func (export "isnull") (param i32) (result i32)
        \\    (if (result i32) (local.get 0)
        \\      (then (ref.is_null (ref.null func)))
        \\      (else (ref.is_null (ref.func $f))))))
    ;
    // cond=1 → ref.is_null(null) = 1; cond=0 → ref.is_null(a real funcref) = 0.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(0)})));
}

test "assembles a funcref-typed select" {
    const src =
        \\(module
        \\  (func $f)
        \\  (func (export "sel") (param i32) (result i32)
        \\    (ref.is_null
        \\      (select (result funcref) (ref.func $f) (ref.null func) (local.get 0)))))
    ;
    // cond=1 → picks ref.func $f (non-null) → is_null = 0.
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(1)})));
    // cond=0 → picks ref.null → is_null = 1.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(0)})));
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
