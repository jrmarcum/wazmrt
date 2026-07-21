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
const opcode = @import("opcode.zig");

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

/// A struct/array field's storage type (GC, §5.3.6). Packed `i8`/`i16` store
/// narrow and widen on read (`*.get_s` sign-extends, `*.get_u` zero-extends);
/// an unpacked field holds an ordinary value type.
pub const StorageType = union(enum) {
    val: types.ValType,
    i8, // packed
    i16, // packed

    /// The value type this field projects onto the operand stack (packed → i32).
    pub fn unpacked(self: StorageType) types.ValType {
        return switch (self) {
            .val => |v| v,
            .i8, .i16 => .i32,
        };
    }
    pub fn isPacked(self: StorageType) bool {
        return self != .val;
    }
};

/// A struct field / array element type (GC): storage type + mutability.
pub const FieldType = struct { storage: StorageType, mutable: bool };

/// The composite-type kind of a type-section entry (GC). Determined by the
/// leading composite-type byte, so it can be pre-scanned before fields (which
/// may forward-reference later types in a rec group) are decoded.
pub const CompKind = enum { func, @"struct", array };

/// A composite type from the type section (§5.3): a function signature, a struct
/// (a vector of fields), or an array (a single element field). Rec/sub wrappers
/// are decoded structurally; the declared supertype (if any) is kept for later
/// cast/subtyping support.
pub const CompType = union(enum) {
    func: FuncType,
    @"struct": []const FieldType,
    array: FieldType,

    pub fn kind(self: CompType) CompKind {
        return switch (self) {
            .func => .func,
            .@"struct" => .@"struct",
            .array => .array,
        };
    }
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
    /// An imported exception tag (EH proposal): its type is a function type
    /// whose params are the exception's value types.
    tag: FuncType,

    pub fn kind(self: Extern) types.ExternKind {
        return switch (self) {
            .func => .func,
            .table => .table,
            .memory => .memory,
            .global => .global,
            .tag => .tag,
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

/// An element segment (§5.5.12). Two element forms are supported: a plain
/// function-index list (`funcs`) or a vector of const-expressions (`exprs`,
/// each producing a reference); exactly one is non-empty. `offset_expr` is
/// arena-owned and only meaningful for active segments.
pub const Element = struct {
    pub const Mode = enum { active, passive, declarative };
    mode: Mode,
    table_index: u32,
    offset_expr: []const u8,
    funcs: []const u32,
    exprs: []const []const u8,
    /// The reference type of the elements (funcref for the func-index form).
    elem_type: types.ValType,
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
    /// Absolute byte offset of `body` within the original module binary. The
    /// bytes themselves are copied out (the input may be freed), so this is the
    /// only way back to a position in the file — it's what lets a trap report
    /// `wasm_frame_module_offset` truthfully.
    body_offset: u32 = 0,

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
/// The type index space (§5.3): func / struct / array composite types, in
/// declaration order (rec groups flattened into consecutive indices).
comp_types: []const CompType,
/// Declared supertype of each type index (GC sub types), or null.
///
/// **LIVE — do not remove.** Read by `isSubtype`'s supertype-chain walk, which
/// `ref.cast`/`br_on_cast`/operand matching all depend on. (This said "kept for
/// future `ref.cast`; unused by the current slice" until 2026-07-21, long after
/// GC P3 shipped — dead-code bait that could have cost a live field.)
supertypes: []const ?u32,
/// Type index of each *defined* function (function section), in order.
functions: []const u32,
/// Type index of each exception tag (tag section §5.5.14, EH proposal). Each
/// names a function type whose params are the exception's value types (results
/// must be empty). Imported tags are not yet in this space (defined tags only).
tags: []const u32,
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
/// The start function's index (start section §5.5.11), run at instantiation.
start: ?u32,
/// Raw `vec(nameassoc)` payload of the name section's function-name subsection
/// (§7.4.2), arena-owned, or null when the module carries no names (a stripped
/// or release build). Read it through `funcName` — it is only consulted when
/// reporting a trap.
func_names: ?[]const u8 = null,

pub const Error = types.DecodeError || std.mem.Allocator.Error;

/// Working state threaded through the section decoders, accumulating the
/// per-kind index spaces (imported entries first, then defined) needed to
/// resolve export indices.
const Decoder = struct {
    a: std.mem.Allocator,
    comp_types: []const CompType = &.{},
    supertypes: []const ?u32 = &.{},
    /// Composite kind of each type index, pre-scanned before bodies are decoded
    /// so a `(ref $t)` value type can collapse to the right family (func /
    /// struct / array) even when `$t` is a forward reference in a rec group.
    type_kinds: []const CompKind = &.{},
    func_space: std.ArrayList(FuncType) = .empty,
    table_space: std.ArrayList(TableType) = .empty,
    mem_space: std.ArrayList(MemoryType) = .empty,
    global_space: std.ArrayList(GlobalType) = .empty,
    /// Exception-tag index space (imported tags first, then defined), each as its
    /// signature — so an exported tag resolves its type (EH proposal).
    tag_space: std.ArrayList(FuncType) = .empty,
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
    var tags: []const u32 = &.{};
    var imports: []const Import = &.{};
    var exports: []const Export = &.{};
    var code: []const Code = &.{};
    var data: []const DataSegment = &.{};
    var elements: []const Element = &.{};
    var start: ?u32 = null;

    var data_count: ?u32 = null;
    var func_names: ?[]const u8 = null;

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
            // A custom section's payload begins with a name (§5.5.3); an empty
            // section (no name) or an over-long name length is malformed.
            .custom => {
                const nlen = try sub.readVarU32();
                const cname = try sub.readBytes(nlen);
                // Keep the "name" section's function-name subsection (§7.4.2) so
                // traps can report a symbol instead of a bare index. We copy the
                // bytes and scan them lazily — a module that never traps pays
                // only the copy, and one built with `-fstrip` has none at all.
                if (std.mem.eql(u8, cname, "name")) func_names = findFuncNameSubsection(a, &sub) catch null;
            },
            .type => try decodeTypeSection(&d, &sub),
            .import => imports = try decodeImportSection(&d, &sub),
            .function => functions = try decodeFunctionSection(&d, &sub),
            .tag => tags = try decodeTagSection(&d, &sub),
            .table => try decodeTableSection(&d, &sub),
            .memory => try decodeMemorySection(&d, &sub),
            .global => try decodeGlobalSection(&d, &sub),
            .@"export" => exports = try decodeExportSection(&d, &sub),
            .element => elements = try decodeElementSection(&d, &sub),
            .code => code = try decodeCodeSection(&d, &sub, offset),
            .data => data = try decodeDataSection(&d, &sub),
            .data_count => data_count = try sub.readVarU32(),
            .start => start = try sub.readVarU32(),
            else => {},
        }
    }

    // If present, the data-count section must equal the data-segment count (§5.5.16).
    if (data_count) |dc| if (dc != data.len) return error.DataCountMismatch;

    return .{
        .arena = arena,
        .version = version,
        .sections = try sections.toOwnedSlice(a),
        .comp_types = d.comp_types,
        .supertypes = d.supertypes,
        .functions = functions,
        .tags = tags,
        .imports = imports,
        .exports = exports,
        .code = code,
        .data = data,
        .elements = elements,
        .start = start,
        .globals = try d.global_space.toOwnedSlice(a),
        .global_inits = try d.global_init_space.toOwnedSlice(a),
        .memories = try d.mem_space.toOwnedSlice(a),
        .tables = try d.table_space.toOwnedSlice(a),
        .func_names = func_names,
    };
}

/// Find the function-name subsection (id 1) inside a `name` custom section and
/// return an arena-owned copy of its `vec(nameassoc)` payload (§7.4.2).
///
/// The name section is a *convention*, not part of validation: a malformed one
/// must never fail the module. Every error here degrades to "no names".
fn findFuncNameSubsection(a: std.mem.Allocator, sub: *Reader) !?[]const u8 {
    while (!sub.atEnd()) {
        const kind = try sub.readByte();
        const size = try sub.readVarU32();
        const payload = try sub.readBytes(size);
        if (kind == 1) return try a.dupe(u8, payload); // 1 = function names
        if (kind > 1) break; // subsections are ordered; 2+ means we passed it
    }
    return null;
}

/// The name recorded for function `index` in the name section, if any.
///
/// Scans linearly rather than building a map: this is only ever called while
/// reporting a trap, so a module that runs clean pays nothing. A malformed
/// entry just ends the scan — a bad name section must not turn into an error
/// on the path that is already reporting an error.
pub fn funcName(self: *const Module, index: u32) ?[]const u8 {
    const bytes = self.func_names orelse return null;
    var r = Reader.init(bytes);
    const count = r.readVarU32() catch return null;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const idx = r.readVarU32() catch return null;
        const len = r.readVarU32() catch return null;
        const name = r.readBytes(len) catch return null;
        if (idx == index) return name;
        if (idx > index) return null; // the vec is sorted by index
    }
    return null;
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

/// Number of imported tables (they occupy the low table indices).
pub fn importedTableCount(self: Module) u32 {
    var n: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .table) n += 1;
    }
    return n;
}

