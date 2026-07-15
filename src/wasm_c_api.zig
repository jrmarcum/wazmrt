//! wazmrt's implementation of the standard **WebAssembly C API** (wasm-c-api).
//!
//! The contract is the vendored standard header
//! `third_party/wasm-c-api/include/wasm.h` (Apache-2.0; see
//! `third_party/LICENSES.md`). Implementing it means any wasm-c-api consumer —
//! including the `universalWasmLoader-*` loaders, wasmtime, and wasmer clients —
//! binds to wazmrt identically.
//!
//! **Complete against the header.** Every function `wasm.h` declares is defined
//! here, and `tests/c_abi_symbols.c` enforces that at link time
//! (`cmem/known-issues.md` #20). It did not used to be: this file once reasoned
//! that "an undefined symbol in a static library only errors if a consumer
//! references it" and left 180 declared functions undefined. That is exactly
//! backwards — a consumer referencing them is the *entire point of the header*,
//! and they got a link error. Do not reintroduce that trade.
//!
//! ## Memory safety
//!
//! This file hands raw ownership across a C boundary, so it is the one place in
//! wazmrt where a mistake is a **heap-corruption primitive**, not a wrong
//! answer. Two rules, both learned from real bugs (see the `Ref` and vec
//! sections):
//!
//! 1. **Every free of a `Ref` goes through `refDelete`.** Never `alloc.destroy`
//!    a `Ref` directly — that skips the refcount (→ double free) and the
//!    object's own cleanup (→ leaked functype/host_global, unrun finalizer).
//! 2. **Nothing aliases a `Ref` without owning a handle to it.** A copy either
//!    retains or duplicates; it never just repeats the pointer.
//!
//! Both are covered by the tests at the bottom, which run the C entry points
//! under `std.testing.allocator` — it detects double-free and leaks, which the
//! C smoke test cannot (it runs on the real allocator, where a double free
//! silently corrupts the freelist and *appears to pass*).
//!
//! Libc-free: uses `std.heap.smp_allocator` (see `cmem/design-decisions.md`).

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const types = @import("types.zig");

/// The C ABI's allocator. Under `zig build test` this is the testing allocator,
/// so the lifecycle tests at the bottom of this file catch double-frees and
/// leaks in the ownership rules above; everywhere else it is the libc-free
/// `smp_allocator`. Comptime, so release builds are unaffected.
const alloc: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

// ---- Opaque objects -------------------------------------------------------
// C sees only `struct wasm_*_t*`; layout is private. The padding byte gives
// each a distinct heap allocation (so handles compare unequal) and keeps the
// types non-zero-sized.

const Config = struct { _pad: u8 = 0 };
const Engine = struct { _pad: u8 = 0 };
const Store = struct { engine: *Engine };

// ---- The reference object model (wasm_ref_t and its subtypes) --------------
//
// `wasm.h` builds every ownable object out of two macros:
//   WASM_DECLARE_REF_BASE — delete/copy/same/{get,set}_host_info
//   WASM_DECLARE_REF      — the above + `X_as_ref` / `ref_as_X` upcasts
// so `wasm_ref_t` is the common supertype of extern/func/global/table/memory,
// foreign, instance, module and trap.
//
// **Copies are references, not clones.** `wasm_X_copy` is `own`, but
// `wasm_X_same(copy(x), x)` must be true — so a copy is another handle to the
// same object, i.e. a refcount bump. That is also what makes copy cheap on
// objects (an `Instance`, a decoded `Module`) that could not be deep-copied
// meaningfully anyway.
//
// The upcast is borrowed (`wasm_ref_t*`, not `own`), so it must not allocate.
// Every object embeds `hdr` and hands out `&obj.hdr`; the downcast recovers the
// object with `@fieldParentPtr`. That works whatever field order Zig picks —
// no `extern struct` or offset-0 assumption.

const RefTag = enum(u8) { extern_obj, foreign, instance, module, trap };

/// `wasm_ref_t`: the header every ref-able object embeds.
const RefHeader = struct {
    tag: RefTag,
    /// Handles to this object. `copy` bumps it; `delete` drops it and frees at 0.
    rc: u32 = 1,
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?Finalizer = null,
};

/// Drop one handle. Returns true when the last one went away and the caller
/// should tear the object down.
///
/// `rc` is driven to 0 rather than left at 1, so a second delete of the same
/// object is a no-op here instead of running the host-info finalizer twice.
fn release(hdr: *RefHeader) bool {
    if (hdr.rc == 0) return false; // already released — don't finalize twice
    hdr.rc -= 1;
    if (hdr.rc != 0) return false;
    if (hdr.host_info_finalizer) |f| f(hdr.host_info);
    return true;
}

/// Take another handle. Returns the same object — see the note above.
fn retain(hdr: *RefHeader) void {
    hdr.rc += 1;
}

const Module = struct {
    hdr: RefHeader = .{ .tag = .module },
    inner: root.Module,
    /// The binary this was decoded from, owned. `root.Module` copies out what it
    /// needs and lets the input go, but `wasm_module_serialize` is specified to
    /// hand back a binary, so the C ABI keeps one. It also gives `deserialize`
    /// something to round-trip against.
    bytes: []u8,
};

/// `wasm_foreign_t` — an opaque host object. It carries nothing but its header;
/// the point is the `host_info` an embedder hangs on it.
const Foreign = struct { hdr: RefHeader = .{ .tag = .foreign } };

/// `wasm_shared_module_t`. Sharing is across stores, so it cannot just be the
/// `Module` handle; it holds its own copy of the binary and `obtain` decodes a
/// fresh module from it.
const SharedModule = struct { bytes: []u8 };

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
    return moduleFromBytes(vecSlice(bin));
}

