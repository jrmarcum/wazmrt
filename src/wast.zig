//! WAST script runner — executes the spec test format (`.wast`).
//!
//! A `.wast` file is a sequence of commands: module definitions plus assertions
//! (`assert_return`, `assert_trap`, …) and actions (`invoke`). This runner is
//! pure orchestration over the finished pipeline: parse (`sexpr`) → assemble
//! (`wat`) or decode a binary module → `validate` → instantiate (`interp`) →
//! run actions → compare results. It counts pass/fail so it can gate against the
//! official testsuite.
//!
//! **Scope today (MVP):** `(module …)` (text) and `(module binary …)`,
//! `assert_return (invoke …) …`, `assert_trap (invoke …) …`, bare `(invoke …)`,
//! and value literals (`i32`/`i64`/`f32`/`f64` incl. `nan:canonical` /
//! `nan:arithmetic`). Deferred: `assert_invalid`/`assert_malformed`, `register`
//! + multi-module linking, `get` actions, `(module quote …)`.

const std = @import("std");
const sexpr = @import("sexpr.zig");
const wat = @import("wat.zig");
const types = @import("types.zig");
const Module = @import("Module.zig");
const interp = @import("interp.zig");
const validate = @import("validate.zig").validate;

const V = types.ValType;
const Value = interp.Value;
const Sexpr = sexpr.Sexpr;

pub const Error = sexpr.Error || error{ BadCommand, BadValue } || std.mem.Allocator.Error;

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    /// Commands the MVP does not handle yet (assert_invalid, register, …).
    skipped: usize = 0,
    /// Description of the first failure, for debugging.
    first_failure: ?[]const u8 = null,
};

/// Parse and run a whole `.wast` source, returning pass/fail counts.
pub fn runScript(gpa: std.mem.Allocator, src: []const u8) Error!Summary {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var r: Runner = .{ .a = arena.allocator() };
    for (try sexpr.parseAll(r.a, src)) |cmd| try r.command(cmd);
    return r.summary;
}

