//! The shared WebAssembly instruction table and the byte-code → IR decoder.
//!
//! This is the single opcode authority the runtime is built around (see
//! `cmem/design-decisions.md`, interpreter architecture = Option A): the same
//! `Op` enum and `Instr` IR feed validation and, later, the switch-dispatched
//! interpreter. `decodeBody` turns a function's raw body bytes (captured in
//! `Module.Code.body`) into a flat `[]Instr` with pre-parsed immediates.
//!
//! **Scope today:** the core MVP instruction set (`0x00`–`0xC4`). Reference-type
//! ops, the `0xFC` (bulk-memory / saturating-truncation) and `0xFD` (SIMD)
//! prefixes, and multi-byte block-type indices decode to `error.UnsupportedOpcode`
//! — a clean, documented boundary to expand from. Control-flow nesting and
//! branch-target resolution are *not* done here; that belongs to validation.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");

const DecodeError = types.DecodeError;

/// Every core-MVP opcode, keyed by its binary byte (§5.4). Non-exhaustive so an
/// unrecognized byte decodes to a value that `decodeBody` rejects.
pub const Op = enum(u8) {
    // Control
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,
    end = 0x0b,
    br = 0x0c,
    br_if = 0x0d,
    br_table = 0x0e,
    @"return" = 0x0f,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1a,
    select = 0x1b,
    select_t = 0x1c, // typed select: immediate is a vec of result types

    // Variable
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Memory
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2a,
    f64_load = 0x2b,
    i32_load8_s = 0x2c,
    i32_load8_u = 0x2d,
    i32_load16_s = 0x2e,
    i32_load16_u = 0x2f,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3a,
    i32_store16 = 0x3b,
    i64_store8 = 0x3c,
    i64_store16 = 0x3d,
    i64_store32 = 0x3e,
    memory_size = 0x3f,
    memory_grow = 0x40,

    // Numeric constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // Comparison — i32
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4a,
    i32_gt_u = 0x4b,
    i32_le_s = 0x4c,
    i32_le_u = 0x4d,
    i32_ge_s = 0x4e,
    i32_ge_u = 0x4f,
    // Comparison — i64
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5a,
    // Comparison — f32
    f32_eq = 0x5b,
    f32_ne = 0x5c,
    f32_lt = 0x5d,
    f32_gt = 0x5e,
    f32_le = 0x5f,
    f32_ge = 0x60,
    // Comparison — f64
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,

    // Numeric — i32
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6a,
    i32_sub = 0x6b,
    i32_mul = 0x6c,
    i32_div_s = 0x6d,
    i32_div_u = 0x6e,
    i32_rem_s = 0x6f,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,
    // Numeric — i64
    i64_clz = 0x79,
    i64_ctz = 0x7a,
    i64_popcnt = 0x7b,
    i64_add = 0x7c,
    i64_sub = 0x7d,
    i64_mul = 0x7e,
    i64_div_s = 0x7f,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8a,
    // Numeric — f32
    f32_abs = 0x8b,
    f32_neg = 0x8c,
    f32_ceil = 0x8d,
    f32_floor = 0x8e,
    f32_trunc = 0x8f,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,
    // Numeric — f64
    f64_abs = 0x99,
    f64_neg = 0x9a,
    f64_ceil = 0x9b,
    f64_floor = 0x9c,
    f64_trunc = 0x9d,
    f64_nearest = 0x9e,
    f64_sqrt = 0x9f,
    f64_add = 0xa0,
    f64_sub = 0xa1,
    f64_mul = 0xa2,
    f64_div = 0xa3,
    f64_min = 0xa4,
    f64_max = 0xa5,
    f64_copysign = 0xa6,

    // Conversions
    i32_wrap_i64 = 0xa7,
    i32_trunc_f32_s = 0xa8,
    i32_trunc_f32_u = 0xa9,
    i32_trunc_f64_s = 0xaa,
    i32_trunc_f64_u = 0xab,
    i64_extend_i32_s = 0xac,
    i64_extend_i32_u = 0xad,
    i64_trunc_f32_s = 0xae,
    i64_trunc_f32_u = 0xaf,
    i64_trunc_f64_s = 0xb0,
    i64_trunc_f64_u = 0xb1,
    f32_convert_i32_s = 0xb2,
    f32_convert_i32_u = 0xb3,
    f32_convert_i64_s = 0xb4,
    f32_convert_i64_u = 0xb5,
    f32_demote_f64 = 0xb6,
    f64_convert_i32_s = 0xb7,
    f64_convert_i32_u = 0xb8,
    f64_convert_i64_s = 0xb9,
    f64_convert_i64_u = 0xba,
    f64_promote_f32 = 0xbb,
    i32_reinterpret_f32 = 0xbc,
    i64_reinterpret_f64 = 0xbd,
    f32_reinterpret_i32 = 0xbe,
    f64_reinterpret_i64 = 0xbf,

    // Sign extension
    i32_extend8_s = 0xc0,
    i32_extend16_s = 0xc1,
    i64_extend8_s = 0xc2,
    i64_extend16_s = 0xc3,
    i64_extend32_s = 0xc4,

    _,
};