/// Decode `src` into a `wasm_module_t`, keeping an owned copy of the binary.
fn moduleFromBytes(src: []const u8) ?*Module {
    const m = alloc.create(Module) catch return null;
    const kept = alloc.dupe(u8, src) catch {
        alloc.destroy(m);
        return null;
    };
    m.* = .{
        .inner = root.decode(alloc, kept) catch {
            alloc.free(kept);
            alloc.destroy(m);
            return null;
        },
        .bytes = kept,
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
    if (!release(&m.hdr)) return; // another handle still holds it
    m.inner.deinit();
    alloc.free(m.bytes);
    alloc.destroy(m);
}

// ---- Module sharing / serialization ---------------------------------------

/// `wasm_module_serialize` — hand back a binary that `deserialize` accepts. We
/// return the original bytes rather than inventing a compiled format: wazmrt
/// interprets a decoded IR, so there is no AOT artifact to emit, and a
/// round-trip through the original binary is both honest and correct.
export fn wasm_module_serialize(module: ?*const Module, out: *ByteVec) void {
    const m = module orelse return out.empty();
    wasm_byte_vec_new(out, m.bytes.len, m.bytes.ptr);
}

export fn wasm_module_deserialize(store: ?*Store, bytes: ?*const ByteVec) ?*Module {
    _ = store;
    const b = bytes orelse return null;
    return moduleFromBytes(vecSlice(b));
}

export fn wasm_module_share(module: ?*const Module) ?*SharedModule {
    const m = module orelse return null;
    const s = alloc.create(SharedModule) catch return null;
    s.bytes = alloc.dupe(u8, m.bytes) catch {
        alloc.destroy(s);
        return null;
    };
    return s;
}

export fn wasm_module_obtain(store: ?*Store, shared: ?*const SharedModule) ?*Module {
    _ = store;
    const s = shared orelse return null;
    return moduleFromBytes(s.bytes);
}

export fn wasm_shared_module_delete(shared: ?*SharedModule) void {
    const s = shared orelse return;
    alloc.free(s.bytes);
    alloc.destroy(s);
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
/// Exception-handling tags. wazmrt doesn't implement EH (`design-decisions.md`
/// defers it until it's browser-standard), but `wasm_tagtype_t` is pure type
/// data an embedder can construct and inspect, and the header declares it — so
/// the *type object* exists even though no module can produce one.
const EXTERN_TAG: Externkind = 4;

/// wasm_limits_t: `{ uint32_t min; uint32_t max; }` (max 0xffffffff == none).
const Limits = extern struct { min: u32, max: u32 };
/// `wasm_limits_max_default` from the header: "no maximum".
const wasm_limits_max_default: u32 = 0xffff_ffff;

const ValType = struct { kind: Valkind };

const ValTypeVec = extern struct { size: usize, data: [*c]?*ValType };
const ImportTypeVec = extern struct { size: usize, data: [*c]?*ImportType };
const ExportTypeVec = extern struct { size: usize, data: [*c]?*ExportType };

const FuncType = extern struct { ekind: Externkind, params: ValTypeVec, results: ValTypeVec };
const GlobalType = extern struct { ekind: Externkind, content: ?*ValType, mutability: u8 };
const TableType = extern struct { ekind: Externkind, element: ?*ValType, limits: Limits };
const MemoryType = extern struct { ekind: Externkind, limits: Limits };

/// `wasm_tagtype_t`. Same `ekind`-first shape as the other extern types, so it
/// participates in the `externtype` tagged union.
const TagType = extern struct { ekind: Externkind, functype: ?*FuncType };
const TagTypeVec = extern struct { size: usize, data: [*c]?*TagType };

const ImportType = struct { module: ByteVec, name: ByteVec, ext: ?*anyopaque };
const ExportType = struct { name: ByteVec, ext: ?*anyopaque };
const FuncTypeVec = extern struct { size: usize, data: [*c]?*FuncType };
const GlobalTypeVec = extern struct { size: usize, data: [*c]?*GlobalType };
const TableTypeVec = extern struct { size: usize, data: [*c]?*TableType };
const MemoryTypeVec = extern struct { size: usize, data: [*c]?*MemoryType };
/// `wasm_externtype_t` is opaque in C; ours is the `ekind`-first union, reached
/// through `*anyopaque`.
const ExternTypeVec = extern struct { size: usize, data: [*c]?*anyopaque };

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
const Instance = struct {
    hdr: RefHeader = .{ .tag = .instance },
    inst: root.Instance,
    host_funcs: []interp.Instance.HostFunc = &.{},
};

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
    hdr: RefHeader = .{ .tag = .extern_obj },
    kind: Externkind,
    /// True when this allocation belongs to the `wasm_extern_vec_t` that
    /// produced it (`wasm_instance_exports`), which frees it. Explicit rather
    /// than inferred from `instance`, because `wasm_table_get` hands back an
    /// `own` handle that *also* names an instance — inferring would leak it.
    vec_owned: bool = false,
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

/// A trap's message plus the call stack it happened on. The frames are
/// snapshotted when the trap is built — the interpreter's trace is reset by the
/// next `invokeIndex`, and a `wasm_trap_t` outlives the call that produced it.
const Trap = struct { hdr: RefHeader = .{ .tag = .trap }, message: ByteVec, frames: []Frame = &.{} };

/// `wasm_frame_t`. Mirrors `interp.TrapFrame` plus the owning instance.
///
/// `func_offset` is a real byte offset within the function body and
/// `module_offset` one within the module binary, per the header's contract — an
/// IR index in either would look plausible and be wrong.
const Frame = struct {
    instance: ?*Instance,
    func_index: u32,
    func_offset: usize,
    module_offset: usize,
};

/// `wasm_frame_vec_t` — a vector of owned `wasm_frame_t*` (WASM_DECLARE_VEC(frame, *)).
const FrameVec = extern struct {
    size: usize,
    data: [*c]?*Frame,

    fn empty(self: *FrameVec) void {
        self.* = .{ .size = 0, .data = null };
    }
};

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

/// Allocate a trap carrying a NUL-terminated copy of `msg` and no frames.
fn makeTrap(msg: []const u8) ?*Trap {
    const t = alloc.create(Trap) catch return null;
    const buf = alloc.alloc(u8, msg.len + 1) catch {
        alloc.destroy(t);
        return null;
    };
    @memcpy(buf[0..msg.len], msg);
    buf[msg.len] = 0;
    t.* = .{ .message = .{ .size = msg.len + 1, .data = buf.ptr } };
    return t;
}

/// `makeTrap`, snapshotting the call stack `wi` just trapped on.
///
/// The copy is the point: the interpreter's trace is reset by the next
/// `invokeIndex`, but a `wasm_trap_t` outlives the call that produced it, so
/// pointing at the live trace would hand the embedder a dangling read. Failing
/// to allocate frames degrades to a message-only trap rather than losing the
/// trap itself.
fn makeTrapFrom(msg: []const u8, wi: *Instance) ?*Trap {
    const t = makeTrap(msg) orelse return null;
    const src = wi.inst.trapFrames();
    if (src.len == 0) return t;

    const frames = alloc.alloc(Frame, src.len) catch return t;
    for (src, frames) |s, *dst| {
        // Byte offsets are resolved here, on the error path, rather than tracked
        // during execution (see `Instance.frameOffset`).
        const off = wi.inst.frameOffset(alloc, s);
        dst.* = .{
            .instance = wi,
            .func_index = s.func_index,
            .func_offset = if (off) |o| o.func else 0,
            .module_offset = if (off) |o| o.module else 0,
        };
    }
    t.frames = frames;
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
            const r = slot orelse continue;
            if (r.vec_owned) {
                // This vec is the sole owner: `copy` duplicates export handles
                // rather than aliasing them, so nothing else can hold this
                // pointer. Free it outright — via destroyRef, so its handle on
                // the instance is dropped too.
                destroyRef(r);
            } else {
                // A standalone object the vec took ownership of (e.g. a host
                // func from `wasm_extern_vec_new`). It is refcounted and owns
                // host resources — its functype, finalizer, backing memory —
                // so it must go through `refDelete`. Destroying it directly
                // leaked all of that and skipped the finalizer.
                refDelete(r);
            }
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
    // Whole-struct literal, so `hdr` gets its default (rc = 1). Assigning
    // `wi.host_funcs`/`wi.inst` field-by-field onto `alloc.create` memory left
    // `hdr` uninitialized — a garbage refcount, which meant the instance could
    // be freed while export handles still pointed at it.
    wi.* = .{
        .inst = root.Instance.initWithImports(alloc, &m.inner, .{
            .funcs = funcs,
            .globals = gvals.items,
            .memories = mems.items,
            .tables = tbls.items,
        }) catch |e| {
            alloc.free(funcs);
            alloc.destroy(wi);
            if (trap_out) |t| t.* = makeTrap(@errorName(e));
            return null;
        },
        .host_funcs = funcs,
    };
    return wi;
}

export fn wasm_instance_delete(instance: ?*Instance) void {
    const wi = instance orelse return;
    if (!release(&wi.hdr)) return; // export handles / copies still hold it
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
        r.* = .{
            .kind = externKindToC(e.type.kind()),
            .vec_owned = true,
            .instance = refRetainInstance(@constCast(wi)),
            .index = e.index,
        };
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
    refDelete(f);
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

    const res = wi.inst.invokeIndex(r.index, argv) catch |e| return makeTrapFrom(@errorName(e), wi);
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
    refDelete(g);
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
    refDelete(m);
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
    refDelete(t);
}

// `wasm_table_get`/`set`/`grow` were deferred until `wasm_ref_t` existed —
// their whole signature is refs. Element values are interpreter `Value`s: a
// funcref is a function index, `null_ref` an empty slot (`interp` docs).

/// Build an `own wasm_ref_t*` for table slot value `v`, or null for an empty
/// slot. The handle is standalone (`vec_owned = false`), so the caller's
/// `wasm_ref_delete` really frees it.
fn refFromTableValue(owner: *const Ref, v: interp.Value) ?*RefHeader {
    if (v == interp.null_ref) return null;
    const r = alloc.create(Ref) catch return null;
    r.* = .{ .kind = EXTERN_FUNC, .instance = refRetainInstance(owner.instance), .index = @intCast(v) };
    return &r.hdr;
}

export fn wasm_table_get(t: ?*const Ref, index: u32) ?*RefHeader {
    const r = t orelse return null;
    const tbl = tableObj(r) orelse return null;
    if (index >= tbl.entries.len) return null;
    return refFromTableValue(r, tbl.entries[index]);
}

export fn wasm_table_set(t: ?*Ref, index: u32, ref: ?*RefHeader) bool {
    const r = t orelse return false;
    const tbl = tableObj(r) orelse return false;
    if (index >= tbl.entries.len) return false;
    tbl.entries[index] = tableValueFromRef(ref) orelse return false;
    return true;
}

/// The `Value` to store for `ref`: `null_ref` for a null ref, the function
/// index for a funcref. Returns null (→ the caller reports failure) for a ref
/// that can't live in a table, rather than storing something meaningless.
fn tableValueFromRef(ref: ?*RefHeader) ?interp.Value {
    const h = ref orelse return interp.null_ref;
    if (h.tag != .extern_obj) return null;
    const obj: *const Ref = @alignCast(@fieldParentPtr("hdr", h));
    if (obj.kind != EXTERN_FUNC) return null;
    return @as(interp.Value, obj.index);
}

export fn wasm_table_grow(t: ?*Ref, delta: u32, init: ?*RefHeader) bool {
    const r = t orelse return false;
    const tbl = tableObj(r) orelse return false;
    const fill = tableValueFromRef(init) orelse return false;
    const old = tbl.entries.len;
    const new_len = std.math.add(usize, old, delta) catch return false;
    if (tbl.max) |m| if (new_len > m) return false;
    const grown = alloc.realloc(tbl.entries, new_len) catch return false;
    @memset(grown[old..], fill);
    tbl.entries = grown;
    return true;
}

// ---- Traps ----------------------------------------------------------------

export fn wasm_trap_new(store: ?*Store, message: ?*const ByteVec) ?*Trap {
    _ = store;
    const t = alloc.create(Trap) catch return null;
    // Whole-struct literal, so `hdr` gets its default (rc = 1). Assigning fields
    // one at a time onto `alloc.create` memory leaves `hdr` uninitialized — a
    // garbage refcount, i.e. free-at-any-time.
    t.* = .{ .message = undefined };
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
    if (t.frames.len != 0) alloc.free(t.frames);
    alloc.destroy(t);
}

// ---- Type-object constructors, copies, and casts --------------------------

export fn wasm_valtype_copy(vt: ?*const ValType) ?*ValType {
    const p = vt orelse return null;
    const n = alloc.create(ValType) catch return null;
    n.* = p.*;
    return n;
}

export fn wasm_globaltype_new(content: ?*ValType, mutability: u8) ?*GlobalType {
    const c = content orelse return null; // takes ownership of `content`
    const gt = alloc.create(GlobalType) catch {
        alloc.destroy(c);
        return null;
    };
    gt.* = .{ .ekind = EXTERN_GLOBAL, .content = c, .mutability = mutability };
    return gt;
}

export fn wasm_tabletype_new(element: ?*ValType, limits: ?*const Limits) ?*TableType {
    const e = element orelse return null; // takes ownership of `element`
    const tt = alloc.create(TableType) catch {
        alloc.destroy(e);
        return null;
    };
    tt.* = .{
        .ekind = EXTERN_TABLE,
        .element = e,
        .limits = if (limits) |l| l.* else .{ .min = 0, .max = wasm_limits_max_default },
    };
    return tt;
}

export fn wasm_memorytype_new(limits: ?*const Limits) ?*MemoryType {
    const mt = alloc.create(MemoryType) catch return null;
    mt.* = .{
        .ekind = EXTERN_MEMORY,
        .limits = if (limits) |l| l.* else .{ .min = 0, .max = wasm_limits_max_default },
    };
    return mt;
}

export fn wasm_tagtype_new(ft: ?*FuncType) ?*TagType {
    const f = ft orelse return null; // takes ownership of `ft`
    const tt = alloc.create(TagType) catch {
        freeExternType(@ptrCast(f));
        return null;
    };
    tt.* = .{ .ekind = EXTERN_TAG, .functype = f };
    return tt;
}

export fn wasm_tagtype_functype(tt: ?*const TagType) ?*const FuncType {
    return (tt orelse return null).functype;
}

export fn wasm_tagtype_delete(tt: ?*TagType) void {
    freeExternType(@ptrCast(tt));
}

export fn wasm_importtype_new(module: ?*ByteVec, name: ?*ByteVec, ext: ?*anyopaque) ?*ImportType {
    // Takes ownership of all three.
    const m = module orelse return null;
    const n = name orelse return null;
    const it = alloc.create(ImportType) catch return null;
    it.* = .{ .module = m.*, .name = n.*, .ext = ext };
    m.* = .{ .size = 0, .data = null }; // moved out
    n.* = .{ .size = 0, .data = null };
    return it;
}

export fn wasm_exporttype_new(name: ?*ByteVec, ext: ?*anyopaque) ?*ExportType {
    const n = name orelse return null;
    const et = alloc.create(ExportType) catch return null;
    et.* = .{ .name = n.*, .ext = ext };
    n.* = .{ .size = 0, .data = null }; // moved out
    return et;
}

/// Deep-copy any `ekind`-first extern type. Type objects are values, not
/// references — unlike `wasm_ref_t`, a copy here really is a clone.
fn copyExternType(p: ?*const anyopaque) ?*anyopaque {
    const src = p orelse return null;
    return switch (externKindOf(src)) {
        EXTERN_FUNC => blk: {
            const ft: *const FuncType = @ptrCast(@alignCast(src));
            const n = alloc.create(FuncType) catch break :blk null;
            n.ekind = EXTERN_FUNC;
            copyValTypeVec(&n.params, &ft.params);
            copyValTypeVec(&n.results, &ft.results);
            break :blk @ptrCast(n);
        },
        EXTERN_GLOBAL => blk: {
            const gt: *const GlobalType = @ptrCast(@alignCast(src));
            const n = alloc.create(GlobalType) catch break :blk null;
            n.* = .{ .ekind = EXTERN_GLOBAL, .content = wasm_valtype_copy(gt.content), .mutability = gt.mutability };
            break :blk @ptrCast(n);
        },
        EXTERN_TABLE => blk: {
            const tt: *const TableType = @ptrCast(@alignCast(src));
            const n = alloc.create(TableType) catch break :blk null;
            n.* = .{ .ekind = EXTERN_TABLE, .element = wasm_valtype_copy(tt.element), .limits = tt.limits };
            break :blk @ptrCast(n);
        },
        EXTERN_MEMORY => blk: {
            const mt: *const MemoryType = @ptrCast(@alignCast(src));
            const n = alloc.create(MemoryType) catch break :blk null;
            n.* = .{ .ekind = EXTERN_MEMORY, .limits = mt.limits };
            break :blk @ptrCast(n);
        },
        EXTERN_TAG => blk: {
            const tt: *const TagType = @ptrCast(@alignCast(src));
            const n = alloc.create(TagType) catch break :blk null;
            n.* = .{ .ekind = EXTERN_TAG, .functype = @ptrCast(@alignCast(copyExternType(@ptrCast(tt.functype)))) };
            break :blk @ptrCast(n);
        },
        else => null,
    };
}

export fn wasm_externtype_copy(et: ?*const anyopaque) ?*anyopaque {
    return copyExternType(et);
}
export fn wasm_functype_copy(ft: ?*const FuncType) ?*FuncType {
    return @ptrCast(@alignCast(copyExternType(@ptrCast(ft))));
}
export fn wasm_globaltype_copy(gt: ?*const GlobalType) ?*GlobalType {
    return @ptrCast(@alignCast(copyExternType(@ptrCast(gt))));
}
export fn wasm_tabletype_copy(tt: ?*const TableType) ?*TableType {
    return @ptrCast(@alignCast(copyExternType(@ptrCast(tt))));
}
export fn wasm_memorytype_copy(mt: ?*const MemoryType) ?*MemoryType {
    return @ptrCast(@alignCast(copyExternType(@ptrCast(mt))));
}
export fn wasm_tagtype_copy(tt: ?*const TagType) ?*TagType {
    return @ptrCast(@alignCast(copyExternType(@ptrCast(tt))));
}

export fn wasm_importtype_copy(it: ?*const ImportType) ?*ImportType {
    const p = it orelse return null;
    const n = alloc.create(ImportType) catch return null;
    n.* = .{ .module = .{ .size = 0, .data = null }, .name = .{ .size = 0, .data = null }, .ext = copyExternType(p.ext) };
    wasm_byte_vec_copy(&n.module, &p.module);
    wasm_byte_vec_copy(&n.name, &p.name);
    return n;
}

export fn wasm_exporttype_copy(et: ?*const ExportType) ?*ExportType {
    const p = et orelse return null;
    const n = alloc.create(ExportType) catch return null;
    n.* = .{ .name = .{ .size = 0, .data = null }, .ext = copyExternType(p.ext) };
    wasm_byte_vec_copy(&n.name, &p.name);
    return n;
}

// The `X_as_externtype` upcasts are pointer reinterprets: every extern type
// starts with `ekind`, which is what `wasm_externtype_kind` reads.
export fn wasm_globaltype_as_externtype(gt: ?*GlobalType) ?*anyopaque {
    return @ptrCast(gt);
}
export fn wasm_globaltype_as_externtype_const(gt: ?*const GlobalType) ?*const anyopaque {
    return @ptrCast(gt);
}
export fn wasm_tabletype_as_externtype(tt: ?*TableType) ?*anyopaque {
    return @ptrCast(tt);
}
export fn wasm_tabletype_as_externtype_const(tt: ?*const TableType) ?*const anyopaque {
    return @ptrCast(tt);
}
export fn wasm_memorytype_as_externtype(mt: ?*MemoryType) ?*anyopaque {
    return @ptrCast(mt);
}
export fn wasm_memorytype_as_externtype_const(mt: ?*const MemoryType) ?*const anyopaque {
    return @ptrCast(mt);
}
export fn wasm_tagtype_as_externtype(tt: ?*TagType) ?*anyopaque {
    return @ptrCast(tt);
}
export fn wasm_tagtype_as_externtype_const(tt: ?*const TagType) ?*const anyopaque {
    return @ptrCast(tt);
}

// The downcasts are checked against `ekind`.
export fn wasm_externtype_as_tagtype(et: ?*anyopaque) ?*TagType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_TAG) @ptrCast(@alignCast(p)) else null;
}
export fn wasm_externtype_as_tagtype_const(et: ?*const anyopaque) ?*const TagType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_TAG) @ptrCast(@alignCast(p)) else null;
}
export fn wasm_externtype_as_globaltype_const(et: ?*const anyopaque) ?*const GlobalType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_GLOBAL) @ptrCast(@alignCast(p)) else null;
}
export fn wasm_externtype_as_tabletype_const(et: ?*const anyopaque) ?*const TableType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_TABLE) @ptrCast(@alignCast(p)) else null;
}
export fn wasm_externtype_as_memorytype_const(et: ?*const anyopaque) ?*const MemoryType {
    const p = et orelse return null;
    return if (externKindOf(p) == EXTERN_MEMORY) @ptrCast(@alignCast(p)) else null;
}

