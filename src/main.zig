//! wazmrt CLI — decode a WebAssembly binary and print a summary of its
//! sections. A thin front-end over the `wazmrt` library module.

const std = @import("std");
const Io = std.Io;

const wazmrt = @import("wazmrt");
const build_options = @import("build_options");

/// The signature trust anchor embedded at build time via `-Droot-key=<hex>`
/// (empty ⇒ `null` ⇒ verification inert). Only the CLI reads it, so the build
/// option is wired only into this module — `sign.zig` stays plumbing-free.
const embedded_root_key: ?[wazmrt.sign.pubkey_len]u8 = wazmrt.sign.rootKeyFromHex(build_options.root_key_hex);

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const prog = if (args.len > 0) args[0] else "wazmrt";
    if (args.len < 2) {
        try printUsage(out, prog);
        return;
    }

    // `-h`/`--help` and `-v`/`--version` are only recognized as the FIRST arg, so
    // a `--help` in a guest's argv (`wazmrt prog.wasm -- --help`) is never ours.
    if (isFlag(args[1], "-h", "--help")) return printHelp(out, prog);
    if (isFlag(args[1], "-v", "--version")) return printVersion(out);

    // `wazmrt pin <file> [--db <path>]` — hash a module for the pin DB (Phase 5).
    if (std.mem.eql(u8, args[1], "pin")) return pinSubcommand(arena, io, out, args[2..]);

    // Publisher-side signing tools (authenticity):
    //   wazmrt keygen [--out <name>]                    — new Ed25519 keypair
    //   wazmrt sign <in> <out> --key <keyfile>          — sign a module
    if (std.mem.eql(u8, args[1], "keygen")) return keygenSubcommand(arena, io, out, args[2..]);
    if (std.mem.eql(u8, args[1], "sign")) return signSubcommand(arena, io, out, args[2..]);

    const path = args[1];
    var bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };

    // .wast script mode: parse + run the assertions, print a pass/fail summary.
    if (std.mem.endsWith(u8, path, ".wast")) {
        // `runScript` INSTANTIATES AND INVOKES the script's modules — including
        // `(module binary "…")` raw payloads — so this path executes and must be
        // gated exactly like a module. It used to `return` before the gate below,
        // which meant `wazmrt payload.wast` ran unpinned, unsigned wasm even
        // under a root-owned `# mode: enforce` that this project documents as
        // absolute. Any wasm can be wrapped in a `.wast`, and the attacker
        // chooses the extension, so the bypass needed no privilege.
        //
        // Hashing the script bytes is the right granularity: every module the
        // script runs is *contained in* those bytes, so authorizing the script
        // authorizes exactly what it can execute — the same
        // hash-what-you-execute property `verifyGate` has for a module.
        if (!(try verifyGate(arena, io, out, bytes, path, args[2..]))) return;

        const s = wazmrt.wast.runScript(arena, bytes) catch |e| {
            try out.print("error: cannot run '{s}': {s}\n", .{ path, @errorName(e) });
            return;
        };
        try out.print("{s}: {d} passed, {d} failed, {d} skipped\n", .{ path, s.passed, s.failed, s.skipped });
        if (s.first_failure) |f| try out.print("  first failure: {s}\n", .{f});
        return;
    }

    // .wat text: assemble to a binary, then treat it like a .wasm.
    if (std.mem.endsWith(u8, path, ".wat")) {
        bytes = wazmrt.wat.assemble(arena, bytes) catch |e| {
            try out.print("error: cannot assemble '{s}': {s}\n", .{ path, @errorName(e) });
            return;
        };
    }

    var module = wazmrt.decode(arena, bytes) catch |e| {
        try out.print("error: cannot decode '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };
    defer module.deinit();

    // Pin verification (Phase 5) gates *execution*: before we run anything, the
    // in-memory `bytes` (exactly what we execute — TOCTOU-safe) are hashed and
    // checked against the root-owned pin DB per the enforcement policy. The
    // summarize path below never executes, so it is never gated.
    const will_execute = (args.len >= 3 and findExport(&module, args[2]) != null) or
        findExport(&module, "_start") != null;
    if (will_execute and !(try verifyGate(arena, io, out, bytes, path, args[2..]))) return;

    // Run mode: `wazmrt <module.wasm> <export> [args...]` — invoke and print.
    // A trailing arg only selects an export if it actually names one; otherwise
    // it belongs to the WASI command below (`--dir …`, guest argv, …).
    if (args.len >= 3 and findExport(&module, args[2]) != null) {
        try runFunction(arena, out, &module, args[2], args[3..]);
        return;
    }

    // WASI command: `wazmrt <module.wasm> [--dir <host>[:<guest>]]... [args...]`
    // runs `_start` with the `wasi_snapshot_preview1` host imports wired up.
    if (findExport(&module, "_start")) |start_index| {
        const code = runWasi(arena, io, out, &module, path, start_index, args[2..]) catch |e| {
            if (e != AlreadyReported) try out.print("trap: {s}\n", .{@errorName(e)});
            return;
        };
        if (code != 0) try out.print("(exit {d})\n", .{code});
        return;
    }

    try out.print("{s}: valid wasm v{d}, {d} section(s)\n", .{ path, module.version, module.sections.len });
    for (module.sections) |s| {
        try out.print("  - {s} (payload {d} bytes @ 0x{x})\n", .{ @tagName(s.id), s.size, s.offset });
    }

    var code_bytes: usize = 0;
    for (module.code) |c| code_bytes += c.body.len;
    try out.print("  types={d} imports={d} functions={d} exports={d} code={d} ({d} body bytes)\n", .{
        module.comp_types.len, module.imports.len, module.functions.len,
        module.exports.len,    module.code.len,    code_bytes,
    });
    for (module.imports) |i| {
        try out.print("  import {s}.{s} : {s}\n", .{ i.module, i.name, @tagName(i.type.kind()) });
    }
    for (module.exports) |e| {
        try out.print("  export {s} : {s} #{d}\n", .{ e.name, @tagName(e.type.kind()), e.index });
    }

    // Decode each function body into the instruction IR (opcode.decodeBody).
    var ok: usize = 0;
    for (module.code, 0..) |c, i| {
        const instrs = wazmrt.opcode.decodeBody(arena, c.body) catch |e| {
            try out.print("  fn[{d}]: body decode FAILED — {s}\n", .{ i, @errorName(e) });
            continue;
        };
        ok += 1;
        try out.print("  fn[{d}]: {d} instr, {d} locals\n", .{ i, instrs.len, c.localCount() });
    }
    if (module.code.len != 0) {
        try out.print("  bodies decoded: {d}/{d}\n", .{ ok, module.code.len });
    }

    wazmrt.validate(arena, &module) catch |e| {
        try out.print("  validation: FAILED — {s}\n", .{@errorName(e)});
        return;
    };
    try out.print("  validation: OK\n", .{});
}

/// True if `arg` is either the short or long spelling of a flag.
fn isFlag(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

/// Brief usage, printed with no arguments. Points at `--help` for the full list.
fn printUsage(out: *Io.Writer, prog: []const u8) !void {
    try out.print(
        \\wazmrt {s} — a WebAssembly runtime (decode, validate, execute; WASI preview 1)
        \\
        \\usage: {s} <module.wasm|.wat|.wast> [export] [args...]
        \\       {s} <pin|keygen|sign> ...
        \\
        \\Run '{s} --help' for the full list of options and subcommands.
        \\
    , .{ wazmrt.version, prog, prog, prog });
}

/// Version info: `-v` / `--version`. Also reports whether this build embedded a
/// signature trust anchor (`-Droot-key`), which determines the default policy.
fn printVersion(out: *Io.Writer) !void {
    try out.print("wazmrt {s} (abi {d})\n", .{ wazmrt.version, wazmrt.abi_version });
    if (embedded_root_key != null)
        try out.print("signature trust anchor: embedded (verification armed)\n", .{})
    else
        try out.print("signature trust anchor: none (build with -Droot-key=<hex> to embed one)\n", .{});
}

/// Full help: `-h` / `--help`. Describes every run mode, flag, and subcommand.
fn printHelp(out: *Io.Writer, prog: []const u8) !void {
    try out.print(
        \\wazmrt {s} — a WebAssembly runtime (decode, validate, execute; WASI preview 1)
        \\
        \\A <module> is a `.wasm` binary or a `.wat` text file (assembled on the fly).
        \\
        \\USAGE
        \\  {s} <module> <export> [args...]   invoke an exported function and print results
        \\  {s} <module> [wasi-flags] [-- argv]  run a WASI `_start` command module
        \\  {s} <module>                      summarize + validate (no matching export/_start)
        \\  {s} <script.wast>                 run a spec-test (.wast) script
        \\  {s} <subcommand> ...              pin / keygen / sign (below)
        \\  {s} -h | --help | -v | --version
        \\
        \\RUN MODES
        \\  {s} add.wasm add 2 3
        \\      Instantiate and call `add` with args 2 and 3 (parsed per the function's
        \\      parameter types: i32/i64/f32/f64). No imports are wired, so a bare
        \\      function call has zero I/O capability.
        \\  {s} prog.wasm --dir .:/ -- foo bar
        \\      If the module exports `_start`, run it as a WASI command. wazmrt flags
        \\      precede the guest argv; `--` ends them and passes the rest to the guest.
        \\
        \\WASI FLAGS (before `--`)
        \\  --dir <host>[:<guest>]      grant a read-write preopen (the guest's only files)
        \\  --ro-dir <host>[:<guest>]   grant a read-only preopen (no write/create/delete)
        \\  --env KEY=VALUE             set one environment variable for the guest
        \\  --max-memory <size>         linear-memory ceiling for a WASI command (default 1G; e.g. 512M, 2G)
        \\                              the default ceiling applies to every run mode
        \\  --                          end wazmrt flags; the rest is the guest's argv
        \\
        \\VERIFICATION FLAGS (authenticity — see the pin DB / signatures)
        \\  --pins <path>               use this pin DB instead of the default;
        \\                              ignored under a root-owned `# mode: enforce`
        \\  --verify off|warn|enforce   raise verification strictness (never lowers it)
        \\  --no-verify, --yes          run an unverified module (refused under enforce)
        \\      Default pin DB: {s}
        \\
        \\SUBCOMMANDS
        \\  pin <file|dir> [--db <path>]
        \\      SHA-256 a module (or every `.wasm`/`.wat` under a directory, recursively)
        \\      and print its pin line(s) for a root-owned allow-list. With --db, also
        \\      append them there. Meant to be run with privilege by an installer.
        \\  keygen [--out <name>]
        \\      Generate an Ed25519 signing keypair: writes `<name>.key` (private — keep
        \\      secret) and prints the public key to embed as the trust anchor.
        \\  sign <in.wasm|.wat> <out.wasm> --key <keyfile>
        \\      Sign a module with the private key, appending a "signature" custom section.
        \\      The signed module still runs anywhere; wazmrt authenticates it when the
        \\      matching root key is embedded (-Droot-key).
        \\
        \\OPTIONS
        \\  -h, --help                  show this help and exit
        \\  -v, --version               show version information and exit
        \\
    , .{ wazmrt.version, prog, prog, prog, prog, prog, prog, prog, prog, defaultPinsPath() });
}

// ===== Phase 5 — pin verification (see cmem/security-model.md, roadmap.md §5) =====

/// One computed pin: the module's hex digest and a human label (its path).
const PinEntry = struct { hex: wazmrt.pin.Hex, label: []const u8 };

/// `wazmrt pin <file|dir> [--db <path>]` — SHA-256 a module (or every `.wasm`/
/// `.wat` under a directory, recursively) and emit its pin line(s). Prints
/// `<hex>  <label>` (redirect/append into a root-owned pin DB); with `--db
/// <path>` also appends there. Meant to be run with privilege by an installer —
/// the runtime only ever *reads* the DB. The **directory** form lets a packager
/// pin a whole bundle in one step.
fn pinSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !void {
    var target: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--db") and i + 1 < rest.len) {
            db_path = rest[i + 1];
            i += 1;
        } else if (target == null and !std.mem.startsWith(u8, rest[i], "--")) {
            target = rest[i];
        }
    }
    if (target == null) {
        try out.print("usage: wazmrt pin <file|dir> [--db <path>]\n", .{});
        return;
    }

    const st = Io.Dir.cwd().statFile(io, target.?, .{}) catch |e| {
        try out.print("error: cannot stat '{s}': {s}\n", .{ target.?, @errorName(e) });
        return;
    };

    var entries: std.ArrayList(PinEntry) = .empty;
    if (st.kind == .directory) {
        collectDirPins(arena, io, out, target.?, &entries) catch |e| {
            try out.print("error: cannot scan '{s}': {s}\n", .{ target.?, @errorName(e) });
            return;
        };
        if (entries.items.len == 0) {
            try out.print("(no .wasm/.wat files under {s})\n", .{target.?});
            return;
        }
        // Deterministic output regardless of directory-iteration order.
        std.mem.sort(PinEntry, entries.items, {}, pinEntryLess);
    } else {
        const hex = hashModuleFile(arena, io, target.?) catch |e| {
            try out.print("error: cannot pin '{s}': {s}\n", .{ target.?, @errorName(e) });
            return;
        };
        try entries.append(arena, .{ .hex = hex, .label = target.? });
    }

    for (entries.items) |e| try out.print("{s}  {s}\n", .{ &e.hex, e.label });
    if (db_path) |p| {
        appendPinLines(arena, io, p, entries.items) catch |e| {
            try out.print("error: cannot append to pin DB '{s}': {s}\n", .{ p, @errorName(e) });
            return;
        };
        try out.print("pinned {d} module(s) to {s}\n", .{ entries.items.len, p });
    }
}

/// Hash the module at `path`, assembling a `.wat` first so the pinned digest
/// matches the *binary* the gate hashes at run time (not the source text).
fn hashModuleFile(arena: std.mem.Allocator, io: Io, path: []const u8) !wazmrt.pin.Hex {
    var bytes: []const u8 = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    if (std.mem.endsWith(u8, path, ".wat")) bytes = try wazmrt.wat.assemble(arena, bytes);
    return wazmrt.pin.hashHex(bytes);
}

fn pinEntryLess(_: void, a: PinEntry, b: PinEntry) bool {
    return std.mem.lessThan(u8, a.label, b.label);
}

/// Recursively collect a pin for every `.wasm`/`.wat` under `dir_path`. A file
/// that can't be read or assembled is skipped with a warning (one bad module
/// shouldn't abort pinning a whole bundle).
fn collectDirPins(arena: std.mem.Allocator, io: Io, out: *Io.Writer, dir_path: []const u8, entries: *std.ArrayList(PinEntry)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |ent| {
        if (ent.kind != .file) continue;
        const is_wat = std.mem.endsWith(u8, ent.basename, ".wat");
        if (!is_wat and !std.mem.endsWith(u8, ent.basename, ".wasm")) continue;
        // Read via the entry's own directory handle + basename (avoids
        // NameTooLong on deep trees). `ent.path`/`ent.basename` are invalidated
        // by the next `walker.next`, so copy the label now.
        var bytes: []const u8 = ent.dir.readFileAlloc(io, ent.basename, arena, .limited(64 << 20)) catch |e| {
            try out.print("warning: skipping '{s}': {s}\n", .{ ent.path, @errorName(e) });
            continue;
        };
        if (is_wat) bytes = wazmrt.wat.assemble(arena, bytes) catch |e| {
            try out.print("warning: skipping '{s}': cannot assemble ({s})\n", .{ ent.path, @errorName(e) });
            continue;
        };
        const label = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, ent.path });
        try entries.append(arena, .{ .hex = wazmrt.pin.hashHex(bytes), .label = label });
    }
}

