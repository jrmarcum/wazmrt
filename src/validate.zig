//! Type validation of a decoded module (WebAssembly spec §3, using the
//! Appendix "Validation Algorithm": an abstract operand-value stack + a
//! control-frame stack, with a bottom `unknown` type for stack-polymorphic /
//! unreachable code).
//!
//! Scope matches the decoder: the core-MVP instruction set. It checks the
//! function/code count match (deferred from decode), local/global/func/type
//! index bounds, structured control flow, and operand-stack typing. Memory
//! presence and load/store alignment are not yet enforced (documented leniency).
//!
//! `validate` does not mutate the module; it decodes each body to IR in a scratch
//! arena and type-checks it.

const std = @import("std");
const types = @import("types.zig");
const Module = @import("Module.zig");
const opcode = @import("opcode.zig");
const Reader = @import("Reader.zig");

const V = types.ValType;
const Op = opcode.Op;

/// Cap on control nesting. Every `pushCtrl` snapshots the whole local-init
/// vector, so cost is depth × locals: a 512 KB module (2 000 locals, 262 144
/// nested blocks) drove **767 MB** peak — ~1500× amplification — on the inspect
/// path. Real code nests a few dozen deep; 1024 also matches `sexpr.zig`'s
/// parser cap, so nothing reachable from `.wat`/`.wast` text can exceed it.
const max_ctrl_depth: usize = 1024;

/// Cap on a function's locals (params + declared). The binary run-length form
/// (`count: u32` per run) lets a handful of bytes ask for billions.
///
/// This and `max_ctrl_depth` must be read together: the snapshot cost is their
/// **product**, so a generous locals cap silently reinstates the amplification
/// (2^20 locals × 1024 frames would still be ~1 GB). 50 000 — matching
/// wasmtime's own default — bounds the worst case at ~51 MB while staying far
/// above anything a compiler emits.
pub const max_locals: u64 = 50_000;

pub const Error = Module.Error || error{
    CountMismatch,
    TypeMismatch,
    StackUnderflow,
    StackHeightMismatch,
    ControlUnderflow,
    UnknownLabel,
    MismatchedElse,
    UndefinedLocal,
    /// A `local.get` of a non-defaultable (non-nullable ref) local before it was
    /// set (function-references local initialization, §3.3.5).
    UninitializedLocal,
    /// Control nesting exceeded `max_ctrl_depth`. Each frame snapshots the whole
    /// local-init vector, so depth × locals is a memory amplifier: a 512 KB
    /// module (2 000 locals, 262 144 nested blocks) drove **767 MB** peak before
    /// this cap.
    NestingTooDeep,
    /// A function declared more than `max_locals` locals. The run-length local
    /// encoding lets a handful of bytes ask for billions.
    TooManyLocals,
    UndefinedGlobal,
    ImmutableGlobal,
    UndefinedFunc,
    UndefinedType,
    /// A `throw`/catch tag index out of range (EH proposal).
    UndefinedTag,
    /// A tag whose type produces results (tags must have empty results).
    InvalidTag,
    UndefinedTable,
    UndefinedElem,
    /// A `memory.init`/`data.drop` data-segment index out of range.
    UndefinedData,
    /// A struct/array field index out of range for its type (GC).
    UndefinedField,
    /// A `struct.set`/`array.set` on an immutable field (GC).
    ImmutableField,
    /// `struct.get`/`array.get` on a packed field (must use `_s`/`_u`), or the
    /// `_s`/`_u` form on an unpacked field (GC).
    BadFieldPacking,
    InvalidStartFunction,
    ConstantExpressionRequired,
    InvalidAlignment,
    MissingMemory,
};

