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

export fn wasm_valtype_vec_new_empty(out: *ValTypeVec) void {
    out.* = .{ .size = 0, .data = null };
}

export fn wasm_valtype_vec_new_uninitialized(out: *ValTypeVec, size: usize) void {
    if (size == 0) return wasm_valtype_vec_new_empty(out);
    const arr = alloc.alloc(?*ValType, size) catch return wasm_valtype_vec_new_empty(out);
    @memset(arr, null);
    out.* = .{ .size = size, .data = arr.ptr };
}

export fn wasm_valtype_vec_new(out: *ValTypeVec, size: usize, data: [*c]const ?*ValType) void {
    if (size == 0 or data == null) return wasm_valtype_vec_new_empty(out);
    const arr = alloc.alloc(?*ValType, size) catch return wasm_valtype_vec_new_empty(out);
    @memcpy(arr, data[0..size]);
    out.* = .{ .size = size, .data = arr.ptr };
}

export fn wasm_valtype_vec_copy(out: *ValTypeVec, src: *const ValTypeVec) void {
    copyValTypeVec(out, src);
}

export fn wasm_valtype_vec_delete(vec: *ValTypeVec) void {
    freeValTypeVec(vec);
}

// ---- Function types -------------------------------------------------------

/// Construct a functype, taking ownership of the two valtype vecs (moved in).
export fn wasm_functype_new(params: ?*ValTypeVec, results: ?*ValTypeVec) ?*FuncType {
    const ft = alloc.create(FuncType) catch return null;
    ft.ekind = EXTERN_FUNC;
    ft.params = if (params) |p| p.* else .{ .size = 0, .data = null };
    ft.results = if (results) |r| r.* else .{ .size = 0, .data = null };
    if (params) |p| p.* = .{ .size = 0, .data = null }; // moved out
    if (results) |r| r.* = .{ .size = 0, .data = null };
    return ft;
}

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

/// `interp.Instance.import_funcs` borrows its slice, so the wrapper owns
/// `host_funcs` for the instance's lifetime.
const Instance = struct { inst: root.Instance, host_funcs: []interp.Instance.HostFunc = &.{} };

const FuncCallback = *const fn (args: ?*const ValVec, results: ?*ValVec) callconv(.c) ?*Trap;
const FuncCallbackWithEnv = *const fn (env: ?*anyopaque, args: ?*const ValVec, results: ?*ValVec) callconv(.c) ?*Trap;
const Finalizer = *const fn (?*anyopaque) callconv(.c) void;

/// A host callback registered via `wasm_func_new[_with_env]`.
const HostCallback = struct {
    plain: ?FuncCallback = null,
    with_env: ?FuncCallbackWithEnv = null,
    env: ?*anyopaque = null,
    finalizer: ?Finalizer = null,
};

/// A standalone host global created by `wasm_global_new`.
const HostGlobal = struct { value: interp.Value, content: Valkind, mutable: bool };

/// Backs every `wasm_extern_t*` / `wasm_func_t*` / `wasm_global_t*` /
/// `wasm_table_t*` / `wasm_memory_t*`. Either an instance-export handle
/// (`instance` set, `index` locates the object in its space) or a standalone
/// host object created by `wasm_*_new` (one of the `host_*` fields set).
const Ref = struct {
    kind: Externkind,
    instance: ?*Instance = null,
    /// Index in the export's kind space (function/global/table for exports).
    index: u32 = 0,
    host: ?HostCallback = null,
    /// Owned signature copy for a host function (arg/result conversion).
    functype: ?*FuncType = null,
    host_global: ?*HostGlobal = null,
    host_memory: ?*interp.Instance.Memory = null,
    host_table: ?*interp.Instance.Table = null,
};

const wasm_page_size: usize = 65536;

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

