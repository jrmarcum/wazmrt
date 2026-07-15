//! WASI Phase 3 demo: the sandboxed filesystem, driven by a real compiled
//! `wasm32-wasi` guest.
//!
//!   zig build-exe examples/wasi_files.zig -target wasm32-wasi -O ReleaseSmall \
//!     -femit-bin=files.wasm
//!   zig-out/bin/wazmrt files.wasm --dir <somedir>:/data
//!
//! Writes a file, reads it back, seeks, stats, lists the directory, and checks
//! that a `..` escape is refused — then cleans up after itself.
//!
//! We call the WASI imports through `std.os.wasi` rather than hand-writing
//! `extern` declarations. That matters: if a guest declares an import with a
//! signature that differs from std's (say `fd_write(...) i32` where std has
//! `errno_t`, an `enum(u16)`), wasm-ld cannot reconcile the two and silently
//! replaces the call with a `…_bitcast_invalid` stub whose entire body is
//! `unreachable` — the program then traps the first time it calls it, with no
//! diagnostic. See `cmem/testing.md`.

const std = @import("std");
const w = std.os.wasi;

const dir_fd: w.fd_t = 3; // the first preopen

fn puts(s: []const u8) void {
    var iov = w.ciovec_t{ .base = s.ptr, .len = s.len };
    var nw: usize = 0;
    _ = w.fd_write(1, @ptrCast(&iov), 1, &nw);
}

fn check(ok: bool, label: []const u8) void {
    puts(if (ok) "ok   " else "FAIL ");
    puts(label);
    puts("\n");
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    // The preopen announces its guest-visible name.
    var name: [64]u8 = undefined;
    var pre: w.prestat_t = undefined;
    var ok = w.fd_prestat_get(dir_fd, &pre) == .SUCCESS;
    const nlen = pre.u.dir.pr_name_len;
    ok = ok and w.fd_prestat_dir_name(dir_fd, &name, nlen) == .SUCCESS;
    check(ok and std.mem.eql(u8, name[0..nlen], "/data"), "fd_prestat_get/dir_name report the preopen");

    // Create + write.
    var fd: w.fd_t = -1;
    var rc = w.path_open(dir_fd, .{}, "hello.txt", 9, .{ .CREAT = true, .TRUNC = true }, rights_all, rights_all, .{}, &fd);
    check(rc == .SUCCESS and fd > 3, "path_open O_CREAT");

    const msg = "wazmrt wrote this";
    var out_iov = w.ciovec_t{ .base = msg.ptr, .len = msg.len };
    var nw: usize = 0;
    check(w.fd_write(fd, @ptrCast(&out_iov), 1, &nw) == .SUCCESS and nw == msg.len, "fd_write to a file");
    _ = w.fd_close(fd);

    // Reopen + read back.
    rc = w.path_open(dir_fd, .{}, "hello.txt", 9, .{}, rights_all, rights_all, .{}, &fd);
    var buf: [64]u8 = undefined;
    var in_iov = w.iovec_t{ .base = &buf, .len = buf.len };
    var nr: usize = 0;
    _ = w.fd_read(fd, @ptrCast(&in_iov), 1, &nr);
    check(rc == .SUCCESS and std.mem.eql(u8, buf[0..nr], msg), "fd_read round-trips the contents");

    // Seek back to 7 and read the rest.
    var pos: w.filesize_t = 0;
    _ = w.fd_seek(fd, 7, .SET, &pos);
    in_iov = w.iovec_t{ .base = &buf, .len = buf.len };
    _ = w.fd_read(fd, @ptrCast(&in_iov), 1, &nr);
    check(pos == 7 and std.mem.eql(u8, buf[0..nr], "wrote this"), "fd_seek repositions");
    _ = w.fd_close(fd);

    // Stat.
    var st: w.filestat_t = undefined;
    rc = w.path_filestat_get(dir_fd, .{ .SYMLINK_FOLLOW = true }, "hello.txt", 9, &st);
    check(rc == .SUCCESS and st.filetype == .REGULAR_FILE and st.size == msg.len, "path_filestat_get reports type + size");

    check(w.path_create_directory(dir_fd, "sub", 3) == .SUCCESS, "path_create_directory");

    // readdir must at least turn up the file we made.
    var dbuf: [512]u8 = undefined;
    var used: usize = 0;
    rc = w.fd_readdir(dir_fd, &dbuf, dbuf.len, 0, &used);
    var found = false;
    var off: usize = 0;
    while (off + 24 <= used) { // dirent: d_next,d_ino,d_namlen@16,d_type@20 + name
        const namlen = std.mem.readInt(u32, dbuf[off + 16 ..][0..4], .little);
        if (off + 24 + namlen > used) break; // truncated tail entry
        if (std.mem.eql(u8, dbuf[off + 24 ..][0..namlen], "hello.txt")) found = true;
        off += 24 + namlen;
    }
    check(rc == .SUCCESS and found, "fd_readdir lists the entry");

    // --- The sandbox. Each of these names a real file outside the preopen. ---
    var esc: w.fd_t = -1;
    const follow = w.lookupflags_t{ .SYMLINK_FOLLOW = true };
    check(w.path_open(dir_fd, follow, "../../../etc/passwd", 19, .{}, rights_all, rights_all, .{}, &esc) == .NOTCAPABLE, "path_open refuses ..-escape");
    check(w.path_open(dir_fd, follow, "/etc/passwd", 11, .{}, rights_all, rights_all, .{}, &esc) == .NOTCAPABLE, "path_open refuses absolute path");
    check(w.path_open(dir_fd, follow, "C:\\Windows\\win.ini", 18, .{}, rights_all, rights_all, .{}, &esc) == .NOTCAPABLE, "path_open refuses drive path");
    check(w.path_filestat_get(dir_fd, follow, "..\\..\\x", 7, &st) == .NOTCAPABLE, "path_filestat_get refuses ..-escape");
    // An interior `..` that stays inside is fine, though.
    check(w.path_filestat_get(dir_fd, follow, "sub/../hello.txt", 16, &st) == .SUCCESS, "interior .. that stays inside is allowed");

    // Clean up.
    check(w.path_remove_directory(dir_fd, "sub", 3) == .SUCCESS, "path_remove_directory");
    check(w.path_unlink_file(dir_fd, "hello.txt", 9) == .SUCCESS, "path_unlink_file");
    check(w.path_filestat_get(dir_fd, follow, "hello.txt", 9, &st) == .NOENT, "unlinked file is gone");
}

const rights_all: w.rights_t = @bitCast(@as(u64, (1 << 29) - 1));
