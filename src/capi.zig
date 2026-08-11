//! capi.zig — the ABI-2 C surface declared by `include/wazmrt.h`.
//!
//! Replaces `wasm_c_api.zig` (the vendored wasm-c-api). See `cmem/roadmap.md` → CURRENT
//! PROGRAM for why, and `cmem/design-decisions.md` for the decision entry.
//!
//! **The safety property that makes this file different from the one it replaces.** The old
//! surface handed *refcounted ownership* across the C boundary, and every C-ABI audit finding
//! this project has ever had (#20, #21, #22 — 180 undefined symbols, a double free, a
//! use-after-free, an uninitialised refcount, and two more from a lifecycle fuzz) lived in it.
//! Here, everything a store owns is named by a **value handle**: a `u64` carrying the store's
//! identity and a slot index. The host cannot free one, cannot alias another store's resource
//! with one, and cannot use one after its store dies — those are decided by *lookup*, not by a
//! count the host is trusted to maintain. There is no ownership to transfer, so there is no
//! ownership bug to have.
//!
//! Opaque pointers (engine/store/module/error/trap) are still owned by the caller with exactly
//! one `_delete` each, which is ordinary C and is what the header documents.
//!
//! Libc-free: `std.heap.smp_allocator` (see `cmem/design-decisions.md`).
//!
//! ⚠️ `root.zig` does NOT import this file — the dependency runs the other way — so tests here
//! are unreachable from `mod_tests` and need their own target in `build.zig`. That exact gap is
//! why the old C ABI went its whole life untested and shipped #21's four bugs.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const Module = root.Module;
const interp = root.interp;

/// The C ABI's allocator. Under the test target this is the testing allocator, which fails on
/// double-free and leaks; otherwise the libc-free `smp_allocator`. Comptime, so release builds
/// are unaffected.
const alloc: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

// ---------------------------------------------------------------------------------------
// Version / ABI handshake
// ---------------------------------------------------------------------------------------

/// ⚠️ Must equal `WAZMRT_ABI_VERSION` in `include/wazmrt.h`. A test below pins them together;
/// they are in different languages, so nothing but a test can.
const abi_version: u32 = 2;

export fn wazmrt_abi_version() u32 {
    return abi_version;
}

export fn wazmrt_version_string() [*:0]const u8 {
    return root.version.ptr;
}

// ---------------------------------------------------------------------------------------
// Errors — host-side failures (compile / link / misuse)
// ---------------------------------------------------------------------------------------

/// Owned by the caller, exactly one `wazmrt_error_delete`.
pub const Error = struct {
    /// NUL-terminated so `wazmrt_error_message` can hand out a `const char *` directly.
    msg: [:0]u8,
};

/// Build an error from a format string. Returns null only if the allocation fails, and callers
/// must treat null as "the operation still failed" — never as success.
fn errorf(comptime fmt: []const u8, args: anytype) ?*Error {
    const e = alloc.create(Error) catch return null;
    const msg = std.fmt.allocPrintSentinel(alloc, fmt, args, 0) catch {
        alloc.destroy(e);
        return null;
    };
    e.* = .{ .msg = msg };
    return e;
}

export fn wazmrt_error_message(e: ?*const Error) ?[*:0]const u8 {
    const err = e orelse return null;
    return err.msg.ptr;
}

export fn wazmrt_error_delete(e: ?*Error) void {
    const err = e orelse return;
    alloc.free(err.msg);
    alloc.destroy(err);
}

// ---------------------------------------------------------------------------------------
// Traps — guest failures
// ---------------------------------------------------------------------------------------

/// One guest stack frame, snapshotted when the trap was made so it outlives the call.
pub const Frame = struct {
    func_index: u32,
    /// Byte offset of the trapping instruction FROM THE START OF THE MODULE — the origin
    /// `wasm-objdump` prints. ⚠️ Do not change this to body-relative: the number exists to be
    /// compared against another tool's output without rebasing.
    offset: u32,
    /// From the name section; null for a stripped guest. Owned by the trap.
    name: ?[:0]u8,
};

pub const Trap = struct {
    msg: [:0]u8,
    frames: []Frame,
};

/// `message` may be null; the trap then carries an empty string rather than a null pointer, so
/// `wazmrt_trap_message` never returns null for a live trap.
export fn wazmrt_trap_new(message: ?[*:0]const u8) ?*Trap {
    const text: []const u8 = if (message) |m| std.mem.span(m) else "";
    const t = alloc.create(Trap) catch return null;
    const msg = alloc.dupeZ(u8, text) catch {
        alloc.destroy(t);
        return null;
    };
    t.* = .{ .msg = msg, .frames = &.{} };
    return t;
}

export fn wazmrt_trap_message(t: ?*const Trap) ?[*:0]const u8 {
    const trap = t orelse return null;
    return trap.msg.ptr;
}

export fn wazmrt_trap_delete(t: ?*Trap) void {
    const trap = t orelse return;
    for (trap.frames) |f| if (f.name) |n| alloc.free(n);
    alloc.free(trap.frames);
    alloc.free(trap.msg);
    alloc.destroy(trap);
}

export fn wazmrt_trap_frame_count(t: ?*const Trap) usize {
    const trap = t orelse return 0;
    return trap.frames.len;
}

/// Every out-parameter is optional. Returns false, writing nothing, for an out-of-range index —
/// so a caller that ignores the return value cannot read a partially-written frame.
export fn wazmrt_trap_frame(
    t: ?*const Trap,
    i: usize,
    func_index_out: ?*u32,
    offset_out: ?*u32,
    name_out: ?*?[*:0]const u8,
) bool {
    const trap = t orelse return false;
    if (i >= trap.frames.len) return false;
    const f = trap.frames[i];
    if (func_index_out) |p| p.* = f.func_index;
    if (offset_out) |p| p.* = f.offset;
    if (name_out) |p| p.* = if (f.name) |n| n.ptr else null;
    return true;
}

// ---------------------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------------------

/// Holds the configuration shared by the stores made from it, and must outlive them. The
/// feature/ceiling fields arrive with the config surface in step 2e — deliberately absent
/// rather than present-and-ignored, because the header promises a disabled proposal makes a
/// module *invalid*, and a toggle that gates nothing while reading as a control is worse than
/// no toggle at all.
pub const Engine = struct {
    /// Distinguishes stores made from different engines in diagnostics; not a security
    /// boundary (the store id is what handles are checked against).
    id: u64,
};

var next_engine_id: std.atomic.Value(u64) = .init(1);

export fn wazmrt_engine_new() ?*Engine {
    const e = alloc.create(Engine) catch return null;
    e.* = .{ .id = next_engine_id.fetchAdd(1, .monotonic) };
    return e;
}

export fn wazmrt_engine_delete(e: ?*Engine) void {
    const eng = e orelse return;
    alloc.destroy(eng);
}

// ---------------------------------------------------------------------------------------
// Store + value handles
// ---------------------------------------------------------------------------------------

/// A value handle is `(store_id << 32) | (slot + 1)`.
///
/// Slot 0 is never used, so an all-zero handle — a `wazmrt_instance_t` a caller forgot to fill
/// in, or one zeroed by `memset` — is *invalid by construction* rather than naming slot 0 of
/// whatever store it is presented to. That is the single most likely host mistake, and it is
/// the one this encoding makes free to catch.
///
/// Store ids come from a process-wide monotonic counter and are never reused, so a handle from
/// a DELETED store fails the id comparison against any later store rather than aliasing it.
const Handle = struct {
    const slot_bits = 32;
    const slot_mask: u64 = (1 << slot_bits) - 1;

    fn make(store_id: u64, index: u32) u64 {
        return (store_id << slot_bits) | (@as(u64, index) + 1);
    }
    fn storeId(id: u64) u64 {
        return id >> slot_bits;
    }
    /// Null when the handle is zero/never-initialized, so callers get "invalid" rather than a
    /// wrapped index.
    fn slot(id: u64) ?u32 {
        const s = id & slot_mask;
        if (s == 0) return null;
        return @intCast(s - 1);
    }
};

/// One instantiated module. The arena is per-instance and owned here, so the instance's whole
/// allocation graph dies with it — no cross-allocator freeing, which has been a real bug in this
/// codebase three separate times.
///
/// ⚠️ ALWAYS HEAP-ALLOCATED, and the store holds POINTERS to these — never the structs by value.
/// `ArenaAllocator` is not movable once `allocator()` has been taken from it: the returned
/// `Allocator` captures `&arena`, so copying the arena (into an ArrayList element, or when that
/// list reallocs on growth) leaves the interpreter allocating through a dangling pointer.
/// `interp.Instance` embeds an arena of its own and has the same constraint. Storing these by
/// value compiles perfectly and crashes on the second instantiation.
const InstanceSlot = struct {
    arena: std.heap.ArenaAllocator,
    inst: interp.Instance,
    module: *CModule,
    /// A trap raised by a HOST callback, stashed here because the interpreter's error set can
    /// only say `HostTrap` — it cannot carry the host's message. Consumed by whoever reports the
    /// failure, so the embedder gets its own trap back instead of a generic one.
    pending_trap: ?*Trap = null,

    /// Take the host trap if there is one, else make one from the interpreter's error.
    fn takeTrap(self: *InstanceSlot, err: anyerror) ?*Trap {
        if (self.pending_trap) |t| {
            self.pending_trap = null;
            return t;
        }
        return trapFrom(&self.inst, err);
    }
};

