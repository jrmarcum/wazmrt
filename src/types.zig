//! Core WebAssembly binary-format constants, section identifiers, and the
//! decoder error set. Kept dependency-free so it compiles for every target,
//! including `wasm32-freestanding`.

/// The 4-byte magic that opens every WebAssembly binary: "\0asm".
pub const magic = [4]u8{ 0x00, 0x61, 0x73, 0x6d };

/// The only binary-format version wazmrt currently decodes.
pub const supported_version: u32 = 1;

/// Section identifiers as defined by the core WebAssembly spec (§5.5).
/// Non-exhaustive so an unknown id decodes rather than crashes; callers
/// validate the range where it matters.
pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    tag = 13, // exception tags (EH proposal, Phase 6)
    _,

    /// Highest identifier defined by the current spec.
    pub const max: u8 = 13;
};

/// WebAssembly value types (§5.3.1). Numeric and abstract-reference types keep
/// their single binary byte (< 0x100). A **concrete typed reference** `(ref null?
/// $t)` (GC) is encoded in the high bits — bit 31 marks concrete, bit 30 marks
/// nullable, bits 28–29 the family (func/struct/array), bits 0–27 the type index
/// — so `ValType` stays a single comparable scalar (backed by `u32`). This lets
/// `(ref $t)` flow through params/fields/locals with its exact type instead of
/// collapsing to a family head. Non-exhaustive: an unrecognized byte decodes
/// rather than crashing; a later validation pass rejects it.
pub const ValType = enum(u32) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    // Abstract nullable heap-type shorthands, encoded by their real valtype bytes.
    // `funcref`/`externref` head their own hierarchies; the `any` family (anyref →
    // eqref → i31ref/structref/arrayref, with `nullref` the bottom) is the WasmGC
    // internal hierarchy (full GC, P3). Concrete typed refs still collapse to the
    // matching family head (see `Module.readValType`).
    funcref = 0x70,
    externref = 0x6f,
    anyref = 0x6e,
    eqref = 0x6d,
    i31ref = 0x6c,
    structref = 0x6b,
    arrayref = 0x6a,
    exnref = 0x69, // (ref null exn) — exception references (EH proposal, Phase 6)
    // The four BOTTOM types, one per hierarchy. Only a null reference inhabits
    // any of them, but each is a subtype of everything in its hierarchy —
    // including the concrete types — which is the property that makes
    // `(func (result (ref null $t)) (global.get $nullfunc))` valid.
    //
    // ⚠️ `nullfuncref`/`nullexternref`/`nullexnref` used to be FOLDED onto
    // `funcref`/`externref`/`exnref` on the reasoning that "only null inhabits
    // them, so the distinction is unobservable". It is observable exactly where
    // it matters: folded onto the head, a bottom stops being below the concrete
    // types and cannot flow into a `(ref null $t)`.
    nullref = 0x71, // (ref null none)      — bottom of the `any` hierarchy
    nullfuncref = 0x73, // (ref null nofunc)    — bottom of the `func` hierarchy
    nullexternref = 0x72, // (ref null noextern)  — bottom of the `extern` hierarchy
    nullexnref = 0x74, // (ref null noexn)     — bottom of the `exn` hierarchy
    // Non-nullable reference types (`(ref func)`/`(ref i31)`/…, function-references
    // + GC proposals). Synthetic internal tags in an otherwise-unused valtype-byte
    // range — our assembler/decoder round-trip them, and an external binary's
    // `0x64 ht` maps here.
    funcref_nn = 0x68,
    externref_nn = 0x67,
    anyref_nn = 0x66,
    eqref_nn = 0x65,
    i31ref_nn = 0x62,
    structref_nn = 0x61,
    arrayref_nn = 0x59,
    nullref_nn = 0x58, // (ref none) — uninhabited but syntactically valid
    exnref_nn = 0x57, // (ref exn) — non-null exception reference
    // The non-null bottoms — `(ref nofunc)` and friends. Uninhabited (not even
    // null), but syntactically valid and needed so the nullable/non-null pair
    // logic in `RefHeap.valType` is total.
    nullfuncref_nn = 0x56,
    nullexternref_nn = 0x55,
    nullexnref_nn = 0x54,
    _,

    // --- Concrete typed-reference encoding (high bits of the u32) -------------
    const concrete_bit: u32 = 0x8000_0000;
    const nullable_bit: u32 = 0x4000_0000;
    const kind_shift: u5 = 28;
    const kind_mask: u32 = 0x3 << kind_shift;
    /// `(ref (exact $t))` — custom-descriptors. **Stolen from the top of the index field**, which
    /// is why `index_mask` is 27 bits and not 28: bits 31/30/29-28 were all spoken for, so the
    /// only room was the index's headroom. The cost is halving the largest expressible type index
    /// from ~268M to ~134M, which no real module approaches and which
    /// `max_concrete_index` keeps enforceable.
    const exact_bit: u32 = 0x0800_0000;
    const index_mask: u32 = 0x07ff_ffff; // 27 bits — up to ~134M types

    /// Largest type index a concrete `(ref $t)` can carry. `concreteRef` masks
    /// with `index_mask`, so anything above this **silently truncates** — and a
    /// large index can truncate to a small *valid* one, which is type confusion
    /// rather than merely a wrong number. Callers must reject above this before
    /// constructing. The binary decoder already bounds `ti` by the declared type
    /// count (`readHeapTypeRef`); the text assembler checks against this.
    pub const max_concrete_index: u32 = index_mask;

    /// Build a concrete typed reference `(ref null? $ti)` for family `kind`
    /// (must be `.func`/`.@"struct"`/`.array`).
    pub fn concreteRef(is_nullable: bool, kind: RefHeap, ti: u32) ValType {
        return concreteRefEx(is_nullable, kind, ti, false);
    }

    /// As `concreteRef`, plus the custom-descriptors `exact` flag.
    ///
    /// Kept as a separate entry point rather than a fourth parameter on `concreteRef` because
    /// **31 existing call sites all mean "inexact"**, and threading a `false` through every one of
    /// them would be noise that hides the handful of sites where exactness is a real decision.
    /// ⚠️ That is the opposite call from the feature-set rule (*a defaulted policy is a policy
    /// nobody reviewed*) and for the opposite reason: inexact is not a policy, it is what a plain
    /// `(ref $t)` MEANS. The two sites that construct exact refs say so explicitly.
    pub fn concreteRefEx(is_nullable: bool, kind: RefHeap, ti: u32, is_exact: bool) ValType {
        const k: u32 = switch (kind) {
            .func => 0,
            .@"struct" => 1,
            .array => 2,
            else => unreachable,
        };
        return @enumFromInt(concrete_bit |
            (if (is_nullable) nullable_bit else 0) |
            (if (is_exact) exact_bit else 0) |
            (k << kind_shift) |
            (ti & index_mask));
    }

    /// True if this is an EXACT concrete reference: `(ref (exact $t))` admits `$t` and nothing
    /// else, where a plain `(ref $t)` admits every subtype of `$t`.
    ///
    /// 🔒 **The soundness hinge of the whole descriptors proposal.** Answering "yes, a subtype
    /// fits" where the spec demands exact is type confusion — the guest receives a value of a type
    /// it proved it did not have. Meaningless (and false) for non-concrete types, which is why it
    /// guards on `isConcrete` rather than testing the bit alone: an abstract valtype's byte may
    /// happen to have bit 27 set.
    pub fn isExact(self: ValType) bool {
        return self.isConcrete() and (@intFromEnum(self) & exact_bit != 0);
    }

    /// True if this is a concrete typed reference (carries a type index).
    pub fn isConcrete(self: ValType) bool {
        return @intFromEnum(self) & concrete_bit != 0;
    }

    /// The type index of a concrete reference (asserts `isConcrete`).
    pub fn concreteIndex(self: ValType) u32 {
        return @intFromEnum(self) & index_mask;
    }

    /// Everything about a concrete reference EXCEPT its type index: the concrete
    /// marker, nullability and family bits. Two concrete refs are the same type
    /// only if these agree *and* their indices name the same type — `(ref $t)` and
    /// `(ref null $t)` are distinct, so the index alone never settles it.
    /// ⚠️ **`exact_bit` is included, and must be.** This is what decides whether two concrete refs
    /// are the SAME type, and `(ref (exact $t))` is not `(ref $t)` — omitting the bit here would
    /// make them compare equal everywhere identity is asked, which is the type-confusion direction
    /// rather than the merely-wrong-answer one.
    pub fn flagBits(self: ValType) u32 {
        return @intFromEnum(self) & (concrete_bit | nullable_bit | exact_bit | kind_mask);
    }

    /// True only for the defined value types (rejects garbage `@enumFromInt`).
    pub fn isValid(self: ValType) bool {
        if (self.isConcrete()) return true;
        return switch (self) {
            .i32, .i64, .f32, .f64, .v128 => true,
            else => self.isRef(),
        };
    }

    /// True for any reference type (nullable or not).
    pub fn isRef(self: ValType) bool {
        if (self.isConcrete()) return true;
        return switch (self) {
            .funcref, .externref, .anyref, .eqref, .i31ref, .structref, .arrayref, .exnref, .nullref => true,
            .nullfuncref, .nullexternref, .nullexnref => true,
            .funcref_nn, .externref_nn, .anyref_nn, .eqref_nn, .i31ref_nn, .structref_nn, .arrayref_nn, .exnref_nn, .nullref_nn => true,
            .nullfuncref_nn, .nullexternref_nn, .nullexnref_nn => true,
            else => false,
        };
    }

    /// True for a non-nullable reference (a non-defaultable local type).
    pub fn isNonNullRef(self: ValType) bool {
        if (self.isConcrete()) return @intFromEnum(self) & nullable_bit == 0;
        return switch (self) {
            .funcref_nn, .externref_nn, .anyref_nn, .eqref_nn, .i31ref_nn, .structref_nn, .arrayref_nn, .exnref_nn, .nullref_nn => true,
            .nullfuncref_nn, .nullexternref_nn, .nullexnref_nn => true,
            else => false,
        };
    }

    /// The NON-nullable form of a reference type (nullable → non-null; others
    /// as-is). The inverse of `nullable`, needed by `ref.as_non_null` and
    /// `br_on_null`, whose whole purpose is to remove nullability.
    pub fn nonNull(self: ValType) ValType {
        if (self.isConcrete()) return @enumFromInt(@intFromEnum(self) & ~nullable_bit);
        return switch (self) {
            .funcref => .funcref_nn,
            .externref => .externref_nn,
            .anyref => .anyref_nn,
            .eqref => .eqref_nn,
            .i31ref => .i31ref_nn,
            .structref => .structref_nn,
            .arrayref => .arrayref_nn,
            .exnref => .exnref_nn,
            .nullref => .nullref_nn,
            .nullfuncref => .nullfuncref_nn,
            .nullexternref => .nullexternref_nn,
            .nullexnref => .nullexnref_nn,
            else => self,
        };
    }

    /// The nullable form of a reference type (non-null → nullable; others as-is).
    pub fn nullable(self: ValType) ValType {
        if (self.isConcrete()) return @enumFromInt(@intFromEnum(self) | nullable_bit);
        return switch (self) {
            .funcref_nn => .funcref,
            .externref_nn => .externref,
            .anyref_nn => .anyref,
            .eqref_nn => .eqref,
            .i31ref_nn => .i31ref,
            .structref_nn => .structref,
            .arrayref_nn => .arrayref,
            .exnref_nn => .exnref,
            .nullref_nn => .nullref,
            .nullfuncref_nn => .nullfuncref,
            .nullexternref_nn => .nullexternref,
            .nullexnref_nn => .nullexnref,
            else => self,
        };
    }

    /// The heap type a reference points at, ignoring nullability. Used to decide
    /// reference subtyping (`RefHeap.sub`). Non-reference types have no heap.
    pub const RefHeap = enum {
        func,
        extern_,
        any,
        eq,
        i31,
        @"struct",
        array,
        none,
        exn, // exception references — its own hierarchy (EH proposal, Phase 6)
        // The bottoms of the func / extern / exn hierarchies. `none` above is the
        // `any` family's. Each is below EVERY type in its hierarchy, concrete
        // types included — see `sub` and `validate.subtypeOf`.
        nofunc,
        noextern,
        noexn,

        /// The value type for this heap head at the given nullability (the
        /// collapsed reference representation — concrete refs share their head).
        pub fn valType(self: RefHeap, is_nullable: bool) ValType {
            return switch (self) {
                .func => if (is_nullable) .funcref else .funcref_nn,
                .extern_ => if (is_nullable) .externref else .externref_nn,
                .any => if (is_nullable) .anyref else .anyref_nn,
                .eq => if (is_nullable) .eqref else .eqref_nn,
                .i31 => if (is_nullable) .i31ref else .i31ref_nn,
                .@"struct" => if (is_nullable) .structref else .structref_nn,
                .array => if (is_nullable) .arrayref else .arrayref_nn,
                .none => if (is_nullable) .nullref else .nullref_nn,
                .exn => if (is_nullable) .exnref else .exnref_nn,
                .nofunc => if (is_nullable) .nullfuncref else .nullfuncref_nn,
                .noextern => if (is_nullable) .nullexternref else .nullexternref_nn,
                .noexn => if (is_nullable) .nullexnref else .nullexnref_nn,
            };
        }

        /// The top of this head's hierarchy: `any` for the internal GC family,
        /// else `func` / `extern`.
        pub fn top(self: RefHeap) RefHeap {
            return switch (self) {
                .func, .nofunc => .func,
                .extern_, .noextern => .extern_,
                .exn, .noexn => .exn,
                else => .any,
            };
        }

        /// Is heap `a` a subtype of heap `b` in the WasmGC hierarchy? The `func`
        /// and `extern` hierarchies are disjoint from the `any` family; within
        /// `any`, i31/struct/array <: eq <: any and `none` is the bottom.
        pub fn sub(a: RefHeap, b: RefHeap) bool {
            if (a == b) return true;
            return switch (a) {
                .none => b == .i31 or b == .@"struct" or b == .array or b == .eq or b == .any,
                .i31, .@"struct", .array => b == .eq or b == .any,
                .eq => b == .any,
                // Each hierarchy's bottom is below its whole hierarchy. The
                // CONCRETE types of a hierarchy are not `RefHeap` values, so
                // `validate.subtypeOf` carries that half — the two must agree on
                // which bottom belongs to which family, which is why `top()`
                // above is the single place that says so.
                .nofunc => b == .func,
                .noextern => b == .extern_,
                .noexn => b == .exn,
                else => false, // the tops have no proper supertype here
            };
        }
    };

    /// The heap type of a reference value type (asserts `isRef`). A concrete ref
    /// reads its family from the kind bits.
    pub fn refHeap(self: ValType) RefHeap {
        if (self.isConcrete()) return switch ((@intFromEnum(self) & kind_mask) >> kind_shift) {
            0 => .func,
            1 => .@"struct",
            2 => .array,
            else => unreachable,
        };
        return switch (self) {
            .funcref, .funcref_nn => .func,
            .externref, .externref_nn => .extern_,
            .anyref, .anyref_nn => .any,
            .eqref, .eqref_nn => .eq,
            .i31ref, .i31ref_nn => .i31,
            .structref, .structref_nn => .@"struct",
            .arrayref, .arrayref_nn => .array,
            .exnref, .exnref_nn => .exn,
            .nullref, .nullref_nn => .none,
            .nullfuncref, .nullfuncref_nn => .nofunc,
            .nullexternref, .nullexternref_nn => .noextern,
            .nullexnref, .nullexnref_nn => .noexn,
            else => unreachable,
        };
    }
};

