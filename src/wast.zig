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
    /// Modules by their textual `$name` (`(module $M …)`), for `(invoke $M …)`,
    /// `(get $M …)`, and `(register "x" $M)`.
    module_names: std.StringHashMapUnmanaged(*interp.Instance) = .{},
    /// The standard `spectest` shared memory (1 page, max 2) and table (10
    /// funcref, max 20), created lazily and shared by every importer.
    spectest_memory: ?*interp.Instance.Memory = null,
    spectest_table: ?*interp.Instance.Table = null,
    /// Interned host externref payloads. A `(ref.extern N)` value is represented
    /// on the value stack as its *index* here (a small integer, never the
    /// `null_ref` = maxInt sentinel), so an externref of any payload — including
    /// one equal to the sentinel — is never misclassified as null (#9).
    extern_pool: std.ArrayList(u64) = .empty,
    summary: Summary = .{},

    fn fail(self: *Runner, comptime fmt: []const u8, args: anytype) void {
        self.summary.failed += 1;
        if (self.summary.first_failure == null)
            self.summary.first_failure = std.fmt.allocPrint(self.a, fmt, args) catch "out of memory";
    }

    fn command(self: *Runner, cmd: Sexpr) Error!void {
        const kw = cmd.keyword() orelse return error.BadCommand;
        if (std.mem.eql(u8, kw, "module")) {
            const list = cmd.asList().?;
            self.current = self.buildModule(list) catch |e| {
                self.current = null;
                self.fail("module failed to build: {s}", .{@errorName(e)});
                return;
            };
            // Track by textual `$name` (`(module $M …)`) for later `$M` references.
            if (self.current) |inst| if (list.len > 1 and isId(list[1]))
                try self.module_names.put(self.a, list[1].atom, inst);
        } else if (std.mem.eql(u8, kw, "assert_return")) {
            try self.assertReturn(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_trap")) {
            try self.assertTrap(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_exhaustion")) {
            try self.assertExhaustion(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_invalid") or std.mem.eql(u8, kw, "assert_malformed")) {
            try self.assertRejected(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_unlinkable")) {
            try self.assertUnlinkable(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "register")) {
            // (register "name" $id?) — expose a module's exports under "name":
            // the `$id`-named module if given, else the current module.
            const list = cmd.asList().?;
            const target = if (list.len > 2 and isId(list[2])) self.module_names.get(list[2].atom) else self.current;
            if (target) |inst| try self.modules.put(self.a, list[1].string, inst);
        } else if (std.mem.eql(u8, kw, "invoke") or std.mem.eql(u8, kw, "get")) {
            _ = self.runAction(cmd) catch |e| self.fail("action failed: {s}", .{@errorName(e)});
        } else {
            self.summary.skipped += 1; // (module quote …), assert_exception, …
        }
    }

    fn buildModule(self: *Runner, form: []const Sexpr) !*interp.Instance {
        const bin = try self.moduleBinary(form);
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try validate(self.a, m);
        const inst = try self.a.create(interp.Instance);
        inst.* = try interp.Instance.initWithImports(self.a, m, try self.resolveImports(m));
        try inst.runStart(); // §4.5.5 — a trap here means instantiation failed
        return inst;
    }

    /// Resolve and *link* a module's imports: each is matched to a registered
    /// module's export or a `spectest` stub, and its declared type is checked
    /// against the provider's actual type. An unknown name → `UnresolvedImport`,
    /// a type mismatch → `IncompatibleImportType` (both = "unlinkable").
    fn resolveImports(self: *Runner, m: *const Module) !interp.Instance.Imports {
        var fs: std.ArrayList(HostFunc) = .empty;
        var gs: std.ArrayList(Value) = .empty;
        var ms: std.ArrayList(*interp.Instance.Memory) = .empty;
        var ts: std.ArrayList(*interp.Instance.Table) = .empty;
        for (m.imports) |imp| switch (imp.type) {
            .func => |want| try fs.append(self.a, try self.resolveFuncImport(imp.module, imp.name, want)),
            .global => |want| try gs.append(self.a, try self.resolveGlobalImport(imp.module, imp.name, want)),
            .memory => |want| try ms.append(self.a, try self.resolveMemoryImport(imp.module, imp.name, want)),
            .table => |want| try ts.append(self.a, try self.resolveTableImport(imp.module, imp.name, want)),
            // An imported tag needs no host backing — it is just a local tag
            // identity in this module's tag index space (EH proposal).
            .tag => {},
        };
        return .{ .funcs = fs.items, .globals = gs.items, .memories = ms.items, .tables = ts.items };
    }

    fn resolveFuncImport(self: *Runner, module: []const u8, name: []const u8, want: Module.FuncType) !HostFunc {
        if (std.mem.eql(u8, module, "spectest")) {
            const got = spectestFuncType(name) orelse return error.UnresolvedImport;
            if (!funcTypeEq(got, want)) return error.IncompatibleImportType;
            return .{ .native = spectestNoop };
        }
        if (self.modules.get(module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .func and std.mem.eql(u8, e.name, name)) {
                    if (!funcTypeEq(e.type.func, want)) return error.IncompatibleImportType;
                    return .{ .wasm = .{ .instance = inst, .func_index = e.index } };
                }
            }
        }
        return error.UnresolvedImport;
    }

    fn resolveGlobalImport(self: *Runner, module: []const u8, name: []const u8, want: Module.GlobalType) !Value {
        if (std.mem.eql(u8, module, "spectest")) {
            const gt = spectestGlobalType(name) orelse return error.UnresolvedImport;
            if (gt.content != want.content or gt.mutable != want.mutable) return error.IncompatibleImportType;
            return spectestGlobal(module, name).?;
        }
        if (self.modules.get(module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .global and std.mem.eql(u8, e.name, name)) {
                    const gt = e.type.global;
                    if (gt.content != want.content or gt.mutable != want.mutable) return error.IncompatibleImportType;
                    return inst.globals[e.index];
                }
            }
        }
        return error.UnresolvedImport;
    }

    fn resolveMemoryImport(self: *Runner, module: []const u8, name: []const u8, want: Module.MemoryType) !*interp.Instance.Memory {
        if (std.mem.eql(u8, module, "spectest") and std.mem.eql(u8, name, "memory")) {
            if (!limitsFit(.{ .min = 1, .max = 2 }, want.limits)) return error.IncompatibleImportType;
            return self.spectestMemory();
        }
        if (self.modules.get(module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .memory and std.mem.eql(u8, e.name, name)) {
                    if (!limitsFit(e.type.memory.limits, want.limits)) return error.IncompatibleImportType;
                    return inst.memory orelse error.UnresolvedImport;
                }
            }
        }
        return error.UnresolvedImport;
    }

    fn resolveTableImport(self: *Runner, module: []const u8, name: []const u8, want: Module.TableType) !*interp.Instance.Table {
        if (std.mem.eql(u8, module, "spectest") and std.mem.eql(u8, name, "table")) {
            if (want.element != .funcref or !limitsFit(.{ .min = 10, .max = 20 }, want.limits)) return error.IncompatibleImportType;
            return self.spectestTable();
        }
        if (self.modules.get(module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .table and std.mem.eql(u8, e.name, name)) {
                    const tt = e.type.table;
                    if (tt.element != want.element or !limitsFit(tt.limits, want.limits)) return error.IncompatibleImportType;
                    if (e.index < inst.tables.len) return inst.tables[e.index];
                }
            }
        }
        return error.UnresolvedImport;
    }

    /// The shared `spectest` memory / table, allocated on first use (from the
    /// runner arena, so they outlive every instance that borrows them).
    fn spectestMemory(self: *Runner) !*interp.Instance.Memory {
        if (self.spectest_memory) |m| return m;
        const buf = try self.a.alloc(u8, interp.page_size); // 1 page
        @memset(buf, 0);
        const m = try self.a.create(interp.Instance.Memory);
        m.* = .{ .bytes = buf, .max = 2 };
        self.spectest_memory = m;
        return m;
    }

    fn spectestTable(self: *Runner) !*interp.Instance.Table {
        if (self.spectest_table) |t| return t;
        const entries = try self.a.alloc(Value, 10); // 10 funcref
        @memset(entries, null_ref);
        const t = try self.a.create(interp.Instance.Table);
        t.* = .{ .entries = entries, .max = 20 };
        self.spectest_table = t;
        return t;
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

    /// Run an action: `(invoke $M? "name" args…)` or `(get $M? "name")`. A leading
    /// `$M` targets that named module, else the current one; `error.NoTarget` if
    /// the target is unavailable (so assertions skip rather than spuriously fail).
    fn runAction(self: *Runner, action: Sexpr) ![]Value {
        const list = action.asList() orelse return error.BadCommand;
        const kw = list[0].asAtom() orelse return error.BadCommand;
        var i: usize = 1;
        const inst = self.actionTarget(list, &i) orelse return error.NoTarget;
        const name = list[i].string;
        i += 1;
        if (std.mem.eql(u8, kw, "invoke")) {
            const args = try self.a.alloc(Value, list.len - i);
            for (list[i..], args) |arg, *dst| dst.* = try self.parseConst(arg);
            return inst.invoke(name, args);
        }
        if (std.mem.eql(u8, kw, "get")) return self.getGlobal(inst, name);
        return error.BadCommand;
    }

    /// Resolve an action's target: a leading `$M` module ref (consumed via `i`),
    /// else the current module. Null if unavailable.
    fn actionTarget(self: *Runner, list: []const Sexpr, i: *usize) ?*interp.Instance {
        if (i.* < list.len and isId(list[i.*])) {
            const inst = self.module_names.get(list[i.*].atom);
            i.* += 1;
            return inst;
        }
        return self.current;
    }

    /// Read an exported global's current value (`(get …)` action).
    fn getGlobal(self: *Runner, inst: *interp.Instance, name: []const u8) ![]Value {
        for (inst.module.exports) |e| {
            if (e.type == .global and std.mem.eql(u8, e.name, name)) {
                const v = try self.a.alloc(Value, 1);
                v[0] = inst.globals[e.index];
                return v;
            }
        }
        return error.UndefinedExport;
    }

    fn assertReturn(self: *Runner, form: []const Sexpr) Error!void {
        const results = self.runAction(form[1]) catch |e| {
            if (e == error.NoTarget) { // module didn't build / unknown $name — can't run
                self.summary.skipped += 1;
                return;
            }
            self.fail("assert_return: unexpected trap {s}", .{@errorName(e)});
            return;
        };
        const expected = form[2..];
        if (results.len != expected.len) {
            self.fail("assert_return: arity {d} != expected {d}", .{ results.len, expected.len });
            return;
        }
        const action_name: []const u8 = actionName(form[1]);
        for (results, expected) |got, exp_form| {
            if (!try self.matches(got, exp_form)) {
                self.fail("assert_return \"{s}\": result mismatch (got 0x{x})", .{ action_name, got });
                return;
            }
        }
        self.summary.passed += 1;
    }

    /// Intern a host externref payload → its stack representation (a small index,
    /// never the `null_ref` sentinel). Equal payloads get the same value so an
    /// externref round-trips through the module and compares equal (#9).
    fn internExtern(self: *Runner, payload: u64) Error!Value {
        for (self.extern_pool.items, 0..) |p, i| if (p == payload) return @intCast(i);
        const idx: Value = @intCast(self.extern_pool.items.len);
        try self.extern_pool.append(self.a, payload);
        return idx;
    }

    /// Parse a concrete value literal (for invoke arguments): `(TYPE.const literal)`
    /// or a reference literal (`(ref.null …)`, `(ref.extern N)`, `(ref.func N)`).
    fn parseConst(self: *Runner, form: Sexpr) Error!Value {
        const list = form.asList() orelse return error.BadValue;
        const kw = list[0].asAtom() orelse return error.BadValue;
        // `ref.null` carries an ignorable heaptype; `ref.func` payload is a func
        // index (used directly); `ref.extern` payload is a host value (interned).
        if (std.mem.eql(u8, kw, "ref.null")) return null_ref;
        if (std.mem.eql(u8, kw, "ref.extern")) {
            if (list.len < 2) return self.internExtern(0); // bare `(ref.extern)` — any non-null
            return self.internExtern(@bitCast(try parseInt(list[1].asAtom() orelse return error.BadValue)));
        }
        if (std.mem.eql(u8, kw, "ref.func")) {
            if (list.len < 2) return null_ref -% 1; // bare `(ref.func)` — any non-null
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
    /// the `nan:canonical` / `nan:arithmetic` matchers for floats and references.
    fn matches(self: *Runner, got: Value, exp_form: Sexpr) Error!bool {
        const list = exp_form.asList() orelse return error.BadValue;
        const kw = list[0].asAtom() orelse return error.BadValue;
        // Reference matchers: `(ref.null …)` ⇒ null; a bare `(ref.func)` /
        // `(ref.extern)` ⇒ any non-null; with a payload ⇒ exact.
        if (std.mem.eql(u8, kw, "ref.null")) return got == null_ref;
        if (std.mem.eql(u8, kw, "ref.extern")) {
            if (list.len < 2) return got != null_ref;
            return got == try self.internExtern(@bitCast(try parseInt(list[1].asAtom() orelse return error.BadValue)));
        }
        if (std.mem.eql(u8, kw, "ref.func")) {
            if (list.len < 2) return got != null_ref;
            return got == @as(Value, @intCast(try parseInt(list[1].asAtom() orelse return error.BadValue)));
        }
        const lit = list[1].asAtom() orelse return error.BadValue;
        if (std.mem.eql(u8, kw, "f32.const")) return floatMatches(f32, got, lit);
        if (std.mem.eql(u8, kw, "f64.const")) return floatMatches(f64, got, lit);
        // Integers: exact bit comparison.
        return got == try self.parseConst(exp_form);
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
        if (self.runAction(form[1])) |_| {
            self.fail("assert_trap: expected a trap, got a result", .{});
        } else |e| {
            // Only a genuine wasm runtime trap counts — an engine limitation or
            // bug (UnsupportedInstruction, UndefinedFunc, a decode/assemble error)
            // must NOT be green-washed as the expected trap.
            if (e == error.NoTarget) self.summary.skipped += 1 else if (isRuntimeTrap(e)) self.summary.passed += 1 else self.fail("assert_trap: non-trap error {s}", .{@errorName(e)});
        }
    }

    /// `assert_exhaustion (invoke …) "call stack exhausted"` — expects the call
    /// depth limit to trip (a runtime trap), not any other error.
    fn assertExhaustion(self: *Runner, form: []const Sexpr) Error!void {
        if (self.runAction(form[1])) |_| {
            self.fail("assert_exhaustion: expected exhaustion, got a result", .{});
        } else |e| {
            if (e == error.NoTarget) self.summary.skipped += 1 else if (e == error.CallStackExhausted) self.summary.passed += 1 else self.fail("assert_exhaustion: got {s}", .{@errorName(e)});
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

    /// `assert_unlinkable (module …) "reason"` — the module is valid but must fail
    /// to *link*: an import with no matching export ("unknown import") or a type
    /// mismatch ("incompatible import type"). Passing = we rejected it at link
    /// time; a non-link error (decode/validate/runtime) does not count. Does not
    /// touch `self.current`.
    fn assertUnlinkable(self: *Runner, form: []const Sexpr) Error!void {
        const inner = form[1].asList() orelse {
            self.fail("assert_unlinkable: malformed command", .{});
            return;
        };
        if (self.buildModule(inner)) |_| {
            self.fail("assert_unlinkable: module linked (should be rejected)", .{});
        } else |e| {
            if (isLinkError(e)) self.summary.passed += 1 else self.fail("assert_unlinkable: non-link error {s}", .{@errorName(e)});
        }
    }
};

/// True for the errors that mean a module failed to *link* (import resolution),
/// as opposed to decode/validate or a runtime trap.
fn isLinkError(e: anyerror) bool {
    return switch (e) {
        error.UnresolvedImport, error.MissingImport, error.IncompatibleImportType => true,
        else => false,
    };
}

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
        error.NullReference,
        error.GcOutOfBounds,
        error.CastFailure,
        error.HostTrap,
        error.CallStackExhausted,
        error.UncaughtException, // an uncaught exception traps (EH proposal)
        => true,
        else => false,
    };
}

// --- Value literals & comparison -------------------------------------------

/// Null reference sentinel — must match `interp`'s `null_ref` on the value stack.
const null_ref: Value = std.math.maxInt(u64);

// --- Import linking: type compatibility ------------------------------------

fn funcTypeEq(a: Module.FuncType, b: Module.FuncType) bool {
    return valTypesEq(a.params, b.params) and valTypesEq(a.results, b.results);
}
fn valTypesEq(a: []const types.ValType, b: []const types.ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
/// True if a provided limits range satisfies (is a subtype of) the required one:
/// provided.min ≥ required.min and, if required is bounded, provided is bounded
/// no higher (§4.5.3 limits matching).
fn limitsFit(provided: Module.Limits, required: Module.Limits) bool {
    if (provided.min < required.min) return false;
    if (required.max) |rmax| {
        const pmax = provided.max orelse return false;
        if (pmax > rmax) return false;
    }
    return true;
}

fn spectestNoop(args: []const Value, results: []Value) void {
    _ = args;
    _ = results; // print funcs return nothing
}

/// The signature of a standard `spectest` `print*` function, or null if unknown.
fn spectestFuncType(name: []const u8) ?Module.FuncType {
    const T = struct {
        const none: []const V = &.{};
        const i32_: []const V = &.{.i32};
        const i64_: []const V = &.{.i64};
        const f32_: []const V = &.{.f32};
        const f64_: []const V = &.{.f64};
        const i32_f32: []const V = &.{ .i32, .f32 };
        const f64_f64: []const V = &.{ .f64, .f64 };
    };
    const p: []const V = if (std.mem.eql(u8, name, "print")) T.none else if (std.mem.eql(u8, name, "print_i32")) T.i32_ else if (std.mem.eql(u8, name, "print_i64")) T.i64_ else if (std.mem.eql(u8, name, "print_f32")) T.f32_ else if (std.mem.eql(u8, name, "print_f64")) T.f64_ else if (std.mem.eql(u8, name, "print_i32_f32")) T.i32_f32 else if (std.mem.eql(u8, name, "print_f64_f64")) T.f64_f64 else return null;
    return .{ .params = p, .results = T.none };
}

/// The type of a standard `spectest` global (all immutable), or null if unknown.
fn spectestGlobalType(name: []const u8) ?Module.GlobalType {
    const content: V = if (std.mem.eql(u8, name, "global_i32")) .i32 else if (std.mem.eql(u8, name, "global_i64")) .i64 else if (std.mem.eql(u8, name, "global_f32")) .f32 else if (std.mem.eql(u8, name, "global_f64")) .f64 else return null;
    return .{ .content = content, .mutable = false };
}

/// The standard testsuite `spectest` host global values (immutable), as their raw
/// slot bits.
fn spectestGlobal(module: []const u8, name: []const u8) ?Value {
    if (!std.mem.eql(u8, module, "spectest")) return null;
    if (std.mem.eql(u8, name, "global_i32")) return interp.i32Value(666);
    if (std.mem.eql(u8, name, "global_i64")) return interp.i64Value(666);
    if (std.mem.eql(u8, name, "global_f32")) return interp.f32Value(666.6);
    if (std.mem.eql(u8, name, "global_f64")) return interp.f64Value(666.6);
    return null;
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

/// The invoked/queried name in an action form (`(invoke $M? "name" …)` /
/// `(get $M? "name")`), for diagnostics; "?" if absent.
fn actionName(action: Sexpr) []const u8 {
    const l = action.asList() orelse return "?";
    var i: usize = 1;
    if (i < l.len and isId(l[i])) i += 1;
    if (i < l.len) return switch (l[i]) {
        .string => |s| s,
        else => "?",
    };
    return "?";
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

fn buildAndValidate(a: std.mem.Allocator, src: []const u8) !void {
    const bin = try wat.assemble(a, src);
    var m = try Module.decode(a, bin);
    try validate(a, &m);
}

test "non-null refs: subtyping + uninitialized-local rejection (P2.5)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A non-nullable local read before being set → invalid.
    try std.testing.expectError(error.UninitializedLocal, buildAndValidate(a,
        \\(module (func (local $x (ref extern)) (drop (local.get $x))))
    ));
    // Passing a nullable null to a non-null param → type mismatch (subtyping).
    try std.testing.expectError(error.TypeMismatch, buildAndValidate(a,
        \\(module (type $t (func))
        \\  (func $g (param (ref $t)))
        \\  (func (call $g (ref.null $t))))
    ));
    // Set-before-get with a non-null local, and a non-null value into a nullable
    // slot (subtype), are valid.
    const ok =
        \\(module
        \\  (func (export "ok") (param $p (ref extern)) (result externref)
        \\    (local $x (ref extern))
        \\    (local.set $x (local.get $p))
        \\    (local.get $x)))
        \\(assert_return (invoke "ok" (ref.extern 7)) (ref.extern 7))
    ;
    const s = try runScript(std.testing.allocator, ok);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "call_ref / return_call_ref / ref.as_non_null (P2)" {
    const src =
        \\(module
        \\  (type $ii (func (param i32) (result i32)))
        \\  (func $sq (type $ii) (i32.mul (local.get 0) (local.get 0)))
        \\  (elem declare func $sq)
        \\  (global $g (ref $ii) (ref.func $sq))
        \\  (func (export "call") (param i32) (result i32)
        \\    (call_ref $ii (local.get 0) (global.get $g)))
        \\  (func (export "asnn") (param i32) (result i32)
        \\    (call_ref $ii (local.get 0) (ref.as_non_null (global.get $g))))
        \\  (func (export "tail") (param i32) (result i32)
        \\    (return_call_ref $ii (local.get 0) (global.get $g)))
        \\  (func (export "trap") (result i32)
        \\    (call_ref $ii (i32.const 1) (ref.null $ii))))
        \\(assert_return (invoke "call" (i32.const 5)) (i32.const 25))
        \\(assert_return (invoke "asnn" (i32.const 6)) (i32.const 36))
        \\(assert_return (invoke "tail" (i32.const 7)) (i32.const 49))
        \\(assert_trap (invoke "trap") "null reference")
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "typed/GC reference value types are accepted (P1)" {
    // anyref/eqref/i31ref/(ref null $t) collapse to the opaque ref slots; a module
    // merely using them in signatures/globals builds and ref.null round-trips.
    const src =
        \\(module
        \\  (type $t (func))
        \\  (global $g eqref (ref.null eq))
        \\  (func (export "a") (result anyref) (ref.null any))
        \\  (func (export "i") (result i31ref) (ref.null i31))
        \\  (func (export "r") (result (ref null $t)) (ref.null $t))
        \\  (func (export "isnull") (param externref) (result i32) (ref.is_null (local.get 0))))
        \\(assert_return (invoke "a") (ref.null any))
        \\(assert_return (invoke "i") (ref.null i31))
        \\(assert_return (invoke "isnull" (ref.null extern)) (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 3), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "invoke / get by module name + register $id" {
    const src =
        \\(module $A (func (export "f") (result i32) (i32.const 11)) (global (export "g") i32 (i32.const 22)))
        \\(module $B (func (export "f") (result i32) (i32.const 33)))
        \\(register "A" $A)
        \\(module (import "A" "f" (func $af (result i32))) (func (export "call-a") (result i32) (call $af)))
        \\(assert_return (invoke $A "f") (i32.const 11))
        \\(assert_return (invoke $B "f") (i32.const 33))
        \\(assert_return (get $A "g") (i32.const 22))
        \\(assert_return (invoke "call-a") (i32.const 11))
    ;
    // A named `$A`/`$B` invoke targets that module; the bare `call-a` invoke uses
    // the current (last-built) module, which imports A's `f` via `(register …)`.
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

test "externref payload equal to the null sentinel is not null (#9)" {
    const src =
        \\(module
        \\  (table $t 1 externref)
        \\  (func (export "isnull") (param externref) (result i32) (ref.is_null (local.get 0)))
        \\  (func (export "roundtrip") (param externref) (result externref)
        \\    (table.set $t (i32.const 0) (local.get 0))
        \\    (table.get $t (i32.const 0))))
        \\(assert_return (invoke "isnull" (ref.extern 0xFFFFFFFFFFFFFFFF)) (i32.const 0))
        \\(assert_return (invoke "isnull" (ref.null extern)) (i32.const 1))
        \\(assert_return (invoke "roundtrip" (ref.extern 0xFFFFFFFFFFFFFFFF)) (ref.extern 0xFFFFFFFFFFFFFFFF))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 3), s.passed);
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

test "exception handling: assert_return on a caught exn, assert_trap on an uncaught one" {
    const src =
        \\(module
        \\  (tag $e (param i32))
        \\  (func (export "caught") (result i32)
        \\    (try_table (result i32) (catch $e 0)
        \\      i32.const 88
        \\      throw $e))
        \\  (func (export "uncaught")
        \\    i32.const 1
        \\    throw $e))
        \\(assert_return (invoke "caught") (i32.const 88))
        \\(assert_trap (invoke "uncaught") "uncaught exception")
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}