/// Append `<hex>  <label>` lines to a pin DB, rewriting the whole (small) file.
/// If the parent directory is missing the write fails — that is the installer's
/// job to create, and a clear error beats silently succeeding.
fn appendPinLines(arena: std.mem.Allocator, io: Io, path: []const u8, entries: []const PinEntry) !void {
    const prev: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, prev);
    if (prev.len > 0 and prev[prev.len - 1] != '\n') try buf.append(arena, '\n');
    for (entries) |e| {
        try buf.appendSlice(arena, &e.hex);
        try buf.appendSlice(arena, "  ");
        try buf.appendSlice(arena, e.label);
        try buf.append(arena, '\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

// ===== Authenticity — publisher-side signing (see cmem/security-model.md) =====

/// `wazmrt keygen [--out <name>]` — generate an Ed25519 signing keypair. Writes
/// the **private** seed (hex) to `<name>.key` and prints the **public** key hex
/// to embed as the verifier's trust anchor. The private key file must be kept
/// secret (a production signer would hold it in an HSM/YubiKey/KMS instead).
fn keygenSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !void {
    const name = flagValue(rest, "--out") orelse "wazmrt_root";
    const kp = wazmrt.sign.Ed25519.KeyPair.generate(io); // entropy from the Io
    const seed_hex = wazmrt.pin.toHex(kp.secret_key.seed());
    const pub_hex = wazmrt.pin.toHex(kp.public_key.bytes);
    const key_path = try std.fmt.allocPrint(arena, "{s}.key", .{name});
    const key_text = try std.fmt.allocPrint(arena, "{s}\n", .{&seed_hex});
    Io.Dir.cwd().writeFile(io, .{ .sub_path = key_path, .data = key_text }) catch |e| {
        try out.print("error: cannot write '{s}': {s}\n", .{ key_path, @errorName(e) });
        return;
    };
    try out.print("wrote private key: {s}  (KEEP SECRET)\n", .{key_path});
    try out.print("public key (embed as sign.embedded_root_key):\n  {s}\n", .{&pub_hex});
}

/// `wazmrt sign <in.wasm|.wat> <out.wasm> --key <keyfile>` — sign a module with
/// the private key and write the signed module (original bytes + a `"signature"`
/// custom section). The signed module still runs in any runtime; wazmrt (with a
/// matching embedded root key) authenticates it before executing.
fn signSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !void {
    const keyfile = flagValue(rest, "--key");
    var pos: [2][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--key")) {
            i += 1; // skip its value
            continue;
        }
        if (std.mem.startsWith(u8, rest[i], "--")) continue;
        if (n < 2) {
            pos[n] = rest[i];
            n += 1;
        }
    }
    if (n < 2 or keyfile == null) {
        try out.print("usage: wazmrt sign <in.wasm|.wat> <out.wasm> --key <keyfile>\n", .{});
        return;
    }
    const in_path = pos[0];
    const out_path = pos[1];

    var bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, in_path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ in_path, @errorName(e) });
        return;
    };
    if (std.mem.endsWith(u8, in_path, ".wat")) bytes = wazmrt.wat.assemble(arena, bytes) catch |e| {
        try out.print("error: cannot assemble '{s}': {s}\n", .{ in_path, @errorName(e) });
        return;
    };

    const key_text = Io.Dir.cwd().readFileAlloc(io, keyfile.?, arena, .limited(1 << 16)) catch |e| {
        try out.print("error: cannot read key '{s}': {s}\n", .{ keyfile.?, @errorName(e) });
        return;
    };
    const seed = wazmrt.pin.parseHex(std.mem.trim(u8, key_text, " \t\r\n")) orelse {
        try out.print("error: '{s}' is not a 64-hex-char Ed25519 seed\n", .{keyfile.?});
        return;
    };
    const kp = wazmrt.sign.Ed25519.KeyPair.generateDeterministic(seed) catch {
        try out.print("error: invalid signing key\n", .{});
        return;
    };
    const signed = wazmrt.sign.signModule(arena, bytes, kp) catch |e| {
        try out.print("error: cannot sign: {s}\n", .{@errorName(e)});
        return;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = signed }) catch |e| {
        try out.print("error: cannot write '{s}': {s}\n", .{ out_path, @errorName(e) });
        return;
    };
    const pub_hex = wazmrt.pin.toHex(kp.public_key.bytes);
    try out.print("signed {s} -> {s}\n  public key: {s}\n", .{ in_path, out_path, &pub_hex });
}

