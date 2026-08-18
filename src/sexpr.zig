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
    /// List nesting exceeded `max_depth` — refuses a `((((…`-bomb that would
    /// otherwise overflow the host stack via `parseList`/`parseValue` recursion.
    NestingTooDeep,
    /// A character that starts no value and that `skipTrivia` does not consume —
    /// today only a lone `;` (`;;` line comments and `(;` block comments are
    /// trivia; a single `;` is not valid `.wat`).
    UnexpectedChar,
    /// §6.2.1's `reserved ::= (idchar | string)+` — a string abutting an idchar
    /// or another string with no separator. Tokens are lexed longest-match, so
    /// `(data"a")` is `(`, the single reserved token `data"a"`, `)`; **no
    /// grammar production accepts `reserved`**, which is why it is rejected here
    /// rather than passed on. Splitting it into `data` + `"a"` — what this lexer
    /// used to do — silently assembles a module the spec calls malformed.
    ReservedToken,
    /// `id ::= '$' idchar+ | '$' string` — a `$` with nothing after it, or with
    /// an empty `$""`. `(func $)` is the spec's own example.
    EmptyIdentifier,
    /// A quoted identifier whose bytes are not valid UTF-8. Plain strings may
    /// hold arbitrary bytes (`(data "\ef")` is fine); an identifier may not.
    BadIdentifier,
    /// §6.2.1 `stringchar` — a RAW character below U+20, or U+7F, inside a
    /// string literal. The escapes `\t` / `\n` / `\r` are how those bytes are
    /// written; a literal tab or newline between the quotes is malformed.
    BadStringChar,
    /// `(@` with no identifier: `(@)`, `(@ )`, `(@ x)`, `(@"")`, `(@(@a)x)`.
    ///
    /// 🔑 **The id must follow `@` with NO separator** — `annotid ::= '@' idchar+ | '@' string`.
    /// A space makes the id empty rather than making the next token the id, which is why
    /// `(@ x)` is malformed and not an annotation named `x`.
    EmptyAnnotationId,
    /// End of input inside an annotation — `(@x `, `(@x ()`, `(@x (y (z))`.
    UnclosedAnnotation,
    /// A raw control byte inside an annotation's contents. §6.2.1 limits source text to
    /// printable characters plus tab/newline/carriage-return, and `annotations.wast` spends
    /// **32 of its 64** malformed assertions on exactly this.
    ///
    /// ⚠️ **Enforced INSIDE ANNOTATIONS ONLY, deliberately.** The same rule holds for source
    /// text at large, and wazmrt does not check it there — `parseAtom` consumes any byte that
    /// is not a delimiter. Widening it is a separate change with a real blast radius (every
    /// `.wat` input in existence goes through that loop), so it is recorded as an observation
    /// rather than smuggled in behind an annotations feature. See `roadmap.md` Track A.
    IllegalCharacter,
} || std.mem.Allocator.Error;

/// Cap on `(`-nesting. Real `.wat`/`.wast` nests a few dozen deep at most; this
/// is a stack-overflow guard against adversarial input, not a real limit.
const max_depth: usize = 1024;

/// Parse an entire source into its sequence of top-level forms. Everything is
/// allocated from `a` (typically an arena).
pub fn parseAll(a: std.mem.Allocator, src: []const u8) Error![]const Sexpr {
    return (try parseAllWithLines(a, src, null));
}

