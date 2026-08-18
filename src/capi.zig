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
const typematch = root.typematch;

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

/// Mirrors `wazmrt_feature_t`.
///
/// ⚠️ **THIS ENUM DRIFTED FROM `features.Feature` ONCE AND SHIPPED THAT WAY — see the comptime pin
/// below.** It stopped at `exceptions = 13` with `valid()` hardcoding `<= 13`, while `features.zig`
/// had `tail_call = 14` and `wazmrt.h` DECLARED `WAZMRT_FEATURE_TAIL_CALL = 14`. The result was a
/// toggle the header advertised that silently did nothing: `set_feature(TAIL_CALL, false)` returned
/// false and changed nothing, while `all_features(false)` — which counts with `features.count` —
/// *did* disable it. **Three spellings of one list, and the two that were written by hand were the
/// two that were wrong.**
const Feature = enum(c_int) {
    sign_extension = 0,
    saturating_float_to_int = 1,
    multi_value = 2,
    reference_types = 3,
    bulk_memory = 4,
    extended_const = 5,
    simd = 6,
    relaxed_simd = 7,
    threads = 8,
    multi_memory = 9,
    memory64 = 10,
    function_references = 11,
    gc = 12,
    exceptions = 13,
    tail_call = 14,
    multi_table = 15,
    custom_descriptors = 16,
    custom_page_sizes = 17,
    _,

    /// Bound DERIVED from `features.count`, never written out again: the literal that used to sit
    /// here is precisely what went stale.
    fn valid(self: Feature) bool {
        return @intFromEnum(self) >= 0 and @intFromEnum(self) < root.features.count;
    }
};

// ⚠️ COVERAGE PIN — the same device `features.zig` uses on `opcode.Op`, for the same reason. A
// proposal added to `features.Feature` must be added HERE and to `wazmrt_feature_t` in
// `include/wazmrt.h`, or the C ABI silently offers fewer switches than the engine enforces.
// Names are compared, not just the count: two lists of equal length can still disagree, and a
// value mismatch would make `@enumFromInt` below cast to the WRONG proposal — gating one feature
// while the embedder asked for another.
//
// If this fires: add the member here, add `WAZMRT_FEATURE_<NAME> = <n>` to the header, and check
// whether the new proposal belongs in `Set.incoherent`. Do NOT just bump a number.
comptime {
    const ours = @typeInfo(Feature).@"enum".fields;
    const theirs = @typeInfo(root.features.Feature).@"enum".fields;
    if (ours.len != theirs.len) @compileError(std.fmt.comptimePrint(
        "capi.Feature has {d} members, features.Feature has {d}. The C ABI must offer exactly the " ++
            "proposals the engine gates, and `include/wazmrt.h` must match both.",
        .{ ours.len, theirs.len },
    ));
    for (ours, theirs) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.value != b.value) @compileError(std.fmt.comptimePrint(
            "capi.Feature.{s} = {d} does not match features.Feature.{s} = {d}. A mismatch makes " ++
                "@enumFromInt gate a DIFFERENT proposal than the embedder selected.",
            .{ a.name, a.value, b.name, b.value },
        ));
    }
}

// ⚠️ F5 COMPOSITION PIN — the runtime feature set vs. Track 2c's COMPTIME gating.
//
// `-Dwat` / `-Dwasi` strip FRONT ENDS (the text assembler, the WASI host); a feature set
// restricts the wasm LANGUAGE. The rule between them is that **a runtime feature set can only
// ever be a SUBSET of what was compiled in** — an embedder must never be able to enable a
// proposal this build cannot honour.
//
// Today that holds because no proposal is compile-time removable: the default `Set` grants the
// whole enum in every configuration, so the subset relation is total. The assertion is here
// rather than in a unit test because `zig build features` compiles THIS FILE in all four
// `-Dwat`/`-Dwasi` combinations, which is the only place a build-dependent feature set would
// show up — and it would otherwise show up as `wazmrt_config_set_feature` returning true for a
// switch the build cannot back.
//
// If this fires: a proposal has become build-dependent. Decide what `set_feature` should answer
// for it in a build that lacks it — refusing loudly, as `wazmrt_module_new_wat` does for `-Dwat`,
// is this codebase's rule — and write that down before touching the assertion.
comptime {
    const all: root.features.Set = .{};
    if (!all.all()) @compileError(
        "the default feature set does not grant every proposal in this build configuration. A " ++
            "runtime feature set may only ever be a SUBSET of what was compiled in; a proposal " ++
            "that is compile-time removable needs an explicit answer from wazmrt_config_set_feature.",
    );
}

/// A template `wazmrt_engine_new_with_config` copies. The embedder keeps ownership.
///
/// ⚠️ **All five ceilings AND per-proposal gating are enforced.** The three ceilings that used to
/// be compile-time constants in `interp.zig` became per-instance fields in step 2e-b, so they do
/// what they say; the feature set became a real refusal on 2026-08-11 and was completed by Track F
/// (2026-08-18), which folded the gate into `validateWith` so the SAME call decides which
/// proposals may appear and which typing rules apply to them.
///
/// 🎓 **This comment claimed the opposite for a week after it stopped being true**, describing
/// gating as unimplemented and `set_feature(…, false)` as returning false — while the code six
/// lines below honoured it and four tests asserted so. It is left in the record as the third
/// instance of one failure: *a status written from an argument rather than from the code.* The
/// argument it preserved is still right, and is why the switch was made to work rather than made
/// to lie: accepting a request to disable a proposal and ignoring it hands an embedder a
/// **security control that controls nothing**.
pub const Config = struct {
    /// 0 means "leave at the default", per the header.
    max_memory_bytes: u64 = 0,
    max_table_elements: u64 = 0,
    max_gc_objects: u64 = 0,
    max_exception_boxes: u64 = 0,
    max_call_depth: u32 = 0,
    features: root.features.Set = .{},
};

export fn wazmrt_config_new() ?*Config {
    const c = alloc.create(Config) catch return null;
    c.* = .{};
    return c;
}

export fn wazmrt_config_delete(c: ?*Config) void {
    const cfg = c orelse return;
    alloc.destroy(cfg);
}

/// False only for an unrecognised feature. Disabling now genuinely gates: a module using a
/// disabled proposal is refused by `wazmrt_module_new` / `wazmrt_module_validate`.
export fn wazmrt_config_set_feature(c: ?*Config, f: Feature, enabled: bool) bool {
    const cfg = c orelse return false;
    if (!f.valid()) return false;
    cfg.features.set(@enumFromInt(@intFromEnum(f)), enabled);
    return true;
}

export fn wazmrt_config_get_feature(c: ?*Config, f: Feature, out: ?*bool) bool {
    const cfg = c orelse return false;
    if (!f.valid()) return false;
    if (out) |p| p.* = cfg.features.has(@enumFromInt(@intFromEnum(f)));
    return true;
}

export fn wazmrt_config_all_features(c: ?*Config, enabled: bool) void {
    const cfg = c orelse return;
    for (0..root.features.count) |i| cfg.features.set(@enumFromInt(@as(u8, @intCast(i))), enabled);
}

export fn wazmrt_config_set_max_memory_bytes(c: ?*Config, n: u64) void {
    if (c) |cfg| if (n != 0) {
        cfg.max_memory_bytes = n;
    };
}

export fn wazmrt_config_set_max_table_elements(c: ?*Config, n: u64) void {
    if (c) |cfg| if (n != 0) {
        cfg.max_table_elements = n;
    };
}

export fn wazmrt_config_set_max_gc_objects(c: ?*Config, n: u64) void {
    if (c) |cfg| if (n != 0) {
        cfg.max_gc_objects = n;
    };
}

export fn wazmrt_config_set_max_exception_boxes(c: ?*Config, n: u64) void {
    if (c) |cfg| if (n != 0) {
        cfg.max_exception_boxes = n;
    };
}

export fn wazmrt_config_set_max_call_depth(c: ?*Config, n: u32) void {
    if (c) |cfg| if (n != 0) {
        cfg.max_call_depth = n;
    };
}

