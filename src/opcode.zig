//! The shared WebAssembly instruction table and the byte-code → IR decoder.
//!
//! This is the single opcode authority the runtime is built around (see
//! `cmem/design-decisions.md`, interpreter architecture = Option A): the same
//! `Op` enum and `Instr` IR feed validation and, later, the switch-dispatched
//! interpreter. `decodeBody` turns a function's raw body bytes (captured in
//! `Module.Code.body`) into a flat `[]Instr` with pre-parsed immediates.
//!
//! **Scope today:** the core MVP instruction set (`0x00`–`0xC4`) plus the basic
//! reference-type ops (`ref.null`/`ref.is_null`/`ref.func`, `0xD0`–`0xD2`). The
//! `0xFC` (bulk-memory / saturating-truncation) and `0xFD` (SIMD) prefixes decode
//! to `error.UnsupportedOpcode` — a clean, documented boundary to expand from.
//! Control-flow nesting and branch-target resolution are *not* done here; that
//! belongs to validation.

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
    // Exception handling (exnref proposal, Phase 6).
    throw = 0x08, // immediate: a tag index — package operands into an exception + throw
    throw_ref = 0x0a, // rethrow the exnref on the stack (null → trap)
    try_table = 0x1f, // immediate: a block type + a vector of catch clauses
    // Typed function references (function-references proposal).
    call_ref = 0x14, // immediate: a type index (the func ref's signature)
    return_call_ref = 0x15,

    // Reference
    ref_null = 0xd0, // immediate: a heaptype byte (func / extern)
    ref_is_null = 0xd1,
    ref_func = 0xd2, // immediate: a function index
    ref_eq = 0xd3, // GC: [eqref eqref] -> [i32]
    ref_as_non_null = 0xd4,
    br_on_null = 0xd5, // immediate: a label index
    br_on_non_null = 0xd6,

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

    // Table access
    table_get = 0x25, // immediate: table index
    table_set = 0x26,

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

    // Saturating (non-trapping) float→int truncation, carried under the `0xFC`
    // prefix. LLVM/Zig emit these by default (`+nontrapping-fptoint`), so a
    // compiled module needs them. Internal tags (wire = `0xFC` + sub-opcode).
    i32_trunc_sat_f32_s = 0xc5, // 0xFC 0x00
    i32_trunc_sat_f32_u = 0xc6, // 0xFC 0x01
    i32_trunc_sat_f64_s = 0xc7, // 0xFC 0x02
    i32_trunc_sat_f64_u = 0xc8, // 0xFC 0x03
    i64_trunc_sat_f32_s = 0xc9, // 0xFC 0x04
    i64_trunc_sat_f32_u = 0xca, // 0xFC 0x05
    i64_trunc_sat_f64_s = 0xcb, // 0xFC 0x06
    i64_trunc_sat_f64_u = 0xcc, // 0xFC 0x07

    // Bulk memory (`0xFC` prefix). LLVM/Zig emit `memory.copy`/`memory.fill` for
    // memcpy/memset by default (`+bulk-memory`).
    memory_init = 0xd7, // 0xFC 0x08: [dst src n] -> [] (from a data segment)
    data_drop = 0xd8, // 0xFC 0x09: mark a data segment consumed
    memory_copy = 0xd9, // 0xFC 0x0a: [dst src n] -> []
    memory_fill = 0xda, // 0xFC 0x0b: [dst byte n] -> []

    // Table ops carried under the `0xFC` prefix. These enum values are INTERNAL
    // tags in an otherwise-unused byte range — the wire encoding is `0xFC` + a
    // LEB sub-opcode (see `fcSubOpcode` / `decodeBody`), not this byte.
    table_init = 0xe0, // 0xFC 0x0c
    elem_drop = 0xe1, // 0xFC 0x0d
    table_copy = 0xe2, // 0xFC 0x0e
    table_grow = 0xe3, // 0xFC 0x0f
    table_size = 0xe4, // 0xFC 0x10
    table_fill = 0xe5, // 0xFC 0x11

    // GC array ops carried under the `0xFB` prefix (full GC proposal, P3).
    array_new = 0xe6, // 0xFB 0x06: [t' i32] -> [(ref $t)]
    array_new_default = 0xe7, // 0xFB 0x07: [i32] -> [(ref $t)]
    array_new_fixed = 0xe8, // 0xFB 0x08: [t'^n] -> [(ref $t)]
    array_get = 0xe9, // 0xFB 0x0b: [(ref null $t) i32] -> [t']
    array_get_s = 0xea, // 0xFB 0x0c (packed)
    array_get_u = 0xeb, // 0xFB 0x0d (packed)
    array_set = 0xec, // 0xFB 0x0e: [(ref null $t) i32 t'] -> []
    array_len = 0xed, // 0xFB 0x0f: [(ref null array)] -> [i32]

    // GC ops carried under the `0xFB` prefix. Like the table ops above, these
    // enum values are INTERNAL tags in an unused byte range — the wire encoding
    // is `0xFB` + a LEB sub-opcode (see `gcSubOpcode`).
    ref_i31 = 0xf0, // 0xFB 0x1c: [i32] -> [(ref i31)]
    i31_get_s = 0xf1, // 0xFB 0x1d: [(ref null i31)] -> [i32]
    i31_get_u = 0xf2, // 0xFB 0x1e: [(ref null i31)] -> [i32]
    struct_new = 0xf3, // 0xFB 0x00: [t'*] -> [(ref $t)]
    struct_new_default = 0xf4, // 0xFB 0x01: [] -> [(ref $t)]
    struct_get = 0xf5, // 0xFB 0x02: [(ref null $t)] -> [t']
    struct_get_s = 0xf6, // 0xFB 0x03 (packed)
    struct_get_u = 0xf7, // 0xFB 0x04 (packed)
    struct_set = 0xf8, // 0xFB 0x05: [(ref null $t) t'] -> []

    // GC casts (0xFB prefix). ref.test/ref.cast carry a target reference type
    // (nullability + heap type); the null/non-null encodings collapse to one
    // internal tag distinguished by the decoded `RefType.nullable`.
    ref_test = 0xee, // 0xFB 0x14 (non-null) / 0x15 (null): [ref] -> [i32]
    ref_cast = 0xef, // 0xFB 0x16 (non-null) / 0x17 (null): [ref] -> [ref]
    br_on_cast = 0xf9, // 0xFB 0x18: branch if the ref casts to dst
    br_on_cast_fail = 0xfa, // 0xFB 0x19: branch if the ref does NOT cast to dst

    _,
};