/// As `parseAll`, but also records the 1-based source LINE each top-level form
/// starts on into `lines` (same length and order as the returned forms).
///
/// The `.wast` runner needs this: a failure message that names only its error
/// ("result mismatch") cannot be matched back to an assertion in a 1,000-line
/// script, and triaging 35 failures across five files by re-deriving which
/// assertion each one was is exactly the hand work that mislabelled three of
/// five items on the 2026-08-11 list. Only top-level forms are tracked — that is
/// the granularity a `.wast` command has.
pub fn parseAllWithLines(
    a: std.mem.Allocator,
    src: []const u8,
    lines: ?*std.ArrayList(u32),
) Error![]const Sexpr {
    var p: Parser = .{ .src = src, .a = a };
    var forms: std.ArrayList(Sexpr) = .empty;
    // Walked forward with `pos` rather than recounting from 0 each form, so a
    // 40k-line script stays linear overall instead of quadratic.
    var line: u32 = 1;
    var counted: usize = 0;
    p.skipTrivia();
    while (p.pos < src.len) {
        // A TOP-LEVEL annotation is dropped too — `.wast` scripts may carry them between
        // commands, and a form that produces no value must not consume a `lines` entry either,
        // or every later command's reported line number is off by one.
        if (p.atAnnotation()) {
            try p.skipAnnotation();
            p.skipTrivia();
            continue;
        }
        if (lines) |l| {
            while (counted < p.pos) : (counted += 1) {
                if (src[counted] == '\n') line += 1;
            }
            try l.append(a, line);
        }
        try forms.append(a, try p.parseValue());
        p.skipTrivia();
    }
    return forms.toOwnedSlice(a);
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    a: std.mem.Allocator,
    depth: usize = 0,

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
            // A lone `;`: `skipTrivia` consumes only `;;` and `(;`, and
            // `parseAtom` treats `;` as a terminator — so it would return an
            // empty atom WITHOUT advancing `pos`, and the `parseAll`/`parseList`
            // loops would append empty atoms forever. `(module) ; x` — 12 bytes —
            // hung the CLI at 10 GB RSS. Reject it instead.
            ';' => error.UnexpectedChar,
            '"' => blk: {
                const s = try self.parseString();
                // A string followed with no separator by an idchar or another
                // string is one `reserved` token, not two tokens.
                if (self.startsReservedTail()) break :blk error.ReservedToken;
                break :blk .{ .string = s };
            },
            else => blk: {
                const at = self.parseAtom();
                // Belt-and-braces: no delimiter added to `parseAtom` in future
                // may reintroduce a zero-progress loop.
                if (at.len == 0) break :blk error.UnexpectedChar;
                // `parseAtom` stops at `"`, so an atom abutting a string would
                // otherwise be handed on as two tokens — the `(data"a")` case.
                if (self.pos < self.src.len and self.src[self.pos] == '"') {
                    // …with one exception: `id ::= '$' idchar+ | '$' string`, so
                    // a lone `$` followed by a string is the QUOTED IDENTIFIER
                    // form, one token, not a reserved one.
                    if (at.len == 1 and at[0] == '$') break :blk .{ .atom = try self.parseQuotedId() };
                    break :blk error.ReservedToken;
                }
                if (at.len == 1 and at[0] == '$') break :blk error.EmptyIdentifier;
                break :blk .{ .atom = at };
            },
        };
    }

    /// **custom-annotations.** `(@id …)` is a syntactic element a conforming implementation
    /// IGNORES — it carries no semantics, so the whole of "implementing" the proposal is lexing
    /// one and throwing it away.
    ///
    /// 🔑 **THE TRIGGER IS `(` IMMEDIATELY FOLLOWED BY `@`, and the immediacy is a rule rather
    /// than an optimisation.** `( @a)` — with a space — is NOT an annotation: it is an ordinary
    /// list whose first token is the atom `@a`, and `annotations.wast` asserts it malformed as
    /// "unknown operator" (which is `wat.zig`'s verdict, not the lexer's). Testing `peek(1)`
    /// rather than skipping trivia first is what keeps those two apart.
    fn atAnnotation(self: *Parser) bool {
        return self.src[self.pos] == '(' and self.peek(1) == '@';
    }

    /// Consume `(@id …)` entirely. The contents are OPAQUE — reserved tokens, stray `;`, `]`,
    /// `}`, unbalanced-looking text are all just characters — but four rules survive inside, and
    /// the corpus spends its 64 malformed assertions pinning exactly which:
    ///
    ///   1. **Parens still balance** (4 assertions, "unclosed annotation").
    ///   2. **Strings are still strings** (2, "unclosed string") — so a `)` inside `"…"` does
    ///      not close anything, which `(@a ")" "(" x")"y)` relies on.
    ///   3. **Comments still nest** — `(@a (;bla;) (; ) ;)` spans lines and closes later.
    ///   4. **The character class still applies** (32 assertions, over HALF the file).
    ///
    /// ⚠️ **Rule 4 is the one an implementation that "skips to the matching paren" would drop**,
    /// and it is the single largest group in the file. Tab, newline and carriage return are
    /// explicitly ALLOWED; every other control byte and `0x7f` are not.
    fn skipAnnotation(self: *Parser) Error!void {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return error.NestingTooDeep;
        self.pos += 2; // `(@`

        // `annotid ::= '@' idchar+ | '@' string` — NO separator, and non-empty.
        if (self.pos >= self.src.len) return error.UnclosedAnnotation;
        if (self.src[self.pos] == '"') {
            const s = try self.parseString();
            if (s.len == 0) return error.EmptyAnnotationId;
            // An annotation id is an IDENTIFIER, so it carries the identifier UTF-8 rule rather
            // than the permissive string one — `(@"\ef")` is malformed.
            if (!std.unicode.utf8ValidateSlice(s)) return error.BadIdentifier;
        } else {
            const start = self.pos;
            while (self.pos < self.src.len and isIdChar(self.src[self.pos])) self.pos += 1;
            if (self.pos == start) return error.EmptyAnnotationId;
        }
        return self.skipAnnotationBody();
    }

    /// The opaque remainder, up to and including the matching `)`. Shared by the annotation
    /// itself and by any nested paren group inside it — a nested `(@y …)` needs no special case
    /// here, because at this depth an annotation and a plain group are both just balanced text.
    fn skipAnnotationBody(self: *Parser) Error!void {
        while (true) {
            self.skipTrivia(); // whitespace, `;;` line comments and nested `(; … ;)` blocks
            if (self.pos >= self.src.len) return error.UnclosedAnnotation;
            switch (self.src[self.pos]) {
                ')' => {
                    self.pos += 1;
                    return;
                },
                '(' => {
                    self.depth += 1;
                    defer self.depth -= 1;
                    if (self.depth > max_depth) return error.NestingTooDeep;
                    self.pos += 1;
                    try self.skipAnnotationBody();
                },
                // A string is still a string: its bytes are consumed by the string rules, so a
                // `)` or `(` inside one cannot affect the balance.
                '"' => _ = try self.parseString(),
                else => {
                    // Any other character is discarded, but the class is still enforced.
                    //
                    // 🔑 **PRINTABLE ASCII ONLY (0x20–0x7E), plus tab/newline/carriage-return.**
                    // Not "idchars" — `(@a , ; ] [ }} }x{ ({) ,{{};}] ;)` is a VALID annotation
                    // and none of `,[]{}` is an idchar. And not "any UTF-8" either: the corpus
                    // asserts `(@a Heiße Würstchen)` and an emoji annotation MALFORMED even
                    // though both are well-formed Unicode, alongside every bare `\80`–`\ff`
                    // byte. ⚠️ **Three plausible rules — idchars, non-control, valid UTF-8 —
                    // each pass most of the file and fail a different corner of it.** Only the
                    // ASCII-printable reading satisfies all 64 assertions.
                    const c = self.src[self.pos];
                    if (c < 0x20 or c > 0x7e) {
                        if (c != '\t' and c != '\n' and c != '\r') return error.IllegalCharacter;
                    }
                    self.pos += 1;
                },
            }
        }
    }

    fn parseList(self: *Parser) Error!Sexpr {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return error.NestingTooDeep;
        self.pos += 1; // consume '('
        var items: std.ArrayList(Sexpr) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.pos >= self.src.len) return error.UnterminatedList;
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            // Annotations may appear anywhere a token may, and are DROPPED here so neither
            // `wat.zig` nor `wast.zig` ever learns they exist. Doing it at this layer is what
            // makes `((@a)@b)` behave: the annotation vanishes and the remaining `@b` is an
            // ordinary atom the assembler rejects as an unknown operator, which is the verdict
            // the corpus asks for.
            if (self.atAnnotation()) {
                try self.skipAnnotation();
                continue;
            }
            try items.append(self.a, try self.parseValue());
        }
        return .{ .list = try items.toOwnedSlice(self.a) };
    }

    /// `$"…"` — the quoted form of an identifier. Returns it NORMALISED to the
    /// bare spelling (`$` ++ the decoded bytes), which is what makes
    /// `(br $"007")` resolve against `block $007`: the two spellings become one
    /// atom, so every downstream name lookup compares them without knowing the
    /// form exists.
    fn parseQuotedId(self: *Parser) Error![]const u8 {
        const s = try self.parseString();
        if (s.len == 0) return error.EmptyIdentifier;
        if (!std.unicode.utf8ValidateSlice(s)) return error.BadIdentifier;
        if (self.startsReservedTail()) return error.ReservedToken; // `$"a"x`
        const buf = try self.a.alloc(u8, s.len + 1);
        buf[0] = '$';
        @memcpy(buf[1..], s);
        return buf;
    }

    /// True if the character at `pos` would continue a `reserved` token that a
    /// string just started — i.e. an `idchar` or the opening quote of a second
    /// string. Called only immediately after a closing `"`.
    fn startsReservedTail(self: *Parser) bool {
        if (self.pos >= self.src.len) return false;
        const c = self.src[self.pos];
        return c == '"' or isIdChar(c);
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
                // §6.2.1 `stringchar ::= c:char (if c ≥ U+20 ∧ c ≠ U+7F ∧ …)`.
                // A raw control byte is malformed; `\t`/`\n`/`\r` below are how
                // those bytes are spelled. This is what separates the legal
                // `(func $"\t")` from the malformed `(func $"a<TAB>b")` — the
                // difference is the escape, not the resulting byte.
                if (c < 0x20 or c == 0x7f) return error.BadStringChar;
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
            const d = hexVal(self.src[self.pos]) orelse return error.BadEscape;
            // Overflow-checked, not wrapping: `\u{100000041}` must be rejected, not
            // silently truncated mod 2^32 to a valid scalar (here `'A'`).
            cp = std.math.mul(u32, cp, 16) catch return error.BadEscape;
            cp = std.math.add(u32, cp, d) catch return error.BadEscape;
            self.pos += 1;
        }
        if (self.pos >= self.src.len) return error.BadEscape;
        self.pos += 1; // consume '}'
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(std.math.cast(u21, cp) orelse return error.BadEscape, &utf8) catch return error.BadEscape;
        try buf.appendSlice(self.a, utf8[0..n]);
    }
};

