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

/// Which run mode the command line ASKED FOR, as opposed to the one the module
/// turns out to support (`interop.md` §2.1, v20).
///
/// 🔒 **The distinction is the whole point of the explicit spellings.** `.auto` is
/// the bare-path form and falls back: an argument that names no export, on a
/// module with no `_start`, ends at the summary. `run` and `wasi` say which mode
/// the user meant, so falling back would be **succeeding at something other than
/// what was asked** — the §2.3 rule Z1 exists for. `wazmrt wasi m.wasm` on a
/// module with no `_start` is a failed run, not a summary.
const Mode = enum { auto, run, wasi };

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

    // 🤝 **The sibling's subcommand spellings** (`interop.md` §2.1, v20 — Track B-c4). wazmrt
    // dispatches on the file extension and on whether an export was named; wasmrt names the mode
    // outright. **The agreed target is ADDITIVE: each accepts the other's spelling and neither
    // loses the form it already ships**, so every bare-path invocation below is untouched and
    // these four are new positions that used to be `cannot read 'run': FileNotFound`.
    //
    // 🔑 **`run` and `wasi` are ALIASES onto the existing paths, not copies of them.** They set a
    // mode and move `argi` past the word; everything after is parsed by the same code, so the
    // verify gate, the feature restriction, `--max-iterations` and the Z1/Z2/Z3 guards apply
    // identically whichever spelling was used. *A second parser would be a second place for those
    // to drift out of.* ⚠️ `wat` is a genuinely NEW capability (assemble to a file), which is why
    // this item is not a rename.
    //
    // 🔒 **Recognised as the FIRST argument only**, like `-h`/`-v` and the three subcommands above
    // (§2.1's last row). `wazmrt m.wasm run` is a module named `m.wasm` being asked for an export
    // called `run`, and it must stay that way.
    var mode: Mode = .auto;
    if (std.mem.eql(u8, args[1], "wat")) return watSubcommand(arena, io, out, args[2..]);
    if (std.mem.eql(u8, args[1], "wast")) return wastSubcommand(arena, io, out, args[2..]);
    if (std.mem.eql(u8, args[1], "run")) mode = .run;
    if (std.mem.eql(u8, args[1], "wasi")) mode = .wasi;

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
    // Past the subcommand word when there was one, so `run --features mvp m.wasm add`
    // parses exactly as `--features mvp m.wasm add` does — one parser, both spellings.
    var argi: usize = if (mode == .auto) 1 else 2;
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

    // Which token is the module path, and what follows it.
    //
    // 🤝 **`wasi` is the one spelling where WASI flags may PRECEDE the path** — the sibling's
    // usage line is `wasi [flags] <file> [-- argv]`, and measured, it accepts them on either side.
    // wazmrt's parser wants the path first, so the leading flag run is moved BEHIND it.
    // ⚠️ **`lead ++ tail`, never `tail ++ lead`:** an explicit `--` lives in `tail`, so appending
    // the flags after it would hand `--dir` to the guest as argv — silently dropping a sandbox
    // grant, which is the fail-OPEN direction §2.4b exists to catch.
    // 🔒 This does NOT loosen §2.4b for the bare form: there, every wazmrt flag but `--features`
    // still trails the path, and one written before it is still an unknown-flag error below.
    var path: []const u8 = undefined;
    var rest: []const [:0]const u8 = undefined;
    if (mode == .wasi) {
        const split = (try wasiSplit(arena, args[argi..])) orelse {
            try out.print(
                "error: wasi: no module given\n  usage: wazmrt wasi [flags] <module> [-- argv]\n",
                .{},
            );
            return exit_failure;
        };
        path = split.path;
        rest = split.rest;
    } else {
        path = args[argi];
        rest = args[argi + 1 ..];
    }

    // ⚠️ **Z2 / v14: a flag-shaped argument in the module-path position is an unknown flag, not a
    // missing file.** This used to fall through to the read below and report
    // `cannot read '--bogus': FileNotFound` — the right exit code with a message that sends the
    // user to look at the filesystem for a typo in their flag. `-h`/`-v` are handled above as the
    // first argument only (§2.4), and `--features` has already been consumed.
    // In `wasi` mode this is also what catches an unrecognised LEADING flag: `flagRegion` stops at
    // it, so it lands in the path position and is named here rather than opened as a file.
    if (path.len >= 2 and path[0] == '-') {
        try reportUnknownFlag(out, path, mode != .run);
        return exit_failure;
    }

    // 🔒 **`--features` after the module path is an ERROR** (owner, 2026-09-19). It is the one
    // wazmrt flag that PRECEDES the path, so written after it the flag cannot apply — and until
    // this check it applied nothing and said nothing, on the one flag whose job is to refuse
    // modules. Checked before the `--max-iterations` splice and before the file is read, so the
    // message names the flag rather than the file.
    if (misplacedFeaturesFlag(rest)) |bad| {
        try out.print(
            "error: '{s}' must come BEFORE the module path\n" ++
                "  usage: wazmrt --features <list> <module> [...]\n" ++
                "  it is the only wazmrt flag that precedes the module; use '--' to pass it to the guest\n",
            .{bad},
        );
        return exit_failure;
    }

    // `--max-iterations <n>` (Track H) is consumed HERE, before the mode dispatch,
    // and not in `runWasi` alongside the other ceilings. Reason: run mode selects
    // on `rest[0]` naming an export, so a flag left in place would silently push
    // `wazmrt m.wasm --max-iterations 100 myfunc` into WASI mode — and the hint the
    // trap prints would then name a flag that did not work on the path that
    // printed it. One parse site, both paths. `0` = no limit.
    var max_iterations: u64 = wazmrt.interp.default_max_iterations;
    {
        const region = flagRegion(rest);
        var i: usize = 0;
        while (i + 1 < region.len) : (i += 1) {
            if (!std.mem.eql(u8, region[i], "--max-iterations")) continue;
            max_iterations = parseSize(region[i + 1]) orelse {
                try out.print("error: --max-iterations '{s}': expected a count like 1M or 100000 (0 = no limit)\n", .{region[i + 1]});
                return exit_failure;
            };
            const spliced = try arena.alloc([:0]const u8, rest.len - 2);
            @memcpy(spliced[0..i], rest[0..i]);
            @memcpy(spliced[i..], rest[i + 2 ..]);
            rest = spliced;
            break;
        }
    }
    // ⚠️ **Z2: an unrecognised `--flag` in the leading host-flag run stops the run** (§2.4a), before
    // the file is read, so the message names the flag rather than the file. Single-dash tokens are
    // NOT examined here: by v15 they are the guest's wherever there is a guest, and the two modes
    // with no guest argv re-check with `single_dash = true` once the mode is known.
    // 🔑 Whether THIS command can have a guest is already knowable here, and the hint is only
    // true when it can: `run` passes function arguments, not argv, and a `.wast` script has no
    // argv at all. `.auto`/`wasi` on a binary stays optimistic — the module has not been decoded
    // yet, so `_start` is genuinely unknown, and over-offering `--` there costs nothing.
    const may_have_guest = mode != .run and !std.mem.endsWith(u8, path, ".wast");
    if (unknownHostFlag(rest, false)) |bad| {
        try reportUnknownFlag(out, bad, may_have_guest);
        return exit_failure;
    }

    // ⚠️ Before anything is read or run: say so if a wazmrt flag was written
    // where only the guest will see it. Placed here so it covers EVERY mode —
    // run, WASI, `.wast` and summarize — rather than the one that happened to
    // notice. See `warnMisplacedFlags`.
    try warnMisplacedFlags(out, rest);

    var bytes: []const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return exit_failure;
    };

    // .wast script mode: parse + run the assertions, print a pass/fail summary.
    if (std.mem.endsWith(u8, path, ".wast")) {
        // ⚠️ **§2.4a item 4: a command with no guest argv has no guest positions**, so a single-dash
        // token here is ours too and an unrecognised one is an error. `wazmrt s.wast --bogus` used
        // to exit 0 with the flag silently ignored.
        if (unknownHostFlag(rest, true)) |bad| {
            try reportUnknownFlag(out, bad, false);
            return exit_failure;
        }
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
    // 🔒 **An explicit `run`/`wasi` IS an intent to execute, whatever the module turns out to
    // contain.** Without this, `wazmrt wasi unauthorized.wasm` on a module with no `_start` would
    // skip the gate, then report which exports it does have — inspecting and describing a module
    // the pin DB never authorized. Authorization first is this path's standing order; the mode
    // check below therefore runs *after* the gate rather than short-circuiting it.
    const will_execute = mode != .auto or
        (rest.len >= 1 and findExport(&module, rest[0]) != null) or
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

    // 🔒 **THE EXPLICIT SPELLINGS DO NOT FALL BACK** (`interop.md` §2.3 — the Z1 rule, applied
    // where the bare form cannot apply it). `wazmrt run m.wasm nosuch` on a module that also
    // exports `_start` would otherwise slide into WASI mode and run something the user never
    // asked for, with `nosuch` quietly becoming guest argv — succeeding at a different job and
    // reporting rc 0. In the bare form that word genuinely might be argv, which is why the guard
    // there is narrow; here the user named the mode, so there is nothing to be ambiguous about.
    switch (mode) {
        .auto => {},
        .run => {
            if (rest.len == 0 or std.mem.eql(u8, rest[0], "--")) {
                try out.print(
                    "error: run: no function named\n  usage: wazmrt run <module> <function> [args...]\n",
                    .{},
                );
                return exit_failure;
            }
            if (findExport(&module, rest[0]) == null) {
                try reportMissingExport(out, &module, rest[0], path);
                return exit_failure;
            }
        },
        .wasi => if (findExport(&module, "_start") == null) {
            try out.print("error: wasi: '{s}' exports no '_start'\n", .{path});
            try printExportList(out, &module);
            return exit_failure;
        },
    }

    // Run mode: `wazmrt <module.wasm> <export> [args...]` — invoke and print.
    // A trailing arg only selects an export if it actually names one; otherwise
    // it belongs to the WASI command below (`--dir …`, guest argv, …).
    if (rest.len >= 1 and findExport(&module, rest[0]) != null) {
        return try runFunction(arena, out, &module, rest[0], rest[1..], max_iterations);
    }

    // WASI command: `wazmrt <module.wasm> [--dir <host>[:<guest>]]... [args...]`
    // runs `_start` with the `wasi_snapshot_preview1` host imports wired up.
    if (findExport(&module, "_start")) |start_index| {
        const code = runWasi(arena, io, out, &module, path, start_index, rest, max_iterations) catch |e| {
            if (e != AlreadyReported) try out.print("trap: {s}\n", .{@errorName(e)});
            return exit_failure; // a trap is a failed run
        };
        // Pass the GUEST's own exit code through: `proc_exit(1)` used to be
        // merely printed as "(exit 1)" while the process still exited 0.
        if (code != 0) try out.print("(exit {d})\n", .{code});
        return std.math.cast(u8, code) orelse exit_failure;
    }

    // 🔒 **Z3 / `interop.md` §2.5: no line may call a module VALID unless it validated.** This
    // header prints BEFORE validation runs at the end of this path, so it said "valid wasm v1" above
    // its own "validation: FAILED" — the exit code was right and the first line a human reads was
    // not. Neutral wording is the fix; the verdict is the `validation:` line below.
    // 🔒 **Z1 / `interop.md` §2.3: never silently succeed at something other than what was asked.**
    // Reaching here means the first argument named no export AND the module has no `_start` — so it
    // could only ever have been an export name, and the run used to print a summary and exit **0**
    // with the word silently dropped. ⚠️ The guard is deliberately narrow, as §2.5h asks: where the
    // module DOES export `_start` the same word may legitimately be guest argv, and that path
    // returned above without reaching this.
    // ⚠️ **Look past the leading host-flag run, not at `rest[0]`.** A first cut checked `rest[0]`
    // and `wazmrt m.wasm --allow-symlink spin` still summarized in silence — the word sat behind a
    // flag, so the guard never saw it. `flagRegion` already knows where our flags stop; use it.
    // ⚠️ An explicit `--` is left alone: the user SAID the rest is the guest's, and a guest position
    // is never examined (§2.4a), even when it turns out there is no guest to receive it.
    const first_word = flagRegion(rest).len;
    if (rest.len > first_word and !std.mem.eql(u8, rest[first_word], "--")) {
        try reportMissingExport(out, &module, rest[first_word], path);
        return exit_failure;
    }

    // ⚠️ **§2.4a item 4 again:** summarize has no guest argv either, so a leftover single-dash flag
    // is a host position. The `--flag` case was caught before the read; this catches `-x`.
    if (unknownHostFlag(rest, true)) |bad| {
        try reportUnknownFlag(out, bad, false);
        return exit_failure;
    }

    try out.print("{s}: wasm v{d}, {d} section(s)\n", .{ path, module.version, module.sections.len });
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

/// Resolve one proposal name, in **either vocabulary**.
///
/// 🤝 `interop.md` §2.2 (v20): wasmrt accepts both spellings and wazmrt accepted only its own, so
/// `--features bulk-memory-operations` was an `unknown proposal` error here while the identical
/// command line worked on the sibling. **A shared CLI whose flag VALUES are not shared is not
/// swappable**, so this is a contract row, not a nicety.
///
/// Three passes, most specific first:
///   1. this enum's own name (`bulk_memory`) — unchanged, and still what wazmrt prints;
///   2. the same name with **hyphens**;
///   3. three longer proposal-repository spellings that carry no shorter form here.
///
/// 🔎 **Pass 2 covers wasm-tools' ENTIRE vocabulary, and that was measured, not assumed.**
/// `wasm-tools validate --features <unknown>` prints its valid list, and every name in it that
/// wazmrt models is this enum's name with `_` written `-`: `bulk-memory`, `sign-extension`,
/// `saturating-float-to-int`, `exceptions`, `reference-types`, `tail-call`, `custom-page-sizes`,
/// `custom-descriptors`, `wide-arithmetic`, `function-references`, `multi-memory`, `multi-value`,
/// `extended-const`, `relaxed-simd`, `memory64`, `gc`, `simd`, `threads`.
/// ⚠️ **A first draft of this function hard-coded four "spec names" — `bulk-memory-operations`,
/// `sign-extension-ops`, `nontrapping-float-to-int-conversions`, `exception-handling` — as though
/// wasm-tools used them. It does not.** Three of the four turned out to be real anyway, as aliases
/// *wasmrt* carries, which is why they are here; but the justification was invented and one branch
/// would have been dead. 🎓 *Being right for a reason you did not check is not being right.*
///
/// Pass 3 is therefore scoped to what was **verified by running the sibling**: each name below was
/// fed to `wasmrt --features` and accepted. `mutable-global` and `tail-calls` were rejected by it
/// and are deliberately absent.
///
/// ⚠️ **An unrecognised name stays an ERROR** (see the caller). Widening the vocabulary must not
/// widen it to "anything we failed to parse": `--features mvp,sim` silently meaning `mvp` is the
/// security-control-that-drops-what-it-was-told failure this file already refuses.
fn featureFromSpelling(name: []const u8) ?wazmrt.features.Feature {
    if (std.meta.stringToEnum(wazmrt.features.Feature, name)) |f| return f;
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    const n = buf[0..name.len];
    if (std.meta.stringToEnum(wazmrt.features.Feature, n)) |f| return f;
    // Longer proposal-repository spellings, each verified accepted by wasmrt (2026-09-19).
    if (std.mem.eql(u8, n, "bulk_memory_operations")) return .bulk_memory;
    if (std.mem.eql(u8, n, "sign_extension_ops")) return .sign_extension;
    if (std.mem.eql(u8, n, "nontrapping_float_to_int_conversions")) return .saturating_float_to_int;
    if (std.mem.eql(u8, n, "exception_handling")) return .exceptions;
    return null;
}

/// Classify one already-trimmed item, or report why it is not one./// Classify one already-trimmed item, or report why it is not one.
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
    const f = featureFromSpelling(name) orelse {
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
        \\USAGE — both spellings work, so a command line written for either runtime runs here:
        \\  {s} <module> <export> [args...]   invoke an exported function and print results
        \\  {s} <module> [wasi-flags] [-- argv]  run a WASI `_start` command module
        \\  {s} <module>                      summarize + validate (no matching export/_start)
        \\  {s} <script.wast>                 run a spec-test (.wast) script
        \\  {s} run <module> <export> [args...]   invoke an exported function
        \\  {s} wasi [flags] <module> [-- argv]   run a WASI `_start` command
        \\  {s} wat <file.wat> [-o out.wasm]      assemble the text format to a binary
        \\  {s} wast <file|dir>... [-v]           run .wast spec scripts
        \\  {s} <subcommand> ...              pin / keygen / sign (below)
        \\  {s} -h | --help | -v | --version
        \\
        \\  The named modes do NOT fall back: `run` must name an export that exists and
        \\  `wasi` must find `_start`, or the run fails. The bare forms still choose the
        \\  mode from the module, which is the behaviour they have always had.
        \\
        \\  POSITION  `--features <list>` is the ONLY wazmrt flag that goes BEFORE <module>:
        \\                {s} --features <list> <module> [...]
        \\            EVERY other wazmrt flag goes AFTER the module path. Written after
        \\            the path it is an ERROR, because it could not apply there.
        \\            EXCEPT under `wasi`, whose flags may precede the module too —
        \\            `wasi --dir .:/ prog.wasm` and `wasi prog.wasm --dir .:/` both work.
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
        \\                              `::` also separates and is never ambiguous: `--dir C:\data::/d`
        \\                              a lone `:` splits too, except after a drive letter (`C:\tmp`)
        \\  --ro-dir <host>[:<guest>]   grant a read-only preopen (no write/create/delete)
        \\  --env KEY=VALUE             set one environment variable for the guest
        \\  --max-memory <size>         linear-memory ceiling for a WASI command (default 1G; e.g. 512M, 2G)
        \\                              the default ceiling applies to every run mode
        \\  --max-table-elems <count>   table-entry ceiling (default 128M; e.g. 1M, 100000)
        \\  --max-iterations <count>    stop a guest that never returns (default 1G; 0 = no limit)
        \\                              one iteration = one loop back-edge or one tail call
        \\  --                          end wazmrt flags; the rest is the guest's argv
        \\
        \\VERIFICATION FLAGS (authenticity — see the pin DB / signatures)
        \\  --pins <path>               use this pin DB instead of the default;
        \\                              ignored under a root-owned `# mode: enforce`
        \\  --verify off|warn|enforce   raise verification strictness (never lowers it)
        \\  --no-verify, --yes          run an unverified module (refused under enforce)
        \\      Pin DB lookup order: {s}
        \\                           then {s}   (wazmrt's own path, kept for existing installs)
        \\      If neither exists but the sibling runtime's DB does, wazmrt says so rather than
        \\      running unverified in silence.
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
        \\  --features <list>           restrict the accepted proposals
        \\      POSITION: BEFORE the module path, unlike every other wazmrt flag:
        \\          {s} --features mvp mod.wasm
        \\      Written after the path it is an ERROR and nothing runs — it could not have
        \\      applied there, and until 2026-09-19 it was ignored in silence. After `--`
        \\      it is the guest's argv and is passed through untouched.
        \\      VALUE: a comma-separated list. Two seeds may lead it: `all` (everything, the default)
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
    , .{ wazmrt.version, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, sharedPinsPath(), defaultPinsPath(), prog });
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
const WasiSplit = struct { path: [:0]const u8, rest: []const [:0]const u8 };

/// Split the sibling's `wasi [flags] <module> [flags] [-- argv]` into the module
/// path and the tail wazmrt's own parser expects — **the leading flags first,
/// then everything that followed the path**. Null when no non-flag token is
/// present, i.e. no module was named.
///
/// ⚠️⚠️ **`lead ++ tail`, NEVER `tail ++ lead`, and that is the whole reason this
/// is a named function with a test instead of four lines inline.** An explicit
/// `--` lives in `tail`; appending the flags after it would put `--dir` into the
/// GUEST's argv, where wazmrt never looks — so `wasi --dir /data prog.wasm -- x`
/// would run with no preopen at all and say nothing. That is the fail-OPEN
/// direction §2.4b exists to catch, produced by an ordering mistake that no
/// amount of reading the happy path would reveal.
///
/// 🔒 An unrecognised LEADING flag is deliberately not diagnosed here:
/// `flagRegion` stops at it, so it lands in the path position and the caller's
/// flag-shaped-path check names it (§2.4a) instead of opening it as a file.
fn wasiSplit(a: std.mem.Allocator, sub: []const [:0]const u8) !?WasiSplit {
    const lead = flagRegion(sub).len;
    if (lead == sub.len) return null;
    const tail = sub[lead + 1 ..];
    const merged = try a.alloc([:0]const u8, lead + tail.len);
    @memcpy(merged[0..lead], sub[0..lead]);
    @memcpy(merged[lead..], tail);
    return .{ .path = sub[lead], .rest = merged };
}

/// `wazmrt wat <file.wat> [-o <out.wasm>]` — assemble the text format to a binary.
///
/// 🆕 **The one genuinely NEW capability in Track B-c4** (`interop.md` §2.1: *"wazmrt must grow
/// it"*). The other three spellings are aliases onto paths that already existed; this is the
/// assembler, which wazmrt has always had, finally reachable without running the module.
///
/// 🔒 **Without `-o` it assembles and reports the size, writing NOTHING** — measured from the
/// sibling rather than assumed, because "assemble" reads like a verb that produces a file and it
/// does not. A default output name would be worse than no output: it would create a file next to
/// the source that the user never named.
///
/// ⚠️ **No verify gate here, deliberately, and the reason is not "it is only a tool":** this path
/// never instantiates or invokes anything, so there is nothing for a pin to authorize. The gate
/// exists to stand in front of EXECUTION, and `.wast` earned its gate precisely because
/// `runScript` executes. Assembling text to bytes is the same operation `pin` itself performs
/// before hashing.
fn watSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !u8 {
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            if (i + 1 >= rest.len) {
                try out.print("error: wat: '{s}' needs a path\n", .{a});
                return exit_failure;
            }
            out_path = rest[i + 1];
            i += 1;
            continue;
        }
        // §2.4a item 4: this command has no guest argv, so EVERY argument is a
        // host position and a single dash is ours too — `-x` is an error, not a
        // filename. The same reading `.wast` and summarize use.
        if (a.len >= 2 and a[0] == '-') {
            try reportUnknownFlag(out, a, false);
            return exit_failure;
        }
        if (in_path != null) {
            try out.print("error: wat: one input file at a time (already given '{s}')\n", .{in_path.?});
            return exit_failure;
        }
        in_path = a;
    }
    const src_path = in_path orelse {
        try out.print("usage: wazmrt wat <file.wat> [-o <out.wasm>]\n", .{});
        return exit_failure;
    };

    const text = Io.Dir.cwd().readFileAlloc(io, src_path, arena, .limited(64 << 20)) catch |e| {
        try out.print("error: cannot read '{s}': {s}\n", .{ src_path, @errorName(e) });
        return exit_failure;
    };
    const bytes = wazmrt.wat.assemble(arena, text) catch |e| {
        try out.print("error: cannot assemble '{s}': {s}\n", .{ src_path, @errorName(e) });
        return exit_failure;
    };
    if (out_path) |dst| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes }) catch |e| {
            try out.print("error: cannot write '{s}': {s}\n", .{ dst, @errorName(e) });
            return exit_failure;
        };
        try out.print("{s}: {d} bytes\n", .{ dst, bytes.len });
    } else {
        try out.print("{s}: assembled {d} bytes\n", .{ src_path, bytes.len });
    }
    return 0;
}

