//! Execution: instantiate a validated module and run its functions with a
//! switch-dispatched interpreter over the `opcode.zig` IR (interpreter
//! architecture = Option A; see `cmem/design-decisions.md`).
//!
//! Values are untyped `u64` slots — validation has already proven the types, so
//! the stack carries raw bits and each opcode reinterprets. Control flow uses a
//! per-call label stack plus a branch-target table precomputed once per function
//! at instantiation (matching `end`/`else` for every `block`/`loop`/`if`).
//!
//! **Scope today:** the core-MVP instruction set plus reference types — i32/i64/
//! f32/f64 numeric ops, locals, globals (init const-exprs evaluated, incl.
//! extended-const and imported-global values), linear memory, `drop`/`select`,
//! structured control flow, direct `call`, `call_indirect` over multiple tables,
//! and `ref.null`/`ref.is_null`/`ref.func`. Imported *functions* still trap
//! (`UnsupportedImportCall`) — host-function calls are the next execution slice.

const std = @import("std");
const types = @import("types.zig");
const Module = @import("Module.zig");
const opcode = @import("opcode.zig");
const Reader = @import("Reader.zig");

const V = types.ValType;
const Op = opcode.Op;

/// WebAssembly linear-memory page size (64 KiB).
pub const page_size = 64 * 1024;

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
pub fn f32Value(x: f32) Value {
    return @as(u32, @bitCast(x));
}
pub fn asF32(v: Value) f32 {
    return @bitCast(@as(u32, @truncate(v)));
}
pub fn f64Value(x: f64) Value {
    return @bitCast(x);
}
pub fn asF64(v: Value) f64 {
    return @bitCast(v);
}

/// Narrow a value to a GC field's storage width before storing (packed i8/i16
/// keep only their low bits; unpacked stores verbatim).
fn packField(storage: Module.StorageType, v: Value) Value {
    return switch (storage) {
        .val => v,
        .i8 => v & 0xff,
        .i16 => v & 0xffff,
    };
}

/// Widen a stored GC field value back to an i32 slot: `_s` sign-extends a packed
/// field, `_u` zero-extends; an unpacked field is returned verbatim.
fn unpackField(storage: Module.StorageType, v: Value, signed: bool) Value {
    return switch (storage) {
        .val => v,
        .i8 => if (signed) i32Value(@as(i8, @bitCast(@as(u8, @truncate(v))))) else i32Value(@as(i32, @as(u8, @truncate(v)))),
        .i16 => if (signed) i32Value(@as(i16, @bitCast(@as(u16, @truncate(v))))) else i32Value(@as(i32, @as(u16, @truncate(v)))),
    };
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
    /// Wrong number of arguments for the invoked function.
    BadArgCount,
    /// Function index out of range (should not happen post-validation).
    UndefinedFunc,
    /// Calling an imported (host) function — not yet supported.
    UnsupportedImportCall,
    /// An imported table/memory was declared but no host backing was supplied.
    MissingImport,
    /// An opcode this interpreter slice does not execute yet (e.g. an unhandled
    /// const-expr opcode, or a `0xFC`/SIMD op with no runtime support).
    UnsupportedInstruction,
    /// A float→int truncation of NaN, infinity, or an out-of-range value.
    InvalidConversionToInt,
    /// A memory access (or data-segment init) outside the memory bounds.
    MemoryOutOfBounds,
    /// A memory instruction in a module with no linear memory.
    NoMemory,
    /// A global index out of range (e.g. in a data-segment offset expression).
    UndefinedGlobal,
    /// `call_indirect` in a module with no table.
    NoTable,
    /// A null reference where a non-null one is required (`call_ref` /
    /// `ref.as_non_null` on null).
    NullReference,
    /// A table access (or element-segment init) outside the table bounds.
    TableOutOfBounds,
    /// `call_indirect` hit an uninitialized (null) table element.
    UninitializedElement,
    /// `call_indirect`'s declared type did not match the callee's signature.
    IndirectTypeMismatch,
    /// A type index out of range.
    UndefinedType,
    /// A GC struct field / array element access outside the object's bounds
    /// (`array.get`/`.set` past the length, or a field index beyond a collapsed
    /// object's fields). Traps.
    GcOutOfBounds,
    /// `ref.cast` to a type the value is not an instance of. Traps.
    CastFailure,
    /// A host-function import callback signaled a trap (C ABI `wasm_func_new`).
    HostTrap,
};

/// Null reference sentinel — on the value stack (`ref.null`) and as an
/// uninitialized table entry. A funcref value is a function index (always small),
/// and host externref values are boxed to small non-sentinel handles at the host
/// boundary (see the WAST runner's `internExtern`, #9), so neither collides.
///
/// Public because the C ABI speaks this model directly: `wasm_table_get`/`set`
/// translate between table slots and `wasm_ref_t`.
pub const null_ref: Value = std.math.maxInt(u64);

/// Tag bit marking a value slot as an unboxed i31 (full GC). Set on `ref.i31`
/// results so `ref.test`/`ref.cast` can distinguish an i31 from a heap-object
/// index (bit 63 clear) within the `any` hierarchy. `null_ref` (all bits set)
/// is checked before this bit, so the two never confuse.
const i31_tag: Value = @as(Value, 1) << 63;

fn funcTypeEqual(x: Module.FuncType, y: Module.FuncType) bool {
    return std.mem.eql(V, x.params, y.params) and std.mem.eql(V, y.results, x.results);
}

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
    /// Default value of every local slot at function entry: `null_ref` for a
    /// reference-typed local (a nullable ref defaults to null; a non-null ref is
    /// non-defaultable, so validation forbids reading it before a set — the value
    /// is immaterial), `0` for a numeric local. Params are overwritten by args.
    local_defaults: []const Value,
    ir: []const opcode.Instr,
    /// For each `block`/`loop`/`if`/`else` index: the matching `end` index.
    end_of: []const usize,
    /// For each `if` index: the `else` index, or `ir.len` if none.
    else_of: []const usize,
};

/// One frame of a trap's call stack: where execution was when it trapped.
pub const TrapFrame = struct {
    /// Index in the *function index space* (imports included), so it lines up
    /// with the name section and with `call` immediates.
    func_index: u32,
    /// Index of the trapping instruction in the decoded IR — not a byte offset.
    /// Resolve it to one with `Instance.frameOffset` when an external tool needs
    /// a real position (`wasm_frame_func_offset`, `wasm-objdump`).
    pc: usize,
};

/// How many frames of a trap's stack we keep. A fixed buffer, deliberately:
/// recording a trap must not allocate (we may be unwinding an OOM) and must not
/// fail. Deep recursion overflows this, so `trap_depth` records the true depth.
pub const max_trap_frames = 16;