/// Number of imported memories (they occupy the low memory indices).
pub fn importedMemoryCount(self: Module) u32 {
    var n: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .memory) n += 1;
    }
    return n;
}

/// Resolve a function index (imports first, then defined) to its signature,
/// or null if out of range.
pub fn funcType(self: *const Module, index: u32) ?FuncType {
    var i: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .func) {
            if (i == index) return imp.type.func;
            i += 1;
        }
    }
    const defined = index - i;
    if (defined >= self.functions.len) return null;
    return self.funcSig(self.functions[defined]);
}

/// The type index of a function (imports first, then defined), or null for an
/// imported function (our import table keeps the signature, not the type index).
pub fn funcTypeIndex(self: *const Module, func_index: u32) ?u32 {
    const imported = self.importedFuncCount();
    if (func_index < imported) return null;
    const defined = func_index - imported;
    if (defined >= self.functions.len) return null;
    return self.functions[defined];
}

/// The function signature at type index `ti`, or null if `ti` is out of range
/// or names a non-function (struct/array) composite type.
pub fn funcSig(self: *const Module, ti: u32) ?FuncType {
    if (ti >= self.comp_types.len) return null;
    return switch (self.comp_types[ti]) {
        .func => |f| f,
        else => null,
    };
}

/// The function type an exception `tag` names (its params are the exception's
/// value types). Imported tags lead the tag index space (like imported funcs),
/// then defined tags. Null if the index or its type index is out of range.
pub fn tagType(self: *const Module, tag_index: u32) ?FuncType {
    var i: u32 = 0;
    for (self.imports) |imp| {
        if (imp.type == .tag) {
            if (i == tag_index) return imp.type.tag;
            i += 1;
        }
    }
    const defined = tag_index - i;
    if (defined >= self.tags.len) return null;
    return self.funcSig(self.tags[defined]);
}