/// Validate an entire module. Returns on the first error.
pub fn validate(gpa: std.mem.Allocator, module: *const Module) Error!void {
    if (module.functions.len != module.code.len) return error.CountMismatch;

    // Global init const-exprs: each must be a constant expression producing
    // exactly the declared type. Defined globals occupy the tail of the space.
    const n_imported_globals: u32 = @intCast(module.globals.len - module.global_inits.len);
    for (module.global_inits, 0..) |init_expr, i| {
        const self_index = n_imported_globals + @as(u32, @intCast(i));
        try validateConstExpr(module, init_expr, module.globals[self_index].content, self_index);
    }

    // Active-segment *offset* const-exprs may reference any immutable global —
    // imported or defined (globals precede the element/data sections). But the
    // ref-producing *element expressions* (and table initializers, lowered to
    // them) follow the stricter rule of referencing only imported globals, so a
    // `global.get` of a defined global there is rejected as "unknown global".
    const all_globals: u32 = @intCast(module.globals.len);

    // Element segments: every referenced function index must exist; each
    // element const-expr must produce the segment's element type; an active
    // segment targets an existing type-compatible table with a valid i32 offset.
    for (module.elements) |elem| {
        for (elem.funcs) |fi| if (module.funcType(fi) == null) return error.UndefinedFunc;
        for (elem.exprs) |ex| try validateConstExpr(module, ex, elem.elem_type, n_imported_globals);
        if (elem.mode == .active) {
            if (elem.table_index >= module.tables.len) return error.UndefinedTable;
            const tet = module.tables[elem.table_index].element;
            // Family match (nullable-normalized) — non-nullability isn't enforced
            // on segment application, and the flag-4 binary form can't carry it.
            // NOTE (2026-07-20): `ValType.nullable()` returns the *nullable form
            // of the type*, not a bool, so this compares heap types with
            // nullability normalized away — which is correct. A 10th-pass audit
            // reported it as an accept-invalid bug on the assumption that
            // `nullable()` was a predicate; verified false. Don't "fix" it again.
            if (elem.elem_type.nullable() != tet.nullable()) return error.TypeMismatch;
            try validateConstExpr(module, elem.offset_expr, .i32, all_globals);
        }
    }

    // Data segments: an active segment targets an existing memory (only memory 0
    // is supported) and its offset const-expr must produce an i32.
    for (module.data) |seg| {
        if (!seg.active) continue;
        if (seg.mem_index >= module.memories.len) return error.MissingMemory;
        try validateConstExpr(module, seg.offset_expr, .i32, all_globals);
    }

    // Start function (§3.5.5): must be a defined/imported function of type [] → [].
    if (module.start) |si| {
        const ft = module.funcType(si) orelse return error.UndefinedFunc;
        if (ft.params.len != 0 or ft.results.len != 0) return error.InvalidStartFunction;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    for (module.functions, module.code) |type_index, code| {
        const ft = module.funcSig(type_index) orelse return error.UndefinedType;
        try validateFunction(arena.allocator(), module, ft, code, null);
        _ = arena.reset(.retain_capacity);
    }
}

/// Type-check a constant expression (§3.3.7 + extended-const `i32`/`i64`
/// `add`/`sub`/`mul`). It must produce exactly one value of `expected`. A
/// `global.get x` may reference only a *prior* (`x < self_index`) *immutable*
/// global; anything outside the const-expr opcode set is rejected.
fn validateConstExpr(module: *const Module, expr: []const u8, expected: V, self_index: u32) Error!void {
    var r = Reader.init(expr);
    var stack: [8]V = undefined;
    var sp: usize = 0;
    const push = struct {
        fn f(s: *[8]V, p: *usize, t: V) Error!void {
            if (p.* >= s.len) return error.ConstantExpressionRequired;
            s[p.*] = t;
            p.* += 1;
        }
    }.f;
    while (true) {
        const op = try r.readByte();
        switch (op) {
            0x0b => break, // end
            0x41 => {
                _ = try r.readVarI32();
                try push(&stack, &sp, .i32);
            },
            0x42 => {
                _ = try r.readVarI64();
                try push(&stack, &sp, .i64);
            },
            0x43 => {
                _ = try r.readBytes(4);
                try push(&stack, &sp, .f32);
            },
            0x44 => {
                _ = try r.readBytes(8);
                try push(&stack, &sp, .f64);
            },
            0x23 => { // global.get x — only a prior, immutable global
                const gi = try r.readVarU32();
                if (gi >= self_index) return error.UndefinedGlobal;
                if (module.globals[gi].mutable) return error.ConstantExpressionRequired;
                try push(&stack, &sp, module.globals[gi].content);
            },
            0xd0 => { // ref.null <heaptype>
                const heap = opcode.readHeapType(&r) catch return error.ConstantExpressionRequired;
                try push(&stack, &sp, try refTypeValType(module, .{ .nullable = true, .heap = heap }));
            },
            0xd2 => { // ref.func x
                const fi = try r.readVarU32();
                if (module.funcType(fi) == null) return error.UndefinedFunc;
                // Concrete `(ref $ftype)` for a defined func; abstract for imports.
                if (module.funcTypeIndex(fi)) |ti|
                    try push(&stack, &sp, V.concreteRef(false, .func, ti))
                else
                    try push(&stack, &sp, .funcref_nn);
            },
            0x6a, 0x6b, 0x6c => { // i32 add/sub/mul (extended-const)
                if (sp < 2 or stack[sp - 1] != .i32 or stack[sp - 2] != .i32) return error.TypeMismatch;
                sp -= 1;
            },
            0x7c, 0x7d, 0x7e => { // i64 add/sub/mul (extended-const)
                if (sp < 2 or stack[sp - 1] != .i64 or stack[sp - 2] != .i64) return error.TypeMismatch;
                sp -= 1;
            },
            else => return error.ConstantExpressionRequired,
        }
    }
    if (sp != 1 or !subtypeOf(module, stack[0], expected)) return error.TypeMismatch;
}

fn validateFunction(a: std.mem.Allocator, module: *const Module, ft: Module.FuncType, code: Module.Code, widths: ?[]u8) Error!void {
    // locals = parameters ++ declared locals (expanded from run-length form).
    var locals: std.ArrayList(V) = .empty;
    try locals.appendSlice(a, ft.params);
    // The run-length form means a few bytes can ask for billions of locals, and
    // the old loop appended them one at a time — multi-GB from a tiny module.
    // Sum first (checked), reject past the cap, then expand.
    var declared: u64 = 0;
    for (code.locals) |l| declared += l.count;
    if (declared + ft.params.len > max_locals) return error.TooManyLocals;
    for (code.locals) |l| {
        var n = l.count;
        while (n > 0) : (n -= 1) try locals.append(a, l.type);
    }

    const instrs = try opcode.decodeBody(a, code.body);

    // Local-init: parameters are always initialized; a *declared* defaultable
    // local starts initialized, but a non-nullable-ref one is non-defaultable and
    // starts uninitialized.
    const n_params = ft.params.len;
    const local_init = try a.alloc(bool, locals.items.len);
    for (local_init, locals.items, 0..) |*init, t, i| init.* = i < n_params or !t.isNonNullRef();

    var v: FuncValidator = .{ .a = a, .module = module, .locals = locals.items, .results = ft.results, .local_init = local_init, .widths = widths, .body_len = instrs.len };
    // The whole body is an implicit block of type [] -> results; its trailing
    // `end` closes this frame.
    try v.pushCtrl(.block, empty, ft.results);
    for (instrs, 0..) |instr, i| {
        v.pc = i;
        try v.step(instr);
    }
    if (v.ctrls.items.len != 0) return error.ControlUnderflow; // missing `end`
}

/// Type-check one function *for the purpose of* annotating each `drop`/`select`
/// with its operand slot width (2 for a v128, else 1) — the interpreter needs
/// this to pop the right number of `u64` slots (a v128 is two). Returns an
/// array indexed by instruction position (1 everywhere except v128 drop/select).
///
/// Only called for functions that actually use v128 (see `interp`), so the
/// common non-SIMD path never pays for it. Tolerant: on a validation error it
/// returns the widths captured **before** the error — an error can only be at or
/// after an unsupported/invalid instruction, which the interpreter traps on
/// before reaching any later drop/select, so those later widths are never used.
pub fn dropSelectWidths(a: std.mem.Allocator, module: *const Module, ft: Module.FuncType, code: Module.Code) std.mem.Allocator.Error![]const u8 {
    // The caller (interp) already decoded this body successfully, so re-decoding
    // here fails only on OOM; a (hypothetical) decode error → empty = all width 1.
    const instrs = opcode.decodeBody(a, code.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const widths = try a.alloc(u8, instrs.len);
    @memset(widths, 1);
    validateFunction(a, module, ft, code, widths) catch {};
    return widths;
}

// --- The validation algorithm ---------------------------------------------

const StackType = union(enum) { val: V, unknown };

const FrameKind = enum { block, loop, if_, else_, try_table };

const Frame = struct {
    kind: FrameKind,
    start: []const V,
    end: []const V,
    height: usize,
    is_unreachable: bool,
    /// Local-init state at this frame's entry; a structured control instruction
    /// restores it on `else`/`end` (inner sets don't escape the construct).
    init_snapshot: []bool,
};

const FuncValidator = struct {
    a: std.mem.Allocator,
    module: *const Module,
    locals: []const V,
    results: []const V,
    /// Whether each local is currently known-initialized (params + defaultable
    /// locals start true; non-nullable-ref locals start false).
    local_init: []bool,
    vals: std.ArrayList(StackType) = .empty,
    ctrls: std.ArrayList(Frame) = .empty,
    /// Optional: per-instruction operand *slot width* (2 for a v128 `drop`/
    /// `select`, else 1), written as those ops are checked. Used by the interp to
    /// pop the right slot count (SIMD). Null when validating for correctness only.
    widths: ?[]u8 = null,
    /// Index of the instruction currently being checked (for `widths`).
    pc: usize = 0,
    /// Instruction count of the body being checked. Used as a sound upper bound
    /// on how many operands an instruction can legitimately consume (see
    /// `array_new_fixed`).
    body_len: usize = 0,

    /// Record the slot width of a `drop`/`select` operand at the current pc
    /// (2 for v128, else 1) when width-capture is on.
    fn recordWidth(self: *FuncValidator, st: StackType) void {
        if (self.widths) |w| w[self.pc] = switch (st) {
            .val => |t| if (t == .v128) 2 else 1,
            .unknown => 1, // polymorphic (unreachable code) — never executed
        };
    }

    fn pushValT(self: *FuncValidator, t: V) Error!void {
        try self.vals.append(self.a, .{ .val = t });
    }
    fn pushVal(self: *FuncValidator, st: StackType) Error!void {
        try self.vals.append(self.a, st);
    }
    fn pushVals(self: *FuncValidator, ts: []const V) Error!void {
        for (ts) |t| try self.pushValT(t);
    }

    fn popVal(self: *FuncValidator) Error!StackType {
        const top = self.ctrls.items[self.ctrls.items.len - 1];
        if (self.vals.items.len == top.height) {
            if (top.is_unreachable) return .unknown;
            return error.StackUnderflow;
        }
        return self.vals.pop().?;
    }
    fn popExpect(self: *FuncValidator, expect: V) Error!StackType {
        const actual = try self.popVal();
        switch (actual) {
            .unknown => {},
            .val => |t| if (!subtypeOf(self.module, t, expect)) return error.TypeMismatch,
        }
        return actual;
    }
    fn popVals(self: *FuncValidator, ts: []const V) Error!void {
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            _ = try self.popExpect(ts[i]);
        }
    }
    /// Pop a value that must be a reference type (or polymorphic `unknown`).
    fn popRef(self: *FuncValidator) Error!StackType {
        const st = try self.popVal();
        switch (st) {
            .val => |v| if (!v.isRef()) return error.TypeMismatch,
            .unknown => {},
        }
        return st;
    }

    /// True if the innermost control frame is in unreachable (polymorphic) code.
    fn topUnreachable(self: *FuncValidator) bool {
        return self.ctrls.items.len != 0 and self.ctrls.items[self.ctrls.items.len - 1].is_unreachable;
    }

    fn pushCtrl(self: *FuncValidator, kind: FrameKind, start: []const V, end: []const V) Error!void {
        if (self.ctrls.items.len >= max_ctrl_depth) return error.NestingTooDeep;
        try self.ctrls.append(self.a, .{
            .kind = kind,
            .start = start,
            .end = end,
            .height = self.vals.items.len,
            .is_unreachable = false,
            .init_snapshot = try self.a.dupe(bool, self.local_init),
        });
        try self.pushVals(start);
    }
    fn popCtrl(self: *FuncValidator) Error!Frame {
        if (self.ctrls.items.len == 0) return error.ControlUnderflow;
        const frame = self.ctrls.items[self.ctrls.items.len - 1];
        try self.popVals(frame.end);
        if (self.vals.items.len != frame.height) return error.StackHeightMismatch;
        _ = self.ctrls.pop();
        return frame;
    }
    fn setUnreachable(self: *FuncValidator) void {
        const top = &self.ctrls.items[self.ctrls.items.len - 1];
        self.vals.shrinkRetainingCapacity(top.height);
        top.is_unreachable = true;
    }

    /// Label types of the frame `n` levels from the top (`br`/`br_if`/`br_table`).
    fn labelTypesAt(self: *FuncValidator, n: u32) Error![]const V {
        if (n >= self.ctrls.items.len) return error.UnknownLabel;
        const frame = self.ctrls.items[self.ctrls.items.len - 1 - n];
        return if (frame.kind == .loop) frame.start else frame.end;
    }

    fn localAt(self: *FuncValidator, i: u32) Error!V {
        if (i >= self.locals.len) return error.UndefinedLocal;
        return self.locals[i];
    }
    fn globalAt(self: *FuncValidator, i: u32) Error!Module.GlobalType {
        if (i >= self.module.globals.len) return error.UndefinedGlobal;
        return self.module.globals[i];
    }
    fn tableElemType(self: *FuncValidator, i: u32) Error!V {
        if (i >= self.module.tables.len) return error.UndefinedTable;
        return self.module.tables[i].element;
    }

    const Sig = struct { pop: []const V, push: []const V };

    fn blockSig(self: *FuncValidator, bt: opcode.BlockType) Error!Sig {
        return switch (bt) {
            .empty => .{ .pop = empty, .push = empty },
            .value => |t| blk: {
                const r = try self.a.alloc(V, 1);
                r[0] = t;
                break :blk .{ .pop = empty, .push = r };
            },
            .type_index => |i| blk: {
                const ft = self.module.funcSig(i) orelse return error.UndefinedType;
                break :blk .{ .pop = ft.params, .push = ft.results };
            },
        };
    }

    /// Every `want[i]` must be a subtype of `got[i]` (same length). Used to check
    /// that a catch handler's pushed values fit its target label.
    fn matchTypes(self: *FuncValidator, want: []const V, got: []const V) Error!void {
        if (want.len != got.len) return error.TypeMismatch;
        for (want, got) |w, g| if (!subtypeOf(self.module, w, g)) return error.TypeMismatch;
    }

    /// A `try_table` catch clause branches to `lt` (its target label's types)
    /// carrying the tag's params (`catch`/`catch_ref`) — plus an `exnref` for the
    /// `_ref` variants, and nothing for `catch_all`. Check those match `lt`.
    fn checkCatch(self: *FuncValidator, c: opcode.Catch, lt: []const V) Error!void {
        switch (c.kind) {
            .catch_ => {
                const ft = self.module.tagType(c.tag) orelse return error.UndefinedTag;
                try self.matchTypes(ft.params, lt);
            },
            .catch_ref => {
                const ft = self.module.tagType(c.tag) orelse return error.UndefinedTag;
                if (lt.len != ft.params.len + 1) return error.TypeMismatch;
                try self.matchTypes(ft.params, lt[0..ft.params.len]);
                if (!subtypeOf(self.module, .exnref, lt[lt.len - 1])) return error.TypeMismatch;
            },
            .catch_all => if (lt.len != 0) return error.TypeMismatch,
            .catch_all_ref => if (lt.len != 1 or !subtypeOf(self.module, .exnref, lt[0])) return error.TypeMismatch,
        }
    }

    fn step(self: *FuncValidator, instr: opcode.Instr) Error!void {
        if (self.ctrls.items.len == 0) return error.ControlUnderflow; // code after final `end`
        switch (instr.op) {
            .@"unreachable" => self.setUnreachable(),
            .nop => {},

            .block => {
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.block, s.pop, s.push);
            },
            .loop => {
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.loop, s.pop, s.push);
            },
            .@"if" => {
                _ = try self.popExpect(.i32);
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.if_, s.pop, s.push);
            },

            // Exception handling (exnref proposal, Phase 6).
            .try_table => {
                const tt = instr.imm.try_table;
                const s = try self.blockSig(tt.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.try_table, s.pop, s.push);
                // Each catch's target label must accept exactly the values the
                // handler pushes: the tag's params, plus an `exnref` for `_ref`.
                // Label indices are resolved with the try_table frame on top.
                for (tt.catches) |c| {
                    const lt = try self.labelTypesAt(c.label);
                    try self.checkCatch(c, lt);
                }
            },
            .throw => {
                const ft = self.module.tagType(instr.imm.tag) orelse return error.UndefinedTag;
                if (ft.results.len != 0) return error.InvalidTag; // tags never produce results
                try self.popVals(ft.params); // consume the exception's operands
                self.setUnreachable(); // control transfers; the rest is dead
            },
            .throw_ref => {
                _ = try self.popExpect(.exnref);
                self.setUnreachable();
            },
            .@"else" => {
                const frame = try self.popCtrl();
                if (frame.kind != .if_) return error.MismatchedElse;
                // The else branch starts from the if's entry init state (sets in
                // the then branch don't carry over).
                @memcpy(self.local_init, frame.init_snapshot);
                try self.pushCtrl(.else_, frame.start, frame.end);
            },
            .end => {
                const frame = try self.popCtrl();
                // An `if` closed without an `else` has an implicit identity else
                // branch, which requires the param and result types to match.
                if (frame.kind == .if_ and !std.mem.eql(V, frame.start, frame.end)) return error.TypeMismatch;
                // Restore the entry init state — inner sets don't escape (§3.3.5).
                @memcpy(self.local_init, frame.init_snapshot);
                try self.pushVals(frame.end);
            },

            .br => {
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                self.setUnreachable();
            },
            .br_if => {
                _ = try self.popExpect(.i32);
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                try self.pushVals(lt);
            },
            .br_table => {
                _ = try self.popExpect(.i32);
                const default_lt = try self.labelTypesAt(instr.imm.br_table.default);
                for (instr.imm.br_table.labels) |l| {
                    const lt = try self.labelTypesAt(l);
                    if (lt.len != default_lt.len) return error.TypeMismatch;
                    // #2f: every target label must be type-compatible with the
                    // default, not merely equal in arity. `popVals` catches a
                    // mismatch in reachable code but NOT in stack-polymorphic
                    // (post-`unreachable`) code, where the operand stack is
                    // `unknown`. `subtypeOf` both ways rejects only genuinely
                    // incompatible pairs (under single inheritance no common
                    // operand type exists), so it never rejects a valid
                    // subtyped `br_table`.
                    for (lt, default_lt) |a, b|
                        if (!subtypeOf(self.module, a, b) and !subtypeOf(self.module, b, a)) return error.TypeMismatch;
                    try self.popVals(lt);
                    try self.pushVals(lt);
                }
                try self.popVals(default_lt);
                self.setUnreachable();
            },
            .@"return" => {
                try self.popVals(self.results);
                self.setUnreachable();
            },

            .call => {
                const ft = self.module.funcType(instr.imm.func) orelse return error.UndefinedFunc;
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },
            .call_indirect => {
                const ci = instr.imm.call_indirect;
                if (ci.table >= self.module.tables.len) return error.UndefinedTable;
                if (self.module.tables[ci.table].element != .funcref) return error.TypeMismatch;
                const ft = self.module.funcSig(ci.type_index) orelse return error.UndefinedType;
                _ = try self.popExpect(.i32);
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },

            .drop => {
                const t = try self.popVal();
                self.recordWidth(t);
            },
            .select => {
                // Untyped select: operands must be equal and a *numeric/vector*
                // type — reference-typed operands require the typed form.
                _ = try self.popExpect(.i32);
                const t1 = try self.popVal();
                const t2 = try self.popVal();
                if (isRefStack(t1) or isRefStack(t2)) return error.TypeMismatch;
                const rt: StackType = switch (t1) {
                    .unknown => t2,
                    .val => |a| switch (t2) {
                        .unknown => t1,
                        .val => |b| if (a == b) t1 else return error.TypeMismatch,
                    },
                };
                self.recordWidth(rt);
                try self.pushVal(rt);
            },
            .select_t => {
                // Typed select: the annotation must be exactly one type; both
                // operands must match it.
                const tys = instr.imm.select_types;
                if (tys.len != 1) return error.TypeMismatch; // invalid result arity
                _ = try self.popExpect(.i32);
                _ = try self.popExpect(tys[0]);
                _ = try self.popExpect(tys[0]);
                if (self.widths) |w| w[self.pc] = if (tys[0] == .v128) 2 else 1;
                try self.pushValT(tys[0]);
            },
            .simd => {
                const s = simdSig(instr.imm.simd.sub);
                try self.popVals(s.pop);
                try self.pushVals(s.push);
            },

            .table_get => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(.i32);
                try self.pushValT(et);
            },
            .table_set => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(et);
                _ = try self.popExpect(.i32);
            },
            .table_size => {
                _ = try self.tableElemType(instr.imm.table); // bounds-check the index
                try self.pushValT(.i32);
            },
            .table_grow => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(.i32); // delta
                _ = try self.popExpect(et); // init value
                try self.pushValT(.i32);
            },
            .table_fill => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(et); // value
                _ = try self.popExpect(.i32); // dst
            },
            .table_init => {
                const tet = try self.tableElemType(instr.imm.table_init.table);
                if (instr.imm.table_init.elem >= self.module.elements.len) return error.UndefinedElem;
                if (self.module.elements[instr.imm.table_init.elem].elem_type != tet) return error.TypeMismatch;
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src
                _ = try self.popExpect(.i32); // dst
            },
            .elem_drop => {
                if (instr.imm.elem >= self.module.elements.len) return error.UndefinedElem;
            },

            // Bulk memory. All three take `[dst, src|byte, n]` as i32 and need a
            // linear memory; `memory.init`/`data.drop` also need a valid data index.
            .memory_copy, .memory_fill => {
                if (self.module.memories.len == 0) return error.MissingMemory;
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src / fill byte
                _ = try self.popExpect(.i32); // dst
            },
            .memory_init => {
                if (self.module.memories.len == 0) return error.MissingMemory;
                if (instr.imm.data >= self.module.data.len) return error.UndefinedData;
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src (offset into the segment)
                _ = try self.popExpect(.i32); // dst
            },
            .data_drop => {
                if (instr.imm.data >= self.module.data.len) return error.UndefinedData;
            },
            .table_copy => {
                const dt = try self.tableElemType(instr.imm.table_copy.dst);
                const st = try self.tableElemType(instr.imm.table_copy.src);
                if (dt != st) return error.TypeMismatch;
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src
                _ = try self.popExpect(.i32); // dst
            },

            .ref_null => try self.pushValT(try refTypeValType(self.module, .{ .nullable = true, .heap = instr.imm.ref_type })),
            .ref_is_null => {
                switch (try self.popVal()) { // requires a reference type (or polymorphic)
                    .val => |v| if (!v.isRef()) return error.TypeMismatch,
                    .unknown => {},
                }
                try self.pushValT(.i32);
            },
            .ref_func => {
                if (self.module.funcType(instr.imm.func) == null) return error.UndefinedFunc;
                // A function reference is non-null and, for a defined function,
                // carries its concrete type (`(ref $ftype)`); imported funcs fall
                // back to the abstract funcref head (no type index kept).
                if (self.module.funcTypeIndex(instr.imm.func)) |ti|
                    try self.pushValT(V.concreteRef(false, .func, ti))
                else
                    try self.pushValT(.funcref_nn);
            },

            // Typed function references (function-references proposal). A typed
            // func ref collapses to `funcref` in our model (see the decoder P1).
            .call_ref => {
                const ft = self.module.funcSig(instr.imm.func) orelse return error.UndefinedType;
                _ = try self.popExpect(.funcref); // the function reference (top)
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },
            .return_call_ref => {
                const ft = self.module.funcSig(instr.imm.func) orelse return error.UndefinedType;
                _ = try self.popExpect(.funcref);
                try self.popVals(ft.params);
                if (!valTypesEqual(ft.results, self.results)) return error.TypeMismatch;
                self.setUnreachable();
            },
            // GC: i31 references (full GC, P3). `ref.i31` boxes an i32 into a
            // non-null i31 ref; `i31.get_s`/`_u` project it back (traps on null).
            .ref_i31 => {
                _ = try self.popExpect(.i32);
                try self.pushValT(.i31ref_nn);
            },
            .i31_get_s, .i31_get_u => {
                _ = try self.popExpect(.i31ref); // (ref null i31) and its subtypes
                try self.pushValT(.i32);
            },

            // GC: eq references compare by identity.
            .ref_eq => {
                _ = try self.popExpect(.eqref);
                _ = try self.popExpect(.eqref);
                try self.pushValT(.i32);
            },

            // GC: struct objects (full GC, P3). Concrete `(ref $t)` operands
            // collapse to `structref` in our model; the exact type index rides in
            // the immediate (fields/mutability come from it).
            .struct_new => {
                const fields = self.module.structFields(instr.imm.gc_type) orelse return error.UndefinedType;
                var i = fields.len;
                while (i > 0) { // operands are pushed field 0 first → pop in reverse
                    i -= 1;
                    _ = try self.popExpect(fields[i].storage.unpacked());
                }
                try self.pushValT(V.concreteRef(false, .@"struct", instr.imm.gc_type));
            },
            .struct_new_default => {
                const fields = self.module.structFields(instr.imm.gc_type) orelse return error.UndefinedType;
                for (fields) |f| if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch; // not defaultable
                try self.pushValT(V.concreteRef(false, .@"struct", instr.imm.gc_type));
            },
            .struct_get, .struct_get_s, .struct_get_u => {
                const gf = instr.imm.gc_field;
                const fields = self.module.structFields(gf.type_index) orelse return error.UndefinedType;
                if (gf.field >= fields.len) return error.UndefinedField;
                const field = fields[gf.field];
                try requirePacking(instr.op == .struct_get, field.storage);
                _ = try self.popExpect(.structref); // (ref null $t)
                try self.pushValT(field.storage.unpacked());
            },
            .struct_set => {
                const gf = instr.imm.gc_field;
                const fields = self.module.structFields(gf.type_index) orelse return error.UndefinedType;
                if (gf.field >= fields.len) return error.UndefinedField;
                if (!fields[gf.field].mutable) return error.ImmutableField;
                _ = try self.popExpect(fields[gf.field].storage.unpacked());
                _ = try self.popExpect(.structref);
            },

            // GC: array objects. `t'` is the (unpacked) element type.
            .array_new => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                _ = try self.popExpect(.i32); // length
                _ = try self.popExpect(f.storage.unpacked()); // init value
                try self.pushValT(V.concreteRef(false, .array, instr.imm.gc_type));
            },
            .array_new_default => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch; // not defaultable
                _ = try self.popExpect(.i32); // length
                try self.pushValT(V.concreteRef(false, .array, instr.imm.gc_type));
            },
            .array_new_fixed => {
                const tn = instr.imm.gc_type_n;
                const f = self.module.arrayField(tn.type_index) orelse return error.UndefinedType;
                // `n` is an unvalidated u32. In *unreachable* code `popExpect`
                // returns `.unknown` instead of underflowing, so the loop would
                // spin up to 2^32 times on a tiny module. Every operand must have
                // been produced by at least one instruction, so a valid `n` can
                // never exceed the body's instruction count — bounding by it
                // kills the spin without being able to reject a valid module.
                if (tn.n > self.body_len) return error.StackUnderflow;
                var k: u32 = 0;
                while (k < tn.n) : (k += 1) _ = try self.popExpect(f.storage.unpacked());
                try self.pushValT(V.concreteRef(false, .array, tn.type_index));
            },
            .array_get, .array_get_s, .array_get_u => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                try requirePacking(instr.op == .array_get, f.storage);
                _ = try self.popExpect(.i32); // index
                _ = try self.popExpect(.arrayref); // (ref null $t)
                try self.pushValT(f.storage.unpacked());
            },
            .array_set => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                if (!f.mutable) return error.ImmutableField;
                _ = try self.popExpect(f.storage.unpacked()); // value
                _ = try self.popExpect(.i32); // index
                _ = try self.popExpect(.arrayref);
            },
            .array_len => {
                _ = try self.popExpect(.arrayref); // (ref null array)
                try self.pushValT(.i32);
            },

            // GC casts. `ref.test` consumes a reference and yields i32; `ref.cast`
            // passes the reference through with the target's (collapsed) type,
            // trapping at runtime on a failed cast.
            .ref_test => {
                _ = try self.popRef();
                try self.pushValT(.i32);
            },
            .ref_cast => {
                _ = try self.popRef();
                try self.pushValT(try refTypeValType(self.module, instr.imm.ref_cast));
            },

            // GC cast-branches. The label carries `[t* rt]` (the ref plus a prefix
            // `t*`); the operand is `[t* src]`. `br_on_cast` branches when the ref
            // matches `dst` (passing it as `dst`) and falls through otherwise;
            // `br_on_cast_fail` is the mirror. `dst` must be a subtype of `src`.
            .br_on_cast, .br_on_cast_fail => {
                const bc = instr.imm.br_cast;
                const src_vt = try refTypeValType(self.module, bc.src);
                const dst_vt = try refTypeValType(self.module, bc.dst);
                if (!subtypeOf(self.module, dst_vt, src_vt)) return error.TypeMismatch; // a downcast
                const lt = try self.labelTypesAt(bc.label); // [t* carried]
                if (lt.len == 0) return error.TypeMismatch;
                // The type carried to the label: `dst` for br_on_cast (the branch
                // fires on a match), `src` for br_on_cast_fail (fires on a miss).
                const carried = if (instr.op == .br_on_cast) dst_vt else src_vt;
                if (!subtypeOf(self.module, carried, lt[lt.len - 1])) return error.TypeMismatch;
                const prefix = lt[0 .. lt.len - 1]; // t*
                _ = try self.popExpect(src_vt); // the ref operand (top)
                try self.popVals(prefix);
                try self.pushVals(prefix);
                // Fall-through leaves the ref: `src` for br_on_cast (not dst),
                // narrowed to `dst` for br_on_cast_fail (it is dst).
                try self.pushValT(if (instr.op == .br_on_cast) src_vt else dst_vt);
            },

            .ref_as_non_null => try self.pushVal(try self.popRef()),
            .br_on_null => {
                // Pop the ref; on branch pass [t*] to the label, on fall-through
                // keep the (now non-null) ref.
                const r = try self.popRef();
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                try self.pushVals(lt);
                try self.pushVal(r);
            },
            .br_on_non_null => {
                // The label expects [t* ref]; on fall-through the ref is consumed.
                const lt = try self.labelTypesAt(instr.imm.label);
                if (lt.len == 0 or (lt[lt.len - 1] != .funcref and lt[lt.len - 1] != .externref)) return error.TypeMismatch;
                try self.popVals(lt);
                try self.pushVals(lt);
                _ = try self.popRef();
            },

            .local_get => {
                const t = try self.localAt(instr.imm.local);
                // A non-defaultable local must have been set on this path (unless
                // we're already in unreachable/polymorphic code).
                if (t.isNonNullRef() and !self.local_init[instr.imm.local] and !self.topUnreachable())
                    return error.UninitializedLocal;
                try self.pushValT(t);
            },
            .local_set => {
                _ = try self.popExpect(try self.localAt(instr.imm.local));
                self.local_init[instr.imm.local] = true;
            },
            .local_tee => {
                const t = try self.localAt(instr.imm.local);
                _ = try self.popExpect(t);
                self.local_init[instr.imm.local] = true;
                try self.pushValT(t);
            },
            .global_get => try self.pushValT((try self.globalAt(instr.imm.global)).content),
            .global_set => {
                const g = try self.globalAt(instr.imm.global);
                if (!g.mutable) return error.ImmutableGlobal;
                _ = try self.popExpect(g.content);
            },

            else => {
                // Load/store: the alignment (log2) must not exceed the access's
                // natural alignment, and a linear memory must exist.
                if (opcode.immediateKind(instr.op) == .mem) {
                    if (self.module.memories.len == 0) return error.MissingMemory;
                    if (instr.imm.mem.alignment > opcode.naturalAlignLog2(instr.op)) return error.InvalidAlignment;
                }
                const s = simpleSig(instr.op) orelse return error.UnsupportedOpcode;
                try self.popVals(s.pop);
                try self.pushVals(s.push);
            },
        }
    }
};