/// A func/memory/global handle names (instance slot, index within that instance) — never a raw
/// pointer, so nothing the host holds can outlive what it points at.
const Ref = struct { inst: u32, index: u32 };

pub const Store = struct {
    id: u64,
    engine: *Engine,
    instances: std.ArrayList(*InstanceSlot) = .empty,
    funcs: std.ArrayList(Ref) = .empty,
    memories: std.ArrayList(Ref) = .empty,
    globals: std.ArrayList(Ref) = .empty,

    /// Does `id` name a live slot in this store? The whole point of value handles: validity is
    /// *decided here*, never trusted from the caller.
    fn owns(self: *const Store, id: u64, len: usize) bool {
        if (Handle.storeId(id) != self.id) return false;
        const s = Handle.slot(id) orelse return false;
        return s < len;
    }

    /// Slot index for a handle of a list of length `len`, or null if the handle does not belong.
    fn resolve(self: *const Store, id: u64, len: usize) ?u32 {
        if (!self.owns(id, len)) return null;
        return Handle.slot(id).?;
    }

    fn instanceOf(self: *Store, r: Ref) *InstanceSlot {
        return self.instances.items[r.inst];
    }
};

var next_store_id: std.atomic.Value(u64) = .init(1);

export fn wazmrt_store_new(e: ?*Engine) ?*Store {
    const eng = e orelse return null;
    const s = alloc.create(Store) catch return null;
    s.* = .{ .id = next_store_id.fetchAdd(1, .monotonic), .engine = eng };
    return s;
}

/// Tears down every instance the store owns, in reverse order of creation, then releases the
/// modules they were holding open. A store is the single owner of everything reachable from it,
/// so this is the only place instances die — the host has no handle it could free.
export fn wazmrt_store_delete(s: ?*Store) void {
    const store = s orelse return;
    var i = store.instances.items.len;
    while (i > 0) {
        i -= 1;
        const slot = store.instances.items[i];
        slot.inst.deinit();
        slot.arena.deinit();
        releaseModule(slot.module);
        alloc.destroy(slot);
    }
    store.instances.deinit(alloc);
    store.funcs.deinit(alloc);
    store.memories.deinit(alloc);
    store.globals.deinit(alloc);
    alloc.destroy(store);
}

/// The four value-handle types. `extern struct` so the layout matches the header's
/// `typedef struct { uint64_t id; }` exactly.
pub const InstanceHandle = extern struct { id: u64 };
pub const FuncHandle = extern struct { id: u64 };
pub const MemoryHandle = extern struct { id: u64 };
pub const GlobalHandle = extern struct { id: u64 };

export fn wazmrt_instance_is_valid(s: ?*const Store, h: InstanceHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, store.instances.items.len);
}
export fn wazmrt_func_is_valid(s: ?*const Store, h: FuncHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, store.funcs.items.len);
}
export fn wazmrt_memory_is_valid(s: ?*const Store, h: MemoryHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, store.memories.items.len);
}
export fn wazmrt_global_is_valid(s: ?*const Store, h: GlobalHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, store.globals.items.len);
}

// ---------------------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------------------

/// A decoded module.
///
/// `interp.Instance` stores `&module.inner` and dereferences it on every call, so a module
/// deleted while an instance still uses it is a use-after-free — that is #22, found by the
/// lifecycle fuzz on the old ABI. Rather than push the rule onto the embedder ("do not delete a
/// module before its instances"), which is a rule that WILL be broken, the module tracks how
/// many instances hold it and `wazmrt_module_delete` defers the free until the last one goes.
///
/// ⚠️ This is internal ownership tracking, NOT the wasm-c-api refcount model we removed. The
/// difference is the one that matters: the host cannot observe, increment or decrement this
/// count, so it cannot get it wrong. There is no `_copy` that bumps it and no `_delete` that
/// forgets to check it.
pub const CModule = struct {
    inner: Module,
    live_instances: u32 = 0,
    /// The host has called `wazmrt_module_delete`; free as soon as `live_instances` hits 0.
    deleted: bool = false,
};

fn freeModule(cm: *CModule) void {
    cm.inner.deinit();
    alloc.destroy(cm);
}

fn releaseModule(cm: *CModule) void {
    cm.live_instances -= 1;
    if (cm.deleted and cm.live_instances == 0) freeModule(cm);
}

/// Mirrors `wazmrt_externkind_t`.
const ExternKind = enum(c_int) { func = 0, table = 1, memory = 2, global = 3, tag = 4 };

/// Null for a kind this ABI cannot name.
///
/// ⚠️ The `else` prong is not defensive noise. `Extern.kind()` returns a NON-EXHAUSTIVE enum, so
/// a future extern kind would compile fine here and — with a `.func` fallback, the tempting
/// shortcut — be reported to the embedder as a *function*. Describing a thing as the wrong kind
/// is the silent-wrong fall-through this codebase treats as the worst failure mode, so an
/// un-nameable kind refuses the whole query instead. Unreachable with today's five kinds.
fn externKind(e: Module.Extern) ?ExternKind {
    return switch (e.kind()) {
        .func => .func,
        .table => .table,
        .memory => .memory,
        .global => .global,
        .tag => .tag,
        else => null,
    };
}

/// Decode **and validate**. Validation is not optional on any path that can execute: a runtime
/// that runs an invalid module is over-permissive, not lenient, and an invalid module that is
/// merely wrong (rather than memory-unsafe) runs and prints a plausible wrong answer. That
/// asymmetry once let the Rust port carry a phantom defect for two releases.
export fn wazmrt_module_new(
    e: ?*Engine,
    bytes: ?[*]const u8,
    len: usize,
    out: ?**CModule,
) ?*Error {
    _ = e orelse return errorf("wazmrt_module_new: engine is NULL", .{});
    const out_p = out orelse return errorf("wazmrt_module_new: out is NULL", .{});
    const src = (bytes orelse return errorf("wazmrt_module_new: bytes is NULL", .{}))[0..len];

    var m = Module.decode(alloc, src) catch |err| {
        return errorf("failed to decode module: {s}", .{@errorName(err)});
    };
    errdefer m.deinit();

    root.validate(alloc, &m) catch |err| {
        // The wasmtime-shaped diagnostic: offset + function + expected/found, matched
        // byte-for-byte against wasmtime 47 so the two tools can be compared directly.
        const site = root.lastFailureSite();
        const msg = diagnose(err, site);
        m.deinit();
        return msg;
    };

    const cm = alloc.create(CModule) catch {
        m.deinit();
        return errorf("out of memory", .{});
    };
    cm.* = .{ .inner = m };
    out_p.* = cm;
    return null;
}

/// Format a validation failure the way the CLI does. Kept beside `wazmrt_module_new` rather
/// than shared with `main.zig` only because the CLI writes to a stream and this must produce an
/// owned string; **the wording must stay identical** — one module must not be described two
/// different ways depending on which entry point refused it.
fn diagnose(err: anyerror, site: root.FailureSite) ?*Error {
    // `ValType` is NON-EXHAUSTIVE, so `@tagName` is undefined on a value outside its fields;
    // `tagName` returns null instead and we fall back to the bare error name.
    if (site.expected != null and site.found != null) {
        const exp = std.enums.tagName(root.types.ValType, site.expected.?);
        const got = std.enums.tagName(root.types.ValType, site.found.?);
        if (exp != null and got != null) {
            if (site.offset) |off| {
                if (site.func_index) |fi| {
                    return errorf("Invalid input WebAssembly code at offset {d} (function {d}): type mismatch: expected {s}, found {s}", .{ off, fi, exp.?, got.? });
                }
                return errorf("Invalid input WebAssembly code at offset {d}: type mismatch: expected {s}, found {s}", .{ off, exp.?, got.? });
            }
            return errorf("type mismatch: expected {s}, found {s}", .{ exp.?, got.? });
        }
    }
    if (site.offset) |off| {
        if (site.func_index) |fi| {
            return errorf("Invalid input WebAssembly code at offset {d} (function {d}): {s}", .{ off, fi, @errorName(err) });
        }
        return errorf("Invalid input WebAssembly code at offset {d}: {s}", .{ off, @errorName(err) });
    }
    return errorf("invalid module: {s}", .{@errorName(err)});
}

