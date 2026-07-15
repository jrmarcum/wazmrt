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
//! It calls `fd_write` directly rather than going through `std.Io`, because
//! Zig 0.16's new Io-model file writer doesn't yet drive WASI's `fd_write` for
//! stdout (it fails before issuing the syscall) — a guest-side toolchain gap,
//! not a runtime one.

const std = @import("std");

const Ciovec = extern struct { buf: [*]const u8, buf_len: u32 };
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: [*]const Ciovec, iovs_len: u32, nwritten: *u32) i32;

fn puts(s: []const u8) void {
    var iov = Ciovec{ .buf = s.ptr, .buf_len = @intCast(s.len) };
    var nw: u32 = 0;
    _ = fd_write(1, @ptrCast(&iov), 1, &nw);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    puts("Hello from a compiled WASI program!\n");

    // @memcpy -> memory.copy
    var buf: [64]u8 = undefined;
    const src = "bulk-memory memcpy works\n";
    @memcpy(buf[0..src.len], src);
    puts(buf[0..src.len]);

    // float -> int lowers to a saturating truncation (must clamp, never trap)
    const f: f64 = 3.9e300;
    const n: i32 = @intFromFloat(std.math.clamp(f, -2147483648.0, 2147483647.0));
    if (n == 2147483647) puts("saturating truncation works\n");
}
