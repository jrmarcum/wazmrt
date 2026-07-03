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

/// Read a signed LEB128 integer into an i32 (§5.2.2).
pub fn readVarI32(self: *Reader) types.DecodeError!i32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    var byte: u8 = undefined;
    while (true) {
        if (shift >= 32) return error.LebOverflow;
        byte = try self.readByte();
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        shift += 7;
        if (byte & 0x80 == 0) break;
    }
    if (shift < 32 and (byte & 0x40) != 0) result |= ~@as(u32, 0) << @intCast(shift);
    return @bitCast(result);
}

/// Read a signed LEB128 integer into an i64 (§5.2.2).
pub fn readVarI64(self: *Reader) types.DecodeError!i64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    var byte: u8 = undefined;
    while (true) {
        if (shift >= 64) return error.LebOverflow;
        byte = try self.readByte();
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        shift += 7;
        if (byte & 0x80 == 0) break;
    }
    if (shift < 64 and (byte & 0x40) != 0) result |= ~@as(u64, 0) << @intCast(shift);
    return @bitCast(result);
}

/// Read a fixed 32-bit little-endian float bit pattern (for `f32.const`).
pub fn readF32Bits(self: *Reader) types.DecodeError!u32 {
    const b = try self.readBytes(4);
    return std.mem.readInt(u32, b[0..4], .little);
}

/// Read a fixed 64-bit little-endian float bit pattern (for `f64.const`).
pub fn readF64Bits(self: *Reader) types.DecodeError!u64 {
    const b = try self.readBytes(8);
    return std.mem.readInt(u64, b[0..8], .little);
}

test "readVarI32 decodes negative values" {
    var r = Reader.init(&[_]u8{0x7f}); // -1
    try std.testing.expectEqual(@as(i32, -1), try r.readVarI32());
    var r2 = Reader.init(&[_]u8{ 0x80, 0x7f }); // -128
    try std.testing.expectEqual(@as(i32, -128), try r2.readVarI32());
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