/// Natural alignment (log2 of the access size in bytes) for a load/store opcode.
fn valTypesEqual(a: []const V, b: []const V) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Is `sub` a subtype of `sup` (for operand matching)? Identical types match.
/// Reference subtyping follows the WasmGC hierarchy on the heap type
/// (`RefHeap.sub`: i31/struct/array <: eq <: any; `none` the bottom; func/extern
/// disjoint) combined with nullability: a non-null reference is a subtype of the
/// nullable form (`(ref t) <: (ref null t)`), so a non-null value satisfies a
/// nullable expectation but not the reverse.
/// Enforce the packed/unpacked rule for a field accessor: the plain `*.get`
/// forms require an unpacked field; the `_s`/`_u` forms require a packed one.
fn requirePacking(is_plain_get: bool, storage: Module.StorageType) Error!void {
    if (is_plain_get == storage.isPacked()) return error.BadFieldPacking;
}

/// The value type of a cast target reference type — a concrete `(ref null? $t)`
/// keeps its type index; an abstract target uses its family head.
fn refTypeValType(module: *const Module, rt: opcode.RefType) Error!V {
    const head = try module.refHead(rt.heap);
    return switch (rt.heap) {
        .concrete => |ti| V.concreteRef(rt.nullable, head, ti),
        else => head.valType(rt.nullable),
    };
}