/// Would `wazmrt_module_new` succeed? No allocation survives, no module is produced.
export fn wazmrt_module_validate(e: ?*Engine, bytes: ?[*]const u8, len: usize) bool {
    _ = e orelse return false;
    const src = (bytes orelse return false)[0..len];
    var m = Module.decode(alloc, src) catch return false;
    defer m.deinit();
    root.validate(alloc, &m) catch return false;
    return true;
}

/// Deferred when instances still hold it — see `CModule`. The caller must not touch the pointer
/// afterwards either way, so the deferral is invisible.
export fn wazmrt_module_delete(m: ?*CModule) void {
    const cm = m orelse return;
    cm.deleted = true;
    if (cm.live_instances == 0) freeModule(cm);
}

export fn wazmrt_module_export_count(m: ?*const CModule) usize {
    const cm = m orelse return 0;
    return cm.inner.exports.len;
}

export fn wazmrt_module_export(
    m: ?*const CModule,
    i: usize,
    name_out: ?*[*]const u8,
    name_len_out: ?*usize,
    kind_out: ?*ExternKind,
) bool {
    const cm = m orelse return false;
    if (i >= cm.inner.exports.len) return false;
    const ex = cm.inner.exports[i];
    const kind = externKind(ex.type) orelse return false;
    // Names are NOT NUL-terminated — wasm names may contain any UTF-8, including a NUL — which
    // is why the length is a separate out-param and not a courtesy.
    if (name_out) |p| p.* = ex.name.ptr;
    if (name_len_out) |p| p.* = ex.name.len;
    if (kind_out) |p| p.* = kind;
    return true;
}

export fn wazmrt_module_import_count(m: ?*const CModule) usize {
    const cm = m orelse return 0;
    return cm.inner.imports.len;
}

/// Imports in DECLARATION ORDER — the order a linker must satisfy them in. The decoder
/// preserves it (grouping by kind would break the positional linking ABI).
export fn wazmrt_module_import(
    m: ?*const CModule,
    i: usize,
    module_out: ?*[*]const u8,
    module_len_out: ?*usize,
    name_out: ?*[*]const u8,
    name_len_out: ?*usize,
    kind_out: ?*ExternKind,
) bool {
    const cm = m orelse return false;
    if (i >= cm.inner.imports.len) return false;
    const im = cm.inner.imports[i];
    const kind = externKind(im.type) orelse return false;
    if (module_out) |p| p.* = im.module.ptr;
    if (module_len_out) |p| p.* = im.module.len;
    if (name_out) |p| p.* = im.name.ptr;
    if (name_len_out) |p| p.* = im.name.len;
    if (kind_out) |p| p.* = kind;
    return true;
}

// ---------------------------------------------------------------------------------------
// Values — wazmrt_val_t <-> interpreter slots
// ---------------------------------------------------------------------------------------

/// Mirrors `wazmrt_valkind_t`.
const ValKind = enum(c_int) { i32 = 0, i64 = 1, f32 = 2, f64 = 3, funcref = 4, externref = 5, v128 = 6 };

/// Mirrors `wazmrt_val_t`. `extern` so the layout is exactly what the header declares.
pub const Val = extern struct {
    kind: ValKind,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        ref: u64,
        v128: [16]u8,
    },
};

/// Null for a type this boundary cannot carry (the GC reference types), which is refused rather
/// than marshalled as something plausible.
fn valKindOf(vt: root.types.ValType) ?ValKind {
    return switch (vt) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        .funcref => .funcref,
        .externref => .externref,
        .v128 => .v128,
        else => null,
    };
}

// ⚠️ A v128 OCCUPIES TWO SLOTS. Walking a slot array in lockstep with a type list is the bug
// that shipped in two separate consumers (the CLI printed raw slots and exited 0; the C ABI
// returned 3 instead of 22 and punned half a vector as a pointer). Every conversion below
// advances by `interp.slotWidth`, never by one.

/// Write one value into `slots`, returning how many it consumed. Null if the kind disagrees with
/// the declared parameter type — a mismatch is refused, never reinterpreted.
fn valToSlots(v: Val, want: root.types.ValType, slots: []interp.Value) ?u32 {
    const k = valKindOf(want) orelse return null;
    if (v.kind != k) return null;
    switch (want) {
        .i32 => slots[0] = interp.i32Value(v.of.i32),
        .i64 => slots[0] = interp.i64Value(v.of.i64),
        .f32 => slots[0] = interp.f32Value(v.of.f32),
        .f64 => slots[0] = interp.f64Value(v.of.f64),
        .funcref, .externref => slots[0] = v.of.ref,
        .v128 => {
            // Low half first, matching how the interpreter stacks a vector.
            slots[0] = std.mem.readInt(u64, v.of.v128[0..8], .little);
            slots[1] = std.mem.readInt(u64, v.of.v128[8..16], .little);
        },
        else => return null,
    }
    return interp.slotWidth(want);
}

fn slotsToVal(slots: []const interp.Value, got: root.types.ValType, out: *Val) ?u32 {
    const k = valKindOf(got) orelse return null;
    out.kind = k;
    switch (got) {
        .i32 => out.of.i32 = interp.asI32(slots[0]),
        .i64 => out.of.i64 = interp.asI64(slots[0]),
        .f32 => out.of.f32 = interp.asF32(slots[0]),
        .f64 => out.of.f64 = interp.asF64(slots[0]),
        .funcref, .externref => out.of.ref = slots[0],
        .v128 => {
            std.mem.writeInt(u64, out.of.v128[0..8], slots[0], .little);
            std.mem.writeInt(u64, out.of.v128[8..16], slots[1], .little);
        },
        else => return null,
    }
    return interp.slotWidth(got);
}

// ---------------------------------------------------------------------------------------
// Function types
// ---------------------------------------------------------------------------------------

pub const FuncType = struct {
    params: []ValKind,
    results: []ValKind,
};

export fn wazmrt_functype_new(
    params: ?[*]const ValKind,
    nparams: usize,
    results: ?[*]const ValKind,
    nresults: usize,
) ?*FuncType {
    const ft = alloc.create(FuncType) catch return null;
    const p = alloc.alloc(ValKind, nparams) catch {
        alloc.destroy(ft);
        return null;
    };
    const r = alloc.alloc(ValKind, nresults) catch {
        alloc.free(p);
        alloc.destroy(ft);
        return null;
    };
    if (params) |src| @memcpy(p, src[0..nparams]);
    if (results) |src| @memcpy(r, src[0..nresults]);
    ft.* = .{ .params = p, .results = r };
    return ft;
}

export fn wazmrt_functype_delete(ft: ?*FuncType) void {
    const f = ft orelse return;
    alloc.free(f.params);
    alloc.free(f.results);
    alloc.destroy(f);
}

export fn wazmrt_functype_param_count(ft: ?*const FuncType) usize {
    const f = ft orelse return 0;
    return f.params.len;
}
export fn wazmrt_functype_result_count(ft: ?*const FuncType) usize {
    const f = ft orelse return 0;
    return f.results.len;
}
export fn wazmrt_functype_param(ft: ?*const FuncType, i: usize, out: ?*ValKind) bool {
    const f = ft orelse return false;
    if (i >= f.params.len) return false;
    if (out) |p| p.* = f.params[i];
    return true;
}
export fn wazmrt_functype_result(ft: ?*const FuncType, i: usize, out: ?*ValKind) bool {
    const f = ft orelse return false;
    if (i >= f.results.len) return false;
    if (out) |p| p.* = f.results[i];
    return true;
}

// ---------------------------------------------------------------------------------------
// Linker
// ---------------------------------------------------------------------------------------

/// The C callback signature from the header.
pub const Callback = *const fn (
    env: ?*anyopaque,
    caller: *Caller,
    args: [*]const Val,
    nargs: usize,
    results: [*]Val,
    nresults: usize,
) callconv(.c) ?*Trap;

const Definition = union(enum) {
    func: struct {
        params: []ValKind,
        results: []ValKind,
        cb: Callback,
        env: ?*anyopaque,
        finalizer: ?*const fn (env: ?*anyopaque) callconv(.c) void,
    },
    global: Val,
};

const Entry = struct {
    module: []u8,
    name: []u8,
    def: Definition,

    fn deinit(self: *Entry) void {
        alloc.free(self.module);
        alloc.free(self.name);
        switch (self.def) {
            .func => |f| {
                if (f.finalizer) |fin| fin(f.env);
                alloc.free(f.params);
                alloc.free(f.results);
            },
            .global => {},
        }
    }
};