/// §6.2.1 `idchar`. Note it includes `'` and `\` but NOT `"`, `;`, `,`, `[`,
/// `]`, `{`, `}` or whitespace. Used only to decide where a `reserved` token
/// continues; `parseAtom` keeps its own (wider, more permissive) terminator set,
/// so tightening this cannot reject an atom that used to assemble.
fn isIdChar(c: u8) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '/' => true,
        ':', '<', '=', '>', '?', '@', '\\', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

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

test "rejects a string abutting another token (reserved)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §6.2.1 `reserved ::= (idchar | string)+`. Each of these lexes as ONE
    // reserved token, which no production accepts.
    for ([_][]const u8{
        "(data\"a\")", // keyword then string
        "(data $l\"a\")", // id then string
        "(data \"a\"\"b\")", // string then string
        "(data \"\"\"\")", // two empty strings, still no separator
        "(func \"a\"x)", // string then idchar
    }) |src| {
        try std.testing.expectError(error.ReservedToken, parseAll(a, src));
    }
    // …and the separated forms all stay legal.
    for ([_][]const u8{
        "(data \"a\")",
        "(data $l \"a\")",
        "(data \"a\" \"b\")",
        "(export \"a\"(func 0))", // `(` is not an idchar — no separator needed
    }) |src| {
        _ = try parseAll(a, src);
    }
}

