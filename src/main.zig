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

/// Exit status for a wazmrt-side failure (unreadable file, bad module, refused
/// by the verify gate, guest trap). A guest's own `proc_exit` code is passed
/// through unchanged instead.
///
/// This matters beyond tidiness: `main` used to print every failure and `return`,
/// so the process exited **0** for a missing file, an undecodable module, a
/// failed assembly, a guest trap — and, worst, for a **verify-gate refusal**, so
/// `wazmrt --verify enforce prog.wasm && deploy` proceeded after wazmrt had
/// refused to run the module.
const exit_failure: u8 = 1;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const code = run(init, arena, io, out) catch |e| blk: {
        out.print("error: {s}\n", .{@errorName(e)}) catch {};
        break :blk exit_failure;
    };
    // Flush BEFORE exiting — `std.process.exit` does not run deferred code, so a
    // buffered final line would be lost.
    out.flush() catch {};
    if (code != 0) std.process.exit(code);
}

/// The CLI body. Returns the process exit status.
fn run(init: std.process.Init, arena: std.mem.Allocator, io: Io, out: *Io.Writer) !u8 {
    const args = try init.minimal.args.toSlice(arena);
    const prog = if (args.len > 0) args[0] else "wazmrt";
    if (args.len < 2) {
        try printUsage(out, prog);
        return exit_failure; // invoked with no arguments
    }

    // `-h`/`--help` and `-v`/`--version` are only recognized as the FIRST arg, so
    // a `--help` in a guest's argv (`wazmrt prog.wasm -- --help`) is never ours.
    if (isFlag(args[1], "-h", "--help")) {
        try printHelp(out, prog);
        return 0;
    }
    if (isFlag(args[1], "-v", "--version")) {
        try printVersion(out);
        return 0;
    }

    // `wazmrt pin <file> [--db <path>]` — hash a module for the pin DB (Phase 5).
    if (std.mem.eql(u8, args[1], "pin")) {
        try pinSubcommand(arena, io, out, args[2..]);
        return 0;
    }

    // Publisher-side signing tools (authenticity):
    //   wazmrt keygen [--out <name>]                    — new Ed25519 keypair
    //   wazmrt sign <in> <out> --key <keyfile>          — sign a module
    if (std.mem.eql(u8, args[1], "keygen")) {
        try keygenSubcommand(arena, io, out, args[2..]);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "sign")) {
        try signSubcommand(arena, io, out, args[2..]);
        return 0;
    }

    // `--features <list>` (F5-CLI) — the accepted WebAssembly LANGUAGE, restricted.
    //
    // ⚠️ **It sits BEFORE the module path, and it is the only wazmrt flag that does.** Every
    // other one trails the path, in the leading run `flagRegion` carves out of the guest's argv
    // — and that position cannot work here. In run mode the export name must be `args[2]`
    // (`wazmrt add.wasm add 2 3`), so a trailing flag region is empty and everything after the
    // export belongs to the guest. Moving the export selector to *after* a flag region would
    // silently change which mode `wazmrt prog.wasm --dir .:/ add 2 3` picks, for a module that
    // exports both `add` and `_start`. A leading flag adds a position that was previously an
    // error ("cannot read '--features'") and changes no existing parse.
    //
    // 🔒 It is also why the flag is NOT in `flagRegion`'s lists: a guest argv that happens to
    // read `--features mvp` must never narrow the language wazmrt accepts, the same reasoning
    // that put `--no-verify` there in the first place.
    var argi: usize = 1;
    var cli_features: wazmrt.features.Set = .{};
    while (argi < args.len) {
        const spec: []const u8 = if (std.mem.eql(u8, args[argi], "--features") and argi + 1 < args.len) blk: {
            argi += 2;
            break :blk args[argi - 1];
        } else if (std.mem.startsWith(u8, args[argi], "--features=")) blk: {
            argi += 1;
            break :blk args[argi - 1]["--features=".len..];
        } else break;
        cli_features = parseFeatures(spec, cli_features, out) catch return exit_failure;
    }
    if (argi >= args.len) {
        try out.print("error: --features given with no module\n", .{});
        return exit_failure;
    }
    // ⚠️ Reported, never repaired — the C ABI's rule, and for its reason: silently enabling a
    // dependency accepts modules the user meant to refuse. `wazmrt_engine_new_with_config` fails
    // on the same set, so the two front ends agree on what a coherent restriction is.
    if (cli_features.incoherent()) |pair| {
        try out.print("error: --features: '{s}' is layered on '{s}' and cannot be enabled without it\n", .{ pair[0].name(), pair[1].name() });
        return exit_failure;
    }

    const path = args[argi];
    // Everything after the module path: the export selector, the WASI flags, the guest's argv.
    // With no leading `--features` this is exactly the `args[2..]` it replaced.
    const rest = args[argi + 1 ..];
    var bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return exit_failure;
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
        if (!(try verifyGate(arena, io, out, bytes, path, rest))) return exit_failure;

        // `path` is passed for the ERA POLICY, not for I/O: a script under `proposals/threads/`
        // is judged by that snapshot's feature set. See `wast.featuresForPath`.
        //
        // 🔒 **`--features` reaches HERE too, and it has to.** A `.wast` instantiates and invokes
        // the modules it contains, so a restriction that covered `.wasm` and not `.wast` could be
        // stepped around by wrapping the module in a script — the identical bypass this path
        // already had once for the verify gate, and the attacker picks the extension. The two
        // sets INTERSECT: an era already narrower than the request stays narrower, and the CLI
        // flag can only ever take features away.
        const s = wazmrt.wast.runScriptWith(arena, bytes, path, cli_features) catch |e| {
            try out.print("error: cannot run '{s}': {s}\n", .{ path, @errorName(e) });
            return exit_failure;
        };
        try out.print("{s}: {d} passed, {d} failed, {d} skipped\n", .{ path, s.passed, s.failed, s.skipped });
        // Every failure, not just the first: one line of output was what made 25
        // distinct decoder defects in `binary.wast` read as a single problem.
        for (s.failures.items) |f| try out.print("  failure: {s}\n", .{f});
        if (s.failed > s.failures.items.len)
            try out.print("  ... and {d} more\n", .{s.failed - s.failures.items.len});
        // A .wast with failing assertions is a failing run — it used to exit 0,
        // so a CI step running the testsuite could never notice.
        return if (s.failed != 0) exit_failure else 0;
    }

    // .wat text: assemble to a binary, then treat it like a .wasm.
    if (std.mem.endsWith(u8, path, ".wat")) {
        bytes = wazmrt.wat.assemble(arena, bytes) catch |e| {
            try out.print("error: cannot assemble '{s}': {s}\n", .{ path, @errorName(e) });
            return exit_failure;
        };
    }

    var module = wazmrt.decode(arena, bytes) catch |e| {
        try out.print("error: cannot decode '{s}': {s}\n", .{ path, @errorName(e) });
        return exit_failure;
    };
    defer module.deinit();

    // Pin verification (Phase 5) gates *execution*: before we run anything, the
    // in-memory `bytes` (exactly what we execute — TOCTOU-safe) are hashed and
    // checked against the root-owned pin DB per the enforcement policy. The
    // summarize path below never executes, so it is never gated.
    const will_execute = (rest.len >= 1 and findExport(&module, rest[0]) != null) or
        findExport(&module, "_start") != null;
    if (will_execute and !(try verifyGate(arena, io, out, bytes, path, rest))) return exit_failure;

    // §4.5.1 defines instantiation only for a VALID module, so nothing executes before validation.
    // Both execute paths — `<module> <export>` and the WASI `_start` command — used to skip this
    // entirely, while the summarize path below validated and reported a verdict. That asymmetry
    // was the bug: the two paths that actually RUN code were the two that did not check it.
    //
    // It was not theoretical. `runFunction` still carries the comment recording what it cost: an
    // export index the decoder never cross-checks against the function space reached a `.?` and
    // was an undefined-data null unwrap in ReleaseFast — a segfault from a 31-byte module. That
    // was patched defensively at the one site it happened to be noticed; this fixes the cause,
    // and every other site that assumes validation has run is covered by the same guard.
    //
    // Placed AFTER the pin gate deliberately: authorization first, so an unauthorized module is
    // refused as unauthorized rather than having its contents inspected and reported on.
    if (will_execute) {
        // `validateWith`, not `validate`: the feature set gates AND selects the typing rules in
        // one call (F1r). Passing `.{}` here — the all-features default — is what the CLI did
        // before `--features` existed, so an unrestricted run is byte-for-byte the same work.
        wazmrt.validateWith(arena, &module, cli_features) catch |e| {
            try out.print("error: '{s}' is not a valid module", .{path});
            try printInvalidity(out, e);
            return exit_failure;
        };
    }

    // Run mode: `wazmrt <module.wasm> <export> [args...]` — invoke and print.
    // A trailing arg only selects an export if it actually names one; otherwise
    // it belongs to the WASI command below (`--dir …`, guest argv, …).
    if (rest.len >= 1 and findExport(&module, rest[0]) != null) {
        return try runFunction(arena, out, &module, rest[0], rest[1..]);
    }

    // WASI command: `wazmrt <module.wasm> [--dir <host>[:<guest>]]... [args...]`
    // runs `_start` with the `wasi_snapshot_preview1` host imports wired up.
    if (findExport(&module, "_start")) |start_index| {
        const code = runWasi(arena, io, out, &module, path, start_index, rest) catch |e| {
            if (e != AlreadyReported) try out.print("trap: {s}\n", .{@errorName(e)});
            return exit_failure; // a trap is a failed run
        };
        // Pass the GUEST's own exit code through: `proc_exit(1)` used to be
        // merely printed as "(exit 1)" while the process still exited 0.
        if (code != 0) try out.print("(exit {d})\n", .{code});
        return std.math.cast(u8, code) orelse exit_failure;
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

    wazmrt.validateWith(arena, &module, cli_features) catch |e| {
        // Same report as the execute paths above, so the two never drift into saying different
        // things about the same module — `--features` included. A restriction that applied only
        // to the paths that RUN would let `wazmrt --features mvp mod.wasm` print "validation: OK"
        // for a module the very next invocation refuses.
        try out.print("  validation: FAILED", .{});
        try printInvalidity(out, e);
        return exit_failure; // the inspect path reports invalidity in its status
    };
    try out.print("  validation: OK\n", .{});
    return 0;
}

