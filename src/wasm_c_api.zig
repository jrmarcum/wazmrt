//! wazmrt's implementation of the standard **WebAssembly C API** (wasm-c-api).
//!
//! The contract is the vendored standard header
//! `third_party/wasm-c-api/include/wasm.h` (Apache-2.0; see
//! `third_party/LICENSES.md`). Implementing it means any wasm-c-api consumer —
//! including the `universalWasmLoader-*` loaders, wasmtime, and wasmer clients —
//! binds to wazmrt identically.
//!
//! **Minimal-now, expand-later (within the standard).** This file backs only
//! what the runtime can do today: `config`/`engine`/`store` lifecycle, byte
//! vectors, and module `new`/`validate`/`delete`. Instances, functions, traps,
//! globals, tables, memories, and calls are declared in the standard header but
//! intentionally left unimplemented until instantiation/execution exist — an
//! undefined symbol in a static library only errors if a consumer references it.
//!
//! Libc-free: uses `std.heap.smp_allocator` (see `cmem/design-decisions.md`).

const std = @import("std");
const root = @import("root.zig");
const types = @import("types.zig");

const alloc = std.heap.smp_allocator;

// ---- Opaque objects -------------------------------------------------------
// C sees only `struct wasm_*_t*`; layout is private. The padding byte gives
// each a distinct heap allocation (so handles compare unequal) and keeps the
// types non-zero-sized.

const Config = struct { _pad: u8 = 0 };
const Engine = struct { _pad: u8 = 0 };
const Store = struct { engine: *Engine };
const Module = struct { inner: root.Module };

// ---- wasm_byte_vec_t ------------------------------------------------------
// Must match the C layout exactly: `struct { size_t size; wasm_byte_t* data; }`
// with `wasm_byte_t == char`.

const ByteVec = extern struct {
    size: usize,
    data: [*c]u8,

    fn empty(out: *ByteVec) void {
        out.size = 0;
        out.data = null;
    }
};

/// Borrow a byte vector's contents as a Zig slice (empty if null/zero-length).
fn vecSlice(vec: *const ByteVec) []const u8 {
    if (vec.size != 0 and vec.data != null) return vec.data[0..vec.size];
    return &[_]u8{};
}

// ---- Byte vectors ---------------------------------------------------------

export fn wasm_byte_vec_new_empty(out: *ByteVec) void {
    out.empty();
}

export fn wasm_byte_vec_new_uninitialized(out: *ByteVec, size: usize) void {
    if (size == 0) return out.empty();
    const buf = alloc.alloc(u8, size) catch return out.empty();
    out.size = size;
    out.data = buf.ptr;
}

export fn wasm_byte_vec_new(out: *ByteVec, size: usize, data: [*c]const u8) void {
    if (size == 0 or data == null) return out.empty();
    const buf = alloc.alloc(u8, size) catch return out.empty();
    @memcpy(buf, data[0..size]);
    out.size = size;
    out.data = buf.ptr;
}

export fn wasm_byte_vec_copy(out: *ByteVec, src: *const ByteVec) void {
    wasm_byte_vec_new(out, src.size, src.data);
}

export fn wasm_byte_vec_delete(vec: *ByteVec) void {
    if (vec.data != null and vec.size != 0) alloc.free(vec.data[0..vec.size]);
    vec.empty();
}

// ---- Config / Engine / Store ---------------------------------------------

export fn wasm_config_new() ?*Config {
    return alloc.create(Config) catch null;
}

export fn wasm_config_delete(config: ?*Config) void {
    if (config) |c| alloc.destroy(c);
}

export fn wasm_engine_new() ?*Engine {
    return alloc.create(Engine) catch null;
}

export fn wasm_engine_new_with_config(config: ?*Config) ?*Engine {
    // We take ownership of the config; no tunable knobs are defined yet.
    if (config) |c| alloc.destroy(c);
    return alloc.create(Engine) catch null;
}

export fn wasm_engine_delete(engine: ?*Engine) void {
    if (engine) |e| alloc.destroy(e);
}

export fn wasm_store_new(engine: ?*Engine) ?*Store {
    const e = engine orelse return null;
    const s = alloc.create(Store) catch return null;
    s.* = .{ .engine = e };
    return s;
}