fn subtypeOf(module: *const Module, sub: V, sup: V) bool {
    if (sub == sup) return true;
    if (!sub.isRef() or !sup.isRef()) return false;
    // A nullable sub cannot satisfy a non-null expectation.
    if (sup.isNonNullRef() and !sub.isNonNullRef()) return false;
    // Concrete → concrete: walk the declared supertype chain (the collapsed
    // heads alone would wrongly accept any two structs / any two arrays).
    if (sub.isConcrete() and sup.isConcrete())
        return module.isSubtype(sub.concreteIndex(), sup.concreteIndex());
    // Abstract sup (or abstract sub): compare on the family hierarchy. A concrete
    // sub matches an abstract sup by its family head (`(ref $struct)` <: structref
    // / eqref / anyref); an abstract sub only satisfies a concrete sup when it is
    // the bottom `none`.
    if (sub.isConcrete()) return sub.refHeap().sub(sup.refHeap());
    if (sup.isConcrete()) return sub.refHeap() == .none;
    return sub.refHeap().sub(sup.refHeap());
}

/// True if an abstract stack entry is a concrete reference type (funcref /
/// externref). Unknown (polymorphic) entries are not — they can't be pinned.
fn isRefStack(st: StackType) bool {
    return switch (st) {
        .val => |v| v.isRef(),
        .unknown => false,
    };
}