/// A GC heap type: an abstract head or a concrete type index (§ GC binary
/// format — the operand of `ref.null`/`ref.test`/`ref.cast`/`br_on_cast`).
pub const HeapType = union(enum) {
    func,
    extern_,
    any,
    eq,
    i31,
    @"struct",
    array,
    none,
    nofunc,
    noextern,
    exn, // exception heap type (EH proposal, Phase 6)
    concrete: u32, // a type index
};

/// A reference type: a heap type plus nullability (`(ref null? ht)`).
pub const RefType = struct { nullable: bool, heap: HeapType };

/// The `0xFC` sub-opcode for an internal saturating-truncation / bulk-memory /
/// table-op tag, or null for a normal op.
pub fn fcSubOpcode(op: Op) ?u8 {
    return switch (op) {
        .i32_trunc_sat_f32_s => 0x00,
        .i32_trunc_sat_f32_u => 0x01,
        .i32_trunc_sat_f64_s => 0x02,
        .i32_trunc_sat_f64_u => 0x03,
        .i64_trunc_sat_f32_s => 0x04,
        .i64_trunc_sat_f32_u => 0x05,
        .i64_trunc_sat_f64_s => 0x06,
        .i64_trunc_sat_f64_u => 0x07,
        .memory_init => 0x08,
        .data_drop => 0x09,
        .memory_copy => 0x0a,
        .memory_fill => 0x0b,
        .table_init => 0x0c,
        .elem_drop => 0x0d,
        .table_copy => 0x0e,
        .table_grow => 0x0f,
        .table_size => 0x10,
        .table_fill => 0x11,
        else => null,
    };
}

