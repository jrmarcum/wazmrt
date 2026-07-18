//! Authenticity — Ed25519 module signatures with an embedded root of trust.
//!
//! A signed module carries a `"signature"` **custom section** holding our magic,
//! the signer's Ed25519 public key, and a signature over *every other byte* of
//! the module. The verifier holds a trusted **root public key** compiled into
//! the binary (`embedded_root_key`); a module is *authenticated* iff the
//! section's key equals the root key **and** the signature verifies over the
//! canonical bytes. This is the "OS verifies wazmrt → wazmrt verifies every
//! module" story: an attacker may edit the wasm freely but cannot forge a
//! signature without the private root key.
//!
//! **Design decisions (owner, 2026-07-18):** trust anchor = embedded root key
//! only (rotation/keyring is a later layer); format = roll-our-own minimal
//! (no external dependency; a tool-conventions-compatible layer can come later).
//! Custom sections don't affect execution and are ignored by other runtimes, so
//! a signed module still runs everywhere — no portability cost. See
//! `cmem/security-model.md`.
//!
//! Self-validation is impossible: the signature may live inside the file, but
//! the *trust anchor* must live outside it — here, inside the verifier binary.

const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;
pub const pubkey_len = 32;
pub const sig_len = 64;

/// Section content wire format: `magic ++ algo ++ pubkey ++ signature`.
pub const magic = "wzsig1\x00"; // 7 bytes; the trailing NUL versions the format
pub const algo_ed25519: u8 = 0;
pub const section_name = "signature";
/// Length of the signature section's *content* (payload after the name).
pub const content_len = magic.len + 1 + pubkey_len + sig_len; // 7+1+32+64 = 104

/// The build-time trust anchor: the root Ed25519 public key this binary trusts.
///
/// `null` (the default) leaves signature verification **inert** — the CLI gate
/// treats every module as unsigned, so behavior is byte-identical to a build
/// with no signature support. A release build sets this to a real key whose
/// *private* half is held only by the publisher (an HSM/YubiKey/KMS — never on
/// a user's machine). Replacing it means rebuilding + re-signing wazmrt, which
/// is exactly the point: the anchor's integrity == the verifier's integrity.
pub const embedded_root_key: ?[pubkey_len]u8 = null;

/// A parsed, well-formed signature section and its byte span within the module.
pub const Located = struct {
    start: usize, // offset of the section id byte
    end: usize, // one past the section's last payload byte
    algo: u8,
    key: [pubkey_len]u8,
    sig: [sig_len]u8,
};

/// The result of scanning a module for our signature section.
pub const FindResult = union(enum) {
    none, // no `"signature"` section carrying our magic
    malformed, // our magic is present but the section is the wrong shape (tamper signal)
    found: Located,
};

/// The verdict for a module against a given root key.
pub const Verdict = enum {
    unsigned, // no trusted signature present → caller falls back (e.g. to a pin)
    authenticated, // signed by the root key and the bytes match → trusted
    foreign, // signed, but by a different key than our root → we can't vouch
    tampered, // signed by our root key (or claims our format) but bytes don't match
};

/// Read a ULEB128 `u32` at `pos.*`, advancing it. Returns null on truncation or
/// on an over-long encoding (guards against overflow on untrusted input).
fn readUleb(b: []const u8, pos: *usize) ?u32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= b.len) return null;
        const byte = b[pos.*];
        pos.* += 1;
        if (shift >= 32) return null; // 5+ bytes would overflow a u32
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

/// Append a ULEB128 encoding of `value` to `out`.
fn writeUleb(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try out.append(gpa, byte);
        if (v == 0) break;
    }
}

/// Scan a module for our `"signature"` custom section. Bounds-safe on any input:
/// a structurally broken module simply yields `.none` (the decoder rejects it
/// separately, before this ever runs on a real module).
pub fn findSignature(bytes: []const u8) FindResult {
    if (bytes.len < 8) return .none; // "\0asm" + version
    var pos: usize = 8; // skip the 8-byte module header
    while (pos < bytes.len) {
        const sec_start = pos;
        const id = bytes[pos];
        pos += 1;
        const size = readUleb(bytes, &pos) orelse return .none;
        const payload_start = pos;
        // A size that runs past the end means a malformed module → give up.
        if (size > bytes.len - payload_start) return .none;
        const payload_end = payload_start + size;
        if (id == 0) { // custom section: name_len ++ name ++ content
            var p = payload_start;
            const name_len = readUleb(bytes, &p) orelse return .none;
            if (name_len <= payload_end - p) {
                const name = bytes[p .. p + name_len];
                const content = bytes[p + name_len .. payload_end];
                if (std.mem.eql(u8, name, section_name) and
                    std.mem.startsWith(u8, content, magic))
                {
                    // It claims our format. Anything but the exact shape is a
                    // tamper signal, not a silently-ignored foreign section.
                    if (content.len != content_len) return .malformed;
                    var loc: Located = .{ .start = sec_start, .end = payload_end, .algo = content[magic.len], .key = undefined, .sig = undefined };
                    @memcpy(&loc.key, content[magic.len + 1 ..][0..pubkey_len]);
                    @memcpy(&loc.sig, content[magic.len + 1 + pubkey_len ..][0..sig_len]);
                    return .{ .found = loc };
                }
            }
        }
        pos = payload_end;
    }
    return .none;
}

/// Verify the signature over the canonical byte range (everything *except* the
/// signature section, fed in two chunks — no allocation, no copy).
fn canonicalVerify(bytes: []const u8, loc: Located) bool {
    const pk = Ed25519.PublicKey.fromBytes(loc.key) catch return false;
    const sig = Ed25519.Signature.fromBytes(loc.sig);
    var v = sig.verifier(pk) catch return false;
    v.update(bytes[0..loc.start]);
    v.update(bytes[loc.end..]);
    v.verify() catch return false;
    return true;
}