const Runner = struct {
    a: std.mem.Allocator,
    current: ?interp.Instance = null,
    summary: Summary = .{},

    fn fail(self: *Runner, comptime fmt: []const u8, args: anytype) void {
        self.summary.failed += 1;
        if (self.summary.first_failure == null)
            self.summary.first_failure = std.fmt.allocPrint(self.a, fmt, args) catch "out of memory";
    }

    fn command(self: *Runner, cmd: Sexpr) Error!void {
        const kw = cmd.keyword() orelse return error.BadCommand;
        if (std.mem.eql(u8, kw, "module")) {
            self.current = self.buildModule(cmd.asList().?) catch |e| {
                self.current = null;
                self.fail("module failed to build: {s}", .{@errorName(e)});
                return;
            };
        } else if (std.mem.eql(u8, kw, "assert_return")) {
            try self.assertReturn(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_trap")) {
            try self.assertTrap(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "invoke")) {
            _ = self.runAction(cmd) catch |e| self.fail("invoke trapped: {s}", .{@errorName(e)});
        } else {
            self.summary.skipped += 1; // assert_invalid/malformed, register, get, …
        }
    }

    fn buildModule(self: *Runner, form: []const Sexpr) !interp.Instance {
        const bin = try self.moduleBinary(form);
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try validate(self.a, m);
        return interp.Instance.init(self.a, m);
    }

    fn moduleBinary(self: *Runner, form: []const Sexpr) ![]const u8 {
        var i: usize = 1;
        if (i < form.len and isId(form[i])) i += 1; // optional $name
        if (i < form.len) {
            if (form[i].asAtom()) |kw| {
                if (std.mem.eql(u8, kw, "binary")) {
                    var bytes: std.ArrayList(u8) = .empty;
                    for (form[i + 1 ..]) |it| switch (it) {
                        .string => |s| try bytes.appendSlice(self.a, s),
                        else => {},
                    };
                    return bytes.items;
                }
                return error.BadCommand; // (module quote …) not supported yet
            }
        }
        return wat.assembleModule(self.a, form);
    }

    /// Run an action; today only `(invoke "name" args…)`.
    fn runAction(self: *Runner, action: Sexpr) ![]Value {
        const list = action.asList() orelse return error.BadCommand;
        if (!std.mem.eql(u8, list[0].asAtom() orelse "", "invoke")) return error.BadCommand;
        const name = list[1].string;
        const args = try self.a.alloc(Value, list.len - 2);
        for (list[2..], args) |arg, *dst| dst.* = try parseConst(arg);
        if (self.current == null) return error.BadCommand;
        return self.current.?.invoke(name, args);
    }

    fn assertReturn(self: *Runner, form: []const Sexpr) Error!void {
        if (self.current == null) {
            self.summary.skipped += 1; // module didn't build; can't run this assertion
            return;
        }
        const results = self.runAction(form[1]) catch |e| {
            self.fail("assert_return: unexpected trap {s}", .{@errorName(e)});
            return;
        };
        const expected = form[2..];
        if (results.len != expected.len) {
            self.fail("assert_return: arity {d} != expected {d}", .{ results.len, expected.len });
            return;
        }
        for (results, expected) |got, exp_form| {
            if (!try matches(got, exp_form)) {
                self.fail("assert_return: result mismatch (got 0x{x})", .{got});
                return;
            }
        }
        self.summary.passed += 1;
    }

    fn assertTrap(self: *Runner, form: []const Sexpr) Error!void {
        if (self.current == null) {
            self.summary.skipped += 1;
            return;
        }
        if (self.runAction(form[1])) |_| {
            self.fail("assert_trap: expected a trap, got a result", .{});
        } else |_| {
            self.summary.passed += 1; // any error counts as the expected trap
        }
    }
};

// --- Value literals & comparison -------------------------------------------

/// Null reference sentinel — must match `interp`'s `null_ref` on the value stack.
const null_ref: Value = std.math.maxInt(u64);

/// Parse a concrete value literal (for invoke arguments): `(TYPE.const literal)`
/// or a reference literal (`(ref.null …)`, `(ref.extern N)`, `(ref.func N)`).
fn parseConst(form: Sexpr) Error!Value {
    const list = form.asList() orelse return error.BadValue;
    const kw = list[0].asAtom() orelse return error.BadValue;
    // Reference literals: `ref.null` carries an ignorable heaptype; `ref.extern`
    // / `ref.func` carry an integer payload (the func index / host value).
    if (std.mem.eql(u8, kw, "ref.null")) return null_ref;
    if (std.mem.eql(u8, kw, "ref.extern") or std.mem.eql(u8, kw, "ref.func")) {
        if (list.len < 2) return null_ref; // bare `(ref.func)` — any non-null; use 0 sentinel
        return @intCast(try parseInt(list[1].asAtom() orelse return error.BadValue));
    }
    const lit = list[1].asAtom() orelse return error.BadValue;
    if (std.mem.eql(u8, kw, "i32.const")) return interp.i32Value(@truncate(try parseInt(lit)));
    if (std.mem.eql(u8, kw, "i64.const")) return interp.i64Value(try parseInt(lit));
    if (std.mem.eql(u8, kw, "f32.const")) return @as(u32, try parseFloatBits(f32, lit));
    if (std.mem.eql(u8, kw, "f64.const")) return try parseFloatBits(f64, lit);
    return error.BadValue;
}

/// Does an actual result value match an expected `(TYPE.const …)` form? Handles
/// the `nan:canonical` / `nan:arithmetic` matchers for floats.
fn matches(got: Value, exp_form: Sexpr) Error!bool {
    const list = exp_form.asList() orelse return error.BadValue;
    const kw = list[0].asAtom() orelse return error.BadValue;
    // Reference matchers: `(ref.null …)` ⇒ null; a bare `(ref.func)` / `(ref.extern)`
    // ⇒ any non-null; with a payload ⇒ exact.
    if (std.mem.eql(u8, kw, "ref.null")) return got == null_ref;
    if (std.mem.eql(u8, kw, "ref.func") or std.mem.eql(u8, kw, "ref.extern")) {
        if (list.len < 2) return got != null_ref;
        return got == @as(Value, @intCast(try parseInt(list[1].asAtom() orelse return error.BadValue)));
    }
    const lit = list[1].asAtom() orelse return error.BadValue;
    if (std.mem.eql(u8, kw, "f32.const")) return floatMatches(f32, got, lit);
    if (std.mem.eql(u8, kw, "f64.const")) return floatMatches(f64, got, lit);
    // Integers: exact bit comparison.
    return got == try parseConst(exp_form);
}

fn floatMatches(comptime F: type, got: Value, lit: []const u8) Error!bool {
    if (std.mem.eql(u8, lit, "nan:canonical")) return isCanonicalNan(F, got);
    if (std.mem.eql(u8, lit, "nan:arithmetic")) return isArithmeticNan(F, got);
    const U = if (F == f32) u32 else u64;
    return @as(U, @truncate(got)) == try parseFloatBits(F, lit);
}

fn parseInt(lit: []const u8) Error!i64 {
    return std.fmt.parseInt(i64, lit, 0) catch {
        const u = std.fmt.parseInt(u64, lit, 0) catch return error.BadValue;
        return @bitCast(u);
    };
}

/// Parse a float literal to its bit pattern, including wasm NaN forms.
fn parseFloatBits(comptime F: type, lit: []const u8) Error!UInt(F) {
    const U = UInt(F);
    if (std.mem.startsWith(u8, lit, "nan") or std.mem.startsWith(u8, lit, "+nan") or std.mem.startsWith(u8, lit, "-nan")) {
        var bits: U = canonicalNanBits(F);
        if (lit[0] == '-') bits |= signBit(F);
        // nan:0x<payload>
        if (std.mem.indexOfScalar(u8, lit, ':')) |c| {
            if (!std.mem.eql(u8, lit[c + 1 ..], "canonical") and !std.mem.eql(u8, lit[c + 1 ..], "arithmetic")) {
                const payload = std.fmt.parseInt(U, lit[c + 1 ..], 0) catch return error.BadValue;
                bits = (bits & ~mantissaMask(F)) | (payload & mantissaMask(F));
            }
        }
        return bits;
    }
    const f = std.fmt.parseFloat(F, lit) catch return error.BadValue;
    return @bitCast(f);
}

// Bit-layout helpers, generic over f32/f64.
fn expBits(comptime F: type) comptime_int {
    return if (F == f32) 8 else 11;
}
fn mantBits(comptime F: type) comptime_int {
    return if (F == f32) 23 else 52;
}
fn UInt(comptime F: type) type {
    return if (F == f32) u32 else u64;
}
fn expMask(comptime F: type) UInt(F) {
    return @as(UInt(F), (1 << expBits(F)) - 1) << mantBits(F);
}
fn mantissaMask(comptime F: type) UInt(F) {
    return (@as(UInt(F), 1) << mantBits(F)) - 1;
}
fn signBit(comptime F: type) UInt(F) {
    return @as(UInt(F), 1) << (expBits(F) + mantBits(F));
}
fn canonicalNanBits(comptime F: type) UInt(F) {
    return expMask(F) | (@as(UInt(F), 1) << (mantBits(F) - 1)); // exp all ones + top mantissa bit
}

fn isCanonicalNan(comptime F: type, got: Value) bool {
    const bits: UInt(F) = @truncate(got);
    return (bits & expMask(F)) == expMask(F) and (bits & mantissaMask(F)) == (@as(UInt(F), 1) << (mantBits(F) - 1));
}
fn isArithmeticNan(comptime F: type, got: Value) bool {
    const bits: UInt(F) = @truncate(got);
    const quiet = @as(UInt(F), 1) << (mantBits(F) - 1);
    return (bits & expMask(F)) == expMask(F) and (bits & quiet) != 0;
}

fn isId(s: Sexpr) bool {
    const atom = s.asAtom() orelse return false;
    return atom.len != 0 and atom[0] == '$';
}

// --- Tests -----------------------------------------------------------------

test "runs assert_return and assert_trap over a module" {
    const src =
        \\(module
        \\  (func (export "add") (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1)))
        \\  (func (export "div") (param i32 i32) (result i32) (i32.div_s (local.get 0) (local.get 1))))
        \\(assert_return (invoke "add" (i32.const 10) (i32.const 20)) (i32.const 30))
        \\(assert_return (invoke "add" (i32.const -5) (i32.const 3)) (i32.const -2))
        \\(assert_return (invoke "div" (i32.const 9) (i32.const 3)) (i32.const 3))
        \\(assert_trap (invoke "div" (i32.const 1) (i32.const 0)) "integer divide by zero")
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "detects a wrong expected result" {
    const src =
        \\(module (func (export "one") (result i32) (i32.const 1)))
        \\(assert_return (invoke "one") (i32.const 2))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 0), s.passed);
    try std.testing.expectEqual(@as(usize, 1), s.failed);
}

test "float results incl. nan:canonical" {
    const src =
        \\(module
        \\  (func (export "fadd") (param f64 f64) (result f64) (f64.add (local.get 0) (local.get 1)))
        \\  (func (export "fnan") (result f64) (f64.div (f64.const 0) (f64.const 0))))
        \\(assert_return (invoke "fadd" (f64.const 1.5) (f64.const 2.25)) (f64.const 3.75))
        \\(assert_return (invoke "fnan") (f64.const nan:canonical))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "runs a (module binary …) command" {
    // magic + version + a func: (result i32) i32.const 7
    const src =
        \\(module binary
        \\  "\00asm\01\00\00\00"
        \\  "\01\05\01\60\00\01\7f"          ;; type: () -> i32
        \\  "\03\02\01\00"                    ;; func 0 : type 0
        \\  "\07\07\01\03\73\65\76\00\00"     ;; export "sev" func 0
        \\  "\0a\06\01\04\00\41\07\0b")       ;; code: i32.const 7 end
        \\(assert_return (invoke "sev") (i32.const 7))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}