/// Holds the configuration shared by the stores made from it, and must outlive them.
pub const Engine = struct {
    /// Distinguishes stores made from different engines in diagnostics; not a security
    /// boundary (the store id is what handles are checked against).
    id: u64,

    /// The `Io` the WASI host performs file and stdio operations through (owner, 2026-08-11:
    /// **single-threaded, one per engine**).
    ///
    /// Single-threaded is not a shortcut, it is the coherent choice: `wazmrt.h` documents that a
    /// store and everything reachable from it is single-threaded, so backing it with a thread
    /// pool would contradict the published contract — and a pool sized from the CPU count is real
    /// bytes in a library whose size is now gated. `init_single_threaded` spawns nothing
    /// (`async_limit = .nothing`).
    ///
    /// ⚠️ `io()` captures `&threaded`, so an Engine must never be moved after creation. It is
    /// always heap-allocated, and it outlives its stores by contract.
    threaded: std.Io.Threaded,

    /// Resource ceilings applied to every instance made through this engine. Enforced by the
    /// interpreter itself (`memory.grow` and `table.grow` re-check them), not merely at
    /// instantiation.
    max_memory_bytes: usize = interp.default_max_memory_bytes,
    max_table_elems: usize = interp.default_max_table_elems,
    max_gc_objects: usize = interp.default_max_gc_objects,
    max_exn_boxes: usize = interp.default_max_exn_boxes,
    max_call_depth: usize = interp.default_max_call_depth,

    /// Which proposals modules made through this engine may use. All-on by default, in which
    /// case the check short-circuits entirely.
    features: root.features.Set = .{},

    fn io(self: *Engine) std.Io {
        return self.threaded.io();
    }
};

var next_engine_id: std.atomic.Value(u64) = .init(1);

export fn wazmrt_engine_new() ?*Engine {
    const e = alloc.create(Engine) catch return null;
    var t = std.Io.Threaded.init_single_threaded;
    // The single-threaded template ships a `.failing` allocator; WASI path work needs a real one.
    t.allocator = alloc;
    e.* = .{ .id = next_engine_id.fetchAdd(1, .monotonic), .threaded = t };
    return e;
}

/// Returns NULL and sets *error for a config this build cannot honour.
///
/// Refusing beats repairing: silently enabling a dependency, or silently ignoring a ceiling,
/// would accept guests the embedder meant to constrain. The embedder still owns `cfg`.
export fn wazmrt_engine_new_with_config(c: ?*const Config, err_out: ?*?*Error) ?*Engine {
    const cfg = c orelse {
        if (err_out) |p| p.* = errorf("wazmrt_engine_new_with_config: config is NULL", .{});
        return null;
    };

    // A proposal layered on another cannot be enabled alone. REPORTED, not repaired: silently
    // enabling the dependency would accept modules the embedder meant to refuse.
    if (cfg.features.incoherent()) |pair| {
        if (err_out) |p| p.* = errorf(
            "incoherent config: {s} is enabled but {s}, which it is layered on, is not",
            .{ pair[0].name(), pair[1].name() },
        );
        return null;
    }

    const e = wazmrt_engine_new() orelse {
        if (err_out) |p| p.* = errorf("out of memory", .{});
        return null;
    };
    // Saturate rather than wrap: a ceiling larger than the address space is simply "no limit",
    // and truncating it would silently produce a TIGHTER cap than the embedder asked for.
    const cap = struct {
        fn u(n: u64) usize {
            return std.math.cast(usize, n) orelse std.math.maxInt(usize);
        }
    }.u;
    if (cfg.max_memory_bytes != 0) e.max_memory_bytes = cap(cfg.max_memory_bytes);
    if (cfg.max_table_elements != 0) e.max_table_elems = cap(cfg.max_table_elements);
    if (cfg.max_gc_objects != 0) e.max_gc_objects = cap(cfg.max_gc_objects);
    if (cfg.max_exception_boxes != 0) e.max_exn_boxes = cap(cfg.max_exception_boxes);
    if (cfg.max_call_depth != 0) e.max_call_depth = cfg.max_call_depth;
    e.features = cfg.features;
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
    /// The WASI host, if this module imported `wasi_snapshot_preview1`. Owned by the arena
    /// except for the directory handles, which `Wasi.deinit` closes.
    wasi: ?*WasiState = null,
    /// The linker that instantiated this, so a guest's `proc_exit` code can reach
    /// `wazmrt_wasi_exit_code`. ⚠️ Cleared by `wazmrt_linker_delete`, and the slot removes itself
    /// from the linker when IT dies — either object may legally outlive the other, so a raw
    /// pointer in one direction only would be a use-after-free waiting for the right order.
    linker: ?*Linker = null,
    /// A trap raised by a HOST callback, stashed here because the interpreter's error set can
    /// only say `HostTrap` — it cannot carry the host's message. Consumed by whoever reports the
    /// failure, so the embedder gets its own trap back instead of a generic one.
    pending_trap: ?*Trap = null,
    /// The store this slot belongs to. Needed wherever a value crosses the ABI:
    /// references are HANDLES issued by that store's table, so converting one
    /// requires knowing which store to ask. Set at creation; the store outlives
    /// its slots.
    store: *Store = undefined,

    /// Take the host trap if there is one, else make one from the interpreter's error.
    fn takeTrap(self: *InstanceSlot, err: anyerror) ?*Trap {
        if (self.pending_trap) |t| {
            self.pending_trap = null;
            return t;
        }
        return trapFrom(&self.inst, err);
    }

    /// A guest `proc_exit` unwinds as `HostTrap` with the code recorded — it is a CLEAN EXIT, not
    /// a failure, and reporting it as a trap would make every normal WASI command look like a
    /// crash. Returns true when the error was really an exit, having recorded the code.
    fn tookExit(self: *InstanceSlot, err: anyerror) bool {
        if (err != error.HostTrap) return false;
        // A `-Dwasi=false` build has no exits to take: no WASI host can be
        // installed, so `self.wasi` is always null.
        if (comptime !root.enable_wasi) return false;
        const w = self.wasi orelse return false;
        const code = w.wasi.exit_code orelse return false;
        // WASI's `proc_exit` takes a u32; the ABI reports int32_t, so 0xFFFFFFFF reads as -1 —
        // which is what a host shell would show. Bit-cast, never truncate.
        if (self.linker) |lk| lk.noteExit(@bitCast(code));
        // Consume any trap the unwind stashed, so it is not leaked or misreported.
        if (self.pending_trap) |t| {
            wazmrt_trap_delete(t);
            self.pending_trap = null;
        }
        return true;
    }
};

/// A func/memory/global handle names (instance slot, index within that instance) — never a raw
/// pointer, so nothing the host holds can outlive what it points at.
const Ref = struct { inst: u32, index: u32 };

pub const Store = struct {
    id: u64,
    engine: *Engine,
    /// The interpreter-side store every instance here joins, so a `funcref` means
    /// the same function to all of them. `define_instance` links one guest module
    /// to another's exports, which is exactly the case that needs it: without a
    /// shared store the importer would resolve the exporter's funcrefs against
    /// its OWN function index space. See `interp.Store`.
    refs: interp.Store = undefined,
    instances: std.ArrayList(*InstanceSlot) = .empty,
    funcs: std.ArrayList(Ref) = .empty,
    memories: std.ArrayList(Ref) = .empty,
    globals: std.ArrayList(Ref) = .empty,
    /// Interned INTERNAL reference values the host has been shown, so a
    /// `funcref`/`externref` crossing the ABI is a HANDLE like every other value
    /// kind here — not the interpreter's raw encoding.
    ///
    /// ⚠️ **This was a raw pass-through, and it was the last hole in the
    /// value-handle model.** Instances, funcs, memories and globals have been
    /// `(store_id << 32) | (slot+1)`, validated by lookup, since ABI 2 — the
    /// header's whole premise is dropping the object model so the bug class is
    /// *inexpressible rather than policed*. References were the one kind still
    /// handed over raw, which meant the interpreter's private encoding leaked
    /// across the boundary: bit 63 marks an i31, bit 62 a host reference,
    /// all-ones is null, and a structured high half is an (owner, index) pair.
    /// A host that passed back exactly what it got was fine; nothing enforced
    /// that, and there was no `is_valid` for refs as there is for the rest. **An
    /// undocumented forbidden value space is an interop bug before it is a
    /// security one.**
    ///
    /// Boxing is complete here precisely because the ABI has **no API for a host
    /// to CREATE a reference** — the host only ever sees handles this table
    /// issued, so an inbound value is always a lookup and an unknown one is
    /// refused rather than guessed.
    ext_refs: std.ArrayList(interp.Value) = .empty,

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

    /// Hand the host a HANDLE for an internal reference value.
    ///
    /// Null maps to handle 0, which is invalid-by-construction everywhere else
    /// in this ABI (slot 0 is never used) — so a `memset`-zeroed `wazmrt_val_t`
    /// is a null reference rather than a wild one, the same trick the other
    /// handle kinds already play.
    ///
    /// Interned by value, so the same reference always yields the same handle:
    /// a host comparing two handles for equality gets the answer it expects, and
    /// returning one reference in a loop does not grow the table.
    fn boxRef(self: *Store, v: interp.Value) ?u64 {
        if (v == interp.null_ref) return 0;
        for (self.ext_refs.items, 0..) |e, i| {
            if (e == v) return Handle.make(self.id, @intCast(i));
        }
        // Bounded like every other guest-driven table here (`max_gc_objects`,
        // `exn_store`): a guest that returns a fresh reference per call must not
        // be able to grow host memory without limit.
        if (self.ext_refs.items.len >= max_ext_refs) return null;
        self.ext_refs.append(alloc, v) catch return null;
        return Handle.make(self.id, @intCast(self.ext_refs.items.len - 1));
    }

    /// The internal reference value a host handle names, or null if it names
    /// none — a handle from another store, a stale one, or a value the host
    /// invented. **Refused, never reinterpreted.**
    fn unboxRef(self: *const Store, h: u64) ?interp.Value {
        if (h == 0) return interp.null_ref;
        const i = self.resolve(h, self.ext_refs.items.len) orelse return null;
        return self.ext_refs.items[i];
    }
};

