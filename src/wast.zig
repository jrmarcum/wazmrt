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
const typematch = @import("typematch.zig");
const validate = @import("validate.zig").validate;
const validateWith = @import("validate.zig").validateWith;
const features = @import("features.zig");

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
/// A `(module quote …)` payload is EITHER a complete `(module …)` form or a bare
/// sequence of module fields (`"(func …)" "(global …)"`) — the spec's text format
/// allows both, and the corpus uses both, sometimes with the opening `(module`
/// split across string pieces. Wrap only when the text does not already open one.
///
/// The test is deliberately syntactic and cheap: skip whitespace and comments,
/// then look for `(module` followed by a delimiter. Getting it wrong is safe in
/// one direction only — wrapping an already-complete module yields
/// `(module (module …))`, which fails to assemble and would score a malformed
/// module as correctly rejected **for the wrong reason**, the false-pass shape
/// R4 hit with `StackUnderflow`. Hence the explicit delimiter check rather than
/// a bare `startsWith`.
fn wrapModuleText(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n' => i += 1,
            ';' => { // `;;` line comment — a quoted module may lead with one
                if (i + 1 >= text.len or text[i + 1] != ';') break;
                while (i < text.len and text[i] != '\n') i += 1;
            },
            else => break,
        }
    }
    const rest = text[i..];
    const kw = "(module";
    const already = std.mem.startsWith(u8, rest, kw) and
        (rest.len == kw.len or switch (rest[kw.len]) {
            ' ', '\t', '\r', '\n', '(', ')', ';', '$' => true,
            else => false,
        });
    if (already) return text;
    return std.fmt.allocPrint(a, "(module {s})", .{text});
}

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
    /// Description of the first failure, for debugging. Aliases `failures[0]`.
    first_failure: ?[]const u8 = null,
    /// Every failure (up to `max_recorded_failures`), in order.
    ///
    /// ⚠️ **Owned by the CALLER's allocator, released by `deinit`.** These used
    /// to come from `runScript`'s internal arena, which `runScript` then freed on
    /// the way out — so both readers (`main.zig`, `tools/conformance.zig`)
    /// printed freed memory and only looked correct because the page allocator
    /// had not reused the pages yet.
    failures: std.ArrayList([]const u8) = .empty,

    /// Release the failure messages. Safe to call when there were none.
    pub fn deinit(self: *Summary, gpa: std.mem.Allocator) void {
        for (self.failures.items) |m| gpa.free(m);
        self.failures.deinit(gpa);
        self.first_failure = null;
    }
};

/// Cap on per-file failure messages retained by `Summary.failures`. High enough
/// that no file in the spec suite is truncated (the worst is ~100), low enough
/// that a hostile script cannot exhaust memory.
pub const max_recorded_failures = 512;

/// The feature set a spec-testsuite file must be judged under, chosen by the PROPOSAL DIRECTORY
/// it lives in.
///
/// 🔑 **A proposal directory asserts the rules of its OWN ERA.** `proposals/threads/` is a snapshot
/// taken before multi-memory and multi-table existed, so it contains
/// `(assert_invalid … "multiple memories")` and `(assert_invalid … "multiple tables")`. wazmrt
/// implements both proposals and therefore ACCEPTS those modules — the file is not wrong and
/// neither are we; **the runtime is ahead of the file**. Running the snapshot with its own era's
/// feature set is what a conformance runner is supposed to do, and it is what makes those 8
/// assertions pass *for the right reason* rather than by being special-cased.
///
/// ⚠️ **This is a POLICY, so it is a table and not a heuristic.** Anything not listed runs
/// unrestricted — a directory must be opted IN to a narrower era, because the failure mode of
/// guessing is silently running some other file's assertions against the wrong language.
///
/// ⚠️ `null` (no path — an inline source, as in this file's own tests) means unrestricted. That is
/// deliberate rather than defaulted: a string literal in a test has no era to belong to.
pub fn featuresForPath(path: ?[]const u8) features.Set {
    var fs: features.Set = .{}; // everything on
    const p = path orelse return fs;
    // Match on either separator: the corpus is walked with native paths on Windows.
    //
    // ⚠️ **custom-descriptors RETYPES `br_on_cast`, so it is off everywhere except its own
    // directory — and this is the FIRST era entry that turns a feature off for the corpus at
    // large rather than for one snapshot.** It has to be: the era that LACKS this proposal is
    // the merged spec, i.e. every other file. The core `br_on_cast.wast` asserts
    // `br_on_cast 0 eqref anyref` INVALID and the proposal's copy of the same file compiles it
    // as VALID; both are right about their own era, and only the path tells them apart.
    if (!containsPathSegment(p, "proposals/custom-descriptors") and
        !containsPathSegment(p, "proposals\\custom-descriptors"))
        fs.set(.custom_descriptors, false);
    if (containsPathSegment(p, "proposals/threads") or containsPathSegment(p, "proposals\\threads")) {
        // The threads proposal predates BOTH. Nothing else is turned off: the files use
        // `funcref`, atomics and shared memories, all of which must keep working — which is why
        // `multi_table` exists as its own switch instead of gating on `reference_types`.
        fs.set(.multi_memory, false);
        fs.set(.multi_table, false);
    }
    return fs;
}

