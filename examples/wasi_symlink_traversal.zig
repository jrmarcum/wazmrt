//! WASI symlink traversal — the security check for #17/4.3 (full traversal).
//! Verifies both that in-sandbox symlinks are FOLLOWED and that no symlink can
//! escape the preopen. The Windows manual counterpart to the POSIX-CI unit
//! tests (Zig std can't create symlinks on unprivileged Windows).
//!
//! Plant real NTFS symlinks (needs Developer Mode) inside a writable <dir>:
//!   mkdir -p <dir>/sub; echo in-sandbox-content > <dir>/sub/real.txt
//!   mkdir -p <outside>; echo SECRET-OUTSIDE > <outside>/secret.txt
//!   MSYS=winsymlinks:nativestrict ln -s sub                  <dir>/good
//!   MSYS=winsymlinks:nativestrict ln -s ../outside           <dir>/escape
//!   MSYS=winsymlinks:nativestrict ln -s <abs outside secret> <dir>/absesc
//!   MSYS=winsymlinks:nativestrict ln -s loop                 <dir>/loop
//! Then: wazmrt wasi_symlink_traversal.wasm --dir <dir>:/data  → five "ok" lines.
const std = @import("std");
const w = std.os.wasi;
const dir_fd: w.fd_t = 3;

fn puts(s: []const u8) void {
    var iov = w.ciovec_t{ .base = s.ptr, .len = s.len };
    var n: usize = 0;
    _ = w.fd_write(1, @ptrCast(&iov), 1, &n);
}
const all: w.rights_t = @bitCast(@as(u64, (1 << 29) - 1));

/// Open+read `path` following symlinks. Returns bytes read (0 = refused/empty).
fn readIt(path: []const u8, buf: []u8) usize {
    var fd: w.fd_t = -1;
    if (w.path_open(dir_fd, .{ .SYMLINK_FOLLOW = true }, path.ptr, path.len, .{}, all, all, .{}, &fd) != .SUCCESS)
        return 0;
    var iov = w.iovec_t{ .base = buf.ptr, .len = buf.len };
    var n: usize = 0;
    _ = w.fd_read(fd, @ptrCast(&iov), 1, &n);
    _ = w.fd_close(fd);
    return n;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var buf: [64]u8 = undefined;

    // 1. In-sandbox symlink dir is now FOLLOWED (the point of full traversal).
    {
        const n = readIt("good/real.txt", &buf);
        check(std.mem.eql(u8, buf[0..n], "in-sandbox-content\n"), "in-sandbox symlink followed");
    }
    // 2. Escaping symlink still REFUSED (handle-stack `..` can't rise above root).
    {
        const n = readIt("escape/secret.txt", &buf);
        check(n == 0, "escaping symlink refused");
    }
    // 3. Absolute symlink to a real host file must NOT read it — the absolute
    //    target is re-based to the preopen root, so it can't reach outside.
    {
        const n = readIt("absesc", &buf);
        check(std.mem.indexOf(u8, buf[0..n], "SECRET-OUTSIDE") == null, "absolute-target symlink cannot reach host file");
    }
    // 4. Self-cycle terminates (ELOOP), never hangs.
    {
        var fd: w.fd_t = -1;
        const rc = w.path_open(dir_fd, .{ .SYMLINK_FOLLOW = true }, "loop", 4, .{}, all, all, .{}, &fd);
        check(rc == .LOOP, "symlink cycle -> ELOOP");
    }
    // 5. path_readlink returns the raw target (no following).
    {
        var lb: [64]u8 = undefined;
        var n: usize = 0;
        const rc = w.path_readlink(dir_fd, "good", 4, &lb, lb.len, &n);
        check(rc == .SUCCESS and std.mem.eql(u8, lb[0..n], "sub"), "path_readlink returns the target");
    }
}

fn check(ok: bool, label: []const u8) void {
    puts(if (ok) "ok   " else "FAIL ");
    puts(label);
    puts("\n");
}
