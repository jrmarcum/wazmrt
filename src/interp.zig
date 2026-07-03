//! Execution: instantiate a validated module and run its functions with a
//! switch-dispatched interpreter over the `opcode.zig` IR (interpreter
//! architecture = Option A; see `cmem/design-decisions.md`).
//!
//! Values are untyped `u64` slots — validation has already proven the types, so
//! the stack carries raw bits and each opcode reinterprets. Control flow uses a
//! per-call label stack plus a branch-target table precomputed once per function
//! at instantiation (matching `end`/`else` for every `block`/`loop`/`if`).
//!
//! **Scope today:** integer core-MVP — i32/i64 arithmetic, comparison, bitwise,
//! integer conversions, locals, globals (zero-initialized for now), `drop`,
//! `select`, structured control flow, and direct `call`. Float ops, memory
//! load/store, `call_indirect`, and host-import calls trap with a clear error;
//! they are the next execution slices.

const std = @import("std");
const types = @import("types.zig");
const Module = @import("Module.zig");
const opcode = @import("opcode.zig");

const V = types.ValType;
const Op = opcode.Op;

/// A runtime value: a raw 64-bit slot reinterpreted per the (validated) type.
pub const Value = u64;

pub fn i32Value(x: i32) Value {
    return @as(u32, @bitCast(x));
}
pub fn asI32(v: Value) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}
pub fn i64Value(x: i64) Value {
    return @bitCast(x);
}
pub fn asI64(v: Value) i64 {
    return @bitCast(v);
}

pub const Error = Module.Error || error{
    /// `unreachable` executed.
    Unreachable,
    /// Integer division or remainder by zero.
    DivByZero,
    /// Signed division overflow (INT_MIN / -1).
    IntOverflow,
    /// Recursion exceeded the interpreter's call-depth limit.
    CallStackExhausted,
    /// No exported function with the requested name.
    UndefinedExport,
    /// The named export is not a function.
    ExportNotFunction,
    /// Wrong number of arguments for the invoked function.
    BadArgCount,
    /// Function index out of range (should not happen post-validation).
    UndefinedFunc,
    /// Calling an imported (host) function — not yet supported.
    UnsupportedImportCall,
    /// An opcode this interpreter slice does not execute yet (floats, memory,
    /// call_indirect).
    UnsupportedInstruction,
};

const max_call_depth = 1024;

const Label = struct {
    is_loop: bool,
    /// Values carried on a branch: results for block/if, params for loop.
    arity: u32,
    /// pc to jump to on a branch to this label.
    target: usize,
    /// Value-stack height below this construct's operands.
    stack_base: usize,
};

/// A defined function prepared for execution.
const FuncBody = struct {
    type: Module.FuncType,
    num_locals: usize, // params + declared locals
    ir: []const opcode.Instr,
    /// For each `block`/`loop`/`if`/`else` index: the matching `end` index.
    end_of: []const usize,
    /// For each `if` index: the `else` index, or `ir.len` if none.
    else_of: []const usize,
};