pub const Instance = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    module: *const Module,
    func_bodies: []FuncBody,
    globals: []Value,
    imported_funcs: u32,
    /// Backing callables for imported functions (index-aligned with the first
    /// `imported_funcs` entries of the function index space).
    import_funcs: []const HostFunc,
    /// Linear memory (shared object so an imported memory reflects the exporter's
    /// growth), or null if the module has neither a defined nor imported memory.
    memory: ?*Memory,
    /// True if `memory` is borrowed from an import (owned/freed by the exporter).
    imported_memory: bool,
    /// Reference tables, one shared `*Table` per module table (imports first, so
    /// an imported table reflects the exporter's growth). The outer slice is
    /// `gpa`-owned; `tables[0..imported_tables]` are borrowed objects.
    tables: []*Table,
    /// Count of leading imported tables (borrowed; not freed by this instance).
    imported_tables: u32,
    /// Evaluated reference values of each element segment (for `table.init`);
    /// `elem_dropped[i]` marks a segment consumed (active/declarative at init, or
    /// `elem.drop`), after which it behaves as an empty segment.
    elem_values: []const []Value,
    elem_dropped: []bool,
    /// `data_dropped[i]` marks a data segment consumed — active segments are
    /// dropped once instantiation copies them in (§4.5.4), and `data.drop` marks
    /// a passive one; a dropped segment behaves as empty for `memory.init`.
    data_dropped: []bool,
    /// Where the last trap happened, innermost frame first. Written only while
    /// unwinding a trap (see `Frame.run`'s `errdefer`) and reset at the start of
    /// each `invokeIndex`, so it always describes the most recent failed call.
    /// Read it with `trapFrames()`.
    trap_frames: [max_trap_frames]TrapFrame = undefined,
    trap_len: usize = 0,
    /// True call depth at the trap; exceeds `trap_len` when the stack was deeper
    /// than `max_trap_frames`, so a truncated backtrace can say it was truncated.
    trap_depth: usize = 0,
    /// GC heap (full GC, P3): one object per allocated struct/array; a GC
    /// reference value is the object's index here (its runtime type — the type
    /// index — rides in the object, so `ref.test`/`ref.cast` can check it).
    /// Objects live for the instance's lifetime (arena-backed field slices; no
    /// collector yet — a size cost accepted per the proposal-scope decision).
    /// `gpa`-owned outer list.
    gc_heap: std.ArrayList(HeapObject) = .empty,

    /// A heap-allocated GC object: its declared type index (RTT) and its struct
    /// fields / array elements (arena-backed).
    pub const HeapObject = struct { type_index: u32, fields: []Value };

    /// Shared linear memory. A single object is referenced by the defining
    /// instance and every importer, so `memory.grow` (which updates `bytes`) is
    /// visible across the module boundary.
    pub const Memory = struct { bytes: []u8, max: ?u32 };

    /// Shared reference table (funcref/externref `Value` slots; `null_ref` =
    /// uninitialized). Referenced by the definer and importers; `table.grow`
    /// updates `entries` in place so all sharers observe it.
    pub const Table = struct { entries: []Value, max: ?u32 };

    /// A callable backing an imported function: another instance's exported
    /// function (module linking), a plain native host function, or a native
    /// host callback with a context that may trap (`false` → `error.HostTrap`).
    /// The C ABI's `wasm_func_new` callbacks bind via `native_env`.
    pub const HostFunc = union(enum) {
        wasm: struct { instance: *Instance, func_index: u32 },
        native: *const fn (args: []const Value, results: []Value) void,
        native_env: struct {
            ctx: *anyopaque,
            call: *const fn (ctx: *anyopaque, args: []const Value, results: []Value) bool,
        },
    };

    /// Host-supplied backing for a module's imports, in per-kind import order:
    /// `funcs`/`globals`/`memories`/`tables` each align with the module's
    /// imports of that kind (imports occupy the low indices of their space).
    pub const Imports = struct {
        funcs: []const HostFunc = &.{},
        globals: []const Value = &.{},
        memories: []const *Memory = &.{},
        tables: []const *Table = &.{},
    };

    pub fn init(gpa: std.mem.Allocator, module: *const Module) Error!Instance {
        return initWithImports(gpa, module, .{});
    }

    pub fn initWithImports(gpa: std.mem.Allocator, module: *const Module, imports: Imports) Error!Instance {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const bodies = try a.alloc(FuncBody, module.functions.len);
        for (module.functions, module.code, bodies) |type_index, code, *body| {
            const ft = module.funcSig(type_index) orelse return error.UndefinedType;
            var num_locals: usize = ft.params.len;
            for (code.locals) |l| num_locals += l.count;

            const ir = try opcode.decodeBody(a, code.body);
            const cf = try precomputeControlFlow(a, ir);

            // Per-slot entry defaults: a reference local starts null, numeric 0.
            const defaults = try a.alloc(Value, num_locals);
            for (ft.params, 0..) |p, i| defaults[i] = if (p.isRef()) null_ref else 0;
            var slot: usize = ft.params.len;
            for (code.locals) |l| {
                const d: Value = if (l.type.isRef()) null_ref else 0;
                @memset(defaults[slot..][0..l.count], d);
                slot += l.count;
            }

            body.* = .{
                .type = ft,
                .num_locals = num_locals,
                .local_defaults = defaults,
                .ir = ir,
                .end_of = cf.end_of,
                .else_of = cf.else_of,
            };
        }

        const globals = try a.alloc(Value, module.globals.len);
        @memset(globals, 0);
        // Imported globals occupy the head of the index space; fill them from the
        // host-supplied values. Defined globals (each with an init expr) follow.
        const defined_start = module.globals.len - module.global_inits.len;
        for (imports.globals, 0..) |gv, i| {
            if (i >= defined_start) break;
            globals[i] = gv;
        }
        for (module.global_inits, 0..) |init_expr, gi|
            globals[defined_start + gi] = try evalConstExpr(globals[0 .. defined_start + gi], init_expr);

        // Linear memory: an imported memory (index 0 when present) borrows the
        // host-supplied shared object; a defined memory allocates its own. Active
        // data segments then initialize whichever memory backs index 0.
        const imported_memory = module.importedMemoryCount() > 0;
        var memory: ?*Memory = null;
        if (module.memories.len > 0) {
            if (imported_memory) {
                if (imports.memories.len == 0) return error.MissingImport;
                memory = imports.memories[0];
            } else {
                const mt = module.memories[0];
                const buf = try gpa.alloc(u8, @as(usize, mt.limits.min) * page_size);
                errdefer gpa.free(buf);
                @memset(buf, 0);
                const mem_obj = try gpa.create(Memory);
                mem_obj.* = .{ .bytes = buf, .max = mt.limits.max };
                memory = mem_obj;
            }
            const bytes = memory.?.bytes;
            for (module.data) |seg| {
                if (!seg.active) continue;
                const offset = try evalConstOffset(module, globals, seg.offset_expr);
                if (@as(u64, offset) + seg.bytes.len > bytes.len) return error.MemoryOutOfBounds;
                @memcpy(bytes[offset..][0..seg.bytes.len], seg.bytes);
            }
        }
        // Cover errors after the memory block; a *defined* memory object is owned.
        errdefer if (!imported_memory) if (memory) |m| {
            gpa.free(m.bytes);
            gpa.destroy(m);
        };

        // Tables: imported tables (the low indices) borrow host-supplied shared
        // objects; defined tables allocate their own. Entries are `Value` slots
        // (`null_ref` = uninitialized; a funcref is its function index; an
        // externref is its host value) so funcref *and* externref tables share one
        // representation.
        const n_imported_tables = module.importedTableCount();
        const tables = try gpa.alloc(*Table, module.tables.len);
        errdefer gpa.free(tables);
        var n_tables_init: usize = 0;
        errdefer for (tables[0..n_tables_init], 0..) |t, k| if (k >= n_imported_tables) {
            gpa.free(t.entries);
            gpa.destroy(t);
        };
        for (tables, module.tables, 0..) |*t, tt, k| {
            if (k < n_imported_tables) {
                if (k >= imports.tables.len) return error.MissingImport;
                t.* = imports.tables[k];
            } else {
                const entries = try gpa.alloc(Value, tt.limits.min);
                @memset(entries, null_ref);
                const tab = try gpa.create(Table);
                tab.* = .{ .entries = entries, .max = tt.limits.max };
                t.* = tab;
            }
            n_tables_init += 1;
        }
        // Evaluate every element segment's reference values. Active segments are
        // applied to their table and then dropped; passive segments stay
        // available for `table.init` until `elem.drop`; declarative are dropped.
        // Active data segments were copied into memory above and are dropped;
        // passive ones stay available to `memory.init` until `data.drop`.
        const data_dropped = try gpa.alloc(bool, module.data.len);
        errdefer gpa.free(data_dropped);
        for (module.data, data_dropped) |seg, *dropped| dropped.* = seg.active;

        const elem_values = try gpa.alloc([]Value, module.elements.len);
        errdefer gpa.free(elem_values);
        const elem_dropped = try gpa.alloc(bool, module.elements.len);
        errdefer gpa.free(elem_dropped);
        var n_elem_alloc: usize = 0;
        errdefer for (elem_values[0..n_elem_alloc]) |ev| gpa.free(ev);
        for (module.elements, elem_values, elem_dropped) |elem, *ev, *dropped| {
            const vals = try gpa.alloc(Value, elem.funcs.len + elem.exprs.len);
            ev.* = vals;
            n_elem_alloc += 1;
            for (elem.funcs, 0..) |f, k| vals[k] = @as(Value, f);
            for (elem.exprs, 0..) |ex, k| vals[k] = try evalConstExpr(globals, ex);
            dropped.* = elem.mode != .passive;
            if (elem.mode == .active) {
                if (elem.table_index >= tables.len) return error.NoTable;
                const tbl = tables[elem.table_index].entries;
                const offset = try evalConstOffset(module, globals, elem.offset_expr);
                for (vals, 0..) |v, k| {
                    if (@as(u64, offset) + k >= tbl.len) return error.TableOutOfBounds;
                    tbl[offset + k] = v;
                }
            }
        }

        return .{
            .gpa = gpa,
            .arena = arena,
            .module = module,
            .func_bodies = bodies,
            .globals = globals,
            .imported_funcs = module.importedFuncCount(),
            .import_funcs = imports.funcs,
            .memory = memory,
            .imported_memory = imported_memory,
            .tables = tables,
            .imported_tables = n_imported_tables,
            .elem_values = elem_values,
            .elem_dropped = elem_dropped,
            .data_dropped = data_dropped,
        };
    }

    pub fn deinit(self: *Instance) void {
        // Free only owned (defined) memory/tables; imported ones belong to the
        // exporting instance.
        if (!self.imported_memory) if (self.memory) |m| {
            self.gpa.free(m.bytes);
            self.gpa.destroy(m);
        };
        for (self.elem_values) |ev| self.gpa.free(ev);
        self.gpa.free(self.elem_values);
        self.gpa.free(self.elem_dropped);
        self.gpa.free(self.data_dropped);
        for (self.tables, 0..) |t, k| if (k >= self.imported_tables) {
            self.gpa.free(t.entries);
            self.gpa.destroy(t);
        };
        self.gpa.free(self.tables);
        self.gc_heap.deinit(self.gpa); // object slices are arena-backed (freed below)
        self.arena.deinit();
        self.* = undefined;
    }

    /// Run the module's start function (§4.5.5), if declared. The embedder calls
    /// this right after instantiation; a trap here means instantiation failed.
    pub fn runStart(self: *Instance) Error!void {
        const si = self.module.start orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        _ = try self.callFunction(scratch.allocator(), si, &.{}, 0);
    }

    /// Invoke an exported function by name. The returned result slice is owned
    /// by the caller (allocated with the instance's gpa).
    pub fn invoke(self: *Instance, name: []const u8, args: []const Value) Error![]Value {
        const func_index = self.findExportedFunc(name) orelse return error.UndefinedExport;
        return self.invokeIndex(func_index, args);
    }

    /// Invoke a function by its index in the function index space. Useful when the
    /// caller has already resolved the export (avoids re-resolving by name).
    pub fn invokeIndex(self: *Instance, func_index: u32, args: []const Value) Error![]Value {
        const ft = self.module.funcType(func_index) orelse return error.UndefinedFunc;
        if (args.len != ft.params.len) return error.BadArgCount;

        // Any trace left over describes an older call, not this one.
        self.trap_len = 0;
        self.trap_depth = 0;

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const results = try self.callFunction(scratch.allocator(), func_index, args, 0);

        const owned = try self.gpa.alloc(Value, results.len);
        @memcpy(owned, results);
        return owned;
    }

    /// The call stack of the most recent trap, innermost frame first. Empty if
    /// nothing has trapped, or if the failure never reached wasm code (a bad
    /// argument count, say). Pair it with `Module.funcName` to name the frames.
    pub fn trapFrames(self: *const Instance) []const TrapFrame {
        return self.trap_frames[0..self.trap_len];
    }

    /// True when the trap stack was deeper than we kept.
    pub fn trapTruncated(self: *const Instance) bool {
        return self.trap_depth > self.trap_len;
    }

    /// Append a frame to the trap trace. Called only while unwinding, from
    /// `Frame.run`'s `errdefer`, so the innermost frame lands first.
    ///
    /// **`noinline` is load-bearing, not a hint.** `Frame.run`'s `errdefer`
    /// expands at *every* `try` in a ~200-arm dispatch switch, so anything
    /// inlined here is duplicated across hundreds of landing pads and evicts the
    /// interpreter loop from i-cache. Letting this inline cost ~14% steady-state
    /// — measured, twice. Keep it out of line; it only ever runs once per frame
    /// while a trap unwinds.
    noinline fn recordTrap(self: *Instance, func_index: u32, pc: usize) void {
        self.trap_depth += 1;
        if (self.trap_len == max_trap_frames) return; // keep the innermost frames
        self.trap_frames[self.trap_len] = .{ .func_index = func_index, .pc = pc };
        self.trap_len += 1;
    }

    /// Byte offset of `frame`'s instruction within its function body, and within
    /// the module binary — what `wasm_frame_func_offset`/`_module_offset` mean,
    /// and what lines up with `wasm-objdump`.
    ///
    /// Resolved on demand by re-decoding that one body, rather than kept per
    /// instruction: tracking offsets at instantiate cost ~7% cold-start and 4
    /// bytes per instruction *for every module*, to serve a path most modules
    /// never take. Traps are rare and already slow; instantiation is the hot
    /// path this runtime competes on. Returns null if the pc has no offset (it
    /// can sit one past the end) or the body can't be re-decoded.
    pub fn frameOffset(self: *const Instance, a: std.mem.Allocator, frame: TrapFrame) ?Offsets {
        if (frame.func_index < self.imported_funcs) return null; // host func: no body
        const defined = frame.func_index - self.imported_funcs;
        if (defined >= self.module.code.len) return null;
        const code = self.module.code[defined];

        var offsets: std.ArrayList(u32) = .empty;
        defer offsets.deinit(a);
        // We want the offsets, not the IR — free the decode's other output.
        const ir = opcode.decodeBodyTracked(a, code.body, &offsets) catch return null;
        a.free(ir);
        if (frame.pc >= offsets.items.len) return null;
        const in_func = offsets.items[frame.pc];
        return .{ .func = in_func, .module = code.body_offset + in_func };
    }

    pub const Offsets = struct { func: u32, module: u32 };

    fn findExportedFunc(self: *Instance, name: []const u8) ?u32 {
        for (self.module.exports) |e| {
            if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    /// Allocate a GC object of type `type_index` (`fields` arena-backed) and
    /// return its reference value — an index into `gc_heap`. Object indices start
    /// at 0 and stay small, so a heap reference (bit 63 clear) never collides
    /// with the `null_ref` sentinel or a tagged i31 (bit 63 set).
    fn allocObject(self: *Instance, type_index: u32, fields: []Value) Error!Value {
        const idx = self.gc_heap.items.len;
        try self.gc_heap.append(self.gpa, .{ .type_index = type_index, .fields = fields });
        return @intCast(idx);
    }

    /// The field/element slice of a non-null GC reference, or a trap on null.
    fn gcObject(self: *Instance, ref: Value) Error![]Value {
        if (ref == null_ref) return error.NullReference;
        return self.gc_heap.items[@intCast(ref)].fields;
    }

    /// Does GC reference value `v` match target reference type `rt`
    /// (`ref.test`/`ref.cast`)? The value is interpreted by the target's top
    /// hierarchy — validation guarantees the operand shares it: `any` values are
    /// null / tagged-i31 / heap-object index; `func`/`extern` are null / handle.
    fn refMatches(self: *Instance, v: Value, rt: opcode.RefType) bool {
        if (v == null_ref) return rt.nullable;
        const target_head = self.module.refHead(rt.heap) catch return false;
        switch (target_head.top()) {
            .any => {
                if (v & i31_tag != 0) return self.headMatches(.i31, null, rt.heap);
                const idx: usize = @intCast(v);
                if (idx >= self.gc_heap.items.len) return false; // defensive
                const obj = self.gc_heap.items[idx];
                const kind: types.ValType.RefHeap = switch (self.module.comp_types[obj.type_index].kind()) {
                    .@"struct" => .@"struct",
                    .array => .array,
                    .func => .func,
                };
                return self.headMatches(kind, obj.type_index, rt.heap);
            },
            .func => return self.headMatches(.func, self.definedFuncType(v), rt.heap),
            else => return self.headMatches(.extern_, null, rt.heap),
        }
    }

    /// Match a value's actual heap head (`actual`, and concrete type index
    /// `actual_ti` when known) against a target heap type — abstract targets use
    /// the hierarchy relation, concrete targets the declared subtype chain.
    fn headMatches(self: *Instance, actual: types.ValType.RefHeap, actual_ti: ?u32, target: opcode.HeapType) bool {
        switch (target) {
            .concrete => |t| return actual_ti != null and self.module.isSubtype(actual_ti.?, t),
            else => {
                const th = self.module.refHead(target) catch return false;
                return actual.sub(th);
            },
        }
    }

    /// The type index of a *defined* function (for `ref.cast` of a funcref to a
    /// concrete func type); null for an imported function (no type index kept).
    fn definedFuncType(self: *Instance, findex: Value) ?u32 {
        const fi: u32 = @intCast(findex);
        const imported = self.module.importedFuncCount();
        if (fi < imported) return null;
        const d = fi - imported;
        if (d >= self.module.functions.len) return null;
        return self.module.functions[d];
    }

    fn callFunction(self: *Instance, a: std.mem.Allocator, func_index: u32, args: []const Value, depth: usize) Error![]Value {
        if (depth > max_call_depth) return error.CallStackExhausted;
        if (func_index < self.imported_funcs) {
            if (func_index >= self.import_funcs.len) return error.UnsupportedImportCall;
            switch (self.import_funcs[func_index]) {
                // Cross-module call: run in the exporting instance's context.
                .wasm => |w| return w.instance.callFunction(a, w.func_index, args, depth + 1),
                .native => |f| {
                    const ft = self.module.funcType(func_index) orelse return error.UndefinedFunc;
                    const results = try a.alloc(Value, ft.results.len);
                    f(args, results);
                    return results;
                },
                .native_env => |ne| {
                    const ft = self.module.funcType(func_index) orelse return error.UndefinedFunc;
                    const results = try a.alloc(Value, ft.results.len);
                    if (!ne.call(ne.ctx, args, results)) return error.HostTrap;
                    return results;
                },
            }
        }
        const defined = func_index - self.imported_funcs;
        if (defined >= self.func_bodies.len) return error.UndefinedFunc;
        const body = &self.func_bodies[defined];

        const locals = try a.alloc(Value, body.num_locals);
        @memcpy(locals, body.local_defaults); // ref locals → null, numeric → 0
        @memcpy(locals[0..args.len], args);

        var frame: Frame = .{ .inst = self, .a = a, .body = body, .locals = locals, .depth = depth, .func_index = func_index };
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
    /// This frame's index in the function index space — carried so a trap can
    /// name where it happened. Set once per call; never read while executing.
    func_index: u32,
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
    fn pushF32(self: *Frame, v: f32) Error!void {
        try self.pushU64(f32Value(v));
    }
    fn popF32(self: *Frame) f32 {
        return asF32(self.pop());
    }
    fn pushF64(self: *Frame, v: f64) Error!void {
        try self.pushU64(f64Value(v));
    }
    fn popF64(self: *Frame) f64 {
        return asF64(self.pop());
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
            // Validated code guarantees a func type at this index.
            .type_index => |i| blk: {
                const ft = self.inst.module.funcSig(i).?;
                break :blk @intCast(if (want_params) ft.params.len else ft.results.len);
            },
        };
    }

    fn run(self: *Frame) Error!void {
        const ir = self.body.ir;
        var pc: usize = 0;
        // Note where we were if anything below traps. `errdefer` emits code on
        // the error path only, so the interpreter loop is untouched — and since
        // it fires as the error unwinds through each frame, the trace builds
        // itself innermost-first with no explicit plumbing.
        errdefer self.inst.recordTrap(self.func_index, pc);
        while (pc < ir.len) {
            const instr = ir[pc];
            switch (instr.op) {
                .nop => pc += 1,
                .@"unreachable" => return error.Unreachable,
                .drop => {
                    _ = self.pop();
                    pc += 1;
                },
                .select, .select_t => {
                    const c = self.popI32();
                    const b = self.pop();
                    const av = self.pop();
                    try self.pushU64(if (c != 0) av else b);
                    pc += 1;
                },

                // --- Reference types ---
                .ref_null => {
                    try self.pushU64(null_ref);
                    pc += 1;
                },
                .ref_is_null => {
                    try self.pushI32(if (self.pop() == null_ref) 1 else 0);
                    pc += 1;
                },
                .ref_func => {
                    try self.pushU64(instr.imm.func); // a funcref is its function index
                    pc += 1;
                },

                // --- GC: i31 references (full GC, P3) ---
                // An i31 is unboxed: the 31-bit payload lives in the low bits and
                // `i31_tag` (bit 63) marks the slot as an i31 — so within the `any`
                // hierarchy `ref.test`/`ref.cast` can tell it from a heap index
                // (bit 63 clear) and from `null_ref` (all bits set; checked first).
                .ref_i31 => {
                    const x: u32 = @bitCast(self.popI32());
                    try self.pushU64(i31_tag | (x & 0x7fff_ffff)); // wrap to 31 bits, non-null
                    pc += 1;
                },
                .i31_get_s => {
                    const r = self.pop();
                    if (r == null_ref) return error.NullReference;
                    // Sign-extend bit 30 of the 31-bit payload to a full i32.
                    const n: u32 = @truncate(r);
                    try self.pushI32(@as(i32, @bitCast(n << 1)) >> 1);
                    pc += 1;
                },
                .i31_get_u => {
                    const r = self.pop();
                    if (r == null_ref) return error.NullReference;
                    try self.pushI32(@bitCast(@as(u32, @truncate(r)) & 0x7fff_ffff));
                    pc += 1;
                },

                // --- GC: eq comparison ---
                .ref_eq => {
                    const b = self.pop();
                    const av = self.pop();
                    try self.pushI32(if (av == b) 1 else 0);
                    pc += 1;
                },

                // --- GC: struct objects ---
                .struct_new => {
                    const sf = self.inst.module.structFields(instr.imm.gc_type).?;
                    const obj = try self.inst.arena.allocator().alloc(Value, sf.len);
                    const base = self.vstack.items.len - sf.len;
                    for (sf, 0..) |f, k| obj[k] = packField(f.storage, self.vstack.items[base + k]);
                    self.vstack.shrinkRetainingCapacity(base);
                    try self.pushU64(try self.inst.allocObject(instr.imm.gc_type, obj));
                    pc += 1;
                },
                .struct_new_default => {
                    const sf = self.inst.module.structFields(instr.imm.gc_type).?;
                    const obj = try self.inst.arena.allocator().alloc(Value, sf.len);
                    for (sf, 0..) |f, k| obj[k] = if (f.storage.unpacked().isRef()) null_ref else 0;
                    try self.pushU64(try self.inst.allocObject(instr.imm.gc_type, obj));
                    pc += 1;
                },
                .struct_get, .struct_get_s, .struct_get_u => {
                    const gf = instr.imm.gc_field;
                    const obj = try self.inst.gcObject(self.pop());
                    if (gf.field >= obj.len) return error.GcOutOfBounds;
                    const storage = self.inst.module.structFields(gf.type_index).?[gf.field].storage;
                    try self.pushU64(unpackField(storage, obj[gf.field], instr.op == .struct_get_s));
                    pc += 1;
                },
                .struct_set => {
                    const gf = instr.imm.gc_field;
                    const v = self.pop();
                    const obj = try self.inst.gcObject(self.pop());
                    if (gf.field >= obj.len) return error.GcOutOfBounds;
                    const storage = self.inst.module.structFields(gf.type_index).?[gf.field].storage;
                    obj[gf.field] = packField(storage, v);
                    pc += 1;
                },

                // --- GC: array objects ---
                .array_new => {
                    const f = self.inst.module.arrayField(instr.imm.gc_type).?;
                    const len = @as(u32, @bitCast(self.popI32()));
                    const init_v = packField(f.storage, self.pop());
                    const obj = try self.inst.arena.allocator().alloc(Value, len);
                    @memset(obj, init_v);
                    try self.pushU64(try self.inst.allocObject(instr.imm.gc_type, obj));
                    pc += 1;
                },
                .array_new_default => {
                    const f = self.inst.module.arrayField(instr.imm.gc_type).?;
                    const len = @as(u32, @bitCast(self.popI32()));
                    const obj = try self.inst.arena.allocator().alloc(Value, len);
                    @memset(obj, if (f.storage.unpacked().isRef()) null_ref else 0);
                    try self.pushU64(try self.inst.allocObject(instr.imm.gc_type, obj));
                    pc += 1;
                },
                .array_new_fixed => {
                    const tn = instr.imm.gc_type_n;
                    const f = self.inst.module.arrayField(tn.type_index).?;
                    const obj = try self.inst.arena.allocator().alloc(Value, tn.n);
                    const base = self.vstack.items.len - tn.n;
                    for (0..tn.n) |k| obj[k] = packField(f.storage, self.vstack.items[base + k]);
                    self.vstack.shrinkRetainingCapacity(base);
                    try self.pushU64(try self.inst.allocObject(tn.type_index, obj));
                    pc += 1;
                },
                .array_get, .array_get_s, .array_get_u => {
                    const f = self.inst.module.arrayField(instr.imm.gc_type).?;
                    const idx = @as(u32, @bitCast(self.popI32()));
                    const obj = try self.inst.gcObject(self.pop());
                    if (idx >= obj.len) return error.GcOutOfBounds;
                    try self.pushU64(unpackField(f.storage, obj[idx], instr.op == .array_get_s));
                    pc += 1;
                },
                .array_set => {
                    const f = self.inst.module.arrayField(instr.imm.gc_type).?;
                    const v = self.pop();
                    const idx = @as(u32, @bitCast(self.popI32()));
                    const obj = try self.inst.gcObject(self.pop());
                    if (idx >= obj.len) return error.GcOutOfBounds;
                    obj[idx] = packField(f.storage, v);
                    pc += 1;
                },
                .array_len => {
                    const obj = try self.inst.gcObject(self.pop());
                    try self.pushI32(@bitCast(@as(u32, @intCast(obj.len))));
                    pc += 1;
                },

                // --- GC: casts ---
                .ref_test => {
                    const v = self.pop();
                    try self.pushI32(if (self.inst.refMatches(v, instr.imm.ref_cast)) 1 else 0);
                    pc += 1;
                },
                .ref_cast => {
                    const v = self.vstack.items[self.vstack.items.len - 1]; // peek
                    if (!self.inst.refMatches(v, instr.imm.ref_cast)) return error.CastFailure;
                    pc += 1; // value stays on the stack with its new (validated) type
                },
                .br_on_cast => {
                    // The ref stays on the stack in both paths; branch iff it casts.
                    const v = self.vstack.items[self.vstack.items.len - 1];
                    pc = if (self.inst.refMatches(v, instr.imm.br_cast.dst)) self.branch(instr.imm.br_cast.label) else pc + 1;
                },
                .br_on_cast_fail => {
                    const v = self.vstack.items[self.vstack.items.len - 1];
                    pc = if (!self.inst.refMatches(v, instr.imm.br_cast.dst)) self.branch(instr.imm.br_cast.label) else pc + 1;
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
                .call_indirect => {
                    const ci = instr.imm.call_indirect;
                    if (ci.table >= self.inst.tables.len) return error.NoTable;
                    const table = self.inst.tables[ci.table].entries;
                    const slot = @as(u32, @bitCast(self.popI32())); // table element index (top of stack)
                    if (slot >= table.len) return error.TableOutOfBounds;
                    if (table[slot] == null_ref) return error.UninitializedElement;
                    const f: u32 = @intCast(table[slot]); // funcref value = function index
                    const want = self.inst.module.funcSig(ci.type_index) orelse return error.UndefinedType;
                    const ft = self.inst.module.funcType(f) orelse return error.UndefinedFunc;
                    if (!funcTypeEqual(want, ft)) return error.IndirectTypeMismatch;
                    const np = ft.params.len;
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = try self.inst.callFunction(self.a, f, args, self.depth + 1);
                    self.vstack.shrinkRetainingCapacity(self.vstack.items.len - np);
                    for (results) |r| try self.pushU64(r);
                    pc += 1;
                },
                .call_ref, .return_call_ref => {
                    // The function reference (a function index) is on top of the
                    // stack; a null ref traps.
                    const f_ref = self.pop();
                    if (f_ref == null_ref) return error.NullReference;
                    const f: u32 = @intCast(f_ref);
                    const ft = self.inst.module.funcType(f) orelse return error.UndefinedFunc;
                    const np = ft.params.len;
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = try self.inst.callFunction(self.a, f, args, self.depth + 1);
                    self.vstack.shrinkRetainingCapacity(self.vstack.items.len - np);
                    for (results) |r| try self.pushU64(r);
                    // return_call_ref is a tail call: the callee's results become
                    // ours (the epilogue takes the top `results.len`).
                    pc = if (instr.op == .return_call_ref) ir.len else pc + 1;
                },
                .ref_as_non_null => {
                    const r = self.pop();
                    if (r == null_ref) return error.NullReference;
                    try self.pushU64(r);
                    pc += 1;
                },
                .br_on_null => {
                    const r = self.pop();
                    if (r == null_ref) {
                        pc = self.branch(instr.imm.label); // null → branch (ref dropped)
                    } else {
                        try self.pushU64(r); // non-null → keep the ref, fall through
                        pc += 1;
                    }
                },
                .br_on_non_null => {
                    const r = self.pop();
                    if (r != null_ref) {
                        try self.pushU64(r); // non-null → keep the ref for the label
                        pc = self.branch(instr.imm.label);
                    } else {
                        pc += 1; // null → ref consumed, fall through
                    }
                },

                // --- Table access ---
                .table_get => {
                    const t = self.inst.tables[instr.imm.table].entries;
                    const i = @as(u32, @bitCast(self.popI32()));
                    if (i >= t.len) return error.TableOutOfBounds;
                    try self.pushU64(t[i]);
                    pc += 1;
                },
                .table_set => {
                    const t = self.inst.tables[instr.imm.table].entries;
                    const v = self.pop();
                    const i = @as(u32, @bitCast(self.popI32()));
                    if (i >= t.len) return error.TableOutOfBounds;
                    t[i] = v;
                    pc += 1;
                },
                .table_size => {
                    try self.pushI32(@bitCast(@as(u32, @intCast(self.inst.tables[instr.imm.table].entries.len))));
                    pc += 1;
                },
                .table_grow => {
                    const tab = self.inst.tables[instr.imm.table];
                    const delta = @as(u32, @bitCast(self.popI32()));
                    const init_val = self.pop();
                    const old = tab.entries;
                    const new_len = @as(u64, old.len) + delta;
                    const max = tab.max orelse std.math.maxInt(u32);
                    if (new_len > max) {
                        try self.pushI32(-1); // growth refused
                    } else {
                        const grown = self.inst.gpa.realloc(old, @intCast(new_len)) catch {
                            try self.pushI32(-1);
                            pc += 1;
                            continue;
                        };
                        @memset(grown[old.len..], init_val);
                        tab.entries = grown; // shared object → visible to importers
                        try self.pushI32(@bitCast(@as(u32, @intCast(old.len))));
                    }
                    pc += 1;
                },
                .table_fill => {
                    const t = self.inst.tables[instr.imm.table].entries;
                    const n = @as(u32, @bitCast(self.popI32()));
                    const val = self.pop();
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, dst) + n > t.len) return error.TableOutOfBounds;
                    @memset(t[dst..][0..n], val);
                    pc += 1;
                },
                // --- Bulk memory ---
                .memory_copy => {
                    const mem = (self.inst.memory orelse return error.NoMemory).bytes;
                    const n = @as(u32, @bitCast(self.popI32()));
                    const src = @as(u32, @bitCast(self.popI32()));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, src) + n > mem.len or @as(u64, dst) + n > mem.len) return error.MemoryOutOfBounds;
                    // Ranges may overlap — copy in the safe direction.
                    if (dst <= src) {
                        std.mem.copyForwards(u8, mem[dst..][0..n], mem[src..][0..n]);
                    } else {
                        std.mem.copyBackwards(u8, mem[dst..][0..n], mem[src..][0..n]);
                    }
                    pc += 1;
                },
                .memory_fill => {
                    const mem = (self.inst.memory orelse return error.NoMemory).bytes;
                    const n = @as(u32, @bitCast(self.popI32()));
                    const byte: u8 = @truncate(@as(u32, @bitCast(self.popI32())));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, dst) + n > mem.len) return error.MemoryOutOfBounds;
                    @memset(mem[dst..][0..n], byte);
                    pc += 1;
                },
                .memory_init => {
                    const mem = (self.inst.memory orelse return error.NoMemory).bytes;
                    const di = instr.imm.data;
                    // A dropped (or active, already-applied) segment reads as empty.
                    const seg: []const u8 = if (self.inst.data_dropped[di]) &.{} else self.inst.module.data[di].bytes;
                    const n = @as(u32, @bitCast(self.popI32()));
                    const src = @as(u32, @bitCast(self.popI32()));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, src) + n > seg.len or @as(u64, dst) + n > mem.len) return error.MemoryOutOfBounds;
                    @memcpy(mem[dst..][0..n], seg[src..][0..n]);
                    pc += 1;
                },
                .data_drop => {
                    self.inst.data_dropped[instr.imm.data] = true;
                    pc += 1;
                },

                .table_init => {
                    const t = self.inst.tables[instr.imm.table_init.table].entries;
                    const seg: []const Value = if (self.inst.elem_dropped[instr.imm.table_init.elem]) &.{} else self.inst.elem_values[instr.imm.table_init.elem];
                    const n = @as(u32, @bitCast(self.popI32()));
                    const src = @as(u32, @bitCast(self.popI32()));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, src) + n > seg.len or @as(u64, dst) + n > t.len) return error.TableOutOfBounds;
                    @memcpy(t[dst..][0..n], seg[src..][0..n]);
                    pc += 1;
                },
                .elem_drop => {
                    self.inst.elem_dropped[instr.imm.elem] = true;
                    pc += 1;
                },
                .table_copy => {
                    const dt = self.inst.tables[instr.imm.table_copy.dst].entries;
                    const st = self.inst.tables[instr.imm.table_copy.src].entries;
                    const n = @as(u32, @bitCast(self.popI32()));
                    const src = @as(u32, @bitCast(self.popI32()));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, src) + n > st.len or @as(u64, dst) + n > dt.len) return error.TableOutOfBounds;
                    // Overlapping ranges within one table: copy in the safe direction.
                    if (dst <= src) {
                        std.mem.copyForwards(Value, dt[dst..][0..n], st[src..][0..n]);
                    } else {
                        std.mem.copyBackwards(Value, dt[dst..][0..n], st[src..][0..n]);
                    }
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
                .f32_const => {
                    try self.pushU64(instr.imm.f32);
                    pc += 1;
                },
                .f64_const => {
                    try self.pushU64(instr.imm.f64);
                    pc += 1;
                },

                .i32_load, .i64_load, .f32_load, .f64_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u, .i32_store, .i64_store, .f32_store, .f64_store, .i32_store8, .i32_store16, .i64_store8, .i64_store16, .i64_store32, .memory_size, .memory_grow => {
                    try self.execMemory(instr);
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

            else => return self.execFloat(op),
        }
    }

    /// Float arithmetic / comparison / conversion opcodes (IEEE 754). Memory,
    /// `call_indirect`, and reference-type ops remain a later slice.
    fn execFloat(self: *Frame, op: Op) Error!void {
        switch (op) {
            // f32 comparison (result i32)
            .f32_eq => try self.cmpF32(.eq),
            .f32_ne => try self.cmpF32(.ne),
            .f32_lt => try self.cmpF32(.lt),
            .f32_gt => try self.cmpF32(.gt),
            .f32_le => try self.cmpF32(.le),
            .f32_ge => try self.cmpF32(.ge),
            // f64 comparison (result i32)
            .f64_eq => try self.cmpF64(.eq),
            .f64_ne => try self.cmpF64(.ne),
            .f64_lt => try self.cmpF64(.lt),
            .f64_gt => try self.cmpF64(.gt),
            .f64_le => try self.cmpF64(.le),
            .f64_ge => try self.cmpF64(.ge),

            // f32 unary
            .f32_abs => try self.pushF32(@abs(self.popF32())),
            .f32_neg => try self.pushF32(-self.popF32()),
            .f32_ceil => try self.pushF32(@ceil(self.popF32())),
            .f32_floor => try self.pushF32(@floor(self.popF32())),
            .f32_trunc => try self.pushF32(@trunc(self.popF32())),
            .f32_nearest => try self.pushF32(rintEven(f32, self.popF32())),
            .f32_sqrt => try self.pushF32(@sqrt(self.popF32())),
            // f64 unary
            .f64_abs => try self.pushF64(@abs(self.popF64())),
            .f64_neg => try self.pushF64(-self.popF64()),
            .f64_ceil => try self.pushF64(@ceil(self.popF64())),
            .f64_floor => try self.pushF64(@floor(self.popF64())),
            .f64_trunc => try self.pushF64(@trunc(self.popF64())),
            .f64_nearest => try self.pushF64(rintEven(f64, self.popF64())),
            .f64_sqrt => try self.pushF64(@sqrt(self.popF64())),

            // f32 binary
            .f32_add => try self.binF32(.add),
            .f32_sub => try self.binF32(.sub),
            .f32_mul => try self.binF32(.mul),
            .f32_div => try self.binF32(.div),
            .f32_min => try self.binF32(.min),
            .f32_max => try self.binF32(.max),
            .f32_copysign => try self.binF32(.copysign),
            // f64 binary
            .f64_add => try self.binF64(.add),
            .f64_sub => try self.binF64(.sub),
            .f64_mul => try self.binF64(.mul),
            .f64_div => try self.binF64(.div),
            .f64_min => try self.binF64(.min),
            .f64_max => try self.binF64(.max),
            .f64_copysign => try self.binF64(.copysign),

            // Float → int (trapping)
            .i32_trunc_f32_s => try self.pushI32(try truncFloatS(i32, f32, self.popF32())),
            .i32_trunc_f32_u => try self.pushI32(@bitCast(try truncFloatU(u32, f32, self.popF32()))),
            .i32_trunc_f64_s => try self.pushI32(try truncFloatS(i32, f64, self.popF64())),
            .i32_trunc_f64_u => try self.pushI32(@bitCast(try truncFloatU(u32, f64, self.popF64()))),
            .i64_trunc_f32_s => try self.pushI64(try truncFloatS(i64, f32, self.popF32())),
            .i64_trunc_f32_u => try self.pushI64(@bitCast(try truncFloatU(u64, f32, self.popF32()))),
            .i64_trunc_f64_s => try self.pushI64(try truncFloatS(i64, f64, self.popF64())),
            .i64_trunc_f64_u => try self.pushI64(@bitCast(try truncFloatU(u64, f64, self.popF64()))),

            // Float → int, saturating (non-trapping): NaN → 0, out-of-range clamps.
            .i32_trunc_sat_f32_s => try self.pushI32(truncSatS(i32, f32, self.popF32())),
            .i32_trunc_sat_f32_u => try self.pushI32(@bitCast(truncSatU(u32, f32, self.popF32()))),
            .i32_trunc_sat_f64_s => try self.pushI32(truncSatS(i32, f64, self.popF64())),
            .i32_trunc_sat_f64_u => try self.pushI32(@bitCast(truncSatU(u32, f64, self.popF64()))),
            .i64_trunc_sat_f32_s => try self.pushI64(truncSatS(i64, f32, self.popF32())),
            .i64_trunc_sat_f32_u => try self.pushI64(@bitCast(truncSatU(u64, f32, self.popF32()))),
            .i64_trunc_sat_f64_s => try self.pushI64(truncSatS(i64, f64, self.popF64())),
            .i64_trunc_sat_f64_u => try self.pushI64(@bitCast(truncSatU(u64, f64, self.popF64()))),

            // Int → float
            .f32_convert_i32_s => try self.pushF32(@floatFromInt(self.popI32())),
            .f32_convert_i32_u => try self.pushF32(@floatFromInt(@as(u32, @bitCast(self.popI32())))),
            .f32_convert_i64_s => try self.pushF32(@floatFromInt(self.popI64())),
            .f32_convert_i64_u => try self.pushF32(@floatFromInt(@as(u64, @bitCast(self.popI64())))),
            .f32_demote_f64 => try self.pushF32(@floatCast(self.popF64())),
            .f64_convert_i32_s => try self.pushF64(@floatFromInt(self.popI32())),
            .f64_convert_i32_u => try self.pushF64(@floatFromInt(@as(u32, @bitCast(self.popI32())))),
            .f64_convert_i64_s => try self.pushF64(@floatFromInt(self.popI64())),
            .f64_convert_i64_u => try self.pushF64(@floatFromInt(@as(u64, @bitCast(self.popI64())))),
            .f64_promote_f32 => try self.pushF64(@floatCast(self.popF32())),

            // Reinterpret: the u64 slot already holds the bit pattern, so these
            // are identity on the stack value.
            .i32_reinterpret_f32, .f32_reinterpret_i32, .i64_reinterpret_f64, .f64_reinterpret_i64 => {},

            else => return error.UnsupportedInstruction, // defensive: not a numeric/convert op
        }
    }

    fn cmpF32(self: *Frame, comptime c: FCmp) Error!void {
        const b = self.popF32();
        const a = self.popF32();
        try self.pushI32(@intFromBool(fcmp(f32, c, a, b)));
    }
    fn cmpF64(self: *Frame, comptime c: FCmp) Error!void {
        const b = self.popF64();
        const a = self.popF64();
        try self.pushI32(@intFromBool(fcmp(f64, c, a, b)));
    }
    fn binF32(self: *Frame, comptime o: FBin) Error!void {
        const b = self.popF32();
        const a = self.popF32();
        try self.pushF32(fbin(f32, o, a, b));
    }
    fn binF64(self: *Frame, comptime o: FBin) Error!void {
        const b = self.popF64();
        const a = self.popF64();
        try self.pushF64(fbin(f64, o, a, b));
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

    /// Load `T` from linear memory at (popped address + memarg offset), little-
    /// endian. Signed `T` sign-extends, unsigned zero-extends when pushed.
    fn load(self: *Frame, comptime T: type, ma: opcode.MemArg) Error!T {
        const n = @sizeOf(T);
        const base: u32 = @bitCast(self.popI32());
        const mem = (self.inst.memory orelse return error.NoMemory).bytes;
        const ea = @as(u64, base) + ma.offset;
        if (ea + n > mem.len) return error.MemoryOutOfBounds;
        return std.mem.readInt(T, mem[@intCast(ea)..][0..n], .little);
    }

    /// Store `value: T` to linear memory at (popped address + memarg offset).
    /// The caller has already popped the value; this pops the address.
    fn store(self: *Frame, comptime T: type, ma: opcode.MemArg, value: T) Error!void {
        const n = @sizeOf(T);
        const base: u32 = @bitCast(self.popI32());
        const mem = (self.inst.memory orelse return error.NoMemory).bytes;
        const ea = @as(u64, base) + ma.offset;
        if (ea + n > mem.len) return error.MemoryOutOfBounds;
        std.mem.writeInt(T, mem[@intCast(ea)..][0..n], value, .little);
    }

    fn memoryGrow(self: *Frame) Error!void {
        const delta: u64 = @as(u32, @bitCast(self.popI32()));
        const m = self.inst.memory orelse return error.NoMemory;
        const old = m.bytes;
        const old_pages: u64 = old.len / page_size;
        const limit: u64 = m.max orelse 65536; // wasm32 hard cap
        if (old_pages + delta > limit) return self.pushI32(-1);
        const new_buf = self.inst.gpa.realloc(old, @intCast((old_pages + delta) * page_size)) catch
            return self.pushI32(-1);
        @memset(new_buf[old.len..], 0);
        m.bytes = new_buf; // shared object → visible to importers
        try self.pushI32(@intCast(old_pages));
    }

    fn execMemory(self: *Frame, instr: opcode.Instr) Error!void {
        // memory.size / memory.grow carry a reserved-byte immediate, not a memarg.
        switch (instr.op) {
            .memory_size => {
                const mem = (self.inst.memory orelse return error.NoMemory).bytes;
                return self.pushI32(@intCast(mem.len / page_size));
            },
            .memory_grow => return self.memoryGrow(),
            else => {},
        }
        const ma = instr.imm.mem;
        switch (instr.op) {
            .i32_load => try self.pushI32(@bitCast(try self.load(u32, ma))),
            .i64_load => try self.pushI64(@bitCast(try self.load(u64, ma))),
            .f32_load => try self.pushU64(try self.load(u32, ma)),
            .f64_load => try self.pushU64(try self.load(u64, ma)),
            .i32_load8_s => try self.pushI32(try self.load(i8, ma)),
            .i32_load8_u => try self.pushI32(try self.load(u8, ma)),
            .i32_load16_s => try self.pushI32(try self.load(i16, ma)),
            .i32_load16_u => try self.pushI32(try self.load(u16, ma)),
            .i64_load8_s => try self.pushI64(try self.load(i8, ma)),
            .i64_load8_u => try self.pushI64(try self.load(u8, ma)),
            .i64_load16_s => try self.pushI64(try self.load(i16, ma)),
            .i64_load16_u => try self.pushI64(try self.load(u16, ma)),
            .i64_load32_s => try self.pushI64(try self.load(i32, ma)),
            .i64_load32_u => try self.pushI64(try self.load(u32, ma)),

            .i32_store => try self.store(i32, ma, self.popI32()),
            .i64_store => try self.store(i64, ma, self.popI64()),
            .f32_store => try self.store(u32, ma, @truncate(self.pop())),
            .f64_store => try self.store(u64, ma, self.pop()),
            .i32_store8 => try self.store(u8, ma, @truncate(@as(u32, @bitCast(self.popI32())))),
            .i32_store16 => try self.store(u16, ma, @truncate(@as(u32, @bitCast(self.popI32())))),
            .i64_store8 => try self.store(u8, ma, @truncate(@as(u64, @bitCast(self.popI64())))),
            .i64_store16 => try self.store(u16, ma, @truncate(@as(u64, @bitCast(self.popI64())))),
            .i64_store32 => try self.store(u32, ma, @truncate(@as(u64, @bitCast(self.popI64())))),

            else => unreachable,
        }
    }
};