/// The `0xFB` sub-opcode for an internal GC-op tag, or null for a normal op.
pub fn gcSubOpcode(op: Op) ?u8 {
    return switch (op) {
        .struct_new => 0x00,
        .struct_new_default => 0x01,
        .struct_get => 0x02,
        .struct_get_s => 0x03,
        .struct_get_u => 0x04,
        .struct_set => 0x05,
        .array_new => 0x06,
        .array_new_default => 0x07,
        .array_new_fixed => 0x08,
        .array_get => 0x0b,
        .array_get_s => 0x0c,
        .array_get_u => 0x0d,
        .array_set => 0x0e,
        .array_len => 0x0f,
        .ref_test => 0x14, // non-null form; the null form (0x15) is chosen at emit
        .ref_cast => 0x16, // non-null form; the null form (0x17) is chosen at emit
        .br_on_cast => 0x18,
        .br_on_cast_fail => 0x19,
        .ref_i31 => 0x1c,
        .i31_get_s => 0x1d,
        .i31_get_u => 0x1e,
        else => null,
    };
}

/// A block signature (§5.3.6): empty, a single value type, or a type index.
pub const BlockType = union(enum) {
    empty,
    value: types.ValType,
    type_index: u32,
};

pub const MemArg = struct { alignment: u32, offset: u32 };
pub const BrTable = struct { labels: []const u32, default: u32 };
pub const CallIndirect = struct { type_index: u32, table: u32 };

/// A `try_table` catch clause (EH proposal). On a thrown exception whose tag
/// matches (or `catch_all`), control branches to `label` with the exception's
/// values pushed — plus the `exnref` itself for the `_ref` variants.
pub const CatchKind = enum { catch_, catch_ref, catch_all, catch_all_ref };
pub const Catch = struct { kind: CatchKind, tag: u32 = 0, label: u32 };
pub const TryTable = struct { block_type: BlockType, catches: []const Catch };

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
    table: u32,
    /// `elem.drop` — a passive element-segment index.
    elem: u32,
    /// `memory.init` / `data.drop` — a data-segment index.
    data: u32,
    /// `table.init` — element-segment index + destination table index.
    table_init: struct { elem: u32, table: u32 },
    /// `table.copy` — destination + source table indices.
    table_copy: struct { dst: u32, src: u32 },
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
    /// Heap type of `ref.null` (`0xd0`) — abstract head or a concrete type index;
    /// the validator resolves it to a (possibly concrete) nullable value type.
    ref_type: HeapType,
    /// A GC type index (`struct.new`/`array.new`/`array.get`/…).
    gc_type: u32,
    /// A GC struct type index + field index (`struct.get`/`struct.set`/…).
    gc_field: struct { type_index: u32, field: u32 },
    /// A GC array type index + element count (`array.new_fixed`).
    gc_type_n: struct { type_index: u32, n: u32 },
    /// A GC cast target reference type (`ref.test` / `ref.cast`).
    ref_cast: RefType,
    /// A GC cast-branch (`br_on_cast` / `br_on_cast_fail`): a label + the source
    /// and destination reference types.
    br_cast: struct { label: u32, src: RefType, dst: RefType },
    /// `throw` — an exception tag index.
    tag: u32,
    /// `try_table` — a block type + its catch clauses.
    try_table: TryTable,
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
    table,
    elem,
    /// `data.drop` — a data index.
    data,
    /// `memory.init` — a data index + a reserved memory byte.
    data_init,
    /// `memory.copy` — two reserved memory bytes (dst, src).
    mem_copy,
    table_init,
    table_copy,
    mem,
    mem_reserved,
    i32c,
    i64c,
    f32c,
    f64c,
    select_types,
    ref_type,
    gc_type,
    gc_field,
    gc_type_n,
    ref_cast,
    br_cast,
    tag,
    try_table,
    unsupported,
};