pub const Instance = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    module: *const Module,
    func_bodies: []FuncBody,
    globals: []Value,
    imported_funcs: u32,

    pub fn init(gpa: std.mem.Allocator, module: *const Module) Error!Instance {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const bodies = try a.alloc(FuncBody, module.functions.len);
        for (module.functions, module.code, bodies) |type_index, code, *body| {
            const ft = module.func_types[type_index];
            var num_locals: usize = ft.params.len;
            for (code.locals) |l| num_locals += l.count;

            const ir = try opcode.decodeBody(a, code.body);
            const cf = try precomputeControlFlow(a, ir);
            body.* = .{
                .type = ft,
                .num_locals = num_locals,
                .ir = ir,
                .end_of = cf.end_of,
                .else_of = cf.else_of,
            };
        }

        const globals = try a.alloc(Value, module.globals.len);
        @memset(globals, 0); // TODO: evaluate global init expressions

        return .{
            .gpa = gpa,
            .arena = arena,
            .module = module,
            .func_bodies = bodies,
            .globals = globals,
            .imported_funcs = module.importedFuncCount(),
        };
    }

    pub fn deinit(self: *Instance) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Invoke an exported function by name. The returned result slice is owned
    /// by the caller (allocated with the instance's gpa).
    pub fn invoke(self: *Instance, name: []const u8, args: []const Value) Error![]Value {
        const func_index = self.findExportedFunc(name) orelse return error.UndefinedExport;
        const ft = self.module.funcType(func_index) orelse return error.UndefinedFunc;
        if (args.len != ft.params.len) return error.BadArgCount;

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const results = try self.callFunction(scratch.allocator(), func_index, args, 0);

        const owned = try self.gpa.alloc(Value, results.len);
        @memcpy(owned, results);
        return owned;
    }

    fn findExportedFunc(self: *Instance, name: []const u8) ?u32 {
        for (self.module.exports) |e| {
            if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    fn callFunction(self: *Instance, a: std.mem.Allocator, func_index: u32, args: []const Value, depth: usize) Error![]Value {
        if (depth > max_call_depth) return error.CallStackExhausted;
        if (func_index < self.imported_funcs) return error.UnsupportedImportCall;
        const defined = func_index - self.imported_funcs;
        if (defined >= self.func_bodies.len) return error.UndefinedFunc;
        const body = &self.func_bodies[defined];

        const locals = try a.alloc(Value, body.num_locals);
        @memset(locals, 0);
        @memcpy(locals[0..args.len], args);

        var frame: Frame = .{ .inst = self, .a = a, .body = body, .locals = locals, .depth = depth };
        try frame.labels.append(a, .{
            .is_loop = false,
            .arity = @intCast(body.type.results.len),
            .target = body.ir.len,
            .stack_base = 0,
        });
        try frame.run();

        const n = body.type.results.len;
        const res = try a.alloc(Value, n);
        @memcpy(res, frame.vstack.items[frame.vstack.items.len - n ..]);
        return res;
    }
};

fn precomputeControlFlow(a: std.mem.Allocator, ir: []const opcode.Instr) Error!struct { end_of: []usize, else_of: []usize } {
    const end_of = try a.alloc(usize, ir.len);
    const else_of = try a.alloc(usize, ir.len);
    @memset(end_of, 0);
    @memset(else_of, ir.len); // sentinel = "no else"

    var stack: std.ArrayList(usize) = .empty;
    for (ir, 0..) |instr, i| {
        switch (instr.op) {
            .block, .loop, .@"if" => try stack.append(a, i),
            .@"else" => else_of[stack.items[stack.items.len - 1]] = i,
            .end => {
                if (stack.items.len == 0) continue; // the function's implicit end
                const opener = stack.pop().?;
                end_of[opener] = i;
                if (else_of[opener] != ir.len) end_of[else_of[opener]] = i;
            },
            else => {},
        }
    }
    return .{ .end_of = end_of, .else_of = else_of };
}

const Frame = struct {
    inst: *Instance,
    a: std.mem.Allocator,
    body: *const FuncBody,
    locals: []Value,
    depth: usize,
    vstack: std.ArrayList(Value) = .empty,
    labels: std.ArrayList(Label) = .empty,

    fn pushU64(self: *Frame, v: Value) Error!void {
        try self.vstack.append(self.a, v);
    }
    fn pop(self: *Frame) Value {
        return self.vstack.pop().?;
    }
    fn pushI32(self: *Frame, v: i32) Error!void {
        try self.pushU64(i32Value(v));
    }
    fn popI32(self: *Frame) i32 {
        return asI32(self.pop());
    }
    fn pushI64(self: *Frame, v: i64) Error!void {
        try self.pushU64(i64Value(v));
    }
    fn popI64(self: *Frame) i64 {
        return asI64(self.pop());
    }

    fn branch(self: *Frame, n: u32) usize {
        const label = self.labels.items[self.labels.items.len - 1 - n];
        const from = self.vstack.items.len - label.arity;
        std.mem.copyForwards(Value, self.vstack.items[label.stack_base..][0..label.arity], self.vstack.items[from..][0..label.arity]);
        self.vstack.shrinkRetainingCapacity(label.stack_base + label.arity);
        // A loop-continue keeps the loop's own label; a forward exit pops it too.
        const keep = if (label.is_loop) self.labels.items.len - n else self.labels.items.len - (n + 1);
        self.labels.shrinkRetainingCapacity(keep);
        return label.target;
    }

    fn blockArity(self: *Frame, bt: opcode.BlockType, comptime want_params: bool) u32 {
        return switch (bt) {
            .empty => 0,
            .value => if (want_params) 0 else 1,
            .type_index => |i| @intCast(if (want_params) self.inst.module.func_types[i].params.len else self.inst.module.func_types[i].results.len),
        };
    }

    fn run(self: *Frame) Error!void {
        const ir = self.body.ir;
        var pc: usize = 0;
        while (pc < ir.len) {
            const instr = ir[pc];
            switch (instr.op) {
                .nop => pc += 1,
                .@"unreachable" => return error.Unreachable,
                .drop => {
                    _ = self.pop();
                    pc += 1;
                },
                .select => {
                    const c = self.popI32();
                    const b = self.pop();
                    const av = self.pop();
                    try self.pushU64(if (c != 0) av else b);
                    pc += 1;
                },

                // --- Structured control flow ---
                .block => {
                    const params = self.blockArity(instr.imm.block_type, true);
                    try self.labels.append(self.a, .{ .is_loop = false, .arity = self.blockArity(instr.imm.block_type, false), .target = self.body.end_of[pc] + 1, .stack_base = self.vstack.items.len - params });
                    pc += 1;
                },
                .loop => {
                    const params = self.blockArity(instr.imm.block_type, true);
                    try self.labels.append(self.a, .{ .is_loop = true, .arity = params, .target = pc + 1, .stack_base = self.vstack.items.len - params });
                    pc += 1;
                },
                .@"if" => {
                    const c = self.popI32();
                    const params = self.blockArity(instr.imm.block_type, true);
                    try self.labels.append(self.a, .{ .is_loop = false, .arity = self.blockArity(instr.imm.block_type, false), .target = self.body.end_of[pc] + 1, .stack_base = self.vstack.items.len - params });
                    if (c != 0) {
                        pc += 1;
                    } else {
                        const else_idx = self.body.else_of[pc];
                        pc = if (else_idx != ir.len) else_idx + 1 else self.body.end_of[pc];
                    }
                },
                .@"else" => pc = self.body.end_of[pc], // end of then-branch: skip to matching end
                .end => {
                    _ = self.labels.pop();
                    pc += 1;
                },
                .br => pc = self.branch(instr.imm.label),
                .br_if => {
                    if (self.popI32() != 0) pc = self.branch(instr.imm.label) else pc += 1;
                },
                .br_table => {
                    const i = self.popI32();
                    const t = instr.imm.br_table;
                    const idx: u32 = if (i >= 0 and @as(usize, @intCast(i)) < t.labels.len) t.labels[@intCast(i)] else t.default;
                    pc = self.branch(idx);
                },
                .@"return" => pc = ir.len,

                .call => {
                    const f = instr.imm.func;
                    const ft = self.inst.module.funcType(f) orelse return error.UndefinedFunc;
                    const np = ft.params.len;
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = try self.inst.callFunction(self.a, f, args, self.depth + 1);
                    self.vstack.shrinkRetainingCapacity(self.vstack.items.len - np);
                    for (results) |r| try self.pushU64(r);
                    pc += 1;
                },

                // --- Variables ---
                .local_get => {
                    try self.pushU64(self.locals[instr.imm.local]);
                    pc += 1;
                },
                .local_set => {
                    self.locals[instr.imm.local] = self.pop();
                    pc += 1;
                },
                .local_tee => {
                    self.locals[instr.imm.local] = self.vstack.items[self.vstack.items.len - 1];
                    pc += 1;
                },
                .global_get => {
                    try self.pushU64(self.inst.globals[instr.imm.global]);
                    pc += 1;
                },
                .global_set => {
                    self.inst.globals[instr.imm.global] = self.pop();
                    pc += 1;
                },

                // --- Constants ---
                .i32_const => {
                    try self.pushI32(instr.imm.i32);
                    pc += 1;
                },
                .i64_const => {
                    try self.pushI64(instr.imm.i64);
                    pc += 1;
                },

                else => {
                    try self.execNumeric(instr.op);
                    pc += 1;
                },
            }
        }
    }

    /// The integer arithmetic / comparison / bitwise / conversion opcodes.
    fn execNumeric(self: *Frame, op: Op) Error!void {
        switch (op) {
            // i32 unary
            .i32_eqz => try self.pushI32(@intFromBool(self.popI32() == 0)),
            .i32_clz => try self.pushI32(@clz(@as(u32, @bitCast(self.popI32())))),
            .i32_ctz => try self.pushI32(@ctz(@as(u32, @bitCast(self.popI32())))),
            .i32_popcnt => try self.pushI32(@popCount(@as(u32, @bitCast(self.popI32())))),
            // i32 comparison
            .i32_eq => try self.cmpI32(.eq),
            .i32_ne => try self.cmpI32(.ne),
            .i32_lt_s => try self.cmpI32(.lt_s),
            .i32_lt_u => try self.cmpI32(.lt_u),
            .i32_gt_s => try self.cmpI32(.gt_s),
            .i32_gt_u => try self.cmpI32(.gt_u),
            .i32_le_s => try self.cmpI32(.le_s),
            .i32_le_u => try self.cmpI32(.le_u),
            .i32_ge_s => try self.cmpI32(.ge_s),
            .i32_ge_u => try self.cmpI32(.ge_u),
            // i32 binary
            .i32_add => try self.binI32(.add),
            .i32_sub => try self.binI32(.sub),
            .i32_mul => try self.binI32(.mul),
            .i32_div_s => try self.binI32(.div_s),
            .i32_div_u => try self.binI32(.div_u),
            .i32_rem_s => try self.binI32(.rem_s),
            .i32_rem_u => try self.binI32(.rem_u),
            .i32_and => try self.binI32(.@"and"),
            .i32_or => try self.binI32(.@"or"),
            .i32_xor => try self.binI32(.xor),
            .i32_shl => try self.binI32(.shl),
            .i32_shr_s => try self.binI32(.shr_s),
            .i32_shr_u => try self.binI32(.shr_u),
            .i32_rotl => try self.binI32(.rotl),
            .i32_rotr => try self.binI32(.rotr),
            .i32_extend8_s => try self.pushI32(@as(i8, @truncate(self.popI32()))),
            .i32_extend16_s => try self.pushI32(@as(i16, @truncate(self.popI32()))),
            .i32_wrap_i64 => try self.pushI32(@bitCast(@as(u32, @truncate(@as(u64, @bitCast(self.popI64())))))),

            // i64 unary
            .i64_eqz => try self.pushI32(@intFromBool(self.popI64() == 0)),
            .i64_clz => try self.pushI64(@clz(@as(u64, @bitCast(self.popI64())))),
            .i64_ctz => try self.pushI64(@ctz(@as(u64, @bitCast(self.popI64())))),
            .i64_popcnt => try self.pushI64(@popCount(@as(u64, @bitCast(self.popI64())))),
            // i64 comparison (result i32)
            .i64_eq => try self.cmpI64(.eq),
            .i64_ne => try self.cmpI64(.ne),
            .i64_lt_s => try self.cmpI64(.lt_s),
            .i64_lt_u => try self.cmpI64(.lt_u),
            .i64_gt_s => try self.cmpI64(.gt_s),
            .i64_gt_u => try self.cmpI64(.gt_u),
            .i64_le_s => try self.cmpI64(.le_s),
            .i64_le_u => try self.cmpI64(.le_u),
            .i64_ge_s => try self.cmpI64(.ge_s),
            .i64_ge_u => try self.cmpI64(.ge_u),
            // i64 binary
            .i64_add => try self.binI64(.add),
            .i64_sub => try self.binI64(.sub),
            .i64_mul => try self.binI64(.mul),
            .i64_div_s => try self.binI64(.div_s),
            .i64_div_u => try self.binI64(.div_u),
            .i64_rem_s => try self.binI64(.rem_s),
            .i64_rem_u => try self.binI64(.rem_u),
            .i64_and => try self.binI64(.@"and"),
            .i64_or => try self.binI64(.@"or"),
            .i64_xor => try self.binI64(.xor),
            .i64_shl => try self.binI64(.shl),
            .i64_shr_s => try self.binI64(.shr_s),
            .i64_shr_u => try self.binI64(.shr_u),
            .i64_rotl => try self.binI64(.rotl),
            .i64_rotr => try self.binI64(.rotr),
            .i64_extend8_s => try self.pushI64(@as(i8, @truncate(self.popI64()))),
            .i64_extend16_s => try self.pushI64(@as(i16, @truncate(self.popI64()))),
            .i64_extend32_s => try self.pushI64(@as(i32, @truncate(self.popI64()))),
            .i64_extend_i32_s => try self.pushI64(self.popI32()),
            .i64_extend_i32_u => try self.pushI64(@as(u32, @bitCast(self.popI32()))),

            // Everything else (floats, memory, conversions to/from float,
            // call_indirect, reference types) is a later slice.
            else => return error.UnsupportedInstruction,
        }
    }

    const CmpOp = enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u };
    const BinOp = enum { add, sub, mul, div_s, div_u, rem_s, rem_u, @"and", @"or", xor, shl, shr_s, shr_u, rotl, rotr };

    fn cmpI32(self: *Frame, comptime c: CmpOp) Error!void {
        const b = self.popI32();
        const a = self.popI32();
        const ub: u32 = @bitCast(b);
        const ua: u32 = @bitCast(a);
        const r = switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt_s => a < b,
            .lt_u => ua < ub,
            .gt_s => a > b,
            .gt_u => ua > ub,
            .le_s => a <= b,
            .le_u => ua <= ub,
            .ge_s => a >= b,
            .ge_u => ua >= ub,
        };
        try self.pushI32(@intFromBool(r));
    }

    fn cmpI64(self: *Frame, comptime c: CmpOp) Error!void {
        const b = self.popI64();
        const a = self.popI64();
        const ub: u64 = @bitCast(b);
        const ua: u64 = @bitCast(a);
        const r = switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt_s => a < b,
            .lt_u => ua < ub,
            .gt_s => a > b,
            .gt_u => ua > ub,
            .le_s => a <= b,
            .le_u => ua <= ub,
            .ge_s => a >= b,
            .ge_u => ua >= ub,
        };
        try self.pushI32(@intFromBool(r));
    }

    fn binI32(self: *Frame, comptime o: BinOp) Error!void {
        const b = self.popI32();
        const a = self.popI32();
        try self.pushI32(try applyInt(i32, u32, o, a, b));
    }
    fn binI64(self: *Frame, comptime o: BinOp) Error!void {
        const b = self.popI64();
        const a = self.popI64();
        try self.pushI64(try applyInt(i64, u64, o, a, b));
    }
};

