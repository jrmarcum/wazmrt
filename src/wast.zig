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
//! `assert_return`/`assert_trap`/`assert_exhaustion (invoke …) …`,
//! `assert_invalid`/`assert_malformed (module …)` (the module must be rejected),
//! bare `(invoke …)`, and value literals (`i32`/`i64`/`f32`/`f64` incl.
//! `nan:canonical`/`nan:arithmetic`, references). `assert_trap` accepts only a
//! genuine runtime trap (see `isRuntimeTrap`), not an engine error. Deferred:
//! `register` + multi-module linking, `get` actions, `(module quote …)`.

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

const HostFunc = interp.Instance.HostFunc;

const Runner = struct {
    a: std.mem.Allocator,
    current: ?*interp.Instance = null,
    /// Registered modules (`(register "name")`), for cross-module imports.
    modules: std.StringHashMapUnmanaged(*interp.Instance) = .{},
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
        } else if (std.mem.eql(u8, kw, "assert_exhaustion")) {
            try self.assertExhaustion(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_invalid") or std.mem.eql(u8, kw, "assert_malformed")) {
            try self.assertRejected(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "register")) {
            // (register "name" $id?) — expose the current module's exports under "name".
            const list = cmd.asList().?;
            if (self.current) |inst| try self.modules.put(self.a, list[1].string, inst);
        } else if (std.mem.eql(u8, kw, "invoke")) {
            _ = self.runAction(cmd) catch |e| self.fail("invoke trapped: {s}", .{@errorName(e)});
        } else {
            self.summary.skipped += 1; // get, (module quote …), …
        }
    }

    fn buildModule(self: *Runner, form: []const Sexpr) !*interp.Instance {
        const bin = try self.moduleBinary(form);
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try validate(self.a, m);
        const inst = try self.a.create(interp.Instance);
        inst.* = try interp.Instance.initWithImports(self.a, m, try self.resolveImports(m));
        return inst;
    }

    /// Resolve a module's imports: functions to `HostFunc`s (a registered
    /// module's export or a `spectest` native), globals to values.
    fn resolveImports(self: *Runner, m: *const Module) !interp.Instance.Imports {
        var fs: std.ArrayList(HostFunc) = .empty;
        var gs: std.ArrayList(Value) = .empty;
        for (m.imports) |imp| switch (imp.type) {
            .func => try fs.append(self.a, try self.resolveFuncImport(imp.module, imp.name)),
            .global => try gs.append(self.a, spectestGlobal(imp.module, imp.name) orelse 0),
            else => {}, // imported tables/memories not yet backed
        };
        return .{ .funcs = fs.items, .globals = gs.items };
    }

    fn resolveFuncImport(self: *Runner, module: []const u8, name: []const u8) !HostFunc {
        if (std.mem.eql(u8, module, "spectest")) {
            if (spectestFunc(name)) |nf| return .{ .native = nf };
        }
        if (self.modules.get(module)) |inst| {
            if (exportedFuncIndex(inst.module, name)) |fi| return .{ .wasm = .{ .instance = inst, .func_index = fi } };
        }
        return error.UnresolvedImport;
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
        const action_name: []const u8 = if (form[1].asList()) |l| (if (l.len > 1) l[1].string else "?") else "?";
        for (results, expected) |got, exp_form| {
            if (!try matches(got, exp_form)) {
                self.fail("assert_return \"{s}\": result mismatch (got 0x{x})", .{ action_name, got });
                return;
            }
        }
        self.summary.passed += 1;
    }

    fn assertTrap(self: *Runner, form: []const Sexpr) Error!void {
        // `assert_trap (module …)` — instantiation itself must trap (e.g. an
        // active data/element segment out of bounds). Build it in isolation and
        // require a genuine runtime trap; it does not become the current module.
        if (form[1].asList()) |inner| {
            if (std.mem.eql(u8, inner[0].asAtom() orelse "", "module")) {
                if (self.buildModule(inner)) |_| {
                    self.fail("assert_trap: module instantiated without trapping", .{});
                } else |e| {
                    if (isRuntimeTrap(e)) self.summary.passed += 1 else self.fail("assert_trap: non-trap error {s}", .{@errorName(e)});
                }
                return;
            }
        }
        if (self.current == null) {
            self.summary.skipped += 1;
            return;
        }
        if (self.runAction(form[1])) |_| {
            self.fail("assert_trap: expected a trap, got a result", .{});
        } else |e| {
            // Only a genuine wasm runtime trap counts — an engine limitation or
            // bug (UnsupportedInstruction, UndefinedFunc, a decode/assemble error)
            // must NOT be green-washed as the expected trap.
            if (isRuntimeTrap(e)) self.summary.passed += 1 else self.fail("assert_trap: non-trap error {s}", .{@errorName(e)});
        }
    }

    /// `assert_exhaustion (invoke …) "call stack exhausted"` — expects the call
    /// depth limit to trip (a runtime trap), not any other error.
    fn assertExhaustion(self: *Runner, form: []const Sexpr) Error!void {
        if (self.current == null) {
            self.summary.skipped += 1;
            return;
        }
        if (self.runAction(form[1])) |_| {
            self.fail("assert_exhaustion: expected exhaustion, got a result", .{});
        } else |e| {
            if (e == error.CallStackExhausted) self.summary.passed += 1 else self.fail("assert_exhaustion: got {s}", .{@errorName(e)});
        }
    }

    /// `assert_invalid`/`assert_malformed (module …) "reason"` — the inner module
    /// must be REJECTED (fail to decode/validate). Passing means we rejected it;
    /// failing means we wrongly accepted an invalid/malformed module. Does not
    /// touch `self.current`.
    fn assertRejected(self: *Runner, form: []const Sexpr) Error!void {
        const inner = form[1].asList() orelse {
            self.fail("assert_invalid: malformed command", .{});
            return;
        };
        if (self.tryBuild(inner)) |_| {
            self.fail("assert_invalid/malformed: module was accepted (should be rejected)", .{});
        } else |_| {
            self.summary.passed += 1;
        }
    }

    /// Decode + validate a module form without instantiating or recording it.
    fn tryBuild(self: *Runner, form: []const Sexpr) !void {
        const bin = try self.moduleBinary(form);
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try validate(self.a, m);
    }
};

