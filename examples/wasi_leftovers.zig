//! WASI Phase 4.3 demo: the ops that were `NOTSUP` stubs — timestamps,
//! preallocation, hard links.
//!
//!   zig build-exe examples/wasi_leftovers.zig -target wasm32-wasi -O ReleaseSmall \
//!     -femit-bin=lo.wasm
//!   wazmrt lo.wasm --dir <writable-dir>:/data
//!
//! Calls the WASI imports through `std.os.wasi` (see `wasi_files.zig` for why
//! hand-rolled externs are a trap). Prints ok/FAIL per op; cleans up after.

const std = @import("std");
const w = std.os.wasi;

const dir_fd: w.fd_t = 3;

fn puts(s: []const u8) void {
    var iov = w.ciovec_t{ .base = s.ptr, .len = s.len };
    var n: usize = 0;
    _ = w.fd_write(1, @ptrCast(&iov), 1, &n);
}
fn check(ok: bool, label: []const u8) void {
    puts(if (ok) "ok   " else "FAIL ");
    puts(label);
    puts("\n");
}

const all: w.rights_t = @bitCast(@as(u64, (1 << 29) - 1));

fn create(name: []const u8, contents: []const u8) w.fd_t {
    var fd: w.fd_t = -1;
    _ = w.path_open(dir_fd, .{}, name.ptr, name.len, .{ .CREAT = true, .TRUNC = true }, all, all, .{}, &fd);
    var iov = w.ciovec_t{ .base = contents.ptr, .len = contents.len };
    var n: usize = 0;
    _ = w.fd_write(fd, @ptrCast(&iov), 1, &n);
    return fd;
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    // --- fd_filestat_set_times: set mtime to a known value, read it back. ---
    {
        const fd = create("times.txt", "x");
        const target: w.timestamp_t = 1_000_000_000 * 1_000_000_000; // 2001-09-09, in ns
        const rc = w.fd_filestat_set_times(fd, 0, target, .{ .MTIM = true });
        var st: w.filestat_t = undefined;
        _ = w.fd_filestat_get(fd, &st);
        _ = w.fd_close(fd);
        // Filesystems store coarser granularity; accept within one second.
        const diff = if (st.mtim > target) st.mtim - target else target - st.mtim;
        check(rc == .SUCCESS and diff < 1_000_000_000, "fd_filestat_set_times sets mtime");
    }

    // --- path_filestat_set_times: same, addressed by path. ---
    {
        const fd = create("ptimes.txt", "y");
        _ = w.fd_close(fd);
        const target: w.timestamp_t = 1_100_000_000 * 1_000_000_000;
        const rc = w.path_filestat_set_times(dir_fd, .{ .SYMLINK_FOLLOW = true }, "ptimes.txt", 10, 0, target, .{ .MTIM = true });
        var st: w.filestat_t = undefined;
        _ = w.path_filestat_get(dir_fd, .{ .SYMLINK_FOLLOW = true }, "ptimes.txt", 10, &st);
        const diff = if (st.mtim > target) st.mtim - target else target - st.mtim;
        check(rc == .SUCCESS and diff < 1_000_000_000, "path_filestat_set_times sets mtime");
    }

    // --- fd_allocate: extend a short file; never shrink a longer one. ---
    {
        const fd = create("alloc.txt", "abc"); // 3 bytes
        const rc = w.fd_allocate(fd, 0, 100); // ensure >= 100 bytes
        var st: w.filestat_t = undefined;
        _ = w.fd_filestat_get(fd, &st);
        const grew = st.size == 100;
        const rc2 = w.fd_allocate(fd, 0, 50); // already >= 50: must NOT shrink
        var st2: w.filestat_t = undefined;
        _ = w.fd_filestat_get(fd, &st2);
        _ = w.fd_close(fd);
        check(rc == .SUCCESS and grew and rc2 == .SUCCESS and st2.size == 100, "fd_allocate extends, never shrinks");
    }

    // --- path_link: hard-link, then both names read the same content. ---
    {
        const fd = create("orig.txt", "shared");
        _ = w.fd_close(fd);
        const rc = w.path_link(dir_fd, .{}, "orig.txt", 8, dir_fd, "hard.txt", 8);
        // Read back through the new name.
        var rfd: w.fd_t = -1;
        _ = w.path_open(dir_fd, .{}, "hard.txt", 8, .{}, all, all, .{}, &rfd);
        var buf: [16]u8 = undefined;
        var iov = w.iovec_t{ .base = &buf, .len = buf.len };
        var n: usize = 0;
        _ = w.fd_read(rfd, @ptrCast(&iov), 1, &n);
        _ = w.fd_close(rfd);
        if (rc == .OPNOTSUPP) { // WASI's ENOTSUP == EOPNOTSUPP == 58
            // Hard links aren't implemented in Zig std on Windows (a std gap,
            // not a wazmrt one). On POSIX this must actually work.
            puts("skip path_link (ENOTSUP — Windows std gap)\n");
        } else {
            check(rc == .SUCCESS and std.mem.eql(u8, buf[0..n], "shared"), "path_link creates a working hard link");
        }
        _ = w.path_unlink_file(dir_fd, "hard.txt", 8);
    }

    // Clean up.
    _ = w.path_unlink_file(dir_fd, "times.txt", 9);
    _ = w.path_unlink_file(dir_fd, "ptimes.txt", 10);
    _ = w.path_unlink_file(dir_fd, "alloc.txt", 9);
    _ = w.path_unlink_file(dir_fd, "orig.txt", 8);
}
