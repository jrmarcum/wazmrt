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
    /// An exception is unwinding and has not (yet) been caught. Used internally
    /// to propagate a `throw` across frames; if it reaches the top of a call it
    /// is an uncaught exception, which traps (EH proposal, Phase 6).
    UncaughtException,
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

/// Stack slots a value type occupies: a `v128` is **two** `u64` slots (SIMD),
/// every other type is one. Only v128 differs, so a module with no v128 keeps
/// the "one value = one slot" model unchanged.
fn slotWidth(vt: types.ValType) u32 {
    return if (vt == .v128) 2 else 1;
}
/// Total stack slots a list of value types occupies.
fn typeSlots(ts: []const types.ValType) u32 {
    var n: u32 = 0;
    for (ts) |t| n += slotWidth(t);
    return n;
}

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
    /// Non-empty only for a `try_table` label — its catch clauses, consulted
    /// when an exception unwinds through this frame (EH proposal, Phase 6).
    catches: []const opcode.Catch = &.{},
    /// Non-null only for a legacy `try` label — its inline handlers (Phase 6.3).
    legacy: ?LegacyTry = null,
    /// The exception currently being handled in this legacy try's catch block,
    /// for `rethrow` to re-raise. Set when a handler is entered.
    caught: ?Exception = null,
};

/// A thrown exception in flight: the tag it carries and its value payload
/// (arena-owned by the invocation). Boxed in `Instance.exn_store` when an
/// `exnref` must be materialized (`catch_ref` / `throw_ref`).
const Exception = struct { tag: u32, values: []const Value };

/// One inline handler of a legacy `try` (Phase 6.3). `tag == null` is
/// `catch_all`; `handler_pc` is the first instruction after the `catch`.
const LegacyCatch = struct { tag: ?u32, handler_pc: usize };

/// The catch handlers (and optional `delegate` label) of a legacy `try`,
/// precomputed per try instruction so unwinding can find them.
const LegacyTry = struct { handlers: []const LegacyCatch = &.{}, delegate: ?u32 = null };

/// A defined function prepared for execution.
const FuncBody = struct {
    type: Module.FuncType,
    /// Total stack slots for params + declared locals (a v128 local is 2 slots).
    num_local_slots: usize,
    /// Starting slot of each local (params first, then declared), and its slot
    /// width (1, or 2 for v128) — so `local.get $i` copies the right slots.
    local_map: []const u32,
    local_w: []const u8,
    /// Default value of every local *slot* at function entry: `null_ref` for a
    /// reference-typed local (a nullable ref defaults to null; a non-null ref is
    /// non-defaultable, so validation forbids reading it before a set — the value
    /// is immaterial), `0` for a numeric or v128 local. Params are overwritten
    /// by args.
    local_defaults: []const Value,
    ir: []const opcode.Instr,
    /// For each `block`/`loop`/`if`/`else` index: the matching `end` index.
    end_of: []const usize,
    /// For each `if` index: the `else` index, or `ir.len` if none.
    else_of: []const usize,
    /// For each legacy `try` index: its catch handlers + optional delegate; null
    /// elsewhere (Phase 6.3). Empty slice when there are no legacy trys.
    try_info: []const ?LegacyTry,
    /// Operand slot width of each `drop`/`select` (2 for a v128, else 1), so the
    /// interpreter pops the right number of `u64` slots (SIMD). Empty for a
    /// function with no v128 — then every drop/select is width 1.
    drop_select_w: []const u8,
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
    /// High 64 bits of each global (only v128 globals use it; 0 otherwise), so a
    /// v128 global's two slots are `globals[i]` (low) + `global_hi[i]` (high).
    global_hi: []Value,
    imported_funcs: u32,
    /// Backing callables for imported functions (index-aligned with the first
    /// `imported_funcs` entries of the function index space).
    import_funcs: []const HostFunc,
    /// The linear-memory index space (multi-memory): imported memories first
    /// (borrowed shared objects, so growth reflects the exporter), then defined
    /// memories (owned). Empty if the module has no memory. A load/store/`memory.*`
    /// selects one by its instruction's memory index.
    memories: []*Memory,
    /// How many leading entries of `memories` are imported (borrowed, not freed).
    imported_memories: usize,
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
    /// Exception handling (Phase 6). `pending_exn` carries a thrown exception
    /// while it unwinds across frames (via `error.UncaughtException`), so a
    /// caller's `call` site can try to catch it. `exn_store` boxes exceptions
    /// that become `exnref` values (`catch_ref`/`throw_ref`); indices into it are
    /// the exnref value. Both are reset per invocation.
    pending_exn: ?Exception = null,
    exn_store: std.ArrayList(Exception) = .empty,
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

    /// Memory index 0, or null if the module has no memory. The WASI host and the
    /// C ABI speak the conventional single memory through this.
    pub fn memory0(self: *const Instance) ?*Memory {
        return if (self.memories.len > 0) self.memories[0] else null;
    }

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
            var local_count: usize = ft.params.len;
            for (code.locals) |l| local_count += l.count;

            const ir = try opcode.decodeBody(a, code.body);
            const cf = try precomputeControlFlow(a, ir);

            // v128 `drop`/`select` pop two slots, not one. A function can only
            // hold a v128 if it has a SIMD op or a v128 param/local, so only then
            // do we run the (validator-backed) width annotation — the common path
            // pays nothing and every drop/select is width 1.
            var has_v128 = false;
            for (ft.params) |p| if (p == .v128) {
                has_v128 = true;
            };
            for (code.locals) |l| if (l.type == .v128) {
                has_v128 = true;
            };
            if (!has_v128) for (ir) |instr| if (instr.op == .simd) {
                has_v128 = true;
                break;
            };
            const drop_select_w: []const u8 = if (has_v128)
                try @import("validate.zig").dropSelectWidths(a, module, ft, code)
            else
                &.{};

            // Build the local slot map: params first, then declared locals, each
            // starting at a running slot offset (v128 = 2 slots). Slot-sized
            // defaults: a reference local starts null, numeric/v128 zero.
            const local_map = try a.alloc(u32, local_count);
            const local_w = try a.alloc(u8, local_count);
            var num_slots: u32 = 0;
            var li: usize = 0;
            for (ft.params) |p| {
                local_map[li] = num_slots;
                local_w[li] = @intCast(slotWidth(p));
                num_slots += local_w[li];
                li += 1;
            }
            for (code.locals) |l| {
                var c: u32 = 0;
                while (c < l.count) : (c += 1) {
                    local_map[li] = num_slots;
                    local_w[li] = @intCast(slotWidth(l.type));
                    num_slots += local_w[li];
                    li += 1;
                }
            }
            const defaults = try a.alloc(Value, num_slots);
            @memset(defaults, 0);
            li = 0;
            for (ft.params) |p| {
                if (p.isRef()) defaults[local_map[li]] = null_ref;
                li += 1;
            }
            for (code.locals) |l| {
                var c: u32 = 0;
                while (c < l.count) : (c += 1) {
                    if (l.type.isRef()) defaults[local_map[li]] = null_ref;
                    li += 1;
                }
            }

            body.* = .{
                .type = ft,
                .num_local_slots = num_slots,
                .local_map = local_map,
                .local_w = local_w,
                .local_defaults = defaults,
                .ir = ir,
                .end_of = cf.end_of,
                .else_of = cf.else_of,
                .try_info = cf.try_info,
                .drop_select_w = drop_select_w,
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
        // A v128 global needs 128 bits: `globals[i]` holds the low 64 and this
        // parallel array the high 64 (0 for scalar globals). Keeping `globals`
        // index-aligned means the const-expr evaluator is unchanged.
        const global_hi = try a.alloc(Value, module.globals.len);
        @memset(global_hi, 0);
        for (module.global_inits, 0..) |init_expr, gi| {
            const gidx = defined_start + gi;
            if (module.globals[gidx].content == .v128) {
                const v = try evalConstV128(init_expr); // a v128 global's init is v128.const
                globals[gidx] = @truncate(v);
                global_hi[gidx] = @truncate(v >> 64);
            } else {
                globals[gidx] = try evalConstExpr(globals[0..gidx], init_expr);
            }
        }

        // Linear memories (multi-memory): imported memories (the low indices)
        // borrow host-supplied shared objects; defined memories allocate their
        // own. Active data segments then initialize their target memory.
        const imported_memories = module.importedMemoryCount();
        const memories = try gpa.alloc(*Memory, module.memories.len);
        errdefer gpa.free(memories);
        var built: usize = 0;
        errdefer for (memories[imported_memories..built]) |m| { // free only owned ones built so far
            gpa.free(m.bytes);
            gpa.destroy(m);
        };
        for (module.memories, 0..) |mt, i| {
            if (i < imported_memories) {
                if (i >= imports.memories.len) return error.MissingImport;
                memories[i] = imports.memories[i];
            } else {
                const buf = try gpa.alloc(u8, @as(usize, mt.limits.min) * page_size);
                @memset(buf, 0);
                const mem_obj = gpa.create(Memory) catch |e| {
                    gpa.free(buf);
                    return e;
                };
                mem_obj.* = .{ .bytes = buf, .max = mt.limits.max };
                memories[i] = mem_obj;
                built = i + 1;
            }
        }
        for (module.data) |seg| {
            if (!seg.active) continue;
            if (seg.mem_index >= memories.len) return error.NoMemory;
            const bytes = memories[seg.mem_index].bytes;
            const offset = try evalConstOffset(module, globals, seg.offset_expr);
            if (@as(u64, offset) + seg.bytes.len > bytes.len) return error.MemoryOutOfBounds;
            @memcpy(bytes[offset..][0..seg.bytes.len], seg.bytes);
        }

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
            .global_hi = global_hi,
            .imported_funcs = module.importedFuncCount(),
            .import_funcs = imports.funcs,
            .memories = memories,
            .imported_memories = imported_memories,
            .tables = tables,
            .imported_tables = n_imported_tables,
            .elem_values = elem_values,
            .elem_dropped = elem_dropped,
            .data_dropped = data_dropped,
        };
    }

    pub fn deinit(self: *Instance) void {
        // Free only owned (defined) memories/tables; imported ones belong to the
        // exporting instance.
        for (self.memories[self.imported_memories..]) |m| {
            self.gpa.free(m.bytes);
            self.gpa.destroy(m);
        }
        self.gpa.free(self.memories);
        for (self.elem_values) |ev| self.gpa.free(ev);
        self.gpa.free(self.elem_values);
        self.gpa.free(self.elem_dropped);
        self.exn_store.deinit(self.gpa);
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
        if (args.len != typeSlots(ft.params)) return error.BadArgCount;

        // Any trace left over describes an older call, not this one.
        self.trap_len = 0;
        self.trap_depth = 0;
        // Exceptions never outlive the invocation that raised them (their payload
        // is invocation-arena memory); start each call with a clean store.
        self.pending_exn = null;
        self.exn_store.clearRetainingCapacity();

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
                    const results = try a.alloc(Value, typeSlots(ft.results));
                    f(args, results);
                    return results;
                },
                .native_env => |ne| {
                    const ft = self.module.funcType(func_index) orelse return error.UndefinedFunc;
                    const results = try a.alloc(Value, typeSlots(ft.results));
                    if (!ne.call(ne.ctx, args, results)) return error.HostTrap;
                    return results;
                },
            }
        }
        const defined = func_index - self.imported_funcs;
        if (defined >= self.func_bodies.len) return error.UndefinedFunc;
        const body = &self.func_bodies[defined];

        const locals = try a.alloc(Value, body.num_local_slots);
        @memcpy(locals, body.local_defaults); // ref locals → null, numeric/v128 → 0
        @memcpy(locals[0..args.len], args); // args are param slots (v128 = 2 each)

        var frame: Frame = .{ .inst = self, .a = a, .body = body, .locals = locals, .depth = depth, .func_index = func_index };
        try frame.labels.append(a, .{
            .is_loop = false,
            .arity = typeSlots(body.type.results),
            .target = body.ir.len,
            .stack_base = 0,
        });
        try frame.run();

        const n = typeSlots(body.type.results);
        const res = try a.alloc(Value, n);
        @memcpy(res, frame.vstack.items[frame.vstack.items.len - n ..]);
        return res;
    }
};

