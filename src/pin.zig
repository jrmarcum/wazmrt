//! Pin verification — the buildable slice of the authenticity design
//! (`cmem/security-model.md` §1, Phase 5 in `roadmap.md`). This file is the
//! **pure logic**: SHA-256 of the module bytes, the plaintext content-addressed
//! pin-DB format, and the enforcement mode. File I/O, the root-owned DB
//! location, env/policy resolution, and the interactive consent prompt live in
//! the CLI (`src/main.zig`) so this stays libc-free and usable from
//! `wasm32-freestanding`.
//!
//! Security model recap (do not re-derive — see `security-model.md`):
//!   - Integrity is anchored by OWNERSHIP (root-owned DB) or a signature, never
//!     by secrecy. The DB is plaintext on purpose — auditable, and a SHA-256 of
//!     a public file is not a secret.
//!   - Hash the bytes you EXECUTE: the caller hashes the in-memory buffer it is
//!     about to run, so the verified bytes and the run bytes are provably the
//!     same. Never hash by path and re-open (TOCTOU).

const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const digest_len = Sha256.digest_length; // 32
pub const hex_len = digest_len * 2; // 64
pub const Digest = [digest_len]u8;
pub const Hex = [hex_len]u8;

/// SHA-256 of exactly these bytes. Pass the in-memory module buffer you are
/// about to execute — that is what makes the check TOCTOU-safe (see file doc).
pub fn hash(bytes: []const u8) Digest {
    var d: Digest = undefined;
    Sha256.hash(bytes, &d, .{});
    return d;
}

const hex_alphabet = "0123456789abcdef";

pub fn toHex(d: Digest) Hex {
    var out: Hex = undefined;
    for (d, 0..) |b, i| {
        out[i * 2] = hex_alphabet[b >> 4];
        out[i * 2 + 1] = hex_alphabet[b & 0xf];
    }
    return out;
}

pub fn hashHex(bytes: []const u8) Hex {
    return toHex(hash(bytes));
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parse a 64-char hex digest (case-insensitive). Null unless exactly 64 hex.
pub fn parseHex(s: []const u8) ?Digest {
    if (s.len != hex_len) return null;
    var d: Digest = undefined;
    var i: usize = 0;
    while (i < digest_len) : (i += 1) {
        const hi = hexVal(s[i * 2]) orelse return null;
        const lo = hexVal(s[i * 2 + 1]) orelse return null;
        d[i] = (hi << 4) | lo;
    }
    return d;
}

/// The root-owned enforcement policy. It is the real security boundary — an
/// interactive prompt or a `--no-verify` flag is UX/convenience, never a
/// substitute for this. Default is `off` (dev) until the owner settles the
/// default-policy question (`security-model.md` "Open decisions").
pub const Mode = enum { off, warn, enforce };

pub fn modeFromStr(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "enforce")) return .enforce;
    return null;
}

/// The stricter of two modes (off < warn < enforce). Used so a dev flag can
/// only *raise* strictness above the DB-declared policy, never lower it.
pub fn stricter(a: Mode, b: Mode) Mode {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
}

/// A pin DB may declare the enforcement policy in a comment directive:
///   `# mode: enforce`
/// The mode then **inherits the DB file's ownership** — a root-owned DB is the
/// trusted policy source, and an unprivileged user can't lower it without
/// writing the root-owned file. Absent → null (caller defaults to `.off`).
pub fn modeFromDb(text: []const u8) ?Mode {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] != '#') continue;
        const body = std.mem.trim(u8, line[1..], " \t");
        const prefix = "mode:";
        if (std.mem.startsWith(u8, body, prefix))
            return modeFromStr(std.mem.trim(u8, body[prefix.len..], " \t"));
    }
    return null;
}

pub const Action = enum { run, deny, prompt };