// ---- Generated vector families --------------------------------------------
//
// `WASM_DECLARE_VEC(name, *)` gives each type five functions with identical
// bodies modulo the element type and its deleter/copier. Same reasoning as the
// ref API: generate them so a typo can't hide in the bulk.
//
// The elements are `own` pointers, so `delete` deletes each one and `copy`
// clones each one — a shallow vec copy would double-free.

fn VecApi(
    comptime Vec: type,
    comptime Elem: type,
    comptime elemDelete: fn (?*Elem) callconv(.c) void,
    comptime elemCopy: fn (?*const Elem) callconv(.c) ?*Elem,
) type {
    return struct {
        fn newEmpty(out: *Vec) callconv(.c) void {
            out.* = .{ .size = 0, .data = null };
        }

        fn newUninitialized(out: *Vec, size: usize) callconv(.c) void {
            if (size == 0) return newEmpty(out);
            const buf = alloc.alloc(?*Elem, size) catch return newEmpty(out);
            @memset(buf, null);
            out.* = .{ .size = size, .data = buf.ptr };
        }

        fn new(out: *Vec, size: usize, data: [*c]const ?*Elem) callconv(.c) void {
            if (size == 0 or data == null) return newEmpty(out);
            const buf = alloc.alloc(?*Elem, size) catch return newEmpty(out);
            // Takes ownership of the caller's elements (they are `own`).
            @memcpy(buf, data[0..size]);
            out.* = .{ .size = size, .data = buf.ptr };
        }

        fn copy(out: *Vec, src: *const Vec) callconv(.c) void {
            if (src.size == 0 or src.data == null) return newEmpty(out);
            const buf = alloc.alloc(?*Elem, src.size) catch return newEmpty(out);
            for (src.data[0..src.size], buf) |s, *dst| dst.* = if (s) |p| elemCopy(p) else null;
            out.* = .{ .size = src.size, .data = buf.ptr };
        }

        fn delete(vec: *Vec) callconv(.c) void {
            if (vec.data != null and vec.size != 0) {
                for (vec.data[0..vec.size]) |slot| elemDelete(slot);
                alloc.free(vec.data[0..vec.size]);
            }
            vec.* = .{ .size = 0, .data = null };
        }
    };
}