/// The struct field vector at type index `ti`, or null if `ti` is not a struct.
pub fn structFields(self: *const Module, ti: u32) ?[]const FieldType {
    if (ti >= self.comp_types.len) return null;
    return switch (self.comp_types[ti]) {
        .@"struct" => |fs| fs,
        else => null,
    };
}

/// The array element field at type index `ti`, or null if `ti` is not an array.
pub fn arrayField(self: *const Module, ti: u32) ?FieldType {
    if (ti >= self.comp_types.len) return null;
    return switch (self.comp_types[ti]) {
        .array => |f| f,
        else => null,
    };
}

/// Resolve a GC heap type to a reference-hierarchy head, mapping a concrete type
/// index to its composite family (func / struct / array). Errors if a concrete
/// index is out of range.
pub fn refHead(self: *const Module, ht: opcode.HeapType) Error!types.ValType.RefHeap {
    return switch (ht) {
        .func, .nofunc => .func,
        .extern_, .noextern => .extern_,
        .any => .any,
        .eq => .eq,
        .i31 => .i31,
        .@"struct" => .@"struct",
        .array => .array,
        .none => .none,
        .exn => .exn,
        .concrete => |ti| blk: {
            if (ti >= self.comp_types.len) return error.IndexOutOfRange;
            break :blk switch (self.comp_types[ti].kind()) {
                .func => .func,
                .@"struct" => .@"struct",
                .array => .array,
            };
        },
    };
}

/// Is type index `a` a (reflexive/transitive) subtype of `b`, walking the
/// declared GC supertype chain?
pub fn isSubtype(self: *const Module, a: u32, b: u32) bool {
    var cur: ?u32 = a;
    while (cur) |c| {
        if (c == b) return true;
        cur = if (c < self.supertypes.len) self.supertypes[c] else null;
    }
    return false;
}

// --- Low-level readers -----------------------------------------------------

/// Read one value type. Numeric types are themselves; abstract reference
/// shorthands map to their family head, and `(ref null? ht)` = 0x63/0x64 +
/// heaptype resolves a concrete `$t` to its family (func / struct / array) via
/// the pre-scanned `kinds`. Non-null synthetic tags (0x58–0x68) round-trip our
/// own assembler output.
fn readValType(r: *Reader, kinds: []const CompKind) Error!types.ValType {
    const b = try r.readByte();
    return switch (b) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b => @enumFromInt(b), // i32 i64 f32 f64 v128
        0x70, 0x73 => .funcref, // funcref, nullfuncref (nofunc) → func family head
        0x6f, 0x72 => .externref, // externref, nullexternref (noextern)
        // The WasmGC `any` internal hierarchy (full GC, P3): each abstract head is
        // its own value type, encoded by its real valtype byte.
        0x6e => .anyref,
        0x6d => .eqref,
        0x6c => .i31ref,
        0x6b => .structref,
        0x6a => .arrayref,
        0x71 => .nullref, // none
        0x69, 0x74 => .externref, // exnref, nullexnref (EH — opaque, out of scope)
        0x68 => .funcref_nn, // our synthetic non-null tags (assembler round-trip)
        0x67 => .externref_nn,
        0x66 => .anyref_nn,
        0x65 => .eqref_nn,
        0x62 => .i31ref_nn,
        0x61 => .structref_nn,
        0x59 => .arrayref_nn,
        0x58 => .nullref_nn,
        0x63 => try readHeapTypeRef(r, true, kinds), // (ref null ht)
        0x64 => try readHeapTypeRef(r, false, kinds), // (ref ht) — non-nullable
        else => error.BadValType,
    };
}