/// Classify an opcode's immediate. Reused by the decoder (and, later, by any
/// pass that needs to walk instructions without fully decoding them).
pub fn immediateKind(op: Op) ImmKind {
    return switch (@intFromEnum(op)) {
        0x02, 0x03, 0x04 => .block_type,
        0x08 => .tag, // throw <tagidx>
        0x0a => .none, // throw_ref
        0x1f => .try_table, // try_table <blocktype> vec(catch)
        0x0c, 0x0d => .label,
        0x0e => .br_table,
        0x10 => .func,
        0x11 => .call_indirect,
        0x14, 0x15 => .func, // call_ref / return_call_ref — imm.func = type index
        0xd5, 0xd6 => .label, // br_on_null / br_on_non_null
        0x20, 0x21, 0x22 => .local,
        0x23, 0x24 => .global,
        0x25, 0x26, 0xe3, 0xe4, 0xe5 => .table, // table.get/set + table.grow/size/fill
        0xe0 => .table_init,
        0xe1 => .elem, // elem.drop
        0xe2 => .table_copy,
        0xd7 => .data_init, // memory.init: data index + reserved mem byte
        0xd8 => .data, // data.drop: data index
        0xd9 => .mem_copy, // memory.copy: two reserved mem bytes
        0xda => .mem_reserved, // memory.fill: one reserved mem byte
        0x28...0x3e => .mem,
        0x3f, 0x40 => .mem_reserved,
        0x41 => .i32c,
        0x42 => .i64c,
        0x43 => .f32c,
        0x44 => .f64c,
        0x1c => .select_types,
        0xd0 => .ref_type, // ref.null <heaptype>
        0xd2 => .func, // ref.func <funcidx>
        // Everything else in the core-MVP range has no immediate; `0xc5…0xcc` are
        // the saturating-truncation tags (also immediate-free).
        0x00, 0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b, 0xd1, 0xd3, 0xd4, 0x45...0xcc => .none,
        // GC ops with no immediate: ref.i31/i31.get_s/i31.get_u, array.len.
        0xf0, 0xf1, 0xf2, 0xed => .none,
        // GC ops with a single type index.
        0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec, 0xf3, 0xf4 => .gc_type,
        // GC struct ops with a type index + field index.
        0xf5, 0xf6, 0xf7, 0xf8 => .gc_field,
        // array.new_fixed: type index + element count.
        0xe8 => .gc_type_n,
        // ref.test / ref.cast: a target reference type.
        0xee, 0xef => .ref_cast,
        // br_on_cast / br_on_cast_fail: a label + source & destination ref types.
        0xf9, 0xfa => .br_cast,
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
        -16 => .{ .value = .funcref }, // 0x70
        -17 => .{ .value = .externref }, // 0x6f
        -18 => .{ .value = .anyref }, // 0x6e
        -19 => .{ .value = .eqref }, // 0x6d
        -20 => .{ .value = .i31ref }, // 0x6c
        -21 => .{ .value = .structref }, // 0x6b
        -22 => .{ .value = .arrayref }, // 0x6a
        -23 => .{ .value = .exnref }, // 0x69 (exception ref)
        -15 => .{ .value = .nullref }, // 0x71 (none)
        -24 => .{ .value = .funcref_nn }, // 0x68 (our synthetic non-null tags)
        -25 => .{ .value = .externref_nn }, // 0x67
        -26 => .{ .value = .anyref_nn }, // 0x66
        -27 => .{ .value = .eqref_nn }, // 0x65
        -30 => .{ .value = .i31ref_nn }, // 0x62
        -31 => .{ .value = .structref_nn }, // 0x61
        -39 => .{ .value = .arrayref_nn }, // 0x59
        -40 => .{ .value = .nullref_nn }, // 0x58
        -41 => .{ .value = .exnref_nn }, // 0x57 (synthetic non-null exn ref)
        else => error.UnsupportedOpcode,
    };
}

/// Read a GC struct-op immediate: a struct type index followed by a field index.
fn readGcField(r: *Reader) DecodeError!Imm {
    const ti = try r.readVarU32();
    const f = try r.readVarU32();
    return .{ .gc_field = .{ .type_index = ti, .field = f } };
}

/// Read a `br_on_cast`/`br_on_cast_fail` immediate: a flags byte (bit 0 = src
/// nullable, bit 1 = dst nullable), a label index, then the src & dst heap types.
fn readBrCast(r: *Reader) DecodeError!Imm {
    const flags = try r.readByte();
    const label = try r.readVarU32();
    const src_ht = try readHeapType(r);
    const dst_ht = try readHeapType(r);
    return .{ .br_cast = .{
        .label = label,
        .src = .{ .nullable = flags & 0b01 != 0, .heap = src_ht },
        .dst = .{ .nullable = flags & 0b10 != 0, .heap = dst_ht },
    } };
}