fn defaultPinsPath() []const u8 {
    return if (@import("builtin").os.tag == .windows)
        "C:\\ProgramData\\wazmrt\\pins"
    else
        "/etc/wazmrt/pins";
}

/// The wazmrt-flag region: the LEADING run of recognized wazmrt flags after the
/// module path, ending at `--` or at the first argument that is not one of ours.
///
/// Verify flags must sit here so a guest arg that happens to read `--no-verify`
/// is never mistaken for one of ours. Scanning everything before `--` did not
/// achieve that: the common WASI form has no `--` at all
/// (`wazmrt prog.wasm install --yes`), so the guest's own argv was still
/// searched and `--yes`/`--no-verify` anywhere in it silently disabled
/// verification. This mirrors exactly the run `runWasi` consumes, so the two
/// agree on where our flags stop and the guest's argv begins.
fn flagRegion(rest: []const []const u8) []const []const u8 {
    const two = [_][]const u8{ "--dir", "--ro-dir", "--env", "--verify", "--pins", "--max-memory" };
    const one = [_][]const u8{ "--no-verify", "--yes" };
    var i: usize = 0;
    outer: while (i < rest.len) {
        if (std.mem.eql(u8, rest[i], "--")) break;
        for (two) |f| if (std.mem.eql(u8, rest[i], f) and i + 1 < rest.len) {
            i += 2;
            continue :outer;
        };
        for (one) |f| if (std.mem.eql(u8, rest[i], f)) {
            i += 1;
            continue :outer;
        };
        break; // first non-flag argument — everything from here is the guest's
    }
    return rest[0..i];
}
/// Parse a `--max-memory` size: a decimal count of bytes with an optional
/// `K`/`M`/`G` suffix (`512M`, `2G`, `1073741824`). Returns null if unparseable
/// or if the multiplier overflows, so the caller can fail loudly rather than
/// silently running with the default.
fn parseSize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    const mult: usize = switch (s[s.len - 1]) {
        'k', 'K' => 1 << 10,
        'm', 'M' => 1 << 20,
        'g', 'G' => 1 << 30,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    return std.math.mul(usize, n, mult) catch null;
}