/// Map a `heaptype` (following a `0x63`/`0x64` ref prefix) to a reference value
/// type. A non-negative `s33` is a concrete type index: it collapses to its
/// composite family's head (func → `funcref`, struct → `structref`, array →
/// `arrayref`) using the pre-scanned `kinds`. Negative encodings are the
/// abstract heap types. `nullable` picks the nullable vs non-null variant.
fn readHeapTypeRef(r: *Reader, nullable: bool, kinds: []const CompKind) Error!types.ValType {
    const ht = try r.readVarI64(); // s33
    if (ht >= 0) {
        if (ht > std.math.maxInt(u32)) return error.IndexOutOfRange; // guard the @intCast (s33 can hold up to 2^63)
        const ti: u32 = @intCast(ht);
        if (ti >= kinds.len) return error.IndexOutOfRange;
        const head: types.ValType.RefHeap = switch (kinds[ti]) {
            .func => .func,
            .@"struct" => .@"struct",
            .array => .array,
        };
        return types.ValType.concreteRef(nullable, head, ti);
    }
    const both: [2]types.ValType = switch (ht) {
        -0x10, -0x0d => .{ .funcref, .funcref_nn }, // func, nofunc
        -0x11, -0x0e => .{ .externref, .externref_nn }, // extern, noextern
        -0x12 => .{ .anyref, .anyref_nn }, // any
        -0x13 => .{ .eqref, .eqref_nn }, // eq
        -0x14 => .{ .i31ref, .i31ref_nn }, // i31
        -0x15 => .{ .structref, .structref_nn }, // struct
        -0x16 => .{ .arrayref, .arrayref_nn }, // array
        -0x0f => .{ .nullref, .nullref_nn }, // none
        else => .{ .externref, .externref_nn }, // exn/other → opaque
    };
    return if (nullable) both[0] else both[1];
}

