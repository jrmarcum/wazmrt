//! WASI preview 1 (`wasi_snapshot_preview1`) — the core host imports that let a
//! command module do I/O: stdout/stderr, args, environ, clocks, randomness, and
//! `proc_exit`. Each function is a native host import bound through the
//! interpreter's `HostFunc.native_env` (a context + a call fn), so WASI needs no
//! special interpreter support — it's just a set of imports.
//!
//! Scope (first slice): enough for a wasi-libc command program to initialize
//! and print. Unimplemented preview-1 functions resolve to a `NOTSUP` stub, so a
//! module instantiates and a call fails gracefully rather than trapping. File
//! system (`path_open`, preopens), sockets, and polling are deferred.

const std = @import("std");
const Io = std.Io;
const interp = @import("interp.zig");

const Value = interp.Value;
const HostFunc = interp.Instance.HostFunc;
const Memory = interp.Instance.Memory;

/// WASI `errno` values (§ preview-1 `errno` enum).
const errno = struct {
    const success: u32 = 0;
    const badf: u32 = 8;
    const fault: u32 = 21;
    const inval: u32 = 28;
    const nosys: u32 = 52;
    const notsup: u32 = 58;
    const spipe: u32 = 70;
};

/// Per-instance WASI state. `memory` is filled in after instantiation (the
/// module's memory doesn't exist until then); the writers, args, and environ
/// are supplied by the embedder (the CLI).
pub const Wasi = struct {
    memory: ?*Memory = null,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    io: Io,
    args: []const []const u8 = &.{},
    environ: []const []const u8 = &.{},
    exit_code: ?u32 = null,
    rng: std.Random.DefaultPrng,

    pub fn init(io: Io, stdout: *Io.Writer, stderr: *Io.Writer, seed: u64) Wasi {
        return .{ .io = io, .stdout = stdout, .stderr = stderr, .rng = std.Random.DefaultPrng.init(seed) };
    }

    /// The `HostFunc` backing `wasi_snapshot_preview1.<name>`. Known functions get
    /// their implementation; everything else gets a `NOTSUP` stub so the module
    /// still instantiates.
    pub fn hostFunc(self: *Wasi, name: []const u8) HostFunc {
        return .{ .native_env = .{ .ctx = self, .call = callFor(name) } };
    }

    // --- memory helpers (bounds-checked; return null / false on out-of-range) ---
    fn bytes(self: *Wasi) ?[]u8 {
        return if (self.memory) |m| m.bytes else null;
    }
    fn readU32(self: *Wasi, off: u32) ?u32 {
        const b = self.bytes() orelse return null;
        if (@as(u64, off) + 4 > b.len) return null;
        return std.mem.readInt(u32, b[off..][0..4], .little);
    }
    fn writeU32(self: *Wasi, off: u32, v: u32) bool {
        const b = self.bytes() orelse return false;
        if (@as(u64, off) + 4 > b.len) return false;
        std.mem.writeInt(u32, b[off..][0..4], v, .little);
        return true;
    }
    fn writeU64(self: *Wasi, off: u32, v: u64) bool {
        const b = self.bytes() orelse return false;
        if (@as(u64, off) + 8 > b.len) return false;
        std.mem.writeInt(u64, b[off..][0..8], v, .little);
        return true;
    }
    /// A mutable slice `[off, off+len)` of linear memory, or null if out of range.
    fn slice(self: *Wasi, off: u32, len: u32) ?[]u8 {
        const b = self.bytes() orelse return null;
        if (@as(u64, off) + len > b.len) return null;
        return b[off..][0..len];
    }
};

const CallFn = *const fn (ctx: *anyopaque, args: []const Value, results: []Value) bool;

fn argU32(args: []const Value, i: usize) u32 {
    return @bitCast(interp.asI32(args[i]));
}

/// Set the errno result (all WASI funcs but `proc_exit` return an `errno` i32).
fn ret(results: []Value, e: u32) bool {
    if (results.len != 0) results[0] = interp.i32Value(@bitCast(e));
    return true;
}