test "lexes quoted identifiers to the bare spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `$"…"` normalises to `$` ++ decoded, so both spellings are ONE atom and
    // `(br $"007")` finds `block $007` with no name-lookup change anywhere.
    const forms = try parseAll(a, "($\"007\" $\"\\41B\" $\"\\u{41}\\u{42}\" $\"\\t\")");
    const l = forms[0].asList().?;
    try std.testing.expectEqualStrings("$007", l[0].atom);
    try std.testing.expectEqualStrings("$AB", l[1].atom);
    try std.testing.expectEqualStrings("$AB", l[2].atom);
    try std.testing.expectEqualStrings("$\t", l[3].atom); // escaped tab: legal
    try std.testing.expectError(error.EmptyIdentifier, parseAll(a, "(func $)"));
    try std.testing.expectError(error.EmptyIdentifier, parseAll(a, "(func $\"\")"));
    try std.testing.expectError(error.EmptyIdentifier, parseAll(a, "(func $ \"a\")"));
    try std.testing.expectError(error.BadIdentifier, parseAll(a, "(func $\"\\ef\")"));
    try std.testing.expectError(error.ReservedToken, parseAll(a, "(func $\"a\"x)"));
    // A RAW control byte in any string is malformed — the escape is the only
    // legal spelling. `$"a<TAB>b"` differs from `$"\t"` in exactly this.
    try std.testing.expectError(error.BadStringChar, parseAll(a, "(func $\"a\tb\")"));
    try std.testing.expectError(error.BadStringChar, parseAll(a, "(func $\"a\nb\")"));
    try std.testing.expectError(error.BadStringChar, parseAll(a, "(data \"a\x7fb\")"));
}