/// `wasm_externtype_t` is reached as `*anyopaque`; give it callconv-C shims so
/// it can go through the same generator as the concrete types.
fn externTypeDelete(p: ?*anyopaque) callconv(.c) void {
    freeExternType(p);
}
fn externTypeCopy(p: ?*const anyopaque) callconv(.c) ?*anyopaque {
    return copyExternType(p);
}

comptime {
    const vecs = .{
        .{ "functype", FuncTypeVec, FuncType, wasm_functype_delete, wasm_functype_copy },
        .{ "globaltype", GlobalTypeVec, GlobalType, wasm_globaltype_delete, wasm_globaltype_copy },
        .{ "tabletype", TableTypeVec, TableType, wasm_tabletype_delete, wasm_tabletype_copy },
        .{ "memorytype", MemoryTypeVec, MemoryType, wasm_memorytype_delete, wasm_memorytype_copy },
        .{ "tagtype", TagTypeVec, TagType, wasm_tagtype_delete, wasm_tagtype_copy },
        .{ "externtype", ExternTypeVec, anyopaque, externTypeDelete, externTypeCopy },
        .{ "importtype", ImportTypeVec, ImportType, wasm_importtype_delete, wasm_importtype_copy },
        .{ "exporttype", ExportTypeVec, ExportType, wasm_exporttype_delete, wasm_exporttype_copy },
    };
    for (vecs) |v| {
        const api = VecApi(v[1], v[2], v[3], v[4]);
        const n = "wasm_" ++ v[0] ++ "_vec_";
        @export(&api.newEmpty, .{ .name = n ++ "new_empty" });
        @export(&api.newUninitialized, .{ .name = n ++ "new_uninitialized" });
        @export(&api.new, .{ .name = n ++ "new" });
        @export(&api.copy, .{ .name = n ++ "copy" });
        // importtype/exporttype already export a hand-written `_vec_delete`.
        if (!std.mem.eql(u8, v[0], "importtype") and !std.mem.eql(u8, v[0], "exporttype"))
            @export(&api.delete, .{ .name = n ++ "delete" });
    }
}

