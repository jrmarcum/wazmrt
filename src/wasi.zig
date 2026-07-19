//! WASI preview 1 (`wasi_snapshot_preview1`) — the host imports that let a
//! command module do I/O: stdout/stderr/stdin, args, environ, clocks,
//! randomness, `proc_exit`, and a **sandboxed filesystem** rooted at the
//! directories the embedder preopens. Each function is a native host import
//! bound through the interpreter's `HostFunc.native_env` (a context + a call
//! fn), so WASI needs no special interpreter support — it's just a set of
//! imports.
//!
//! Unimplemented preview-1 functions resolve to a `NOTSUP` stub, so a module
//! instantiates and a call fails gracefully rather than trapping. Sockets are
//! not implemented.
//!
//! ## The sandbox
//!
//! A guest may only name paths under a directory the embedder preopened
//! (`--dir` on the CLI). **We resolve and contain guest paths ourselves**, in
//! two layers — `Io.Dir`'s `resolve_beneath` is a silent no-op on Windows and
//! Linux (it only maps to a FreeBSD `O.RESOLVE_BENEATH`), so the `*at`-style dir
//! handle alone is NOT a security boundary.
//!
//! 1. **Lexical** (`resolve`): reject absolute paths, escaping `..`, NT/device
//!    prefixes, and embedded NUL in the *guest* path; normalize.
//! 2. **Filesystem** (`walkFull`, the handle-stack resolver): symlinks are
//!    **followed**, but securely — RESOLVE_BENEATH in userspace (4.3). A stack of
//!    open directory handles is kept, bottom = the preopen. `..` pops it but
//!    **never below the bottom** (no handle exists above the preopen, so
//!    up-escape is impossible, not merely rejected); a symlink's target is
//!    expanded through the *same* loop; an **absolute** target resets the stack
//!    to the preopen root (absolute means the sandbox root, never the host
//!    root); every open is one component, no-follow, relative to a held handle
//!    (TOCTOU-safe — the handle pins the inode); a `symlink_max` budget bounds
//!    cycles. See `cmem/security-model.md` for the full argument, and
//!    `walkFull`'s doc for the spec.
//!
//! So an **in-sandbox** symlink works like a real filesystem, while a symlink
//! whose target leaves the preopen simply fails to resolve — security is a
//! property of the construction, not of lexical target-checking. Ops pass
//! `follow_final`: stat/open with `SYMLINK_FOLLOW` follow the final component;
//! `unlink`/`readlink`/no-follow stats operate on the link itself.
//!
//! Residual: a narrow TOCTOU on the *final* component of `path_open` — the walk
//! resolves the final to a non-symlink, then opens with follow (a no-op),
//! because `openFile(.follow_symlinks = false)` crashes the host on Windows (std
//! bug #18). A swap in that window needs write access *inside* the sandbox and a
//! race; the walk's per-component opens have no such window.

const std = @import("std");
const Io = std.Io;
const interp = @import("interp.zig");

const Value = interp.Value;
const HostFunc = interp.Instance.HostFunc;
const Memory = interp.Instance.Memory;

/// WASI `errno` values (§ preview-1 `errno` enum).
const errno = struct {
    const success: u32 = 0;
    const acces: u32 = 2;
    const again: u32 = 6;
    const badf: u32 = 8;
    const busy: u32 = 10;
    const canceled: u32 = 11;
    const dquot: u32 = 19;
    const exist: u32 = 20;
    const fault: u32 = 21;
    const fbig: u32 = 22;
    const ilseq: u32 = 25;
    const inval: u32 = 28;
    const io: u32 = 29;
    const isdir: u32 = 31;
    const loop: u32 = 32;
    const mfile: u32 = 33;
    const mlink: u32 = 34;
    const nametoolong: u32 = 37;
    const nfile: u32 = 41;
    const noent: u32 = 44;
    const nomem: u32 = 48;
    const nospc: u32 = 51;
    const nosys: u32 = 52;
    const notdir: u32 = 54;
    const notempty: u32 = 55;
    const notsup: u32 = 58;
    const nxio: u32 = 60;
    const perm: u32 = 63;
    const pipe: u32 = 64;
    const rofs: u32 = 69;
    const spipe: u32 = 70;
    const xdev: u32 = 75;
    /// The path escaped the sandbox, or the fd lacks the right.
    const notcapable: u32 = 76;
};

/// Map a Zig `Io` error to the closest WASI errno. Taken across the union of the
/// `Io.Dir`/`Io.File` error sets; anything unrecognized degrades to EIO rather
/// than being reported as success.
fn errnoFor(e: anyerror) u32 {
    return switch (e) {
        error.FileNotFound => errno.noent,
        error.PathAlreadyExists => errno.exist,
        error.AccessDenied, error.PermissionDenied => errno.acces,
        error.NotDir => errno.notdir,
        error.IsDir => errno.isdir,
        error.DirNotEmpty => errno.notempty,
        error.SymLinkLoop => errno.loop,
        error.ProcessFdQuotaExceeded => errno.mfile,
        error.SystemFdQuotaExceeded => errno.nfile,
        error.SystemResources, error.OutOfMemory => errno.nomem,
        error.NoSpaceLeft => errno.nospc,
        error.DiskQuota => errno.dquot,
        error.FileTooBig => errno.fbig,
        error.ReadOnlyFileSystem => errno.rofs,
        error.DeviceBusy, error.FileBusy, error.PipeBusy => errno.busy,
        error.WouldBlock => errno.again,
        error.NoDevice => errno.nxio,
        error.LinkQuotaExceeded => errno.mlink,
        error.CrossDevice => errno.xdev,
        error.NameTooLong => errno.nametoolong,
        error.BadPathName => errno.ilseq,
        error.Unseekable, error.Streaming => errno.spipe,
        error.NotOpenForReading, error.NotOpenForWriting => errno.notcapable,
        error.BrokenPipe => errno.pipe,
        error.Canceled => errno.canceled,
        error.LockViolation => errno.busy,
        error.FileLocksUnsupported, error.OperationUnsupported => errno.notsup,
        error.FileSystem, error.InputOutput, error.HardwareFailure => errno.io,
        else => errno.io,
    };
}

// --- WASI constants (§ preview-1) ------------------------------------------

/// `rights` flags.
const rights = struct {
    const fd_datasync: u64 = 1 << 0;
    const fd_read: u64 = 1 << 1;
    const fd_seek: u64 = 1 << 2;
    const fd_fdstat_set_flags: u64 = 1 << 3;
    const fd_sync: u64 = 1 << 4;
    const fd_tell: u64 = 1 << 5;
    const fd_write: u64 = 1 << 6;
    const fd_allocate: u64 = 1 << 8;
    const path_create_directory: u64 = 1 << 9;
    const path_create_file: u64 = 1 << 10;
    const path_link_source: u64 = 1 << 11;
    const path_link_target: u64 = 1 << 12;
    const path_open: u64 = 1 << 13;
    const fd_readdir: u64 = 1 << 14;
    const path_readlink: u64 = 1 << 15;
    const path_rename_source: u64 = 1 << 16;
    const path_rename_target: u64 = 1 << 17;
    const path_filestat_get: u64 = 1 << 18;
    const path_filestat_set_times: u64 = 1 << 20;
    const fd_filestat_get: u64 = 1 << 21;
    const fd_filestat_set_size: u64 = 1 << 22;
    const fd_filestat_set_times: u64 = 1 << 23;
    const path_remove_directory: u64 = 1 << 25;
    const path_unlink_file: u64 = 1 << 26;
    const poll_fd_readwrite: u64 = 1 << 27;

    /// Everything a preopened directory hands out (dir rights + what files
    /// opened under it may inherit).
    const all: u64 = (1 << 29) - 1;

    /// The rights that let a guest *mutate* the filesystem — write, create,
    /// delete, rename, link, truncate, set-times, preallocate.
    const write_mask: u64 = fd_write | fd_allocate |
        path_create_directory | path_create_file |
        path_link_source | path_link_target |
        path_rename_source | path_rename_target |
        path_filestat_set_times | fd_filestat_set_size | fd_filestat_set_times |
        path_remove_directory | path_unlink_file;

    /// A read-only preopen (`--ro-dir`): everything except the mutating rights.
    /// Since `path_open` intersects a new fd's rights with the dir fd's
    /// inheriting rights, nothing opened under a read-only preopen can write
    /// either — the restriction propagates.
    const read_only: u64 = all & ~write_mask;
};

/// Preopen rights masks for the embedder (the CLI's `--dir` / `--ro-dir`).
pub const allRights: u64 = rights.all;
pub const readOnlyRights: u64 = rights.read_only;

/// `oflags` for `path_open`.
const oflags = struct {
    const creat: u16 = 1 << 0;
    const directory: u16 = 1 << 1;
    const excl: u16 = 1 << 2;
    const trunc: u16 = 1 << 3;
};

/// `fdflags`.
const fdflags = struct {
    const append: u16 = 1 << 0;
    const dsync: u16 = 1 << 1;
    const nonblock: u16 = 1 << 2;
    const rsync: u16 = 1 << 3;
    const sync: u16 = 1 << 4;
};

/// `lookupflags`.
const lookup_symlink_follow: u32 = 1 << 0;

/// `fstflags` for `*_filestat_set_times` (§ preview-1). Setting both the value
/// and the _NOW bit for one timestamp is invalid.
const fstflags = struct {
    const atim: u16 = 1 << 0;
    const atim_now: u16 = 1 << 1;
    const mtim: u16 = 1 << 2;
    const mtim_now: u16 = 1 << 3;
};

/// `filetype` enum values.
const filetype = struct {
    const unknown: u8 = 0;
    const block_device: u8 = 1;
    const character_device: u8 = 2;
    const directory: u8 = 3;
    const regular_file: u8 = 4;
    const socket_stream: u8 = 6;
    const symbolic_link: u8 = 7;
};

fn filetypeOf(k: Io.File.Kind) u8 {
    return switch (k) {
        .block_device => filetype.block_device,
        .character_device => filetype.character_device,
        .directory => filetype.directory,
        .sym_link => filetype.symbolic_link,
        .file => filetype.regular_file,
        .unix_domain_socket => filetype.socket_stream,
        else => filetype.unknown,
    };
}

/// WASI `timestamp_t` is `u64` ns since the Unix epoch; `Io.Timestamp` is a
/// *signed* `i96`. Clamp rather than wrap: a pre-1970 mtime is negative and a
/// post-2554 one overflows.
fn timestampOf(t: Io.Timestamp) u64 {
    return @intCast(std.math.clamp(t.nanoseconds, 0, std.math.maxInt(u64)));
}

