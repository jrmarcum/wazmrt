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
    /// ⚠️ **NOT a wasm proposal name — deliberately finer-grained than the spec's own grouping.**
    /// Multiple tables arrived *inside* `reference_types`, so the spec has no separate switch for
    /// them. wazmrt needs one because gating on `reference_types` would also disable `funcref`,
    /// which `proposals/threads/imports.wast` legitimately uses in the very modules whose
    /// "multiple tables" assertions we need to honour. The split exists so a snapshot can be run
    /// **at its own era**; it is not a claim that the spec factors the proposals this way.
    /// Layered on `reference_types` — see `incoherent`.
    multi_table = 15,
    /// custom-descriptors. ⚠️ **This bit exists because the proposal CHANGES THE
    /// TYPING OF AN EXISTING INSTRUCTION, not merely because it adds new ones.**
    /// Under it, `br_on_cast`'s `rt2 <: rt1` requirement is relaxed to "`rt1` and
    /// `rt2` share a top type" — so the very same module is `assert_invalid` in
    /// the core testsuite and VALID in `proposals/custom-descriptors/`. There is
    /// no single answer that satisfies both files, which is exactly the situation
    /// `wast.featuresForPath` was built for (F4, `proposals/threads`).
    ///
    /// ✅ **FULLY enforced as of Track F.** It gates the six D3/D4 INSTRUCTIONS, the
    /// `br_on_cast` typing rule, **and** the three type-level formers — `(exact $t)`,
    /// `(descriptor $d)`, `(describes $s)` — wherever they appear: composite types,
    /// struct fields, table/global types, an EXACT func import (descriptor kind
    /// `0x20`), and the exactness carried in instruction immediates.
    ///
    /// ⚠️ It was knowingly partial until then, and the reason is worth keeping: the
    /// walk only visited INSTRUCTIONS, and these formers live in the TYPE SECTION, so
    /// a module using nothing but the type syntax was accepted with the bit off. **A
    /// proposal is not gated when its instructions are gated — it is gated when
    /// everything that makes a module NEED it is.** See `firstViolation`'s type pass.
    ///
    /// Layered on `gc` — see `incoherent`.
    custom_descriptors = 16,
    /// custom-page-sizes: `(memory 1 (pagesize 1))` — a memory declares its own page size,
    /// byte-granular instead of the fixed 64 KiB.
    ///
    /// ⚠️ **This bit was MISSING until Track F, and the proposal shipped without it.**
    /// Track P landed custom-page-sizes end to end — decoder, validator, every bounds
    /// check — and added no way to refuse it, so an embedder who turned off literally
    /// every switch in this enum still accepted byte-paged memories. **A proposal that
    /// ships without a bit here is not "enabled by default"; it is unrefusable**, and the
    /// only thing that would have caught it is the habit of grepping for the gate as part
    /// of landing the feature.
    ///
    /// Layered on nothing — it extends core memories, so it stands alone in `incoherent`.
    custom_page_sizes = 17,

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
        // Multiple tables shipped as part of reference-types, so allowing them while refusing
        // that proposal describes no wasm version that ever existed.
        if (self.has(.multi_table) and !self.has(.reference_types)) return .{ .multi_table, .reference_types };
        // custom-descriptors extends GC; enabling it alone describes no wasm version.
        if (self.has(.custom_descriptors) and !self.has(.gc)) return .{ .custom_descriptors, .gc };
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
        .array_new_data, .array_new_elem, .array_fill, .array_copy, .array_init_data, .array_init_elem,
        .extern_convert_any, .any_convert_extern,
        .ref_test, .ref_cast, .br_on_cast, .br_on_cast_fail,
        => .gc,

        // custom-descriptors (Tracks D3/D4). ⚠️ D3 filed these under `.gc` because
        // no `custom_descriptors` bit existed; D4 had to add one anyway — the
        // proposal RETYPES `br_on_cast`, and a typing rule cannot be filed under
        // the proposal it modifies. Now that the bit exists, the instructions
        // belong to it: "requires GC" was the closest true statement available,
        // not the accurate one.
        .struct_new_desc, .struct_new_default_desc, .ref_get_desc,
        .ref_cast_desc_eq, .br_on_cast_desc_eq, .br_on_cast_desc_eq_fail,
        => .custom_descriptors,

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

/// Every proposal one value type needs — its FAMILY first, then the custom-descriptors
/// `exact` former layered on top.
///
/// 🔑 **Two requirements, in layering order, and the order is the whole point.** A
/// `(ref (exact $t))` needs GC *and* custom-descriptors; reporting whichever happens to be
/// checked first would tell an embedder who disabled GC that they are missing
/// custom-descriptors. `valTypeFeature` alone could not say this — exactness is a BIT on the
/// value type, not a member of its family, so it has no place in a switch over the families.
fn requireValType(fs: Set, vt: types.ValType, found: *?Feature) Error!void {
    try require(fs, valTypeFeature(vt), found);
    if (vt.isExact()) try require(fs, .custom_descriptors, found);
}

