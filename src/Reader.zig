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

/// Read an unsigned LEB128 integer into a u32 (§5.2.2). Rejects over-long
/// encodings and values that don't fit in 32 bits (`LebOverflow`).
pub fn readVarU32(self: *Reader) types.DecodeError!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = try self.readByte();
        if (shift == 28) {
            // 5th byte: only 4 value bits fit, and there must be no 6th byte.
            if (byte >> 4 != 0) return error.LebOverflow;
            return result | (@as(u32, byte) << 28);
        }
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
    }
}

/// Read a signed LEB128 integer into an i32 (§5.2.2). Rejects over-long
/// encodings and values that don't sign-fit in 32 bits.
pub fn readVarI32(self: *Reader) types.DecodeError!i32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = try self.readByte();
        if (shift == 28) {
            // 5th byte: bits 4..6 must sign-extend bit 3 (value bit 31), no 6th byte.
            if (byte & 0x80 != 0) return error.LebOverflow;
            const hi = byte & 0x78;
            if (hi != 0 and hi != 0x78) return error.LebOverflow;
            return @bitCast(result | (@as(u32, byte & 0x7f) << 28));
        }
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if ((byte & 0x40) != 0) result |= ~@as(u32, 0) << (shift + 7); // sign-extend
            return @bitCast(result);
        }
        shift += 7;
    }
}

/// Read a signed LEB128 integer into an i64 (§5.2.2). Rejects over-long
/// encodings and values that don't sign-fit in 64 bits.
pub fn readVarI64(self: *Reader) types.DecodeError!i64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = try self.readByte();
        if (shift == 63) {
            // 10th byte: only bit 63 fits; bits 1..6 must sign-extend it, no 11th byte.
            if (byte & 0x80 != 0) return error.LebOverflow;
            const v = byte & 0x7f;
            if (v != 0x00 and v != 0x7f) return error.LebOverflow;
            return @bitCast(result | (@as(u64, byte & 0x01) << 63));
        }
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if ((byte & 0x40) != 0) result |= ~@as(u64, 0) << (shift + 7); // sign-extend
            return @bitCast(result);
        }
        shift += 7;
    }
}

/// Skip a LEB128-encoded integer, consuming bytes until the continuation bit
/// clears. `max_bytes` bounds the encoding length (5 for a 32-bit LEB, 10 for a
/// 64-bit LEB) so an over-long encoding is rejected as malformed, not spun on.
pub fn skipLeb(self: *Reader, max_bytes: usize) types.DecodeError!void {
    var n: usize = 0;
    while (true) {
        const byte = try self.readByte();
        n += 1;
        if (byte & 0x80 == 0) break;
        if (n >= max_bytes) return error.LebOverflow;
    }
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

test "readVarU32 accepts valid 5-byte, rejects over-long / too-large" {
    var ok = Reader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f }); // 0xFFFFFFFF
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try ok.readVarU32());
    var pad = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x00 }); // 0, padded to 5 bytes
    try std.testing.expectEqual(@as(u32, 0), try pad.readVarU32());
    var toolong = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }); // 6 bytes
    try std.testing.expectError(error.LebOverflow, toolong.readVarU32());
    var toobig = Reader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x1f }); // 5th byte > 0x0f
    try std.testing.expectError(error.LebOverflow, toobig.readVarU32());
}

test "readVarI64 accepts valid 10-byte, rejects over-long / too-large" {
    var zero = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try std.testing.expectEqual(@as(i64, 0), try zero.readVarI64()); // 10-byte 0
    var neg = Reader.init(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f });
    try std.testing.expectEqual(@as(i64, -1), try neg.readVarI64()); // 10-byte -1
    var toolong = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try std.testing.expectError(error.LebOverflow, toolong.readVarI64()); // 11 bytes
    var toobig = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40 });
    try std.testing.expectError(error.LebOverflow, toobig.readVarI64()); // 10th byte not sign-consistent
}