pub const Linker = struct {
    engine: *Engine,
    entries: std.ArrayList(Entry) = .empty,
    /// Back otherwise-unsatisfied FUNCTION imports with a trapping stub.
    trap_unknown: bool = false,
    /// Set when a guest called `proc_exit`; read by `wazmrt_wasi_exit_code` (2d).
    exit_code: ?i32 = null,

    fn find(self: *const Linker, module: []const u8, name: []const u8) ?*const Definition {
        // Linear: import counts are small, and a map would cost more in code size than it saves.
        // Later definitions win, so a redefinition replaces — hence the reverse walk.
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (std.mem.eql(u8, e.module, module) and std.mem.eql(u8, e.name, name)) return &e.def;
        }
        return null;
    }
};

export fn wazmrt_linker_new(e: ?*Engine) ?*Linker {
    const eng = e orelse return null;
    const l = alloc.create(Linker) catch return null;
    l.* = .{ .engine = eng };
    return l;
}

export fn wazmrt_linker_delete(l: ?*Linker) void {
    const lk = l orelse return;
    for (lk.entries.items) |*e| e.deinit();
    lk.entries.deinit(alloc);
    alloc.destroy(lk);
}

/// Define `module`.`name` as a host function. Name strings are copied; `env` is passed to every
/// call and `env_finalizer` (may be NULL) runs when the linker is deleted or the name redefined.
export fn wazmrt_linker_define_func(
    l: ?*Linker,
    module: ?[*:0]const u8,
    name: ?[*:0]const u8,
    ft: ?*const FuncType,
    cb: ?Callback,
    env: ?*anyopaque,
    env_finalizer: ?*const fn (env: ?*anyopaque) callconv(.c) void,
) ?*Error {
    const lk = l orelse return errorf("wazmrt_linker_define_func: linker is NULL", .{});
    const t = ft orelse return errorf("wazmrt_linker_define_func: type is NULL", .{});
    const f = cb orelse return errorf("wazmrt_linker_define_func: callback is NULL", .{});
    const m = spanOf(module);
    const n = spanOf(name);

    const mc = alloc.dupe(u8, m) catch return errorf("out of memory", .{});
    const nc = alloc.dupe(u8, n) catch {
        alloc.free(mc);
        return errorf("out of memory", .{});
    };
    const p = alloc.dupe(ValKind, t.params) catch {
        alloc.free(mc);
        alloc.free(nc);
        return errorf("out of memory", .{});
    };
    const r = alloc.dupe(ValKind, t.results) catch {
        alloc.free(mc);
        alloc.free(nc);
        alloc.free(p);
        return errorf("out of memory", .{});
    };
    lk.entries.append(alloc, .{
        .module = mc,
        .name = nc,
        .def = .{ .func = .{ .params = p, .results = r, .cb = f, .env = env, .finalizer = env_finalizer } },
    }) catch {
        alloc.free(mc);
        alloc.free(nc);
        alloc.free(p);
        alloc.free(r);
        return errorf("out of memory", .{});
    };
    return null;
}

export fn wazmrt_linker_define_global(
    l: ?*Linker,
    module: ?[*:0]const u8,
    name: ?[*:0]const u8,
    value: Val,
) ?*Error {
    const lk = l orelse return errorf("wazmrt_linker_define_global: linker is NULL", .{});
    const mc = alloc.dupe(u8, spanOf(module)) catch return errorf("out of memory", .{});
    const nc = alloc.dupe(u8, spanOf(name)) catch {
        alloc.free(mc);
        return errorf("out of memory", .{});
    };
    lk.entries.append(alloc, .{ .module = mc, .name = nc, .def = .{ .global = value } }) catch {
        alloc.free(mc);
        alloc.free(nc);
        return errorf("out of memory", .{});
    };
    return null;
}

/// ⚠️ Convenience with a real cost, documented in the header: with this set a typo'd import name
/// stops being a link-time error and becomes a runtime surprise.
export fn wazmrt_linker_define_unknown_imports_as_traps(l: ?*Linker) ?*Error {
    const lk = l orelse return errorf("wazmrt_linker_define_unknown_imports_as_traps: linker is NULL", .{});
    lk.trap_unknown = true;
    return null;
}

// ---------------------------------------------------------------------------------------
// Host callback plumbing
// ---------------------------------------------------------------------------------------

/// Per-import state for one host function, living in the instance's arena so it dies with the
/// instance. `slot` is filled before the instance can run, and the instance is heap-stable.
const Trampoline = struct {
    slot: *InstanceSlot,
    cb: ?Callback, // null ⇒ the trap-unknown stub
    env: ?*anyopaque,
    params: []const root.types.ValType,
    results: []const root.types.ValType,
};

/// Valid ONLY for the duration of one callback — it lives on the trampoline's stack frame.
pub const Caller = struct {
    slot: *InstanceSlot,
};

/// Arities above this use the heap. Sized so every surveyed loader import fits on the stack;
/// beyond it correctness matters more than the allocation.
const stack_vals = 16;

fn hostTrampoline(ctx: *anyopaque, args: []const interp.Value, results: []interp.Value) bool {
    const t: *Trampoline = @ptrCast(@alignCast(ctx));
    const cb = t.cb orelse {
        // The trap-unknown stub: an import that was never defined.
        t.slot.pending_trap = wazmrt_trap_new("unknown import called");
        return false;
    };

    var in_buf: [stack_vals]Val = undefined;
    var out_buf: [stack_vals]Val = undefined;
    const nin = t.params.len;
    const nout = t.results.len;

    const in: []Val = if (nin <= stack_vals) in_buf[0..nin] else alloc.alloc(Val, nin) catch {
        t.slot.pending_trap = wazmrt_trap_new("out of memory marshalling host call arguments");
        return false;
    };
    defer if (nin > stack_vals) alloc.free(in);
    const out: []Val = if (nout <= stack_vals) out_buf[0..nout] else alloc.alloc(Val, nout) catch {
        t.slot.pending_trap = wazmrt_trap_new("out of memory marshalling host call results");
        return false;
    };
    defer if (nout > stack_vals) alloc.free(out);

    // Slots in, values out — by slot width, because a v128 is two slots.
    var si: usize = 0;
    for (t.params, 0..) |vt, i| {
        const w = interp.slotWidth(vt);
        if (si + w > args.len) {
            t.slot.pending_trap = wazmrt_trap_new("host call: argument slots exhausted");
            return false;
        }
        _ = slotsToVal(args[si..], vt, &in[i]) orelse {
            t.slot.pending_trap = wazmrt_trap_new("host call: argument type cannot cross the ABI");
            return false;
        };
        si += w;
    }
    // Zeroed so a callback that writes nothing yields a defined value rather than whatever was
    // on the stack — the old ABI disclosed uninitialised heap to the guest exactly this way.
    @memset(out, .{ .kind = .i32, .of = .{ .i64 = 0 } });

    var caller: Caller = .{ .slot = t.slot };
    if (cb(t.env, &caller, in.ptr, nin, out.ptr, nout)) |trap| {
        t.slot.pending_trap = trap; // ownership transferred to the engine, per the header
        return false;
    }

    var oi: usize = 0;
    for (t.results, 0..) |vt, i| {
        const w = interp.slotWidth(vt);
        if (oi + w > results.len) {
            t.slot.pending_trap = wazmrt_trap_new("host call: result slots exhausted");
            return false;
        }
        _ = valToSlots(out[i], vt, results[oi..]) orelse {
            t.slot.pending_trap = wazmrt_trap_new("host call: result has the wrong type");
            return false;
        };
        oi += w;
    }
    return true;
}

export fn wazmrt_caller_get_memory(c: ?*Caller, name: ?[*:0]const u8, out: ?*MemoryHandle) bool {
    _ = c;
    _ = name;
    _ = out;
    // Deliberately always false, and the header says so: a durable memory handle must be tagged
    // against a live store, and during a callback the store is mid-borrow. Use the read/write
    // helpers below — which is what a loader actually needs. Kept so the wasmtime-shaped call
    // sequence compiles.
    return false;
}

export fn wazmrt_caller_memory_size(c: ?*Caller) usize {
    const caller = c orelse return 0;
    const mem = caller.slot.inst.memory0() orelse return 0;
    return mem.bytes.len;
}

export fn wazmrt_caller_read(c: ?*Caller, offset: u64, dst: ?*anyopaque, n: usize) bool {
    const caller = c orelse return false;
    const mem = caller.slot.inst.memory0() orelse return false;
    const end = std.math.add(u64, offset, n) catch return false;
    if (end > mem.bytes.len) return false;
    if (n == 0) return true;
    const d = dst orelse return false;
    @memcpy(@as([*]u8, @ptrCast(d))[0..n], mem.bytes[@intCast(offset)..][0..n]);
    return true;
}

