//! A decoded WebAssembly module.
//!
//! Pipeline stage 1 (decode): validate the header, index the top-level
//! sections, and decode the type / import / function / table / memory / global
//! / export sections. Every import and export is resolved to its full
//! `Extern` type, so the wasm-c-api layer can hand back complete
//! `wasm_importtype_t` / `wasm_exporttype_t` objects. Validation,
//! instantiation, and execution are later stages that build on this type.
//!
//! **Ownership:** everything a `Module` exposes is owned by an internal arena,
//! so a decoded module remains valid after the input `bytes` are freed (names
//! are copied in). Release with `deinit`.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");

const Module = @This();

/// A top-level section, indexed by id and payload location (metadata only —
/// `offset`/`size` must not be used to index the input after decode).
pub const Section = struct {
    id: types.SectionId,
    offset: usize,
    size: usize,
};

/// A function signature from the type section (§5.3.3).
pub const FuncType = struct {
    params: []const types.ValType,
    results: []const types.ValType,
};

/// Resizable-range limits shared by tables and memories (§5.3.7).
pub const Limits = struct { min: u32, max: ?u32 };

pub const TableType = struct { element: types.ValType, limits: Limits };
pub const MemoryType = struct { limits: Limits };
pub const GlobalType = struct { content: types.ValType, mutable: bool };

/// The resolved type of an import or export.
pub const Extern = union(enum) {
    func: FuncType,
    table: TableType,
    memory: MemoryType,
    global: GlobalType,

    pub fn kind(self: Extern) types.ExternKind {
        return switch (self) {
            .func => .func,
            .table => .table,
            .memory => .memory,
            .global => .global,
        };
    }
};

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    type: Extern,
};

pub const Export = struct {
    name: []const u8,
    /// Index into the module's combined space for its kind (§5.5.10).
    index: u32,
    type: Extern,
};

/// A data segment (§5.5.14). Active segments initialize linear memory at an
/// offset given by a constant expression; passive segments are copied
/// explicitly by `memory.init` (bulk-memory, not run yet). `offset_expr` and
/// `bytes` are arena-owned copies.
pub const DataSegment = struct {
    active: bool,
    mem_index: u32,
    /// Raw constant-expression bytes (including the terminating `end`); empty
    /// for passive segments.
    offset_expr: []const u8,
    bytes: []const u8,
};

/// An element segment (§5.5.12) that populates a table with function references.
/// MVP handles active funcref segments; `offset_expr` is an arena-owned copy.
pub const Element = struct {
    active: bool,
    table_index: u32,
    offset_expr: []const u8,
    funcs: []const u32,
};

/// A run of consecutive locals of the same type, as encoded in a code entry
/// (§5.4.5). The binary groups locals by type with a repeat count.
pub const Local = struct { count: u32, type: types.ValType };

/// A defined function's body from the code section (§5.5.13): its declared
/// locals and the raw instruction bytes (including the terminating `end`).
/// Instructions are not decoded here — that happens with validation/execution,
/// which choose the internal representation. `body` is arena-owned.
pub const Code = struct {
    locals: []const Local,
    body: []const u8,

    /// Total number of declared locals (excludes parameters).
    pub fn localCount(self: Code) u64 {
        var n: u64 = 0;
        for (self.locals) |l| n += l.count;
        return n;
    }
};

/// Owns all decoded data. `arena.allocator()` is used only during `decode`, so
/// moving the arena into the returned `Module` is safe.
arena: std.heap.ArenaAllocator,
version: u32,
sections: []const Section,
func_types: []const FuncType,
/// Type index of each *defined* function (function section), in order.
functions: []const u32,
imports: []const Import,
exports: []const Export,
/// Body of each defined function (code section), positionally matching
/// `functions`. May be empty if the module has no code section.
code: []const Code,
/// The global index space (imported globals first, then defined), for
/// resolving `global.get`/`global.set` during validation.
globals: []const GlobalType,
/// Init const-expr bytes for each *defined* global (positionally the tail of
/// `globals`, after imported globals), for evaluating initial values.
global_inits: []const []const u8,
/// The memory index space (imported memories first, then defined). MVP allows
/// at most one; kept as a slice for uniformity.
memories: []const MemoryType,
/// The table index space (imported tables first, then defined).
tables: []const TableType,
/// Data segments (data section), for initializing linear memory.
data: []const DataSegment,
/// Element segments (element section), for initializing tables.
elements: []const Element,

