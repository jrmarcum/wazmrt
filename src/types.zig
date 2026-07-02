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
};