fn precomputeControlFlow(a: std.mem.Allocator, ir: []const opcode.Instr) Error!struct { end_of: []usize, else_of: []usize, try_info: []?LegacyTry } {
    const end_of = try a.alloc(usize, ir.len);
    const else_of = try a.alloc(usize, ir.len);
    const try_info = try a.alloc(?LegacyTry, ir.len);
    @memset(end_of, 0);
    @memset(else_of, ir.len); // sentinel = "no else"
    @memset(try_info, null);

    // For a legacy `try`, its inline `catch`/`catch_all` handlers are collected as
    // we pass them (the top opener is always the enclosing try — the body's nested
    // blocks are balanced before the first catch). At the try's `end` we also
    // point `end_of` at that end for every catch, so a normally-completing body or
    // handler skips the remaining handlers.
    var stack: std.ArrayList(usize) = .empty;
    var handlers: std.ArrayList(std.ArrayList(LegacyCatch)) = .empty; // parallel to `stack`
    var catch_pcs: std.ArrayList(std.ArrayList(usize)) = .empty; // catch instr pcs, parallel
    for (ir, 0..) |instr, i| {
        switch (instr.op) {
            .block, .loop, .@"if", .try_table, .try_ => {
                try stack.append(a, i);
                try handlers.append(a, .empty);
                try catch_pcs.append(a, .empty);
            },
            .@"else" => else_of[stack.items[stack.items.len - 1]] = i,
            .catch_, .catch_all => {
                const top = handlers.items.len - 1;
                try handlers.items[top].append(a, .{
                    .tag = if (instr.op == .catch_) instr.imm.tag else null,
                    .handler_pc = i + 1,
                });
                try catch_pcs.items[top].append(a, i);
            },
            .delegate => {
                const opener = stack.pop().?;
                _ = handlers.pop();
                _ = catch_pcs.pop();
                // `delegate` terminates the try in place of an `end`.
                end_of[opener] = i;
                try_info[opener] = .{ .handlers = &.{}, .delegate = instr.imm.label };
            },
            .end => {
                if (stack.items.len == 0) continue; // the function's implicit end
                const opener = stack.pop().?;
                var hs = handlers.pop().?;
                var cps = catch_pcs.pop().?;
                end_of[opener] = i;
                if (else_of[opener] != ir.len) end_of[else_of[opener]] = i;
                if (ir[opener].op == .try_) {
                    for (cps.items) |cp| end_of[cp] = i; // catch → skip to end on normal flow
                    try_info[opener] = .{ .handlers = try hs.toOwnedSlice(a) };
                }
                hs.deinit(a);
                cps.deinit(a);
            },
            else => {},
        }
    }
    return .{ .end_of = end_of, .else_of = else_of, .try_info = try_info };
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

    /// Try to catch `exn` in this frame: search the label stack innermost-out for
    /// a `try_table` whose catch clauses match this exception's tag (or a
    /// `catch_all`). On a match, unwind the value stack to that try_table's base,
    /// push the handler values (the exception payload, plus the `exnref` for a
    /// `_ref` clause), and branch to the clause's target label — returning the new
    /// pc. Returns null if no handler in this frame matches (the caller then
    /// propagates `error.UncaughtException`).
    fn throwException(self: *Frame, exn: Exception) Error!?usize {
        var d: usize = 0;
        while (d < self.labels.items.len) : (d += 1) {
            const idx = self.labels.items.len - 1 - d;
            const label = self.labels.items[idx];
            // try_table (exnref proposal): a matching catch branches OUT of the
            // try_table to the clause's label.
            for (label.catches) |c| {
                const matches = switch (c.kind) {
                    .catch_, .catch_ref => c.tag == exn.tag,
                    .catch_all, .catch_all_ref => true,
                };
                if (!matches) continue;
                // Discard everything the try_table body pushed (incl. any call
                // args in flight), back to its entry height.
                self.vstack.shrinkRetainingCapacity(label.stack_base);
                switch (c.kind) {
                    .catch_, .catch_ref => for (exn.values) |v| try self.pushU64(v),
                    .catch_all, .catch_all_ref => {},
                }
                switch (c.kind) {
                    .catch_ref, .catch_all_ref => {
                        const eidx = self.inst.exn_store.items.len;
                        try self.inst.exn_store.append(self.inst.gpa, exn);
                        try self.pushU64(@intCast(eidx));
                    },
                    else => {},
                }
                // The clause's label index is relative to the try_table (label 0 =
                // the try_table block); the try_table sits `d` deep, so branch to
                // `d + c.label`.
                return self.branch(@intCast(d + c.label));
            }
            // Legacy `try`: a matching inline handler runs INSIDE the try (the try
            // label stays on the stack for `rethrow`/`br`).
            if (label.legacy) |lt| {
                for (lt.handlers) |h| {
                    if (h.tag != null and h.tag.? != exn.tag) continue;
                    self.vstack.shrinkRetainingCapacity(label.stack_base);
                    if (h.tag != null) for (exn.values) |v| try self.pushU64(v); // catch pushes the payload
                    // Drop the body's nested labels but keep this try; record the
                    // caught exception for `rethrow`.
                    self.labels.shrinkRetainingCapacity(idx + 1);
                    self.labels.items[idx].caught = exn;
                    return h.handler_pc;
                }
            }
        }
        return null;
    }

    /// Handle an error propagating out of a `call`. If it is an unwinding
    /// exception this frame catches, return the resumption pc; otherwise re-raise
    /// it (so a real trap, or an exception no handler here matches, keeps
    /// unwinding). Never returns null — it either yields a pc or re-raises.
    fn onCallError(self: *Frame, e: Error) Error!usize {
        if (e != error.UncaughtException) return e;
        const exn = self.inst.pending_exn.?;
        const target = (try self.throwException(exn)) orelse return e;
        // Caught here: drop the in-flight exception and the unwind trace it left.
        self.inst.pending_exn = null;
        self.inst.trap_len = 0;
        self.inst.trap_depth = 0;
        return target;
    }

    /// Branch/label arity in **slots** (a v128 result is 2 slots), so `branch`
    /// copies the right number of `u64`s.
    fn blockArity(self: *Frame, bt: opcode.BlockType, comptime want_params: bool) u32 {
        return switch (bt) {
            .empty => 0,
            .value => |t| if (want_params) 0 else slotWidth(t),
            // Validated code guarantees a func type at this index.
            .type_index => |i| blk: {
                const ft = self.inst.module.funcSig(i).?;
                break :blk typeSlots(if (want_params) ft.params else ft.results);
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
                    // A v128 is two slots; `dropWidth` is 2 there (SIMD), else 1.
                    var k = self.dropSelectWidth(pc);
                    while (k > 0) : (k -= 1) _ = self.pop();
                    pc += 1;
                },
                .select, .select_t => {
                    const w = self.dropSelectWidth(pc);
                    const c = self.popI32();
                    var b: [2]Value = undefined;
                    var av: [2]Value = undefined;
                    var k: u8 = w;
                    while (k > 0) : (k -= 1) b[k - 1] = self.pop(); // b (high slot first)
                    k = w;
                    while (k > 0) : (k -= 1) av[k - 1] = self.pop();
                    const chosen = if (c != 0) av else b;
                    for (0..w) |i| try self.pushU64(chosen[i]);
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

                // --- Exception handling (exnref proposal, Phase 6) ---
                .try_table => {
                    const tt = instr.imm.try_table;
                    const params = self.blockArity(tt.block_type, true);
                    try self.labels.append(self.a, .{
                        .is_loop = false,
                        .arity = self.blockArity(tt.block_type, false),
                        .target = self.body.end_of[pc] + 1,
                        .stack_base = self.vstack.items.len - params,
                        .catches = tt.catches,
                    });
                    pc += 1;
                },
                .throw => {
                    const tag = instr.imm.tag;
                    const ft = self.inst.module.tagType(tag).?; // validated
                    const base = self.vstack.items.len - ft.params.len;
                    const exn: Exception = .{ .tag = tag, .values = try self.a.dupe(Value, self.vstack.items[base..]) };
                    self.vstack.shrinkRetainingCapacity(base);
                    if (try self.throwException(exn)) |target| {
                        pc = target;
                    } else {
                        self.inst.pending_exn = exn;
                        return error.UncaughtException;
                    }
                },
                .throw_ref => {
                    const r = self.pop();
                    if (r == null_ref) return error.NullReference;
                    const exn = self.inst.exn_store.items[@intCast(r)];
                    if (try self.throwException(exn)) |target| {
                        pc = target;
                    } else {
                        self.inst.pending_exn = exn;
                        return error.UncaughtException;
                    }
                },

                // --- Legacy exception handling (Phase 6.3) ---
                .try_ => {
                    const params = self.blockArity(instr.imm.block_type, true);
                    try self.labels.append(self.a, .{
                        .is_loop = false,
                        .arity = self.blockArity(instr.imm.block_type, false),
                        .target = self.body.end_of[pc] + 1,
                        .stack_base = self.vstack.items.len - params,
                        .legacy = self.body.try_info[pc],
                    });
                    pc += 1;
                },
                // Reached only by normal control flow (the body or a prior handler
                // completed): skip the remaining handlers to the `end`.
                .catch_, .catch_all => pc = self.body.end_of[pc],
                // `delegate`, reached normally, just ends the try like `end`.
                .delegate => {
                    _ = self.labels.pop();
                    pc += 1;
                },
                .rethrow => {
                    // Re-raise the exception caught by the try `label` levels out,
                    // propagating from OUTSIDE that try (it already had its turn).
                    const n = instr.imm.label;
                    const tgt = self.labels.items[self.labels.items.len - 1 - n];
                    const exn = tgt.caught orelse return error.UncaughtException;
                    self.labels.shrinkRetainingCapacity(self.labels.items.len - 1 - n);
                    self.vstack.shrinkRetainingCapacity(tgt.stack_base);
                    if (try self.throwException(exn)) |target| {
                        pc = target;
                    } else {
                        self.inst.pending_exn = exn;
                        return error.UncaughtException;
                    }
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
                    const np = typeSlots(ft.params); // param slots (v128 = 2)
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = self.inst.callFunction(self.a, f, args, self.depth + 1) catch |e| {
                        pc = try self.onCallError(e); // caught here → resume; else re-raise
                        continue;
                    };
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
                    const np = typeSlots(ft.params); // param slots (v128 = 2)
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = self.inst.callFunction(self.a, f, args, self.depth + 1) catch |e| {
                        pc = try self.onCallError(e);
                        continue;
                    };
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
                    const np = typeSlots(ft.params); // param slots (v128 = 2)
                    const args = self.vstack.items[self.vstack.items.len - np ..];
                    const results = self.inst.callFunction(self.a, f, args, self.depth + 1) catch |e| {
                        pc = try self.onCallError(e);
                        continue;
                    };
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
                // --- Bulk memory (multi-memory: each carries its memory index) ---
                .memory_copy => {
                    const dmem = try self.memBytes(instr.imm.mem_copy.dst);
                    const smem = try self.memBytes(instr.imm.mem_copy.src);
                    const n = @as(u32, @bitCast(self.popI32()));
                    const src = @as(u32, @bitCast(self.popI32()));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, src) + n > smem.len or @as(u64, dst) + n > dmem.len) return error.MemoryOutOfBounds;
                    if (instr.imm.mem_copy.dst != instr.imm.mem_copy.src) {
                        @memcpy(dmem[dst..][0..n], smem[src..][0..n]); // distinct buffers: no overlap
                    } else if (dst <= src) {
                        std.mem.copyForwards(u8, dmem[dst..][0..n], smem[src..][0..n]);
                    } else {
                        std.mem.copyBackwards(u8, dmem[dst..][0..n], smem[src..][0..n]);
                    }
                    pc += 1;
                },
                .memory_fill => {
                    const mem = try self.memBytes(instr.imm.mem_index);
                    const n = @as(u32, @bitCast(self.popI32()));
                    const byte: u8 = @truncate(@as(u32, @bitCast(self.popI32())));
                    const dst = @as(u32, @bitCast(self.popI32()));
                    if (@as(u64, dst) + n > mem.len) return error.MemoryOutOfBounds;
                    @memset(mem[dst..][0..n], byte);
                    pc += 1;
                },
                .memory_init => {
                    const mem = try self.memBytes(instr.imm.mem_init.mem);
                    const di = instr.imm.mem_init.data;
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
                    const off = self.body.local_map[instr.imm.local];
                    var k: u32 = 0;
                    while (k < self.body.local_w[instr.imm.local]) : (k += 1) try self.pushU64(self.locals[off + k]);
                    pc += 1;
                },
                .local_set => {
                    const off = self.body.local_map[instr.imm.local];
                    var k = self.body.local_w[instr.imm.local];
                    while (k > 0) { // top of stack is the value's high slot
                        k -= 1;
                        self.locals[off + k] = self.pop();
                    }
                    pc += 1;
                },
                .local_tee => {
                    const off = self.body.local_map[instr.imm.local];
                    const w = self.body.local_w[instr.imm.local];
                    for (0..w) |k| self.locals[off + k] = self.vstack.items[self.vstack.items.len - w + k];
                    pc += 1;
                },
                .global_get => {
                    const gi = instr.imm.global;
                    try self.pushU64(self.inst.globals[gi]);
                    // A v128 global is two slots: low then high.
                    if (self.inst.module.globals[gi].content == .v128) try self.pushU64(self.inst.global_hi[gi]);
                    pc += 1;
                },
                .global_set => {
                    const gi = instr.imm.global;
                    if (self.inst.module.globals[gi].content == .v128) self.inst.global_hi[gi] = self.pop(); // high (top)
                    self.inst.globals[gi] = self.pop(); // low
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
                .simd => {
                    try self.execSimd(instr.imm.simd);
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

    /// The bytes of memory `idx` (multi-memory); `NoMemory` if out of range.
    fn memBytes(self: *Frame, idx: u32) Error![]u8 {
        if (idx >= self.inst.memories.len) return error.NoMemory;
        return self.inst.memories[idx].bytes;
    }

    /// Load `T` from linear memory `ma.memory` at (popped address + memarg
    /// offset), little-endian. Signed `T` sign-extends, unsigned zero-extends.
    fn load(self: *Frame, comptime T: type, ma: opcode.MemArg) Error!T {
        const n = @sizeOf(T);
        const base: u32 = @bitCast(self.popI32());
        const mem = try self.memBytes(ma.memory);
        const ea = @as(u64, base) + ma.offset;
        if (ea + n > mem.len) return error.MemoryOutOfBounds;
        return std.mem.readInt(T, mem[@intCast(ea)..][0..n], .little);
    }

    /// Store `value: T` to linear memory `ma.memory` at (popped address + memarg
    /// offset). The caller has already popped the value; this pops the address.
    fn store(self: *Frame, comptime T: type, ma: opcode.MemArg, value: T) Error!void {
        const n = @sizeOf(T);
        const base: u32 = @bitCast(self.popI32());
        const mem = try self.memBytes(ma.memory);
        const ea = @as(u64, base) + ma.offset;
        if (ea + n > mem.len) return error.MemoryOutOfBounds;
        std.mem.writeInt(T, mem[@intCast(ea)..][0..n], value, .little);
    }

    fn memoryGrow(self: *Frame, mem_idx: u32) Error!void {
        const delta: u64 = @as(u32, @bitCast(self.popI32()));
        if (mem_idx >= self.inst.memories.len) return error.NoMemory;
        const m = self.inst.memories[mem_idx];
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
        // memory.size / memory.grow carry a memory index, not a memarg.
        switch (instr.op) {
            .memory_size => {
                const mem = try self.memBytes(instr.imm.mem_index);
                return self.pushI32(@intCast(mem.len / page_size));
            },
            .memory_grow => return self.memoryGrow(instr.imm.mem_index),
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

    /// Slot width of the `drop`/`select` at `pc` (2 for a v128, else 1). Empty
    /// annotation (a function with no v128) means every drop/select is width 1.
    fn dropSelectWidth(self: *Frame, pc: usize) u8 {
        return if (pc < self.body.drop_select_w.len) self.body.drop_select_w[pc] else 1;
    }

    // --- SIMD (v128): a value is two u64 stack slots, low then high --------
    fn pushV128(self: *Frame, v: u128) Error!void {
        try self.pushU64(@truncate(v));
        try self.pushU64(@truncate(v >> 64));
    }
    fn popV128(self: *Frame) u128 {
        const hi = self.pop();
        const lo = self.pop();
        return (@as(u128, hi) << 64) | lo;
    }

    /// A lane-wise wrapping binary op on integer lanes of width `Lane`.
    fn simdIntBin(self: *Frame, comptime Lane: type, comptime op: enum { add, sub, mul }) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const b: Vec = @bitCast(self.popV128());
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
        };
        try self.pushV128(@bitCast(r));
    }
    /// Saturating add/sub on integer lanes: widen a lane, compute, clamp back to
    /// `Lane`'s range (signedness of `Lane` decides signed vs unsigned saturation).
    fn simdSatAddSub(self: *Frame, comptime Lane: type, comptime is_add: bool) Error!void {
        const N = 16 / @sizeOf(Lane);
        const Wide = std.meta.Int(@typeInfo(Lane).int.signedness, @bitSizeOf(Lane) + 1);
        const b: [N]Lane = @bitCast(self.popV128());
        const a: [N]Lane = @bitCast(self.popV128());
        var r: [N]Lane = undefined;
        for (0..N) |i| {
            const s: Wide = if (is_add) @as(Wide, a[i]) + b[i] else @as(Wide, a[i]) - b[i];
            r[i] = satTo(Lane, s);
        }
        try self.pushV128(@bitCast(r));
    }
    /// Unsigned rounding average: (a + b + 1) >> 1, computed a lane wider so it
    /// can't overflow.
    fn simdAvgrU(self: *Frame, comptime Lane: type) Error!void {
        const N = 16 / @sizeOf(Lane);
        const W = std.meta.Int(.unsigned, @bitSizeOf(Lane) + 1);
        const b: [N]Lane = @bitCast(self.popV128());
        const a: [N]Lane = @bitCast(self.popV128());
        var r: [N]Lane = undefined;
        for (0..N) |i| r[i] = @intCast((@as(W, a[i]) + @as(W, b[i]) + 1) >> 1);
        try self.pushV128(@bitCast(r));
    }
    /// popcount per lane.
    fn simdPopcnt(self: *Frame, comptime Lane: type) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = @intCast(@popCount(a)); // @popCount lanes are narrower; widen back
        try self.pushV128(@bitCast(r));
    }
    /// Widen the low or high half of the operand: each `Src` lane → a `Dst` lane
    /// (sign- or zero-extend per `Src`'s signedness).
    fn simdExtend(self: *Frame, comptime Src: type, comptime Dst: type, comptime high: bool) Error!void {
        const src: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        var dst: [16 / @sizeOf(Dst)]Dst = undefined;
        const base: usize = if (high) dst.len else 0;
        for (0..dst.len) |i| dst[i] = src[base + i];
        try self.pushV128(@bitCast(dst));
    }
    /// Narrow two `Src` vectors into one `Dst` vector with saturation.
    fn simdNarrow(self: *Frame, comptime Src: type, comptime Dst: type) Error!void {
        const b: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        const a: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        var r: [16 / @sizeOf(Dst)]Dst = undefined;
        const half = a.len;
        for (0..half) |i| r[i] = satTo(Dst, a[i]);
        for (0..half) |i| r[half + i] = satTo(Dst, b[i]);
        try self.pushV128(@bitCast(r));
    }
    /// Convert integer lanes to float lanes (widening a low half for f64x2).
    fn simdConvert(self: *Frame, comptime Src: type, comptime Dst: type, comptime low_only: bool) Error!void {
        const N = 16 / @sizeOf(Dst);
        const src: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        var dst: [N]Dst = undefined;
        for (0..N) |i| dst[i] = if (low_only or i < src.len) @floatFromInt(src[i]) else 0;
        try self.pushV128(@bitCast(dst));
    }
    /// Truncate float lanes to saturated integer lanes (NaN→0). `low_only` zeroes
    /// the high half (the `_zero` forms narrowing f64x2 → i32x4).
    fn simdTruncSat(self: *Frame, comptime Src: type, comptime Dst: type, comptime low_only: bool) Error!void {
        const N = 16 / @sizeOf(Dst);
        const src: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        var dst: [N]Dst = undefined;
        for (0..N) |i| dst[i] = if (i < src.len) satTruncLane(Dst, src[i]) else 0;
        if (low_only) for (src.len..N) |i| {
            dst[i] = 0;
        };
        try self.pushV128(@bitCast(dst));
    }
    /// A lane-wise binary op on float lanes of width `Lane`.
    fn simdFloatBin(self: *Frame, comptime Lane: type, comptime op: enum { add, sub, mul, div, min, max, pmin, pmax }) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const b: Vec = @bitCast(self.popV128());
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
            .min => @min(a, b),
            .max => @max(a, b),
            .pmin => @select(Lane, b < a, b, a), // pseudo-min: b if b<a else a
            .pmax => @select(Lane, a < b, b, a),
        };
        try self.pushV128(@bitCast(r));
    }
    /// A lane-wise unary op on float lanes. (ceil/floor/trunc/nearest — which
    /// need round-to-even — are not wired yet; see the SIMD gap notes.)
    fn simdFloatUn(self: *Frame, comptime Lane: type, comptime op: enum { abs, neg, sqrt, ceil, floor, trunc }) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = switch (op) {
            .abs => @abs(a),
            .neg => -a,
            .sqrt => @sqrt(a),
            .ceil => @ceil(a),
            .floor => @floor(a),
            .trunc => @trunc(a),
        };
        try self.pushV128(@bitCast(r));
    }
    /// Integer min/max (signed lanes if `Signed`), lane-wise.
    fn simdIntMinMax(self: *Frame, comptime Lane: type, comptime want_max: bool) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const b: Vec = @bitCast(self.popV128());
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = if (want_max) @max(a, b) else @min(a, b);
        try self.pushV128(@bitCast(r));
    }
    /// Integer unary abs/neg, lane-wise (signed).
    fn simdIntUn(self: *Frame, comptime Lane: type, comptime op: enum { abs, neg }) Error!void {
        const Vec = @Vector(16 / @sizeOf(Lane), Lane);
        const a: Vec = @bitCast(self.popV128());
        const r: Vec = switch (op) {
            .abs => @bitCast(@abs(a)), // @abs of a signed vector is unsigned; bitcast back (wraps INT_MIN correctly)
            .neg => -%a,
        };
        try self.pushV128(@bitCast(r));
    }
    /// Lane-wise comparison → all-ones / all-zeros mask per lane (`Lane` is the
    /// lane type; unsigned lanes give an unsigned compare).
    fn simdCmp(self: *Frame, comptime Lane: type, comptime op: enum { eq, ne, lt, gt, le, ge }) Error!void {
        const N = 16 / @sizeOf(Lane);
        const Vec = @Vector(N, Lane);
        const U = @Vector(N, std.meta.Int(.unsigned, @bitSizeOf(Lane)));
        const b: Vec = @bitCast(self.popV128());
        const a: Vec = @bitCast(self.popV128());
        const m: @Vector(N, bool) = switch (op) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .gt => a > b,
            .le => a <= b,
            .ge => a >= b,
        };
        const ones: U = @splat(std.math.maxInt(std.meta.Int(.unsigned, @bitSizeOf(Lane))));
        const zeros: U = @splat(0);
        try self.pushV128(@bitCast(@select(std.meta.Int(.unsigned, @bitSizeOf(Lane)), m, ones, zeros)));
    }
    /// A vector shift (shl / shr) by a scalar amount (mod lane bits).
    fn simdShift(self: *Frame, comptime Lane: type, comptime op: enum { shl, shr }) Error!void {
        const N = 16 / @sizeOf(Lane);
        const Vec = @Vector(N, Lane);
        const ShiftLane = std.math.Log2Int(Lane);
        const amt: ShiftLane = @intCast(@as(u32, @bitCast(self.popI32())) % @bitSizeOf(Lane));
        const a: Vec = @bitCast(self.popV128());
        const sh: @Vector(N, ShiftLane) = @splat(amt);
        const r: Vec = switch (op) {
            .shl => a << sh,
            .shr => a >> sh, // arithmetic if Lane is signed, logical if unsigned
        };
        try self.pushV128(@bitCast(r));
    }
    fn simdAllTrue(self: *Frame, comptime Lane: type) Error!void {
        const arr: [16 / @sizeOf(Lane)]Lane = @bitCast(self.popV128());
        var all: bool = true;
        for (arr) |x| if (x == 0) {
            all = false;
        };
        try self.pushI32(if (all) 1 else 0);
    }
    fn simdBitmask(self: *Frame, comptime Lane: type) Error!void {
        // The high bit of each lane, packed into the low bits of an i32.
        const arr: [16 / @sizeOf(Lane)]Lane = @bitCast(self.popV128());
        var m: u32 = 0;
        for (arr, 0..) |x, i| {
            if (@as(std.meta.Int(.unsigned, @bitSizeOf(Lane)), @bitCast(x)) >> (@bitSizeOf(Lane) - 1) != 0) m |= (@as(u32, 1) << @intCast(i));
        }
        try self.pushI32(@bitCast(m));
    }

    /// Pop an address and compute the effective address for a SIMD memory op,
    /// bounds-checking `n` bytes. `offset` is a `u32` and the base a `u32`, so
    /// `base + offset + n` cannot overflow `u64` — the check is exact.
    fn simdMemEA(self: *Frame, ma: opcode.MemArg, n: u64) Error!struct { mem: []u8, ea: usize } {
        const base: u32 = @bitCast(self.popI32());
        const mem = try self.memBytes(ma.memory);
        const ea = @as(u64, base) + ma.offset;
        if (ea + n > mem.len) return error.MemoryOutOfBounds;
        return .{ .mem = mem, .ea = @intCast(ea) };
    }
    /// `v128.loadMxN_s/u`: load 8 bytes as `Src` lanes, widen each to `Dst`.
    fn simdLoadExtend(self: *Frame, comptime Src: type, comptime Dst: type, ma: opcode.MemArg) Error!void {
        const N = 8 / @sizeOf(Src); // 8 source bytes → N lanes; N*sizeof(Dst)==16
        const r = try self.simdMemEA(ma, 8);
        const src: [N]Src = @bitCast(r.mem[r.ea..][0..8].*);
        var dst: [N]Dst = undefined;
        for (0..N) |i| dst[i] = src[i]; // widen (sign/zero per Src's signedness)
        try self.pushV128(@bitCast(dst));
    }
    /// `v128.loadN_splat`: load one `Lane` and broadcast it across all lanes.
    fn simdLoadSplat(self: *Frame, comptime Lane: type, ma: opcode.MemArg) Error!void {
        const sz = @sizeOf(Lane);
        const r = try self.simdMemEA(ma, sz);
        const v = std.mem.readInt(Lane, r.mem[r.ea..][0..sz], .little);
        const vec: @Vector(16 / sz, Lane) = @splat(v);
        try self.pushV128(@bitCast(vec));
    }
    /// `v128.loadN_zero`: load `sz` bytes into the low lane, zeroing the rest.
    fn simdLoadZero(self: *Frame, comptime sz: usize, ma: opcode.MemArg) Error!void {
        const r = try self.simdMemEA(ma, sz);
        var bytes: [16]u8 = @splat(0);
        @memcpy(bytes[0..sz], r.mem[r.ea..][0..sz]);
        try self.pushV128(@bitCast(bytes));
    }
    /// `v128.loadN_lane`: replace lane `lane` of the operand v128 with `Lane`
    /// bytes from memory. The v128 is on top of the stack (popped first), the
    /// address below it.
    fn simdLoadLane(self: *Frame, comptime Lane: type, ma: opcode.MemArg, lane: u8) Error!void {
        const sz = @sizeOf(Lane);
        var arr: [16 / sz]Lane = @bitCast(self.popV128());
        const r = try self.simdMemEA(ma, sz);
        arr[lane] = std.mem.readInt(Lane, r.mem[r.ea..][0..sz], .little);
        try self.pushV128(@bitCast(arr));
    }
    /// `v128.storeN_lane`: store lane `lane` of the operand v128 to memory.
    fn simdStoreLane(self: *Frame, comptime Lane: type, ma: opcode.MemArg, lane: u8) Error!void {
        const sz = @sizeOf(Lane);
        const arr: [16 / sz]Lane = @bitCast(self.popV128());
        const r = try self.simdMemEA(ma, sz);
        std.mem.writeInt(Lane, r.mem[r.ea..][0..sz], arr[lane], .little);
    }
    /// Extended multiply: widen the low (or high) half of two `Src` vectors to
    /// `Dst` and multiply lane-wise. `Dst` is twice `Src`'s width, so the product
    /// never overflows.
    fn simdExtmul(self: *Frame, comptime Src: type, comptime Dst: type, comptime high: bool) Error!void {
        const b: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        const a: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        const N = 16 / @sizeOf(Dst); // result lanes
        const base: usize = if (high) N else 0;
        var r: [N]Dst = undefined;
        for (0..N) |i| r[i] = @as(Dst, a[base + i]) * @as(Dst, b[base + i]);
        try self.pushV128(@bitCast(r));
    }
    /// Extended pairwise add: sum adjacent `Src` lane pairs, each sum widened to
    /// `Dst` (which is twice `Src`'s width, so the sum never overflows).
    fn simdExtaddPairwise(self: *Frame, comptime Src: type, comptime Dst: type) Error!void {
        const src: [16 / @sizeOf(Src)]Src = @bitCast(self.popV128());
        const N = 16 / @sizeOf(Dst);
        var r: [N]Dst = undefined;
        for (0..N) |i| r[i] = @as(Dst, src[2 * i]) + @as(Dst, src[2 * i + 1]);
        try self.pushV128(@bitCast(r));
    }
    /// `i16x8.q15mulr_sat_s`: fixed-point Q15 rounding multiply, saturating.
    fn simdQ15mulrSat(self: *Frame) Error!void {
        const b: [8]i16 = @bitCast(self.popV128());
        const a: [8]i16 = @bitCast(self.popV128());
        var r: [8]i16 = undefined;
        for (0..8) |i| r[i] = satTo(i16, (@as(i32, a[i]) * @as(i32, b[i]) + 0x4000) >> 15);
        try self.pushV128(@bitCast(r));
    }
    /// `i32x4.dot_i16x8_s`: multiply i16 lanes pairwise (exact i32 products) and
    /// add adjacent products with wrapping (the spec's modular `iadd`).
    fn simdDot(self: *Frame) Error!void {
        const b: [8]i16 = @bitCast(self.popV128());
        const a: [8]i16 = @bitCast(self.popV128());
        var r: [4]i32 = undefined;
        for (0..4) |i| r[i] = @as(i32, a[2 * i]) * @as(i32, b[2 * i]) +% @as(i32, a[2 * i + 1]) * @as(i32, b[2 * i + 1]);
        try self.pushV128(@bitCast(r));
    }

    /// Execute a `0xFD` SIMD op. Covers const, load/store (incl. splat/extend/
    /// zero and lane load/store), splat, lane get/set, shuffle/swizzle, bitwise,
    /// comparisons, integer & float arithmetic, saturating add/sub, narrow/
    /// extend/extmul, dot, q15, extadd_pairwise, conversions, any/all_true and
    /// bitmask — via Zig `@Vector`. Only the relaxed-SIMD ops and v128 GC-fields
    /// remain unimplemented (they trap `UnsupportedInstruction`).
    fn execSimd(self: *Frame, s: opcode.Simd) Error!void {
        switch (s.sub) {
            0x0c => try self.pushV128(s.bytes), // v128.const
            0x00 => { // v128.load
                const base: u32 = @bitCast(self.popI32());
                const mem = try self.memBytes(s.mem.memory);
                const ea = @as(u64, base) + s.mem.offset;
                if (ea + 16 > mem.len) return error.MemoryOutOfBounds;
                try self.pushV128(std.mem.readInt(u128, mem[@intCast(ea)..][0..16], .little));
            },
            0x0b => { // v128.store
                const v = self.popV128();
                const base: u32 = @bitCast(self.popI32());
                const mem = try self.memBytes(s.mem.memory);
                const ea = @as(u64, base) + s.mem.offset;
                if (ea + 16 > mem.len) return error.MemoryOutOfBounds;
                std.mem.writeInt(u128, mem[@intCast(ea)..][0..16], v, .little);
            },
            0x0d => { // i8x16.shuffle — 16 immediate byte indices into a++b (32 bytes)
                const b: [16]u8 = @bitCast(self.popV128());
                const a: [16]u8 = @bitCast(self.popV128());
                const idx: [16]u8 = @bitCast(s.bytes);
                var r: [16]u8 = undefined;
                for (0..16) |i| r[i] = if (idx[i] < 16) a[idx[i]] else if (idx[i] < 32) b[idx[i] - 16] else 0;
                try self.pushV128(@bitCast(r));
            },
            0x0e => { // i8x16.swizzle — runtime byte indices
                const idx: [16]u8 = @bitCast(self.popV128());
                const a: [16]u8 = @bitCast(self.popV128());
                var r: [16]u8 = undefined;
                for (0..16) |i| r[i] = if (idx[i] < 16) a[idx[i]] else 0;
                try self.pushV128(@bitCast(r));
            },
            // splat
            0x0f => try self.pushV128(@bitCast(@as(@Vector(16, u8), @splat(@truncate(@as(u32, @bitCast(self.popI32()))))))),
            0x10 => try self.pushV128(@bitCast(@as(@Vector(8, u16), @splat(@truncate(@as(u32, @bitCast(self.popI32()))))))),
            0x11 => try self.pushV128(@bitCast(@as(@Vector(4, u32), @splat(@bitCast(self.popI32()))))),
            0x12 => try self.pushV128(@bitCast(@as(@Vector(2, u64), @splat(@bitCast(self.popI64()))))),
            0x13 => try self.pushV128(@bitCast(@as(@Vector(4, u32), @splat(@truncate(self.pop()))))),
            0x14 => try self.pushV128(@bitCast(@as(@Vector(2, u64), @splat(self.pop())))),
            // extract_lane
            0x15 => try self.extractLaneInt(i8, s.lane), // i8x16.extract_lane_s
            0x16 => try self.extractLaneInt(u8, s.lane),
            0x18 => try self.extractLaneInt(i16, s.lane),
            0x19 => try self.extractLaneInt(u16, s.lane),
            0x1b => { // i32x4.extract_lane
                const arr: [4]u32 = @bitCast(self.popV128());
                try self.pushI32(@bitCast(arr[s.lane]));
            },
            0x1d => { // i64x2.extract_lane
                const arr: [2]u64 = @bitCast(self.popV128());
                try self.pushU64(arr[s.lane]);
            },
            0x1f => { // f32x4.extract_lane
                const arr: [4]u32 = @bitCast(self.popV128());
                try self.pushU64(arr[s.lane]);
            },
            0x21 => { // f64x2.extract_lane
                const arr: [2]u64 = @bitCast(self.popV128());
                try self.pushU64(arr[s.lane]);
            },
            // replace_lane
            0x17 => try self.replaceLaneInt(u8, s.lane),
            0x1a => try self.replaceLaneInt(u16, s.lane),
            0x1c => try self.replaceLaneInt(u32, s.lane),
            0x1e => { // i64x2.replace_lane
                const x: u64 = @bitCast(self.popI64());
                var arr: [2]u64 = @bitCast(self.popV128());
                arr[s.lane] = x;
                try self.pushV128(@bitCast(arr));
            },
            0x20 => { // f32x4.replace_lane
                const x: u32 = @truncate(self.pop());
                var arr: [4]u32 = @bitCast(self.popV128());
                arr[s.lane] = x;
                try self.pushV128(@bitCast(arr));
            },
            0x22 => { // f64x2.replace_lane
                const x: u64 = self.pop();
                var arr: [2]u64 = @bitCast(self.popV128());
                arr[s.lane] = x;
                try self.pushV128(@bitCast(arr));
            },
            // comparisons — i8x16 / i16x8 / i32x4 (s/u), f32x4 / f64x2
            0x23 => try self.simdCmp(u8, .eq),
            0x24 => try self.simdCmp(u8, .ne),
            0x25 => try self.simdCmp(i8, .lt),
            0x26 => try self.simdCmp(u8, .lt),
            0x27 => try self.simdCmp(i8, .gt),
            0x28 => try self.simdCmp(u8, .gt),
            0x29 => try self.simdCmp(i8, .le),
            0x2a => try self.simdCmp(u8, .le),
            0x2b => try self.simdCmp(i8, .ge),
            0x2c => try self.simdCmp(u8, .ge),
            0x2d => try self.simdCmp(u16, .eq),
            0x2e => try self.simdCmp(u16, .ne),
            0x2f => try self.simdCmp(i16, .lt),
            0x30 => try self.simdCmp(u16, .lt),
            0x31 => try self.simdCmp(i16, .gt),
            0x32 => try self.simdCmp(u16, .gt),
            0x33 => try self.simdCmp(i16, .le),
            0x34 => try self.simdCmp(u16, .le),
            0x35 => try self.simdCmp(i16, .ge),
            0x36 => try self.simdCmp(u16, .ge),
            0x37 => try self.simdCmp(u32, .eq),
            0x38 => try self.simdCmp(u32, .ne),
            0x39 => try self.simdCmp(i32, .lt),
            0x3a => try self.simdCmp(u32, .lt),
            0x3b => try self.simdCmp(i32, .gt),
            0x3c => try self.simdCmp(u32, .gt),
            0x3d => try self.simdCmp(i32, .le),
            0x3e => try self.simdCmp(u32, .le),
            0x3f => try self.simdCmp(i32, .ge),
            0x40 => try self.simdCmp(u32, .ge),
            0x41 => try self.simdCmp(f32, .eq),
            0x42 => try self.simdCmp(f32, .ne),
            0x43 => try self.simdCmp(f32, .lt),
            0x44 => try self.simdCmp(f32, .gt),
            0x45 => try self.simdCmp(f32, .le),
            0x46 => try self.simdCmp(f32, .ge),
            0x47 => try self.simdCmp(f64, .eq),
            0x48 => try self.simdCmp(f64, .ne),
            0x49 => try self.simdCmp(f64, .lt),
            0x4a => try self.simdCmp(f64, .gt),
            0x4b => try self.simdCmp(f64, .le),
            0x4c => try self.simdCmp(f64, .ge),
            // bitwise (whole v128)
            0x4d => try self.pushV128(~self.popV128()), // v128.not
            0x4e => { // v128.and
                const b = self.popV128();
                try self.pushV128(self.popV128() & b);
            },
            0x4f => { // v128.andnot
                const b = self.popV128();
                try self.pushV128(self.popV128() & ~b);
            },
            0x50 => { // v128.or
                const b = self.popV128();
                try self.pushV128(self.popV128() | b);
            },
            0x51 => { // v128.xor
                const b = self.popV128();
                try self.pushV128(self.popV128() ^ b);
            },
            0x52 => { // v128.bitselect: (a & c) | (b & ~c)
                const c = self.popV128();
                const b = self.popV128();
                const a = self.popV128();
                try self.pushV128((a & c) | (b & ~c));
            },
            0x53 => try self.pushI32(if (self.popV128() != 0) 1 else 0), // v128.any_true
            // i8x16
            0x60 => try self.simdIntUn(i8, .abs),
            0x61 => try self.simdIntUn(i8, .neg),
            0x63 => try self.simdAllTrue(u8),
            0x64 => try self.simdBitmask(u8),
            0x6b => try self.simdShift(u8, .shl),
            0x6c => try self.simdShift(i8, .shr),
            0x6d => try self.simdShift(u8, .shr),
            0x6e => try self.simdIntBin(u8, .add),
            0x71 => try self.simdIntBin(u8, .sub),
            0x76 => try self.simdIntMinMax(i8, false),
            0x77 => try self.simdIntMinMax(u8, false),
            0x78 => try self.simdIntMinMax(i8, true),
            0x79 => try self.simdIntMinMax(u8, true),
            // i16x8
            0x80 => try self.simdIntUn(i16, .abs),
            0x81 => try self.simdIntUn(i16, .neg),
            0x83 => try self.simdAllTrue(u16),
            0x84 => try self.simdBitmask(u16),
            0x8b => try self.simdShift(u16, .shl),
            0x8c => try self.simdShift(i16, .shr),
            0x8d => try self.simdShift(u16, .shr),
            0x8e => try self.simdIntBin(u16, .add),
            0x91 => try self.simdIntBin(u16, .sub),
            0x95 => try self.simdIntBin(u16, .mul),
            0x96 => try self.simdIntMinMax(i16, false),
            0x97 => try self.simdIntMinMax(u16, false),
            0x98 => try self.simdIntMinMax(i16, true),
            0x99 => try self.simdIntMinMax(u16, true),
            // i32x4
            0xa0 => try self.simdIntUn(i32, .abs),
            0xa1 => try self.simdIntUn(i32, .neg),
            0xa3 => try self.simdAllTrue(u32),
            0xa4 => try self.simdBitmask(u32),
            0xab => try self.simdShift(u32, .shl),
            0xac => try self.simdShift(i32, .shr),
            0xad => try self.simdShift(u32, .shr),
            0xae => try self.simdIntBin(u32, .add),
            0xb1 => try self.simdIntBin(u32, .sub),
            0xb5 => try self.simdIntBin(u32, .mul),
            0xb6 => try self.simdIntMinMax(i32, false),
            0xb7 => try self.simdIntMinMax(u32, false),
            0xb8 => try self.simdIntMinMax(i32, true),
            0xb9 => try self.simdIntMinMax(u32, true),
            // i64x2
            0xc1 => try self.simdIntUn(i64, .neg),
            0xcb => try self.simdShift(u64, .shl),
            0xcc => try self.simdShift(i64, .shr),
            0xcd => try self.simdShift(u64, .shr),
            0xce => try self.simdIntBin(u64, .add),
            0xd1 => try self.simdIntBin(u64, .sub),
            0xd5 => try self.simdIntBin(u64, .mul),
            // f32x4
            0xe0 => try self.simdFloatUn(f32, .abs),
            0xe1 => try self.simdFloatUn(f32, .neg),
            0xe3 => try self.simdFloatUn(f32, .sqrt),
            0x67 => try self.simdFloatUn(f32, .ceil),
            0x68 => try self.simdFloatUn(f32, .floor),
            0x69 => try self.simdFloatUn(f32, .trunc),
            0xe4 => try self.simdFloatBin(f32, .add),
            0xe5 => try self.simdFloatBin(f32, .sub),
            0xe6 => try self.simdFloatBin(f32, .mul),
            0xe7 => try self.simdFloatBin(f32, .div),
            0xe8 => try self.simdFloatBin(f32, .min),
            0xe9 => try self.simdFloatBin(f32, .max),
            0xea => try self.simdFloatBin(f32, .pmin),
            0xeb => try self.simdFloatBin(f32, .pmax),
            // f64x2
            0xec => try self.simdFloatUn(f64, .abs),
            0xed => try self.simdFloatUn(f64, .neg),
            0xef => try self.simdFloatUn(f64, .sqrt),
            0x74 => try self.simdFloatUn(f64, .ceil),
            0x75 => try self.simdFloatUn(f64, .floor),
            0x7a => try self.simdFloatUn(f64, .trunc),
            0xf0 => try self.simdFloatBin(f64, .add),
            0xf1 => try self.simdFloatBin(f64, .sub),
            0xf2 => try self.simdFloatBin(f64, .mul),
            0xf3 => try self.simdFloatBin(f64, .div),
            0xf4 => try self.simdFloatBin(f64, .min),
            0xf5 => try self.simdFloatBin(f64, .max),
            0xf6 => try self.simdFloatBin(f64, .pmin),
            0xf7 => try self.simdFloatBin(f64, .pmax),
            // saturating add/sub, avgr, popcnt, i64 abs
            0x6f => try self.simdSatAddSub(i8, true),
            0x70 => try self.simdSatAddSub(u8, true),
            0x72 => try self.simdSatAddSub(i8, false),
            0x73 => try self.simdSatAddSub(u8, false),
            0x8f => try self.simdSatAddSub(i16, true),
            0x90 => try self.simdSatAddSub(u16, true),
            0x92 => try self.simdSatAddSub(i16, false),
            0x93 => try self.simdSatAddSub(u16, false),
            0x7b => try self.simdAvgrU(u8),
            0x9b => try self.simdAvgrU(u16),
            0x62 => try self.simdPopcnt(u8),
            0xc0 => try self.simdIntUn(i64, .abs),
            // extend (widen) low/high halves
            0x87 => try self.simdExtend(i8, i16, false),
            0x88 => try self.simdExtend(i8, i16, true),
            0x89 => try self.simdExtend(u8, u16, false),
            0x8a => try self.simdExtend(u8, u16, true),
            0xa7 => try self.simdExtend(i16, i32, false),
            0xa8 => try self.simdExtend(i16, i32, true),
            0xa9 => try self.simdExtend(u16, u32, false),
            0xaa => try self.simdExtend(u16, u32, true),
            0xc7 => try self.simdExtend(i32, i64, false),
            0xc8 => try self.simdExtend(i32, i64, true),
            0xc9 => try self.simdExtend(u32, u64, false),
            0xca => try self.simdExtend(u32, u64, true),
            // narrow (saturating)
            0x65 => try self.simdNarrow(i16, i8),
            0x66 => try self.simdNarrow(i16, u8),
            0x85 => try self.simdNarrow(i32, i16),
            0x86 => try self.simdNarrow(i32, u16),
            // int<->float conversions
            0xfa => try self.simdConvert(i32, f32, false), // f32x4.convert_i32x4_s
            0xfb => try self.simdConvert(u32, f32, false),
            0xfe => try self.simdConvert(i32, f64, true), // f64x2.convert_low_i32x4_s
            0xff => try self.simdConvert(u32, f64, true),
            0xf8 => try self.simdTruncSat(f32, i32, false), // i32x4.trunc_sat_f32x4_s
            0xf9 => try self.simdTruncSat(f32, u32, false),
            0xfc => try self.simdTruncSat(f64, i32, true), // ..._f64x2_s_zero
            0xfd => try self.simdTruncSat(f64, u32, true),
            0x5e => { // f64x2.promote_low_f32x4
                const src: [4]f32 = @bitCast(self.popV128());
                const dst = [2]f64{ src[0], src[1] };
                try self.pushV128(@bitCast(dst));
            },
            0x5f => { // f32x4.demote_f64x2_zero
                const src: [2]f64 = @bitCast(self.popV128());
                const dst = [4]f32{ @floatCast(src[0]), @floatCast(src[1]), 0, 0 };
                try self.pushV128(@bitCast(dst));
            },
            // widening loads: load8x8 / load16x4 / load32x2 (s/u)
            0x01 => try self.simdLoadExtend(i8, i16, s.mem),
            0x02 => try self.simdLoadExtend(u8, u16, s.mem),
            0x03 => try self.simdLoadExtend(i16, i32, s.mem),
            0x04 => try self.simdLoadExtend(u16, u32, s.mem),
            0x05 => try self.simdLoadExtend(i32, i64, s.mem),
            0x06 => try self.simdLoadExtend(u32, u64, s.mem),
            // load-splat / load-zero
            0x07 => try self.simdLoadSplat(u8, s.mem),
            0x08 => try self.simdLoadSplat(u16, s.mem),
            0x09 => try self.simdLoadSplat(u32, s.mem),
            0x0a => try self.simdLoadSplat(u64, s.mem),
            0x5c => try self.simdLoadZero(4, s.mem),
            0x5d => try self.simdLoadZero(8, s.mem),
            // load-lane / store-lane
            0x54 => try self.simdLoadLane(u8, s.mem, s.lane),
            0x55 => try self.simdLoadLane(u16, s.mem, s.lane),
            0x56 => try self.simdLoadLane(u32, s.mem, s.lane),
            0x57 => try self.simdLoadLane(u64, s.mem, s.lane),
            0x58 => try self.simdStoreLane(u8, s.mem, s.lane),
            0x59 => try self.simdStoreLane(u16, s.mem, s.lane),
            0x5a => try self.simdStoreLane(u32, s.mem, s.lane),
            0x5b => try self.simdStoreLane(u64, s.mem, s.lane),
            // extadd_pairwise
            0x7c => try self.simdExtaddPairwise(i8, i16),
            0x7d => try self.simdExtaddPairwise(u8, u16),
            0x7e => try self.simdExtaddPairwise(i16, i32),
            0x7f => try self.simdExtaddPairwise(u16, u32),
            // q15mulr / dot
            0x82 => try self.simdQ15mulrSat(),
            0xba => try self.simdDot(),
            // extmul low/high — i16x8 / i32x4 / i64x2
            0x9c => try self.simdExtmul(i8, i16, false),
            0x9d => try self.simdExtmul(i8, i16, true),
            0x9e => try self.simdExtmul(u8, u16, false),
            0x9f => try self.simdExtmul(u8, u16, true),
            0xbc => try self.simdExtmul(i16, i32, false),
            0xbd => try self.simdExtmul(i16, i32, true),
            0xbe => try self.simdExtmul(u16, u32, false),
            0xbf => try self.simdExtmul(u16, u32, true),
            0xdc => try self.simdExtmul(i32, i64, false),
            0xdd => try self.simdExtmul(i32, i64, true),
            0xde => try self.simdExtmul(u32, u64, false),
            0xdf => try self.simdExtmul(u32, u64, true),
            // i64x2 comparisons (signed lt/gt/le/ge; eq/ne signedness-agnostic)
            0xd6 => try self.simdCmp(u64, .eq),
            0xd7 => try self.simdCmp(u64, .ne),
            0xd8 => try self.simdCmp(i64, .lt),
            0xd9 => try self.simdCmp(i64, .gt),
            0xda => try self.simdCmp(i64, .le),
            0xdb => try self.simdCmp(i64, .ge),
            else => return error.UnsupportedInstruction,
        }
    }

    /// `iNxM.extract_lane_s/u`: read lane `lane` of type `Lane`, sign- or zero-
    /// extend (per `Lane`'s signedness) to i32.
    fn extractLaneInt(self: *Frame, comptime Lane: type, lane: u8) Error!void {
        const arr: [16 / @sizeOf(Lane)]Lane = @bitCast(self.popV128());
        try self.pushI32(@intCast(arr[lane]));
    }
    /// `iNxM.replace_lane`: set lane `lane` from a truncated i32.
    fn replaceLaneInt(self: *Frame, comptime Lane: type, lane: u8) Error!void {
        const x: Lane = @truncate(@as(u32, @bitCast(self.popI32())));
        var arr: [16 / @sizeOf(Lane)]Lane = @bitCast(self.popV128());
        arr[lane] = x;
        try self.pushV128(@bitCast(arr));
    }
};