/// A block signature (§5.3.6): empty, a single value type, or a type index.
pub const BlockType = union(enum) {
    empty,
    value: types.ValType,
    type_index: u32,
};

pub const MemArg = struct { alignment: u32, offset: u32 };
pub const BrTable = struct { labels: []const u32, default: u32 };
pub const CallIndirect = struct { type_index: u32, table: u32 };

/// A decoded instruction immediate.
pub const Imm = union(enum) {
    none,
    block_type: BlockType,
    label: u32,
    br_table: BrTable,
    func: u32,
    call_indirect: CallIndirect,
    local: u32,
    global: u32,
    mem: MemArg,
    /// Reserved byte of `memory.size` / `memory.grow` (the memory index, 0).
    mem_reserved: u8,
    i32: i32,
    i64: i64,
    /// Raw little-endian bit pattern (`f32.const` / `f64.const`).
    f32: u32,
    f64: u64,
    /// Result types of a typed `select` (`0x1c`).
    select_types: []const types.ValType,
};

pub const Instr = struct { op: Op, imm: Imm };

const ImmKind = enum {
    none,
    block_type,
    label,
    br_table,
    func,
    call_indirect,
    local,
    global,
    mem,
    mem_reserved,
    i32c,
    i64c,
    f32c,
    f64c,
    select_types,
    unsupported,
};

/// Classify an opcode's immediate. Reused by the decoder (and, later, by any
/// pass that needs to walk instructions without fully decoding them).
pub fn immediateKind(op: Op) ImmKind {
    return switch (@intFromEnum(op)) {
        0x02, 0x03, 0x04 => .block_type,
        0x0c, 0x0d => .label,
        0x0e => .br_table,
        0x10 => .func,
        0x11 => .call_indirect,
        0x20, 0x21, 0x22 => .local,
        0x23, 0x24 => .global,
        0x28...0x3e => .mem,
        0x3f, 0x40 => .mem_reserved,
        0x41 => .i32c,
        0x42 => .i64c,
        0x43 => .f32c,
        0x44 => .f64c,
        0x1c => .select_types,
        // Everything else in the core-MVP range has no immediate.
        0x00, 0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b, 0x45...0xc4 => .none,
        else => .unsupported,
    };
}

/// Decode a block type (§5.3.6): an s33 — negative values encode empty/valtype,
/// non-negative values are a type index.
fn readBlockType(r: *Reader) DecodeError!BlockType {
    const v = try r.readVarI64();
    if (v >= 0) return .{ .type_index = @intCast(v) };
    return switch (v) {
        -64 => .empty,
        -1 => .{ .value = .i32 },
        -2 => .{ .value = .i64 },
        -3 => .{ .value = .f32 },
        -4 => .{ .value = .f64 },
        -5 => .{ .value = .v128 },
        -16 => .{ .value = .funcref },
        -17 => .{ .value = .externref },
        else => error.UnsupportedOpcode,
    };
}