/// `wazmrt wast <file|dir>... [-v] [--features <list>]` — run one or more `.wast`
/// spec scripts, or every script under a directory.
///
/// 🤝 The sibling's spelling (`interop.md` §2.1). wazmrt's own `wazmrt s.wast` keeps working and
/// is unchanged; this adds the multi-target and directory forms it never had.
///
/// 🔒 **The verify gate runs per script, exactly as the bare form's does, and that is not
/// optional.** `runScriptWith` INSTANTIATES AND INVOKES the modules a script contains, including
/// `(module binary "…")` raw payloads — so this is an execution path. The bare `.wast` path once
/// returned before its gate, which meant any wasm could be run unpinned under a root-owned
/// `# mode: enforce` just by wrapping it in a script, and the attacker picks the extension.
/// ⚠️ **A second entry point to an execution path is a second chance to forget the gate.**
///
/// 🔑 `--features` reaches here for the same reason: a restriction that covered `.wasm` and not
/// `.wast` could be stepped around by wrapping the module in a script.
fn wastSubcommand(arena: std.mem.Allocator, io: Io, out: *Io.Writer, rest: []const []const u8) !u8 {
    var targets: std.ArrayList([]const u8) = .empty;
    var verbose = false;
    var cli_features: wazmrt.features.Set = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--features") and i + 1 < rest.len) {
            cli_features = parseFeatures(rest[i + 1], cli_features, out) catch return exit_failure;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--features=")) {
            cli_features = parseFeatures(a["--features=".len..], cli_features, out) catch return exit_failure;
            continue;
        }
        // No guest argv in this mode, so a single dash is a host position too (§2.4a item 4).
        if (a.len >= 2 and a[0] == '-') {
            try reportUnknownFlag(out, a, false);
            return exit_failure;
        }
        try targets.append(arena, a);
    }
    if (targets.items.len == 0) {
        try out.print("usage: wazmrt wast <file|dir>... [-v]\n", .{});
        return exit_failure;
    }
    if (cli_features.incoherent()) |pair| {
        try out.print("error: --features: '{s}' is layered on '{s}' and cannot be enabled without it\n", .{ pair[0].name(), pair[1].name() });
        return exit_failure;
    }

    // Expand directories into the scripts under them, so one line of output per
    // script either way and the totals mean the same thing in both forms.
    var scripts: std.ArrayList([]const u8) = .empty;
    for (targets.items) |t| {
        const st = Io.Dir.cwd().statFile(io, t, .{}) catch |e| {
            try out.print("error: cannot stat '{s}': {s}\n", .{ t, @errorName(e) });
            return exit_failure;
        };
        if (st.kind != .directory) {
            try scripts.append(arena, t);
            continue;
        }
        collectWastFiles(arena, io, t, &scripts) catch |e| {
            try out.print("error: cannot walk '{s}': {s}\n", .{ t, @errorName(e) });
            return exit_failure;
        };
    }
    if (scripts.items.len == 0) {
        try out.print("error: no .wast scripts under the given path(s)\n", .{});
        return exit_failure;
    }

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;
    var errored: usize = 0;
    for (scripts.items) |script| {
        const bytes = Io.Dir.cwd().readFileAlloc(io, script, arena, .limited(64 << 20)) catch |e| {
            try out.print("error: cannot read '{s}': {s}\n", .{ script, @errorName(e) });
            errored += 1;
            continue;
        };
        // See the doc comment: this executes, so it is gated like a module.
        if (!(try verifyGate(arena, io, out, bytes, script, rest))) return exit_failure;
        const s = wazmrt.wast.runScriptWith(arena, bytes, script, cli_features) catch |e| {
            try out.print("error: cannot run '{s}': {s}\n", .{ script, @errorName(e) });
            errored += 1;
            continue;
        };
        total_passed += s.passed;
        total_failed += s.failed;
        total_skipped += s.skipped;
        try out.print("{s}: {d} passed, {d} failed, {d} skipped\n", .{ script, s.passed, s.failed, s.skipped });
        for (s.failures.items) |f| try out.print("  failure: {s}\n", .{f});
        // ⚠️ `runScriptWith` caps the failure list it retains. Saying "and N more"
        // is what stopped 25 distinct decoder defects reading as one problem; `-v`
        // is for when the cap itself is what you are fighting, and says so rather
        // than pretending the remainder was printed.
        if (s.failed > s.failures.items.len) {
            if (verbose) {
                try out.print("  ... and {d} more, NOT listed — the runner keeps only the first {d}\n", .{ s.failed - s.failures.items.len, s.failures.items.len });
            } else {
                try out.print("  ... and {d} more\n", .{s.failed - s.failures.items.len});
            }
        }
    }

    // One script keeps the single-line output the bare form has always printed;
    // more than one gets a total, because a per-file list with no sum is a list
    // somebody has to add up by hand.
    if (scripts.items.len > 1 or errored != 0) {
        try out.print("total: {d} file(s) — {d} passed, {d} failed, {d} skipped", .{ scripts.items.len, total_passed, total_failed, total_skipped });
        if (errored != 0) try out.print(", {d} could not be run", .{errored});
        try out.print("\n", .{});
    }
    // A failing assertion is a failing run — and so is a script that could not be
    // read or parsed, which used to be indistinguishable from one that passed.
    return if (total_failed != 0 or errored != 0) exit_failure else 0;
}