/// Shared integer binary-op semantics for i32 (S=i32,U=u32) and i64.
fn applyInt(comptime S: type, comptime U: type, comptime o: Frame.BinOp, a: S, b: S) Error!S {
    const bits = @typeInfo(S).int.bits;
    const Shift = std.math.Log2Int(U);
    const ua: U = @bitCast(a);
    const ub: U = @bitCast(b);
    return switch (o) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div_s => blk: {
            if (b == 0) return error.DivByZero;
            if (a == std.math.minInt(S) and b == -1) return error.IntOverflow;
            break :blk @divTrunc(a, b);
        },
        .div_u => blk: {
            if (b == 0) return error.DivByZero;
            break :blk @bitCast(ua / ub);
        },
        .rem_s => blk: {
            if (b == 0) return error.DivByZero;
            if (b == -1) break :blk 0; // avoids INT_MIN % -1 overflow; result is 0
            break :blk @rem(a, b);
        },
        .rem_u => blk: {
            if (b == 0) return error.DivByZero;
            break :blk @bitCast(ua % ub);
        },
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .shl => @bitCast(ua << @as(Shift, @intCast(@mod(ub, bits)))),
        .shr_s => a >> @as(Shift, @intCast(@mod(ub, bits))),
        .shr_u => @bitCast(ua >> @as(Shift, @intCast(@mod(ub, bits)))),
        .rotl => @bitCast(std.math.rotl(U, ua, @mod(ub, bits))),
        .rotr => @bitCast(std.math.rotr(U, ua, @mod(ub, bits))),
    };
}