/// Build a C value of the given valkind from an interpreter slot (used when the
/// target type is only known as a `wasm_valkind_t`, e.g. a host callback's args).
fn slotToValKind(kind: Valkind, x: interp.Value) Val {
    return switch (kind) {
        0 => .{ .kind = 0, .of = .{ .i32 = interp.asI32(x) } },
        1 => .{ .kind = 1, .of = .{ .i64 = interp.asI64(x) } },
        2 => .{ .kind = 2, .of = .{ .f32 = interp.asF32(x) } },
        3 => .{ .kind = 3, .of = .{ .f64 = interp.asF64(x) } },
        else => .{ .kind = kind, .of = .{ .ref = @ptrFromInt(x) } },
    };
}

/// The valkind of a functype param / result slot (defaults to i32 if absent).
fn valTypeVecKind(vec: *const ValTypeVec, i: usize) Valkind {
    if (i >= vec.size or vec.data == null) return 0;
    return if (vec.data[i]) |vt| vt.kind else 0;
}

fn copyValTypeVec(out: *ValTypeVec, src: *const ValTypeVec) void {
    if (src.size == 0 or src.data == null) {
        out.* = .{ .size = 0, .data = null };
        return;
    }
    const arr = alloc.alloc(?*ValType, src.size) catch {
        out.* = .{ .size = 0, .data = null };
        return;
    };
    for (arr, 0..) |*slot, i| {
        slot.* = null;
        if (src.data[i]) |vt| {
            const c = alloc.create(ValType) catch continue;
            c.* = .{ .kind = vt.kind };
            slot.* = c;
        }
    }
    out.* = .{ .size = src.size, .data = arr.ptr };
}

