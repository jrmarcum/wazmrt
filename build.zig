const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Core library module (dependency-free, wasm-friendly) --------------
    const mod = b.addModule("wazmrt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- CLI front-end -----------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "wazmrt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wazmrt", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI (zig build run -- <module.wasm>)");
    run_step.dependOn(&run_cmd.step);

    // ---- C ABI library for universalWasmLoader-* ---------------------------
    // Implements the standard wasm-c-api (third_party/wasm-c-api/include/wasm.h).
    // Own root module so the core stays libc-free; this artifact is libc-free too.
    const cabi = b.addLibrary(.{
        .name = "wazmrt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi.installHeader(b.path("third_party/wasm-c-api/include/wasm.h"), "wasm.h");
    cabi.installHeader(b.path("include/wazmrt.h"), "wazmrt.h");
    b.installArtifact(cabi);

    // ---- C ABI *shared* library (`zig build dll`) --------------------------
    // The same wasm-c-api implementation as a dynamic library, so host languages
    // can load it over FFI (Deno.dlopen, Python ctypes, …) — the vision's
    // "native FFI → the C-ABI shared library" path. Libc-free, like the static
    // lib.
    const dll = b.addLibrary(.{
        .name = "wazmrt",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_c_api.zig"),
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
    const ffi = b.addSystemCommand(&.{ "deno", "run", "--allow-ffi", "--allow-env", "examples/deno_ffi.mjs" });
    ffi.setEnvironmentVariable("WAZMRT_DLL", "zig-out/bin/wazmrt.dll");
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

    // ---- C smoke test (`zig build c-smoke`) --------------------------------
    // Compiles tests/c_smoke.c against the C ABI exactly as an embedder would and
    // runs it: engine/store, module decode + introspection, and instantiate +
    // call. Uses the mingw (windows-gnu) target so the C client gets a libc
    // without MSVC (the native target can't link libc on a MSVC-less box — see
    // cmem/design-decisions.md); the wazmrt lib itself stays libc-free.
    {
        const gnu = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
        const cabi_gnu = b.addLibrary(.{
            .name = "wazmrt_csmoke",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm_c_api.zig"),
                .target = gnu,
                .optimize = optimize,
            }),
        });
        const csmoke_mod = b.createModule(.{ .target = gnu, .optimize = optimize, .link_libc = true });
        csmoke_mod.addCSourceFile(.{ .file = b.path("tests/c_smoke.c"), .flags = &.{"-DLIBWASM_STATIC"} });
        // The completeness gate: references every function wasm.h declares, so a
        // symbol we promise but don't define breaks THIS build rather than an
        // embedder's link. See cmem/known-issues.md #20.
        csmoke_mod.addCSourceFile(.{ .file = b.path("tests/c_abi_symbols.c"), .flags = &.{"-DLIBWASM_STATIC"} });
        csmoke_mod.addIncludePath(b.path("include"));
        csmoke_mod.addIncludePath(b.path("third_party/wasm-c-api/include"));
        csmoke_mod.linkLibrary(cabi_gnu);
        const csmoke = b.addExecutable(.{ .name = "c_smoke", .root_module = csmoke_mod });
        const run_csmoke = b.addRunArtifact(csmoke);
        const csmoke_step = b.step("c-smoke", "Build + run the C smoke test (wasm-c-api from C)");
        csmoke_step.dependOn(&run_csmoke.step);
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

    // The C ABI needs its own test target: `root.zig` doesn't import
    // `wasm_c_api.zig` (the dependency runs the other way), so tests in it were
    // unreachable from `mod_tests` — the file had none, and couldn't have had
    // any. Its tests drive the C entry points under `std.testing.allocator`,
    // which catches the double-frees and leaks that the C smoke test cannot see
    // (on the real allocator a double free corrupts the freelist silently and
    // the test still prints OK).
    const cabi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cabi_tests).step);
}