/// Clamp an integer `x` into `Dst`'s range (saturating narrow).
fn satTo(comptime Dst: type, x: anytype) Dst {
    const lo = std.math.minInt(Dst);
    const hi = std.math.maxInt(Dst);
    if (x < lo) return lo;
    if (x > hi) return hi;
    return @intCast(x);
}

/// Truncate a float toward zero into `Int`'s range, saturating; NaN → 0. The
/// bounds are compared in f64 (which represents i32/u32 bounds exactly, unlike f32).
fn satTruncLane(comptime Int: type, x: anytype) Int {
    if (std.math.isNan(x)) return 0;
    const tf: f64 = @trunc(x);
    if (tf <= @as(f64, std.math.minInt(Int))) return std.math.minInt(Int);
    if (tf >= @as(f64, std.math.maxInt(Int))) return std.math.maxInt(Int);
    return @intFromFloat(tf);
}

/// Evaluate a v128 global's init const-expr (`v128.const <16 bytes> end`) to a
/// u128. (A v128 global initialized from an imported v128 global is not
/// supported — rare — and errors.)
fn evalConstV128(expr: []const u8) Error!u128 {
    var r = Reader.init(expr);
    if ((try r.readByte()) != 0xfd) return error.UnsupportedInstruction;
    if ((try r.readVarU32()) != 0x0c) return error.UnsupportedInstruction; // v128.const
    var v: u128 = 0;
    var i: u5 = 0;
    while (i < 16) : (i += 1) v |= @as(u128, try r.readByte()) << (@as(u7, i) * 8);
    return v;
}

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