export fn wasm_store_delete(store: ?*Store) void {
    if (store) |s| alloc.destroy(s);
}

// ---- Modules --------------------------------------------------------------

export fn wasm_module_new(store: ?*Store, binary: ?*const ByteVec) ?*Module {
    _ = store;
    const bin = binary orelse return null;
    const m = alloc.create(Module) catch return null;
    m.inner = root.decode(alloc, vecSlice(bin)) catch {
        alloc.destroy(m);
        return null;
    };
    return m;
}

export fn wasm_module_validate(store: ?*Store, binary: ?*const ByteVec) bool {
    _ = store;
    const bin = binary orelse return false;
    var m = root.decode(alloc, vecSlice(bin)) catch return false;
    m.deinit();
    return true;
}

export fn wasm_module_delete(module: ?*Module) void {
    const m = module orelse return;
    m.inner.deinit();
    alloc.destroy(m);
}

// ===========================================================================
// Type introspection: wasm_module_imports / wasm_module_exports and the
// wasm-c-api type-object hierarchy they return.
//
// Each concrete type object (`FuncType`/`GlobalType`/`TableType`/`MemoryType`)
// is an `extern struct` whose first field is `ekind`, so a pointer to it
// doubles as a `wasm_externtype_t*` — the wasm-c-api "is-a externtype"
// convention, letting `wasm_*type_as_externtype` / `wasm_externtype_as_*type`
// be plain pointer casts and `wasm_externtype_kind` read the first byte.
// ===========================================================================

const Valkind = u8; // wasm_valkind_t
const Externkind = u8; // wasm_externkind_t (C order: func,global,table,memory,tag)
const EXTERN_FUNC: Externkind = 0;
const EXTERN_GLOBAL: Externkind = 1;
const EXTERN_TABLE: Externkind = 2;
const EXTERN_MEMORY: Externkind = 3;

/// wasm_limits_t: `{ uint32_t min; uint32_t max; }` (max 0xffffffff == none).
const Limits = extern struct { min: u32, max: u32 };

const ValType = struct { kind: Valkind };

const ValTypeVec = extern struct { size: usize, data: [*c]?*ValType };
const ImportTypeVec = extern struct { size: usize, data: [*c]?*ImportType };
const ExportTypeVec = extern struct { size: usize, data: [*c]?*ExportType };

const FuncType = extern struct { ekind: Externkind, params: ValTypeVec, results: ValTypeVec };
const GlobalType = extern struct { ekind: Externkind, content: ?*ValType, mutability: u8 };
const TableType = extern struct { ekind: Externkind, element: ?*ValType, limits: Limits };
const MemoryType = extern struct { ekind: Externkind, limits: Limits };

const ImportType = struct { module: ByteVec, name: ByteVec, ext: ?*anyopaque };
const ExportType = struct { name: ByteVec, ext: ?*anyopaque };

fn valkindOf(v: types.ValType) Valkind {
    return switch (v) {
        .i32 => 0,
        .i64 => 1,
        .f32 => 2,
        .f64 => 3,
        else => {
            // Any reference maps to the two base wasm-c-api ref kinds by family
            // (func → funcref, everything else → externref). Non-ref/unknown
            // (e.g. v128) has no base valkind — default to i32.
            if (!v.isRef()) return 0;
            return if (v.refHeap() == .func) 129 else 128;
        },
    };
}

fn limitsOf(l: root.Module.Limits) Limits {
    return .{ .min = l.min, .max = l.max orelse 0xffff_ffff };
}

fn makeValType(v: types.ValType) ?*ValType {
    const vt = alloc.create(ValType) catch return null;
    vt.* = .{ .kind = valkindOf(v) };
    return vt;
}

fn makeValTypeVec(out: *ValTypeVec, src: []const types.ValType) void {
    if (src.len == 0) {
        out.* = .{ .size = 0, .data = null };
        return;
    }
    const arr = alloc.alloc(?*ValType, src.len) catch {
        out.* = .{ .size = 0, .data = null };
        return;
    };
    for (arr, src) |*slot, v| slot.* = makeValType(v);
    out.* = .{ .size = src.len, .data = arr.ptr };
}