/// One item of a `--features` list: a proposal and whether it is being added or removed. `null`
/// for an `all` / `mvp` / `none` SEED, which replaces the whole set rather than editing it.
const FeatureItem = struct { f: ?wazmrt.features.Feature, on: bool };

/// Classify one already-trimmed item, or report why it is not one.
///
/// ⚠️ **An unrecognised name is an ERROR, never a skip.** Ignoring it would leave the user
/// believing they had restricted something: `--features mvp,sim` would silently be `mvp`, and
/// `--features -simd2` would silently be `all`. A security control that quietly drops what it was
/// told is worse than no control.
fn parseFeatureItem(item: []const u8, first: bool, out: *Io.Writer) !FeatureItem {
    if (item.len == 0) {
        try out.print("error: --features: empty item\n", .{});
        return error.BadFeatures;
    }
    // `none` is accepted alongside `mvp`: both name "the WebAssembly 1.0 core", and a user who
    // types the other one means the same thing. Seeds are positional — only the first item can
    // replace the set, because "everything, then nothing, then gc" is not a list anyone means.
    if (first and (std.mem.eql(u8, item, "all") or std.mem.eql(u8, item, "mvp") or std.mem.eql(u8, item, "none")))
        return .{ .f = null, .on = std.mem.eql(u8, item, "all") };

    const on = item[0] != '-';
    const name = if (item[0] == '-' or item[0] == '+') item[1..] else item;
    if (name.len == 0) {
        try out.print("error: --features: '{s}' names no proposal\n", .{item});
        return error.BadFeatures;
    }
    const f = std.meta.stringToEnum(wazmrt.features.Feature, name) orelse {
        try out.print("error: --features: unknown proposal '{s}'\n", .{name});
        try out.print("  known: all, mvp", .{});
        for (0..wazmrt.features.count) |i| {
            const known: wazmrt.features.Feature = @enumFromInt(@as(u8, @intCast(i)));
            try out.print(", {s}", .{known.name()});
        }
        try out.print("\n", .{});
        return error.BadFeatures;
    };
    return .{ .f = f, .on = on };
}