// --- Exception handling tests (Phase 6) ------------------------------------
// These build module binaries by hand (no assembler yet) so they exercise the
// tag-section decode, the validator's try_table/throw typing, and the
// interpreter's unwinding directly. Section bodies are raw opcode bytes; the
// helper frames the section/body lengths so only the opcodes are hand-written.

fn ehUleb(a: std.mem.Allocator, out: *std.ArrayList(u8), v: usize) !void {
    var x = v;
    while (true) {
        var b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) b |= 0x80;
        try out.append(a, b);
        if (x == 0) break;
    }
}

const EhSection = struct { id: u8, body: []const u8 };

fn ehModule(a: std.mem.Allocator, sections: []const EhSection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    for (sections) |s| {
        try out.append(a, s.id);
        try ehUleb(a, &out, s.body.len);
        try out.appendSlice(a, s.body);
    }
    return out.toOwnedSlice(a);
}

/// Frame a code section from raw function bodies (count + per-body size).
fn ehCode(a: std.mem.Allocator, bodies: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try ehUleb(a, &out, bodies.len);
    for (bodies) |b| {
        try ehUleb(a, &out, b.len);
        try out.appendSlice(a, b);
    }
    return out.toOwnedSlice(a);
}

fn instantiateValidated(bytes: []const u8) !Instance {
    const m = try std.testing.allocator.create(Module);
    errdefer std.testing.allocator.destroy(m);
    m.* = try Module_decode(std.testing.allocator, bytes);
    errdefer m.deinit();
    try @import("validate.zig").validate(std.testing.allocator, m);
    return Instance.init(std.testing.allocator, m);
}