export fn wazmrt_caller_write(c: ?*Caller, offset: u64, src: ?*const anyopaque, n: usize) bool {
    const caller = c orelse return false;
    const mem = caller.slot.inst.memory0() orelse return false;
    const end = std.math.add(u64, offset, n) catch return false;
    if (end > mem.bytes.len) return false;
    if (n == 0) return true;
    const s = src orelse return false;
    @memcpy(mem.bytes[@intCast(offset)..][0..n], @as([*]const u8, @ptrCast(s))[0..n]);
    return true;
}

/// Bind every declared import to something the linker defines.
///
/// Returns null on success. `Imports.funcs`/`globals` align with the module's imports OF THAT
/// KIND in declaration order, which is why this walks `module.imports` rather than the linker's
/// table — the positional layout is the interpreter's contract, not ours to reorder.
fn resolveImports(
    lk: *Linker,
    slot: *InstanceSlot,
    cm: *CModule,
    sa: std.mem.Allocator,
    out: *interp.Instance.Imports,
) ?*Error {
    var nfunc: usize = 0;
    var nglobal: usize = 0;
    for (cm.inner.imports) |im| switch (im.type.kind()) {
        .func => nfunc += 1,
        .global => nglobal += 1,
        else => {},
    };

    const funcs = sa.alloc(interp.Instance.HostFunc, nfunc) catch return errorf("out of memory", .{});
    const globals = sa.alloc(interp.Value, nglobal) catch return errorf("out of memory", .{});
    const globals_hi = sa.alloc(interp.Value, nglobal) catch return errorf("out of memory", .{});

    var fi: usize = 0;
    var gi: usize = 0;
    for (cm.inner.imports) |im| {
        switch (im.type) {
            .func => |want| {
                const def = lk.find(im.module, im.name) orelse {
                    if (!lk.trap_unknown)
                        return errorf("unresolved import '{s}'.'{s}'", .{ im.module, im.name });
                    const t = sa.create(Trampoline) catch return errorf("out of memory", .{});
                    t.* = .{ .slot = slot, .cb = null, .env = null, .params = want.params, .results = want.results };
                    funcs[fi] = .{ .native_env = .{ .ctx = t, .call = hostTrampoline } };
                    fi += 1;
                    continue;
                };
                const hf = switch (def.*) {
                    .func => |f| f,
                    .global => return errorf("import '{s}'.'{s}' is declared as a function but defined as a global", .{ im.module, im.name }),
                };

                // ⚠️ CHECK THE DECLARED SIGNATURE AT BIND TIME. An import declaration is
                // untrusted input: the guest picks the type it declares, and the host picks the
                // type it defines. If they disagree and we bind anyway, the callback reads
                // arguments that were never passed — which is a segfault from a four-line `.wat`
                // (10th audit pass, `wasi.guardArity`). Refusing here costs one comparison per
                // import and removes the whole class.
                if (hf.params.len != want.params.len or hf.results.len != want.results.len)
                    return errorf("import '{s}'.'{s}': the guest declares {d} param(s)/{d} result(s), the host defines {d}/{d}", .{ im.module, im.name, want.params.len, want.results.len, hf.params.len, hf.results.len });
                for (want.params, hf.params, 0..) |vt, k, i| {
                    const declared = valKindOf(vt) orelse
                        return errorf("import '{s}'.'{s}': parameter {d} has a type this ABI cannot carry", .{ im.module, im.name, i });
                    if (declared != k)
                        return errorf("import '{s}'.'{s}': parameter {d} type mismatch", .{ im.module, im.name, i });
                }
                for (want.results, hf.results, 0..) |vt, k, i| {
                    const declared = valKindOf(vt) orelse
                        return errorf("import '{s}'.'{s}': result {d} has a type this ABI cannot carry", .{ im.module, im.name, i });
                    if (declared != k)
                        return errorf("import '{s}'.'{s}': result {d} type mismatch", .{ im.module, im.name, i });
                }

                const t = sa.create(Trampoline) catch return errorf("out of memory", .{});
                t.* = .{ .slot = slot, .cb = hf.cb, .env = hf.env, .params = want.params, .results = want.results };
                funcs[fi] = .{ .native_env = .{ .ctx = t, .call = hostTrampoline } };
                fi += 1;
            },
            .global => |want| {
                const def = lk.find(im.module, im.name) orelse
                    return errorf("unresolved global import '{s}'.'{s}'", .{ im.module, im.name });
                const v = switch (def.*) {
                    .global => |g| g,
                    .func => return errorf("import '{s}'.'{s}' is declared as a global but defined as a function", .{ im.module, im.name }),
                };
                var two: [2]interp.Value = .{ 0, 0 };
                _ = valToSlots(v, want.content, &two) orelse
                    return errorf("import '{s}'.'{s}': global value has the wrong type", .{ im.module, im.name });
                globals[gi] = two[0];
                globals_hi[gi] = two[1];
                gi += 1;
            },
            // Refused LOUDLY rather than left unbound: an unbacked memory or table import would
            // otherwise surface as a confusing trap deep inside execution. No surveyed consumer
            // needs them, and adding them later is additive.
            .memory => return errorf("import '{s}'.'{s}': imported memories are not supported by this ABI", .{ im.module, im.name }),
            .table => return errorf("import '{s}'.'{s}': imported tables are not supported by this ABI", .{ im.module, im.name }),
            .tag => return errorf("import '{s}'.'{s}': imported tags are not supported by this ABI", .{ im.module, im.name }),
        }
    }

    out.* = .{ .funcs = funcs, .globals = globals, .globals_hi = globals_hi };
    return null;
}

/// Instantiate into `store`, running the start function if there is one.
///
/// Two distinct failure channels, and a caller must check both: a link/host failure returns an
/// `Error`, while a trapping start function returns NULL and sets `*trap_out`.
export fn wazmrt_linker_instantiate(
    l: ?*Linker,
    s: ?*Store,
    m: ?*CModule,
    out: ?*InstanceHandle,
    trap_out: ?*?*Trap,
) ?*Error {
    const lk = l orelse return errorf("wazmrt_linker_instantiate: linker is NULL", .{});
    const store = s orelse return errorf("wazmrt_linker_instantiate: store is NULL", .{});
    const cm = m orelse return errorf("wazmrt_linker_instantiate: module is NULL", .{});
    const out_p = out orelse return errorf("wazmrt_linker_instantiate: out is NULL", .{});

    // The slot is allocated FIRST so the arena has its final address before `allocator()` is
    // taken from it — see the warning on `InstanceSlot`.
    const slot = alloc.create(InstanceSlot) catch return errorf("out of memory", .{});
    slot.* = .{ .arena = std.heap.ArenaAllocator.init(alloc), .inst = undefined, .module = cm };
    const sa = slot.arena.allocator();

    var imports: interp.Instance.Imports = .{};
    if (resolveImports(lk, slot, cm, sa, &imports)) |msg| {
        slot.arena.deinit();
        alloc.destroy(slot);
        return msg;
    }

    slot.inst = interp.Instance.initWithImports(sa, &cm.inner, imports) catch |err| {
        slot.arena.deinit();
        alloc.destroy(slot);
        return errorf("instantiate: {s}", .{@errorName(err)});
    };

    slot.inst.runStart() catch |err| {
        if (trap_out) |p| p.* = slot.takeTrap(err);
        slot.inst.deinit();
        slot.arena.deinit();
        alloc.destroy(slot);
        return null; // a trap is not a host error
    };

    store.instances.append(alloc, slot) catch {
        slot.inst.deinit();
        slot.arena.deinit();
        alloc.destroy(slot);
        return errorf("out of memory", .{});
    };
    cm.live_instances += 1;
    out_p.* = .{ .id = Handle.make(store.id, @intCast(store.instances.items.len - 1)) };
    return null;
}

/// Snapshot a trap out of the interpreter, frames included, so it outlives the call.
fn trapFrom(inst: *interp.Instance, err: anyerror) ?*Trap {
    const t = alloc.create(Trap) catch return null;
    const msg = alloc.dupeZ(u8, @errorName(err)) catch {
        alloc.destroy(t);
        return null;
    };
    const src = inst.trapFrames();
    const frames = alloc.alloc(Frame, src.len) catch {
        alloc.free(msg);
        alloc.destroy(t);
        return null;
    };
    // `frameOffset` re-decodes one body to resolve a pc, so it needs scratch that dies here.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    for (src, frames) |f, *dst| {
        // `TrapFrame.pc` is an index into the decoded IR, NOT a byte offset. `frameOffset`
        // resolves it to a real module-relative position — the whole point of the number, since
        // it exists to be compared against `wasm-objdump` without rebasing. Null (a host frame,
        // or a pc one past the end) reports 0 rather than inventing a position.
        const off: u32 = if (inst.frameOffset(scratch.allocator(), f)) |o| o.module else 0;
        dst.* = .{ .func_index = f.func_index, .offset = off, .name = null };
    }
    t.* = .{ .msg = msg, .frames = frames };
    return t;
}