/// `wasm_extern_vec_copy` — externs are *references*, so unlike the type vecs
/// above this does not clone objects. It must still leave the two vecs with
/// independent ownership: aliasing the element pointers made
/// `copy(&b,&a); delete(&a); delete(&b);` — which the header invites — a double
/// free. It did not crash; it corrupted the freelist. Each element therefore
/// takes a real handle, via exactly the rule `wasm_X_copy` uses.
export fn wasm_extern_vec_copy(out: *ExternVec, src: *const ExternVec) void {
    if (src.size == 0 or src.data == null) return wasm_extern_vec_new_empty(out);
    const buf = alloc.alloc(?*Ref, src.size) catch return wasm_extern_vec_new_empty(out);
    for (src.data[0..src.size], buf) |s, *dst| {
        dst.* = if (s) |r| refApiFor("extern").copy(r) else null;
    }
    out.* = .{ .size = src.size, .data = buf.ptr };
}

// ---- wasm_ref_t: the shared reference API ---------------------------------
//
// `wasm.h` gives every ref-able object the same five entry points plus two
// upcasts and two downcasts. Writing those out by hand is ~86 near-identical
// functions — the kind of bulk where one copy-paste slip (a `global` body under
// a `memory` name) compiles fine and is invisible until an embedder hits it.
// Generating them from one table makes that class of bug unrepresentable.

/// The ref-able object types, in `wasm.h`'s terms. `kind` narrows the ones that
/// share our `Ref` struct: `wasm_ref_as_func` must reject a global, and only
/// `Externkind` can tell them apart.
const RefType = struct {
    name: []const u8,
    T: type,
    tag: RefTag,
    kind: ?Externkind = null,
};

const ref_types = [_]RefType{
    .{ .name = "extern", .T = Ref, .tag = .extern_obj },
    .{ .name = "func", .T = Ref, .tag = .extern_obj, .kind = EXTERN_FUNC },
    .{ .name = "global", .T = Ref, .tag = .extern_obj, .kind = EXTERN_GLOBAL },
    .{ .name = "table", .T = Ref, .tag = .extern_obj, .kind = EXTERN_TABLE },
    .{ .name = "memory", .T = Ref, .tag = .extern_obj, .kind = EXTERN_MEMORY },
    .{ .name = "foreign", .T = Foreign, .tag = .foreign },
    .{ .name = "instance", .T = Instance, .tag = .instance },
    .{ .name = "module", .T = Module, .tag = .module },
    .{ .name = "trap", .T = Trap, .tag = .trap },
};

/// Generate the `WASM_DECLARE_REF` surface for one object type.
fn RefApi(comptime rt: RefType) type {
    const T = rt.T;
    return struct {
        /// Does this header actually point at an `rt`-shaped object?
        fn matches(h: *const RefHeader) bool {
            if (h.tag != rt.tag) return false;
            const want = rt.kind orelse return true;
            const obj: *const Ref = @alignCast(@fieldParentPtr("hdr", h));
            return obj.kind == want;
        }

        /// `wasm_X_copy` — another handle to the same object, not a clone. See
        /// the object-model note: `same(copy(x), x)` has to hold.
        fn copy(x: ?*const T) callconv(.c) ?*T {
            const p = x orelse return null;
            const m: *T = @constCast(p);
            // An export handle's storage belongs to the extern vec that made it,
            // and that vec frees it on its own schedule. Retaining would hand
            // the caller a pointer the vec later frees regardless — a
            // use-after-free. Duplicate instead: it is a cheap view (kind +
            // instance + index), `same` compares those structurally, so the
            // duplicate is still "the same object" while owning itself.
            if (rt.tag == .extern_obj and @as(*const Ref, @ptrCast(p)).vec_owned)
                return @ptrCast(dupExportHandle(@ptrCast(p)) orelse return null);
            retain(&m.hdr);
            return m;
        }

        fn same(a: ?*const T, b: ?*const T) callconv(.c) bool {
            const x = a orelse return b == null;
            const y = b orelse return false;
            if (x == y) return true;
            // Two handles onto the same instance export are the same object,
            // even though they are distinct allocations.
            if (rt.tag == .extern_obj) {
                const rx: *const Ref = @ptrCast(x);
                const ry: *const Ref = @ptrCast(y);
                if (rx.instance != null and rx.instance == ry.instance)
                    return rx.kind == ry.kind and rx.index == ry.index;
            }
            return false;
        }

        fn getHostInfo(x: ?*const T) callconv(.c) ?*anyopaque {
            const p = x orelse return null;
            return p.hdr.host_info;
        }

        fn setHostInfo(x: ?*T, info: ?*anyopaque) callconv(.c) void {
            const p = x orelse return;
            p.hdr.host_info = info;
            p.hdr.host_info_finalizer = null;
        }

        fn setHostInfoWithFinalizer(x: ?*T, info: ?*anyopaque, fin: ?Finalizer) callconv(.c) void {
            const p = x orelse return;
            p.hdr.host_info = info;
            p.hdr.host_info_finalizer = fin;
        }

        /// Borrowed upcast — must not allocate, so hand out the embedded header.
        fn asRef(x: ?*T) callconv(.c) ?*RefHeader {
            const p = x orelse return null;
            return &p.hdr;
        }

        fn asRefConst(x: ?*const T) callconv(.c) ?*const RefHeader {
            const p = x orelse return null;
            return &p.hdr;
        }

        /// Downcast, checked: a `wasm_ref_t` that isn't this type yields null
        /// rather than a bogus pointer.
        fn refAs(r: ?*RefHeader) callconv(.c) ?*T {
            const h = r orelse return null;
            if (!matches(h)) return null;
            return @alignCast(@fieldParentPtr("hdr", h));
        }

        fn refAsConst(r: ?*const RefHeader) callconv(.c) ?*const T {
            const h = r orelse return null;
            if (!matches(h)) return null;
            return @alignCast(@fieldParentPtr("hdr", h));
        }
    };
}