fn containsPathSegment(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// A proposal survives only if BOTH sets grant it. See `runScriptWith` for why this is an
/// intersection and not a replacement.
fn intersect(a: features.Set, b: features.Set) features.Set {
    var out: features.Set = .{};
    for (0..features.count) |i| {
        const f: features.Feature = @enumFromInt(@as(u8, @intCast(i)));
        out.set(f, a.has(f) and b.has(f));
    }
    return out;
}

/// Parse and run a whole `.wast` source, returning pass/fail counts.
///
/// `path` is the file the source came from, used ONLY to pick the era feature set
/// (`featuresForPath`); pass `null` for an inline source. It is a required parameter rather than a
/// defaulted one on purpose — **a defaulted policy is a policy nobody reviewed.**
pub fn runScript(gpa: std.mem.Allocator, src: []const u8, path: ?[]const u8) Error!Summary {
    return runScriptWith(gpa, src, path, .{});
}

/// `runScript`, narrowed further by a set the CALLER chose — the CLI's `--features`.
///
/// 🔒 **The two sets INTERSECT; `limit` can only ever take features away.** A `.wast` runs the
/// modules it contains, so a CLI restriction that stopped at `.wasm` would be sidestepped by
/// wrapping the module in a script — the same bypass this file's caller already closed once for
/// the verify gate, and the attacker picks the extension. Intersecting (rather than replacing)
/// keeps the era policy intact underneath: `proposals/threads/` is still judged without
/// multi-memory even if the caller asked for everything, because a snapshot's own era is a fact
/// about the file and not a preference the command line can raise. Same shape as `--verify`,
/// which raises strictness and never lowers it.
pub fn runScriptWith(gpa: std.mem.Allocator, src: []const u8, path: ?[]const u8, limit: features.Set) Error!Summary {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // One store for the whole script: every module a `.wast` file builds can be
    // `register`ed and imported by a later one, so they all have to agree on what
    // a reference value means.
    var store: interp.Store = .init(gpa);
    defer store.deinit();
    var r: Runner = .{
        .a = arena.allocator(),
        .msg_a = gpa,
        .store = &store,
        .features = intersect(featuresForPath(path), limit),
    };
    // Guest linear memory is PAGE-ALLOCATOR owned, so the arena above does NOT
    // reclaim it — every `(memory N)` in every module, plus every `memory.grow`,
    // leaked for the life of the process, and `tools/conformance.zig`'s careful
    // per-file arena did not help either. Deinit the instances explicitly.
    defer {
        for (r.instances.items) |inst| inst.deinit();
        // The shared `spectest` memories are BORROWED by every importer, so no
        // instance frees them — but their bytes are page-allocator owned too.
        if (r.spectest_memory) |m| interp.freeGuestMemory(m.bytes);
        if (r.spectest_shared_memory) |m| interp.freeGuestMemory(m.bytes);
    }
    var lines: std.ArrayList(u32) = .empty;
    const forms = try sexpr.parseAllWithLines(r.a, src, &lines);
    // §6.6.13's abbreviated module — a script that is nothing but module FIELDS. Checked before
    // the command loop because it is a property of the WHOLE script, not of any one form.
    if (Runner.isInlineModule(forms)) {
        r.line = lines.items[0];
        try r.inlineModule(forms);
        return r.summary;
    }
    for (forms, 0..) |cmd, i| {
        r.line = lines.items[i];
        try r.command(cmd);
    }
    return r.summary;
}

const HostFunc = interp.Instance.HostFunc;

const Runner = struct {
    a: std.mem.Allocator,
    /// Allocator for failure messages ONLY — the caller's, not the arena's, so
    /// the messages survive `runScript`. See `Summary.failures`.
    msg_a: std.mem.Allocator,
    /// The store shared by every instance this script builds. See `interp.Store`.
    store: *interp.Store,
    /// The era this script's assertions are judged under — see `featuresForPath`. No default:
    /// `runScript` sets it from the path so there is exactly ONE place the policy is decided.
    features: features.Set,
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
    /// `spectest.shared_memory` — the threads proposal's second memory export,
    /// declared `shared`. A SEPARATE object from `spectest_memory`, because the
    /// whole point of the three assertions that use it is that a shared and a
    /// non-shared memory do NOT satisfy each other's import.
    spectest_shared_memory: ?*interp.Instance.Memory = null,
    spectest_table: ?*interp.Instance.Table = null,
    /// `spectest.table64` — the table64 proposal's 64-bit twin of the above.
    spectest_table64: ?*interp.Instance.Table = null,
    /// Cells for the `spectest` constant globals, by name. See `spectestGlobalCell`.
    spectest_globals: std.StringHashMapUnmanaged(*interp.Instance.Global) = .{},
    /// `(module definition $M …)` bodies, by `$M` — assembled but NOT
    /// instantiated, so `(module instance $I $M)` can build fresh instances.
    definitions: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Interned host externref payloads. A `(ref.extern N)` value is represented
    /// on the value stack as its *index* here (a small integer, never the
    /// `null_ref` = maxInt sentinel), so an externref of any payload — including
    /// one equal to the sentinel — is never misclassified as null (#9).
    extern_pool: std.ArrayList(u64) = .empty,
    /// 1-based source line of the top-level command being run, prefixed onto
    /// every failure message so a failure names the assertion that produced it.
    line: u32 = 0,
    summary: Summary = .{},

    fn fail(self: *Runner, comptime fmt: []const u8, args: anytype) void {
        self.summary.failed += 1;
        if (self.summary.failures.items.len >= max_recorded_failures) return;
        // `msg_a`, not `a`: the arena dies with `runScript`, and these outlive it.
        const msg = std.fmt.allocPrint(self.msg_a, "L{d}: " ++ fmt, .{self.line} ++ args) catch return;
        if (self.summary.first_failure == null) self.summary.first_failure = msg;
        // Keep EVERY failure, not just the first. Reporting one per file made
        // 25 distinct decoder defects in `binary.wast` look like one, and sent
        // the 2026-08-11 triage to the wrong cause on three of its five items —
        // the first failure names a symptom, and the ones behind it are what say
        // WHICH symptom. `failed` still counts past the cap.
        self.summary.failures.append(self.msg_a, msg) catch {};
    }

    fn command(self: *Runner, cmd: Sexpr) Error!void {
        const kw = cmd.keyword() orelse return error.BadCommand;
        if (std.mem.eql(u8, kw, "module")) {
            return self.moduleCommand(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_return")) {
            try self.assertReturn(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_trap")) {
            try self.assertTrap(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_exhaustion")) {
            try self.assertExhaustion(cmd.asList().?);
        } else if (std.mem.eql(u8, kw, "assert_exception")) {
            try self.assertException(cmd.asList().?);
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

    /// The `(module …)` command, factored out so §6.6.13's ABBREVIATED form can reach exactly the
    /// same path — see `inlineModule`. A second copy of this arm would be a second place for the
    /// `isOurLimitation` scoring rule below to be got wrong.
    fn moduleCommand(self: *Runner, list: []const Sexpr) Error!void {
        {
            // `(module definition $M …)` DEFINES without instantiating, and
            // `(module instance $I $M)` instantiates a definition — the pair
            // `instance.wast` uses to check that instantiation is generative
            // (two instances of one definition must not share state). Neither was
            // implemented, so that whole file scored 0 passed / 8 failed / 12
            // skipped: every failure was the harness, not the runtime.
            if (list.len > 1) if (list[1].asAtom()) |k2| {
                if (std.mem.eql(u8, k2, "definition")) return self.moduleDefinition(list);
                if (std.mem.eql(u8, k2, "instance")) return self.moduleInstance(list);
            };
            self.current = self.buildModule(list) catch |e| {
                self.current = null;
                // ⚠️ **The same error was a SKIP on every assertion path and a
                // FAILURE here**, because this arm never consulted
                // `isOurLimitation`. So a module using a proposal wazmrt does
                // not target — `UnsupportedProposal`, `UnknownInstr` — was
                // reported as a defect, and 14 of the corpus's 104 "failures"
                // were that inconsistency rather than anything wrong.
                //
                // A gap is not a defect and it is not a pass either: banking it
                // as a pass is the green-washing `isOurLimitation`'s comment was
                // written after. It is a SKIP, scored the same way here as
                // everywhere else.
                if (isOurLimitation(e)) {
                    self.summary.skipped += 1;
                    return;
                }
                self.fail("module failed to build: {s}", .{@errorName(e)});
                return;
            };
            // Track by textual `$name` (`(module $M …)`) for later `$M` references.
            if (self.current) |inst| if (list.len > 1 and isId(list[1]))
                try self.module_names.put(self.a, list[1].atom, inst);
        }
    }

    /// §6.6.13 — **the `(module …)` wrapper may be omitted when the script IS a single module.**
    /// `inline-module.wast` is the whole test and it is one line: `(func) (memory 0) (func
    /// (export "f"))`. The dispatcher above saw three commands named `func`, `memory` and `func`,
    /// recognised none of them, and banked three skips.
    ///
    /// ⚠️ **The trigger is "EVERY top-level form is a module field", not "the first one is not a
    /// command", and the difference is a fail-safe.** Keying on the first form would make any
    /// future command keyword this runner does not know turn its whole script into a bogus module
    /// — a file of assertions silently reinterpreted as one malformed module. Requiring all of
    /// them means an unrecognised form leaves the script on the ordinary path, where it is scored
    /// as the skip it always was. **When a heuristic decides how to read an entire file, pick the
    /// direction whose failure is a no-op.**
    fn isInlineModule(forms: []const Sexpr) bool {
        if (forms.len == 0) return false;
        for (forms) |f| {
            const kw = f.keyword() orelse return false;
            var ok = false;
            for ([_][]const u8{
                "type", "import", "func",  "table", "memory", "global",
                "export", "start", "elem", "data",  "rec",    "tag",
            }) |field| {
                if (std.mem.eql(u8, kw, field)) ok = true;
            }
            if (!ok) return false;
        }
        return true;
    }

    /// Run a script that is one abbreviated module: synthesise the wrapper and hand it to the
    /// ordinary module path, so the era gate, the `isOurLimitation` scoring and the `$name`
    /// tracking are the same code rather than the same intent.
    fn inlineModule(self: *Runner, fields: []const Sexpr) Error!void {
        const list = try self.a.alloc(Sexpr, fields.len + 1);
        list[0] = .{ .atom = "module" };
        @memcpy(list[1..], fields);
        try self.moduleCommand(list);
    }

    /// `(module definition $M <fields>)` — assemble and remember, WITHOUT
    /// instantiating. It does not become `current`: a definition is not an
    /// instance, and treating it as one is what makes "instantiation is
    /// generative" untestable.
    fn moduleDefinition(self: *Runner, list: []const Sexpr) Error!void {
        // Re-shape to a plain `(module <fields>)` for the assembler: drop the
        // `definition` keyword and the `$M`, keep everything after.
        var i: usize = 2;
        const name: ?[]const u8 = if (i < list.len and isId(list[i])) blk: {
            defer i += 1;
            break :blk list[i].atom;
        } else null;
        var form: std.ArrayList(Sexpr) = .empty;
        try form.append(self.a, list[0]); // "module"
        try form.appendSlice(self.a, list[i..]);
        const bin = self.moduleBinary(form.items) catch |e| {
            self.fail("module definition failed to assemble: {s}", .{@errorName(e)});
            return;
        };
        if (name) |n| try self.definitions.put(self.a, n, bin);
    }

    /// `(module instance $I $M)` — instantiate the definition named `$M` afresh.
    /// Each call allocates its own globals/tables/memories, which is precisely
    /// the property `instance.wast` is checking.
    fn moduleInstance(self: *Runner, list: []const Sexpr) Error!void {
        var i: usize = 2;
        const name: ?[]const u8 = if (i < list.len and isId(list[i])) blk: {
            defer i += 1;
            break :blk list[i].atom;
        } else null;
        const def_id = if (i < list.len and isId(list[i])) list[i].atom else {
            self.fail("module instance: no definition named", .{});
            return;
        };
        const bin = self.definitions.get(def_id) orelse {
            self.fail("module instance: no definition '{s}'", .{def_id});
            return;
        };
        const inst = self.instantiateBinary(bin) catch |e| {
            self.current = null;
            self.fail("module failed to build: {s}", .{@errorName(e)});
            return;
        };
        self.current = inst;
        if (name) |n| try self.module_names.put(self.a, n, inst);
    }

    fn buildModule(self: *Runner, form: []const Sexpr) !*interp.Instance {
        return self.instantiateBinary(try self.moduleBinary(form));
    }

    /// Validate under this script's era feature set (`featuresForPath`).
    ///
    /// 🔑 **The ONLY validation entry point in this file.** Both the positive path
    /// (`instantiateBinary`) and the negative one (`tryBuild`) call it, because the two must answer
    /// the SAME question — `capi.zig` states the rule for the C ABI and it holds just as hard here:
    /// a runner whose `assert_invalid` path gates while its `(module …)` path does not would report
    /// a module both valid and invalid within one file.
    ///
    /// ⚠️ The gate runs BEFORE type validation, so the refusal names the proposal rather than
    /// surfacing as some type error deep inside a feature this era never had. 🆕 **F1r moved that
    /// gate INSIDE `validateWith`,** so this is now a single call — and the ordering it relied on
    /// is a property of the callee rather than of every caller remembering it.
    fn validateEra(self: *Runner, m: *const Module) !void {
        try validateWith(self.a, m, self.features);
    }

    /// Decode, validate, link and instantiate a module binary. Shared by
    /// `(module …)` and `(module instance …)`, which differ only in where the
    /// bytes come from — each call builds a FRESH instance, so two instances of
    /// one definition share nothing.
    fn instantiateBinary(self: *Runner, bin: []const u8) !*interp.Instance {
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try self.validateEra(m);
        // Allocated first, then instantiated IN PLACE: the instance's address is
        // baked into every funcref its element segments and global initializers
        // create, so it cannot be built somewhere else and moved here.
        const inst = try self.a.create(interp.Instance);
        try inst.instantiateWithImports(self.a, m, try self.resolveImports(m));
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
        var gs: std.ArrayList(*interp.Instance.Global) = .empty;
        var ms: std.ArrayList(*interp.Instance.Memory) = .empty;
        var ts: std.ArrayList(*interp.Instance.Table) = .empty;
        var tgs: std.ArrayList(u64) = .empty;
        // One matcher per link: its memo is keyed by module pointer, and every
        // module it names is alive for exactly this long.
        var tm: typematch.Ctx = .init(self.a);
        defer tm.deinit();
        for (m.imports) |imp| switch (imp.type) {
            .func => try fs.append(self.a, try self.resolveFuncImport(&tm, m, imp)),
            .global => |want| try gs.append(self.a, try self.resolveGlobalImport(&tm, m, imp, want)),
            .memory => |want| try ms.append(self.a, try self.resolveMemoryImport(imp.module, imp.name, want)),
            .table => |want| try ts.append(self.a, try self.resolveTableImport(&tm, m, imp, want)),
            // An imported tag needs no host backing — it is just a local identity
            // in this module's tag index space (EH proposal) — but its TYPE still
            // has to match the provider's, and that went unchecked entirely. A tag
            // carries the payload of every exception thrown with it, so a
            // mismatched link hands the catcher values it will read as the wrong
            // types.
            .tag => try tgs.append(self.a, try self.resolveTagImport(&tm, m, imp)),
        };
        return .{ .funcs = fs.items, .globals = gs.items, .memories = ms.items, .tables = ts.items, .tags = tgs.items, .store = self.store };
    }

    fn resolveFuncImport(self: *Runner, tm: *typematch.Ctx, m: *const Module, imp: Module.Import) !HostFunc {
        if (std.mem.eql(u8, imp.module, "spectest")) {
            const got = spectestFuncType(imp.name) orelse return error.UnresolvedImport;
            if (!abstractFuncTypeEq(got, imp.type.func)) return error.IncompatibleImportType;
            return .{ .native = spectestNoop };
        }
        const want_ti = imp.type_index orelse return error.IncompatibleImportType;
        if (self.modules.get(imp.module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .func and std.mem.eql(u8, e.name, imp.name)) {
                    // Match by TYPE INDEX in each module, not by the two expanded
                    // signatures: a `(ref $t)` inside a signature is a module-local
                    // index, so comparing the signatures compared numbers that mean
                    // different things on each side — rejecting good links and, worse,
                    // accepting bad ones whenever two unrelated types happened to sit
                    // at the same index. See `typematch.zig`.
                    // ⚠️ **Resolve to the DEFINING instance before reading the type.**
                    // An export may be a function the exporter itself IMPORTED, and an
                    // import may legally name a SUPERTYPE — so the re-exporter's declared
                    // type is not the function's type. Reading it there refused
                    // `(func (exact (type $sub)))` imported from a module that had taken
                    // the same function inexactly as `$super`, which is
                    // `exact-func-import.wast`'s last assertion. D3 fixed the RUN-time
                    // half of this defect; `definingFuncAt` is that walk, shared rather
                    // than copied.
                    //
                    // A NATIVE host function has no defining wasm module, so it falls back
                    // to what the exporter declared — which is all that exists for it.
                    const site = interp.Instance.definingFuncAt(inst, e.index);
                    const src_mod = if (site) |s| s.inst.module else inst.module;
                    const src_idx = if (site) |s| s.index else e.index;
                    const got_ti = src_mod.funcTypeIndex(src_idx) orelse return error.IncompatibleImportType;
                    // An EXACT import demands the type itself; a plain one accepts a subtype.
                    const ok = if (imp.exact)
                        try tm.funcImportExactOk(src_mod, got_ti, m, want_ti)
                    else
                        try tm.funcImportOk(src_mod, got_ti, m, want_ti);
                    if (!ok) return error.IncompatibleImportType;
                    return .{ .wasm = .{ .instance = inst, .func_index = e.index } };
                }
            }
        }
        return error.UnresolvedImport;
    }

    /// Tag imports match by type EQUIVALENCE, not subtyping: a tag names the exact
    /// payload shape both sides must agree on, and there is no variance that keeps
    /// a throw and its catch reading the same values.
    ///
    /// Returns the provider's tag IDENTITY, which the importer adopts. It used to
    /// return nothing — a tag import was "just a local identity in this module's
    /// tag index space" — so importing one tag twice produced two identities that
    /// did not match each other, and an exception thrown with one was not caught
    /// by a handler naming the other (`instance.wast`).
    fn resolveTagImport(self: *Runner, tm: *typematch.Ctx, m: *const Module, imp: Module.Import) !u64 {
        const want_ti = imp.type_index orelse return error.IncompatibleImportType;
        if (self.modules.get(imp.module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .tag and std.mem.eql(u8, e.name, imp.name)) {
                    const got_ti = inst.module.tagTypeIndex(e.index) orelse return error.IncompatibleImportType;
                    if (!try tm.tagImportOk(inst.module, got_ti, m, want_ti)) return error.IncompatibleImportType;
                    return inst.tagId(e.index);
                }
            }
        }
        return error.UnresolvedImport;
    }

    fn resolveGlobalImport(self: *Runner, tm: *typematch.Ctx, m: *const Module, imp: Module.Import, want: Module.GlobalType) !*interp.Instance.Global {
        if (std.mem.eql(u8, imp.module, "spectest")) {
            const gt = spectestGlobalType(imp.name) orelse return error.UnresolvedImport;
            if (gt.content != want.content or gt.mutable != want.mutable) return error.IncompatibleImportType;
            return self.spectestGlobalCell(imp.name, spectestGlobal(imp.module, imp.name).?);
        }
        if (self.modules.get(imp.module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .global and std.mem.eql(u8, e.name, imp.name)) {
                    if (!try tm.globalImportOk(inst.module, e.type.global, m, want)) return error.IncompatibleImportType;
                    return inst.globals[e.index];
                }
            }
        }
        return error.UnresolvedImport;
    }

    /// A cell holding a `spectest` global's constant value. An imported global is
    /// a borrowed CELL now, not a copied value, so the runner has to own storage
    /// for the host-side constants that lives as long as any importer. They are
    /// immutable, so one cell per name is shared.
    fn spectestGlobalCell(self: *Runner, name: []const u8, v: Value) !*interp.Instance.Global {
        if (self.spectest_globals.get(name)) |g| return g;
        const g = try self.a.create(interp.Instance.Global);
        g.* = .{ .value = v };
        try self.spectest_globals.put(self.a, name, g);
        return g;
    }

    fn resolveMemoryImport(self: *Runner, module: []const u8, name: []const u8, want: Module.MemoryType) !*interp.Instance.Memory {
        if (std.mem.eql(u8, module, "spectest") and std.mem.eql(u8, name, "memory")) {
            if (!limitsFit(.{ .min = 1, .max = 2 }, want.limits)) return error.IncompatibleImportType;
            return self.spectestMemory();
        }
        // `spectest.shared_memory` (threads). `limitsFit` already compares the
        // `shared` flag, so declaring it here is all three assertions:
        // `(memory 1 2 shared)` links, `(memory 1 2)` against it does not, and
        // `(memory 1 2 shared)` against plain `spectest.memory` does not either.
        if (std.mem.eql(u8, module, "spectest") and std.mem.eql(u8, name, "shared_memory")) {
            if (!limitsFit(.{ .min = 1, .max = 2, .shared = true }, want.limits)) return error.IncompatibleImportType;
            return self.spectestSharedMemory();
        }
        if (self.modules.get(module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .memory and std.mem.eql(u8, e.name, name)) {
                    // The EXPORT names a specific memory index (multi-memory), not
                    // necessarily 0 — `memory0()` here linked every imported memory
                    // to the exporter's first one, so `memory.size $mem2` read the
                    // wrong memory.
                    if (e.index >= inst.memories.len) return error.UnresolvedImport;
                    const mem = inst.memories[e.index];
                    // ⚠️ **The limits to match are the INSTANCE's, not the
                    // module's.** §7.2's `mem_type(store, a)` reads the minimum
                    // off the memory's CURRENT size (`|data| / 64Ki`), so a
                    // memory declared `(memory 1)` that has since grown to 2
                    // pages satisfies an `(import … (memory 2))`. Comparing the
                    // DECLARED minimum refused it — and then the module that
                    // would have exported it never registered, so the next two
                    // modules failed as `UnresolvedImport` behind it.
                    // ⚠️ **`mem.page_size`, NOT the 64 KiB constant** — §7.2's `|data| / page_size`
                    // is in the memory's OWN pages, and the page size is part of the type that
                    // `limitsFit` compares. Built from the constant, this reported every memory
                    // as 64 KiB-paged: a 1-byte-paged export then failed to satisfy its matching
                    // import (both directions of the spec's link test were wrong at once, one
                    // refusing a legal link and one accepting an illegal one).
                    if (!limitsFit(.{
                        .min = mem.bytes.len / mem.page_size,
                        .max = mem.max,
                        .shared = mem.shared,
                        .is64 = mem.is64,
                        .page_size_log2 = @intCast(std.math.log2_int(u64, mem.page_size)),
                    }, want.limits)) return error.IncompatibleImportType;
                    return mem;
                }
            }
        }
        return error.UnresolvedImport;
    }

    fn resolveTableImport(self: *Runner, tm: *typematch.Ctx, m: *const Module, imp: Module.Import, want: Module.TableType) !*interp.Instance.Table {
        if (std.mem.eql(u8, imp.module, "spectest") and std.mem.eql(u8, imp.name, "table")) {
            if (want.element != .funcref or !limitsFit(.{ .min = 10, .max = 20 }, want.limits)) return error.IncompatibleImportType;
            return self.spectestTable();
        }
        // `spectest.table64` — the table64 proposal's 64-bit twin. `limitsFit`
        // already refuses a cross-width match (the index type is part of the
        // type, not a detail of the limits), so one entry gives both directions.
        if (std.mem.eql(u8, imp.module, "spectest") and std.mem.eql(u8, imp.name, "table64")) {
            if (want.element != .funcref or !limitsFit(.{ .min = 10, .max = 20, .is64 = true }, want.limits)) return error.IncompatibleImportType;
            return self.spectestTable64();
        }
        if (self.modules.get(imp.module)) |inst| {
            for (inst.module.exports) |e| {
                if (e.type == .table and std.mem.eql(u8, e.name, imp.name)) {
                    const tt = e.type.table;
                    if (!try tm.tableElemOk(inst.module, tt.element, m, want.element)) return error.IncompatibleImportType;
                    if (e.index >= inst.tables.len) continue;
                    const tbl = inst.tables[e.index];
                    // Same rule as memories: §7.2's `table_type(store, a)` takes
                    // the minimum from the table's CURRENT length, so a table
                    // grown past its declared minimum satisfies an import that
                    // asks for the larger size. The element type still comes from
                    // the declared type — growing does not change it.
                    if (!limitsFit(.{
                        .min = tbl.entries.len,
                        .max = tbl.max,
                        .is64 = tbl.is64,
                    }, want.limits)) return error.IncompatibleImportType;
                    return tbl;
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

    /// `spectest.shared_memory` — same shape as `spectestMemory`, `shared` set.
    /// Its `bytes` are page-allocator owned for the same `memory.grow` reason.
    fn spectestSharedMemory(self: *Runner) !*interp.Instance.Memory {
        if (self.spectest_shared_memory) |m| return m;
        const buf = try interp.allocGuestMemory(interp.page_size);
        const m = try self.a.create(interp.Instance.Memory);
        m.* = .{ .bytes = buf, .max = 2, .shared = true };
        self.spectest_shared_memory = m;
        return m;
    }

    /// `spectest.table64` — same 10/20 funcref shape, 64-bit index type.
    fn spectestTable64(self: *Runner) !*interp.Instance.Table {
        if (self.spectest_table64) |t| return t;
        const entries = try self.a.alloc(Value, 10);
        @memset(entries, null_ref);
        const t = try self.a.create(interp.Instance.Table);
        t.* = .{ .entries = entries, .max = 20, .is64 = true, .store = self.store };
        self.spectest_table64 = t;
        return t;
    }

    fn spectestTable(self: *Runner) !*interp.Instance.Table {
        if (self.spectest_table) |t| return t;
        const entries = try self.a.alloc(Value, 10); // 10 funcref
        @memset(entries, null_ref);
        const t = try self.a.create(interp.Instance.Table);
        t.* = .{ .entries = entries, .max = 20, .store = self.store };
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
                // `(module quote "…" …)` — the module given as SOURCE TEXT, in one
                // or more string literals. The lexer has already resolved escapes
                // to bytes, so `"\80"` really is byte 0x80 here; that is the whole
                // point for the UTF-8 corpus, whose names must reach the decoder
                // with their invalid bytes intact.
                //
                // ⚠️ **This single `BadCommand` was suppressing 1,291 assertions**
                // — more than half of every skip in the suite — because a `quote`
                // module is how the spec tests anything about *text*: malformed
                // literals, bad tokens, invalid names. `utf8-invalid-encoding.wast`
                // is 176 of them, which is why UTF-8 name validation could be
                // recorded as fixed and be checked by nothing (R8).
                if (std.mem.eql(u8, kw, "quote")) {
                    var text: std.ArrayList(u8) = .empty;
                    for (form[i + 1 ..]) |it| switch (it) {
                        // Pieces are separate source lines. A newline (not a space)
                        // is the safe join: a piece may end in a line comment, and
                        // `";; …" "(func)"` concatenated on one line would swallow
                        // the next piece.
                        .string => |s| {
                            try text.appendSlice(self.a, s);
                            try text.append(self.a, '\n');
                        },
                        else => {},
                    };
                    return wat.assemble(self.a, try wrapModuleText(self.a, text.items));
                }
                return error.BadCommand;
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
                v[0] = inst.globals[e.index].value;
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
        // An `(either …)` wrapper contributes the slots of its alternatives, which
        // all share one type — so measure the shape from the first alternative.
        var want_slots: usize = 0;
        for (expected) |exp_form| {
            const alts = eitherAlts(exp_form);
            want_slots += if (isV128Form(if (alts.len != 0) alts[0] else exp_form)) 2 else 1;
        }
        if (results.len != want_slots) {
            self.fail("assert_return: arity {d} != expected {d}", .{ results.len, want_slots });
            return;
        }
        const action_name: []const u8 = actionName(form[1]);
        var ri: usize = 0;
        var solo: [1]Sexpr = undefined; // backing for the not-an-`either` case
        for (expected) |exp_form| {
            var alts = eitherAlts(exp_form);
            if (alts.len == 0) {
                solo[0] = exp_form;
                alts = solo[0..1];
            }
            // Any alternative matching is a pass — that is what `either` means.
            if (isV128Form(alts[0])) {
                const lo = results[ri];
                const hi = results[ri + 1];
                ri += 2;
                const got: u128 = (@as(u128, hi) << 64) | lo;
                var ok = false;
                for (alts) |alt| {
                    if (try v128Matches(got, alt.asList() orelse continue)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) {
                    self.fail("assert_return \"{s}\": v128 mismatch (got 0x{x})", .{ action_name, got });
                    return;
                }
            } else {
                const got = results[ri];
                ri += 1;
                var ok = false;
                for (alts) |alt| {
                    if (try self.matches(got, alt)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) {
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
    /// ⚠️ The result is `interp.hostRefValue`-TAGGED, not a bare index. A bare
    /// index is exactly a GC heap index, so `any.convert_extern` (identity) used
    /// to hand `ref.test`/`ref.cast` a value that read as `gc_heap[i]` — a host
    /// reference answering yes to `structref` and yielding another object's
    /// fields. The tag keeps the two spaces disjoint.
    fn internExtern(self: *Runner, payload: u64) Error!Value {
        for (self.extern_pool.items, 0..) |p, i| if (p == payload) return interp.hostRefValue(i);
        const idx = self.extern_pool.items.len;
        try self.extern_pool.append(self.a, payload);
        return interp.hostRefValue(idx);
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
        // `ref.extern N` and `ref.host N` are the SAME value seen from the two
        // hierarchies — `extern.convert_any`/`any.convert_extern` are identity —
        // so they intern identically. `extern.wast` pins the pair directly:
        // `(invoke "internalize" (ref.extern 1))` must equal `(ref.host 1)`, and
        // `(invoke "externalize" (ref.host 2))` must equal `(ref.extern 2)`.
        // `ref.host` was missing here, so that second assertion could not even
        // build its ARGUMENT and reported `unexpected trap BadValue`.
        if (std.mem.eql(u8, kw, "ref.extern") or std.mem.eql(u8, kw, "ref.host")) {
            if (list.len < 2) return self.internExtern(0); // bare form — any non-null
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
        // `ref.host N` is `ref.extern N` seen from the `any` side, so a payload
        // makes it an EXACT match too — `(ref.host 1)` in `extern.wast` asserts
        // the round trip preserved the identity, which "any non-null" would not
        // have checked at all.
        if (std.mem.eql(u8, kw, "ref.extern") or (std.mem.eql(u8, kw, "ref.host") and list.len >= 2)) {
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

    /// `assert_exception (invoke …)` — the action must terminate with an UNCAUGHT
    /// exception (EH proposal). Distinct from `assert_trap`: any runtime trap
    /// satisfies that, but only `UncaughtException` satisfies this, so a module
    /// that traps for an unrelated reason is a failure and not a pass.
    ///
    /// ⚠️ 41 of these were being skipped as an unknown command keyword — in
    /// `throw.wast`, `throw_ref.wast`, `try_table.wast` and the three legacy EH
    /// files, i.e. exactly the assertions that check exceptions actually ESCAPE.
    /// The EH implementation was carrying that property untested.
    fn assertException(self: *Runner, form: []const Sexpr) Error!void {
        if (form.len < 2) return self.fail("assert_exception: missing action", .{});
        if (self.runAction(form[1])) |_| {
            self.fail("assert_exception: expected an exception, got a result", .{});
        } else |e| {
            if (e == error.NoTarget) {
                self.summary.skipped += 1;
            } else if (e == error.UncaughtException) {
                self.summary.passed += 1;
            } else {
                self.fail("assert_exception: got {s}", .{@errorName(e)});
            }
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
            // ⚠️ `error.UnknownInstr` USED TO BE ON THIS LIST and was removed 2026-08-17. It meant
            // "the assembler doesn't know this mnemonic", which conflated two opposite things:
            // a mnemonic that exists in NO proposal (a genuine malformation — a verdict we may
            // give) and one from a proposal we do not target (our gap). `wat.zig`'s
            // `untargetedProposalMnemonic` now splits them at the point where the difference is
            // actually known, routing our gaps to `UnsupportedInstr` below. Conflating them cost
            // ~244 correct rejections in CORE files, banked as skips — `load.wast` asserts
            // `(i32.load32 …)` is malformed, which it is: that mnemonic exists in no wasm
            // proposal, and answering "unknown" was answering CORRECTLY.
            error.UnsupportedInstr,
            // Recognised syntax from a proposal we do not target (`pagesize`).
            // The module may be valid under that proposal, so refusing it is our
            // gap — banking these as passes is exactly the green-washing the
            // comment above describes.
            error.UnsupportedProposal,
            error.UnknownIdentifier,
            error.UnsupportedOpcode, // ambiguous → treat as ours
            error.UnsupportedInstruction,
            error.OutOfMemory, // a resource failure is not a verdict
            => true,
            else => false,
        };
    }

    /// Decode + validate a module form without instantiating or recording it.
    ///
    /// Goes through `validateEra` so an `assert_invalid` in a proposal directory is judged by that
    /// directory's era — the reason the threads snapshot's "multiple memories"/"multiple tables"
    /// assertions pass rather than being written off as deviations.
    fn tryBuild(self: *Runner, form: []const Sexpr) !void {
        const bin = try self.moduleBinary(form);
        const m = try self.a.create(Module);
        m.* = try Module.decode(self.a, bin);
        try self.validateEra(m);
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
        } else |e| if (isLinkError(e)) {
            self.summary.passed += 1;
        } else if (isOurLimitation(e)) {
            // We never got as far as linking, so we have no verdict to give.
            // `assertRejected` already drew this line; this arm did not, and
            // charged our own gaps as conformance failures — `memory_max.wast`
            // reported two where one was simply `(pagesize …)`, syntax we refuse
            // by design. NOTE the order: `isLinkError` is asked FIRST and this
            // list stays narrow, so a real wrong-STAGE rejection (T5's
            // `InvalidLimits` at decode where the spec wants a link failure)
            // still lands in `fail` below where it belongs.
            self.summary.skipped += 1;
        } else {
            self.fail("assert_unlinkable: non-link error {s}", .{@errorName(e)});
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
        error.UnalignedAtomic, // atomic op on a misaligned address (threads)
        error.ExpectedSharedMemory, // atomic.wait on a non-shared memory (threads)
        error.TableOutOfBounds,
        error.UninitializedElement,
        error.IndirectTypeMismatch,
        error.NullReference,
        error.NullDescriptor, // "null descriptor reference" (custom-descriptors)
        error.DescriptorCastFailure, // "descriptor cast failure" (custom-descriptors)
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

/// Function-type equality by RAW value type, valid only where neither side can
/// contain a concrete `(ref $t)` — i.e. the `spectest` host signatures below,
/// which are numeric throughout and belong to no module.
///
/// Everything else goes through `typematch.zig`. A concrete reference carries a
/// module-local type index, so raw comparison across a module boundary compares
/// two unrelated numbering schemes.
fn abstractFuncTypeEq(a: Module.FuncType, b: Module.FuncType) bool {
    return abstractValTypesEq(a.params, b.params) and abstractValTypesEq(a.results, b.results);
}
fn abstractValTypesEq(a: []const types.ValType, b: []const types.ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
/// True if a provided limits range satisfies (is a subtype of) the required one:
/// provided.min ≥ required.min and, if required is bounded, provided is bounded
/// no higher (§4.5.3 limits matching).
fn limitsFit(provided: Module.Limits, required: Module.Limits) bool {
    // The INDEX TYPE is part of the type, not a detail of the limits: a 32-bit
    // table/memory cannot satisfy a 64-bit import or vice versa, because every
    // index operand changes width. We compared only min/max, so all eight
    // cross-width imports in `memory64-imports.wast` linked when the spec
    // requires them unlinkable — and the importer would then have driven the
    // object with operands of the wrong type.
    if (provided.is64 != required.is64) return false;
    if (provided.shared != required.shared) return false;
    // PAGE SIZE is part of the type for the same reason the index type is, and the failure mode
    // is worse: `min`/`max` are counted IN pages, so two memories with different page sizes have
    // limits that are not even commensurable — comparing their numbers below would be comparing
    // bytes to 64 KiB blocks. Exact equality, not a subtype relation: a 1-byte-page memory does
    // not "satisfy" a 64 KiB-page import at any size. (§4.5.3, custom-page-sizes.)
    if (provided.page_size_log2 != required.page_size_log2) return false;
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
/// The alternatives an expected-result form admits, or empty if it is not an
/// `(either …)`.
///
/// `(either e1 e2 …)` is how the spec suite writes a result the standard leaves
/// **implementation-defined** — the relaxed-SIMD instructions, where fused vs
/// unfused multiply-add, NaN propagation and the sign of zero in `min`/`max` are
/// all permitted to differ. Any listed alternative is a CORRECT answer.
///
/// We did not parse it, so `assert_return` counted the wrapper as one expected
/// value and reported `arity 4 != expected 1` — 32 assertions across six relaxed
/// SIMD files, none of which had ever actually compared anything. That is the
/// mirror of green-washing: our own gap charged as a wazmrt failure, and it
/// hides whether those instructions are right or wrong.
fn eitherAlts(form: Sexpr) []const Sexpr {
    const list = form.asList() orelse return &.{};
    if (list.len < 2) return &.{};
    const kw = list[0].asAtom() orelse return &.{};
    if (!std.mem.eql(u8, kw, "either")) return &.{};
    return list[1..];
}

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
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "a GC reference crossing an instance boundary names its OWN object" {
    // ⚠️ Before this, a GC reference was a bare index into the READER's
    // per-instance `gc_heap`, so B read its own object at A's index: `ref.cast`
    // SUCCEEDED and `struct.get` returned 222 instead of 111. `refMatches` could
    // not notice — it took the type index from that same wrong entry and checked
    // it against B's own types, so it was self-consistent and blind. R2 fixed
    // exactly this for funcrefs ("a reference names an ENTITY, not an index");
    // only funcrefs had been converted.
    //
    // The concrete cross-module cast answers CORRECTLY (111, not a refusal)
    // because the store-wide `TypeRegistry` interns both modules' rec groups at
    // instantiation: `$ta` and `$tb` are structurally identical, so they land on
    // one canonical id and the comparison is an integer compare.
    //
    // Kept in-repo as well as in `tests/gc_cross_instance_repro.wast` because the
    // `.wast` corpus lives on removable media and cannot gate a commit — and
    // because the spec suite crosses GC references between instances almost
    // nowhere, which is why nothing caught this for months.
    const src =
        \\(module $A (type $ta (struct (field i32)))
        \\  (global (export "g") anyref (struct.new $ta (i32.const 111))))
        \\(register "A" $A)
        \\(module $B (type $tb (struct (field i32)))
        \\  (global $fromA (import "A" "g") anyref)
        \\  (global $mine (mut anyref) (ref.null any))
        \\  (func (export "seed") (global.set $mine (struct.new $tb (i32.const 222))))
        \\  (func (export "isStruct") (result i32) (ref.test (ref struct) (global.get $fromA)))
        \\  (func (export "isArray") (result i32) (ref.test (ref array) (global.get $fromA)))
        \\  (func (export "ownRead") (result i32)
        \\    (struct.get $tb 0 (ref.cast (ref $tb) (global.get $mine))))
        \\  (func (export "concreteTest") (result i32) (ref.test (ref $tb) (global.get $fromA)))
        \\  (func (export "concreteRead") (result i32)
        \\    (struct.get $tb 0 (ref.cast (ref $tb) (global.get $fromA)))))
        \\(assert_return (invoke $B "seed"))
        \\(assert_return (invoke $B "ownRead") (i32.const 222))
        \\(assert_return (invoke $B "isStruct") (i32.const 1))
        \\(assert_return (invoke $B "isArray") (i32.const 0))
        \\(assert_return (invoke $B "concreteTest") (i32.const 1))
        \\(assert_return (invoke $B "concreteRead") (i32.const 111))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 6), s.passed);

    // ⚠️ The registry must still REFUSE a structurally different type, or it has
    // replaced a false negative with a false POSITIVE — R1's failure mode, and
    // the dangerous direction. A's object is `(struct i32)`; B's index 0 is a
    // `(struct i64)` and its index 1 is the match, so the two answers must
    // differ. (This is the shape that catches wasmrt today: it reads A's type
    // index against B's table and answers 1 / 0 — both wrong.)
    const negative =
        \\(module $A (type $ta (struct (field i32)))
        \\  (global (export "g") anyref (struct.new $ta (i32.const 111))))
        \\(register "A" $A)
        \\(module $B
        \\  (type $b0 (struct (field i64)))
        \\  (type $b1 (struct (field i32)))
        \\  (global $fromA (import "A" "g") anyref)
        \\  (func (export "wrong") (result i32) (ref.test (ref $b0) (global.get $fromA)))
        \\  (func (export "right") (result i32) (ref.test (ref $b1) (global.get $fromA))))
        \\(assert_return (invoke $B "wrong") (i32.const 0))
        \\(assert_return (invoke $B "right") (i32.const 1))
        \\(module $C
        \\  (type $base (sub (struct (field i32))))
        \\  (type $derived (sub $base (struct (field i32) (field i32))))
        \\  (global (export "d") anyref (struct.new $derived (i32.const 7) (i32.const 8))))
        \\(register "C" $C)
        \\(module $D
        \\  (type $base2 (sub (struct (field i32))))
        \\  (global $fromC (import "C" "d") anyref)
        \\  (func (export "isBase") (result i32) (ref.test (ref $base2) (global.get $fromC))))
        \\(assert_return (invoke $D "isBase") (i32.const 1))
    ;
    const s2 = try runScript(std.testing.allocator, negative, null);
    try std.testing.expectEqual(@as(usize, 0), s2.failed);
    try std.testing.expectEqual(@as(usize, 3), s2.passed);
}

test "L1: an import matches a memory/table's CURRENT size, not its declared minimum" {
    // §7.2's `mem_type`/`table_type` read the minimum off the live instance, so a
    // memory declared `(memory 1)` that has GROWN to 2 pages satisfies an
    // `(import … (memory 2))`. Comparing the declared minimum refused it — and
    // then this module never registered either, so anything importing from it
    // failed as `UnresolvedImport` behind the first error.
    const src =
        \\(module $M (memory (export "mem") 1) (table (export "tab") 1 funcref)
        \\  (func (export "grow-mem") (result i32) (memory.grow (i32.const 1)))
        \\  (func (export "grow-tab") (result i32) (table.grow (ref.null func) (i32.const 1))))
        \\(register "grown" $M)
        \\(assert_return (invoke $M "grow-mem") (i32.const 1))
        \\(assert_return (invoke $M "grow-tab") (i32.const 1))
        \\(module $N (memory (export "mem2") (import "grown" "mem") 2)
        \\  (table (import "grown" "tab") 2 funcref)
        \\  (func (export "size") (result i32) (memory.size)))
        \\(register "grown2" $N)
        \\(assert_return (invoke $N "size") (i32.const 2))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 3), s.passed);
    // …and the rule does not go the other way: asking for MORE than the current
    // size is still incompatible.
    const too_big =
        \\(module $M (memory (export "mem") 1))
        \\(register "g" $M)
        \\(module (memory (import "g" "mem") 2))
    ;
    var s2 = try runScript(std.testing.allocator, too_big, null);
    defer s2.deinit(std.testing.allocator); // failure messages are caller-owned
    try std.testing.expectEqual(@as(usize, 1), s2.failed);
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
        var s = runScript(std.testing.allocator, src, null) catch continue;
        s.deinit(std.testing.allocator);
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
    const s = try runScript(std.testing.allocator, ok, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "detects a wrong expected result" {
    const src =
        \\(module (func (export "one") (result i32) (i32.const 1)))
        \\(assert_return (invoke "one") (i32.const 2))
    ;
    var s = try runScript(std.testing.allocator, src, null);
    defer s.deinit(std.testing.allocator); // failure messages are caller-owned
    try std.testing.expectEqual(@as(usize, 0), s.passed);
    try std.testing.expectEqual(@as(usize, 1), s.failed);
    // The message must be READABLE here — it used to point into an arena
    // `runScript` had already freed, so both callers printed freed memory.
    try std.testing.expect(std.mem.indexOf(u8, s.first_failure.?, "one") != null);
}

test "float results incl. nan:canonical" {
    const src =
        \\(module
        \\  (func (export "fadd") (param f64 f64) (result f64) (f64.add (local.get 0) (local.get 1)))
        \\  (func (export "fnan") (result f64) (f64.div (f64.const 0) (f64.const 0))))
        \\(assert_return (invoke "fadd" (f64.const 1.5) (f64.const 2.25)) (f64.const 3.75))
        \\(assert_return (invoke "fnan") (f64.const nan:canonical))
    ;
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

// ---------------------------------------------------------------------------------------
// Era feature sets (F3/F4) — see `featuresForPath`.
//
// ⚠️ These live here rather than only in the corpus because **the `.wast` corpus is on removable
// media and cannot gate a commit** (the same reason the GC cross-instance fix carries an in-repo
// test). A corpus-only proof of this behaviour would be unverifiable on a fresh clone.
// ---------------------------------------------------------------------------------------

test "era policy: the threads snapshot loses multi-memory and multi-table, and NOTHING else" {
    const threads = featuresForPath("testsuite/proposals/threads/imports.wast");
    try std.testing.expect(!threads.has(.multi_memory));
    try std.testing.expect(!threads.has(.multi_table));
    // The rest of the era must survive. `funcref` (reference_types) is the load-bearing one:
    // gating multiple tables via `reference_types` would have broken the very files this policy
    // exists to fix, which is why `multi_table` is its own switch.
    try std.testing.expect(threads.has(.reference_types));
    try std.testing.expect(threads.has(.threads));
    try std.testing.expect(threads.has(.bulk_memory));
    // A coherent set, so it describes a wasm version that actually existed.
    try std.testing.expect(threads.incoherent() == null);

    // Windows separators reach here from the corpus walker.
    const win = featuresForPath("testsuite\\proposals\\threads\\memory.wast");
    try std.testing.expect(!win.has(.multi_table));

    // ⚠️ THE OPT-IN HALF, **and D4 had to qualify it.** The rule was "everything not listed runs
    // unrestricted", so a policy could not leak into directories it knows nothing about. That
    // still holds for every proposal whose era is a RESTRICTION of the merged spec — but
    // custom-descriptors is not one: it RETYPES `br_on_cast`, so the era that lacks it is the
    // merged spec itself, i.e. every other file. It is therefore opt-IN by directory, the only
    // entry that is. Everything else about those paths is still unrestricted.
    const core = featuresForPath("testsuite/memory.wast");
    try std.testing.expect(!core.has(.custom_descriptors));
    try std.testing.expect(core.incoherent() == null); // still a set that describes a real wasm
    for (0..features.count) |i| {
        const f: features.Feature = @enumFromInt(i);
        if (f == .custom_descriptors) continue;
        try std.testing.expect(core.has(f)); // nothing else leaked
    }
    // ...and the proposal's own directory is the one place it IS on.
    const cd = featuresForPath("testsuite/proposals/custom-descriptors/br_on_cast.wast");
    try std.testing.expect(cd.all());
    try std.testing.expect(featuresForPath("testsuite\\proposals\\custom-descriptors\\exact.wast").all());
    // A sibling proposal snapshot predates it, so it stays off there too.
    try std.testing.expect(!featuresForPath("testsuite/proposals/gc/struct.wast").has(.custom_descriptors));
    // An INLINE source has no era to belong to and keeps the permissive default — the unit tests
    // in this repo depend on it, and `runScript`'s required `path` is what makes that deliberate.
    try std.testing.expect(featuresForPath(null).all());
}

test "era policy: custom-descriptors RETYPES br_on_cast, so the same module is judged both ways" {
    // 🔒 **The conflict, written down as a test rather than left to the corpus.** The core
    // testsuite and the proposal snapshot contain the SAME module with opposite verdicts:
    // `br_on_cast 0 eqref anyref` is an upcast, which the GC rule forbids (`rt2 <: rt1`) and
    // custom-descriptors permits (only a shared top type). No single answer satisfies both, so
    // the era decides — and both directions are pinned here, because a rule that is only ever
    // exercised one way is a rule nobody has checked.
    const src = "(module (func (result anyref) (br_on_cast 0 eqref anyref (unreachable))))";
    const relaxed = try runScript(std.testing.allocator, src, "proposals/custom-descriptors/br_on_cast.wast");
    try std.testing.expectEqual(@as(usize, 0), relaxed.failed);

    // Under the merged-spec era the identical text must be REFUSED. `assert_invalid` is how the
    // core file states it, so that is how it is stated here.
    const negative = "(assert_invalid (module (func (result anyref) (br_on_cast 0 eqref anyref (unreachable)))) \"type mismatch\")";
    const strict = try runScript(std.testing.allocator, negative, "br_on_cast.wast");
    try std.testing.expectEqual(@as(usize, 1), strict.passed);
    try std.testing.expectEqual(@as(usize, 0), strict.failed);
}

test "era policy: threads-era assertions pass, and the SAME modules are accepted without it" {
    // The two shapes the snapshot asserts invalid. Under its era both must be REFUSED.
    const src =
        \\(assert_invalid (module (memory 0) (memory 0)) "multiple memories")
        \\(assert_invalid (module (table 10 funcref) (table 10 funcref)) "multiple tables")
    ;
    var era = try runScript(std.testing.allocator, src, "proposals/threads/imports.wast");
    defer era.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), era.passed);
    try std.testing.expectEqual(@as(usize, 0), era.failed);
    try std.testing.expectEqual(@as(usize, 0), era.skipped);

    // 🔒 THE INVERSION, and it is the whole point: with no era policy the very same assertions
    // FAIL, because wazmrt implements both proposals and rightly accepts those modules. If this
    // half ever passes too, the gate has stopped gating and the test above is proving nothing.
    var unrestricted = try runScript(std.testing.allocator, src, null);
    defer unrestricted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unrestricted.passed);
    try std.testing.expectEqual(@as(usize, 2), unrestricted.failed);
}

test "era policy: a positive threads module still runs under the narrowed set" {
    // The regression the roadmap flagged: turning features off can cost PASSES elsewhere in the
    // same file. A single memory, a single table, funcref and atomics must all still work.
    const src =
        \\(module (memory 1 1 shared) (table 2 funcref)
        \\  (func $f (result i32) (i32.const 7))
        \\  (elem (i32.const 0) $f)
        \\  (func (export "call") (result i32) (call_indirect (result i32) (i32.const 0)))
        \\  (func (export "at") (result i32) (i32.atomic.load (i32.const 0))))
        \\(assert_return (invoke "call") (i32.const 7))
        \\(assert_return (invoke "at") (i32.const 0))
    ;
    var s = try runScript(std.testing.allocator, src, "proposals/threads/atomic.wast");
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "atomics: a misaligned access traps; a naturally aligned one does not" {
    const src =
        \\(module (memory 1)
        \\  (func (export "aligned") (result i32) (i32.atomic.load (i32.const 4)))
        \\  (func (export "misaligned") (result i32) (i32.atomic.load (i32.const 3))))
        \\(assert_return (invoke "aligned") (i32.const 0))
        \\(assert_trap (invoke "misaligned") "unaligned atomic")
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "atomics: wait/notify semantics; wait requires shared memory" {
    // On a shared memory: notify wakes 0 (single-threaded), and wait returns 1
    // ("not equal") when the value differs from `expected`. init writes 0xff… so
    // the compared value is non-zero and `expected` 0 mismatches.
    const shared =
        \\(module
        \\  (memory 1 1 shared)
        \\  (func (export "init") (i64.store (i32.const 0) (i64.const 0xffffffffffff)))
        \\  (func (export "notify") (result i32) (memory.atomic.notify (i32.const 0) (i32.const 0)))
        \\  (func (export "wait32") (result i32) (memory.atomic.wait32 (i32.const 0) (i32.const 0) (i64.const 0))))
        \\(invoke "init")
        \\(assert_return (invoke "notify") (i32.const 0))
        \\(assert_return (invoke "wait32") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, shared, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);

    // wait on a NON-shared memory traps.
    const nonshared =
        \\(module (memory 1)
        \\  (func (export "w") (result i32) (memory.atomic.wait32 (i32.const 0) (i32.const 0) (i64.const 0))))
        \\(assert_trap (invoke "w") "expected shared memory")
    ;
    const s2 = try runScript(std.testing.allocator, nonshared, null);
    try std.testing.expectEqual(@as(usize, 1), s2.passed);
    try std.testing.expectEqual(@as(usize, 0), s2.failed);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
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
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "a funcref in a shared table names its own instance, not the caller's index" {
    // A funcref used to be a bare function index, resolved against whatever
    // instance was executing `call_indirect`. $B writes its `$b` (index 1 in
    // $B: the imported `$a` takes index 0) into $A's table at slot 0. Reading
    // that slot from $A then dispatched to *$A's* function 1 — `at`, the very
    // function doing the reading — instead of $B's `$b`.
    //
    // The old answer was not an error, it was 11: plausible, self-consistent,
    // and wrong. Both directions are asserted, because the defect was symmetric
    // — each instance saw its own function through the other's entry.
    const src =
        \\(module $A
        \\  (type $r (func (result i32)))
        \\  (table (export "t") 2 funcref)
        \\  (func (export "a") (type $r) (i32.const 11))
        \\  (func (export "at") (param i32) (result i32)
        \\    (call_indirect (type $r) (local.get 0))))
        \\(register "A" $A)
        \\(module $B
        \\  (type $r (func (result i32)))
        \\  (func $a (import "A" "a") (type $r))
        \\  (table (import "A" "t") 2 funcref)
        \\  (func $b (type $r) (i32.const 22))
        \\  (elem (i32.const 0) $b $a)
        \\  (func (export "bt") (param i32) (result i32)
        \\    (call_indirect (type $r) (local.get 0))))
        \\(assert_return (invoke $A "at" (i32.const 0)) (i32.const 22))
        \\(assert_return (invoke $A "at" (i32.const 1)) (i32.const 11))
        \\(assert_return (invoke $B "bt" (i32.const 0)) (i32.const 22))
        \\(assert_return (invoke $B "bt" (i32.const 1)) (i32.const 11))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "instantiation is generative: two instances of one definition share nothing" {
    // `(module definition …)` / `(module instance …)` — the pair `instance.wast`
    // uses. Neither was implemented, so the file scored 0 passed / 8 failed / 12
    // skipped and the property went unchecked entirely.
    const src =
        \\(module definition $M
        \\  (global (export "g") (mut i32) (i32.const 0))
        \\  (func (export "bump") (result i32)
        \\    (global.set 0 (i32.add (global.get 0) (i32.const 1)))
        \\    (global.get 0)))
        \\(module instance $I1 $M)
        \\(module instance $I2 $M)
        \\(assert_return (invoke $I1 "bump") (i32.const 1))
        \\(assert_return (invoke $I1 "bump") (i32.const 2))
        \\(assert_return (invoke $I2 "bump") (i32.const 1))
        \\(assert_return (get $I1 "g") (i32.const 2))
        \\(assert_return (get $I2 "g") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 5), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "importing one tag twice yields ONE identity, so a throw matches either name" {
    // A tag import used to carry no identity at all — it was "just a local index
    // in this module's tag space" — so importing `A.t` as both $t1 and $t2 gave
    // two indices that never compared equal. `throw $t2` then fell past
    // `catch $t1` into `catch_all`. An exception routed to the wrong handler:
    // the same class as a funcref resolving to the wrong function.
    const src =
        \\(module $A (tag (export "t")))
        \\(register "A" $A)
        \\(module $B
        \\  (tag $t1 (import "A" "t"))
        \\  (tag $t2 (import "A" "t"))
        \\  (func (export "f") (result i32)
        \\    (block $on_t1
        \\      (block $other
        \\        (try_table (catch $t1 $on_t1) (catch_all $other) (throw $t2))
        \\        (unreachable))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1))))
        \\(assert_return (invoke $B "f") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "an element segment's type must be a SUBTYPE of its table's, not the same family" {
    // §3.5.11. The check normalized nullability away, so a nullable `funcref`
    // segment was accepted into a `(ref func)` table — putting nulls in a table
    // whose type promises there are none. A 10th-pass audit raised this and the
    // finding was RETRACTED on a mistaken reading of `ValType.nullable()`; the
    // reading was indeed mistaken and the rule was still wrong.
    //
    // The second module is the other direction and must stay VALID: a funcidx
    // segment has type `(ref func)` (§5.5.12 forms 0-3), which is a subtype of
    // both table types.
    const src =
        \\(assert_invalid
        \\  (module
        \\    (func)
        \\    (table 1 (ref func) (ref.func 0))
        \\    (elem (i32.const 0) funcref (ref.func 0)))
        \\  "type mismatch")
        \\(module
        \\  (func)
        \\  (table 1 (ref func) (ref.func 0))
        \\  (elem (i32.const 0) func 0))
        \\(module
        \\  (func)
        \\  (table 1 funcref)
        \\  (elem (i32.const 0) func 0))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "element segments applied before a failed data segment persist AND stay callable" {
    // §4.5.5 runs element inits before data inits, and entries already written
    // into an imported table survive a later trap. Two defects stacked here:
    //
    //  1. data segments were applied FIRST, so the out-of-bounds data below
    //     aborted before the element segment ran and slot 7 stayed empty;
    //  2. even once it ran, the funcref it wrote named an instance that
    //     instantiation then threw away, so the call resolved to nothing.
    //
    // Both have to be fixed for this to pass, and the second is why the store
    // keeps a failed instance alive rather than tearing it down.
    const src =
        \\(module $A
        \\  (type $r (func (result i32)))
        \\  (table (export "t") 10 funcref)
        \\  (func (export "at") (param i32) (result i32)
        \\    (call_indirect (type $r) (local.get 0))))
        \\(register "A" $A)
        \\(assert_trap
        \\  (module
        \\    (table (import "A" "t") 10 funcref)
        \\    (func $f (result i32) (i32.const 7))
        \\    (elem (i32.const 7) $f)
        \\    (memory 1)
        \\    (data (i32.const 0x10000) "d"))
        \\  "out of bounds memory access")
        \\(assert_return (invoke $A "at" (i32.const 7)) (i32.const 7))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "an imported mutable global is SHARED, not copied at instantiation" {
    // Imported globals were copied by value, so a `(mut i32)` import was a
    // snapshot taken at link time. $B re-exports $A's global; $A then writes 241
    // through its own setter, and the read through $B still returned the old
    // 142 — `linking.wast`'s `Mg.mut_glob`. The value was stale, not garbage,
    // which is why it never looked like a bug from inside $B.
    const src =
        \\(module $A
        \\  (global (export "g") (mut i32) (i32.const 142))
        \\  (func (export "set") (param i32) (global.set 0 (local.get 0))))
        \\(register "A" $A)
        \\(module $B
        \\  (global $g (import "A" "g") (mut i32))
        \\  (export "g" (global $g))
        \\  (func (export "get") (result i32) (global.get $g)))
        \\(assert_return (get $B "g") (i32.const 142))
        \\(assert_return (invoke $A "set" (i32.const 241)))
        \\(assert_return (get $B "g") (i32.const 241))
        \\(assert_return (invoke $B "get") (i32.const 241))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "a funcref crossing a module boundary in a global keeps its identity" {
    // The same defect reached through a `funcref` GLOBAL rather than a table:
    // $M exports `(ref.func 0)`, and the importer drops it into its own table.
    // Resolving that value locally selected the importer's own function 0 —
    // which here is the caller itself, so the corpus saw it as unbounded
    // recursion (`elem.wast`'s `call_imported_elem`, CallStackExhausted) rather
    // than as a wrong value. Same bug, unrecognisable symptom.
    const src =
        \\(module $M
        \\  (func (result i32) (i32.const 42))
        \\  (global (export "f") funcref (ref.func 0)))
        \\(register "M" $M)
        \\(module $N
        \\  (import "M" "f" (global funcref))
        \\  (type $r (func (result i32)))
        \\  (table 1 funcref)
        \\  (elem (offset (i32.const 0)) funcref (global.get 0))
        \\  (func (export "call") (type $r)
        \\    (call_indirect (type $r) (i32.const 0))))
        \\(assert_return (invoke $N "call") (i32.const 42))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 1), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "assert_invalid/malformed does not count OUR limitations as passes" {
    // `assertRejected` used to score ANY error as a pass, so a module we simply
    // could not BUILD — an unimplemented command form, or a mnemonic our
    // assembler doesn't know — inflated the conformance numbers with our own
    // gaps. `assert_trap` and `assert_unlinkable` already filtered their
    // verdicts; this was the arm that didn't.
    const gpa = std.testing.allocator;

    // (a) A limitation reached THROUGH `(module quote …)` must still skip.
    //
    //     ⚠️ **THE EXAMPLE HAS NOW MOVED TWICE, AND THE PROPERTY HAS NOT CHANGED EITHER TIME.**
    //     It began as `(module quote …)` itself (R5 implemented the form). It then became
    //     `some.bogus.instruction` — which 2026-08-17 showed was never an instance of this
    //     property at all: a mnemonic in NO proposal is a genuine malformation, and refusing it
    //     is a verdict we are entitled to give, not a gap. The example is now a REAL instruction
    //     from a proposal wazmrt does not target (`i64.add128`, wide-arithmetic), which is what
    //     "our limitation" actually means. See `wat.untargetedProposalMnemonic`.
    //
    //     🎓 When a test fails after a change, ask whether its EXAMPLE still demonstrates its
    //     PROPERTY. Twice now the answer was no, and twice the property was fine.
    {
        const src = "(assert_malformed (module quote \"(func (i64.add128))\") \"unexpected token\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 0), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
        try std.testing.expectEqual(@as(usize, 1), s.skipped);
    }

    // (a1) The other half of that split, and the reason it was worth making: a mnemonic that
    //      exists in no wasm proposal IS a malformation, so refusing it is a PASS. This is the
    //      case that used to be example (a) — ~292 assertions across the corpus were being
    //      banked as skips on the strength of our own ignorance.
    {
        const src = "(assert_malformed (module quote \"(func (some.bogus.instruction))\") \"unexpected token\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }

    // (a2) …and a quoted module that is GENUINELY malformed must now pass, which
    //      is the whole point of implementing the form. Before R5 this scored as a
    //      skip, and 1,291 assertions across the suite went with it.
    {
        const src = "(assert_malformed (module quote \"(func (i32.const 0x100000000) drop)\") \"constant out of range\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }

    // (a3) A quoted module that is VALID must build — the wrapping has to accept
    //      both a bare field sequence and a complete `(module …)` form.
    {
        const s = try runScript(gpa, "(module quote \"(func (export \\\"f\\\"))\")", null);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
        const s2 = try runScript(gpa, "(module quote \"(module (func (export \\\"f\\\")))\")", null);
        try std.testing.expectEqual(@as(usize, 0), s2.failed);
    }

    // (b) A mnemonic from an UNTARGETED PROPOSAL is an assembler gap, not evidence of invalidity —
    //     the same property as (a), reached through a direct `(module …)` rather than a quoted
    //     one, because the two paths score independently. Example updated 2026-08-17 for the
    //     reason given at (a): `some.bogus.instruction` was never an instance of this property.
    {
        const src = "(assert_invalid (module (func (result i32) (i64.add128))) \"type mismatch\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 0), s.passed);
        try std.testing.expectEqual(@as(usize, 1), s.skipped);
    }

    // (b1) …and the same shape with a mnemonic that exists in no proposal is a real rejection.
    //      Kept beside (b) so the two are read together: the ONLY difference between them is
    //      whether the mnemonic is a real wasm instruction, which is precisely the distinction
    //      `untargetedProposalMnemonic` exists to draw.
    {
        const src = "(assert_invalid (module (func (result i32) (some.bogus.instruction))) \"type mismatch\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }

    // (c) a genuinely ill-typed module must still PASS — the fix must not turn
    //     real rejections into skips.
    {
        const src = "(assert_invalid (module (func (result i32) (i64.const 1))) \"type mismatch\")";
        const s = try runScript(gpa, src, null);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }
}

test "(either …) accepts any listed alternative, and still rejects a non-alternative" {
    const gpa = std.testing.allocator;
    // Relaxed-SIMD results are implementation-defined, so the suite lists every
    // permitted answer. We could not parse the wrapper and counted it as one
    // expected value — `arity 1 != expected 1` never even got that far; the real
    // report was `arity 4 != expected 1` for f32x4. 32 assertions across six
    // files had therefore never compared anything.
    {
        const src =
            \\(module (func (export "f") (result i32) (i32.const 7)))
            \\(assert_return (invoke "f") (either (i32.const 5) (i32.const 7)))
        ;
        var s = try runScript(gpa, src, null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
    }
    // A value in NO alternative must still fail — the wrapper widens the set of
    // right answers, it does not stop checking.
    {
        const src =
            \\(module (func (export "f") (result i32) (i32.const 7)))
            \\(assert_return (invoke "f") (either (i32.const 5) (i32.const 6)))
        ;
        var s = try runScript(gpa, src, null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), s.passed);
        try std.testing.expectEqual(@as(usize, 1), s.failed);
    }
    // v128 alternatives occupy TWO result slots each; the arity must come from
    // an alternative's shape, not from the wrapper.
    {
        const src =
            \\(module (func (export "f") (result v128) (v128.const i32x4 1 2 3 4)))
            \\(assert_return (invoke "f")
            \\  (either (v128.const i32x4 9 9 9 9) (v128.const i32x4 1 2 3 4)))
        ;
        var s = try runScript(gpa, src, null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
    }
}

test "D3 soundness: a descriptor is an ENTITY — two instances do not share one" {
    // 🔒 **THE TRAP THE ROADMAP NAMED FOR D3, written by CONSTRUCTION.** "The descriptor a value
    // carries must name an ENTITY, not a type index" — R2's lesson, and the third place it
    // applies. Both instances here are the SAME definition, so their type indices are identical
    // and a descriptor stored as an index would make `ref.get_desc` on I1's object hand back
    // I2's descriptor. `ref.eq` is the only way to see it: every type check passes either way,
    // so no assertion about types can catch this and neither can the corpus.
    const src =
        \\(module definition $M
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (global $d (export "d") (ref (exact $b)) (struct.new $b))
        \\  (func (export "make") (result (ref (exact $a)))
        \\    (struct.new_desc $a (global.get $d)))
        \\  (func (export "desc-of-mine-is-mine") (result i32)
        \\    (ref.eq (ref.get_desc $a (call 0)) (global.get $d))))
        \\(module instance $I1 $M)
        \\(module instance $I2 $M)
        \\(assert_return (invoke $I1 "desc-of-mine-is-mine") (i32.const 1))
        \\(assert_return (invoke $I2 "desc-of-mine-is-mine") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);

    // The other half, and the one that would actually be WRONG rather than merely unchecked:
    // I1's object must not report I2's descriptor. Two separate instances of one definition are
    // generative, so their globals are distinct objects — `ref.eq` across them must be 0.
    const cross =
        \\(module definition $M
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (global $d (export "d") (ref (exact $b)) (struct.new $b))
        \\  (func (export "make") (result (ref (exact $a)))
        \\    (struct.new_desc $a (global.get $d))))
        \\(module instance $I1 $M)
        \\(module instance $I2 $M)
        \\(register "I1" $I1)
        \\(register "I2" $I2)
        \\(module $Q
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (import "I1" "make" (func $m1 (result (ref (exact $a)))))
        \\  (import "I1" "d" (global $d1 (ref (exact $b))))
        \\  (import "I2" "d" (global $d2 (ref (exact $b))))
        \\  (func (export "mine") (result i32)
        \\    (ref.eq (ref.get_desc $a (call $m1)) (global.get $d1)))
        \\  (func (export "theirs") (result i32)
        \\    (ref.eq (ref.get_desc $a (call $m1)) (global.get $d2))))
        \\(assert_return (invoke $Q "mine") (i32.const 1))
        \\(assert_return (invoke $Q "theirs") (i32.const 0))
    ;
    // Read from a THIRD module, so the descriptor value crosses two boundaries. `mine` is the
    // arm a type-index representation would still pass; `theirs` is the one it could not.
    const s2 = try runScript(std.testing.allocator, cross, null);
    try std.testing.expectEqual(@as(usize, 2), s2.passed);
    try std.testing.expectEqual(@as(usize, 0), s2.failed);
}

test "D3: a null descriptor traps, at run time AND during instantiation" {
    // `struct.new_desc` is a constant instruction, so the same rule has to hold on both paths —
    // and they are two separate evaluators (`interp.step` and `evalConstGc`), which is exactly
    // the shape that lets one of them forget. The const-expr trap surfaces as a failed
    // instantiation, not a failed call.
    const src =
        \\(module
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (func (export "boom") (result (ref (exact $a)))
        \\    (struct.new_desc $a (ref.null none))))
        \\(assert_trap (invoke "boom") "null descriptor reference")
        \\(assert_trap
        \\  (module
        \\    (rec
        \\      (type $a (descriptor $b) (struct))
        \\      (type $b (describes $a) (struct)))
        \\    (global (ref (exact $a)) (struct.new_desc $a (ref.null (exact $b)))))
        \\  "null descriptor reference")
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "D3 soundness: an EXACT cast across instances refuses a subtype" {
    // 🔒 **A live type-confusion defect found while doing D3, fixed in `canonMatches`.**
    // `refMatches`'s cross-module arm called `TypeRegistry.isSub` and never looked at `rt.exact`,
    // so `ref.test (ref (exact $super))` on an object belonging to ANOTHER INSTANCE answered 1
    // for a subtype. D1 closed exactly this hole for the same-module path and its tests could not
    // reach here — the third time this codebase has found a defect by asking "and across
    // instances?". The corpus cannot see it either: both modules are valid on their own.
    const src =
        \\(module $A
        \\  (rec
        \\    (type $super (sub (struct)))
        \\    (type $sub (sub $super (struct))))
        \\  (global (export "s") (ref (exact $sub)) (struct.new $sub)))
        \\(register "A")
        \\(module
        \\  (rec
        \\    (type $super (sub (struct)))
        \\    (type $sub (sub $super (struct))))
        \\  (import "A" "s" (global $s (ref (exact $sub))))
        \\  (func (export "sub-vs-exact-super") (result i32)
        \\    (ref.test (ref (exact $super)) (global.get $s)))
        \\  (func (export "sub-vs-inexact-super") (result i32)
        \\    (ref.test (ref $super) (global.get $s)))
        \\  (func (export "sub-vs-exact-sub") (result i32)
        \\    (ref.test (ref (exact $sub)) (global.get $s))))
        \\(assert_return (invoke "sub-vs-exact-super") (i32.const 0))
        \\(assert_return (invoke "sub-vs-inexact-super") (i32.const 1))
        \\(assert_return (invoke "sub-vs-exact-sub") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    // The load-bearing line is the FIRST: a subtype must not satisfy an exact supertype across
    // the boundary. The other two prove the fix is exactness and not a blanket refusal, which
    // would pass the first for entirely the wrong reason.
    try std.testing.expectEqual(@as(usize, 3), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "D3: a funcref's dynamic type is its DEFINITION's, through a chain of re-exports" {
    // 🐛 Found while doing D3, and NOT a custom-descriptors bug: `definedFuncType` answered null
    // for any imported or foreign funcref, so EVERY concrete cast on one failed — including the
    // plain inexact `ref.test (ref $f)`. An import may legally name a SUPERTYPE, so reading the
    // type off the importing module is wrong even when it answers; `$D` below re-exports what it
    // imported inexactly, so the walk has to follow more than one hop.
    const src =
        \\(module $C
        \\  (type $super (sub (func)))
        \\  (type $sub (sub $super (func)))
        \\  (func (export "f") (type $sub))
        \\  (func (export "g") (type $super)))
        \\(register "C")
        \\(module $D
        \\  (type $super (sub (func)))
        \\  (import "C" "f" (func (type $super)))
        \\  (export "f" (func 0)))
        \\(register "D")
        \\(module
        \\  (type $super (sub (func)))
        \\  (type $sub (sub $super (func)))
        \\  (import "D" "f" (func $viaD (type $super)))
        \\  (import "C" "g" (func $g (type $super)))
        \\  (elem declare func $viaD $g)
        \\  (func (export "exact-sub") (result i32)
        \\    (ref.test (ref (exact $sub)) (ref.func $viaD)))
        \\  (func (export "inexact-super") (result i32)
        \\    (ref.test (ref $super) (ref.func $viaD)))
        \\  (func (export "g-is-not-sub") (result i32)
        \\    (ref.test (ref (exact $sub)) (ref.func $g))))
        \\(assert_return (invoke "exact-sub") (i32.const 1))
        \\(assert_return (invoke "inexact-super") (i32.const 1))
        \\(assert_return (invoke "g-is-not-sub") (i32.const 0))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    // The third is the control: `$g` really IS only a `$super`, so the exact-`$sub` test must
    // still answer 0. Without it the first two would pass under "always say yes".
    try std.testing.expectEqual(@as(usize, 3), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "D4 soundness: `_desc_eq` compares OBJECT IDENTITY, not descriptor type" {
    // 🔒 **THE LOAD-BEARING D4 TEST.** `$b1` and `$b2` are two allocations of the SAME descriptor
    // type, so every type-level question about them answers identically — canonical id, subtype
    // chain, exactness, all equal. An implementation that compared TYPES here would satisfy every
    // shape assertion in `ref_cast_desc_eq.wast` and still be a different instruction from the one
    // the proposal defines: it would be `ref.cast`. Only asking "is it THIS object" separates
    // them, so that is what is written down.
    const src =
        \\(module
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (global $b1 (ref (exact $b)) (struct.new $b))
        \\  (global $b2 (ref (exact $b)) (struct.new $b))
        \\  (global $a1 (ref (exact $a)) (struct.new_desc $a (global.get $b1)))
        \\  (func (export "hit") (result anyref)
        \\    (ref.cast_desc_eq (ref $a) (global.get $a1) (global.get $b1)))
        \\  (func (export "miss") (result anyref)
        \\    (ref.cast_desc_eq (ref $a) (global.get $a1) (global.get $b2)))
        \\  (func (export "br-hit") (result i32)
        \\    (block (result anyref)
        \\      (br_on_cast_desc_eq 0 anyref (ref $a) (global.get $a1) (global.get $b1))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1)))
        \\  (func (export "br-miss") (result i32)
        \\    (block (result anyref)
        \\      (br_on_cast_desc_eq 0 anyref (ref $a) (global.get $a1) (global.get $b2))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1)))
        \\  (func (export "br-fail-hit") (result i32)
        \\    (block (result anyref)
        \\      (br_on_cast_desc_eq_fail 0 anyref (ref $a) (global.get $a1) (global.get $b1))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1)))
        \\  (func (export "br-fail-miss") (result i32)
        \\    (block (result anyref)
        \\      (br_on_cast_desc_eq_fail 0 anyref (ref $a) (global.get $a1) (global.get $b2))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1))))
        \\(assert_return (invoke "hit") (ref.struct))
        \\(assert_trap (invoke "miss") "descriptor cast failure")
        \\(assert_return (invoke "br-hit") (i32.const 1))
        \\(assert_return (invoke "br-miss") (i32.const 0))
        \\(assert_return (invoke "br-fail-hit") (i32.const 0))
        \\(assert_return (invoke "br-fail-miss") (i32.const 1))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    // `hit` vs `miss` is the identity question. The four `br-*` arms then pin the BRANCH
    // DIRECTION for both spellings — `_eq` fires on a match, `_eq_fail` on a miss — which one arm
    // apiece could not: a swapped pair passes any single-direction check.
    try std.testing.expectEqual(@as(usize, 6), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "D4: a null descriptor traps BEFORE anything about the value is considered" {
    // ⚠️ **The ORDER is the rule.** The target is nullable and the value is null, so a naive
    // implementation returns null and never looks at the descriptor — the spec says trap. Getting
    // this backwards turns a trap into a successful cast, which is the failure direction that
    // matters. `ref_cast_desc_eq.wast` states it as `self-nullable-null-null`.
    const src =
        \\(module
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (global $null-a (ref null (exact $a)) (ref.null none))
        \\  (global $null-b (ref null (exact $b)) (ref.null none))
        \\  (global $b1 (ref (exact $b)) (struct.new $b))
        \\  (func (export "null-value-null-desc") (result anyref)
        \\    (ref.cast_desc_eq (ref null $a) (global.get $null-a) (global.get $null-b)))
        \\  (func (export "null-value-good-desc") (result anyref)
        \\    (ref.cast_desc_eq (ref null $a) (global.get $null-a) (global.get $b1)))
        \\  (func (export "null-value-nonnull-target") (result anyref)
        \\    (ref.cast_desc_eq (ref $a) (global.get $null-a) (global.get $b1)))
        \\  (func (export "br-null-desc") (result i32)
        \\    (block (result anyref)
        \\      (br_on_cast_desc_eq 0 anyref (ref $a) (global.get $null-a) (global.get $null-b))
        \\      (return (i32.const 0)))
        \\    (return (i32.const 1))))
        \\(assert_trap (invoke "null-value-null-desc") "null descriptor reference")
        \\(assert_return (invoke "null-value-good-desc") (ref.null none))
        \\(assert_trap (invoke "null-value-nonnull-target") "descriptor cast failure")
        \\(assert_trap (invoke "br-null-desc") "null descriptor reference")
    ;
    const s = try runScript(std.testing.allocator, src, null);
    // The middle case is the control: with a REAL descriptor, a null value against a nullable
    // target returns null rather than trapping — so the first trap is about the descriptor, not
    // about nulls in general.
    try std.testing.expectEqual(@as(usize, 4), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "D4 soundness: a `_desc_eq` cast across instances compares the RIGHT object" {
    // 🔒 Same shape as D3's cross-instance test, one layer up: the descriptor now arrives from
    // another instance AND the value being cast does too. `gcEntry` resolves through the store,
    // so the comparison is between two store-wide values — but only a test with two INSTANCES OF
    // ONE DEFINITION can show it, because their type indices are identical and every type-level
    // check passes either way.
    const src =
        \\(module definition $M
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (global $b1 (export "b") (ref (exact $b)) (struct.new $b))
        \\  (func (export "make") (result (ref (exact $a)))
        \\    (struct.new_desc $a (global.get $b1))))
        \\(module instance $I1 $M)
        \\(module instance $I2 $M)
        \\(register "I1" $I1)
        \\(register "I2" $I2)
        \\(module $Q
        \\  (rec
        \\    (type $a (descriptor $b) (struct))
        \\    (type $b (describes $a) (struct)))
        \\  (import "I1" "make" (func $m1 (result (ref (exact $a)))))
        \\  (import "I1" "b" (global $d1 (ref (exact $b))))
        \\  (import "I2" "b" (global $d2 (ref (exact $b))))
        \\  (func (export "own") (result anyref)
        \\    (ref.cast_desc_eq (ref $a) (call $m1) (global.get $d1)))
        \\  (func (export "other") (result anyref)
        \\    (ref.cast_desc_eq (ref $a) (call $m1) (global.get $d2))))
        \\(assert_return (invoke $Q "own") (ref.struct))
        \\(assert_trap (invoke $Q "other") "descriptor cast failure")
    ;
    const s = try runScript(std.testing.allocator, src, null);
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "an EXACT function import demands the type itself, through a re-export chain" {
    // 🔒 Two rules that only meet at LINK time, and the corpus is the only other place they are
    // checked — so an inversion of either was silent in `zig build test` until this existed.
    //
    // (1) An exact import demands the type ITSELF: `$C.f` really is a `$sub`, so importing it as
    //     `(exact (type $super))` must be UNLINKABLE even though `$sub <: $super`. This is
    //     `(ref (exact $t))`'s subtyping rule at the module boundary.
    // (2) A function's type is its DEFINITION's, not the type an importer declared for it. `$D`
    //     takes `$C.f` inexactly as `$super` and re-exports it; importing THAT as
    //     `(exact (type $sub))` must still link, because the function is a `$sub` whatever `$D`
    //     called it. D3 fixed the run-time half; `definingFuncAt` is the same walk, shared.
    const src =
        \\(module $C
        \\  (type $super (sub (func)))
        \\  (type $sub (sub $super (func)))
        \\  (func (export "f") (type $sub))
        \\  (func (export "g") (type $super)))
        \\(register "C")
        \\(module $D
        \\  (type $super (sub (func)))
        \\  (import "C" "f" (func (type $super)))
        \\  (export "f" (func 0)))
        \\(register "D")
        \\(assert_unlinkable
        \\  (module
        \\    (type $super (sub (func)))
        \\    (type $sub (sub $super (func)))
        \\    (import "C" "f" (func (exact (type $super)))))
        \\  "incompatible import type")
        \\(assert_unlinkable
        \\  (module
        \\    (type $super (sub (func)))
        \\    (type $sub (sub $super (func)))
        \\    (import "C" "g" (func (exact (type $sub)))))
        \\  "incompatible import type")
        \\(module
        \\  (type $super (sub (func)))
        \\  (type $sub (sub $super (func)))
        \\  (import "C" "f" (func (exact (type $sub)))))
        \\(module
        \\  (type $super (sub (func)))
        \\  (type $sub (sub $super (func)))
        \\  (import "D" "f" (func (exact (type $sub)))))
        \\(module
        \\  (type $super (sub (func)))
        \\  (import "D" "f" (func (type $super))))
    ;
    const s = try runScript(std.testing.allocator, src, null);
    // The two `assert_unlinkable`s are the exactness rule in both directions (a subtype offered
    // for an exact super, and a supertype offered for an exact sub); the three modules that must
    // BUILD are the control — without them "always refuse" would pass the first two.
    try std.testing.expectEqual(@as(usize, 2), s.passed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "the abbreviated module (§6.6.13) — a script that is nothing but module FIELDS" {
    // 🔒 REGRESSION TEST. `inline-module.wast` is one line and the whole file:
    // `(func) (memory 0) (func (export "f"))`. The command dispatcher saw three commands named
    // `func`, `memory` and `func`, recognised none, and banked three skips — a runner gap
    // reported as though the spec had asked us something we declined to answer.
    const gpa = std.testing.allocator;
    {
        var s = try runScript(gpa, "(func) (memory 0) (func (export \"f\"))", null);
        defer s.deinit(gpa);
        // One module, built. No assertions in the file, so nothing to pass — the point is that
        // nothing is SKIPPED any more.
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
    }
    // The fields really do become ONE module: a `(func (export "f"))` here is callable, which it
    // would not be if each form had been read as a module of its own.
    {
        var s = try runScript(gpa,
            \\(func (export "f") (result i32) (i32.const 7))
            \\(memory 0)
        , null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }
}

test "the abbreviated-module trigger FAILS SAFE on anything that is not a module field" {
    // ⚠️ The trigger is "every top-level form is a module field", not "the first one is not a
    // command". Keying on the first form would let a command keyword this runner does not know
    // reinterpret its entire script as one bogus module — turning a file of assertions into a
    // single malformed-module failure. **When a heuristic decides how to read a whole file, the
    // direction whose failure is a no-op is the one to pick.**
    const gpa = std.testing.allocator;

    // A real script is untouched: `(module …)` plus an assertion, both scored normally.
    {
        var s = try runScript(gpa,
            \\(module (func (export "f") (result i32) (i32.const 1)))
            \\(assert_return (invoke "f") (i32.const 1))
        , null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), s.passed);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
    }
    // Module fields MIXED with an unknown command stay on the ordinary path — the unknown form is
    // the skip it always was, and the fields are not silently welded into a module.
    {
        var s = try runScript(gpa, "(func) (totally_not_a_command)", null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), s.skipped);
        try std.testing.expectEqual(@as(usize, 0), s.failed);
    }
    // An empty script is not a module.
    {
        var s = try runScript(gpa, "", null);
        defer s.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), s.skipped);
    }
}
