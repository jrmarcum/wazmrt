//! Freestanding `wasm32` entry surface. Building this proves the core runtime
//! compiles to WebAssembly (so wazmrt can be embedded *inside* another wasm
//! host via the `universalWasmLoader-*` loaders). It uses the wasm page
//! allocator instead of libc.
//!
//! The exported surface will grow to mirror the C ABI; for now it exposes the
//! ABI version and a decode-and-count entry that operates on wasm linear
//! memory the host has written the module bytes into.

const std = @import("std");
const root = @import("root.zig");

const gpa = std.heap.wasm_allocator;

/// Stable ABI version, so a host can verify compatibility after loading.
export fn wazmrt_abi_version() u32 {
    return root.abi_version;
}

/// Decode `len` bytes at `ptr` in linear memory and return the number of
/// top-level sections, or -1 on any decode failure.
export fn wazmrt_decode_section_count(ptr: [*]const u8, len: usize) i64 {
    var module = root.decode(gpa, ptr[0..len]) catch return -1;
    defer module.deinit();
    return @intCast(module.sections.len);
}