/// Ceiling on distinct references handed across the C ABI per store. Generous —
/// a real embedder holds a handful — and finite, which is the point.
const max_ext_refs: usize = 1 << 20;

var next_store_id: std.atomic.Value(u64) = .init(1);

export fn wazmrt_store_new(e: ?*Engine) ?*Store {
    const eng = e orelse return null;
    const s = alloc.create(Store) catch return null;
    s.* = .{ .id = next_store_id.fetchAdd(1, .monotonic), .engine = eng };
    s.refs = .init(alloc);
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
        // Before the arena goes: `Wasi.deinit` closes the preopened directory handles it owns,
        // which are OS resources the arena knows nothing about.
        if (comptime root.enable_wasi) if (slot.wasi) |w| w.wasi.deinit();
        // Symmetric to `wazmrt_linker_delete`: drop the linker's reference to us first.
        if (slot.linker) |lk| {
            for (lk.slots.items, 0..) |cand, k| {
                if (cand == slot) {
                    _ = lk.slots.swapRemove(k);
                    break;
                }
            }
        }
        slot.arena.deinit();
        releaseModule(slot.module);
        alloc.destroy(slot);
    }
    // After every instance is gone: `Instance.deinit` tombstones its slot here.
    store.refs.deinit();
    store.instances.deinit(alloc);
    store.funcs.deinit(alloc);
    store.memories.deinit(alloc);
    store.globals.deinit(alloc);
    store.ext_refs.deinit(alloc);
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
export fn wazmrt_ref_is_valid(s: ?*const Store, ref: u64) bool {
    const st = s orelse return false;
    return st.unboxRef(ref) != null;
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
    const eng = e orelse return errorf("wazmrt_module_new: engine is NULL", .{});
    const out_p = out orelse return errorf("wazmrt_module_new: out is NULL", .{});
    const src = (bytes orelse return errorf("wazmrt_module_new: bytes is NULL", .{}))[0..len];

    var m = Module.decode(alloc, src) catch |err| {
        return errorf("failed to decode module: {s}", .{@errorName(err)});
    };
    errdefer m.deinit();

    // A disabled proposal makes the module INVALID — refused wholly, before anything executes.
    //
    // 🔑 **One call, not two (F1r).** This used to gate with `firstViolation` and then validate
    // with `root.validate` — i.e. with EVERY feature on — so the engine's set chose which
    // proposals were admissible while the all-features rules chose what they MEANT. With
    // `custom_descriptors` off, `br_on_cast` was still typed by the relaxed custom-descriptors
    // rule, and no gating test could see it because the instruction is present either way.
    // `validateWith` gates and types from the same set, so the two cannot disagree.
    root.validateWith(alloc, &m, eng.features) catch |err| {
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
    // A refused proposal is reported FIRST and by NAME. "you disabled this" is actionable;
    // letting it fall through to the generic "invalid module: DisabledProposal" would tell the
    // embedder that the module is broken when what actually happened is that they refused it.
    if (site.disabled_proposal) |f| {
        return errorf("module uses the '{s}' proposal, which this engine has disabled", .{f.name()});
    }
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
    const eng = e orelse return false;
    const src = (bytes orelse return false)[0..len];
    var m = Module.decode(alloc, src) catch return false;
    defer m.deinit();
    // Must answer the same question `wazmrt_module_new` does, gating included — a `validate` that
    // said yes to a module `new` would refuse is worse than not having it. Sharing ONE call is
    // what makes that true by construction rather than by two sites being kept in step.
    root.validateWith(alloc, &m, eng.features) catch return false;
    return true;
}

/// Deferred when instances still hold it — see `CModule`. The caller must not touch the pointer
/// afterwards either way, so the deferral is invisible.
export fn wazmrt_module_delete(m: ?*CModule) void {
    const cm = m orelse return;
    cm.deleted = true;
    if (cm.live_instances == 0) freeModule(cm);
}

// ---------------------------------------------------------------------------------------
// WebAssembly text (`.wat`)
// ---------------------------------------------------------------------------------------
//
// The differentiator: an embedder can run a `.wat` with no external toolchain — no `wat2wasm`
// process, no temp file, no build step. ⚠️ The saving is a PIPELINE, not decode time. Parsing
// text costs more per module than decoding a binary, so a module run repeatedly is still better
// assembled once and cached — which is what `wazmrt_wat_to_wasm` is for.

/// The refusal a `-Dwat=false` build gives for every text entry point (Track 2c).
///
/// ⚠️ **Loud, not silent.** A gated-out feature that returns "success with
/// nothing done" is the canonical fall-through failure this codebase refuses
/// everywhere else: the embedder would get a NULL module, or a linker with no
/// WASI in it, and discover the cause at run time in the guest. The message
/// names the build flag, because the caller cannot see our build options and
/// "unsupported" alone would send them looking in the wrong place.
fn featureDisabled(
    comptime fn_name: []const u8,
    comptime what: []const u8,
    comptime flag: []const u8,
) ?*Error {
    return errorf(fn_name ++ ": this build has " ++ what ++
        " compiled out (-D" ++ flag ++ "=false); rebuild with -D" ++ flag ++ "=true", .{});
}

/// Assemble text to a binary the caller owns and frees with `wazmrt_bytes_delete`.
export fn wazmrt_wat_to_wasm(
    text: ?[*]const u8,
    len: usize,
    out: ?*[*]u8,
    out_len: ?*usize,
) ?*Error {
    if (comptime !root.enable_wat) return featureDisabled("wazmrt_wat_to_wasm", "the WAT text assembler", "wat");
    const src = (text orelse return errorf("wazmrt_wat_to_wasm: text is NULL", .{}))[0..len];
    const out_p = out orelse return errorf("wazmrt_wat_to_wasm: out is NULL", .{});
    const out_len_p = out_len orelse return errorf("wazmrt_wat_to_wasm: out_len is NULL", .{});

    // The assembler allocates freely into an arena; the result is copied out so the caller owns
    // one flat buffer it can free with one call, rather than a graph it cannot see.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const wasm = root.wat.assemble(arena.allocator(), src) catch |err| {
        return errorf("failed to assemble wat: {s}", .{@errorName(err)});
    };
    const owned = alloc.dupe(u8, wasm) catch return errorf("out of memory", .{});
    out_p.* = owned.ptr;
    out_len_p.* = owned.len;
    return null;
}

/// Free a buffer this library produced. Only ever call it on such a buffer.
export fn wazmrt_bytes_delete(bytes: ?[*]u8, len: usize) void {
    const p = bytes orelse return;
    alloc.free(p[0..len]);
}

