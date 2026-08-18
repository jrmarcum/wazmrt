//! The shared WebAssembly instruction table and the byte-code → IR decoder.
//!
//! This is the single opcode authority the runtime is built around (see
//! `cmem/design-decisions.md`, interpreter architecture = Option A): the same
//! `Op` enum and `Instr` IR feed validation and, later, the switch-dispatched
//! interpreter. `decodeBody` turns a function's raw body bytes (captured in
//! `Module.Code.body`) into a flat `[]Instr` with pre-parsed immediates.
//!
//! **Scope today (corrected 2026-07-21 — this header had gone badly stale):**
//! the core instruction set (`0x00`–`0xC4`), the reference-type and typed-ref
//! ops (`0xD0`–`0xD6`), the **complete** `0xFC` prefix (saturating truncation,
//! bulk memory, table ops), the **complete** `0xFD` SIMD set, the `0xFB` GC ops,
//! and exception handling in both encodings. The old claim that `0xFC`/`0xFD`
//! "decode to `error.UnsupportedOpcode`" has been false since Phase 1 / Phase 8.
//!
//! **`Op` values `0xD7`–`0xFA` are INTERNAL tags**, not wire bytes: they name ops
//! whose real encoding is `0xFB`/`0xFC` + a LEB sub-opcode. `decodeBody` rejects
//! a raw byte in that range — accepting one executed a non-standard encoding as
//! a real instruction (see `cmem/design-decisions.md`, "guard the property, not
//! a proxy for it").
//!
//! Control-flow nesting and branch-target resolution are *not* done here; that
//! belongs to validation.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");

const DecodeError = types.DecodeError;

/// Every core-MVP opcode, keyed by its binary byte (§5.4). Non-exhaustive so an
/// unrecognized byte decodes to a value that `decodeBody` rejects.
pub const Op = enum(u16) {
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
    // Tail calls (tail-call proposal). Same immediates as `call`/`call_indirect`;
    // the callee REPLACES this frame rather than nesting inside it, so its
    // results must be the current function's results.
    return_call = 0x12,
    return_call_indirect = 0x13,
    // Exception handling (exnref proposal, Phase 6).
    throw = 0x08, // immediate: a tag index — package operands into an exception + throw
    throw_ref = 0x0a, // rethrow the exnref on the stack (null → trap)
    try_table = 0x1f, // immediate: a block type + a vector of catch clauses
    // Legacy exception handling (older LLVM/toolchains, Phase 6.3). `try` opens a
    // block whose inline `catch`/`catch_all` handlers follow the body; `rethrow`
    // re-raises a caught exception by label; `delegate` forwards to an outer try.
    try_ = 0x06, // immediate: a block type
    catch_ = 0x07, // immediate: a tag index — an inline handler for that tag
    rethrow = 0x09, // immediate: a label (which enclosing try's caught exception)
    delegate = 0x18, // immediate: a label (forward to an outer try)
    catch_all = 0x19, // an inline handler for any tag
    // Typed function references (function-references proposal).
    call_ref = 0x14, // immediate: a type index (the func ref's signature)
    return_call_ref = 0x15,

    // GC: the extern↔any bridge (`0xFB 0x1a` / `0x1b`). INTERNAL tags in the
    // unassigned `0x16`/`0x17` slots — the wire form is the `0xFB` prefix, and
    // `decodeBody` rejects the raw bytes alongside the other tag ranges.
    //
    // ⚠️ These existed ONLY in the constant-expression path (`validateConstExpr`
    // and `evalConstExpr`) — there was no `Op`, so a function BODY using them was
    // `UnknownInstr` at the assembler and undecodable after it. One missing
    // mnemonic pair failed the first module of `ref_test`, `ref_cast`,
    // `br_on_cast`, `br_on_cast_fail` and `extern`, blacking out **172
    // assertions**. A feature implemented for one of its two contexts reads as
    // implemented.
    extern_convert_any = 0x16, // 0xFB 0x1a: [(ref null? any)] -> [(ref null? extern)]
    any_convert_extern = 0x17, // 0xFB 0x1b: [(ref null? extern)] -> [(ref null? any)]

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
    /// All `0xFD`-prefixed fixed-width SIMD (v128) ops share this tag; the
    /// specific operation is `imm.simd.sub` (the 0xFD sub-opcode). Using one tag
    /// keeps the ~236-op family out of the u8 `Op` space.
    simd = 0xdb,
    /// All `0xFE`-prefixed atomic (threads proposal) ops share this tag; the
    /// specific operation is `imm.atomic.sub` (the 0xFE sub-opcode). One tag keeps
    /// the ~66-op family out of the u8 `Op` space (mirrors `simd`).
    atomic = 0xdc,
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
    // The array bulk ops. These were absent from this table entirely until R3
    // (2026-08-13) — GC shipped as a targeted proposal with a sixth of its array
    // instructions missing, and every `.wast` reaching one died at the ASSEMBLER
    // (`UnknownInstr`), which cascaded 197 further assertions into skips.
    array_new_data = 0xdd, // 0xFB 0x09: [i32 i32] -> [(ref $t)] (offset, size)
    array_new_elem = 0xde, // 0xFB 0x0a: [i32 i32] -> [(ref $t)] (offset, size)
    array_fill = 0xdf, // 0xFB 0x10: [(ref null $t) i32 t' i32] -> []
    array_copy = 0xcd, // 0xFB 0x11: [(ref null $t1) i32 (ref null $t2) i32 i32] -> []
    array_init_data = 0xce, // 0xFB 0x12: [(ref null $t) i32 i32 i32] -> []
    array_init_elem = 0xcf, // 0xFB 0x13: [(ref null $t) i32 i32 i32] -> []

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

    // --- custom-descriptors (Tracks D3/D4) -----------------------------------
    //
    // 🔑 **THESE TAGS LIVE ABOVE `0xff`, AND THAT IS THE POINT.** `Op` is
    // `enum(u16)` (widened by D4), so `@enumFromInt(b0)` on a wire BYTE can never
    // produce one of them — no raw-byte guard is needed, or even possible. Every
    // tag below `0x100` is a pre-widening one, kept where it is only because
    // `immediateKind`/`simpleSig` switch on those literal values; those still
    // depend on `decodeBody`'s guard, which has been wrong three times (R3's
    // `0xc5..0xcc`, R10's `0x16`/`0x17`, and a fourth arm D3 added then removed
    // as redundant). **Add new internal tags HERE, never below `0x100`.**
    //
    // D3 originally took `0x1d`/`0x1e`/`0x27` — the last three unassigned bytes —
    // and D4 needed three more, which is what forced the widening.
    struct_new_desc = 0x100, // 0xFB 0x20: [t'* (ref null (exact $d))] -> [(ref (exact $t))]
    struct_new_default_desc = 0x101, // 0xFB 0x21: [(ref null (exact $d))] -> [(ref (exact $t))]
    ref_get_desc = 0x102, // 0xFB 0x22: [(ref null $t)] -> [(ref exact? $d)]
    /// 0xFB 0x23 (non-null) / 0x24 (null) — the two encodings collapse to one tag,
    /// distinguished by the decoded `RefType.nullable`, exactly as `ref_cast` does.
    /// `[(ref null? any) (ref null? $d)] -> [ref]`: casts only when the value's
    /// DESCRIPTOR is the very object supplied, not merely one of the right type.
    ref_cast_desc_eq = 0x103,
    /// 0xFB 0x25 / 0x26 — `br_on_cast` and its `_fail` twin plus a descriptor
    /// operand: a label, source & destination ref types, and the same identity
    /// comparison `ref_cast_desc_eq` makes.
    br_on_cast_desc_eq = 0x104,
    br_on_cast_desc_eq_fail = 0x105,

    // Wide arithmetic (`0xFC` prefix, sub-opcodes `0x13`–`0x16`). 128-bit add/sub and
    // 64×64→128 multiply, each producing TWO i64 results — so every one of them needs
    // multi-value, and none of them has an immediate.
    //
    // 🔑 **The sub-opcode numbers are READ OFF THE SPEC TESTSUITE, not inferred.**
    // `wide-arithmetic.wast` contains a `(module binary …)` whose whole purpose is overlong
    // LEB encodings of these four: `\fc\93\80\00`, `\fc\94\00`, `\fc\95\80\80\80\00`,
    // `\fc\96\80\80\00` — which decode to 0x13, 0x14, 0x15, 0x16. ⚠️ **Our assembler is not
    // an oracle for our decoder**: a self-consistent wrong number would have passed every
    // text assertion in that file and still been wrong on the wire, so the number had to come
    // from outside wazmrt. That module is now also a conformance test of these constants.
    //
    // ⚠️ **Operand and result order is (lo, hi), lo DEEPEST.** `i64.add128` takes
    // `[a_lo a_hi b_lo b_hi]` and returns `[r_lo r_hi]`; the file pins it —
    // `(1,2)+(3,4) = (4,6)` is `{hi:2,lo:1} + {hi:4,lo:3} = {hi:6,lo:4}`. Getting this
    // backwards still type-checks (every operand is an i64) and every arity test still
    // passes, which is exactly the shape of defect the corpus catches and unit tests do not.
    i64_add128 = 0x106, // 0xFC 0x13: [i64 i64 i64 i64] -> [i64 i64]
    i64_sub128 = 0x107, // 0xFC 0x14: [i64 i64 i64 i64] -> [i64 i64]
    i64_mul_wide_s = 0x108, // 0xFC 0x15: [i64 i64] -> [i64 i64]
    i64_mul_wide_u = 0x109, // 0xFC 0x16: [i64 i64] -> [i64 i64]

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
    noexn, // the bottom of the exn hierarchy — see `types.ValType.RefHeap`
    concrete: u32, // a type index
};