fn makeExternType(ext: root.Module.Extern) ?*anyopaque {
    switch (ext) {
        .func => |ft| {
            const obj = alloc.create(FuncType) catch return null;
            obj.ekind = EXTERN_FUNC;
            makeValTypeVec(&obj.params, ft.params);
            makeValTypeVec(&obj.results, ft.results);
            return @ptrCast(obj);
        },
        .global => |gt| {
            const obj = alloc.create(GlobalType) catch return null;
            obj.* = .{ .ekind = EXTERN_GLOBAL, .content = makeValType(gt.content), .mutability = @intFromBool(gt.mutable) };
            return @ptrCast(obj);
        },
        .table => |tt| {
            const obj = alloc.create(TableType) catch return null;
            obj.* = .{ .ekind = EXTERN_TABLE, .element = makeValType(tt.element), .limits = limitsOf(tt.limits) };
            return @ptrCast(obj);
        },
        .memory => |mt| {
            const obj = alloc.create(MemoryType) catch return null;
            obj.* = .{ .ekind = EXTERN_MEMORY, .limits = limitsOf(mt.limits) };
            return @ptrCast(obj);
        },
    }
}

fn externKindOf(p: *const anyopaque) Externkind {
    return @as(*const Externkind, @ptrCast(@alignCast(p))).*;
}

fn freeValTypeVec(vec: *ValTypeVec) void {
    if (vec.data != null and vec.size != 0) {
        for (vec.data[0..vec.size]) |slot| {
            if (slot) |vt| alloc.destroy(vt);
        }
        alloc.free(vec.data[0..vec.size]);
    }
    vec.* = .{ .size = 0, .data = null };
}

fn freeExternType(ext: ?*anyopaque) void {
    const p = ext orelse return;
    switch (externKindOf(p)) {
        EXTERN_FUNC => {
            const ft: *FuncType = @ptrCast(@alignCast(p));
            freeValTypeVec(&ft.params);
            freeValTypeVec(&ft.results);
            alloc.destroy(ft);
        },
        EXTERN_GLOBAL => {
            const gt: *GlobalType = @ptrCast(@alignCast(p));
            if (gt.content) |vt| alloc.destroy(vt);
            alloc.destroy(gt);
        },
        EXTERN_TABLE => {
            const tt: *TableType = @ptrCast(@alignCast(p));
            if (tt.element) |vt| alloc.destroy(vt);
            alloc.destroy(tt);
        },
        EXTERN_MEMORY => alloc.destroy(@as(*MemoryType, @ptrCast(@alignCast(p)))),
        else => {},
    }
}

// ---- Value types ----------------------------------------------------------

export fn wasm_valtype_new(kind: Valkind) ?*ValType {
    const vt = alloc.create(ValType) catch return null;
    vt.* = .{ .kind = kind };
    return vt;
}

export fn wasm_valtype_delete(vt: ?*ValType) void {
    if (vt) |v| alloc.destroy(v);
}

export fn wasm_valtype_kind(vt: ?*const ValType) Valkind {
    return (vt orelse return 0).kind;
}

// ---- Function types -------------------------------------------------------

export fn wasm_functype_delete(ft: ?*FuncType) void {
    freeExternType(@ptrCast(ft));
}

export fn wasm_functype_params(ft: ?*const FuncType) ?*const ValTypeVec {
    return &(ft orelse return null).params;
}

export fn wasm_functype_results(ft: ?*const FuncType) ?*const ValTypeVec {
    return &(ft orelse return null).results;
}

export fn wasm_functype_as_externtype(ft: ?*FuncType) ?*anyopaque {
    return @ptrCast(ft);
}

export fn wasm_functype_as_externtype_const(ft: ?*const FuncType) ?*const anyopaque {
    return @ptrCast(ft);
}

// ---- Global / Table / Memory types ---------------------------------------

export fn wasm_globaltype_delete(gt: ?*GlobalType) void {
    freeExternType(@ptrCast(gt));
}

export fn wasm_globaltype_content(gt: ?*const GlobalType) ?*const ValType {
    return (gt orelse return null).content;
}

export fn wasm_globaltype_mutability(gt: ?*const GlobalType) u8 {
    return (gt orelse return 0).mutability;
}

export fn wasm_tabletype_delete(tt: ?*TableType) void {
    freeExternType(@ptrCast(tt));
}

