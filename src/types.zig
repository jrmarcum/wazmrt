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
    nullref = 0x71, // (ref null none) — bottom of the `any` hierarchy
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
    _,

    // --- Concrete typed-reference encoding (high bits of the u32) -------------
    const concrete_bit: u32 = 0x8000_0000;
    const nullable_bit: u32 = 0x4000_0000;
    const kind_shift: u5 = 28;
    const kind_mask: u32 = 0x3 << kind_shift;
    const index_mask: u32 = 0x0fff_ffff; // 28 bits — up to ~268M types

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
        const k: u32 = switch (kind) {
            .func => 0,
            .@"struct" => 1,
            .array => 2,
            else => unreachable,
        };
        return @enumFromInt(concrete_bit |
            (if (is_nullable) nullable_bit else 0) |
            (k << kind_shift) |
            (ti & index_mask));
    }

    /// True if this is a concrete typed reference (carries a type index).
    pub fn isConcrete(self: ValType) bool {
        return @intFromEnum(self) & concrete_bit != 0;
    }

    /// The type index of a concrete reference (asserts `isConcrete`).
    pub fn concreteIndex(self: ValType) u32 {
        return @intFromEnum(self) & index_mask;
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
            .funcref_nn, .externref_nn, .anyref_nn, .eqref_nn, .i31ref_nn, .structref_nn, .arrayref_nn, .exnref_nn, .nullref_nn => true,
            else => false,
        };
    }

    /// True for a non-nullable reference (a non-defaultable local type).
    pub fn isNonNullRef(self: ValType) bool {
        if (self.isConcrete()) return @intFromEnum(self) & nullable_bit == 0;
        return switch (self) {
            .funcref_nn, .externref_nn, .anyref_nn, .eqref_nn, .i31ref_nn, .structref_nn, .arrayref_nn, .exnref_nn, .nullref_nn => true,
            else => false,
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
            };
        }

        /// The top of this head's hierarchy: `any` for the internal GC family,
        /// else `func` / `extern`.
        pub fn top(self: RefHeap) RefHeap {
            return switch (self) {
                .func => .func,
                .extern_ => .extern_,
                .exn => .exn,
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
                else => false, // func/extern/any have no proper supertype here
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
    /// The data-count section disagreed with the number of data segments.
    DataCountMismatch,
    /// An instruction opcode wazmrt does not decode. The `0xFC` (saturating
    /// truncation, bulk memory, table ops), `0xFD` (the complete SIMD set) and
    /// `0xFB` (GC) prefixes are all implemented, as is exception handling in both
    /// encodings — **only threads/atomics remain** (corrected 2026-07-21; this
    /// doc still listed SIMD and EH as gaps long after both shipped).
    ///
    /// Also returned for a **raw byte in `0xD7`–`0xFA`**: those are internal `Op`
    /// tags for prefixed ops, never valid single-byte encodings (see `opcode.zig`).
    UnsupportedOpcode,
};