fn hasFlag(rest: []const []const u8, name: []const u8) bool {
    for (flagRegion(rest)) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}
fn flagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
    const region = flagRegion(rest);
    var i: usize = 0;
    while (i + 1 < region.len) : (i += 1)
        if (std.mem.eql(u8, region[i], name)) return region[i + 1];
    return null;
}

/// Read one line from stdin; true iff it starts with y/Y. EOF/error → false
/// (default No), so a closed or redirected stdin can never mean "yes".
fn promptYesNo(io: Io) bool {
    var buf: [64]u8 = undefined;
    var r: Io.File.Reader = .init(.stdin(), io, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len > 0 and (t[0] == 'y' or t[0] == 'Y');
}

/// The execution gate. Returns true to proceed, false to abort (already
/// reported). The root-owned pin DB carries both the approved digests and the
/// enforcement `# mode:` — so the policy inherits the DB file's ownership.
/// `bytes` is the in-memory buffer we are about to execute (TOCTOU-safe).
fn verifyGate(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    bytes: []const u8,
    path: []const u8,
    rest: []const []const u8,
) !bool {
    // Authenticity gate (signature) runs before the pin fallback: a module
    // signed by the trusted root key is authenticated and needs no pin. Inert
    // unless this build embedded a root key (`-Droot-key`, i.e.
    // `embedded_root_key != null`), so a default build behaves exactly as the
    // pin-only path did. The bytes checked are the in-memory buffer we are about
    // to run (TOCTOU-safe).
    if (embedded_root_key) |root| switch (wazmrt.sign.verify(bytes, root)) {
        .authenticated => return true, // signed by the trusted root; skip the pin check
        .tampered => {
            try out.print("refusing to run {s}: signed by the trusted key but the bytes do not match (tampered or corrupt)\n", .{path});
            return false;
        },
        .foreign, .unsigned => {}, // no trusted signature → fall through to the pin check
    };

    // The root-owned DEFAULT pin DB is authoritative: a runtime flag can never
    // weaken a `# mode: enforce` it mandates (#24). Read it FIRST to learn the
    // root policy; only when it does NOT enforce do `--pins`/`--verify` — dev /
    // unmanaged-machine overrides — take effect. Under a root enforce, both the
    // pin set and the policy come from root, so redirecting via `--pins` or
    // lowering via `--verify` is ignored.
    const default_path = defaultPinsPath();
    const default_text: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, default_path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            try out.print("error: cannot read pin DB '{s}': {s}\n", .{ default_path, @errorName(e) });
            return false;
        },
    };
    const root_enforce = if (default_text) |t| (wazmrt.pin.modeFromDb(t) orelse .off) == .enforce else false;

    const pins_flag = if (root_enforce) null else flagValue(rest, "--pins");
    const db_path = pins_flag orelse default_path;
    const db_text: ?[]const u8 = if (pins_flag) |p|
        (Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => {
                try out.print("error: cannot read pin DB '{s}': {s}\n", .{ p, @errorName(e) });
                return false;
            },
        })
    else
        default_text;

    // The DB's `# mode:` is the effective policy (null if absent).
    var explicit: ?wazmrt.pin.Mode = null;
    var db: wazmrt.pin.Db = .empty;
    if (db_text) |text| {
        explicit = wazmrt.pin.modeFromDb(text);
        db = wazmrt.pin.Db.parse(arena, text) catch |e| {
            // A corrupt/truncated DB fails CLOSED — never silently "not listed".
            try out.print("error: pin DB '{s}' is corrupt ({s}); refusing to run\n", .{ db_path, @errorName(e) });
            return false;
        };
    }
    // `--verify` may only RAISE strictness, and is ignored under a root enforce.
    if (!root_enforce) if (flagValue(rest, "--verify")) |mv|
        if (wazmrt.pin.modeFromStr(mv)) |m| {
            explicit = wazmrt.pin.stricter(explicit orelse .off, m);
        };

    // Hash the in-memory bytes we are about to execute (TOCTOU-safe), then let
    // the pure decision function pick the action from the security matrix.
    const digest = wazmrt.pin.hash(bytes);
    const pinned = db.contains(digest);
    const opt_out = hasFlag(rest, "--no-verify") or hasFlag(rest, "--yes");
    const tty = Io.File.stdin().isTty(io) catch false;
    const hex = wazmrt.pin.toHex(digest);

    // Verification is "armed" — deny an unsigned/unpinned module by default —
    // when a root key is embedded OR a pin DB is present, i.e. a real deployment
    // rather than a bare dev build (which runs everything). A signature-verified
    // module already returned above; this governs the *unsigned* case.
    const armed = embedded_root_key != null or db_text != null;
    const would_block = wazmrt.pin.decide(explicit, pinned, false, tty, armed) != .run;

    switch (wazmrt.pin.decide(explicit, pinned, opt_out, tty, armed)) {
        .run => {
            // We only reach `.run` here for an unpinned module by overriding a
            // block with --no-verify (or via an explicit `# mode: off`). Note the
            // override so it is never silent.
            if (would_block and opt_out)
                try out.print("warning: running unverified module {s} (sha256 {s}) — --no-verify\n", .{ path, &hex });
            return true;
        },
        .deny => {
            const why = if (explicit) |m| switch (m) {
                .enforce => "policy=enforce (root-owned; not overridable)",
                .warn => "unpinned; no TTY to confirm — pass --no-verify to allow",
                .off => unreachable, // `off` never denies
            } else "unsigned and not pinned — sign it, pin it, or pass --no-verify to allow on your own machine";
            try out.print("refusing to run unverified module: {s}\n  sha256 {s}\n  (not in pin DB {s}; {s})\n", .{ path, &hex, db_path, why });
            return false;
        },
        .prompt => {
            try out.print("module is unverified (not pinned): {s}\n  sha256 {s}\nproceed? [y/N] ", .{ path, &hex });
            try out.flush();
            if (promptYesNo(io)) return true;
            try out.print("aborted.\n", .{});
            return false;
        },
    }
}