/// Evaluate a constant offset expression (data / element segment offset) to an
/// i32 address.
fn evalConstOffset(module: *const Module, globals: []const Value, expr: []const u8) Error!u32 {
    _ = module;
    return @bitCast(asI32(try evalConstExpr(globals, expr)));
}

/// Evaluate a constant expression (§3.3.7, incl. the extended-const `i32`/`i64`
/// `add`/`sub`/`mul`): a short stack machine over `*.const`, `global.get` (of a
/// preceding global), `ref.null`/`ref.func`, terminated by `end`. Returns the
/// single resulting slot.
fn evalConstExpr(globals: []const Value, expr: []const u8) Error!Value {
    var r = Reader.init(expr);
    var stack: [16]Value = undefined;
    var sp: usize = 0;
    const push = struct {
        fn f(s: *[16]Value, p: *usize, v: Value) Error!void {
            if (p.* >= s.len) return error.UnsupportedInstruction;
            s[p.*] = v;
            p.* += 1;
        }
    }.f;
    while (true) {
        const op = try r.readByte();
        switch (op) {
            0x0b => break, // end
            0x41 => try push(&stack, &sp, i32Value(try r.readVarI32())), // i32.const
            0x42 => try push(&stack, &sp, i64Value(try r.readVarI64())), // i64.const
            0x43 => try push(&stack, &sp, std.mem.readInt(u32, (try r.readBytes(4))[0..4], .little)), // f32.const
            0x44 => try push(&stack, &sp, std.mem.readInt(u64, (try r.readBytes(8))[0..8], .little)), // f64.const
            0x23 => { // global.get
                const gi = try r.readVarU32();
                if (gi >= globals.len) return error.UndefinedGlobal;
                try push(&stack, &sp, globals[gi]);
            },
            0xd0 => { // ref.null <heaptype>
                _ = try r.readByte();
                try push(&stack, &sp, null_ref);
            },
            0xd2 => try push(&stack, &sp, @as(Value, try r.readVarU32())), // ref.func <funcidx>
            0x6a, 0x6b, 0x6c => { // i32 add / sub / mul
                if (sp < 2) return error.UnsupportedInstruction;
                const b = asI32(stack[sp - 1]);
                const a = asI32(stack[sp - 2]);
                sp -= 1;
                stack[sp - 1] = i32Value(switch (op) {
                    0x6a => a +% b,
                    0x6b => a -% b,
                    else => a *% b,
                });
            },
            0x7c, 0x7d, 0x7e => { // i64 add / sub / mul
                if (sp < 2) return error.UnsupportedInstruction;
                const b = asI64(stack[sp - 1]);
                const a = asI64(stack[sp - 2]);
                sp -= 1;
                stack[sp - 1] = i64Value(switch (op) {
                    0x7c => a +% b,
                    0x7d => a -% b,
                    else => a *% b,
                });
            },
            else => return error.UnsupportedInstruction,
        }
    }
    if (sp == 0) return error.UnsupportedInstruction;
    return stack[sp - 1];
}

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

