//! WASI Phase 2 demo: clocks, `poll_oneoff` (sleep), and real stdin.
//!
//!   zig build-exe examples/wasi_clock_stdin.zig -target wasm32-wasi -O ReleaseSmall \
//!     -femit-bin=p2.wasm
//!   echo "hello stdin!" | zig-out/bin/wazmrt p2.wasm
//!
//! The WASI calls go through `std.os.wasi` rather than hand-written `extern`
//! declarations — see `examples/wasi_files.zig` for why that matters.

const std = @import("std");
const w = std.os.wasi;

fn puts(s: []const u8) void {
    var iov = w.ciovec_t{ .base = s.ptr, .len = s.len };
    var nw: usize = 0;
    _ = w.fd_write(1, @ptrCast(&iov), 1, &nw);
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    var res: w.timestamp_t = 0;
    if (w.clock_res_get(.REALTIME, &res) == .SUCCESS and res > 0) puts("clock_res_get works\n");

    // poll_oneoff with a single relative clock subscription == sleep 20ms.
    var t0: w.timestamp_t = 0;
    _ = w.clock_time_get(.MONOTONIC, 0, &t0);
    const sub = w.subscription_t{
        .userdata = 1,
        .u = .{ .tag = .CLOCK, .u = .{ .clock = .{
            .id = .MONOTONIC,
            .timeout = 20_000_000, // 20ms, relative
            .precision = 0,
            .flags = 0, // not ABSTIME
        } } },
    };
    var ev: w.event_t = undefined;
    var nev: usize = 0;
    const rc = w.poll_oneoff(&sub, &ev, 1, &nev);
    var t1: w.timestamp_t = 0;
    _ = w.clock_time_get(.MONOTONIC, 0, &t1);
    if (rc == .SUCCESS and nev == 1 and (t1 - t0) >= 15_000_000) puts("poll_oneoff clock sleep works\n");

    var buf: [64]u8 = undefined;
    var iov = w.iovec_t{ .base = &buf, .len = buf.len };
    var nr: usize = 0;
    if (w.fd_read(0, @ptrCast(&iov), 1, &nr) == .SUCCESS and nr > 0) {
        puts("stdin echo: ");
        puts(buf[0..nr]);
    } else puts("stdin: EOF\n");
}