/// `wazmrt_module_new` for text: assemble, then decode and validate the result.
export fn wazmrt_module_new_wat(
    e: ?*Engine,
    text: ?[*]const u8,
    len: usize,
    out: ?**CModule,
) ?*Error {
    if (comptime !root.enable_wat) return featureDisabled("wazmrt_module_new_wat", "the WAT text assembler", "wat");
    var bin: [*]u8 = undefined;
    var bin_len: usize = 0;
    if (wazmrt_wat_to_wasm(text, len, &bin, &bin_len)) |err| return err;
    defer wazmrt_bytes_delete(bin, bin_len);
    // Decoding the ASSEMBLED bytes, not trusting the assembler: a module wazmrt produced still
    // goes through the same validation an untrusted one does.
    return wazmrt_module_new(e, bin, bin_len, out);
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
fn valToSlots(st: *Store, v: Val, want: root.types.ValType, slots: []interp.Value) ?u32 {
    const k = valKindOf(want) orelse return null;
    if (v.kind != k) return null;
    switch (want) {
        .i32 => slots[0] = interp.i32Value(v.of.i32),
        .i64 => slots[0] = interp.i64Value(v.of.i64),
        .f32 => slots[0] = interp.f32Value(v.of.f32),
        .f64 => slots[0] = interp.f64Value(v.of.f64),
        .funcref, .externref => slots[0] = st.unboxRef(v.of.ref) orelse return null,
        .v128 => {
            // Low half first, matching how the interpreter stacks a vector.
            slots[0] = std.mem.readInt(u64, v.of.v128[0..8], .little);
            slots[1] = std.mem.readInt(u64, v.of.v128[8..16], .little);
        },
        else => return null,
    }
    return interp.slotWidth(want);
}

fn slotsToVal(st: *Store, slots: []const interp.Value, got: root.types.ValType, out: *Val) ?u32 {
    const k = valKindOf(got) orelse return null;
    out.kind = k;
    switch (got) {
        .i32 => out.of.i32 = interp.asI32(slots[0]),
        .i64 => out.of.i64 = interp.asI64(slots[0]),
        .f32 => out.of.f32 = interp.asF32(slots[0]),
        .f64 => out.of.f64 = interp.asF64(slots[0]),
        .funcref, .externref => out.of.ref = st.boxRef(slots[0]) orelse return null,
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
    /// Every export of an already-instantiated module, published under one namespace.
    instance: InstanceHandle,
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
            .global, .instance => {},
        }
    }
};

pub const Linker = struct {
    engine: *Engine,
    entries: std.ArrayList(Entry) = .empty,
    /// A copy of the embedder's WASI template, or null if `define_wasi` was never called.
    wasi: ?WasiConfig = null,
    /// Back otherwise-unsatisfied FUNCTION imports with a trapping stub.
    trap_unknown: bool = false,
    /// Set when a guest called `proc_exit`; read by `wazmrt_wasi_exit_code`.
    exit_code: ?i32 = null,
    /// Instances made by this linker, so their back-pointers can be cleared if it dies first.
    slots: std.ArrayList(*InstanceSlot) = .empty,

    /// Record a guest's exit code and detach the instance, which has finished with us.
    fn noteExit(self: *Linker, code: i32) void {
        self.exit_code = code;
    }

    /// A namespace published by `define_instance`, if any. Kept separate from `find` because an
    /// instance entry matches on the MODULE alone — every name under it comes from that
    /// instance's exports, not from our table.
    fn findInstance(self: *const Linker, module: []const u8) ?InstanceHandle {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (e.def == .instance and std.mem.eql(u8, e.module, module)) return e.def.instance;
        }
        return null;
    }

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
    // Detach every instance still pointing back here, or their `proc_exit` reporting would write
    // into freed memory.
    for (lk.slots.items) |s| s.linker = null;
    lk.slots.deinit(alloc);
    if (lk.wasi) |*w| w.deinit();
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