/// Classify `bytes` against `root_key`.
pub fn verify(bytes: []const u8, root_key: [pubkey_len]u8) Verdict {
    return switch (findSignature(bytes)) {
        .none => .unsigned,
        .malformed => .tampered,
        .found => |loc| blk: {
            if (loc.algo != algo_ed25519) break :blk .tampered;
            if (!std.mem.eql(u8, &loc.key, &root_key)) break :blk .foreign;
            break :blk if (canonicalVerify(bytes, loc)) .authenticated else .tampered;
        },
    };
}

/// Produce a signed module: sign `unsigned` with `kp` and append a `"signature"`
/// custom section. Caller owns the returned bytes. (The section goes last, so a
/// verifier's canonical bytes are exactly `unsigned`.) Used by tests today and a
/// future `wazmrt sign` subcommand.
pub fn signModule(gpa: std.mem.Allocator, unsigned: []const u8, kp: Ed25519.KeyPair) ![]u8 {
    const sig = kp.sign(unsigned, null) catch return error.SignFailed;

    var content: [content_len]u8 = undefined;
    @memcpy(content[0..magic.len], magic);
    content[magic.len] = algo_ed25519;
    @memcpy(content[magic.len + 1 ..][0..pubkey_len], &kp.public_key.bytes);
    @memcpy(content[magic.len + 1 + pubkey_len ..][0..sig_len], &sig.toBytes());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, unsigned);
    try out.append(gpa, 0); // custom section id
    // section size = uleb(name_len) + name + content
    const name_len: u32 = @intCast(section_name.len);
    var name_len_buf: std.ArrayList(u8) = .empty;
    defer name_len_buf.deinit(gpa);
    try writeUleb(gpa, &name_len_buf, name_len);
    const section_size: u32 = @intCast(name_len_buf.items.len + section_name.len + content.len);
    try writeUleb(gpa, &out, section_size);
    try writeUleb(gpa, &out, name_len);
    try out.appendSlice(gpa, section_name);
    try out.appendSlice(gpa, &content);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

// A minimal but valid empty module (header only). findSignature scans sections
// after the 8-byte header; signModule appends the signature section.
const empty_module = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

fn testKey(seed_byte: u8) Ed25519.KeyPair {
    const seed: [32]u8 = @splat(seed_byte);
    return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
}

test "sign then verify → authenticated" {
    const gpa = std.testing.allocator;
    const kp = testKey(1);
    const signed = try signModule(gpa, &empty_module, kp);
    defer gpa.free(signed);
    try std.testing.expectEqual(Verdict.authenticated, verify(signed, kp.public_key.bytes));
}

test "a byte flipped after signing → tampered" {
    const gpa = std.testing.allocator;
    const kp = testKey(1);
    const signed = try signModule(gpa, &empty_module, kp);
    defer gpa.free(signed);
    signed[5] ^= 0xff; // corrupt a byte inside the signed (canonical) region
    try std.testing.expectEqual(Verdict.tampered, verify(signed, kp.public_key.bytes));
}

test "signed by a different key than the root → foreign" {
    const gpa = std.testing.allocator;
    const signer = testKey(1);
    const other_root = testKey(2);
    const signed = try signModule(gpa, &empty_module, signer);
    defer gpa.free(signed);
    try std.testing.expectEqual(Verdict.foreign, verify(signed, other_root.public_key.bytes));
}

test "no signature section → unsigned" {
    const kp = testKey(1);
    try std.testing.expectEqual(Verdict.unsigned, verify(&empty_module, kp.public_key.bytes));
}

test "our magic but wrong shape → tampered (malformed)" {
    const gpa = std.testing.allocator;
    // Hand-build a custom section named "signature" whose content is our magic
    // followed by too few bytes.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &empty_module);
    const content = magic ++ [_]u8{ algo_ed25519, 0, 0 }; // magic + 3 stray bytes
    try out.append(gpa, 0);
    const section_size: u32 = @intCast(1 + section_name.len + content.len);
    try writeUleb(gpa, &out, section_size);
    try writeUleb(gpa, &out, @intCast(section_name.len));
    try out.appendSlice(gpa, section_name);
    try out.appendSlice(gpa, content);
    const kp = testKey(1);
    try std.testing.expectEqual(Verdict.tampered, verify(out.items, kp.public_key.bytes));
}

test "signs and verifies a real (non-empty) assembled module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wat = @import("wat.zig");
    const bin = try wat.assemble(a, "(module (func (export \"answer\") (result i32) (i32.const 42)))");
    const kp = testKey(7);
    const signed = try signModule(a, bin, kp);
    try std.testing.expectEqual(Verdict.authenticated, verify(signed, kp.public_key.bytes));
    // Corrupting a byte in the module body (before the appended section) is
    // caught. `bin.len` is the section's start, so `bin.len - 1` is body.
    signed[bin.len - 1] ^= 0x01;
    try std.testing.expectEqual(Verdict.tampered, verify(signed, kp.public_key.bytes));
}

test "a foreign-named custom section is ignored → unsigned" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &empty_module);
    const body = "hello"; // some other tool's custom section
    try out.append(gpa, 0);
    try writeUleb(gpa, &out, @intCast(1 + "note".len + body.len));
    try writeUleb(gpa, &out, @intCast("note".len));
    try out.appendSlice(gpa, "note");
    try out.appendSlice(gpa, body);
    const kp = testKey(1);
    try std.testing.expectEqual(Verdict.unsigned, verify(out.items, kp.public_key.bytes));
}