/// Read a `try_table` immediate: a block type followed by a vector of catch
/// clauses. Each clause is a kind byte (0=catch, 1=catch_ref, 2=catch_all,
/// 3=catch_all_ref), a tag index for the non-`all` kinds, then a label index.
fn readTryTable(r: *Reader, a: std.mem.Allocator) (DecodeError || std.mem.Allocator.Error)!Imm {
    const bt = try readBlockType(r);
    const n = try r.readVarU32();
    const catches = try a.alloc(Catch, n);
    for (catches) |*c| {
        const kind: CatchKind = switch (try r.readByte()) {
            0x00 => .catch_,
            0x01 => .catch_ref,
            0x02 => .catch_all,
            0x03 => .catch_all_ref,
            else => return error.UnsupportedOpcode,
        };
        const tag: u32 = switch (kind) {
            .catch_, .catch_ref => try r.readVarU32(),
            .catch_all, .catch_all_ref => 0,
        };
        c.* = .{ .kind = kind, .tag = tag, .label = try r.readVarU32() };
    }
    return .{ .try_table = .{ .block_type = bt, .catches = catches } };
}

/// Read a heap type (§ GC binary format): a non-negative `s33` is a concrete
/// type index; negative values are the abstract heap-type codes.
pub fn readHeapType(r: *Reader) DecodeError!HeapType {
    const v = try r.readVarI64(); // s33
    if (v >= 0) return .{ .concrete = @intCast(v) };
    return switch (v) {
        -0x10 => .func,
        -0x11 => .extern_,
        -0x12 => .any,
        -0x13 => .eq,
        -0x14 => .i31,
        -0x15 => .@"struct",
        -0x16 => .array,
        -0x0f => .none,
        -0x0d => .nofunc,
        -0x0e => .noextern,
        -0x17 => .exn, // 0x69
        else => error.UnsupportedOpcode,
    };
}

/// Decode a function body's raw bytes into a flat instruction list. The result
/// is allocated from `a` (typically the module's arena). Nesting and branch
/// targets are left to validation.
pub fn decodeBody(a: std.mem.Allocator, body: []const u8) (DecodeError || std.mem.Allocator.Error)![]const Instr {
    return decodeBodyTracked(a, body, null);
}