// ---------------------------------------------------------------------------------------
// Instance exports
// ---------------------------------------------------------------------------------------

/// Find an export by name, of a given kind, returning its index in that kind's space.
fn findExport(cm: *const CModule, name: []const u8, kind: root.types.ExternKind) ?u32 {
    for (cm.inner.exports) |e| {
        if (e.type.kind() == kind and std.mem.eql(u8, e.name, name)) return e.index;
    }
    return null;
}

fn spanOf(name: ?[*:0]const u8) []const u8 {
    return if (name) |n| std.mem.span(n) else "";
}

export fn wazmrt_instance_get_func(
    s: ?*Store,
    h: InstanceHandle,
    name: ?[*:0]const u8,
    out: ?*FuncHandle,
) bool {
    const store = s orelse return false;
    const islot = store.resolve(h.id, store.instances.items.len) orelse return false;
    const out_p = out orelse return false;
    const cm = store.instances.items[islot].module;
    const fi = findExport(cm, spanOf(name), .func) orelse return false;
    store.funcs.append(alloc, .{ .inst = islot, .index = fi }) catch return false;
    out_p.* = .{ .id = Handle.make(store.id, @intCast(store.funcs.items.len - 1)) };
    return true;
}

export fn wazmrt_instance_get_memory(
    s: ?*Store,
    h: InstanceHandle,
    name: ?[*:0]const u8,
    out: ?*MemoryHandle,
) bool {
    const store = s orelse return false;
    const islot = store.resolve(h.id, store.instances.items.len) orelse return false;
    const out_p = out orelse return false;
    const cm = store.instances.items[islot].module;
    const mi = findExport(cm, spanOf(name), .memory) orelse return false;
    if (mi >= store.instances.items[islot].inst.memories.len) return false;
    store.memories.append(alloc, .{ .inst = islot, .index = mi }) catch return false;
    out_p.* = .{ .id = Handle.make(store.id, @intCast(store.memories.items.len - 1)) };
    return true;
}

export fn wazmrt_instance_get_global(
    s: ?*Store,
    h: InstanceHandle,
    name: ?[*:0]const u8,
    out: ?*GlobalHandle,
) bool {
    const store = s orelse return false;
    const islot = store.resolve(h.id, store.instances.items.len) orelse return false;
    const out_p = out orelse return false;
    const cm = store.instances.items[islot].module;
    const gi = findExport(cm, spanOf(name), .global) orelse return false;
    if (gi >= store.instances.items[islot].inst.globals.len) return false;
    store.globals.append(alloc, .{ .inst = islot, .index = gi }) catch return false;
    out_p.* = .{ .id = Handle.make(store.id, @intCast(store.globals.items.len - 1)) };
    return true;
}

/// The reactor convention. A no-op returning NULL when `_initialize` is not exported.
export fn wazmrt_instance_initialize(s: ?*Store, h: InstanceHandle, trap_out: ?*?*Trap) ?*Error {
    const store = s orelse return errorf("wazmrt_instance_initialize: store is NULL", .{});
    const islot = store.resolve(h.id, store.instances.items.len) orelse
        return errorf("wazmrt_instance_initialize: invalid instance handle", .{});
    const slot = store.instances.items[islot];
    const fi = findExport(slot.module, "_initialize", .func) orelse return null;
    _ = slot.inst.invokeIndex(fi, &.{}) catch |err| {
        if (trap_out) |p| p.* = slot.takeTrap(err);
        return null;
    };
    return null;
}

// ---------------------------------------------------------------------------------------
// Calling exports
// ---------------------------------------------------------------------------------------

export fn wazmrt_func_type(s: ?*const Store, h: FuncHandle) ?*FuncType {
    const store = s orelse return null;
    const fslot = store.resolve(h.id, store.funcs.items.len) orelse return null;
    const r = store.funcs.items[fslot];
    const cm = store.instances.items[r.inst].module;
    const ft = cm.inner.funcType(r.index) orelse return null;

    const p = alloc.alloc(ValKind, ft.params.len) catch return null;
    for (ft.params, p) |vt, *dst| dst.* = valKindOf(vt) orelse {
        alloc.free(p);
        return null;
    };
    const res = alloc.alloc(ValKind, ft.results.len) catch {
        alloc.free(p);
        return null;
    };
    for (ft.results, res) |vt, *dst| dst.* = valKindOf(vt) orelse {
        alloc.free(p);
        alloc.free(res);
        return null;
    };
    const out = alloc.create(FuncType) catch {
        alloc.free(p);
        alloc.free(res);
        return null;
    };
    out.* = .{ .params = p, .results = res };
    return out;
}

export fn wazmrt_func_call(
    s: ?*Store,
    h: FuncHandle,
    args: ?[*]const Val,
    nargs: usize,
    results: ?[*]Val,
    nresults: usize,
    trap_out: ?*?*Trap,
) ?*Error {
    const store = s orelse return errorf("wazmrt_func_call: store is NULL", .{});
    const fslot = store.resolve(h.id, store.funcs.items.len) orelse
        return errorf("wazmrt_func_call: invalid function handle", .{});
    const r = store.funcs.items[fslot];
    const slot = store.instances.items[r.inst];
    const ft = slot.module.inner.funcType(r.index) orelse
        return errorf("wazmrt_func_call: function {d} is out of range", .{r.index});

    if (nargs != ft.params.len)
        return errorf("wazmrt_func_call: expected {d} argument(s), got {d}", .{ ft.params.len, nargs });
    if (nresults != ft.results.len)
        return errorf("wazmrt_func_call: expected room for {d} result(s), got {d}", .{ ft.results.len, nresults });

    // Slot buffers, sized by slot width rather than by count — a v128 needs two.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var nslots: usize = 0;
    for (ft.params) |vt| nslots += interp.slotWidth(vt);
    const slots = sa.alloc(interp.Value, nslots) catch return errorf("out of memory", .{});

    var si: usize = 0;
    for (ft.params, 0..) |vt, i| {
        const v = (args orelse return errorf("wazmrt_func_call: args is NULL", .{}))[i];
        const w = valToSlots(v, vt, slots[si..]) orelse
            return errorf("wazmrt_func_call: argument {d} has the wrong type", .{i});
        si += w;
    }

    const got = slot.inst.invokeIndex(r.index, slots) catch |err| {
        if (trap_out) |p| p.* = slot.takeTrap(err);
        return null; // trapped, but no host error
    };

    if (nresults > 0) {
        const dst = results orelse return errorf("wazmrt_func_call: results is NULL", .{});
        var gi: usize = 0;
        for (ft.results, 0..) |vt, i| {
            const w = interp.slotWidth(vt);
            if (gi + w > got.len) return errorf("wazmrt_func_call: result {d} is missing", .{i});
            _ = slotsToVal(got[gi..], vt, &dst[i]) orelse
                return errorf("wazmrt_func_call: result {d} has a type this ABI cannot carry", .{i});
            gi += w;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Linear memory
// ---------------------------------------------------------------------------------------

fn memoryOf(store: *Store, id: u64) ?*interp.Instance.Memory {
    const mslot = store.resolve(id, store.memories.items.len) orelse return null;
    const r = store.memories.items[mslot];
    const inst = &store.instances.items[r.inst].inst;
    if (r.index >= inst.memories.len) return null;
    return inst.memories[r.index];
}

export fn wazmrt_memory_data(s: ?*Store, h: MemoryHandle) ?[*]u8 {
    const store = s orelse return null;
    const mem = memoryOf(store, h.id) orelse return null;
    return mem.bytes.ptr;
}

export fn wazmrt_memory_data_size(s: ?*const Store, h: MemoryHandle) usize {
    const store = s orelse return 0;
    const mem = memoryOf(@constCast(store), h.id) orelse return 0;
    return mem.bytes.len;
}

export fn wazmrt_memory_size_pages(s: ?*const Store, h: MemoryHandle) u64 {
    const store = s orelse return 0;
    const mem = memoryOf(@constCast(store), h.id) orelse return 0;
    return mem.bytes.len / interp.page_size;
}

/// Bounds-checked, and the check is done in u64 BEFORE any pointer arithmetic: `offset + n` on a
/// 32-bit size would wrap and turn an out-of-range read into an in-range one.
export fn wazmrt_memory_read(s: ?*const Store, h: MemoryHandle, offset: u64, dst: ?*anyopaque, n: usize) bool {
    const store = s orelse return false;
    const mem = memoryOf(@constCast(store), h.id) orelse return false;
    const end = std.math.add(u64, offset, n) catch return false;
    if (end > mem.bytes.len) return false;
    if (n == 0) return true;
    const d = dst orelse return false;
    @memcpy(@as([*]u8, @ptrCast(d))[0..n], mem.bytes[@intCast(offset)..][0..n]);
    return true;
}

export fn wazmrt_memory_write(s: ?*Store, h: MemoryHandle, offset: u64, src: ?*const anyopaque, n: usize) bool {
    const store = s orelse return false;
    const mem = memoryOf(store, h.id) orelse return false;
    const end = std.math.add(u64, offset, n) catch return false;
    if (end > mem.bytes.len) return false;
    if (n == 0) return true;
    const sp = src orelse return false;
    @memcpy(mem.bytes[@intCast(offset)..][0..n], @as([*]const u8, @ptrCast(sp))[0..n]);
    return true;
}

// ---------------------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------------------

export fn wazmrt_global_get(s: ?*const Store, h: GlobalHandle, out: ?*Val) bool {
    const store = @constCast(s orelse return false);
    const gslot = store.resolve(h.id, store.globals.items.len) orelse return false;
    const out_p = out orelse return false;
    const r = store.globals.items[gslot];
    const slot = store.instances.items[r.inst];
    if (r.index >= slot.inst.globals.len) return false;
    if (r.index >= slot.module.inner.globals.len) return false;

    const vt = slot.module.inner.globals[r.index].content;
    // A v128 global keeps its high half in a parallel array, so it cannot be read as one slot.
    if (vt == .v128) {
        var two = [2]interp.Value{ slot.inst.globals[r.index], slot.inst.global_hi[r.index] };
        return slotsToVal(&two, vt, out_p) != null;
    }
    const one = [1]interp.Value{slot.inst.globals[r.index]};
    return slotsToVal(&one, vt, out_p) != null;
}

// =========================================================================================
// Tests — these drive the C entry points under `std.testing.allocator`, which fails on
// double-free and leaks. `tests/c_smoke.c` cannot substitute: on the real allocator a double
// free silently corrupts the freelist and the test still prints OK. It did, once.
// =========================================================================================

const testing = std.testing;

/// The smallest valid module: the 8-byte header.
const empty_module = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

test "abi version matches the header" {
    // The header is C and this is Zig; nothing but a test can hold them together. If this
    // fails, `include/wazmrt.h`'s WAZMRT_ABI_VERSION and `abi_version` here have drifted.
    try testing.expectEqual(@as(u32, 2), wazmrt_abi_version());
}

test "engine and store lifecycle" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    // A second store from the same engine gets a DIFFERENT id, which is what makes
    // cross-store handle rejection possible at all.
    const s2 = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s2);
    try testing.expect(s.id != s2.id);
}

test "a zeroed handle is invalid, not slot 0" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);

    // The likeliest host mistake: a handle that was never filled in. It must not name
    // anything, in any store, ever.
    try testing.expect(!wazmrt_instance_is_valid(s, .{ .id = 0 }));
    try testing.expect(!wazmrt_func_is_valid(s, .{ .id = 0 }));
    try testing.expect(!wazmrt_memory_is_valid(s, .{ .id = 0 }));
    try testing.expect(!wazmrt_global_is_valid(s, .{ .id = 0 }));
}