pub const Error = types.DecodeError || std.mem.Allocator.Error;

/// Working state threaded through the section decoders, accumulating the
/// per-kind index spaces (imported entries first, then defined) needed to
/// resolve export indices.
const Decoder = struct {
    a: std.mem.Allocator,
    func_types: []const FuncType = &.{},
    func_space: std.ArrayList(FuncType) = .empty,
    table_space: std.ArrayList(TableType) = .empty,
    mem_space: std.ArrayList(MemoryType) = .empty,
    global_space: std.ArrayList(GlobalType) = .empty,
    global_init_space: std.ArrayList([]const u8) = .empty,
};

/// Decode a WebAssembly binary. Caller owns the result; release with `deinit`.
/// `bytes` may be freed afterward — the module copies out everything it keeps.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Module {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var r = Reader.init(bytes);
    if (!std.mem.eql(u8, try r.readBytes(4), &types.magic)) return error.BadMagic;
    const version = try r.readU32Le();
    if (version != types.supported_version) return error.UnsupportedVersion;

    var d: Decoder = .{ .a = a };
    var sections: std.ArrayList(Section) = .empty;
    var functions: []const u32 = &.{};
    var imports: []const Import = &.{};
    var exports: []const Export = &.{};
    var code: []const Code = &.{};
    var data: []const DataSegment = &.{};
    var elements: []const Element = &.{};

    while (!r.atEnd()) {
        const raw_id = try r.readByte();
        if (raw_id > types.SectionId.max) return error.InvalidSectionId;
        const id: types.SectionId = @enumFromInt(raw_id);
        const size = try r.readVarU32();
        const offset = r.pos;
        const payload = try r.readBytes(size);
        try sections.append(a, .{ .id = id, .offset = offset, .size = size });

        var sub = Reader.init(payload);
        switch (id) {
            .type => d.func_types = try decodeTypeSection(&d, &sub),
            .import => imports = try decodeImportSection(&d, &sub),
            .function => functions = try decodeFunctionSection(&d, &sub),
            .table => try decodeTableSection(&d, &sub),
            .memory => try decodeMemorySection(&d, &sub),
            .global => try decodeGlobalSection(&d, &sub),
            .@"export" => exports = try decodeExportSection(&d, &sub),
            .element => elements = try decodeElementSection(&d, &sub),
            .code => code = try decodeCodeSection(&d, &sub),
            .data => data = try decodeDataSection(&d, &sub),
            else => {},
        }
    }

    return .{
        .arena = arena,
        .version = version,
        .sections = try sections.toOwnedSlice(a),
        .func_types = d.func_types,
        .functions = functions,
        .imports = imports,
        .exports = exports,
        .code = code,
        .data = data,
        .elements = elements,
        .globals = try d.global_space.toOwnedSlice(a),
        .global_inits = try d.global_init_space.toOwnedSlice(a),
        .memories = try d.mem_space.toOwnedSlice(a),
        .tables = try d.table_space.toOwnedSlice(a),
    };
}

pub fn deinit(self: *Module) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Return the first section with `id`, or null if absent.
pub fn section(self: Module, id: types.SectionId) ?Section {
    for (self.sections) |s| {
        if (s.id == id) return s;
    }
    return null;
}

/// Number of imported functions (they occupy the low function indices).
pub fn importedFuncCount(self: Module) u32 {
    var n: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .func) n += 1;
    }
    return n;
}

/// Resolve a function index (imports first, then defined) to its signature,
/// or null if out of range.
pub fn funcType(self: Module, index: u32) ?FuncType {
    var i: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .func) {
            if (i == index) return imp.type.func;
            i += 1;
        }
    }
    const defined = index - i;
    if (defined >= self.functions.len) return null;
    const ti = self.functions[defined];
    if (ti >= self.func_types.len) return null;
    return self.func_types[ti];
}

// --- Low-level readers -----------------------------------------------------

fn readValTypes(a: std.mem.Allocator, r: *Reader) Error![]const types.ValType {
    const n = try r.readVarU32();
    const vts = try a.alloc(types.ValType, n);
    for (vts) |*v| v.* = @enumFromInt(try r.readByte());
    return vts;
}

/// Copy a length-prefixed name (§5.2.4) into arena-owned memory.
fn readName(a: std.mem.Allocator, r: *Reader) Error![]const u8 {
    const n = try r.readVarU32();
    const src = try r.readBytes(n);
    const dst = try a.alloc(u8, n);
    @memcpy(dst, src);
    return dst;
}