/// Resolve a guest path to a sandbox-safe path relative to its preopen dir.
///
/// This is the sandbox (see the module doc for why `Io.Dir` can't be trusted to
/// enforce it). Returns null — the caller reports `ENOTCAPABLE` — for anything
/// that could name a file outside the preopen:
///   - an absolute path (`/etc/passwd`, `\x`, `C:\x`) — bypasses the dir handle
///   - a `..` that pops above the root, at any point in the walk
///   - a UNC / NT / device prefix (`\\?\`, `\??\`, `//server/share`)
///   - an embedded NUL (would truncate the path at the syscall boundary)
/// `.` components are dropped and separators collapsed, so the result is
/// normalized with no `..` remaining — safe to hand to `Io.Dir`, whose lexical
/// Windows normalization is then a no-op. An empty result means "the dir
/// itself" and is returned as ".".
fn resolve(gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    // Absolute: POSIX root, a Windows separator, or a drive letter.
    if (path[0] == '/' or path[0] == '\\') return null;
    if (path.len >= 2 and path[1] == ':') return null;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            // Popping past the root escapes the sandbox.
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        // A device name or NT-namespace component never belongs in a guest path.
        if (std.mem.indexOfScalar(u8, part, ':') != null) return null;
        if (std.mem.eql(u8, part, "?") or std.mem.eql(u8, part, "??")) return null;
        parts.append(gpa, part) catch return null;
    }
    if (parts.items.len == 0) return gpa.dupe(u8, ".") catch null;
    return std.mem.join(gpa, "/", parts.items) catch null;
}

/// One guest file descriptor: stdio, a preopened/opened directory, or a file.
pub const FdEntry = union(enum) {
    stdin,
    stdout,
    stderr,
    dir: Dir,
    file: File,

    pub const Dir = struct {
        handle: Io.Dir,
        /// The guest-visible path (`fd_prestat_dir_name`), set only on preopens.
        preopen_name: ?[]const u8 = null,
        rights_base: u64 = rights.all,
        rights_inheriting: u64 = rights.all,
        /// Close the handle on `fd_close`. Preopens opened by the embedder are
        /// owned by us; `Io.Dir.cwd()` would not be.
        owned: bool = true,
    };

    pub const File = struct {
        handle: Io.File,
        /// The seek position. WASI fds carry their own offset and we use the
        /// positional read/write calls, so this stays independent of the host
        /// handle's position (and is threadsafe).
        offset: u64 = 0,
        rights_base: u64 = rights.all,
        rights_inheriting: u64 = rights.all,
        flags: u16 = 0,
    };
};