const FCmp = enum { eq, ne, lt, gt, le, ge };
const FBin = enum { add, sub, mul, div, min, max, copysign };

fn fcmp(comptime F: type, comptime c: FCmp, a: F, b: F) bool {
    return switch (c) {
        .eq => a == b,
        .ne => a != b,
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
}

fn fbin(comptime F: type, comptime o: FBin, a: F, b: F) F {
    return switch (o) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .min => fmin(F, a, b),
        .max => fmax(F, a, b),
        .copysign => std.math.copysign(a, b),
    };
}

/// wasm `fmin`: NaN-propagating, and `min(+0,-0) == -0` (via sign-bit OR).
fn fmin(comptime F: type, a: F, b: F) F {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(F);
    if (a < b) return a;
    if (b < a) return b;
    const U = std.meta.Int(.unsigned, @typeInfo(F).float.bits);
    return @bitCast(@as(U, @bitCast(a)) | @as(U, @bitCast(b)));
}

/// wasm `fmax`: NaN-propagating, and `max(+0,-0) == +0` (via sign-bit AND).
fn fmax(comptime F: type, a: F, b: F) F {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(F);
    if (a > b) return a;
    if (b > a) return b;
    const U = std.meta.Int(.unsigned, @typeInfo(F).float.bits);
    return @bitCast(@as(U, @bitCast(a)) & @as(U, @bitCast(b)));
}

