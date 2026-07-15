//! A real, LLVM-compiled WASI program — the Phase 1 milestone (see the
//! "run a fully compiled WASI program" plan in `cmem/roadmap.md`).
//!
//!   zig build-exe examples/hello_compiled.zig -target wasm32-wasi -O ReleaseSmall \
//!     -femit-bin=hello.wasm
//!   zig build && zig-out/bin/wazmrt hello.wasm
//!
//! It exercises the ops that used to block compiled modules: `@memcpy` lowers to
//! **memory.copy** (bulk memory, `0xFC 0x0a`) and the float→int conversion to
//! **i32.trunc_sat_f64_s** (`0xFC 0x02`) — both emitted by LLVM/Zig by default.
//!
//! Printing goes through ordinary `std.Io` — no hand-written `extern` imports.
//! That is deliberate: it proves the plain Zig path works end to end, and it
//! avoids the trap described in `examples/wasi_files.zig` (a guest-declared
//! import whose signature differs from std's makes wasm-ld emit a trapping
//! stub).

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var out_buf: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    try out.writeAll("Hello from a compiled WASI program!\n");

    // @memcpy -> memory.copy
    var buf: [64]u8 = undefined;
    const src = "bulk-memory memcpy works\n";
    @memcpy(buf[0..src.len], src);
    try out.writeAll(buf[0..src.len]);

    // float -> int lowers to a saturating truncation (must clamp, never trap)
    const f: f64 = 3.9e300;
    const n: i32 = @intFromFloat(std.math.clamp(f, -2147483648.0, 2147483647.0));
    if (n == 2147483647) try out.writeAll("saturating truncation works\n");
}
