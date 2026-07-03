//! wazmrt — a fast, tiny WebAssembly runtime.
//!
//! This is the public library surface. It is dependency-free and compiles for
//! native targets as well as `wasm32-freestanding`, so wazmrt can host wasm on
//! a machine or be embedded *inside* another wasm host.

const std = @import("std");

pub const types = @import("types.zig");
pub const Reader = @import("Reader.zig");
pub const Module = @import("Module.zig");
pub const opcode = @import("opcode.zig");
pub const validate = @import("validate.zig").validate;
pub const interp = @import("interp.zig");
pub const Instance = interp.Instance;

/// Human-readable library version (keep in sync with build.zig.zon).
pub const version: [:0]const u8 = "0.1.0";

/// Stable C-ABI version for embedders (universalWasmLoader-*). Bump on any
/// breaking change to the exported C symbols.
pub const abi_version: u32 = 1;

/// Decode a WebAssembly binary into a `Module`. Caller owns the result and
/// must call `Module.deinit`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Module.Error!Module {
    return Module.decode(allocator, bytes);
}

test {
    // Pull in the tests declared across the core modules.
    std.testing.refAllDecls(@This());
    _ = Reader;
    _ = Module;
    _ = opcode;
    _ = @import("validate.zig");
    _ = interp;
}