fn readLimits(r: *Reader) Error!Limits {
    const flag = try r.readByte();
    if (flag > 0x01) return error.MalformedFlag; // only 0x00 (min) / 0x01 (min,max)
    const min = try r.readVarU32();
    const max: ?u32 = if (flag & 0x01 != 0) try r.readVarU32() else null;
    return .{ .min = min, .max = max };
}

fn readTableType(r: *Reader) Error!TableType {
    const element: types.ValType = @enumFromInt(try r.readByte());
    return .{ .element = element, .limits = try readLimits(r) };
}

fn readGlobalType(r: *Reader) Error!GlobalType {
    const content: types.ValType = @enumFromInt(try r.readByte());
    const mut = try r.readByte();
    if (mut > 0x01) return error.MalformedFlag; // only 0x00 (const) / 0x01 (var)
    return .{ .content = content, .mutable = mut != 0 };
}

/// Skip a constant init expression (§5.4.9): a short instruction sequence
/// terminated by `end` (0x0B). Handles the const-expr opcodes so an operand
/// byte can never be mistaken for the terminator.
fn skipConstExpr(r: *Reader) Error!void {
    while (true) {
        const op = try r.readByte();
        switch (op) {
            0x0b => return, // end
            0x41, 0x42 => _ = try r.readVarU32(), // i32/i64.const (operand length-compatible)
            0x23, 0xd2 => _ = try r.readVarU32(), // global.get / ref.func
            0x43 => _ = try r.readBytes(4), // f32.const
            0x44 => _ = try r.readBytes(8), // f64.const
            0xd0 => _ = try r.readByte(), // ref.null (heaptype)
            else => {}, // other zero-operand ops
        }
    }
}

// --- Section decoders ------------------------------------------------------

fn decodeTypeSection(d: *Decoder, r: *Reader) Error![]const FuncType {
    const count = try r.readVarU32();
    const list = try d.a.alloc(FuncType, count);
    for (list) |*ft| {
        if (try r.readByte() != 0x60) return error.BadFuncType;
        ft.params = try readValTypes(d.a, r);
        ft.results = try readValTypes(d.a, r);
    }
    return list;
}

fn funcTypeAt(d: *Decoder, type_index: u32) Error!FuncType {
    if (type_index >= d.func_types.len) return error.IndexOutOfRange;
    return d.func_types[type_index];
}

fn decodeImportSection(d: *Decoder, r: *Reader) Error![]const Import {
    const count = try r.readVarU32();
    const list = try d.a.alloc(Import, count);
    for (list) |*imp| {
        imp.module = try readName(d.a, r);
        imp.name = try readName(d.a, r);
        const kind: types.ExternKind = @enumFromInt(try r.readByte());
        imp.type = switch (kind) {
            .func => blk: {
                const ft = try funcTypeAt(d, try r.readVarU32());
                try d.func_space.append(d.a, ft);
                break :blk .{ .func = ft };
            },
            .table => blk: {
                const tt = try readTableType(r);
                try d.table_space.append(d.a, tt);
                break :blk .{ .table = tt };
            },
            .memory => blk: {
                const mt: MemoryType = .{ .limits = try readLimits(r) };
                try d.mem_space.append(d.a, mt);
                break :blk .{ .memory = mt };
            },
            .global => blk: {
                const gt = try readGlobalType(r);
                try d.global_space.append(d.a, gt);
                break :blk .{ .global = gt };
            },
            else => return error.UnknownExternKind,
        };
    }
    return list;
}

fn decodeFunctionSection(d: *Decoder, r: *Reader) Error![]const u32 {
    const count = try r.readVarU32();
    const list = try d.a.alloc(u32, count);
    for (list) |*i| {
        i.* = try r.readVarU32();
        try d.func_space.append(d.a, try funcTypeAt(d, i.*));
    }
    return list;
}

fn decodeTableSection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) try d.table_space.append(d.a, try readTableType(r));
}

fn decodeMemorySection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) try d.mem_space.append(d.a, .{ .limits = try readLimits(r) });
}

fn decodeGlobalSection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) {
        try d.global_space.append(d.a, try readGlobalType(r));
        try d.global_init_space.append(d.a, try readConstExprBytes(d.a, r)); // init expression
    }
}