/// Report a trap with the location it actually happened at, innermost frame
/// first, naming each frame from the module's name section when it has one.
///
/// Without this a trap is just `trap: Unreachable`, which says nothing about
/// where — the gap that made the Phase 3 `bitcast_invalid` hunt cost hours
/// (`cmem/known-issues.md` #19). A 2-instruction body trapping at +0 is the
/// signature of a wasm-ld stub, and the name says which import it stubbed.
fn printTrap(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    inst: *const wazmrt.interp.Instance,
    e: anyerror,
) !void {
    try out.print("trap: {s}\n", .{@errorName(e)});
    const frames = inst.trapFrames();
    if (frames.len == 0) return; // never reached wasm code (bad arity, say)

    for (frames, 0..) |f, i| {
        const lead = if (i == 0) "at" else "by";
        // Prefer a real byte offset: it lines up with `wasm-objdump` output,
        // where an IR index means nothing outside this runtime.
        const off = inst.frameOffset(arena, f);
        if (module.funcName(f.func_index)) |n|
            try out.print("  {s} fn[{d}] <{s}> +{d}\n", .{ lead, f.func_index, n, offOr(off, f) })
        else
            try out.print("  {s} fn[{d}] +{d}\n", .{ lead, f.func_index, offOr(off, f) });
    }
    if (inst.trapTruncated())
        try out.print("  ... {d} more frame(s)\n", .{inst.trap_depth - frames.len});
    if (module.func_names == null)
        try out.print("  (no name section: rebuild the guest unstripped for symbols)\n", .{});
}

