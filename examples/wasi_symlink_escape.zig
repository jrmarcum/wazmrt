//! Attempts to escape a preopen via symlinks — the manual Windows check for
//! known-issues #17 (the unit test in `src/wasi.zig` covers POSIX CI but skips
//! on an unprivileged Windows box, since Zig std can't create a symlink there).
//!
//! Set it up with real NTFS symlinks (git-bash makes copies by default; force
//! native links, which needs Developer Mode):
//!
//!   SB=/some/tmp
//!   mkdir -p $SB/data $SB/outside/secret
//!   echo OUTSIDE > $SB/outside/secret/data.txt
//!   echo in-sandbox > $SB/data/real.txt
//!   MSYS=winsymlinks:nativestrict ln -s $SB/outside/secret   $SB/data/dirlink
//!   MSYS=winsymlinks:nativestrict ln -s $SB/outside/secret/data.txt $SB/data/filelink
//!   zig build-exe examples/wasi_symlink_escape.zig -target wasm32-wasi -femit-bin=se.wasm
//!   wazmrt se.wasm --dir $SB/data:/data
//!
//! Expected (fixed): all three "ok" lines. A build before #17 prints "ESCAPED
//! via intermediate dir symlink" — it read the file outside the preopen.
//!
//! The harness plants, inside the preopened /data dir:
//!   dirlink   -> a directory outside the preopen (holding data.txt)
//!   filelink  -> a file outside the preopen
//! A correct sandbox must refuse both. If either read returns content, the
//! sandbox is broken and we print ESCAPED.
const std = @import("std");
const w = std.os.wasi;

const dir_fd: w.fd_t = 3;

fn puts(s: []const u8) void {
    var iov = w.ciovec_t{ .base = s.ptr, .len = s.len };
    var n: usize = 0;
    _ = w.fd_write(1, @ptrCast(&iov), 1, &n);
}

/// Try to open `path` (following symlinks) and read it. Returns true if it read
/// any bytes — i.e. the sandbox let us through.
fn tryRead(path: []const u8) bool {
    var fd: w.fd_t = -1;
    const rc = w.path_open(dir_fd, .{ .SYMLINK_FOLLOW = true }, path.ptr, path.len, .{}, all, all, .{}, &fd);
    if (rc != .SUCCESS) return false;
    var buf: [64]u8 = undefined;
    var iov = w.iovec_t{ .base = &buf, .len = buf.len };
    var n: usize = 0;
    _ = w.fd_read(fd, @ptrCast(&iov), 1, &n);
    _ = w.fd_close(fd);
    return n > 0;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // Intermediate-component escape: dirlink is a symlink to an outside dir.
    if (tryRead("dirlink/data.txt")) {
        puts("ESCAPED via intermediate dir symlink\n");
        return;
    }
    puts("ok   intermediate dir symlink refused\n");

    // Final-component escape: filelink is a symlink to an outside file.
    if (tryRead("filelink")) {
        puts("ESCAPED via final file symlink\n");
        return;
    }
    puts("ok   final file symlink refused\n");

    // Sanity: a real in-sandbox file still opens (proves we didn't just break
    // everything). The harness plants real.txt inside /data.
    if (tryRead("real.txt")) {
        puts("ok   in-sandbox file still readable\n");
    } else {
        puts("FAIL in-sandbox file unreadable — over-restricted\n");
    }
}

const all: w.rights_t = @bitCast(@as(u64, (1 << 29) - 1));