/// Every proposal off — the `mvp` seed, and the base an all-additive list is applied to.
fn noFeatures() wazmrt.features.Set {
    var s: wazmrt.features.Set = .{};
    for (0..wazmrt.features.count) |i| s.set(@enumFromInt(@as(u8, @intCast(i))), false);
    return s;
}

/// Parse one `--features` list onto `base`, or report why it cannot be parsed.
///
/// Grammar: comma-separated items, each a proposal name, optionally signed `+name` / `-name`.
/// Two seeds may lead the list: `all` (everything on) and `mvp` / `none` (everything off).
///
/// 🔑 **THE SEED IS EXPLICIT OR IT IS INFERRED FROM ONE UNAMBIGUOUS SHAPE, AND MIXING IS AN
/// ERROR.** `--features simd,gc` means "these and nothing else"; `--features -simd` means
/// "everything but this". Both readings are obvious in isolation and neither is obvious for
/// `--features gc,-simd`, so that spelling is refused rather than resolved by a precedence rule
/// nobody asked for — *a defaulted policy is a policy nobody reviewed*. Say `mvp,gc` or
/// `all,-simd` and the question does not arise.
///
/// ⚠️ **The names come from `@tagName`, not from a list written here.** The C ABI's copy of this
/// enum drifted from the engine's once and shipped a switch that silently did nothing; the CLI
/// would have been the FOURTH hand-written spelling of the same list. Deriving it means the build
/// cannot produce a CLI that offers a different set of proposals than it enforces.
///
/// 🔒 **TWO PASSES OVER THE STRING, AND NO BUFFER — THIS IS A FIXED BUG, NOT A STYLE CHOICE.**
/// The first version read the items into a `[count * 2]` array so the seed could be applied before
/// them, and never bounded `n`: every item has to be a VALID proposal name to be stored, but
/// nothing stops a caller repeating one, so `--features simd,simd,…` past 36 entries wrote off the
/// end of a stack array. Under `zig build test` that is a panic; in the SHIPPED ReleaseSmall CLI
/// it is a stack smash reachable from the command line. Re-splitting the string costs nothing and
/// removes the bound entirely. **A buffer sized from a type is not sized from the input.**
fn parseFeatures(spec: []const u8, base: wazmrt.features.Set, out: *Io.Writer) !wazmrt.features.Set {
    // --- pass 1: validate every item, and decide the seed ---------------------------------
    var set = base;
    var seeded = false;
    var saw_add = false;
    var saw_sub = false;
    var n: usize = 0;
    var scan = std.mem.splitScalar(u8, spec, ',');
    while (scan.next()) |raw| {
        const item = try parseFeatureItem(std.mem.trim(u8, raw, " \t"), n == 0, out);
        n += 1;
        if (item.f == null) {
            set = if (item.on) .{} else noFeatures();
            seeded = true;
            continue;
        }
        if (item.on) saw_add = true else saw_sub = true;
    }
    if (n == 0) {
        try out.print("error: --features: empty list\n", .{});
        return error.BadFeatures;
    }
    if (!seeded and saw_add and saw_sub) {
        try out.print(
            "error: --features: '{s}' both adds and removes with no seed — say 'mvp,<added>' or 'all,-<removed>'\n",
            .{spec},
        );
        return error.BadFeatures;
    }
    // An unseeded list takes the only seed its shape can mean: bare names are the WHOLE language
    // asked for, so start from nothing; `-name` items describe subtractions from the default.
    if (!seeded and saw_add) set = noFeatures();

    // --- pass 2: apply, now that the seed underneath them is settled -----------------------
    var apply = std.mem.splitScalar(u8, spec, ',');
    var i: usize = 0;
    while (apply.next()) |raw| : (i += 1) {
        const item = try parseFeatureItem(std.mem.trim(u8, raw, " \t"), i == 0, out);
        if (item.f) |f| set.set(f, item.on);
    }
    return set;
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
        \\usage: {s} [--features <list>] <module.wasm|.wat|.wast> [export] [args...]
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
        \\  --max-table-elems <count>   table-entry ceiling (default 128M; e.g. 1M, 100000)
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
        \\FEATURE FLAGS (the WebAssembly language wazmrt will accept)
        \\  --features <list>           restrict the accepted proposals; goes BEFORE the module
        \\      A comma-separated list. Two seeds may lead it: `all` (everything, the default)
        \\      and `mvp` (nothing but WebAssembly 1.0). Items are proposal names, optionally
        \\      signed: `gc` adds, `-gc` removes.
        \\        --features mvp                       WebAssembly 1.0 and nothing else
        \\        --features simd,bulk_memory          MVP plus these two (bare names imply `mvp`)
        \\        --features -threads,-memory64        everything except these (`-` implies `all`)
        \\      Adding and removing without a seed is refused — `mvp,gc` or `all,-gc` says which
        \\      you meant. A proposal layered on another cannot be kept without it (gc needs
        \\      function_references, and so on); that is reported, never silently repaired.
        \\      A module needing an excluded proposal is INVALID and is refused before it runs,
        \\      `.wast` scripts included. The flag can only ever narrow: a spec-testsuite
        \\      snapshot already judged by an older era stays at that era.
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
    const name = subcommandFlagValue(rest, "--out") orelse "wazmrt_root";
    const kp = wazmrt.sign.Ed25519.KeyPair.generate(io); // entropy from the Io
    const seed_hex = wazmrt.pin.toHex(kp.secret_key.seed());
    const pub_hex = wazmrt.pin.toHex(kp.public_key.bytes);
    const key_path = try std.fmt.allocPrint(arena, "{s}.key", .{name});
    const key_text = try std.fmt.allocPrint(arena, "{s}\n", .{&seed_hex});
    // The Ed25519 *private* seed. Default file permissions are 0644 after umask
    // on POSIX — i.e. world-readable, for the one file in this project that must
    // not be. Create it 0600. Windows has no mode bit here (`Permissions` is an
    // attribute set), so the file inherits the directory ACL; the honest
    // mitigation there is the documented one — keep the key off shared paths, or
    // hold it in an HSM.
    const key_perms: Io.File.Permissions = if (@import("builtin").os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    Io.Dir.cwd().writeFile(io, .{
        .sub_path = key_path,
        .data = key_text,
        .flags = .{ .permissions = key_perms },
    }) catch |e| {
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
    const keyfile = subcommandFlagValue(rest, "--key");
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
    const two = [_][]const u8{ "--dir", "--ro-dir", "--env", "--verify", "--pins", "--max-memory", "--max-table-elems" };
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

/// `flagValue` for a SUBCOMMAND's own flags (`keygen --out`, `sign --key`),
/// which searches all of `rest`.
///
/// It cannot go through `flagRegion`: that scan stops at the first argument
/// which is not a *run-mode* flag, deliberately, so a guest's argv can never
/// smuggle in `--no-verify`. `--out`/`--key` are in neither of its lists, so the
/// region was always empty and both flags were silently ignored — `keygen --out
/// mykey` wrote `wazmrt_root.key`, and `sign` could not be invoked at all in any
/// argument order because its required `--key` never resolved.
///
/// Safe here precisely because these subcommands take no guest argv: everything
/// after the subcommand name belongs to us.
fn subcommandFlagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < rest.len) : (i += 1)
        if (std.mem.eql(u8, rest[i], name)) return rest[i + 1];
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
    if (!root_enforce) if (flagValue(rest, "--verify")) |mv| {
        // Fail closed on a typo. `--verify` can only raise strictness, so
        // silently ignoring an unparseable value meant the user's *intended*
        // extra strictness was dropped without a word — the opposite posture to
        // `pin.modeFromDb`, which was fixed to fail closed in the 5th pass.
        const m = wazmrt.pin.modeFromStr(mv) orelse {
            try out.print("error: --verify '{s}': expected off, warn or enforce\n", .{mv});
            return false;
        };
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

/// Report an invalid module, **shaped to match wasmtime**.
///
/// wasmtime 47 on `(func (result i32) i64.const 1)`:
///
/// ```text
/// Invalid input WebAssembly code at offset 33: type mismatch: expected i32, found i64
/// ```
///
/// So: the byte offset **in decimal**, counted from the start of the module — the same origin
/// wasmtime uses, so the two tools' numbers are directly comparable on the same file — then the two
/// types. The function index is ours to add; wasmtime does not print it, and it is what makes a
/// twenty-body module tractable. Anything the validator did not record is omitted, never guessed.
///
/// Without this, an invalid module was just `TypeMismatch` — the same gap for validation that
/// `printTrap` below closes for traps, and the reason a port punch-list item sat misdiagnosed for two
/// releases (`cmem/known-issues.md`).
/// Prints only the DETAIL — " at offset N (function M): type mismatch: …" — so each caller supplies
/// the lead-in that reads correctly in its own context ("… is not a valid module" vs
/// "validation: FAILED"). One formatter, so the two can never say different things about one module.
fn printInvalidity(out: *Io.Writer, e: anyerror) !void {
    const site = wazmrt.lastFailureSite();
    // A proposal the user themself refused is reported by NAME and first. Falling through to
    // "is not a valid module: DisabledProposal" would describe their own `--features` as a defect
    // in the module — the same reason `capi.zig`'s `diagnose` leads with it.
    if (site.disabled_proposal) |f| {
        try out.print(": uses the '{s}' proposal, which --features excludes\n", .{f.name()});
        return;
    }
    if (site.offset) |off| try out.print(" at offset {d}", .{off});
    if (site.func_index) |fi| try out.print(" (function {d})", .{fi});
    if (site.expected != null and site.found != null) {
        // `ValType` is a NON-EXHAUSTIVE enum, so `@tagName` would be undefined on a value outside its
        // fields — `tagName` returns null instead, and an unnamed type falls back to the bare error.
        const exp = std.enums.tagName(wazmrt.types.ValType, site.expected.?);
        const got = std.enums.tagName(wazmrt.types.ValType, site.found.?);
        if (exp != null and got != null) {
            try out.print(": type mismatch: expected {s}, found {s}\n", .{ exp.?, got.? });
            return;
        }
    }
    try out.print(": {s}\n", .{@errorName(e)});
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
    var wasi = try wazmrt.wasi.Wasi.init(arena, io, out, err_w);
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
    var max_table_elems: usize = interp.default_max_table_elems;
    var rest = wasi_args;
    // 🔒 Symlink CREATION is off unless asked for — see `wasi.readWriteRights`.
    var allow_symlink = false;
    flags: while (rest.len >= 1) {
        const flag = rest[0];
        if (std.mem.eql(u8, flag, "--allow-symlink")) {
            allow_symlink = true;
            rest = rest[1..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--max-memory") and rest.len >= 2) {
            max_memory = parseSize(rest[1]) orelse {
                try out.print("error: --max-memory '{s}': expected a size like 512M or 2G\n", .{rest[1]});
                return 1;
            };
            rest = rest[2..];
            continue :flags;
        }
        if (std.mem.eql(u8, flag, "--max-table-elems") and rest.len >= 2) {
            max_table_elems = parseSize(rest[1]) orelse {
                try out.print("error: --max-table-elems '{s}': expected a count like 1M or 100000\n", .{rest[1]});
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
            // 🔒 Read-write does NOT include planting symlinks unless `--allow-symlink` asked for it.
            const rmask = if (ro)
                wazmrt.wasi.readOnlyRights
            else if (allow_symlink) wazmrt.wasi.allRights else wazmrt.wasi.readWriteRights;
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

    var inst: interp.Instance = undefined;
    try inst.instantiateWithImports(arena, module, .{ .funcs = funcs.items, .max_memory_bytes = max_memory, .max_table_elems = max_table_elems });
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
) !u8 {
    const interp = wazmrt.interp;

    // Resolve the export to a function index + signature.
    var func_index: ?u32 = null;
    for (module.exports) |e| {
        if (e.type.kind() == .func and std.mem.eql(u8, e.name, name)) func_index = e.index;
    }
    const fi = func_index orelse {
        try out.print("error: no exported function '{s}'\n", .{name});
        return exit_failure;
    };
    // `fi` came from the export section, which the decoder does NOT cross-check
    // against the function space (a repeated `function` section appends to the
    // space but replaces `module.functions`, so the two can disagree). The run
    // path never validates, so an out-of-range export index reaches here and the
    // old `.?` was a null unwrap — undefined data in ReleaseFast, i.e. a segfault
    // from a 31-byte module. Fail loud instead.
    const ft = module.funcType(fi) orelse {
        try out.print("error: export '{s}' names an out-of-range function index {d}\n", .{ name, fi });
        return exit_failure;
    };
    if (arg_strings.len != ft.params.len) {
        try out.print("error: '{s}' takes {d} arg(s), got {d}\n", .{ name, ft.params.len, arg_strings.len });
        return exit_failure;
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
                return exit_failure;
            },
        };
    }

    var inst: interp.Instance = undefined;
    inst.instantiate(arena, module) catch |e| {
        try out.print("error: instantiate: {s}\n", .{@errorName(e)});
        return exit_failure;
    };
    defer inst.deinit();

    inst.runStart() catch |e| {
        try out.print("trap: start: ", .{});
        try printTrap(arena, out, module, &inst, e);
        return exit_failure;
    };

    const results = inst.invokeIndex(fi, call_args) catch |e| {
        try printTrap(arena, out, module, &inst, e);
        return exit_failure;
    };

    // `results` is a SLOT array and a v128 occupies two slots, so it cannot be
    // walked in lockstep with `ft.results`. The old multi-object `for` did
    // exactly that: with any v128 result the two lengths differ, which is
    // *illegal behaviour* in Zig — it panicked in Debug/ReleaseSafe, and in the
    // shipped ReleaseFast build it printed the raw slots and exited 0, silently
    // dropping the other results (and reading past `ft.results` for a lone
    // v128).
    var si: usize = 0;
    for (ft.results, 0..) |rt, i| {
        if (i != 0) try out.print(" ", .{});
        const w = interp.slotWidth(rt);
        if (si + w > results.len) break; // defensive: arity already agreed above
        if (rt == .v128) {
            // Low half first on the stack; print as one 128-bit hex value.
            try out.print("0x{x:0>16}{x:0>16}", .{ results[si + 1], results[si] });
            si += 2;
            continue;
        }
        const res = results[si];
        si += 1;
        switch (rt) {
            .i32 => try out.print("{d}", .{interp.asI32(res)}),
            .i64 => try out.print("{d}", .{interp.asI64(res)}),
            .f32 => try out.print("{d}", .{interp.asF32(res)}),
            .f64 => try out.print("{d}", .{interp.asF64(res)}),
            else => try out.print("0x{x}", .{res}),
        }
    }
    try out.print("\n", .{});
    return 0;
}

// =========================================================================================
// Tests. The CLI had none at all until F5-CLI put a POLICY PARSER in it — see `build.zig`'s
// `cli_tests` for why that stopped being acceptable.
// =========================================================================================

/// `parseFeatures` against a throwaway writer: the diagnostics are checked by the CLI's own
/// behaviour, and the tests below are about the SET it produces.
fn parseInto(spec: []const u8, base: wazmrt.features.Set) !wazmrt.features.Set {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    return parseFeatures(spec, base, &w);
}

fn parseFails(spec: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.BadFeatures, parseFeatures(spec, .{}, &w));
    // A refusal that says nothing is a refusal the user cannot act on.
    try std.testing.expect(w.buffered().len > 0);
}

test "--features: the seed is explicit, or inferred from ONE unambiguous shape" {
    const F = wazmrt.features.Feature;

    // Bare names mean "these and nothing else" — the seed is MVP.
    const only = try parseInto("simd,bulk_memory", .{});
    try std.testing.expect(only.has(.simd) and only.has(.bulk_memory));
    try std.testing.expect(!only.has(.gc) and !only.has(.threads) and !only.has(.custom_page_sizes));

    // Signed names mean "everything except these" — the seed is ALL.
    const except = try parseInto("-threads,-memory64", .{});
    try std.testing.expect(!except.has(.threads) and !except.has(.memory64));
    try std.testing.expect(except.has(.simd) and except.has(.gc));

    // Explicit seeds say it outright, and then either sign is unambiguous.
    try std.testing.expect((try parseInto("all", .{})).all());
    const mvp = try parseInto("mvp", .{});
    for (0..wazmrt.features.count) |i| try std.testing.expect(!mvp.has(@as(F, @enumFromInt(@as(u8, @intCast(i))))));
    try std.testing.expect(std.meta.eql(try parseInto("none", .{}), mvp));
    const seeded = try parseInto("mvp,gc,function_references,reference_types", .{});
    try std.testing.expect(seeded.has(.gc) and !seeded.has(.simd));
    const trimmed = try parseInto("all,-simd,-relaxed_simd", .{});
    try std.testing.expect(!trimmed.has(.simd) and trimmed.has(.gc));

    // ⚠️ Mixing signs WITHOUT a seed is refused rather than resolved. Both readings of
    // `gc,-simd` are defensible and neither is obvious, so picking one would be a precedence
    // rule nobody reviewed — the same objection that made `runScript`'s `path` a required
    // parameter instead of a defaulted one.
    try parseFails("gc,-simd");
    // ...and with a seed the identical items are fine, because now the question has an answer.
    const mixed = try parseInto("all,-simd,-relaxed_simd,gc", .{});
    try std.testing.expect(mixed.has(.gc) and !mixed.has(.simd));
}

test "--features: a name that is not a proposal is refused, not ignored" {
    // 🔒 THE FAILURE MODE THIS EXISTS TO PREVENT. Skipping an unrecognised item would leave the
    // user believing they had restricted something — `--features mvp,sim` would silently be
    // `mvp`, and a typo in the OTHER direction (`--features -simd2`) would silently be `all`.
    // A security control that quietly ignores what it was told is worse than no control.
    try parseFails("simd2");
    try parseFails("-nope");
    try parseFails("mvp,gc,typo");
    try parseFails("");
    try parseFails("simd,,gc");
    try parseFails("-");
}

test "--features: names come from the ENUM, so the CLI cannot offer a different list" {
    // ⚠️ The CLI would have been the FOURTH hand-written spelling of `features.Feature`, after
    // the engine, `capi.Feature` and `wazmrt.h` — and the two that were hand-written are exactly
    // the two that drifted and shipped a switch which silently did nothing. Every name is
    // accepted here without any of them being written down in `main.zig`.
    for (0..wazmrt.features.count) |i| {
        const f: wazmrt.features.Feature = @enumFromInt(@as(u8, @intCast(i)));
        const on = try parseInto(f.name(), .{});
        try std.testing.expect(on.has(f));
        var buf: [64]u8 = undefined;
        const off = try parseInto(try std.fmt.bufPrint(&buf, "-{s}", .{f.name()}), .{});
        try std.testing.expect(!off.has(f));
    }
}

test "--features: successive flags COMPOSE onto each other" {
    // `--features mvp --features simd` is one conversation, not two: each list is parsed onto
    // the set the previous one produced, so a later item cannot be silently dropped.
    const a = try parseInto("mvp", .{});
    const b = try parseInto("simd", a);
    // `simd` is bare, so it re-seeds to MVP and adds — the shape rule does not change because
    // the base did. What composes is the BASE, not the seed inference.
    try std.testing.expect(b.has(.simd));
    const c = try parseInto("-gc,-custom_descriptors", .{});
    const d = try parseInto("-simd,-relaxed_simd", c);
    try std.testing.expect(!d.has(.gc) and !d.has(.simd) and d.has(.threads));
}

test "F5: the runtime feature set is a subset of what was COMPILED IN, in every build" {
    // The Track 2c composition rule, stated once and pinned once. `-Dwat`/`-Dwasi` gate FRONT
    // ENDS (the text assembler, the WASI host); `--features` gates the wasm LANGUAGE. They are
    // orthogonal today — no proposal in `features.Feature` is compile-time removable — so the
    // subset relation holds because the compiled-in set is always the whole enum.
    //
    // ⚠️ That is a fact about today's code, not a law, which is why it is asserted rather than
    // assumed: a proposal that ever became `-D`-gated would make `Set.all()` mean different
    // things in different builds, and `--features simd` would then succeed in a build that
    // cannot honour it. `zig build features` compiles the same assertion in `capi.zig` across
    // all four `-Dwat`/`-Dwasi` combinations, which is where a divergence would first appear.
    const all: wazmrt.features.Set = .{};
    try std.testing.expect(all.all());
    try std.testing.expectEqual(@as(usize, 19), wazmrt.features.count);
}

test "--features: a long list does not overflow anything (regression)" {
    // 🔒 REGRESSION TEST FOR A STACK SMASH THIS PARSER SHIPPED IN ITS FIRST DRAFT. The items were
    // read into a `[features.count * 2]` array so the seed could be applied underneath them, and
    // `n` was never bounded. Every item must be a VALID proposal name to be stored — which is
    // exactly what made it look safe — but nothing stops a caller REPEATING one. Past 36 entries
    // it wrote off the end of a stack array: a panic under `zig build test`, and in the shipped
    // ReleaseSmall CLI a stack write reachable from the command line.
    //
    // ⚠️ **A buffer sized from a TYPE is not sized from the INPUT.** The fix re-splits the string
    // instead of buffering it, so there is no bound left to exceed.
    var buf: [4096]u8 = undefined;
    var spec: std.ArrayList(u8) = .empty;
    defer spec.deinit(std.testing.allocator);
    try spec.appendSlice(std.testing.allocator, "mvp");
    for (0..500) |_| try spec.appendSlice(std.testing.allocator, ",simd");

    var w: Io.Writer = .fixed(&buf);
    const set = try parseFeatures(spec.items, .{}, &w);
    try std.testing.expect(set.has(.simd));
    try std.testing.expect(!set.has(.gc));

    // The same length on the failing path — the error must be reported, not reached by walking
    // off the end of something first.
    var spec2: std.ArrayList(u8) = .empty;
    defer spec2.deinit(std.testing.allocator);
    for (0..500) |_| try spec2.appendSlice(std.testing.allocator, "simd,");
    try spec2.appendSlice(std.testing.allocator, "nosuchproposal");
    var w2: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.BadFeatures, parseFeatures(spec2.items, .{}, &w2));
}

test "--features: a seed is POSITIONAL — only the first item can replace the set" {
    // `mvp,gc,all` would otherwise mean "nothing, then gc, then everything", which is not a list
    // anyone writes on purpose. `all` in a later position is an unknown proposal name and is
    // refused, so the intent has to be stated once and at the front.
    try parseFails("mvp,gc,all");
    try parseFails("simd,mvp");
}