/// The pure decision the CLI gate makes for a module that is **not**
/// signature-authenticated (that case is handled earlier and always runs).
/// Inputs: the DB's `explicit` `# mode:` (null if the DB has no directive, or
/// there is no DB); whether the module is `pinned`; whether a non-interactive
/// `opt_out` (`--no-verify`) was passed; whether stdin is a `tty`; and whether
/// verification is `armed` (a root key is embedded **or** a pin DB is present).
/// Kept pure so the whole precedence matrix is unit-testable without any I/O.
///
/// Precedence:
///   1. `pinned` → run (approved by the DB).
///   2. explicit `# mode:` (root-owned) wins when present: `off` runs all,
///      `enforce` denies **absolutely** (opt-out/tty cannot rescue — authority
///      comes from the root-owned policy, not a runtime argument), `warn`
///      prompts (tty) or denies unless opted out.
///   3. no explicit mode: if `armed`, deny an unsigned/unpinned module — but the
///      user **may** override with `--no-verify` on their own machine; if not
///      armed (bare build, no key, no DB) there is nothing to verify against, so
///      run.
pub fn decide(explicit: ?Mode, pinned: bool, opt_out: bool, tty: bool, armed: bool) Action {
    if (pinned) return .run;
    if (explicit) |m| return switch (m) {
        .off => .run,
        .enforce => .deny, // absolute: opt-out/tty ignored
        .warn => if (opt_out) .run else if (tty) .prompt else .deny,
    };
    if (!armed) return .run; // nothing to verify against
    return if (opt_out) .run else .deny; // armed default-deny, user-overridable
}

pub const ParseError = error{ InvalidPinLine, OutOfMemory };

/// A content-addressed pin database: the set of approved SHA-256 digests.
///
/// Format (plaintext, auditable): one lowercase-hex SHA-256 per line; blank
/// lines and lines beginning with `#` are ignored; any whitespace-separated
/// text after the hash is a human label and is ignored. **Content-addressed on
/// purpose** — a module approved anywhere is approved (no paths in the DB), so
/// moving/renaming an approved file does not re-open a verification hole.
pub const Db = struct {
    entries: []Digest,

    pub const empty: Db = .{ .entries = &.{} };

    pub fn deinit(self: *Db, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.entries = &.{};
    }

    pub fn contains(self: Db, d: Digest) bool {
        for (self.entries) |e| if (std.mem.eql(u8, &e, &d)) return true;
        return false;
    }

    /// A corrupted/truncated DB must fail LOUD, not silently short: a content
    /// line whose first token isn't a valid 64-hex hash is `InvalidPinLine`, so
    /// a mangled DB fails closed (caller denies) rather than silently dropping
    /// approvals and letting an unpinned module look "not in the list".
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Db {
        var list: std.ArrayList(Digest) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.tokenizeAny(u8, text, "\r\n");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const tok_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const d = parseHex(line[0..tok_end]) orelse return error.InvalidPinLine;
            try list.append(gpa, d);
        }
        return .{ .entries = try list.toOwnedSlice(gpa) };
    }
};

test "hash matches known SHA-256 vectors" {
    // NIST vectors.
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hashHex(""),
    );
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hashHex("abc"),
    );
}

test "parseHex round-trips toHex (case-insensitive)" {
    const d = hash("wazmrt");
    const hex = toHex(d);
    try std.testing.expectEqual(d, parseHex(&hex).?);
    // uppercase parses to the same digest
    var upper: Hex = hex;
    for (&upper) |*c| c.* = std.ascii.toUpper(c.*);
    try std.testing.expectEqual(d, parseHex(&upper).?);
    // wrong length / non-hex → null
    try std.testing.expectEqual(@as(?Digest, null), parseHex("abc"));
    try std.testing.expectEqual(@as(?Digest, null), parseHex("z" ** hex_len));
}