/// Round to nearest, ties to even (wasm `nearest`), preserving the sign of zero.
fn rintEven(comptime F: type, x: F) F {
    if (!std.math.isFinite(x)) return x;
    const f = @floor(x);
    const diff = x - f;
    var r: F = f;
    if (diff > 0.5) {
        r = f + 1;
    } else if (diff == 0.5) {
        r = if (@rem(f, 2.0) == 0) f else f + 1;
    }
    if (r == 0) return std.math.copysign(@as(F, 0.0), x);
    return r;
}

/// Trapping signed float→int truncation.
fn truncFloatS(comptime I: type, comptime F: type, x: F) Error!I {
    if (std.math.isNan(x)) return error.InvalidConversionToInt;
    const t = @trunc(x);
    const bits = @typeInfo(I).int.bits;
    const hi: F = std.math.ldexp(@as(F, 1.0), bits - 1); // 2^(bits-1)
    if (t < -hi or t >= hi) return error.InvalidConversionToInt;
    return @intFromFloat(t);
}

/// Trapping unsigned float→int truncation.
fn truncFloatU(comptime U: type, comptime F: type, x: F) Error!U {
    if (std.math.isNan(x)) return error.InvalidConversionToInt;
    const t = @trunc(x);
    const bits = @typeInfo(U).int.bits;
    const hi: F = std.math.ldexp(@as(F, 1.0), bits); // 2^bits
    if (t < 0 or t >= hi) return error.InvalidConversionToInt;
    return @intFromFloat(t);
}

