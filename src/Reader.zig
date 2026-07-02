//! A zero-copy cursor over a WebAssembly binary. Bounds-checked reads and
//! LEB128 decoding, with no allocation — the fast, small core the rest of the
//! decoder builds on.

const std = @import("std");
const types = @import("types.zig");

const Reader = @This();

bytes: []const u8,
pos: usize = 0,

pub fn init(bytes: []const u8) Reader {
    return .{ .bytes = bytes };
}

pub fn remaining(self: Reader) usize {
    return self.bytes.len - self.pos;
}

pub fn atEnd(self: Reader) bool {
    return self.pos >= self.bytes.len;
}

pub fn readByte(self: *Reader) types.DecodeError!u8 {
    if (self.pos >= self.bytes.len) return error.UnexpectedEof;
    defer self.pos += 1;
    return self.bytes[self.pos];
}

/// Borrow `n` bytes from the current position without copying.
pub fn readBytes(self: *Reader, n: usize) types.DecodeError![]const u8 {
    if (self.remaining() < n) return error.UnexpectedEof;
    const slice = self.bytes[self.pos .. self.pos + n];
    self.pos += n;
    return slice;
}

/// Read a fixed 32-bit little-endian integer (used for the format version).
pub fn readU32Le(self: *Reader) types.DecodeError!u32 {
    const b = try self.readBytes(4);
    return std.mem.readInt(u32, b[0..4], .little);
}

/// Read an unsigned LEB128 integer into a u32 (§5.2.2).
pub fn readVarU32(self: *Reader) types.DecodeError!u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (true) {
        const byte = try self.readByte();
        if (shift >= 32) return error.LebOverflow;
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

test "readVarU32 decodes multi-byte values" {
    var r = Reader.init(&[_]u8{ 0xE5, 0x8E, 0x26 }); // 624485
    try std.testing.expectEqual(@as(u32, 624485), try r.readVarU32());
    try std.testing.expect(r.atEnd());
}

test "readBytes past end reports UnexpectedEof" {
    var r = Reader.init(&[_]u8{ 0x00, 0x01 });
    try std.testing.expectError(error.UnexpectedEof, r.readBytes(4));
}