test "a handle is rejected by a different store" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const a = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(a);
    const b = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(b);

    // Slot 0 of store `a`, presented to store `b`. Once instances exist this is the case that
    // would otherwise hand out another store's resource.
    const h: InstanceHandle = .{ .id = Handle.make(a.id, 0) };
    try testing.expect(!wazmrt_instance_is_valid(b, h));
    // And `a` itself rejects it too, for now, because `a` owns no instances yet — validity is
    // decided by lookup, never by the handle asserting it.
    try testing.expect(!wazmrt_instance_is_valid(a, h));
}

test "handle encoding round-trips and never yields slot 0" {
    try testing.expectEqual(@as(?u32, null), Handle.slot(0));
    const id = Handle.make(7, 0);
    try testing.expectEqual(@as(u64, 7), Handle.storeId(id));
    try testing.expectEqual(@as(?u32, 0), Handle.slot(id));
    const id2 = Handle.make(7, 41);
    try testing.expectEqual(@as(?u32, 41), Handle.slot(id2));
}

test "module: decode, introspect, delete" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);

    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &empty_module, empty_module.len, &m);
    try testing.expect(err == null);
    defer wazmrt_module_delete(m);

    try testing.expectEqual(@as(usize, 0), wazmrt_module_export_count(m));
    try testing.expectEqual(@as(usize, 0), wazmrt_module_import_count(m));
    // Out of range writes nothing and says so.
    try testing.expect(!wazmrt_module_export(m, 0, null, null, null));
    try testing.expect(!wazmrt_module_import(m, 0, null, null, null, null, null));
}

test "module: garbage is refused with a message, and nothing leaks" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);

    const junk = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &junk, junk.len, &m);
    try testing.expect(err != null);
    defer wazmrt_error_delete(err);
    // A message, not an empty string: an embedder's only channel for the reason.
    try testing.expect(wazmrt_error_message(err).?[0] != 0);
    try testing.expect(!wazmrt_module_validate(e, &junk, junk.len));
}

test "module: NULL arguments are refused, not dereferenced" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    var m: *CModule = undefined;

    const e1 = wazmrt_module_new(null, &empty_module, empty_module.len, &m);
    defer wazmrt_error_delete(e1);
    try testing.expect(e1 != null);

    const e2 = wazmrt_module_new(e, null, 0, &m);
    defer wazmrt_error_delete(e2);
    try testing.expect(e2 != null);

    const e3 = wazmrt_module_new(e, &empty_module, empty_module.len, null);
    defer wazmrt_error_delete(e3);
    try testing.expect(e3 != null);

    // And the accessors tolerate a null module rather than trapping.
    try testing.expectEqual(@as(usize, 0), wazmrt_module_export_count(null));
    try testing.expect(!wazmrt_module_export(null, 0, null, null, null));
}

test "trap: message, frames, delete" {
    const t = wazmrt_trap_new("unreachable").?;
    try testing.expectEqualStrings("unreachable", std.mem.span(wazmrt_trap_message(t).?));
    // A host-made trap did not come out of guest code, so it reports no frames — and asking
    // for one writes nothing.
    try testing.expectEqual(@as(usize, 0), wazmrt_trap_frame_count(t));
    try testing.expect(!wazmrt_trap_frame(t, 0, null, null, null));
    wazmrt_trap_delete(t);

    // A null message is an empty string, never a null pointer.
    const t2 = wazmrt_trap_new(null).?;
    try testing.expectEqualStrings("", std.mem.span(wazmrt_trap_message(t2).?));
    wazmrt_trap_delete(t2);
}

/// `(module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))`
/// Hand-assembled so the test depends on nothing but the decoder.
const add_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // header
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export "add"
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
};

test "instantiate and call an export" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &add_module, add_module.len, &m) == null);
    defer wazmrt_module_delete(m);

    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    try testing.expect(trap == null);
    try testing.expect(wazmrt_instance_is_valid(s, inst));

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "add", &f));
    try testing.expect(wazmrt_func_is_valid(s, f));
    // A name that is not exported must not resolve to "some function".
    var missing: FuncHandle = .{ .id = 0 };
    try testing.expect(!wazmrt_instance_get_func(s, inst, "nope", &missing));

    const ft = wazmrt_func_type(s, f).?;
    defer wazmrt_functype_delete(ft);
    try testing.expectEqual(@as(usize, 2), wazmrt_functype_param_count(ft));
    try testing.expectEqual(@as(usize, 1), wazmrt_functype_result_count(ft));

    const args = [_]Val{
        .{ .kind = .i32, .of = .{ .i32 = 2 } },
        .{ .kind = .i32, .of = .{ .i32 = 3 } },
    };
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    try testing.expect(wazmrt_func_call(s, f, &args, 2, &res, 1, &trap) == null);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(i32, 5), res[0].of.i32);
}

test "call: arity and argument type are checked, not assumed" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &add_module, add_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "add", &f));

    const one = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 1 } }};
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};

    // Too few arguments.
    const e1 = wazmrt_func_call(s, f, &one, 1, &res, 1, &trap);
    defer wazmrt_error_delete(e1);
    try testing.expect(e1 != null);

    // Right count, wrong type: an f64 where an i32 is declared must be REFUSED, not
    // reinterpreted — reinterpreting is how a host gets a plausible wrong answer.
    const wrong = [_]Val{
        .{ .kind = .f64, .of = .{ .f64 = 1.0 } },
        .{ .kind = .i32, .of = .{ .i32 = 2 } },
    };
    const e2 = wazmrt_func_call(s, f, &wrong, 2, &res, 1, &trap);
    defer wazmrt_error_delete(e2);
    try testing.expect(e2 != null);
}