/// Saturating signed float→int truncation (`*.trunc_sat_*_s`): never traps —
/// NaN → 0, and out-of-range clamps to the integer's min/max.
fn truncSatS(comptime I: type, comptime F: type, x: F) I {
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    const bits = @typeInfo(I).int.bits;
    const hi: F = std.math.ldexp(@as(F, 1.0), bits - 1); // 2^(bits-1)
    if (t <= -hi) return std.math.minInt(I);
    if (t >= hi) return std.math.maxInt(I);
    return @intFromFloat(t);
}

/// Saturating unsigned float→int truncation (`*.trunc_sat_*_u`): NaN and
/// negatives → 0, above-range clamps to the maximum.
fn truncSatU(comptime U: type, comptime F: type, x: F) U {
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    const bits = @typeInfo(U).int.bits;
    const hi: F = std.math.ldexp(@as(F, 1.0), bits); // 2^bits
    if (t <= 0) return 0;
    if (t >= hi) return std.math.maxInt(U);
    return @intFromFloat(t);
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

test "a trap records where it happened, innermost frame first" {
    // func0 boom() = unreachable ; func1 outer() = call boom
    // Mirrors the real shape this exists for: a 2-instruction body whose first
    // instruction traps is exactly a wasm-ld stub (see known-issues #19).
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++ // one type ()->()
        [_]u8{ 0x03, 0x03, 0x02, 0x00, 0x00 } ++ // two funcs
        [_]u8{ 0x07, 0x09, 0x01, 0x05, 'o', 'u', 't', 'e', 'r', 0x00, 0x01 } ++
        // code: size 12 = count(1) + [len(1)+4] + [len(1)+5].
        // boom body(4) = 00 locals, nop, unreachable, end -> traps at pc 1.
        // outer body(5) = 00 locals, nop, call 0, end     -> calls at pc 1.
        [_]u8{ 0x0a, 0x0c, 0x02, 0x04, 0x00, 0x01, 0x00, 0x0b, 0x05, 0x00, 0x01, 0x10, 0x00, 0x0b };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    try std.testing.expectError(error.Unreachable, inst.invoke("outer", &.{}));

    const frames = inst.trapFrames();
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    // innermost first: the `unreachable` at pc 1 of func 0 ...
    try std.testing.expectEqual(@as(u32, 0), frames[0].func_index);
    try std.testing.expectEqual(@as(usize, 1), frames[0].pc);
    // ... reached from the `call` at pc 1 of func 1.
    try std.testing.expectEqual(@as(u32, 1), frames[1].func_index);
    try std.testing.expectEqual(@as(usize, 1), frames[1].pc);
    try std.testing.expect(!inst.trapTruncated());

    // Byte offsets into the body, resolved on demand — what
    // wasm_frame_func_offset means. boom's body is [01 nop][00 unreachable]
    // [0b end] (the decoder sees it past the locals count), so `unreachable` is
    // at byte 1; outer's `call` is likewise at 1, after its nop.
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 1), inst.frameOffset(a, frames[0]).?.func);
    try std.testing.expectEqual(@as(u32, 1), inst.frameOffset(a, frames[1]).?.func);
}