/// Per-instance WASI state. `memory` is filled in after instantiation (the
/// module's memory doesn't exist until then); the writers, args, environ, and
/// preopens are supplied by the embedder (the CLI).
pub const Wasi = struct {
    memory: ?*Memory = null,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    /// Process stdin for `fd_read` on fd 0; null reports EOF.
    stdin: ?*Io.Reader = null,
    io: Io,
    gpa: std.mem.Allocator,
    args: []const []const u8 = &.{},
    environ: []const []const u8 = &.{},
    exit_code: ?u32 = null,
    rng: std.Random.DefaultPrng,
    /// Guest fd -> host resource, indexed by fd. 0/1/2 are stdio; preopens land
    /// at 3+ (the convention every wasi-libc expects). A hole is a closed fd.
    fds: std.ArrayList(?FdEntry) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, seed: u64) Wasi {
        var w: Wasi = .{
            .io = io,
            .gpa = gpa,
            .stdout = stdout,
            .stderr = stderr,
            .rng = std.Random.DefaultPrng.init(seed),
        };
        // fds 0-2 are always the standard streams.
        w.fds.appendSlice(gpa, &.{ .stdin, .stdout, .stderr }) catch {};
        return w;
    }

    pub fn deinit(self: *Wasi) void {
        for (self.fds.items) |maybe| {
            const e = maybe orelse continue;
            switch (e) {
                .dir => |d| {
                    if (d.owned) d.handle.close(self.io);
                    if (d.preopen_name) |n| self.gpa.free(n);
                },
                .file => |f| f.handle.close(self.io),
                else => {},
            }
        }
        self.fds.deinit(self.gpa);
        self.* = undefined;
    }

    /// Preopen `host_path` as the guest-visible directory `guest_name`, so the
    /// guest may reach it (and only it) via `path_open`. Returns the guest fd.
    /// Preopen `host_path` as guest dir `guest_name` with the given `dir_rights`
    /// (`rights.all` for read-write, `rights.read_only` for `--ro-dir`). The
    /// rights also cap what fds opened under it may hold (inheriting), so a
    /// read-only preopen makes the whole subtree read-only.
    pub fn addPreopen(self: *Wasi, host_path: []const u8, guest_name: []const u8, dir_rights: u64) !u32 {
        const cwd = Io.Dir.cwd();
        const handle = if (std.fs.path.isAbsolute(host_path))
            try Io.Dir.openDirAbsolute(self.io, host_path, .{ .iterate = true })
        else
            try cwd.openDir(self.io, host_path, .{ .iterate = true });
        errdefer handle.close(self.io);

        const name = try self.gpa.dupe(u8, guest_name);
        errdefer self.gpa.free(name);
        try self.fds.append(self.gpa, .{ .dir = .{
            .handle = handle,
            .preopen_name = name,
            .rights_base = dir_rights,
            .rights_inheriting = dir_rights,
        } });
        return @intCast(self.fds.items.len - 1);
    }

    /// The entry for guest `fd`, or null if it is closed / out of range.
    fn get(self: *Wasi, fd: u32) ?*FdEntry {
        if (fd >= self.fds.items.len) return null;
        if (self.fds.items[fd] == null) return null;
        return &self.fds.items[fd].?;
    }

    /// Install `e` at the lowest free guest fd.
    fn put(self: *Wasi, e: FdEntry) !u32 {
        for (self.fds.items, 0..) |slot, i| {
            if (slot == null) {
                self.fds.items[i] = e;
                return @intCast(i);
            }
        }
        try self.fds.append(self.gpa, e);
        return @intCast(self.fds.items.len - 1);
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
    fn readU16(self: *Wasi, off: u32) ?u16 {
        const b = self.bytes() orelse return null;
        if (@as(u64, off) + 2 > b.len) return null;
        return std.mem.readInt(u16, b[off..][0..2], .little);
    }
    fn readU64(self: *Wasi, off: u32) ?u64 {
        const b = self.bytes() orelse return null;
        if (@as(u64, off) + 8 > b.len) return null;
        return std.mem.readInt(u64, b[off..][0..8], .little);
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

/// Cap on symlink expansions during one resolution (→ `ELOOP`). Bounds cycles
/// (`a→b→a`) and length amplification.
const symlink_max: u32 = 32;

/// A `(dirfd, path, path_len)` argument resolved against the sandbox: the final
/// component (`name`) and the directory handle it lives in (`dir`), reached by a
/// handle-stack walk that **follows symlinks securely** (see the module doc and
/// `cmem/security-model.md`). Caller must `close()`.
const ResolvedPath = struct {
    dir: Io.Dir,
    /// The final component, owned (freed by `close`). After a followed symlink
    /// this is the resolved real name; with `follow_final = false` it may be a
    /// symlink the op operates on directly.
    name: []u8,
    /// True if `name` is itself a symlink (only possible when the op asked not
    /// to follow the final). `path_open` uses this to `ELOOP` on a bare symlink.
    final_is_symlink: bool,
    /// Directory handles the walk opened, to close afterward. `dir` is the last
    /// of these, or the preopen handle if the walk opened none.
    opened: std.ArrayList(Io.Dir),
    /// The dir fd's inheriting rights, which cap what an opened fd may hold.
    inheriting: u64,

    fn close(self: *ResolvedPath, w: *Wasi) void {
        for (self.opened.items) |d| d.close(w.io);
        self.opened.deinit(w.gpa);
        w.gpa.free(self.name);
    }
};

const WalkOut = struct { dir: Io.Dir, name: []u8, final_is_symlink: bool };

fn isAbsoluteTarget(t: []const u8) bool {
    if (t.len == 0) return false;
    if (t[0] == '/' or t[0] == '\\') return true;
    return t.len >= 2 and t[1] == ':'; // drive-qualified
}

/// Resolve `guest_path` from `start` to `(dir, name)`, **following symlinks
/// through a handle stack** — the RESOLVE_BENEATH model in userspace, secure by
/// construction (see `cmem/security-model.md` for the full argument):
///
///   - the stack bottom is `start` (the preopen); `..` pops it but **never below
///     the bottom** — there is no handle above the preopen to reach, so up-escape
///     is impossible, not merely rejected;
///   - a **symlink**'s target is expanded through the *same* loop; an **absolute**
///     target resets the stack to `[start]` — absolute means the preopen root,
///     never the host root;
///   - every open is a single component, no-follow, relative to a held handle —
///     TOCTOU-safe (the handle pins the inode) and immune to intermediate-symlink
///     redirection;
///   - `symlink_max` bounds cycles/amplification.
///
/// `follow_final = false` leaves a final-component symlink unfollowed (for
/// `unlink`/`readlink`/no-`SYMLINK_FOLLOW` stats). Opened handles go to `opened`;
/// on failure this closes them and writes the errno. `name` is `gpa`-owned.
fn walkFull(w: *Wasi, start: Io.Dir, guest_path: []const u8, follow_final: bool, opened: *std.ArrayList(Io.Dir), results: []Value) ?WalkOut {
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const fail = struct {
        fn f(ww: *Wasi, op: *std.ArrayList(Io.Dir), res: []Value, e: u32) ?WalkOut {
            for (op.items) |d| d.close(ww.io);
            op.deinit(ww.gpa);
            op.* = .empty;
            _ = ret(res, e);
            return null;
        }
    }.f;

    // The current directory is `start` when `opened` is empty, else the last
    // handle we pushed. `..` pops (and closes) the last pushed handle; it can
    // never reach `start`, which we never push.
    const topDir = struct {
        fn f(s: Io.Dir, op: *std.ArrayList(Io.Dir)) Io.Dir {
            return if (op.items.len == 0) s else op.items[op.items.len - 1];
        }
    }.f;

    // Pending components as a LIFO stack: push a path's components in reverse so
    // popping yields them left-to-right. Following a symlink pushes its target's
    // components (reversed) on top, so they resolve before the remainder.
    var pending: std.ArrayList([]const u8) = .empty;
    pushReversed(a, &pending, guest_path) catch return fail(w, opened, results, errno.nomem);

    var budget: u32 = symlink_max;

    while (pending.pop()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (opened.items.len == 0) return fail(w, opened, results, errno.notcapable); // would escape above root
            (opened.pop().?).close(w.io);
            continue;
        }
        const is_final = pending.items.len == 0;
        const top = topDir(start, opened);

        const st = top.statFile(w.io, c, .{ .follow_symlinks = false }) catch |err| {
            // A missing FINAL component is fine for create ops; the caller sees
            // it via a later openFile/createFile. Anything else is a real error.
            if (is_final and err == error.FileNotFound)
                return .{ .dir = top, .name = w.gpa.dupe(u8, c) catch return fail(w, opened, results, errno.nomem), .final_is_symlink = false };
            return fail(w, opened, results, errnoFor(err));
        };

        if (st.kind == .sym_link and !(is_final and !follow_final)) {
            // Follow it: read the target and splice its components onto `pending`.
            if (budget == 0) return fail(w, opened, results, errno.loop);
            budget -= 1;
            var buf: [4096]u8 = undefined;
            const n = top.readLink(w.io, c, &buf) catch |err| return fail(w, opened, results, errnoFor(err));
            var target = a.dupe(u8, buf[0..n]) catch return fail(w, opened, results, errno.nomem);
            if (isAbsoluteTarget(target)) {
                // Absolute → the preopen root, not the host root: reset the stack
                // and re-base. Strip the whole absolute prefix — a drive
                // (`C:`), then any leading separators — so what remains is
                // relative to the root. (`readLink` on Windows can return a
                // drive-qualified target even for a link made with `/foo`.)
                while (opened.pop()) |d| d.close(w.io);
                if (target.len >= 2 and target[1] == ':') target = target[2..];
                while (target.len > 0 and (target[0] == '/' or target[0] == '\\')) target = target[1..];
            }
            pushReversed(a, &pending, target) catch return fail(w, opened, results, errno.nomem);
            continue;
        }

        if (is_final)
            return .{ .dir = top, .name = w.gpa.dupe(u8, c) catch return fail(w, opened, results, errno.nomem), .final_is_symlink = st.kind == .sym_link };

        // Intermediate real component: must be a directory; descend into it.
        if (st.kind != .directory) return fail(w, opened, results, errno.notdir);
        const next = top.openDir(w.io, c, .{ .iterate = true, .follow_symlinks = false }) catch |err|
            return fail(w, opened, results, errnoFor(err));
        // Post-open guard: on Windows a reparse point can be opened rather than
        // fail; the fstat catches a symlink that slipped through no-follow.
        const nst = next.stat(w.io) catch {
            next.close(w.io);
            return fail(w, opened, results, errno.io);
        };
        if (nst.kind != .directory) {
            next.close(w.io);
            return fail(w, opened, results, errno.notcapable);
        }
        opened.append(w.gpa, next) catch {
            next.close(w.io);
            return fail(w, opened, results, errno.nomem);
        };
    }

    // The path resolved to a directory itself (all `.`/`..`, or empty): name ".".
    return .{ .dir = topDir(start, opened), .name = w.gpa.dupe(u8, ".") catch return fail(w, opened, results, errno.nomem), .final_is_symlink = false };
}

/// Split `path` on `/` and `\` and push the components onto `pending` in reverse
/// (so a LIFO pop yields them left-to-right). A leading absolute prefix is
/// dropped — the caller has already reset to the root for absolute targets.
fn pushReversed(a: std.mem.Allocator, pending: *std.ArrayList([]const u8), path: []const u8) !void {
    var it = std.mem.splitAny(u8, path, "/\\");
    var comps: std.ArrayList([]const u8) = .empty;
    defer comps.deinit(a);
    while (it.next()) |c| try comps.append(a, c);
    var i: usize = comps.items.len;
    while (i > 0) {
        i -= 1;
        try pending.append(a, comps.items[i]);
    }
}

/// Resolve `(fd, ptr, len)` from a `path_*` call: the fd must be an open
/// directory holding `need` rights, and the path is walked into the sandbox
/// following symlinks securely (`walkFull`). `follow_final` = whether a final
/// symlink is followed. On failure writes the errno and returns null.
fn resolveArg(w: *Wasi, fd: u32, ptr: u32, len: u32, need: u64, follow_final: bool, results: []Value) ?ResolvedPath {
    const e = w.get(fd) orelse {
        _ = ret(results, errno.badf);
        return null;
    };
    const d = switch (e.*) {
        .dir => |d| d,
        else => {
            _ = ret(results, errno.notdir);
            return null;
        },
    };
    if (need != 0 and d.rights_base & need != need) {
        _ = ret(results, errno.notcapable);
        return null;
    }
    const raw = w.slice(ptr, len) orelse {
        _ = ret(results, errno.fault);
        return null;
    };
    // Cheap lexical gate on the *guest* path: reject absolute / escaping-`..` /
    // NT-device / NUL up front. (Symlink *targets* are handled by walkFull's
    // stack, where absolute means the preopen root — a different rule.)
    const norm = resolve(w.gpa, raw) orelse {
        _ = ret(results, errno.notcapable);
        return null;
    };
    defer w.gpa.free(norm);

    var opened: std.ArrayList(Io.Dir) = .empty;
    const out = walkFull(w, d.handle, norm, follow_final, &opened, results) orelse return null;
    return .{
        .dir = out.dir,
        .name = out.name,
        .final_is_symlink = out.final_is_symlink,
        .opened = opened,
        .inheriting = d.rights_inheriting,
    };
}

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
        .{ "fd_tell", wFdTell },
        .{ "fd_pread", wFdPread },
        .{ "fd_pwrite", wFdPwrite },
        .{ "fd_sync", wFdSync },
        .{ "fd_datasync", wFdSync }, // Io.File.sync flushes contents + metadata
        .{ "fd_fdstat_get", wFdFdstatGet },
        .{ "fd_fdstat_set_flags", wFdFdstatSetFlags },
        .{ "fd_filestat_get", wFdFilestatGet },
        .{ "fd_filestat_set_size", wFdFilestatSetSize },
        .{ "fd_filestat_set_times", wFdFilestatSetTimes },
        .{ "fd_allocate", wFdAllocate },
        .{ "fd_readdir", wFdReaddir },
        .{ "fd_renumber", wFdRenumber },
        .{ "fd_advise", wSchedYield }, // advisory only — success is honest
        .{ "fd_prestat_get", wFdPrestatGet },
        .{ "fd_prestat_dir_name", wFdPrestatDirName },
        .{ "path_open", wPathOpen },
        .{ "path_filestat_get", wPathFilestatGet },
        .{ "path_filestat_set_times", wPathFilestatSetTimes },
        .{ "path_create_directory", wPathCreateDirectory },
        .{ "path_remove_directory", wPathRemoveDirectory },
        .{ "path_unlink_file", wPathUnlinkFile },
        .{ "path_rename", wPathRename },
        .{ "path_link", wPathLink },
        .{ "path_symlink", wPathSymlink },
        .{ "path_readlink", wPathReadlink },
        .{ "args_sizes_get", wArgsSizesGet },
        .{ "args_get", wArgsGet },
        .{ "environ_sizes_get", wEnvironSizesGet },
        .{ "environ_get", wEnvironGet },
        .{ "clock_time_get", wClockTimeGet },
        .{ "clock_res_get", wClockResGet },
        .{ "poll_oneoff", wPollOneoff },
        .{ "random_get", wRandomGet },
        .{ "sched_yield", wSchedYield },
        .{ "proc_raise", wProcRaise },
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

/// Gather the guest's `iovec`/`ciovec` array into host slices pointing straight
/// into linear memory — the shape `Io.File.read/writePositional` want. Caller
/// frees. Returns null after writing the errno into `results`.
fn gatherIovecs(w: *Wasi, iovs: u32, iovs_len: u32, results: []Value) ?[][]u8 {
    const vecs = w.gpa.alloc([]u8, iovs_len) catch {
        _ = ret(results, errno.nomem);
        return null;
    };
    var i: u32 = 0;
    while (i < iovs_len) : (i += 1) {
        const iov = iovs + i * 8; // { buf: u32, buf_len: u32 }
        const buf = w.readU32(iov) orelse {
            w.gpa.free(vecs);
            _ = ret(results, errno.fault);
            return null;
        };
        const len = w.readU32(iov + 4) orelse {
            w.gpa.free(vecs);
            _ = ret(results, errno.fault);
            return null;
        };
        vecs[i] = w.slice(buf, len) orelse {
            w.gpa.free(vecs);
            _ = ret(results, errno.fault);
            return null;
        };
    }
    return vecs;
}

/// `fd_write(fd, iovs, iovs_len, nwritten)` — gather the iovecs and write them
/// to stdout/stderr or to a file fd at its current offset (or, with the APPEND
/// flag, at the end — `Io` has no O_APPEND, so we place the write ourselves).
fn wFdWrite(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const fd = argU32(args, 0);
    const iovs = argU32(args, 1);
    const iovs_len = argU32(args, 2);
    const nwritten_ptr = argU32(args, 3);

    const e = w.get(fd) orelse return ret(results, errno.badf);
    const vecs = gatherIovecs(w, iovs, iovs_len, results) orelse return true;
    defer w.gpa.free(vecs);

    var total: u64 = 0;
    switch (e.*) {
        .stdout, .stderr => {
            const sink: *Io.Writer = if (e.* == .stdout) w.stdout else w.stderr;
            for (vecs) |v| {
                sink.writeAll(v) catch return ret(results, errno.io);
                total += v.len;
            }
        },
        .file => |*f| {
            if (f.rights_base & rights.fd_write == 0) return ret(results, errno.notcapable);
            var at = f.offset;
            if (f.flags & fdflags.append != 0)
                at = f.handle.length(w.io) catch |err| return ret(results, errnoFor(err));
            total = f.handle.writePositional(w.io, vecs, at) catch |err|
                return ret(results, errnoFor(err));
            f.offset = at + total;
        },
        .stdin => return ret(results, errno.notcapable),
        .dir => return ret(results, errno.isdir),
    }
    if (!w.writeU32(nwritten_ptr, @intCast(total))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_read(fd, iovs, iovs_len, nread)` — scatter-read stdin or a file fd into
/// the iovecs. EOF reports 0 bytes with SUCCESS.
fn wFdRead(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const fd = argU32(args, 0);
    const iovs = argU32(args, 1);
    const iovs_len = argU32(args, 2);
    const nread_ptr = argU32(args, 3);

    const e = w.get(fd) orelse return ret(results, errno.badf);
    var total: u64 = 0;
    switch (e.*) {
        .stdin => {
            if (w.stdin) |src| {
                var i: u32 = 0;
                while (i < iovs_len) : (i += 1) {
                    const iov = iovs + i * 8;
                    const buf = w.readU32(iov) orelse return ret(results, errno.fault);
                    const len = w.readU32(iov + 4) orelse return ret(results, errno.fault);
                    if (len == 0) continue;
                    const dst = w.slice(buf, len) orelse return ret(results, errno.fault);
                    const n = src.readSliceShort(dst) catch return ret(results, errno.io);
                    total += n;
                    if (n < len) break; // short read / EOF — don't block for more
                }
            }
        },
        .file => |*f| {
            if (f.rights_base & rights.fd_read == 0) return ret(results, errno.notcapable);
            const vecs = gatherIovecs(w, iovs, iovs_len, results) orelse return true;
            defer w.gpa.free(vecs);
            // readPositional returns 0 at end-of-file rather than erroring.
            total = f.handle.readPositional(w.io, vecs, f.offset) catch |err|
                return ret(results, errnoFor(err));
            f.offset += total;
        },
        .stdout, .stderr => return ret(results, errno.notcapable),
        .dir => return ret(results, errno.isdir),
    }
    if (!w.writeU32(nread_ptr, @intCast(total))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_pread(fd, iovs, iovs_len, offset, nread)` — read at `offset` without
/// disturbing the fd's position.
fn wFdPread(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    return preadWrite(ctx, args, results, .read);
}

/// `fd_pwrite(fd, iovs, iovs_len, offset, nwritten)`.
fn wFdPwrite(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    return preadWrite(ctx, args, results, .write);
}

fn preadWrite(ctx: *anyopaque, args: []const Value, results: []Value, comptime dir: enum { read, write }) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |*f| f,
        .dir => return ret(results, errno.isdir),
        else => return ret(results, errno.spipe), // stdio is not seekable
    };
    const need = if (dir == .read) rights.fd_read else rights.fd_write;
    if (f.rights_base & (need | rights.fd_seek) != (need | rights.fd_seek))
        return ret(results, errno.notcapable);

    const offset: u64 = @bitCast(interp.asI64(args[3]));
    const vecs = gatherIovecs(w, argU32(args, 1), argU32(args, 2), results) orelse return true;
    defer w.gpa.free(vecs);

    const n = switch (dir) {
        .read => f.handle.readPositional(w.io, vecs, offset),
        .write => f.handle.writePositional(w.io, vecs, offset),
    } catch |err| return ret(results, errnoFor(err));

    if (!w.writeU32(argU32(args, 4), @intCast(n))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_close(fd)` — release the host handle and free the guest fd for reuse.
fn wFdClose(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const fd = argU32(args, 0);
    const e = w.get(fd) orelse return ret(results, errno.badf);
    switch (e.*) {
        .file => |f| f.handle.close(w.io),
        .dir => |d| {
            if (d.owned) d.handle.close(w.io);
            if (d.preopen_name) |n| w.gpa.free(n);
        },
        else => return ret(results, errno.success), // closing stdio is a no-op
    }
    w.fds.items[fd] = null;
    return ret(results, errno.success);
}

/// `fd_renumber(from, to)` — move `from` onto `to`, closing whatever `to` was.
fn wFdRenumber(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const from = argU32(args, 0);
    const to = argU32(args, 1);
    if (w.get(from) == null or w.get(to) == null) return ret(results, errno.badf);
    if (from == to) return ret(results, errno.success);
    const closing = [_]Value{interp.i32Value(@bitCast(to))};
    var ignored = [_]Value{interp.i32Value(0)};
    _ = wFdClose(ctx, &closing, &ignored);
    w.fds.items[to] = w.fds.items[from];
    w.fds.items[from] = null;
    return ret(results, errno.success);
}

/// `fd_seek(fd, offset, whence, newoffset)` — reposition a file fd.
fn wFdSeek(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |*f| f,
        else => return ret(results, errno.spipe), // stdio/dirs are not seekable
    };
    if (f.rights_base & rights.fd_seek == 0) return ret(results, errno.notcapable);

    const delta = interp.asI64(args[1]);
    const whence = argU32(args, 2);
    const base: i128 = switch (whence) {
        0 => 0, // SET
        1 => @intCast(f.offset), // CUR
        2 => @intCast(f.handle.length(w.io) catch |err| return ret(results, errnoFor(err))), // END
        else => return ret(results, errno.inval),
    };
    const target = base + delta;
    if (target < 0) return ret(results, errno.inval); // seeking before byte 0
    f.offset = @intCast(target);
    if (!w.writeU64(argU32(args, 3), f.offset)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_tell(fd, offset)`.
fn wFdTell(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |*f| f,
        else => return ret(results, errno.spipe),
    };
    if (f.rights_base & rights.fd_tell == 0) return ret(results, errno.notcapable);
    if (!w.writeU64(argU32(args, 1), f.offset)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_sync(fd)` / `fd_datasync(fd)` — `Io.File.sync` covers both (it flushes
/// contents *and* metadata; there is no data-only split).
fn wFdSync(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    switch (e.*) {
        .file => |f| f.handle.sync(w.io) catch |err| return ret(results, errnoFor(err)),
        .stdout => w.stdout.flush() catch return ret(results, errno.io),
        .stderr => w.stderr.flush() catch return ret(results, errno.io),
        else => {},
    }
    return ret(results, errno.success);
}

/// `fd_fdstat_get(fd, stat)` — the fd's type, flags, and rights.
fn wFdFdstatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    // fdstat: { fs_filetype: u8, pad, fs_flags: u16, pad, rights_base: u64, rights_inheriting: u64 }
    const b = w.slice(argU32(args, 1), 24) orelse return ret(results, errno.fault);
    @memset(b, 0);
    switch (e.*) {
        // stdio reports as a character device with all rights, so wasi-libc
        // treats it as a tty.
        .stdin, .stdout, .stderr => {
            b[0] = filetype.character_device;
            std.mem.writeInt(u64, b[8..][0..8], std.math.maxInt(u64), .little);
            std.mem.writeInt(u64, b[16..][0..8], std.math.maxInt(u64), .little);
        },
        .dir => |d| {
            b[0] = filetype.directory;
            std.mem.writeInt(u64, b[8..][0..8], d.rights_base, .little);
            std.mem.writeInt(u64, b[16..][0..8], d.rights_inheriting, .little);
        },
        .file => |f| {
            const st = f.handle.stat(w.io) catch |err| return ret(results, errnoFor(err));
            b[0] = filetypeOf(st.kind);
            std.mem.writeInt(u16, b[2..][0..2], f.flags, .little);
            std.mem.writeInt(u64, b[8..][0..8], f.rights_base, .little);
            std.mem.writeInt(u64, b[16..][0..8], f.rights_inheriting, .little);
        },
    }
    return ret(results, errno.success);
}

/// `fd_fdstat_set_flags(fd, flags)` — only APPEND is meaningful here, and we
/// honor it in `fd_write` rather than at the host handle.
fn wFdFdstatSetFlags(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    switch (e.*) {
        .file => |*f| {
            if (f.rights_base & rights.fd_fdstat_set_flags == 0) return ret(results, errno.notcapable);
            f.flags = @truncate(argU32(args, 1));
        },
        else => {},
    }
    return ret(results, errno.success);
}

/// Write a 64-byte `filestat` at `at`.
fn writeFilestat(w: *Wasi, at: u32, st: Io.File.Stat) bool {
    const b = w.slice(at, 64) orelse return false;
    @memset(b, 0);
    // dev@0 has no source in Io.File.Stat — 0. ino@8, filetype@16, nlink@24,
    // size@32, atim@40, mtim@48, ctim@56.
    std.mem.writeInt(u64, b[8..][0..8], @intCast(st.inode), .little);
    b[16] = filetypeOf(st.kind);
    std.mem.writeInt(u64, b[24..][0..8], @intCast(st.nlink), .little);
    std.mem.writeInt(u64, b[32..][0..8], st.size, .little);
    // atime is optional (some systems refuse to report it) — fall back to mtime.
    std.mem.writeInt(u64, b[40..][0..8], timestampOf(st.atime orelse st.mtime), .little);
    std.mem.writeInt(u64, b[48..][0..8], timestampOf(st.mtime), .little);
    std.mem.writeInt(u64, b[56..][0..8], timestampOf(st.ctime), .little);
    return true;
}

/// `fd_filestat_get(fd, buf)`.
fn wFdFilestatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const st: Io.File.Stat = switch (e.*) {
        .file => |f| blk: {
            if (f.rights_base & rights.fd_filestat_get == 0) return ret(results, errno.notcapable);
            break :blk f.handle.stat(w.io) catch |err| return ret(results, errnoFor(err));
        },
        .dir => |d| d.handle.stat(w.io) catch |err| return ret(results, errnoFor(err)),
        // stdio has no stat; report a character device.
        else => {
            const b = w.slice(argU32(args, 1), 64) orelse return ret(results, errno.fault);
            @memset(b, 0);
            b[16] = filetype.character_device;
            return ret(results, errno.success);
        },
    };
    if (!writeFilestat(w, argU32(args, 1), st)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `fd_filestat_set_size(fd, size)` — truncate/extend.
fn wFdFilestatSetSize(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |f| f,
        else => return ret(results, errno.inval),
    };
    if (f.rights_base & rights.fd_filestat_set_size == 0) return ret(results, errno.notcapable);
    const size: u64 = @bitCast(interp.asI64(args[1]));
    f.handle.setLength(w.io, size) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// Translate a WASI `(atim, mtim, fstflags)` trio to `Io`'s timestamp options,
/// or null if the flags are invalid (both a value bit and its _NOW bit set for
/// the same timestamp — the guest asked for two different things at once).
fn timeSet(atim: u64, mtim: u64, flags: u16) ?struct { a: Io.File.SetTimestamp, m: Io.File.SetTimestamp } {
    if (flags & fstflags.atim != 0 and flags & fstflags.atim_now != 0) return null;
    if (flags & fstflags.mtim != 0 and flags & fstflags.mtim_now != 0) return null;
    return .{
        .a = if (flags & fstflags.atim_now != 0) .now else if (flags & fstflags.atim != 0) .{ .new = .{ .nanoseconds = @intCast(atim) } } else .unchanged,
        .m = if (flags & fstflags.mtim_now != 0) .now else if (flags & fstflags.mtim != 0) .{ .new = .{ .nanoseconds = @intCast(mtim) } } else .unchanged,
    };
}

/// `fd_filestat_set_times(fd, atim, mtim, fstflags)` — set access/modify times.
fn wFdFilestatSetTimes(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |f| f,
        else => return ret(results, errno.inval),
    };
    if (f.rights_base & rights.fd_filestat_set_times == 0) return ret(results, errno.notcapable);
    const atim: u64 = @bitCast(interp.asI64(args[1]));
    const mtim: u64 = @bitCast(interp.asI64(args[2]));
    const t = timeSet(atim, mtim, @truncate(argU32(args, 3))) orelse return ret(results, errno.inval);
    f.handle.setTimestamps(w.io, .{ .access_timestamp = t.a, .modify_timestamp = t.m }) catch |err|
        return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `fd_allocate(fd, offset, len)` — ensure the file is at least `offset+len`
/// bytes, extending (never shrinking) it. `Io` has no posix_fallocate, so we
/// extend via `setLength` when short; a file already large enough is untouched.
fn wFdAllocate(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const f = switch (e.*) {
        .file => |f| f,
        else => return ret(results, errno.badf),
    };
    if (f.rights_base & rights.fd_allocate == 0) return ret(results, errno.notcapable);
    const offset: u64 = @bitCast(interp.asI64(args[1]));
    const len: u64 = @bitCast(interp.asI64(args[2]));
    const need = std.math.add(u64, offset, len) catch return ret(results, errno.inval);
    const cur = f.handle.length(w.io) catch |err| return ret(results, errnoFor(err));
    if (need > cur) f.handle.setLength(w.io, need) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `fd_prestat_get(fd, buf)` — describe a preopen. wasi-libc walks fds upward
/// from 3 and stops at the first EBADF, so non-preopens must report EBADF.
fn wFdPrestatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const d = switch (e.*) {
        .dir => |d| d,
        else => return ret(results, errno.badf),
    };
    const name = d.preopen_name orelse return ret(results, errno.badf);
    // prestat: { tag: u8, pad, u: { dir: { pr_name_len: u32 } } } — len at +4.
    const b = w.slice(argU32(args, 1), 8) orelse return ret(results, errno.fault);
    @memset(b, 0);
    b[0] = 0; // preopentype = dir
    std.mem.writeInt(u32, b[4..][0..4], @intCast(name.len), .little);
    return ret(results, errno.success);
}

/// `fd_prestat_dir_name(fd, path, path_len)` — the guest-visible name.
fn wFdPrestatDirName(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const d = switch (e.*) {
        .dir => |d| d,
        else => return ret(results, errno.badf),
    };
    const name = d.preopen_name orelse return ret(results, errno.badf);
    const len = argU32(args, 2);
    if (len < name.len) return ret(results, errno.nametoolong);
    const b = w.slice(argU32(args, 1), len) orelse return ret(results, errno.fault);
    @memcpy(b[0..name.len], name);
    return ret(results, errno.success);
}

/// `path_open(dirfd, lookupflags, path, path_len, oflags, rights_base,
///            rights_inheriting, fdflags, opened_fd)` — the gateway into the
/// sandbox. The new fd's rights are capped by the dir fd's inheriting rights,
/// so a guest can never widen its own capability by reopening.
fn wPathOpen(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const follow = argU32(args, 1) & lookup_symlink_follow != 0;
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 2), argU32(args, 3), rights.path_open, follow, results) orelse
        return true;
    defer rp.close(w);

    const of: u16 = @truncate(argU32(args, 4));
    const want_base: u64 = @bitCast(interp.asI64(args[5]));
    const want_inheriting: u64 = @bitCast(interp.asI64(args[6]));
    const ff: u16 = @truncate(argU32(args, 7));
    const opened_fd_ptr = argU32(args, 8);

    // The walk already followed symlinks securely to a real final component. If
    // it stopped at a symlink, the guest asked NOT to follow (no SYMLINK_FOLLOW)
    // — you can't `open` a bare symlink as a file, so ELOOP (POSIX O_NOFOLLOW).
    if (rp.final_is_symlink) return ret(results, errno.loop);

    // A guest may only ever narrow: intersect with what the dir fd may pass on.
    const new_base = want_base & rp.inheriting;
    const new_inheriting = want_inheriting & rp.inheriting;

    if (of & oflags.directory != 0) {
        const dir = rp.dir.openDir(w.io, rp.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
            return ret(results, errnoFor(err));
        const fd = w.put(.{ .dir = .{
            .handle = dir,
            .rights_base = new_base,
            .rights_inheriting = new_inheriting,
        } }) catch {
            dir.close(w.io);
            return ret(results, errno.nomem);
        };
        if (!w.writeU32(opened_fd_ptr, fd)) return ret(results, errno.fault);
        return ret(results, errno.success);
    }

    const wants_read = new_base & rights.fd_read != 0;
    const wants_write = new_base & (rights.fd_write | rights.fd_filestat_set_size) != 0;

    const file: Io.File = if (of & oflags.creat != 0) blk: {
        if (rp.inheriting & rights.path_create_file == 0) return ret(results, errno.notcapable);
        // createFile is always write-capable; `read` widens it to read_write.
        break :blk rp.dir.createFile(w.io, rp.name, .{
            .read = wants_read,
            .truncate = of & oflags.trunc != 0,
            .exclusive = of & oflags.excl != 0,
        }) catch |err| return ret(results, errnoFor(err));
    } else blk: {
        // The walk resolved away any symlink (`final_is_symlink` was refused
        // above), so `rp.name` is a real file — opening with follow is a no-op
        // and avoids the Windows std bug where `openFile(.follow_symlinks =
        // false)` returns an async handle that crashes the first read
        // (Threaded.zig:5033, known-issues #18).
        const f = rp.dir.openFile(w.io, rp.name, .{
            .mode = if (wants_write and wants_read) .read_write else if (wants_write) .write_only else .read_only,
        }) catch |err| return ret(results, errnoFor(err));
        // O_TRUNC without O_CREAT: truncate after opening.
        if (of & oflags.trunc != 0) f.setLength(w.io, 0) catch |err| {
            f.close(w.io);
            return ret(results, errnoFor(err));
        };
        break :blk f;
    };

    const fd = w.put(.{ .file = .{
        .handle = file,
        .rights_base = new_base,
        .rights_inheriting = new_inheriting,
        .flags = ff,
    } }) catch {
        file.close(w.io);
        return ret(results, errno.nomem);
    };
    if (!w.writeU32(opened_fd_ptr, fd)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `path_filestat_get(dirfd, lookupflags, path, path_len, buf)`.
fn wPathFilestatGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const follow = argU32(args, 1) & lookup_symlink_follow != 0;
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 2), argU32(args, 3), rights.path_filestat_get, follow, results) orelse
        return true;
    defer rp.close(w);
    // The walk already followed per `follow`. With no-follow, `rp.name` may be a
    // symlink — stat it no-follow to describe the link itself (safe on Windows,
    // unlike openFile-nofollow).
    const st = rp.dir.statFile(w.io, rp.name, .{ .follow_symlinks = false }) catch |err|
        return ret(results, errnoFor(err));
    if (!writeFilestat(w, argU32(args, 4), st)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `path_filestat_set_times(dirfd, lookupflags, path, path_len, atim, mtim, fstflags)`.
fn wPathFilestatSetTimes(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const follow = argU32(args, 1) & lookup_symlink_follow != 0;
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 2), argU32(args, 3), rights.path_filestat_set_times, follow, results) orelse
        return true;
    defer rp.close(w);
    // The walk followed per `follow`; a leftover symlink final (no-follow) can't
    // be opened read_write below, so refuse it — set-times on a link itself is
    // uncommon and not supported here.
    if (rp.final_is_symlink) return ret(results, errno.loop);
    const atim: u64 = @bitCast(interp.asI64(args[4]));
    const mtim: u64 = @bitCast(interp.asI64(args[5]));
    const t = timeSet(atim, mtim, @truncate(argU32(args, 6))) orelse return ret(results, errno.inval);
    // Open the file and use the fd-based `setTimestamps`: `Io.Dir.setTimestamps`
    // (the path form) is an unimplemented `@panic("TODO")` on Windows (std;
    // sibling of #18). Opening with follow is safe — we already refused a
    // symlink — and dodges the #18 openFile-nofollow crash.
    const f = rp.dir.openFile(w.io, rp.name, .{ .mode = .read_write }) catch |err|
        return ret(results, errnoFor(err));
    defer f.close(w.io);
    f.setTimestamps(w.io, .{ .access_timestamp = t.a, .modify_timestamp = t.m }) catch |err|
        return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_link(old_dirfd, old_flags, old_path, old_len, new_dirfd, new_path, new_len)`
/// — a hard link. Both ends are resolved through the sandbox walk, so neither
/// may escape its preopen. The source follows a symlink only if `old_flags` asks
/// (`SYMLINK_FOLLOW`); the new name is created without following.
fn wPathLink(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const src_follow = argU32(args, 1) & lookup_symlink_follow != 0;
    var old = resolveArg(w, argU32(args, 0), argU32(args, 2), argU32(args, 3), rights.path_link_source, src_follow, results) orelse
        return true;
    defer old.close(w);
    var new = resolveArg(w, argU32(args, 4), argU32(args, 5), argU32(args, 6), rights.path_link_target, false, results) orelse
        return true;
    defer new.close(w);
    Io.Dir.hardLink(old.dir, old.name, new.dir, new.name, w.io, .{ .follow_symlinks = false }) catch |err|
        return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_symlink(old_path, old_len, dirfd, new_path, new_len)` — create a
/// symlink at `new_path` (inside the sandbox) whose target is `old_path`.
///
/// The *link's location* is contained by the walk (no-follow: we create the link
/// itself, not through one). The *target* is stored as given — it is only ever
/// resolved later through the same secure `walkFull`, where an escaping target
/// simply fails to escape at follow time. We still refuse an obviously-escaping
/// **absolute** target at creation (defence in depth: don't plant a landmine a
/// less careful reader might follow — the orchestrator-invariant concern in
/// `cmem/security-model.md`).
fn wPathSymlink(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const target = w.slice(argU32(args, 0), argU32(args, 1)) orelse return ret(results, errno.fault);
    if (isAbsoluteTarget(target)) return ret(results, errno.notcapable); // don't plant an escape
    if (std.mem.indexOfScalar(u8, target, 0) != null) return ret(results, errno.inval);
    var rp = resolveArg(w, argU32(args, 2), argU32(args, 3), argU32(args, 4), rights.path_open, false, results) orelse
        return true;
    defer rp.close(w);
    // Copy the target — `slice` borrows linear memory that `symLink` may outlive.
    const tgt = w.gpa.dupe(u8, target) catch return ret(results, errno.nomem);
    defer w.gpa.free(tgt);
    rp.dir.symLink(w.io, tgt, rp.name, .{}) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_readlink(dirfd, path, path_len, buf, buf_len, bufused)` — read a
/// symlink's target into the guest buffer (the link itself, never followed).
fn wPathReadlink(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 1), argU32(args, 2), rights.path_readlink, false, results) orelse
        return true;
    defer rp.close(w);
    const out = w.slice(argU32(args, 3), argU32(args, 4)) orelse return ret(results, errno.fault);
    // readLink truncates to the buffer; WASI reports the written length. Read
    // into a scratch buffer first so we control truncation semantics.
    var scratch: [4096]u8 = undefined;
    const cap = @min(out.len, scratch.len);
    const n = rp.dir.readLink(w.io, rp.name, scratch[0..cap]) catch |err| return ret(results, errnoFor(err));
    @memcpy(out[0..n], scratch[0..n]);
    if (!w.writeU32(argU32(args, 5), @intCast(n))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `path_create_directory(dirfd, path, path_len)`.
fn wPathCreateDirectory(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 1), argU32(args, 2), rights.path_create_directory, false, results) orelse
        return true;
    defer rp.close(w);
    rp.dir.createDir(w.io, rp.name, .default_dir) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_remove_directory(dirfd, path, path_len)`.
fn wPathRemoveDirectory(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 1), argU32(args, 2), rights.path_remove_directory, false, results) orelse
        return true;
    defer rp.close(w);
    rp.dir.deleteDir(w.io, rp.name) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_unlink_file(dirfd, path, path_len)` — removes the final component
/// itself (never follows it), so a symlink is unlinked, not its target.
fn wPathUnlinkFile(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var rp = resolveArg(w, argU32(args, 0), argU32(args, 1), argU32(args, 2), rights.path_unlink_file, false, results) orelse
        return true;
    defer rp.close(w);
    rp.dir.deleteFile(w.io, rp.name) catch |err| return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `path_rename(old_dirfd, old_path, old_len, new_dirfd, new_path, new_len)` —
/// both ends resolved independently (walk included), neither may escape; rename
/// acts on the final names without following them.
fn wPathRename(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    var old = resolveArg(w, argU32(args, 0), argU32(args, 1), argU32(args, 2), rights.path_rename_source, false, results) orelse
        return true;
    defer old.close(w);
    var new = resolveArg(w, argU32(args, 3), argU32(args, 4), argU32(args, 5), rights.path_rename_target, false, results) orelse
        return true;
    defer new.close(w);
    // `io` is the LAST parameter on the two-dir operations.
    Io.Dir.rename(old.dir, old.name, new.dir, new.name, w.io) catch |err|
        return ret(results, errnoFor(err));
    return ret(results, errno.success);
}

/// `fd_readdir(fd, buf, buf_len, cookie, bufused)` — serialize dirents into the
/// guest buffer, resuming at `cookie`.
///
/// `Io.Dir.Reader` has no arbitrary-cookie seek (only reset + skip forward), so
/// we restart the walk each call and skip `cookie` entries. That is O(n²) across
/// a full enumeration of a large directory, but it is correct and keeps no
/// per-fd iterator state alive between calls. Cookies 0 and 1 are the synthetic
/// `.` and `..` that std filters out but readdir consumers expect.
fn wFdReaddir(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const e = w.get(argU32(args, 0)) orelse return ret(results, errno.badf);
    const d = switch (e.*) {
        .dir => |d| d,
        else => return ret(results, errno.notdir),
    };
    if (d.rights_base & rights.fd_readdir == 0) return ret(results, errno.notcapable);

    const buf_ptr = argU32(args, 1);
    const buf_len = argU32(args, 2);
    const cookie: u64 = @bitCast(interp.asI64(args[3]));
    const out = w.slice(buf_ptr, buf_len) orelse return ret(results, errno.fault);

    var used: u32 = 0;
    var index: u64 = 0;

    // dirent: { d_next: u64, d_ino: u64, d_namlen: u32, d_type: u8 } = 24 bytes,
    // followed by the name. A truncated final entry is how a guest learns its
    // buffer was too small, so a partial copy is correct — not an error.
    const emit = struct {
        fn f(dst: []u8, u: *u32, name: []const u8, ino: u64, kind: u8, next: u64) bool {
            var hdr: [24]u8 = @splat(0);
            std.mem.writeInt(u64, hdr[0..8], next, .little);
            std.mem.writeInt(u64, hdr[8..16], ino, .little);
            std.mem.writeInt(u32, hdr[16..20], @intCast(name.len), .little);
            hdr[20] = kind;
            for ([2][]const u8{ &hdr, name }) |src| {
                const room = dst.len - u.*;
                const n = @min(room, src.len);
                @memcpy(dst[u.*..][0..n], src[0..n]);
                u.* += @intCast(n);
                if (n < src.len) return false; // buffer full
            }
            return true;
        }
    }.f;

    const self_ino: u64 = if (d.handle.stat(w.io)) |st| @intCast(st.inode) else |_| 0;
    for ([2][]const u8{ ".", ".." }) |dot| {
        defer index += 1;
        if (index < cookie) continue;
        if (!emit(out, &used, dot, if (index == 0) self_ino else 0, filetype.directory, index + 1)) break;
    }

    if (used < buf_len) {
        var rbuf: [Io.Dir.Reader.min_buffer_len * 2]u8 align(@alignOf(usize)) = undefined;
        var r = Io.Dir.Reader.init(d.handle, &rbuf);
        // `Entry.name` is invalidated by the next `next()`, so copy it out now.
        while (r.next(w.io) catch |err| return ret(results, errnoFor(err))) |entry| {
            defer index += 1;
            if (index < cookie) continue;
            if (!emit(out, &used, entry.name, @intCast(entry.inode), filetypeOf(entry.kind), index + 1)) break;
        }
    }

    if (!w.writeU32(argU32(args, 4), used)) return ret(results, errno.fault);
    return ret(results, errno.success);
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

/// The WASI clock id 0 is realtime; everything else maps to the monotonic clock.
fn clockOf(id: u32) Io.Clock {
    return if (id == 0) .real else .awake;
}

/// `clock_res_get(id, resolution)` — the clock's tick resolution, in ns.
fn wClockResGet(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const d = clockOf(argU32(args, 0)).resolution(w.io) catch return ret(results, errno.inval);
    // A zero resolution would be nonsense to a guest; report at least 1 ns.
    if (!w.writeU64(argU32(args, 1), @intCast(@max(d.nanoseconds, 1)))) return ret(results, errno.fault);
    return ret(results, errno.success);
}

// `poll_oneoff` record layout (§ preview-1): a 48-byte subscription and a
// 32-byte event.
const sub_size: u32 = 48;
const event_size: u32 = 32;
const subclock_abstime: u16 = 1;

/// Write one `event { userdata, error, type, fd_readwrite{nbytes, flags} }`.
fn writeEvent(w: *Wasi, at: u32, userdata: u64, err: u16, kind: u8) bool {
    const b = w.slice(at, event_size) orelse return false;
    @memset(b, 0);
    std.mem.writeInt(u64, b[0..8], userdata, .little);
    std.mem.writeInt(u16, b[8..10], err, .little);
    b[10] = kind;
    return true;
}

/// `poll_oneoff(in, out, nsubscriptions, nevents)` — block until a subscription
/// is ready, then report the ready events.
///
/// Scope: **clock** subscriptions sleep until the earliest deadline (this is what
/// `sleep()` compiles to), and **fd_read/fd_write** subscriptions on stdio report
/// ready immediately (stdio never blocks here). Real fd readiness polling is
/// deferred with the rest of the filesystem work.
fn wPollOneoff(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    const w: *Wasi = @ptrCast(@alignCast(ctx));
    const in = argU32(args, 0);
    const out = argU32(args, 1);
    const nsubs = argU32(args, 2);
    const nevents_ptr = argU32(args, 3);
    if (nsubs == 0) return ret(results, errno.inval);

    var emitted: u32 = 0;

    // fd subscriptions resolve now (they win over any timeout). A regular file
    // and stdio never block, so "ready" is the *correct* answer for them, not a
    // stub — the only fds where readiness is non-trivial are pipes/sockets,
    // which wazmrt doesn't have. A closed/invalid fd is reported EBADF rather
    // than a false "ready".
    var i: u32 = 0;
    while (i < nsubs) : (i += 1) {
        const s = in + i * sub_size;
        const userdata = w.readU64(s) orelse return ret(results, errno.fault);
        const tag = (w.slice(s + 8, 1) orelse return ret(results, errno.fault))[0];
        if (tag == 1 or tag == 2) { // fd_read / fd_write
            const fd = w.readU32(s + 16) orelse return ret(results, errno.fault);
            const err: u16 = if (w.get(fd) != null) errno.success else errno.badf;
            if (!writeEvent(w, out + emitted * event_size, userdata, @intCast(err), tag)) return ret(results, errno.fault);
            emitted += 1;
        }
    }

    // Otherwise sleep until the earliest clock deadline, then report those.
    if (emitted == 0) {
        var min_ns: ?i96 = null;
        i = 0;
        while (i < nsubs) : (i += 1) {
            const s = in + i * sub_size;
            const tag = (w.slice(s + 8, 1) orelse return ret(results, errno.fault))[0];
            if (tag != 0) continue; // clock
            const id = w.readU32(s + 16) orelse return ret(results, errno.fault);
            const timeout = w.readU64(s + 24) orelse return ret(results, errno.fault);
            const flags = w.readU16(s + 40) orelse return ret(results, errno.fault);
            var ns: i96 = @intCast(timeout);
            if (flags & subclock_abstime != 0) ns -= Io.Timestamp.now(w.io, clockOf(id)).nanoseconds;
            if (ns < 0) ns = 0;
            if (min_ns == null or ns < min_ns.?) min_ns = ns;
        }
        const ns = min_ns orelse return ret(results, errno.inval); // no clock subs either
        w.io.sleep(.fromNanoseconds(ns), .awake) catch {};
        i = 0;
        while (i < nsubs) : (i += 1) {
            const s = in + i * sub_size;
            const tag = (w.slice(s + 8, 1) orelse return ret(results, errno.fault))[0];
            if (tag != 0) continue;
            const userdata = w.readU64(s) orelse return ret(results, errno.fault);
            if (!writeEvent(w, out + emitted * event_size, userdata, errno.success, 0)) return ret(results, errno.fault);
            emitted += 1;
        }
    }

    if (!w.writeU32(nevents_ptr, emitted)) return ret(results, errno.fault);
    return ret(results, errno.success);
}

/// `proc_raise(sig)` — a raised signal terminates the guest; unwind as a trap.
fn wProcRaise(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    _ = results;
    return false; // -> error.HostTrap
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

fn wStubNotsup(ctx: *anyopaque, args: []const Value, results: []Value) bool {
    _ = ctx;
    _ = args;
    return ret(results, errno.notsup);
}

// --- Tests -----------------------------------------------------------------

fn testWasi(mem: *Memory, stdout: *Io.Writer) Wasi {
    var w: Wasi = .{
        .memory = mem,
        .stdout = stdout,
        .stderr = stdout,
        .io = undefined,
        .gpa = std.testing.allocator,
        .rng = std.Random.DefaultPrng.init(0),
    };
    w.fds.appendSlice(std.testing.allocator, &.{ .stdin, .stdout, .stderr }) catch unreachable;
    return w;
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
    defer w.fds.deinit(std.testing.allocator);

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
    defer w.fds.deinit(std.testing.allocator);

    const args = [_]Value{interp.i32Value(7)};
    try std.testing.expect(!wProcExit(&w, &args, &.{})); // false -> HostTrap
    try std.testing.expectEqual(@as(u32, 7), w.exit_code.?);
}

test "fd_read scatters stdin into the iovecs (and reports EOF)" {
    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    // two iovecs: {base=64,len=4} and {base=80,len=4}
    std.mem.writeInt(u32, mem_bytes[0..4], 64, .little);
    std.mem.writeInt(u32, mem_bytes[4..8], 4, .little);
    std.mem.writeInt(u32, mem_bytes[8..12], 80, .little);
    std.mem.writeInt(u32, mem_bytes[12..16], 4, .little);

    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    defer w.fds.deinit(std.testing.allocator);
    var in = Io.Reader.fixed("abcdefg"); // 7 bytes -> fills 4, then a short 3
    w.stdin = &in;

    const args = [_]Value{ interp.i32Value(0), interp.i32Value(0), interp.i32Value(2), interp.i32Value(120) };
    var results = [_]Value{interp.i32Value(-1)};
    try std.testing.expect(wFdRead(&w, &args, &results));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(results[0])); // SUCCESS
    try std.testing.expectEqual(@as(u32, 7), w.readU32(120).?); // nread
    try std.testing.expectEqualStrings("abcd", mem_bytes[64..68]);
    try std.testing.expectEqualStrings("efg", mem_bytes[80..83]);

    // Exhausted -> EOF reports 0 bytes, still SUCCESS.
    try std.testing.expect(wFdRead(&w, &args, &results));
    try std.testing.expectEqual(@as(u32, 0), w.readU32(120).?);

    // A non-stdin fd is EBADF.
    const bad = [_]Value{ interp.i32Value(5), interp.i32Value(0), interp.i32Value(2), interp.i32Value(120) };
    try std.testing.expect(wFdRead(&w, &bad, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.badf)), interp.asI32(results[0]));
}

test "poll_oneoff reports an fd subscription ready immediately" {
    var mem_bytes = [_]u8{0} ** 256;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    defer w.fds.deinit(std.testing.allocator);

    // one subscription at 0: userdata=42, tag=2 (fd_write)
    std.mem.writeInt(u64, mem_bytes[0..8], 42, .little);
    mem_bytes[8] = 2;

    const args = [_]Value{ interp.i32Value(0), interp.i32Value(128), interp.i32Value(1), interp.i32Value(200) };
    var results = [_]Value{interp.i32Value(-1)};
    try std.testing.expect(wPollOneoff(&w, &args, &results));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(results[0]));
    try std.testing.expectEqual(@as(u32, 1), w.readU32(200).?); // nevents
    // the event carries the userdata back, with no error and type=fd_write
    try std.testing.expectEqual(@as(u64, 42), w.readU64(128).?);
    try std.testing.expectEqual(@as(u16, 0), w.readU16(136).?); // error
    try std.testing.expectEqual(@as(u8, 2), mem_bytes[138]); // type

    // Zero subscriptions is invalid.
    const none = [_]Value{ interp.i32Value(0), interp.i32Value(128), interp.i32Value(0), interp.i32Value(200) };
    try std.testing.expect(wPollOneoff(&w, &none, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.inval)), interp.asI32(results[0]));

    // A subscription on a closed/invalid fd reports EBADF, not a false "ready".
    @memset(mem_bytes[0..16], 0);
    std.mem.writeInt(u64, mem_bytes[0..8], 7, .little); // userdata
    mem_bytes[8] = 1; // tag = fd_read
    std.mem.writeInt(u32, mem_bytes[16..20], 99, .little); // fd 99 — not open
    try std.testing.expect(wPollOneoff(&w, &args, &results));
    try std.testing.expectEqual(@as(u16, @intCast(errno.badf)), w.readU16(136).?);
}

test "fstflags translate to Io timestamp options (and reject value+NOW together)" {
    // NOW bits win; value bits carry the timestamp; unset = unchanged.
    const t = timeSet(111, 222, fstflags.atim_now | fstflags.mtim).?;
    try std.testing.expectEqual(Io.File.SetTimestamp.now, t.a);
    try std.testing.expectEqual(@as(i96, 222), t.m.new.nanoseconds);

    const none = timeSet(0, 0, 0).?;
    try std.testing.expectEqual(Io.File.SetTimestamp.unchanged, none.a);
    try std.testing.expectEqual(Io.File.SetTimestamp.unchanged, none.m);

    // Asking for both a value and NOW on the same timestamp is invalid.
    try std.testing.expectEqual(@as(?@TypeOf(none), null), timeSet(1, 2, fstflags.atim | fstflags.atim_now));
    try std.testing.expectEqual(@as(?@TypeOf(none), null), timeSet(1, 2, fstflags.mtim | fstflags.mtim_now));
}

test "resolve contains guest paths inside the preopen" {
    const gpa = std.testing.allocator;

    // Accepted, and normalized: `.` dropped, separators collapsed, an interior
    // `..` folded away — the result never reaches Io.Dir with a `..` left.
    const ok = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "a.txt", .want = "a.txt" },
        .{ .in = "./a.txt", .want = "a.txt" },
        .{ .in = "d/./e//f.txt", .want = "d/e/f.txt" },
        .{ .in = "d/../e.txt", .want = "e.txt" },
        .{ .in = "d/e/../../f.txt", .want = "f.txt" },
        .{ .in = "d\\e.txt", .want = "d/e.txt" }, // guests may use either separator
        .{ .in = ".", .want = "." },
    };
    for (ok) |c| {
        const got = resolve(gpa, c.in) orelse return error.UnexpectedlyRejected;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }

    // Rejected — each of these would name a file outside the preopen.
    const escapes = [_][]const u8{
        "..", // pop above the root
        "../etc/passwd",
        "a/../../b", // net escape, even though it dips inside first
        "/etc/passwd", // absolute POSIX
        "\\Windows\\x", // absolute Windows
        "C:\\Windows\\x", // drive-qualified
        "C:x", // drive-relative
        "\\\\?\\C:\\x", // NT/UNC prefix
        "a\x00b", // embedded NUL would truncate at the syscall
        "", // empty
    };
    for (escapes) |p| {
        if (resolve(gpa, p)) |got| {
            defer gpa.free(got);
            std.debug.print("escape not rejected: '{s}' -> '{s}'\n", .{ p, got });
            return error.SandboxEscaped;
        }
    }
}

test "symlink traversal: in-sandbox links follow, escaping links refused (#17/4.3)" {
    // The real-filesystem resolver test. Full traversal (4.3): an in-sandbox
    // symlink is FOLLOWED; a symlink whose target leaves the preopen is REFUSED
    // by the handle-stack (`..` can't rise above the root). Creating a symlink
    // needs privilege on Windows (Zig std uses raw FSCTL_SET_REPARSE_POINT), so
    // this SKIPS on an unprivileged Windows box; it runs on POSIX CI. The
    // Windows path is covered manually by `examples/wasi_symlink_traversal.zig`.
    const gpa = std.testing.allocator;
    const tio = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // tmp/outside/secret.txt is OUTSIDE the preopen; tmp/pre is the preopen.
    try tmp.dir.createDir(tio, "outside", .default_dir);
    try tmp.dir.createDir(tio, "pre", .default_dir);
    try tmp.dir.createDir(tio, "pre/sub", .default_dir);
    {
        const f = try tmp.dir.createFile(tio, "outside/secret.txt", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "SECRET");
    }
    {
        const f = try tmp.dir.createFile(tio, "pre/sub/inside.txt", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "ok");
    }
    var pre = try tmp.dir.openDir(tio, "pre", .{ .iterate = true });
    // Plant the links. If we can't make one, there's nothing to test — skip.
    pre.symLink(tio, "sub", "inlink", .{ .is_directory = true }) catch { // in-sandbox
        pre.close(tio);
        return error.SkipZigTest;
    };
    pre.symLink(tio, "../outside", "dlink", .{ .is_directory = true }) catch { // escapes
        pre.close(tio);
        return error.SkipZigTest;
    };
    pre.symLink(tio, "../outside/secret.txt", "flink", .{}) catch { // escapes
        pre.close(tio);
        return error.SkipZigTest;
    };

    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = Wasi.init(gpa, tio, &ow, &ow, 0);
    defer w.deinit(); // closes the preopen (owned) + any fd path_open opened
    w.memory = &mem;
    try w.fds.append(gpa, .{ .dir = .{ .handle = pre, .preopen_name = null, .owned = true } });

    const openErrno = struct {
        fn f(wasi: *Wasi, buf: []u8, path: []const u8) u32 {
            @memcpy(buf[0..path.len], path);
            var results = [_]Value{interp.i32Value(-1)};
            const args = [_]Value{
                interp.i32Value(3), // dirfd = the preopen
                interp.i32Value(1), // lookupflags = SYMLINK_FOLLOW
                interp.i32Value(0), // path ptr
                interp.i32Value(@intCast(path.len)),
                interp.i32Value(0), // oflags
                interp.i64Value(@bitCast(rights.all)),
                interp.i64Value(@bitCast(rights.all)),
                interp.i32Value(0), // fdflags
                interp.i32Value(120), // opened-fd out
            };
            _ = wPathOpen(wasi, &args, &results);
            return @bitCast(interp.asI32(results[0]));
        }
    }.f;

    // Refusal = any error that isn't SUCCESS (ENOTCAPABLE / ELOOP), which would
    // mean we followed the link out.
    const refused = struct {
        fn ok(e: u32) bool {
            return e != errno.success;
        }
    }.ok;

    // In-sandbox symlink IS followed now.
    try std.testing.expectEqual(errno.success, openErrno(&w, &mem_bytes, "inlink/inside.txt"));
    // Escaping symlinks refused, intermediate and final.
    try std.testing.expect(refused(openErrno(&w, &mem_bytes, "dlink/secret.txt")));
    try std.testing.expect(refused(openErrno(&w, &mem_bytes, "flink")));
}

test "symlink resolver fuzz: no adversarial topology reaches outside the preopen" {
    // The mandated adversarial test for the security-critical resolver
    // (`cmem/security-model.md`): plant random symlink graphs — in-sandbox,
    // escaping via `..`, absolute to a canary, chains, cycles — then hammer
    // random guest paths and assert the CANARY content (a file outside the
    // preopen) is NEVER read, and nothing hangs. POSIX CI; skips on unprivileged
    // Windows (can't create symlinks). The oracle is the canary, not a value.
    const gpa = std.testing.allocator;
    const tio = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(tio, "outside", .default_dir);
    try tmp.dir.createDir(tio, "pre", .default_dir);
    {
        const f = try tmp.dir.createFile(tio, "outside/canary.txt", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "CANARY-LEAKED");
    }
    var pre = try tmp.dir.openDir(tio, "pre", .{ .iterate = true });
    // A real in-sandbox file, so some paths legitimately resolve.
    {
        const f = pre.createFile(tio, "real.txt", .{}) catch {
            pre.close(tio);
            return error.SkipZigTest;
        };
        f.close(tio);
    }

    // Plant a set of links with adversarial targets. `l0..l7`.
    const targets = [_][]const u8{
        "real.txt", // in-sandbox
        "..", // escape attempt (parent)
        "../outside", // escape to the canary dir
        "../outside/canary.txt", // direct escape to canary
        "l4", // chain -> l4
        "l3", // l4 -> l3 (so l5->l4->l3->canary): a chain to the escape
        "l6", // cycle: l6 -> l7
        "l6", // l7 -> l6 (cycle)
    };
    for (targets, 0..) |t, i| {
        var name: [4]u8 = undefined;
        const nm = std.fmt.bufPrint(&name, "l{d}", .{i}) catch unreachable;
        pre.symLink(tio, t, nm, .{}) catch {
            pre.close(tio);
            return error.SkipZigTest; // no symlink support here
        };
    }
    // An absolute-target link to the host root — must re-base to the preopen,
    // never reach the host `/etc/passwd` etc. (absolute-to-canary is covered by
    // examples/wasi_symlink_traversal.zig on Windows).
    pre.symLink(tio, "/outside/canary.txt", "labs", .{}) catch {
        pre.close(tio);
        return error.SkipZigTest;
    };

    var mem_bytes = [_]u8{0} ** 256;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = Wasi.init(gpa, tio, &ow, &ow, 0);
    defer w.deinit();
    w.memory = &mem;
    try w.fds.append(gpa, .{ .dir = .{ .handle = pre, .preopen_name = null, .owned = true } });

    const names = [_][]const u8{ "l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7", "labs", "real.txt", "..", "sub" };

    var prng = std.Random.DefaultPrng.init(0x5217);
    const rng = prng.random();
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        // Build a random path of 1–4 components from the link/name set.
        var path_buf: [128]u8 = undefined;
        var len: usize = 0;
        const parts = rng.intRangeAtMost(usize, 1, 4);
        var p: usize = 0;
        while (p < parts) : (p += 1) {
            if (p != 0) {
                path_buf[len] = '/';
                len += 1;
            }
            const seg = names[rng.uintLessThan(usize, names.len)];
            @memcpy(path_buf[len..][0..seg.len], seg);
            len += seg.len;
        }
        const path = path_buf[0..len];

        // Resolve + open + read; assert we never read the canary.
        @memset(mem_bytes[0..200], 0);
        @memcpy(mem_bytes[0..path.len], path);
        var results = [_]Value{interp.i32Value(-1)};
        const args = [_]Value{
            interp.i32Value(3),                      interp.i32Value(1), // dirfd, SYMLINK_FOLLOW
            interp.i32Value(0),                      interp.i32Value(@intCast(path.len)),
            interp.i32Value(0),                      interp.i64Value(@bitCast(rights.all)),
            interp.i64Value(@bitCast(rights.all)),   interp.i32Value(0),
            interp.i32Value(200), // opened-fd out
        };
        _ = wPathOpen(&w, &args, &results);
        if (interp.asI32(results[0]) != 0) continue; // refused — good
        const fd = w.readU32(200).?;
        // Read it (into guest memory at 220, len 32) and check for the canary.
        std.mem.writeInt(u32, mem_bytes[208..212], 220, .little); // iovec.base
        std.mem.writeInt(u32, mem_bytes[212..216], 32, .little); // iovec.len
        var rres = [_]Value{interp.i32Value(-1)};
        const rargs = [_]Value{ interp.i32Value(@bitCast(fd)), interp.i32Value(208), interp.i32Value(1), interp.i32Value(240) };
        _ = wFdRead(&w, &rargs, &rres);
        const nread = w.readU32(240) orelse 0;
        const content = mem_bytes[220..][0..@min(nread, 32)];
        if (std.mem.indexOf(u8, content, "CANARY") != null) {
            std.debug.print("LEAK via path '{s}'\n", .{path});
            return error.SandboxEscaped;
        }
        // close the fd
        var cres = [_]Value{interp.i32Value(-1)};
        const cargs = [_]Value{interp.i32Value(@bitCast(fd))};
        _ = wFdClose(&w, &cargs, &cres);
    }
}

test "path_open rejects an escaping path with ENOTCAPABLE before touching the host" {
    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    defer w.fds.deinit(std.testing.allocator);

    // fd 3: a preopen dir. `io` is undefined in this test, so a call that
    // reached the host would crash — proving the rejection is purely lexical.
    try w.fds.append(std.testing.allocator, .{ .dir = .{
        .handle = .{ .handle = undefined },
        .preopen_name = null,
        .owned = false,
    } });

    const path = "../../etc/passwd";
    @memcpy(mem_bytes[0..path.len], path);
    var results = [_]Value{interp.i32Value(-1)};
    const args = [_]Value{
        interp.i32Value(3), // dirfd
        interp.i32Value(1), // lookupflags = SYMLINK_FOLLOW
        interp.i32Value(0), // path ptr
        interp.i32Value(path.len),
        interp.i32Value(0), // oflags
        interp.i64Value(@bitCast(rights.all)), // rights_base
        interp.i64Value(@bitCast(rights.all)), // rights_inheriting
        interp.i32Value(0), // fdflags
        interp.i32Value(64), // opened_fd out
    };
    try std.testing.expect(wPathOpen(&w, &args, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.notcapable)), interp.asI32(results[0]));
}

test "read-only preopen rights can never yield a writable child fd (--ro-dir)" {
    // The security contract behind `--ro-dir`: a read-only preopen omits every
    // mutating right, and `path_open` only ever *narrows* (new_inheriting =
    // want_inheriting & dir.inheriting). So no matter what a guest asks for,
    // nothing opened under a read-only preopen can gain a write right.
    const ro = readOnlyRights;

    // The mask itself carries no mutating right...
    try std.testing.expectEqual(@as(u64, 0), ro & rights.write_mask);
    inline for (.{
        rights.fd_write,          rights.path_create_file, rights.path_create_directory,
        rights.path_unlink_file,  rights.path_remove_directory, rights.path_link_source,
        rights.path_rename_source, rights.fd_filestat_set_size, rights.fd_allocate,
    }) |bit| {
        try std.testing.expectEqual(@as(u64, 0), ro & bit);
    }
    // ...yet keeps the read rights that make it useful.
    try std.testing.expect(ro & rights.fd_read != 0);
    try std.testing.expect(ro & rights.path_open != 0);
    try std.testing.expect(ro & rights.fd_readdir != 0);

    // The intersection path_open performs: even a guest that requests *all*
    // rights (rights.all) under a read-only dir fd is narrowed to no writes.
    const child_inheriting = rights.all & ro;
    try std.testing.expectEqual(@as(u64, 0), child_inheriting & rights.write_mask);
    // A read-write preopen, by contrast, does pass write rights through.
    try std.testing.expect((rights.all & allRights) & rights.fd_write != 0);
}

test "fd_prestat_get/dir_name enumerate preopens and stop at the first non-preopen" {
    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    defer w.fds.deinit(std.testing.allocator);

    try w.fds.append(std.testing.allocator, .{ .dir = .{
        .handle = .{ .handle = undefined },
        .preopen_name = "/sandbox",
        .owned = false,
    } });

    var results = [_]Value{interp.i32Value(-1)};
    const pre = [_]Value{ interp.i32Value(3), interp.i32Value(0) };
    try std.testing.expect(wFdPrestatGet(&w, &pre, &results));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(results[0]));
    try std.testing.expectEqual(@as(u8, 0), mem_bytes[0]); // preopentype = dir
    try std.testing.expectEqual(@as(u32, 8), w.readU32(4).?); // len("/sandbox")

    const name = [_]Value{ interp.i32Value(3), interp.i32Value(16), interp.i32Value(8) };
    try std.testing.expect(wFdPrestatDirName(&w, &name, &results));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(results[0]));
    try std.testing.expectEqualStrings("/sandbox", mem_bytes[16..24]);

    // fd 4 doesn't exist -> EBADF, which is how wasi-libc stops enumerating.
    const done = [_]Value{ interp.i32Value(4), interp.i32Value(0) };
    try std.testing.expect(wFdPrestatGet(&w, &done, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.badf)), interp.asI32(results[0]));

    // So is stdout: it's an fd, but not a preopen.
    const nope = [_]Value{ interp.i32Value(1), interp.i32Value(0) };
    try std.testing.expect(wFdPrestatGet(&w, &nope, &results));
    try std.testing.expectEqual(@as(i32, @bitCast(errno.badf)), interp.asI32(results[0]));
}

test "args_sizes_get + args_get round-trip argv into memory" {
    var mem_bytes = [_]u8{0} ** 128;
    var mem = Memory{ .bytes = &mem_bytes, .max = null };
    var obuf: [8]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);
    var w = testWasi(&mem, &ow);
    defer w.fds.deinit(std.testing.allocator);
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