export fn wasm_tabletype_element(tt: ?*const TableType) ?*const ValType {
    return (tt orelse return null).element;
}

export fn wasm_tabletype_limits(tt: ?*const TableType) ?*const Limits {
    return &(tt orelse return null).limits;
}

export fn wasm_memorytype_delete(mt: ?*MemoryType) void {
    freeExternType(@ptrCast(mt));
}

export fn wasm_memorytype_limits(mt: ?*const MemoryType) ?*const Limits {
    return &(mt orelse return null).limits;
}

// ---- Extern types ---------------------------------------------------------

export fn wasm_externtype_delete(et: ?*anyopaque) void {
    freeExternType(et);
}

export fn wasm_externtype_kind(et: ?*const anyopaque) Externkind {
    return externKindOf(et orelse return 0);
}

export fn wasm_externtype_as_functype(et: ?*anyopaque) ?*FuncType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_FUNC) @ptrCast(@alignCast(p)) else null;
}

export fn wasm_externtype_as_functype_const(et: ?*const anyopaque) ?*const FuncType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_FUNC) @ptrCast(@alignCast(p)) else null;
}

export fn wasm_externtype_as_globaltype(et: ?*anyopaque) ?*GlobalType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_GLOBAL) @ptrCast(@alignCast(p)) else null;
}

export fn wasm_externtype_as_tabletype(et: ?*anyopaque) ?*TableType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_TABLE) @ptrCast(@alignCast(p)) else null;
}

export fn wasm_externtype_as_memorytype(et: ?*anyopaque) ?*MemoryType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_MEMORY) @ptrCast(@alignCast(p)) else null;
}

// ---- Import / Export types ------------------------------------------------

export fn wasm_importtype_delete(it: ?*ImportType) void {
    const i = it orelse return;
    wasm_byte_vec_delete(&i.module);
    wasm_byte_vec_delete(&i.name);
    freeExternType(i.ext);
    alloc.destroy(i);
}

export fn wasm_importtype_module(it: ?*const ImportType) ?*const ByteVec {
    return &(it orelse return null).module;
}

export fn wasm_importtype_name(it: ?*const ImportType) ?*const ByteVec {
    return &(it orelse return null).name;
}

export fn wasm_importtype_type(it: ?*const ImportType) ?*const anyopaque {
    return (it orelse return null).ext;
}

export fn wasm_importtype_vec_delete(vec: *ImportTypeVec) void {
    if (vec.data != null and vec.size != 0) {
        for (vec.data[0..vec.size]) |slot| {
            if (slot) |it| wasm_importtype_delete(it);
        }
        alloc.free(vec.data[0..vec.size]);
    }
    vec.* = .{ .size = 0, .data = null };
}

export fn wasm_exporttype_delete(et: ?*ExportType) void {
    const e = et orelse return;
    wasm_byte_vec_delete(&e.name);
    freeExternType(e.ext);
    alloc.destroy(e);
}

export fn wasm_exporttype_name(et: ?*const ExportType) ?*const ByteVec {
    return &(et orelse return null).name;
}

export fn wasm_exporttype_type(et: ?*const ExportType) ?*const anyopaque {
    return (et orelse return null).ext;
}

export fn wasm_exporttype_vec_delete(vec: *ExportTypeVec) void {
    if (vec.data != null and vec.size != 0) {
        for (vec.data[0..vec.size]) |slot| {
            if (slot) |et| wasm_exporttype_delete(et);
        }
        alloc.free(vec.data[0..vec.size]);
    }
    vec.* = .{ .size = 0, .data = null };
}

// ---- Module introspection -------------------------------------------------

export fn wasm_module_imports(module: ?*const Module, out: *ImportTypeVec) void {
    out.* = .{ .size = 0, .data = null };
    const m = module orelse return;
    const src = m.inner.imports;
    if (src.len == 0) return;
    const arr = alloc.alloc(?*ImportType, src.len) catch return;
    for (arr, src) |*slot, imp| {
        const obj = alloc.create(ImportType) catch {
            slot.* = null;
            continue;
        };
        wasm_byte_vec_new(&obj.module, imp.module.len, imp.module.ptr);
        wasm_byte_vec_new(&obj.name, imp.name.len, imp.name.ptr);
        obj.ext = makeExternType(imp.type);
        slot.* = obj;
    }
    out.* = .{ .size = src.len, .data = arr.ptr };
}