test "reports an unterminated list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedList, parseAll(arena.allocator(), "(module (func"));
}

test "custom-annotations: `(@id …)` is lexed and DISCARDED" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The annotation vanishes: the list holds only the real tokens.
    {
        const forms = try parseAll(a, "(module (@a x y z) (func))");
        const items = forms[0].asList().?;
        try std.testing.expectEqual(@as(usize, 2), items.len); // `module`, `(func)`
        try std.testing.expectEqualStrings("module", items[0].atom);
        try std.testing.expectEqualStrings("func", items[1].asList().?[0].atom);
    }
    // A TOP-LEVEL annotation is dropped without consuming a form slot — a `.wast` script may
    // carry them between commands, and a phantom form would shift every later line number.
    {
        const forms = try parseAll(a, "(@a) (module) (@b x) (module)");
        try std.testing.expectEqual(@as(usize, 2), forms.len);
    }
    // Contents are OPAQUE: reserved tokens, stray brackets and semicolons are just characters.
    // Each of these is a VALID annotation in `annotations.wast`.
    for ([_][]const u8{
        "(module (@a , ; ] [ }} }x{ ({) ,{{};}] ;))",
        "(module (@a (bla) () (5-g) (\"aa\" a) ($x) (bla bla) (x (y)) \")\" \"(\" x\")\"y))",
        "(module (@a @ @x (@x) (@x y) (@) (@ x) (@(@(@(@))))))",
        "(module (@\"a\") (@\"quoted id\"))",
        "(module (@a 0x 8q 0xfa #4g0-.@f#^&@#$*0sf -- @#))",
    }) |src| {
        _ = parseAll(a, src) catch |e| {
            std.debug.print("rejected a valid annotation: {s} -> {s}\n", .{ src, @errorName(e) });
            return e;
        };
    }
    // 🔑 A `)` INSIDE A STRING does not close the annotation, and a `(` inside one does not open
    // anything — without the string rule surviving, the first case below eats the module's paren.
    _ = try parseAll(a, "(module (@a \")\"))");
    // ...and comments still nest, across lines.
    _ = try parseAll(a,
        \\(module (@a (;bla;) (; ) ;)
        \\  ;; bla)
        \\  ;; bla (@x
        \\))
    );
}