// --- Tests -----------------------------------------------------------------

const Module_decode = Module.decode;

fn instantiate(bytes: []const u8) !Instance {
    const m = try std.testing.allocator.create(Module);
    errdefer std.testing.allocator.destroy(m);
    m.* = try Module_decode(std.testing.allocator, bytes);
    errdefer m.deinit();
    return Instance.init(std.testing.allocator, m);
}

fn destroy(inst: *Instance) void {
    const m = inst.module;
    inst.deinit();
    // free the module we heap-allocated in `instantiate`
    var mm = @constCast(m);
    mm.deinit();
    std.testing.allocator.destroy(mm);
}

test "runs add(a,b) -> a+b" {
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    const r = try inst.invoke("add", &.{ i32Value(10), i32Value(20) });
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 30), asI32(r[0]));

    const r2 = try inst.invoke("add", &.{ i32Value(-5), i32Value(3) });
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqual(@as(i32, -2), asI32(r2[0]));
}

test "runs an if/else (isNonZero)" {
    // (func (param i32) (result i32) (if (result i32) (local.get 0) (i32.const 1) (else i32.const 0)))
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f } ++ // (i32)->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        // body(12): locals(00) local.get0 if(i32) i32.const1 else i32.const0 end end
        [_]u8{ 0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x20, 0x00, 0x04, 0x7f, 0x41, 0x01, 0x05, 0x41, 0x00, 0x0b, 0x0b } ++
        [_]u8{ 0x07, 0x06, 0x01, 0x02, 'n', 'z', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    const r = try inst.invoke("nz", &.{i32Value(5)});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 1), asI32(r[0]));

    const r0 = try inst.invoke("nz", &.{i32Value(0)});
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqual(@as(i32, 0), asI32(r0[0]));
}