// Common operand lists, in stack bottom→top order.
const empty: []const V = &.{};
const i32_1: []const V = &.{.i32};
const i32_2: []const V = &.{ .i32, .i32 };
const i64_1: []const V = &.{.i64};
const i64_2: []const V = &.{ .i64, .i64 };
const f32_1: []const V = &.{.f32};
const f32_2: []const V = &.{ .f32, .f32 };
const f64_1: []const V = &.{.f64};
const f64_2: []const V = &.{ .f64, .f64 };
const store_i64: []const V = &.{ .i32, .i64 }; // addr, value
const store_f32: []const V = &.{ .i32, .f32 };
const store_f64: []const V = &.{ .i32, .f64 };
const v128_1: []const V = &.{.v128};
const v128_2: []const V = &.{ .v128, .v128 };
const v128_3: []const V = &.{ .v128, .v128, .v128 };
const v128_shift: []const V = &.{ .v128, .i32 }; // vector, shift amount
const addr_v128: []const V = &.{ .i32, .v128 }; // store / lane load-store: addr, vector

fn sig(pop: []const V, push: []const V) FuncValidator.Sig {
    return .{ .pop = pop, .push = push };
}

/// Value-type signature of a `0xFD` SIMD op (by sub-opcode). Total — an
/// unclassified op defaults to the common binary shape `v128,v128 -> v128`;
/// that only affects functions using unimplemented ops, which trap at execution
/// before the annotation is used (see `interp` drop/select width handling).
fn simdSig(sub: u32) FuncValidator.Sig {
    return switch (sub) {
        0x00...0x0a, 0x5c, 0x5d => sig(i32_1, v128_1), // loads: addr -> v128
        0x0b => sig(addr_v128, empty), // v128.store
        0x54...0x57 => sig(addr_v128, v128_1), // load lane
        0x58...0x5b => sig(addr_v128, empty), // store lane
        0x0c => sig(empty, v128_1), // v128.const
        0x0d, 0x0e => sig(v128_2, v128_1), // shuffle / swizzle
        0x0f, 0x10, 0x11 => sig(i32_1, v128_1), // i8/i16/i32 splat
        0x12 => sig(i64_1, v128_1), // i64x2.splat
        0x13 => sig(f32_1, v128_1), // f32x4.splat
        0x14 => sig(f64_1, v128_1), // f64x2.splat
        0x15, 0x16, 0x18, 0x19, 0x1b => sig(v128_1, i32_1), // extract_lane -> i32
        0x1d => sig(v128_1, i64_1),
        0x1f => sig(v128_1, f32_1),
        0x21 => sig(v128_1, f64_1),
        0x17, 0x1a, 0x1c => sig(&.{ .v128, .i32 }, v128_1), // replace_lane
        0x1e => sig(&.{ .v128, .i64 }, v128_1),
        0x20 => sig(&.{ .v128, .f32 }, v128_1),
        0x22 => sig(&.{ .v128, .f64 }, v128_1),
        0x23...0x4c => sig(v128_2, v128_1), // comparisons
        0x4d => sig(v128_1, v128_1), // v128.not
        0x4e...0x51 => sig(v128_2, v128_1), // and/andnot/or/xor
        0x52, 0x105...0x10c, 0x113 => sig(v128_3, v128_1), // bitselect + relaxed madd/nmadd/laneselect/dot_add
        0x53, 0x63, 0x83, 0xa3, 0xc3 => sig(v128_1, i32_1), // any_true / all_true
        0x64, 0x84, 0xa4, 0xc4 => sig(v128_1, i32_1), // bitmask
        0x6b...0x6d, 0x8b...0x8d, 0xab...0xad, 0xcb...0xcd => sig(v128_shift, v128_1), // shifts
        // unary v128 -> v128: abs/neg/popcnt, sqrt, ceil/floor/trunc/nearest,
        // extend low/high, extadd_pairwise, int<->float convert, trunc_sat,
        // promote/demote. (Arity here must match the interpreter, or the
        // drop/select width tracking downstream mis-counts v128 operands.)
        0x60, 0x61, 0x62, 0x80, 0x81, 0xa0, 0xa1, 0xc0, 0xc1, 0xe0, 0xe1, 0xe3, 0xec, 0xed, 0xef, 0x67, 0x68, 0x69, 0x6a, 0x74, 0x75, 0x7a, 0x94, 0x87, 0x88, 0x89, 0x8a, 0xa7, 0xa8, 0xa9, 0xaa, 0xc7, 0xc8, 0xc9, 0xca, 0x7c, 0x7d, 0x7e, 0x7f, 0x5e, 0x5f, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff, 0x101, 0x102, 0x103, 0x104 => sig(v128_1, v128_1), // (incl. relaxed_trunc)
        else => sig(v128_2, v128_1), // default: binary lane arithmetic (incl. relaxed swizzle/min/max/q15/dot)
    };
}