/// The generated API for one ref type, by its `wasm.h` name. The generated
/// functions are exported symbols, not Zig identifiers, so this is how Zig code
/// (the tests below) reaches them.
fn refApiFor(comptime name: []const u8) type {
    for (ref_types) |rt| {
        if (std.mem.eql(u8, rt.name, name)) return RefApi(rt);
    }
    @compileError("no ref type named " ++ name);
}

comptime {
    for (ref_types) |rt| {
        const api = RefApi(rt);
        const n = "wasm_" ++ rt.name;
        @export(&api.copy, .{ .name = n ++ "_copy" });
        @export(&api.same, .{ .name = n ++ "_same" });
        @export(&api.getHostInfo, .{ .name = n ++ "_get_host_info" });
        @export(&api.setHostInfo, .{ .name = n ++ "_set_host_info" });
        @export(&api.setHostInfoWithFinalizer, .{ .name = n ++ "_set_host_info_with_finalizer" });
        @export(&api.asRef, .{ .name = n ++ "_as_ref" });
        @export(&api.asRefConst, .{ .name = n ++ "_as_ref_const" });
        @export(&api.refAs, .{ .name = "wasm_ref_as_" ++ rt.name });
        @export(&api.refAsConst, .{ .name = "wasm_ref_as_" ++ rt.name ++ "_const" });
    }
}

// `wasm_ref_t` itself gets the base API (no casts — it is the base).

export fn wasm_ref_delete(r: ?*RefHeader) void {
    const h = r orelse return;
    // Dispatch to the concrete deleter so the object's own teardown runs.
    switch (h.tag) {
        .extern_obj => wasm_extern_delete(@alignCast(@fieldParentPtr("hdr", h))),
        .foreign => wasm_foreign_delete(@alignCast(@fieldParentPtr("hdr", h))),
        .instance => wasm_instance_delete(@alignCast(@fieldParentPtr("hdr", h))),
        .module => wasm_module_delete(@alignCast(@fieldParentPtr("hdr", h))),
        .trap => wasm_trap_delete(@alignCast(@fieldParentPtr("hdr", h))),
    }
}

export fn wasm_ref_copy(r: ?*const RefHeader) ?*RefHeader {
    const h = r orelse return null;
    const m: *RefHeader = @constCast(h);
    retain(m);
    return m;
}

export fn wasm_ref_same(a: ?*const RefHeader, b: ?*const RefHeader) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x == y) return true;
    if (x.tag != y.tag) return false;
    if (x.tag == .extern_obj) {
        const rx: *const Ref = @alignCast(@fieldParentPtr("hdr", x));
        const ry: *const Ref = @alignCast(@fieldParentPtr("hdr", y));
        if (rx.instance != null and rx.instance == ry.instance)
            return rx.kind == ry.kind and rx.index == ry.index;
    }
    return false;
}

export fn wasm_ref_get_host_info(r: ?*const RefHeader) ?*anyopaque {
    return (r orelse return null).host_info;
}

export fn wasm_ref_set_host_info(r: ?*RefHeader, info: ?*anyopaque) void {
    const h = r orelse return;
    h.host_info = info;
    h.host_info_finalizer = null;
}

export fn wasm_ref_set_host_info_with_finalizer(r: ?*RefHeader, info: ?*anyopaque, fin: ?Finalizer) void {
    const h = r orelse return;
    h.host_info = info;
    h.host_info_finalizer = fin;
}

// ---- wasm_foreign_t -------------------------------------------------------

export fn wasm_foreign_new(store: ?*Store) ?*Foreign {
    _ = store;
    const f = alloc.create(Foreign) catch return null;
    f.* = .{};
    return f;
}

export fn wasm_foreign_delete(foreign: ?*Foreign) void {
    const f = foreign orelse return;
    if (!release(&f.hdr)) return;
    alloc.destroy(f);
}

// ---- wasm_extern_t (delete; the rest is generated above) ------------------

export fn wasm_extern_delete(e: ?*Ref) void {
    refDelete(e);
}

/// A standalone copy of an instance-export handle: same object (`same` compares
/// kind+instance+index), but owning its own allocation so the caller can delete
/// it independently of the `wasm_extern_vec_t` the original came from.
///
/// Export handles are views — kind, instance, index — with no host resources to
/// clone, which is what makes duplicating them correct rather than a deep-copy
/// problem.
fn dupExportHandle(src: *const Ref) ?*Ref {
    const r = alloc.create(Ref) catch return null;
    r.* = .{ .kind = src.kind, .instance = refRetainInstance(src.instance), .index = src.index };
    return r;
}

/// Take a handle on the instance a `Ref` names, if any.
///
/// A `Ref` that names an instance dereferences it on **every call** — so it has
/// to own it. Without this, `exports(); instance_delete(); func_call()` — an
/// ordinary embedder sequence, no misuse — read freed memory. Balanced by
/// `destroyRef`.
fn refRetainInstance(wi: ?*Instance) ?*Instance {
    if (wi) |p| retain(&p.hdr);
    return wi;
}

/// Tear a `Ref` down: drop its handle on its instance, run its host cleanup,
/// free its storage. **The only place a `Ref`'s storage is released** — so the
/// instance handle can't be dropped twice or forgotten.
fn destroyRef(r: *Ref) void {
    if (r.instance) |wi| wasm_instance_delete(wi); // our handle, not the caller's
    // Whatever this Ref happens to own — a Ref is one struct covering all five
    // extern kinds, so each field is independent.
    if (r.host) |hc| if (hc.finalizer) |fin| fin(hc.env);
    if (r.functype) |ft| freeExternType(@ptrCast(ft));
    if (r.host_global) |hg| alloc.destroy(hg);
    if (r.host_memory) |mem| {
        alloc.free(mem.bytes);
        alloc.destroy(mem);
    }
    if (r.host_table) |tbl| {
        alloc.free(tbl.entries);
        alloc.destroy(tbl);
    }
    alloc.destroy(r);
}

/// Free a `Ref` if this was its last handle.
///
/// An **export handle** is storage owned by the `wasm_extern_vec_t` it came out
/// of, so dropping a handle never frees it here — `wasm_extern_vec_delete`
/// does. Only standalone objects from `wasm_*_new` own themselves.
fn refDelete(maybe: ?*Ref) void {
    const r = maybe orelse return;
    if (!release(&r.hdr)) return; // other handles remain
    if (r.vec_owned) return; // storage belongs to the extern vec
    destroyRef(r);
}