test "custom-annotations: the four rules that SURVIVE inside an annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (1) The id must follow `@` with NO separator and be non-empty.
    for ([_][]const u8{ "(@)", "(@ )", "(@ x)", "(@(@a)x)", "(@\"\")", "(@ \"a\")" }) |src| {
        std.testing.expectError(error.EmptyAnnotationId, parseAll(a, src)) catch |e| {
            std.debug.print("id rule missed: {s}\n", .{src});
            return e;
        };
    }
    // ⚠️ `( @a)` — one space — is NOT an annotation at all. It is a list holding the atom `@a`,
    // which the ASSEMBLER rejects as an unknown operator. Testing `peek(1)` rather than skipping
    // trivia first is the whole of that distinction.
    {
        const forms = try parseAll(a, "( @a)");
        try std.testing.expectEqualStrings("@a", forms[0].asList().?[0].atom);
    }
    // (2) Parens must still balance.
    for ([_][]const u8{ "(@x ", "(@x ()", "(@x (y (z))", "(@x (@y )" }) |src| {
        try std.testing.expectError(error.UnclosedAnnotation, parseAll(a, src));
    }
    // (3) Strings must still terminate.
    try std.testing.expectError(error.UnterminatedString, parseAll(a, "(@x \")"));
    // (4) The character class: printable ASCII plus tab/nl/cr, and NOTHING else.
    //     ⚠️ Not "non-control" and not "valid UTF-8" — both of those readings pass most of the
    //     corpus and fail a different corner. `ß` and an emoji are well-formed Unicode and are
    //     asserted MALFORMED; every bare 0x80–0xff byte likewise.
    for ([_][]const u8{
        "(@a \x00)", "(@a \x08)", "(@a \x0b)", "(@a \x1f)", "(@a \x7f)",
        "(@a \x80)",  "(@a \xff)", "(@a Hei\xc3\x9fe)", // the last is valid UTF-8 and still illegal
    }) |src| {
        std.testing.expectError(error.IllegalCharacter, parseAll(a, src)) catch |e| {
            std.debug.print("char rule missed: {any}\n", .{src});
            return e;
        };
    }
    // ...and the three whitespace characters that ARE allowed, plus a plain space.
    for ([_][]const u8{ "(@a \x09)", "(@a \x0a)", "(@a \x0d)", "(@a \x20)" }) |src| {
        _ = try parseAll(a, src);
    }
    // An annotation id given as a string carries the IDENTIFIER utf-8 rule, not the permissive
    // string one.
    try std.testing.expectError(error.BadIdentifier, parseAll(a, "(@\"\xef\")"));
}

test "custom-annotations did NOT relax the lexer outside annotations (regression)" {
    // 🔒 **THE BLAST-RADIUS TEST.** `sexpr.zig` is the foundation of both `wat.zig` and
    // `wast.zig`, so a lexer change is on every text input there is. These are the rules a
    // relaxed lexer would silently reopen, and the first one is not hypothetical: a lone `;`
    // once made `parseAtom` return an empty atom WITHOUT advancing `pos`, and `(module) ; x` —
    // twelve bytes — hung the CLI at 10.4 GB RSS.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.UnexpectedChar, parseAll(a, "(module) ; x"));
    try std.testing.expectError(error.ReservedToken, parseAll(a, "(func $\"a\"x)"));
    try std.testing.expectError(error.ReservedToken, parseAll(a, "(data\"a\")"));
    try std.testing.expectError(error.EmptyIdentifier, parseAll(a, "(func $)"));
    try std.testing.expectError(error.BadStringChar, parseAll(a, "(func $\"a\tb\")"));
    // ⚠️ And the character class is NOT enforced outside an annotation — that is a deliberate
    // scope limit, not an oversight. Widening it would touch every `.wat` in existence; it is
    // recorded in `Error.IllegalCharacter` and in roadmap Track A as a separate decision.
    _ = try parseAll(a, "(module \x01)");
}