fn readValTypes(a: std.mem.Allocator, r: *Reader, kinds: []const CompKind) Error![]const types.ValType {
    const n = try r.readVecLen();
    const vts = try a.alloc(types.ValType, n);
    for (vts) |*v| v.* = try readValType(r, kinds);
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

fn readTableType(r: *Reader, kinds: []const CompKind) Error!TableType {
    const element = try readValType(r, kinds);
    return .{ .element = element, .limits = try readLimits(r) };
}

fn readGlobalType(r: *Reader, kinds: []const CompKind) Error!GlobalType {
    const content = try readValType(r, kinds);
    const mut = try r.readByte();
    if (mut > 0x01) return error.MalformedFlag; // only 0x00 (const) / 0x01 (var)
    return .{ .content = content, .mutable = mut != 0 };
}

/// Read a field type (GC §5.3.6): a storage type + a mutability byte.
fn readFieldType(r: *Reader, kinds: []const CompKind) Error!FieldType {
    const st = try readStorageType(r, kinds);
    const mut = try r.readByte();
    if (mut > 0x01) return error.MalformedFlag;
    return .{ .storage = st, .mutable = mut != 0 };
}

/// Read a storage type: a packed `i8` (0x78) / `i16` (0x77), else a value type.
fn readStorageType(r: *Reader, kinds: []const CompKind) Error!StorageType {
    const b = try r.peekByte();
    return switch (b) {
        0x78 => {
            _ = try r.readByte();
            return .i8;
        },
        0x77 => {
            _ = try r.readByte();
            return .i16;
        },
        else => .{ .val = try readValType(r, kinds) },
    };
}

/// Skip a constant init expression (§5.4.9): a short instruction sequence
/// terminated by `end` (0x0B). Handles the const-expr opcodes so an operand
/// byte can never be mistaken for the terminator.
fn skipConstExpr(r: *Reader) Error!void {
    while (true) {
        const op = try r.readByte();
        switch (op) {
            0x0b => return, // end
            0x41, 0x23, 0xd2 => try r.skipLeb(5), // i32.const, global.get, ref.func (32-bit LEB)
            0x42 => try r.skipLeb(10), // i64.const (64-bit LEB)
            0x43 => _ = try r.readBytes(4), // f32.const
            0x44 => _ = try r.readBytes(8), // f64.const
            0xd0 => _ = try r.readVarI64(), // ref.null (heaptype s33)
            else => {}, // other zero-operand ops
        }
    }
}

// --- Section decoders ------------------------------------------------------

/// Decode the type section (§5.5.4, GC §5.3): a vector of *rec types*, each a
/// bare composite type or a `0x4e` rec group of sub types. Rec groups flatten
/// into consecutive type indices. Runs a cheap kind pre-scan first so a
/// `(ref $t)` inside a field can collapse to the right family even when `$t`
/// forward-references a later type in the same group.
fn decodeTypeSection(d: *Decoder, r: *Reader) Error!void {
    var scan = r.*; // Reader is a value cursor — copy for the pre-scan pass.
    d.type_kinds = try prescanTypeKinds(d.a, &scan);

    var comp: std.ArrayList(CompType) = .empty;
    var supers: std.ArrayList(?u32) = .empty;
    var nrec = try r.readVarU32();
    while (nrec > 0) : (nrec -= 1) {
        if (try r.peekByte() == 0x4e) {
            _ = try r.readByte(); // rec group
            var k = try r.readVarU32();
            while (k > 0) : (k -= 1) try decodeSubType(d, r, &comp, &supers);
        } else {
            try decodeSubType(d, r, &comp, &supers);
        }
    }
    d.comp_types = try comp.toOwnedSlice(d.a);
    d.supertypes = try supers.toOwnedSlice(d.a);
}

/// Decode one sub type: an optional `0x50`/`0x4f` (non-final / final) wrapper
/// carrying a supertype list (GC MVP: at most one), then a composite type.
fn decodeSubType(d: *Decoder, r: *Reader, comp: *std.ArrayList(CompType), supers: *std.ArrayList(?u32)) Error!void {
    var super: ?u32 = null;
    const tag = try r.peekByte();
    if (tag == 0x50 or tag == 0x4f) {
        _ = try r.readByte();
        const ns = try r.readVarU32();
        if (ns > 1) return error.BadType; // MVP allows at most one supertype
        if (ns == 1) {
            super = try r.readVarU32();
            // A supertype must be a PRIOR type (a lower index than this one,
            // whose index is `comp.items.len` — it hasn't been appended yet). This
            // makes the supertype chain strictly decreasing, so `isSubtype`'s walk
            // can't loop forever on a self- or forward-referential supertype.
            if (super.? >= comp.items.len) return error.BadType;
        }
    }
    try comp.append(d.a, try decodeCompType(d, r));
    try supers.append(d.a, super);
}

/// Decode a composite type: `0x60` func / `0x5f` struct / `0x5e` array.
fn decodeCompType(d: *Decoder, r: *Reader) Error!CompType {
    return switch (try r.readByte()) {
        0x60 => .{ .func = .{
            .params = try readValTypes(d.a, r, d.type_kinds),
            .results = try readValTypes(d.a, r, d.type_kinds),
        } },
        0x5f => blk: {
            var n = try r.readVecLen();
            const fs = try d.a.alloc(FieldType, n);
            var i: usize = 0;
            while (n > 0) : (n -= 1) {
                fs[i] = try readFieldType(r, d.type_kinds);
                i += 1;
            }
            break :blk .{ .@"struct" = fs };
        },
        0x5e => .{ .array = try readFieldType(r, d.type_kinds) },
        else => error.BadType,
    };
}

// --- Type-kind pre-scan (pass A) -------------------------------------------
// Walk the type section structurally, recording each type's composite kind
// without resolving inner reference types (whose family may forward-reference a
// later type). Deliberately mirrors the pass-B structure above.

fn prescanTypeKinds(a: std.mem.Allocator, r: *Reader) Error![]const CompKind {
    var kinds: std.ArrayList(CompKind) = .empty;
    var nrec = try r.readVarU32();
    while (nrec > 0) : (nrec -= 1) {
        if (try r.peekByte() == 0x4e) {
            _ = try r.readByte();
            var k = try r.readVarU32();
            while (k > 0) : (k -= 1) try scanSubType(a, r, &kinds);
        } else {
            try scanSubType(a, r, &kinds);
        }
    }
    return kinds.toOwnedSlice(a);
}

fn scanSubType(a: std.mem.Allocator, r: *Reader, kinds: *std.ArrayList(CompKind)) Error!void {
    const tag = try r.peekByte();
    if (tag == 0x50 or tag == 0x4f) {
        _ = try r.readByte();
        var ns = try r.readVarU32();
        while (ns > 0) : (ns -= 1) _ = try r.readVarU32(); // supertype indices
    }
    switch (try r.readByte()) {
        0x60 => {
            try skipValTypeVec(r);
            try skipValTypeVec(r);
            try kinds.append(a, .func);
        },
        0x5f => {
            var n = try r.readVarU32();
            while (n > 0) : (n -= 1) try skipFieldType(r);
            try kinds.append(a, .@"struct");
        },
        0x5e => {
            try skipFieldType(r);
            try kinds.append(a, .array);
        },
        else => return error.BadType,
    }
}

fn skipValTypeVec(r: *Reader) Error!void {
    var n = try r.readVarU32();
    while (n > 0) : (n -= 1) try skipValType(r);
}

/// Advance past one value type without resolving it (bytes only).
fn skipValType(r: *Reader) Error!void {
    const b = try r.readByte();
    if (b == 0x63 or b == 0x64) _ = try r.readVarI64(); // (ref null? ht): + heaptype s33
}

fn skipFieldType(r: *Reader) Error!void {
    const b = try r.peekByte();
    if (b == 0x77 or b == 0x78) {
        _ = try r.readByte(); // packed i16 / i8
    } else {
        try skipValType(r);
    }
    _ = try r.readByte(); // mutability
}

fn funcTypeAt(d: *Decoder, type_index: u32) Error!FuncType {
    if (type_index >= d.comp_types.len) return error.IndexOutOfRange;
    return switch (d.comp_types[type_index]) {
        .func => |f| f,
        else => error.BadType, // a struct/array type used where a func type is required
    };
}

fn decodeImportSection(d: *Decoder, r: *Reader) Error![]const Import {
    const count = try r.readVecLen();
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
                const tt = try readTableType(r, d.type_kinds);
                try d.table_space.append(d.a, tt);
                break :blk .{ .table = tt };
            },
            .memory => blk: {
                const mt: MemoryType = .{ .limits = try readLimits(r) };
                try d.mem_space.append(d.a, mt);
                break :blk .{ .memory = mt };
            },
            .global => blk: {
                const gt = try readGlobalType(r, d.type_kinds);
                try d.global_space.append(d.a, gt);
                break :blk .{ .global = gt };
            },
            .tag => blk: {
                // Tag import: an attribute byte (0 = exception) + a type index.
                if ((try r.readByte()) != 0x00) return error.MalformedFlag;
                const ft = try funcTypeAt(d, try r.readVarU32());
                try d.tag_space.append(d.a, ft);
                break :blk .{ .tag = ft };
            },
            else => return error.UnknownExternKind,
        };
    }
    return list;
}

