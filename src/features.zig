//! features.zig — per-proposal gating.
//!
//! A module that uses a DISABLED proposal is **invalid**: it is refused wholly, before execution,
//! rather than trapping part-way through. That is the only useful meaning for the switch, because
//! an embedder disables a proposal to say "I will not run guests that need this", and a check that
//! fires mid-execution has already run some of the guest.
//!
//! **Everything is enabled by default.** Restricting is opt-in, so the default path costs nothing:
//! `Set.all()` short-circuits the whole pass (see `check`).
//!
//! ⚠️ **THE COVERAGE PROBLEM, AND HOW IT IS SOLVED HERE.** A gate that misses an opcode is worse
//! than no gate: it reads as a control while letting the thing through. The mapping below is a
//! switch with an `else` for the MVP core — so a NEW opcode would silently default to "always
//! allowed". The `comptime` assertion at the bottom of this file pins the size of the `Op` enum,
//! so adding one fails the build until someone decides which proposal it belongs to. Do not
//! "fix" that assertion by bumping the number without making that decision.

const std = @import("std");
const Module = @import("Module.zig");
const opcode = @import("opcode.zig");
const types = @import("types.zig");

/// The proposals that can be individually refused. Values match `wazmrt_feature_t` in
/// `include/wazmrt.h` — the C ABI casts straight across, so the two must not drift.
pub const Feature = enum(u8) {
    sign_extension = 0,
    saturating_float_to_int = 1,
    multi_value = 2,
    reference_types = 3,
    bulk_memory = 4,
    extended_const = 5,
    simd = 6,
    relaxed_simd = 7,
    threads = 8,
    multi_memory = 9,
    memory64 = 10,
    function_references = 11,
    gc = 12,
    exceptions = 13,
    tail_call = 14,

    pub fn name(self: Feature) []const u8 {
        return @tagName(self);
    }
};

pub const count = @typeInfo(Feature).@"enum".fields.len;

/// Which proposals a module may use. All-on is the default and the fast path.
pub const Set = struct {
    bits: [count]bool = [_]bool{true} ** count,

    pub fn has(self: Set, f: Feature) bool {
        return self.bits[@intFromEnum(f)];
    }

    pub fn set(self: *Set, f: Feature, on: bool) void {
        self.bits[@intFromEnum(f)] = on;
    }

    /// True when nothing is restricted — the common case, and the one that skips the pass.
    pub fn all(self: Set) bool {
        for (self.bits) |b| if (!b) return false;
        return true;
    }

    /// A proposal layered on another cannot be enabled alone. Reported rather than repaired:
    /// silently enabling a dependency would accept modules the embedder meant to refuse.
    pub fn incoherent(self: Set) ?[2]Feature {
        if (self.has(.relaxed_simd) and !self.has(.simd)) return .{ .relaxed_simd, .simd };
        if (self.has(.gc) and !self.has(.function_references)) return .{ .gc, .function_references };
        if (self.has(.function_references) and !self.has(.reference_types)) return .{ .function_references, .reference_types };
        if (self.has(.exceptions) and !self.has(.reference_types)) return .{ .exceptions, .reference_types };
        return null;
    }
};

pub const Error = error{DisabledProposal};

/// The proposal an instruction belongs to, or null for the WebAssembly 1.0 core.
///
/// ⚠️ Relaxed SIMD shares the `.simd` tag — the distinction is the `0xFD` sub-opcode, so it is
/// resolved by `instrFeature` rather than here.
fn opFeature(op: opcode.Op) ?Feature {
    return switch (op) {
        // Sign-extension operators.
        .i32_extend8_s, .i32_extend16_s, .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => .sign_extension,

        // Non-trapping float→int truncation.
        .i32_trunc_sat_f32_s, .i32_trunc_sat_f32_u, .i32_trunc_sat_f64_s, .i32_trunc_sat_f64_u,
        .i64_trunc_sat_f32_s, .i64_trunc_sat_f32_u, .i64_trunc_sat_f64_s, .i64_trunc_sat_f64_u,
        => .saturating_float_to_int,

        // Bulk memory. `table.init`/`table.copy` + the drops belong to this proposal too.
        .memory_init, .data_drop, .memory_copy, .memory_fill, .table_init, .elem_drop, .table_copy => .bulk_memory,

        // Reference types: the ref values themselves, typed select, and table get/set/grow/size/fill.
        .ref_null, .ref_is_null, .ref_func, .select_t, .table_get, .table_set, .table_grow, .table_size, .table_fill => .reference_types,

        // Typed function references.
        .call_ref, .return_call_ref, .ref_as_non_null, .br_on_null, .br_on_non_null => .function_references,

        // Tail calls. `return_call_ref` above belongs to function-references, not
        // here — it arrived with that proposal and is gated with its siblings.
        .return_call, .return_call_indirect => .tail_call,

        // WasmGC: i31, struct, array, equality and the casts.
        .ref_eq, .ref_i31, .i31_get_s, .i31_get_u,
        .struct_new, .struct_new_default, .struct_get, .struct_get_s, .struct_get_u, .struct_set,
        .array_new, .array_new_default, .array_new_fixed, .array_get, .array_get_s, .array_get_u,
        .array_set, .array_len,
        .ref_test, .ref_cast, .br_on_cast, .br_on_cast_fail,
        => .gc,

        // Exception handling, both encodings.
        .throw, .throw_ref, .try_table, .try_, .catch_, .catch_all, .rethrow, .delegate => .exceptions,

        .simd => .simd, // relaxed vs not is decided by the sub-opcode
        .atomic => .threads,

        // WebAssembly 1.0 core. See the comptime assertion below: this `else` is why adding an
        // opcode must be a deliberate decision rather than a silent default.
        else => null,
    };
}

