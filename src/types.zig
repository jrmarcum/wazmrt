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
    _,

    /// Highest identifier defined by the current spec.
    pub const max: u8 = 12;
};

/// WebAssembly value types (§5.3.1), encoded by their binary opcode byte.
/// Non-exhaustive: an unrecognized byte decodes rather than crashing; a later
/// validation pass rejects it.
pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    funcref = 0x70,
    externref = 0x6f,
    _,
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
    /// An import/export descriptor used an unknown kind byte.
    UnknownExternKind,
    /// A type/function/extern index referred outside the decoded space.
    IndexOutOfRange,
};