fn decodeExportSection(d: *Decoder, r: *Reader) Error![]const Export {
    const count = try r.readVarU32();
    const list = try d.a.alloc(Export, count);
    for (list) |*e| {
        e.name = try readName(d.a, r);
        const kind: types.ExternKind = @enumFromInt(try r.readByte());
        e.index = try r.readVarU32();
        e.type = switch (kind) {
            .func => .{ .func = try spaceAt(FuncType, d.func_space, e.index) },
            .table => .{ .table = try spaceAt(TableType, d.table_space, e.index) },
            .memory => .{ .memory = try spaceAt(MemoryType, d.mem_space, e.index) },
            .global => .{ .global = try spaceAt(GlobalType, d.global_space, e.index) },
            else => return error.UnknownExternKind,
        };
    }
    return list;
}

fn spaceAt(comptime T: type, space: std.ArrayList(T), index: u32) Error!T {
    if (index >= space.items.len) return error.IndexOutOfRange;
    return space.items[index];
}

fn decodeLocals(a: std.mem.Allocator, r: *Reader) Error![]const Local {
    const n = try r.readVarU32();
    const locals = try a.alloc(Local, n);
    for (locals) |*l| {
        l.count = try r.readVarU32();
        l.type = @enumFromInt(try r.readByte());
    }
    return locals;
}

/// Copy a length-prefixed byte vector into arena-owned memory.
fn readByteVec(a: std.mem.Allocator, r: *Reader) Error![]const u8 {
    const n = try r.readVarU32();
    const src = try r.readBytes(n);
    const dst = try a.alloc(u8, n);
    @memcpy(dst, src);
    return dst;
}

/// Capture the raw bytes of a constant expression (through its `end`) so it can
/// be evaluated later (e.g. a data-segment offset).
fn readConstExprBytes(a: std.mem.Allocator, r: *Reader) Error![]const u8 {
    const start = r.pos;
    try skipConstExpr(r);
    const src = r.bytes[start..r.pos];
    const dst = try a.alloc(u8, src.len);
    @memcpy(dst, src);
    return dst;
}

fn readFuncVec(a: std.mem.Allocator, r: *Reader) Error![]const u32 {
    const n = try r.readVarU32();
    const funcs = try a.alloc(u32, n);
    for (funcs) |*f| f.* = try r.readVarU32();
    return funcs;
}

fn decodeElementSection(d: *Decoder, r: *Reader) Error![]const Element {
    const count = try r.readVarU32();
    const list = try d.a.alloc(Element, count);
    for (list) |*e| {
        switch (try r.readVarU32()) { // segment flags (§5.5.12)
            0 => e.* = .{ .active = true, .table_index = 0, .offset_expr = try readConstExprBytes(d.a, r), .funcs = try readFuncVec(d.a, r) },
            2 => blk: {
                const ti = try r.readVarU32();
                const off = try readConstExprBytes(d.a, r);
                _ = try r.readByte(); // elemkind (0x00 = funcref)
                e.* = .{ .active = true, .table_index = ti, .offset_expr = off, .funcs = try readFuncVec(d.a, r) };
                break :blk;
            },
            else => return error.UnsupportedOpcode, // passive/declarative/expr-form deferred
        }
    }
    return list;
}

fn decodeDataSection(d: *Decoder, r: *Reader) Error![]const DataSegment {
    const count = try r.readVarU32();
    const list = try d.a.alloc(DataSegment, count);
    for (list) |*seg| {
        switch (try r.readVarU32()) { // segment flags (§5.5.14)
            0 => seg.* = .{ .active = true, .mem_index = 0, .offset_expr = try readConstExprBytes(d.a, r), .bytes = try readByteVec(d.a, r) },
            1 => seg.* = .{ .active = false, .mem_index = 0, .offset_expr = &.{}, .bytes = try readByteVec(d.a, r) },
            2 => seg.* = .{ .active = true, .mem_index = try r.readVarU32(), .offset_expr = try readConstExprBytes(d.a, r), .bytes = try readByteVec(d.a, r) },
            else => return error.UnsupportedOpcode,
        }
    }
    return list;
}

fn decodeCodeSection(d: *Decoder, r: *Reader) Error![]const Code {
    const count = try r.readVarU32();
    const list = try d.a.alloc(Code, count);
    for (list) |*c| {
        // Each entry is a byte-counted (locals ++ body) blob; decode within it
        // so a malformed local vector can't run past the entry.
        const entry = try r.readBytes(try r.readVarU32());
        var er = Reader.init(entry);
        c.locals = try decodeLocals(d.a, &er);
        const rest = entry[er.pos..]; // instruction bytes, incl. terminating end
        const owned = try d.a.alloc(u8, rest.len);
        @memcpy(owned, rest);
        c.body = owned;
    }
    return list;
}