// ---- wasm_frame_t + the trap backtrace ------------------------------------
// `wasm.h` declares this whole family, so an embedder that follows the header
// and never gets it back is a link error, not a missing feature. The data comes
// from the interpreter's trap trace (`interp.Instance.trapFrames`).

/// `wasm_trap_origin` — the innermost frame, or null if the trap carries none
/// (a host-callback trap, or one raised before any wasm code ran). Owned by the
/// caller, per the header's `own` annotation.
export fn wasm_trap_origin(trap: ?*const Trap) ?*Frame {
    const t = trap orelse return null;
    if (t.frames.len == 0) return null;
    return copyFrame(&t.frames[0]);
}

/// `wasm_trap_trace` — the whole call stack, innermost first. Each element is
/// owned by the caller; `wasm_frame_vec_delete` releases them.
export fn wasm_trap_trace(trap: ?*const Trap, out: *FrameVec) void {
    const t = trap orelse return out.empty();
    if (t.frames.len == 0) return out.empty();
    const buf = alloc.alloc(?*Frame, t.frames.len) catch return out.empty();
    for (t.frames, buf) |*src, *dst| dst.* = copyFrame(src);
    out.* = .{ .size = buf.len, .data = buf.ptr };
}

fn copyFrame(src: *const Frame) ?*Frame {
    const f = alloc.create(Frame) catch return null;
    f.* = src.*;
    return f;
}

export fn wasm_frame_copy(frame: ?*const Frame) ?*Frame {
    const f = frame orelse return null;
    return copyFrame(f);
}

export fn wasm_frame_delete(frame: ?*Frame) void {
    const f = frame orelse return;
    alloc.destroy(f);
}

/// The instance the frame ran in. Borrowed — not `own` in the header.
export fn wasm_frame_instance(frame: ?*const Frame) ?*Instance {
    const f = frame orelse return null;
    return f.instance;
}

export fn wasm_frame_func_index(frame: ?*const Frame) u32 {
    const f = frame orelse return 0;
    return f.func_index;
}

/// Byte offset of the trapping instruction within its function's body — a real
/// offset into the original bytes, so it lines up with `wasm-objdump`.
export fn wasm_frame_func_offset(frame: ?*const Frame) usize {
    const f = frame orelse return 0;
    return f.func_offset;
}

/// Byte offset of the trapping instruction within the module binary.
export fn wasm_frame_module_offset(frame: ?*const Frame) usize {
    const f = frame orelse return 0;
    return f.module_offset;
}

// ---- wasm_frame_vec_t -----------------------------------------------------

export fn wasm_frame_vec_new_empty(out: *FrameVec) void {
    out.empty();
}

export fn wasm_frame_vec_new_uninitialized(out: *FrameVec, size: usize) void {
    if (size == 0) return out.empty();
    const buf = alloc.alloc(?*Frame, size) catch return out.empty();
    @memset(buf, null);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_frame_vec_new(out: *FrameVec, size: usize, data: [*c]const ?*Frame) void {
    if (size == 0 or data == null) return out.empty();
    const buf = alloc.alloc(?*Frame, size) catch return out.empty();
    @memcpy(buf, data[0..size]);
    out.* = .{ .size = size, .data = buf.ptr };
}

export fn wasm_frame_vec_copy(out: *FrameVec, src: *const FrameVec) void {
    if (src.size == 0 or src.data == null) return out.empty();
    const buf = alloc.alloc(?*Frame, src.size) catch return out.empty();
    // A vec of `own` pointers: copying the vec must deep-copy the frames, or
    // both vecs would free the same objects.
    for (src.data[0..src.size], buf) |s, *dst| dst.* = if (s) |p| copyFrame(p) else null;
    out.* = .{ .size = src.size, .data = buf.ptr };
}

export fn wasm_frame_vec_delete(vec: *FrameVec) void {
    if (vec.data != null and vec.size != 0) {
        for (vec.data[0..vec.size]) |slot| {
            if (slot) |f| alloc.destroy(f);
        }
        alloc.free(vec.data[0..vec.size]);
    }
    vec.empty();
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

// --- Tests -----------------------------------------------------------------
//
// These run the **C entry points** under `std.testing.allocator`, which fails a
// test on a leak or a double free. That detection is the point: `c_smoke.c`
// exercises the same paths on the real allocator, where a double free quietly
// corrupts the freelist and the test still prints OK — i.e. the C test cannot
// tell "correct" from "exploitable". Anything that hands ownership across the
// boundary belongs here too.

/// (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
const test_add_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
};

fn testInstance() struct { engine: *Engine, store: *Store, module: *Module, inst: *Instance } {
    const e = wasm_engine_new().?;
    const s = wasm_store_new(e).?;
    var bin: ByteVec = undefined;
    wasm_byte_vec_new(&bin, test_add_module.len, &test_add_module);
    defer wasm_byte_vec_delete(&bin);
    const m = wasm_module_new(s, &bin).?;
    var trap: ?*Trap = null;
    var none: ExternVec = undefined;
    wasm_extern_vec_new_empty(&none);
    const i = wasm_instance_new(s, m, &none, &trap).?;
    return .{ .engine = e, .store = s, .module = m, .inst = i };
}

fn testTeardown(h: anytype) void {
    wasm_instance_delete(h.inst);
    wasm_module_delete(h.module);
    wasm_store_delete(h.store);
    wasm_engine_delete(h.engine);
}

test "copying an extern vec and deleting both frees each Ref exactly once" {
    // The bug this exists for: `wasm_extern_vec_copy` aliased the element
    // pointers while `wasm_extern_vec_delete` destroyed them outright, so this
    // sequence — which the header invites — was a double free. It did not
    // crash; it corrupted the freelist. The testing allocator sees it.
    const h = testInstance();
    defer testTeardown(h);

    var a: ExternVec = undefined;
    wasm_instance_exports(h.inst, &a);
    try std.testing.expectEqual(@as(usize, 1), a.size);

    var b: ExternVec = undefined;
    wasm_extern_vec_copy(&b, &a);
    try std.testing.expectEqual(@as(usize, 1), b.size);

    wasm_extern_vec_delete(&a);
    wasm_extern_vec_delete(&b); // must not double-free the shared elements
}

test "a standalone host func in an extern vec is freed once, with its type" {
    // A vec the embedder built themselves owns real host objects: deleting it
    // must run the object's own cleanup (its functype), not just free the Ref.
    const e = wasm_engine_new().?;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e).?;
    defer wasm_store_delete(s);

    var params: ValTypeVec = undefined;
    var results: ValTypeVec = undefined;
    wasm_valtype_vec_new_empty(&params);
    wasm_valtype_vec_new_empty(&results);
    const ft = wasm_functype_new(&params, &results).?;
    const f = wasm_func_new(s, ft, testHostNoop).?;
    wasm_functype_delete(ft);

    var vec: ExternVec = undefined;
    const items = [_]?*Ref{wasm_func_as_extern(f)};
    wasm_extern_vec_new(&vec, 1, &items);
    wasm_extern_vec_delete(&vec); // owns the func now — frees it and its type
}