test "EH: throw is caught by a matching catch, carrying the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f } }, // (func(param i32)), (func()->i32)
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } }, // tag 0 : type 0
        .{ .id = 3, .body = &.{ 0x01, 0x01 } }, // func 0 : type 1
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try_table (result i32) (catch 0 0) ; i32.const 42 ; throw 0 ; end
            &.{ 0x00, 0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00, 0x41, 0x2a, 0x08, 0x00, 0x0b, 0x0b },
        }) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 42), asI32(r[0]));
}

test "EH: catch_all catches any tag and control resumes after the try_table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } }, // (func), (func()->i32)
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try_table (catch_all 0) ; throw 0 ; end ; i32.const 55
            &.{ 0x00, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x08, 0x00, 0x0b, 0x41, 0x37, 0x0b },
        }) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 55), asI32(r[0]));
}

test "EH: an uncaught throw traps (UncaughtException)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x00 } }, // (func)
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{ 0x00, 0x08, 0x00, 0x0b }}) }, // throw 0 ; end
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    try std.testing.expectError(error.UncaughtException, inst.invoke("f", &.{}));
}

test "EH: an exception thrown in a callee is caught in the caller's try_table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } }, // (func), (func()->i32)
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x02, 0x00, 0x01 } }, // func0:type0 (callee), func1:type1 (caller)
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x01 } }, // export caller (func 1)
        .{ .id = 10, .body = try ehCode(a, &.{
            &.{ 0x00, 0x08, 0x00, 0x0b }, // callee: throw 0 ; end
            // caller: try_table (catch_all 0) ; call 0 ; end ; i32.const 7
            &.{ 0x00, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x10, 0x00, 0x0b, 0x41, 0x07, 0x0b },
        }) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 7), asI32(r[0]));
}