/// Publish every export of an already-instantiated module under `module`, so later modules can
/// import from it. The callee runs against ITS OWN instance, so it sees the exporter's memory
/// and globals — that is what makes this real linking rather than a copy.
export fn wazmrt_linker_define_instance(
    l: ?*Linker,
    module: ?[*:0]const u8,
    instance: InstanceHandle,
) ?*Error {
    const lk = l orelse return errorf("wazmrt_linker_define_instance: linker is NULL", .{});
    const mc = alloc.dupe(u8, spanOf(module)) catch return errorf("out of memory", .{});
    // The handle is stored unresolved: it is only meaningful against the store you later
    // instantiate into, and it is checked there. Storing a resolved pointer here would be a
    // dangling one the moment that store died.
    // A real zero-length allocation, not `&.{}`: `Entry.deinit` frees `name` unconditionally, and
    // the two must not disagree about whether it was ever allocated.
    const nc = alloc.dupe(u8, "") catch {
        alloc.free(mc);
        return errorf("out of memory", .{});
    };
    lk.entries.append(alloc, .{ .module = mc, .name = nc, .def = .{ .instance = instance } }) catch {
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
// WASI preview 1
// ---------------------------------------------------------------------------------------

const Preopen = struct {
    host: []u8,
    guest: []u8,
    read_only: bool,
    allow_symlink: bool,
};

/// A template the linker copies. Everything is owned here and duplicated on copy, so an
/// embedder can delete the config the moment `wazmrt_linker_define_wasi` returns.
pub const WasiConfig = struct {
    args: std.ArrayList([]u8) = .empty,
    env_names: std.ArrayList([]u8) = .empty,
    env_values: std.ArrayList([]u8) = .empty,
    preopens: std.ArrayList(Preopen) = .empty,
    inherit_stdout: bool = false,
    inherit_stderr: bool = false,
    inherit_stdin: bool = false,

    fn deinit(self: *WasiConfig) void {
        for (self.args.items) |a| alloc.free(a);
        for (self.env_names.items) |a| alloc.free(a);
        for (self.env_values.items) |a| alloc.free(a);
        for (self.preopens.items) |p| {
            alloc.free(p.host);
            alloc.free(p.guest);
        }
        self.args.deinit(alloc);
        self.env_names.deinit(alloc);
        self.env_values.deinit(alloc);
        self.preopens.deinit(alloc);
    }

    fn clone(self: *const WasiConfig) ?WasiConfig {
        var out: WasiConfig = .{
            .inherit_stdout = self.inherit_stdout,
            .inherit_stderr = self.inherit_stderr,
            .inherit_stdin = self.inherit_stdin,
        };
        for (self.args.items) |a| {
            const c = alloc.dupe(u8, a) catch {
                out.deinit();
                return null;
            };
            out.args.append(alloc, c) catch {
                alloc.free(c);
                out.deinit();
                return null;
            };
        }
        for (self.env_names.items, self.env_values.items) |n, v| {
            const cn = alloc.dupe(u8, n) catch {
                out.deinit();
                return null;
            };
            const cv = alloc.dupe(u8, v) catch {
                alloc.free(cn);
                out.deinit();
                return null;
            };
            out.env_names.append(alloc, cn) catch {
                out.deinit();
                return null;
            };
            out.env_values.append(alloc, cv) catch {
                out.deinit();
                return null;
            };
        }
        for (self.preopens.items) |p| {
            const ch = alloc.dupe(u8, p.host) catch {
                out.deinit();
                return null;
            };
            const cg = alloc.dupe(u8, p.guest) catch {
                alloc.free(ch);
                out.deinit();
                return null;
            };
            out.preopens.append(alloc, .{ .host = ch, .guest = cg, .read_only = p.read_only, .allow_symlink = p.allow_symlink }) catch {
                out.deinit();
                return null;
            };
        }
        return out;
    }
};

export fn wazmrt_wasi_config_new() ?*WasiConfig {
    const c = alloc.create(WasiConfig) catch return null;
    c.* = .{};
    return c;
}

export fn wazmrt_wasi_config_delete(c: ?*WasiConfig) void {
    const cfg = c orelse return;
    cfg.deinit();
    alloc.destroy(cfg);
}

export fn wazmrt_wasi_config_inherit_stdout(c: ?*WasiConfig) void {
    if (c) |cfg| cfg.inherit_stdout = true;
}
export fn wazmrt_wasi_config_inherit_stderr(c: ?*WasiConfig) void {
    if (c) |cfg| cfg.inherit_stderr = true;
}
export fn wazmrt_wasi_config_inherit_stdin(c: ?*WasiConfig) void {
    if (c) |cfg| cfg.inherit_stdin = true;
}

/// Replaces any previous argv. Strings are copied.
export fn wazmrt_wasi_config_set_args(c: ?*WasiConfig, argv: ?[*]const ?[*:0]const u8, n: usize) void {
    const cfg = c orelse return;
    for (cfg.args.items) |a| alloc.free(a);
    cfg.args.clearRetainingCapacity();
    const src = argv orelse return;
    for (0..n) |i| {
        const dup = alloc.dupe(u8, spanOf(src[i])) catch return;
        cfg.args.append(alloc, dup) catch alloc.free(dup);
    }
}

export fn wazmrt_wasi_config_set_env(
    c: ?*WasiConfig,
    names: ?[*]const ?[*:0]const u8,
    values: ?[*]const ?[*:0]const u8,
    n: usize,
) void {
    const cfg = c orelse return;
    for (cfg.env_names.items) |a| alloc.free(a);
    for (cfg.env_values.items) |a| alloc.free(a);
    cfg.env_names.clearRetainingCapacity();
    cfg.env_values.clearRetainingCapacity();
    const ns = names orelse return;
    const vs = values orelse return;
    for (0..n) |i| {
        const dn = alloc.dupe(u8, spanOf(ns[i])) catch return;
        const dv = alloc.dupe(u8, spanOf(vs[i])) catch {
            alloc.free(dn);
            return;
        };
        cfg.env_names.append(alloc, dn) catch {
            alloc.free(dn);
            alloc.free(dv);
            return;
        };
        cfg.env_values.append(alloc, dv) catch {
            alloc.free(dv);
            return;
        };
    }
}

/// 🔒 `read_only` narrows rights and propagates to the subtree; `allow_symlink` is what lets the
/// guest CREATE links, and it is OFF unless asked for — denying creation shrinks what an external
/// racer can repoint. Following a PRE-EXISTING link is unaffected.
export fn wazmrt_wasi_config_preopen_dir(
    c: ?*WasiConfig,
    host_path: ?[*:0]const u8,
    guest_path: ?[*:0]const u8,
    read_only: bool,
    allow_symlink: bool,
) ?*Error {
    const cfg = c orelse return errorf("wazmrt_wasi_config_preopen_dir: config is NULL", .{});
    const h = alloc.dupe(u8, spanOf(host_path)) catch return errorf("out of memory", .{});
    const g = alloc.dupe(u8, spanOf(guest_path)) catch {
        alloc.free(h);
        return errorf("out of memory", .{});
    };
    cfg.preopens.append(alloc, .{ .host = h, .guest = g, .read_only = read_only, .allow_symlink = allow_symlink }) catch {
        alloc.free(h);
        alloc.free(g);
        return errorf("out of memory", .{});
    };
    return null;
}

export fn wazmrt_linker_define_wasi(l: ?*Linker, c: ?*const WasiConfig) ?*Error {
    if (comptime !root.enable_wasi) return featureDisabled("wazmrt_linker_define_wasi", "the WASI preview-1 host", "wasi");
    const lk = l orelse return errorf("wazmrt_linker_define_wasi: linker is NULL", .{});
    const cfg = c orelse return errorf("wazmrt_linker_define_wasi: config is NULL", .{});
    if (lk.wasi) |*old| old.deinit();
    lk.wasi = cfg.clone() orelse return errorf("out of memory", .{});
    return null;
}

export fn wazmrt_wasi_exit_code(l: ?*const Linker, out: ?*i32) bool {
    const lk = l orelse return false;
    const code = lk.exit_code orelse return false;
    if (out) |p| p.* = code;
    return true;
}

/// Everything one instance's WASI host needs, all living in that instance's arena.
///
/// Empty in a `-Dwasi=false` build so `InstanceSlot.wasi: ?*WasiState` still has
/// a type, while every field that names `root.wasi.*` disappears with it. The
/// pointer is then always null — `wazmrt_linker_define_wasi` refuses before one
/// can be created — so the guarded use sites are unreachable as well as
/// unanalyzed.
const WasiState = if (!root.enable_wasi) struct {} else struct {
    wasi: root.wasi.Wasi,
    out_writer: std.Io.File.Writer,
    err_writer: std.Io.File.Writer,
    discard_out: std.Io.Writer.Discarding,
    discard_err: std.Io.Writer.Discarding,
};

/// Build the WASI host for one instance. `sa` is the instance arena, so nothing here needs an
/// explicit free beyond `Wasi.deinit` (which closes the preopened directories it owns).
fn initWasi(eng: *Engine, cfg: *const WasiConfig, sa: std.mem.Allocator) !*WasiState {
    const st = try sa.create(WasiState);
    const io = eng.io();

    const obuf = try sa.alloc(u8, 4096);
    const ebuf = try sa.alloc(u8, 4096);
    st.discard_out = std.Io.Writer.Discarding.init(obuf);
    st.discard_err = std.Io.Writer.Discarding.init(ebuf);
    st.out_writer = .init(.stdout(), io, obuf);
    st.err_writer = .init(.stderr(), io, ebuf);

    // Not inheriting means DISCARD, not "write to a broken handle": a guest that prints when the
    // embedder asked for no stdout should be silent, not fail.
    const out_iface = if (cfg.inherit_stdout) &st.out_writer.interface else &st.discard_out.writer;
    const err_iface = if (cfg.inherit_stderr) &st.err_writer.interface else &st.discard_err.writer;

    st.wasi = try root.wasi.Wasi.init(sa, io, out_iface, err_iface);
    errdefer st.wasi.deinit();

    for (cfg.preopens.items) |p| {
        // 🔒 Read-write does NOT include planting symlinks unless explicitly granted.
        const rights = if (p.read_only)
            root.wasi.readOnlyRights
        else if (p.allow_symlink) root.wasi.allRights else root.wasi.readWriteRights;
        _ = try st.wasi.addPreopen(p.host, p.guest, rights);
    }

    const args = try sa.alloc([]const u8, cfg.args.items.len);
    for (cfg.args.items, args) |src, *dst| dst.* = src;
    st.wasi.args = args;

    // `Wasi.environ` wants "KEY=VALUE" strings.
    const env = try sa.alloc([]const u8, cfg.env_names.items.len);
    for (cfg.env_names.items, cfg.env_values.items, env) |n, v, *dst| {
        dst.* = try std.fmt.allocPrint(sa, "{s}={s}", .{ n, v });
    }
    st.wasi.environ = env;

    return st;
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
        _ = slotsToVal(t.slot.store, args[si..], vt, &in[i]) orelse {
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
        _ = valToSlots(t.slot.store, out[i], vt, results[oi..]) orelse {
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
    store: *Store,
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
    const globals = sa.alloc(*interp.Instance.Global, nglobal) catch return errorf("out of memory", .{});

    // One matcher per link, so its module-pointer-keyed memo lives no longer than
    // the modules it names (see `typematch.Ctx`).
    var tm: typematch.Ctx = .init(sa);
    defer tm.deinit();

    var fi: usize = 0;
    var gi: usize = 0;
    for (cm.inner.imports) |im| {
        switch (im.type) {
            .func => |want| {
                // WASI is backed by the runtime's own host, not by a linker entry. Checked
                // first so an embedder cannot shadow a WASI syscall with a define_func of the
                // same name and have the two silently disagree about which one runs.
                // `comptime root.enable_wasi and` — not just a run-time guard: it
                // is what keeps `initWasi` UNREFERENCED in a `-Dwasi=false`
                // build, which is what actually keeps `wasi.zig` out of the
                // artifact. A run-time-only check would leave the whole host
                // linked in and gate nothing.
                if (comptime root.enable_wasi) if (lk.wasi != null and std.mem.eql(u8, im.module, "wasi_snapshot_preview1")) {
                    if (slot.wasi == null) {
                        slot.wasi = initWasi(lk.engine, &lk.wasi.?, sa) catch |err|
                            return errorf("wasi: {s}", .{@errorName(err)});
                    }
                    funcs[fi] = slot.wasi.?.wasi.hostFunc(im.name);
                    fi += 1;
                    continue;
                };
                const def = lk.find(im.module, im.name) orelse {
                    // A namespace published by `define_instance`. Explicit definitions win, so
                    // this is only consulted after the table misses.
                    if (lk.findInstance(im.module)) |h| {
                        const oi = store.resolve(h.id, store.instances.items.len) orelse
                            return errorf("import '{s}'.'{s}': the instance published as '{s}' does not belong to this store", .{ im.module, im.name, im.module });
                        const oslot = store.instances.items[oi];
                        const idx = findExport(oslot.module, im.name, .func) orelse
                            return errorf("import '{s}'.'{s}': the published instance exports no such function", .{ im.module, im.name });
                        // Same rule as for host callbacks: two declarations exist, so compare
                        // them rather than trusting that a shared name means a shared signature.
                        //
                        // ⚠️ Compare through `typematch`, NOT the two expanded signatures. Both
                        // sides are real wasm modules here, so a parameter may be a concrete
                        // `(ref $t)` — and that carries a MODULE-LOCAL type index, which made
                        // `a != b` compare two unrelated numbering schemes. It rejected valid
                        // links and, worse, accepted invalid ones whenever two different types
                        // happened to sit at the same index in their modules, handing the guest
                        // values of a type it never agreed to. This is the shipped embedder path,
                        // so it had the defect `wast.zig` was fixed for and no test covering it.
                        const want_ti = im.type_index orelse
                            return errorf("import '{s}'.'{s}': the declared import has no type index", .{ im.module, im.name });
                        const have_ti = oslot.module.inner.funcTypeIndex(idx) orelse
                            return errorf("import '{s}'.'{s}': the published export has no type", .{ im.module, im.name });
                        const compatible = tm.funcImportOk(&oslot.module.inner, have_ti, &cm.inner, want_ti) catch
                            return errorf("out of memory", .{});
                        if (!compatible)
                            return errorf("import '{s}'.'{s}': signature mismatch with the published instance", .{ im.module, im.name });
                        funcs[fi] = .{ .wasm = .{ .instance = &oslot.inst, .func_index = idx } };
                        fi += 1;
                        continue;
                    }
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
                    .instance => return errorf("import '{s}'.'{s}': namespace entry used as a function", .{ im.module, im.name }),
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
                // A published instance's exported global, bound as the SHARED CELL — a
                // `(mut i32)` the exporter writes is now visible here. It used to be read once
                // at link time and copied, so the importer held a snapshot that never changed:
                // the same defect `linking.wast` caught on the `.wast` path, on the embedder
                // path the corpus never reaches (R1's lesson, again).
                if (lk.find(im.module, im.name) == null) {
                    if (lk.findInstance(im.module)) |h| {
                        const oi = store.resolve(h.id, store.instances.items.len) orelse
                            return errorf("import '{s}'.'{s}': the instance published as '{s}' does not belong to this store", .{ im.module, im.name, im.module });
                        const oslot = store.instances.items[oi];
                        const idx = findExport(oslot.module, im.name, .global) orelse
                            return errorf("import '{s}'.'{s}': the published instance exports no such global", .{ im.module, im.name });
                        if (idx >= oslot.inst.globals.len)
                            return errorf("import '{s}'.'{s}': published global is out of range", .{ im.module, im.name });
                        globals[gi] = oslot.inst.globals[idx];
                        gi += 1;
                        continue;
                    }
                }
                const def = lk.find(im.module, im.name) orelse
                    return errorf("unresolved global import '{s}'.'{s}'", .{ im.module, im.name });
                const v = switch (def.*) {
                    .global => |g| g,
                    .func => return errorf("import '{s}'.'{s}' is declared as a global but defined as a function", .{ im.module, im.name }),
                    .instance => return errorf("import '{s}'.'{s}': namespace entry used as a value", .{ im.module, im.name }),
                };
                var two: [2]interp.Value = .{ 0, 0 };
                _ = valToSlots(store, v, want.content, &two) orelse
                    return errorf("import '{s}'.'{s}': global value has the wrong type", .{ im.module, im.name });
                // A host-defined constant needs a cell of its own, on the instance's arena so
                // it outlives every read the guest makes through it.
                const cell = sa.create(interp.Instance.Global) catch return errorf("out of memory", .{});
                cell.* = .{ .value = two[0], .hi = two[1] };
                globals[gi] = cell;
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

    out.* = .{
        .funcs = funcs,
        .globals = globals,
        // The engine's ceilings, carried per-instance so `memory.grow`/`table.grow` re-check
        // them at run time rather than only at instantiation.
        .max_memory_bytes = lk.engine.max_memory_bytes,
        .max_table_elems = lk.engine.max_table_elems,
        .max_gc_objects = lk.engine.max_gc_objects,
        .max_exn_boxes = lk.engine.max_exn_boxes,
        .max_call_depth = lk.engine.max_call_depth,
    };
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
    slot.* = .{ .arena = std.heap.ArenaAllocator.init(alloc), .inst = undefined, .module = cm, .store = store };
    const sa = slot.arena.allocator();

    var imports: interp.Instance.Imports = .{};
    if (resolveImports(lk, store, slot, cm, sa, &imports)) |msg| {
        slot.arena.deinit();
        alloc.destroy(slot);
        return msg;
    }

    imports.store = &store.refs;
    slot.inst.instantiateWithImports(sa, &cm.inner, imports) catch |err| {
        if (comptime root.enable_wasi) if (slot.wasi) |w| w.wasi.deinit();
        slot.arena.deinit();
        alloc.destroy(slot);
        return errorf("instantiate: {s}", .{@errorName(err)});
    };

    // The guest's memory only exists once the instance does, and every WASI call that touches a
    // buffer needs it — so this must happen after init and before anything can run.
    if (comptime root.enable_wasi) { if (slot.wasi) |w| { w.wasi.memory = slot.inst.memory0(); } }

    slot.inst.runStart() catch |err| {
        if (trap_out) |p| p.* = slot.takeTrap(err);
        slot.inst.deinit();
        slot.arena.deinit();
        alloc.destroy(slot);
        return null; // a trap is not a host error
    };

    slot.linker = lk;
    lk.slots.append(alloc, slot) catch {
        slot.inst.deinit();
        if (comptime root.enable_wasi) if (slot.wasi) |w| w.wasi.deinit();
        slot.arena.deinit();
        alloc.destroy(slot);
        return errorf("out of memory", .{});
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
        // The name section is optional, so null genuinely means "this guest was built stripped"
        // — which is what the header promises. Copied because the trap outlives the call and may
        // outlive the module the name is borrowed from.
        const nm: ?[:0]u8 = if (inst.module.funcName(f.func_index)) |n|
            alloc.dupeZ(u8, n) catch null
        else
            null;
        dst.* = .{ .func_index = f.func_index, .offset = off, .name = nm };
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
        const w = valToSlots(slot.store, v, vt, slots[si..]) orelse
            return errorf("wazmrt_func_call: argument {d} has the wrong type", .{i});
        si += w;
    }

    const got = slot.inst.invokeIndex(r.index, slots) catch |err| {
        if (slot.tookExit(err)) return null; // proc_exit — a clean finish, not a trap
        if (trap_out) |p| p.* = slot.takeTrap(err);
        return null; // trapped, but no host error
    };

    if (nresults > 0) {
        const dst = results orelse return errorf("wazmrt_func_call: results is NULL", .{});
        var gi: usize = 0;
        for (ft.results, 0..) |vt, i| {
            const w = interp.slotWidth(vt);
            if (gi + w > got.len) return errorf("wazmrt_func_call: result {d} is missing", .{i});
            _ = slotsToVal(slot.store, got[gi..], vt, &dst[i]) orelse
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
        var two = [2]interp.Value{ slot.inst.globals[r.index].value, slot.inst.globals[r.index].hi };
        return slotsToVal(slot.store, &two, vt, out_p) != null;
    }
    const one = [1]interp.Value{slot.inst.globals[r.index].value};
    return slotsToVal(slot.store, &one, vt, out_p) != null;
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

test "define_instance: a concrete (ref $t) import matches by TYPE, not by index" {
    // The `define_instance` path binds one guest module's import to another's export, so both
    // sides are real wasm modules and a parameter can be a concrete `(ref $t)` — which carries a
    // MODULE-LOCAL type index. Comparing the expanded signatures compared those indices, which is
    // two different numbering schemes: it rejected good links and accepted bad ones whenever two
    // unrelated types sat at the same index. Nothing covered this path, so both directions are
    // pinned here.
    const provider_wat =
        \\(module
        \\  (type $pair (func (param i32 i32) (result i32)))
        \\  (func $use (param (ref $pair)) (result i32) (i32.const 7))
        \\  (export "use" (func $use))
        \\)
    ;
    // Same type, reached through a DIFFERENT index (a padding type comes first). Must link.
    const good_wat =
        \\(module
        \\  (type $pad (func (result f64)))
        \\  (type $pair (func (param i32 i32) (result i32)))
        \\  (func (import "P" "use") (param (ref $pair)) (result i32))
        \\)
    ;
    // A DIFFERENT type at the SAME index the provider uses — the case raw index comparison
    // wrongly accepted, handing the guest a reference of a type it never agreed to.
    const bad_wat =
        \\(module
        \\  (type $other (func (param f32) (result i64)))
        \\  (func (import "P" "use") (param (ref $other)) (result i32))
        \\)
    ;

    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);

    var pm: *CModule = undefined;
    try testing.expect(wazmrt_module_new_wat(e, provider_wat, provider_wat.len, &pm) == null);
    defer wazmrt_module_delete(pm);

    const pl = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(pl);
    var pinst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(pl, s, pm, &pinst, &trap) == null);

    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);
    try testing.expect(wazmrt_linker_define_instance(l, "P", pinst) == null);

    var gm: *CModule = undefined;
    try testing.expect(wazmrt_module_new_wat(e, good_wat, good_wat.len, &gm) == null);
    defer wazmrt_module_delete(gm);
    var ginst: InstanceHandle = .{ .id = 0 };
    try testing.expect(wazmrt_linker_instantiate(l, s, gm, &ginst, &trap) == null);

    var bm: *CModule = undefined;
    try testing.expect(wazmrt_module_new_wat(e, bad_wat, bad_wat.len, &bm) == null);
    defer wazmrt_module_delete(bm);
    var binst: InstanceHandle = .{ .id = 0 };
    const err = wazmrt_linker_instantiate(l, s, bm, &binst, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
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

/// ```wat
/// (module
///   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
///   (memory (export "memory") 1)
///   (func (export "_start") i32.const 7 call $exit))
/// ```
const wasi_exit_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // types: 1 + (i32)->() is 4 + ()->() is 3 = 8 bytes of content
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
    // import: 1 + (1+22) + (1+9) + 1 + 1 = 36 = 0x24 bytes of content
    0x02, 0x24, 0x01, 0x16, 'w', 'a', 's', 'i', '_', 's', 'n', 'a', 'p', 's', 'h', 'o',
    't', '_', 'p', 'r', 'e', 'v', 'i', 'e', 'w', '1', 0x09, 'p', 'r', 'o', 'c', '_',
    'e', 'x', 'i', 't', 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, // func 1 : type 1 = ()->()
    0x05, 0x03, 0x01, 0x00, 0x01, // memory 0: min 1 page
    // export: 1 + (1+6) + 1 + 1 = 10 = 0x0a bytes of content
    0x07, 0x0a, 0x01, 0x06, '_', 's', 't', 'a', 'r', 't', 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x07, 0x10, 0x00, 0x0b, // i32.const 7; call 0
};

test "wasi: proc_exit is a clean finish, not a trap" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    const cfg = wazmrt_wasi_config_new().?;
    defer wazmrt_wasi_config_delete(cfg);
    // Deliberately NOT inheriting stdout: a guest that prints should be silent, not fail.
    const argv = [_]?[*:0]const u8{ "prog", "--flag" };
    wazmrt_wasi_config_set_args(cfg, &argv, argv.len);
    const en = [_]?[*:0]const u8{"KEY"};
    const ev = [_]?[*:0]const u8{"VALUE"};
    wazmrt_wasi_config_set_env(cfg, &en, &ev, 1);
    try testing.expect(wazmrt_linker_define_wasi(l, cfg) == null);

    // The config is the embedder's; deleting it now must not affect the linker's copy.
    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &wasi_exit_module, wasi_exit_module.len, &m) == null);
    defer wazmrt_module_delete(m);

    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    try testing.expect(trap == null);

    var code: i32 = -1;
    try testing.expect(!wazmrt_wasi_exit_code(l, &code)); // nothing has exited yet

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "_start", &f));
    // proc_exit unwinds as HostTrap internally. The embedder must see a normal return, or every
    // ordinary WASI command would look like a crash.
    try testing.expect(wazmrt_func_call(s, f, null, 0, null, 0, &trap) == null);
    try testing.expect(trap == null);
    try testing.expect(wazmrt_wasi_exit_code(l, &code));
    try testing.expectEqual(@as(i32, 7), code);
}

test "wasi: a module importing wasi without define_wasi is refused by name" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &wasi_exit_module, wasi_exit_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    const err = wazmrt_linker_instantiate(l, s, m, &inst, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "proc_exit") != null);
}

test "an instance outliving its linker does not write through a dangling pointer" {
    // Either object may legally be deleted first. The back-pointer is cleared on both paths, so
    // a later proc_exit has nowhere to report rather than corrupting freed memory.
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);

    const l = wazmrt_linker_new(e).?;
    const cfg = wazmrt_wasi_config_new().?;
    defer wazmrt_wasi_config_delete(cfg);
    try testing.expect(wazmrt_linker_define_wasi(l, cfg) == null);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &wasi_exit_module, wasi_exit_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    wazmrt_linker_delete(l); // gone first; the instance is still live

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "_start", &f));
    try testing.expect(wazmrt_func_call(s, f, null, 0, null, 0, &trap) == null);
    if (trap) |t| wazmrt_trap_delete(t);
}

