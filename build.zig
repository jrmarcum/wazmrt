const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Core library module (dependency-free, wasm-friendly) --------------
    const mod = b.addModule("wazmrt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- Signature trust anchor (build-time embed) -------------------------
    // `-Droot-key=<64 hex chars>` embeds the Ed25519 root public key the CLI
    // verifies module signatures against. Empty (the default) ⇒ verification is
    // inert. Only main.zig reads it, so `build_options` is imported by the CLI
    // module alone — sign.zig (compiled into every target via root.zig) stays
    // free of build plumbing.
    const root_key_hex = b.option([]const u8, "root-key", "Ed25519 root public key (64 hex chars) to embed as the signature trust anchor; empty ⇒ verification inert") orelse "";
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "root_key_hex", root_key_hex);

    // ---- CLI front-end -----------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "wazmrt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wazmrt", .module = mod },
                .{ .name = "build_options", .module = cli_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI (zig build run -- <module.wasm>)");
    run_step.dependOn(&run_cmd.step);

    // ---- C ABI library for universalWasmLoader-* ---------------------------
    // The native ABI-2 surface (`include/wazmrt.h`), which replaced the vendored wasm-c-api.
    // Own root module so the core stays libc-free; this artifact is libc-free too.
    //
    // `zig-out/include` is now ONE file. Nothing third-party ships, so there is no licence to
    // propagate alongside it — see cmem/licensing.md.
    const cabi = b.addLibrary(.{
        .name = "wazmrt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi.installHeader(b.path("include/wazmrt.h"), "wazmrt.h");
    b.installArtifact(cabi);

    // ---- C ABI *shared* library (`zig build dll`) --------------------------
    // The same implementation as a dynamic library, so host languages can load it over FFI
    // (Deno.dlopen, Python ctypes, …) — the vision's "native FFI → the C-ABI shared library"
    // path. Libc-free, like the static lib.
    const dll = b.addLibrary(.{
        .name = "wazmrt",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_dll = b.addInstallArtifact(dll, .{});
    const dll_step = b.step("dll", "Build the C ABI as a shared library (for FFI)");
    dll_step.dependOn(&install_dll.step);

    // ---- Deno FFI demo (`zig build ffi-demo`) ------------------------------
    // Builds the DLL, then runs a Deno script that loads it over FFI and drives
    // the standard wasm-c-api (decode -> instantiate -> call) — proving the
    // native runtime binds from a host language. Requires `deno` on PATH.
    const ffi = b.addSystemCommand(&.{ "deno", "run", "--allow-ffi", "--allow-env" });
    // `addFileArg`, not a relative string: a bare "examples/…" resolves against the PROCESS cwd,
    // so the step worked from the repo root and failed from anywhere else — including
    // `zig build --build-file` run from another drive, which is how the sandbox tests have to be
    // run on this machine.
    ffi.addFileArg(b.path("examples/deno_ffi_capi.mjs"));
    ffi.setEnvironmentVariable("WAZMRT_CAPI_DLL", b.getInstallPath(.bin, "wazmrt.dll"));
    ffi.step.dependOn(&install_dll.step);
    const ffi_step = b.step("ffi-demo", "Build the DLL + run the Deno FFI demo (needs deno)");
    ffi_step.dependOn(&ffi.step);

    // ---- Freestanding wasm build (`zig build wasm`) ------------------------
    // Proves the runtime itself compiles to WebAssembly.
    const wasm_exe = b.addExecutable(.{
        .name = "wazmrt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build the runtime as a freestanding wasm module");
    wasm_step.dependOn(&install_wasm.step);

    // ---- ABI-2 C smoke test (`zig build capi-smoke`) -----------------------
    // The same idea as `c-smoke`, pointed at the NEW surface: compile `tests/capi_smoke.c`
    // against `src/capi.zig` exactly as an embedder would, and run it. Two things it proves that
    // the Zig tests cannot — that the published HEADER is usable from a C compiler (types,
    // const-ness, calling convention), and that every function it declares really links.
    //
    // `tests/wazmrt_abi_symbols.c` is the completeness gate: it takes the address of every
    // declared function, so a symbol we promise but never define breaks THIS build rather than an
    // embedder's. Audit #20 found 180 such symbols in the old ABI, invisible because our own tests
    // only called what we had implemented.
    //
    // mingw target for the same reason `c-smoke` uses it: the C client needs a libc without MSVC.
    // The wazmrt library itself stays libc-free.
    {
        const gnu = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
        const capi_gnu = b.addLibrary(.{
            .name = "wazmrt_capismoke",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/capi.zig"),
                .target = gnu,
                .optimize = optimize,
            }),
        });
        const smoke_mod = b.createModule(.{ .target = gnu, .optimize = optimize, .link_libc = true });
        smoke_mod.addCSourceFile(.{ .file = b.path("tests/capi_smoke.c"), .flags = &.{ "-Wall", "-Wextra" } });
        smoke_mod.addCSourceFile(.{ .file = b.path("tests/wazmrt_abi_symbols.c"), .flags = &.{ "-Wall", "-Wextra" } });
        smoke_mod.addIncludePath(b.path("include"));
        smoke_mod.linkLibrary(capi_gnu);
        const smoke = b.addExecutable(.{ .name = "capi_smoke", .root_module = smoke_mod });
        const run_smoke = b.addRunArtifact(smoke);
        const step = b.step("capi-smoke", "Build + run the ABI-2 C smoke test (link-time symbol gate included)");
        step.dependOn(&run_smoke.step);
    }

    // ---- Interpreter microbenchmark (`zig build bench`) --------------------
    // In-process cold-path + steady-state timing, always ReleaseFast so the
    // numbers reflect the real interpreter, not a Debug build.
    {
        const bench = b.addExecutable(.{
            .name = "bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "wazmrt", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                }) }},
            }),
        });
        const run_bench = b.addRunArtifact(bench);
        if (b.args) |args| run_bench.addArgs(args); // `zig build bench -- out.wasm` emits the module
        const bench_step = b.step("bench", "Run the interpreter microbenchmark (ReleaseFast)");
        bench_step.dependOn(&run_bench.step);
    }

    // ---- Compiled-program conformance gate (`zig build wasi-gate`) ---------
    // Compiles REAL `wasm32-wasi` programs with independent toolchains, runs
    // each through the wazmrt CLI, and asserts exact stdout. This turns the
    // hand-run WASI examples into a CI gate: a regression in decode /
    // instantiate / the WASI host surface fails the build, not a manual check.
    //
    //   Zig  — always available (this toolchain), compiled to wasm32-wasi.
    //   C    — always available (`zig cc` ships clang + wasi-libc).
    //   Rust — opt-in `-Drust-gate=true` (needs rustc w/ wasm32-wasip1); a
    //          genuinely different compiler is the strongest conformance signal.
    {
        const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
        const gate_step = b.step("wasi-gate", "Compile wasm32-wasi programs (Zig/C[/Rust]) and run them through wazmrt");

        // Assert `wazmrt <wasm>` prints exactly `out`.
        const assertOut = struct {
            fn run(bld: *std.Build, cli: *std.Build.Step.Compile, step: *std.Build.Step, wasm: std.Build.LazyPath, out: []const u8) void {
                const r = bld.addRunArtifact(cli);
                r.addFileArg(wasm);
                r.expectStdOutEqual(out);
                step.dependOn(&r.step);
            }
        }.run;

        // Zig guest — compiled by the Zig build graph itself.
        const zig_guest = b.addExecutable(.{
            .name = "wasi_gate_zig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/hello_compiled.zig"),
                .target = wasi_target,
                .optimize = .ReleaseSmall,
            }),
        });
        assertOut(b, exe, gate_step, zig_guest.getEmittedBin(), "Hello from a compiled WASI program!\nbulk-memory memcpy works\nsaturating truncation works\n");

        // C guest — `zig cc -target wasm32-wasi` (LLVM + bundled wasi-libc).
        const cc = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-target", "wasm32-wasi", "-Oz", "-o" });
        const c_wasm = cc.addOutputFileArg("c_hello.wasm");
        cc.addFileArg(b.path("examples/c_hello.c"));
        assertOut(b, exe, gate_step, c_wasm, "Hello from C on wazmrt!\nsum 1..100 = 5050\n");

        // Rust guest — opt-in; a third, independent compiler.
        if (b.option(bool, "rust-gate", "Also build examples/rust_hello.rs via rustc (needs wasm32-wasip1)") orelse false) {
            const rc = b.addSystemCommand(&.{ "rustc", "--target", "wasm32-wasip1", "-O", "-o" });
            const rust_wasm = rc.addOutputFileArg("rust_hello.wasm");
            rc.addFileArg(b.path("examples/rust_hello.rs"));
            assertOut(b, exe, gate_step, rust_wasm, "Hello from Rust on wazmrt!\nsum of squares 1..5 = 55\n");
        }
    }

    // ---- Tests -------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The C ABI needs its own test target: `root.zig` does not import `capi.zig` (the dependency
    // runs the other way), so its tests are unreachable from `mod_tests`. That gap is not
    // theoretical — the previous C ABI had NO reachable tests for its entire life, and shipped
    // #21's double free, use-after-free and uninitialised refcount as a result. These drive the C
    // entry points under `std.testing.allocator`, which catches what a C smoke test cannot: on
    // the real allocator a double free corrupts the freelist silently and the test still prints OK.
    const capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(capi_tests).step);

    // ---- Security gate (`zig build test-security`) -------------------------
    // The sandbox-escape tests SKIP when the harness cannot create a symlink. ⚠️ On the dev machine
    // that is NOT a privilege problem — Developer Mode is on. `std.testing.tmpDir` puts its scratch
    // under `.zig-cache/tmp` **relative to the CWD**, and the D: drive is **exFAT**, which has no
    // reparse points, so FSCTL_SET_REPARSE_POINT returns INVALID_DEVICE_REQUEST. Run from an NTFS cwd
    // and the whole suite is **493/493 with ZERO skips**. Inside `zig build test` that skip disappears
    // into "489/493, 4 skipped" — and an UNVERIFIED sandbox then looks exactly like a verified one.
    // Removing that ambiguity is the entire point of this step.
    //
    // `WAZMRT_SECURITY_STRICT=1` makes those same tests FAIL instead of skipping, so this step goes
    // red on a box that cannot verify the sandbox. Deliberately separate: the default `test` stays
    // dev-friendly on an unprivileged box, while the security properties get a gate that CAN fail.
    //
    // A skip here was never a pass — it fires during fixture setup, before any assertion, so nothing
    // was refused by wazmrt; the OS refused the test harness. Run this before any security review, and
    // if it goes red for lack of privilege, grant the privilege and run it again rather than waving
    // it through.
    {
        const sec_tests = b.addTest(.{
            .root_module = mod,
            // Only the tests whose subject IS the sandbox boundary. Keep this list in step with any
            // new escape/traversal test, or the gate silently stops covering it.
            .filters = &.{ "symlink traversal", "symlink resolver fuzz" },
        });
        const run_sec = b.addRunArtifact(sec_tests);
        run_sec.setEnvironmentVariable("WAZMRT_SECURITY_STRICT", "1");
        run_sec.has_side_effects = true; // always re-run: a cached pass proves nothing about today
        const sec_step = b.step("test-security", "Sandbox-escape tests, where a SKIP is a FAILURE (run from an NTFS cwd)");
        sec_step.dependOn(&run_sec.step);
    }

    // ---- ReleaseSafe test run (`zig build test-safe`) ----------------------
    // The same suite compiled with the optimizer ON but safety checks KEPT
    // (bounds, integer overflow, out-of-range @intCast, .? on null, reaching
    // `unreachable`). A memory-safety bug that only manifests in an optimized
    // build — or the malformed-input fuzz's OOB/overflow — trips a panic here
    // instead of being silent UB in the shipped ReleaseFast/ReleaseSmall builds.
    // Kept a separate step so the default `test` stays a fast Debug run.
    {
        const mod_tests_safe = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }) });
        // The C ABI is in the memory-safety gate as well: a C boundary is exactly where an
        // out-of-range cast or a bad index stops being a wrong answer and becomes a corrupted
        // heap, and ReleaseSafe is what turns that from silent UB in the SHIPPED build into a
        // loud panic here.
        const capi_tests_safe = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }) });
        const test_safe_step = b.step("test-safe", "Run the test suite under ReleaseSafe (optimized + safety checks kept)");
        test_safe_step.dependOn(&b.addRunArtifact(mod_tests_safe).step);
        test_safe_step.dependOn(&b.addRunArtifact(capi_tests_safe).step);
    }

    // ---- Size gate (`zig build size -Doptimize=ReleaseSmall`) --------------
    // `ReleaseSmall` is a first-class goal, and a goal with no gate is a preference: between
    // 2026-07-14 and 2026-08-11 the DLL grew +75% and the static lib +122% unnoticed, because the only
    // size numbers on record were a month-old note in a memory file. Same shape as `test-security` —
    // a step whose entire value is that it CAN go red.
    //
    // Ceilings in `tools/size-ceilings.txt` are EXACT, so growth must raise the number in the same
    // commit and say what bought the bytes. Not wired into `zig build test`: it needs the artifacts
    // built in the shipping mode, and silently passing in Debug would be worse than not running.
    {
        const size_gate = b.addExecutable(.{ .name = "size_gate", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/size_gate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }) });
        const run_size = b.addRunArtifact(size_gate);
        run_size.addFileArg(b.path("tools/size-ceilings.txt"));
        // The mode is passed to the TOOL rather than checked here: a configure-time warning would
        // print on every `zig build`, including the ones that never asked for this step.
        run_size.addArg(@tagName(optimize));
        run_size.addArg(b.getInstallPath(.bin, ""));
        run_size.addArg(b.getInstallPath(.lib, ""));
        run_size.has_side_effects = true; // measure what is on disk NOW, never a cached verdict
        run_size.step.dependOn(b.getInstallStep());

        const size_step = b.step("size", "Check shipped artifact sizes (needs -Doptimize=ReleaseSmall)");
        size_step.dependOn(&run_size.step);
    }

    // ---- Spec-conformance runner (`zig build conformance -Dtestsuite=<dir>`) -
    // Walks a WebAssembly spec-testsuite checkout (a directory of `.wast` files),
    // runs each through the in-process `.wast` runner, aggregates pass/fail, and
    // fails the build if any assertion fails. The corpus is NOT vendored (it is
    // large and lives upstream / on removable media — see cmem/testing.md), so
    // point the step at a local checkout:
    //   git clone https://github.com/WebAssembly/testsuite
    //   zig build conformance -Dtestsuite=path/to/testsuite
    // With no `-Dtestsuite`, the runner prints how to use it and exits 0.
    {
        const testsuite = b.option([]const u8, "testsuite", "Directory of spec-testsuite .wast files for `zig build conformance`");
        const baseline = b.option([]const u8, "baseline", "Expected-failure baseline file — gates on REGRESSIONS instead of zero failures");
        const write_baseline = b.option(bool, "write-baseline", "Write today's results to -Dbaseline=<file> instead of checking against it") orelse false;
        const conf = b.addExecutable(.{ .name = "conformance", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wazmrt", .module = mod }},
        }) });
        const run_conf = b.addRunArtifact(conf);
        run_conf.addArg(testsuite orelse ""); // empty ⇒ the runner prints guidance
        run_conf.addArg(baseline orelse ""); // empty ⇒ gate on zero failures
        run_conf.addArg(if (write_baseline) "write" else "check");
        const conf_step = b.step("conformance", "Run the spec testsuite (.wast) — needs -Dtestsuite=<dir>; add -Dbaseline=<file> to gate on regressions");
        conf_step.dependOn(&run_conf.step);
    }
}