/// `requireValType` for a struct field / array element. Packed fields (`i8`/`i16`) are GC's
/// own storage types and carry no value type to inspect; the enclosing composite already
/// required `.gc`.
fn requireStorage(fs: Set, st: Module.StorageType, found: *?Feature) Error!void {
    switch (st) {
        .val => |v| try requireValType(fs, v, found),
        .i8, .i16 => {},
    }
}

/// The custom-descriptors exactness carried inside an INSTRUCTION immediate.
///
/// ⚠️ **The instructions themselves are not the whole of it.** `ref.cast`, `br_on_cast` and
/// `ref.null` all exist without custom-descriptors and are gated as `.gc` / `.reference_types`;
/// what the proposal adds is an `exact` prefix on the heap type they carry. A gate that only
/// asked "is this opcode allowed" would let `ref.cast (ref (exact $t))` through with the bit
/// off — refusing the *opcodes* a proposal adds is not the same as refusing the proposal.
fn immIsExact(imm: opcode.Imm) bool {
    return switch (imm) {
        .ref_type, .ref_cast => |rt| rt.exact,
        .br_cast => |bc| bc.src.exact or bc.dst.exact,
        .block_type => |bt| switch (bt) {
            .ref => |rt| rt.exact,
            .value => |v| v.isExact(),
            .empty, .type_index => false,
        },
        .select_types => |ts| blk: {
            for (ts) |t| if (t.isExact()) break :blk true;
            break :blk false;
        },
        else => false,
    };
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
            for (ft.params) |p| requireValType(fs, p, &found) catch return found;
            for (ft.results) |r| requireValType(fs, r, &found) catch return found;
            // Multi-value: more than one result is the proposal's whole content.
            if (ft.results.len > 1) require(fs, .multi_value, &found) catch return found;
        },
        // ⚠️ The FIELDS are walked too, not just the composite kind. `.gc` alone left a
        // `(struct (field (ref (exact $t))))` accepted with custom-descriptors off whenever GC
        // was on — the arm answered the question "is this a GC form?" when the question is
        // "what does this type need?".
        .@"struct" => |fields| {
            require(fs, .gc, &found) catch return found;
            for (fields) |f| requireStorage(fs, f.storage, &found) catch return found;
        },
        .array => |f| {
            require(fs, .gc, &found) catch return found;
            requireStorage(fs, f.storage, &found) catch return found;
        },
    };

    // --- custom-descriptors type-level formers ---------------------------------------------
    // `(descriptor $d)` and `(describes $s)` are clauses on a TYPE, so nothing in the
    // instruction walk below can see them. A module that only declares a descriptor pair —
    // never executing one D3/D4 instruction — used to load with `custom_descriptors` off.
    for (module.descriptors) |d| if (d != null) {
        require(fs, .custom_descriptors, &found) catch return found;
    };
    for (module.describes) |d| if (d != null) {
        require(fs, .custom_descriptors, &found) catch return found;
    };

    // --- memories ------------------------------------------------------------------------
    if (module.memories.len > 1) require(fs, .multi_memory, &found) catch return found;
    for (module.memories) |m| {
        if (m.limits.is64) require(fs, .memory64, &found) catch return found;
        if (m.limits.shared) require(fs, .threads, &found) catch return found;
        // custom-page-sizes. 16 is the fixed 64 KiB page every wasm before the proposal had, and
        // `Limits.page_size_log2` defaults to it — so `!= 16` is exactly "this memory declared
        // its own page size". Tested on the whole INDEX SPACE, imports included, for the reason
        // `module.tables` is: an IMPORTED byte-paged memory needs the proposal just as much, and
        // counting only defined memories would gate the easy half.
        if (m.limits.page_size_log2 != 16) require(fs, .custom_page_sizes, &found) catch return found;
    }

    // --- tables and globals --------------------------------------------------------------
    // ⚠️ `module.tables` is the whole INDEX SPACE — imported tables first, then defined — so this
    // one test covers all three spellings the spec asserts on (import+import, import+defined,
    // defined+defined). Counting only defined tables would pass two of the three.
    if (module.tables.len > 1) require(fs, .multi_table, &found) catch return found;
    for (module.tables) |t| requireValType(fs, t.element, &found) catch return found;
    for (module.globals) |g| requireValType(fs, g.content, &found) catch return found;

    // --- tags ----------------------------------------------------------------------------
    if (module.tags.len > 0) require(fs, .exceptions, &found) catch return found;
    for (module.imports) |im| {
        if (im.type.kind() == .tag) require(fs, .exceptions, &found) catch return found;
        // custom-descriptors: an EXACT func import (descriptor kind `0x20`) demands type
        // EQUALITY where an ordinary import accepts a subtype. It is a link-time rule with no
        // instruction and no value type of its own, so neither walk reaches it.
        if (im.exact) require(fs, .custom_descriptors, &found) catch return found;
    }

    // --- function bodies -------------------------------------------------------------------
    // Decoded here rather than reusing the validator's pass: this runs ONLY when something is
    // restricted, so the default path pays nothing for it.
    for (module.code) |code| {
        const instrs = opcode.decodeBody(gpa, code.body) catch continue; // malformed: validate reports it
        defer opcode.freeBody(gpa, instrs);
        for (instrs) |instr| {
            require(fs, instrFeature(instr), &found) catch return found;
            // The opcode's own proposal is only half of it — see `immIsExact`.
            if (immIsExact(instr.imm)) require(fs, .custom_descriptors, &found) catch return found;
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
    if (n != 254) @compileError(std.fmt.comptimePrint(
        "opcode.Op has {d} members, features.zig was written against 254. A new opcode must be " ++
            "classified in opFeature() before this number is updated — an unclassified opcode " ++
            "silently passes every proposal gate.",
        .{n},
    ));
}

// The classification behind that 254, recorded so the next person can re-check it cheaply rather
// than re-deriving it: 82 opcodes are mapped to a proposal in `opFeature`, and the remaining 172
// are WebAssembly 1.0 core — control flow, numerics, comparisons, loads/stores, locals/globals,
// `select`, `drop`, `nop`, `memory.size`/`grow`.
//
// ⚠️ The prose here read "that 238 … 66 opcodes" while the pin above said 240; both halves of a
// note like this go stale independently, and only the pin is compiler-checked. R3 (2026-08-13)
// added the six array bulk ops — 68 → 74 mapped, 240 → 246 total — and the core count is
// unchanged at 172, which is the arithmetic that says the six really did land in `.gc`.
//
// ⚠️ Four of those 172 are spelled `@"unreachable"`, `@"if"`, `@"else"` and `@"return"` because
// they collide with Zig keywords. A grep for `^    [a-z_]` misses all four — which is exactly how
// a hand-audit of this enum goes wrong, and why the count above comes from `@typeInfo` rather
// than from a text search.

// =========================================================================================
// Tests. These live here rather than in `capi.zig` (where the four original gating tests are)
// because every case below turns on a piece of TYPE SYNTAX, and hand-encoding a descriptor rec
// group as a byte array would make the test unreadable at exactly the point it has to be read.
// =========================================================================================

/// Everything on except the named proposals. Dependents are the caller's job — `Set.incoherent`
/// reports an unlayered set rather than repairing it, and a test that repaired it here would be
/// asserting against a config the engine would refuse.
fn setWithout(off: []const Feature) Set {
    var s: Set = .{};
    for (off) |f| s.set(f, false);
    return s;
}

/// Assemble `src`, decode it, and answer which proposal it needs that `fs` does not grant.
fn needs(src: []const u8, fs: Set) !?Feature {
    const wat = @import("wat.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bin = try wat.assemble(arena.allocator(), src);
    var m = try Module.decode(std.testing.allocator, bin);
    defer m.deinit();
    return firstViolation(std.testing.allocator, &m, fs);
}

test "gating: custom_descriptors covers the TYPE-LEVEL formers, not only its instructions" {
    // ⚠️ REGRESSION TEST FOR A KNOWINGLY PARTIAL GATE. `firstViolation` walked instructions, and
    // `(exact $t)` / `(descriptor $d)` / `(describes $s)` live in the TYPE SECTION — so every
    // module below, none of which executes a single D3/D4 instruction, loaded with the bit off.
    //
    // 🔑 GC stays ON throughout. That is the whole point: with GC off these would be refused
    // anyway, and the test would pass while proving nothing about `custom_descriptors`.
    const off = setWithout(&.{.custom_descriptors});
    const all: Set = .{};

    const cases = [_][]const u8{
        // `(exact $t)` in a function signature — a parameter, then a result.
        "(module (type $s (struct)) (type (func (param (ref (exact $s))))))",
        "(module (type $s (struct)) (type (func (result (ref (exact $s))))))",
        // ... in a STRUCT FIELD and an ARRAY ELEMENT. Reached only because the composite arms
        // now walk their fields; requiring `.gc` for the kind alone stopped at the container.
        "(module (type $s (struct)) (type (struct (field (ref (exact $s))))))",
        "(module (type $s (struct)) (type (array (ref (exact $s)))))",
        // ... in an imported GLOBAL's type and an imported TABLE's element type.
        "(module (type $s (struct)) (import \"a\" \"b\" (global (ref null (exact $s)))))",
        "(module (type $s (struct)) (import \"a\" \"b\" (table 1 (ref null (exact $s)))))",
        // A `(descriptor $d)`/`(describes $s)` pair: no `exact` anywhere, no instruction at all.
        "(module (rec (type $a (sub (descriptor $a.d) (struct))) (type $a.d (sub (describes $a) (struct)))))",
        // An EXACT FUNC IMPORT (descriptor kind 0x20) — a link-time rule with neither an
        // instruction nor a value type of its own, so neither walk could reach it.
        "(module (type $f (func)) (import \"m\" \"n\" (func (exact (type $f)))))",
        // And exactness carried in an INSTRUCTION IMMEDIATE. `ref.test` exists without
        // custom-descriptors and is gated as `.gc`; the `exact` prefix on its target is the
        // proposal. A gate that only asked "is this opcode allowed" let this through.
        "(module (type $s (struct)) (func (param anyref) (result i32) (ref.test (ref (exact $s)) (local.get 0))))",
    };
    for (cases) |src| {
        std.testing.expectEqual(@as(?Feature, .custom_descriptors), try needs(src, off)) catch |e| {
            std.debug.print("not gated: {s}\n", .{src});
            return e;
        };
        // The same bytes are fine with the bit on — so the refusal is the gate, not the module.
        try std.testing.expectEqual(@as(?Feature, null), try needs(src, all));
    }
}

test "gating: custom_descriptors has NO false positives on plain GC" {
    // The failure mode that would make the new type pass unusable: refusing GC modules that
    // never touch a descriptor. Every one of these must load with `custom_descriptors` off.
    const off = setWithout(&.{.custom_descriptors});
    const cases = [_][]const u8{
        "(module (type $s (struct (field i32))) (func (result (ref $s)) (struct.new_default $s)))",
        "(module (type $a (array (mut i32))) (func (result (ref $a)) (array.new_default $a (i32.const 1))))",
        "(module (type $s (struct)) (func (param anyref) (result i32) (ref.test (ref $s) (local.get 0))))",
        "(module (type $s (struct)) (global (ref null $s) (ref.null $s)))",
    };
    for (cases) |src| {
        std.testing.expectEqual(@as(?Feature, null), try needs(src, off)) catch |e| {
            std.debug.print("false positive: {s}\n", .{src});
            return e;
        };
    }
}

test "gating: an exact ref reports the LAYER it is missing — gc before custom_descriptors" {
    // `requireValType` asks for the family first and the `exact` former second, and the order is
    // observable. An embedder who turned off GC has not "forgotten custom-descriptors"; telling
    // them so would name a switch that is not the one they touched.
    const src = "(module (type $s (struct)) (type (func (param (ref (exact $s))))))";
    // A coherent "no GC" set: `Set.incoherent` requires custom_descriptors to fall with it.
    try std.testing.expectEqual(@as(?Feature, .gc), try needs(src, setWithout(&.{ .gc, .custom_descriptors })));
    try std.testing.expectEqual(@as(?Feature, .custom_descriptors), try needs(src, setWithout(&.{.custom_descriptors})));
}

test "gating: custom_page_sizes — the proposal that shipped with no switch at all" {
    // ⚠️ REGRESSION TEST FOR AN UNREFUSABLE PROPOSAL. Track P landed custom-page-sizes with no
    // `Feature` member, so `wazmrt_config_all_features(cfg, false)` — every switch in the enum
    // off — still accepted a byte-paged memory. There was nothing to turn off.
    const off = setWithout(&.{.custom_page_sizes});
    const all: Set = .{};

    const paged = [_][]const u8{
        "(module (memory 1 (pagesize 1)))",
        // The IMPORTED half. `module.memories` is the whole index space, imports first, and a
        // gate that counted only defined memories would cover exactly half the spellings.
        "(module (memory (import \"m\" \"n\") 0 (pagesize 1)))",
    };
    for (paged) |src| {
        std.testing.expectEqual(@as(?Feature, .custom_page_sizes), try needs(src, off)) catch |e| {
            std.debug.print("not gated: {s}\n", .{src});
            return e;
        };
        try std.testing.expectEqual(@as(?Feature, null), try needs(src, all));
    }

    // No false positives: an ordinary 64 KiB memory is MVP and must survive with EVERY switch
    // off, defined or imported. `Limits.page_size_log2` defaults to 16, so a gate written as
    // "the field is set" rather than "the field is not 16" would have refused both of these.
    var nothing: Set = .{};
    for (0..count) |i| nothing.set(@enumFromInt(@as(u8, @intCast(i))), false);
    for ([_][]const u8{
        "(module (memory 1))",
        "(module (memory (import \"m\" \"n\") 0))",
    }) |src| {
        std.testing.expectEqual(@as(?Feature, null), try needs(src, nothing)) catch |e| {
            std.debug.print("false positive: {s}\n", .{src});
            return e;
        };
    }
}
