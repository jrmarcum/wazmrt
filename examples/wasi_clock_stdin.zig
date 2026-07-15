//! WASI Phase 2 demo: clocks, `poll_oneoff` (sleep), and real stdin.
//!
//!   zig build-exe examples/wasi_clock_stdin.zig -target wasm32-wasi -O ReleaseSmall \
//!     -femit-bin=p2.wasm
//!   echo "hello stdin!" | zig-out/bin/wazmrt p2.wasm
//!
//! Calls the WASI imports directly (see `hello_compiled.zig` for why we don't
//! go through Zig 0.16's Io-model file writer on wasm32-wasi).

const std = @import("std");

const Ciovec = extern struct { buf: [*]const u8, buf_len: u32 };
const Iovec = extern struct { buf: [*]u8, buf_len: u32 };
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: [*]const Ciovec, n: u32, nw: *u32) i32;
extern "wasi_snapshot_preview1" fn fd_read(fd: i32, iovs: [*]const Iovec, n: u32, nr: *u32) i32;
extern "wasi_snapshot_preview1" fn clock_res_get(id: i32, res: *u64) i32;
extern "wasi_snapshot_preview1" fn clock_time_get(id: i32, prec: u64, t: *u64) i32;
extern "wasi_snapshot_preview1" fn poll_oneoff(in: *const anyopaque, out: *anyopaque, n: u32, ne: *u32) i32;

fn puts(s: []const u8) void {
    var iov = Ciovec{ .buf = s.ptr, .buf_len = @intCast(s.len) };
    var nw: u32 = 0;
    _ = fd_write(1, @ptrCast(&iov), 1, &nw);
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    var res: u64 = 0;
    if (clock_res_get(0, &res) == 0 and res > 0) puts("clock_res_get works\n");

    // poll_oneoff with a single relative clock subscription == sleep 20ms.
    var t0: u64 = 0;
    _ = clock_time_get(1, 0, &t0);
    var sub = [_]u8{0} ** 48; // subscription: userdata@0, tag@8, clockid@16, timeout@24, flags@40
    sub[8] = 0; // eventtype = clock
    std.mem.writeInt(u32, sub[16..20], 1, .little); // monotonic
    std.mem.writeInt(u64, sub[24..32], 20_000_000, .little); // 20ms, relative
    var ev = [_]u8{0} ** 32;
    var nev: u32 = 0;
    const rc = poll_oneoff(@ptrCast(&sub), @ptrCast(&ev), 1, &nev);
    var t1: u64 = 0;
    _ = clock_time_get(1, 0, &t1);
    if (rc == 0 and nev == 1 and (t1 - t0) >= 15_000_000) puts("poll_oneoff clock sleep works\n");

    var buf: [64]u8 = undefined;
    var iov = Iovec{ .buf = &buf, .buf_len = buf.len };
    var nr: u32 = 0;
    if (fd_read(0, @ptrCast(&iov), 1, &nr) == 0 and nr > 0) {
        puts("stdin echo: ");
        puts(buf[0..nr]);
    } else puts("stdin: EOF\n");
}