fn decodeFunctionSection(d: *Decoder, r: *Reader) Error![]const u32 {
    const count = try r.readVecLen();
    const list = try d.a.alloc(u32, count);
    for (list) |*i| {
        i.* = try r.readVarU32();
        try d.func_space.append(d.a, try funcTypeAt(d, i.*));
    }
    return list;
}

/// Tag section (§5.5.14, EH proposal): a vector of tags, each an attribute byte
/// (0x00 = exception) followed by a type index. Returns the type indices.
fn decodeTagSection(d: *Decoder, r: *Reader) Error![]const u32 {
    const count = try r.readVecLen();
    const list = try d.a.alloc(u32, count);
    for (list) |*i| {
        const attr = try r.readByte();
        if (attr != 0x00) return error.MalformedFlag; // only the exception attribute (0) exists
        i.* = try r.readVarU32();
        try d.tag_space.append(d.a, try funcTypeAt(d, i.*)); // defined tags follow imported ones
    }
    return list;
}

fn decodeTableSection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) try d.table_space.append(d.a, try readTableType(r, d.type_kinds));
}

fn decodeMemorySection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) try d.mem_space.append(d.a, .{ .limits = try readLimits(r) });
}

fn decodeGlobalSection(d: *Decoder, r: *Reader) Error!void {
    var count = try r.readVarU32();
    while (count > 0) : (count -= 1) {
        try d.global_space.append(d.a, try readGlobalType(r, d.type_kinds));
        try d.global_init_space.append(d.a, try readConstExprBytes(d.a, r)); // init expression
    }
}

fn decodeExportSection(d: *Decoder, r: *Reader) Error![]const Export {
    const count = try r.readVecLen();
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
            .tag => .{ .tag = try spaceAt(FuncType, d.tag_space, e.index) },
            else => return error.UnknownExternKind,
        };
    }
    return list;
}

fn spaceAt(comptime T: type, space: std.ArrayList(T), index: u32) Error!T {
    if (index >= space.items.len) return error.IndexOutOfRange;
    return space.items[index];
}