/// A reference type: a heap type plus nullability (`(ref null? ht)`) and, for custom-descriptors,
/// exactness (`(ref null? (exact $t))`).
///
/// ⚠️ `exact` is only ever true for a `.concrete` heap type — an abstract head names a family, so
/// there is nothing for "exactly this" to bind to, and both readers reject the combination.
pub const RefType = struct { nullable: bool, heap: HeapType, exact: bool = false };

/// One entry of a typed `select`'s result vector: a single-byte valtype the decoder can resolve on
/// its own, or a multi-byte `(ref null? ht)` that cannot be resolved without the module.
///
/// 🔑 **This union exists because the select decoder read ONE BYTE per type and rejected anything
/// else.** Its comment even said "a single byte can't encode a concrete `(ref $t)`" — true, and it
/// was being used to justify the check rather than read as the reason the check was wrong. The
/// vector may CONTAIN one; the byte just is not the whole of it. So
/// `(select (result (ref null $t)) …)` — a valid module — failed to decode with
/// `UnsupportedOpcode`, and `ref.wast`'s `(select (result (ref 1)))`, which must be refused as
/// "unknown type", was refused for our reason instead and banked as a skip. **The same gap
/// `readBlockType` was fixed for, in the sibling function, left standing in the vector form.**
pub const SelectType = union(enum) {
    value: types.ValType,
    ref: RefType,
};

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
        // Wide arithmetic. The assembler emits through here, so these numbers and the decoder's
        // are one list read twice — the producer/consumer pair this repo checks first.
        .i64_add128 => 0x13,
        .i64_sub128 => 0x14,
        .i64_mul_wide_s => 0x15,
        .i64_mul_wide_u => 0x16,
        else => null,
    };
}

/// The single WIRE byte of a real one-byte opcode, or null if `op` is an
/// INTERNAL TAG that has no one-byte form.
///
/// 🔑 **`Op` is `enum(u16)` and every internal tag added from Track D4 onward
/// lives above `0xff`.** Those ops are written as a prefix byte plus a
/// sub-opcode (`fcSubOpcode` / `gcSubOpcode`), never as themselves, so asking
/// for their wire byte is a bug rather than a truncation. Returning `?u8` makes
/// that a checked question at the one site that asks it with a runtime `op`;
/// a bare `@intFromEnum` would have silently kept the low 8 bits.
///
/// ⚠️ Tags that predate the widening (`0x16`/`0x17`, `0xc5..0xcf`, `0xd7..0xfa`)
/// still sit INSIDE the byte range and still answer here — they are guarded
/// instead by `decodeBody`'s raw-byte check, which is exactly the machinery the
/// widening exists to stop needing. Do not add new tags below `0x100`.
pub fn wireByte(op: Op) ?u8 {
    const v = @intFromEnum(op);
    return if (v <= 0xff) @intCast(v) else null;
}

/// The `0xFB` sub-opcode for an internal GC-op tag, or null for a normal op.
pub fn gcSubOpcode(op: Op) ?u8 {
    return switch (op) {
        .struct_new => 0x00,
        .struct_new_default => 0x01,
        .struct_new_desc => 0x20,
        .struct_new_default_desc => 0x21,
        .ref_get_desc => 0x22,
        .struct_get => 0x02,
        .struct_get_s => 0x03,
        .struct_get_u => 0x04,
        .struct_set => 0x05,
        .array_new => 0x06,
        .array_new_default => 0x07,
        .array_new_fixed => 0x08,
        .array_new_data => 0x09,
        .array_new_elem => 0x0a,
        .array_fill => 0x10,
        .array_copy => 0x11,
        .array_init_data => 0x12,
        .array_init_elem => 0x13,
        .array_get => 0x0b,
        .array_get_s => 0x0c,
        .array_get_u => 0x0d,
        .array_set => 0x0e,
        .array_len => 0x0f,
        .ref_test => 0x14, // non-null form; the null form (0x15) is chosen at emit
        .ref_cast => 0x16, // non-null form; the null form (0x17) is chosen at emit
        .br_on_cast => 0x18,
        .br_on_cast_fail => 0x19,
        .ref_cast_desc_eq => 0x23, // non-null form; the null form (0x24) is chosen at emit
        .br_on_cast_desc_eq => 0x25,
        .br_on_cast_desc_eq_fail => 0x26,
        .ref_i31 => 0x1c,
        .i31_get_s => 0x1d,
        .i31_get_u => 0x1e,
        .extern_convert_any => 0x1a,
        .any_convert_extern => 0x1b,
        else => null,
    };
}

/// A block signature (§5.3.6): empty, a single value type, or a type index.
pub const BlockType = union(enum) {
    empty,
    value: types.ValType,
    type_index: u32,
    /// A single `(ref null? ht)` result — the two MULTI-byte valtypes, which the
    /// decoder cannot collapse into `.value` because a concrete heap type index
    /// needs the module's composite kinds to pick its family head. Kept
    /// unresolved here and turned into a `ValType` by the validator/interpreter,
    /// which have the module. (`.value` still carries every single-byte valtype.)
    ref: RefType,
};