test "trap frames carry real byte offsets, not IR indices" {
    // A body where the two diverge: multi-byte instructions push later byte
    // offsets well past their IR index, so an IR index in func_offset would be
    // visibly wrong rather than coincidentally equal.
    //   00 locals | i32.const 0x80 0x01 (2-byte LEB) | drop | unreachable | end
    //   IR:          pc0                               pc1    pc2           pc3
    //   bytes:       @0                                @3     @4            @5
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 } ++
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x80, 0x01, 0x1a, 0x00, 0x0b };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    try std.testing.expectError(error.Unreachable, inst.invoke("f", &.{}));
    const f = inst.trapFrames()[0];
    const off = inst.frameOffset(std.testing.allocator, f).?;
    try std.testing.expectEqual(@as(usize, 2), f.pc); // third instruction ...
    try std.testing.expectEqual(@as(u32, 4), off.func); // ... at byte 4 of the body

    // The module offset must land on the `unreachable` byte in the real binary.
    try std.testing.expect(off.module < bytes.len);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[off.module]);
}

test "the trap trace resets per invoke and survives a deeper-than-buffer stack" {
    // A self-recursive function that traps at the bottom: depth blows past
    // max_trap_frames, so the trace must truncate rather than overrun.
    // func0 f(x) = if x==0 { unreachable } else { f(x-1) }
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00 } ++ // (i32)->()
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 } ++
        // body (17 bytes): 00 locals; local.get0; i32.eqz; if void; unreachable;
        // else; local.get0; i32.const 1; i32.sub; call 0; end; end
        [_]u8{
            0x0a, 0x13, 0x01, 0x11, 0x00,
            0x20, 0x00, 0x45, 0x04, 0x40, 0x00, 0x05,
            0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00, 0x0b, 0x0b,
        };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    try std.testing.expectError(error.Unreachable, inst.invoke("f", &.{i32Value(40)}));
    try std.testing.expectEqual(max_trap_frames, inst.trapFrames().len);
    try std.testing.expect(inst.trapTruncated());
    try std.testing.expectEqual(@as(usize, 41), inst.trap_depth); // 40 recursions + the base
    for (inst.trapFrames()) |f| try std.testing.expectEqual(@as(u32, 0), f.func_index);

    // A shallower trap must report its own depth, not the previous one's.
    try std.testing.expectError(error.Unreachable, inst.invoke("f", &.{i32Value(2)}));
    try std.testing.expectEqual(@as(usize, 3), inst.trapFrames().len);
    try std.testing.expect(!inst.trapTruncated());
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