fn testHostNoop(args: ?*const ValVec, results: ?*ValVec) callconv(.c) ?*Trap {
    _ = args;
    _ = results;
    return null;
}

test "refcounted copy: the object outlives the first handle, and is freed once" {
    const e = wasm_engine_new().?;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e).?;
    defer wasm_store_delete(s);
    var bin: ByteVec = undefined;
    wasm_byte_vec_new(&bin, test_add_module.len, &test_add_module);
    defer wasm_byte_vec_delete(&bin);

    const mod_api = refApiFor("module"); // the generated fns are symbols, not idents
    const m = wasm_module_new(s, &bin).?;
    const m2 = mod_api.copy(m).?;
    try std.testing.expect(mod_api.same(m, m2)); // a copy IS the same object

    wasm_module_delete(m); // first handle goes; the object must survive
    {
        // Read through the surviving handle. The name is owned by `ex`, so it
        // must be compared before `ex` is deleted — not returned out of the
        // block (the testing allocator caught that as a use-after-free).
        var ex: ExportTypeVec = undefined;
        wasm_module_exports(m2, &ex);
        defer wasm_exporttype_vec_delete(&ex);
        try std.testing.expectEqual(@as(usize, 1), ex.size);
        const n = wasm_exporttype_name(ex.data[0]).?;
        try std.testing.expectEqualStrings("add", n.data[0..n.size]);
    }
    wasm_module_delete(m2); // last handle: freed exactly once
}

test "host_info finalizer runs exactly once, on the last handle" {
    const S = struct {
        var calls: usize = 0;
        fn fin(p: ?*anyopaque) callconv(.c) void {
            _ = p;
            calls += 1;
        }
    };
    S.calls = 0;

    const e = wasm_engine_new().?;
    defer wasm_engine_delete(e);
    const fgn = refApiFor("foreign");
    const f = wasm_foreign_new(null).?;
    var marker: u32 = 7;
    fgn.setHostInfoWithFinalizer(f, &marker, S.fin);

    const f2 = fgn.copy(f).?;
    wasm_foreign_delete(f); // not the last handle: finalizer must NOT run
    try std.testing.expectEqual(@as(usize, 0), S.calls);
    wasm_foreign_delete(f2); // last handle
    try std.testing.expectEqual(@as(usize, 1), S.calls);
}

test "a trap's frames stay valid after the call, and free once" {
    const h = testInstance();
    defer testTeardown(h);
    // Build a trap the way a failed call does, then read it back.
    const t = makeTrap("boom").?;
    var msg: ByteVec = undefined;
    wasm_trap_message(t, &msg);
    try std.testing.expectEqualStrings("boom", msg.data[0..4]);
    wasm_byte_vec_delete(&msg);

    var frames: FrameVec = undefined;
    wasm_trap_trace(t, &frames);
    wasm_frame_vec_delete(&frames);
    wasm_trap_delete(t);
}

test "an export handle keeps its instance alive" {
    // A Ref stores `*Instance` and dereferences it on every call. If deleting
    // the instance freed it while an export handle still pointed at it, the
    // next call would be a use-after-free -- reachable from a plain embedder
    // sequence (take exports, delete the instance, call). Handles own their
    // instance, so this must stay valid.
    const e = wasm_engine_new().?;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e).?;
    defer wasm_store_delete(s);
    var bin: ByteVec = undefined;
    wasm_byte_vec_new(&bin, test_add_module.len, &test_add_module);
    defer wasm_byte_vec_delete(&bin);
    const m = wasm_module_new(s, &bin).?;
    defer wasm_module_delete(m);

    var trap: ?*Trap = null;
    var none: ExternVec = undefined;
    wasm_extern_vec_new_empty(&none);
    const inst = wasm_instance_new(s, m, &none, &trap).?;

    var exps: ExternVec = undefined;
    wasm_instance_exports(inst, &exps);
    defer wasm_extern_vec_delete(&exps);

    wasm_instance_delete(inst); // the embedder is done with their handle

    // The export handle must still work.
    const f = wasm_extern_as_func(exps.data[0]).?;
    var args_buf = [_]Val{ valI32(40), valI32(2) };
    var args: ValVec = .{ .size = 2, .data = &args_buf };
    var res_buf = [_]Val{undefined};
    var res: ValVec = .{ .size = 1, .data = &res_buf };
    const t = wasm_func_call(f, &args, &res);
    try std.testing.expect(t == null);
    try std.testing.expectEqual(@as(i32, 42), res_buf[0].of.i32);
}

fn valI32(v: i32) Val {
    return .{ .kind = 0, .of = .{ .i32 = v } };
}

test "every ref-able object starts with exactly one handle" {
    // Guards a whole bug class. `alloc.create` returns uninitialized memory, so
    // a constructor that assigns fields one at a time leaves `hdr` — and thus
    // `rc` — garbage: the object is then freeable at any moment, or never.
    // `wasm_instance_new` and `wasm_trap_new` both did exactly that. Only a
    // whole-struct literal picks up the field defaults. Any new constructor for
    // a ref-able type must appear here.
    const e = wasm_engine_new().?;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e).?;
    defer wasm_store_delete(s);
    var bin: ByteVec = undefined;
    wasm_byte_vec_new(&bin, test_add_module.len, &test_add_module);
    defer wasm_byte_vec_delete(&bin);

    const m = wasm_module_new(s, &bin).?;
    try std.testing.expectEqual(@as(u32, 1), m.hdr.rc);
    try std.testing.expectEqual(RefTag.module, m.hdr.tag);

    var trap: ?*Trap = null;
    var none: ExternVec = undefined;
    wasm_extern_vec_new_empty(&none);
    const inst = wasm_instance_new(s, m, &none, &trap).?;
    try std.testing.expectEqual(@as(u32, 1), inst.hdr.rc);
    try std.testing.expectEqual(RefTag.instance, inst.hdr.tag);

    const t = wasm_trap_new(s, null).?;
    try std.testing.expectEqual(@as(u32, 1), t.hdr.rc);
    try std.testing.expectEqual(RefTag.trap, t.hdr.tag);
    wasm_trap_delete(t);

    const fgn = wasm_foreign_new(s).?;
    try std.testing.expectEqual(@as(u32, 1), fgn.hdr.rc);
    wasm_foreign_delete(fgn);

    // Standalone extern objects (each `wasm_*_new` builds a Ref).
    const gt = wasm_globaltype_new(wasm_valtype_new(WASM_I32_KIND), 1).?;
    var gv: Val = .{ .kind = 0, .of = .{ .i32 = 1 } };
    const g = wasm_global_new(s, gt, &gv).?;
    try std.testing.expectEqual(@as(u32, 1), g.hdr.rc);
    try std.testing.expectEqual(RefTag.extern_obj, g.hdr.tag);
    wasm_global_delete(g);
    wasm_globaltype_delete(gt);

    // An export handle, which the vec owns.
    var exps: ExternVec = undefined;
    wasm_instance_exports(inst, &exps);
    try std.testing.expectEqual(@as(u32, 1), exps.data[0].?.hdr.rc);
    try std.testing.expect(exps.data[0].?.vec_owned);
    wasm_extern_vec_delete(&exps);

    wasm_instance_delete(inst);
    wasm_module_delete(m);
}

const WASM_I32_KIND: Valkind = 0;