test "config: the memory ceiling is enforced, not merely accepted" {
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);
    wazmrt_config_set_max_memory_bytes(cfg, 64 * 1024); // one page

    var cerr: ?*Error = null;
    const e = wazmrt_engine_new_with_config(cfg, &cerr).?;
    defer wazmrt_engine_delete(e);
    try testing.expect(cerr == null);

    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    // `peek_module` declares one page, which exactly fits the ceiling.
    const ft = i32Type(&.{.i32}, &.{.i32});
    defer wazmrt_functype_delete(ft);
    try testing.expect(wazmrt_linker_define_func(l, "env", "peek", ft, peekCb, null, null) == null);
    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &peek_module, peek_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    // Below the ceiling the same module must be REFUSED — otherwise the number is decoration.
    const tight = wazmrt_config_new().?;
    defer wazmrt_config_delete(tight);
    wazmrt_config_set_max_memory_bytes(tight, 4096);
    const e2 = wazmrt_engine_new_with_config(tight, &cerr).?;
    defer wazmrt_engine_delete(e2);
    const s2 = wazmrt_store_new(e2).?;
    defer wazmrt_store_delete(s2);
    const l2 = wazmrt_linker_new(e2).?;
    defer wazmrt_linker_delete(l2);
    try testing.expect(wazmrt_linker_define_func(l2, "env", "peek", ft, peekCb, null, null) == null);
    var m2: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e2, &peek_module, peek_module.len, &m2) == null);
    defer wazmrt_module_delete(m2);
    var inst2: InstanceHandle = .{ .id = 0 };
    const err = wazmrt_linker_instantiate(l2, s2, m2, &inst2, &trap);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
}