/// Collect every `.wast` under `dir_path`, recursively, in walk order.
fn collectWastFiles(arena: std.mem.Allocator, io: Io, dir_path: []const u8, outp: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.basename, ".wast")) continue;
        // `ent.path` is invalidated by the next `walker.next`, so copy it now —
        // the same trap `collectDirPins` documents.
        try outp.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, ent.path }));
    }
}

/// Z1's refusal (`interop.md` §2.3): an export was named and the module does not
/// have it. One wording, two callers — the bare form's guard and the explicit
/// `run` spelling — because *a message written out a second time is a message
/// that will drift*, and this one is a contract row.
fn reportMissingExport(out: *Io.Writer, module: *const wazmrt.Module, name: []const u8, path: []const u8) !void {
    try out.print("error: no exported function '{s}' in {s}\n", .{ name, path });
    try printExportList(out, module);
}

/// The `exports:` line under a refusal — or an explicit statement that there are
/// none, which is the case a bare list would render as blank and unreadable.
fn printExportList(out: *Io.Writer, module: *const wazmrt.Module) !void {
    if (module.exports.len == 0) {
        try out.print("  the module exports nothing\n", .{});
        return;
    }
    try out.print("  exports:", .{});
    for (module.exports) |e| try out.print(" {s}", .{e.name});
    try out.print("\n", .{});
}

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