/// A load/store memory-immediate. `memory` is the target memory index
/// (multi-memory): the alignment's bit 6 flags an explicit index that follows.
/// `offset` is `u64`: the memory64 proposal widens the static offset to a full
/// 64-bit value for a 64-bit memory (a 32-bit memory still requires it to fit in
/// `u32`, enforced by the validator).
pub const MemArg = struct { alignment: u32, offset: u64, memory: u32 = 0 };
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
    /// Memory index of `memory.size` / `memory.grow` / `memory.fill` (multi-memory).
    mem_index: u32,
    /// `memory.copy` — destination + source memory indices (multi-memory).
    mem_copy: struct { dst: u32, src: u32 },
    /// `memory.init` — a data-segment index + the target memory index.
    mem_init: struct { data: u32, mem: u32 },
    i32: i32,
    i64: i64,
    /// Raw little-endian bit pattern (`f32.const` / `f64.const`).
    f32: u32,
    f64: u64,
    /// Result types of a typed `select` (`0x1c`).
    ///
    /// ⚠️ **Not `[]const ValType`, and the reason is the same one `readBlockType` records one
    /// function below.** `(ref null ht)` = `0x63 ht` and `(ref ht)` = `0x64 ht` are ordinary
    /// valtypes and therefore ordinary `select` result types, but a concrete heap index cannot
    /// become a `ValType` here: picking its family head needs the module's composite kinds, which
    /// the body decoder does not have. `BlockType` solved this by staying UNRESOLVED; this is the
    /// same answer for the same reason, in the vector form.
    select_types: []const SelectType,
    /// Heap type of `ref.null` (`0xd0`) — abstract head or a concrete type index;
    /// the validator resolves it to a (possibly concrete) nullable value type.
    /// `ref.null <heaptype>`. Carries exactness because the heap-type grammar
    /// admits the custom-descriptors `exact` former here too — `(ref.null (exact
    /// $t))` is a NULL of the exact type, and dropping the prefix would type it
    /// as the inexact `(ref null $t)`, which `ref.get_desc` then reads as "not an
    /// exact input" and answers with an inexact descriptor. `nullable` is always
    /// true for this immediate; the field rides along so `refTypeValType` takes it
    /// unchanged.
    ref_type: RefType,
    /// A GC type index (`struct.new`/`array.new`/`array.get`/…).
    gc_type: u32,
    /// A GC struct type index + field index (`struct.get`/`struct.set`/…).
    gc_field: struct { type_index: u32, field: u32 },
    /// A GC array type index + element count (`array.new_fixed`).
    gc_type_n: struct { type_index: u32, n: u32 },
    /// A GC array type index + a DATA-segment index (`array.new_data` /
    /// `array.init_data`).
    gc_data: struct { type_index: u32, data: u32 },
    /// A GC array type index + an ELEMENT-segment index (`array.new_elem` /
    /// `array.init_elem`).
    gc_elem: struct { type_index: u32, elem: u32 },
    /// Destination + source array type indices (`array.copy`).
    gc_array_copy: struct { dst: u32, src: u32 },
    /// A GC cast target reference type (`ref.test` / `ref.cast`).
    ref_cast: RefType,
    /// A GC cast-branch (`br_on_cast` / `br_on_cast_fail`): a label + the source
    /// and destination reference types.
    br_cast: struct { label: u32, src: RefType, dst: RefType },
    /// `throw` — an exception tag index.
    tag: u32,
    /// `try_table` — a block type + its catch clauses.
    try_table: TryTable,
    /// A `0xFD` SIMD op: the sub-opcode plus whatever immediate it carries.
    simd: Simd,
    /// A `0xFE` atomic op: the sub-opcode plus its memarg (all atomic ops carry
    /// one except `atomic.fence`, whose immediate is a reserved `0x00`).
    atomic: Atomic,
};

/// A decoded `0xFD` (v128 SIMD) instruction. `sub` is the 0xFD sub-opcode;
/// `mem` is set for loads/stores, `lane` for lane ops, `bytes` for `v128.const`
/// (and the 16 lane indices of `i8x16.shuffle`).
pub const Simd = struct {
    sub: u32,
    mem: MemArg = .{ .alignment = 0, .offset = 0 },
    lane: u8 = 0,
    bytes: u128 = 0,
};

/// A decoded `0xFE` atomic instruction. `sub` is the 0xFE sub-opcode; `mem` is
/// the memarg every atomic memory op carries (`atomic.fence` has none, so `mem`
/// stays default and is ignored).
pub const Atomic = struct {
    sub: u32,
    mem: MemArg = .{ .alignment = 0, .offset = 0 },
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
    /// `memory.size` / `memory.grow` — a single memory index (multi-memory).
    mem_index,
    i32c,
    i64c,
    f32c,
    f64c,
    select_types,
    ref_type,
    gc_type,
    gc_field,
    gc_type_n,
    /// `array.new_data` / `array.init_data` — a type index + a data index.
    gc_data,
    /// `array.new_elem` / `array.init_elem` — a type index + an elem index.
    gc_elem,
    /// `array.copy` — two array type indices (dst, src).
    gc_array_copy,
    ref_cast,
    br_cast,
    tag,
    try_table,
    unsupported,
};

/// Classify an opcode's immediate. Reused by the decoder (and, later, by any
/// pass that needs to walk instructions without fully decoding them).
/// The natural alignment of a memory access, **as a log2 exponent** (the form
/// the memarg carries): 0 for 8-bit, 1 for 16-bit, 2 for 32-bit, 3 for 64-bit.
///
/// Lives here because both the assembler (which defaults a missing `align=`)
/// and the validator (which rejects `align=` larger than natural) need exactly
/// this table; they previously kept byte-identical private copies, one of them
/// misnamed `naturalAlign` as though it returned a byte count.
pub fn naturalAlignLog2(op: Op) u32 {
    return switch (op) {
        .i32_load8_s, .i32_load8_u, .i64_load8_s, .i64_load8_u, .i32_store8, .i64_store8 => 0,
        .i32_load16_s, .i32_load16_u, .i64_load16_s, .i64_load16_u, .i32_store16, .i64_store16 => 1,
        .i32_load, .f32_load, .i32_store, .f32_store, .i64_load32_s, .i64_load32_u, .i64_store32 => 2,
        .i64_load, .f64_load, .i64_store, .f64_store => 3,
        else => 0,
    };
}

pub fn immediateKind(op: Op) ImmKind {
    return switch (@intFromEnum(op)) {
        0x02, 0x03, 0x04, 0x06 => .block_type, // block/loop/if + legacy `try`
        0x08, 0x07 => .tag, // throw / legacy `catch` — a tag index
        0x0a => .none, // throw_ref
        0x19 => .none, // legacy `catch_all`
        0x1f => .try_table, // try_table <blocktype> vec(catch)
        0x0c, 0x0d, 0x09, 0x18 => .label, // br/br_if + legacy `rethrow`/`delegate`
        0x0e => .br_table,
        0x10, 0x12 => .func, // call / return_call
        0x11, 0x13 => .call_indirect, // call_indirect / return_call_indirect
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
        0xda => .mem_reserved, // memory.fill: a memory index (multi-memory). Kept
        // a distinct kind (not `.mem_index`) so the raw synthetic-tag byte 0xDA is
        // still rejected by the decoder; the assembler emits the index for it.
        0x28...0x3e => .mem,
        0x3f, 0x40 => .mem_index, // memory.size / memory.grow — a memory index
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
        // GC ops with no immediate: ref.i31/i31.get_s/i31.get_u, array.len, and
        // the extern↔any bridge (`0x16`/`0x17`, rejected as raw bytes below).
        0xf0, 0xf1, 0xf2, 0xed, 0x16, 0x17 => .none,
        // GC ops with a single type index (`array.fill` = 0xDF included), plus
        // custom-descriptors' `struct.new_desc`/`struct.new_default_desc`/
        // `ref.get_desc` — `0x100`+, so no wire byte can name them.
        0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec, 0xf3, 0xf4, 0xdf, 0x100, 0x101, 0x102 => .gc_type,
        // GC struct ops with a type index + field index.
        0xf5, 0xf6, 0xf7, 0xf8 => .gc_field,
        // array.new_fixed: type index + element count.
        0xe8 => .gc_type_n,
        // array.new_data / array.init_data: type index + data-segment index.
        0xdd, 0xce => .gc_data,
        // array.new_elem / array.init_elem: type index + elem-segment index.
        0xde, 0xcf => .gc_elem,
        // array.copy: destination + source array type indices.
        0xcd => .gc_array_copy,
        // ref.test / ref.cast: a target reference type.
        0xee, 0xef, 0x103 => .ref_cast, // + custom-descriptors `ref.cast_desc_eq`
        // Wide arithmetic (0xFC 0x13..0x16) — no immediates.
        0x106, 0x107, 0x108, 0x109 => .none,
        // br_on_cast / br_on_cast_fail: a label + source & destination ref types.
        0xf9, 0xfa, 0x104, 0x105 => .br_cast, // + the `_desc_eq` pair
        else => .unsupported,
    };
}

/// Decode a block type (§5.3.6): `0x40` (empty), a valtype, or a non-negative
/// s33 type index. Every *single-byte* valtype encodes as a negative s33, which
/// is what lets one `readVarS33` separate the three cases.
fn readBlockType(r: *Reader) DecodeError!BlockType {
    // ⚠️ …except the two MULTI-byte valtypes. `(ref null ht)` = `0x63 ht` and
    // `(ref ht)` = `0x64 ht` are ordinary valtypes and therefore ordinary block
    // types, but only their first byte is in the s33 stream — the heap type
    // follows. Reading them as a bare s33 yields −29/−28, which matched no arm,
    // so a concrete-ref block type was undecodable. `wat.zig` worked around it by
    // interning a function type and emitting a type INDEX instead, which is legal
    // but non-canonical — and it MANUFACTURED a type entry, so
    // `(block (result (ref 1)))` in a module with one type resolved `(ref 1)` to
    // the signature the block had just created and validated clean. `ref.wast`
    // requires it rejected as "unknown type". **A workaround in the producer for
    // a gap in the consumer does not stay cosmetic.**
    const first = try r.peekByte();
    if (first == 0x63 or first == 0x64) {
        _ = try r.readByte();
        const he = try readHeapTypeExact(r);
        return .{ .ref = .{ .nullable = first == 0x63, .heap = he.heap, .exact = he.exact } };
    }
    const v = try r.readVarS33();
    if (v >= 0) {
        if (v > std.math.maxInt(u32)) return error.UnsupportedOpcode; // guard the @intCast
        return .{ .type_index = @intCast(v) };
    }
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
    const src_ht = try readHeapTypeExact(r);
    const dst_ht = try readHeapTypeExact(r);
    return .{ .br_cast = .{
        .label = label,
        .src = .{ .nullable = flags & 0b01 != 0, .heap = src_ht.heap, .exact = src_ht.exact },
        .dst = .{ .nullable = flags & 0b10 != 0, .heap = dst_ht.heap, .exact = dst_ht.exact },
    } };
}

