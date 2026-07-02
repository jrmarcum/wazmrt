//! A decoded WebAssembly module.
//!
//! Today this is the first vertical slice of the pipeline: validate the header
//! and index the top-level sections. Subsequent slices (type/function/code
//! decoding, validation, instantiation, execution) hang off this same type.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");

const Module = @This();

/// A top-level section, indexed by id and by its payload's location within the
/// original binary (zero-copy: payloads are not eagerly parsed).
pub const Section = struct {
    id: types.SectionId,
    /// Byte offset of the section payload within the source binary.
    offset: usize,
    /// Payload length in bytes.
    size: usize,
};

allocator: std.mem.Allocator,
version: u32,
sections: []Section,

pub const Error = types.DecodeError || std.mem.Allocator.Error;

/// Decode a WebAssembly binary. The returned module borrows nothing from
/// `bytes` except section extents, so `bytes` may be freed afterwards; the
/// module owns its `sections` slice and must be released with `deinit`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Module {
    var r = Reader.init(bytes);

    if (!std.mem.eql(u8, try r.readBytes(4), &types.magic)) return error.BadMagic;
    const version = try r.readU32Le();
    if (version != types.supported_version) return error.UnsupportedVersion;

    var sections: std.ArrayList(Section) = .empty;
    errdefer sections.deinit(allocator);

    while (!r.atEnd()) {
        const raw_id = try r.readByte();
        if (raw_id > types.SectionId.max) return error.InvalidSectionId;
        const size = try r.readVarU32();
        const offset = r.pos;
        _ = try r.readBytes(size); // bounds-check and skip the payload
        try sections.append(allocator, .{
            .id = @enumFromInt(raw_id),
            .offset = offset,
            .size = size,
        });
    }

    return .{
        .allocator = allocator,
        .version = version,
        .sections = try sections.toOwnedSlice(allocator),
    };
}

pub fn deinit(self: *Module) void {
    self.allocator.free(self.sections);
    self.* = undefined;
}

/// Return the first section with `id`, or null if absent.
pub fn section(self: Module, id: types.SectionId) ?Section {
    for (self.sections) |s| {
        if (s.id == id) return s;
    }
    return null;
}

test "decodes an empty module (header only)" {
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 1), m.version);
    try std.testing.expectEqual(@as(usize, 0), m.sections.len);
}

test "indexes a single custom section" {
    // header + custom section (id 0), payload size 1, one payload byte
    const bytes = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x00, 0x01, 0x2a };
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