test "runs f64.add" {
    // (func (param f64 f64) (result f64) local.get0 local.get1 f64.add)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x0b } ++
        [_]u8{ 0x07, 0x08, 0x01, 0x04, 'f', 'a', 'd', 'd', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);
    const r = try inst.invoke("fadd", &.{ f64Value(1.5), f64Value(2.25) });
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(f64, 3.75), asF64(r[0]));
}

test "runs i32.trunc_f64_s and traps on NaN" {
    // (func (param f64) (result i32) local.get0 i32.trunc_f64_s)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7f } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xaa, 0x0b } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 't', 'o', 'i', 0x00, 0x00 };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);

    const r = try inst.invoke("toi", &.{f64Value(3.7)});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 3), asI32(r[0]));

    try std.testing.expectError(error.InvalidConversionToInt, inst.invoke("toi", &.{f64Value(std.math.nan(f64))}));
}

test "stores then loads through linear memory" {
    // (memory 1) (func (param i32) (result i32) i32.const 0; local.get 0; i32.store;
    //                                            i32.const 0; i32.load)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f } ++ // (i32)->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++ // 1 func
        [_]u8{ 0x05, 0x03, 0x01, 0x00, 0x01 } ++ // memory: min 1 page
        [_]u8{ 0x07, 0x06, 0x01, 0x02, 'r', 't', 0x00, 0x00 } ++ // export "rt"
        [_]u8{ 0x0a, 0x10, 0x01, 0x0e, 0x00, 0x41, 0x00, 0x20, 0x00, 0x36, 0x02, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b };
    var inst = try instantiate(&bytes);
    defer destroy(&inst);
    const r = try inst.invoke("rt", &.{i32Value(0x12345678)});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(u32, 0x12345678), @as(u32, @bitCast(asI32(r[0]))));
}

test "initializes memory from an active data segment" {
    // (memory 1) (data (i32.const 0) "\ef\be\ad\de")   ; loads 0xDEADBEEF
    // (func (result i32) i32.const 0; i32.load)
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f } ++ // ()->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x05, 0x03, 0x01, 0x00, 0x01 } ++ // memory min 1
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'g', 'e', 't', 0x00, 0x00 } ++
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b } ++ // code
        [_]u8{ 0x0b, 0x0a, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x04, 0xef, 0xbe, 0xad, 0xde }; // data
    var inst = try instantiate(&bytes);
    defer destroy(&inst);
    const r = try inst.invoke("get", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), @as(u32, @bitCast(asI32(r[0]))));
}