const windows = @import("builtin").os.tag == .windows;

/// 🔒 **The SHARED pin DB, named for the deployment both runtimes ship inside** (owner, 2026-09-19;
/// `interop.md` §3.3, contract v18). Looked at first by wazmrt and by wasmrt alike, so an operator
/// who swaps one binary for the other keeps the same policy.
fn sharedPinsPath() []const u8 {
    return if (windows) "C:\\ProgramData\\wasmtk\\pins" else "/etc/wasmtk/pins";
}

/// wazmrt's own historical path, kept as a FALLBACK so existing installs keep working.
fn defaultPinsPath() []const u8 {
    return if (windows) "C:\\ProgramData\\wazmrt\\pins" else "/etc/wazmrt/pins";
}

/// The SIBLING's path. Read for one purpose only: to tell "this host has no pin policy" apart from
/// "this host has one and I am not the runtime that was installed with it".
fn siblingPinsPath() []const u8 {
    return if (windows) "C:\\ProgramData\\wasmrt\\pins" else "/etc/wasmrt/pins";
}

/// Where the default pin DB was found, and what it said.
const PinDbLookup = struct { path: []const u8, text: ?[]const u8 };

/// Resolve the default pin DB: shared path, then our own, **and say something loud when neither
/// exists but the sibling's does.**
///
/// ⚠⚠ **The WARNING is the load-bearing half of this row, not the shared path** (`interop.md` §3.3).
/// A shared path alone still fails silently the moment a deployment is part-migrated: the binary is
/// swapped, the DB is still at the sibling's path, nothing is found, and `armed = false` is a
/// *perfectly ordinary* state with no error attached to it. 🎓 **The failure mode was never "no DB" —
/// it is "no DB, and no reason to think that is wrong."** Detecting the sibling's DB is the one cheap
/// signal that distinguishes the two, and without it swapping runtimes is a **silent security
/// downgrade**, which is the worst defect class either project tracks.
///
/// ⚠️ It warns; it does not refuse. Refusing would make installing either runtime on a host that has
/// never had a pin policy an error, and "no policy" is a legitimate configuration.
fn resolvePinDb(arena: std.mem.Allocator, io: Io, out: *Io.Writer) !?PinDbLookup {
    const read = struct {
        fn f(a: std.mem.Allocator, i: Io, o: *Io.Writer, p: []const u8) !?[]const u8 {
            return Io.Dir.cwd().readFileAlloc(i, p, a, .limited(1 << 20)) catch |e| switch (e) {
                error.FileNotFound => null,
                else => {
                    try o.print("error: cannot read pin DB '{s}': {s}\n", .{ p, @errorName(e) });
                    return error.Reported;
                },
            };
        }
    }.f;

    const shared_text = try read(arena, io, out, sharedPinsPath());
    const own_text = if (shared_text == null) try read(arena, io, out, defaultPinsPath()) else null;
    // The sibling's path is consulted ONLY when neither of ours exists — never to read a policy
    // from, only to answer "is this host actually unmanaged?".
    const sibling_text = if (shared_text == null and own_text == null)
        try read(arena, io, out, siblingPinsPath())
    else
        null;

    const choice = choosePinDb(shared_text != null, own_text != null, sibling_text != null);
    if (choice.warn_sibling) {
        try out.print(
            "warning: no pin DB at '{s}' or '{s}', but one EXISTS at '{s}'\n" ++
                "  this host has a pin policy installed for the sibling runtime and wazmrt is NOT reading it\n" ++
                "  verification is effectively OFF for this run; move or copy it to '{s}' to apply it\n",
            .{ sharedPinsPath(), defaultPinsPath(), siblingPinsPath(), sharedPinsPath() },
        );
    }
    return switch (choice.which) {
        .shared => .{ .path = sharedPinsPath(), .text = shared_text },
        .own => .{ .path = defaultPinsPath(), .text = own_text },
        .none => .{ .path = sharedPinsPath(), .text = null },
    };
}