export fn wasm_module_exports(module: ?*const Module, out: *ExportTypeVec) void {
    out.* = .{ .size = 0, .data = null };
    const m = module orelse return;
    const src = m.inner.exports;
    if (src.len == 0) return;
    const arr = alloc.alloc(?*ExportType, src.len) catch return;
    for (arr, src) |*slot, e| {
        const obj = alloc.create(ExportType) catch {
            slot.* = null;
            continue;
        };
        wasm_byte_vec_new(&obj.name, e.name.len, e.name.ptr);
        obj.ext = makeExternType(e.type);
        slot.* = obj;
    }
    out.* = .{ .size = src.len, .data = arr.ptr };
}

// ===========================================================================
// Runtime objects: instantiation + calls. `wasm_instance_t` wraps the
// interpreter's `Instance`; a `wasm_extern_t` / `wasm_func_t` is a small handle
// (kind + owning instance + index) — the two share one `Ref` struct so
// `wasm_extern_as_func` is a checked pointer cast. Values cross the boundary as
// `wasm_val_t`; the untyped `u64` interpreter slots convert per the (validated)
// signature. Modules with imports instantiate but trap only if an unbacked
// import is actually called (host-function import wiring is a later slice).
// ===========================================================================

const interp = root.interp;

const Instance = struct { inst: root.Instance };

/// Backs both `wasm_extern_t*` and `wasm_func_t*`: a runtime export handle.
const Ref = struct {
    kind: Externkind,
    instance: *Instance,
    /// Index in the export's kind space (the function index for a func).
    index: u32,
};

const Trap = struct { message: ByteVec };

// ---- wasm_val_t / wasm_val_vec_t ------------------------------------------
// Layout must match C: `{ wasm_valkind_t kind; union { i32; i64; f32; f64;
// ref; } of; }` — the 8-byte union forces `of` to offset 8.

const ValOf = extern union { i32: i32, i64: i64, f32: f32, f64: f64, ref: ?*anyopaque };
const Val = extern struct { kind: Valkind, of: ValOf };
const ValVec = extern struct { size: usize, data: [*c]Val };
const ExternVec = extern struct { size: usize, data: [*c]?*Ref };

/// C order (func,global,table,memory,tag) from the binary order (func,table,
/// memory,global) the decoder uses.
fn externKindToC(k: types.ExternKind) Externkind {
    return switch (k) {
        .func => EXTERN_FUNC,
        .global => EXTERN_GLOBAL,
        .table => EXTERN_TABLE,
        .memory => EXTERN_MEMORY,
        else => EXTERN_FUNC,
    };
}

/// Read a C value into an interpreter slot (per its declared kind).
fn valToSlot(v: Val) interp.Value {
    return switch (v.kind) {
        0 => interp.i32Value(v.of.i32), // WASM_I32
        1 => interp.i64Value(v.of.i64), // WASM_I64
        2 => interp.f32Value(v.of.f32), // WASM_F32
        3 => interp.f64Value(v.of.f64), // WASM_F64
        else => @intFromPtr(v.of.ref), // ref: pass the host pointer through
    };
}

/// Convert an interpreter slot to a C value, typed by its (validated) valtype.
fn slotToVal(t: types.ValType, x: interp.Value) Val {
    return switch (t) {
        .i32 => .{ .kind = 0, .of = .{ .i32 = interp.asI32(x) } },
        .i64 => .{ .kind = 1, .of = .{ .i64 = interp.asI64(x) } },
        .f32 => .{ .kind = 2, .of = .{ .f32 = interp.asF32(x) } },
        .f64 => .{ .kind = 3, .of = .{ .f64 = interp.asF64(x) } },
        else => .{ .kind = valkindOf(t), .of = .{ .ref = @ptrFromInt(x) } },
    };
}

/// Allocate a trap carrying a NUL-terminated copy of `msg`.
fn makeTrap(msg: []const u8) ?*Trap {
    const t = alloc.create(Trap) catch return null;
    const buf = alloc.alloc(u8, msg.len + 1) catch {
        alloc.destroy(t);
        return null;
    };
    @memcpy(buf[0..msg.len], msg);
    buf[msg.len] = 0;
    t.message = .{ .size = msg.len + 1, .data = buf.ptr };
    return t;
}

