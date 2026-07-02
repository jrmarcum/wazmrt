//! Stable C ABI for embedding wazmrt from any language via the
//! `universalWasmLoader-*` loaders (jvm, c, go, dotnet, dart, rs, py, v, zig,
//! js). The module is handed back as an opaque pointer so the internal layout
//! can evolve without breaking the ABI; only the functions and `wazmrt_status`
//! values below are contractual.
//!
//! This translation unit is the root of the C-library build artifact. It uses
//! a libc-free allocator so the produced static library carries no libc
//! dependency — smaller binaries and no toolchain requirement for embedders.
//! The core `wazmrt` library (root.zig) is likewise libc-free so it can also
//! target `wasm32-freestanding`.

const std = @import("std");
const root = @import("root.zig");

const gpa = std.heap.smp_allocator;

/// Result codes returned by the C ABI. 0 is success; negatives are errors.
pub const wazmrt_status = enum(c_int) {
    ok = 0,
    err_null = -1,
    err_oom = -2,
    err_decode = -3,
};

/// Returns the stable C ABI version. Embedders should check this matches what
/// they were built against.
export fn wazmrt_abi_version() u32 {
    return root.abi_version;
}

/// Returns a NUL-terminated human-readable library version string. The pointer
/// is static; do not free it.
export fn wazmrt_version_string() [*:0]const u8 {
    return root.version.ptr;
}

/// Decode a WebAssembly binary of `len` bytes. On success writes an owned
/// module handle to `out_module` and returns `ok`. The handle must later be
/// released with `wazmrt_module_free`.
export fn wazmrt_module_decode(
    bytes: [*]const u8,
    len: usize,
    out_module: ?*?*anyopaque,
) c_int {
    const out = out_module orelse return @intFromEnum(wazmrt_status.err_null);
    out.* = null;

    const module = gpa.create(root.Module) catch
        return @intFromEnum(wazmrt_status.err_oom);
    module.* = root.decode(gpa, bytes[0..len]) catch |e| {
        gpa.destroy(module);
        return @intFromEnum(switch (e) {
            error.OutOfMemory => wazmrt_status.err_oom,
            else => wazmrt_status.err_decode,
        });
    };
    out.* = module;
    return @intFromEnum(wazmrt_status.ok);
}

/// Returns the number of top-level sections in a decoded module, or 0 for a
/// null handle.
export fn wazmrt_module_section_count(handle: ?*anyopaque) usize {
    const module: *root.Module = @ptrCast(@alignCast(handle orelse return 0));
    return module.sections.len;
}

/// Frees a module handle previously produced by `wazmrt_module_decode`.
/// Passing null is a no-op.
export fn wazmrt_module_free(handle: ?*anyopaque) void {
    const module: *root.Module = @ptrCast(@alignCast(handle orelse return));
    module.deinit();
    gpa.destroy(module);
}