/// The lowest `0xFD` sub-opcode belonging to relaxed SIMD. Everything at or above this in the
/// SIMD space is the relaxed set; below it is fixed-width SIMD.
const first_relaxed_simd_sub: u32 = 0x100;

fn instrFeature(instr: opcode.Instr) ?Feature {
    const f = opFeature(instr.op) orelse return null;
    if (f == .simd and instr.imm == .simd and instr.imm.simd.sub >= first_relaxed_simd_sub) return .relaxed_simd;
    return f;
}

/// The proposal a value type belongs to. Catches a module that never executes a gated
/// instruction but still *declares* a gated type — a `v128` parameter, say.
fn valTypeFeature(vt: types.ValType) ?Feature {
    return switch (vt) {
        .i32, .i64, .f32, .f64 => null,
        .v128 => .simd,
        .funcref, .externref => .reference_types,
        else => blk: {
            // Everything else in this non-exhaustive enum is a GC or typed-ref form: the abstract
            // heads (any/eq/i31/struct/array/none/…), their non-null variants, and concrete
            // `(ref $t)` indices. Treated as GC, which requires function-references, which
            // requires reference-types — so a disabled GC refuses all of them.
            break :blk .gc;
        },
    };
}

fn require(fs: Set, f: ?Feature, found: *?Feature) Error!void {
    const need = f orelse return;
    if (fs.has(need)) return;
    found.* = need;
    return error.DisabledProposal;
}

/// The proposal a module needs but was not granted, or null if it is within its budget.
///
/// Returns the offending feature rather than just failing, so the caller can name it — "this
/// module uses gc" is actionable; "invalid module" is not.
pub fn firstViolation(gpa: std.mem.Allocator, module: *const Module, fs: Set) !?Feature {
    if (fs.all()) return null; // nothing restricted: skip the whole pass
    var found: ?Feature = null;

    // --- composite types -------------------------------------------------------------------
    // ⚠️ `comp_types` holds function signatures AND the GC struct/array forms, so its mere
    // non-emptiness says nothing — every module has function types. Only the struct/array arms
    // are GC.
    for (module.comp_types) |ct| switch (ct) {
        .func => |ft| {
            for (ft.params) |p| require(fs, valTypeFeature(p), &found) catch return found;
            for (ft.results) |r| require(fs, valTypeFeature(r), &found) catch return found;
            // Multi-value: more than one result is the proposal's whole content.
            if (ft.results.len > 1) require(fs, .multi_value, &found) catch return found;
        },
        .@"struct", .array => require(fs, .gc, &found) catch return found,
    };

    // --- memories ------------------------------------------------------------------------
    if (module.memories.len > 1) require(fs, .multi_memory, &found) catch return found;
    for (module.memories) |m| {
        if (m.limits.is64) require(fs, .memory64, &found) catch return found;
        if (m.limits.shared) require(fs, .threads, &found) catch return found;
    }

    // --- tables and globals --------------------------------------------------------------
    for (module.tables) |t| require(fs, valTypeFeature(t.element), &found) catch return found;
    for (module.globals) |g| require(fs, valTypeFeature(g.content), &found) catch return found;

    // --- tags ----------------------------------------------------------------------------
    if (module.tags.len > 0) require(fs, .exceptions, &found) catch return found;
    for (module.imports) |im| if (im.type.kind() == .tag) {
        require(fs, .exceptions, &found) catch return found;
    };

    // --- function bodies -------------------------------------------------------------------
    // Decoded here rather than reusing the validator's pass: this runs ONLY when something is
    // restricted, so the default path pays nothing for it.
    for (module.code) |code| {
        const instrs = opcode.decodeBody(gpa, code.body) catch continue; // malformed: validate reports it
        defer opcode.freeBody(gpa, instrs);
        for (instrs) |instr| {
            require(fs, instrFeature(instr), &found) catch return found;
        }
    }

    return null;
}

// ⚠️ COVERAGE PIN — see the file header. `opFeature` ends in `else => null`, so a newly added
// opcode would be treated as WebAssembly 1.0 core and pass every gate silently. This assertion
// makes that impossible without a deliberate act: adding an `Op` breaks the build here.
//
// If it fires: decide which proposal the new opcode belongs to, add it to `opFeature` (or
// confirm it really is MVP core), and only then update the number.
comptime {
    const n = @typeInfo(opcode.Op).@"enum".fields.len;
    if (n != 240) @compileError(std.fmt.comptimePrint(
        "opcode.Op has {d} members, features.zig was written against 240. A new opcode must be " ++
            "classified in opFeature() before this number is updated — an unclassified opcode " ++
            "silently passes every proposal gate.",
        .{n},
    ));
}

// The classification behind that 238, recorded so the next person can re-check it cheaply rather
// than re-deriving it: 66 opcodes are mapped to a proposal in `opFeature`, and the remaining 172
// are WebAssembly 1.0 core — control flow, numerics, comparisons, loads/stores, locals/globals,
// `select`, `drop`, `nop`, `memory.size`/`grow`.
//
// ⚠️ Four of those 172 are spelled `@"unreachable"`, `@"if"`, `@"else"` and `@"return"` because
// they collide with Zig keywords. A grep for `^    [a-z_]` misses all four — which is exactly how
// a hand-audit of this enum goes wrong, and why the count above comes from `@typeInfo` rather
// than from a text search.
