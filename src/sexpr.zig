//! S-expression lexer + parser for the WebAssembly text format (`.wat`) and the
//! spec script format (`.wast`). This is the shared front-end for the WAT
//! assembler (`wat.zig`, text → wasm binary) and the WAST script runner
//! (`wast.zig`, assertions).
//!
//! It tokenizes and parses into a tree of `Sexpr` nodes: atoms (keywords,
//! `$identifiers`, numbers, `key=value`), strings (decoded to their byte
//! values, so `(module binary "\00asm…")` yields real bytes), and lists. Line
//! comments (`;; …`) and nestable block comments (`(; … ;)`) are skipped.

const std = @import("std");

pub const Sexpr = union(enum) {
    /// A keyword (`module`, `i32.add`), identifier (`$x`), number, or
    /// `key=value` token — kept as raw source text for the assembler to parse.
    atom: []const u8,
    /// A string literal, decoded to its byte values (escapes resolved).
    string: []const u8,
    list: []const Sexpr,

    /// For a list, the leading atom (its "keyword"), else null.
    pub fn keyword(self: Sexpr) ?[]const u8 {
        return switch (self) {
            .list => |items| if (items.len > 0) switch (items[0]) {
                .atom => |a| a,
                else => null,
            } else null,
            else => null,
        };
    }

    pub fn asAtom(self: Sexpr) ?[]const u8 {
        return switch (self) {
            .atom => |a| a,
            else => null,
        };
    }

    pub fn asList(self: Sexpr) ?[]const Sexpr {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }
};

pub const Error = error{
    UnexpectedEof,
    UnexpectedParen,
    UnterminatedString,
    UnterminatedList,
    BadEscape,
} || std.mem.Allocator.Error;

/// Parse an entire source into its sequence of top-level forms. Everything is
/// allocated from `a` (typically an arena).
pub fn parseAll(a: std.mem.Allocator, src: []const u8) Error![]const Sexpr {
    var p: Parser = .{ .src = src, .a = a };
    var forms: std.ArrayList(Sexpr) = .empty;
    p.skipTrivia();
    while (p.pos < src.len) {
        try forms.append(a, try p.parseValue());
        p.skipTrivia();
    }
    return forms.toOwnedSlice(a);
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    a: std.mem.Allocator,

    fn skipTrivia(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == ';' and self.peek(1) == ';') {
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else if (c == '(' and self.peek(1) == ';') {
                self.pos += 2;
                var depth: usize = 1;
                while (self.pos < self.src.len and depth > 0) {
                    if (self.src[self.pos] == '(' and self.peek(1) == ';') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.src[self.pos] == ';' and self.peek(1) == ')') {
                        depth -= 1;
                        self.pos += 2;
                    } else self.pos += 1;
                }
            } else break;
        }
    }

    fn peek(self: *Parser, ahead: usize) u8 {
        const i = self.pos + ahead;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn parseValue(self: *Parser) Error!Sexpr {
        self.skipTrivia();
        if (self.pos >= self.src.len) return error.UnexpectedEof;
        return switch (self.src[self.pos]) {
            '(' => self.parseList(),
            ')' => error.UnexpectedParen,
            '"' => .{ .string = try self.parseString() },
            else => .{ .atom = self.parseAtom() },
        };
    }

    fn parseList(self: *Parser) Error!Sexpr {
        self.pos += 1; // consume '('
        var items: std.ArrayList(Sexpr) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.pos >= self.src.len) return error.UnterminatedList;
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            try items.append(self.a, try self.parseValue());
        }
        return .{ .list = try items.toOwnedSlice(self.a) };
    }

    fn parseAtom(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n', '(', ')', ';', '"' => break,
                else => self.pos += 1,
            }
        }
        return self.src[start..self.pos];
    }

    fn parseString(self: *Parser) Error![]const u8 {
        self.pos += 1; // consume opening quote
        var buf: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '"') return buf.toOwnedSlice(self.a);
            if (c != '\\') {
                try buf.append(self.a, c);
                continue;
            }
            if (self.pos >= self.src.len) return error.BadEscape;
            const e = self.src[self.pos];
            self.pos += 1;
            switch (e) {
                't' => try buf.append(self.a, '\t'),
                'n' => try buf.append(self.a, '\n'),
                'r' => try buf.append(self.a, '\r'),
                '"' => try buf.append(self.a, '"'),
                '\'' => try buf.append(self.a, '\''),
                '\\' => try buf.append(self.a, '\\'),
                'u' => try self.parseUnicodeEscape(&buf),
                else => { // \XX hex byte
                    const hi = hexVal(e) orelse return error.BadEscape;
                    const lo = hexVal(if (self.pos < self.src.len) self.src[self.pos] else 0) orelse return error.BadEscape;
                    self.pos += 1;
                    try buf.append(self.a, hi * 16 + lo);
                },
            }
        }
        return error.UnterminatedString;
    }

    fn parseUnicodeEscape(self: *Parser, buf: *std.ArrayList(u8)) Error!void {
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return error.BadEscape;
        self.pos += 1;
        var cp: u32 = 0;
        while (self.pos < self.src.len and self.src[self.pos] != '}') {
            cp = cp *% 16 + (hexVal(self.src[self.pos]) orelse return error.BadEscape);
            self.pos += 1;
        }
        if (self.pos >= self.src.len) return error.BadEscape;
        self.pos += 1; // consume '}'
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(std.math.cast(u21, cp) orelse return error.BadEscape, &utf8) catch return error.BadEscape;
        try buf.appendSlice(self.a, utf8[0..n]);
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// --- Tests -----------------------------------------------------------------

test "parses a nested module form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const forms = try parseAll(arena.allocator(),
        \\(module
        \\  (func (export "add") (param $x i32) (result i32)
        \\    (i32.add (local.get $x) (i32.const 1))))
    );
    try std.testing.expectEqual(@as(usize, 1), forms.len);
    try std.testing.expectEqualStrings("module", forms[0].keyword().?);
    const module = forms[0].asList().?;
    // module -> [ "module", (func ...) ]
    try std.testing.expectEqualStrings("func", module[1].keyword().?);
    const func = module[1].asList().?;
    try std.testing.expectEqualStrings("export", func[1].keyword().?);
    try std.testing.expectEqualStrings("add", func[1].asList().?[1].string);
}

test "skips line and block comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const forms = try parseAll(arena.allocator(),
        \\;; a leading line comment
        \\(a (; nested (; block ;) comment ;) b) ;; trailing
    );
    try std.testing.expectEqual(@as(usize, 1), forms.len);
    const list = forms[0].asList().?;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0].atom);
    try std.testing.expectEqualStrings("b", list[1].atom);
}

test "decodes string escapes to bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const forms = try parseAll(arena.allocator(),
        \\(module binary "\00asm\01\00\00\00")
    );
    const list = forms[0].asList().?;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 'a', 's', 'm', 0x01, 0x00, 0x00, 0x00 }, list[2].string);
}

test "reports an unterminated list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedList, parseAll(arena.allocator(), "(module (func"));
}