/// Decode a function body's raw bytes into a flat instruction list. The result
/// is allocated from `a` (typically the module's arena). Nesting and branch
/// targets are left to validation.
pub fn decodeBody(a: std.mem.Allocator, body: []const u8) (DecodeError || std.mem.Allocator.Error)![]const Instr {
    var r = Reader.init(body);
    var list: std.ArrayList(Instr) = .empty;
    errdefer list.deinit(a);

    while (!r.atEnd()) {
        const op: Op = @enumFromInt(try r.readByte());
        const imm: Imm = switch (immediateKind(op)) {
            .none => .none,
            .block_type => .{ .block_type = try readBlockType(&r) },
            .label => .{ .label = try r.readVarU32() },
            .br_table => blk: {
                const n = try r.readVarU32();
                const labels = try a.alloc(u32, n);
                for (labels) |*l| l.* = try r.readVarU32();
                break :blk .{ .br_table = .{ .labels = labels, .default = try r.readVarU32() } };
            },
            .func => .{ .func = try r.readVarU32() },
            .call_indirect => blk: {
                const ti = try r.readVarU32();
                const tb = try r.readVarU32();
                break :blk .{ .call_indirect = .{ .type_index = ti, .table = tb } };
            },
            .local => .{ .local = try r.readVarU32() },
            .global => .{ .global = try r.readVarU32() },
            .mem => blk: {
                const al = try r.readVarU32();
                const of = try r.readVarU32();
                break :blk .{ .mem = .{ .alignment = al, .offset = of } };
            },
            .mem_reserved => .{ .mem_reserved = try r.readByte() },
            .i32c => .{ .i32 = try r.readVarI32() },
            .i64c => .{ .i64 = try r.readVarI64() },
            .f32c => .{ .f32 = try r.readF32Bits() },
            .f64c => .{ .f64 = try r.readF64Bits() },
            .select_types => blk: {
                const n = try r.readVarU32();
                const tys = try a.alloc(types.ValType, n);
                for (tys) |*t| t.* = @enumFromInt(try r.readByte());
                break :blk .{ .select_types = tys };
            },
            .unsupported => return error.UnsupportedOpcode,
        };
        try list.append(a, .{ .op = op, .imm = imm });
    }
    return list.toOwnedSlice(a);
}

// --- Tests -----------------------------------------------------------------

test "decodes a simple body: local.get local.get i32.add end" {
    const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b };
    const instrs = try decodeBody(std.testing.allocator, &body);
    defer std.testing.allocator.free(instrs);

    try std.testing.expectEqual(@as(usize, 4), instrs.len);
    try std.testing.expectEqual(Op.local_get, instrs[0].op);
    try std.testing.expectEqual(@as(u32, 0), instrs[0].imm.local);
    try std.testing.expectEqual(Op.local_get, instrs[1].op);
    try std.testing.expectEqual(@as(u32, 1), instrs[1].imm.local);
    try std.testing.expectEqual(Op.i32_add, instrs[2].op);
    try std.testing.expectEqual(Imm.none, instrs[2].imm);
    try std.testing.expectEqual(Op.end, instrs[3].op);
}

test "decodes immediates: block, const, and a memory load" {
    // block (result i32) ; i32.const -3 ; i32.load align=2 offset=8 ; end
    const body = [_]u8{ 0x02, 0x7f, 0x41, 0x7d, 0x28, 0x02, 0x08, 0x0b };
    const instrs = try decodeBody(std.testing.allocator, &body);
    defer std.testing.allocator.free(instrs);

    try std.testing.expectEqual(@as(usize, 4), instrs.len);
    try std.testing.expectEqual(BlockType{ .value = .i32 }, instrs[0].imm.block_type);
    try std.testing.expectEqual(@as(i32, -3), instrs[1].imm.i32);
    try std.testing.expectEqual(@as(u32, 2), instrs[2].imm.mem.alignment);
    try std.testing.expectEqual(@as(u32, 8), instrs[2].imm.mem.offset);
    try std.testing.expectEqual(Op.end, instrs[3].op);
}

test "decodes a br_table" {
    // br_table 0 1 (default 2)
    const body = [_]u8{ 0x0e, 0x02, 0x00, 0x01, 0x02 };
    const instrs = try decodeBody(std.testing.allocator, &body);
    defer std.testing.allocator.free(instrs);
    defer std.testing.allocator.free(instrs[0].imm.br_table.labels);

    try std.testing.expectEqual(@as(usize, 1), instrs.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, instrs[0].imm.br_table.labels);
    try std.testing.expectEqual(@as(u32, 2), instrs[0].imm.br_table.default);
}

test "rejects an unsupported opcode (SIMD prefix)" {
    const body = [_]u8{0xfd};
    try std.testing.expectError(error.UnsupportedOpcode, decodeBody(std.testing.allocator, &body));
}