/// Fixed value-type signature for the numeric / comparison / conversion /
/// const / load / store / memory opcodes. Returns null for opcodes handled
/// specially in `step` (control flow, variable, call, drop, select).
fn simpleSig(op: Op) ?FuncValidator.Sig {
    return switch (@intFromEnum(op)) {
        // Comparisons
        0x45 => sig(i32_1, i32_1), // i32.eqz
        0x46...0x4f => sig(i32_2, i32_1),
        0x50 => sig(i64_1, i32_1), // i64.eqz
        0x51...0x5a => sig(i64_2, i32_1),
        0x5b...0x60 => sig(f32_2, i32_1),
        0x61...0x66 => sig(f64_2, i32_1),
        // Numeric
        0x67...0x69 => sig(i32_1, i32_1), // i32 clz/ctz/popcnt
        0x6a...0x78 => sig(i32_2, i32_1), // i32 binops
        0x79...0x7b => sig(i64_1, i64_1), // i64 clz/ctz/popcnt
        0x7c...0x8a => sig(i64_2, i64_1), // i64 binops
        0x8b...0x91 => sig(f32_1, f32_1), // f32 unops
        0x92...0x98 => sig(f32_2, f32_1), // f32 binops
        0x99...0x9f => sig(f64_1, f64_1), // f64 unops
        0xa0...0xa6 => sig(f64_2, f64_1), // f64 binops
        // Conversions
        0xa7 => sig(i64_1, i32_1), // i32.wrap_i64
        0xa8, 0xa9 => sig(f32_1, i32_1), // i32.trunc_f32
        0xaa, 0xab => sig(f64_1, i32_1), // i32.trunc_f64
        0xac, 0xad => sig(i32_1, i64_1), // i64.extend_i32
        0xae, 0xaf => sig(f32_1, i64_1), // i64.trunc_f32
        0xb0, 0xb1 => sig(f64_1, i64_1), // i64.trunc_f64
        // Saturating truncation (internal tags for `0xFC 0x00–0x07`).
        0xc5, 0xc6 => sig(f32_1, i32_1), // i32.trunc_sat_f32_s/u
        0xc7, 0xc8 => sig(f64_1, i32_1), // i32.trunc_sat_f64_s/u
        0xc9, 0xca => sig(f32_1, i64_1), // i64.trunc_sat_f32_s/u
        0xcb, 0xcc => sig(f64_1, i64_1), // i64.trunc_sat_f64_s/u
        0xb2, 0xb3 => sig(i32_1, f32_1), // f32.convert_i32
        0xb4, 0xb5 => sig(i64_1, f32_1), // f32.convert_i64
        0xb6 => sig(f64_1, f32_1), // f32.demote_f64
        0xb7, 0xb8 => sig(i32_1, f64_1), // f64.convert_i32
        0xb9, 0xba => sig(i64_1, f64_1), // f64.convert_i64
        0xbb => sig(f32_1, f64_1), // f64.promote_f32
        0xbc => sig(f32_1, i32_1), // i32.reinterpret_f32
        0xbd => sig(f64_1, i64_1), // i64.reinterpret_f64
        0xbe => sig(i32_1, f32_1), // f32.reinterpret_i32
        0xbf => sig(i64_1, f64_1), // f64.reinterpret_i64
        // Sign extension
        0xc0, 0xc1 => sig(i32_1, i32_1),
        0xc2, 0xc3, 0xc4 => sig(i64_1, i64_1),
        // Constants
        0x41 => sig(empty, i32_1),
        0x42 => sig(empty, i64_1),
        0x43 => sig(empty, f32_1),
        0x44 => sig(empty, f64_1),
        // Loads: [i32 addr] -> [value]
        0x28, 0x2c, 0x2d, 0x2e, 0x2f => sig(i32_1, i32_1), // i32.load / load8 / load16
        0x29, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 => sig(i32_1, i64_1), // i64.load*
        0x2a => sig(i32_1, f32_1), // f32.load
        0x2b => sig(i32_1, f64_1), // f64.load
        // Stores: [i32 addr, value] -> []
        0x36, 0x3a, 0x3b => sig(i32_2, empty), // i32.store / store8 / store16
        0x37, 0x3c, 0x3d, 0x3e => sig(store_i64, empty), // i64.store*
        0x38 => sig(store_f32, empty), // f32.store
        0x39 => sig(store_f64, empty), // f64.store
        // Memory
        0x3f => sig(empty, i32_1), // memory.size
        0x40 => sig(i32_1, i32_1), // memory.grow
        else => null,
    };
}

