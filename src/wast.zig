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

// Shape-checked accessors — the `.wast` runner operates on parser output whose
// shape is NOT validated (the parser only balances parens/strings). Malformed
// `.wast` (reached via `wazmrt <file.wast>`) must error, never index a parsed
// s-expression out of bounds or deref a wrong-union `.string` (UB in ReleaseFast).

/// The i-th element of a command/action form, or `error.BadCommand` if too short.
fn nth(items: []const Sexpr, i: usize) Error!Sexpr {
    return if (i < items.len) items[i] else error.BadCommand;
}
/// A form as a string literal (an action/register name), or `error.BadCommand`.
fn asStr(s: Sexpr) Error![]const u8 {
    return switch (s) {
        .string => |x| x,
        else => error.BadCommand,
    };
}

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
    // Guest linear memory is PAGE-ALLOCATOR owned, so the arena above does NOT
    // reclaim it — every `(memory N)` in every module, plus every `memory.grow`,
    // leaked for the life of the process, and `tools/conformance.zig`'s careful
    // per-file arena did not help either. Deinit the instances explicitly.
    defer {
        for (r.instances.items) |inst| inst.deinit();
        // The shared `spectest` memory is BORROWED by every importer, so no
        // instance frees it — but its bytes are page-allocator owned too.
        if (r.spectest_memory) |m| interp.freeGuestMemory(m.bytes);
    }
    for (try sexpr.parseAll(r.a, src)) |cmd| try r.command(cmd);
    return r.summary;
}

const HostFunc = interp.Instance.HostFunc;