test "Db.parse: comments, labels, blanks; contains; loud on corruption" {
    const gpa = std.testing.allocator;
    const good = hashHex("module-A");
    const other = hashHex("module-B");
    // Built at runtime (the hashes are runtime values): comment, blank line, a
    // hash with leading whitespace + a label, and a bare hash.
    const text = try std.fmt.allocPrint(gpa,
        "# wazmrt pin database\n\n  {s}   examples/a.wasm\n{s}\n",
        .{ good, other },
    );
    defer gpa.free(text);
    var db = try Db.parse(gpa, text);
    defer db.deinit(gpa);
    try std.testing.expect(db.contains(hash("module-A")));
    try std.testing.expect(db.contains(hash("module-B")));
    try std.testing.expect(!db.contains(hash("module-C")));

    // A mangled content line fails closed rather than silently dropping.
    try std.testing.expectError(error.InvalidPinLine, Db.parse(gpa, "not-a-hash\n"));
    const truncated = try std.fmt.allocPrint(gpa, "{s}\n", .{good[0 .. hex_len - 1]});
    defer gpa.free(truncated);
    try std.testing.expectError(error.InvalidPinLine, Db.parse(gpa, truncated));
}

test "modeFromStr" {
    try std.testing.expectEqual(Mode.off, modeFromStr("off").?);
    try std.testing.expectEqual(Mode.warn, modeFromStr("warn").?);
    try std.testing.expectEqual(Mode.enforce, modeFromStr("enforce").?);
    try std.testing.expectEqual(@as(?Mode, null), modeFromStr("nope"));
}

test "stricter never lowers" {
    try std.testing.expectEqual(Mode.enforce, stricter(.enforce, .off));
    try std.testing.expectEqual(Mode.enforce, stricter(.off, .enforce));
    try std.testing.expectEqual(Mode.warn, stricter(.warn, .off));
    try std.testing.expectEqual(Mode.off, stricter(.off, .off));
}

test "decide: the enforcement/precedence matrix" {
    const arm = true;
    const bare = false;
    // Pinned → always run, regardless of mode / armed / anything.
    for ([_]?Mode{ null, .off, .warn, .enforce }) |m| {
        try std.testing.expectEqual(Action.run, decide(m, true, false, false, arm));
        try std.testing.expectEqual(Action.run, decide(m, true, false, false, bare));
    }

    // Explicit `# mode:` wins when present (armed value is irrelevant).
    try std.testing.expectEqual(Action.run, decide(.off, false, false, false, arm)); // operator allows all
    // enforce + unpinned → deny, and NO opt-out / TTY can rescue it (root mandate).
    try std.testing.expectEqual(Action.deny, decide(.enforce, false, false, true, arm));
    try std.testing.expectEqual(Action.deny, decide(.enforce, false, true, true, arm)); // opt-out ignored
    try std.testing.expectEqual(Action.deny, decide(.enforce, false, true, false, bare));
    // warn + unpinned: opt-out runs; else TTY prompts, non-TTY denies.
    try std.testing.expectEqual(Action.run, decide(.warn, false, true, false, arm));
    try std.testing.expectEqual(Action.prompt, decide(.warn, false, false, true, arm));
    try std.testing.expectEqual(Action.deny, decide(.warn, false, false, false, arm));

    // No explicit mode: armed → deny an unsigned/unpinned module, but --no-verify
    // (opt_out) lets the machine's owner override; a TTY does NOT prompt (deny).
    try std.testing.expectEqual(Action.deny, decide(null, false, false, false, arm));
    try std.testing.expectEqual(Action.deny, decide(null, false, false, true, arm)); // no prompt
    try std.testing.expectEqual(Action.run, decide(null, false, true, false, arm)); // --no-verify overrides
    // No explicit mode and NOT armed (bare build, no key/DB) → run everything.
    try std.testing.expectEqual(Action.run, decide(null, false, false, false, bare));
}

test "modeFromDb reads the # mode: directive, ignores other comments" {
    try std.testing.expectEqual(Mode.enforce, modeFromDb("# mode: enforce\n<hash>\n").?);
    try std.testing.expectEqual(Mode.warn, modeFromDb("#mode:warn\n").?);
    try std.testing.expectEqual(@as(?Mode, null), modeFromDb("# just a comment\ndeadbeef\n"));
    try std.testing.expectEqual(@as(?Mode, null), modeFromDb(""));
}