/// Read a load/store memarg. Multi-memory: bit 6 of the alignment flags an
/// explicit memory index that follows (before the offset); else memory 0.
fn readMemArg(r: *Reader) DecodeError!MemArg {
    var al = try r.readVarU32();
    var mem_i: u32 = 0;
    if (al & 0x40 != 0) {
        al &= ~@as(u32, 0x40);
        mem_i = try r.readVarU32();
    }
    // memory64: the offset is a full u64 (`readVarU32` would reject a valid
    // >=2^32 offset on a 64-bit memory). The 32-bit-memory ceiling is a
    // validation rule, not a decode one.
    const of = try r.readVarU64();
    return .{ .alignment = al, .offset = of, .memory = mem_i };
}

/// Decode a `0xFD` SIMD op given its sub-opcode. Every op is `Op.simd`; the
/// sub-opcode picks the operation and its immediate shape (memarg for loads/
/// stores, +lane for load/store-lane, 16 bytes for `v128.const`/`shuffle`, a
/// lane byte for extract/replace_lane, nothing otherwise). Decoding is complete
/// for the whole family; execution supports a subset (`interp.execSimd`).
/// Lanes addressable by an extract/replace/lane-load-store lane immediate. An
/// out-of-range lane must be rejected **at decode** — the CLI run path does not
/// re-validate, and the interpreter indexes a fixed `[N]Lane` array by this
/// byte, so an unchecked value is an out-of-bounds read (and, for replace/
/// load_lane, an out-of-bounds *write*). Not a lane op → 255 (never rejects).
fn simdLaneCount(sub: u32) u8 {
    return switch (sub) {
        0x15, 0x16, 0x17, 0x54, 0x58 => 16, // i8x16 lanes / *8_lane
        0x18, 0x19, 0x1a, 0x55, 0x59 => 8, // i16x8 lanes / *16_lane
        0x1b, 0x1c, 0x1f, 0x20, 0x56, 0x5a => 4, // i32x4/f32x4 / *32_lane
        0x1d, 0x1e, 0x21, 0x22, 0x57, 0x5b => 2, // i64x2/f64x2 / *64_lane
        else => 255,
    };
}

/// Highest `0xFD` sub-opcode wazmrt implements — the tail of the relaxed-SIMD
/// range (`0x113`, `relaxed_dot_add`). Anything above it is not a SIMD op we
/// know, and `decodeSimd` rejects it rather than letting it decode with no
/// immediate (which also caused the following bytes to be re-read as
/// instructions). Raise this when adding sub-opcodes past it.
const max_simd_sub: u32 = 0x113;

/// Free an instruction stream from `decodeBody`/`decodeBodyTracked`, including
/// the SIDE allocations some immediates own — `br_table`'s label array and typed
/// `select`'s type vector are separate allocations, so `a.free(ir)` alone leaks
/// them. Harmless under an arena (every caller but one), but `frameOffset` runs
/// on the C ABI's general-purpose allocator, so a long-lived embedder that
/// trapped repeatedly in a function containing `br_table` grew without bound.
pub fn freeBody(a: std.mem.Allocator, ir: []const Instr) void {
    for (ir) |instr| switch (instr.imm) {
        .br_table => |bt| a.free(bt.labels),
        .select_types => |ts| a.free(ts),
        else => {},
    };
    a.free(ir);
}

/// The natural (maximum-allowed) alignment of a SIMD memory access, as a log2.
/// Lives here for the same reason as `simdIsMemoryOp` and `naturalAlignLog2` —
/// one authority. The assembler uses it to default a missing `align=`; the
/// validator uses it to reject an over-aligned memarg (§6.5.8). They kept
/// separate copies until 2026-07-21, so the validator simply had no SIMD
/// alignment check at all.
pub fn simdNaturalAlignLog2(sub: u32) u32 {
    return switch (sub) {
        0x07, 0x54, 0x58 => 0, // 1-byte: load8_splat, load8_lane, store8_lane
        0x08, 0x55, 0x59 => 1, // 2-byte
        0x09, 0x5c, 0x56, 0x5a => 2, // 4-byte: load32_splat/zero/lane, store32_lane
        0x01...0x06, 0x0a, 0x5d, 0x57, 0x5b => 3, // 8-byte: loadMxN, load64_splat/zero/lane, store64_lane
        else => 4, // 16-byte: v128.load / v128.store
    };
}

/// Does this `0xFD` sub-opcode carry a memarg (i.e. touch linear memory)?
/// The `Simd` immediate always has a `mem` field (defaulted), so its presence
/// cannot distinguish these — kept beside `decodeSimd`, whose switch is the
/// authority, so the two can't drift.
pub fn simdIsMemoryOp(sub: u32) bool {
    return switch (sub) {
        0x00...0x0b, 0x5c, 0x5d => true, // v128.load* / store / load{32,64}_zero
        0x54...0x5b => true, // v128.load/store lane
        else => false,
    };
}

/// Highest `0xFE` atomic sub-opcode wazmrt knows (`i64.atomic.rmw32.cmpxchg_u`).
pub const max_atomic_sub: u32 = 0x4e;

/// The REQUIRED alignment (log2 bytes) of a `0xFE` atomic op — atomics must be
/// naturally aligned, so this is both the assembler default and the exact value
/// the validator enforces (an atomic access with any other alignment traps/is
/// invalid). Access width is encoded in the sub-opcode: `8`→1 byte, `16`→2,
/// `32`→4, else the full type width (i32=4, i64=8). notify/wait32 are 4, wait64
/// is 8. `atomic.fence` (0x03) has no memarg; returns 0.
pub fn atomicNaturalAlignLog2(sub: u32) u32 {
    return switch (sub) {
        0x00, 0x01 => 2, // notify, wait32
        0x02 => 3, //       wait64
        0x03 => 0, //       fence (no memarg)
        // i32 full / i64 full loads+stores
        0x10, 0x17 => 2, // i32.atomic.load / store
        0x11, 0x18 => 3, // i64.atomic.load / store
        // sub-width loads (0x12–0x16) and stores (0x19–0x1d): width in the name
        0x12, 0x19 => 0, // i32 …8
        0x13, 0x1a => 1, // i32 …16
        0x14, 0x1b => 0, // i64 …8
        0x15, 0x1c => 1, // i64 …16
        0x16, 0x1d => 2, // i64 …32
        // rmw/cmpxchg: 7 ops per group, laid out
        // [i32.full, i64.full, i32.8, i32.16, i64.8, i64.16, i64.32] from 0x1e.
        else => atomicRmwAlign(sub),
    };
}

fn atomicRmwAlign(sub: u32) u32 {
    if (sub < 0x1e or sub > 0x4e) return 0;
    return switch ((sub - 0x1e) % 7) {
        0 => 2, // i32 full  (4 bytes)
        1 => 3, // i64 full  (8 bytes)
        2 => 0, // i32.8     (1)
        3 => 1, // i32.16    (2)
        4 => 0, // i64.8     (1)
        5 => 1, // i64.16    (2)
        6 => 2, // i64.32    (4)
        else => unreachable,
    };
}

