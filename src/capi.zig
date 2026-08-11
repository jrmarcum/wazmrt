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

pub const Store = struct {
    id: u64,
    engine: *Engine,

    /// Does `id` name a live slot of `kind` in this store? The whole point of value handles:
    /// validity is *decided here*, never trusted from the caller.
    fn owns(self: *const Store, id: u64, len: usize) bool {
        if (Handle.storeId(id) != self.id) return false;
        const s = Handle.slot(id) orelse return false;
        return s < len;
    }
};

var next_store_id: std.atomic.Value(u64) = .init(1);

export fn wazmrt_store_new(e: ?*Engine) ?*Store {
    const eng = e orelse return null;
    const s = alloc.create(Store) catch return null;
    s.* = .{ .id = next_store_id.fetchAdd(1, .monotonic), .engine = eng };
    return s;
}

export fn wazmrt_store_delete(s: ?*Store) void {
    const store = s orelse return;
    alloc.destroy(store);
}

/// The four value-handle types. `extern struct` so the layout matches the header's
/// `typedef struct { uint64_t id; }` exactly.
pub const InstanceHandle = extern struct { id: u64 };
pub const FuncHandle = extern struct { id: u64 };
pub const MemoryHandle = extern struct { id: u64 };
pub const GlobalHandle = extern struct { id: u64 };

// Instances arrive with the linker in step 2c; until then a store owns none, so every handle is
// correctly invalid. The functions exist now because the *encoding* is what step 2a is for, and
// it is testable without an instance.
export fn wazmrt_instance_is_valid(s: ?*const Store, h: InstanceHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, 0);
}
export fn wazmrt_func_is_valid(s: ?*const Store, h: FuncHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, 0);
}
export fn wazmrt_memory_is_valid(s: ?*const Store, h: MemoryHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, 0);
}
export fn wazmrt_global_is_valid(s: ?*const Store, h: GlobalHandle) bool {
    const store = s orelse return false;
    return store.owns(h.id, 0);
}

// ---------------------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------------------

pub const CModule = struct {
    inner: Module,
};

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

export fn wazmrt_module_delete(m: ?*CModule) void {
    const cm = m orelse return;
    cm.inner.deinit();
    alloc.destroy(cm);
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