fn decodeLocals(a: std.mem.Allocator, r: *Reader, kinds: []const CompKind) Error![]const Local {
    const n = try r.readVecLen();
    const locals = try a.alloc(Local, n);
    for (locals) |*l| {
        l.count = try r.readVarU32();
        l.type = try readValType(r, kinds);
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
    const n = try r.readVecLen();
    const funcs = try a.alloc(u32, n);
    for (funcs) |*f| f.* = try r.readVarU32();
    return funcs;
}

/// Read a vector of element const-expressions (each terminated by `end`).
fn readExprVec(a: std.mem.Allocator, r: *Reader) Error![]const []const u8 {
    const n = try r.readVecLen();
    const exprs = try a.alloc([]const u8, n);
    for (exprs) |*e| e.* = try readConstExprBytes(a, r);
    return exprs;
}

const no_funcs: []const u32 = &.{};
const no_exprs: []const []const u8 = &.{};

/// Decode the element section (§5.5.12): all 8 flag variants — active /
/// passive / declarative, in either the func-index or const-expr form.
fn decodeElementSection(d: *Decoder, r: *Reader) Error![]const Element {
    const count = try r.readVecLen();
    const list = try d.a.alloc(Element, count);
    for (list) |*e| {
        const flags = try r.readVarU32();
        e.table_index = 0;
        e.offset_expr = &.{};
        e.funcs = no_funcs;
        e.exprs = no_exprs;
        e.elem_type = .funcref;
        // bit0: 0 = active; bit1 (when bit0=1): 0 = passive, 1 = declarative.
        e.mode = if (flags & 0b001 == 0) .active else if (flags & 0b010 == 0) .passive else .declarative;
        // bit1 (of active) selects an explicit table index; bit2 selects the expr form.
        if (e.mode == .active and (flags & 0b010) != 0) e.table_index = try r.readVarU32();
        if (e.mode == .active) e.offset_expr = try readConstExprBytes(d.a, r);
        if (flags & 0b100 == 0) {
            // Func-index form. Non-flag-0 variants carry a leading elemkind byte.
            if (flags != 0) _ = try r.readByte(); // elemkind (0x00 = funcref)
            e.funcs = try readFuncVec(d.a, r);
        } else {
            // Const-expr form. Non-flag-4 variants carry a leading reftype byte.
            if (flags != 4) e.elem_type = try readValType(r, d.type_kinds);
            e.exprs = try readExprVec(d.a, r);
        }
    }
    return list;
}

fn decodeDataSection(d: *Decoder, r: *Reader) Error![]const DataSegment {
    const count = try r.readVecLen();
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

/// `payload_base` is the code section payload's absolute offset in the module,
/// so each body can record where its bytes live in the original binary.
fn decodeCodeSection(d: *Decoder, r: *Reader, payload_base: usize) Error![]const Code {
    const count = try r.readVecLen();
    const list = try d.a.alloc(Code, count);
    for (list) |*c| {
        // Each entry is a byte-counted (locals ++ body) blob; decode within it
        // so a malformed local vector can't run past the entry.
        const entry = try r.readBytes(try r.readVarU32());
        var er = Reader.init(entry);
        c.locals = try decodeLocals(d.a, &er, d.type_kinds);
        const rest = entry[er.pos..]; // instruction bytes, incl. terminating end
        const owned = try d.a.alloc(u8, rest.len);
        @memcpy(owned, rest);
        c.body = owned;
        // `entry` ends at r.pos, so it began at r.pos - entry.len; the body
        // starts er.pos into it (past the locals vector).
        // Saturate rather than `@intCast`: `body_offset` is a `u32` and this sum
        // is a `usize`, so a >4 GiB module (impossible via the CLI's 64 MB read
        // cap, but the C ABI takes arbitrary embedder bytes) made the cast
        // out-of-range — illegal behaviour in the shipped ReleaseFast build.
        // The offset is only ever used to label a trap backtrace, so a clamped
        // value is a cosmetically wrong line number instead of UB.
        c.body_offset = std.math.cast(u32, payload_base + (r.pos - entry.len) + er.pos) orelse
            std.math.maxInt(u32);
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
    try std.testing.expectEqual(@as(usize, 0), m.comp_types.len);
}

test "indexes a single custom section" {
    // custom section: id 0, size 1, payload = name-length 0 (empty name, no content).
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x00, 0x01, 0x00 };
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

test "rejects an undefined value-type byte" {
    // type section: one func type with a single param byte 0x50 (not a valtype;
    // 0x69–0x74 are now the GC/ref-type bytes, so pick one well outside that).
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x01, 0x50, 0x00 };
    try std.testing.expectError(error.BadValType, Module.decode(std.testing.allocator, &bytes));
}

test "rejects a reserved global-mutability byte" {
    // global section: one global i32 with mutability byte 0x02 (only 0/1 valid).
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x06, 0x04, 0x01, 0x7f, 0x02, 0x0b };
    try std.testing.expectError(error.MalformedFlag, Module.decode(std.testing.allocator, &bytes));
}

test "rejects a self-referential supertype (would otherwise hang isSubtype)" {
    // type section: one type = sub (0x50) with supertype [0] (itself), func [] -> [].
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x50, 0x01, 0x00, 0x60, 0x00, 0x00 };
    try std.testing.expectError(error.BadType, Module.decode(std.testing.allocator, &bytes));
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
    try std.testing.expectEqual(@as(usize, 1), m.comp_types.len);
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i32 }, m.comp_types[0].func.params);
    try std.testing.expectEqualSlices(types.ValType, &.{.i32}, m.comp_types[0].func.results);

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