// --- Tests -----------------------------------------------------------------

test "validates a well-typed add function" {
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x0b, 0x01, 0x09, 0x01, 0x01, 0x7f, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00 };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try validate(std.testing.allocator, &m);
}

test "rejects a stack underflow (i32.add with no operands)" {
    // type ()->() ; one func ; body: i32.add end
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x05, 0x01, 0x03, 0x00, 0x6a, 0x0b };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.StackUnderflow, validate(std.testing.allocator, &m));
}

test "rejects a result type mismatch (returns f32 for i32)" {
    // type ()->(i32) ; body: f32.const 0 end  -> end expects [i32], finds [f32]
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f } ++ // ()->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        // body: f32.const 0x00000000 (0x43 00 00 00 00) end
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x43, 0x00, 0x00, 0x00, 0x00, 0x0b };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(std.testing.allocator, &m));
}

test "rejects function/code count mismatch" {
    // function section declares 1 func, but no code section
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.CountMismatch, validate(std.testing.allocator, &m));
}

test "resource caps: a huge locals run and deep nesting are refused, not expanded" {
    // Both are amplifiers a tiny module can trigger, and the snapshot cost is
    // their PRODUCT (each control frame dupes the whole local-init vector).
    // Before the caps, a 512 KB module drove ~767 MB peak on the inspect path.
    const gpa = std.testing.allocator;

    // (func) with one locals run of count 0xFFFFFFFF — 37 bytes total.
    const many_locals = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x0a, 0x01, 0x08, 0x01, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x7f, 0x0b };
    {
        var m = try Module.decode(gpa, &many_locals);
        defer m.deinit();
        try std.testing.expectError(error.TooManyLocals, validate(gpa, &m));
    }

    // A body of `block` × (max_ctrl_depth + 1) then matching `end`s.
    {
        const depth = max_ctrl_depth + 1;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x00); // no locals
        for (0..depth) |_| try body.appendSlice(gpa, &.{ 0x02, 0x40 }); // block (empty type)
        for (0..depth) |_| try body.append(gpa, 0x0b); // end
        try body.append(gpa, 0x0b); // function's own end

        var sec: std.ArrayList(u8) = .empty;
        defer sec.deinit(gpa);
        try sec.append(gpa, 0x01); // one body
        var lenbuf: [5]u8 = undefined;
        var n: usize = 0;
        var v: u32 = @intCast(body.items.len);
        while (true) : (n += 1) { // uleb128
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            lenbuf[n] = if (v != 0) b | 0x80 else b;
            if (v == 0) break;
        }
        try sec.appendSlice(gpa, lenbuf[0 .. n + 1]);
        try sec.appendSlice(gpa, body.items);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
        try bytes.appendSlice(gpa, &.{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 });
        try bytes.appendSlice(gpa, &.{ 0x03, 0x02, 0x01, 0x00 });
        try bytes.append(gpa, 0x0a);
        var slen: [5]u8 = undefined;
        var sn: usize = 0;
        var sv: u32 = @intCast(sec.items.len);
        while (true) : (sn += 1) {
            const b: u8 = @intCast(sv & 0x7f);
            sv >>= 7;
            slen[sn] = if (sv != 0) b | 0x80 else b;
            if (sv == 0) break;
        }
        try bytes.appendSlice(gpa, slen[0 .. sn + 1]);
        try bytes.appendSlice(gpa, sec.items);

        var m = try Module.decode(gpa, bytes.items);
        defer m.deinit();
        try std.testing.expectError(error.NestingTooDeep, validate(gpa, &m));
    }
}