test "config: the three former constants are now accepted and applied" {
    // They were compile-time constants in interp.zig until 2e-b, and this ABI refused them
    // rather than pretending. They are per-instance fields now, so they must be accepted — and
    // the values must actually reach the instance, not just the Config.
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);
    wazmrt_config_set_max_gc_objects(cfg, 1000);
    wazmrt_config_set_max_exception_boxes(cfg, 2000);
    wazmrt_config_set_max_call_depth(cfg, 64);

    var cerr: ?*Error = null;
    const e = wazmrt_engine_new_with_config(cfg, &cerr).?;
    defer wazmrt_engine_delete(e);
    try testing.expect(cerr == null);
    try testing.expectEqual(@as(usize, 1000), e.max_gc_objects);
    try testing.expectEqual(@as(usize, 2000), e.max_exn_boxes);
    try testing.expectEqual(@as(usize, 64), e.max_call_depth);

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
    // The ceiling reached the interpreter, which is the only place it can do any work.
    const slot = s.instances.items[0];
    try testing.expectEqual(@as(usize, 1000), slot.inst.max_gc_objects);
    try testing.expectEqual(@as(usize, 2000), slot.inst.max_exn_boxes);
    try testing.expectEqual(@as(usize, 64), slot.inst.max_call_depth);
}

/// `(module (type (func (param v128))))` — declares a SIMD type and nothing else. A module can
/// need a proposal without ever executing one of its instructions, which is why gating looks at
/// types and not only at code.
const v128_type_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7b, 0x00, // type: (v128) -> ()
};

/// `(module (type (func (result i32 i32))))` — two results is the whole of multi-value.
const multi_value_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x00, 0x02, 0x7f, 0x7f,
};

/// Turn `f` off, along with anything layered on it.
///
/// The dependents have to go too, and that is the EMBEDDER's job by design: turning off `simd`
/// while `relaxed_simd` stays on is an incoherent config, and the engine reports it rather than
/// quietly repairing it. Repairing would mean an embedder who disabled SIMD still had relaxed
/// SIMD enabled — a config that does not mean what it says.
fn engineWithout(f: Feature) *Engine {
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);
    _ = wazmrt_config_set_feature(cfg, f, false);
    switch (f) {
        .simd => _ = wazmrt_config_set_feature(cfg, .relaxed_simd, false),
        .reference_types => {
            _ = wazmrt_config_set_feature(cfg, .function_references, false);
            _ = wazmrt_config_set_feature(cfg, .exceptions, false);
            _ = wazmrt_config_set_feature(cfg, .gc, false);
        },
        .function_references => _ = wazmrt_config_set_feature(cfg, .gc, false),
        else => {},
    }
    var cerr: ?*Error = null;
    const e = wazmrt_engine_new_with_config(cfg, &cerr);
    if (e == null) {
        if (cerr) |bad| {
            std.debug.print("engineWithout({s}): {s}\n", .{ @tagName(f), wazmrt_error_message(bad).? });
            wazmrt_error_delete(bad);
        }
        unreachable; // a test helper handing back a null engine would fail confusingly later
    }
    return e.?;
}