/// Decode a `0xFE` atomic op. `atomic.fence` (0x03) carries a reserved byte;
/// every other op (notify/wait, and all load/store/rmw/cmpxchg) carries a
/// memarg. Sub-opcodes outside the defined set are rejected at decode (the run
/// path does not re-validate).
fn decodeAtomic(r: *Reader, sub: u32) DecodeError!Instr {
    var at: Atomic = .{ .sub = sub };
    switch (sub) {
        0x03 => _ = try r.readByte(), // atomic.fence: a reserved 0x00
        0x00, 0x01, 0x02, // notify / wait32 / wait64
        0x10...max_atomic_sub, // loads / stores / rmw / cmpxchg
        => at.mem = try readMemArg(r),
        else => return error.UnsupportedOpcode,
    }
    return .{ .op = .atomic, .imm = .{ .atomic = at } };
}

fn decodeSimd(r: *Reader, sub: u32) DecodeError!Instr {
    var s: Simd = .{ .sub = sub };
    switch (sub) {
        0x00...0x0b, 0x5c, 0x5d => s.mem = try readMemArg(r), // v128.load* / store / load{32,64}_zero
        0x54...0x5b => { // v128.load/store lane: memarg + a lane index
            s.mem = try readMemArg(r);
            s.lane = try r.readByte();
            if (s.lane >= simdLaneCount(sub)) return error.BadLaneIndex;
        },
        0x0c, 0x0d => { // v128.const / i8x16.shuffle: 16 immediate bytes (LE)
            var v: u128 = 0;
            var i: u5 = 0;
            while (i < 16) : (i += 1) {
                const b = try r.readByte();
                // `i8x16.shuffle`'s 16 bytes are LANE INDICES selecting from the
                // two 16-byte operands, so each must be < 32. Extract/replace and
                // load/store_lane are bounds-checked (below / above); shuffle was
                // the missed sibling, and an out-of-range index silently produced
                // 0. `v128.const` (0x0c) has no such constraint — its bytes are
                // literal data.
                if (sub == 0x0d and b >= 32) return error.BadLaneIndex;
                v |= @as(u128, b) << (@as(u7, i) * 8);
            }
            s.bytes = v;
        },
        0x15...0x22 => { // extract_lane / replace_lane
            s.lane = try r.readByte();
            if (s.lane >= simdLaneCount(sub)) return error.BadLaneIndex;
        },
        // An undefined `0xFD` sub-opcode used to decode AND validate, trapping
        // only at execution — so `wasm_module_validate` lied to the embedder, and
        // because the unknown sub consumes no immediate, following bytes were
        // re-interpreted as instructions. `0x113` is the highest implemented
        // (the relaxed-SIMD tail); reject anything past it.
        else => if (sub > max_simd_sub) return error.UnsupportedOpcode,
    }
    return .{ .op = .simd, .imm = .{ .simd = s } };
}