/// The frame's byte offset within its function, falling back to the IR index
/// when the body can't be re-decoded (a host frame, or OOM). Both are "+N" after
/// a function name; the byte offset is the one an external tool can use.
fn offOr(off: ?wazmrt.interp.Instance.Offsets, f: wazmrt.interp.TrapFrame) usize {
    return if (off) |o| o.func else f.pc;
}

/// `runWasi` already reported the trap in full; the caller must not print again.
const AlreadyReported = error.AlreadyReported;

/// Function index of the exported function `name`, or null.
fn findExport(module: *const wazmrt.Module, name: []const u8) ?u32 {
    for (module.exports) |e| {
        if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) return e.index;
    }
    return null;
}

/// Run a WASI command module: wire the `wasi_snapshot_preview1` host imports,
/// instantiate, and invoke `_start`. Returns the process exit code (0 unless
/// `proc_exit` set one). `wasi_args` become argv[1..]; argv[0] is the path.
fn runWasi(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    path: []const u8,
    start_index: u32,
    wasi_args: []const [:0]const u8,
) !u32 {
    const interp = wazmrt.interp;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_w = &stderr_file_writer.interface;
    defer err_w.flush() catch {};

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    // No seed: `random_get` is a CSPRNG seeded lazily from OS entropy inside
    // `Wasi` (it used to be a timestamp-seeded Xoshiro256++). See `Wasi.csprng`.
    var wasi = wazmrt.wasi.Wasi.init(arena, io, out, err_w);
    defer wasi.deinit();
    wasi.stdin = &stdin_file_reader.interface;

    // wazmrt flags precede the guest's own argv. Each takes a value:
    //   --dir <host>[:<guest>]      read-write preopen (the guest's only files)
    //   --ro-dir <host>[:<guest>]   read-only preopen (no write/create/delete)
    //   --env KEY=VAL               one environment variable for the guest
    //   --max-memory <size>         linear-memory ceiling (default 1G)
    //   --                          end of wazmrt flags; the rest is guest argv
    var environ: std.ArrayList([]const u8) = .empty;
    var max_memory: usize = interp.default_max_memory_bytes;
    var rest = wasi_args;
    flags: while (rest.len >= 1) {
        const flag = rest[0];
        if (std.mem.eql(u8, flag, "--max-memory") and rest.len >= 2) {
            max_memory = parseSize(rest[1]) orelse {
                try out.print("error: --max-memory '{s}': expected a size like 512M or 2G\n", .{rest[1]});
                return 1;
            };
            rest = rest[2..];
            continue :flags;
        }
        const ro = std.mem.eql(u8, flag, "--ro-dir");
        if ((std.mem.eql(u8, flag, "--dir") or ro) and rest.len >= 2) {
            const spec = rest[1];
            // Split on the LAST ':' so a Windows host path (`C:\tmp`) still parses.
            const host, const guest = if (std.mem.lastIndexOfScalar(u8, spec, ':')) |i|
                if (i > 1) .{ spec[0..i], spec[i + 1 ..] } else .{ spec, spec }
            else
                .{ spec, spec };
            const rmask = if (ro) wazmrt.wasi.readOnlyRights else wazmrt.wasi.allRights;
            _ = wasi.addPreopen(host, guest, rmask) catch |e| {
                try out.print("error: {s} '{s}': {s}\n", .{ flag, host, @errorName(e) });
                return 1;
            };
            rest = rest[2..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--env") and rest.len >= 2) {
            // WASI environ entries are `KEY=VALUE`; pass through verbatim.
            try environ.append(arena, try arena.dupe(u8, rest[1]));
            rest = rest[2..];
            continue :flags;
        }
        // Pin-verification flags are handled by `verifyGate` before we get here;
        // consume them so they never reach the guest's argv (see verifyGate).
        if ((std.mem.eql(u8, flag, "--verify") or std.mem.eql(u8, flag, "--pins")) and rest.len >= 2) {
            rest = rest[2..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--no-verify") or std.mem.eql(u8, flag, "--yes")) {
            rest = rest[1..];
            continue :flags;
        }
        // An explicit `--` ends our flags; everything after it is the guest's.
        if (std.mem.eql(u8, flag, "--")) rest = rest[1..];
        break :flags;
    }
    wasi.environ = environ.items;

    // argv: the module path, then the guest's own args (the preopen flags are
    // ours, not the guest's).
    const argv = try arena.alloc([]const u8, 1 + rest.len);
    argv[0] = path;
    for (rest, argv[1..]) |src, *dst| dst.* = src;
    wasi.args = argv;

    // Back every imported function: `wasi_snapshot_preview1.*` from WASI, any
    // other import with a trap-on-call stub.
    var funcs: std.ArrayList(interp.Instance.HostFunc) = .empty;
    for (module.imports) |imp| {
        if (imp.type != .func) continue;
        if (std.mem.eql(u8, imp.module, "wasi_snapshot_preview1"))
            try funcs.append(arena, wasi.hostFunc(imp.name))
        else
            try funcs.append(arena, .{ .native_env = .{ .ctx = &wasi, .call = unresolvedImport } });
    }

    var inst = try interp.Instance.initWithImports(arena, module, .{ .funcs = funcs.items, .max_memory_bytes = max_memory });
    defer inst.deinit();
    wasi.memory = inst.memory0(); // module memory now exists

    _ = inst.invokeIndex(start_index, &.{}) catch |e| {
        // `proc_exit` unwinds via HostTrap with the code recorded — a clean exit.
        if (e == error.HostTrap and wasi.exit_code != null) return wasi.exit_code.?;
        try printTrap(arena, out, module, &inst, e);
        return AlreadyReported;
    };
    return wasi.exit_code orelse 0;
}

fn unresolvedImport(ctx: *anyopaque, args: []const wazmrt.interp.Value, results: []wazmrt.interp.Value) bool {
    _ = ctx;
    _ = args;
    _ = results;
    return false; // -> error.HostTrap
}

/// Instantiate `module`, invoke exported function `name` with `arg_strings`
/// (parsed per the function's parameter types), and print the results.
fn runFunction(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    module: *const wazmrt.Module,
    name: []const u8,
    arg_strings: []const [:0]const u8,
) !void {
    const interp = wazmrt.interp;

    // Resolve the export to a function index + signature.
    var func_index: ?u32 = null;
    for (module.exports) |e| {
        if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) func_index = e.index;
    }
    const fi = func_index orelse {
        try out.print("error: no exported function '{s}'\n", .{name});
        return;
    };
    // `fi` came from the export section, which the decoder does NOT cross-check
    // against the function space (a repeated `function` section appends to the
    // space but replaces `module.functions`, so the two can disagree). The run
    // path never validates, so an out-of-range export index reaches here and the
    // old `.?` was a null unwrap — undefined data in ReleaseFast, i.e. a segfault
    // from a 31-byte module. Fail loud instead.
    const ft = module.funcType(fi) orelse {
        try out.print("error: export '{s}' names an out-of-range function index {d}\n", .{ name, fi });
        return;
    };
    if (arg_strings.len != ft.params.len) {
        try out.print("error: '{s}' takes {d} arg(s), got {d}\n", .{ name, ft.params.len, arg_strings.len });
        return;
    }

    // Parse each argument according to its declared parameter type.
    const call_args = try arena.alloc(interp.Value, ft.params.len);
    for (arg_strings, ft.params, call_args) |s, pt, *dst| {
        dst.* = switch (pt) {
            .i32 => interp.i32Value(@truncate(try std.fmt.parseInt(i64, s, 0))),
            .i64 => interp.i64Value(try std.fmt.parseInt(i64, s, 0)),
            .f32 => interp.f32Value(@floatCast(try std.fmt.parseFloat(f64, s))),
            .f64 => interp.f64Value(try std.fmt.parseFloat(f64, s)),
            else => {
                try out.print("error: unsupported parameter type {s}\n", .{@tagName(pt)});
                return;
            },
        };
    }

    var inst = interp.Instance.init(arena, module) catch |e| {
        try out.print("error: instantiate: {s}\n", .{@errorName(e)});
        return;
    };
    defer inst.deinit();

    inst.runStart() catch |e| {
        try out.print("trap: start: ", .{});
        try printTrap(arena, out, module, &inst, e);
        return;
    };

    const results = inst.invokeIndex(fi, call_args) catch |e| {
        try printTrap(arena, out, module, &inst, e);
        return;
    };

    for (results, ft.results, 0..) |res, rt, i| {
        if (i != 0) try out.print(" ", .{});
        switch (rt) {
            .i32 => try out.print("{d}", .{interp.asI32(res)}),
            .i64 => try out.print("{d}", .{interp.asI64(res)}),
            .f32 => try out.print("{d}", .{interp.asF32(res)}),
            .f64 => try out.print("{d}", .{interp.asF64(res)}),
            else => try out.print("0x{x}", .{res}),
        }
    }
    try out.print("\n", .{});
}