test "EH: catch_ref materializes a non-null exnref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try_table (result exnref) (catch_ref 0 0) ; throw 0 ; end ; ref.is_null
            &.{ 0x00, 0x1f, 0x69, 0x01, 0x01, 0x00, 0x00, 0x08, 0x00, 0x0b, 0xd1, 0x0b },
        }) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 0), asI32(r[0])); // non-null exnref => ref.is_null = 0
}

test "EH: throw_ref rethrows a caught exnref to an outer catch_all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00,
            0x1f, 0x40, 0x01, 0x02, 0x00, // outer try_table (catch_all 0)
            0x1f, 0x69, 0x01, 0x01, 0x00, 0x00, // inner try_table (result exnref) (catch_ref 0 0)
            0x08, 0x00, // throw 0
            0x0b, // end inner
            0x0a, // throw_ref
            0x0b, // end outer
            0x41, 0x05, // i32.const 5
            0x0b, // end func
        }}) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 5), asI32(r[0]));
}

test "EH: an imported tag leads the tag index space and can be thrown + caught" {
    // Import a tag from env, then throw/catch it by index 0 (the imported tag),
    // proving imported tags decode and lead the tag index space (Phase 6.2).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f } }, // (func(param i32)), (func()->i32)
        // import "env"."e" (tag (type 0)) — kind 0x04, attr 0x00, typeidx 0.
        .{ .id = 2, .body = &.{ 0x01, 0x03, 'e', 'n', 'v', 0x01, 'e', 0x04, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } }, // func 0 : type 1
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try_table (result i32) (catch 0 0) ; i32.const 42 ; throw 0 ; end
            &.{ 0x00, 0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00, 0x41, 0x2a, 0x08, 0x00, 0x0b, 0x0b },
        }) },
    });
    var inst = try instantiateValidated(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 42), asI32(r[0]));
}

