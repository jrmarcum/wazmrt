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

// ---- wazmrt extension surface (include/wazmrt.h) --------------------------

/// Stable wazmrt C-ABI version; embedders verify it matches what they built on.
export fn wazmrt_abi_version() u32 {
    return root.abi_version;
}

/// Static, NUL-terminated library version string; do not free.
export fn wazmrt_version_string() [*:0]const u8 {
    return root.version.ptr;
}