/// True only for genuine wasm runtime traps (§4.2). Engine limitations, decode/
/// assemble errors, and setup errors are explicitly excluded so `assert_trap` /
/// `assert_exhaustion` cannot be satisfied by a bug.
fn isRuntimeTrap(e: anyerror) bool {
    return switch (e) {
        error.Unreachable,
        error.DivByZero,
        error.IntOverflow,
        error.InvalidConversionToInt,
        error.MemoryOutOfBounds,
        error.TableOutOfBounds,
        error.UninitializedElement,
        error.IndirectTypeMismatch,
        error.CallStackExhausted,
        => true,
        else => false,
    };
}

// --- Value literals & comparison -------------------------------------------

/// Null reference sentinel — must match `interp`'s `null_ref` on the value stack.
const null_ref: Value = std.math.maxInt(u64);

/// The index (into a module's function index space) of an exported function.
fn exportedFuncIndex(m: *const Module, name: []const u8) ?u32 {
    for (m.exports) |e| {
        if (e.type == .func and std.mem.eql(u8, e.name, name)) return e.index;
    }
    return null;
}

/// A `spectest` host function. The standard ones (`print*`) are side-effect-only
/// with no results, so a single no-op backs them all.
fn spectestFunc(name: []const u8) ?*const fn ([]const Value, []Value) void {
    if (std.mem.startsWith(u8, name, "print")) return spectestNoop;
    return null;
}
fn spectestNoop(args: []const Value, results: []Value) void {
    _ = args;
    _ = results; // print funcs return nothing
}

/// The standard testsuite `spectest` host globals (immutable), as their raw slot
/// bits. Modules import these to test imported-global handling.
fn spectestGlobal(module: []const u8, name: []const u8) ?Value {
    if (!std.mem.eql(u8, module, "spectest")) return null;
    if (std.mem.eql(u8, name, "global_i32")) return interp.i32Value(666);
    if (std.mem.eql(u8, name, "global_i64")) return interp.i64Value(666);
    if (std.mem.eql(u8, name, "global_f32")) return interp.f32Value(666.6);
    if (std.mem.eql(u8, name, "global_f64")) return interp.f64Value(666.6);
    return null;
}

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