// --- Legacy exception handling tests (Phase 6.3) ---------------------------
// Older LLVM emits `try`/`catch`/`catch_all`/`rethrow` (not `try_table`). These
// hand-built binaries exercise the interpreter directly (the validator does not
// model legacy try, and the CLI run path does not validate).

test "legacy EH: try/catch catches a thrown exception and binds its payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } }, // tag 0 : type 0 (param i32)
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try (result i32) ; i32.const 42 ; throw 0 ; catch 0 ; end
            &.{ 0x00, 0x06, 0x7f, 0x41, 0x2a, 0x08, 0x00, 0x07, 0x00, 0x0b, 0x0b },
        }) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 42), asI32(r[0])); // caught payload becomes the result
}

test "legacy EH: a try body that does not throw skips the catch handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try (result i32) ; i32.const 7 ; catch 0 ; (unreached) ; end
            &.{ 0x00, 0x06, 0x7f, 0x41, 0x07, 0x07, 0x00, 0x0b, 0x0b },
        }) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 7), asI32(r[0]));
}

test "legacy EH: catch_all catches any tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } }, // (func), (func()->i32)
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            // try (result i32) ; throw 0 ; catch_all ; i32.const 5 ; end
            &.{ 0x00, 0x06, 0x7f, 0x08, 0x00, 0x19, 0x41, 0x05, 0x0b, 0x0b },
        }) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 5), asI32(r[0]));
}

test "legacy EH: rethrow from an inner catch propagates to an outer catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 13, .body = &.{ 0x01, 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00,
            0x06, 0x7f, // OUTER try (result i32)
            0x06, 0x40, // INNER try (void)
            0x08, 0x00, // throw 0
            0x19, // catch_all (inner)
            0x09, 0x00, // rethrow 0  (re-raise inner's exception)
            0x0b, // end inner
            0x41, 0x00, // i32.const 0 (not reached)
            0x19, // catch_all (outer)
            0x41, 0x09, // i32.const 9
            0x0b, // end outer
            0x0b, // end func
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 9), asI32(r[0]));
}