/// Which DB wins, and whether to shout — **a pure function, so it can be tested exhaustively**
/// without a root-owned file on the machine running the tests. (wasmrt reached the same shape for
/// the same reason; `interop.md` §3.3.)
const PinDbChoice = struct { which: enum { shared, own, none }, warn_sibling: bool };

fn choosePinDb(shared_exists: bool, own_exists: bool, sibling_exists: bool) PinDbChoice {
    if (shared_exists) return .{ .which = .shared, .warn_sibling = false };
    if (own_exists) return .{ .which = .own, .warn_sibling = false };
    // ⚠️ Unarmed is a legitimate state; unarmed WHILE THE SIBLING'S POLICY SITS THERE is not.
    return .{ .which = .none, .warn_sibling = sibling_exists };
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
/// Every wazmrt flag that takes a VALUE, and every one that does not.
///
/// 🔒 **One list, at file scope, because `warnMisplacedFlags` needs the same
/// names `flagRegion` recognises.** A second copy would drift — *a list written
/// out a second time is a list that will drift* is a rule this project has paid
/// for repeatedly, and a drifted copy here would mean a flag that is parsed but
/// never warned about, or warned about but not parsed.
const flags_with_value = [_][]const u8{ "--dir", "--ro-dir", "--env", "--verify", "--pins", "--max-memory", "--max-table-elems", "--max-iterations" };
///
/// 🚨 **`--allow-symlink` WAS MISSING FROM THIS LIST AND IT DISARMED THE VERIFY GATE.**
/// `runWasi` parses it in its own flag loop, but `flagRegion` never knew about it, so the region
/// ENDED at it and every host flag written after it became invisible to `hasFlag`, `flagValue`
/// and the `--max-iterations` splice. Measured 2026-09-19:
/// `wazmrt start.wasm --allow-symlink --verify enforce` ran an **unverified** module, **rc 0**,
/// where the same line without `--allow-symlink` correctly refuses it. `--max-iterations` after it
/// was likewise dropped, and the mode dispatch lost the export name to boot.
/// 🎓 **This is exactly the drift the comment above warns about, and it had already happened** —
/// the "one list" was one list and the parser was still reading a different vocabulary. *A list
/// kept in one place is not the same as a list kept in agreement with its consumer.*
const flags_bare = [_][]const u8{ "--no-verify", "--yes", "--allow-symlink" };

fn flagRegion(rest: []const []const u8) []const []const u8 {
    const two = flags_with_value;
    const one = flags_bare;
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

/// ⚠️ **`--features` written AFTER the module path is an ERROR, not a warning.**
///
/// 🔒 **Owner, 2026-09-19:** *"If the `--features <list>` has to go before the module, we need
/// to identify that in the invocation and help sections for sure, and we need an error thrown when
/// it is in the wrong location."*
///
/// `--features` is the ONE wazmrt flag that precedes the module path, and it is deliberately absent
/// from `flagRegion`'s lists so a guest's own `--features mvp` can never narrow the language (see
/// the parse site). ⚠️ **That left it with no position where being wrong was noticed:**
/// `flagRegion` stops at it, so it reads as the first guest argument, and `warnMisplacedFlags` only
/// fires for names in those same lists. **Measured 2026-09-19: `wazmrt m.wasm --features mvp` ran
/// under the FULL feature set and printed nothing** — the fail-OPEN direction, on the one flag
/// whose entire job is to REFUSE modules.
///
/// 🎓 **This is the "one list" comment's blind spot, not a missing entry in it.** Both lists are
/// complete for flags that TRAIL the path; `--features` is invisible to them because it belongs to
/// a position neither list describes. *A rule that names the thing it guards will not guard the
/// thing it does not name.*
///
/// **Error, do not warn — a deliberate split from `warnMisplacedFlags`.** That function warns
/// because a guest may legitimately take `--dir` as its own argument. Here the token sits in a
/// HOST-flag position (the leading run after the path, before any guest argument), where the user
/// is unambiguously addressing wazmrt; `interop.md` §2.4a makes that position an error for an
/// unrecognised `--flag`, and a recognised one written where it cannot work is no better.
/// ⚠️ Nothing after `--`, and nothing after the first non-flag argument, is examined: there the
/// token is the guest's, and `warnMisplacedFlags` keeps its warning.
///
/// 🔒 **This walk MIRRORS `flagRegion`'s and must keep doing so** — same lists, same stop
/// conditions. A test pins the two against each other.
fn misplacedFeaturesFlag(rest: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    outer: while (i < rest.len) {
        if (std.mem.eql(u8, rest[i], "--")) return null; // explicit hand-off; the guest's
        if (std.mem.eql(u8, rest[i], "--features") or
            std.mem.startsWith(u8, rest[i], "--features=")) return rest[i];
        for (flags_with_value) |f| if (std.mem.eql(u8, rest[i], f) and i + 1 < rest.len) {
            i += 2;
            continue :outer;
        };
        for (flags_bare) |f| if (std.mem.eql(u8, rest[i], f)) {
            i += 1;
            continue :outer;
        };
        return null; // first non-flag argument — everything from here is the guest's
    }
    return null;
}

/// ⚠️ **Z2 / `interop.md` §2.4a: a flag-shaped argument in a HOST-flag position that this command
/// does not recognise is an ERROR.** Returns the offending token, or null.
///
/// 🔒 **Owner, 2026-09-19 — v14, no "looks like":** *"If it is a valid cli option run it, if not
/// throw and error."* So this compares against the recognised set and nothing else: no prefix
/// matching, no near-miss adoption, and above all **no guessing that a flag is a PATH** — which is
/// what wazmrt used to do (`cannot read '--bogus': FileNotFound`, sending the user to the
/// filesystem to debug a typo'd flag).
///
/// 🎯 **`single_dash` is v15, the owner's same-day narrowing, and it is scoped by MODE.** After the
/// module path, a single-dash token is the GUEST's and runs as written (`prog.wasm -la`) — because
/// every host flag legal there is double-dash, so a lone dash cannot be one of ours. That carve-out
/// only applies where there IS a guest: in summarize and `.wast` there is no argv to hand it to, so
/// every argument is a host position (§2.4a item 4) and callers pass `single_dash = true`.
///
/// ⚠️ **Guest positions are never examined**, which is the half that keeps `prog.wasm install --yes`
/// working: the walk stops at an explicit `--` and at the first non-flag argument, so a guest's own
/// `--yes` can never be mistaken for the host's. §2.4 records what that trap cost.
fn unknownHostFlag(rest: []const []const u8, single_dash: bool) ?[]const u8 {
    var i: usize = 0;
    outer: while (i < rest.len) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--")) return null; // explicit hand-off; the guest's
        if (a.len < 2 or a[0] != '-') return null; // first non-flag argument — the guest's
        if (a[1] != '-' and !single_dash) return null; // v15: a lone dash belongs to the guest
        for (flags_with_value) |f| if (std.mem.eql(u8, a, f) and i + 1 < rest.len) {
            i += 2;
            continue :outer;
        };
        for (flags_bare) |f| if (std.mem.eql(u8, a, f)) {
            i += 1;
            continue :outer;
        };
        return a;
    }
    return null;
}

/// Report an unknown host flag and fail. One wording, so the call sites cannot drift.
///
/// ⚠️ **`has_guest` exists because the hint was false in half the places it printed.** The second
/// line used to advise *"use `--` to pass it to the guest"* unconditionally — including from
/// `.wast`, `wat` and summarize, which have no guest argv at all, so `--` there does nothing and
/// the advice sends the user to try something that cannot work. **A hint that names a remedy the
/// printing path does not have is the same defect class as a line that calls a module valid before
/// it validated** (§2.5 / Z3), and `--max-iterations` already cost this project the lesson once.
fn reportUnknownFlag(out: *Io.Writer, bad: []const u8, has_guest: bool) !void {
    try out.print("error: unknown flag '{s}'\n", .{bad});
    if (has_guest) {
        try out.print("  run with --help for the flags this command accepts; use '--' to pass it to the guest\n", .{});
    } else {
        try out.print("  run with --help for the flags this command accepts (this command takes no guest arguments)\n", .{});
    }
}
/// Split a `--dir` / `--ro-dir` spec into a host path and the guest path it is mounted at.
///
/// ⚠⚠ **The rule this replaces was BROKEN, and it broke the example wazmrt's own `--help` prints.**
/// It split on the last `:` **only when its index was > 1** — a guard meant to stop `C:\tmp` becoming
/// `C` + `\tmp`. But a **one-character relative host path** puts its colon at index 1 too, so `.:/`
/// was never split: the whole string became the host path and the run died with
/// `error: --dir '.:/': FileNotFound`. `./:/` worked, which is how long it hid. Measured 2026-09-19
/// during a cross-project pass; `interop.md` §2.2 had claimed since v1 that `--dir .:/` was a working
/// wazmrt invocation, and that claim had been **written from reading and never run**.
///
/// 🔒 **Owner decision, 2026-09-19 (`interop.md` §5 #10):** keep accepting a single `:`, but narrow
/// the drive-letter case to what a drive letter actually is — **exactly one ASCII letter, at the
/// start**. `.` is not a letter, so `.:/` splits; `C:\tmp` still does not.
///
/// The order matters and is the agreed resolution in §2.2 — **both runtimes accept both spellings**:
///
///   1. **`::` wins wherever it appears.** It is unambiguous and it is wasmrt's preferred spelling,
///      so a caller who wants no guessing at all has a way to say so.
///   2. Otherwise the **last** single `:` splits — so `C:\data:/data` mounts `C:\data` at `/data`.
///   3. Unless that colon is a **drive letter** (`C:\tmp`), in which case there is no guest path and
///      the spec is mounted at itself.
///
/// ⚠️ **One genuinely ambiguous case survives and is documented rather than guessed away:** `x:/`
/// means drive `X:` under rule 3, never the relative directory `x` mounted at `/`. Write `./x:/` or
/// `x::/` for the latter. *A rule that resolves every case is a rule that is wrong about one of them.*
fn splitPreopen(spec: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.lastIndexOf(u8, spec, "::")) |i| return .{ spec[0..i], spec[i + 2 ..] };
    const i = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return .{ spec, spec };
    if (i == 1 and std.ascii.isAlphabetic(spec[0])) return .{ spec, spec }; // a drive letter
    return .{ spec[0..i], spec[i + 1 ..] };
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

/// ⚠️ **Warn when a wazmrt flag was written where the GUEST will receive it.**
///
/// wazmrt flags are recognised only in the LEADING run after the module path
/// (`flagRegion`), which exists so a guest's own `--no-verify` can never be
/// mistaken for the host's. **That protection is one-directional, and the other
/// direction is what this function covers**: a flag placed after the first
/// non-flag argument is silently handed to the guest as argv and never applies.
///
/// 🔒 **Found by cross-project coordination, 2026-08-19** (`interop.md` §2.1m
/// F3 raised the mirror case in wasmrt). The split by flag is what makes it
/// worth a warning rather than a note:
///
///   - `--no-verify` / `--yes` dropped ⇒ verification stays ON — **fail-closed**,
///     and precisely the case `flagRegion` was built for.
///   - `--dir` / `--ro-dir` dropped ⇒ no preopen — fail-closed, but the guest
///     just gets `BADF` everywhere, which reads as a guest bug.
///   - ⚠️ **`--verify` / `--pins` / `--max-*` dropped ⇒ the DEFAULT applies.**
///     A user hardening an untrusted workload asked for a restriction, got no
///     error, and ran without it. **That direction is fail-OPEN**, and it is why
///     this is a warning and not a comment.
///
/// **Warn, do not refuse.** A guest may legitimately take one of these spellings
/// as its own argument (`wazmrt tool.wasm build --dir src` is a plausible real
/// command), so erroring would break valid invocations to catch a typo. ⚠️
/// Nothing after an explicit `--` is examined: there the user has *said* the rest
/// belongs to the guest, and warning would punish the correct spelling.
fn warnMisplacedFlags(out: *Io.Writer, rest: []const []const u8) !void {
    const guest = rest[flagRegion(rest).len..];
    for (guest) |a| {
        if (std.mem.eql(u8, a, "--")) break; // explicit hand-off; the user meant it
        const known = for (flags_with_value) |f| {
            if (std.mem.eql(u8, a, f)) break true;
        } else for (flags_bare) |f| {
            if (std.mem.eql(u8, a, f)) break true;
        } else false;
        if (!known) continue;
        try out.print(
            "warning: '{s}' came after a non-flag argument, so it was passed to the GUEST and did NOT apply\n" ++
                "  wazmrt flags must directly follow the module path; use '--' to pass one to the guest on purpose\n",
            .{a},
        );
    }
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
    const looked_up = resolvePinDb(arena, io, out) catch return false;
    const default_path = looked_up.?.path;
    const default_text: ?[]const u8 = looked_up.?.text;
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
    // The iteration budget is the one trap whose name does not tell the user what
    // to DO, and it is the one most likely to be hit by accident, so it gets a
    // sentence. ⚠️ It says "did not terminate within", not "infinite loop": the
    // budget bounds non-termination, it does not prove it — a legitimately
    // long-running module trips the same trap and its owner needs to know that
    // raising the ceiling is the right answer.
    if (e == error.IterationLimitExceeded)
        try out.print(
            "  the guest did not terminate within {d} iterations (loop back-edges + tail calls)\n" ++
                "  raise it with --max-iterations <n>, or --max-iterations 0 for no limit\n",
            .{inst.max_iterations},
        );
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
    max_iterations: u64,
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
            const host, const guest = splitPreopen(spec);
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
    try inst.instantiateWithImports(arena, module, .{ .funcs = funcs.items, .max_memory_bytes = max_memory, .max_table_elems = max_table_elems, .max_iterations = max_iterations });
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
    max_iterations: u64,
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
    // `instantiate` takes no options (that is `instantiateWithImports`), so the
    // iteration ceiling is applied to the built instance. It is read at each
    // top-level `invokeIndex`, so setting it here is in time.
    inst.max_iterations = max_iterations;

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

/// `warnMisplacedFlags` against a throwaway writer; returns what it printed.
fn misplacedWarnings(rest: []const []const u8) ![]const u8 {
    const S = struct {
        var buf: [2048]u8 = undefined;
    };
    var w: Io.Writer = .fixed(&S.buf);
    try warnMisplacedFlags(&w, rest);
    return w.buffered();
}

test "the pin DB lookup prefers the SHARED path and never disarms in silence" {
    // 🔒 `interop.md` §3.3, contract v18 (owner, 2026-09-19). All eight combinations, because the
    // one that matters is a single row and it is the one nobody would think to write by hand.
    const S = struct {
        fn eq(sh: bool, own: bool, sib: bool, which: @TypeOf(@as(PinDbChoice, undefined).which), warn: bool) !void {
            const c = choosePinDb(sh, own, sib);
            try std.testing.expectEqual(which, c.which);
            try std.testing.expectEqual(warn, c.warn_sibling);
        }
    };
    // The shared wasmtk path wins whenever it exists — that is what makes a binary swap keep its
    // policy — and the sibling's presence is then irrelevant.
    try S.eq(true, true, true, .shared, false);
    try S.eq(true, true, false, .shared, false);
    try S.eq(true, false, true, .shared, false);
    try S.eq(true, false, false, .shared, false);
    // Our own path is the fallback, so existing installs keep working.
    try S.eq(false, true, true, .own, false);
    try S.eq(false, true, false, .own, false);
    // ⚠⚠ **THE ROW THIS WHOLE DECISION EXISTS FOR.** Neither of ours, but the sibling's policy is
    // sitting right there: a part-migrated host. Without the warning this is indistinguishable from
    // an unmanaged machine — `armed = false`, no error, everything runs. A SILENT security downgrade.
    try S.eq(false, false, true, .none, true);
    // Genuinely no pin policy anywhere: unarmed, and silent, because that is a real configuration.
    try S.eq(false, false, false, .none, false);
}

test "--dir splits host from guest, and a DRIVE LETTER is not a separator" {
    // ⚠⚠ The rule this replaced split on the last `:` only when its index was > 1, to protect
    // `C:\tmp`. A ONE-CHARACTER relative host path puts its colon at index 1 too, so `.:/` was
    // never split — and `--dir .:/` is the example wazmrt's own `--help` prints. It failed with
    // `FileNotFound` on the whole spec. `./:/` worked, which is how long it hid.
    // 🔒 Owner, 2026-09-19 (`interop.md` §5 #10): a drive letter is exactly one ASCII letter at
    // the start — nothing else.
    const S = struct {
        fn eq(spec: []const u8, host: []const u8, guest: []const u8) !void {
            const h, const g = splitPreopen(spec);
            try std.testing.expectEqualStrings(host, h);
            try std.testing.expectEqualStrings(guest, g);
        }
    };
    // The regression, and the form the help documents.
    try S.eq(".:/", ".", "/");
    try S.eq("./:/", "./", "/");
    try S.eq("sub:/s", "sub", "/s");
    // `::` wins wherever it appears — wasmrt's spelling, and the way to ask for no guessing at all.
    try S.eq(".::/", ".", "/");
    try S.eq("C:\\data::/d", "C:\\data", "/d");
    // ⚠️ A drive letter is NOT a separator: no guest path, the spec mounts at itself.
    try S.eq("C:\\tmp", "C:\\tmp", "C:\\tmp");
    // ...but a drive-qualified path with a real guest path still splits on the LAST colon.
    try S.eq("C:\\data:/data", "C:\\data", "/data");
    // No colon at all: mounted at itself.
    try S.eq(".", ".", ".");
}

test "--features accepts wasm-tools' vocabulary as well as wazmrt's own" {
    // 🤝 `interop.md` §2.2 (v20): the same `--features` line must work on both runtimes.
    // `bulk-memory-operations` was an `unknown proposal` here while it worked on wasmrt.
    //
    // 🔎 Every hyphenated name below appears in `wasm-tools validate --features <unknown>`'s
    // "Valid features" list — read from the tool, not recalled.
    const S = struct {
        fn is(comptime want: wazmrt.features.Feature, spelling: []const u8) !void {
            try std.testing.expectEqual(want, featureFromSpelling(spelling).?);
        }
    };
    try S.is(.bulk_memory, "bulk_memory"); // wazmrt's own
    try S.is(.bulk_memory, "bulk-memory"); // wasm-tools'
    try S.is(.sign_extension, "sign-extension");
    try S.is(.saturating_float_to_int, "saturating-float-to-int");
    try S.is(.exceptions, "exceptions");
    try S.is(.reference_types, "reference-types");
    try S.is(.tail_call, "tail-call");
    try S.is(.custom_page_sizes, "custom-page-sizes");
    try S.is(.custom_descriptors, "custom-descriptors");
    try S.is(.wide_arithmetic, "wide-arithmetic");
    try S.is(.function_references, "function-references");

    // The longer proposal-repository spellings, each verified accepted by wasmrt.
    try S.is(.bulk_memory, "bulk-memory-operations");
    try S.is(.sign_extension, "sign-extension-ops");
    try S.is(.saturating_float_to_int, "nontrapping-float-to-int-conversions");
    try S.is(.exceptions, "exception-handling");

    // ⚠️ Widening the vocabulary must NOT widen it to "anything": an unknown name stays an error,
    // or a restriction silently drops what it was told to exclude. Both of these are rejected by
    // wasmrt too, which is why they are the ones pinned here.
    try std.testing.expect(featureFromSpelling("mutable-global") == null);
    try std.testing.expect(featureFromSpelling("tail-calls") == null);
    try std.testing.expect(featureFromSpelling("sim") == null);
    try std.testing.expect(featureFromSpelling("") == null);
}

test "a wazmrt flag after --allow-symlink still APPLIES (the list drift that disarmed --verify)" {
    // 🚨 **This is a SECURITY regression test.** `--allow-symlink` is parsed by `runWasi`'s own flag
    // loop but was missing from `flags_bare`, so `flagRegion` ENDED at it and every host flag after
    // it became invisible to `hasFlag`, `flagValue` and the `--max-iterations` splice.
    //
    // Measured before the fix, 2026-09-19:
    //   wazmrt start.wasm --verify enforce                  -> rc 1, refused (correct)
    //   wazmrt start.wasm --allow-symlink --verify enforce  -> rc 0, **RAN UNVERIFIED**
    //
    // 🎓 The "one list" comment above `flags_with_value` exists to stop exactly this, and it had
    // happened anyway: the list was in one place and the PARSER was reading a different vocabulary.
    // *A list kept in one place is not the same as a list kept in agreement with its consumer.*

    // The whole line must be consumed as host flags — nothing may be left for the guest.
    const line = [_][]const u8{ "--allow-symlink", "--verify", "enforce", "--no-verify", "--max-iterations", "1000" };
    try std.testing.expectEqual(line.len, flagRegion(&line).len);

    // The direction that actually bit: a verification flag written after it must still be FOUND.
    try std.testing.expect(hasFlag(&line, "--no-verify"));
    try std.testing.expectEqualStrings("enforce", flagValue(&line, "--verify").?);
    try std.testing.expectEqualStrings("1000", flagValue(&line, "--max-iterations").?);

    // ⚠️ And the protection it must NOT weaken: past the first guest argument, nothing is ours.
    const guest = [_][]const u8{ "--allow-symlink", "install", "--yes" };
    try std.testing.expectEqual(@as(usize, 1), flagRegion(&guest).len);
    try std.testing.expect(!hasFlag(&guest, "--yes"));
}

test "an unrecognised flag in a HOST position is an error; guest positions are untouched" {
    // 🔒 Z2 / `interop.md` §2.4a, as narrowed by v15, and §2.4a-i (v14): exact match or error.
    // wazmrt used to exit **0** for an unknown flag after the module path and in `.wast`, and to
    // report one before the path as `cannot read '--bogus': FileNotFound` — a path-guess.

    // ---- host positions: an unknown `--flag` is an error regardless of mode ----
    try std.testing.expectEqualStrings("--bogus", unknownHostFlag(&.{"--bogus"}, false).?);
    try std.testing.expectEqualStrings("--bogus", unknownHostFlag(&.{ "--dir", ".", "--bogus" }, false).?);
    try std.testing.expectEqualStrings("--bogus", unknownHostFlag(&.{ "--allow-symlink", "--bogus" }, false).?);

    // ---- v15: a SINGLE-dash token is the guest's wherever there IS a guest ----
    try std.testing.expect(unknownHostFlag(&.{"-la"}, false) == null);
    // ...and a host position wherever there is NOT (summarize, `.wast`, `wat` — §2.4a item 4).
    try std.testing.expectEqualStrings("-la", unknownHostFlag(&.{"-la"}, true).?);

    // ---- recognised flags are consumed, with and without their values ----
    try std.testing.expect(unknownHostFlag(&.{ "--dir", ".", "--no-verify", "--max-memory", "1M" }, true) == null);

    // ---- guest positions are NEVER examined, which is half the rule ----
    // After an explicit `--` the user said the rest is the guest's.
    try std.testing.expect(unknownHostFlag(&.{ "--", "--bogus" }, true) == null);
    // ⚠️ After the first non-flag argument. This is `prog.wasm install --yes`, the case §2.4 was
    // bought with: a guest's own `--yes` must never be read as the host's.
    try std.testing.expect(unknownHostFlag(&.{ "install", "--yes" }, true) == null);
    try std.testing.expect(unknownHostFlag(&.{ "add", "-1", "2" }, true) == null);
    // A lone "-" is a conventional stdin/stdout stand-in, not a flag.
    try std.testing.expect(unknownHostFlag(&.{"-"}, true) == null);
    try std.testing.expect(unknownHostFlag(&.{}, true) == null);
}

test "B-c4: `wasi`'s leading flags move BEHIND the module, never behind the `--`" {
    // 🤝 `interop.md` §2.1 (v20): the sibling's spelling is `wasi [flags] <file> [-- argv]`, and
    // measured, it accepts the flags on either side. wazmrt's parser wants the path first, so the
    // leading run is moved — and the ORDER of that move is the whole risk.
    //
    // ⚠️⚠️ `tail ++ lead` would put `--dir` AFTER the explicit `--`, where it becomes the guest's
    // argv and wazmrt never looks at it: the run then proceeds with no preopen and says nothing.
    // Fail-OPEN, from an ordering mistake, on the flag that grants filesystem access.
    const a = std.testing.allocator;

    // Flags before the path, with an explicit guest hand-off after it.
    {
        const s = (try wasiSplit(a, &.{ "--dir", ".:/", "prog.wasm", "--", "x" })).?;
        defer a.free(s.rest);
        try std.testing.expectEqualStrings("prog.wasm", s.path);
        try std.testing.expectEqual(@as(usize, 4), s.rest.len);
        try std.testing.expectEqualStrings("--dir", s.rest[0]);
        try std.testing.expectEqualStrings(".:/", s.rest[1]);
        // 🔒 The `--` must still come AFTER the flags, or the grant is lost.
        try std.testing.expectEqualStrings("--", s.rest[2]);
        try std.testing.expectEqualStrings("x", s.rest[3]);
    }
    // Flags on BOTH sides — the sibling accepts that, so both must survive.
    {
        const s = (try wasiSplit(a, &.{ "--dir", ".:/", "prog.wasm", "--env", "A=1", "--", "x" })).?;
        defer a.free(s.rest);
        try std.testing.expectEqualStrings("prog.wasm", s.path);
        try std.testing.expectEqualSlices([:0]const u8, &.{ "--dir", ".:/", "--env", "A=1", "--", "x" }, s.rest);
    }
    // The bare `wasi <file>` form, and `wasi <file> [flags]` — nothing to move.
    {
        const s = (try wasiSplit(a, &.{ "prog.wasm", "--allow-symlink" })).?;
        defer a.free(s.rest);
        try std.testing.expectEqualStrings("prog.wasm", s.path);
        try std.testing.expectEqualSlices([:0]const u8, &.{"--allow-symlink"}, s.rest);
    }
    // No module named at all: flags only, and flags that consume a value.
    try std.testing.expect((try wasiSplit(a, &.{})) == null);
    try std.testing.expect((try wasiSplit(a, &.{ "--dir", "." })) == null);
    // ⚠️ An UNRECOGNISED leading flag is NOT consumed — `flagRegion` stops at it, so it lands in
    // the path position where the caller reports it as an unknown flag (§2.4a) rather than
    // trying to open it as a file. Pinned here because it is the behaviour the caller relies on.
    {
        const s = (try wasiSplit(a, &.{ "--bogus", "prog.wasm" })).?;
        defer a.free(s.rest);
        try std.testing.expectEqualStrings("--bogus", s.path);
    }
}

test "--features written AFTER the module path is an ERROR, not a silent no-op" {
    // 🔒 **Owner, 2026-09-19:** *"we need an error thrown when it is in the wrong location."*
    //
    // ⚠️ **Before this, `wazmrt m.wasm --features mvp` ran under the FULL feature set and printed
    // NOTHING.** `--features` precedes the module path, so it is deliberately absent from
    // `flagRegion`'s lists (a guest's own `--features mvp` must never narrow the language). The
    // cost was that no code path noticed it being in the wrong place: `flagRegion` stops at it,
    // and `warnMisplacedFlags` only fires for names in those lists.
    //
    // 🎓 **The fail-OPEN direction on the one flag whose entire job is to REFUSE modules** — the
    // user asked for a smaller trusted computing base, got no error, and ran with everything on.

    // ---- the wrong position is caught, in every host-flag spelling ----
    try std.testing.expectEqualStrings("--features", misplacedFeaturesFlag(&.{"--features", "mvp"}).?);
    try std.testing.expectEqualStrings("--features=mvp", misplacedFeaturesFlag(&.{"--features=mvp"}).?);
    // ...including after a correctly-placed trailing flag, which is still a HOST position.
    try std.testing.expectEqualStrings("--features", misplacedFeaturesFlag(&.{ "--dir", ".", "--features", "mvp" }).?);
    try std.testing.expectEqualStrings("--features", misplacedFeaturesFlag(&.{ "--no-verify", "--features", "mvp" }).?);

    // ---- and the directions that must stay SILENT, which is half the point ----

    // ⚠️ After an explicit `--` the user SAID the rest is the guest's. This is the spelling the
    // error message recommends, so erroring here would make the advice a lie.
    try std.testing.expect(misplacedFeaturesFlag(&.{ "--", "--features", "mvp" }) == null);
    // After the first non-flag argument it is guest argv / export arguments. A guest may
    // legitimately take `--features` as its own option; `warnMisplacedFlags` keeps that case.
    try std.testing.expect(misplacedFeaturesFlag(&.{ "guestarg", "--features", "mvp" }) == null);
    // An ordinary export call must not be disturbed.
    try std.testing.expect(misplacedFeaturesFlag(&.{ "add", "2", "3" }) == null);
    // Correctly-placed trailing flags alone: nothing to report.
    try std.testing.expect(misplacedFeaturesFlag(&.{ "--dir", ".", "--", "x" }) == null);
    // Empty rest (bare summarize).
    try std.testing.expect(misplacedFeaturesFlag(&.{}) == null);
}

test "misplacedFeaturesFlag walks exactly the region flagRegion does" {
    // 🔒 The two walks share `flags_with_value` / `flags_bare` and must agree on where the
    // host's flags stop, or one of them will judge a token the other has already handed to the
    // guest. *A list written out a second time is a list that will drift* — this pins the pair.
    const cases = [_][]const []const u8{
        &.{ "--dir", ".", "--no-verify", "guestarg", "--features", "mvp" },
        &.{ "--max-iterations", "1000", "--", "--features", "mvp" },
        &.{ "--yes", "--features", "mvp" },
        &.{"guestarg"},
        &.{},
    };
    for (cases) |rest| {
        const region = flagRegion(rest);
        if (misplacedFeaturesFlag(rest)) |bad| {
            // It reported: the offender must sit at the END of the host-flag region, i.e. at the
            // first index flagRegion stopped at — never inside the guest's argv.
            try std.testing.expect(region.len < rest.len);
            try std.testing.expectEqualStrings(rest[region.len], bad);
        } else {
            // It stayed silent: nothing in the host-flag region may be a --features spelling.
            for (region) |a| {
                try std.testing.expect(!std.mem.eql(u8, a, "--features"));
                try std.testing.expect(!std.mem.startsWith(u8, a, "--features="));
            }
        }
    }
}

test "a wazmrt flag written where only the GUEST sees it is warned about" {
    // 🔒 **Found by cross-project coordination, 2026-08-19** (`interop.md` §2.1m
    // F3 raised the mirror case in wasmrt). wazmrt flags are recognised only in
    // the LEADING run after the module path — a protection built so a guest's own
    // `--no-verify` is never mistaken for the host's. **The inverse was never
    // considered:** a flag placed after the first non-flag argument is handed to
    // the guest and never applies, and for `--verify` / `--pins` / `--max-*` that
    // direction is **fail-OPEN** — the user asked for a restriction, got no error,
    // and ran without it.
    //
    // ⚠️ Demonstrated with `--max-iterations`, a flag added earlier the same day:
    // `wazmrt spin.wat guestarg --max-iterations 1000` ran under the DEFAULT
    // 1<<30 budget and said nothing.

    // The reported case: a value-taking flag after a non-flag argument.
    {
        const w = try misplacedWarnings(&.{ "guestarg", "--max-iterations", "1000" });
        try std.testing.expect(std.mem.indexOf(u8, w, "--max-iterations") != null);
        try std.testing.expect(std.mem.indexOf(u8, w, "did NOT apply") != null);
    }
    // The fail-open security case.
    {
        const w = try misplacedWarnings(&.{ "guestarg", "--verify", "enforce" });
        try std.testing.expect(std.mem.indexOf(u8, w, "--verify") != null);
    }
    // A bare flag counts too — `--no-verify` dropped is fail-CLOSED, but the user
    // still asked for something they did not get, and silence is what this fixes.
    {
        const w = try misplacedWarnings(&.{ "guestarg", "--no-verify" });
        try std.testing.expect(std.mem.indexOf(u8, w, "--no-verify") != null);
    }

    // ---- and the directions that must stay SILENT, which is half the point ----

    // Correct placement: the flag is in the leading run, so it applies.
    try std.testing.expectEqual(@as(usize, 0), (try misplacedWarnings(&.{ "--max-iterations", "1000", "guestarg" })).len);
    // ⚠️ After an explicit `--` the user SAID the rest is the guest's. Warning
    // there would punish the correct spelling for passing a flag on purpose.
    try std.testing.expectEqual(@as(usize, 0), (try misplacedWarnings(&.{ "--", "--max-iterations", "1000" })).len);
    try std.testing.expectEqual(@as(usize, 0), (try misplacedWarnings(&.{ "guestarg", "--", "--verify" })).len);
    // A guest argument that merely LOOKS flag-ish is not one of ours.
    try std.testing.expectEqual(@as(usize, 0), (try misplacedWarnings(&.{ "guestarg", "--max-iterations-ish", "--verifyx" })).len);
    // No arguments at all.
    try std.testing.expectEqual(@as(usize, 0), (try misplacedWarnings(&.{})).len);
}