const Runner = struct {
    a: std.mem.Allocator,
    /// Every instance built by this script, so their page-allocator memories can
    /// be released (the runner arena cannot reclaim those). See `runScript`.
    instances: std.ArrayList(*interp.Instance) = .empty,
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
            if (target) |inst| try self.modules.put(self.a, try asStr(try nth(list, 1)), inst);
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
        // Register before `runStart`: even if the start function traps, the
        // instance already owns page-allocator memory that must be released.
        try self.instances.append(self.a, inst);
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
                    return inst.memory0() orelse error.UnresolvedImport;
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

    /// The shared `spectest` memory / table, allocated on first use (the `Memory`
    /// *object* from the runner arena, so it outlives every instance that borrows
    /// it — but its `bytes` from the page allocator, see below).
    fn spectestMemory(self: *Runner) !*interp.Instance.Memory {
        if (self.spectest_memory) |m| return m;
        // `Memory.bytes` is ALWAYS page-allocator owned — `memory.grow` hands it
        // to `growGuestMemory`/`rawRemap`, which `@alignCast`s to page alignment.
        // Arena bytes are a 16-byte-aligned interior pointer, so a guest
        // `memory.grow` on an imported `spectest.memory` panicked with
        // "incorrect alignment" in Debug and did an mremap/munmap on host-heap
        // memory in ReleaseFast. (This is the sibling the `wasm_memory_new`
        // cross-allocator fix missed: that swept `wasm_c_api.zig` but not
        // `wast.zig`, the other producer of `Memory` objects — reachable from
        // the official testsuite's `imports.wast`.)
        const buf = try interp.allocGuestMemory(interp.page_size); // 1 page, demand-zero
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
        const kw = (try nth(list, 0)).asAtom() orelse return error.BadCommand;
        var i: usize = 1;
        const inst = self.actionTarget(list, &i) orelse return error.NoTarget;
        const name = try asStr(try nth(list, i));
        i += 1;
        if (std.mem.eql(u8, kw, "invoke")) {
            // A `v128` argument occupies TWO slots (low then high), so the slot
            // count is not the form count.
            var nslots: usize = 0;
            for (list[i..]) |arg| nslots += if (isV128Form(arg)) 2 else 1;
            const args = try self.a.alloc(Value, nslots);
            var ai: usize = 0;
            for (list[i..]) |arg| {
                if (isV128Form(arg)) {
                    const v = try parseV128(arg.asList().?);
                    args[ai] = @truncate(v);
                    args[ai + 1] = @truncate(v >> 64);
                    ai += 2;
                } else {
                    args[ai] = try self.parseConst(arg);
                    ai += 1;
                }
            }
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
        if (form.len < 2) return self.fail("assert_return: missing action", .{});
        const results = self.runAction(form[1]) catch |e| {
            if (e == error.NoTarget) { // module didn't build / unknown $name — can't run
                self.summary.skipped += 1;
                return;
            }
            self.fail("assert_return: unexpected trap {s}", .{@errorName(e)});
            return;
        };
        const expected = form[2..];
        // Results are counted in SLOTS, and a v128 is two of them (`pushV128`
        // pushes low then high). Comparing form count to slot count directly
        // reported "arity 2 != expected 1" for every SIMD assertion in the
        // testsuite, which is why none of them had ever actually run.
        var want_slots: usize = 0;
        for (expected) |exp_form| want_slots += if (isV128Form(exp_form)) 2 else 1;
        if (results.len != want_slots) {
            self.fail("assert_return: arity {d} != expected {d}", .{ results.len, want_slots });
            return;
        }
        const action_name: []const u8 = actionName(form[1]);
        var ri: usize = 0;
        for (expected) |exp_form| {
            if (isV128Form(exp_form)) {
                const lo = results[ri];
                const hi = results[ri + 1];
                ri += 2;
                const got: u128 = (@as(u128, hi) << 64) | lo;
                if (!try v128Matches(got, exp_form.asList().?)) {
                    self.fail("assert_return \"{s}\": v128 mismatch (got 0x{x})", .{ action_name, got });
                    return;
                }
            } else {
                const got = results[ri];
                ri += 1;
                if (!try self.matches(got, exp_form)) {
                    self.fail("assert_return \"{s}\": result mismatch (got 0x{x})", .{ action_name, got });
                    return;
                }
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
        if (list.len == 0) return error.BadValue;
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
            return @bitCast(try parseInt(list[1].asAtom() orelse return error.BadValue)); // @bitCast: a negative index is bogus but must not be UB
        }
        if (list.len < 2) return error.BadValue;
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
        if (list.len == 0) return error.BadValue;
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
            return got == @as(Value, @bitCast(try parseInt(list[1].asAtom() orelse return error.BadValue)));
        }
        // Abstract GC reference matchers (`(ref.struct)`, `(ref.array)`,
        // `(ref.i31)`, `(ref.eq)`, `(ref.any)`, `(ref.host)`, `(ref.data)`): the
        // GC testsuite uses these to assert the result is a non-null reference of
        // the given kind. We check non-null, matching the bare `(ref.func)` /
        // `(ref.extern)` convention — before this, an unhandled matcher returned
        // `error.BadValue` and ABORTED the whole `.wast` file, so as soon as a GC
        // module built far enough to reach one, every later assertion was lost.
        if (std.mem.eql(u8, kw, "ref.struct") or std.mem.eql(u8, kw, "ref.array") or
            std.mem.eql(u8, kw, "ref.i31") or std.mem.eql(u8, kw, "ref.eq") or
            std.mem.eql(u8, kw, "ref.any") or std.mem.eql(u8, kw, "ref.host") or
            std.mem.eql(u8, kw, "ref.data")) return got != null_ref;
        if (list.len < 2) return error.BadValue;
        const lit = list[1].asAtom() orelse return error.BadValue;
        if (std.mem.eql(u8, kw, "f32.const")) return floatMatches(f32, got, lit);
        if (std.mem.eql(u8, kw, "f64.const")) return floatMatches(f64, got, lit);
        // Integers: exact bit comparison.
        return got == try self.parseConst(exp_form);
    }

    fn assertTrap(self: *Runner, form: []const Sexpr) Error!void {
        if (form.len < 2) return self.fail("assert_trap: missing operand", .{});
        // `assert_trap (module …)` — instantiation itself must trap (e.g. an
        // active data/element segment out of bounds). Build it in isolation and
        // require a genuine runtime trap; it does not become the current module.
        if (form[1].asList()) |inner| {
            if (inner.len != 0 and std.mem.eql(u8, inner[0].asAtom() orelse "", "module")) {
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
        if (form.len < 2) return self.fail("assert_exhaustion: missing action", .{});
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
        if (form.len < 2) return self.fail("assert_invalid: malformed command", .{});
        const inner = form[1].asList() orelse {
            self.fail("assert_invalid: malformed command", .{});
            return;
        };
        if (self.tryBuild(inner)) |_| {
            self.fail("assert_invalid/malformed: module was accepted (should be rejected)", .{});
        } else |e| if (isOurLimitation(e)) {
            // We failed to BUILD the module for a reason of our own — an
            // unimplemented command form or an instruction the assembler doesn't
            // know. That is not evidence the module is invalid, and counting it
            // as a pass green-washed the conformance numbers with our own gaps:
            // `(module quote …)` (unimplemented → `BadCommand`) and any unknown
            // mnemonic (→ `UnknownInstr`) both scored as passes. `assert_trap`
            // and `assert_unlinkable` already filter their verdicts this way;
            // this was the arm that did not.
            self.summary.skipped += 1;
        } else {
            self.summary.passed += 1;
        }
    }

    /// True if `e` means "wazmrt cannot build this", as opposed to "the module is
    /// genuinely invalid/malformed".
    ///
    /// Deliberately conservative: a mis-classification here under-reports passes
    /// (honest) whereas the reverse inflates them (the bug this fixes). When an
    /// error is ambiguous — `UnsupportedOpcode` could be a truly bad byte *or* an
    /// opcode we have not implemented — it belongs on this list.
    fn isOurLimitation(e: anyerror) bool {
        return switch (e) {
            error.BadCommand, // e.g. `(module quote …)`, not implemented
            error.NotAModule,
            error.UnknownInstr, // the assembler doesn't know this mnemonic
            error.UnsupportedInstr,
            error.UnknownIdentifier,
            error.UnsupportedOpcode, // ambiguous → treat as ours
            error.UnsupportedInstruction,
            error.OutOfMemory, // a resource failure is not a verdict
            => true,
            else => false,
        };
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
        if (form.len < 2) return self.fail("assert_unlinkable: malformed command", .{});
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
        // Deliberately NOT listed: `error.GcHeapExhausted` and
        // `error.ExnStoreExhausted`. Both are OUR resource caps, not §4.2 traps —
        // admitting them here would let a module that merely allocates a lot (or
        // catches a lot) satisfy an `assert_trap` meant for real trapping
        // behaviour, which is exactly what this filter prevents.
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

/// Lane count for a `v128.const` shape keyword, or null if it is not one.
fn v128Shape(kw: []const u8) ?struct { lanes: usize, width: usize, float: bool } {
    if (std.mem.eql(u8, kw, "i8x16")) return .{ .lanes = 16, .width = 1, .float = false };
    if (std.mem.eql(u8, kw, "i16x8")) return .{ .lanes = 8, .width = 2, .float = false };
    if (std.mem.eql(u8, kw, "i32x4")) return .{ .lanes = 4, .width = 4, .float = false };
    if (std.mem.eql(u8, kw, "i64x2")) return .{ .lanes = 2, .width = 8, .float = false };
    if (std.mem.eql(u8, kw, "f32x4")) return .{ .lanes = 4, .width = 4, .float = true };
    if (std.mem.eql(u8, kw, "f64x2")) return .{ .lanes = 2, .width = 8, .float = true };
    return null;
}

/// True if `form` is a `(v128.const <shape> <lane>…)` literal — which occupies
/// **two** result slots, unlike every other value form.
fn isV128Form(form: Sexpr) bool {
    const list = form.asList() orelse return false;
    if (list.len < 2) return false;
    const kw = list[0].asAtom() orelse return false;
    return std.mem.eql(u8, kw, "v128.const");
}

/// Parse `(v128.const <shape> <lane>…)` into its 128-bit value. Lanes are
/// little-endian: lane 0 occupies the low bits, matching `pushV128`, which
/// pushes the low half first.
fn parseV128(list: []const Sexpr) Error!u128 {
    if (list.len < 2) return error.BadValue;
    const shape = v128Shape(list[1].asAtom() orelse return error.BadValue) orelse return error.BadValue;
    if (list.len != 2 + shape.lanes) return error.BadValue;
    var out: u128 = 0;
    for (0..shape.lanes) |i| {
        const lit = list[2 + i].asAtom() orelse return error.BadValue;
        const bits: u64 = switch (shape.width) {
            1 => @as(u8, @truncate(@as(u64, @bitCast(try parseInt(lit))))),
            2 => @as(u16, @truncate(@as(u64, @bitCast(try parseInt(lit))))),
            4 => if (shape.float) @as(u64, try parseFloatBits(f32, lit)) else @as(u32, @truncate(@as(u64, @bitCast(try parseInt(lit))))),
            8 => if (shape.float) try parseFloatBits(f64, lit) else @as(u64, @bitCast(try parseInt(lit))),
            else => unreachable,
        };
        out |= @as(u128, bits) << @intCast(i * shape.width * 8);
    }
    return out;
}

/// Compare a 128-bit result against a `(v128.const …)` expectation. Float shapes
/// are matched **lane by lane** so the per-lane `nan:canonical`/`nan:arithmetic`
/// matchers work — a whole-vector bit compare would reject a legitimate NaN.
fn v128Matches(got: u128, list: []const Sexpr) Error!bool {
    if (list.len < 2) return error.BadValue;
    const shape = v128Shape(list[1].asAtom() orelse return error.BadValue) orelse return error.BadValue;
    if (list.len != 2 + shape.lanes) return error.BadValue;
    if (!shape.float) return got == try parseV128(list);
    for (0..shape.lanes) |i| {
        const lit = list[2 + i].asAtom() orelse return error.BadValue;
        const lane: u64 = @truncate(got >> @intCast(i * shape.width * 8));
        const ok = if (shape.width == 4) try floatMatches(f32, lane, lit) else try floatMatches(f64, lane, lit);
        if (!ok) return false;
    }
    return true;
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
    // `wat.parseFloatLit`, not `std.fmt.parseFloat`: one authority for float
    // literals across the assembler and this runner, so an `assert_return`
    // expectation and the module it checks can never disagree about what a
    // literal means. (std truncates long hex mantissas — see that function.)
    const f = wat.parseFloatLit(F, lit) orelse return error.BadValue;
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

test "runner rejects malformed commands without indexing out of bounds" {
    // Each is shape-malformed: the runner must error or record a failure, never
    // index a parsed s-expression past its end / deref a wrong-union `.string`
    // (a Debug panic here, UB in ReleaseFast). Pre-hardening these read `form[1]`/
    // `list[i]`/`list[0]` OOB. Reaching the end of the loop is the assertion.
    const cases = [_][]const u8{
        "(assert_return)", // missing action
        "(assert_return ())", // action is an empty list
        "(assert_trap)", // missing operand
        "(assert_trap ())", // operand is an empty list → inner[0]
        "(assert_exhaustion)",
        "(assert_invalid)",
        "(assert_unlinkable)",
        "(register)", // missing name → list[1]
        "(module (func (export \"f\"))) (invoke)", // missing name
        "(module (func (export \"f\"))) (invoke \"f\" (i32.const))", // const w/o literal
        "(module (func (export \"f\"))) (invoke \"f\" ())", // arg is an empty list
        "(module (func (export \"f\"))) (register)",
    };
    for (cases) |src| {
        // Either outcome (error or a recorded failure) is fine; the point is that
        // no path indexes out of bounds.
        _ = runScript(std.testing.allocator, src) catch {};
    }
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

test "wast runner: abstract GC ref matchers ((ref.struct)/(ref.i31)) don't abort the file" {
    // A GC module returning a struct/array/i31 reference is checked with
    // `(assert_return (invoke …) (ref.struct))` etc. The runner had no arm for
    // these, so `matches` returned error.BadValue and aborted the ENTIRE .wast
    // file the moment one was reached — losing every later assertion. They now
    // match "non-null reference", like the bare `(ref.func)` convention. The
    // trailing i32 assert would be lost (BadValue abort) if the ref matcher
    // aborted, so its passing proves the file kept running.
    const src =
        \\(module
        \\  (type $s (struct (field i32)))
        \\  (func (export "mk") (result (ref $s)) (struct.new $s (i32.const 1)))
        \\  (func (export "mki31") (result (ref i31)) (ref.i31 (i32.const 5)))
        \\  (func (export "n") (result i32) (i32.const 42)))
        \\(assert_return (invoke "mk") (ref.struct))
        \\(assert_return (invoke "mki31") (ref.i31))
        \\(assert_return (invoke "n") (i32.const 42))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 3), s.passed);
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

test "unbounded recursion traps CallStackExhausted instead of overflowing the host stack" {
    // A guest `call` recurses NATIVELY, so `max_call_depth` is the only thing
    // between a runaway module and a segfault. It was calibrated against
    // ReleaseFast frames and sat ABOVE what Debug's larger frames could take, so
    // in Debug the process died at ~878 frames without the guard ever firing.
    // Nothing in the suite recursed deeply enough to notice — the spec suite's
    // own `call.wast` did, and crashed the runner.
    //
    // Both shapes matter: direct self-recursion and a mutual cycle (which a
    // naive same-function-index guard would miss).
    const src =
        \\(module
        \\  (func $runaway (export "runaway") (call $runaway))
        \\  (func $m1 (export "mutual") (call $m2))
        \\  (func $m2 (call $m1)))
        \\(assert_exhaustion (invoke "runaway") "call stack exhausted")
        \\(assert_exhaustion (invoke "mutual") "call stack exhausted")
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "exception handling: an exception crossing a module boundary is catchable by the importer" {
    // `pending_exn` hangs off `Instance`, so an exception unwinding out of an
    // imported function used to be parked on the CALLEE's instance where the
    // caller's `onCallError` could never find it: a `try_table (catch_all …)`
    // wrapped around the call silently failed to fire and the whole invocation
    // trapped `UncaughtException` instead. `callFunction`'s cross-module arm
    // now hands the exception to the caller's instance on the way out.
    //
    // `$r` stays 0 only if the catch_all really fired; 1 means the callee never
    // threw, and a trap means the exception escaped uncaught.
    const src =
        \\(module (tag $t) (func (export "boom") (throw $t)))
        \\(register "callee")
        \\(module
        \\  (import "callee" "boom" (func $boom))
        \\  (func (export "go") (result i32)
        \\    (local $r i32)
        \\    (block $b
        \\      (try_table (catch_all $b)
        \\        (call $boom)
        \\        (local.set $r (i32.const 1))))
        \\    (local.get $r)))
        \\(assert_return (invoke "go") (i32.const 0))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "v128 among multiple results keeps the other results aligned" {
    // A v128 occupies TWO slots, so any consumer walking a result array in
    // lockstep with the result TYPES drifts from the first v128 onwards. This
    // shape — i32, v128, i32 — is the minimal case that catches it: the trailing
    // 22 came back as 3 through the C ABI, and the CLI dropped both i32s.
    const src =
        \\(module (func (export "g") (result i32 v128 i32)
        \\  (i32.const 11) (v128.const i32x4 1 2 3 4) (i32.const 22)))
        \\(assert_return (invoke "g")
        \\  (i32.const 11) (v128.const i32x4 1 2 3 4) (i32.const 22))
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "a rejected module cannot leave entries in another module's table" {
    // The active-element loop used to bounds-check per entry, so an over-long
    // segment wrote a partial prefix and *then* failed instantiation. For an
    // IMPORTED table that storage belongs to the exporter and outlives the
    // rejected instantiation — so a module that FAILED TO INSTANTIATE could
    // install entries into another module's table.
    //
    // Here $A never populates its own table and keeps `$secret` unexported. The
    // importing module is rejected (offset 2 + 3 entries > 4 slots), after which
    // $A's `call_indirect` through slot 2 must still trap. Before the fix it
    // returned 1337 — $A dispatching to a function it never installed, chosen by
    // a module that was refused.
    const src =
        \\(module $A
        \\  (type $r (func (result i32)))
        \\  (table (export "t") 4 funcref)
        \\  (func $secret (type $r) (i32.const 1337))
        \\  (func (export "at") (param i32) (result i32)
        \\    (call_indirect (type $r) (local.get 0))))
        \\(register "A" $A)
        \\(assert_trap
        \\  (module
        \\    (import "A" "t" (table 4 funcref))
        \\    (type $r (func (result i32)))
        \\    (func $f (type $r) (i32.const 1337))
        \\    (elem (i32.const 2) $f $f $f))
        \\  "out of bounds table access")
        \\(assert_trap (invoke $A "at" (i32.const 2)) "uninitialized element")
    ;
    const s = try runScript(std.testing.allocator, src);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "assert_invalid/malformed does not count OUR limitations as passes" {
    // `assertRejected` used to score ANY error as a pass, so a module we simply
    // could not BUILD — an unimplemented command form, or a mnemonic our
    // assembler doesn't know — inflated the conformance numbers with our own
    // gaps. `assert_trap` and `assert_unlinkable` already filtered their
    // verdicts; this was the arm that didn't.
    const gpa = std.testing.allocator;

    // (a) `(module quote …)` is unimplemented -> BadCommand -> must SKIP.
    {
        const src = "(assert_malformed (module quote \"not wasm\") \"unexpected token\")";
        const s = try runScript(gpa, src);
        try std.testing.expectEqual(@as(usize, 0), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
        try std.testing.expectEqual(@as(usize, 1), s.skipped);
    }

    // (b) an unknown mnemonic is an ASSEMBLER gap, not evidence of invalidity.
    {
        const src = "(assert_invalid (module (func (result i32) (some.bogus.instruction))) \"type mismatch\")";
        const s = try runScript(gpa, src);
        try std.testing.expectEqual(@as(usize, 0), s.passed);
        try std.testing.expectEqual(@as(usize, 1), s.skipped);
    }

    // (c) a genuinely ill-typed module must still PASS — the fix must not turn
    //     real rejections into skips.
    {
        const src = "(assert_invalid (module (func (result i32) (i64.const 1))) \"type mismatch\")";
        const s = try runScript(gpa, src);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }
}