/// Deep-copy a functype (the caller keeps ownership of the one passed in).
fn copyFuncType(src: ?*const FuncType) ?*FuncType {
    const s = src orelse return null;
    const dst = alloc.create(FuncType) catch return null;
    dst.ekind = EXTERN_FUNC;
    copyValTypeVec(&dst.params, &s.params);
    copyValTypeVec(&dst.results, &s.results);
    return dst;
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

// ---- Host functions (wasm_func_new) ---------------------------------------

/// Non-null `ctx` sentinel for a func import the embedder left unbacked; calling
/// it traps.
var unbacked_marker: u8 = 0;

fn unbackedTrap(ctx: *anyopaque, args: []const interp.Value, results: []interp.Value) bool {
    _ = ctx;
    _ = args;
    _ = results;
    return false;
}

/// Bridge an interpreter call to a C host callback: convert the untyped `u64`
/// args to `wasm_val_t` (typed by the host func's signature), invoke the C
/// callback, and convert the results back. Returns false (→ `error.HostTrap`)
/// if the callback returns a trap.
fn hostTrampoline(ctx: *anyopaque, args: []const interp.Value, results: []interp.Value) bool {
    const ref: *Ref = @ptrCast(@alignCast(ctx));
    const hc = ref.host orelse return false;
    const ft = ref.functype orelse return false;

    var argvec: ValVec = undefined;
    wasm_val_vec_new_uninitialized(&argvec, args.len);
    defer wasm_val_vec_delete(&argvec);
    for (0..args.len) |i| argvec.data[i] = slotToValKind(valTypeVecKind(&ft.params, i), args[i]);

    var resvec: ValVec = undefined;
    wasm_val_vec_new_uninitialized(&resvec, results.len);
    defer wasm_val_vec_delete(&resvec);

    const trap = if (hc.with_env) |cb| cb(hc.env, &argvec, &resvec) else if (hc.plain) |cb| cb(&argvec, &resvec) else return false;
    if (trap) |t| {
        wasm_trap_delete(t);
        return false;
    }
    for (0..results.len) |i| results[i] = valToSlot(resvec.data[i]);
    return true;
}

export fn wasm_func_new(store: ?*Store, ft: ?*const FuncType, callback: FuncCallback) ?*Ref {
    _ = store;
    const r = alloc.create(Ref) catch return null;
    r.* = .{ .kind = EXTERN_FUNC, .host = .{ .plain = callback }, .functype = copyFuncType(ft) };
    return r;
}

export fn wasm_func_new_with_env(store: ?*Store, ft: ?*const FuncType, callback: FuncCallbackWithEnv, env: ?*anyopaque, finalizer: ?Finalizer) ?*Ref {
    _ = store;
    const r = alloc.create(Ref) catch return null;
    r.* = .{ .kind = EXTERN_FUNC, .host = .{ .with_env = callback, .env = env, .finalizer = finalizer }, .functype = copyFuncType(ft) };
    return r;
}

// ---- Instances ------------------------------------------------------------

export fn wasm_instance_new(store: ?*Store, module: ?*const Module, imports: ?*const ExternVec, trap_out: ?*?*Trap) ?*Instance {
    _ = store;
    if (trap_out) |t| t.* = null;
    const m = module orelse return null;

    // Map the supplied externs (in `wasm_module_imports` order — mixed kinds) to
    // the interpreter's per-kind import arrays. Func imports become host
    // trampolines (`funcs`, borrowed by the instance for its lifetime); global
    // values are copied in; memories/tables are borrowed shared objects. The
    // per-kind arrays other than `funcs` are only read during init, so they're
    // freed right after.
    var host_funcs: std.ArrayList(interp.Instance.HostFunc) = .empty;
    var gvals: std.ArrayList(interp.Value) = .empty;
    var mems: std.ArrayList(*interp.Instance.Memory) = .empty;
    var tbls: std.ArrayList(*interp.Instance.Table) = .empty;
    defer gvals.deinit(alloc);
    defer mems.deinit(alloc);
    defer tbls.deinit(alloc);
    for (m.inner.imports, 0..) |imp, i| {
        const ext: ?*Ref = if (imports) |v| (if (i < v.size) v.data[i] else null) else null;
        switch (imp.type) {
            .func => {
                const hf: interp.Instance.HostFunc = if (ext != null and ext.?.host != null)
                    .{ .native_env = .{ .ctx = ext.?, .call = hostTrampoline } }
                else
                    .{ .native_env = .{ .ctx = &unbacked_marker, .call = unbackedTrap } };
                host_funcs.append(alloc, hf) catch return null;
            },
            .global => gvals.append(alloc, if (ext) |e| (if (e.host_global) |hg| hg.value else 0) else 0) catch return null,
            .memory => if (ext) |e| {
                if (e.host_memory) |mem| mems.append(alloc, mem) catch return null;
            },
            .table => if (ext) |e| {
                if (e.host_table) |tbl| tbls.append(alloc, tbl) catch return null;
            },
        }
    }

    const wi = alloc.create(Instance) catch {
        host_funcs.deinit(alloc);
        return null;
    };
    const funcs = host_funcs.toOwnedSlice(alloc) catch {
        host_funcs.deinit(alloc);
        alloc.destroy(wi);
        return null;
    };
    wi.host_funcs = funcs;
    wi.inst = root.Instance.initWithImports(alloc, &m.inner, .{
        .funcs = funcs,
        .globals = gvals.items,
        .memories = mems.items,
        .tables = tbls.items,
    }) catch |e| {
        alloc.free(funcs);
        alloc.destroy(wi);
        if (trap_out) |t| t.* = makeTrap(@errorName(e));
        return null;
    };
    return wi;
}

export fn wasm_instance_delete(instance: ?*Instance) void {
    const wi = instance orelse return;
    wi.inst.deinit();
    if (wi.host_funcs.len != 0) alloc.free(wi.host_funcs);
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
    switch (r.kind) {
        EXTERN_FUNC => {
            if (r.instance) |wi| return makeExternType(.{ .func = wi.inst.module.funcType(r.index) orelse return null });
            return @ptrCast(copyFuncType(r.functype));
        },
        EXTERN_GLOBAL => return @ptrCast(wasm_global_type(r)),
        EXTERN_TABLE => return @ptrCast(wasm_table_type(r)),
        EXTERN_MEMORY => return @ptrCast(wasm_memory_type(r)),
        else => return null,
    }
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

fn asKind(e: ?*Ref, want: Externkind) ?*Ref {
    const r = e orelse return null;
    return if (r.kind == want) r else null;
}

export fn wasm_extern_as_global(e: ?*Ref) ?*Ref {
    return asKind(e, EXTERN_GLOBAL);
}
export fn wasm_extern_as_table(e: ?*Ref) ?*Ref {
    return asKind(e, EXTERN_TABLE);
}
export fn wasm_extern_as_memory(e: ?*Ref) ?*Ref {
    return asKind(e, EXTERN_MEMORY);
}
export fn wasm_extern_as_global_const(e: ?*const Ref) ?*const Ref {
    const r = e orelse return null;
    return if (r.kind == EXTERN_GLOBAL) r else null;
}
export fn wasm_extern_as_table_const(e: ?*const Ref) ?*const Ref {
    const r = e orelse return null;
    return if (r.kind == EXTERN_TABLE) r else null;
}
export fn wasm_extern_as_memory_const(e: ?*const Ref) ?*const Ref {
    const r = e orelse return null;
    return if (r.kind == EXTERN_MEMORY) r else null;
}
export fn wasm_global_as_extern(g: ?*Ref) ?*Ref {
    return g;
}
export fn wasm_table_as_extern(t: ?*Ref) ?*Ref {
    return t;
}
export fn wasm_memory_as_extern(m: ?*Ref) ?*Ref {
    return m;
}
export fn wasm_global_as_extern_const(g: ?*const Ref) ?*const Ref {
    return g;
}
export fn wasm_table_as_extern_const(t: ?*const Ref) ?*const Ref {
    return t;
}
export fn wasm_memory_as_extern_const(m: ?*const Ref) ?*const Ref {
    return m;
}

// ---- Functions ------------------------------------------------------------

export fn wasm_func_delete(f: ?*Ref) void {
    const r = f orelse return;
    // An export handle (`instance` set) is borrowed — freed by the extern vec.
    // A standalone host func from `wasm_func_new` is owned and freed here.
    if (r.instance != null) return;
    if (r.host) |hc| if (hc.finalizer) |fin| fin(hc.env);
    if (r.functype) |ft| freeExternType(@ptrCast(ft));
    alloc.destroy(r);
}

export fn wasm_func_type(f: ?*const Ref) ?*FuncType {
    const r = f orelse return null;
    if (r.instance) |wi| {
        const ft = wi.inst.module.funcType(r.index) orelse return null;
        return @ptrCast(@alignCast(makeExternType(.{ .func = ft }) orelse return null));
    }
    return copyFuncType(r.functype); // host func
}

export fn wasm_func_param_arity(f: ?*const Ref) usize {
    const r = f orelse return 0;
    if (r.instance) |wi| return (wi.inst.module.funcType(r.index) orelse return 0).params.len;
    return if (r.functype) |ft| ft.params.size else 0;
}

export fn wasm_func_result_arity(f: ?*const Ref) usize {
    const r = f orelse return 0;
    if (r.instance) |wi| return (wi.inst.module.funcType(r.index) orelse return 0).results.len;
    return if (r.functype) |ft| ft.results.size else 0;
}

export fn wasm_func_call(func: ?*const Ref, args: ?*const ValVec, results: ?*ValVec) ?*Trap {
    const r = func orelse return makeTrap("null function");

    // A standalone host func: invoke its callback directly.
    if (r.instance == null) {
        const hc = r.host orelse return makeTrap("undefined function");
        if (hc.with_env) |cb| return cb(hc.env, args, results);
        if (hc.plain) |cb| return cb(args, results);
        return makeTrap("undefined function");
    }
    const wi = r.instance.?;
    const ft = wi.inst.module.funcType(r.index) orelse return makeTrap("undefined function");

    const n = if (args) |a| a.size else 0;
    const argv = alloc.alloc(interp.Value, n) catch return makeTrap("out of memory");
    defer alloc.free(argv);
    if (args) |a| for (argv, 0..) |*slot, i| {
        slot.* = valToSlot(a.data[i]);
    };

    const res = wi.inst.invokeIndex(r.index, argv) catch |e| return makeTrap(@errorName(e));
    defer alloc.free(res);

    if (results) |out| {
        const m = @min(out.size, @min(res.len, ft.results.len));
        for (0..m) |i| out.data[i] = slotToVal(ft.results[i], res[i]);
    }
    return null; // success
}

// ---- Globals --------------------------------------------------------------

fn valTypeFromKind(k: Valkind) types.ValType {
    return switch (k) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        129 => .funcref,
        else => .externref,
    };
}

/// The storage slot of a global (instance export or standalone host global).
fn globalStorage(r: *Ref) ?*interp.Value {
    if (r.instance) |wi| return if (r.index < wi.inst.globals.len) &wi.inst.globals[r.index] else null;
    if (r.host_global) |hg| return &hg.value;
    return null;
}
fn globalKind(r: *const Ref) Valkind {
    if (r.instance) |wi| return if (r.index < wi.inst.module.globals.len) valkindOf(wi.inst.module.globals[r.index].content) else 0;
    return if (r.host_global) |hg| hg.content else 0;
}
fn globalMutable(r: *const Ref) bool {
    if (r.instance) |wi| return r.index < wi.inst.module.globals.len and wi.inst.module.globals[r.index].mutable;
    return if (r.host_global) |hg| hg.mutable else false;
}

export fn wasm_global_new(store: ?*Store, gt: ?*const GlobalType, val: ?*const Val) ?*Ref {
    _ = store;
    const g = gt orelse return null;
    const hg = alloc.create(HostGlobal) catch return null;
    hg.* = .{
        .value = if (val) |v| valToSlot(v.*) else 0,
        .content = if (g.content) |c| c.kind else 0,
        .mutable = g.mutability != 0,
    };
    const r = alloc.create(Ref) catch {
        alloc.destroy(hg);
        return null;
    };
    r.* = .{ .kind = EXTERN_GLOBAL, .host_global = hg };
    return r;
}

export fn wasm_global_get(g: ?*const Ref, out: ?*Val) void {
    const o = out orelse return;
    const r = @constCast(g orelse {
        o.* = .{ .kind = 0, .of = .{ .i32 = 0 } };
        return;
    });
    const s = globalStorage(r) orelse {
        o.* = .{ .kind = 0, .of = .{ .i32 = 0 } };
        return;
    };
    o.* = slotToValKind(globalKind(r), s.*);
}

export fn wasm_global_set(g: ?*Ref, val: ?*const Val) void {
    const r = g orelse return;
    if (!globalMutable(r)) return;
    const s = globalStorage(r) orelse return;
    if (val) |v| s.* = valToSlot(v.*);
}

export fn wasm_global_type(g: ?*const Ref) ?*GlobalType {
    const r = g orelse return null;
    const ext = makeExternType(.{ .global = .{ .content = valTypeFromKind(globalKind(r)), .mutable = globalMutable(r) } }) orelse return null;
    return @ptrCast(@alignCast(ext));
}

export fn wasm_global_delete(g: ?*Ref) void {
    const r = g orelse return;
    if (r.instance != null) return; // export handle: freed by the extern vec
    if (r.host_global) |hg| alloc.destroy(hg);
    alloc.destroy(r);
}

// ---- Memories -------------------------------------------------------------

fn memObj(r: *const Ref) ?*interp.Instance.Memory {
    if (r.instance) |wi| return wi.inst.memory; // MVP: single memory (index 0)
    return r.host_memory;
}

export fn wasm_memory_new(store: ?*Store, mt: ?*const MemoryType) ?*Ref {
    _ = store;
    const t = mt orelse return null;
    const bytes = alloc.alloc(u8, @as(usize, t.limits.min) * wasm_page_size) catch return null;
    @memset(bytes, 0);
    const mem = alloc.create(interp.Instance.Memory) catch {
        alloc.free(bytes);
        return null;
    };
    mem.* = .{ .bytes = bytes, .max = if (t.limits.max == 0xffff_ffff) null else t.limits.max };
    const r = alloc.create(Ref) catch {
        alloc.free(bytes);
        alloc.destroy(mem);
        return null;
    };
    r.* = .{ .kind = EXTERN_MEMORY, .host_memory = mem };
    return r;
}

export fn wasm_memory_data(m: ?*Ref) [*c]u8 {
    const r = m orelse return null;
    return (memObj(r) orelse return null).bytes.ptr;
}

export fn wasm_memory_data_size(m: ?*const Ref) usize {
    const r = m orelse return 0;
    return (memObj(r) orelse return 0).bytes.len;
}

export fn wasm_memory_size(m: ?*const Ref) u32 {
    const r = m orelse return 0;
    return @intCast((memObj(r) orelse return 0).bytes.len / wasm_page_size);
}

export fn wasm_memory_grow(m: ?*Ref, delta: u32) bool {
    const r = m orelse return false;
    const mem = memObj(r) orelse return false;
    const old_len = mem.bytes.len;
    const old_pages: u32 = @intCast(old_len / wasm_page_size);
    const new_pages = @as(u64, old_pages) + delta;
    const max = mem.max orelse 0x1_0000; // wasm32: at most 65536 pages
    if (new_pages > max) return false;
    const grown = alloc.realloc(mem.bytes, @as(usize, @intCast(new_pages)) * wasm_page_size) catch return false;
    @memset(grown[old_len..], 0);
    mem.bytes = grown;
    return true;
}

export fn wasm_memory_type(m: ?*const Ref) ?*MemoryType {
    const r = m orelse return null;
    const mem = memObj(r) orelse return null;
    const min: u32 = @intCast(mem.bytes.len / wasm_page_size);
    const ext = makeExternType(.{ .memory = .{ .limits = .{ .min = min, .max = mem.max } } }) orelse return null;
    return @ptrCast(@alignCast(ext));
}

export fn wasm_memory_delete(m: ?*Ref) void {
    const r = m orelse return;
    if (r.instance != null) return; // export handle: interp owns the memory
    if (r.host_memory) |mem| {
        alloc.free(mem.bytes);
        alloc.destroy(mem);
    }
    alloc.destroy(r);
}

// ---- Tables ---------------------------------------------------------------
// new/type/size + the extern casts. Element get/set/grow need a `wasm_ref_t`
// object model (funcref/externref handles), which is a later slice.

fn tableObj(r: *const Ref) ?*interp.Instance.Table {
    if (r.instance) |wi| return if (r.index < wi.inst.tables.len) wi.inst.tables[r.index] else null;
    return r.host_table;
}

export fn wasm_table_new(store: ?*Store, tt: ?*const TableType, init: ?*Ref) ?*Ref {
    _ = store;
    _ = init; // entries start uninitialized (null) — typed-init is a later slice
    const t = tt orelse return null;
    const entries = alloc.alloc(interp.Value, t.limits.min) catch return null;
    @memset(entries, std.math.maxInt(u64)); // null_ref
    const tbl = alloc.create(interp.Instance.Table) catch {
        alloc.free(entries);
        return null;
    };
    tbl.* = .{ .entries = entries, .max = if (t.limits.max == 0xffff_ffff) null else t.limits.max };
    const r = alloc.create(Ref) catch {
        alloc.free(entries);
        alloc.destroy(tbl);
        return null;
    };
    r.* = .{ .kind = EXTERN_TABLE, .host_table = tbl };
    return r;
}

export fn wasm_table_size(t: ?*const Ref) u32 {
    const r = t orelse return 0;
    return @intCast((tableObj(r) orelse return 0).entries.len);
}

export fn wasm_table_type(t: ?*const Ref) ?*TableType {
    const r = t orelse return null;
    var elem: types.ValType = .funcref;
    var maxv: ?u32 = null;
    if (r.instance) |wi| {
        if (r.index < wi.inst.module.tables.len) {
            elem = wi.inst.module.tables[r.index].element;
            maxv = wi.inst.module.tables[r.index].limits.max;
        }
    } else if (r.host_table) |tbl| maxv = tbl.max;
    const min: u32 = @intCast((tableObj(r) orelse return null).entries.len);
    const ext = makeExternType(.{ .table = .{ .element = elem, .limits = .{ .min = min, .max = maxv } } }) orelse return null;
    return @ptrCast(@alignCast(ext));
}

export fn wasm_table_delete(t: ?*Ref) void {
    const r = t orelse return;
    if (r.instance != null) return; // export handle: interp owns the table
    if (r.host_table) |tbl| {
        alloc.free(tbl.entries);
        alloc.destroy(tbl);
    }
    alloc.destroy(r);
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