// --- Tests -----------------------------------------------------------------

test "decodes an empty module (header only)" {
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 1), m.version);
    try std.testing.expectEqual(@as(usize, 0), m.sections.len);
    try std.testing.expectEqual(@as(usize, 0), m.func_types.len);
}

test "indexes a single custom section" {
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x00, 0x01, 0x2a };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.sections.len);
    const s = m.section(.custom).?;
    try std.testing.expectEqual(@as(usize, 1), s.size);
    try std.testing.expectEqual(@as(usize, 10), s.offset);
}

test "rejects a bad magic" {
    const bytes = [_]u8{ 'n', 'o', 'p', 'e', 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.BadMagic, Module.decode(std.testing.allocator, &bytes));
}

test "rejects an unsupported version" {
    const bytes = types.magic ++ [_]u8{ 0x02, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.UnsupportedVersion, Module.decode(std.testing.allocator, &bytes));
}

test "decodes and resolves type/import/function/export sections" {
    // (i32,i32)->i32 ; import env.add:func 0 ; one defined func of type 0 ;
    // export "run" = func 1 (imported func is index 0, defined func is index 1).
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        [_]u8{ 0x02, 0x0b, 0x01, 0x03, 'e', 'n', 'v', 0x03, 'a', 'd', 'd', 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x01 };

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 4), m.sections.len);
    try std.testing.expectEqual(@as(usize, 1), m.func_types.len);
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i32 }, m.func_types[0].params);
    try std.testing.expectEqualSlices(types.ValType, &.{.i32}, m.func_types[0].results);

    try std.testing.expectEqual(@as(usize, 1), m.imports.len);
    try std.testing.expectEqualStrings("env", m.imports[0].module);
    try std.testing.expectEqualStrings("add", m.imports[0].name);
    try std.testing.expectEqual(types.ExternKind.func, m.imports[0].type.kind());
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i32 }, m.imports[0].type.func.params);

    try std.testing.expectEqualSlices(u32, &.{0}, m.functions);

    try std.testing.expectEqual(@as(usize, 1), m.exports.len);
    try std.testing.expectEqualStrings("run", m.exports[0].name);
    try std.testing.expectEqual(types.ExternKind.func, m.exports[0].type.kind());
    try std.testing.expectEqual(@as(u32, 1), m.exports[0].index);
    // export "run" resolves to the (i32,i32)->i32 signature of defined func 1.
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i32 }, m.exports[0].type.func.params);
    try std.testing.expectEqualSlices(types.ValType, &.{.i32}, m.exports[0].type.func.results);
}

test "decodes a code section with locals and a body" {
    // (func (param i32 i32) (result i32) (local i32)
    //    local.get 0  local.get 1  i32.add)   ; export "add" (func 0)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++ // type
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++ // function: 1 func of type 0
        // code: 1 entry, size 9 = locals(01 01 7f) ++ body(20 00 20 01 6a 0b)
        [_]u8{ 0x0a, 0x0b, 0x01, 0x09, 0x01, 0x01, 0x7f, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00 }; // export

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 1), m.code.len);
    try std.testing.expectEqual(@as(usize, 1), m.code[0].locals.len);
    try std.testing.expectEqual(@as(u32, 1), m.code[0].locals[0].count);
    try std.testing.expectEqual(types.ValType.i32, m.code[0].locals[0].type);
    try std.testing.expectEqual(@as(u64, 1), m.code[0].localCount());
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b }, m.code[0].body);

    // export "add" still resolves to the defined function's signature.
    try std.testing.expectEqual(types.ExternKind.func, m.exports[0].type.kind());
    try std.testing.expectEqualSlices(types.ValType, &.{.i32}, m.exports[0].type.func.results);
}

test "resolves a memory export with limits" {
    // memory section: one memory, limits {min=1,max=2}; export "mem" memory 0.
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x05, 0x04, 0x01, 0x01, 0x01, 0x02 } ++ // memory: count 1, flag 1, min 1, max 2
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00 };

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.exports.len);
    try std.testing.expectEqual(types.ExternKind.memory, m.exports[0].type.kind());
    try std.testing.expectEqual(@as(u32, 1), m.exports[0].type.memory.limits.min);
    try std.testing.expectEqual(@as(?u32, 2), m.exports[0].type.memory.limits.max);
}
