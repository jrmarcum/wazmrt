//! A decoded WebAssembly module.
//!
//! Pipeline stage 1 (decode): validate the header, index the top-level
//! sections, and decode the type / function / import / export sections into
//! owned structures. Validation, instantiation, and execution are later stages
//! that build on this type.
//!
//! **Ownership:** everything a `Module` exposes is owned by an internal arena,
//! so a decoded module remains valid after the input `bytes` are freed (names
//! are copied in). Release with `deinit`.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");

const Module = @This();

/// A top-level section, indexed by id and by its payload's location within the
/// original binary. (The meaningful sections are also decoded eagerly below;
/// `offset`/`size` are retained as metadata only — they must not be used to
/// index the input after decode, which may have been freed.)
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

/// An import from the import section (§5.5.10).
pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: types.ExternKind,
    /// For a function import, the type index. Zero for other kinds in this
    /// decode slice (their full type descriptors are consumed but not retained).
    index: u32,
};

/// An export from the export section (§5.5.10).
pub const Export = struct {
    name: []const u8,
    kind: types.ExternKind,
    index: u32,
};

/// Owns all decoded data. Getting `.allocator()` before the return move is safe
/// because that allocator is only used during `decode`.
arena: std.heap.ArenaAllocator,
version: u32,
sections: []const Section,
/// Function signatures (type section).
func_types: []const FuncType,
/// Type index of each *defined* function (function section), in order.
functions: []const u32,
imports: []const Import,
exports: []const Export,

pub const Error = types.DecodeError || std.mem.Allocator.Error;

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

    var sections: std.ArrayList(Section) = .empty;
    var func_types: []const FuncType = &.{};
    var functions: []const u32 = &.{};
    var imports: []const Import = &.{};
    var exports: []const Export = &.{};

    while (!r.atEnd()) {
        const raw_id = try r.readByte();
        if (raw_id > types.SectionId.max) return error.InvalidSectionId;
        const id: types.SectionId = @enumFromInt(raw_id);
        const size = try r.readVarU32();
        const offset = r.pos;
        const payload = try r.readBytes(size); // bounds-check + advance

        try sections.append(a, .{ .id = id, .offset = offset, .size = size });

        var sub = Reader.init(payload);
        switch (id) {
            .type => func_types = try decodeTypeSection(a, &sub),
            .function => functions = try decodeFunctionSection(a, &sub),
            .import => imports = try decodeImportSection(a, &sub),
            .@"export" => exports = try decodeExportSection(a, &sub),
            else => {},
        }
    }

    return .{
        .arena = arena,
        .version = version,
        .sections = try sections.toOwnedSlice(a),
        .func_types = func_types,
        .functions = functions,
        .imports = imports,
        .exports = exports,
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

// --- Section decoders (operate on a sub-reader over the section payload) ---

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

/// Consume a `limits` (§5.3.7): flag byte, min, and max if the low flag bit set.
fn skipLimits(r: *Reader) Error!void {
    const flag = try r.readByte();
    _ = try r.readVarU32();
    if (flag & 0x01 != 0) _ = try r.readVarU32();
}

fn decodeTypeSection(a: std.mem.Allocator, r: *Reader) Error![]const FuncType {
    const count = try r.readVarU32();
    const list = try a.alloc(FuncType, count);
    for (list) |*ft| {
        if (try r.readByte() != 0x60) return error.BadFuncType;
        ft.params = try readValTypes(a, r);
        ft.results = try readValTypes(a, r);
    }
    return list;
}

fn decodeFunctionSection(a: std.mem.Allocator, r: *Reader) Error![]const u32 {
    const count = try r.readVarU32();
    const list = try a.alloc(u32, count);
    for (list) |*i| i.* = try r.readVarU32();
    return list;
}

fn decodeImportSection(a: std.mem.Allocator, r: *Reader) Error![]const Import {
    const count = try r.readVarU32();
    const list = try a.alloc(Import, count);
    for (list) |*imp| {
        imp.module = try readName(a, r);
        imp.name = try readName(a, r);
        imp.kind = @enumFromInt(try r.readByte());
        imp.index = 0;
        switch (imp.kind) {
            .func => imp.index = try r.readVarU32(), // typeidx
            .table => {
                _ = try r.readByte(); // reftype
                try skipLimits(r);
            },
            .memory => try skipLimits(r),
            .global => {
                _ = try r.readByte(); // valtype
                _ = try r.readByte(); // mutability
            },
            else => return error.UnknownExternKind,
        }
    }
    return list;
}

fn decodeExportSection(a: std.mem.Allocator, r: *Reader) Error![]const Export {
    const count = try r.readVarU32();
    const list = try a.alloc(Export, count);
    for (list) |*e| {
        e.name = try readName(a, r);
        e.kind = @enumFromInt(try r.readByte());
        e.index = try r.readVarU32();
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

test "decodes type/import/function/export sections" {
    // (i32,i32)->i32 ; import env.add:func 0 ; one defined func of type 0 ;
    // export "run" = func 1 (imported func is index 0, defined func is index 1).
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        // type section
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        // import section: "env" "add" func typeidx 0
        [_]u8{ 0x02, 0x0b, 0x01, 0x03, 'e', 'n', 'v', 0x03, 'a', 'd', 'd', 0x00, 0x00 } ++
        // function section: one func, type 0
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        // export section: "run" func index 1
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
    try std.testing.expectEqual(types.ExternKind.func, m.imports[0].kind);
    try std.testing.expectEqual(@as(u32, 0), m.imports[0].index);

    try std.testing.expectEqualSlices(u32, &.{0}, m.functions);

    try std.testing.expectEqual(@as(usize, 1), m.exports.len);
    try std.testing.expectEqualStrings("run", m.exports[0].name);
    try std.testing.expectEqual(types.ExternKind.func, m.exports[0].kind);
    try std.testing.expectEqual(@as(u32, 1), m.exports[0].index);
}