/// The kind of an import or export, as encoded in the binary import/export
/// descriptor byte (§5.5.10 / §5.5.5). NOTE: this is the *binary* ordering
/// (func=0, table=1, mem=2, global=3), which differs from the wasm-c-api
/// `wasm_externkind_t` ordering — the C ABI layer maps between them.
pub const ExternKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
    tag = 0x04, // exception tag (EH proposal)
    _,
};

/// Errors that can arise while decoding a WebAssembly binary.
pub const DecodeError = error{
    /// Ran out of input before a structure was complete.
    UnexpectedEof,
    /// The leading 4 bytes were not the WebAssembly magic.
    BadMagic,
    /// The binary declares a version wazmrt does not support.
    UnsupportedVersion,
    /// A LEB128-encoded integer did not fit in its target type.
    LebOverflow,
    /// A section declared an identifier outside the defined range.
    InvalidSectionId,
    /// A non-custom section appeared twice, or out of the order §5.5.2 fixes.
    /// Custom sections are exempt: they may appear anywhere, any number of times.
    SectionOrder,
    /// A section's declared byte size did not match what its contents consumed —
    /// the payload had trailing bytes left over. §5.5.1 makes the size part of
    /// the encoding, so a mismatch is malformed even when the contents parse.
    SectionSizeMismatch,
    /// A function type did not begin with the 0x60 form byte.
    BadFuncType,
    /// A type-section entry was not a valid composite type (func/struct/array),
    /// or a GC sub type declared more than one supertype.
    BadType,
    /// An import/export descriptor used an unknown kind byte.
    UnknownExternKind,
    /// A type/function/extern index referred outside the decoded space.
    IndexOutOfRange,
    /// A single-byte flag (global mutability, limits flag) held a reserved value.
    MalformedFlag,
    /// A value-type byte was not one of the defined value types.
    BadValType,
    /// A name (import module/field, export, custom-section id) was not valid
    /// UTF-8. §5.2.4 defines a name as a UTF-8 byte vector, so this is a
    /// malformed module, not merely an odd one.
    InvalidUtf8,
    /// The data-count section disagreed with the number of data segments.
    DataCountMismatch,
    /// An instruction opcode wazmrt does not decode. The `0xFC` (saturating
    /// truncation, bulk memory, table ops), `0xFD` (the complete SIMD set),
    /// `0xFB` (GC) and `0xFE` (threads/atomics) prefixes are all implemented, as
    /// is exception handling in both encodings and memory64 (i64 addresses) —
    /// **every wasm proposal wazmrt targets is now implemented** (memory64
    /// shipped 2026-07-27, the last one).
    ///
    /// Also returned for a **raw byte in `0xD7`–`0xFA`**: those are internal `Op`
    /// tags for prefixed ops, never valid single-byte encodings (see `opcode.zig`).
    ///
    /// ⚠️ **THIS ERROR IS AMBIGUOUS ON PURPOSE and the ambiguity is scored against us.**
    /// It cannot distinguish "this byte is not a valid encoding" from "wazmrt does not implement
    /// this yet", so `wast.zig`'s `isOurLimitation` must treat it as OUR gap — which means a
    /// module we rejected *correctly* is banked as a SKIP rather than a pass. **Anything that is
    /// unambiguously bad INPUT deserves its own error rather than this one**; see `BadLaneIndex`.
    UnsupportedOpcode,
    /// A memory declared a page size that is not 1 or 65536 (custom-page-sizes). The proposal
    /// admits exactly those two — **not every power of two**, which is the trap: `(pagesize 2)`
    /// through `(pagesize 32768)` are all invalid, and a check written as "is a power of two"
    /// would accept fourteen modules the spec rejects.
    InvalidPageSize,
    /// A SIMD lane index was out of range for its instruction: `i8x16.extract_lane 16`,
    /// `i8x16.shuffle` with a byte ≥ 32, or a `v128.load/store_lane` lane past the vector's
    /// lane count.
    ///
    /// 🔑 **Split out of `UnsupportedOpcode` 2026-08-17, and the split is the whole point.** A
    /// lane index is checked against a bound wazmrt knows exactly, so "out of range" can only
    /// ever mean the MODULE is wrong — there is no reading under which it means wazmrt is
    /// incomplete. Reporting it as `UnsupportedOpcode` made ~51 correct rejections in
    /// `simd_lane.wast` and friends score as skips instead of passes.
    ///
    /// **The general rule this encodes: an error name that conflates "your input is bad" with
    /// "we are incomplete" cannot be scored correctly by ANY caller.** The distinction is known
    /// here and nowhere upstream, so it has to be made here.
    BadLaneIndex,
};