test "decodes GC struct and array composite types (packed fields)" {
    // type section, 2 types:
    //   0: (struct (field (mut i32)) (field i64))     -> 5f 02  7f 01  7e 00
    //   1: (array (field (mut i8)))                   -> 5e  78 01
    const payload = [_]u8{ 0x02, 0x5f, 0x02, 0x7f, 0x01, 0x7e, 0x00, 0x5e, 0x78, 0x01 };
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, payload.len } ++ payload;

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.comp_types.len);
    const st = m.structFields(0).?;
    try std.testing.expectEqual(@as(usize, 2), st.len);
    try std.testing.expectEqual(StorageType{ .val = .i32 }, st[0].storage);
    try std.testing.expect(st[0].mutable);
    try std.testing.expectEqual(StorageType{ .val = .i64 }, st[1].storage);
    try std.testing.expect(!st[1].mutable);
    const arr = m.arrayField(1).?;
    try std.testing.expectEqual(StorageType.i8, arr.storage); // packed
    try std.testing.expect(arr.mutable);
    try std.testing.expect(arr.storage.isPacked());
    try std.testing.expectEqual(types.ValType.i32, arr.storage.unpacked()); // projects to i32
}

test "GC rec group: a struct field forward-references a later type (concrete ref)" {
    // (rec (struct (field (ref 1))) (struct (field i32)))
    //   01                 ; 1 rectype
    //   4e 02              ; rec group of 2 sub types
    //   5f 01  64 01 00    ; struct{ (ref $1) }  -- forward ref to type 1
    //   5f 01  7f 00       ; struct{ i32 }
    const payload = [_]u8{ 0x01, 0x4e, 0x02, 0x5f, 0x01, 0x64, 0x01, 0x00, 0x5f, 0x01, 0x7f, 0x00 };
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, payload.len } ++ payload;

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.comp_types.len);
    // The forward `(ref 1)` decodes to a non-null concrete reference to type 1
    // (the kind pre-scan sees type 1 is a struct → the struct family head).
    const f0 = m.structFields(0).?[0].storage.val;
    try std.testing.expect(f0.isConcrete());
    try std.testing.expect(f0.isNonNullRef());
    try std.testing.expectEqual(@as(u32, 1), f0.concreteIndex());
    try std.testing.expectEqual(types.ValType.RefHeap.@"struct", f0.refHeap());
    try std.testing.expectEqual(StorageType{ .val = .i32 }, m.structFields(1).?[0].storage);
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

test "reads function names from the name section" {
    // custom section "name": subsection 1 (function names) = [ (0,"hi"), (3,"bye") ].
    //   nameassoc vec: count=2, then (idx, len, bytes) each.
    const namemap = [_]u8{ 0x02, 0x00, 0x02, 'h', 'i', 0x03, 0x03, 'b', 'y', 'e' };
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        // custom section payload = namelen(1) + "name"(4) + sub0(5) + sub1(12) = 22.
        [_]u8{ 0x00, 0x16, 0x04, 'n', 'a', 'm', 'e' } ++
        [_]u8{ 0x00, 0x03, 0x02, 'm', 'd' } ++ // subsection 0 (module name) — skipped
        [_]u8{ 0x01, 0x0a } ++ namemap; // subsection 1 (function names), size 10

    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();

    try std.testing.expectEqualStrings("hi", m.funcName(0).?);
    try std.testing.expectEqualStrings("bye", m.funcName(3).?);
    try std.testing.expectEqual(@as(?[]const u8, null), m.funcName(1)); // gap in the vec
    try std.testing.expectEqual(@as(?[]const u8, null), m.funcName(9)); // past the end
}

test "a module without a name section has no names, and a malformed one is not an error" {
    // No custom section at all.
    const plain = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    var m1 = try Module.decode(std.testing.allocator, &plain);
    defer m1.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), m1.func_names);
    try std.testing.expectEqual(@as(?[]const u8, null), m1.funcName(0));

    // A name section whose function subsection is truncated mid-entry. The name
    // section is a convention, not validation: it must never fail the module,
    // and must not fail the trap report that is already reporting a failure.
    const truncated =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x00, 0x0b, 0x04, 'n', 'a', 'm', 'e' } ++
        [_]u8{ 0x01, 0x04, 0x02, 0x00, 0x05, 'h' }; // claims 2 entries + a 5-byte name, has 1 byte
    var m2 = try Module.decode(std.testing.allocator, &truncated);
    defer m2.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), m2.funcName(0)); // degrades to "no name"
}
