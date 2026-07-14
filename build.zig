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
        csmoke_mod.addIncludePath(b.path("include"));
        csmoke_mod.addIncludePath(b.path("third_party/wasm-c-api/include"));
        csmoke_mod.linkLibrary(cabi_gnu);
        const csmoke = b.addExecutable(.{ .name = "c_smoke", .root_module = csmoke_mod });
        const run_csmoke = b.addRunArtifact(csmoke);
        const csmoke_step = b.step("c-smoke", "Build + run the C smoke test (wasm-c-api from C)");
        csmoke_step.dependOn(&run_csmoke.step);
    }

    // ---- Tests -------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