export fn wasm_val_delete(v: ?*Val) void {
    _ = v; // scalar values own nothing; refs are borrowed host pointers
}

export fn wasm_val_copy(out: ?*Val, src: ?*const Val) void {
    if (out) |o| o.* = (src orelse return).*;
}

export fn wasm_val_vec_new_empty(out: *ValVec) void {
    out.* = .{ .size = 0, .data = null };
}

export fn wasm_val_vec_new_uninitialized(out: *ValVec, size: usize) void {
    if (size == 0) return wasm_val_vec_new_empty(out);
    const buf = alloc.alloc(Val, size) catch return wasm_val_vec_new_empty(out);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_val_vec_new(out: *ValVec, size: usize, data: [*c]const Val) void {
    if (size == 0 or data == null) return wasm_val_vec_new_empty(out);
    const buf = alloc.alloc(Val, size) catch return wasm_val_vec_new_empty(out);
    @memcpy(buf, data[0..size]);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_val_vec_copy(out: *ValVec, src: *const ValVec) void {
    wasm_val_vec_new(out, src.size, src.data);
}

export fn wasm_val_vec_delete(vec: *ValVec) void {
    if (vec.data != null and vec.size != 0) alloc.free(vec.data[0..vec.size]);
    vec.* = .{ .size = 0, .data = null };
}

// ---- wasm_extern_vec_t ----------------------------------------------------

export fn wasm_extern_vec_new_empty(out: *ExternVec) void {
    out.* = .{ .size = 0, .data = null };
}

export fn wasm_extern_vec_new_uninitialized(out: *ExternVec, size: usize) void {
    if (size == 0) return wasm_extern_vec_new_empty(out);
    const buf = alloc.alloc(?*Ref, size) catch return wasm_extern_vec_new_empty(out);
    @memset(buf, null);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_extern_vec_new(out: *ExternVec, size: usize, data: [*c]const ?*Ref) void {
    if (size == 0 or data == null) return wasm_extern_vec_new_empty(out);
    const buf = alloc.alloc(?*Ref, size) catch return wasm_extern_vec_new_empty(out);
    @memcpy(buf, data[0..size]);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_extern_vec_delete(vec: *ExternVec) void {
    if (vec.data != null and vec.size != 0) {
        for (vec.data[0..vec.size]) |slot| {
            if (slot) |r| alloc.destroy(r);
        }
        alloc.free(vec.data[0..vec.size]);
    }
    vec.* = .{ .size = 0, .data = null };
}

// ---- Instances ------------------------------------------------------------

export fn wasm_instance_new(store: ?*Store, module: ?*const Module, imports: ?*const ExternVec, trap_out: ?*?*Trap) ?*Instance {
    _ = store;
    _ = imports; // host-import wiring is a later slice (no-import modules for now)
    if (trap_out) |t| t.* = null;
    const m = module orelse return null;
    const wi = alloc.create(Instance) catch return null;
    wi.inst = root.Instance.init(alloc, &m.inner) catch |e| {
        alloc.destroy(wi);
        if (trap_out) |t| t.* = makeTrap(@errorName(e));
        return null;
    };
    return wi;
}

export fn wasm_instance_delete(instance: ?*Instance) void {
    const wi = instance orelse return;
    wi.inst.deinit();
    alloc.destroy(wi);
}

export fn wasm_instance_exports(instance: ?*const Instance, out: *ExternVec) void {
    out.* = .{ .size = 0, .data = null };
    const wi = instance orelse return;
    const exps = wi.inst.module.exports;
    if (exps.len == 0) return;
    const arr = alloc.alloc(?*Ref, exps.len) catch return;
    for (arr, exps) |*slot, e| {
        const r = alloc.create(Ref) catch {
            slot.* = null;
            continue;
        };
        // Calls mutate instance state (memory/heap growth), so the handle keeps a
        // mutable pointer despite the `const` export view.
        r.* = .{ .kind = externKindToC(e.type.kind()), .instance = @constCast(wi), .index = e.index };
        slot.* = r;
    }
    out.* = .{ .size = exps.len, .data = arr.ptr };
}

// ---- Externs --------------------------------------------------------------

export fn wasm_extern_kind(e: ?*const Ref) Externkind {
    return (e orelse return 0).kind;
}

export fn wasm_extern_type(e: ?*const Ref) ?*anyopaque {
    const r = e orelse return null;
    if (r.kind != EXTERN_FUNC) return null; // only func externs are typed today
    const ft = r.instance.inst.module.funcType(r.index) orelse return null;
    return makeExternType(.{ .func = ft });
}

export fn wasm_extern_as_func(e: ?*Ref) ?*Ref {
    const r = e orelse return null;
    return if (r.kind == EXTERN_FUNC) r else null;
}

export fn wasm_extern_as_func_const(e: ?*const Ref) ?*const Ref {
    const r = e orelse return null;
    return if (r.kind == EXTERN_FUNC) r else null;
}

export fn wasm_func_as_extern(f: ?*Ref) ?*Ref {
    return f;
}

export fn wasm_func_as_extern_const(f: ?*const Ref) ?*const Ref {
    return f;
}

// ---- Functions ------------------------------------------------------------

export fn wasm_func_delete(f: ?*Ref) void {
    // A func obtained from `wasm_extern_as_func` is borrowed (freed by the
    // extern vec); a standalone func would be freed here. We only vend borrowed
    // funcs today, so this is a no-op to avoid a double free.
    _ = f;
}

export fn wasm_func_type(f: ?*const Ref) ?*FuncType {
    const r = f orelse return null;
    const ft = r.instance.inst.module.funcType(r.index) orelse return null;
    return @ptrCast(@alignCast(makeExternType(.{ .func = ft }) orelse return null));
}

export fn wasm_func_param_arity(f: ?*const Ref) usize {
    const r = f orelse return 0;
    const ft = r.instance.inst.module.funcType(r.index) orelse return 0;
    return ft.params.len;
}

export fn wasm_func_result_arity(f: ?*const Ref) usize {
    const r = f orelse return 0;
    const ft = r.instance.inst.module.funcType(r.index) orelse return 0;
    return ft.results.len;
}

export fn wasm_func_call(func: ?*const Ref, args: ?*const ValVec, results: ?*ValVec) ?*Trap {
    const r = func orelse return makeTrap("null function");
    const ft = r.instance.inst.module.funcType(r.index) orelse return makeTrap("undefined function");

    const n = if (args) |a| a.size else 0;
    const argv = alloc.alloc(interp.Value, n) catch return makeTrap("out of memory");
    defer alloc.free(argv);
    if (args) |a| for (argv, 0..) |*slot, i| {
        slot.* = valToSlot(a.data[i]);
    };

    const res = r.instance.inst.invokeIndex(r.index, argv) catch |e| return makeTrap(@errorName(e));
    defer alloc.free(res);

    if (results) |out| {
        const m = @min(out.size, @min(res.len, ft.results.len));
        for (0..m) |i| out.data[i] = slotToVal(ft.results[i], res[i]);
    }
    return null; // success
}

// ---- Traps ----------------------------------------------------------------

export fn wasm_trap_new(store: ?*Store, message: ?*const ByteVec) ?*Trap {
    _ = store;
    const t = alloc.create(Trap) catch return null;
    t.message = undefined;
    if (message) |m| wasm_byte_vec_copy(&t.message, m) else t.message.empty();
    return t;
}

export fn wasm_trap_message(trap: ?*const Trap, out: *ByteVec) void {
    const t = trap orelse return out.empty();
    wasm_byte_vec_copy(out, &t.message);
}

export fn wasm_trap_delete(trap: ?*Trap) void {
    const t = trap orelse return;
    wasm_byte_vec_delete(&t.message);
    alloc.destroy(t);
}

// ---- wazmrt extension surface (include/wazmrt.h) --------------------------

/// Stable wazmrt C-ABI version; embedders verify it matches what they built on.
export fn wazmrt_abi_version() u32 {
    return root.abi_version;
}

/// Static, NUL-terminated library version string; do not free.
export fn wazmrt_version_string() [*:0]const u8 {
    return root.version.ptr;
}
