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

pub const Error = Module.Error || error{
    CountMismatch,
    TypeMismatch,
    StackUnderflow,
    StackHeightMismatch,
    ControlUnderflow,
    UnknownLabel,
    MismatchedElse,
    UndefinedLocal,
    UndefinedGlobal,
    ImmutableGlobal,
    UndefinedFunc,
    UndefinedType,
    UndefinedTable,
    UndefinedElem,
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
            if (tet != elem.elem_type) return error.TypeMismatch;
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
        if (type_index >= module.func_types.len) return error.UndefinedType;
        try validateFunction(arena.allocator(), module, module.func_types[type_index], code);
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
                const ht: V = @enumFromInt(try r.readByte());
                try push(&stack, &sp, ht);
            },
            0xd2 => { // ref.func x
                const fi = try r.readVarU32();
                if (module.funcType(fi) == null) return error.UndefinedFunc;
                try push(&stack, &sp, .funcref);
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
    if (sp != 1 or stack[0] != expected) return error.TypeMismatch;
}

fn validateFunction(a: std.mem.Allocator, module: *const Module, ft: Module.FuncType, code: Module.Code) Error!void {
    // locals = parameters ++ declared locals (expanded from run-length form).
    var locals: std.ArrayList(V) = .empty;
    try locals.appendSlice(a, ft.params);
    for (code.locals) |l| {
        var n = l.count;
        while (n > 0) : (n -= 1) try locals.append(a, l.type);
    }

    const instrs = try opcode.decodeBody(a, code.body);

    var v: FuncValidator = .{ .a = a, .module = module, .locals = locals.items, .results = ft.results };
    // The whole body is an implicit block of type [] -> results; its trailing
    // `end` closes this frame.
    try v.pushCtrl(.block, empty, ft.results);
    for (instrs) |instr| try v.step(instr);
    if (v.ctrls.items.len != 0) return error.ControlUnderflow; // missing `end`
}

// --- The validation algorithm ---------------------------------------------

const StackType = union(enum) { val: V, unknown };

const FrameKind = enum { block, loop, if_, else_ };

const Frame = struct {
    kind: FrameKind,
    start: []const V,
    end: []const V,
    height: usize,
    is_unreachable: bool,
};

const FuncValidator = struct {
    a: std.mem.Allocator,
    module: *const Module,
    locals: []const V,
    results: []const V,
    vals: std.ArrayList(StackType) = .empty,
    ctrls: std.ArrayList(Frame) = .empty,

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
            .val => |t| if (t != expect) return error.TypeMismatch,
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
            .val => |v| if (v != .funcref and v != .externref) return error.TypeMismatch,
            .unknown => {},
        }
        return st;
    }

    fn pushCtrl(self: *FuncValidator, kind: FrameKind, start: []const V, end: []const V) Error!void {
        try self.ctrls.append(self.a, .{
            .kind = kind,
            .start = start,
            .end = end,
            .height = self.vals.items.len,
            .is_unreachable = false,
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
                if (i >= self.module.func_types.len) return error.UndefinedType;
                const ft = self.module.func_types[i];
                break :blk .{ .pop = ft.params, .push = ft.results };
            },
        };
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
            .@"else" => {
                const frame = try self.popCtrl();
                if (frame.kind != .if_) return error.MismatchedElse;
                try self.pushCtrl(.else_, frame.start, frame.end);
            },
            .end => {
                const frame = try self.popCtrl();
                // An `if` closed without an `else` has an implicit identity else
                // branch, which requires the param and result types to match.
                if (frame.kind == .if_ and !std.mem.eql(V, frame.start, frame.end)) return error.TypeMismatch;
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
                if (ci.type_index >= self.module.func_types.len) return error.UndefinedType;
                const ft = self.module.func_types[ci.type_index];
                _ = try self.popExpect(.i32);
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },

            .drop => _ = try self.popVal(),
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
                try self.pushValT(tys[0]);
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
            .table_copy => {
                const dt = try self.tableElemType(instr.imm.table_copy.dst);
                const st = try self.tableElemType(instr.imm.table_copy.src);
                if (dt != st) return error.TypeMismatch;
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src
                _ = try self.popExpect(.i32); // dst
            },

            .ref_null => try self.pushValT(instr.imm.ref_type),
            .ref_is_null => {
                switch (try self.popVal()) { // requires a reference type (or polymorphic)
                    .val => |v| if (v != .funcref and v != .externref) return error.TypeMismatch,
                    .unknown => {},
                }
                try self.pushValT(.i32);
            },
            .ref_func => {
                if (self.module.funcType(instr.imm.func) == null) return error.UndefinedFunc;
                try self.pushValT(.funcref);
            },

            // Typed function references (function-references proposal). A typed
            // func ref collapses to `funcref` in our model (see the decoder P1).
            .call_ref => {
                if (instr.imm.func >= self.module.func_types.len) return error.UndefinedType;
                const ft = self.module.func_types[instr.imm.func];
                _ = try self.popExpect(.funcref); // the function reference (top)
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },
            .return_call_ref => {
                if (instr.imm.func >= self.module.func_types.len) return error.UndefinedType;
                const ft = self.module.func_types[instr.imm.func];
                _ = try self.popExpect(.funcref);
                try self.popVals(ft.params);
                if (!valTypesEqual(ft.results, self.results)) return error.TypeMismatch;
                self.setUnreachable();
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

            .local_get => try self.pushValT(try self.localAt(instr.imm.local)),
            .local_set => _ = try self.popExpect(try self.localAt(instr.imm.local)),
            .local_tee => {
                const t = try self.localAt(instr.imm.local);
                _ = try self.popExpect(t);
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
                    if (instr.imm.mem.alignment > naturalAlignLog2(instr.op)) return error.InvalidAlignment;
                }
                const s = simpleSig(instr.op) orelse return error.UnsupportedOpcode;
                try self.popVals(s.pop);
                try self.pushVals(s.push);
            },
        }
    }
};

/// Natural alignment (log2 of the access size in bytes) for a load/store opcode.
fn naturalAlignLog2(op: Op) u32 {
    return switch (op) {
        .i32_load8_s, .i32_load8_u, .i64_load8_s, .i64_load8_u, .i32_store8, .i64_store8 => 0,
        .i32_load16_s, .i32_load16_u, .i64_load16_s, .i64_load16_u, .i32_store16, .i64_store16 => 1,
        .i32_load, .f32_load, .i32_store, .f32_store, .i64_load32_s, .i64_load32_u, .i64_store32 => 2,
        .i64_load, .f64_load, .i64_store, .f64_store => 3,
        else => 0,
    };
}

fn valTypesEqual(a: []const V, b: []const V) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// True if an abstract stack entry is a concrete reference type (funcref /
/// externref). Unknown (polymorphic) entries are not — they can't be pinned.
fn isRefStack(st: StackType) bool {
    return switch (st) {
        .val => |v| v == .funcref or v == .externref,
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

fn sig(pop: []const V, push: []const V) FuncValidator.Sig {
    return .{ .pop = pop, .push = push };
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