// --- Multi-memory tests (Phase 7) ------------------------------------------
// Two defined memories; loads/stores/bulk ops select one by index (the memarg's
// bit-6 flag carries an explicit index). Hand-built binaries exercise decode +
// execute directly (the CLI run path doesn't validate).

test "multi-memory: a store to memory 1 does not touch memory 0 (index routing)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } }, // (func()->i32)
        .{ .id = 5, .body = &.{ 0x02, 0x00, 0x01, 0x00, 0x01 } }, // 2 memories, each min 1
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00,
            0x41, 0x00, 0x41, 0x07, 0x36, 0x02, 0x00, // i32.store mem0[0] = 7  (align 2, offset 0)
            0x41, 0x00, 0x41, 0x09, 0x36, 0x42, 0x01, 0x00, // i32.store (memory 1) [0] = 9  (align|0x40, memidx 1)
            0x41, 0x00, 0x28, 0x02, 0x00, // i32.load mem0[0]  -> 7 (not clobbered by the mem1 store)
            0x0b,
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 7), asI32(r[0]));
}

test "multi-memory: memory.copy moves bytes between two memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 5, .body = &.{ 0x02, 0x00, 0x01, 0x00, 0x01 } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'g', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00,
            0x41, 0x00, 0x41, 0x37, 0x36, 0x42, 0x01, 0x00, // i32.store (memory 1) [0] = 55
            0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0a, 0x00, 0x01, // memory.copy dst=mem0 src=mem1 (dst0,src0,n1)
            0x41, 0x00, 0x28, 0x02, 0x00, // i32.load mem0[0] -> 55 (copied from mem1)
            0x0b,
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("g", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 55), asI32(r[0]));
}

test "multi-memory: memory.size / memory.grow select by index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        // mem0 min 1, mem1 min 3
        .{ .id = 5, .body = &.{ 0x02, 0x00, 0x01, 0x00, 0x03 } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00,
            0x3f, 0x01, // memory.size (memory 1) -> 3
            0x0b,
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 3), asI32(r[0])); // mem1 has 3 pages, not mem0's 1
}

// --- SIMD (v128) tests (Phase 8) -------------------------------------------
// A v128 is two u64 stack slots. These hand-built binaries prove the two-slot
// model end to end: v128 held in a LOCAL (2 slots), lane arithmetic, extract,
// and load/store to linear memory.

test "SIMD: v128 in a local, i32x4.add, extract_lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } }, // (func()->i32)
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x01, 0x01, 0x7b, // 1 local: v128  (occupies 2 slots)
            0xfd, 0x0c, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, // v128.const i32x4(1,2,3,4)
            0x21, 0x00, // local.set 0   (pops 2 slots)
            0x20, 0x00, // local.get 0   (pushes 2 slots)
            0xfd, 0x0c, 10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 0, 40, 0, 0, 0, // v128.const i32x4(10,20,30,40)
            0xfd, 0xae, 0x01, // i32x4.add  (sub-opcode 0xae = LEB 0xae 0x01) -> (11,22,33,44)
            0xfd, 0x1b, 0x02, // i32x4.extract_lane 2  -> 33
            0x0b,
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 33), asI32(r[0]));
}

test "SIMD: i32x4.splat -> v128.store -> v128.load -> extract_lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 5, .body = &.{ 0x01, 0x00, 0x01 } }, // 1 memory, min 1
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'g', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&.{
            0x00, // no locals
            0x41, 0x00, // i32.const 0 (store addr)
            0x41, 0x07, // i32.const 7
            0xfd, 0x11, // i32x4.splat -> (7,7,7,7)
            0xfd, 0x0b, 0x00, 0x00, // v128.store (align 0, offset 0)
            0x41, 0x00, // i32.const 0 (load addr)
            0xfd, 0x00, 0x00, 0x00, // v128.load (align 0, offset 0)
            0xfd, 0x1b, 0x00, // i32x4.extract_lane 0 -> 7
            0x0b,
        }}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("g", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 7), asI32(r[0]));
}

test "SIMD: f32x4.mul lane-wise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (2.0,2.0,2.0,2.0) * (3.0,1.5,4.0,0.5) -> lane 1 = 3.0
    const two = @as(u32, @bitCast(@as(f32, 2.0)));
    const b0 = @as(u32, @bitCast(@as(f32, 3.0)));
    const b1 = @as(u32, @bitCast(@as(f32, 1.5)));
    const b2 = @as(u32, @bitCast(@as(f32, 4.0)));
    const b3 = @as(u32, @bitCast(@as(f32, 0.5)));
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7d } }, // (func()->f32)
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{
            &([_]u8{ 0x00, 0xfd, 0x0c } ++ le32(two) ++ le32(two) ++ le32(two) ++ le32(two) ++
                [_]u8{ 0xfd, 0x0c } ++ le32(b0) ++ le32(b1) ++ le32(b2) ++ le32(b3) ++
                [_]u8{ 0xfd, 0xe6, 0x01, 0xfd, 0x1f, 0x01, 0x0b }), // f32x4.mul ; f32x4.extract_lane 1 ; end
        }) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(f32, 3.0), asF32(r[0]));
}

fn le32(x: u32) [4]u8 {
    return .{ @truncate(x), @truncate(x >> 8), @truncate(x >> 16), @truncate(x >> 24) };
}

test "SIMD: i32x4.eq produces an all-ones lane mask" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0x00, 0xfd, 0x0c } ++ le32(1) ++ le32(2) ++ le32(3) ++ le32(4) ++
        [_]u8{ 0xfd, 0x0c } ++ le32(1) ++ le32(9) ++ le32(3) ++ le32(9) ++
        [_]u8{ 0xfd, 0x37, 0xfd, 0x1b, 0x00, 0x0b }; // i32x4.eq ; extract_lane 0 -> -1
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, -1), asI32(r[0]));
}

test "SIMD: i32x4.max_s picks the signed max per lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0x00, 0xfd, 0x0c } ++ le32(5) ++ le32(2) ++ le32(8) ++ le32(1) ++
        [_]u8{ 0xfd, 0x0c } ++ le32(3) ++ le32(7) ++ le32(8) ++ le32(0) ++
        [_]u8{ 0xfd, 0xb8, 0x01, 0xfd, 0x1b, 0x01, 0x0b }; // i32x4.max_s ; extract_lane 1 -> 7
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 7), asI32(r[0]));
}

test "SIMD: drop of a v128 pops both slots (width-aware)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // i32.const 42 ; v128.const(..) ; drop ; end  -> 42 (drop must remove BOTH v128 slots)
    const body = [_]u8{ 0x00, 0x41, 0x2a, 0xfd, 0x0c } ++ le32(1) ++ le32(2) ++ le32(3) ++ le32(4) ++ [_]u8{ 0x1a, 0x0b };
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 42), asI32(r[0]));
}

test "SIMD: select of two v128s picks the whole vector (width-aware)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // v128.const A ; v128.const B ; i32.const 1 ; select ; i32x4.extract_lane 0 -> A[0] = 10
    const body = [_]u8{ 0x00, 0xfd, 0x0c } ++ le32(10) ++ le32(20) ++ le32(30) ++ le32(40) ++
        [_]u8{ 0xfd, 0x0c } ++ le32(50) ++ le32(60) ++ le32(70) ++ le32(80) ++
        [_]u8{ 0x41, 0x01, 0x1b, 0xfd, 0x1b, 0x00, 0x0b };
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 10), asI32(r[0]));
}

test "SIMD: typed select (select_t v128) is width-aware" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ... i32.const 0 ; select_t v128 ; extract_lane 0 -> B[0] = 50 (cond 0 picks second)
    const body = [_]u8{ 0x00, 0xfd, 0x0c } ++ le32(10) ++ le32(20) ++ le32(30) ++ le32(40) ++
        [_]u8{ 0xfd, 0x0c } ++ le32(50) ++ le32(60) ++ le32(70) ++ le32(80) ++
        [_]u8{ 0x41, 0x00, 0x1c, 0x01, 0x7b, 0xfd, 0x1b, 0x00, 0x0b }; // select_t (1 type: v128)
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 50), asI32(r[0]));
}

test "SIMD: i8x16.add_sat_s saturates instead of wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // splat(100) + splat(100) with signed saturation -> 127 (not -56 wrap).
    // 100 is encoded as multi-byte SLEB (0xe4 0x00) — a single 0x64 byte is -28.
    const body = [_]u8{ 0x00, 0x41, 0xe4, 0x00, 0xfd, 0x0f, 0x41, 0xe4, 0x00, 0xfd, 0x0f, 0xfd, 0x6f, 0xfd, 0x15, 0x00, 0x0b };
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 127), asI32(r[0]));
}

test "SIMD: i16x8.extend_low_i8x16_s sign-extends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // splat(-1) as i8x16 ; extend_low_s -> i16 ; extract_lane_s 0 -> -1 (not 255)
    const body = [_]u8{ 0x00, 0x41, 0x7f, 0xfd, 0x0f, 0xfd, 0x87, 0x01, 0xfd, 0x18, 0x00, 0x0b };
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&body}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, -1), asI32(r[0]));
}

test "SIMD: a v128 global initializes, gets, and extracts a lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // global 0: (global v128 (v128.const i32x4 7 8 9 10))
    const gbody = [_]u8{ 0x01, 0x7b, 0x00, 0xfd, 0x0c } ++ le32(7) ++ le32(8) ++ le32(9) ++ le32(10) ++ [_]u8{0x0b};
    // f: global.get 0 ; i32x4.extract_lane 2 -> 9
    const fbody = [_]u8{ 0x00, 0x23, 0x00, 0xfd, 0x1b, 0x02, 0x0b };
    const bytes = try ehModule(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 6, .body = &gbody },
        .{ .id = 7, .body = &.{ 0x01, 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 10, .body = try ehCode(a, &.{&fbody}) },
    });
    var inst = try instantiate(bytes);
    defer destroy(&inst);
    const r = try inst.invoke("f", &.{});
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(i32, 9), asI32(r[0]));
}