/// `decodeBody`, additionally recording each instruction's **byte offset within
/// `body`** into `offsets` (positionally aligned with the returned IR).
///
/// Decoding to an IR throws the original byte offsets away, but a trap has to
/// report one: the C API's `wasm_frame_func_offset` is specified as a byte
/// offset, and an IR index there would be a plausible-looking lie. Offsets live
/// in a parallel array rather than in `Instr` so the dispatch loop's working set
/// is unchanged — nothing reads them except a trap report.
pub fn decodeBodyTracked(
    a: std.mem.Allocator,
    body: []const u8,
    offsets: ?*std.ArrayList(u32),
) (DecodeError || std.mem.Allocator.Error)![]const Instr {
    var r = Reader.init(body);
    var list: std.ArrayList(Instr) = .empty;
    errdefer list.deinit(a);

    while (!r.atEnd()) {
        // Where this instruction starts, before its opcode byte is consumed.
        if (offsets) |o| try o.append(a, @intCast(r.pos));
        const b0 = try r.readByte();
        if (b0 == 0xfb) {
            // 0xFB-prefixed GC op: a LEB sub-opcode picks the internal Op tag,
            // then its immediates (a type index, a type+field, or a type+count).
            const instr: Instr = switch (try r.readVarU32()) {
                0x00 => .{ .op = .struct_new, .imm = .{ .gc_type = try r.readVarU32() } },
                0x01 => .{ .op = .struct_new_default, .imm = .{ .gc_type = try r.readVarU32() } },
                0x02 => .{ .op = .struct_get, .imm = try readGcField(&r) },
                0x03 => .{ .op = .struct_get_s, .imm = try readGcField(&r) },
                0x04 => .{ .op = .struct_get_u, .imm = try readGcField(&r) },
                0x05 => .{ .op = .struct_set, .imm = try readGcField(&r) },
                0x06 => .{ .op = .array_new, .imm = .{ .gc_type = try r.readVarU32() } },
                0x07 => .{ .op = .array_new_default, .imm = .{ .gc_type = try r.readVarU32() } },
                0x08 => .{ .op = .array_new_fixed, .imm = .{ .gc_type_n = .{ .type_index = try r.readVarU32(), .n = try r.readVarU32() } } },
                0x0b => .{ .op = .array_get, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0c => .{ .op = .array_get_s, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0d => .{ .op = .array_get_u, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0e => .{ .op = .array_set, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0f => .{ .op = .array_len, .imm = .none },
                0x14 => .{ .op = .ref_test, .imm = .{ .ref_cast = .{ .nullable = false, .heap = try readHeapType(&r) } } },
                0x15 => .{ .op = .ref_test, .imm = .{ .ref_cast = .{ .nullable = true, .heap = try readHeapType(&r) } } },
                0x16 => .{ .op = .ref_cast, .imm = .{ .ref_cast = .{ .nullable = false, .heap = try readHeapType(&r) } } },
                0x17 => .{ .op = .ref_cast, .imm = .{ .ref_cast = .{ .nullable = true, .heap = try readHeapType(&r) } } },
                0x18 => .{ .op = .br_on_cast, .imm = try readBrCast(&r) },
                0x19 => .{ .op = .br_on_cast_fail, .imm = try readBrCast(&r) },
                0x1c => .{ .op = .ref_i31, .imm = .none },
                0x1d => .{ .op = .i31_get_s, .imm = .none },
                0x1e => .{ .op = .i31_get_u, .imm = .none },
                else => return error.UnsupportedOpcode,
            };
            try list.append(a, instr);
            continue;
        }
        if (b0 == 0xfc) {
            // 0xFC-prefixed op: a LEB sub-opcode picks the internal Op tag.
            const imm: Instr = switch (try r.readVarU32()) {
                // Saturating truncation — no immediates.
                0x00 => .{ .op = .i32_trunc_sat_f32_s, .imm = .none },
                0x01 => .{ .op = .i32_trunc_sat_f32_u, .imm = .none },
                0x02 => .{ .op = .i32_trunc_sat_f64_s, .imm = .none },
                0x03 => .{ .op = .i32_trunc_sat_f64_u, .imm = .none },
                0x04 => .{ .op = .i64_trunc_sat_f32_s, .imm = .none },
                0x05 => .{ .op = .i64_trunc_sat_f32_u, .imm = .none },
                0x06 => .{ .op = .i64_trunc_sat_f64_s, .imm = .none },
                0x07 => .{ .op = .i64_trunc_sat_f64_u, .imm = .none },
                // Bulk memory. The trailing memory indices are reserved (always 0
                // until multi-memory); read and discard them.
                0x08 => blk: {
                    const d = try r.readVarU32();
                    _ = try r.readByte(); // reserved memory index
                    break :blk .{ .op = .memory_init, .imm = .{ .data = d } };
                },
                0x09 => .{ .op = .data_drop, .imm = .{ .data = try r.readVarU32() } },
                0x0a => blk: {
                    _ = try r.readByte(); // reserved dst memory index
                    _ = try r.readByte(); // reserved src memory index
                    break :blk .{ .op = .memory_copy, .imm = .none };
                },
                0x0b => .{ .op = .memory_fill, .imm = .{ .mem_reserved = try r.readByte() } },
                0x0c => .{ .op = .table_init, .imm = .{ .table_init = .{ .elem = try r.readVarU32(), .table = try r.readVarU32() } } },
                0x0d => .{ .op = .elem_drop, .imm = .{ .elem = try r.readVarU32() } },
                0x0e => .{ .op = .table_copy, .imm = .{ .table_copy = .{ .dst = try r.readVarU32(), .src = try r.readVarU32() } } },
                0x0f => .{ .op = .table_grow, .imm = .{ .table = try r.readVarU32() } },
                0x10 => .{ .op = .table_size, .imm = .{ .table = try r.readVarU32() } },
                0x11 => .{ .op = .table_fill, .imm = .{ .table = try r.readVarU32() } },
                else => return error.UnsupportedOpcode,
            };
            try list.append(a, imm);
            continue;
        }
        const op: Op = @enumFromInt(b0);
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
            .table => .{ .table = try r.readVarU32() },
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
            .ref_type => .{ .ref_type = try readHeapType(&r) },
            .tag => .{ .tag = try r.readVarU32() },
            .try_table => try readTryTable(&r, a),
            // These are `0xFC`-prefixed ops decoded via the interception above;
            // reaching here means a raw synthetic-tag byte, which is malformed.
            // 0xFB/0xFC-prefixed ops are decoded via the prefix interceptions
            // above; reaching here means a raw synthetic-tag byte (malformed).
            .elem, .data, .data_init, .mem_copy, .table_init, .table_copy, .gc_type, .gc_field, .gc_type_n, .ref_cast, .br_cast => return error.UnsupportedOpcode,
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