test "a module may be deleted while its instances live" {
    // This is #22 on the old ABI: `interp.Instance` holds `&module.inner`, so a module deleted
    // after instantiating was a use-after-free the moment anything was called. Here the module
    // is kept alive internally until the last instance goes, and the host cannot tell.
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &add_module, add_module.len, &m) == null);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "add", &f));

    wazmrt_module_delete(m); // host is done with it — the instance is not

    const args = [_]Val{
        .{ .kind = .i32, .of = .{ .i32 = 20 } },
        .{ .kind = .i32, .of = .{ .i32 = 22 } },
    };
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    try testing.expect(wazmrt_func_call(s, f, &args, 2, &res, 1, &trap) == null);
    try testing.expectEqual(@as(i32, 42), res[0].of.i32);

    wazmrt_store_delete(s); // last instance dies here, and so does the module
}

test "a handle from one store is refused by another" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const a = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(a);
    const b = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(b);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &add_module, add_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, a, m, &inst, &trap) == null);
    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(a, inst, "add", &f));

    // Store `b` owns nothing of the sort. Without the store id in the handle this would index
    // `b`'s empty lists — or, once `b` had its own instance, call the WRONG function.
    try testing.expect(!wazmrt_instance_is_valid(b, inst));
    try testing.expect(!wazmrt_func_is_valid(b, f));
    const args = [_]Val{
        .{ .kind = .i32, .of = .{ .i32 = 1 } },
        .{ .kind = .i32, .of = .{ .i32 = 1 } },
    };
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    const err = wazmrt_func_call(b, f, &args, 2, &res, 1, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
}

test "instantiate refuses a module with unresolved imports" {
    // Until host imports are wired (step 2c), an import must be refused BY NAME rather than
    // instantiated half-connected.
    const imports_module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x02, 0x0b, 0x01, 0x03, 'e', 'n', 'v', 0x03, 'l', 'o', 'g', 0x00, 0x00, // import env.log
    };
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &imports_module, imports_module.len, &m) == null);
    defer wazmrt_module_delete(m);

    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    const err = wazmrt_linker_instantiate(l, s, m, &inst, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    // The message must name the import, or the embedder has to guess which one.
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "log") != null);
}

/// ```wat
/// (module
///   (import "env" "peek" (func $peek (param i32) (result i32)))
///   (memory (export "mem") 1)
///   (func (export "run") (result i32) i32.const 4 call $peek))
/// ```
/// The shape every surveyed loader import has: the guest calls out, and the host must read the
/// guest's memory from inside the callback to do its job.
const peek_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // Two types: the import's (i32)->i32, and `run`'s ()->i32. They are NOT the same signature,
    // and reusing type 0 for `run` would silently give it a parameter it never reads.
    0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f,
    0x02, 0x0c, 0x01, 0x03, 'e', 'n', 'v', 0x04, 'p', 'e', 'e', 'k', 0x00, 0x00, // import env.peek
    0x03, 0x02, 0x01, 0x01, // func 1 : type 1 = ()->i32
    0x05, 0x03, 0x01, 0x00, 0x01, // memory 0: min 1 page
    0x07, 0x0d, 0x02, 0x03, 'r', 'u', 'n', 0x00, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x04, 0x10, 0x00, 0x0b, // i32.const 4; call 0
};

/// Reads 4 bytes of GUEST memory at the offset it was handed, and returns them. This is the
/// capability wasm-c-api structurally could not provide.
fn peekCb(env: ?*anyopaque, caller: *Caller, args: [*]const Val, nargs: usize, results: [*]Val, nresults: usize) callconv(.c) ?*Trap {
    _ = env;
    if (nargs != 1 or nresults != 1) return wazmrt_trap_new("peek: bad arity");
    var word: u32 = 0;
    if (!wazmrt_caller_read(caller, @intCast(args[0].of.i32), &word, 4)) return wazmrt_trap_new("peek: out of bounds");
    results[0] = .{ .kind = .i32, .of = .{ .i32 = @bitCast(word) } };
    return null;
}

fn trappingCb(env: ?*anyopaque, caller: *Caller, args: [*]const Val, nargs: usize, results: [*]Val, nresults: usize) callconv(.c) ?*Trap {
    _ = .{ env, caller, args, nargs, results, nresults };
    return wazmrt_trap_new("host said no");
}

fn i32Type(params: []const ValKind, results: []const ValKind) *FuncType {
    return wazmrt_functype_new(params.ptr, params.len, results.ptr, results.len).?;
}

test "host callback reads guest memory through the caller" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    const ft = i32Type(&.{.i32}, &.{.i32});
    defer wazmrt_functype_delete(ft);
    try testing.expect(wazmrt_linker_define_func(l, "env", "peek", ft, peekCb, null, null) == null);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &peek_module, peek_module.len, &m) == null);
    defer wazmrt_module_delete(m);

    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    try testing.expect(trap == null);

    // Plant a value at offset 4, which is where the guest asks the host to look.
    var mem: MemoryHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_memory(s, inst, "mem", &mem));
    try testing.expectEqual(@as(u64, 1), wazmrt_memory_size_pages(s, mem));
    const planted: u32 = 0xdeadbeef;
    try testing.expect(wazmrt_memory_write(s, mem, 4, &planted, 4));

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "run", &f));
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    try testing.expect(wazmrt_func_call(s, f, null, 0, &res, 1, &trap) == null);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(u32, 0xdeadbeef), @as(u32, @bitCast(res[0].of.i32)));

    // And the bounds check is real: one byte past the end must refuse, not read.
    const size = wazmrt_memory_data_size(s, mem);
    var scratch: u32 = 0;
    try testing.expect(!wazmrt_memory_read(s, mem, size - 3, &scratch, 4));
    // Wrapping arithmetic must not turn an out-of-range offset into an in-range one.
    try testing.expect(!wazmrt_memory_read(s, mem, std.math.maxInt(u64) - 1, &scratch, 4));
}

test "a host trap reaches the embedder with its own message" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    const ft = i32Type(&.{.i32}, &.{.i32});
    defer wazmrt_functype_delete(ft);
    try testing.expect(wazmrt_linker_define_func(l, "env", "peek", ft, trappingCb, null, null) == null);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &peek_module, peek_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "run", &f));

    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    // No host ERROR — the guest trapped — so both channels must be checked.
    try testing.expect(wazmrt_func_call(s, f, null, 0, &res, 1, &trap) == null);
    const t = trap orelse return error.TestExpectedTrap;
    defer wazmrt_trap_delete(t);
    // The host's own message, not a generic "HostTrap" the interpreter's error set would give.
    try testing.expectEqualStrings("host said no", std.mem.span(wazmrt_trap_message(t).?));
}

test "a host/guest signature disagreement is refused at link time" {
    // The guest declares (i32)->i32. Defining (i64)->i32 and binding anyway would have the
    // callback read an argument that was never passed — a segfault from a four-line module.
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    const wrong = i32Type(&.{.i64}, &.{.i32});
    defer wazmrt_functype_delete(wrong);
    try testing.expect(wazmrt_linker_define_func(l, "env", "peek", wrong, peekCb, null, null) == null);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &peek_module, peek_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    const err = wazmrt_linker_instantiate(l, s, m, &inst, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "peek") != null);

    // Arity disagreement is caught the same way.
    const short = i32Type(&.{}, &.{.i32});
    defer wazmrt_functype_delete(short);
    try testing.expect(wazmrt_linker_define_func(l, "env", "peek", short, peekCb, null, null) == null);
    const err2 = wazmrt_linker_instantiate(l, s, m, &inst, &trap);
    defer wazmrt_error_delete(err2);
    try testing.expect(err2 != null);
}

test "unknown imports as traps: links, then traps when called" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);
    try testing.expect(wazmrt_linker_define_unknown_imports_as_traps(l) == null);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &peek_module, peek_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    // Links despite `env.peek` being undefined — that is the whole point of the flag, and the
    // documented cost is that a typo becomes a runtime surprise instead of a link error.
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "run", &f));
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    try testing.expect(wazmrt_func_call(s, f, null, 0, &res, 1, &trap) == null);
    const t = trap orelse return error.TestExpectedTrap;
    defer wazmrt_trap_delete(t);
    try testing.expectEqualStrings("unknown import called", std.mem.span(wazmrt_trap_message(t).?));
}

test "delete functions tolerate NULL" {
    // C code deletes unconditionally in cleanup paths; every one of these must be a no-op
    // rather than a crash.
    wazmrt_engine_delete(null);
    wazmrt_store_delete(null);
    wazmrt_module_delete(null);
    wazmrt_trap_delete(null);
    wazmrt_error_delete(null);
    try testing.expect(wazmrt_error_message(null) == null);
    try testing.expect(wazmrt_trap_message(null) == null);
}