test "gating: a disabled proposal makes a module invalid" {
    const e = engineWithout(.simd);
    defer wazmrt_engine_delete(e);

    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &v128_type_module, v128_type_module.len, &m);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    // Names the proposal: "you disabled this" is actionable, "invalid module" is not.
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "simd") != null);
    // `validate` must answer the SAME question as `new`, gating included.
    try testing.expect(!wazmrt_module_validate(e, &v128_type_module, v128_type_module.len));

    // With SIMD on, the very same bytes are fine — so the refusal is the gate, not the module.
    const on = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(on);
    var m2: *CModule = undefined;
    try testing.expect(wazmrt_module_new(on, &v128_type_module, v128_type_module.len, &m2) == null);
    wazmrt_module_delete(m2);
}

test "gating: multi-value is detected from the type section" {
    const e = engineWithout(.multi_value);
    defer wazmrt_engine_delete(e);
    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &multi_value_module, multi_value_module.len, &m);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "multi_value") != null);
}

test "gating: NO false positives on a plain module" {
    // The failure mode that would make gating unusable: refusing modules that do not actually
    // use the proposal. `add_module` is pure WebAssembly 1.0, so it must load with EVERY
    // proposal turned off.
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);
    wazmrt_config_all_features(cfg, false);
    var cerr: ?*Error = null;
    const e = wazmrt_engine_new_with_config(cfg, &cerr).?;
    defer wazmrt_engine_delete(e);
    try testing.expect(cerr == null);

    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &add_module, add_module.len, &m);
    if (err) |bad| {
        defer wazmrt_error_delete(bad);
        std.debug.print("unexpected refusal: {s}\n", .{wazmrt_error_message(bad).?});
        return error.TestUnexpectedResult;
    }
    defer wazmrt_module_delete(m);

    // And it still runs, so gating did not disturb execution.
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);
    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "add", &f));
    const args = [_]Val{
        .{ .kind = .i32, .of = .{ .i32 = 2 } },
        .{ .kind = .i32, .of = .{ .i32 = 3 } },
    };
    var res = [_]Val{.{ .kind = .i32, .of = .{ .i32 = 0 } }};
    try testing.expect(wazmrt_func_call(s, f, &args, 2, &res, 1, &trap) == null);
    try testing.expectEqual(@as(i32, 5), res[0].of.i32);
}

/// `(module (table 1 funcref) (table 1 funcref))` — two tables is the whole of `multi_table`.
const two_table_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70, 0x00, 0x01,
};

test "gating: multi_table refuses two tables while KEEPING funcref" {
    const e = engineWithout(.multi_table);
    defer wazmrt_engine_delete(e);

    var m: *CModule = undefined;
    const err = wazmrt_module_new(e, &two_table_module, two_table_module.len, &m);
    defer wazmrt_error_delete(err);
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "multi_table") != null);
    try testing.expect(!wazmrt_module_validate(e, &two_table_module, two_table_module.len));

    // 🔑 THE POINT OF A SEPARATE FLAG. A ONE-table module still loads, so `funcref` and the table
    // machinery survive — gating this on `reference_types` instead would have refused this too,
    // and with it most of `proposals/threads/imports.wast`.
    const one_table_module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
    };
    var m2: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &one_table_module, one_table_module.len, &m2) == null);
    wazmrt_module_delete(m2);

    // And with the flag on, the same two-table bytes are fine — so the refusal is the gate.
    const on = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(on);
    var m3: *CModule = undefined;
    try testing.expect(wazmrt_module_new(on, &two_table_module, two_table_module.len, &m3) == null);
    wazmrt_module_delete(m3);
}

test "config: EVERY feature the header declares is actually settable" {
    // ⚠️ REGRESSION TEST FOR A SHIPPED DEFECT. `capi.Feature` stopped at `exceptions = 13` with
    // `valid()` hardcoding `<= 13`, so `set_feature(TAIL_CALL, …)` returned false and changed
    // nothing while `all_features(false)` — which counts with `features.count` — disabled it.
    // The header advertised a switch that did not exist.
    //
    // Loops over the whole enum rather than naming members: a test that listed them by hand
    // would have had exactly the same blind spot as the code it is checking.
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);
    for (0..root.features.count) |i| {
        const f: Feature = @enumFromInt(@as(c_int, @intCast(i)));
        try testing.expect(wazmrt_config_set_feature(cfg, f, false));
        var got = true;
        try testing.expect(wazmrt_config_get_feature(cfg, f, &got));
        try testing.expect(!got);
    }
    // One past the end is still refused, so the bound moved rather than vanishing.
    const past: Feature = @enumFromInt(@as(c_int, root.features.count));
    try testing.expect(!wazmrt_config_set_feature(cfg, past, false));
}

test "config: features round-trip, and an incoherent set is refused" {
    const cfg = wazmrt_config_new().?;
    defer wazmrt_config_delete(cfg);

    try testing.expect(wazmrt_config_set_feature(cfg, .simd, false));
    var on: bool = true;
    try testing.expect(wazmrt_config_get_feature(cfg, .simd, &on));
    try testing.expect(!on); // it really is off now
    try testing.expect(wazmrt_config_set_feature(cfg, .simd, true));

    // An unrecognised feature is false either way.
    try testing.expect(!wazmrt_config_set_feature(cfg, @enumFromInt(99), true));
    try testing.expect(!wazmrt_config_get_feature(cfg, @enumFromInt(99), &on));

    // GC rests on function-references. Enabling one without the other is REPORTED, not quietly
    // repaired — silently enabling the dependency would accept modules meant to be refused.
    try testing.expect(wazmrt_config_set_feature(cfg, .function_references, false));
    var cerr: ?*Error = null;
    try testing.expect(wazmrt_engine_new_with_config(cfg, &cerr) == null);
    const err = cerr orelse return error.TestExpectedError;
    defer wazmrt_error_delete(err);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(wazmrt_error_message(err).?), "incoherent") != null);
}

/// `(module (func (export "boom") unreachable))` plus a name section naming func 0 "boom_fn".
/// Hand-assembled so the test does not depend on a toolchain emitting names.
const named_trap_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x08, 0x01, 0x04, 'b', 'o', 'o', 'm', 0x00, 0x00, // export "boom"
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, // code: unreachable; end
    // Custom section "name". Payload = 5 bytes of `"name"` + a 12-byte subsection = 17 (0x11);
    // the subsection's own content is count(1) + index(1) + len(1) + 7 = 10 (0x0a).
    0x00, 0x11, 0x04, 'n', 'a', 'm', 'e',
    0x01, 0x0a, 0x01, 0x00, 0x07, 'b', 'o', 'o', 'm', '_', 'f', 'n',
};

test "trap frames carry the function name from the name section" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &named_trap_module, named_trap_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    var f: FuncHandle = .{ .id = 0 };
    try testing.expect(wazmrt_instance_get_func(s, inst, "boom", &f));
    try testing.expect(wazmrt_func_call(s, f, null, 0, null, 0, &trap) == null);
    const t = trap orelse return error.TestExpectedTrap;
    defer wazmrt_trap_delete(t);

    try testing.expect(wazmrt_trap_frame_count(t) >= 1);
    var fi: u32 = 0xffff_ffff;
    var off: u32 = 0xffff_ffff;
    var name: ?[*:0]const u8 = null;
    try testing.expect(wazmrt_trap_frame(t, 0, &fi, &off, &name));
    try testing.expectEqual(@as(u32, 0), fi);
    // NULL here would mean "stripped guest" per the header — this guest is not stripped, so a
    // null would be the header lying rather than a missing name.
    const got = name orelse return error.TestExpectedName;
    try testing.expectEqualStrings("boom_fn", std.mem.span(got));

    // Out-of-range writes nothing and says so.
    try testing.expect(!wazmrt_trap_frame(t, wazmrt_trap_frame_count(t), null, null, null));
}

test "a stripped guest reports no name, which is what NULL means" {
    const e = wazmrt_engine_new().?;
    defer wazmrt_engine_delete(e);
    const s = wazmrt_store_new(e).?;
    defer wazmrt_store_delete(s);
    const l = wazmrt_linker_new(e).?;
    defer wazmrt_linker_delete(l);

    // `add_module` carries no name section.
    var m: *CModule = undefined;
    try testing.expect(wazmrt_module_new(e, &add_module, add_module.len, &m) == null);
    defer wazmrt_module_delete(m);
    var inst: InstanceHandle = .{ .id = 0 };
    var trap: ?*Trap = null;
    try testing.expect(wazmrt_linker_instantiate(l, s, m, &inst, &trap) == null);

    const t = wazmrt_trap_new("synthetic").?;
    defer wazmrt_trap_delete(t);
    // A host-made trap has no guest stack at all, so there is nothing to name.
    try testing.expectEqual(@as(usize, 0), wazmrt_trap_frame_count(t));
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