test "runs a nested call (quad = double(double(x)))" {
    // func0 double(x)=x+x ; func1 quad(x)=call double; call double
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f } ++ // one type (i32)->(i32)
        [_]u8{ 0x03, 0x03, 0x02, 0x00, 0x00 } ++ // two funcs, both type 0
        [_]u8{ 0x07, 0x08, 0x01, 0x04, 'q', 'u', 'a', 'd', 0x00, 0x01 } ++ // export quad = func 1
        // code: double body(7) (local.get0 local.get0 i32.add end); quad body(8) (local.get0 call0 call0 end)
        [_]u8{ 0x0a, 0x12, 0x02, 0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x6a, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x10, 0x00, 0x10, 0x00, 0x0b };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    const r = try inst.invoke("quad", &.{i32Value(5)});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 20), asI32(r[0]));
}

test "runs a br out of a block" {
    // (func (result i32) (block (result i32) i32.const 42 br 0))
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f } ++ // ()->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        // body: block (result i32) ; i32.const 42 ; br 0 ; end ; end
        [_]u8{ 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x02, 0x7f, 0x41, 0x2a, 0x0c, 0x00, 0x0b, 0x0b } ++
        [_]u8{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 42), asI32(r[0]));
}

test "traps on division by zero" {
    // (func (param i32 i32) (result i32) local.get0 local.get1 i32.div_s)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6d, 0x0b } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'd', 'i', 'v', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);
    try std.testing.expectError(error.DivByZero, inst.invoke("div", &.{ i32Value(1), i32Value(0) }));
}