/// Read a `try_table` immediate: a block type followed by a vector of catch
/// clauses. Each clause is a kind byte (0=catch, 1=catch_ref, 2=catch_all,
/// 3=catch_all_ref), a tag index for the non-`all` kinds, then a label index.
fn readTryTable(r: *Reader, a: std.mem.Allocator) (DecodeError || std.mem.Allocator.Error)!Imm {
    const bt = try readBlockType(r);
    const n = try r.readVecLen();
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
/// Read a heap type, reporting whether it carried the custom-descriptors `exact` prefix.
///
/// 🔑 **`readHeapType` and this must stay in step with `wat.zig`'s emitter.** The assembler writes
/// `0x62` before the heap-type code for an exact cast target; a reader that does not know the byte
/// treats it as a malformed opcode and the module fails to DECODE — which is what happened for one
/// build of this change, and is the producer/consumer pair this codebase has been bitten by five
/// times. The regression is silent in the failure column: the affected modules simply stop
/// building, so their assertions become SKIPS rather than failures.
pub fn readHeapTypeExact(r: *Reader) DecodeError!struct { heap: HeapType, exact: bool } {
    const first = try r.readVarS33();
    if (first == -0x1e) { // 0x62 — the `exact` former
        const inner = try readHeapType(r);
        // Concrete only; `(ref (exact any))` and friends are malformed.
        if (inner != .concrete) return error.BadValType;
        return .{ .heap = inner, .exact = true };
    }
    return .{ .heap = try heapTypeFromCode(first), .exact = false };
}

pub fn readHeapType(r: *Reader) DecodeError!HeapType {
    return heapTypeFromCode(try r.readVarS33());
}

/// A `ref.test`/`ref.cast` target: nullability (from the sub-opcode) plus an exactness-aware heap
/// type.
///
/// ⚠️ **The four cast sub-opcodes read their target here and NOT through `readHeapType`.** They
/// were the sites that still dropped the `exact` prefix after the type/valtype readers had been
/// taught it, so `ref.test (ref (exact $super))` answered **1** for a subtype — type confusion,
/// and invisible to the conformance score because the corpus files involved were already failing
/// for other reasons. Found only by the by-construction wrong-answer test.
fn readRefTypeExact(r: *Reader, nullable: bool) DecodeError!RefType {
    const he = try readHeapTypeExact(r);
    return .{ .nullable = nullable, .heap = he.heap, .exact = he.exact };
}

fn heapTypeFromCode(v: i64) DecodeError!HeapType {
    if (v >= 0) {
        if (v > std.math.maxInt(u32)) return error.UnsupportedOpcode; // guard the @intCast
        return .{ .concrete = @intCast(v) };
    }
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
        // `noexn` (0x74) — the bottom of the exn hierarchy, its OWN head now.
        // ⚠️ It used to fold onto `exn`, "because only null inhabits it, so the
        // distinction is unobservable in this model". The distinction is not
        // unobservable: a bottom type is a subtype of every type in its
        // hierarchy — including the CONCRETE ones — which is exactly the property
        // `ref_null.wast` tests and which folding erases. The same correction
        // applies to `nofunc`/`noextern` below.
        -0x0c => .noexn,
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
        // Saturating for the same reason as `Module.body_offset`: `r.pos` is a
        // `usize` and this list is `u32`, so a >4 GiB body would make the cast
        // out-of-range (UB in ReleaseFast). These offsets only label trap
        // backtraces, so clamping is cosmetic where the cast was not.
        if (offsets) |o| try o.append(a, std.math.cast(u32, r.pos) orelse std.math.maxInt(u32));
        const b0 = try r.readByte();
        if (b0 == 0xfb) {
            // 0xFB-prefixed GC op: a LEB sub-opcode picks the internal Op tag,
            // then its immediates (a type index, a type+field, or a type+count).
            const instr: Instr = switch (try r.readVarU32()) {
                0x00 => .{ .op = .struct_new, .imm = .{ .gc_type = try r.readVarU32() } },
                0x01 => .{ .op = .struct_new_default, .imm = .{ .gc_type = try r.readVarU32() } },
                0x20 => .{ .op = .struct_new_desc, .imm = .{ .gc_type = try r.readVarU32() } },
                0x21 => .{ .op = .struct_new_default_desc, .imm = .{ .gc_type = try r.readVarU32() } },
                0x22 => .{ .op = .ref_get_desc, .imm = .{ .gc_type = try r.readVarU32() } },
                0x02 => .{ .op = .struct_get, .imm = try readGcField(&r) },
                0x03 => .{ .op = .struct_get_s, .imm = try readGcField(&r) },
                0x04 => .{ .op = .struct_get_u, .imm = try readGcField(&r) },
                0x05 => .{ .op = .struct_set, .imm = try readGcField(&r) },
                0x06 => .{ .op = .array_new, .imm = .{ .gc_type = try r.readVarU32() } },
                0x07 => .{ .op = .array_new_default, .imm = .{ .gc_type = try r.readVarU32() } },
                0x08 => .{ .op = .array_new_fixed, .imm = .{ .gc_type_n = .{ .type_index = try r.readVarU32(), .n = try r.readVarU32() } } },
                0x09 => .{ .op = .array_new_data, .imm = .{ .gc_data = .{ .type_index = try r.readVarU32(), .data = try r.readVarU32() } } },
                0x0a => .{ .op = .array_new_elem, .imm = .{ .gc_elem = .{ .type_index = try r.readVarU32(), .elem = try r.readVarU32() } } },
                0x10 => .{ .op = .array_fill, .imm = .{ .gc_type = try r.readVarU32() } },
                0x11 => .{ .op = .array_copy, .imm = .{ .gc_array_copy = .{ .dst = try r.readVarU32(), .src = try r.readVarU32() } } },
                0x12 => .{ .op = .array_init_data, .imm = .{ .gc_data = .{ .type_index = try r.readVarU32(), .data = try r.readVarU32() } } },
                0x13 => .{ .op = .array_init_elem, .imm = .{ .gc_elem = .{ .type_index = try r.readVarU32(), .elem = try r.readVarU32() } } },
                0x0b => .{ .op = .array_get, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0c => .{ .op = .array_get_s, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0d => .{ .op = .array_get_u, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0e => .{ .op = .array_set, .imm = .{ .gc_type = try r.readVarU32() } },
                0x0f => .{ .op = .array_len, .imm = .none },
                0x14 => .{ .op = .ref_test, .imm = .{ .ref_cast = try readRefTypeExact(&r, false) } },
                0x15 => .{ .op = .ref_test, .imm = .{ .ref_cast = try readRefTypeExact(&r, true) } },
                0x16 => .{ .op = .ref_cast, .imm = .{ .ref_cast = try readRefTypeExact(&r, false) } },
                0x17 => .{ .op = .ref_cast, .imm = .{ .ref_cast = try readRefTypeExact(&r, true) } },
                0x18 => .{ .op = .br_on_cast, .imm = try readBrCast(&r) },
                0x19 => .{ .op = .br_on_cast_fail, .imm = try readBrCast(&r) },
                // custom-descriptors (D4). The `_desc_eq` casts mirror their plain
                // twins byte for byte and add a DESCRIPTOR operand on the stack —
                // nothing extra in the immediate, so the readers are shared.
                0x23 => .{ .op = .ref_cast_desc_eq, .imm = .{ .ref_cast = try readRefTypeExact(&r, false) } },
                0x24 => .{ .op = .ref_cast_desc_eq, .imm = .{ .ref_cast = try readRefTypeExact(&r, true) } },
                0x25 => .{ .op = .br_on_cast_desc_eq, .imm = try readBrCast(&r) },
                0x26 => .{ .op = .br_on_cast_desc_eq_fail, .imm = try readBrCast(&r) },
                0x1c => .{ .op = .ref_i31, .imm = .none },
                0x1d => .{ .op = .i31_get_s, .imm = .none },
                0x1e => .{ .op = .i31_get_u, .imm = .none },
                0x1a => .{ .op = .extern_convert_any, .imm = .none },
                0x1b => .{ .op = .any_convert_extern, .imm = .none },
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
                // Bulk memory (multi-memory: each carries a memory index — a
                // varu32 that reads 0 for the single-memory case).
                0x08 => blk: {
                    const d = try r.readVarU32();
                    const m = try r.readVarU32(); // target memory index
                    break :blk .{ .op = .memory_init, .imm = .{ .mem_init = .{ .data = d, .mem = m } } };
                },
                0x09 => .{ .op = .data_drop, .imm = .{ .data = try r.readVarU32() } },
                0x0a => blk: {
                    const dst = try r.readVarU32(); // dst memory index
                    const src = try r.readVarU32(); // src memory index
                    break :blk .{ .op = .memory_copy, .imm = .{ .mem_copy = .{ .dst = dst, .src = src } } };
                },
                0x0b => .{ .op = .memory_fill, .imm = .{ .mem_index = try r.readVarU32() } },
                0x0c => .{ .op = .table_init, .imm = .{ .table_init = .{ .elem = try r.readVarU32(), .table = try r.readVarU32() } } },
                0x0d => .{ .op = .elem_drop, .imm = .{ .elem = try r.readVarU32() } },
                0x0e => .{ .op = .table_copy, .imm = .{ .table_copy = .{ .dst = try r.readVarU32(), .src = try r.readVarU32() } } },
                0x0f => .{ .op = .table_grow, .imm = .{ .table = try r.readVarU32() } },
                0x10 => .{ .op = .table_size, .imm = .{ .table = try r.readVarU32() } },
                0x11 => .{ .op = .table_fill, .imm = .{ .table = try r.readVarU32() } },
                // Wide arithmetic — no immediates. `readVarU32` already accepts the OVERLONG
                // encodings `wide-arithmetic.wast` insists on, which is where these four numbers
                // came from in the first place.
                0x13 => .{ .op = .i64_add128, .imm = .none },
                0x14 => .{ .op = .i64_sub128, .imm = .none },
                0x15 => .{ .op = .i64_mul_wide_s, .imm = .none },
                0x16 => .{ .op = .i64_mul_wide_u, .imm = .none },
                else => return error.UnsupportedOpcode,
            };
            try list.append(a, imm);
            continue;
        }
        if (b0 == 0xfd) {
            // 0xFD-prefixed fixed-width SIMD (v128): a LEB sub-opcode + immediate.
            try list.append(a, try decodeSimd(&r, try r.readVarU32()));
            continue;
        }
        if (b0 == 0xfe) {
            // 0xFE-prefixed atomics (threads proposal): a LEB sub-opcode + memarg
            // (or a reserved byte for `atomic.fence`).
            try list.append(a, try decodeAtomic(&r, try r.readVarU32()));
            continue;
        }
        // `0xc5..0xcf` and `0xd7..0xfa` are wazmrt's INTERNAL tags for ops whose
        // real wire form is `0xFB`/`0xFC` + a LEB sub-opcode (handled above). A raw
        // byte in either range is not a valid single-byte wasm opcode, so accepting
        // one executed a non-standard encoding as if it were e.g. `table.grow`.
        //
        // ⚠️ TWO ranges, not one — `0xd0..0xd6` (`ref.null` … `br_on_non_null`) are
        // REAL single-byte opcodes sitting between them. Only `0xd7..0xfa` was
        // guarded until R3 (2026-08-13), which left the eight saturating-truncation
        // tags `0xc5..0xcc` open: `immediateKind` classifies `0x45...0xcc` as
        // `.none`, so a raw `0xC5` byte — not a wasm opcode at all — decoded and
        // executed as `i32.trunc_sat_f32_s`. Same accept-invalid the original guard
        // was written to close; it just stopped short of tags that already existed.
        // `0xcd..0xcf` are R3's `array.copy`/`array.init_data`/`array.init_elem`.
        //
        // The pre-existing guard rejected by *immediate kind*, which catches only
        // the tags whose kind is unreachable from any real single-byte op — it
        // could never catch `0xe3–0xe5` (`.table`) or `0xed`/`0xf0–0xf2`
        // (`.none`), whose kinds are legitimately reachable. A range check is the
        // property that actually holds. (`0xd0–0xd6` are real ops; `0xfb–0xfd`
        // are prefixes consumed above, and both sit outside this range.)
        // THREE ranges now: R10 put the extern↔any bridge in the unassigned
        // `0x16`/`0x17` slots, the only pair left outside the two blocks below.
        // Their `immediateKind` is `.none`, which is reachable from real ops, so
        // without this arm a raw `0x16` byte would decode and EXECUTE as
        // `extern.convert_any` — the accept-invalid R3 closed for `0xc5..0xcc`.
        // 🔑 **THIS CONDITION IS FROZEN — it lists the tags that predate the D4
        // widening, and no tag added after it can ever need an entry.** `Op` is
        // `enum(u16)` with every new internal tag at `0x100`+, and `b0` is a
        // BYTE, so `@enumFromInt(b0)` below cannot name one: the whole class of
        // bug this guard exists for is closed by construction rather than by
        // enumeration. It has been got wrong three times (R3's `0xc5..0xcc`,
        // R10's `0x16`/`0x17`, and a fourth arm D3 added then removed once an
        // inversion showed the immediate-kind switch already covered it).
        // **Adding a tag below `0x100` re-opens it. Do not.**
        if (b0 == 0x16 or b0 == 0x17 or
            (b0 >= 0xc5 and b0 <= 0xcf) or (b0 >= 0xd7 and b0 <= 0xfa)) return error.UnsupportedOpcode;
        // ⚠️ `0xFF` gets its OWN error, and the distinction is not cosmetic. Everything the guard
        // above refuses is *unassigned today*; `0xFF` is reserved by the spec **forever**, so it
        // is the one byte where "not an opcode" cannot also mean "wazmrt is behind". See
        // `types.DecodeError.IllegalOpcode` — it is off `wast.isOurLimitation` for that reason
        // and `UnsupportedOpcode` must stay on it.
        if (b0 == 0xff) return error.IllegalOpcode;
        const op: Op = @enumFromInt(b0);
        const imm: Imm = switch (immediateKind(op)) {
            .none => .none,
            .block_type => .{ .block_type = try readBlockType(&r) },
            .label => .{ .label = try r.readVarU32() },
            .br_table => blk: {
                const n = try r.readVecLen();
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
            .mem => .{ .mem = try readMemArg(&r) },
            // `.mem_reserved` (raw byte 0xDA) is rejected below: it is the internal
            // tag for `memory.fill`, which only decodes via `0xFC 0x0B` (→ `.mem_index`).
            // Accepting the raw byte here built the WRONG union variant.
            .mem_index => .{ .mem_index = try r.readVarU32() }, // memory.size / memory.grow
            .i32c => .{ .i32 = try r.readVarI32() },
            .i64c => .{ .i64 = try r.readVarI64() },
            .f32c => .{ .f32 = try r.readF32Bits() },
            .f64c => .{ .f64 = try r.readF64Bits() },
            .select_types => blk: {
                const n = try r.readVecLen();
                const tys = try a.alloc(SelectType, n);
                for (tys) |*t| {
                    // ⚠️ **The MULTI-BYTE valtypes first, exactly as `readBlockType` does.**
                    // `(ref null ht)` = `0x63 ht` and `(ref ht)` = `0x64 ht`; reading one byte and
                    // stopping left the heap type in the stream and answered `UnsupportedOpcode`
                    // for a VALID module. `0x63`/`0x64` are unambiguous here because no
                    // single-byte valtype uses either code.
                    const first = try r.peekByte();
                    if (first == 0x63 or first == 0x64) {
                        _ = try r.readByte();
                        const he = try readHeapTypeExact(&r);
                        t.* = .{ .ref = .{ .nullable = first == 0x63, .heap = he.heap, .exact = he.exact } };
                        continue;
                    }
                    // #6: reject an unknown value-type byte rather than silently building a bogus
                    // `ValType`. Every remaining form IS one byte, so `isValid` is exactly the
                    // abstract/numeric set here.
                    const v: types.ValType = @enumFromInt(try r.readByte());
                    if (!v.isValid()) return error.UnsupportedOpcode;
                    t.* = .{ .value = v };
                }
                break :blk .{ .select_types = tys };
            },
            .ref_type => blk: {
                const ht = try readHeapTypeExact(&r);
                break :blk .{ .ref_type = .{ .nullable = true, .heap = ht.heap, .exact = ht.exact } };
            },
            .tag => .{ .tag = try r.readVarU32() },
            .try_table => try readTryTable(&r, a),
            // These are `0xFC`-prefixed ops decoded via the interception above;
            // reaching here means a raw synthetic-tag byte, which is malformed.
            // 0xFB/0xFC-prefixed ops are decoded via the prefix interceptions
            // above; reaching here means a raw synthetic-tag byte (malformed).
            .elem, .data, .data_init, .mem_copy, .mem_reserved, .table_init, .table_copy, .gc_type, .gc_field, .gc_type_n, .gc_data, .gc_elem, .gc_array_copy, .ref_cast, .br_cast => return error.UnsupportedOpcode,
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
    try std.testing.expectEqual(@as(u64, 8), instrs[2].imm.mem.offset);
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

test "rejects a block type index outside the s33 range" {
    // `block` (0x02) with an s33 whose bit 32 (0x10 in the 5th byte) is set but the
    // higher bits don't sign-extend it — 2^32 is out of the s33 range [-2^32,2^32-1]
    // (bit 32 is the sign). `readVarS33` rejects it as malformed, not a huge index.
    const body = [_]u8{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x10 };
    try std.testing.expectError(error.LebOverflow, decodeBody(std.testing.allocator, &body));
    // An over-long (>5-byte) s33 encoding of a small index is also rejected.
    const overlong = [_]u8{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try std.testing.expectError(error.LebOverflow, decodeBody(std.testing.allocator, &overlong));
}

test "#6: select_t rejects an invalid value-type byte at decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // select_t (0x1c), 1 result type, 0x50 — not a value type → rejected.
    try std.testing.expectError(error.UnsupportedOpcode, decodeBody(a, &[_]u8{ 0x1c, 0x01, 0x50 }));
    // A valid typed select (i32 = 0x7f) still decodes.
    const ok = try decodeBody(a, &[_]u8{ 0x1c, 0x01, 0x7f, 0x0b });
    try std.testing.expectEqual(Op.select_t, ok[0].op);
    try std.testing.expectEqual(types.ValType.i32, ok[0].imm.select_types[0].value);
}

test "select_t decodes the MULTI-BYTE ref valtypes, which it used to refuse" {
    // 🔒 REGRESSION TEST FOR A DECODER GAP THAT REJECTED VALID MODULES. The loop read exactly one
    // byte per result type, so `(ref null $t)` = `0x63 ht` and `(ref $t)` = `0x64 ht` came back as
    // `UnsupportedOpcode` — and the heap type was left in the stream, so the failure was not even
    // at the right place. It is the same gap `readBlockType` above was fixed for; only the vector
    // form was left behind. ⚠️ **When a decoder is taught a multi-byte form, grep for every OTHER
    // site that reads that grammar** — a fix applied at one of two call sites is half a fix.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // select_t, 1 type, `0x63 0x00` = (ref null <type 0>).
    const nullable = try decodeBody(a, &[_]u8{ 0x1c, 0x01, 0x63, 0x00, 0x0b });
    try std.testing.expectEqual(Op.select_t, nullable[0].op);
    try std.testing.expect(nullable[0].imm.select_types[0] == .ref);
    try std.testing.expect(nullable[0].imm.select_types[0].ref.nullable);
    try std.testing.expectEqual(@as(u32, 0), nullable[0].imm.select_types[0].ref.heap.concrete);

    // `0x64 0x01` = (ref <type 1>), non-nullable. The index is NOT range-checked here — that is
    // the validator's job, and it is what turns `(select (result (ref 1)))` in a module with no
    // such type into the spec's "unknown type" rather than a decode failure.
    const non_null = try decodeBody(a, &[_]u8{ 0x1c, 0x01, 0x64, 0x01, 0x0b });
    try std.testing.expect(!non_null[0].imm.select_types[0].ref.nullable);
    try std.testing.expectEqual(@as(u32, 1), non_null[0].imm.select_types[0].ref.heap.concrete);

    // An abstract head still takes the single-byte path: `0x70` = funcref.
    const abstract = try decodeBody(a, &[_]u8{ 0x1c, 0x01, 0x70, 0x0b });
    try std.testing.expectEqual(types.ValType.funcref, abstract[0].imm.select_types[0].value);
}

test "decodes a SIMD (0xFD) op: v128.const" {
    // 0xfd 0x0c <16 bytes> — v128.const with a 1,2,3,4 (i32x4) little-endian payload.
    const body = [_]u8{ 0xfd, 0x0c, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0 };
    const instrs = try decodeBody(std.testing.allocator, &body);
    defer std.testing.allocator.free(instrs);
    try std.testing.expectEqual(Op.simd, instrs[0].op);
    try std.testing.expectEqual(@as(u32, 0x0c), instrs[0].imm.simd.sub);
    // lanes 1,2,3,4 packed little-endian into the u128.
    try std.testing.expectEqual(@as(u128, 1 | (2 << 32) | (3 << 64) | (4 << 96)), instrs[0].imm.simd.bytes);
}

test "rejects a genuinely unknown opcode, and 0xff by its OWN error" {
    // 🔑 The two halves are deliberately different errors. `0xff` is reserved by the spec
    // FOREVER — no proposal can ever assign it — so refusing it is a verdict on the module and
    // scores as a conformance pass (`binary.wast`: "illegal opcode ff"). An unassigned byte like
    // `0x27` is merely unassigned TODAY; if a proposal takes it, wazmrt is the incomplete party,
    // so it stays `UnsupportedOpcode` and `wast.isOurLimitation` keeps scoring it as our gap.
    // **The asymmetry is the point: split what the spec makes permanent, not what is empty now.**
    try std.testing.expectError(error.IllegalOpcode, decodeBody(std.testing.allocator, &[_]u8{0xff}));
    try std.testing.expectError(error.UnsupportedOpcode, decodeBody(std.testing.allocator, &[_]u8{0x27}));
}

test "rejects raw internal-tag bytes that are not real single-byte opcodes" {
    // `0xd7..0xfa` are wazmrt's internal Op tags for ops whose real wire form is
    // `0xFB`/`0xFC` + a sub-opcode. Accepting the raw byte executed a
    // non-standard encoding as a real instruction. The pre-existing guard was by
    // immediate *kind*, so it could not catch tags whose kind is also reachable
    // from a genuine single-byte op — these are exactly those cases.
    const tags = [_]u8{
        0xe3, 0xe4, 0xe5, // table.grow/size/fill  (kind .table — also a real kind)
        0xed, // array.len              (kind .none  — also a real kind)
        0xf0, 0xf1, 0xf2, // ref.i31 / i31.get_s/u  (kind .none)
        0xd7, 0xdb, 0xfa, // upper-range endpoints + the SIMD tag
        // R3: the LOWER tag range, which no guard covered until 2026-08-13. The
        // eight `0xc5..0xcc` saturating-truncation tags all classify as `.none`,
        // so a raw byte decoded and EXECUTED as a real instruction — `0xC5` ran
        // as `i32.trunc_sat_f32_s`. `0xcd..0xcf` are the new array bulk tags.
        0xc5, 0xc8, 0xcc, // saturating-truncation range: low, middle, high
        0xcd, 0xce, 0xcf, // array.copy / array.init_data / array.init_elem
        0xdd, 0xde, 0xdf, // array.new_data / array.new_elem / array.fill
        // `0x1d`/`0x1e`/`0x27` were D3's custom-descriptors tags and are UNASSIGNED
        // again since D4 widened `Op` and moved them to `0x100`+. They stay in
        // this list because the property being pinned is about the BYTE, not the
        // tag: no unassigned wire byte may decode as anything. They now fail via
        // `immediateKind`'s `.unsupported`, where before they failed via
        // `.gc_type` — a different route to the same verdict, and the reason to
        // keep asserting it rather than assume it.
        0x1d, 0x1e, 0x27,
    };
    for (tags) |b| {
        const body = [_]u8{b};
        try std.testing.expectError(error.UnsupportedOpcode, decodeBody(std.testing.allocator, &body));
    }

    // The real single-byte ops BETWEEN the two tag ranges must still decode —
    // `0xd0..0xd6` sit in the gap, which is why the guard cannot be one range.
    for ([_]u8{ 0xd1, 0xd4, 0xd6 }) |b| { // ref.is_null / ref.as_non_null / br_on_non_null
        const body = if (b == 0xd6) [_]u8{ b, 0x00 } else [_]u8{ b, 0x0b }; // br_on_non_null takes a label
        const ir = decodeBody(std.testing.allocator, &body) catch |e| {
            std.debug.print("byte 0x{x} unexpectedly rejected: {s}\n", .{ b, @errorName(e) });
            return e;
        };
        defer std.testing.allocator.free(ir);
    }
    // …and so must the real ops just BELOW the lower range (`0xc0..0xc4`, the
    // sign-extension operators), or the new lower bound has been set too low.
    for ([_]u8{ 0xc0, 0xc4 }) |b| {
        const ir = try decodeBody(std.testing.allocator, &[_]u8{ b, 0x0b });
        defer std.testing.allocator.free(ir);
    }
}

test "R3: the six array bulk ops decode from their 0xFB sub-opcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each is `0xFB <sub> <imm…>`; the immediates are LEB indices.
    const body = [_]u8{
        0xfb, 0x09, 0x01, 0x02, // array.new_data  $1 $2
        0xfb, 0x0a, 0x03, 0x04, // array.new_elem  $3 $4
        0xfb, 0x10, 0x05, // array.fill      $5
        0xfb, 0x11, 0x06, 0x07, // array.copy      $6 $7
        0xfb, 0x12, 0x08, 0x09, // array.init_data $8 $9
        0xfb, 0x13, 0x0a, 0x0b, // array.init_elem $10 $11
        0x0b, // end
    };
    const ir = try decodeBody(a, &body);
    try std.testing.expectEqual(@as(usize, 7), ir.len);

    try std.testing.expectEqual(Op.array_new_data, ir[0].op);
    try std.testing.expectEqual(@as(u32, 1), ir[0].imm.gc_data.type_index);
    try std.testing.expectEqual(@as(u32, 2), ir[0].imm.gc_data.data);
    try std.testing.expectEqual(Op.array_new_elem, ir[1].op);
    try std.testing.expectEqual(@as(u32, 3), ir[1].imm.gc_elem.type_index);
    try std.testing.expectEqual(@as(u32, 4), ir[1].imm.gc_elem.elem);
    try std.testing.expectEqual(Op.array_fill, ir[2].op);
    try std.testing.expectEqual(@as(u32, 5), ir[2].imm.gc_type);
    try std.testing.expectEqual(Op.array_copy, ir[3].op);
    try std.testing.expectEqual(@as(u32, 6), ir[3].imm.gc_array_copy.dst);
    try std.testing.expectEqual(@as(u32, 7), ir[3].imm.gc_array_copy.src);
    try std.testing.expectEqual(Op.array_init_data, ir[4].op);
    try std.testing.expectEqual(@as(u32, 9), ir[4].imm.gc_data.data);
    try std.testing.expectEqual(Op.array_init_elem, ir[5].op);
    try std.testing.expectEqual(@as(u32, 11), ir[5].imm.gc_elem.elem);

    // Round-trip the sub-opcode table: what the assembler emits is what the
    // decoder just read. A decoder rule with no matching emitter rule is the
    // producer/consumer blind spot this codebase has hit four times.
    try std.testing.expectEqual(@as(?u8, 0x09), gcSubOpcode(.array_new_data));
    try std.testing.expectEqual(@as(?u8, 0x0a), gcSubOpcode(.array_new_elem));
    try std.testing.expectEqual(@as(?u8, 0x10), gcSubOpcode(.array_fill));
    try std.testing.expectEqual(@as(?u8, 0x11), gcSubOpcode(.array_copy));
    try std.testing.expectEqual(@as(?u8, 0x12), gcSubOpcode(.array_init_data));
    try std.testing.expectEqual(@as(?u8, 0x13), gcSubOpcode(.array_init_elem));
}

test "wide-arithmetic: the encoding matches the SPEC's own bytes, both directions" {
    // 🔑 **OUR ASSEMBLER IS NOT AN ORACLE FOR OUR DECODER**, and these four sub-opcode numbers are
    // exactly the case that rule exists for: had `0x13`–`0x16` been guessed wrong, every text
    // assertion in `wide-arithmetic.wast` would still have passed — the assembler would emit the
    // wrong byte and the decoder would read it back — and the module would be wrong on the wire
    // against every other runtime. The numbers come from the spec suite's own `(module binary …)`,
    // whose overlong LEBs `\fc\93\80\00` / `\fc\94\00` / `\fc\95\80\80\80\00` / `\fc\96\80\80\00`
    // decode to 19, 20, 21, 22.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Decode: the canonical single-byte sub-opcode.
    for ([_]struct { sub: u8, op: Op }{
        .{ .sub = 0x13, .op = .i64_add128 },
        .{ .sub = 0x14, .op = .i64_sub128 },
        .{ .sub = 0x15, .op = .i64_mul_wide_s },
        .{ .sub = 0x16, .op = .i64_mul_wide_u },
    }) |c| {
        const ir = try decodeBody(a, &[_]u8{ 0xfc, c.sub, 0x0b });
        try std.testing.expectEqual(c.op, ir[0].op);
        try std.testing.expectEqual(Imm.none, ir[0].imm);
        // ...and the OVERLONG encoding the corpus insists on decodes identically.
        const long = try decodeBody(a, &[_]u8{ 0xfc, c.sub | 0x80, 0x80, 0x00, 0x0b });
        try std.testing.expectEqual(c.op, long[0].op);
    }
    // Emit: `fcSubOpcode` is the same list read the other way, so a drift between the two
    // would be a module wazmrt writes and cannot read.
    try std.testing.expectEqual(@as(?u8, 0x13), fcSubOpcode(.i64_add128));
    try std.testing.expectEqual(@as(?u8, 0x14), fcSubOpcode(.i64_sub128));
    try std.testing.expectEqual(@as(?u8, 0x15), fcSubOpcode(.i64_mul_wide_s));
    try std.testing.expectEqual(@as(?u8, 0x16), fcSubOpcode(.i64_mul_wide_u));
    // They are `0x100`+ internal tags, so no raw wire byte can ever name one.
    try std.testing.expectEqual(@as(?u8, null), wireByte(.i64_add128));
}