fn callFor(name: []const u8) CallFn {
    const map = .{
        .{ "proc_exit", wProcExit },
        .{ "fd_write", wFdWrite },
        .{ "fd_read", wFdRead },
        .{ "fd_close", wFdClose },
        .{ "fd_seek", wFdSeek },
        .{ "fd_fdstat_get", wFdFdstatGet },
        .{ "fd_prestat_get", wFdPrestatGet },
        .{ "fd_prestat_dir_name", wStubBadf },
        .{ "args_sizes_get", wArgsSizesGet },
        .{ "args_get", wArgsGet },
        .{ "environ_sizes_get", wEnvironSizesGet },
        .{ "environ_get", wEnvironGet },
        .{ "clock_time_get", wClockTimeGet },
        .{ "random_get", wRandomGet },
        .{ "sched_yield", wSchedYield },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return wStubNotsup;
}

// --- Implementations -------------------------------------------------------

/// `proc_exit(code)` — record the exit code and trap to unwind the call stack.
fn wProcExit(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = results;
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    w.exit_code = argU32(args, 0);
    return false; // -> error.HostTrap; the host reads exit_code
}

/// `fd_write(fd, iovs, iovs_len, nwritten)` — gather the iovecs from memory and
/// write them to fd 1 (stdout) / 2 (stderr).
fn wFdWrite(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const fd = argU32(args, 0);
    const iovs = argU32(args, 1);
    const iovs_len = argU32(args, 2);
    const nwritten_ptr = argU32(args, 3);

    const sink: *Io.Writer = switch (fd) {
        1 => w.stdout,
        2 => w.stderr,
        else => return ret(results, errno.badf),
    };
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovs_len) : (i += 1) {
        const iov = iovs + i * 8; // ciovec = { buf: u32, buf_len: u32 }
        const buf = w.readU32(iov) orelse return ret(results, errno.fault);
        const len = w.readU32(iov + 4) orelse return ret(results, errno.fault);
        const data = w.slice(buf, len) orelse return ret(results, errno.fault);
        sink.writeAll(data) catch return ret(results, errno.badf);
        total +%= len;
    }
    if (!w.writeU32(nwritten_ptr, total)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_read(...)` — no stdin wired yet: report 0 bytes read (EOF).
fn wFdRead(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const nread_ptr = argU32(args, 3);
    if (!w.writeU32(nread_ptr, 0)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

fn wFdClose(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.success);
}

/// `fd_seek(...)` — stdio streams are not seekable.
fn wFdSeek(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.spipe);
}

/// `fd_fdstat_get(fd, stat)` — report stdio as a character device with all
/// rights, so wasi-libc treats it as a tty.
fn wFdFdstatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const fd = argU32(args, 0);
    if (fd > 2) return ret(results, errno.badf);
    const stat = argU32(args, 1);
    // fdstat: { fs_filetype: u8, pad, fs_flags: u16, pad, rights_base: u64, rights_inheriting: u64 } (24 bytes)
    const b = w.slice(stat, 24) orelse return ret(results, errno.fault);
    @memset(b, 0);
    b[0] = 2; // filetype = character_device
    std.mem.writeInt(u64, b[8..][0..8], std.math.maxInt(u64), .little); // rights_base
    std.mem.writeInt(u64, b[16..][0..8], std.math.maxInt(u64), .little); // rights_inheriting
    return ret(results, errno.success);
}

/// `fd_prestat_get(fd, ...)` — no preopened directories, so every fd is BADF;
/// wasi-libc uses this to stop enumerating preopens.
fn wFdPrestatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.badf);
}

fn wArgsSizesGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var buf_size: u32 = 0;
    for (w.args) |a| buf_size += @intCast(a.len + 1);
    if (!w.writeU32(argU32(args, 0), @intCast(w.args.len))) return ret(results, errno.fault);
    if (!w.writeU32(argU32(args, 1), buf_size)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

fn wArgsGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    return writeStringVec(w, argU32(args, 0), argU32(args, 1), w.args, results);
}

fn wEnvironSizesGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var buf_size: u32 = 0;
    for (w.environ) |e| buf_size += @intCast(e.len + 1);
    if (!w.writeU32(argU32(args, 0), @intCast(w.environ.len))) return ret(results, errno.fault);
    if (!w.writeU32(argU32(args, 1), buf_size)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

fn wEnvironGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    return writeStringVec(w, argU32(args, 0), argU32(args, 1), w.environ, results);
}

/// Write a `char**` vector (args/environ): the pointer array at `ptrs`, the
/// NUL-terminated strings packed at `buf`.
fn writeStringVec(w: *Wasi, ptrs: u32, buf: u32, strings: []const []const u8, results: []Value) bool {
    var p = buf;
    for (strings, 0..) |s, i| {
        if (!w.writeU32(ptrs + @as(u32, @intCast(i)) * 4, p)) return ret(results, errno.fault);
        const dst = w.slice(p, @intCast(s.len + 1)) orelse return ret(results, errno.fault);
        @memcpy(dst[0..s.len], s);
        dst[s.len] = 0;
        p += @intCast(s.len + 1);
    }
    return ret(results, errno.success);
}

/// `clock_time_get(id, precision, time)` — a nanosecond timestamp.
fn wClockTimeGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const clock: Io.Clock = if (argU32(args, 0) == 0) .real else .awake; // 0 = realtime
    const ns: i96 = Io.Timestamp.now(w.io, clock).nanoseconds;
    if (!w.writeU64(argU32(args, 2), @intCast(@max(ns, 0)))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `random_get(buf, len)` — fill `buf` with pseudo-random bytes.
fn wRandomGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const buf = w.slice(argU32(args, 0), argU32(args, 1)) orelse return ret(results, errno.fault);
    w.rng.random().bytes(buf);
    return ret(results, errno.success);
}

fn wSchedYield(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.success);
}

fn wStubBadf(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.badf);
}

fn wStubNotsup(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.notsup);
}

// --- Tests -----------------------------------------------------------------

fn testWasi(mem: *Memory, stdout: *Io.Writer) Wasi {
    return .{ .memory = mem, .stdout = stdout, .stderr = stdout, .io = undefined, .rng = std.Random.DefaultPrng.init(0) };
}

test "fd_write gathers iovecs to the target stream" {
    var mem_bytes = [_]u8{0} ** 64;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    // one iovec at 0: { base=16, len=5 }; the data "hello" at 16.
    std.mem.writeInt(u32, mem_bytes[0..4], 16, .little);
    std.mem.writeInt(u32, mem_bytes[4..8], 5, .little);
    @memcpy(mem_bytes[16..21], "hello");

    var obuf: [64]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);

    const args = [_]Value{ interp.i32Value(1), interp.i32Value(0), interp.i32Value(1), interp.i32Value(40) };
    var results = [_]Value{interp.i32Value(-1)};
    try std.testing.expect(wFdWrite(&w, &args, &results));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(results[0])); // SUCCESS
    try std.testing.expectEqualStrings("hello", ow.buffered());
    try std.testing.expectEqual(@as(u32, 5), w.readU32(40).?); // nwritten

    // A bad fd reports EBADF.
    const bad = [_]Value{ interp.i32Value(9), interp.i32Value(0), interp.i32Value(1), interp.i32Value(40) };
    try std.testing.expect(wFdWrite(&w, &bad, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.badf)), interp.asI32(results[0]));
}

test "proc_exit records the code and traps" {
    var mem_bytes = [_]u8{0} ** 8;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);

    const args = [_]Value{interp.i32Value(7)};
    try std.testing.expect(!wProcExit(&w, &args, &.{})); // false -> HostTrap
    try std.testing.expectEqual(@as(u32, 7), w.exit_code.?);
}

test "args_sizes_get + args_get round-trip argv into memory" {
    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    w.args = &.{ "prog", "hi" };

    var results = [_]Value{interp.i32Value(-1)};
    // sizes -> argc at 0, buf_size at 4
    const sz = [_]Value{ interp.i32Value(0), interp.i32Value(4) };
    try std.testing.expect(wArgsSizesGet(&w, &sz, &results));
    try std.testing.expectEqual(@as(u32, 2), w.readU32(0).?); // argc
    try std.testing.expectEqual(@as(u32, 8), w.readU32(4).?); // "prog\0" + "hi\0"

    // get -> pointer array at 16, string buffer at 32
    const gv = [_]Value{ interp.i32Value(16), interp.i32Value(32) };
    try std.testing.expect(wArgsGet(&w, &gv, &results));
    const p0 = w.readU32(16).?;
    const p1 = w.readU32(20).?;
    try std.testing.expectEqualStrings("prog", std.mem.sliceTo(mem_bytes[p0..], 0));
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(mem_bytes[p1..], 0));
}
